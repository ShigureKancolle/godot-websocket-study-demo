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
            room._enemy_mgr.change_state("chase", self.target_entity_id)
       导致状态逻辑双端各写一遍——这正是我们最想避免的重复
    3. 状态形状（玩家字典里有哪些字段）被 handler 隐式约定，proto 一改两边漏改

解决思路：把「状态长什么样、怎么变」全部收口到 GameRoom 这一个类。
    handler 只做三件事：从消息里取参数 → 调 GameRoom 方法 → 把结果发出去。
    handler 不再直接读写 _entities。

这样客户端的对应物（ClientStateMirror）就只能是「只读镜像」——
    它没有 apply_move_dir 可抄，因为 apply_move_dir 根本不存在于客户端。
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
    GameRoom.apply_move_dir(...)   ← 本文件：唯一改状态的地方
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
from typing import Callable, Dict, List, Optional, Tuple, Union

# 项目模块用 `import game.xxx as xxx` 形式(热更约束+包前缀规范)
import game.collision as collision
import game.entity_config as entity_config
import config.config_loader as config_loader
import typing
if typing.TYPE_CHECKING:
    import game.enemy_mgr as enemy_mgr
    from config.config_loader import AttackShape

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
    ai_state: str = "idle"                  # AI 状态:patrol/chase/attack/look_around(只有敌人填,玩家/木桩留空)
    # 注:ai_state 和 state 是两个独立维度——state 是动画状态(所有实体都有),
    # ai_state 是 AI 决策状态(只有敌人有,由 EnemyAIMachine 持有并同步到 EntityInfo,
    # 客户端据此切换视锥形态 normal/chase)。proto EntityInfo 必须同步加 ai_state 字段
    # (GameState 用 asdict 转 dict 后 ParseDict,未知字段会报错,见 KnockbackState 注释)。
    # 注:碰撞形状不再存 EntityInfo,改由 entity_type 查 entity_config 决定
    # (形状是类型属性:所有玩家一样大,所有木桩一样大,没必要每个实例存一份)
    # player 特有字段(其他类型不填,保持默认空值)
    player_name: str = ""                   # 玩家名称(只有 player 有)
    account_id: str = ""                    # 账号ID(客户端本地存档生成,跨会话稳定;只有 player 有)
    moving: bool = False                    # 是否正在移动(玩家+敌人都用)
    # 当前移动方向(归一化),服务端记住方向后每 tick 持续推进位移
    # 旧模型:apply_move_dir 收到输入才推进一次,网络丢 tick 导致误差累积 → 拉回
    # 新模型:apply_move_dir 只记方向,tick_movement 每 tick 持续推进 → 无误差累积
    move_dir_x: float = 0.0                 # 移动方向 X(归一化,-1~1)
    move_dir_y: float = 0.0                 # 移动方向 Y(归一化,-1~1)

@dataclass
class CombatComponent:
    entity_id: str                          # "player:uuid" | "entity:stake_1"
    cur_hp: int = 0
    max_hp: int = 0
    attack_power: int = 0
    defense: int = 0
    look_around_fact_speed: float = 0.5  # 朝向转转转速(弧度/秒)


