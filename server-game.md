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
| [config/config_loader.py](file:///d:/work2/godot_demo/server/config/config_loader.py) | 配置加载层:读 server/config/*.json 构造对象(攻击配置+实体能力+全局常量+视野) |
| [game/enemy_mgr.py](file:///d:/work2/godot_demo/server/game/enemy_mgr.py) | 敌人 AI 管理器:持有每个敌人的 AI 状态机,每 tick 驱动决策 |
| [game/ai/enemy_ai_machine.py](file:///d:/work2/godot_demo/server/game/ai/enemy_ai_machine.py) | 敌人 AI 状态机(状态注册/切换/update) |
| [game/ai/ai_state_base.py](file:///d:/work2/godot_demo/server/game/ai/ai_state_base.py) | AI 状态基类(enter/exit/update 生命周期) |
| [game/ai/states/](file:///d:/work2/godot_demo/server/game/ai/states) | 具体 AI 状态:patrol/chase/attack/look_around |
| [game/helper/ai_state_helper.py](file:///d:/work2/godot_demo/server/game/helper/ai_state_helper.py) | AI 状态帮助:视锥寻人(is_in_sight/find_nearest_entity_in_sight)+ 寻路 + 状态切换 |
| [game/handlers/__init__.py](file:///d:/work2/godot_demo/server/game/handlers/__init__.py) | handlers 统一入口:register_all(server) 遍历子模块注册 |
| [game/handlers/player_handlers.py](file:///d:/work2/godot_demo/server/game/handlers/player_handlers.py) | 玩家 handler:PlayerJoin/PlayerMove/PlayerFacing/AttackStart |
| [game/handlers/chat_handlers.py](file:///d:/work2/godot_demo/server/game/handlers/chat_handlers.py) | 聊天 handler:ChatMessage/Heartbeat |

## GameRoom — 唯一状态持有者

### 核心动机
重构前玩家状态散落在 web_server.py 各处(on_player_join 里 `server.player_infos[pid] = ...`、on_player_move 里直接改坐标),带来三个问题:
1. 状态变更规则无统一入口,加校验(如移动不能穿墙)要改多处
2. 客户端容易复制 apply_move_dir 到 GDScript,导致状态逻辑双端各写一遍
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
GameRoom.apply_move_dir(...)   ← 唯一改状态的地方
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
- `EntityInfo` dataclass 字段:entity_id/entity_type/x/y/facing/state/ai_state/player_name/account_id/moving
  - `ai_state` — AI 状态(patrol/chase/attack/look_around,只有敌人填,玩家/木桩留空)。和 `state`(动画状态)是两个独立维度,由 EnemyAIMachine 状态切换钩子同步进 EntityInfo(供 GameState 快照带初始值),客户端据此切换视锥形态
  - `account_id` — 客户端本地存档生成的账号ID(跨会话稳定),PlayerJoin 时从消息读入;web_server 优先用它作 player_id
- **注**:原 `radius` 字段已删除——碰撞形状改由 entity_type 查 entity_config 决定(形状是类型属性,所有同类型实体形状相同)

### 只读方法
- `get_entity(entity_id) -> EntityInfo` — 返回内部 dataclass 引用(约定只读不改,要改走变更方法)
- `has_entity(entity_id)` — 实体是否在房间
- `snapshot() -> List[EntityInfo]` — 返回 `list(self._entities.values())`。调用方广播时用 `dataclasses.asdict()` 转 dict 列表给 message_bus
- `entity_count()` — 实体总数

### 状态变更方法(唯一允许改状态的地方)
所有 apply_xxx 方法先查 entity_config 的能力配置:能做才改状态,不能做返回 False。

**HurtResult 枚举**(apply_hurt 返回值):区分受击后的状态分支,让调用方(web_server 的 hit_cb)据此决定启 HurtTimer 还是 DeadTimer。
- `FAILED` — 实体不存在/不能被攻击/无战斗组件,调用方不应有后续动作
- `HURT` — 扣血但没死,调用方启 HurtTimer(硬直)
- `DEAD` — 扣血后 hp<=0 且 can_die=True,调用方启 DeadTimer(死亡延迟移除)

**_is_input_locked(info) 方法**:统一判断实体是否处于输入锁定状态。锁定状态集合 `_INPUT_LOCKED_STATES = {"hurt", "dead", "attacking"}`,apply_move_dir/apply_facing/apply_attack_start 三个输入方法统一调本方法做拒绝判定。新增锁定状态时只改常量集合,不用改各 apply_xxx 方法(避免散落 if state=="hurt" 漏掉 dead 之类的新状态)。

- `add_entity(entity_id, entity_info: EntityInfo)` — 强制覆盖 entity_id(不变式:状态里的 entity_id 永远=传入的 key)。重复加入抛 ValueError(bug 早暴露)
- `remove_entity(entity_id)` — pop,不存在返回 None(幂等,断连清理可能重复调用)。连带清理 `_combats`(战斗组件)+ `_knockbacks`(击退状态)+ EnemyMgr AI 状态,避免遗留幽灵状态
- `create_enemy(entity_type, pos) -> EntityInfo` — 敌人创建语法糖:分配 `enemy:{type}_{序号}` entity_id(序号按该类型现有数量+1 推算)→ 构造 EntityInfo 设好位置 → `add_entity`(自动建 CombatComponent)→ `EnemyMgr.on_enemy_created` 挂 AI(默认 patrol)。创建完成后回调 `_entity_spawn_hook` 通知网络层广播新实体——**GM 运行时调 room.create_enemy 时,在线客户端才能立刻看到新敌人**
- `apply_move_dir(entity_id, dir_x, dir_y, moving, dt)` — **只记住方向,不推进位移!** 能力校验:can_move=False 直接拒(木桩不能动)。**输入锁定校验:调 `_is_input_locked`,hurt(硬直)/dead(死亡)/attacking(攻击中)期间拒移动**。归一化方向存到 `EntityInfo.move_dir_x/y`,设 moving/state。位移推进由 `tick_movement` 每 tick 统一做。moving=false 时清零方向,设 state='idle'。
- `tick_movement(dt) -> list` — 每 tick 推进位移,分两段:**① 击退推进** 遍历 `_knockbacks` 表,对被击退实体按 vx/vy 推进(不受输入锁定影响,硬直中被推走),耗时耗尽自动清理;**② 普通移动推进** 所有 moving=True 且未锁定实体的位移 `info.x += move_dir_x * speed * dt`(击退中的实体不叠加普通移动)。返回本 tick 移动了的 entity_id 列表(供 web_server 收集广播)。**这是服务端权威移动的核心**:服务端记住方向后每 tick 都推进,不依赖客户端输入是否到达,无累积误差。
- `apply_facing(entity_id, facing)` — 能力校验:can_move=False 直接拒(木桩不转向)。**输入锁定校验:调 `_is_input_locked`,hurt/dead/attacking 期间锁朝向**。只改 facing,弧度归一到 [0, 2*PI)。
- `trigger_attack(entity_id, atk_id) -> bool` — **攻击发动统一入口**(玩家和敌人都调本方法)。内部转调 GameServer 注册的 `attack_trigger` 钩子(由 web_server._trigger_attack 实现),完成 apply_attack_start + 广播 AttackStart + 注册 AttackTimer(hit_cb/end_cb)的完整流程。钩子未注册时退化为 apply_attack_start(供单测)。**AI 不要直接调 apply_attack_start**——那只改状态,不广播也不判定,敌人攻击会"空挥"
- `set_attack_trigger(cb)` — 注册攻击发动回调(由 GameServer 在 __init__ 时调),cb 签名 `(attacker_id, atk_id) -> bool`
- `set_entity_spawn_hook(cb)` — 注册实体创建回调(由 GameServer 在 __init__ 时调),cb 签名 `(entity_info) -> None`。在 `create_enemy` 的 `add_entity` 之后被调,网络层据此广播新实体(GameState + StatsInit 全量快照)
- `apply_attack_start(entity_id, atk_id)` — 能力校验:can_attack=False 直接拒。**输入锁定校验:调 `_is_input_locked`,hurt/dead 期间不能发起攻击**;另外 state=="attacking" 也拒(防连点造成一次攻击多次伤害)。设 state='attacking'。只做状态变更,判定在 get_attack_hits。**由 trigger_attack 内部调用,外部一般不直接调**
- `apply_attack_end(entity_id, atk_id)` — 攻击结束恢复 state='idle'
- `apply_hurt(target_id, atk_id, atk_shape_idx, damage, attacker_id) -> HurtResult` — 能力校验:can_be_hurt=False 直接拒返回 FAILED(墙/水地不会进入 hurt)。**统一处理玩家和木桩,不区分类型**。扣血后判定:cur_hp<=0 且 can_die=True → 设 state='dead' 返回 DEAD(调用方启 DeadTimer);否则设 state='hurt' 返回 HURT(调用方启 HurtTimer)。玩家 can_die=False,hp 扣到 0 也走 HURT 分支(死亡流程暂不实现)。
- `apply_dead(target_id, atk_id) -> bool` — 设 state='dead'。由 apply_hurt 内部死亡分支调用,也可由外部(如 Boss 机制)直接调用。能力校验:can_die=False 直接拒。**只设状态不做 remove_entity**——实体移除由 DeadTimer 到期后调 remove_entity 完成,让客户端有时间播死亡动画(服务端"立即判定死亡"但"延迟移除实体")。
- `apply_hurt_end(entity_id)` — hurt 硬直定时器到期时调,恢复 state='idle'。等下一次 PlayerMove 决定后续状态(若玩家还在按方向键,下一 tick 自然切 run)
- `apply_knockback(target_id, attacker_id, distance) -> bool` — **击退**:把目标从攻击者中心向外推 distance 像素。方向 = normalize(目标位置-攻击者位置),时长 = hurt 硬直时长,速度 = distance / 时长 → 整个硬直期间匀速推出,「硬直结束 = 击退结束」。**不按 can_move 过滤**(木桩也会被击退)。击退状态存 `_knockbacks`(服务端瞬态,不进 EntityInfo——避免 asdict 污染 proto 快照广播),由 tick_movement 每 tick 推进位移,新位置走现有 PlayerMove 广播。由 web_server.hit_cb 在「连段最后一段」命中时调用

### 攻击命中判定方法(读状态 + 调 collision 纯函数,不改状态)
- `get_attack_hits(atk_shape, attacker_id) -> List[str]` — 计算一次攻击形状的命中列表
  - 取攻击者位置/朝向 + atk_shape.shape_params 构造 collision.Sector
  - direction 直接用 facing 弧度(0=右逆时针正,和 collision.Sector.direction 语义对齐),不量化到四方向
  - **阵营掩码:从攻击者实体类型取 `attack_mask`,和目标 `hit_layer` 按位与,为 0 跳过**(玩家 attack_mask=2 打敌人/木桩层,敌人 attack_mask=1 打玩家层)。阵营是实体属性,挂在实体上后玩家和敌人可复用同一 atk_id 各打各阵营
  - **遍历 _entities 一张表,跳过自己,用 can_be_hurt 能力过滤**(墙/水地等自动跳过)
  - **死亡过滤:state=="dead" 的实体跳过**(避免鞭尸)。和 can_be_hurt 正交:can_be_hurt 是能力层(能不能被打),state=="dead" 是状态层(当前还能不能被打)
  - 每个目标用 entity_config 的 body_shape/body_params 构造 collision.Circle(碰撞形状由类型决定,不再存 EntityInfo)
  - 命中者 entity_id 加入返回列表(带前缀,调用方不用分流)
  - 调用方:web_server._trigger_attack 的 hit_cb 调本方法取 hit_list 广播 AttackHit

### 击退(Knockback)——攻击连段最后一段推开目标

**动机**:攻击间隔(583ms)比 hurt 硬直(666ms)短,若不击退,攻击者可在目标硬直中无限连击到死。连段最后一段命中后把目标推开,硬直结束时已脱离下一击范围,被打的人有反击/逃跑的机会。

**规则**:
- 只对连段「最后一段」触发(`_shape_idx == len(shape_list) - 1`),非最后一段不击退(避免连段中途推开目标打断连击)。单段攻击(如 1001)唯一一段即最后一段。
- 距离取该 shape 的 `knockback_distance`(像素),>0 才击退;死亡(DEAD)不击退。
- 方向 = 被击者位置 - 攻击者位置(向外推),与攻击者 facing 无关;位置重合时跳过。

**数据流**:`web_server.hit_cb`(HURT 分支,最后一段)→ `room.apply_knockback` 写 `_knockbacks` → `tick_movement` 每 tick 推进位移并进 moved_ids → 现有 `PlayerMove` 广播 → 客户端 lerp 跟随(本地玩家 hurt 期间跟随服务端位置,见 client-role.md)。

### 攻击配置 / 形状数据类已移到 config/config_loader.py
原来在 game_room.py 的 AttackShapeType/ShapeParams/SectorParams/AttackShape/AttackConfig/ATTACK_CONFIG/HURT_DURATION_MS 已迁移到 [config_loader.py](file:///d:/work2/godot_demo/server/config/config_loader.py)(JSON 单数据源方案):
- `ShapeType`(字符串常量,非 Enum)— 形状类型:sector/rect/circle/ring,实体和攻击共用
- `ShapeParams / SectorParams / CircleParams / RectParams` — 形状参数 dataclass
- `AttackShape / AttackConfig` — 攻击形状/配置 dataclass。`AttackShape.knockback_distance`(像素)= 击退距离,只在连段最后一段配置,0=不击退
- `EntityCapability` — 实体能力 + 碰撞形状 + 基础战斗属性 dataclass(can_move/can_attack/can_be_hurt/can_disconnect + body_shape/body_params + combat_stats)
- `CombatStats` — 类型级基础战斗属性 dataclass(max_hp/attack_power/defense),EntityInfo 初始化时拷贝一份作实例运行时状态
- 访问 API:`config_loader.get_attack_config(atk_id)` / `config_loader.get_capability(entity_type)` / `config_loader.get_combat_stats(entity_type)` / `config_loader.get_hurt_duration_ms()` / `config_loader.get_dead_duration_ms(entity_type)`(死亡动画时长,can_die=False 返回 0)

### apply_move_dir / tick_movement 移动模型
当前移动模型:"记住方向 + 每 tick 持续推进":
- 客户端发方向向量(dir_x/dir_y),服务端 apply_move_dir 只记住方向到 EntityInfo.move_dir_x/y,不推进位移
- tick_movement 每 tick 对所有 moving=True 的实体统一按 dir * speed * dt 推进位移。**dt 是实测 tick 间隔**(GameServer._tick_loop 用 time.monotonic() 测得并钳制,详见 server-net.md),不能用固定 TICK_INTERVAL——真实 tick 间隔受系统定时粒度影响会漂移(Windows 默认粒度下 33ms 请求实际约 47ms),固定 dt 积分让服务端移速系统性偏慢,客户端预测对账累积超阈值 → 周期性回拉(移动拉扯根因)
- speed 从 config_loader.get_speed(entity_type) 查配置(防作弊,不从消息读)
- moving=false 时清零方向,只更新 state
- **核心优势**:服务端记住方向后每 tick 都推进,不依赖客户端输入是否到达——即使某个 tick 没收到输入,服务端也会按记住的方向继续推进,无累积误差,无 snap 拉回

未来可加:
- 移动合法性校验:地图边界、穿墙、单次位移过大(防作弊)
- 朝向更新频率限制:鼠标高频触发,服务端应做节流
- 实例级 speed 变化(减速/加速 buff):在 EnemyAIState 或 EntityInfo 加实例 speed 字段

收口的好处:加这些逻辑只改对应方法,handler 和客户端都不用动。

### speed 从配置读取(不再从消息读)
- proto PlayerMove 的 speed 字段已废弃(保留兼容)
- 服务端 apply_move_dir / tick_movement 调 `config_loader.get_speed(entity_type)` 查配置
- 速度是「类型属性」(所有玩家同速、所有史莱姆同速),防作弊且配置统一
- 运行时若需减速/加速 buff,应该改实例级 speed 字段(目前未实现,YAGNI)

### 状态 vs 事件的区分
- **状态**(持续存在):位置(x/y)、朝向(facing)、动画状态(state) — 存在 EntityInfo 里
  - state 是动画状态字段:idle/run/attacking/hurt,客户端动画状态机读它切换动画
- **事件**(瞬时发生):一次移动、一次朝向变更、一次攻击 — speed 是移动事件属性,不存入 EntityInfo 状态
  - moving 是 PlayerMove 的事件属性:客户端告诉服务端是否正在移动(瞬时输入),不直接声明 state
- proto 里 EntityInfo 没有 speed、PlayerMove 有 speed,正好对应这个区分
- facing 是状态(存在 EntityInfo),PlayerFacing 是事件(瞬时朝向变更),对应 apply_facing 只改状态里的 facing
- 服务端 apply_move_dir 用 moving 推 state:客户端发"我在动/没在动"(事件),服务端定"处于 run/idle"(状态),客户端不直接声明 state
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
- `can_move: bool` — 能否移动(apply_move_dir 校验)。玩家 True,木桩 False
- `can_attack: bool` — 能否发起攻击(apply_attack_start 校验)。玩家 True,木桩 False
- `can_be_hurt: bool` — 能否被攻击命中(get_attack_hits 过滤 + apply_hurt 校验)。玩家/木桩 True,墙/水地 False
- `can_disconnect: bool` — 是否会断连(cleanup_player 用,避免误删非玩家实体)。玩家 True,其他 False
- `can_die: bool` — 能否进入死亡流程(apply_hurt 内 hp<=0 时判定)。player=False(暂不实现),stake=False(木桩不会死),敌人=True。can_die=False 时 hp 扣到 0 也走 hurt 分支
- `dead_duration_ms: int` — 死亡动画时长(毫秒)。can_die=False 时为 0。DeadTimer 用此值计时,到期后 remove_entity + 广播 EntityRemove,让客户端有时间播死亡动画
- `body_shape: str` — 碰撞形状类型(ShapeType.CIRCLE/RECT/...),由 entity_type 决定
- `body_params: ShapeParams` — 碰撞形状参数(如 CircleParams.radius),由 entity_type 决定
- `hit_layer: int` — 被判定层掩码(被哪些攻击命中)。player=1,enemy/stake=2
- `attack_mask: int` — 攻击判定掩码(发起攻击时打哪些 hit_layer)。player=2(打敌人层),enemy=1(打玩家层),stake=0(不能攻击)。get_attack_hits 用 `attacker_cap.attack_mask & target_cap.hit_layer` 过滤,玩家和敌人可复用同一 atk_id 各打各阵营

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

### DeadTimer(单次死亡)
- 生命周期:`start() → await duration → 调 end_cb`(单段 await,结构和 HurtTimer 一样)
- `cancel()` 任意时刻可取消,end_cb 不触发
- 用途:死亡动画计时,到期调 remove_entity + 广播 EntityRemove(由调用方在 end_cb 闭包里绑定)
- 和 HurtTimer 保持独立类而非复用:语义不同(HurtTimer 恢复 idle / DeadTimer 移除实体),未来死亡流程可能加逻辑(如死亡时还能被推动),届时只改 DeadTimer 不影响 hurt 逻辑
- 同时只会有一个 dead timer(死亡期间不会再死)

### TimerManager(按 player_id 管理)
- `start_attack(pid, hit_time, duration, hit_cb, end_cb)` 启动一次攻击定时器
- `cancel(player_id)` — **取消该玩家的所有定时器:attack + hurt + dead**。cleanup_player 时调用,防对已删除玩家操作状态(断连清理需全覆盖,避免任意一种定时器到期对已删除实体操作状态)
- `start_hurt(pid, duration, end_cb)` 启动一次 hurt 定时器。内部先 cancel 该玩家的 attack timers(攻击被中断)+ cancel 旧 hurt timer(连击重置),再启新 hurt timer。不 cancel dead(硬直期间不会被死亡打断——死亡实体不会走 hurt 分支)
- `start_dead(pid, duration, end_cb)` 启动一次死亡定时器。**死亡打断一切**:内部先 cancel 该玩家的 attack + hurt timers(死亡是最高优先级终态,攻击判定帧/结束广播和 hurt 恢复都不该再触发),再启 DeadTimer。duration 从 `config_loader.get_dead_duration_ms(entity_type)` 取
- `has_active(player_id)` 判断是否在攻击中
- attack timers 用 List(为连击/多段攻击留接口),hurt/dead timers 各用单个(同时只会有一个 hurt / 一个 dead)

### 协作关系
```
room.trigger_attack(attacker_id, atk_id)   ← 玩家 pending / 敌人 AI 都调这个
    ↓ 转调 attack_trigger 钩子 (GameServer._trigger_attack)
    ↓ apply_attack_start 改状态 + 广播 AttackStart
    ↓ 遍历 shape_list 调 TimerManager.start_attack(pid, hit_time, duration, hit_cb, end_cb)
    ↓ AttackTimer 启动 asyncio.Task
await hit_time → hit_cb (get_attack_hits + apply_hurt + 广播 AttackHit/HpChanged)
await duration-hit_time → end_cb (apply_attack_end + 广播 AttackEnd)

玩家断连 → cleanup_player → TimerManager.cancel(pid)
```

### 当前状态
- AttackTimer + TimerManager 已实现并接入 `_trigger_attack`(注册为 GameRoom 的 `attack_trigger` 钩子)
- 玩家(经 pending_inputs→_process_tick)和敌人(AI 状态机直接调 `room.trigger_attack`)走同一条完整攻击流程
- cleanup_player 已调 TimerManager.cancel(取消该实体所有 attack/hurt/dead 定时器)

## 敌人 AI 状态机(EnemyMgr + ai/states)

### 为什么 AI 状态不进 EntityInfo
敌人 AI 决策状态(当前状态/追击目标/路径)是所有实体共用的 EntityInfo 不该承载的,单独由 EnemyMgr 持有,以 entity_id 关联 GameRoom._entities。AI 只读 GameRoom 共有状态、通过 apply_xxx 改状态,不直接写 _entities。

### 状态机
EnemyAIMachine 持有 states dict,EnemyMgr.add_enemy_ai_state 注册四个状态:
- patrol(巡逻):出生点附近随机移动,视锥内发现玩家 → chase;走到目标点 → look_around
- look_around(张望):原地左右转头,转动中视锥发现玩家 → chase,转完 → patrol
- chase(追逐):A* 寻路追击,进攻击距离 → attack;目标死亡/超距离/脱离追逐视锥 → patrol
- attack(攻击):调 trigger_attack 完整攻击流程,目标消失/距离过远 → patrol

### 视锥视野
敌人寻人用「视锥」判定:距离(半径)+ 角度(朝向左右半角)。
- 配置:shared_config/vision_config.json,两套模式:
  - normal(常态,除 chase 外的所有状态):half_angle_deg=30°,radius=750px(宽而近)
  - chase(追逐态):half_angle_deg=22.5°,radius=1000px(窄而远,盯死目标)
- loader:config_loader.get_vision(mode) 返回 VisionParams(half_angle 弧度 / radius 像素),未知 mode 回退 normal
- 判定:ai_state_helper.is_in_sight(finder, target, vision) 纯几何判「距离 + 角度」(目标方向与 facing 夹角 ≤ 半角);遮挡不在此判,由 find_path 可达性承担(墙后目标即使可见也追不到)
- 寻人:ai_state_helper.find_nearest_entity_in_sight(room, entity_id, entity_type, vision_mode) 先视锥过滤,再 find_path 可达性过滤,取最近目标
- 用途:patrol/look_around 用 normal 视野寻人;chase 用 chase 视野判定「目标是否脱离视野」,脱离即放弃追击回 patrol

### AI 状态切换广播(视锥渲染的数据源)
AI 状态要同步给客户端渲染视锥形态(normal/chase),切换不能等低频快照:
- **钩子链**:`EnemyMgr.set_ai_state_change_hook(cb)`(GameServer 初始化时注册)→ 注入每个 `EnemyAIMachine` → `change_state` 状态**真正切换**(old != new)时调钩子 → `GameServer._on_ai_state_changed` 同步 `EntityInfo.ai_state`(供 GameState 快照带初始值)+ `_queue_broadcast("AiStateChanged", ...)`
- 重入不广播:change_state 目标=当前状态时(重入)不触发,避免重复广播
- 创建敌人时 `change_state("patrol")` 也会触发一次(此时客户端可能还没有该实体,StateMirror 会忽略,等全量快照带初始 ai_state)

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
- 冒烟测试通过:A 攻击命中 entity:stake_1(80,0);apply_hurt 设 stake state='hurt' 成功;木桩 apply_move_dir 被能力配置拒绝

## 当前是"记住方向 + 持续推进"移动模型
移动模型演进:坐标落地 → 收到输入才推进 → 记住方向 + 每 tick 持续推进:
- 客户端发 PlayerMove{dir_x, dir_y, moving}(C2S 语义,只发"改方向"指令,低频)
- 服务端 apply_move_dir 只记住方向到 EntityInfo.move_dir_x/y,不推进位移
- 服务端 tick_movement 每 tick 对所有 moving=True 的实体统一推进 EntityInfo.x/y
- 服务端广播 PlayerMove{x, y, moving}(S2C 语义,发算出的坐标)
- 客户端本地预测 position += dir * speed * delta,收到服务端广播后软对账(回溯 RTT+半个 tick 前预测位置,误差大才 lerp 平滑回正;变向/急停后宽限窗口内跳过回正,详见 client-role.md)

核心优势:服务端记住方向后每 tick 都推进,不依赖客户端输入是否到达——无累积误差,无 snap 拉回。
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
- **服务端权威移动已实现**:apply_move_dir 只记住方向(不推进位移)+ tick_movement 每 tick 持续推进所有 moving=True 实体的位移;EntityInfo 加 move_dir_x/y 字段;PlayerMove 协议改为双向语义(C2S 发方向,S2C 发坐标);解决了"丢 tick → 误差累积 → snap 拉回"问题
- **tick_movement 改用实测 dt**:dt 由 GameServer._tick_loop 用 time.monotonic() 实测(钳制 [0,100ms]),替代原固定 TICK_INTERVAL 积分——修复 Windows 15.6ms 定时粒度下 tick 实际约 47ms、服务端移速只有 71%、客户端预测对账周期性回拉的问题
- **hurt 硬直已实现**:apply_move_dir/apply_facing/apply_attack_start 在 state=="hurt" 时拒绝输入;apply_hurt_end 恢复 idle;config_loader.get_hurt_duration_ms()=666ms
- **击退已实现**:AttackShape 加 knockback_distance 配置(1001/1002 最后一段=80px);GameRoom 加 `_knockbacks` 击退表 + apply_knockback(方向=目标-攻击者,时长=hurt 时长,速度=距离/时长);tick_movement 先推进击退(不受输入锁定影响);web_server.hit_cb 只对连段最后一段且 knockback_distance>0 触发,死亡不击退;remove_entity 连带清理击退状态
- **死亡流程已实现**:apply_hurt 返回 HurtResult(FAILED/HURT/DEAD),hp<=0 且 can_die=True 走死亡分支;apply_dead 设 state="dead";_is_input_locked 统一校验 hurt/dead/attacking 锁定状态;get_attack_hits 过滤 state=="dead" 实体;DeadTimer + TimerManager.start_dead 实现延迟移除;config_loader 加 can_die/dead_duration_ms 字段 + get_dead_duration_ms() API
- 攻击状态三件套已实现:apply_attack_start/apply_attack_end/apply_hurt(原 apply_attack_hurt 改名,统一处理玩家和木桩)
- **trigger_attack 攻击发动钩子已实现**:GameRoom 持有 `_attack_trigger` 回调(由 GameServer._trigger_attack 注册),玩家和敌人都调 `room.trigger_attack()` 走完整流程(状态变更+广播+判定帧定时器+命中扣血),修复敌人 AI 直接调 apply_attack_start 导致"只改状态不发动"的问题
- **create_enemy 实体创建钩子已实现**:GameRoom 持有 `_entity_spawn_hook` 回调(由 GameServer._on_entity_spawned 注册),GM 运行时调 `room.create_enemy` 后网络层广播 GameState + StatsInit 全量快照,在线客户端立刻创建并显示新敌人(修复 GM 创建敌人客户端看不到的问题)
- 攻击命中判定已接入:get_attack_hits 遍历 _entities,用 can_be_hurt 过滤,每个目标查 entity_config 取 body_params 构造 Circle
- **阵营掩码改用实体 attack_mask**:原 attack_config 的 hit_mask 字段移除(它挂在攻击上,导致敌人复用 1001 只能打敌人)。改用实体类型的 attack_mask(玩家=2 打敌人层,敌人=1 打玩家层),玩家和敌人可复用同一 atk_id 各打各阵营,get_attack_hits 用 `attacker_cap.attack_mask & target_cap.hit_layer` 过滤
- **配置已迁移到 JSON 单数据源**:ATTACK_CONFIG / ENTITY_CAPABILITIES / HURT_DURATION_MS 改为读 shared_config/*.json(由 sync_config.py 同步)
- **EntityInfo.radius 字段已删除**:碰撞形状改由 entity_type 查 entity_config.body_shape/body_params 决定(形状是类型属性)
- **ShapeType 改名**:原 AttackShapeType → ShapeType,实体碰撞和攻击形状共用
- handlers 已从 web_server.py 拆分,按功能分文件,PlayerJoin 用 EntityInfo dataclass
- main.py 启动时硬编码注册 entity:stake_1 木桩(位置和客户端场景一致)
- **timer_mgr.py 已实现 AttackTimer + HurtTimer + DeadTimer + TimerManager**:attack 三段定时器 + hurt 单段定时器 + dead 单段定时器,start_hurt 内部 cancel 旧 attack(攻击被中断)+ 旧 hurt(连击重置);start_dead 内部 cancel 旧 attack + hurt(死亡打断一切);cancel(player_id) 取消该玩家所有 attack/hurt/dead 定时器
- collision.py 已实现:Circle/Sector 形状 + 相交判定函数,冒烟测试通过
- 冒烟测试通过:A 攻击命中 entity:stake_1;apply_hurt 设 stake state='hurt';木桩 apply_move_dir 被能力配置拒绝
- **敌人视锥视野已实现**:vision_config.json 新增 normal(30°/750px)/chase(22.5°/1000px) 两套视野;config_loader.get_vision(mode) 读取为 VisionParams(half_angle 弧度/radius);ai_state_helper.is_in_sight 纯几何判定(距离+角度,遮挡由 find_path 可达性承担);find_nearest_entity_in_sight 先视锥过滤再寻路;patrol/look_around 用常态视野寻人,chase 用追逐视野判「目标脱离视野即放弃追击」;enemy_mgr 补注册 look_around 状态
- **AI 状态同步已实现**:EntityInfo 加 ai_state 字段(proto 同步加,GameState 快照带初始值);EnemyAIMachine.change_state 状态真正切换(old != new)时触发钩子(重入不广播);EnemyMgr.set_ai_state_change_hook 注入所有状态机;GameServer._on_ai_state_changed 同步 EntityInfo.ai_state + 广播 AiStateChanged(客户端据此切换视锥形态 normal/chase,详见 tools/视锥渲染方案.md)
