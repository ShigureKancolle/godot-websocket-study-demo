# coding=utf-8

"""
文件: server/game/handlers/chat_handlers.py
作用: 聊天相关消息处理器(ChatMessage/Heartbeat)

============================================================================
 设计说明
============================================================================
ChatMessage: 双向消息,不改游戏状态(只广播)。
    - handler 取 player_name 署名后转发给所有人(含发送者回显)
    - 不走 tick:聊天是低频即时事件,不该等 tick 增加延迟

Heartbeat: 心跳保活,不改游戏状态,只记日志。
    - 服务端在 30 秒无消息时主动发 Heartbeat(见 web_server.handle_client 超时分支)
    - 客户端收到后原样回发 Heartbeat,这里只记 debug 日志确认存活
"""

import time
import logging

logger = logging.getLogger(__name__)


def register(server) -> None:
    """
    注册聊天相关 handler 到 server.bus

    Args:
        server: GameServer 实例,handler 通过闭包捕获它
    """
    bus = server.bus

    @bus.onproto("ChatMessage")
    async def on_chat_message(data: dict, ctx):
        """处理聊天消息——事件型,不改游戏状态,不走 tick"""
        session = server.sessions.get(ctx.player_id)
        if session is None:
            return

        player_name = session.get("player_name", "未知")
        chat_data = {
            "player_id": ctx.player_id,
            "player_name": player_name,
            "content": data.get("content", ""),
            "timestamp": int(time.time() * 1000)
        }
        logger.info(f"玩家 {player_name} 发送消息: {data.get('content')}")

        # 广播聊天消息给所有已登录客户端(包括发送者,让发送者也能看到自己发的消息回显)
        await server.broadcast_to_clients("ChatMessage", chat_data)

    @bus.onproto("Heartbeat")
    async def on_heartbeat(data: dict, ctx):
        """处理心跳消息——保活,只记日志"""
        logger.debug(f"收到玩家 {ctx.player_id} 的心跳")
