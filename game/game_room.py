# coding=utf-8

"""
文件: server/game_room.py
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
    handler 不再直接读写 player_infos。

这样客户端的对应物（ClientStateMirror）就只能是「只读镜像」——
    它没有 apply_move 可抄，因为 apply_move 根本不存在于客户端。
    状态逻辑的重复从「难以避免」变成「结构上不可能发生」。

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

============================================================================
 当前是「混合模型」，不是纯快照（学习要点）
============================================================================
理想的服务器权威快照模型：客户端发 PlayerMove 输入 → 服务端改状态 →
    服务端广播 GameState 快照给所有人，客户端整体替换本地镜像。

但本项目当前实现是「事件转发」：服务端收到 PlayerMove 后，
    既更新了自己的状态，又把 PlayerMove 原样转发给其他客户端。
    其他客户端靠「收到 PlayerMove 事件」来更新本地视图，而非靠 GameState。

这是为了平滑过渡、降低首次实现难度。后续可以演进为纯快照：
    把 on_player_move 里的 broadcast("PlayerMove", ...) 换成 broadcast("GameState", room.snapshot())。
    GameRoom 本身不用改——这正是把状态逻辑收口的好处：换广播策略不动状态代码。
"""

# 只用了标准库的类型标注，没有引入任何游戏/网络依赖
from typing import Dict, List, Optional
import logging

logger = logging.getLogger(__name__)


# 玩家信息在内存中的形态：就是一个普通字典。
# 为什么不定义 dataclass：
#   - 状态最终要序列化成 protobuf 的 PlayerInfo，而 MessageBus.send 接收的就是字典
#   - 用字典做内部表示，可以和 send 的入参无缝衔接，少一层转换
#   - dataclass 的字段类型检查在 6 个字段时收益有限，反而增加样板代码
# 代价：字段名拼错要到运行时才暴露。这个代价我们后续用 messages.yaml 契约锁回来。
PlayerInfoDict = Dict[str, object]


