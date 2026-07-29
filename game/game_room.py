# coding=utf-8

"""
文件: server/game/game_room.py
作用: 服务器端「唯一」的游戏状态持有者

============================================================================
 为什么有这个文件（核心动机）
============================================================================
重构前，玩家状态散落在 web_server.py 各处：
    - on_player_join 里:  server.player_infos[pid] = player_info
    - on_player_move 里:  server.player_infos[pid]["x"] = data["x"]
    - cleanup_player 里:  del server.player_infos[pid]
    - on_player_join 里:  list(server.player_infos.values())  # 拼 GameState

这带来三个问题：
    1. 状态变更规则无统一入口，想加校验（如「移动不能穿墙」）要在多处改
    2. 客户端为了预测，很容易把同样的 apply_move 复制一份到 GDScript，
       导致状态逻辑双端各写一遍——这正是我们最想避免的重复
    3. 状态形状（玩家字典里有哪些字段）被 handler 隐式约定，proto 一改两边漏改

解决思路：把「状态长什么样、怎么变」全部收口到 GameRoom 这一个类。
    handler 只做三件事：从消息里取参数 → 调 GameRoom 方法 → 把结果发出去。
    handler 不再直接读写 _entities。

这样客户端的对应物（ClientStateMirror）就只能是「只读镜像」——
    它没有 apply_move 可抄，因为 apply_move 根本不存在于客户端。
    状态逻辑的重复从「难以避免」变成「结构上不可能发生」。

============================================================================
 统一 Entity 模型（本次重构）
============================================================================
所有可交互物体都是 Entity:玩家、木桩、箱子、陷阱...
统一用 _entities: Dict[entity_id, EntityInfo] 一张表存,不再区分 player/entity。

区别在 entity_type 决定的"行为能力"(见 entity_config.py):
    - player: 可移动/可攻击/可被攻击/可断连
    - stake:  不可移动/不可攻击/可被攻击/不可断连

apply_xxx 方法先查能力再改状态,不能干的就拒绝。
get_attack_hits 遍历一张表,用 can_be_hurt 过滤,无需分流。

ID 格式统一带类型前缀:
    - "player:uuid-xxx"
    - "entity:stake_1"
前缀让调试时一眼看出类型,也避免不同类型 ID 撞名。

============================================================================
 数据存储用 dataclass 而非 dict（本次重构）
============================================================================
之前用 Dict[str, object] 存 entity 信息,字段全靠记忆+IDE 补全 dict key,容易拼错。
改用 EntityInfo dataclass:
    - IDE 自动补全字段名(entity.x 比 entity["x"] 直观)
    - 拼错字段名编译期就报错,不用等运行时
    - 类型标注让数据形状有明确文档
代价:广播完整快照时要用 dataclasses.asdict() 转 dict 给 message_bus(message_bus 不改)。
增量消息(PlayerMove 等)仍手写 dict,和之前一样——因为消息形状 ≠ 实体形状。

============================================================================
 架构位置
============================================================================
    WebSocket 收到 bytes
        ↓
    MessageBus.dispatch   (反序列化 + 路由)
        ↓
    handler (on_player_move 等)
        ↓
    GameRoom.apply_move(...)   ← 本文件：唯一改状态的地方
        ↓
    GameRoom 内部状态变更
        ↓
    handler 取 GameRoom.snapshot() 或直接转发，调 bus.send 广播

GameRoom 自身不做任何网络 I/O，也不知道 WebSocket 存在。
这种「状态层与传输层解耦」是服务器权威模型能长期维护的关键。
"""

import math
import enum
import logging
from dataclasses import dataclass, field, asdict
from typing import Dict, List, Optional

# 项目模块用 `import game.xxx as xxx` 形式(热更约束+包前缀规范)
import game.collision as collision
import game.entity_config as entity_config

logger = logging.getLogger(__name__)


