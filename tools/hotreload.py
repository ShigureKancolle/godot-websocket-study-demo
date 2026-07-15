# coding=utf-8

"""
文件: server/tools/hotreload.py
作用: 服务端热更模块——在不停机的情况下重新加载业务代码

============================================================================
 为什么需要这个文件（核心动机）
============================================================================
学习项目里会频繁改动 handler 逻辑（调整业务规则、加日志、改广播内容等）。
如果每次改完都要重启服务端，已连接的客户端会断开重连，调试体验很差。

热更的目标：改完代码后，在控制台敲一个命令，新代码立即生效，连接不中断。

============================================================================
 热更原理（和项目的 import 约束强相关）
============================================================================
Python 的 importlib.reload(module) 是「原地更新模块对象的属性」：
    - reload 会重新执行模块代码
    - 模块对象本身（内存地址）不变，但它的属性（类、函数）被替换成新的
    - 所有 `import xxx as xxx` 拿到的是同一个模块对象，reload 后通过 xxx.def 能拿到新版本

这就是为什么项目规则强制 `import xxx` + `xxx.def` 而禁止 `from xxx import def`：
    - from import 把名字绑定到当前命名空间，reload 后名字仍指向旧对象
    - import + 属性查找每次走模块对象，reload 后自然拿到新对象

============================================================================
 热更的边界（能热更什么，不能热更什么）
============================================================================
能热更（reload + 重新注册后立即生效）：
    - handler 内部逻辑（改 on_player_move 的处理流程）
    - 新增/删除 handler（加新消息处理器）
    - handler 调用 GameRoom 的方式（在 handler 里加业务规则）
    - 模块级常量/配置

不能热更（需要重启服务器）：
    - GameRoom 类的方法实现（旧实例是旧类的实例，用旧方法）
    - GameServer 类的方法实现（同上）
    - MessageBus 类的 send/dispatch 实现（同上，但 _handlers 数据能更新）
    - 类的 __init__ 改动（旧实例没有新属性）

一句话总结：handler 层（控制流、业务规则）能热更；
            状态层和传输层的类方法改动需要重启（但实例保留，状态不丢）。

============================================================================
 为什么 reload 后要重新 register
============================================================================
reload(handlers) 会更新模块里的函数定义,
但 bus._handlers 里存的还是旧函数对象（reload 前注册的）。
所以必须重新调 handlers.register_all(server),把新函数注册进去覆盖旧的。

这就是为什么 register_all 设计成显式函数而非模块级装饰器——
显式函数能被反复调用,每次调用都用最新的函数定义注册。

============================================================================
 模块列表配置
============================================================================
热更的模块列表不写死在本文件里，而是放在 server/hotreload_config.py。
这样新增/移除热更模块时只改配置文件，不用动 hotreload.py 的逻辑。

hotreload_config.py 不在 HOT_MODULES 列表里（它定义了列表，不能自己 reload 自己）。
但 reload_all() 会在开头先 reload 一次 hotreload_config，让配置改动也能热更——
改完 hotreload_config.py 后调 reload()，新加的模块就会立即被 reload。
"""

import importlib
import logging

# 项目模块用 import xxx + xxx.def 访问，不用 from xxx import def
# 原因：热更约束（详见各模块文件头注释）
import game.handlers as handlers
# 热更模块配置（定义哪些模块需要 reload，详见 hotreload_config.py 文件头注释）
import hotreload_config

logger = logging.getLogger(__name__)


def _get_hot_modules() -> list:
    """
    从配置文件读取热更模块列表

    注意：这个函数读的是「当前内存里」的 hotreload_config.HOT_MODULES。
    如果刚改了 hotreload_config.py 但还没 reload(hotreload_config)，
    读到的还是旧版本。reload_all() 会在开头先 reload(hotreload_config)
    来保证拿到最新配置。
    """
    return hotreload_config.HOT_MODULES