class GameRoom:
    """
    游戏房间状态机（服务端权威）

    =========================================================================
     设计决策
    =========================================================================
    1. 内部用 dict[player_id, PlayerInfoDict] 而不是 list：
         - O(1) 按 player_id 查找/更新/删除，list 是 O(n)
         - 天然保证 player_id 唯一（dict key 不可重复）
         - snapshot() 时再转成 list，匹配 proto 里 repeated PlayerInfo 的形状

    2. 状态变更只通过本类方法（add_player / remove_player / apply_move）：
         - 不允许外部直接 room.players[pid]["x"] = ...
         - 这样所有状态变更都在这里被看到，未来加校验/日志/回放只需改一处
         - 哪怕现在方法很薄，这个「门面」也比直接暴露内部字典更有价值

    3. snapshot() 返回新构造的列表，不返回内部对象的引用：
         - 避免 handler 拿到引用后误改，污染服务端权威状态
         - 注意：这里是浅拷贝（dict.copy()），玩家字典内的值仍是共享引用。
           当前所有字段都是标量（str/int/float），浅拷贝足够安全。
           未来若玩家字典里出现嵌套对象（如 inventory），需改用 copy.deepcopy。

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
        # 玩家表：player_id -> 玩家信息字典
        # 用下划线前缀暗示「内部实现」，外部应通过方法访问
        # （Python 没有真正的私有，下划线只是约定）
        self._players: Dict[str, PlayerInfoDict] = {}

    # ------------------------------------------------------------------
    # 只读访问
    # ------------------------------------------------------------------

    def get_player(self, player_id: str) -> Optional[PlayerInfoDict]:
        """
        获取单个玩家信息（只读意图）

        为什么返回的是内部字典而非拷贝：
            读场景频繁（如 handler 里取 player_name 拼 ChatMessage），
            每次都拷贝开销大且无必要——只要调用方不改它即可。
            约定：拿到 get_player 结果后只读不改；要改状态请走 apply_move 等方法。
        """
        return self._players.get(player_id)

    def has_player(self, player_id: str) -> bool:
        """玩家是否在房间内"""
        return player_id in self._players

    def snapshot(self) -> List[PlayerInfoDict]:
        """
        生成当前完整状态的快照，用于广播 GameState

        返回值形状匹配 proto 的 GameState.players（repeated PlayerInfo），
        可直接传给 bus.send("GameState", {"players": room.snapshot(), ...})。

        为什么返回 list 而非 dict：
            proto 里定义的是 repeated PlayerInfo（列表），不是 map。
            所以序列化前必须转成 list。在这里转，handler 就不用关心形状差异。

        为什么对每个玩家做 dict.copy()：
            如果直接返回 self._players.values()，调用方拿到的是内部字典的引用，
            任何修改都会污染服务端权威状态。copy() 保证快照与内部状态解耦。
            （浅拷贝在此够用，因为字段都是标量；详见类文档第 3 条。）
        """
        return [info.copy() for info in self._players.values()]

    def player_count(self) -> int:
        """当前在线玩家数（调试/监控用）"""
        return len(self._players)

    # ------------------------------------------------------------------
    # 状态变更（唯一允许改状态的地方）
    # ------------------------------------------------------------------

    def add_player(self, player_id: str, player_info: PlayerInfoDict) -> PlayerInfoDict:
        """
        玩家加入房间

        为什么在这里强制设置 player_id 而不是信任传入的字典：
            player_id 是服务器分配的连接标识（见 web_server.py 里的 uuid4），
            客户端传来的 player_info 里可能没有 player_id 或是占位值。
            在这里统一覆盖，保证「状态里的 player_id 永远等于连接 ID」这条不变式。
            这就是收口的好处：不变式只在这里维护一次。

        Args:
            player_id: 服务器分配的连接 ID
            player_info: 客户端发来的玩家信息（player_name/level/score/x/y 等）

        Returns:
            实际存入房间的玩家信息字典（已确保 player_id 字段正确）

        Raises:
            ValueError: player_id 已存在（重复加入，调用方应先检查或忽略）
        """
        if player_id in self._players:
            # 显式报错而非静默覆盖：重复加入通常是逻辑 bug，早暴露比晚暴露好
            raise ValueError(f"玩家 {player_id} 已在房间内，不能重复加入")

        # 复制一份再存，避免外部持有的字典后续被改影响内部状态
        # （web_server.py 的 handler 会保留 player_info 引用做日志，不能让它误改状态）
        stored = dict(player_info)
        stored["player_id"] = player_id  # 强制不变式
        # facing 默认 0(朝右)——客户端加入时通常没带 facing，状态从创建起就要有这个字段
        # 不用 .get() 是因为要确保字段存在(后续 snapshot/apply_facing 都依赖它)
        if "facing" not in stored:
            stored["facing"] = 0.0
        # state 默认 "idle"——动画状态字段,和 facing 一样属于持续状态
        # 客户端加入时没带 state,服务端从创建起就给默认值
        # 后续 apply_move 会根据 moving 参数把它改成 "run"/"idle"
        if "state" not in stored:
            stored["state"] = "idle"

        self._players[player_id] = stored
        logger.info(f"玩家加入房间: {stored.get('player_name', '?')} (ID: {player_id})")
        return stored

    def remove_player(self, player_id: str) -> Optional[PlayerInfoDict]:
        """
        玩家离开房间

        Returns:
            被移除的玩家信息（用于离开时取 player_name 做日志/广播）；
            若玩家本来就不在房间，返回 None（不报错，因为断连清理可能被重复调用）。

        为什么不存在时返回 None 而非报错：
            cleanup_player 在 finally 里被调用，可能因异常路径被触发多次。
            重复删除是合法的幂等行为，不应抛异常打断清理流程。
            这与 add_player 的「重复加入报错」相反——
            加入重复是 bug，离开重复是容错，语义不同。
        """
        removed = self._players.pop(player_id, None)
        if removed is not None:
            logger.info(f"玩家离开房间: {removed.get('player_name', '?')} (ID: {player_id})")
        return removed

    def apply_move(self, player_id: str, x: float, y: float, speed: float = 1.0, moving: bool = False) -> bool:
        """
        应用一次玩家移动输入到状态

        =========================================================================
         为什么不直接 set 位置——这里埋了演进路径
        =========================================================================
        当前是「目标坐标直接落地」的简化版：客户端说移到 (x,y)，状态就直接是 (x,y)。
        真实游戏里移动是连续的，应该是：
            - 服务端按 tick 推进：new_pos = old_pos + velocity * dt
            - 或至少校验移动合法性：目标点是否在地图内、是否穿墙、单次位移是否过大（防作弊）

        把 apply_move 收口到这里的好处恰恰在此：
        后续要加上述任何逻辑，只改这一个方法，handler 和客户端都不用动。
        如果状态逻辑还散落在 handler 里，加校验要改 N 处，且客户端的副本会漏改。

        =========================================================================
         speed 参数当前未使用，但保留——为什么
        =========================================================================
        speed 字段已存在于 proto 的 PlayerMove 里，客户端会发。
        当前服务端忽略它（直接落地目标坐标），但保留参数位是为了：
            1. handler 签名和 proto 字段一一对应，读代码就能看出「消息里有什么」
            2. 后续做连续移动模型时，speed 立刻可用，不用再改接口
        这是一种「为已知的下一步留接口，但不实现」的克制——
            不要因此就去写 half-implemented 的速度积分逻辑，那才是过度设计。

        =========================================================================
         moving 参数：驱动动画状态 state
        =========================================================================
        moving=True 表示玩家正在移动→state="run"；moving=False 表示停止→state="idle"。
        这把"动画状态"也收口到服务端权威：客户端不发"我处于 run 状态"，
        而是发"我在动/我没在动"，由服务端定 state。
        未来加攻击/受击等动作状态时,用独立的 apply_attack/apply_hurt 方法,
        各自设自己的 state,和 apply_move 互不干扰(攻击时可能不能移动,那是上层逻辑)。

        Args:
            player_id: 谁在移动
            x, y: 目标坐标
            speed: 移动速度（当前未使用，保留字段）
            moving: 是否正在移动(驱动 state 字段)

        Returns:
            True 表示状态已更新；False 表示玩家不存在（移动被忽略）
        """
        info = self._players.get(player_id)
        if info is None:
            # 玩家不在房间：可能是未加入就发移动，或已离开。
            # 返回 False 让 handler 决定是否告警，而不是在这里抛异常——
            # 网络消息乱序是常态，不该让状态层处理容错逻辑。
            return False

        # 直接落地目标坐标（简化模型，见上方说明）
        info["x"] = x
        info["y"] = y
        # 注意：speed 当前不存入状态，因为状态快照（PlayerInfo）里没有 speed 字段。
        # speed 是「移动事件」的属性，不是「玩家状态」的属性——这个区分很重要：
        #   - 状态 = 持续存在的属性（位置、等级、分数）
        #   - 事件 = 瞬时发生的动作（一次移动、一次攻击）
        # proto 里 PlayerInfo 没有 speed、PlayerMove 有 speed，正好对应这个区分。

        # 动画状态:moving 决定 idle/run
        # state 是持久状态字段(存 PlayerInfo),客户端动画状态机读它切换动画
        info["state"] = "run" if moving else "idle"

        logger.debug(f"玩家 {player_id} 移动到 ({x}, {y}) state={info['state']}")
        return True

    def apply_facing(self, player_id: str, facing: float) -> bool:
        """
        应用一次玩家朝向输入到状态

        和 apply_move 平行，但只改 facing 不改坐标。
        朝向和移动是两个独立状态维度——玩家可以一边移动一边朝任意方向攻击，
        所以 facing 不应混在 apply_move 里（那会让朝向变成"移动的附属属性"，语义错了）。

        Args:
            player_id: 谁在转朝向
            facing: 朝向角度(弧度),0=右,逆时针正(Godot 标准)

        Returns:
            True 表示状态已更新；False 表示玩家不存在（朝向被忽略）

        =========================================================================
         频率限制当前未做——留给第3步
        =========================================================================
        鼠标移动会高频触发朝向更新(60Hz+)，服务端应做频率限制(如 30Hz)。
        当前简化版不做限制，第3步"限定服务端同步速率"会统一加 tick 机制处理。
        这里只做状态变更逻辑，节流策略交给上层(handler/web_server)。
        """
        info = self._players.get(player_id)
        if info is None:
            return False

        # 弧度归一到 [0, 2*PI)，避免数值无限增长
        # 不做范围校验(如限制角度范围)，因为任意朝向都是合法的
        import math
        info["facing"] = facing % (2 * math.pi)

        logger.debug(f"玩家 {player_id} 朝向 {info['facing']}")
        return True