# ============================================================================
# EntityInfo: 所有可交互物体的统一数据结构
# ============================================================================
# 为什么用 dataclass 而非 dict:
#   - 字段名拼写错误编译期就报错,不用等运行时崩
#   - IDE 自动补全字段名,改字段时找引用方便
#   - 类型标注本身就是文档,看类定义就知道 Entity 有哪些字段
# 为什么所有类型共用一个 EntityInfo 而非子类继承:
#   - 不同 entity_type 的字段差异小(player 多 player_name/moving,其他没有)
#   - 用扁平字段 + 默认值比继承简单,proto 也只能表达扁平结构
#   - 未来字段差异大了再考虑拆分,目前 YAGNI
@dataclass
class EntityInfo:
    """所有可交互物体(玩家/木桩/...)的统一数据结构"""
    entity_id: str                          # "player:uuid" | "entity:stake_1"
    entity_type: str                        # "player" | "stake" | ...
    x: float = 0.0                          # X坐标
    y: float = 0.0                          # Y坐标
    facing: float = 0.0                     # 朝向(弧度,0=右,逆时针正)。木桩永远 0
    state: str = "idle"                     # 动画状态:idle/run/attack/hurt/...
    radius: float = 24.0                    # 碰撞半径(用于攻击命中判定)
    # player 特有字段(其他类型不填,保持默认空值)
    player_name: str = ""                   # 玩家名称(只有 player 有)
    moving: bool = False                    # 是否正在移动(只有 player 有)


# ============================================================================
# 攻击配置数据类
# ============================================================================
# 时间单位:毫秒(ms),和 timer_mgr.py 一致
# 选毫秒不选秒:配置可读性(583 比 0.583 直观)+ 避免浮点书写误差 + 行业惯例
class AttackShapeType(enum.Enum):
    SECTOR = "sector"   # 扇形
    RECT = "rect"       # 矩形
    CIRCLE = "circle"   # 圆形
    RING = "ring"       # 环形


@dataclass
class ShapeParams:
    """形状参数基类,实际参数由子类决定"""
    pass


@dataclass
class SectorParams(ShapeParams):
    radius: float = 80.0                     # 扇形半径,单位像素
    angle: float = math.pi / 2 * (4 / 3)     # 扇形角度(±60°)


@dataclass
class AttackShape:
    """单个攻击形状(一次攻击可由多个形状组成,如双段斩)"""
    shape: AttackShapeType = AttackShapeType.SECTOR
    shape_params: Optional[ShapeParams] = None  # 具体参数,根据 shape 决定
    duration: int = 583  # 攻击持续时间(ms)
    hit_time: int = 83   # 判定帧时间(从发起算,ms)


@dataclass
class AttackConfig:
    """攻击配置:一个 atk_id 对应一组形状列表"""
    # 用 field(default_factory=list) 避免可变默认值共享陷阱
    shape_list: List[AttackShape] = field(default_factory=list)


# 攻击配置表:atk_id -> AttackConfig
# 当前硬编码在代码里,之后多了再考虑配表(读 json/csv)
ATTACK_CONFIG: Dict[int, AttackConfig] = {
    1001: AttackConfig(shape_list=[
        AttackShape(AttackShapeType.SECTOR, SectorParams())
    ]),  # 扇形一刀
    1002: AttackConfig(shape_list=[
        AttackShape(AttackShapeType.SECTOR, SectorParams()),
        AttackShape(AttackShapeType.SECTOR, SectorParams())
    ]),  # 扇形两刀
}


