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
from typing import Dict, List, Optional, Tuple, Union

# 项目模块用 `import game.xxx as xxx` 形式(热更约束+包前缀规范)
import game.collision as collision
import game.entity_config as entity_config
import config.config_loader as config_loader

logger = logging.getLogger(__name__)


# ============================================================================
# HurtResult: apply_hurt 的返回值,告知调用方受击后的状态分支
# ============================================================================
class HurtResult(enum.Enum):
    """apply_hurt 返回值:区分"没死/死了/失败"三种状态,调用方据此决定后续流程"""
    FAILED = 0   # 实体不存在/不能被攻击/无战斗组件,调用方不应有任何后续动作
    HURT = 1     # 扣血但没死,调用方应启 HurtTimer(硬直)
    DEAD = 2     # 扣血后 hp<=0 且 can_die=True,调用方应启 DeadTimer(死亡延迟移除)


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
    # 注:碰撞形状不再存 EntityInfo,改由 entity_type 查 entity_config 决定
    # (形状是类型属性:所有玩家一样大,所有木桩一样大,没必要每个实例存一份)
    # player 特有字段(其他类型不填,保持默认空值)
    player_name: str = ""                   # 玩家名称(只有 player 有)
    moving: bool = False                    # 是否正在移动(只有 player 有)

@dataclass
class CombatComponent:
    entity_id: str                          # "player:uuid" | "entity:stake_1"
    cur_hp: int = 0
    max_hp: int = 0
    attack_power: int = 0
    defense: int = 0



