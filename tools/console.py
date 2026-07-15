# coding=utf-8

"""
文件: server/tools/console.py
作用: 交互式 Python 控制台——运行时调试服务器状态、发消息、触发热更

============================================================================
 为什么从 web_server.py 移到这里
============================================================================
之前 start_console 写在 net/web_server.py 里，但它和 WebSocket 服务逻辑无关：
    - web_server.py 的职责是「连接管理 + handler 注册」，是网络层
    - start_console 的职责是「运行时调试入口」，是工具层

混在一起的问题：
    1. web_server.py 越来越长，职责不清
    2. 控制台的依赖（热更模块、便捷函数）和网络层耦合
    3. 热更 reload(web_server) 时会重新加载 start_console 代码——没必要

移到 tools/console.py 后：
    - web_server.py 只管网络层，console.py 只管调试入口
    - 控制台依赖的 hotreload/game_pb2 在这里 import，不污染网络层
    - 热更 reload(web_server) 时不会连带重载控制台代码（控制台不需要热更）

============================================================================
 控制台的工作方式
============================================================================
控制台跑在独立线程（由 main.py 创建 daemon 线程），不阻塞 asyncio 事件循环。
需要调用服务器的协程时（如 broadcast），用 run_coroutine_threadsafe 把任务
投递回主事件循环执行。

注入的可用变量：
    server        - 服务器实例（可查看 players 连接表、room 状态）
    bus           - 消息总线
    game_pb2      - protobuf 模块
    broadcast()   - 广播消息给所有玩家（便捷封装）
    send_to()     - 向指定玩家发送消息（便捷封装）
    kick()        - 踢出玩家
    reload()      - 热更（reload 业务模块 + 重新注册 handler）
    hot_status()  - 查看热更状态
    players       - 在线玩家连接表
    room          - 游戏状态持有者
    state()       - 返回所有玩家信息快照
"""

import asyncio
import code
import logging

# 项目模块用 import xxx + xxx.def 访问，不用 from xxx import def
# 原因：热更约束（详见 net/web_server.py 文件头注释）
# 控制台本身不参与热更（它是工具，改完重启即可），但它调用的模块走热更约束
import tools.hotreload as hotreload
# game_pb2 是生成代码，由 message_bus 内部加入 sys.path，这里直接 import
import game_pb2

logger = logging.getLogger(__name__)


def start_console(server_instance, bus_instance, loop):
    """
    启动交互式 Python 控制台（在单独线程中运行）

    Args:
        server_instance: GameServer 实例
        bus_instance: MessageBus 实例
        loop: asyncio 事件循环（用于 run_coroutine_threadsafe 投递协程）
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

    def reload():
        """热更：reload 所有业务模块并重新注册 handler

        改完 .py 代码后，在控制台敲 reload() 即可生效，连接不中断。
        能热更：handler 逻辑、新增/删除 handler、handler 调 GameRoom 的方式
        不能热更：GameRoom/GameServer/MessageBus 类的方法实现（需重启）
        详见 tools/hotreload.py 文件头注释。
        """
        return hotreload.reload_all(server_instance)

    def hot_status():
        """查看热更状态：监听模块、已注册 handler、在线玩家数"""
        hotreload.print_status(server_instance)

    namespace = {
        'server': server_instance,
        'bus': bus_instance,
        'game_pb2': game_pb2,
        'broadcast': broadcast,
        'send_to': send_to,
        'kick': kick,
        # 热更命令（详见 tools/hotreload.py）
        'reload': reload,
        'hot_status': hot_status,
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
   reload()                 - 热更：reload 业务模块 + 重新注册 handler
   hot_status()             - 查看热更状态（监听模块、handler、玩家数）
   broadcast(name, dict)    - 广播消息给所有玩家
   send_to(pid, name, dict) - 向指定玩家发送消息
   kick(pid)                - 踢出玩家
   state()                  - 查看所有玩家信息快照
 示例:
   reload()                           # 改完代码后热更
   hot_status()                       # 查看热更状态
   len(players)                       # 查看在线连接数
   room.player_count()                # 查看房间内玩家数
   state()                            # 查看所有玩家详情
   room.get_player('<player_id>')     # 查看单个玩家
   broadcast('ChatMessage', {'content': '服务器公告'})  # 发公告
============================================================
"""

    console = code.InteractiveConsole(namespace)
    console.interact(banner=banner, exitmsg="控制台已退出")
