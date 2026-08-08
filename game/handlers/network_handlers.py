# coding=utf-8

"""
文件: server/game/handlers/network_handlers.py
作用: 网络层消息处理器(Ping/Pong 延迟探测)

============================================================================
 设计说明
============================================================================
Ping/Pong: 网络延迟探测(RTT 测量),不改游戏状态。
    - 客户端发 Ping(带 t = Time.get_ticks_msec())
    - 服务端收到后把 t 原样填进 Pong
    - 服务端把 Pong 单播回给「发 Ping 的那个玩家」(ctx.websocket)
    - 客户端收到 Pong 后用 now - t 算 RTT

关键点: Pong 必须单播,不能广播。
    - 广播会让所有客户端都收到 Pong,并按自己的 now - t 算 RTT
    - 但 t 是「别人发送的时刻」,算出来是错的(误测 RTT)
    - 所以用 ctx.websocket 单播回请求者本人

为什么不走发送队列(不塞 _send_queue):
    - Ping/Pong 是延迟测量,追求「最小延迟」的往返
    - 走队列会引入 sender 协程的排队延迟,测出来的 RTT 偏大
    - 所以直接 await bus.send 立即发,和 ChatMessage 的低频即时处理一致
"""

import logging

logger = logging.getLogger(__name__)


def register(server) -> None:
    """
    注册网络层 handler 到 server.bus

    Args:
        server: GameServer 实例,handler 通过闭包捕获它
    """
    bus = server.bus

    @bus.onproto("Ping")
    async def on_ping(data: dict, ctx):
        """处理 Ping 延迟探测——把 t 原样填进 Pong,单播回给请求者本人"""
        t = data.get("t", 0)
        logger.debug(f"玩家 {ctx.player_id} 发起 Ping(t={t}),回 Pong")

        # 单播回给发 Ping 的玩家(ctx.websocket 就是请求者的连接)
        # 不能广播——广播会让所有客户端按别人的 t 误算 RTT
        # 不走发送队列——延迟测量要最小化往返,直接立即发
        await bus.send("Pong", {"t": t}, websocket=ctx.websocket)
