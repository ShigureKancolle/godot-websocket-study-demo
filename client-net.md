# 客户端网络层 (client-net)

覆盖:`client/Script/Net/*` + `client/Script/proto/*` + `client/Script/gdproto/*`
职责:WebSocket 连接管理、消息总线(序列化/路由)、只读状态镜像、契约方向校验

## 文件清单

| 文件 | 职责 |
|------|------|
| [Net/WebScoketMgr.gd](file:///d:/work2/godot_demo/client/Script/Net/WebScoketMgr.gd) | autoload 单例,_process 轮询连接,初始化 MessageBus/Contract/StateMirror |
| [Net/WebScoketClient.gd](file:///d:/work2/godot_demo/client/Script/Net/WebScoketClient.gd) | MyWebSocketClient 单例(RefCounted),WebSocketPeer 封装:连接/轮询/分发 |
| [Net/MessageBus.gd](file:///d:/work2/godot_demo/client/Script/Net/MessageBus.gd) | MessageBus 单例(Object),序列化/反序列化/路由分发 |
| [Net/EntityInfo.gd](file:///d:/work2/godot_demo/client/Script/Net/EntityInfo.gd) | ClientEntityInfo 强类型类(RefCounted)+ EntityType 枚举,客户端镜像实体数据载体 |
| [Net/StateMirror.gd](file:///d:/work2/godot_demo/client/Script/Net/StateMirror.gd) | ClientStateMirror 单例(RefCounted),只读状态镜像,接收服务端状态更新(存 ClientEntityInfo) |
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
    "entity_info": { "player_name": "测试名字", "x": 0.0, "y": 0.0 }
})
```
并 fire `websocket_connected` 信号(UI 层监听它显示"已连接")。
注意:统一 Entity 模型后,字段名是 `entity_info`(原 `player_info` 已废弃);服务端 add_entity 会初始化 facing=0。

## MessageBus.gd — 客户端消息总线

`extends Object`, `class_name MessageBus`,static var 单例。和服务端 message_bus.py 对称。

### 核心机制
- `_auto_register()` — 扫描 gdproto/ 目录下 .gd 文件,用 `get_script_constant_list` 找 GameMessage 内部类并注册。老版本 Godot 可能扫描不到,降级用 `register()` 手动注册
- `register(gm_class, package)` — 手动注册一个 GameMessage 类
- `_resolve_name(name)` — 支持全名(`game.PlayerMove`)和短名(`PlayerMove`)
- `send(protoname, dict, websocket)` — 字典→protobuf→bytes→`ws.send(data)`(async)
- `dispatch(data, ctx)` — bytes→protobuf→字典→调 handler。遍历所有已注册 GameMessage 类尝试解析
- `onproto(protoname, handler)` — 注册 handler,register() 之前调用会暂存到 `_pending_handlers`,register() 后自动绑定

### _local_entity_id 的提取
MessageBus 在 `_init` 里自己注册了 `game.PlayerJoin` 的 handler `_on_player_join`,从消息里提取 entity_id:
- 字段从 `entity_info.entity_id` 取(统一 Entity 模型后,PlayerJoin 消息体是 EntityInfo 而非 PlayerInfo)
- 提取后写入 `ClientStateMirror._local_entity_id`(渲染层用它区分本地/远程玩家)
- `MessageBus._player_id` 仍保留作为兼容别名(部分老代码引用),推荐用 `ClientStateMirror.local_entity_id()`

### PB 数据结构(godobuf 生成)
godobuf 生成的 proto 代码用 `msg.data` 字典存储字段,结构是 `{tag: {field, state, ...}}`,和服务端 protobuf 的 API 不同。MessageBus._message_to_dict / _fill_message 适配这个结构。

## StateMirror.gd — 客户端只读状态镜像

`extends RefCounted`, `class_name ClientStateMirror`,static var 单例。

### 核心原则
**只接收、只镜像、只读暴露;绝不本地推演状态**。和服务端 GameRoom 对照:
- GameRoom.apply_move(eid, x, y) — 改状态(主人)
- ClientStateMirror._on_move(d) — 接收服务端广播,更新镜像(奴仆)

客户端没有 apply_move 等变更方法,结构上杜绝状态逻辑重复。

### 统一 Entity 模型 + 强类型 ClientEntityInfo(本次重构)
和服务端对齐:所有可交互物体(玩家/木桩)统一用 `_entities` 一张表存,不再区分 _players。
- entity_id 带类型前缀: "player:uuid-xxx" / "entity:stake_1"
- entity_type 用 `ClientEntityInfo.EntityType` 枚举(PLAYER/STAKE/UNKNOWN),从服务端字符串 `"player"`/`"stake"` 转换而来
- `_entities` 存的是 `ClientEntityInfo`(强类型 RefCounted),不再存 Dictionary
- 字段访问用 `info.x` / `info.state` 而非 `info["x"]` / `info["state"]`
- 渲染层(dead_man_scene)根据 entity_type 创建不同 Role 配置

### 信号(通知渲染层)
- `state_replaced(entities: Array)` — 全量替换,渲染层重建所有实体(玩家+木桩)。元素是 ClientEntityInfo
- `entity_updated(entity_info: ClientEntityInfo)` — 单个实体变化(加入/移动/朝向/动画状态),渲染层更新一个实体
- `entity_removed(entity_id: String)` — 实体离开(玩家断连),渲染层移除实体

### 内部状态
- `_entities: Dictionary` — 实体镜像表(entity_id -> ClientEntityInfo),和服务端 GameRoom._entities 结构对齐(服务端存 EntityInfo dataclass,客户端存 ClientEntityInfo RefCounted)
- `_local_entity_id: String` — 本地玩家 entity_id(从 PlayerJoin 响应提取,渲染层用它区分自己/别人)

### 只读访问 API
- `all_entities() -> Array` — 返回所有 ClientEntityInfo(元素是强类型)
- `get_entity(entity_id) -> ClientEntityInfo` — 返回单个实体,不存在返回 null
- `local_entity_id() -> String` — 本地玩家 entity_id
- `entity_count() -> int` — 当前镜像实体数

### handler(注册给 MessageBus)
handler 接收 `data: Dictionary`(godobuf 反序列化的原始 dict),内部调 `ClientEntityInfo.from_dict(d)` 转成强类型再存。dict→强类型的转换集中在此处,业务层不再碰 dict。

- `_on_game_state(data)` — 整体替换镜像(读 `entities` 字段),逐个 `from_dict` 转 ClientEntityInfo 后存,emit state_replaced
- `_on_player_join(data)` — 增量添加实体(读 `entity_info` 字段并 `from_dict`),emit entity_updated(兼容本地 entity_id 提取)
- `_on_player_move(data)` — 取出 ClientEntityInfo,改 x/y;并从 moving 字段推断 state(moving=true→"run", false→"idle",和服务端 apply_move 一致)写入 `entity.state`,emit entity_updated
- `_on_player_facing(data)` — 取出 ClientEntityInfo,改 facing,emit entity_updated。复用同一信号,Role.on_entity_updated 里判断 facing 字段转发给 PlayerVisual
- `_on_player_leave(data)` — 移除实体,emit entity_removed
- `_on_attack_start(data)` — 取出攻击者 ClientEntityInfo,设 `entity.state = "attacking"` + `entity.atk_id = atk_id`(和服务端 apply_attack_start 对齐),emit entity_updated
- `_on_attack_end(data)` — 取出攻击者 ClientEntityInfo,设 `entity.state = "idle"`,emit entity_updated
- `_on_attack_hit(data)` — 攻击命中广播:遍历 `hit_list` 逐个取出被命中者 ClientEntityInfo,设 `entity.state = "hurt"`,emit entity_updated。**只处理 hit_list,不处理 attacker_id**(攻击者 state 由 AttackStart 设为 attacking)

> 注:`_on_player_move` 里从 moving 推断 state 只是**字段映射**(服务端广播的 PlayerMove 只有 moving,没有 state,state 存在服务端 EntityInfo 里),不是状态逻辑重复。真正的状态权威在服务端——GameState 快照会带服务端的 state 字段,可对账。

### 容错策略
- PlayerJoin 收到已存在实体:覆盖(服务端可能重发,以最新为准)
- PlayerMove/PlayerFacing 收到不存在的实体:忽略(等全量快照修正)
- PlayerLeave 不存在也 erase(幂等)

## EntityInfo.gd — 客户端镜像实体(强类型)

`extends RefCounted`, `class_name ClientEntityInfo`。客户端镜像实体的数据载体,和服务端 `EntityInfo` dataclass 字段对齐。

### 为什么不用 Dictionary
之前 StateMirror._entities 存 Dictionary,字段访问靠字符串 key(`entity["state"]`),问题:
- 字段名拼错运行时才报错,IDE 无法补全/检查
- 类型不明确,`entity["facing"]` 是 float 还是 int 全靠记忆
- 容易写出 `entity["atk_id"] = ...` 这种往字典塞非 EntityInfo 字段的代码

改用强类型 RefCounted:
- 字段类型在编辑器/IDE 可见,拼错编译期报错
- `from_dict(d)` 集中做 dict→强类型的转换,全工厂数 dict 访问只在此处
- 字段不可随意扩展:加字段必须改类定义,字段集合显式

### EntityType 枚举
```
enum EntityType { PLAYER, STAKE, UNKNOWN }
```
- 服务端 entity_type 是字符串("player"/"stake")。客户端转成枚举做 match,避免字符串拼错
- `from_string(s)` 静态方法做字符串→枚举转换,未知字符串返回 UNKNOWN(容错)
- `type_to_string(t)` 反向转换(给日志/调试用)
- 实例方法 `type_string()` 返回当前 entity_type 的字符串表示

### 字段(和服务端 EntityInfo dataclass 对齐)
- `entity_id: String` — 实体ID(带类型前缀)
- `entity_type: EntityType` — 实体类型枚举
- `x, y: float` — 坐标
- `facing: float` — 朝向(弧度)
- `state: String` — 动画状态(idle/run/attacking/hurt)
- `player_name: String` — 玩家名字(只有 player 类型有)
- `atk_id: int` — 攻击ID(非 EntityInfo proto 字段,攻击消息携带,客户端临时存)

### 静态构造
- `from_dict(d: Dictionary) -> ClientEntityInfo` — 从 godobuf 反序列化的 dict 构造强类型对象,集中处理字段名/类型转换。调用方:`StateMirror._on_game_state` / `_on_player_join`

### 调试
- `_to_string()` — print/str 调用时自动调用,格式化输出实体信息(DebugCommands.gd 的 cmd_state/cmd_me 直接受益)

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
