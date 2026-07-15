# coding=utf-8

"""
文件: server/game/handlers/__init__.py
作用: handler 模块统一入口

============================================================================
 为什么把 handler 从 web_server.py 拆出来
============================================================================
之前所有 handler 写在 web_server.py 里,导致网络层和业务逻辑混在一起:
    - web_server.py 既管 WebSocket 连接、tick 机制,又管玩家加入/移动/聊天等游戏规则
    - handler 是"业务逻辑"(属 game 层),不是"网络层"

拆分后:
    - web_server.py 只管网络层(连接、tick、broadcast 基础设施)
    - game/handlers/ 专注业务逻辑,按功能分文件(player/chat/...)
    - 新增 handler 类型时改对应文件,不用碰网络层

============================================================================
 调用方式
============================================================================
main.py 创建 GameServer 实例后:
    import game.handlers as handlers
    handlers.register_all(server)

register_all 会遍历所有子模块,调各自的 register(server)。
"""

# 项目模块用 import xxx as xxx,不用 from xxx import(热更约束)
import game.handlers.player_handlers as player_handlers
import game.handlers.chat_handlers as chat_handlers


def register_all(server) -> None:
    """
    注册所有 handler 到 server.bus

    在 main.py 创建 GameServer 实例后调用一次。
    热更时调 hotreload.reload_all() 也会重新调此函数,覆盖旧 handler。
    """
    player_handlers.register(server)
    chat_handlers.register(server)