@dataclass
class KnockbackState:
    """
    单个实体的击退状态(挂在 GameRoom._knockbacks 上,不进 EntityInfo)

    字段语义:
        vx/vy:  击退速度(像素/秒),方向从攻击者中心指向被击者(向外推)
        time:   剩余击退时间(秒)。>0 表示正在被击退,由 tick_movement 每 tick 推进位移

    为什么单独一张表而不进 EntityInfo:
        和 _combats 同理——击退是「服务端瞬态战斗状态」,客户端不需要知道。
        塞进 EntityInfo 会污染 proto 快照广播:GameState 用 asdict() 转 dict,
        多出的字段会让 ParseDict 因未知字段报错(见 web_server 的 GameState 广播)。
    """
    vx: float = 0.0
    vy: float = 0.0
    time: float = 0.0



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

    2. 状态变更只通过本类方法（add_entity / apply_move_dir / apply_facing 等）：
         - 不允许外部直接 room._entities[eid].x = ...
         - 所有状态变更都在这里被看到，未来加校验/日志/回放只需改一处
         - 方法内先查 entity_config 的能力,能拒绝就拒绝(如木桩不能 apply_move_dir)

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

    # 上一 tick 结束时「仍在移动 / 正在被推着动」的实体集合(服务端瞬态,客户端不需要)。
    # 用途:tick_movement 里检测「移动 → 停止」的状态迁移——AI 主动停下时
    # apply_move_dir(False) 只改 moving/state 不改位置,进不了 moved_ids;
    # 若不单独记录,客户端永远收不到"敌人停下了"的 PlayerMove 广播,会一直预测漂移。
    # 和 _knockbacks 同理独立成表,不进 EntityInfo(避免污染 proto 快照)。
    #
    # 为什么要有类属性默认值(而不是只在 __init__ 初始化):
    #   本项目热更(importlib.reload)只重载模块定义,不会重跑已实例化 GameRoom
    #   的 __init__。若只在 __init__ 里建 _was_moving,热更后旧实例在 tick_movement
    #   读 self._was_moving 会 AttributeError,每 tick 崩一次。
    #   类属性兜底让旧实例也能读到空 set;tick_movement 每 tick 用
    #   self._was_moving = still_moving 重新绑定成实例属性(覆盖类属性),
    #   所以类默认值不会被跨实例共享污染。
    _was_moving: set[str] = set()

    def __init__(self):
        # 所有实体表:entity_id -> EntityInfo
        # 玩家/木桩/箱子/陷阱都在这一张表里,用 entity_type 区分行为能力
        # 用下划线前缀暗示「内部实现」,外部应通过方法访问
        # (Python 没有真正的私有,下划线只是约定)
        self._entities: Dict[str, EntityInfo] = {}
        self._combats: Dict[str, CombatComponent] = {}
        # 击退状态表:entity_id -> KnockbackState(服务端瞬态,客户端不需要)
        # 和 _combats 一样独立成表,不进 EntityInfo(避免污染 proto 快照广播)
        self._knockbacks: Dict[str, KnockbackState] = {}
        # 重新赋一个空 set,覆盖类属性默认值——保证每个实例独立,不共享同一个 set
        # (类属性默认值只作为热更旧实例的兜底,见类属性上的注释)
        self._was_moving: set[str] = set()
        import game.enemy_mgr as enemy_mgr
        self._enemy_mgr = enemy_mgr.EnemyMgr()

        # 攻击发动钩子:由 GameServer 在初始化时通过 set_attack_trigger 注册。
        # 为什么需要钩子(而不让 AI 直接调 GameServer):
        #   apply_attack_start 只做状态变更(设 state="attacking"),真正的攻击发动
        #   流程(广播 AttackStart + 注册判定帧定时器 + 命中扣血 + 广播 AttackEnd)
        #   在网络层 GameServer 里。敌人 AI 只持有 room,够不着 GameServer。
        #   所以 GameServer 把"完整攻击流程"作为回调注册进来,玩家和敌人统一调
        #   room.trigger_attack(),调用方无需关心是玩家还是敌人。
        self._attack_trigger: Optional[Callable[[str, int], bool]] = None

        # 实体创建钩子:由 GameServer 在初始化时通过 set_entity_spawn_hook 注册。
        # 为什么需要钩子(而不让 GameRoom 直接广播):
        #   GameRoom 是纯状态层,不碰网络。GM/控制台调 room.create_enemy 后,
        #   新敌人已入 _entities,但客户端不知道——需要网络层广播新实体。
        #   和 _attack_trigger 同理:GameServer 把"广播新实体"作为回调注册进来,
        #   room.create_enemy 对调用方透明,GM 不用关心广播细节。
        self._entity_spawn_hook: Optional[Callable[[EntityInfo], None]] = None

        # A* 寻路器:由 GameServer 在初始化时通过 set_pathfinder 注入。
        # 为什么不放 GameRoom 内部 new:GameRoom 不知道 map_seed(seed 在
        # GameServer 上,通过 MapInfo 下发给客户端)。注入而非自建,保持
        # GameRoom「纯状态层,不依赖外部配置来源」的边界。
        # 敌人 AI(ChaseState)通过 room.get_pathfinder() 取用,避免每次寻路
        # 都重新构造 ChunkGenerator(每次构造 = 重新算 seed 哈希,浪费)。
        self._pathfinder = None

        # 穿墙白名单:集合内的 entity_type 在 tick_movement 推进时跳过地形阻挡。
        # 默认空集 = 所有人都受阻挡(符合「玩家+敌人都不穿墙」的常规预期)。
        # 为什么用 set 而非 dict:只需要「在/不在」判定,不需要附带数据。
        # 为什么按 entity_type 而非 entity_id:GM 想开的是「整类」权限(调试用),
        # 按实例开太碎;按类型开一行就能让所有玩家/敌人穿墙。
        # 为什么不进 entity_config.json:那是「类型固有能力」,穿墙是「运行时调试权限」,
        # 语义不同;放 GameRoom 上随用随开,不污染配置单数据源。
        self._wallhack_types: set[str] = set()
        
    # region 只读访问
    # ------------------------------------------------------------------

    def get_entity(self, entity_id: str) -> Optional[EntityInfo]:
        """
        获取单个实体信息(只读意图)

        为什么返回的是内部 dataclass 而非拷贝:
            读场景频繁(如 handler 里取 player_name 拼 ChatMessage),
            每次都拷贝开销大且无必要——只要调用方不改它即可。
            dataclass 是可变的,但约定:拿到 get_entity 结果后只读不改,
            要改状态请走 apply_move_dir 等方法。
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

    def get_stakes(self) -> List[EntityInfo]:
        """
        获取所有木桩实体的 EntityInfo 列表
        """
        return [entity for entity in self._entities.values() if entity.entity_type == "stake"]

    def get_enemy_manager(self) -> "enemy_mgr.EnemyMgr":
        return self._enemy_mgr

    def get_combat(self, entity_id) -> Optional[CombatComponent]:
        return self._combats.get(entity_id)

    def snapshot_combats(self) -> List[CombatComponent]:
        # StatsInit 用,返回 list(和 snapshot() 对称,调用方用 asdict 转 dict)
        return list(self._combats.values())

    # endregion

    # region 状态变更:实体加入/离开
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
            # 连带清理击退状态(和 _entities 同步,避免遗留幽灵击退)
            self._knockbacks.pop(entity_id, None)
            # 清理敌人 AI 状态(如果是敌人;非敌人 on_enemy_removed 是 no-op,安全)
            self._enemy_mgr.on_enemy_removed(entity_id)
            logger.info(f"实体离开房间: type={removed.entity_type} id={entity_id}")
        return removed

    # endregion

    # region 状态变更:玩家行为(apply_xxx)
    # ------------------------------------------------------------------
    # 所有 apply_xxx 方法都先查 entity_config 的能力配置:
    #   - 能做才改状态,不能做返回 False(如木桩 apply_move_dir 直接拒)
    #   - 这样把"能不能做"和"怎么做"分离,加新类型只改 entity_config
    # ------------------------------------------------------------------

    # 输入锁定状态集合:hurt(硬直)/ dead(死亡)/ attacking(攻击中)期间拒绝所有玩家输入
    # 抽成常量方便统一修改,避免散落在各 apply_xxx 方法里漏改
    #
    # attacking 必须锁:客户端移动中点击攻击时,攻击开始前已发出的残留 PlayerMove
    # 可能晚于 AttackStart 到达/被 tick 处理。若 attacking 状态仍执行 apply_move_dir,
    # 会把 state 从 "attacking" 覆盖回 "run" 并广播,导致客户端攻击动画被移动动画吞掉。
    # 锁住后残留 PlayerMove 的 apply_move_dir 返回 False,不会覆盖攻击状态、也不会广播。
    _INPUT_LOCKED_STATES = frozenset({"hurt", "dead", "attacking"})

    def _is_input_locked(self, info: EntityInfo) -> bool:
        """
        判断实体当前是否处于输入锁定状态(hurt 硬直 / dead 死亡)

        所有 apply_xxx 输入方法(move/facing/attack_start)统一调本方法做拒绝判定,
        避免每个方法各写一个 if state=="hurt" 然后漏掉 dead 之类的新状态。
        新增锁定状态时只改 _INPUT_LOCKED_STATES,不用改各 apply_xxx 方法。
        """
        return info.state in self._INPUT_LOCKED_STATES

    def apply_move_dir(self, entity_id: str, dir_x: float, dir_y: float,
                       moving: bool, dt: float) -> bool:
        """
        记住移动方向(不推进位移!)——持续推进由 tick_movement 统一做

        =========================================================================
         移动模型:记住方向 + 每 tick 持续推进
        =========================================================================
        客户端发"改方向"指令(低频),服务端 apply_move_dir 只记住方向到
        EntityInfo.move_dir_x/y,不推进位移。tick_movement 每 tick 对所有
        moving=True 的实体统一按 dir * speed * dt 推进位移。
        这样服务端不依赖客户端输入是否到达——即使某个 tick 没收到输入,
        服务端也会按记住的方向继续推进,无累积误差,无 snap 拉回。

        =========================================================================
         能力校验 / 锁定校验
        =========================================================================
        can_move=False 拒绝(木桩),hurt/attacking/dead 锁定拒绝。

        =========================================================================
         方向归一化
        =========================================================================
        客户端发的 dir_x/dir_y 理论上已归一化(Input.get_vector),这里防御性再归一化一次。
        moving=False 时清零方向(停止移动)。

        Args:
            entity_id: 谁在移动
            dir_x, dir_y: 移动方向向量(理论归一化,内部会再归一化一次防作弊)
            moving: 是否正在移动
            dt: 已废弃(保留签名兼容,持续推进由 tick_movement 用实测 dt 做)

        Returns:
            True 表示方向/状态已更新;False 表示实体不存在/不能移动/锁定中
        """
        info = self._entities.get(entity_id)
        if info is None:
            return False

        if not entity_config.get_capability(info.entity_type).can_move:
            logger.warning(f"实体 {entity_id} (type={info.entity_type}) 不能移动,apply_move_dir 被拒绝")
            return False

        if self._is_input_locked(info):
            logger.debug(f"实体 {entity_id} 处于 {info.state} 锁定,apply_move_dir 被拒绝")
            return False

        info.moving = moving
        info.state = "run" if moving else "idle"

        if moving:
            # 防御性归一化:存归一化方向供 tick_movement 持续推进用
            length_sq = dir_x * dir_x + dir_y * dir_y
            if length_sq > 0.0001:
                length = length_sq ** 0.5
                info.move_dir_x = dir_x / length
                info.move_dir_y = dir_y / length
            else:
                # 方向为零向量但 moving=True:不合理,当作停止处理
                info.moving = False
                info.state = "idle"
                info.move_dir_x = 0.0
                info.move_dir_y = 0.0
        else:
            # 停止移动:清零方向
            info.move_dir_x = 0.0
            info.move_dir_y = 0.0

        return True

    def tick_movement(self, dt: float) -> list:
        """
        每 tick 持续推进所有 moving=True 的实体位移(服务端权威移动核心)

        =========================================================================
         为什么需要这个方法
        =========================================================================
        旧模型(apply_move_dir 里推进)的问题:
            - 服务端只在收到客户端输入的 tick 才推进位移
            - 网络抖动/丢包导致某些 tick 没收到输入 → 不推进
            - 客户端每帧都在预测推进 → 误差累积 → 超过阈值 snap 拉回
        新模型(apply_move_dir 只记方向 + tick_movement 持续推进):
            - 客户端发"改方向"(低频),服务端记住方向
            - 服务端每 tick 都按记住的方向推进所有 moving=True 的实体
            - 客户端每帧也按同方向预测推进
            - 两端用同一个 speed 和接近的 dt,位移量一致,无累积误差

        =========================================================================
         和敌人 AI 的关系
        =========================================================================
        敌人 AI(EnemyMgr.update)每 tick 调 apply_move_dir 改方向,
        tick_movement 统一推进所有实体(含玩家和敌人),逻辑收口在状态层。

        =========================================================================
         返回值为什么包含「停止迁移」的实体
        =========================================================================
        返回列表除了「本 tick 位移变化的实体」,还包含「本 tick 从移动→停止」的
        实体(上一 tick 在移动、本 tick moving 变 False)。原因:
            - AI 主动停下(PatrolState/AttackState 调 apply_move_dir(False))
              只改 moving/state,不改位置,本 tick 不产生位移
            - 若不广播,客户端收不到任何 PlayerMove,会一直按旧方向预测 → 漂移
            - 把这些实体放进返回值,web_server 就广播一条 moving=False 的
              PlayerMove,客户端据此切回 idle / 停止预测
        玩家停止不会重复广播:web_server 用 set 收集(moved_entities),
        玩家停止已在处理 pending 输入时入 set,天然去重。

        Args:
            dt: 时间步长(秒),由 GameServer 传实测 tick 间隔(time.monotonic 差值,
                已钳制)。必须用实测值而非固定 TICK_INTERVAL:真实 tick 间隔受系统
                定时粒度影响会漂移(Windows 默认粒度下 33ms 请求实际约 47ms),
                固定 dt 积分会让移速系统性偏慢,客户端预测对账累积超阈值 → 周期性回拉

        Returns:
            本 tick 需要广播 PlayerMove 的 entity_id 列表
            (位移变化的 + 从移动→停止迁移的,供 web_server 收集广播用)
        """
        moved_ids = []
        # 本 tick 结束时「仍在移动 / 正在被推着动」的实体集合,
        # 存为 _was_moving 作为下一 tick 检测"停止迁移"(③)的基准。
        still_moving: set[str] = set()

        # ① 击退推进:不受输入锁定(hurt/attacking/dead)影响——硬直期间也要被推走
        # 击退是服务端权威位移(被攻击时由 apply_knockback 设定),和"自己按方向走"
        # 是两回事,所以和下方普通移动互斥(被击退的实体不叠加普通移动)。
        # 时长 = hurt 硬直时长,所以"硬直结束 = 击退结束",恢复时正好停在被推出位置。
        # 地形阻挡:击退也受地形约束(被推到墙边就沿墙滑,不穿墙)。分轴尝试:
        # 先试 X 轴,再试 Y 轴,任一可走就推进该轴 → 自然贴墙滑行,不会原地卡死。
        for entity_id in list(self._knockbacks.keys()):
            kb = self._knockbacks[entity_id]
            if kb.time <= 0:
                self._knockbacks.pop(entity_id, None)  # 击退时间耗尽,清理
                continue
            info = self._entities.get(entity_id)
            if info is None:
                self._knockbacks.pop(entity_id, None)  # 实体已移除(死亡/断连),清理
                continue
            step_x = kb.vx * dt
            step_y = kb.vy * dt
            # 分轴尝试:先 X 后 Y。某轴被挡就只推另一轴 → 沿墙滑行。
            # ★ 击退只查地形(_is_blocked_by_terrain),不查实体间碰撞。
            # 原因:击退是被攻击的硬直位移,必须强制发生(被打飞)。重叠时被击退者要推开
            # 攻击者,若查实体碰撞,新位置还在攻击者 body 圆内 → 被挡 → 推不出去 → 卡死。
            # 击退方向是远离攻击者,推一两帧后自然脱离重叠,穿实体只是瞬间,可接受。
            # 地形还是要查——不能把人打进墙里。
            if not self._is_blocked_by_terrain(info.x + step_x, info.y, info.entity_type):
                info.x += step_x
            if not self._is_blocked_by_terrain(info.x, info.y + step_y, info.entity_type):
                info.y += step_y
            kb.time -= dt
            moved_ids.append(entity_id)
            still_moving.add(entity_id)  # 被击退中,位置仍在变,不算停止

        # ② 普通移动推进(记住方向 + 每 tick 持续推进)
        # 地形阻挡:分轴尝试,被挡的轴不推进,可走的轴照走 → 贴墙滑行。
        # 两轴都被挡(正面撞墙)→ 不推进,但 moving 仍 True(下一 tick 会再试,
        # 配合 AI 寻路重新算路径绕开,不会卡死)。
        for entity_id, info in self._entities.items():
            if entity_id in self._knockbacks:
                continue  # 正在被击退,位移由击退分支推进,不叠加普通移动
            if not info.moving:
                continue
            # 锁定状态(hurt/attacking/dead)不推进位移
            if self._is_input_locked(info):
                # 锁定只是「暂缓推进」不是「停止」,moving 仍是 True,
                # 归入 still_moving,避免解锁后误判成"停止"广播
                still_moving.add(entity_id)
                continue
            speed = config_loader.get_speed(info.entity_type)
            step_x = info.move_dir_x * speed * dt
            step_y = info.move_dir_y * speed * dt
            # 分轴尝试:先 X 后 Y。某轴被挡就只推另一轴 → 沿墙滑行
            if not self._is_blocked(entity_id, info.x + step_x, info.y, info.entity_type):
                info.x += step_x
            if not self._is_blocked(entity_id, info.x, info.y + step_y, info.entity_type):
                info.y += step_y
            moved_ids.append(entity_id)
            still_moving.add(entity_id)

        # ③ 停止迁移检测:上一 tick 在移动、本 tick 明确停止的实体也放进返回值。
        # 场景:AI 主动停下(PatrolState/AttackState 调 apply_move_dir(False)),
        # 只改 moving/state 不改位置,进不了 ② 的 moved_ids——若不广播,
        # 客户端永远不知道敌人停下了,会继续按旧方向预测 → 漂移。
        for entity_id in self._was_moving:
            info = self._entities.get(entity_id)
            if info is None:
                continue  # 实体已移除(死亡/断连),无需同步
            if entity_id in self._knockbacks:
                continue  # 正在被击退,位置仍由击退分支推进,不算停止
            if not info.moving:
                # 上一 tick 还在移动、本 tick 停了 → 广播让客户端切回 idle
                moved_ids.append(entity_id)

        # 记录本 tick 结束时仍在移动的实体,供下一 tick 检测"停止迁移"
        self._was_moving = still_moving
        return moved_ids

    def apply_facing(self, entity_id: str, facing: float) -> bool:
        """
        应用一次朝向输入到状态

        和 apply_move_dir 平行,但只改 facing 不改坐标。
        朝向和移动是两个独立状态维度——玩家可以一边移动一边朝任意方向攻击,
        所以 facing 不应混在 apply_move_dir 里(那会让朝向变成"移动的附属属性",语义错了)。

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

    def set_attack_trigger(self, cb: Callable[[str, int], bool]) -> None:
        """
        注册攻击发动回调(由 GameServer 在初始化时调用)

        回调签名: cb(attacker_id, atk_id) -> bool
            内部负责:apply_attack_start + 广播 AttackStart + 注册判定帧定时器 +
            命中扣血 + 广播 AttackEnd(完整流程)。
        返回 True 表示攻击已发起(状态已变更为 attacking)。
        """
        self._attack_trigger = cb

    def set_entity_spawn_hook(self, cb: Callable[[EntityInfo], None]) -> None:
        """
        注册实体创建回调(由 GameServer 在初始化时调用)

        回调签名: cb(entity_info) -> None
            entity_info 是已入房间的 EntityInfo(add_entity 之后)。
            网络层收到后负责广播新实体(当前广播 GameState + StatsInit 全量快照)。

        为什么不放进 add_entity:add_entity 是所有实体(玩家/木桩/敌人)的通用入口,
        玩家加入已走 PlayerJoin 流程、木桩在启动时注册(那时还没客户端),只有敌人
        是「运行时由 GM 动态创建」且需要即时广播给在线客户端。所以钩子只挂在
        create_enemy 上,不污染 add_entity 的通用语义。
        """
        self._entity_spawn_hook = cb

    def set_pathfinder(self, pf) -> None:
        """
        注入 A* 寻路器(由 GameServer 在初始化时调用)

        GameServer 持有 map_seed,负责构造 ChunkGenerator + Pathfinder 后注入,
        GameRoom 不关心 seed 来源。敌人 AI(ChaseState)通过 get_pathfinder 取用。
        """
        self._pathfinder = pf

    def get_pathfinder(self):
        """取 A* 寻路器(敌人 AI 寻路用,可能为 None——未注入时降级为直线追击)"""
        return self._pathfinder

    # ------------------------------------------------------------------
    # 穿墙权限(GM 调试用)
    # ------------------------------------------------------------------
    def set_wallhack(self, entity_type: str, enabled: bool) -> None:
        """
        开启/关闭某类型实体的穿墙权限(GM 调试入口)

        Args:
            entity_type: 实体类型(如 "player" / "enemy_slime")
            enabled:     True=可穿墙,False=受地形阻挡

        幂等:重复设同一值不会出问题。set 内部用 add/discard 而非
        直接赋值,避免误把整个集合覆盖掉。
        """
        if enabled:
            self._wallhack_types.add(entity_type)
        else:
            self._wallhack_types.discard(entity_type)
        logger.info(f"穿墙权限变更: {entity_type} = {enabled} (当前白名单: {self._wallhack_types})")

    def is_wallhack(self, entity_type: str) -> bool:
        """该类型当前是否允许穿墙(供调试/查询用,tick_movement 内部直接查 _wallhack_types)"""
        return entity_type in self._wallhack_types

    def _is_blocked(self, entity_id: str, x: float, y: float, entity_type: str) -> bool:
        """
        查实体「走一步后」是否被挡(供普通移动推进位移前调用)

        两层阻挡判定:
            ① 地形阻挡(脚点判定):脚点 (x, y + radius) 所在 tile 不可通行 → 阻挡
                - 脚点 = 圆底部,角色和地面的接触点
                - 效果:圆心停在障碍 tile 边界外,角色站在岸边、脚不踩水
            ② 实体间碰撞(圆心判定):圆心 (x, y) 落在其他实体 body 圆内 → 阻挡
                - 防止怪物寻路挤成一坨、玩家穿模重叠
                - 圆-圆相交:distance² < (r1 + r2)²

        普通移动调本方法(查地形 + 查实体)。击退调 _is_blocked_by_terrain(只查地形),
        因为击退是被动位移,必须强制发生——重叠时被击退者要能推开攻击者,若查实体碰撞
        会被攻击者挡住推不出去(详见 tick_movement 击退分支注释)。

        radius 来源:entity_config.json 的 body_params.radius(player=24, enemy=20)
            双端从同一份配置同步,保证服务端阻挡判定和客户端预测一致

        穿墙白名单:只跳过①地形阻挡,不跳过②实体碰撞(穿墙≠穿人)

        Args:
            entity_id:   移动实体自己的 ID(排除自己用)
            x, y:        待推进到的圆心世界坐标(实体「走一步后」的位置)
            entity_type: 实体类型(查穿墙白名单 + 取 radius 用)

        Returns:
            True = 被挡,调用方不应推进该坐标
            False = 可走,调用方可推进
        """
        # ① 地形阻挡(脚点判定)
        if self._is_blocked_by_terrain(x, y, entity_type):
            return True
        # ② 实体间碰撞(圆心判定)
        radius = self._get_circle_radius(entity_type)
        return self._is_blocked_by_entity(entity_id, x, y, radius)

    def _get_circle_radius(self, entity_type: str) -> float:
        """取实体类型的圆形碰撞半径。非圆形/未配置返回 0。"""
        cap = config_loader.get_capability(entity_type)
        if cap.body_shape == config_loader.ShapeType.CIRCLE and isinstance(cap.body_params, config_loader.CircleParams):
            return cap.body_params.radius
        return 0.0

    def _is_blocked_by_terrain(self, x: float, y: float, entity_type: str) -> bool:
        """
        只查地形阻挡(脚点判定),不查实体间碰撞

        击退分支用本方法:击退是被攻击的硬直位移,物理上必须强制发生(被打飞)。
        重叠时被击退者要推开攻击者,若查实体碰撞会被攻击者 body 挡住 → 推不出去 → 卡死。
        击退期间穿实体可接受(被打飞穿过别人,比卡住不动合理),但地形还是要查(不能打进墙里)。

        判定点 = 脚点 (x, y + radius):
            - 穿墙白名单内 → 跳过
            - pathfinder 未注入 → 跳过(降级)
            - 否则查脚点 tile 可通行性
        """
        if entity_type in self._wallhack_types:
            return False
        if self._pathfinder is None:
            return False
        radius = self._get_circle_radius(entity_type)
        foot_y = y + radius
        return not self._pathfinder.is_walkable_at(x, foot_y)

    def _is_blocked_by_entity(self, entity_id: str, x: float, y: float, self_radius: float) -> bool:
        """
        实体间圆-圆碰撞查询:圆心 (x, y) 是否落在其他实体 body 圆内

        过滤规则(跳过以下实体,不挡路):
            - 自己:entity_id 相同
            - 非碰撞体:can_move=false 的实体(如木桩 stake 是测试靶,挡路会卡死玩家)
            - 死亡实体:state=="dead"(正在播死亡动画等待移除,不该挡路)
            - 被击退中的实体:位置不受控(被击退时位移由击退分支推进),
              若挡路会让其他实体卡死在被击退者身上

        判定方式:圆-圆相交
            distance² < (r1 + r2)² → 碰撞
            用平方比较避免开方,性能更好

        Args:
            entity_id:   移动实体自己的 ID(排除自己)
            x, y:        待推进到的圆心世界坐标
            self_radius: 移动实体的半径

        Returns:
            True = 撞到其他实体;False = 无碰撞
        """
        for other_id, other in self._entities.items():
            if other_id == entity_id:
                continue  # 不挡自己
            # 跳过死亡实体(播死亡动画中,即将被移除)
            if other.state == "dead":
                continue
            # 跳过被击退中的实体(位置不受控,挡路会卡死别人)
            if other_id in self._knockbacks:
                continue
            # 取对方能力配置,过滤非碰撞体 + 取半径
            other_cap = config_loader.get_capability(other.entity_type)
            # can_move=false 的实体不挡路(木桩是测试靶,挡路卡死玩家)
            if not other_cap.can_move:
                continue
            # 目前只支持圆形碰撞(和其他形状的判定未来扩展)
            if other_cap.body_shape != config_loader.ShapeType.CIRCLE:
                continue
            if not isinstance(other_cap.body_params, config_loader.CircleParams):
                continue
            other_radius = other_cap.body_params.radius
            # 圆-圆相交判定:用平方比较避免开方
            dx = x - other.x
            dy = y - other.y
            r_sum = self_radius + other_radius
            if dx * dx + dy * dy < r_sum * r_sum:
                return True
        return False

    def trigger_attack(self, entity_id: str, atk_id: int) -> bool:
        """
        发动一次完整攻击流程(对外统一入口)

        玩家(经 pending_inputs)和敌人(AI 状态机)都调本方法,无需关心调用方是谁。
        内部转调 GameServer 注册的 _attack_trigger 回调,完成:
            apply_attack_start → 广播 AttackStart → 注册 AttackTimer →
            hit_cb(命中扣血+广播 AttackHit) → end_cb(apply_attack_end+广播 AttackEnd)

        为什么不直接调 apply_attack_start:
            apply_attack_start 只改状态(设 state="attacking"),不做判定也不广播。
            若敌人 AI 直接调它,会出现"状态切了 attacking 又切回,但全程无伤害无广播"
            的现象——这正是本方法要解决的问题。

        Returns:
            True 表示攻击已发起;False 表示被拒绝(实体不存在/不能攻击/状态锁定/
            已在攻击中)。调用方(AI)可据此决定是否重试。
        """
        if self._attack_trigger is None:
            # 钩子未注册(理论上 GameServer 初始化时就注册,不该走到这里)
            # 退化为只改状态,保证状态层不依赖网络层也能跑(如单测)
            logger.warning("attack_trigger 未注册,trigger_attack 退化为 apply_attack_start")
            return self.apply_attack_start(entity_id, atk_id)
        return self._attack_trigger(entity_id, atk_id)

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

        # 阵营掩码:从攻击者的实体类型取 attack_mask(玩家=2 打敌人层,敌人=1 打玩家层)
        # 为什么用攻击者的 attack_mask 而非 atk_shape.hit_mask:
        #   阵营是实体属性(谁打谁),不是攻击属性。挂在实体上后,玩家和敌人可复用
        #   同一个 atk_id(如 1001),各自打各自阵营——避免攻击配置耦合阵营,
        #   也避免"敌人 1001 只能打敌人"的尴尬(原 hit_mask=2 写死在 attack_config)
        attacker_cap = entity_config.get_capability(attacker.entity_type)
        attack_mask = attacker_cap.attack_mask

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
            # 阵营掩码过滤:攻击者的 attack_mask & 目标的 hit_layer == 0 时跳过
            # (玩家 attack_mask=2 & 敌人 hit_layer=2 → 命中;敌人 attack_mask=1 & 玩家 hit_layer=1 → 命中)
            if (attack_mask & target_cap.hit_layer) == 0:
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

    def apply_knockback(self, target_id: str, attacker_id: str, distance: float) -> bool:
        """
        应用一次击退:把目标从攻击者中心向外推 distance 像素(hurt 硬直期间匀速完成)

        方向:从攻击者位置指向被击者位置(向外推开),和攻击者 facing 无关。
        时长:取 hurt 硬直时长(HURT_DURATION_MS),速度 = distance / 时长——
              整个硬直期间恰好推出 distance 像素,「硬直结束 = 击退结束」。
        复用/覆盖:连击中再次被命中时,新击退覆盖旧击退(方向+速度+计时整体重置),
              和 start_hurt 的"连击重置硬直"语义一致。
        不按 can_move 过滤:木桩(can_move=False)也会被击退(用户确认过,方便测试位移)。

        击退状态存 _knockbacks(服务端瞬态),由 tick_movement 每 tick 推进位移,
        新位置走现有 PlayerMove 广播,客户端无需知道击退细节(服务端权威)。

        Args:
            target_id: 被击退者 entity_id
            attacker_id: 攻击者 entity_id(决定推离方向)
            distance: 击退总距离(像素)

        Returns:
            True 表示击退已生效;False 表示实体不存在/位置重合无法定向
        """
        target = self._entities.get(target_id)
        attacker = self._entities.get(attacker_id)
        if target is None or attacker is None:
            return False

        # 方向:被击者 - 攻击者(归一化)。位置重合(零向量)时无法定向,跳过击退
        dx = target.x - attacker.x
        dy = target.y - attacker.y
        length = math.sqrt(dx * dx + dy * dy)
        if length < 1e-6:
            logger.debug(f"实体 {target_id} 与攻击者 {attacker_id} 位置重合,击退跳过")
            return False

        # 时长 = hurt 硬直时长(秒);速度 = 距离 / 时长 → 硬直期间匀速推出 distance 像素
        duration = config_loader.get_hurt_duration_ms() / 1000.0
        if duration <= 0:
            return False
        speed = distance / duration
        self._knockbacks[target_id] = KnockbackState(
            vx=dx / length * speed,
            vy=dy / length * speed,
            time=duration,
        )
        logger.debug(f"实体 {target_id} 被击退 {distance}px(攻击者 {attacker_id})")
        return True

    # endregion

    # region 战斗组件管理
    ############################################################################

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

    def apply_stat_boost(self, entity_id, max_hp_delta, atk_delta, def_delta):
        # 强化用(预留,阶段 1 可不实现)
        # 后续实现:改 combat 实例字段 + 广播 StatsChanged
        pass

    # endregion

    # region 战斗相关查询
    ############################################################################

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

    # endregion

    # region enemy_mgr
    ############################################################################
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
        self._enemy_mgr.on_enemy_created(entity_id, entity_type)  # AI 状态

        # 通知网络层广播新实体(GM 运行时创建时在线客户端要能看到)。
        # 启动期(main.py)创建时还没有玩家连接,广播是空 no-op;玩家加入时
        # on_player_join 会发全量 GameState,自然包含这个敌人,不受影响。
        if self._entity_spawn_hook is not None:
            self._entity_spawn_hook(enemy)
        return enemy

    # endregion
    
   