# 服务端网络层 (server-net)

覆盖:`server/main.py` + `server/net/*` + `server/tools/hotreload.py` + `server/tools/console.py` + `server/hotreload_config.py`

EntityRelocated 属于可靠控制事件，进入普通发送 FIFO，不使用 latest-only MovementBatch 槽位。
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
- `sessions: Dict[entity_id, dict]` — 所有已 Login 的客户端会话(大厅 + 房间内)
- `players: Dict[entity_id, websocket]` — 房间内玩家连接表(谁在房间里,entity_id 带 `player:` 前缀)
- `room: GameRoom` — 游戏状态持有者(唯一能改状态的地方,详见 server-game.md)
- `timer_mgr: TimerManager` — 攻击定时器管理器(详见 server-game.md 的 timer_mgr 章节)
- `_pending_inputs: Dict[entity_id, Dict[action, data]]` — tick 待处理输入(move/facing/attackstart 高频输入先存这里)
- `_send_queue: asyncio.Queue` — 发送队列(逻辑层塞消息,传输层独立协程发,见下方"发送队列"章节)
- `TICK_HZ = 30` / `TICK_INTERVAL = 0.033s` — tick 频率常量
- `handle_client(websocket)` — 处理单个连接:先收首条消息(必须是 Login)并从中取客户端本地账号 id(`account_id`,带 `player:` 前缀则优先用作 player_id,跨会话稳定识别同一账号)→ 无账号 id 才回退随机 `player:uuid` → 构造 ctx → 进主循环分发消息
- `_loop: asyncio.AbstractEventLoop | None` — 事件循环引用(start 时 get_running_loop 填充)。GM 控制台在独立线程调 room.create_enemy,实体创建回调 `_on_entity_spawned` 用它把广播投递回事件循环线程
- `TICK_INTERVAL_MS = 33` — tick 周期(整数毫秒,约 30.3Hz,只用于控频 sleep);`MAX_TICK_DT = 0.1` — 实测 dt 钳制上限(秒)
- `handle_client(websocket)` — 处理单个连接:分配 `player:uuid` 作为 entity_id → 等首条消息(必须是 Login)→ 进主循环分发消息
- `broadcast(protoname, params, exclude_player=None)` — 真正的广播(遍历玩家 await ws.send)。**只被 _sender_loop 调用**,业务代码不直接调
- `_queue_broadcast(protoname, params)` — 塞队列(不阻塞)。**业务代码(tick/timer 回调/cleanup)用这个替代 await broadcast**
- `_on_entity_spawned(entity_info)` — 实体创建钩子(注册给 GameRoom 的 `entity_spawn_hook`,由 `room.create_enemy` 回调)。GM 控制台在独立线程调 create_enemy,本方法会从该线程进入,所以用 `loop.call_soon_threadsafe` 投递回事件循环线程执行真正广播(start 前 loop 未建立时直接同步广播,此时无并发安全)
- `_broadcast_entity_spawn(entity_info)` — 在事件循环线程内执行:先 `_queue_broadcast("StatsInit", ...)` 再 `_queue_broadcast("GameState", ...)`(全量快照)。**先 StatsInit 再 GameState**:客户端 _create_role 创建 Role 时会查 mirror.get_combat() 初始化血条,先发 StatsInit 让新敌人战斗属性先进 _combats,再发 GameState 触发 state_replaced 重建 Role,创建时就能取到 combat、血条当前值正确。用全量快照而非复用 EnterRoom:EnterRoom 语义是进入房间,复用会把客户端 _local_entity_id 覆盖成敌人 id,破坏本地玩家识别
- `_sender_loop()` — 独立协程,从 _send_queue 取消息调 broadcast 发出。和 _tick_loop 并行
- 生存结算消息在入队时保存旧房间 `players` 的 websocket 快照；收尾随后移除这些连接的房间资格，但 sender 按快照完成一次 `SurvivalResult` 发送。`sessions` 保留连接，未重新 `EnterRoom` 的大厅客户端不会收到新局广播。
- `add_pending_input(entity_id, action, data)` — 存入 pending,等 tick 处理(同一 tick 内同动作覆盖=节流)
- `_tick_loop()` — asyncio task,启动 _sender_loop + 每 TICK_INTERVAL_MS 毫秒调 _process_tick(dt),退出时 cancel sender。**dt 用 time.monotonic() 实测两次 tick 的真实间隔(钳制到 [0, MAX_TICK_DT])**——sleep 实际唤醒间隔受系统定时粒度影响(Windows 默认 15.6ms 粒度下 33ms 请求约 47ms 才醒),用固定值当 dt 积分会让服务端移速系统性偏慢,客户端预测对账累积超阈值 → 周期性回拉(拉扯根因)
- `_process_tick(dt)` — 取出 pending → apply_move_dir(只记方向)/apply_facing/room.trigger_attack(attackstart) → 木桩回血 → 敌人 AI tick(dt) → **tick_movement(dt) 持续推进所有 moving=True 实体位移** → 收集广播 → _queue_broadcast 塞队列
- 单人升级暂停时，`_process_tick` 仍发送权威 `SurvivalState`/`LevelUpChoices`，但在世界推进阶段前短路：不回血、不执行 EnemyMgr AI、不推进普通移动/经验球；PlayerMove/PlayerFacing/AttackStart handler 同时拒绝暂停期输入。多人模式不进入该短路。
- `_trigger_attack(attacker_id, atk_id)` — 完整攻击发动流程(注册给 GameRoom 作为 `attack_trigger` 钩子,由 `room.trigger_attack` 转调)。apply_attack_start 改状态 → 广播 AttackStart → 遍历 shape_list 注册 AttackTimer(hit_cb/end_cb)。**玩家(经 pending)和敌人(AI 直接调)走同一条路**,避免敌人 AI 直接调 apply_attack_start 导致"只改状态不发动"
- `cleanup_player(player_id)` — 断连清理:删会话/连接表 + timer_mgr.cancel + room.remove_entity + _queue_broadcast(LeaveRoom)
- `start()` — _enable_high_timer_resolution(win32 提频) + 记录 self._loop(asyncio.get_running_loop,供实体创建回调线程安全投递) + create_task(_tick_loop) + websockets.serve 启动
- `stop()` — 取消 tick_task(tick 的 finally 会连带 cancel sender_task) + _restore_timer_resolution(对称恢复)
- `_enable_high_timer_resolution()` / `_restore_timer_resolution()` — **Windows 定时器提频**:ctypes 调 winmm.timeBeginPeriod(1) 把系统定时粒度从 15.6ms 提到 1ms,asyncio.sleep 精度接近 1ms,tick 真正跑在 33ms 周期(否则 Windows 下实际约 47ms)。pending 输入排队延迟和 tick 间隔抖动随之减小。仅 win32 生效,失败静默降级(实测 dt 已保证移速正确,提频是"又快又稳"的补充);stop 时对称 timeEndPeriod