def reload_all(server_instance) -> dict:
    """
    热更所有业务模块并重新注册 handler

    流程：
        1. 先 reload(hotreload_config) 读取最新配置（让配置改动也能热更）
        2. 从最新配置读取模块列表
        3. 按列表顺序 reload 每个模块
        4. 重新调用 handlers.register_all(server) 覆盖旧 handler
        5. 返回热更结果摘要

    为什么先 reload(hotreload_config)：
        hotreload_config.py 不在 HOT_MODULES 列表里（它定义了列表，不能自己 reload 自己）。
        如果不先 reload 它，改了配置（比如加新模块）后调 reload() 读到的还是旧列表。
        在 reload_all 开头先 reload 一次，配置改动就能热更，不用重启服务器。

    reload(hotreload_config) 安全吗：
        安全。hotreload_config.py 里的 `import net.xxx as xxx` 走的是 sys.modules 缓存——
        如果模块已在 sys.modules 里，import 只是拿到现有模块对象，不会重新加载模块代码。
        所以 reload(hotreload_config) 只是重新执行配置文件的列表定义，不会干扰后续模块 reload。

    Args:
        server_instance: GameServer 实例（reload 后用它重新注册 handler）

    Returns:
        结果字典 {success: bool, reloaded: [模块名], errors: [错误信息]}
    """
    result = {"success": True, "reloaded": [], "errors": []}

    logger.info("=" * 60)
    logger.info("开始热更...")
    logger.info("=" * 60)

    # 1. 先 reload 配置文件，让配置改动也能热更
    try:
        importlib.reload(hotreload_config)
        logger.info("  ✓ 已 reload 配置: hotreload_config")
    except Exception as e:
        result["success"] = False
        result["errors"].append(f"hotreload_config: {e}")
        logger.error(f"  ✗ reload 配置失败: hotreload_config: {e}")
        # 配置 reload 失败就不能继续——后面的模块列表可能已失效
        return result

    # 2. 从最新配置读取模块列表
    modules = _get_hot_modules()

    # 2. 按依赖顺序 reload 每个模块
    for module in modules:
        mod_name = module.__name__
        try:
            importlib.reload(module)
            result["reloaded"].append(mod_name)
            logger.info(f"  ✓ 已 reload: {mod_name}")
        except Exception as e:
            result["success"] = False
            result["errors"].append(f"{mod_name}: {e}")
            logger.error(f"  ✗ reload 失败: {mod_name}: {e}")
            # 某个模块 reload 失败就不继续后面的（避免连锁错误）
            # 已 reload 的模块可能处于不一致状态，但 importlib 会保留旧版本，不会让模块变成空的
            break

    # 3. 重新注册 handler（覆盖 bus._handlers 里的旧函数）
    # 注意：这里用 handlers.register_all（reload 后是新版本）
    # 而非缓存的对象——这正是 import xxx + xxx.def 的价值
    if result["success"]:
        try:
            handlers.register_all(server_instance)
            logger.info("  ✓ 已重新注册 handler")
        except Exception as e:
            result["success"] = False
            result["errors"].append(f"register_all: {e}")
            logger.error(f"  ✗ 重新注册 handler 失败: {e}")

    # 4. 打印摘要
    logger.info("-" * 60)
    if result["success"]:
        handler_count = len(server_instance.bus.list_handlers())
        logger.info(
            f"热更完成: {len(result['reloaded'])} 个模块, "
            f"{handler_count} 个 handler 已注册"
        )
    else:
        logger.warning(
            f"热更未完全成功: {len(result['reloaded'])} 个模块已 reload, "
            f"{len(result['errors'])} 个错误"
        )
    logger.info("=" * 60)

    return result


def list_hot_modules() -> list:
    """返回当前热更列表里的模块名（调试用）"""
    return [m.__name__ for m in _get_hot_modules()]


def print_status(server_instance):
    """打印当前热更状态（调试用）"""
    print("=" * 60)
    print("热更状态")
    print("=" * 60)
    print(f"监听模块: {list_hot_modules()}")
    print(f"已注册 handler: {list(server_instance.bus.list_handlers().keys())}")
    print(f"在线玩家数: {len(server_instance.players)}")
    print(f"房间玩家数: {server_instance.room.player_count()}")
    print("=" * 60)
