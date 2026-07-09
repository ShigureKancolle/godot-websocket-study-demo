# coding=utf-8

"""
WebSocket 游戏服务器主程序
使用 MessageBus 单例进行消息收发，业务代码只处理字典，不接触 protobuf
"""

import asyncio
import websockets
import uuid
import time
import argparse
import code
import threading
from typing import Dict, Set, Optional
import logging

# 项目模块用 import xxx + xxx.def 访问，不用 from xxx import def
# 原因：后续要支持 hotfix/hotreload。
#   from message_bus import MessageBus 会把 MessageBus 这个名字绑定到本模块命名空间，
#   热更时即使重新 import message_bus，已绑定的 MessageBus 仍指向旧类。
#   用 import message_bus + message_bus.MessageBus() 访问，每次走模块属性查找，
#   热更后重新加载模块就能拿到新类。
# 标准库和第三方库不热更，保留 from import 不受此约束。
import message_bus
import message_contract
import game_room
# game_pb2 是生成代码，也用 import 方式（虽然不会热更，但保持项目模块风格一致）
import game_pb2

# 配置日志系统
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# 获取全局消息总线单例
# 注意：这里用 message_bus.MessageBus() 而非直接 MessageBus()，
# 是为了热更时能拿到最新版本（见文件头注释）
bus = message_bus.MessageBus()

# 加载消息契约并设置入站校验钩子
# 必须在 handler 注册之前加载契约——虽然契约校验是运行时的，但启动时加载能尽早暴露问题
# （如契约文件格式错误，启动日志里立刻看到，不用等第一条消息进来）
contract = message_contract.MessageContract()
contract.load()  # 默认从 proto/messages.json 加载
bus.set_inbound_validator(contract.is_valid_inbound)


