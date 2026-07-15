# coding=utf-8

"""
文件: server/hotreload_config.py
作用: 热更模块配置——声明哪些模块需要被 hotreload 重新加载

============================================================================
 为什么用 Python 文件而不是 JSON
============================================================================
用 Python 文件的好处：
    1. 能写注释说明「为什么这个模块要热更」「依赖关系是什么」
    2. import 时直接得到模块对象，hotreload.py 不用再 importlib.import_module 动态导入
    3. 改完即生效（下次 reload 时自然读到新版本），不用重启读取
    4. 和项目其他模块风格一致（都是 .py）

JSON 只在需要跨语言共享时才有优势（如 messages.json 要被 GDScript 读取），
热更配置是 Python 专属功能，用 Python 文件更自然。

============================================================================
 怎么修改这个文件
============================================================================
新增需要热更的模块时：
    1. 在本文件加 import + 在 HOT_MODULES 列表里加上模块引用
    2. 注意顺序：被依赖的模块排前面（reload 时先 reload 被依赖的）
    3. 保存后在控制台敲 reload() 即可生效——reload_all() 会先 reload 本配置文件，
       再按新列表 reload 各模块。不用重启服务器。

移除模块时：删掉对应的 import 和列表项，然后 reload() 即可。

============================================================================
 顺序原则
============================================================================
reload 按列表顺序执行。被依赖的模块要排前面，避免 reload 时引用到旧版本：
    - message_contract: 无项目内依赖，最先
    - message_bus: 依赖 message_contract 的钩子（运行时通过参数传入，不强依赖）
    - game_room: 无项目内依赖
    - handlers: 依赖 game_room + message_bus(handler 代码里用 room/bus)
    - web_server: 依赖上面四个（通过 import xxx as xxx，reload 后能拿到新版本）

新增模块时，根据它的依赖关系插入合适的位置。
"""

# 项目模块用 import xxx + xxx.def 访问，不用 from xxx import def
# 原因：热更约束（详见 net/web_server.py 文件头注释）
import net.message_contract as message_contract
import net.message_bus as message_bus
import game.game_room as game_room
import game.handlers as handlers
import net.web_server as web_server


# 需要热更的业务模块列表（按依赖顺序，被依赖的排前面）
# hotreload.py 会按这个顺序逐个 reload，然后重新注册 handler
HOT_MODULES = [
    message_contract,   # 契约模块：无项目内依赖，最先 reload
    message_bus,        # 消息总线：依赖 message_contract 的钩子
    game_room,          # 游戏状态：无项目内依赖
    handlers,          # 业务 handler：依赖 game_room + message_bus
    web_server,         # 网络层：依赖上面四个，最后 reload
]
