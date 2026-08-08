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
# level=INFO 会打印 logger.exception 的完整 traceback(ERROR 级别及以上)
# format 带时间+模块名,方便定位是哪个协程出的错
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def _setup_asyncio_exception_handler() -> None:
    """
    设置 asyncio 全局异常钩子

    为什么需要:
        asyncio.create_task 创建的协程,如果抛了未被 try/except 捕获的异常,
       默认行为是"静默吞掉"——异常被存到 Task 对象里,直到 Task 被 GC 才打一句
        "Task exception was never retrieved" 到 stderr,而且时间已经过去很久,
        根本看不出是哪个协程、哪一行出的错。

        设了这个钩子后,任何 Task 的未捕获异常会立刻打到控制台,带完整 traceback。

    覆盖范围:
        - _tick_loop / _sender_loop / handle_client 里漏网的异常
        - timer 回调(hit_cb / end_cb / hurt_end / dead_end)里的异常
        - 未来新增协程的异常
    """
    loop = asyncio.get_event_loop()
    default_handler = loop.get_exception_handler()

    def _exception_handler(loop, context):
        # 先打完整信息到日志(带 traceback)
        exception = context.get("exception")
        message = context.get("message", "未命名异常")
        if exception is not None:
            logger.exception(f"asyncio 未捕获异常: {message}", exc_info=exception)
        else:
            logger.error(f"asyncio 异常上下文: {context}")
        # 调用默认处理器(保持 asyncio 原生行为,如 Future 的异常传递)
        if default_handler is not None:
            default_handler(loop, context)

    loop.set_exception_handler(_exception_handler)


async def main():
    # 设置 asyncio 全局异常钩子(必须在事件循环开始后、create_task 之前)
    # 这样所有协程的未捕获异常都会被打到控制台,而不是被 asyncio 静默吞掉
    _setup_asyncio_exception_handler()

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
        x=50.0,
        y=50.0,
        state="idle",
    ))

    server.room.create_enemy("enemy_slime", (100, 150))
    # server.room.create_enemy("enemy_skeleton", (150, 150))

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
