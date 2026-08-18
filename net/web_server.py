# coding=utf-8

"""
WebSocket 游戏服务器核心模块
使用 MessageBus 单例进行消息收发，业务代码只处理字典，不接触 protobuf

本文件只定义类和 handler 注册函数，不产生模块级副作用（不创建实例、不注册 handler）。
实例创建和 handler 注册由 main.py 负责——这样 import 本模块不会有副作用，
便于测试和未来热更（热更时重新 import 不会重复创建实例）。
"""

import asyncio
import sys
import websockets
import uuid
import time
import logging
import dataclasses
from typing import Dict, Optional, Set

# 项目模块用 import xxx + xxx.def 访问，不用 from xxx import def
# 原因：后续要支持 hotfix/hotreload。
#   from message_bus import MessageBus 会把 MessageBus 这个名字绑定到本模块命名空间，
#   热更时即使重新 import message_bus，已绑定的 MessageBus 仍指向旧类。
#   用 import message_bus + message_bus.MessageBus() 访问，每次走模块属性查找，
#   热更后重新加载模块就能拿到新类。
# 标准库和第三方库不热更，保留 from import 不受此约束。
#
# 包内模块引用用 `import net.xxx as xxx` 形式：
#   - 这是 import 语句（不是 from...import），不违反热更约束
#   - as 别名只是给模块对象起短名，message_bus.MessageBus() 仍走模块属性查找
#   - 不用 `from . import` 是因为项目规则禁止 from...import 形式
import net.message_bus as message_bus
import net.message_contract as message_contract
import game.game_room as game_room
import game.timer_mgr as timer_mgr
import config.config_loader as config_loader
import game.helper.ai_state_helper as ai_state_helper
# game_pb2 是生成代码，由 message_bus 内部加入 sys.path，这里直接 import
import game_pb2

logger = logging.getLogger(__name__)


