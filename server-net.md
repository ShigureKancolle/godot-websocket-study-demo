# 服务端网络层 (server-net)

覆盖:`server/main.py` + `server/net/*` + `server/tools/hotreload.py` + `server/tools/console.py` + `server/hotreload_config.py`
职责:服务端入口装配、WebSocket 连接管理、消息总线(序列化/路由)、契约方向校验、热更、交互控制台

## 文件清单

| 文件 | 职责 |
|------|------|
| [main.py](file:///d:/work2/godot_demo/server/main.py) | 唯一入口:实例创建+契约加载+handler注册+启动 |
| [net/web_server.py](file:///d:/work2/godot_demo/server/net/web_server.py) | GameServer 类(连接管理+broadcast+tick 基础设施) |
| [net/message_bus.py](file:///d:/work2/godot_demo/server/net/message_bus.py) | MessageBus 单例(序列化/反序列化/路由分发)、MessageContext(连接上下文) |
| [net/message_contract.py](file:///d:/work2/godot_demo/server/net/message_contract.py) | MessageContract 单例(加载 messages.json,校验入站方向) |
| [hotreload_config.py](file:///d:/work2/godot_demo/server/hotreload_config.py) | 热更模块配置:声明 HOT_MODULES 列表(哪些模块要 reload + 依赖顺序) |
| [tools/hotreload.py](file:///d:/work2/godot_demo/server/tools/hotreload.py) | 热更模块:reload_all 从 hotreload_config 读列表+reload+重新注册 handler |
| [tools/console.py](file:///d:/work2/godot_demo/server/tools/console.py) | 交互式控制台:start_console 注入 server/bus/room/reload 等变量和便捷函数 |
| [tools/client.py](file:///d:/work2/godot_demo/server/tools/client.py) | Python 测试客户端(调试用,非真正客户端) |

注:handler 业务逻辑已拆到 `server/game/handlers/` 下,详见 [server-game.md](file:///d:/work2/godot_demo/docs/server-game.md)。

## main.py — 唯一入口

把所有副作用收口到这里:实例创建、契约加载、handler 注册、服务器启动。
- 之前 web_server.py 既定义类又在模块级创建实例,导致 import 触发副作用
- 现在模块级只有类定义和函数,import 无副作用,便于热更和测试

启动流程:
```
解析参数 → 创建 MessageBus → 加载 MessageContract → 创建 GameServer → handlers.register_all → (可选)启动控制台 → server.start()
```

支持参数:`--host`(默认0.0.0.0) `--port`(默认8765) `--console`(开交互控制台)

## web_server.py

### GameServer 类
- `players: Dict[player_id, websocket]` — 传输层连接表(谁连着)
- `room: GameRoom` — 游戏状态持有者(唯一能改状态的地方,详见 server-game.md)
- `_pending_inputs: Dict[player_id, Dict[action, data]]` — tick 待处理输入(move/facing 高频输入先存这里)
- `TICK_HZ = 30` / `TICK_INTERVAL = 0.033s` — tick 频率常量
- `handle_client(websocket)` — 处理单个连接:分配 uuid4 作为 player_id → 等首条消息(必须是 PlayerJoin)→ 进主循环分发消息
- `broadcast(protoname, params, exclude_player=None)` — 广播给所有玩家
- `add_pending_input(player_id, action, data)` — 存入 pending,等 tick 处理(同一 tick 内同动作覆盖=节流)
- `_tick_loop()` — asyncio task,每 TICK_INTERVAL 秒调 _process_tick
- `_process_tick()` — 取出 pending → apply_move/apply_facing → 统一广播
- `cleanup_player(player_id)` — 断连清理:删连接表 + room.remove_player + 广播 PlayerLeave
- `start()` — create_task(_tick_loop) + websockets.serve 启动
- `stop()` — 取消 tick_task + 停服务

### tick 机制(限定同步速率)
高频输入(PlayerMove/PlayerFacing)不立即处理,存入 `_pending_inputs`,每 33ms(30Hz)统一处理+广播:
- **节流**:同一 tick 内同一动作的多次输入只保留最后一次(覆盖)。客户端 60Hz 发 → 服务端 30Hz 处理
- **合并**:一个 tick 内所有玩家的变更统一广播,频率从 60Hz 降到 30Hz(带宽减半)
- **哪些走 tick**:PlayerMove / PlayerFacing(高频输入)
- **哪些不走 tick**:PlayerJoin / PlayerLeave / ChatMessage / Heartbeat(低频事件,立即处理)
- **线程安全**:asyncio 单线程事件循环,handler 存 pending 时无 await(原子),不会在存入中途被 tick 打断

### broadcast 的 exclude_player 语义
**重要**:状态更新类广播(PlayerJoin/PlayerMove/PlayerFacing)**不要**用 exclude_player 排除发起者。
- 原因:客户端无本地预测,所有状态更新靠服务端广播驱动。排除发起者→它收不到自己的操作回传→看不到自己动作
- exclude_player 只适用于纯转发场景(当前未使用)
- cleanup_player 广播 PlayerLeave 时也无需 exclude(发起者已断连,不在 players 表里)
- tick 机制下的 _process_tick 广播也不 exclude(同上)

### handler 已拆到 game/handlers/
之前所有 handler 写在 web_server.py 里,导致网络层和业务逻辑混在一起。拆分后:
- web_server.py 只管网络层(连接、tick、broadcast 基础设施)
- `game/handlers/` 专注业务逻辑,按功能分文件
- 详见 [server-game.md](file:///d:/work2/godot_demo/docs/server-game.md)
- main.py 调 `handlers.register_all(server)` 完成注册

## message_bus.py — MessageBus

单例。屏蔽 protobuf 细节,提供字典式 API。

### 核心机制
- `_auto_register()` — 扫描 game_pb2.GameMessage的 oneof 字段,自动注册所有消息类型
- `_resolve_name(name)` — 支持全名(`game.PlayerMove`)和短名(`PlayerMove`),短名有歧义时报错
- `send(protoname, dict, websocket)` — 字典→protobuf→bytes→发送
- `dispatch(data, ctx)` — bytes→protobuf→字典→调 handler;中间过 `_inbound_validator` 做方向校验
- `onproto(protoname)` — 装饰器注册 handler

### proto/generated 路径处理
message_bus.py 在 `server/net/`,generated 在 `server/proto/generated/`,通过 `__file__` 往上跳一层再进 proto:
```python
_HERE = os.path.dirname(os.path.abspath(__file__))        # server/net
_SERVER_ROOT = os.path.dirname(_HERE)                       # server
_GENERATED_DIR = os.path.join(_SERVER_ROOT, "proto", "generated")
```

### MessageContext
携带连接信息:websocket、player_id、is_server。handler 第二参数接收它(可选,按参数个数判断)。

## message_contract.py — MessageContract

单例。加载 `server/proto/messages.json` 做方向校验。

- `load(path=None)` — 默认从 `server/proto/messages.json` 加载(路径用 `__file__` 定位)
- `is_valid_inbound(full_name)` — 服务端 dispatch 时调,S2C 消息拒绝(客户端不该发),C2S/both 放行,未登记放行但告警
- 契约缺失时不阻断运行(只告警),设计为"增强而非必需"

## 依赖关系
- 依赖 server-game:GameRoom(状态层)+ handlers(业务逻辑)
- 依赖 server-proto:game_pb2(生成代码)、messages.json(契约)
- 被 main.py 装配启动

## import 约束(热更)
所有项目模块用 `import net.xxx as xxx` + `xxx.def` 形式,**禁止** `from xxx import def`。
原因:热更时重新 import 模块,`from import` 绑定的名字仍指向旧类;`import` + 属性查找每次走模块对象,能拿到新类。
标准库和第三方库不受此约束(不参与热更)。

## hotreload.py — 热更模块

### 原理
Python 的 `importlib.reload(module)` 原地更新模块对象的属性:模块对象本身(内存地址)不变,但它的类/函数被替换成新的。因为项目用 `import xxx as xxx` + `xxx.def`,reload 后通过 `xxx.def` 能拿到新版本。

### reload_all(server_instance)
从 `hotreload_config.HOT_MODULES` 读取模块列表,按列表顺序逐个 reload,然后重新调 `handlers.register_all(server)` 覆盖旧 handler。

当前配置里的 5 个模块(按依赖顺序):
1. `net.message_contract`(无项目内依赖,最先)
2. `net.message_bus`
3. `game.game_room`
4. `game.handlers`(依赖 game_room + message_bus)
5. `net.web_server`(依赖上面四个)

reload 后重新 `handlers.register_all(server)`,把新函数注册到 `bus._handlers` 覆盖旧的。这就是 register_all 设计成显式函数而非模块级装饰器的价值——能被反复调用。

### 为什么模块列表抽到 hotreload_config.py
之前模块列表写死在 hotreload.py 的 `_HOT_MODULES` 常量里,新增/移除模块要改 hotreload.py 逻辑。抽到独立配置文件后:
- 新增模块只改 hotreload_config.py(加 import + 加列表项),不动 hotreload.py
- 配置文件里能写注释说明依赖关系和顺序原因
- 用 Python 文件而非 JSON:能直接 import 得到模块对象,不用 importlib 动态导入;能写注释

### 配置改动也能热更
hotreload_config.py 不在 HOT_MODULES 列表里(它定义了列表,不能自己 reload 自己)。但 `reload_all()` 会在开头先 reload 一次 hotreload_config,让配置改动也能热更——改完 hotreload_config.py 后调 reload(),新加的模块就会立即被 reload,不用重启服务器。

reload(hotreload_config) 安全的原因:hotreload_config.py 里的 `import net.xxx as xxx` 走的是 sys.modules 缓存——如果模块已在 sys.modules 里,import 只是拿到现有模块对象,不会重新加载模块代码。所以 reload(hotreload_config) 只是重新执行配置文件的列表定义,不会干扰后续模块 reload。

### 热更边界
**能热更**(reload + 重新注册后立即生效):
- handler 内部逻辑(改 on_player_move 的处理流程)
- 新增/删除 handler(加新消息处理器)
- handler 调用 GameRoom 的方式(在 handler 里加业务规则)
- 模块级常量/配置

**不能热更**(需要重启服务器):
- GameRoom 类的方法实现(旧实例是旧类的实例,用旧方法)
- GameServer 类的方法实现(同上)
- MessageBus 类的 send/dispatch 实现(同上,但 _handlers 数据能更新)
- 类的 __init__ 改动(旧实例没有新属性)

一句话:handler 层(控制流、业务规则)能热更;状态层和传输层的类方法改动需要重启(但实例保留,状态不丢)。

### 触发方式
在交互式控制台(用 `--console` 启动)里输入:
- `reload()` — 触发热更
- `hot_status()` — 查看热更状态(监听模块、handler、玩家数)

### 为什么不重建状态层实例
重建 GameRoom 实例并迁移 _players 状态逻辑复杂易错,且 GameRoom 改动少。当前方案:实例保留(状态不丢),类方法改动需重启。这是可接受的折衷。

## console.py — 交互式控制台

### 为什么从 web_server.py 移出来
start_console 之前写在 web_server.py 里,但它和 WebSocket 服务逻辑无关(是调试入口,属工具层)。移到 tools/console.py 后:
- web_server.py 只管网络层,职责清晰
- 控制台依赖(hotreload/game_pb2)不污染网络层
- 热更 reload(web_server) 不会连带重载控制台代码(控制台不需要热更)

### start_console(server, bus, loop)
独立线程跑,不阻塞 asyncio 事件循环。需要调协程时用 run_coroutine_threadsafe 投递回主循环。

注入的变量和函数:
- `server` / `bus` / `players` / `room` / `game_pb2` — 直接访问实例
- `state()` — 返回玩家信息快照
- `broadcast(name, dict)` — 广播给所有玩家
- `send_to(pid, name, dict)` — 发给指定玩家
- `kick(pid)` — 踢出玩家
- `reload()` — 触发热更(调 hotreload.reload_all)
- `hot_status()` — 查看热更状态

### 启动方式
`py -3 main.py --console` 或在 VSCode launch.json 的 args 里加 `--console`。

## 当前状态
- 功能完整:连接、加入、移动、朝向、聊天、心跳、断连清理都已实现
- 玩家同步闭环已跑通:两个客户端能互相看到对方移动+朝向(本地蓝箭头/远程棕箭头)
- tick 机制已实现:30Hz 限定同步速率,PlayerMove/PlayerFacing 走 pending 统一处理
- handler 已拆到 game/handlers/,web_server.py 只管网络层
- 热更已实现:控制台 `reload()` 命令,reload 5 模块+重新注册 handler
- 控制台已拆分到 tools/console.py