# ============================================================================
# GameRoom: 游戏房间状态机(服务端权威)
# ============================================================================
class GameRoom:
    """
    =========================================================================
     设计决策
    =========================================================================
    1. 内部用 Dict[entity_id, EntityInfo] 而不是 list：
         - O(1) 按 entity_id 查找/更新/删除，list 是 O(n)
         - 天然保证 entity_id 唯一（dict key 不可重复）
         - snapshot() 时再转成 list，匹配 proto 里 repeated EntityInfo 的形状

    2. 状态变更只通过本类方法（add_entity / apply_move / apply_facing 等）：
         - 不允许外部直接 room._entities[eid].x = ...
         - 所有状态变更都在这里被看到，未来加校验/日志/回放只需改一处
         - 方法内先查 entity_config 的能力,能拒绝就拒绝(如木桩不能 apply_move)

    3. snapshot() 返回 dataclass 列表的浅拷贝：
         - 返回新的 list,但内部 EntityInfo 对象是共享引用
         - 当前 EntityInfo 全是标量字段,共享引用也安全(调用方只能读不能改字段)
         - 如果未来加了可变嵌套字段,再改成 deepcopy
         - 调用方广播时用 dataclasses.asdict() 转 dict 给 message_bus

    =========================================================================
     刻意不做的事（防止过度设计）
    =========================================================================
    - 不做网络 I/O：不知道 WebSocket、不调用 bus.send，纯内存逻辑
    - 不做插值/平滑：那是客户端表现层的事
    - 不做持久化：重启即清空，后续要存档再加 load/save
    - 不做房间分区/多房间：当前只有一个全局房间，够用
    - 不做 tick 调度：是否定时广播由 handler/web_server 决定，GameRoom 只在被调用时算
    """

    def __init__(self):
        # 所有实体表:entity_id -> EntityInfo
        # 玩家/木桩/箱子/陷阱都在这一张表里,用 entity_type 区分行为能力
        # 用下划线前缀暗示「内部实现」,外部应通过方法访问
        # (Python 没有真正的私有,下划线只是约定)
        self._entities: Dict[str, EntityInfo] = {}

    # ------------------------------------------------------------------
    # 只读访问
    # ------------------------------------------------------------------

    def get_entity(self, entity_id: str) -> Optional[EntityInfo]:
        """
        获取单个实体信息(只读意图)

        为什么返回的是内部 dataclass 而非拷贝:
            读场景频繁(如 handler 里取 player_name 拼 ChatMessage),
            每次都拷贝开销大且无必要——只要调用方不改它即可。
            dataclass 是可变的,但约定:拿到 get_entity 结果后只读不改,
            要改状态请走 apply_move 等方法。
        """
        return self._entities.get(entity_id)

    def has_entity(self, entity_id: str) -> bool:
        """实体是否在房间内"""
        return entity_id in self._entities

    def snapshot(self) -> List[EntityInfo]:
        """
        生成当前完整状态的快照,用于广播 GameState

        返回值是 EntityInfo dataclass 列表,调用方(web_server)需要用
        dataclasses.asdict() 转成 dict 列表再传给 message_bus.broadcast。

        为什么返回 dataclass 列表而非 dict 列表:
            - 调用方可能想先看一眼数据(asdict 后就是 dict 了,看不出字段类型)
            - 让转换时机尽量靠后,中间环节都能享受类型信息
            - 如果调用方不广播而是做调试输出,dataclass 打印更清晰

        为什么返回新 list 而非 self._entities.values():
            - 避免 handler 拿到内部 dict_values 视图后,_entities 改动影响迭代
            - list() 拷贝一次,迭代期间安全
        """
        return list(self._entities.values())

    def entity_count(self) -> int:
        """当前房间内实体总数(调试/监控用)"""
        return len(self._entities)

    # ------------------------------------------------------------------
    # 状态变更:实体加入/离开
    # ------------------------------------------------------------------

    def add_entity(self, entity_id: str, entity_info: EntityInfo) -> EntityInfo:
        """
        实体加入房间(玩家上线/木桩初始化都用这个)

        为什么在这里强制设置 entity_id 而不是信任传入的 EntityInfo:
            entity_id 是服务端分配的(玩家=player:uuid, 木桩=entity:stake_1),
            调用方可能传进来时 entity_id 字段是空的或是占位值。
            在这里统一覆盖,保证「状态里的 entity_id 永远等于传入的 key」这条不变式。
            这就是收口的好处:不变式只在这里维护一次。

        Args:
            entity_id: 实体ID(带类型前缀,如 "player:uuid-xxx")
            entity_info: 实体初始数据

        Returns:
            实际存入房间的 EntityInfo(已确保 entity_id 字段正确)

        Raises:
            ValueError: entity_id 已存在(重复加入,通常是 bug,早暴露比晚暴露好)
        """
        if entity_id in self._entities:
            raise ValueError(f"实体 {entity_id} 已在房间内,不能重复加入")

        # 强制覆盖 entity_id,保证不变式
        entity_info.entity_id = entity_id
        self._entities[entity_id] = entity_info
        logger.info(f"实体加入房间: type={entity_info.entity_type} id={entity_id}")
        return entity_info

    def remove_entity(self, entity_id: str) -> Optional[EntityInfo]:
        """
        实体离开房间(玩家下线/木桩被破坏都用这个)

        Returns:
            被移除的 EntityInfo;若实体本来就不在房间,返回 None(幂等)

        为什么不存在时返回 None 而非报错:
            cleanup_player 在 finally 里被调用,可能因异常路径被触发多次。
            重复删除是合法的幂等行为,不应抛异常打断清理流程。
            这与 add_entity 的「重复加入报错」相反——
            加入重复是 bug,离开重复是容错,语义不同。
        """
        removed = self._entities.pop(entity_id, None)
        if removed is not None:
            logger.info(f"实体离开房间: type={removed.entity_type} id={entity_id}")
        return removed

    # ------------------------------------------------------------------
    # 状态变更:玩家行为(apply_xxx)
    # ------------------------------------------------------------------
    # 所有 apply_xxx 方法都先查 entity_config 的能力配置:
    #   - 能做才改状态,不能做返回 False(如木桩 apply_move 直接拒)
    #   - 这样把"能不能做"和"怎么做"分离,加新类型只改 entity_config
    # ------------------------------------------------------------------

    def apply_move(self, entity_id: str, x: float, y: float,
                   speed: float = 1.0, moving: bool = False) -> bool:
        """
        应用一次移动输入到状态

        =========================================================================
         能力校验
        =========================================================================
        先查 entity_type 能不能移动(can_move):
            - player: can_move=True,正常改状态
            - stake:  can_move=False,直接返回 False(木桩不能动)
        这让 apply_move 不用关心"谁能动谁不能动",逻辑统一。

        =========================================================================
         当前是「目标坐标直接落地」的简化版
        =========================================================================
        客户端说移到 (x,y),状态就直接是 (x,y)。
        真实游戏里移动是连续的,应该是:
            - 服务端按 tick 推进: new_pos = old_pos + velocity * dt
            - 或至少校验移动合法性: 目标点是否在地图内、是否穿墙、单次位移是否过大(防作弊)
        把 apply_move 收口到这里的好处:后续加任何逻辑只改这一个方法,
        handler 和客户端都不用动。

        =========================================================================
         speed 参数当前未使用,但保留
        =========================================================================
        speed 已存在于 proto 的 PlayerMove 里,客户端会发。
        当前忽略它(直接落地目标坐标),保留参数位是为了:
            1. handler 签名和 proto 字段一一对应,读代码就能看出"消息里有什么"
            2. 后续做连续移动模型时,speed 立刻可用,不用再改接口

        =========================================================================
         moving 参数:驱动动画状态 state
        =========================================================================
        moving=True → state="run";moving=False → state="idle"。
        这把"动画状态"收口到服务端权威:客户端发"我在动/我没在动",服务端定 state。

        Args:
            entity_id: 谁在移动
            x, y: 目标坐标
            speed: 移动速度(当前未使用,保留字段)
            moving: 是否正在移动(驱动 state 字段)

        Returns:
            True 表示状态已更新;False 表示实体不存在或不能移动
        """
        info = self._entities.get(entity_id)
        if info is None:
            # 实体不在房间:可能是未加入就发移动,或已离开。
            # 返回 False 让 handler 决定是否告警,而不是在这里抛异常——
            # 网络消息乱序是常态,不该让状态层处理容错逻辑。
            return False

        # 能力校验:不能移动的实体直接拒绝
        if not entity_config.get_capability(info.entity_type).can_move:
            logger.warning(f"实体 {entity_id} (type={info.entity_type}) 不能移动,apply_move 被拒绝")
            return False

        # 直接落地目标坐标(简化模型,见上方说明)
        info.x = x
        info.y = y
        # 注意:speed 当前不存入状态,因为 EntityInfo 里没有 speed 字段。
        # speed 是"移动事件"的属性,不是"实体状态"的属性——这个区分很重要:
        #   - 状态 = 持续存在的属性(位置、朝向、动画状态)
        #   - 事件 = 瞬时发生的动作(一次移动、一次攻击)
        info.moving = moving
        info.state = "run" if moving else "idle"

        logger.debug(f"实体 {entity_id} 移动到 ({x}, {y}) state={info.state}")
        return True

    def apply_facing(self, entity_id: str, facing: float) -> bool:
        """
        应用一次朝向输入到状态

        和 apply_move 平行,但只改 facing 不改坐标。
        朝向和移动是两个独立状态维度——玩家可以一边移动一边朝任意方向攻击,
        所以 facing 不应混在 apply_move 里(那会让朝向变成"移动的附属属性",语义错了)。

        Args:
            entity_id: 谁在转朝向
            facing: 朝向角度(弧度),0=右,逆时针正(Godot 标准)

        Returns:
            True 表示状态已更新;False 表示实体不存在或不能移动
            (不能移动的实体也不该转向,如木桩)
        """
        info = self._entities.get(entity_id)
        if info is None:
            return False

        # 能力校验:不能移动的实体也不该转向(木桩没有朝向概念)
        if not entity_config.get_capability(info.entity_type).can_move:
            logger.warning(f"实体 {entity_id} (type={info.entity_type}) 不能转向,apply_facing 被拒绝")
            return False

        # 弧度归一到 [0, 2*PI),避免数值无限增长
        # 不做范围校验(如限制角度范围),因为任意朝向都是合法的
        info.facing = facing % (2 * math.pi)

        logger.debug(f"实体 {entity_id} 朝向 {info.facing}")
        return True

    def apply_attack_start(self, entity_id: str, atk_id: int) -> bool:
        """
        应用一次攻击开始到状态(设 state="attacking")

        能力校验:can_attack=False 的实体(如木桩)不能发起攻击。

        Args:
            entity_id: 攻击者ID
            atk_id: 攻击ID(对应 ATTACK_CONFIG 的 key)

        Returns:
            True 表示状态已更新;False 表示实体不存在或不能攻击
        """
        info = self._entities.get(entity_id)
        if info is None:
            return False

        if not entity_config.get_capability(info.entity_type).can_attack:
            logger.warning(f"实体 {entity_id} (type={info.entity_type}) 不能攻击,apply_attack_start 被拒绝")
            return False

        # 这里不做任何判定逻辑(如攻击范围/碰撞检测),只做状态变更
        # 攻击命中判定在 get_attack_hits 方法,由 web_server 的 hit_cb 触发
        info.state = "attacking"
        logger.debug(f"实体 {entity_id} 发起攻击 atk_id={atk_id}")
        return True

    def apply_attack_end(self, entity_id: str, atk_id: int) -> bool:
        """
        应用一次攻击结束到状态(恢复 state="idle")

        能力校验:can_attack=False 的实体不应该有攻击结束(逻辑上不会发生,但防御性校验)。
        """
        info = self._entities.get(entity_id)
        if info is None:
            return False

        if not entity_config.get_capability(info.entity_type).can_attack:
            return False

        info.state = "idle"
        logger.debug(f"实体 {entity_id} 攻击结束 atk_id={atk_id}")
        return True

    def apply_hurt(self, target_id: str, atk_id: int) -> bool:
        """
        应用一次受击到状态(设 state="hurt")

        能力校验:can_be_hurt=False 的实体(如墙/水地)不会进入 hurt 状态。

        注意:本方法不区分受击者是玩家还是木桩——所有可被攻击的实体统一处理。
        这正是统一 Entity 模型的好处:不用 if-else 分流,逻辑统一。

        Args:
            target_id: 被命中者ID
            atk_id: 攻击ID(当前未使用,未来加伤害公式时用来查 ATTACK_CONFIG)

        Returns:
            True 表示状态已更新;False 表示实体不存在或不能被攻击
        """
        info = self._entities.get(target_id)
        if info is None:
            return False

        if not entity_config.get_capability(info.entity_type).can_be_hurt:
            logger.warning(f"实体 {target_id} (type={info.entity_type}) 不能被攻击,apply_hurt 被拒绝")
            return False

        info.state = "hurt"
        logger.debug(f"实体 {target_id} 受到攻击 atk_id={atk_id}")
        return True

    # ------------------------------------------------------------------
    # 攻击命中判定(读取状态 + 调 collision 纯函数,不改状态)
    # ------------------------------------------------------------------

    def get_attack_hits(self, atk_shape: "AttackShape", attacker_id: str) -> List[str]:
        """
        计算一次攻击形状的命中列表(纯读 + 计算,不改状态)。

        =========================================================================
         为什么这个方法在 GameRoom 里
        =========================================================================
        - 命中判定需要读 _entities 状态(攻击者位置/朝向 + 所有目标位置)
        - GameRoom 是唯一状态持有者,由它读状态最合适
        - 几何计算委托给 collision.py(纯函数),GameRoom 只做"取状态→调计算→收集结果"
        - web_server 的 hit_cb 只调本方法,不直接读 _entities,保持网络层/状态层解耦

        =========================================================================
         统一 Entity 模型的好处
        =========================================================================
        - 一张表遍历,不用区分 player/entity
        - 用 can_be_hurt 能力过滤,墙/水地等不可被攻击的实体自动跳过
        - 被命中者 ID 直接用 entity_id(带前缀),调用方不用分流处理

        =========================================================================
         为什么 direction 直接用 facing 弧度
        =========================================================================
        - EntityInfo.facing 是连续弧度(0=右,逆时针正,Godot 标准)
        - collision.Sector.direction 也是弧度(0=右,逆时针正)
        - 两者语义完全对齐,直接传即可,不需要量化到四方向
        - 量化到四方向是动画表现层的事,判定层必须用精确弧度

        Args:
            atk_shape: 攻击形状配置(从 ATTACK_CONFIG 取出的单个 AttackShape)
            attacker_id: 攻击者的 entity_id

        Returns:
            命中目标的 entity_id 列表(不含攻击者自己)
        """
        attacker = self._entities.get(attacker_id)
        if attacker is None:
            return []

        # 目前只实现了扇形判定,其它形状未来扩展
        if atk_shape.shape != AttackShapeType.SECTOR:
            logger.warning(f"未支持的攻击形状: {atk_shape.shape},跳过命中判定")
            return []

        # shape_params 类型是 ShapeParams 基类,扇形时实际是 SectorParams
        sector_params = atk_shape.shape_params
        if not isinstance(sector_params, SectorParams):
            logger.warning(f"扇形攻击的 shape_params 不是 SectorParams: {type(sector_params)}")
            return []

        # 构造攻击扇形:pos=攻击者位置, direction=攻击者朝向(弧度直接用)
        atk_sector = collision.Sector(
            pos=(attacker.x, attacker.y),
            radius=sector_params.radius,
            angle=sector_params.angle,
            direction=attacker.facing,
        )

        # 遍历所有实体,跳过自己,用能力过滤,做圆 vs 扇形相交判定
        hits: List[str] = []
        for target_id, target in self._entities.items():
            # 不打自己
            if target_id == attacker_id:
                continue
            # 能力过滤:不能被攻击的实体跳过(墙/水地等)
            if not entity_config.get_capability(target.entity_type).can_be_hurt:
                continue
            # 几何判定:用实体自己的 radius(支持不同体积)
            target_circle = collision.Circle(
                pos=(target.x, target.y),
                radius=target.radius,
            )
            if collision.intersect_circle_sector(target_circle, atk_sector):
                hits.append(target_id)

        return hits
