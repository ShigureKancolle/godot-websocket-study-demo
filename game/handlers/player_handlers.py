# coding=utf-8

"""
文件: server/game/handlers/player_handlers.py
作用: 玩家相关消息处理器(PlayerJoin/PlayerMove/PlayerFacing/PlayerLeave/AttackStart)

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
PlayerMove / PlayerFacing / AttackStart(高频输入):存 pending,等 tick 统一处理。
    - 同一 tick 内同动作多次输入只保留最后一次(覆盖=节流)
    - 客户端 60Hz 发 → 服务端 30Hz 处理
    - handler 不调 apply_move/apply_facing/apply_attack_start,也不调 broadcast

PlayerJoin / PlayerLeave(低频事件):立即处理,不走 tick。
    - 加入/离开是即时事件,不该等 tick 增加延迟
    - handler 直接调 room.add_entity / remove_entity + broadcast

============================================================================
 统一 Entity 模型(本次重构)
============================================================================
所有可交互物体都是 Entity,player_id 也是 entity_id(带 "player:" 前缀)。
handler 处理的消息字段名从 role_id/player_id 统一改为 entity_id。
GameRoom.snapshot() 返回 List[EntityInfo] dataclass,广播时用 dataclasses.asdict() 转 dict。
"""

import time
import logging
import dataclasses

# 项目模块用 `import game.xxx as xxx` 形式(热更约束+包前缀规范)
import game.game_room as game_room

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
        # 客户端发来的 player_info 字典(只含 player_name 等可选字段)
        player_info = data.get("entity_info", {})

        # 构造 EntityInfo dataclass 存入 GameRoom
        # entity_id 由 ctx.player_id 提供(已带 "player:" 前缀,见 web_server.handle_client)
        # entity_type 固定 "player",其他字段从客户端数据取(有默认值兜底)
        entity_info = game_room.EntityInfo(
            entity_id=ctx.player_id,        # 会被 add_entity 强制覆盖,这里只是占位
            entity_type="player",
            x=float(player_info.get("x", 0.0)),
            y=float(player_info.get("y", 0.0)),
            facing=float(player_info.get("facing", 0.0)),
            state="idle",
            player_name=player_info.get("player_name", "未命名"),
            moving=False,
        )

        # add_entity 内部会强制覆盖 entity_id 为 ctx.player_id(不变式)
        stored = server.room.add_entity(ctx.player_id, entity_info)

        logger.info(f"玩家 {stored.player_name} (ID: {ctx.player_id}) 加入游戏")

        # 广播 PlayerJoin 给所有人(含新玩家自己)
        # 为什么不 exclude 新玩家: 新玩家需要从 PlayerJoin 里提取自己被分配的 entity_id
        #   (见客户端 StateMirror._on_player_join 和 MessageBus._on_player_join)。
        # 和 PlayerMove 的对比: PlayerMove 是「转发」,PlayerJoin 是「通知」——两者语义不同。
        # dataclass 转 dict 给 message_bus(用 asdict 一把梭,EntityInfo 全是扁平字段)
        await server.broadcast("PlayerJoin", {
            "entity_info": dataclasses.asdict(stored)
        })

        # 给「新玩家」发当前完整状态快照(GameState),让它知道房间里都有谁
        # snapshot 返回 List[EntityInfo],要转成 dict 列表给 message_bus
        entities_list = [dataclasses.asdict(e) for e in server.room.snapshot()]
        await bus.send("GameState", {
            "entities": entities_list,
            "timestamp": int(time.time() * 1000)
        }, websocket=ctx.websocket)

        # 给「新玩家」发战斗属性全量快照(StatsInit),让它知道所有人的血量/属性
        # snapshot_combats 返回 List[CombatComponent],转 dict 列表给 message_bus
        combat_list = [dataclasses.asdict(c) for c in server.room.snapshot_combats()]
        await bus.send("StatsInit", {
            "entries": combat_list
        }, websocket=ctx.websocket)

        # 给「其他人」发新玩家的战斗属性(StatsChanged),让它们知道新玩家血量/属性
        # (新玩家自己已经通过上面的 StatsInit 拿到了,不用再发)
        new_combat = server.room.get_combat(ctx.player_id)
        if new_combat is not None:
            await server.broadcast("StatsChanged", {
                "entity_id": ctx.player_id,
                "max_hp": new_combat.max_hp,
                "attack_power": new_combat.attack_power,
                "defense": new_combat.defense,
            }, exclude_player=ctx.player_id)
            # 新玩家的 cur_hp 也要让其他人知道(走 HpChanged,因为 StatsChanged 不含 cur_hp)
            await server.broadcast("HpChanged", {
                "entity_id": ctx.player_id,
                "cur_hp": new_combat.cur_hp,
                "damage": 0,           # 0 表示非伤害性血量同步(初始化)
                "attacker_id": "",
                "atk_id": 0,
                "atk_shape_idx": 0,
            }, exclude_player=ctx.player_id)

    @bus.onproto("PlayerMove")
    async def on_player_move(data: dict, ctx):
        """处理玩家移动——高频输入,存入 pending,等 tick 统一处理"""
        # 实体不在房间就忽略:可能是未加入就发移动,或已离开(网络消息乱序)
        if not server.room.has_entity(ctx.player_id):
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
        # 实体不在房间就忽略(和 on_player_move 一致的容错策略)
        if not server.room.has_entity(ctx.player_id):
            return

        # 存入 pending,不立即 apply_facing 也不立即广播
        # 和 PlayerMove 一样走 tick 节流
        server.add_pending_input(ctx.player_id, "facing", {
            "facing": data.get("facing", 0.0),
        })

    # 注意: PlayerLeave 不是客户端主动发的,是 cleanup_player 触发的广播
    # 所以这里不注册 PlayerLeave handler
    # (cleanup_player 在 web_server.py 里直接调 broadcast("PlayerLeave", ...))

    @bus.onproto("AttackStart")
    async def on_attack_start(data: dict, ctx):
        """处理玩家攻击发起——高频输入,存入 pending,等 tick 统一处理
        判定帧模型下只接收发起请求;AttackHit/AttackEnd 是服务端主动广播,无 C2S handler"""
        # 实体不在房间就忽略(和 on_player_move 一致的容错策略)
        if not server.room.has_entity(ctx.player_id):
            return

        # 存入 pending,不立即 apply_attack_start 也不立即广播
        # 和 PlayerMove 一样走 tick 节流
        # 字段名 entity_id 和 proto 一致(原 role_id 已废弃)
        server.add_pending_input(ctx.player_id, "attackstart", {
            "entity_id": ctx.player_id,
            "atk_id": data.get("atk_id", 0),
        })
