# 客户端网络层 (client-net)

覆盖:`client/Script/Net/*` + `client/Script/proto/*` + `client/Script/gdproto/*`
职责:WebSocket 连接管理、消息总线(序列化/路由)、只读状态镜像、契约方向校验

## 文件清单

| 文件 | 职责 |
|------|------|
| [Net/WebScoketMgr.gd](file:///d:/work2/godot_demo/client/Script/Net/WebScoketMgr.gd) | autoload 单例,_process 轮询连接,初始化 MessageBus/Contract/StateMirror |
| [Net/WebScoketClient.gd](file:///d:/work2/godot_demo/client/Script/Net/WebScoketClient.gd) | MyWebSocketClient 单例(RefCounted),WebSocketPeer 封装:连接/轮询/分发 |
| [Net/MessageBus.gd](file:///d:/work2/godot_demo/client/Script/Net/MessageBus.gd) | MessageBus 单例(Object),序列化/反序列化/路由分发 |
| [Net/StateMirror.gd](file:///d:/work2/godot_demo/client/Script/Net/StateMirror.gd) | ClientStateMirror 单例(RefCounted),只读状态镜像,接收服务端状态更新 |
| [Net/MessageContract.gd](file:///d:/work2/godot_demo/client/Script/Net/MessageContract.gd) | MessageContract 单例(RefCounted),加载 messages.json,校验出站方向 |
| [proto/messages.json](file:///d:/work2/godot_demo/client/Script/proto/messages.json) | 客户端契约副本(从 server/proto/messages.json 手动复制) |
| [gdproto/game.gd](file:///d:/work2/godot_demo/client/Script/gdproto/game.gd) | godobuf 生成的 GDScript proto 代码 |

## WebScoketMgr.gd — autoload 轮询器

`extends Node`,注册为 autoload(项目设置里)。为什么用 Node+autoload 而非 RefCounted:需要进场景树跑 `_process` 轮询 WebSocket 状态。

### 初始化流程(_init)
```
_init_websocket():
  MessageBus.instance()                                    # 创建消息总线
  MyWebSocketClient.instance().connect_to_url(ws_path)     # 连接
  mb.set_websocket(myws._ws)                               # 给 bus 设默认连接
  _register_gd_script_constants()                          # 注册 proto 类(game.GameMessage)
  MessageContract.instance().load()                        # 加载契约
  ClientStateMirror.instance().register_handlers()         # 注册状态镜像 handler
```

### _process
每帧调 `MyWebSocketClient.instance().poll()`,状态为 CLOSED 时停止 set_process。

## WebScoketClient.gd — WebSocketPeer 封装

`extends RefCounted`, `class_name MyWebSocketClient`,static var 单例。

- `connect_to_url(url)` — 创建 WebSocketPeer 并连接
- `poll()` — 每帧调,按状态处理:
  - STATE_CONNECTING: 等待
  - STATE_OPEN: 首次连接时发 PlayerJoin + fire `websocket_connected` 信号;循环取 packet 调 `_dispatch_packet`
  - STATE_CLOSED: 打印关闭信息
- `_dispatch_packet(packet)` — `MessageBus.instance().dispatch(packet)`

### 连接成功后自动发 PlayerJoin
STATE_OPEN 首次进入时发:
```gdscript
MessageBus.instance().send("game.PlayerJoin", {
    "player_info": { "player_name": "测试名字", "level": 1, "score": 0, "x": 0.0, "y": 0.0 }
})
```
并 fire `websocket_connected` 信号(UI 层监听它显示"已连接")。
注意:PlayerJoin 不带 facing,服务端 add_player 会初始化 facing=0。

## MessageBus.gd — 客户端消息总线

`extends Object`, `class_name MessageBus`,static var 单例。和服务端 message_bus.py 对称。

### 核心机制
- `_auto_register()` — 扫描 gdproto/ 目录下 .gd 文件,用 `get_script_constant_list` 找 GameMessage 内部类并注册。老版本 Godot 可能扫描不到,降级用 `register()` 手动注册
- `register(gm_class, package)` — 手动注册一个 GameMessage 类
- `_resolve_name(name)` — 支持全名(`game.PlayerMove`)和短名(`PlayerMove`)
- `send(protoname, dict, websocket)` — 字典→protobuf→bytes→`ws.send(data)`(async)
- `dispatch(data, ctx)` — bytes→protobuf→字典→调 handler。遍历所有已注册 GameMessage 类尝试解析
- `onproto(protoname, handler)` — 注册 handler,register() 之前调用会暂存到 `_pending_handlers`,register() 后自动绑定

### _player_id 的提取
MessageBus 在 `_init` 里自己注册了 `game.PlayerJoin` 的 handler `_on_player_join`,从消息里提取 player_id 存到 `_player_id`(注意:取的是 `player_id` 不是 `player_name`,之前有 bug 用错了字段)。

### PB 数据结构(godobuf 生成)
godobuf 生成的 proto 代码用 `msg.data` 字典存储字段,结构是 `{tag: {field, state, ...}}`,和服务端 protobuf 的 API 不同。MessageBus._message_to_dict / _fill_message 适配这个结构。

## StateMirror.gd — 客户端只读状态镜像

`extends RefCounted`, `class_name ClientStateMirror`,static var 单例。

### 核心原则
**只接收、只镜像、只读暴露;绝不本地推演状态**。和服务端 GameRoom 对照:
- GameRoom.apply_move(pid, x, y) — 改状态(主人)
- ClientStateMirror._on_move(d) — 接收服务端广播,更新镜像(奴仆)

客户端没有 apply_move 等变更方法,结构上杜绝状态逻辑重复。

### 信号(通知渲染层)
- `state_replaced(players: Array)` — 全量替换,渲染层重建所有角色
- `player_updated(player_info: Dictionary)` — 单个玩家变化(加入/移动),渲染层更新一个角色
- `player_removed(player_id: String)` — 玩家离开,渲染层移除角色

### 内部状态
- `_players: Dictionary` — 玩家镜像表(player_id -> info dict),和服务端 GameRoom._players 结构一致
- `_local_player_id: String` — 本地玩家ID(从 PlayerJoin 响应提取,渲染层用它区分自己/别人)

### handler(注册给 MessageBus)
- `_on_game_state(data)` — 整体替换镜像,emit state_replaced
- `_on_player_join(data)` — 增量添加玩家,emit player_updated(兼容本地玩家ID提取)
- `_on_player_move(data)` — 更新坐标(只改 x/y,不整体替换);并从 moving 字段推断 state(moving=true→"run", false→"idle",和服务端 apply_move 一致)存入 player 字典,emit player_updated(此时携带的 player 字典含 state 字段)
- `_on_player_facing(data)` — 更新朝向(只改 facing,不整体替换),emit player_updated。复用同一信号,Role.on_player_updated 里判断 facing 字段转发给 PlayerVisual
- `_on_player_leave(data)` — 移除玩家,emit player_removed

> 注:`_on_player_move` 里从 moving 推断 state 只是**字段映射**(服务端广播的 PlayerMove 只有 moving,没有 state,state 存在服务端 PlayerInfo 里),不是状态逻辑重复。真正的状态权威在服务端——GameState 快照会带服务端的 state 字段,可对账。

### 容错策略
- PlayerJoin 收到已存在玩家:覆盖(服务端可能重发,以最新为准)
- PlayerMove/PlayerFacing 收到不存在的玩家:忽略(等全量快照修正)
- PlayerLeave 不存在也 erase(幂等)

## MessageContract.gd — 客户端契约

`extends RefCounted`, `class_name MessageContract`,static var 单例。和服务端 message_contract.py 对称。

- `load(path="")` — 默认从 `client/Script/proto/messages.json` 加载
- `is_valid_outbound(full_name)` — send 时调,S2C 消息拒绝(客户端不该发),C2S/both 放行
- `is_valid_inbound_handler(full_name)` — onproto 注册时调,C2S 消息告警"可能永远不会被触发"(只告警不阻止)
- `is_state_affecting(short_name)` — 查询是否影响状态

契约缺失时不阻断运行(只告警)。

## 为什么用 RefCounted + static var 而非 autoload
StateMirror/MessageContract/WebSocketClient 都是纯数据容器,不参与 _process/_physics_process,用 RefCounted 更轻量。懒加载避免 autoload 初始化顺序问题(StateMirror 依赖 MessageBus 已就绪)。

WebScoketMgr 需要 _process 轮询,用 Node + autoload。

## 依赖关系
- 依赖 gdproto(godobuf 生成的 proto 代码)
- 依赖 proto/messages.json(契约副本)
- 被 client-role 依赖:StateMirror 的信号驱动 Role 更新
- 被 client-ui 依赖:WebScoketClient fire 的 websocket_connected 信号驱动 UI

## 当前状态
- 功能完整:连接、消息收发、状态镜像、契约校验都已实现
- 玩家同步闭环已跑通
- 注意:WebScoketMgr/WebScoketClient 是原拼写(Scoket),已遍布代码,暂不改
