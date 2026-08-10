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
reload 按列表顺序执行。被依赖的模块要排前面，避免 reload 时引用到旧版本。

当前模块依赖关系（被依赖的排前面）：
    ── 第一梯队：无项目内依赖（或被最多模块依赖），最先 reload ──
    - message_contract  契约：无项目内依赖
    - config_loader     配置：无项目内依赖（只读 JSON + 标准库）
    - collision         碰撞：无项目内依赖（纯几何函数）
    - map_generator     地图生成：无项目内依赖（纯算法）
    - timer_mgr         定时器：无项目内依赖
    - message_bus       消息总线：依赖 message_contract 钩子（运行时传入，不强依赖）

    ── 第二梯队：依赖第一梯队 ──
    - entity_config     实体配置：依赖 config_loader
    - pathfinder        寻路：依赖 map_generator + config_loader
    - ai_state_base     AI 状态基类：依赖 game_room（类型注解）
    - ai_state_helper   AI 辅助函数：运行时依赖 room / collision
    - enemy_ai_machine  AI 状态机：依赖 ai_state_base
    - look_around_state / patrol_state / chase_state / attack_state
                        AI 具体状态：依赖 ai_state_base / ai_state_helper / config_loader
    - enemy_mgr         敌人管理：依赖 ai_state_base + enemy_ai_machine
                        （运行时按需 import 各 states，reload 后能拿到新版）

    ── 第三梯队：状态层 ──
    - game_room         游戏状态：依赖 collision + entity_config + config_loader

    ── 第四梯队：业务 handler ──
    - player/chat/network_handlers  各 handler 子模块
    - handlers          handler 包：register_all 入口。
                        ⚠ 必须把三个子模块放它前面 reload——否则 reload 包时
                        import 子模块拿到的是旧模块，register_all 注册的仍是旧 handler

    ── 网络层 ──
    - web_server        网络层：依赖上面全部，最后 reload

新增模块时，根据它的依赖关系插入合适的位置（被依赖的排前面）。

热更边界（沿用 tools/hotreload.py 文件头）：
    reload 更新的是「模块定义」——模块级函数/常量/配置会生效，reload 后新建的实例会生效。
    已实例化的类（GameRoom/GameServer/EnemyMgr/TimerManager/状态实例等）的方法改动
    仍需重启才生效；但把子模块放前面 reload，包 reload 后引用的就是新版本。
"""

# 项目模块用 import xxx + xxx.def 访问，不用 from xxx import def
# 原因：热更约束（详见 net/web_server.py 文件头注释）
# import 顺序和 HOT_MODULES 列表一致（按依赖，被依赖的排前面），便于对照阅读
import net.message_contract as message_contract
import net.message_bus as message_bus
import config.config_loader as config_loader
import game.collision as collision
import game.map_generator as map_generator
import game.timer_mgr as timer_mgr
import game.entity_config as entity_config
import game.pathfinder as pathfinder
import game.ai.ai_state_base as ai_state_base
import game.helper.ai_state_helper as ai_state_helper
import game.ai.enemy_ai_machine as enemy_ai_machine
import game.ai.states.look_around_state as look_around_state
import game.ai.states.patrol_state as patrol_state
import game.ai.states.chase_state as chase_state
import game.ai.states.attack_state as attack_state
import game.enemy_mgr as enemy_mgr
import game.game_room as game_room
import game.handlers.player_handlers as player_handlers
import game.handlers.chat_handlers as chat_handlers
import game.handlers.network_handlers as network_handlers
import game.handlers as handlers
import net.web_server as web_server


# 需要热更的业务模块列表（按依赖顺序，被依赖的排前面）
# hotreload.py 会按这个顺序逐个 reload，然后重新注册 handler
HOT_MODULES = [
    # —— 第一梯队：无项目内依赖（或被最多模块依赖），最先 reload ——
    message_contract,   # 契约：无项目内依赖
    config_loader,      # 配置：无项目内依赖；被 entity_config/pathfinder/game_room/attack 依赖
    collision,          # 碰撞：无项目内依赖；被 game_room/ai_state_helper 依赖
    map_generator,      # 地图生成：无项目内依赖；被 pathfinder 依赖
    timer_mgr,          # 定时器：无项目内依赖；被 web_server 依赖
    message_bus,        # 消息总线：依赖 message_contract 钩子（运行时传入）

    # —— 第二梯队：依赖第一梯队 ——
    entity_config,      # 实体配置：依赖 config_loader
    pathfinder,         # 寻路：依赖 map_generator + config_loader
    ai_state_base,      # AI 状态基类：依赖 game_room（类型注解）
    ai_state_helper,    # AI 辅助函数：运行时依赖 room/collision
    enemy_ai_machine,   # AI 状态机：依赖 ai_state_base
    look_around_state,  # AI 状态：依赖 ai_state_base
    patrol_state,       # AI 状态：依赖 ai_state_base + ai_state_helper
    chase_state,        # AI 状态：依赖 ai_state_base + ai_state_helper + config_loader
    attack_state,       # AI 状态：依赖 ai_state_base + ai_state_helper + config_loader
    enemy_mgr,          # 敌人管理：依赖 ai_state_base + enemy_ai_machine

    # —— 第三梯队：状态层 ——
    game_room,          # 游戏状态：依赖 collision + entity_config + config_loader

    # —— 第四梯队：业务 handler（子模块在前，包在后，register_all 才拿到新版本）——
    player_handlers,    # 玩家 handler：依赖 game_room
    chat_handlers,      # 聊天 handler：无项目内依赖
    network_handlers,   # 网络 handler：无项目内依赖
    handlers,           # handler 包：register_all 入口，依赖三个子模块

    # —— 网络层：最后 reload ——
    web_server,         # 网络层：依赖上面全部
]
