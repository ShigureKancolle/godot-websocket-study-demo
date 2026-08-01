# 服务端游戏逻辑层 (server-game)

覆盖:`server/game/*` + `server/config/*`
职责:唯一游戏状态持有者 GameRoom + 消息处理器 handlers + 配置加载层

## 文件清单

| 文件 | 职责 |
|------|------|
| [game/game_room.py](file:///d:/work2/godot_demo/server/game/game_room.py) | GameRoom 类(状态持有者)+ EntityInfo dataclass |
| [game/entity_config.py](file:///d:/work2/godot_demo/server/game/entity_config.py) | 实体能力配置表:entity_config 是 config_loader 的薄包装,提供 get_capability API |
| [game/timer_mgr.py](file:///d:/work2/godot_demo/server/game/timer_mgr.py) | AttackTimer + TimerManager:攻击生命周期定时器(判定帧+结束两个时间点回调) |
| [game/collision.py](file:///d:/work2/godot_demo/server/game/collision.py) | 纯几何碰撞判定:形状定义(Circle/Sector)+ 相交判定函数,无外部依赖,可独立单测 |
| [config/config_loader.py](file:///d:/work2/godot_demo/server/config/config_loader.py) | 配置加载层:读 server/config/*.json 构造对象(攻击配置+实体能力+全局常量) |
| [game/handlers/__init__.py](file:///d:/work2/godot_demo/server/game/handlers/__init__.py) | handlers 统一入口:register_all(server) 遍历子模块注册 |
| [game/handlers/player_handlers.py](file:///d:/work2/godot_demo/server/game/handlers/player_handlers.py) | 玩家 handler:PlayerJoin/PlayerMove/PlayerFacing/AttackStart |
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

### 统一 Entity 模型(本次重构)
所有可交互物体(玩家/木桩/箱子/陷阱)统一用 `_entities: Dict[entity_id, EntityInfo]` 一张表存,不再区分 player/entity。
区别在 `entity_type` 字段决定行为能力(见下方 entity_config.py 章节):
- `player`: 可移动/可攻击/可被攻击/可断连
- `stake`: 不可移动/不可攻击/可被攻击/不可断连

ID 格式统一带类型前缀:`player:uuid-xxx` / `entity:stake_1`。

数据存储用 dataclass(EntityInfo)而非 dict:
- 字段拼写错误编译期就报错,不用等运行时崩
- IDE 自动补全字段名(entity.x 比 entity["x"] 直观)
- 类型标注本身就是文档
- 广播完整快照时用 `dataclasses.asdict()` 转 dict 给 message_bus(message_bus 不改)

### 内部结构
- `_entities: Dict[entity_id, EntityInfo]` — 实体表,dict 而非 list(O(1) 查找+天然 entity_id 唯一)
- `EntityInfo` dataclass 字段:entity_id/entity_type/x/y/facing/state/player_name/moving(后两个是 player 特有)
- **注**:原 `radius` 字段已删除——碰撞形状改由 entity_type 查 entity_config 决定(形状是类型属性,所有同类型实体形状相同)

### 只读方法
- `get_entity(entity_id) -> EntityInfo` — 返回内部 dataclass 引用(约定只读不改,要改走变更方法)
- `has_entity(entity_id)` — 实体是否在房间
- `snapshot() -> List[EntityInfo]` — 返回 `list(self._entities.values())`。调用方广播时用 `dataclasses.asdict()` 转 dict 列表给 message_bus
- `entity_count()` — 实体总数

### 状态变更方法(唯一允许改状态的地方)
所有 apply_xxx 方法先查 entity_config 的能力配置:能做才改状态,不能做返回 False。
- `add_entity(entity_id, entity_info: EntityInfo)` — 强制覆盖 entity_id(不变式:状态里的 entity_id 永远=传入的 key)。重复加入抛 ValueError(bug 早暴露)
- `remove_entity(entity_id)` — pop,不存在返回 None(幂等,断连清理可能重复调用)
- `apply_move(entity_id, x, y, speed=1.0, moving=False)` — 能力校验:can_move=False 直接拒(木桩不能动)。**硬直校验:state=="hurt" 直接拒(硬直期间锁移动)**。直接落地目标坐标(简化模型)。根据 moving 设 state='run'/'idle'。
- `apply_facing(entity_id, facing)` — 能力校验:can_move=False 直接拒(木桩不转向)。**硬直校验:state=="hurt" 直接拒(硬直期间锁朝向)**。只改 facing,弧度归一到 [0, 2*PI)。
- `apply_attack_start(entity_id, atk_id)` — 能力校验:can_attack=False 直接拒。**硬直校验:state=="hurt" 直接拒(硬直期间不能发起攻击)**。设 state='attacking'。只做状态变更,判定在 get_attack_hits
- `apply_attack_end(entity_id, atk_id)` — 攻击结束恢复 state='idle'
- `apply_hurt(target_id, atk_id)` — 能力校验:can_be_hurt=False 直接拒(墙/水地不会进入 hurt)。**统一处理玩家和木桩,不区分类型**。设 state='hurt'
- `apply_hurt_end(entity_id)` — hurt 硬直定时器到期时调,恢复 state='idle'。等下一次 PlayerMove 决定后续状态(若玩家还在按方向键,下一 tick 自然切 run)

### 攻击命中判定方法(读状态 + 调 collision 纯函数,不改状态)
- `get_attack_hits(atk_shape, attacker_id) -> List[str]` — 计算一次攻击形状的命中列表
  - 取攻击者位置/朝向 + atk_shape.shape_params 构造 collision.Sector
  - direction 直接用 facing 弧度(0=右逆时针正,和 collision.Sector.direction 语义对齐),不量化到四方向
  - **遍历 _entities 一张表,跳过自己,用 can_be_hurt 能力过滤**(墙/水地等自动跳过)
  - 每个目标用 entity_config 的 body_shape/body_params 构造 collision.Circle(碰撞形状由类型决定,不再存 EntityInfo)
  - 命中者 entity_id 加入返回列表(带前缀,调用方不用分流)
  - 调用方:web_server._process_tick 的 hit_cb 调本方法取 hit_list 广播 AttackHit

### 攻击配置 / 形状数据类已移到 config/config_loader.py
原来在 game_room.py 的 AttackShapeType/ShapeParams/SectorParams/AttackShape/AttackConfig/ATTACK_CONFIG/HURT_DURATION_MS 已迁移到 [config_loader.py](file:///d:/work2/godot_demo/server/config/config_loader.py)(JSON 单数据源方案):
- `ShapeType`(字符串常量,非 Enum)— 形状类型:sector/rect/circle/ring,实体和攻击共用
- `ShapeParams / SectorParams / CircleParams / RectParams` — 形状参数 dataclass
- `AttackShape / AttackConfig` — 攻击形状/配置 dataclass
- `EntityCapability` — 实体能力 + 碰撞形状 + 基础战斗属性 dataclass(can_move/can_attack/can_be_hurt/can_disconnect + body_shape/body_params + combat_stats)
- `CombatStats` — 类型级基础战斗属性 dataclass(max_hp/attack_power/defense),EntityInfo 初始化时拷贝一份作实例运行时状态
- 访问 API:`config_loader.get_attack_config(atk_id)` / `config_loader.get_capability(entity_type)` / `config_loader.get_combat_stats(entity_type)` / `config_loader.get_hurt_duration_ms()`

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
- **状态**(持续存在):位置(x/y)、朝向(facing)、动画状态(state) — 存在 EntityInfo 里
  - state 是动画状态字段:idle/run/attacking/hurt,客户端动画状态机读它切换动画
- **事件**(瞬时发生):一次移动、一次朝向变更、一次攻击 — speed 是移动事件属性,不存入 EntityInfo 状态
  - moving 是 PlayerMove 的事件属性:客户端告诉服务端是否正在移动(瞬时输入),不直接声明 state
- proto 里 EntityInfo 没有 speed、PlayerMove 有 speed,正好对应这个区分
- facing 是状态(存在 EntityInfo),PlayerFacing 是事件(瞬时朝向变更),对应 apply_facing 只改状态里的 facing
- 服务端 apply_move 用 moving 推 state:客户端发"我在动/没在动"(事件),服务端定"处于 run/idle"(状态),客户端不直接声明 state
- **碰撞形状是类型属性**(不是实例状态):由 entity_type 查 entity_config 决定,不存 EntityInfo。所有同类型实体形状相同(玩家一样大,木桩一样大)

### 刻意不做的事(防过度设计)
- 不做网络 I/O:纯内存逻辑
- 不做插值/平滑:客户端表现层的事
- 不做持久化:重启即清空
- 不做房间分区:当前只有一个全局房间
- 不做 tick 调度:由 GameServer(网络层)决定是否定时广播,GameRoom 不知道 tick 存在

## entity_config.py — 实体能力配置表(config_loader 薄包装)

### 为什么单独一个文件
不同 entity_type(player/stake/box/...)的行为能力不同,把这些"谁能做什么"的配置抽出来:
1. GameRoom 的 apply_xxx 方法不用 if-else 判断类型,统一查表
2. 加新类型只改 shared_config/entity_config.json,不用动 GameRoom/handlers
3. 能力是"白名单":没列在表里的类型默认零能力(安全的默认值)

### EntityCapability dataclass(定义在 config_loader,本文件复用)
- `can_move: bool` — 能否移动(apply_move 校验)。玩家 True,木桩 False
- `can_attack: bool` — 能否发起攻击(apply_attack_start 校验)。玩家 True,木桩 False
- `can_be_hurt: bool` — 能否被攻击命中(get_attack_hits 过滤 + apply_hurt 校验)。玩家/木桩 True,墙/水地 False
- `can_disconnect: bool` — 是否会断连(cleanup_player 用,避免误删非玩家实体)。玩家 True,其他 False
- `body_shape: str` — 碰撞形状类型(ShapeType.CIRCLE/RECT/...),由 entity_type 决定
- `body_params: ShapeParams` — 碰撞形状参数(如 CircleParams.radius),由 entity_type 决定

### 配置数据来源
本文件不硬编码配置,转调 `config_loader.get_capability(entity_type)`,实际数据从 `shared_config/entity_config.json` 加载(由 sync_config.py 同步到 server/config/)。

### get_capability(entity_type) -> EntityCapability
取某个类型的能力配置(含碰撞形状)。未列在表里的类型返回零能力 EntityCapability(安全的默认值),避免加新类型时忘记配能力导致崩溃。

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
- `player_handlers.register(server)` — PlayerJoin/PlayerMove/PlayerFacing/AttackStart
- `chat_handlers.register(server)` — ChatMessage/Heartbeat

### handler 的 tick 分流
高频输入(PlayerMove/PlayerFacing/AttackStart)走 tick,存入 `server._pending_inputs`,等 tick 统一处理+广播。
低频事件(PlayerJoin/ChatMessage)立即处理,不走 tick。
详见 [server-net.md](file:///d:/work2/godot_demo/docs/server-net.md) 的 tick 机制章节。

### handler 通过闭包捕获 server
handler 内部通过 `server.room` / `server.bus` / `server.broadcast` / `server.add_pending_input` 访问依赖。
不依赖模块级全局变量——这样热更时重新 import + 重新 register 能拿到新代码。

## timer_mgr.py — 攻击生命周期定时器
判定帧模型下,一次攻击有两个时间点要触发回调,都用 asyncio.sleep 等待,所以需要 asyncio.Task。
timer_mgr.py 只管"到时间调回调",不依赖 GameRoom——保持 GameRoom 是唯一状态持有者。

文件名为什么不用 timer.py:pywin32 包提供了 `timer.pyd`,`import timer` 会命中它而非本模块。虽然用 `import game.timer` 有 package 前缀不冲突,但名字相同易混淆,所以用 timer_mgr.py。

### AttackTimer(单次攻击)
- 生命周期:`start() → await hit_time → 调 hit_cb → await (duration-hit_time) → 调 end_cb`
- `cancel()` 任意时刻可取消,两个回调都不触发(若还没触发的话)
- 单 task 两段 await,取消时 CancelledError 静默退出
- hit_cb / end_cb 异常被捕获并记录,不让 task 静默挂掉

### HurtTimer(单次受击)
- 生命周期:`start() → await duration → 调 end_cb`(只有一段 await,无判定帧概念)
- `cancel()` 任意时刻可取消,end_cb 不触发
- 用途:hurt 硬直计时,到期调 apply_hurt_end 设 state="idle" + 广播 HurtEnd
- 连击场景:被命中者已在 hurt 时再被命中,start_hurt 会 cancel 旧 HurtTimer 启新的(实现"重置硬直"+ 客户端重启动画)

### TimerManager(按 player_id 管理)
- `start_attack(pid, hit_time, duration, hit_cb, end_cb)` 启动一次攻击定时器
- `cancel(player_id)` — **只取消该玩家的 attack timers,不取消 hurt timers**(命名提醒:方法名是 cancel 但范围限定 attack)。cleanup_player 时调用,防对已删除玩家操作状态
- `start_hurt(pid, duration, end_cb)` 启动一次 hurt 定时器。内部先 cancel 该玩家的 attack timers(攻击被中断)+ cancel 旧 hurt timer(连击重置),再启新 hurt timer
- `has_active(player_id)` 判断是否在攻击中
- attack timers 用 List(为连击/多段攻击留接口),hurt timers 用单个(同时只会有一个 hurt)

### 协作关系
```
GameServer._process_tick
    ↓ pending 里有 attackstart
    ↓ (TODO) 调 TimerManager.start_attack(pid, hit_time, duration, hit_cb, end_cb)
    ↓ AttackTimer 启动 asyncio.Task
await hit_time → hit_cb (apply_attack_hit + broadcast AttackHit)
await duration-hit_time → end_cb (apply_set_state idle + broadcast AttackEnd)

玩家断连 → cleanup_player → (TODO) TimerManager.cancel(pid)
```

### 当前状态
- AttackTimer + TimerManager 已实现,冒烟测试通过(正常流程/取消/取消后 hit 已触发三种情况)
- GameServer 还未接入 TimerManager:_process_tick 里直接调 apply_attack,没启动定时器
- cleanup_player 还未调 TimerManager.cancel——下一步接入时补

## collision.py — 纯几何碰撞判定

### 为什么单独一个文件
碰撞判定是纯数学(距离/角度/投影),不依赖 GameRoom 状态,也不依赖网络层。独立出来:
1. GameRoom 保持"唯一状态持有者"职责,不混入几何计算
2. 纯函数可独立单元测试(不启动服务器就能验证判定是否正确)
3. 未来加矩形/射线判定只改本文件,不破坏现有结构

### 形状定义(@dataclass)
- `Shape`(基类):`pos` 锚点,含义由子类决定
- `Circle(Shape)`:pos=圆心 + radius。用于被攻击目标的体积
- `Sector(Shape)`:pos=圆心 + radius + angle(张角) + direction(朝向,0=右逆时针正,和 PlayerInfo.facing 一致)

### 相交判定函数(对外暴露)
- `intersect_circle_circle(c1, c2)` — 圆 vs 圆:距离 ≤ 半径和
- `intersect_circle_sector(circle, sector)` — 圆 vs 扇形(攻击命中的核心):四步短路
  1. 距离判定:圆心到扇形圆心 > 扇形半径+圆半径 → 不相交
  2. 圆心在扇形圆心(重合)→ 相交
  3. 圆心在扇形角度范围内 → 相交(距离已满足)
  4. 圆心在角度范围外 → 检查圆心到两条翅膀(径向边)线段的距离 ≤ 圆半径
  - 关键:第4步只查翅膀不查弧,因为弧在角度范围内,圆心在范围外时圆要碰到弧必须先越过翅膀,翅膀远端点就在弧上
- `intersect_sector_sector(s1, s2)` — 扇形 vs 扇形(当前攻击系统暂未使用,供未来扩展如攻击互碰)
  1. 圆心在对方扇形内?
  2. 翅膀线段两两相交?
  3. 翅膀穿过对方扇形区域?

### 内部辅助函数(_前缀,不对外暴露)
- `_angle_diff(a, b)` — 角度差归一到 [-π, π](处理 350° vs 10° 这种跨零点情况)
- `_point_in_sector(point, sector)` — 点是否在扇形内
- `_point_segment_dist(point, seg_start, seg_end)` — 点到线段最短距离(投影法,t 限制在 [0,1])
- `_cross / _on_segment / _segment_segment_intersect` — 叉积法线段相交判定(straddle test)
- `_sector_wing_endpoints(sector)` — 扇形两条翅膀的远端点(弧上端点)
- `_segment_arc_intersect(p1, p2, sector)` — 线段穿过扇形弧(解参数方程求 t,检查角度范围)
- `_segment_sector_intersect(p1, p2, sector)` — 线段穿过扇形区域(端点在扇形内 / 与翅膀相交 / 穿过弧)

### 协作关系(已接入)
```
web_server._process_tick 的 hit_cb(判定帧触发)
    ↓ 调 room.get_attack_hits(shape, attacker_id)
GameRoom.get_attack_hits
    ↓ 取 attacker 状态(x/y/facing) + shape.shape_params(SectorParams)
    ↓ 构造 collision.Sector(pos, radius, angle, direction=facing)
    ↓ 遍历 _entities,跳过自己,用 can_be_hurt 过滤
    ↓ 每个目标查 entity_config.get_capability 取 body_shape/body_params 构造 Circle
    ↓ 调 collision.intersect_circle_sector(circle, sector)
    ↓ 收集命中者 entity_id 列表
web_server.hit_cb
    ↓ 遍历 hit_list 逐个调 room.apply_hurt(hurt_id, atk_id)
    ↓ 逐个调 timer_mgr.start_hurt(hurt_id, config_loader.get_hurt_duration_ms(), hurt_end_cb)
        ↓ start_hurt 内部 cancel 旧 attack timers(攻击被中断)+ cancel 旧 hurt timer(连击重置)
    ↓ broadcast("AttackHit", {attacker_id, hit_list, atk_id, hurt_duration, atk_shape_idx})

hurt 定时器到期
    ↓ hurt_end_cb 调 room.apply_hurt_end(hurt_id) 设 state="idle"
    ↓ broadcast("HurtEnd", {attacker_id, hurt_id, atk_id, hurt_duration})
```

### 当前状态
- collision.py 已实现:Circle/Sector 形状 + 三个相交判定函数 + 内部辅助函数,冒烟测试通过
- GameRoom.get_attack_hits 已实现并接入:统一遍历 _entities,用能力过滤,每个目标查 entity_config 取 body_params 构造 Circle
- 冒烟测试通过:A 攻击命中 entity:stake_1(80,0);apply_hurt 设 stake state='hurt' 成功;木桩 apply_move 被能力配置拒绝

## 当前是"混合模型"不是纯快照
理想服务器权威快照:发 PlayerMove → 服务端改状态 → 广播 GameState 快照 → 客户端整体替换。
当前实现是"事件转发":服务端收到 PlayerMove 后既更新状态又原样转发 PlayerMove 给所有人。
后续可演进为纯快照:把 `broadcast("PlayerMove", ...)` 换成 `broadcast("GameState", room.snapshot())`,GameRoom 不用改。

## 依赖关系
- GameRoom:依赖 game.collision(纯几何判定) + game.entity_config(能力配置) + config.config_loader(攻击配置+常量)
- entity_config:依赖 config.config_loader(转调 get_capability)
- config_loader:无外部依赖,只用标准库 json/math/dataclasses
- collision:无外部依赖,只用标准库 math/dataclasses
- handlers:依赖 server-net(GameServer/MessageBus)和 server-game(GameRoom)
- 被 main.py 装配启动(handlers.register_all + room.add_entity 注册木桩)

## 当前状态
- **统一 Entity 模型已落地**:所有可交互物体(玩家/木桩)统一用 _entities 表存,EntityInfo dataclass 替代 dict
- **entity_config.py 已建立**:EntityCapability 能力配置表,apply_xxx 方法先查能力再改状态
- **ID 统一加前缀**:player:uuid-xxx / entity:stake_1
- GameRoom 功能完整:实体加入/离开/移动/朝向状态管理已实现,所有方法带能力校验
- **hurt 硬直已实现**:apply_move/apply_facing/apply_attack_start 在 state=="hurt" 时拒绝输入;apply_hurt_end 恢复 idle;config_loader.get_hurt_duration_ms()=666ms
- 攻击状态三件套已实现:apply_attack_start/apply_attack_end/apply_hurt(原 apply_attack_hurt 改名,统一处理玩家和木桩)
- 攻击命中判定已接入:get_attack_hits 遍历 _entities,用 can_be_hurt 过滤,每个目标查 entity_config 取 body_params 构造 Circle
- **配置已迁移到 JSON 单数据源**:ATTACK_CONFIG / ENTITY_CAPABILITIES / HURT_DURATION_MS 改为读 shared_config/*.json(由 sync_config.py 同步)
- **EntityInfo.radius 字段已删除**:碰撞形状改由 entity_type 查 entity_config.body_shape/body_params 决定(形状是类型属性)
- **ShapeType 改名**:原 AttackShapeType → ShapeType,实体碰撞和攻击形状共用
- handlers 已从 web_server.py 拆分,按功能分文件,PlayerJoin 用 EntityInfo dataclass
- main.py 启动时硬编码注册 entity:stake_1 木桩(位置和客户端场景一致)
- **timer_mgr.py 已实现 AttackTimer + HurtTimer + TimerManager**:attack 三段定时器 + hurt 单段定时器,start_hurt 内部 cancel 旧 attack(攻击被中断)+ 旧 hurt(连击重置)
- collision.py 已实现:Circle/Sector 形状 + 相交判定函数,冒烟测试通过
- 冒烟测试通过:A 攻击命中 entity:stake_1;apply_hurt 设 stake state='hurt';木桩 apply_move 被能力配置拒绝