class GameServer:
    # tick 周期:33ms(约 30.3Hz)
    # 为什么 30Hz 量级:
    #   - 60Hz 流畅但带宽/CPU 消耗大,2D 学习项目没必要
    #   - 20Hz 动作游戏会感觉略卡,攻击朝向不跟手
    #   - 30Hz 主流平衡点,MOBA/ARPG 常用
    # 为什么用整数毫秒而非 1/30 浮点秒:
    #   - 与 Windows 定时粒度(提频到 1ms 后)天然对齐,asyncio.sleep 醒来时刻均匀,
    #     避免 0.0333 无限小数在定时器取整时的系统性偏差
    #   - 日志/调试输出读数直观(33ms 而非 33.333ms),和客户端宽限窗口计算语义一致
    # 注意:本常量只用于控频(sleep 时长),位移积分用实测 dt(见 _tick_loop),
    #   不再用 TICK_INTERVAL 当 dt——那是 tick 漂移导致移动拉扯的根因
    TICK_INTERVAL_MS: int = 33

    # 实测 dt 钳制上限(秒):防卡顿/调试断点后大步跳变把实体瞬移
    # 截断会造成短暂慢速,属于可接受的退化行为
    MAX_TICK_DT: float = 0.1

    def __init__(self, host: str = "0.0.0.0", port: int = 8765, bus=None):
        self.host = host
        self.port = port

        # 地图种子(双端一致生成的关键)
        # 服务端启动时持有 seed,通过 MapInfo 消息下发给客户端,
        # 客户端 InfiniteTileMap.setup(seed) 用相同 seed 构造 ChunkGenerator,
        # 双端产出完全相同的地图(详见 game/map_generator.py)
        # 当前硬编码 12345(和客户端调试用的 seed 一致,便于验证双端产出)
        # 未来可改成 random.randint(0, 2**31-1) 或从配置读
        self.map_seed: int = 12345

        # 消息总线：由外部传入（main.py 创建），避免本模块创建单例的副作用
        # 如果没传，用 MessageBus 单例（兼容旧用法）
        self.bus = bus if bus is not None else message_bus.MessageBus()

        # 玩家连接表：player_id -> websocket
        # 这是「传输层」状态：谁连着、往哪个 socket 发数据。
        # 与游戏状态（玩家坐标/等级）分开存放，因为它们的变更时机不同：
        #   - 连接在 handle_client 开始/结束时变更
        #   - 游戏状态在收到 PlayerMove 等消息时变更
        # 会话表：所有已 Login 的客户端（大厅 + 房间内）
        # 拆出 Login 后，连接一建立就进 sessions，但不一定进 players。
        # 大厅聊天/后续大厅功能都通过 sessions 找连接和玩家信息。
        self.sessions: Dict[str, dict] = {}

        # 房间内玩家连接表：player_id -> websocket
        # 只有点击“开始游戏”进入房间后才加入，用于游戏状态广播。
        self.players: Dict[str, websockets.WebSocketServerProtocol] = {}

        # 游戏状态持有者：所有玩家信息（坐标、等级、分数）都由它管理。
        # 重构前这里是 self.player_infos 字典，handler 直接读写它。
        # 现在统一收口到 GameRoom，handler 只能通过 room.add_player / apply_move_dir 等方法变更状态。
        # 这样状态变更规则只有一处定义，避免双端重复（详见 game_room.py 文档）。
        # 用 game_room.GameRoom() 而非 GameRoom()，热更见文件头注释
        self.room = game_room.GameRoom()
        self.timer_mgr = timer_mgr.TimerManager()

        # 把"完整攻击发动流程"注册给 GameRoom 作为钩子。
        # 这样玩家(经 pending_inputs)和敌人(AI 直接调用)都走 room.trigger_attack(),
        # 统一入口,避免敌人 AI 绕过网络层导致"只改状态不发动"的问题(详见 game_room.trigger_attack)
        self.room.set_attack_trigger(self._trigger_attack)

        # 把"新实体出现广播"注册给 GameRoom 作为钩子。
        # GM/控制台调 room.create_enemy 后,GameRoom 会回调这里,由网络层广播
        # EntitySpawn 增量消息，让所有在线客户端原子接收新实体及其战斗属性。
        self.room.set_entity_spawn_hook(self._on_entity_spawned)

        # 把"AI 状态变更广播"注册给 EnemyMgr 作为钩子。
        # 敌人 AI 状态切换(patrol/chase/attack/look_around)时,EnemyMgr 回调这里,
        # 网络层广播 AiStateChanged 增量消息——客户端据此切换视锥形态(normal/chase),
        # 切换视野不能等低频快照,所以状态切换即广播(低频事件,不走 tick dirty 集合)。
        self.room.get_enemy_manager().set_ai_state_change_hook(self._on_ai_state_changed)

        # 构造 A* 寻路器并注入 GameRoom。
        # 敌人 AI(ChaseState)通过 room.get_pathfinder() 取用,基于双端一致的
        # ChunkGenerator(seed 来自 self.map_seed)做网格寻路,绕开不可通行地形。
        # 这里只构造一次:ChunkGenerator 是无状态的(同 seed 同输入永远同输出),
        # Pathfinder 也是纯算法模块,全房间共享一个实例即可。
        import game.map_generator as map_generator
        import game.pathfinder as pathfinder
        _gen = map_generator.ChunkGenerator(seed=self.map_seed)
        self._pathfinder = pathfinder.Pathfinder(_gen)
        self.room.set_pathfinder(self._pathfinder)

        self.is_running = False

        # 事件循环引用(start 时用 asyncio.get_running_loop() 填充)。
        # 为什么需要:GM 控制台在独立线程里调 room.create_enemy,回调 _on_entity_spawned
        # 会从该线程触发;broadcast/_queue_broadcast 操作 asyncio 队列,必须投递回
        # 事件循环线程执行,用 loop.call_soon_threadsafe 做线程安全投递。
        self._loop = None

        # tick 机制:pending_inputs 收集高频输入(move/facing),每 tick 统一处理+广播
        # 结构: {player_id: {"move": {...}, "facing": {...}}}
        # 同一 tick 内同一动作的多次输入只保留最后一次(覆盖)——这就是节流的核心
        # 为什么放这里而不是 GameRoom:
        #   - pending_inputs 是"传输层待处理数据",不是游戏状态
        #   - GameRoom 保持纯状态层,不知道 tick 存在
        #   - GameServer 是传输层和状态层的协调点,管 tick 合适
        self._pending_inputs: Dict[str, Dict[str, dict]] = {}

        # tick 循环任务(start 时 create,stop 时 cancel)
        self._tick_task = None

        # 发送队列 + sender 协程:状态层(tick)只往队列塞消息,传输层(sender)独立协程发
        # 为什么这样设计:
        #   原来 _process_tick 里 await self.broadcast(...),tick 间隔会被 I/O 时间拉长
        #   (broadcast 要遍历所有玩家 await ws.send,网络慢就卡 tick)
        #   改成塞队列后,tick 只做状态计算(微秒级),broadcast 在 sender 协程里慢慢发
        #   某个玩家网络慢只影响 sender,不影响 tick 节奏——30Hz 严格稳定
        # 顺序保证:asyncio.Queue 是 FIFO,tick 塞的消息顺序 = 发送顺序
        self._send_queue: asyncio.Queue = asyncio.Queue()
        # 控制消息保持 FIFO；移动快照只保留最新一份，避免慢客户端拖住状态同步。
        self._latest_movement: Optional[dict] = None
        self._send_wakeup = asyncio.Event()
        self._movement_overwrites = 0
        self._movement_batches_sent = 0
        self._movement_entries_sent = 0
        self._movement_max_wait_ms = 0.0
        self._control_burst = 0
        self._max_control_burst = 8
        self._tick_sequence = 0
        self._socket_send_locks: Dict[object, asyncio.Lock] = {}
        self._sender_task = None

        # Windows 定时粒度是否已被本进程提升(timeBeginPeriod 成功才置 True)
        # 用于 stop 时对称调 timeEndPeriod,避免重复/无效调用
        self._timer_resolution_raised: bool = False

    async def handle_client(self, websocket: websockets.WebSocketServerProtocol):
        """处理单个客户端连接

        注意：websockets 13.0+ 版本不再传 path 参数，如需路径可从 websocket.request.path 获取
        """
        async with websocket:
            # 先收客户端第一条消息(应该是 Login),从中取客户端本地账号 id(account_id)
            # 顺序调整原因:账号 id 是随 Login 传来的,服务端要先用它确定 player_id,
            # 再构造 ctx / 存连接 / 分发——所以 recv 提前到 player_id 分配之前。
            try:
                first_message = await websocket.recv()

                # 注意:第一条消息需要特殊处理,先解析判断是否是 Login
                game_msg = game_pb2.GameMessage()
                game_msg.ParseFromString(first_message)

                if not game_msg.HasField('login'):
                    logger.warning("第一条消息不是 Login，断开连接")
                    return
            except websockets.exceptions.ConnectionClosed:
                logger.info("客户端在发送 Login 前断开连接")
                return

            # 优先用客户端本地账号 id 作为 player_id(跨会话/跨重启稳定识别同一账号)
            # 老客户端/测试工具不带 account_id(proto3 未设置返回 "")，回退随机 uuid
            account_id = game_msg.login.account_id
            player_name = game_msg.login.player_name or "未命名"
            if account_id.startswith("player:"):
                player_id = account_id
                logger.info(f"新客户端连接，使用账号ID作为玩家ID: {player_id}")
            else:
                player_id = f"player:{uuid.uuid4()}"
                logger.info(f"新客户端连接(无账号ID)，随机分配玩家ID: {player_id}")

            # 构造消息上下文，后续所有消息分发都带上它
            # MessageContext 定义在 message_bus 模块里，用 message_bus.MessageContext 访问
            ctx = message_bus.MessageContext(websocket=websocket, player_id=player_id, is_server=True)

            try:
                # 保存会话信息（在 handler 之前，因为 handler 里要用）
                self.sessions[player_id] = {
                    "websocket": websocket,
                    "player_name": player_name,
                    "account_id": account_id,
                }

                # 分发第一条消息（触发 on_login）
                await self.bus.dispatch(first_message, ctx)

                # 进入主循环，持续处理消息
                while self.is_running:
                    try:
                        message = await asyncio.wait_for(websocket.recv(), timeout=30.0)
                        # 所有消息都交给 bus 分发，handler 通过 @bus.onproto 注册
                        await self.bus.dispatch(message, ctx)

                    except asyncio.TimeoutError:
                        # 超时发心跳
                        logger.debug(f"玩家 {player_id} 超时，发送心跳")
                        await self.bus.send("Heartbeat", {"timestamp": int(time.time() * 1000)},
                                            websocket=websocket)

                    except websockets.exceptions.ConnectionClosed:
                        logger.info(f"玩家 {player_id} 连接关闭")
                        break

                    except Exception as e:
                        logger.exception(f"处理玩家 {player_id} 消息时出错: {e}")
                        break

            except Exception as e:
                logger.exception(f"处理客户端 {player_id} 时出错: {e}")

            finally:
                await self.cleanup_player(player_id)

    async def broadcast(self, protoname: str, protoprama: dict, exclude_player: Optional[str] = None):
        """
        广播消息给所有玩家（服务器端专用）

        Args:
            protoname: 消息类型名
            protoprama: 消息内容（字典）
            exclude_player: 排除的玩家ID（通常是发送者自己）
        """
        disconnected = set()
        for pid, ws in self.players.items():
            if exclude_player and pid == exclude_player:
                continue
            try:
                await self._send_serialized(protoname, protoprama, ws)
            except Exception as e:
                logger.error(f"向玩家 {pid} 发送消息失败: {e}")
                disconnected.add(pid)

        for pid in disconnected:
            await self.cleanup_player(pid)

    async def broadcast_to_clients(self, protoname: str, protoprama: dict, exclude_player: Optional[str] = None):
        """广播消息给所有已 Login 的客户端（大厅 + 房间内）

        聊天等大厅级消息用这个，游戏状态广播仍用 broadcast() 只发给房间内玩家。
        """
        disconnected = set()
        for pid, session in self.sessions.items():
            if exclude_player and pid == exclude_player:
                continue
            ws = session["websocket"]
            try:
                await self._send_serialized(protoname, protoprama, ws)
            except Exception as e:
                logger.error(f"向客户端 {pid} 发送消息失败: {e}")
                disconnected.add(pid)

        for pid in disconnected:
            await self.cleanup_player(pid)

    async def _send_serialized(self, protoname: str, protodata: dict, websocket) -> None:
        """串行化同一 websocket 的写入，防止 Pong 与广播并发调用底层 send。"""
        lock = self._socket_send_locks.setdefault(websocket, asyncio.Lock())
        async with lock:
            await self.bus.send(protoname, protodata, websocket=websocket)

    async def send_control(self, protoname: str, protodata: dict, websocket) -> None:
        """发送高优先级控制消息；网络 handler 用此路径返回 Pong。"""
        await self._send_serialized(protoname, protodata, websocket)

    def get_send_diagnostics(self) -> dict:
        """返回发送调度指标，供诊断面板或日志采样读取。"""
        return {
            "control_queue_depth": self._send_queue.qsize(),
            "movement_pending": self._latest_movement is not None,
            "movement_overwrites": self._movement_overwrites,
            "movement_batches_sent": self._movement_batches_sent,
            "movement_entries_sent": self._movement_entries_sent,
            "movement_max_wait_ms": self._movement_max_wait_ms,
            "control_burst": self._control_burst,
            "astar_count_this_tick": self.room.get_enemy_manager().astar_count_this_tick,
            "path_invalidations": self.room.get_enemy_manager().path_invalidations,
            "reschedule_count": self.room.survival_run.reschedule_count,
        }


    # ------------------------------------------------------------------
    # 发送队列:逻辑层与传输层解耦
    # ------------------------------------------------------------------
    # _process_tick 和 timer 回调都不直接 await broadcast,而是调 _queue_broadcast 塞队列。
    # _sender_loop 独立协程从队列取消息,调真正的 broadcast 发出去。
    # 这样 tick 不会被网络 I/O 阻塞,保证 30Hz 严格稳定。

    def _queue_broadcast(self, protoname: str, protodata: dict) -> None:
        """把广播消息塞进发送队列(不阻塞,立即返回)

        逻辑层(tick / timer 回调)用这个替代 await self.broadcast(...)。
        真正的发送在 _sender_loop 里进行,不影响 tick 节奏。
        """
        if protoname == "MovementBatch":
            if self._latest_movement is not None:
                self._movement_overwrites += 1
            self._latest_movement = protodata
            protodata["_queued_at"] = time.monotonic()
        else:
            self._send_queue.put_nowait((protoname, protodata))
        self._send_wakeup.set()

    def _on_entity_spawned(self, entity_info) -> None:
        """
        实体创建钩子(由 GameRoom.create_enemy 回调,见 game_room.set_entity_spawn_hook)

        线程安全:GM 控制台在独立线程调 room.create_enemy,本方法会从该线程进入。
        asyncio 队列不是线程安全的,不能直接 _queue_broadcast,改用
        loop.call_soon_threadsafe 投递回事件循环线程执行真正的广播。
        start() 之前(如 main.py 启动期创建敌人)loop 还是 None,此时没有并发,
        直接同步广播塞队列是安全的(队列尚未被 sender 消费)。
        """
        if self._loop is not None and not self._loop.is_closed():
            self._loop.call_soon_threadsafe(self._broadcast_entity_spawn, entity_info)
        else:
            self._broadcast_entity_spawn(entity_info)

    def _on_ai_state_changed(self, entity_id: str, ai_state: str) -> None:
        """
        AI 状态变更钩子(由 EnemyMgr 回调,见 enemy_mgr.set_ai_state_change_hook)

        两件事:
            1. 同步 AI 状态到 EntityInfo.ai_state——GameState 快照用 asdict 转 dict,
               新玩家加入时能带真实 AI 状态(否则快照里 ai_state 永远是默认 "idle")。
            2. 广播 AiStateChanged 增量消息——客户端据此切换视锥形态。

        状态切换即广播(不走 tick dirty 集合):AI 状态切换是低频事件
        (patrol→chase→attack),而视锥形态必须实时跟随——等低频快照会延迟。
        和 tick 广播同一条发送队列(FIFO 保序),调用方都在事件循环线程,
        不需要 call_soon_threadsafe。
        """
        entity = self.room.get_entity(entity_id)
        if entity is not None:
            entity.ai_state = ai_state
        self._queue_broadcast("AiStateChanged", {
            "entity_id": entity_id,
            "ai_state": ai_state,
        })

    def _broadcast_entity_spawn(self, entity_info) -> None:
        """
        广播新实体出现(在事件循环线程内执行)

        GameRoom 先完成实体、战斗组件和 EnemyMgr AI 挂载，再回调本方法。
        EntitySpawn 一条消息同时携带 EntityInfo 与 CombatStatsEntry，客户端可
        原子写入两个镜像后创建 Role；新玩家进房/重连仍使用 GameState + StatsInit。
        """
        # GameRoom 已先完成实体、战斗组件和 AI 挂载；一条 EntitySpawn 原子携带
        # 实体与初始战斗属性，客户端无需触发全量 state_replaced 重建所有 Role。
        combat = self.room.get_combat(entity_info.entity_id)
        if combat is None:
            # 无战斗组件的实体仍可出生，但不能伪造可战斗属性。
            combat_data = {"entity_id": entity_info.entity_id}
        else:
            combat_data = dataclasses.asdict(combat)
        self._queue_broadcast("EntitySpawn", {
            "entity_info": dataclasses.asdict(entity_info),
            "combat": combat_data,
        })

    async def _sender_loop(self) -> None:
        """发送协程:独立运行,从队列取消息调 broadcast 发出

        为什么需要独立协程:
            _process_tick 里如果 await self.broadcast(...),tick 间隔会被 I/O 时间拉长。
            改成塞队列后,tick 只做状态计算(微秒级),broadcast 在本协程里慢慢发。
            某个玩家网络慢只影响本协程,不影响 tick 节奏。

        积压处理:
            控制事件保留 FIFO，并限制连续控制发送 burst；移动状态只保留最新槽位，
            到达公平点后发送，避免旧移动快照堆积或移动快照长期饥饿。

        错误处理:
            单条消息发送失败不退出循环,记日志继续发下一条。
            broadcast 内部已有失败玩家的 cleanup 逻辑。
        """
        logger.info("sender 协程启动")
        while self.is_running:
            try:
                if (not self._send_queue.empty() and
                        (self._latest_movement is None or self._control_burst < self._max_control_burst)):
                    protoname, protodata = self._send_queue.get_nowait()
                elif self._latest_movement is not None:
                    protoname, protodata = "MovementBatch", self._latest_movement
                    self._latest_movement = None
                else:
                    # 先清除事件，再重新检查生产者写入；这样生产者在第一次空检查
                    # 与 clear 之间 set 事件时，第二次检查会直接继续，不会丢唤醒。
                    self._send_wakeup.clear()
                    if not self._send_queue.empty() or self._latest_movement is not None:
                        continue
                    await self._send_wakeup.wait()
                    continue
                await self.broadcast(protoname, protodata)
                if protoname == "MovementBatch":
                    queued_at = protodata.pop("_queued_at", None)
                    if queued_at is not None:
                        self._movement_max_wait_ms = max(
                            self._movement_max_wait_ms,
                            (time.monotonic() - queued_at) * 1000.0)
                    self._movement_batches_sent += 1
                    self._movement_entries_sent += len(protodata.get("entries", []))
                    self._control_burst = 0
                else:
                    self._control_burst += 1
            except asyncio.CancelledError:
                break
            except Exception as e:
                # 用 logger.exception 而非 logger.error:打完整 traceback,方便定位
                logger.exception(f"sender_loop 发送消息出错: {e}")
                continue
        logger.info("sender 协程已停止")

    # ------------------------------------------------------------------
    # tick 机制:限定同步速率
    # ------------------------------------------------------------------
    # 为什么需要 tick:
    #   客户端 60Hz 发 move/facing,服务端如果立即处理+广播,会导致:
    #     1. 高频广播冲击带宽(10 玩家 × 60Hz × 2 消息 = 1200 次/秒广播)
    #     2. 同一玩家一帧内多次输入只取最后一次即可,中间的都浪费
    #   tick 机制把"立即处理"改成"存 pending → 每 33ms 统一处理+广播":
    #     - 同一 tick 内同一动作的多次输入只保留最后一次(节流)
    #     - 广播频率从 60Hz 降到 30Hz(带宽减半)
    #     - 所有玩家状态在同一 tick 对齐(状态有序)
    #
    # 哪些消息走 tick:
    #   - PlayerMove / PlayerFacing(高频输入)→ 走 tick
    #   - EnterRoom / LeaveRoom / ChatMessage(低频事件)→ 不走 tick,立即处理
    #     理由:加入/离开/聊天是即时事件,不该等 tick 增加延迟

    def add_pending_input(self, player_id: str, action: str, data: dict) -> None:
        """
        存入 pending 输入,等 tick 时统一处理

        Args:
            player_id: 哪个玩家的输入
            action: "move" 或 "facing"
            data: 输入数据字典(move: {x,y,speed} / facing: {facing})

        同一 tick 内同一动作的多次输入只保留最后一次(覆盖)——
        这就是节流的核心:60Hz 发的移动,服务端只处理 30Hz 的最后一次。
        """
        if player_id not in self._pending_inputs:
            self._pending_inputs[player_id] = {}
        self._pending_inputs[player_id][action] = data

    async def _tick_loop(self) -> None:
        """
        tick 循环:每 TICK_INTERVAL_MS 毫秒处理一次 pending

        asyncio 单线程事件循环:tick_loop 和 handle_client 在同一线程,
        通过 await 切换执行。pending_inputs 不需要锁——
        handler 存入 pending 时不会 await(原子执行),不会在存入中途被 tick 打断。

        为什么 tick 节奏稳定:
            tick 循环里不再有 await self.broadcast(...)(那会因网络 I/O 拉长间隔)。
            tick 只做状态计算(apply_move_dir 等,纯内存微秒级)+ 塞队列(put_nowait 不阻塞)。
            真正的广播在 _sender_loop 独立协程里发,不影响 tick 节奏。

        实测 dt(关键):
            sleep 的实际唤醒间隔受系统定时粒度影响(Windows 默认 15.6ms,
            33ms 请求实际约 47ms 才醒),不能用固定 TICK_INTERVAL 当 dt 积分——
            那会让服务端移速系统性慢于客户端预测,累积超对账阈值触发周期性回拉。
            这里用 time.monotonic() 实测两次 tick 的真实间隔作为 dt,
            位移推进与墙钟一致,tick 率漂移不影响移速。
        """
        logger.info(f"tick 循环启动,周期 {self.TICK_INTERVAL_MS}ms")
        # 启动 sender 协程:tick 只算状态+塞队列,sender 负责真正发
        # tick 和 sender 通过 _send_queue 解耦,互不阻塞
        self._sender_task = asyncio.create_task(self._sender_loop())
        last_tick_ts = time.monotonic()
        try:
            while self.is_running:
                await asyncio.sleep(self.TICK_INTERVAL_MS / 1000.0)
                # 实测 dt:真实 tick 间隔,钳制到 [0, MAX_TICK_DT]
                # 上限防卡顿/断点后大步跳变把实体瞬移(截断代价是短暂慢速,可接受)
                now = time.monotonic()
                dt = min(max(now - last_tick_ts, 0.0), self.MAX_TICK_DT)
                last_tick_ts = now
                # inner try:单个 tick 出错不能停整个循环
                # asyncio 默认不会把 create_task 的异常打到控制台,
                # 这里手动 catch + logger.exception 打完整 traceback
                try:
                    await self._process_tick(dt)
                except asyncio.CancelledError:
                    raise   # CancelledError 要继续往外抛,不能吞
                except Exception as e:
                    logger.exception(f"_process_tick 异常,本 tick 跳过: {e}")
        finally:
            # tick 退出时必须连带取消 sender,否则 sender 会永远阻塞在 queue.get()
            if self._sender_task and not self._sender_task.done():
                self._sender_task.cancel()
                try:
                    await self._sender_task
                except asyncio.CancelledError:
                    pass
        logger.info("tick 循环已停止")

    async def _process_tick(self, dt: float) -> None:
        """
        处理一个 tick 的 pending 输入 + 持续移动推进

        流程:
            1. 取出并清空 pending(下一 tick 重新收集)
            2. 遍历 pending,调 apply_move_dir(只记方向)/apply_facing/apply_attack_start
            3. 木桩回血
            4. 敌人 AI tick(EnemyMgr.update,内部调 apply_move_dir 改方向)
            5. ★ 持续移动推进:tick_movement 对所有 moving=True 的实体统一推进位移
            6. 收集广播(改方向的 + 被推进的 + 朝向变化的)
            7. 统一广播

        Args:
            dt: 实测 tick 间隔(秒,由 _tick_loop 用 time.monotonic() 测得并钳制)。
                位移推进/AI 都用它积分,不能用固定 TICK_INTERVAL 替代——
                真实 tick 间隔受系统定时粒度影响会漂移,固定 dt 会让服务端移速
                系统性偏慢,客户端预测对账累积超阈值 → 周期性回拉。
        """
        # 取出并清空(下一 tick 重新收集新的输入)
        tick_start = time.perf_counter()
        pending = self._pending_inputs
        self._pending_inputs = {}
        # A solo level-up pauses the whole Run, including movement and attacks.
        if self.room.survival_run.should_pause():
            # 单人升级暂停必须阻断本 tick 的移动/攻击输入；多人升级不进入此分支，
            # 各玩家的奖励队列由 SurvivalRun 独立维护。
            pending = {}

        # 收集本 tick 要广播的消息:List[(protoname, protodata)]
        broadcasts = []
        # 需要广播 PlayerMove 的实体集合(改方向 + 被持续推进 + AI 停止迁移)
        moved_entities: set = set()

        # ① 处理 pending 输入(只改方向/朝向/攻击,不推进位移)
        for entity_id, inputs in pending.items():
            if not self.room.has_entity(entity_id):
                continue

            # 处理移动输入:apply_move_dir 只记住方向,不推进位移
            if "move" in inputs:
                m = inputs["move"]
                if self.room.apply_move_dir(entity_id, m["dir_x"], m["dir_y"], m["moving"], dt):
                    # 标记需要广播(方向/移动状态可能变了,即使停止也要广播让客户端切 idle)
                    moved_entities.add(entity_id)

            # 处理朝向输入
            if "facing" in inputs:
                f = inputs["facing"]
                if self.room.apply_facing(entity_id, f["facing"]):
                    broadcasts.append(("PlayerFacing", {
                        "entity_id": entity_id,
                        "facing": f["facing"]
                    }))

            # 处理攻击发起输入
            if "attackstart" in inputs:
                a = inputs["attackstart"]
                # 走 room.trigger_attack 统一入口(和敌人 AI 同一条路)
                # 完整流程(状态变更+广播 AttackStart+注册判定帧定时器+命中扣血+广播 AttackEnd)
                # 在 _trigger_attack 里,由 GameRoom 通过 attack_trigger 钩子转调
                self.room.trigger_attack(a["entity_id"], a["atk_id"])

        # SurvivalRun is owned by GameRoom and is advanced before ordinary AI.
        # It may spawn enemies and put distant enemies into returning state.
        self.room.survival_run.update(dt)
        run = self.room.survival_run
        # 重定位是可靠控制事件，先入 FIFO，再发移动快照，客户端收到后直接 snap。
        for relocation in self.room.consume_relocations():
            self._queue_broadcast("EntityRelocated", relocation)
        # Run 先写入 GameRoom 权威状态，再由本层把快照/候选广播给客户端；
        # 客户端收到的 SurvivalState 和 LevelUpChoices 都不反向驱动服务器。
        for player in run.active_players():
            state = self.room.get_survival_player(player.entity_id)
            if state is not None:
                self._queue_broadcast("SurvivalState", {
                    "elapsed_seconds": run.elapsed,
                    "wave": run.wave,
                    "paused": run.paused,
                    "level": state.level,
                    "experience": state.experience,
                    "next_experience": state.next_experience,
                })
                queues = run.pending_rewards.get(player.entity_id, [])
                if queues:
                    self._queue_broadcast("LevelUpChoices", {
                        "player_id": player.entity_id,
                        "reward_ids": [c.reward_id for c in queues[0]],
                        "labels": [c.label for c in queues[0]],
                    })

        # ② 木桩回血
        stakes = self.room.get_stakes()
        for stake in stakes:
            stake_combat = self.room.get_combat(stake.entity_id)
            if stake_combat and stake_combat.cur_hp < stake_combat.max_hp:
                stake_combat.cur_hp = stake_combat.max_hp
                self._queue_broadcast("HpChanged", {
                    "entity_id": stake.entity_id,
                    "cur_hp": stake_combat.max_hp,
                    "damage": 0,
                    "attacker_id": "",
                    "atk_id": 0,
                    "atk_shape_idx": 0,
                })

        # ③ 敌人 AI tick(内部调 apply_move_dir 改方向,apply_facing 改朝向)
        self.room.get_enemy_manager().update(dt, self.room)
        # 脏敌人 = 朝向变化了的敌人(用于 PlayerFacing 广播)
        # 注:位置变化不在 dirty 里(apply_move_dir 不再推进位移),
        # 位置变化由下面的 tick_movement 统一推进,通过 moved_entities 收集广播
        dirty_enemies = self.room.get_enemy_manager().pop_dirty_entities()

        # ④ ★ 持续移动推进:所有 moving=True 的实体每 tick 推进位移
        # 这是第三版移动模型的核心:服务端记住方向后每 tick 都推进,不依赖客户端输入是否到达
        # 解决了"丢 tick → 误差累积 → snap 拉回"的问题
        moved_ids = self.room.tick_movement(dt)
        moved_entities.update(moved_ids)
        self._tick_sequence += 1

        # ⑤ 收集广播
        # PlayerMove: 所有需要同步移动状态的实体(改方向 + 被持续推进 + 停止迁移)
        movement_entries = []
        for entity_id in moved_entities:
            info = self.room.get_entity(entity_id)
            if info is not None:
                movement_entries.append({
                    "entity_id": entity_id,
                    "x": info.x, "y": info.y,
                    "moving": info.moving
                })
        if movement_entries:
            broadcasts.append(("MovementBatch", {
                "tick": self._tick_sequence,
                "entries": movement_entries,
            }))
        # PlayerFacing: 朝向变化了的敌人
        for entity_id in dirty_enemies:
            info = self.room.get_entity(entity_id)
            if info is not None:
                broadcasts.append(("PlayerFacing", {
                    "entity_id": entity_id,
                    "facing": info.facing
                }))

        # ⑥ 统一广播
        for proto_name, proto_data in broadcasts:
            self._queue_broadcast(proto_name, proto_data)
        elapsed_ms = (time.perf_counter() - tick_start) * 1000.0
        warning_ms = float(config_loader.get_constant("SLOW_TICK_WARNING_MS", 50.0))
        if elapsed_ms >= warning_ms:
            enemy_mgr = self.room.get_enemy_manager()
            logger.warning("生存 tick 超时: %.2fms, 活跃敌人数=%d, 本tick A*=%d",
                           elapsed_ms, enemy_mgr.get_enemy_count(), enemy_mgr.astar_count_this_tick)

    def set_wallhack(self, entity_type: str, enabled: bool) -> None:
        """
        GM 指令入口:开启/关闭某类型实体的穿墙权限

        转发给 GameRoom.set_wallhack,tick_movement 推进位移时据此跳过地形阻挡。
        用法:
            server.set_wallhack("player", True)        # 玩家可穿墙(调试用)
            server.set_wallhack("enemy_slime", False)   # 史莱姆恢复受阻挡

        为什么放 GameServer 而非 GameRoom:GameServer 是「外部入口层」(main/
        GM 工具/未来聊天指令都从这里进),GameRoom 是「纯状态层」不暴露给外部。
        """
        self.room.set_wallhack(entity_type, enabled)

    def _trigger_attack(self, attacker_id: str, atk_id: int) -> bool:
        """
        完整攻击发动流程(注册给 GameRoom 作为 attack_trigger 钩子)

        由 GameRoom.trigger_attack 转调,玩家(经 pending_inputs→_process_tick)和
        敌人(AI 状态机直接调 room.trigger_attack)走同一条路,避免敌人 AI 直接调
        apply_attack_start 导致"只改状态不发动"的问题。

        流程:
            1. apply_attack_start 改状态(设 state="attacking"),失败直接返回 False
            2. 广播 AttackStart
            3. 遍历 atk_id 的 shape_list,为每个 shape 注册 AttackTimer:
               - hit_time 到 → hit_cb:算命中 + apply_hurt + 广播 AttackHit/HpChanged
               - duration 到 → end_cb:apply_attack_end + 广播 AttackEnd

        Returns:
            True 表示攻击已发起(state 已变更为 attacking);
            False 表示被拒绝(实体不存在/不能攻击/状态锁定/已在攻击中)
        """
        if not self.room.apply_attack_start(attacker_id, atk_id):
            return False

        # 塞队列不阻塞 tick:AttackStart 广播由 _sender_loop 异步发出
        self._queue_broadcast("AttackStart", {
            "entity_id": attacker_id,
            "atk_id": atk_id
        })
        config = config_loader.get_attack_config(atk_id)
        if config:
            # 闭包陷阱修复:for 循环里定义 async def hit_cb 会捕获 shape 这个
            # 循环变量,所有 hit_cb 实际都会用循环结束时的最后一个 shape 值。
            # 用默认参数把当前 shape 绑定到 hit_cb 的局部作用域,绕开陷阱。
            # (当前 ATTACK_CONFIG[1002] 两个 shape 配置相同,触发不了;但配置不同会出 bug)
            for shape_idx, shape in enumerate(list(config.shape_list)):
                logger.info(f"实体 {attacker_id} 发起攻击 atk_id={atk_id}，形状 {shape.shape}")
                # hit_cb: 判定帧触发,调 GameRoom 算命中列表并广播
                # 命中判定逻辑在 game_room.get_attack_hits(状态层),不在网络层
                # 统一 Entity 模型:hit_list 里可能同时含玩家和木桩,统一调 apply_hurt
                # 注:hit_cb/end_cb 里也用 _queue_broadcast 而非 await broadcast——
                # timer 回调虽然是独立协程,但仍不应被 I/O 阻塞(回调链可能很长)
                async def hit_cb(_shape=shape, _shape_idx=shape_idx):
                    if self.room.survival_run.should_pause():
                        return
                    attacker_entity = self.room.get_entity(attacker_id)
                    if attacker_entity is not None and attacker_entity.ai_state == "returning":
                        return
                    hurt_list = self.room.get_attack_hits(_shape, attacker_id)
                    # 击退:只在连段的「最后一段」触发,把目标推出攻击范围。
                    # 动机:攻击间隔(583ms)比 hurt 硬直(666ms)短,不击退会被连击到死。
                    # 最后一段命中后目标被匀速推出 knockback_distance 像素,硬直结束时
                    # 已脱离下一击范围,被打的人有反击/逃跑的机会。
                    # 非最后一段不击退(避免连段中途把目标推开,反而打断连击)。
                    is_last_shape = (_shape_idx == len(config.shape_list) - 1)
                    knockback_distance = getattr(_shape, "knockback_distance", 0.0) if is_last_shape else 0.0
                    # 逐个调 apply_hurt 改状态(状态变更方法都是单玩家的,
                    # 遍历列表由调用方负责,保持原子性;apply_hurt 内部会查能力配置)
                    _hurt_duration = config_loader.get_hurt_duration_ms()
                    for hurt_id in hurt_list:
                        damage = self.room.get_attack_damage(attacker_id, atk_id, _shape_idx, hurt_id)
                        # apply_hurt 返回 HurtResult 枚举,区分 HURT/DEAD/FAILED
                        result = self.room.apply_hurt(hurt_id, atk_id, _shape_idx, damage, attacker_id)
                        if result == game_room.HurtResult.HURT:
                            # 没死:启 hurt timer(硬直)
                            # # 转向攻击者
                            # attacker_entity = self.room.get_entity(attacker_id)
                            # hurt_entity = self.room.get_entity(hurt_id)
                            # dir_x, dir_y = hurt_entity.x - attacker_entity.x, hurt_entity.y - attacker_entity.y
                            # facing = ai_state_helper.get_facing_by_vector2((dir_x, dir_y))
                            # self.room.apply_facing(hurt_id, facing)
                            self.timer_mgr.start_hurt(hurt_id, _hurt_duration, self.get_hurt_end_callback(hurt_id, attacker_id, atk_id, _hurt_duration))
                            # 连段最后一段命中:应用击退(硬直期间被匀速推出)
                            # 死亡(DEAD)不击退——尸体不该滑走
                            if knockback_distance > 0:
                                self.room.apply_knockback(hurt_id, attacker_id, knockback_distance)
                        elif result == game_room.HurtResult.DEAD:
                            # 死亡回调同时驱动 Run 结算或经验球事件；实体的延迟移除
                            # 仍交给既有 timer，避免客户端在死亡动画前丢失实体。
                            # 死亡:启 dead timer(延迟移除实体,让客户端播死亡动画)
                            # 取死亡者类型的死亡动画时长(从 entity_config 查)
                            dead_entity = self.room.get_entity(hurt_id)
                            if dead_entity is not None:
                                _dead_duration = config_loader.get_dead_duration_ms(dead_entity.entity_type)
                                self.timer_mgr.start_dead(hurt_id, _dead_duration, self.get_dead_end_callback(hurt_id, attacker_id, atk_id))
                            # 广播 EntityDead(客户端切 DeadState 播死亡动画)
                            self._queue_broadcast("EntityDead", {
                                "entity_id": hurt_id,
                                "attacker_id": attacker_id,
                                "atk_id": atk_id,
                            })
                            if dead_entity is not None and dead_entity.entity_type == "player":
                                self.room.survival_run.on_player_dead(hurt_id)
                                if self.room.survival_run.ended:
                                    self._queue_broadcast("SurvivalResult", self.room.survival_run.result())
                            elif dead_entity is not None:
                                orb = self.room.survival_run.on_enemy_dead(hurt_id, attacker_id)
                                if orb is not None:
                                    self._queue_broadcast("ExperienceOrb", {
                                        "orb_id": orb.entity_id, "x": orb.x,
                                        "y": orb.y, "value": orb.value,
                                    })
                        # FAILED:实体不存在/不能被攻击/无战斗组件,不做任何后续(防御性,get_attack_hits 已过滤)
                        # 广播 HpChanged(含 damage 给飘字,cur_hp 给血条)
                        # cur_hp 从 combat 取(apply_hurt 已扣过血)
                        hurt_combat = self.room.get_combat(hurt_id)
                        self._queue_broadcast("HpChanged", {
                            "entity_id": hurt_id,
                            "cur_hp": hurt_combat.cur_hp if hurt_combat else 0,
                            "damage": damage,
                            "attacker_id": attacker_id,
                            "atk_id": atk_id,
                            "atk_shape_idx": _shape_idx,
                        })

                    # 塞队列不阻塞 timer 回调
                    self._queue_broadcast("AttackHit", {
                        "attacker_id": attacker_id,
                        "hit_list": hurt_list,
                        "atk_id": atk_id,
                        "hurt_duration": _hurt_duration,
                        "atk_shape_idx": _shape_idx,
                    })

                async def end_cb():
                    self.room.apply_attack_end(attacker_id, atk_id)
                    # 塞队列不阻塞 timer 回调
                    self._queue_broadcast("AttackEnd", {
                        "entity_id": attacker_id,
                    })

                self.timer_mgr.start_attack(attacker_id, shape.hit_time, shape.duration, hit_cb, end_cb)
        return True

    def get_hurt_end_callback(self, hurt_id: str, attacker_id: str, atk_id: int, hurt_duration: int):
        async def hurt_end():
            self.room.apply_hurt_end(hurt_id)
            # 塞队列不阻塞 timer 回调
            self._queue_broadcast("HurtEnd", {
                "attacker_id": attacker_id,
                "hurt_id": hurt_id,
                "atk_id": atk_id,
                "hurt_duration": hurt_duration,
            })
        return hurt_end

    def get_dead_end_callback(self, dead_id: str, attacker_id: str, atk_id: int):
        """
        构造死亡定时器到期回调

        DeadTimer 到期后调本回调:
            1. remove_entity 从 GameRoom 移除实体(状态层)
            2. 广播 EntityRemove 通知客户端 queue_free 节点

        和 get_hurt_end_callback 的区别:
            - hurt_end: apply_hurt_end 恢复 state=idle(实体还在)
            - dead_end: remove_entity(实体消失)
        """
        async def dead_end():
            # 实体可能已被 cleanup_player 移除(断连清理),幂等处理
            if not self.room.has_entity(dead_id):
                return
            self.room.remove_entity(dead_id)
            self._queue_broadcast("EntityRemove", {
                "entity_id": dead_id,
            })
        return dead_end
        

    async def cleanup_player(self, player_id: str):
        """
        玩家断开连接时清理资源

        清理三步,对应三份状态:
            1. 会话/传输层状态(self.sessions / self.players):删引用
            2. 攻击定时器(self.timer_mgr):取消该玩家所有未完成的攻击定时器
            3. 游戏状态(self.room):调 remove_entity
        三份状态必须同步清理,否则会出现:
            - 连接已断但状态还在 → 幽灵玩家
            - 定时器没取消 → 回调对已删除实体 apply_attack_end/broadcast 报错
        """
        # 1. 会话/传输层:删除连接引用
        if player_id in self.sessions:
            del self.sessions[player_id]
        if player_id in self.players:
            del self.players[player_id]

        # 2. 攻击定时器:取消该玩家所有未完成的攻击
        # 必须在 remove_entity 之前——否则定时器回调可能对已删除实体操作状态
        # cancel 是幂等的,玩家没有定时器时静默返回
        self.timer_mgr.cancel(player_id)

        # 3. 游戏状态:从房间移除
        # remove_entity 返回被移除的 EntityInfo(用于取名字做日志),
        # 实体不存在时返回 None(幂等,详见 game_room.py 的 remove_entity 文档)。
        removed = self.room.remove_entity(player_id)
        if removed is not None:
            # dataclass 用点访问而非 dict 的 .get()
            player_name = removed.player_name or "未知"
            logger.info(f"玩家 {player_name} (ID: {player_id}) 离开游戏")

            # 广播玩家离开房间消息给其他房间内玩家
            # 注意:这里广播的是"事件"(LeaveRoom),不是"快照"(GameState)。
            # 客户端收到后从本地镜像里删掉该实体。这是当前混合模型的体现。
            # 走发送队列,和 tick 广播一致(避免 cleanup_player 被一条慢消息阻塞)
            self._queue_broadcast("LeaveRoom", {"entity_id": player_id})

    # ------------------------------------------------------------------
    # Windows 定时器提频
    # ------------------------------------------------------------------
    # Windows 默认定时粒度约 15.6ms,asyncio.sleep(0.033) 实际约 47ms 才醒,
    # tick 率从 30Hz 掉到约 21Hz:
    #   - pending 输入排队等 tick 的延迟变长(变向时服务端滞后更久,客户端对账易误判)
    #   - tick 间隔抖动大,位移步长不均匀
    # timeBeginPeriod(1) 把系统定时粒度提到 1ms,sleep 精度接近 1ms,tick 节奏稳定。
    # 实测 dt(见 _tick_loop)保证移速不受 tick 率影响,提频是让它"又快又稳"的补充。
    # 非 Windows 平台定时粒度本身约 1ms,无需处理。

    def _enable_high_timer_resolution(self) -> None:
        """Windows 下把系统定时粒度提到 1ms(timeBeginPeriod),其他平台跳过"""
        if sys.platform != "win32":
            return
        try:
            import ctypes
            # winmm.timeBeginPeriod(1):请求 1ms 定时粒度,进程级生效
            if ctypes.windll.winmm.timeBeginPeriod(1) == 0:  # 0 = TIMERR_NOERROR
                self._timer_resolution_raised = True
                logger.info("Windows 定时粒度已提升到 1ms(timeBeginPeriod)")
            else:
                logger.warning("timeBeginPeriod(1) 请求被拒绝,定时粒度保持系统默认")
        except Exception as e:
            # 提频失败不阻断启动:实测 dt 已保证移速正确,只是 tick 节奏粗一些
            logger.warning(f"定时器提频失败,使用系统默认粒度: {e}")

    def _restore_timer_resolution(self) -> None:
        """对称释放 timeBeginPeriod(timeEndPeriod),只在成功提频过时调用"""
        if sys.platform != "win32" or not self._timer_resolution_raised:
            return
        try:
            import ctypes
            ctypes.windll.winmm.timeEndPeriod(1)
            self._timer_resolution_raised = False
        except Exception as e:
            logger.warning(f"定时粒度恢复失败: {e}")

    async def start(self):
        self.is_running = True
        self._loop = asyncio.get_running_loop()
        logger.info(f"游戏服务器启动，监听 {self.host}:{self.port}")
        logger.info(f"已注册的处理器: {list(self.bus.list_handlers().keys())}")

        # Windows 定时器提频(仅 win32 生效):让 asyncio.sleep 精度接近 1ms
        self._enable_high_timer_resolution()

        # 启动 tick 循环(和 websocket serve 并行,asyncio 单线程交替执行)
        self._tick_task = asyncio.create_task(self._tick_loop())

        async with websockets.serve(self.handle_client, self.host, self.port):
            logger.info("服务器正在运行，按 Ctrl+C 停止")
            await asyncio.Future()  # 永久运行

    def stop(self):
        self.is_running = False
        # 取消 tick 循环(is_running=False 后 _tick_loop 的 while 循环会退出,
        # 但 cancel 确保即使正在 await asyncio.sleep 也能立即取消)
        # _tick_loop 的 finally 会连带取消 _sender_task,这里不用单独 cancel sender
        if self._tick_task and not self._tick_task.done():
            self._tick_task.cancel()
        # 对称恢复系统定时粒度(start 里 timeBeginPeriod 过的话)
        self._restore_timer_resolution()
        logger.info("服务器停止中...")


# handler 注册已移到 server/game/handlers/ 下:
#   - game/handlers/__init__.py: register_all(server) 统一入口
#   - game/handlers/player_handlers.py: EnterRoom/PlayerMove/PlayerFacing/LeaveRoom
#   - game/handlers/chat_handlers.py: ChatMessage/Heartbeat
# main.py 调 handlers.register_all(server) 完成注册
# 这样网络层(web_server.py)和业务逻辑层(handlers/)职责分离