### 统一 Entity 模型(本次重构)
- player_id 改为带 `player:` 前缀的 entity_id(如 `player:uuid-xxx`)
- GameRoom 内部用 `_entities: Dict[entity_id, EntityInfo]` 一张表存所有可交互物体(玩家+木桩)
- web_server 通过 `room.has_entity` / `room.remove_entity` / `room.get_entity` 访问
- PlayerJoin handler 构造 EntityInfo dataclass 存入,广播时用 `dataclasses.asdict()` 转 dict
- 广播 GameState 时用 `[dataclasses.asdict(e) for e in room.snapshot()]` 转 dict 列表

### 账号系统(account_id 作 player_id)
- 客户端本地存档生成稳定账号 id(带 `player:` 前缀),随 PlayerJoin 的 `entity_info.account_id` 传来
- `handle_client` 优先用它作为 player_id:同一账号跨会话/跨重启 id 稳定,服务端日志、未来持久化都能识别
- 老客户端/测试工具不带 account_id,回退随机 `player:uuid`(兼容)

### 攻击配置已迁回 game 层
`ATTACK_CONFIG` / `AttackShape` / `AttackConfig` / `SectorParams` 等数据类原本写在 web_server.py 的 `# region` 块里,现已迁移到 [game_room.py](file:///d:/work2/godot_demo/server/game/game_room.py)。
理由:配置属 game 层(被 GameRoom.get_attack_hits 读取),不属于 net 层。web_server.py 通过 `game_room.ATTACK_CONFIG` 引用。

### hit_cb / end_cb / hurt_end_cb 攻击+受击定时器回调
> hit_cb / end_cb 定义在 `_trigger_attack` 里(不再内联在 _process_tick),随 AttackTimer 注册;hurt_end_cb 由 `get_hurt_end_callback` 闭包工厂生成。玩家和敌人的攻击都经 _trigger_attack 注册这些回调。

判定帧触发时(hit_cb):
1. 调 `room.get_attack_hits(shape, attacker_id)` 取命中列表(统一 Entity 模型:可能含玩家和木桩)
2. 遍历命中列表逐个调 `room.apply_hurt(hurt_id, atk_id)` 设被命中者 state="hurt"
   - apply_hurt 内部查能力配置(can_be_hurt),统一处理玩家和木桩,不用分流
3. 逐个调 `timer_mgr.start_hurt(hurt_id, HURT_DURATION_MS, hurt_end_cb)` 启动 hurt 硬直定时器
   - start_hurt 内部会 cancel 被命中者身上旧的 attack timers(攻击被打断)+ 旧 hurt timer(连击重置硬直)
4. `_queue_broadcast("AttackHit", ...)` 塞队列(不阻塞 timer 回调),key 和 proto 字段名一致:`attacker_id` / `hit_list` / `atk_id` / `hurt_duration`
   - hurt_duration 字段客户端当前不读(走路径X纯等服务端 idle 信号),留作未来预演/调试用

攻击结束触发时(end_cb):
1. 调 `room.apply_attack_end(attacker_id, atk_id)` 设攻击者 state="idle"
2. `_queue_broadcast("AttackEnd", ...)` 塞队列,key 用 `entity_id`(不是 role_id)

hurt 硬直到期触发时(hurt_end_cb,由 `get_hurt_end_callback` 闭包工厂生成):
1. 调 `room.apply_hurt_end(hurt_id)` 设被命中者 state="idle"
2. `_queue_broadcast("HurtEnd", ...)` 塞队列,key:`attacker_id` / `hurt_id` / `atk_id` / `hurt_duration`
3. 连击场景下 hurt timer 被 cancel+restart,不会触发 hurt_end_cb(不发 HurtEnd)

> 三个回调都走 `_queue_broadcast` 而非 `await broadcast`:timer 回调虽然是独立协程,但若直接 await broadcast 仍会被 I/O 阻塞,导致回调链堆积。走队列后回调立即返回,timer 节奏也不受网络影响。

### apply_xxx 返回值检查(避免状态矛盾)
`_process_tick` 里 move/facing 输入调 apply_xxx 后**只有返回 True 才标记广播**;attackstart 输入调 `room.trigger_attack`(内部调 apply_attack_start,失败直接返回 False,不广播也不启定时器):
- apply_move_dir / apply_facing / apply_attack_start 可能因 hurt 硬直 / 能力不足返回 False
- 若不检查就广播,其他客户端会收到"X 在移动/攻击"广播,但 X 实际没动(state 还是 hurt)——状态矛盾
- trigger_attack 内部:apply_attack_start 返回 False 时不广播 AttackStart,也不启 hit_cb/end_cb 定时器

### tick_movement 持续推进(服务端权威移动核心)
当前移动模型:"记住方向 + 每 tick 持续推进",tick 处理流程:
1. pending 里存的是客户端发的方向向量(dir_x/dir_y/moving),不是目标坐标
2. apply_move_dir 只记住方向到 EntityInfo.move_dir_x/y,**不推进位移**
3. 敌人 AI tick(EnemyMgr.update)内部也调 apply_move_dir 改方向
4. **tick_movement 每 tick 对所有 moving=True 的实体统一推进位移**:`info.x += move_dir_x * speed * dt`
5. 从 moved_entities 集合读服务端算出的 x/y,广播 PlayerMove{x, y, moving}

核心:服务端记住方向后每 tick 都推进,不依赖客户端输入是否到达——无累积误差,无 snap 拉回。
敌人移动也走同一套:EnemyMgr.update 调 apply_move_dir 改方向,tick_movement 统一推进。

### hit_cb 闭包陷阱修复
`for shape in config.shape_list:` 循环里定义 `async def hit_cb()`,闭包捕获 `shape` 这个循环变量。多个 shape 时所有 hit_cb 实际都会用循环结束时的最后一个 shape 值(Python 闭包经典坑)。
修复:用默认参数 `async def hit_cb(_shape=shape):` 把当前 shape 绑定到 hit_cb 局部作用域。
(当前 ATTACK_CONFIG[1002] 两个 shape 配置相同触发不了,但配置不同会出 bug)

### 发送队列:逻辑层与传输层解耦(本次重构)
**问题**:原来 `_process_tick` 里 `await self.broadcast(...)`,tick 间隔会被网络 I/O 时间拉长——broadcast 要遍历所有玩家 `await ws.send`,某玩家网络慢就卡 tick,30Hz 不稳定。

**解法**:把"算状态"和"发消息"彻底分层:
```
_process_tick(逻辑层,30Hz 严格)
    ↓ apply_xxx 改状态(纯内存,微秒级)
    ↓ _queue_broadcast(protoname, data) → self._send_queue.put_nowait(...)
    ↓ 立即返回,不等发送

_sender_loop(传输层,独立协程)
    ↓ while True: (protoname, data) = await self._send_queue.get()
    ↓ await self.broadcast(protoname, data)  # 慢就慢,不影响 tick
```

- **tick 节奏稳定**:tick 只做状态计算 + put_nowait(都不阻塞),间隔 ≈ TICK_INTERVAL_MS + 几微秒(Windows 下配合 timeBeginPeriod(1) 提频后成立)
- **某玩家网络慢只影响 sender_loop**:不卡 tick,不卡其他协程
- **顺序保证**:asyncio.Queue 是 FIFO,tick 塞的消息顺序 = 发送顺序
- **积压可接受**:sender 发得慢会积压,但客户端最终收到最新状态。积压严重说明带宽不足,需要优化广播内容(如 delta 压缩)
- **所有 broadcast 都走队列**:tick / hit_cb / end_cb / hurt_end / cleanup_player 全部用 `_queue_broadcast`,没有业务代码直接 `await self.broadcast`

### tick 机制(限定同步速率)
高频输入(PlayerMove/PlayerFacing)不立即处理,存入 `_pending_inputs`,每 33ms(TICK_INTERVAL_MS,约 30Hz)统一处理+塞队列:
- **节流**:同一 tick 内同一动作的多次输入只保留最后一次(覆盖)。客户端 60Hz 发 → 服务端 30Hz 处理
- **合并**:一个 tick 内所有玩家的变更统一塞队列,sender 按 FIFO 发出,频率从 60Hz 降到 30Hz(带宽减半)
- **哪些走 tick**:PlayerMove / PlayerFacing(高频输入)
- **哪些不走 tick**:PlayerJoin / PlayerLeave / ChatMessage / Heartbeat(低频事件,立即处理)
- **线程安全**:asyncio 单线程事件循环,handler 存 pending 时无 await(原子),不会在存入中途被 tick 打断
- **间隔稳定**:tick 不再 await broadcast(改 put_nowait),间隔不受网络 I/O 影响(见上方"发送队列"章节)
- **实测 dt 积分**:tick_movement / 敌人 AI 用 time.monotonic() 实测的真实 tick 间隔做 dt(钳制 [0, 100ms]),不用固定值——真实间隔受系统定时粒度影响会漂移,固定 dt 积分让移速系统性偏慢,是客户端移动被周期性回拉的根因
- **tick 周期用整数毫秒**:TICK_INTERVAL_MS=33 而非 1/30 浮点秒,与提频后的 1ms 定时粒度天然对齐,sleep 唤醒时刻均匀,日志读数直观

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
- `is_valid_inbound(full_name)` — 服务端 dispatch 时调,S2C 消息拒绝(客户端不该发),C2S/both 放行,未登记放行但告警;PlayerLeave 显式放行(支持客户端主动退出房间)
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
- **统一 Entity 模型已落地**:player_id 加 `player:` 前缀,GameRoom 用 _entities 表统一存玩家和木桩
- **proto 字段名已统一**:role_id/player_id → entity_id(AttackHit 的 attacker_id 保留)
- **数据存储用 dataclass**:EntityInfo 替代 dict,广播时用 dataclasses.asdict() 转 dict
- **发送队列已实现**:tick / timer 回调 / cleanup_player 都用 `_queue_broadcast` 塞队列,`_sender_loop` 独立协程负责真正广播。tick 间隔不再被网络 I/O 拉长
- **实测 dt + Windows 定时提频已实现**:tick 周期改整数毫秒 TICK_INTERVAL_MS=33;_tick_loop 用 time.monotonic() 实测真实间隔作 dt(钳制 [0,100ms])透传 _process_tick/tick_movement/EnemyMgr,修复"Windows 15.6ms 定时粒度 + 固定 dt 积分 → 服务端移速只有 71% → 客户端周期性回拉"的问题;start 时 timeBeginPeriod(1) 提频(stop 对称 timeEndPeriod),tick 真正接近 33ms 周期
- 玩家同步闭环已跑通:两个客户端能互相看到对方移动+朝向(本地蓝箭头/远程棕箭头)
- tick 机制已实现:30Hz 限定同步速率,PlayerMove/PlayerFacing/AttackStart 走 pending 统一处理
- 攻击命中判定已接入:hit_cb 调 `room.get_attack_hits` 取命中列表,遍历调 `room.apply_hurt` 设 hurt 状态(统一处理玩家和木桩)
- **hurt 硬直已实现**:hit_cb 启 hurt 定时器(start_hurt 内部 cancel 旧 attack+旧 hurt),到期 hurt_end_cb 调 apply_hurt_end 恢复 idle + 塞队列 HurtEnd
- **apply_xxx 返回值检查已加**:三个输入(move/facing/attackstart)只有 True 才塞队列,避免 hurt 期间广播造成状态矛盾
- **hit_cb 闭包陷阱已修复**:用默认参数 `_shape=shape` 绑定循环变量
- **敌人攻击已接入**:`_trigger_attack` 抽成方法并注册给 GameRoom 作为 `attack_trigger` 钩子,玩家(经 pending)和敌人(AI 状态机直接调 `room.trigger_attack`)走同一条完整攻击流程(状态变更+广播+判定帧定时器+命中扣血),修复了敌人 AI 直接调 apply_attack_start 导致"只改状态不发动"的问题
- **AttackHit 加 hurt_duration 字段**:客户端当前不读,留作未来预演/调试
- ATTACK_CONFIG 等攻击配置已从 web_server.py 迁回 game_room.py(配置属 game 层)

## EntitySpawn 增量广播（PLAN-20260818-008）

`GameRoom.create_enemy` 完成实体、CombatComponent 和 AI 初始化后，通过线程安全的实体出生钩子进入事件循环；`_broadcast_entity_spawn` 发送单条 EntitySpawn，原子包含 EntityInfo 与初始 CombatStatsEntry。刷怪不再发送 StatsInit + GameState 全量重建，只有新玩家进房/重连继续使用全量初始化。
- handler 已拆到 game/handlers/,web_server.py 只管网络层
- 热更已实现:控制台 `reload()` 命令,reload 5 模块+重新注册 handler
- 控制台已拆分到 tools/console.py
## 生存 tick 性能诊断（PLAN-20260818-010）

## 批量移动发送（PLAN-20260818-012）

发送器在控制消息连续发送达到 burst 上限后优先发送等待中的 MovementBatch，避免 SurvivalState 等高频控制事件无限饿死移动快照；诊断记录移动等待时长及 A*/重部署相关计数。

每个 tick 最多构建一条 `MovementBatch`。控制消息继续进入 FIFO 优先队列，移动消息使用可覆盖的 latest slot；发送诊断提供控制队列深度、移动槽覆盖次数、批次数和批内实体数。Pong 走高优先级单播，并与同一 websocket 的广播写入串行化。

`EnemyMgr` 维护房间级 A* 请求队列，每 tick 按 `ENEMY_MAX_PATH_TASKS_PER_TICK` 执行；`GameServer._process_tick` 在超过 `SLOW_TICK_WARNING_MS` 时才记录耗时、活跃敌人数和实际 A* 数，正常 tick 不输出日志。该诊断只读服务端权威状态，不增加协议字段。