# ============================================================================
# 攻击配置 / 形状数据类 / HURT_DURATION_MS 已移到 config/config_loader.py
# ============================================================================
# 改成 JSON 单数据源(shared_config/)后,相关 dataclass 和常量集中到 config_loader,
# 本文件只保留 EntityInfo(实体状态数据结构)和 GameRoom(状态持有者)。
# 访问攻击配置:config_loader.get_attack_config(atk_id)
# 访问 hurt 时长:config_loader.get_hurt_duration_ms()
# 访问实体能力+形状:entity_config.get_capability(entity_type)(内部调 config_loader)


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
        self._combats: Dict[str, CombatComponent] = {}
        import game.enemy_mgr as enemy_mgr
        self.enemy_mgr = enemy_mgr.EnemyMgr()

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

        # 自动为有战斗属性的类型创建 CombatComponent
        # (config 里 max_hp>0 的类型才需要战斗组件,纯装饰实体不创建)
        combat_stats = config_loader.get_combat_stats(entity_info.entity_type)
        if combat_stats.max_hp > 0:
            self.add_combat(entity_id, entity_info.entity_type)

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
            # 连带清理战斗组件(和 _entities 同步,避免遗留幽灵 combat)
            self._combats.pop(entity_id, None)
            # 清理敌人 AI 状态(如果是敌人;非敌人 on_enemy_removed 是 no-op,安全)
            self.enemy_mgr.on_enemy_removed(entity_id)
            logger.info(f"实体离开房间: type={removed.entity_type} id={entity_id}")
        return removed

    # ------------------------------------------------------------------
    # 状态变更:玩家行为(apply_xxx)
    # ------------------------------------------------------------------
    # 所有 apply_xxx 方法都先查 entity_config 的能力配置:
    #   - 能做才改状态,不能做返回 False(如木桩 apply_move 直接拒)
    #   - 这样把"能不能做"和"怎么做"分离,加新类型只改 entity_config
    # ------------------------------------------------------------------

    # 输入锁定状态集合:hurt(硬直)/ dead(死亡)/ attacking(攻击中)期间拒绝所有玩家输入
    # 抽成常量方便统一修改,避免散落在各 apply_xxx 方法里漏改
    #
    # attacking 必须锁:客户端移动中点击攻击时,攻击开始前已发出的残留 PlayerMove
    # 可能晚于 AttackStart 到达/被 tick 处理。若 attacking 状态仍执行 apply_move,
    # 会把 state 从 "attacking" 覆盖回 "run" 并广播,导致客户端攻击动画被移动动画吞掉。
    # 锁住后残留 PlayerMove 的 apply_move 返回 False,不会覆盖攻击状态、也不会广播。
    _INPUT_LOCKED_STATES = frozenset({"hurt", "dead", "attacking"})

    def _is_input_locked(self, info: EntityInfo) -> bool:
        """
        判断实体当前是否处于输入锁定状态(hurt 硬直 / dead 死亡)

        所有 apply_xxx 输入方法(move/facing/attack_start)统一调本方法做拒绝判定,
        避免每个方法各写一个 if state=="hurt" 然后漏掉 dead 之类的新状态。
        新增锁定状态时只改 _INPUT_LOCKED_STATES,不用改各 apply_xxx 方法。
        """
        return info.state in self._INPUT_LOCKED_STATES

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
        speed 已存在于 proto 的 PlayerMove 里,客户端会发(值取自 entity_config.json
        的 player.speed)。当前 apply_move 忽略它(直接落地目标坐标),保留参数位是为了:
            1. handler 签名和 proto 字段一一对应,读代码就能看出"消息里有什么"
            2. 后续做连续移动模型时,speed 立刻可用,不用再改接口
        注意:speed 作为「类型属性」已在 entity_config.json 定义并由 config_loader 解析,
        EnemyMgr 推进敌人位移走 config_loader.get_speed(entity_type),不读这里的参数。
        这里的 speed 参数是「移动事件属性」(客户端这一次移动的瞬时速度),两者语义不同。

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

        # 输入锁定校验:hurt(硬直)/ dead(死亡)期间拒绝移动输入
        # 服务端是唯一状态权威,锁定期间客户端发的 PlayerMove 不应改状态。
        # 这里拒绝后,web_server._process_tick 检查 apply_xxx 返回值,不会广播——
        # 避免出现"客户端收到 X 在移动广播,但 X 实际还在 hurt/dead"的状态矛盾。
        if self._is_input_locked(info):
            logger.debug(f"实体 {entity_id} 处于 {info.state} 锁定,apply_move 被拒绝")
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

        # 输入锁定校验:hurt/dead 期间拒绝朝向输入(锁定期间朝向也锁)
        if self._is_input_locked(info):
            logger.debug(f"实体 {entity_id} 处于 {info.state} 锁定,apply_facing 被拒绝")
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

        # 输入锁定校验:hurt/dead 期间不能发起攻击
        # (锁定被打断的不只是移动,新攻击也要拒绝,否则会出现"边硬直/死亡边攻击"的诡异状态)
        if self._is_input_locked(info):
            logger.debug(f"实体 {entity_id} 处于 {info.state} 锁定,apply_attack_start 被拒绝")
            return False

        # 攻击中锁定:同一实体同时只允许一个攻击在进行。
        # 若不加此检查,客户端在旧攻击未结束(duration 内)再发 AttackStart,
        # 服务端会再启动一个 AttackTimer,两个判定帧各算一次伤害,
        # 表现为"一次攻击造成两次伤害"(如 22 被打两次)。
        if info.state == "attacking":
            logger.debug(f"实体 {entity_id} 已在攻击中,重复 AttackStart 被拒绝")
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

    def apply_hurt(self, target_id: str, atk_id: int, atk_shape_idx: int, damage: int, attacker_id: str) -> HurtResult:
        """
        应用一次受击到状态:扣血 + 设 state(hurt 或 dead)

        能力校验:can_be_hurt=False 的实体(如墙/水地)不会进入 hurt 状态。

        注意:本方法不区分受击者是玩家还是木桩——所有可被攻击的实体统一处理。
        这正是统一 Entity 模型的好处:不用 if-else 分流,逻辑统一。

        死亡判定:cur_hp<=0 且 can_die=True 时走死亡分支(设 state="dead",返回 DEAD);
        否则设 state="hurt" 返回 HURT(调用方启 hurt timer)。
        玩家 can_die=False,即使 hp 扣到 0 也走 HURT 分支(死亡流程暂不实现)。

        Args:
            target_id: 被命中者ID
            atk_id: 攻击ID(当前未使用,保留给未来扩展如属性攻击)
            atk_shape_idx: 攻击形状索引(当前未使用,保留给未来扩展)
            damage: 伤害值(已由调用方算好,本方法只负责扣)
            attacker_id: 攻击者ID(当前未使用,保留给未来扩展如仇恨表)

        Returns:
            HurtResult.DEAD: 被命中者死了(调用方应启 DeadTimer,不启 HurtTimer)
            HurtResult.HURT: 没死(调用方应启 HurtTimer)
            HurtResult.FAILED: 实体不存在/不能被攻击/无战斗组件(调用方不应有后续动作)
        """
        info = self._entities.get(target_id)
        if info is None:
            return HurtResult.FAILED

        cap = entity_config.get_capability(info.entity_type)
        if not cap.can_be_hurt:
            logger.warning(f"实体 {target_id} (type={info.entity_type}) 不能被攻击,apply_hurt 被拒绝")
            return HurtResult.FAILED

        combat = self._combats.get(target_id)
        if combat is None:
            # 没有战斗组件(如纯装饰实体),无法扣血,按失败处理
            return HurtResult.FAILED

        combat.cur_hp -= damage

        # 死亡判定:hp<=0 且 can_die=True 才走死亡分支
        # 玩家 can_die=False(hp 扣到 0 也走 hurt,死亡流程暂不实现)
        # 木桩 can_die=False(且每 tick 回满血,实际不会到 0)
        if combat.cur_hp <= 0 and cap.can_die:
            combat.cur_hp = 0  # 钳到 0,避免显示负血量
            info.state = "dead"
            logger.info(f"实体 {target_id} 死亡(攻击者 {attacker_id}, atk_id={atk_id})")
            return HurtResult.DEAD

        # 钳到 0 避免负血量(can_die=False 但 hp 扣到 0 的情况,如玩家)
        if combat.cur_hp < 0:
            combat.cur_hp = 0

        # 没死:设 state="hurt",调用方启 hurt timer
        info.state = "hurt"
        logger.debug(f"实体 {target_id} 受击扣血 -{damage} → {combat.cur_hp}/{combat.max_hp}")
        return HurtResult.HURT

    def apply_dead(self, target_id: str, atk_id: int) -> bool:
        """
        应用死亡状态到实体(设 state="dead")

        本方法由 apply_hurt 内部死亡分支调用,也可由外部(如 Boss 机制)直接调用。
        能力校验:can_die=False 的实体不能进入死亡状态。

        注意:本方法只设状态,不做 remove_entity。
        实体移除由 DeadTimer 到期后调 remove_entity 完成——
        这样客户端有时间播死亡动画(服务端"立即判定死亡"但"延迟移除实体")。

        Args:
            target_id: 死亡的实体ID
            atk_id: 致死的攻击ID(当前未使用,保留给未来扩展如击杀日志)

        Returns:
            True 表示状态已更新;False 表示实体不存在或不能死
        """
        info = self._entities.get(target_id)
        if info is None:
            return False

        if not entity_config.get_capability(info.entity_type).can_die:
            logger.warning(f"实体 {target_id} (type={info.entity_type}) 不能死亡,apply_dead 被拒绝")
            return False

        info.state = "dead"
        logger.info(f"实体 {target_id} 进入死亡状态 atk_id={atk_id}")
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
            atk_shape: 攻击形状配置(从 config_loader.get_attack_config 取出的单个 AttackShape)
            attacker_id: 攻击者的 entity_id

        Returns:
            命中目标的 entity_id 列表(不含攻击者自己)
        """
        attacker = self._entities.get(attacker_id)
        if attacker is None:
            return []

        # 目前只实现了扇形判定,其它形状未来扩展
        if atk_shape.shape != config_loader.ShapeType.SECTOR:
            logger.warning(f"未支持的攻击形状: {atk_shape.shape},跳过命中判定")
            return []

        # shape_params 类型是 ShapeParams 基类,扇形时实际是 SectorParams
        sector_params = atk_shape.shape_params
        if not isinstance(sector_params, config_loader.SectorParams):
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
            # 同时取出 body_shape/body_params 用于构造碰撞形状
            target_cap = entity_config.get_capability(target.entity_type)
            if not target_cap.can_be_hurt:
                continue
            # 死亡过滤:已经 dead 的实体不可再被攻击(避免鞭尸)
            # 这和 can_be_hurt 正交:can_be_hurt 是能力层(能不能被打),
            # state=="dead" 是状态层(当前还能不能被打)
            if target.state == "dead":
                continue
            # 碰撞掩码过滤:攻击者的攻击掩码 & 目标的碰撞掩码 == 0 时跳过
            if (atk_shape.hit_mask & target_cap.hit_layer) == 0:
                continue
            # 几何判定:用实体类型的碰撞形状(从 entity_config 查,而非 EntityInfo.radius)
            # 目前实体碰撞只支持圆形,其他形状未来扩展
            if target_cap.body_shape != config_loader.ShapeType.CIRCLE:
                logger.warning(f"实体 {target_id} 的 body_shape={target_cap.body_shape} 暂不支持,跳过")
                continue
            if not isinstance(target_cap.body_params, config_loader.CircleParams):
                logger.warning(f"实体 {target_id} 的 body_params 类型错误: {type(target_cap.body_params)}")
                continue
            target_circle = collision.Circle(
                pos=(target.x, target.y),
                radius=target_cap.body_params.radius,
            )
            if collision.intersect_circle_sector(target_circle, atk_sector):
                hits.append(target_id)

        return hits

    def apply_hurt_end(self, entity_id: str):
        """
        应用实体的伤害结束状态,将实体状态重置为正常
        """
        info = self._entities.get(entity_id)
        if info is None:
            return

        info.state = "idle"
        logger.debug(f"实体 {entity_id} 伤害结束")

    def add_combat(self, entity_id, entity_type):
        # — 从 config_loader.get_combat_stats 拷基础值初始化
        combat_stats = config_loader.get_combat_stats(entity_type)
        combat = CombatComponent(
            entity_id=entity_id,
            cur_hp=combat_stats.max_hp,
            max_hp=combat_stats.max_hp,
            attack_power=combat_stats.attack_power,
            defense=combat_stats.defense
        )
        self._combats[entity_id] = combat
        return combat

    def remove_combat(self, entity_id):
        # 幂等:不存在时不报错(和 remove_entity 一致的容错策略)
        self._combats.pop(entity_id, None)

    def get_combat(self, entity_id) -> Optional[CombatComponent]:
        return self._combats.get(entity_id)

    def snapshot_combats(self) -> List[CombatComponent]:
        # StatsInit 用,返回 list(和 snapshot() 对称,调用方用 asdict 转 dict)
        return list(self._combats.values())

    def apply_stat_boost(self, entity_id, max_hp_delta, atk_delta, def_delta):
        # 强化用(预留,阶段 1 可不实现)
        # 后续实现:改 combat 实例字段 + 广播 StatsChanged
        pass

    def is_dead(self, entity_id) -> bool:
        # state=="dead" 的便捷查询(state 在 EntityInfo,不在 CombatComponent)
        info = self._entities.get(entity_id)
        if info is None:
            return False
        return info.state == "dead"

    def get_attack_damage(self, attacker_id, atk_id, atk_shape_idx, hurt_id) -> int:
        """
        计算伤害值(服务器权威,客户端不算)

        公式:
            raw = attacker.attack_power * atk_shape.damage_multiplier
            reduction = target.defense / (target.defense + K)   # 减伤比例 0~1,K=100
            damage = max(1, int(raw * (1 - reduction)))

        减伤系数 K=100:defense=5 时减伤约 4.8%,defense=50 时减伤 33%
        下限 max(1, ...):保证防御再高也至少扣 1 血,避免无敌
        """
        atk_combat = self._combats.get(attacker_id)
        def_combat = self._combats.get(hurt_id)
        if atk_combat is None or def_combat is None:
            return 0
        atk_config = config_loader.get_attack_config(atk_id)
        if atk_config is None or atk_shape_idx < 0 or atk_shape_idx >= len(atk_config.shape_list):
            return 0
        atk_shape = atk_config.shape_list[atk_shape_idx]
        # damage_multiplier 字段可能未配置,默认 1.0
        multiplier = getattr(atk_shape, "damage_multiplier", 1.0)
        raw = atk_combat.attack_power * multiplier
        # 减伤公式:防御越高减伤越多,但有下限保证至少扣 1
        K = 100
        reduction = def_combat.defense / (def_combat.defense + K)
        return max(1, int(raw * (1 - reduction)))

    def get_stakes(self) -> List[EntityInfo]:
        """
        获取所有木桩实体的 EntityInfo 列表
        """
        return [entity for entity in self._entities.values() if entity.entity_type == "stake"]

    def create_enemy(self, entity_type: str, pos: Tuple[float, float]) -> EntityInfo:
        """
        创建敌人实体的便捷方法(语法糖)

        做三件事:
            1. 分配 entity_id(格式 "enemy:{type}_{序号}",序号按该类型现有数量推算)
            2. 构造 EntityInfo 并设好位置,调 add_entity 入房间
               (add_entity 内部会按 entity_type 自动建 CombatComponent)
            3. 调 EnemyMgr.on_enemy_created 挂上 AI 状态(为寻路预留)

        Args:
            entity_type: 敌人类型(需已在 entity_config.json 配置,如 "enemy_slime")
            pos: 出生坐标 (x, y)

        Returns:
            入房间后的 EntityInfo(entity_id 已确定)

        为什么位置在 add_entity 之前设好:
            add_entity 内部将来若要广播快照/触发 on_join 回调,位置必须是正确的。
            先 add 再设位置会让"加入瞬间"的位置是 (0,0),埋坑。
        """
        # 序号:统计该类型当前已有数量 +1 作为序号
        # 不用单独维护计数器:计数器在敌人增删后会错位,用现有数量推算天然正确
        count = sum(1 for e in self._entities.values() if e.entity_type == entity_type)
        entity_id = f"enemy:{entity_type}_{count + 1}"

        enemy = EntityInfo(
            entity_id=entity_id,    # add_entity 会再强制覆盖一次,这里只是占位
            entity_type=entity_type,
            x=pos[0],
            y=pos[1],
            state="idle",
        )
        self.add_entity(entity_id, enemy)               # 共有状态 + 战斗组件
        self.enemy_mgr.on_enemy_created(entity_id, entity_type)  # AI 状态
        return enemy
