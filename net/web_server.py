# coding=utf-8

"""
WebSocket 游戏服务器核心模块
使用 MessageBus 单例进行消息收发，业务代码只处理字典，不接触 protobuf

本文件只定义类和 handler 注册函数，不产生模块级副作用（不创建实例、不注册 handler）。
实例创建和 handler 注册由 main.py 负责——这样 import 本模块不会有副作用，
便于测试和未来热更（热更时重新 import 不会重复创建实例）。
"""

import asyncio
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
# game_pb2 是生成代码，由 message_bus 内部加入 sys.path，这里直接 import
import game_pb2

logger = logging.getLogger(__name__)


class GameServer:
    # tick 频率:30Hz(每 33ms 一个 tick)
    # 为什么 30Hz:
    #   - 60Hz 流畅但带宽/CPU 消耗大,2D 学习项目没必要
    #   - 20Hz 动作游戏会感觉略卡,攻击朝向不跟手
    #   - 30Hz 主流平衡点,MOBA/ARPG 常用
    TICK_HZ: float = 30.0
    TICK_INTERVAL: float = 1.0 / TICK_HZ  # 0.0333 秒

    def __init__(self, host: str = "0.0.0.0", port: int = 8765, bus=None):
        self.host = host
        self.port = port

        # 消息总线：由外部传入（main.py 创建），避免本模块创建单例的副作用
        # 如果没传，用 MessageBus 单例（兼容旧用法）
        self.bus = bus if bus is not None else message_bus.MessageBus()

        # 玩家连接表：player_id -> websocket
        # 这是「传输层」状态：谁连着、往哪个 socket 发数据。
        # 与游戏状态（玩家坐标/等级）分开存放，因为它们的变更时机不同：
        #   - 连接在 handle_client 开始/结束时变更
        #   - 游戏状态在收到 PlayerMove 等消息时变更
        self.players: Dict[str, websockets.WebSocketServerProtocol] = {}

        # 游戏状态持有者：所有玩家信息（坐标、等级、分数）都由它管理。
        # 重构前这里是 self.player_infos 字典，handler 直接读写它。
        # 现在统一收口到 GameRoom，handler 只能通过 room.add_player / apply_move 等方法变更状态。
        # 这样状态变更规则只有一处定义，避免双端重复（详见 game_room.py 文档）。
        # 用 game_room.GameRoom() 而非 GameRoom()，热更见文件头注释
        self.room = game_room.GameRoom()
        self.timer_mgr = timer_mgr.TimerManager()

        self.is_running = False

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
        self._sender_task = None

    async def handle_client(self, websocket: websockets.WebSocketServerProtocol):
        """处理单个客户端连接

        注意：websockets 13.0+ 版本不再传 path 参数，如需路径可从 websocket.request.path 获取
        """
        async with websocket:
            # entity_id 统一带类型前缀(见 game_room.py 的统一 Entity 模型说明)
            # player: 前缀区分玩家和木桩等实体,避免 ID 撞名,调试时一眼看出类型
            player_id = f"player:{uuid.uuid4()}"
            logger.info(f"新客户端连接，分配玩家ID: {player_id}")

            # 构造消息上下文，后续所有消息分发都带上它
            # MessageContext 定义在 message_bus 模块里，用 message_bus.MessageContext 访问
            ctx = message_bus.MessageContext(websocket=websocket, player_id=player_id, is_server=True)

            try:
                # 等待客户端的第一条消息（应该是 PlayerJoin）
                first_message = await websocket.recv()

                # 直接用 bus 分发，handler 里会处理加入逻辑
                # 注意：第一条消息需要特殊处理，先解析判断是否是 PlayerJoin
                game_msg = game_pb2.GameMessage()
                game_msg.ParseFromString(first_message)

                if not game_msg.HasField('player_join'):
                    logger.warning(f"玩家 {player_id} 第一条消息不是加入消息，断开连接")
                    return

                # 保存连接信息（在 handler 之前，因为 handler 里要用）
                self.players[player_id] = websocket

                # 分发第一条消息（触发 on_player_join）
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
                        logger.error(f"处理玩家 {player_id} 消息时出错: {e}")
                        break

            except Exception as e:
                logger.error(f"处理客户端 {player_id} 时出错: {e}")

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
                await self.bus.send(protoname, protoprama, websocket=ws)
            except Exception as e:
                logger.error(f"向玩家 {pid} 发送消息失败: {e}")
                disconnected.add(pid)

        for pid in disconnected:
            await self.cleanup_player(pid)

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
        self._send_queue.put_nowait((protoname, protodata))

    async def _sender_loop(self) -> None:
        """发送协程:独立运行,从队列取消息调 broadcast 发出

        为什么需要独立协程:
            _process_tick 里如果 await self.broadcast(...),tick 间隔会被 I/O 时间拉长。
            改成塞队列后,tick 只做状态计算(微秒级),broadcast 在本协程里慢慢发。
            某个玩家网络慢只影响本协程,不影响 tick 节奏。

        积压处理:
            队列可能积压(tick 产生消息比 sender 发得快)。
            这没关系——sender 会按 FIFO 顺序慢慢发,客户端最终收到最新状态。
            如果积压严重,说明带宽不足或玩家太多,需要优化广播内容(如 delta 压缩)。

        错误处理:
            单条消息发送失败不退出循环,记日志继续发下一条。
            broadcast 内部已有失败玩家的 cleanup 逻辑。
        """
        logger.info("sender 协程启动")
        while self.is_running:
            try:
                protoname, protodata = await self._send_queue.get()
                await self.broadcast(protoname, protodata)
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"sender_loop 发送消息出错: {e}")
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
    #   - PlayerJoin / PlayerLeave / ChatMessage(低频事件)→ 不走 tick,立即处理
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
        tick 循环:每 TICK_INTERVAL 秒处理一次 pending

        asyncio 单线程事件循环:tick_loop 和 handle_client 在同一线程,
        通过 await 切换执行。pending_inputs 不需要锁——
        handler 存入 pending 时不会 await(原子执行),不会在存入中途被 tick 打断。

        为什么 tick 间隔严格 30Hz:
            tick 循环里不再有 await self.broadcast(...)(那会因网络 I/O 拉长间隔)。
            tick 只做状态计算(apply_move 等,纯内存微秒级)+ 塞队列(put_nowait 不阻塞)。
            真正的广播在 _sender_loop 独立协程里发,不影响 tick 节奏。
        """
        logger.info(f"tick 循环启动,频率 {self.TICK_HZ}Hz")
        # 启动 sender 协程:tick 只算状态+塞队列,sender 负责真正发
        # tick 和 sender 通过 _send_queue 解耦,互不阻塞
        self._sender_task = asyncio.create_task(self._sender_loop())
        try:
            while self.is_running:
                await asyncio.sleep(self.TICK_INTERVAL)
                await self._process_tick()
        finally:
            # tick 退出时必须连带取消 sender,否则 sender 会永远阻塞在 queue.get()
            if self._sender_task and not self._sender_task.done():
                self._sender_task.cancel()
                try:
                    await self._sender_task
                except asyncio.CancelledError:
                    pass
        logger.info("tick 循环已停止")

    async def _process_tick(self) -> None:
        """
        处理一个 tick 的 pending 输入

        流程:
            1. 取出并清空 pending(下一 tick 重新收集)
            2. 遍历 pending,调 GameRoom.apply_move / apply_facing 更新状态
            3. 收集本 tick 要广播的消息
            4. 统一广播

        为什么不把 pending 直接传给 GameRoom:
            GameRoom 是纯状态层,不该知道 tick/pending 的存在。
            tick 协调逻辑留在 GameServer,GameRoom 只在被调 apply_xxx 时改状态。
            这保持了状态层与传输层的解耦。
        """
        # 取出并清空(下一 tick 重新收集新的输入)
        pending = self._pending_inputs
        self._pending_inputs = {}

        if not pending:
            return  # 本 tick 无输入,空转

        # 收集本 tick 要广播的消息:List[(protoname, protodata)]
        broadcasts = []
        for entity_id, inputs in pending.items():
            # 实体可能已离开(tick 间隔内断连),跳过
            if not self.room.has_entity(entity_id):
                continue

            # 处理移动输入
            if "move" in inputs:
                m = inputs["move"]
                # 检查 apply_xxx 返回值:只有状态真的改了才广播
                # (apply_move 可能因 hurt 硬直/能力不足返回 False,此时广播会让其他客户端
                #  收到"X 在移动"但 X 实际没动,造成状态矛盾)
                if self.room.apply_move(entity_id, m["x"], m["y"], m["speed"], m["moving"]):
                    broadcasts.append(("PlayerMove", {
                        "entity_id": entity_id,
                        "x": m["x"], "y": m["y"], "speed": m["speed"],
                        "moving": m["moving"]
                    }))

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
                attacker_id = a["entity_id"]
                if self.room.apply_attack_start(attacker_id, a["atk_id"]):
                    # 塞队列不阻塞 tick:AttackStart 广播由 _sender_loop 异步发出
                    self._queue_broadcast("AttackStart", {
                        "entity_id": attacker_id,
                        "atk_id": a["atk_id"]
                    })
                    config = game_room.ATTACK_CONFIG.get(a["atk_id"])
                    if config:
                        # 闭包陷阱修复:for 循环里定义 async def hit_cb 会捕获 shape 这个
                        # 循环变量,所有 hit_cb 实际都会用循环结束时的最后一个 shape 值。
                        # 用默认参数把当前 shape 绑定到 hit_cb 的局部作用域,绕开陷阱。
                        # (当前 ATTACK_CONFIG[1002] 两个 shape 配置相同,触发不了;但配置不同会出 bug)
                        for shape in list(config.shape_list):
                            logger.info(f"实体 {attacker_id} 发起攻击 atk_id={a['atk_id']}，形状 {shape.shape.value}")
                            # hit_cb: 判定帧触发,调 GameRoom 算命中列表并广播
                            # 命中判定逻辑在 game_room.get_attack_hits(状态层),不在网络层
                            # 统一 Entity 模型:hit_list 里可能同时含玩家和木桩,统一调 apply_hurt
                            # 注:hit_cb/end_cb 里也用 _queue_broadcast 而非 await broadcast——
                            # timer 回调虽然是独立协程,但仍不应被 I/O 阻塞(回调链可能很长)
                            async def hit_cb(_shape=shape):
                                hurt_list = self.room.get_attack_hits(_shape, attacker_id)
                                # 逐个调 apply_hurt 改状态(状态变更方法都是单玩家的,
                                # 遍历列表由调用方负责,保持原子性;apply_hurt 内部会查能力配置)
                                for hurt_id in hurt_list:
                                    self.room.apply_hurt(hurt_id, a["atk_id"])
                                    self.timer_mgr.start_hurt(hurt_id, game_room.HURT_DURATION_MS, self.get_hurt_end_callback(hurt_id, attacker_id, a["atk_id"], game_room.HURT_DURATION_MS))
                                # 塞队列不阻塞 timer 回调
                                self._queue_broadcast("AttackHit", {
                                    "attacker_id": attacker_id,
                                    "hit_list": hurt_list,
                                    "atk_id": a["atk_id"],
                                    "hurt_duration": game_room.HURT_DURATION_MS
                                })

                            async def end_cb():
                                self.room.apply_attack_end(attacker_id, a["atk_id"])
                                # 塞队列不阻塞 timer 回调
                                self._queue_broadcast("AttackEnd", {
                                    "entity_id": attacker_id,
                                })

                            self.timer_mgr.start_attack(attacker_id, shape.hit_time, shape.duration, hit_cb, end_cb)


        # 统一塞队列:一个 tick 内所有变更的消息按顺序发出
        # 注意:这里不 exclude 任何人——状态变更广播必须包含发起者
        # (项目硬约束:所有状态变更广播必须包含发起客户端)
        # 注:改成 _queue_broadcast 后不再 await,tick 立即完成,广播在 _sender_loop 里发
        for proto_name, proto_data in broadcasts:
            self._queue_broadcast(proto_name, proto_data)

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
        

    async def cleanup_player(self, player_id: str):
        """
        玩家断开连接时清理资源

        清理三步,对应三份状态:
            1. 传输层状态(self.players 连接表):删 websocket 引用
            2. 攻击定时器(self.timer_mgr):取消该玩家所有未完成的攻击定时器
            3. 游戏状态(self.room):调 remove_entity
        三份状态必须同步清理,否则会出现:
            - 连接已断但状态还在 → 幽灵玩家
            - 定时器没取消 → 回调对已删除实体 apply_attack_end/broadcast 报错
        """
        # 1. 传输层:删除连接引用
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

            # 广播玩家离开消息给其他人
            # 注意:这里广播的是"事件"(PlayerLeave),不是"快照"(GameState)。
            # 客户端收到后从本地镜像里删掉该实体。这是当前混合模型的体现。
            # 走发送队列,和 tick 广播一致(避免 cleanup_player 被一条慢消息阻塞)
            self._queue_broadcast("PlayerLeave", {"entity_id": player_id})

    async def start(self):
        self.is_running = True
        logger.info(f"游戏服务器启动，监听 {self.host}:{self.port}")
        logger.info(f"已注册的处理器: {list(self.bus.list_handlers().keys())}")

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
        logger.info("服务器停止中...")


# handler 注册已移到 server/game/handlers/ 下:
#   - game/handlers/__init__.py: register_all(server) 统一入口
#   - game/handlers/player_handlers.py: PlayerJoin/PlayerMove/PlayerFacing
#   - game/handlers/chat_handlers.py: ChatMessage/Heartbeat
# main.py 调 handlers.register_all(server) 完成注册
# 这样网络层(web_server.py)和业务逻辑层(handlers/)职责分离
