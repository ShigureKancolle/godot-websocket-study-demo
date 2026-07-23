# 服务端游戏逻辑层 (server-game)

覆盖:`server/game/*`
职责:唯一游戏状态持有者 GameRoom + 消息处理器 handlers

## 文件清单

| 文件 | 职责 |
|------|------|
| [game/game_room.py](file:///d:/work2/godot_demo/server/game/game_room.py) | GameRoom 类:玩家表管理、状态变更、快照生成 |
| [game/handlers/__init__.py](file:///d:/work2/godot_demo/server/game/handlers/__init__.py) | handlers 统一入口:register_all(server) 遍历子模块注册 |
| [game/handlers/player_handlers.py](file:///d:/work2/godot_demo/server/game/handlers/player_handlers.py) | 玩家 handler:PlayerJoin/PlayerMove/PlayerFacing |
| [game/handlers/chat_handlers.py](file:///d:/work2/godot_demo/server/game/handlers/chat_handlers.py) | 聊天 handler:ChatMessage/Heartbeat |

## GameRoom — 唯一状态持有者

### 核心动机
重构前玩家状态散落在 web_server.py 各处(on_player_join 里 `server.player_infos[pid] = ...`、on_player_move 里直接改坐标),带来三个问题:
1. 状态变更规则无统一入口,加校验(如移动不能穿墙)要改多处
2. 客户端容易复制 apply_move 到 GDScript,导致状态逻辑双端各写一遍
3. 状态形状被 handler 隐式约定,proto 一改两边漏改

**解决**:把"状态长什么样、怎么变"全收口到 GameRoom。handler 只做三件事:取参数→调 GameRoom 方法→发结果。

### 架构位置
```
WebSocket 收到 bytes
    ↓
MessageBus.dispatch (反序列化+路由)
    ↓
handler (on_player_move 等,在 game/handlers/)
    ↓
GameRoom.apply_move(...)   ← 唯一改状态的地方
    ↓
handler 取 room.snapshot() 或转发,调 bus.send 广播
```

GameRoom 自身不做网络 I/O,不知道 WebSocket 存在。状态层与传输层解耦。

### 内部结构
- `_players: Dict[player_id, PlayerInfoDict]` — 玩家表,dict 而非 list(O(1) 查找+天然 player_id 唯一)
- `PlayerInfoDict` 就是普通 dict,字段:player_id/player_name/level/score/x/y/facing/state。和 MessageBus.send 的入参无缝衔接

### 只读方法
- `get_player(player_id)` — 返回内部字典引用(约定只读不改,要改走变更方法)
- `has_player(player_id)` — 玩家是否在房间
- `snapshot()` — 返回 `[info.copy() for info in _players.values()]`,形状匹配 proto 的 repeated PlayerInfo。浅拷贝保证快照与内部状态解耦
- `player_count()` — 玩家数

### 状态变更方法(唯一允许改状态的地方)
- `add_player(player_id, player_info)` — 复制字典+强制覆盖 player_id(不变式:状态里的 player_id 永远=连接ID)+初始化 facing=0(如传入无此字段)。初始化 state='idle'(动画状态默认静止),和 facing=0 一样的字段默认值处理(确保字段存在)。重复加入抛 ValueError(bug 早暴露)
- `remove_player(player_id)` — pop,不存在返回 None(幂等,断连清理可能重复调用)
- `apply_move(player_id, x, y, speed=1.0, moving=False)` — 直接落地目标坐标(简化模型)。根据 moving 设 state='run'/'idle'。这把动画状态收口到服务端权威:客户端发 moving(是否在动),服务端定 state(动画状态)。玩家不存在返回 False(网络乱序是常态,不抛异常)
- `apply_facing(player_id, facing)` — 只改 facing 不改坐标。弧度归一到 [0, 2*PI)。和 apply_move 平行,朝向和移动是两个独立状态维度

### apply_move / apply_facing 的演进路径
当前是"目标坐标/朝向直接落地"的简化版。moving 参数驱动 state(动画状态),未来可加:
- 服务端按 tick 推进:`new_pos = old_pos + velocity * dt`
- 移动合法性校验:地图边界、穿墙、单次位移过大(防作弊)
- 朝向更新频率限制:鼠标高频触发,服务端应做节流
- 未来加攻击/受击时用独立的 apply_attack/apply_hurt 方法设各自的 state,和 apply_move 互不干扰

收口的好处:加这些逻辑只改对应方法,handler 和客户端都不用动。

### speed 参数当前未使用但保留
- proto PlayerMove 有 speed 字段,客户端会发
- 当前服务端忽略(直接落地目标坐标)
- 保留参数位:handler 签名和 proto 字段一一对应;后续连续移动模型时立刻可用

### 状态 vs 事件的区分
- **状态**(持续存在):位置(x/y)、朝向(facing)、等级、分数、动画状态(state) — 存在 PlayerInfo 里
  - state 是动画状态字段:idle/run/attack/hurt,客户端动画状态机读它切换动画
- **事件**(瞬时发生):一次移动、一次朝向变更、一次攻击 — speed 是移动事件属性,不存入 PlayerInfo 状态
  - moving 是 PlayerMove 的事件属性:客户端告诉服务端是否正在移动(瞬时输入),不直接声明 state
- proto 里 PlayerInfo 没有 speed、PlayerMove 有 speed,正好对应这个区分
- facing 是状态(存在 PlayerInfo),PlayerFacing 是事件(瞬时朝向变更),对应 apply_facing 只改状态里的 facing
- 服务端 apply_move 用 moving 推 state:客户端发"我在动/没在动"(事件),服务端定"处于 run/idle"(状态),客户端不直接声明 state

### 刻意不做的事(防过度设计)
- 不做网络 I/O:纯内存逻辑
- 不做插值/平滑:客户端表现层的事
- 不做持久化:重启即清空
- 不做房间分区:当前只有一个全局房间
- 不做 tick 调度:由 GameServer(网络层)决定是否定时广播,GameRoom 不知道 tick 存在

## handlers — 消息处理器

### 为什么从 web_server.py 拆出来
之前所有 handler 写在 web_server.py 里,导致:
- 网络层(web_server.py)既管 WebSocket 连接、tick 机制,又管玩家加入/移动/聊天等游戏规则
- handler 是"业务逻辑"(属 game 层),不是"网络层"
- 加新 handler 类型时改网络层代码不合适

拆分后:
- web_server.py 只管网络层(连接、tick、broadcast 基础设施)
- game/handlers/ 专注业务逻辑,按功能分文件(player/chat/...)
- 新增 handler 类型时改对应文件,不用碰网络层

### register_all(server) — 统一入口
在 main.py 创建 GameServer 实例后调用一次。热更时 `reload_all` 也会重新调此函数覆盖旧 handler。

内部遍历所有子模块,调各自的 `register(server)`:
- `player_handlers.register(server)` — PlayerJoin/PlayerMove/PlayerFacing
- `chat_handlers.register(server)` — ChatMessage/Heartbeat

### handler 的 tick 分流
高频输入(PlayerMove/PlayerFacing)走 tick,存入 `server._pending_inputs`,等 tick 统一处理+广播。
低频事件(PlayerJoin/ChatMessage)立即处理,不走 tick。
详见 [server-net.md](file:///d:/work2/godot_demo/docs/server-net.md) 的 tick 机制章节。

### handler 通过闭包捕获 server
handler 内部通过 `server.room` / `server.bus` / `server.broadcast` / `server.add_pending_input` 访问依赖。
不依赖模块级全局变量——这样热更时重新 import + 重新 register 能拿到新代码。

## 当前是"混合模型"不是纯快照
理想服务器权威快照:发 PlayerMove → 服务端改状态 → 广播 GameState 快照 → 客户端整体替换。
当前实现是"事件转发":服务端收到 PlayerMove 后既更新状态又原样转发 PlayerMove 给所有人。
后续可演进为纯快照:把 `broadcast("PlayerMove", ...)` 换成 `broadcast("GameState", room.snapshot())`,GameRoom 不用改。

## 依赖关系
- GameRoom:无外部依赖,只用标准库 typing
- handlers:依赖 server-net(GameServer/MessageBus)和 server-game(GameRoom)
- 被 main.py 装配启动(handlers.register_all)

## 当前状态
- GameRoom 功能完整:玩家加入/离开/移动/朝向状态管理已实现。动画状态管理(state 字段)已加入 apply_move,通过 moving 参数驱动
- handlers 已从 web_server.py 拆分,按功能分文件
- 不需要改动直到加新状态字段(如 inventory)或新业务逻辑(如战斗)
