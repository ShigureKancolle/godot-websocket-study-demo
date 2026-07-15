# coding=utf-8

"""
文件: server/game/handlers/player_handlers.py
作用: 玩家相关消息处理器(PlayerJoin/PlayerMove/PlayerFacing/PlayerLeave)

============================================================================
 架构位置
============================================================================
    WebSocket 收到 bytes
        ↓
    MessageBus.dispatch (反序列化+路由)
        ↓
    本文件的 handler     ← 业务逻辑层
        ↓
    GameRoom.apply_xxx   ← 状态变更(唯一改状态的地方)
        ↓
    server.broadcast      ← 广播(网络层)

handler 通过闭包捕获 server 实例访问 room/bus/broadcast/add_pending_input,
不依赖模块级全局变量——这样热更时重新 import + 重新 register 能拿到新代码。

============================================================================
 tick 分流
============================================================================
PlayerMove / PlayerFacing(高频输入):存 pending,等 tick 统一处理。
    - 同一 tick 内同动作多次输入只保留最后一次(覆盖=节流)
    - 客户端 60Hz 发 → 服务端 30Hz 处理
    - handler 不调 apply_move/apply_facing,也不调 broadcast

PlayerJoin / PlayerLeave(低频事件):立即处理,不走 tick。
    - 加入/离开是即时事件,不该等 tick 增加延迟
    - handler 直接调 room.add_player / remove_player + broadcast
"""

import time
import logging

logger = logging.getLogger(__name__)


def register(server) -> None:
    """
    注册玩家相关 handler 到 server.bus

    Args:
        server: GameServer 实例,handler 通过闭包捕获它
    """
    bus = server.bus

    @bus.onproto("PlayerJoin")
    async def on_player_join(data: dict, ctx):
        """处理玩家加入——低频事件,立即处理,不走 tick"""
        player_info = data.get("player_info", {})

        # add_player 内部会复制字典 + 强制覆盖 player_id 为 ctx.player_id(不变式)
        stored = server.room.add_player(ctx.player_id, player_info)

        logger.info(f"玩家 {stored.get('player_name', '未知')} (ID: {ctx.player_id}) 加入游戏")

        # 广播 PlayerJoin 给所有人(含新玩家自己)
        # 为什么不 exclude 新玩家: 新玩家需要从 PlayerJoin 里提取自己被分配的 player_id
        #   (见客户端 StateMirror._on_player_join 和 MessageBus._on_player_join)。
        # 和 PlayerMove 的对比: PlayerMove 是「转发」,PlayerJoin 是「通知」——两者语义不同。
        await server.broadcast("PlayerJoin", {"player_info": stored})

        # 给「新玩家」发当前完整状态快照(GameState),让它知道房间里都有谁
        players_list = server.room.snapshot()
        await bus.send("GameState", {
            "players": players_list,
            "timestamp": int(time.time() * 1000)
        }, websocket=ctx.websocket)

    @bus.onproto("PlayerMove")
    async def on_player_move(data: dict, ctx):
        """处理玩家移动——高频输入,存入 pending,等 tick 统一处理"""
        # 玩家不在房间就忽略:可能是未加入就发移动,或已离开(网络消息乱序)
        if not server.room.has_player(ctx.player_id):
            return

        # 存入 pending,不立即 apply_move 也不立即广播
        # tick 机制:同一 tick 内多次 PlayerMove 只保留最后一次(覆盖)
        # 这把客户端 60Hz 的输入节流到服务端 30Hz 的处理
        server.add_pending_input(ctx.player_id, "move", {
            "x": data.get("x", 0),
            "y": data.get("y", 0),
            "speed": data.get("speed", 1.0),
            "moving": data.get("moving", False),
        })

    @bus.onproto("PlayerFacing")
    async def on_player_facing(data: dict, ctx):
        """处理玩家朝向——高频输入,存入 pending,等 tick 统一处理"""
        # 玩家不在房间就忽略(和 on_player_move 一致的容错策略)
        if not server.room.has_player(ctx.player_id):
            return

        # 存入 pending,不立即 apply_facing 也不立即广播
        # 和 PlayerMove 一样走 tick 节流
        server.add_pending_input(ctx.player_id, "facing", {
            "facing": data.get("facing", 0.0),
        })

    # 注意: PlayerLeave 不是客户端主动发的,是 cleanup_player 触发的广播
    # 所以这里不注册 PlayerLeave handler
    # (cleanup_player 在 web_server.py 里直接调 broadcast("PlayerLeave", ...))