class GameServer:
    def __init__(self, host: str = "0.0.0.0", port: int = 8765):
        self.host = host
        self.port = port

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

        self.is_running = False

    async def handle_client(self, websocket: websockets.WebSocketServerProtocol):
        """处理单个客户端连接

        注意：websockets 13.0+ 版本不再传 path 参数，如需路径可从 websocket.request.path 获取
        """
        async with websocket:
            player_id = str(uuid.uuid4())
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
                await bus.dispatch(first_message, ctx)

                # 进入主循环，持续处理消息
                while self.is_running:
                    try:
                        message = await asyncio.wait_for(websocket.recv(), timeout=30.0)
                        # 所有消息都交给 bus 分发，handler 通过 @bus.onproto 注册
                        await bus.dispatch(message, ctx)

                    except asyncio.TimeoutError:
                        # 超时发心跳
                        logger.debug(f"玩家 {player_id} 超时，发送心跳")
                        await bus.send("Heartbeat", {"timestamp": int(time.time() * 1000)},
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
                await bus.send(protoname, protoprama, websocket=ws)
            except Exception as e:
                logger.error(f"向玩家 {pid} 发送消息失败: {e}")
                disconnected.add(pid)

        for pid in disconnected:
            await self.cleanup_player(pid)

    async def cleanup_player(self, player_id: str):
        """
        玩家断开连接时清理资源

        清理分两步，对应两份状态：
            1. 传输层状态（self.players 连接表）：删 websocket 引用
            2. 游戏状态（self.room）：调 remove_player
        两份状态必须同步清理，否则会出现「连接已断但状态还在」的幽灵玩家。
        """
        # 1. 传输层：删除连接引用
        if player_id in self.players:
            del self.players[player_id]

        # 2. 游戏状态：从房间移除
        # remove_player 返回被移除的玩家信息（用于取名字做日志），
        # 玩家不存在时返回 None（幂等，详见 game_room.py 的 remove_player 文档）。
        removed = self.room.remove_player(player_id)
        if removed is not None:
            player_name = removed.get("player_name", "未知")
            logger.info(f"玩家 {player_name} (ID: {player_id}) 离开游戏")

            # 广播玩家离开消息给其他人
            # 注意：这里广播的是「事件」(PlayerLeave)，不是「快照」(GameState)。
            # 客户端收到后从本地镜像里删掉该玩家。这是当前混合模型的体现。
            await self.broadcast("PlayerLeave", {"player_id": player_id})

    async def start(self):
        self.is_running = True
        logger.info(f"游戏服务器启动，监听 {self.host}:{self.port}")
        logger.info(f"已注册的处理器: {list(bus.list_handlers().keys())}")

        async with websockets.serve(self.handle_client, self.host, self.port):
            logger.info("服务器正在运行，按 Ctrl+C 停止")
            await asyncio.Future()  # 永久运行

    def stop(self):
        self.is_running = False
        logger.info("服务器停止中...")


# ==================== 消息处理器 ====================
# 使用 @bus.onproto 装饰器注册，函数参数是字典，完全屏蔽 protobuf

# 全局服务器实例（handler 里需要访问）
server = GameServer()


@bus.onproto("PlayerJoin")
async def on_player_join(data: dict, ctx: message_bus.MessageContext):
    """
    处理玩家加入

    重构后 handler 的职责收窄为三步（见 game_room.py 文档的架构图）：
        1. 从消息字典里取参数
        2. 调 GameRoom 方法变更状态
        3. 把结果通过 bus 广播出去
    handler 不再直接读写 player_infos，状态形状的细节交给 GameRoom。

    data 是字典，包含 player_info 等字段
    ctx 包含 websocket 和 player_id
    """
    player_info = data.get("player_info", {})

    # 2. 调 GameRoom 变更状态
    # add_player 内部会做两件事（见其文档）：
    #   - 复制字典避免外部引用污染状态
    #   - 强制覆盖 player_id 为服务器分配的 ctx.player_id（不变式）
    # 返回值 stored 就是真正存入房间的字典，后续广播应基于它而非原 player_info。
    stored = server.room.add_player(ctx.player_id, player_info)

    logger.info(f"玩家 {stored.get('player_name', '未知')} (ID: {ctx.player_id}) 加入游戏")

    # 3. 广播 PlayerJoin 给所有人（含新玩家自己）
    # 为什么不 exclude 新玩家: 新玩家需要从 PlayerJoin 里提取自己被分配的 player_id
    #   （见客户端 StateMirror._on_player_join 和 MessageBus._on_player_join）。
    #   新玩家发送 PlayerJoin 时带的 player_id 是自己填的（可能为空），
    #   服务端在 add_player 里用 ctx.player_id 覆盖了它——客户端必须收到这份回传，
    #   才能知道服务端分配的权威 ID 是什么。
    # 和 PlayerMove 的对比: PlayerMove 是「转发」（发送者已有状态，exclude 自己），
    #   PlayerJoin 是「通知」（服务端改写了 ID，必须回传给发送者）——两者语义不同。
    await server.broadcast("PlayerJoin", {"player_info": stored})

    # 给「新玩家」发当前完整状态快照（GameState），让它知道房间里都有谁
    # snapshot() 返回所有玩家的列表（浅拷贝），匹配 proto 的 repeated PlayerInfo 形状
    players_list = server.room.snapshot()
    await bus.send("GameState", {
        "players": players_list,
        "timestamp": int(time.time() * 1000)
    }, websocket=ctx.websocket)


@bus.onproto("PlayerMove")
async def on_player_move(data: dict, ctx: message_bus.MessageContext):
    """
    处理玩家移动

    这是「服务器权威」体现得最清楚的地方：
        客户端发来的 PlayerMove 是「输入请求」，不是「状态声明」。
        服务端收到后先调 apply_move 更新权威状态，再决定如何告诉其他客户端。
        客户端不能直接改自己的坐标并广播——那会绕过服务端校验。

    当前实现仍是混合模型（转发 PlayerMove 事件给其他人），
    纯快照模型应改为广播 GameState。详见 game_room.py 文档的「混合模型」章节。
    """
    # 玩家不在房间就忽略：可能是未加入就发移动，或已离开（网络消息乱序）
    if not server.room.has_player(ctx.player_id):
        return

    # 2. 调 GameRoom 变更状态
    # apply_move 内部直接落地目标坐标（简化模型）。
    # 未来要加碰撞校验/速度积分，只改 apply_move，这里一行不动。
    server.room.apply_move(
        ctx.player_id,
        data.get("x", 0),
        data.get("y", 0),
        data.get("speed", 1.0),
    )

    # 3. 广播移动事件给其他玩家
    # 为什么 exclude_player=ctx.player_id：
    #   发送者自己已经本地「以为」移过去了（客户端乐观更新），
    #   再回传 PlayerMove 会造成重复处理。这是事件模型的常规处理。
    #   纯快照模型下则要广播给所有人（含发送者）做对账，此处暂不切换。
    await server.broadcast("PlayerMove", {
        "player_id": ctx.player_id,
        "x": data.get("x", 0),
        "y": data.get("y", 0),
        "speed": data.get("speed", 1.0)
    }, exclude_player=ctx.player_id)


@bus.onproto("ChatMessage")
async def on_chat_message(data: dict, ctx: message_bus.MessageContext):
    """处理聊天消息

    聊天是「事件型」消息：不改变游戏状态（玩家坐标/等级），只是瞬时通信。
    所以这里不调 GameRoom 的变更方法，只读 player_name 来署名。
    """
    # 只读访问玩家信息：get_player 返回内部字典的引用，约定不改它
    info = server.room.get_player(ctx.player_id)
    if info is None:
        # 玩家不在房间，拒绝消息（防止未加入的连接发聊天）
        return

    player_name = info.get("player_name", "未知")

    chat_data = {
        "player_id": ctx.player_id,
        "player_name": player_name,
        "content": data.get("content", ""),
        "timestamp": int(time.time() * 1000)
    }

    logger.info(f"玩家 {player_name} 发送消息: {data.get('content')}")

    # 广播聊天消息给所有玩家（包括发送者，让发送者也能看到自己发的消息回显）
    await server.broadcast("ChatMessage", chat_data)


@bus.onproto("Heartbeat")
async def on_heartbeat(data: dict, ctx: message_bus.MessageContext):
    """处理心跳消息"""
    logger.debug(f"收到玩家 {ctx.player_id} 的心跳")


def start_console(server_instance, bus_instance, loop):
    """
    启动交互式 Python 控制台（在单独线程中运行）

    控制台跑在独立线程，不阻塞 asyncio 事件循环。
    需要调用服务器的协程时，用 run_coroutine_threadsafe 把任务投递回主事件循环。

    注入的可用变量：
        server        - 服务器实例（可查看 players 连接表、room 状态）
        bus           - 消息总线
        game_pb2      - protobuf 模块
        broadcast()   - 广播消息给所有玩家（便捷封装）
        send_to()     - 向指定玩家发送消息（便捷封装）
        players       - 在线玩家连接表（server.players 的快捷引用）
        room          - 游戏状态持有者（server.room 的快捷引用，用 room.snapshot() 看状态）
        state()       - 返回所有玩家信息快照的便捷函数
    """

    def broadcast(protoname: str, protoprama: dict):
        """同步广播：把协程投递到事件循环并等待结果"""
        future = asyncio.run_coroutine_threadsafe(
            server_instance.broadcast(protoname, protoprama), loop
        )
        return future.result(timeout=5)

    def send_to(player_id: str, protoname: str, protoprama: dict):
        """向指定玩家发送消息"""
        ws = server_instance.players.get(player_id)
        if ws is None:
            print(f"玩家 {player_id} 不在线")
            return
        future = asyncio.run_coroutine_threadsafe(
            bus_instance.send(protoname, protoprama, websocket=ws), loop
        )
        return future.result(timeout=5)

    def kick(player_id: str):
        """踢出指定玩家"""
        future = asyncio.run_coroutine_threadsafe(
            server_instance.cleanup_player(player_id), loop
        )
        return future.result(timeout=5)

    namespace = {
        'server': server_instance,
        'bus': bus_instance,
        'game_pb2': game_pb2,
        'broadcast': broadcast,
        'send_to': send_to,
        'kick': kick,
        # 连接表（传输层状态）：player_id -> websocket
        'players': server_instance.players,
        # 游戏状态持有者：用 room.snapshot() 看所有玩家，room.get_player(pid) 看单个
        'room': server_instance.room,
        # 便捷函数：返回当前所有玩家信息的快照列表（等同于 room.snapshot()）
        # 提供它是因为控制台里频繁要看状态，写 state() 比写 server.room.snapshot() 顺手
        'state': lambda: server_instance.room.snapshot(),
    }

    banner = """
============================================================
 游戏服务器交互式控制台
============================================================
 可用变量:
   server        - 服务器实例
   bus           - 消息总线
   players       - 在线玩家连接表 {player_id: websocket}
   room          - 游戏状态持有者（用 room.snapshot() 看所有玩家）
   game_pb2      - protobuf 模块
 可用函数:
   broadcast(name, dict)    - 广播消息给所有玩家
   send_to(pid, name, dict) - 向指定玩家发送消息
   kick(pid)                - 踢出玩家
   state()                  - 查看所有玩家信息快照
 示例:
   len(players)                       # 查看在线连接数
   room.player_count()                # 查看房间内玩家数
   state()                            # 查看所有玩家详情
   room.get_player('<player_id>')     # 查看单个玩家
   broadcast('ChatMessage', {'content': '服务器公告'})  # 发公告
============================================================
"""

    console = code.InteractiveConsole(namespace)
    console.interact(banner=banner, exitmsg="控制台已退出")


async def main():
    # 解析命令行参数
    parser = argparse.ArgumentParser(description="WebSocket 游戏服务器")
    parser.add_argument(
        '--console', action='store_true',
        help='开启交互式 Python 控制台（可在运行时查看状态、发送消息）'
    )
    args = parser.parse_args()

    # 如果指定了 --console，在单独线程启动交互式控制台
    if args.console:
        loop = asyncio.get_running_loop()
        console_thread = threading.Thread(
            target=start_console,
            args=(server, bus, loop),
            daemon=True  # 设为守护线程，主程序退出时自动结束
        )
        console_thread.start()
        logger.info("交互式控制台已启动（独立线程）")

    try:
        await server.start()
    except KeyboardInterrupt:
        logger.info("收到停止信号")
        server.stop()


if __name__ == "__main__":
    asyncio.run(main())