# coding=utf-8

"""
WebSocket 游戏服务器入口

本文件是服务器的唯一启动入口，负责:
    1. 配置日志
    2. 创建 MessageBus 单例
    3. 加载消息契约并设置入站校验钩子
    4. 创建 GameServer 实例
    5. 注册消息处理器
    6. （可选）启动交互式控制台
    7. 启动服务器

为什么需要单独的入口文件:
    之前 web_server.py 既定义类又在模块级创建实例和注册 handler，
    导致 import web_server 会触发副作用（实例创建、handler 注册）。
    把这些副作用移到 main.py 后:
        - import web_server 无副作用，便于测试
        - 启动配置（端口、控制台开关）和类定义分离
        - 热更时重新 import 不会重复创建实例
"""

import asyncio
import argparse
import threading
import logging

# 项目模块用 import xxx + xxx.def 访问，不用 from xxx import def
# 原因：后续要支持 hotfix/hotreload（详见 net/web_server.py 文件头注释）
# 用 `import net.xxx as xxx` 形式：import 语句不违反热更约束，as 别名只是短名
import net.message_bus as message_bus
import net.message_contract as message_contract
import net.web_server as web_server
import game.handlers as handlers
import game.game_room as game_room
import tools.console as console

# 配置日志系统
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


async def main():
    # 解析命令行参数
    parser = argparse.ArgumentParser(description="WebSocket 游戏服务器")
    parser.add_argument(
        '--console', action='store_true',
        help='开启交互式 Python 控制台（可在运行时查看状态、发送消息）'
    )
    parser.add_argument(
        '--host', default='0.0.0.0',
        help='监听地址（默认 0.0.0.0）'
    )
    parser.add_argument(
        '--port', type=int, default=8765,
        help='监听端口（默认 8765）'
    )
    args = parser.parse_args()

    # 1. 创建消息总线单例
    bus = message_bus.MessageBus()

    # 2. 加载消息契约并设置入站校验钩子
    # 必须在 handler 注册之前加载契约——虽然契约校验是运行时的，但启动时加载能尽早暴露问题
    # （如契约文件格式错误，启动日志里立刻看到，不用等第一条消息进来）
    contract = message_contract.MessageContract()
    contract.load()  # 默认从 proto/messages.json 加载
    bus.set_inbound_validator(contract.is_valid_inbound)

    # 3. 创建服务器实例
    server = web_server.GameServer(host=args.host, port=args.port, bus=bus)

    # 4. 注册消息处理器
    # 在服务器实例创建后调用——handler 通过闭包捕获 server 实例
    # handler 代码已拆到 game/handlers/ 下(player_handlers/chat_handlers)
    handlers.register_all(server)

    # 5. 注册静态实体(木桩/箱子等,服务端硬编码位置)
    # 这些实体没有连接,不会被 cleanup_player 清理,启动时一次性注册
    # 位置和客户端场景里的 DeadMan 节点一致(见 client/Scene/DeadManScene.tscn)
    # 未来多了可读配置文件,当前硬编码够用
    server.room.add_entity("entity:stake_1", game_room.EntityInfo(
        entity_id="entity:stake_1",    # 会被 add_entity 强制覆盖,这里只是占位
        entity_type="stake",
        x=350.0,
        y=200.0,
        state="idle",
    ))

    server.room.add_entity("entity:enemy_slime_1", game_room.EntityInfo(
        entity_id="entity:enemy_slime_1",
        entity_type="enemy_slime",
        x=100.0,
        y=150.0,
        state="idle",
    ))
    server.room.add_entity("entity:enemy_skeleton_1", game_room.EntityInfo(
        entity_id="entity:enemy_skeleton_1",
        entity_type="enemy_skeleton",
        x=150.0,
        y=150.0,
        state="idle",
    ))

    # 6. （可选）启动交互式控制台
    if args.console:
        loop = asyncio.get_running_loop()
        console_thread = threading.Thread(
            target=console.start_console,
            args=(server, bus, loop),
            daemon=True  # 设为守护线程，主程序退出时自动结束
        )
        console_thread.start()
        logger.info("交互式控制台已启动（独立线程）")

    # 7. 启动服务器
    try:
        await server.start()
    except KeyboardInterrupt:
        logger.info("收到停止信号")
        server.stop()


if __name__ == "__main__":
    asyncio.run(main())
