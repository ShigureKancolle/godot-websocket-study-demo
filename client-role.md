# 客户端角色组件 (client-role)

覆盖:`client/Script/role/*` + `client/Script/statemachine/*` + `client/Script/dead_man_scene.gd`
职责:组件化实体容器、视觉表现、本地玩家控制、动画状态机、场景管理 Role 实例

## 文件清单

| 文件 | 职责 |
|------|------|
| [role/Role.gd](file:///d:/work2/godot_demo/client/Script/role/Role.gd) | 通用实体容器(Node2D),按 entity_type 分发挂载不同组件 |
| [role/PlayerVisual.gd](file:///d:/work2/godot_demo/client/Script/role/PlayerVisual.gd) | 视觉组件(Node2D),预制体脚本,运行时切换贴图+设名字+转朝向箭头+按四方向拼动画 |
| [role/LocalPlayerController.gd](file:///d:/work2/godot_demo/client/Script/role/LocalPlayerController.gd) | 本地玩家控制组件(Node),读 InputIntentProvider 意图发 PlayerMove+PlayerFacing+AttackStart |
| [role/CameraFollow.gd](file:///d:/work2/godot_demo/client/Script/role/CameraFollow.gd) | 相机平滑跟随组件(Camera2D),跟随本地玩家坐标 lerp |
| [role/input/InputIntent.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputIntent.gd) | 意图数据结构(RefCounted),move_dir + look_target + attack_pressed |
| [role/input/InputBinding.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputBinding.gd) | 自定义键位映射(RefCounted+static),类型化绑定(key/mouse)支持键盘+鼠标,rebind+持久化到 user://input_binding.cfg |
| [role/input/InputDevice.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputDevice.gd) | 输入设备抽象基类(Node),定义 poll(intent) 接口 |
| [role/input/KeyboardMouseDevice.gd](file:///d:/work2/godot_demo/client/Script/role/input/KeyboardMouseDevice.gd) | 键鼠设备(extends InputDevice),读键盘+鼠标转意图 |
| [role/input/InputIntentProvider.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputIntentProvider.gd) | autoload 全局 Provider(Node),每帧采集+暴露 get_intent() |
| [statemachine/StateBase.gd](file:///d:/work2/godot_demo/client/Script/statemachine/StateBase.gd) | 状态基类(extends RefCounted,纯逻辑),machine/state_name 引用 + _enter_state/_exit_state/_process 虚方法 |
| [statemachine/StateMachineBase.gd](file:///d:/work2/godot_demo/client/Script/statemachine/StateMachineBase.gd) | 状态机基类(extends Node,可 add_child + 自动 _process),add_state/change_state/get_state/get_current_state_name |
| [statemachine/AnimState/AnimStateMachine.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/AnimStateMachine.gd) | 动画状态机(extends StateMachineBase),Role 平级组件,注册 Idle/Run/Attack/Hurt 状态,update_state 转发服务端 state |
| [statemachine/AnimState/IdleState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/IdleState.gd) | 静止状态(extends StateBase),_enter_state 调 visual.play_anim("idle") |
| [statemachine/AnimState/RunState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/RunState.gd) | 移动状态(extends StateBase),_enter_state 调 visual.play_anim("run") |
| [statemachine/AnimState/AttackState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/AttackState.gd) | 攻击状态(extends StateBase),_enter_state 调 visual.play_anim("attack") |
| [statemachine/AnimState/HurtState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/HurtState.gd) | 受击状态(extends StateBase),_enter_state 调 visual.play_anim("hurt"),_reenter_state 调 visual.replay_cur_anim() 处理连击重启 |
| [dead_man_scene.gd](file:///d:/work2/godot_demo/client/Script/dead_man_scene.gd) | 木桩场景(Node2D),接 StateMirror 信号管理所有实体(玩家+木桩)的 Role 创建/更新/删除 |
| [prefab/role/Role.tscn](file:///d:/work2/godot_demo/client/prefab/role/Role.tscn) | Role 预制体(当前空 Node,实际用脚本 new()) |
| [prefab/role/PlayerVisual.tscn](file:///d:/work2/godot_demo/client/prefab/role/PlayerVisual.tscn) | PlayerVisual 预制体(Body + FacingArrow + NameLabel,静态视觉配置) |

## 统一 Entity 模型 + 强类型 ClientEntityInfo(本次重构)

和服务端对齐:所有可交互物体(玩家/木桩)统一为 Entity,Role 是它们在客户端的渲染容器。
- `entity_id` 带类型前缀:`"player:uuid-xxx"` / `"entity:stake_1"`
- `entity_type` 用 `ClientEntityInfo.EntityType` 枚举(PLAYER/STAKE/UNKNOWN),不再用字符串
- StateMirror 信号 / Role / PlayerVisual / LocalPlayerController / dead_man_scene 的接口参数全部从 `Dictionary` 改为 `ClientEntityInfo`(强类型 RefCounted)
- 字段访问用 `info.x` / `info.state` 而非 `info["x"]` / `info["state"]`,IDE 补全 + 编译期检查
- 详见 [docs/client-net.md](file:///d:/work2/godot_demo/docs/client-net.md) 的 EntityInfo.gd 章节

## Role.gd — 通用实体容器

`extends Node2D`, `class_name Role`。组件化 / ECS-lite 设计。

### 核心思路
Role 本身只是"位置容器":有坐标、能挂子节点。它不知道自己是玩家还是木桩——"是什么"由 `entity_type` 决定挂载的组件。

### 组件分类
- **Visual 组件**:负责显示(Sprite、动画等)
- **Controller 组件**:负责行为(本地玩家读输入、远程玩家读 StateMirror)
- **AnimStateMachine 组件**:负责动画状态切换(idle/run/attacking/hurt)

### 按 entity_type 分发
| entity_type | Visual | AnimStateMachine | Controller | 备注 |
|-------------|--------|------------------|------------|------|
| PLAYER(本地) | PlayerVisual | ✓ | LocalPlayerController | 本地额外挂 Controller |
| PLAYER(远程) | PlayerVisual | ✓ | — | 只显示,坐标由 StateMirror 驱动 |
| STAKE | PlayerVisual(占位) | — | — | 未来可换 StakeVisual |

未知 `entity_type`(UNKNOWN)按 PLAYER 处理(兼容兜底,push_warning 告警)。

### setup(info: ClientEntityInfo)
由 dead_man_scene 在创建/更新 Role 时调用:
1. 缓存 `entity_id` / `entity_type`(从 info 的强类型属性取)
2. 更新坐标(_update_position)
3. 移除旧组件(避免重复挂:`_remove_component("PlayerVisual")` / `LocalPlayerController` / `AnimStateMachine`)
4. 按 `entity_type` match 分发到 `_setup_player` / `_setup_stake`(用 EntityType 枚举做穷尽性 match)

### _setup_player(info)
1. 实例化 `PlayerVisual.tscn`,add_child 后调 `visual.setup(info)`
2. 实例化 `AnimStateMachine.gd`(脚本 new,不是预制体),add_child 后调 `setup(info)`
   - 挂载顺序:先 PlayerVisual 后 AnimStateMachine——状态机 `_ready` 进入 idle 时要访问 visual 调 `play_anim`
3. 判断是否本地玩家:`entity_id == ClientStateMirror.local_entity_id()`,是则额外挂 LocalPlayerController

### _setup_stake(info)
当前简化:只挂 PlayerVisual(占位,显示圆形角色贴图 + 名字标签 + 朝向箭头)。
- 不挂 AnimStateMachine:木桩目前没有动画状态切换需求
- 不挂 LocalPlayerController:木桩不被本地控制
- 未来木桩的 hurt 状态由 StateMirror 的 `entity_updated` 信号直接改 state 字段驱动(无动画状态机介入)
- 后续替换为 StakeVisual 时只改本方法,不影响其他 entity_type

### on_entity_updated(info: ClientEntityInfo)
收到 StateMirror 的 `entity_updated` 信号时调(Role 自己不改状态——永远由 StateMirror 信号驱动,这是服务器权威在客户端的最终体现):
- 坐标:调 `_update_position(info)`(读 `info.x` / `info.y`)
- 朝向:转发 `info.facing` 给 `PlayerVisual.update_facing`
- 动画状态:`info.state` 非空则转发给 `AnimStateMachine.update_state`(木桩没挂状态机时跳过)

## PlayerVisual.gd — 视觉组件

`extends Node2D`, `class_name PlayerVisual`。作为预制体 `PlayerVisual.tscn` 的脚本:节点结构/Label 位置/颜色等静态视觉配置在预制体编辑器里配,运行时只处理动态逻辑(切换贴图、设名字文本、转朝向箭头)。

### 节点结构(预制体)
```
PlayerVisual (Node2D)
├── Body (AnimatedSprite2D)   角色身体动画(4方向×idle/run/attack/hurt,由 AnimStateMachine 驱动)
├── FacingArrow (Sprite2D)    朝向指示器箭头,绕 Body 旋转
└── NameLabel (Label)         名字标签
```

### setup(info: ClientEntityInfo)
- 记录 entity_id, player_name(从强类型属性取,不再 .get("xxx") 兜底)
- 取预制体节点引用($Body / $FacingArrow / $NameLabel)— 不用 @onready 避免 _ready 时机问题(Role 在 add_child 后立即调 setup)
- Body 不再设 texture:已升级为 AnimatedSprite2D,SpriteFrames 在预制体里配多个动画(4方向×idle/run/attack/hurt,命名 "Down_Idle" 等),播放由 AnimStateMachine 通过 `play_anim` 驱动
- 朝向箭头贴图:本地用蓝色(`arrowBlue_right.png`),远程用棕色(`arrowBrown_right.png`)— 仅靠箭头颜色区分本地/远程
- 设 FacingArrow.texture + NameLabel.text
- 初始朝向:从 `info.facing`(默认 0),调 update_facing
- 本地玩家名字加"(你)"前缀

### update_facing(facing)
- 设箭头 rotation = facing(贴图 _right 后缀表示指向右方,rotation=0 朝右,正好对应 facing=0)
- 设箭头 position = Vector2.RIGHT.rotated(facing) * ARROW_OFFSET(箭头绕 Body 外圈转,ARROW_OFFSET=35)
- 把弧度映射到四方向字符串(Down/Left/Right/Up),存进 `_facing_dir`;方向变了主动重播当前状态动画(切到新方向前缀,如朝右跑→朝上跑切 Up_Run)
- 方向判定:`_facing_to_dir` 用 wrapf 归一到 [-π, π),再以 ±45° 分四象限

### play_anim(anim_name)
- 由 AnimStateMachine 的状态(IdleState/RunState/AttackState/HurtState)在 `_enter_state` 时调用
- anim_name 是基础状态名(idle/run/attack/hurt),状态机不知道方向——职责分离
- 缓存 anim_name 到 `_current_state`,再调 `_play_current` 拼成 "Down_Idle" 等真实动画名播放
- `_play_current`:`_facing_dir + "_" + _current_state.capitalize()`,防御动画不存在 push_warning,同名动画不重复 play
- 朝向变了但状态没变时由 `update_facing` 触发 `_play_current`,状态变了由 `play_anim` 触发——两个入口共用同一拼名逻辑

### 为什么箭头用 _right 贴图 + rotation 转动
- _right 后缀:贴图本身指向右方(+x),所以 rotation=0 时箭头朝右
- facing 语义:弧度,0=朝右,逆时针正(Godot 标准)
- 箭头位置随 facing 转动,始终在 Body 外圈对应方向(不压在身体上)

### 为什么是组件而非直接写在 Role 里
Role 是通用容器,不该知道"玩家长什么样"。把显示逻辑抽成组件后:
- 木桩挂 StakeVisual,不挂 PlayerVisual
- 显示逻辑变更(换贴图、加动画)只改这一个文件

组件用 Node2D 而非 RefCounted:要被 add_child 到 Role 上,Sprite2D 要在场景树里显示。

> 当前 stake 复用 PlayerVisual 作占位。后续替换为 StakeVisual 时,只需新建 `StakeVisual.tscn` + `StakeVisual.gd`,在 `Role._setup_stake` 里改 preload 路径即可,Role/AnimStateMachine 都不动。

## AnimStateMachine.gd — 动画状态机

`extends StateMachineBase`, `class_name AnimStateMachine`。位于 `statemachine/AnimState/` 目录,Role 的平级组件(和 PlayerVisual/LocalPlayerController 一样 add_child 到 Role),根据服务端 state 切换动画。

### 架构位置(服务器权威的最终体现)
```
服务端 EntityInfo.state(idle/run/attacking/hurt/...)
    ↓ StateMirror._on_player_move 从 moving 推断 state
    ↓ StateMirror._on_attack_start / _on_attack_hit / _on_attack_end 设 state
    ↓ entity_updated 信号
Role.on_entity_updated
    ↓ 转发 state 字段给 AnimStateMachine
AnimStateMachine.update_state(state_name)
    ↓ change_state
IdleState / RunState / AttackState / HurtState._enter_state
    ↓ machine.get_visual().play_anim("idle"/"run"/"attack"/"hurt")
PlayerVisual 的 AnimatedSprite2D 播放对应动画
```

### _ready
- 调 `_register_states()` 注册所有状态:`add_state("idle", IdleState.new())` + `add_state("run", RunState.new())` + `add_state("attack", AttackState.new())` + `add_state("hurt", HurtState.new())`
- 进入初始状态 "idle"(玩家默认静止)
- 时机保证:Role.setup 先 add PlayerVisual 再 add AnimStateMachine,子节点 `_ready` 按添加顺序触发,PlayerVisual 先于 AnimStateMachine,所以状态机 `_ready` 进入 idle 调 `play_anim` 时 visual 已就绪

### update_state(state_name)
由 Role.on_entity_updated 调用,转发服务端 EntityInfo.state 字段。内部调 `change_state`(带校验:不存在状态告警,相同状态不重复进入)。

> state 名约定:服务端 EntityInfo.state 用 "attacking"(进行时),客户端 AnimStateMachine 注册的状态名是 "attack"(动作名)。`update_state` 内部做映射:`"attacking" → "attack"`。这是「服务端业务态 ↔ 客户端动画态」的语义边界,不要让服务端字符串直接当动画名用。

### get_visual() -> PlayerVisual
状态对象(IdleState/RunState/AttackState/HurtState)通过这个方法访问显示层。AnimStateMachine add_child 到 Role,所以 `get_parent()` = Role,再 `get_node_or_null("PlayerVisual")` 拿到 PlayerVisual。

### 状态基类说明(StateBase / StateMachineBase)
- **StateBase**(extends RefCounted):纯逻辑状态对象,不进场景树。持有 `machine`/`state_name` 引用(add_state 时注入),四个虚方法 `_enter_state`/`_exit_state`/`_process`/`_reenter_state` 由状态机回调。RefCounted 更轻量,切换时旧状态自动释放。
- **StateMachineBase**(extends Node):状态机基类,可 add_child 到宿主、自动 `_process` 驱动当前状态。管状态表(`_states: Dictionary`)、当前状态、切换(`change_state` 带校验)、查询(`get_state`/`get_current_state_name`)。状态机只负责「怎么切」,不决策「什么时候切」(切换由 Role 转发服务端 state 触发)。
- **change_state 的重入机制**:`change_state` 检测到"目标状态=当前状态"时调 `_reenter_state`(基类默认空实现,等价于之前的 return)。HurtState override `_reenter_state` 调 `visual.replay_cur_anim()` 重启动画——处理连击场景(服务端 hurt timer 被 cancel+restart 不重发 state="hurt",但客户端会再收到一次 AttackHit,触发 change_state("hurt") 进入重入分支)。其他状态(Idle/Run/Attack)不 override,相同状态调用时等价于之前的行为。
- 旧版基类 extends Object,无法 add_child、无法自动 _process、用 state.name 当 key 会报错(Object 无 name 属性),已废弃。

## input/ — 输入端模块

### 核心设计:意图层解耦
```
[KeyboardMouseDevice] ┐
[GamepadDevice(未来)]  ┤→ [InputIntentProvider] → InputIntent → [LocalPlayerController]
[其它设备(未来)]      ┘          (autoload)        (move_dir+
                                                          look_target+
                                                          attack_pressed)
```
接收端只读 InputIntentProvider.get_intent(),**不知道也不关心**输入来自哪个设备、按了什么键、键位怎么配的。

### InputIntent.gd — 意图数据结构
`extends RefCounted`。只描述"玩家想做什么",不描述"按了什么键":
- `move_dir: Vector2` — 移动方向(归一化),零向量=不动
- `look_target: Vector2` — 朝向目标点(世界坐标)
- `attack_pressed: bool` — 攻击键边沿触发(本帧按下为 true,下一帧 reset)

### InputBinding.gd — 自定义键位映射
`extends RefCounted`, static 单例。逻辑动作名 ↔ 类型化绑定的映射表。
- 类型化绑定:`{"type": "key"|"mouse", "code": int}`,type 决定查询走哪个 Input API
  - type="key" → `Input.is_key_pressed(code)`
  - type="mouse" → `Input.is_mouse_button_pressed(code)`
  - 未来加手柄:type="pad" → `Input.is_joy_button_pressed(code)`,结构不动
- 默认键位:WASD + 方向键双绑(move_up: 两个 key 绑定),attack 绑鼠标左键
- `is_action_pressed(action)` 按 type 分发查询,任意一个绑定触发即 true
- `rebind(action, old_type, old_code, new_type, new_code)` / `add_binding(action, type, code)` / `remove_binding(action, type, code)` —— 参数都带 type
- `get_bindings(action)` 返回 Array[Dictionary](替代旧的 get_keys)
- 持久化到 `user://input_binding.cfg`(格式:每行 `action:type:code,type:code`,type 缩写 k/m;老格式被静默丢弃)
- **完全独立于 Godot InputMap**,自己管映射表(用 InputMap 会绕过意图层抽象)
- **边沿触发(attack 需要)不在 InputBinding 做**:InputBinding 是纯映射查询层,边沿逻辑放 KeyboardMouseDevice

### InputDevice.gd — 抽象基类
`extends Node`, `class_name InputDevice`。定义 `poll(intent)` 接口。
- Node 而非 RefCounted:需要 add_child 到 Provider,才能用 get_viewport() 拿相机
- poll 接收 intent 参数(共享对象写入),多个 device 往同一 intent 写各自字段

### KeyboardMouseDevice.gd — 键鼠设备
`extends InputDevice`。每帧 poll:
- 读键盘:按 InputBinding 查 move_up/down/left/right,累加成 move_dir(归一化,斜走不快 1.414 倍)
- 读鼠标:get_viewport().get_camera_2d().get_global_mouse_position() 转世界坐标写进 look_target
- 读攻击键:边沿触发(本帧按下→attack_pressed=true),下一帧由 Provider reset

### InputIntentProvider.gd — autoload Provider
`extends Node`, autoload 全局单例。
- _ready 时默认注册一个 KeyboardMouseDevice
- _process 每帧:reset intent → 遍历所有 device 调 poll(intent) → 缓存最终 intent
- `get_intent() -> InputIntent` — 接收端唯一入口,返回缓存值不触发采集
- add_device(device) — 注册新设备(未来加手柄时用)

## LocalPlayerController.gd — 本地控制组件

`extends Node`, `class_name LocalPlayerController`。**接收端**——只读 InputIntentProvider.get_intent()。

### 核心设计(服务器权威 + 输入端解耦)
本地玩家想移动/转朝向/攻击,流程:
1. 读 intent(intent.move_dir + intent.look_target + intent.attack_pressed)
2. 发 PlayerMove(从 move_dir 算 target)/ PlayerFacing(从 look_target 算 facing)/ AttackStart(攻击键按下时)
3. 服务端 apply_move / apply_facing / apply_attack_start 更新权威状态,广播给所有人(含自己)
4. StateMirror 收到 → `entity_updated` 信号 → Role.on_entity_updated → 更新坐标 + 转发 facing 给 PlayerVisual + 转发 state 给 AnimStateMachine

**注意第4步**:本地玩家的坐标和朝向也是由 StateMirror 信号更新的,不是这里直接改的。保证"本地玩家看到的自己"和"服务端认为的本地玩家"永远一致。

### 攻击流程
1. 检查 `mirror.get_entity(mirror.local_entity_id()).state`,若已是 `"attacking"` 则跳过(防连点)
2. `intent.attack_pressed` 为 true 时发 `game.AttackStart`,字段 `entity_id` + `atk_id`
3. **预判**:`player.state = "attacking"`(直接改 ClientEntityInfo 强类型对象的字段,不等服务端广播回来才切,避免输入延迟感)
4. 服务端走 AttackStart → hit_cb → end_cb 三段定时器,期间广播 AttackHit/AttackEnd
5. 客户端收到 AttackHit 时,StateMirror 遍历 hit_list 把被命中者的 `ClientEntityInfo.state` 设为 `"hurt"`

> 字段名:统一 Entity 模型后用 `entity_id`(原 `role_id` 已废弃)。注:服务端 handler 实际用 `ctx.player_id` 而非读 client 发的 entity_id,但为了契约一致性,客户端仍然填上 entity_id 字段。
> 字段访问:从 dict 索引 `player["state"]` 改为强类型属性 `player.state`,IDE 可补全、拼错编译期报错。

### 朝向和移动是两个独立状态维度
玩家可以一边移动(WASD 决定方向)一边朝任意方向攻击(鼠标决定朝向)。所以 PlayerMove 和 PlayerFacing 是两条独立的消息流,各自发各自的。攻击期间(state=="attacking")两者都禁发。

### 移动模型:方向移动 → target 坐标
- 当前 proto 的 PlayerMove 是「目标坐标」(target x/y),不是「方向」
- 键盘方向移动转换:target = 当前位置 + move_dir * MOVE_STEP(每帧 5 像素)
- 只有 move_dir 非零时才发包(避免静止时无意义发包)
- `moving` 字段状态机:
  - 正在移动:每帧发 moving=true,服务端设 state="run"
  - 刚停止(`_was_moving` true → false):发一次 moving=false,服务端设 state="idle"
  - 持续静止:不发(避免无意义发包)

### 朝向模型:鼠标位置 → facing 弧度
- look_target(世界坐标) - role_pos 得到方向向量
- Vector2.angle() 返回弧度(0=右,逆时针正),和 facing 语义完全一致
- 节流基于 **facing 弧度本身** 是否变化(超过 FACING_EPSILON 才发包),不是基于 look_target
  - 原因:facing = (look_target - role_pos).angle(),鼠标不动但人物在动时 role_pos 变了,facing 也会变
  - 若按 look_target 节流,会出现「鼠标不动人物动时朝向不更新」的 bug
- 首次有有效 look_target 时强制发包一次(_has_last_look 标记初始状态)

### setup(_info: ClientEntityInfo)
当前空实现,保留接口和 PlayerVisual.setup 对称。后续如需根据玩家信息调整控制参数(如不同角色移速不同),在这里实现。

## dead_man_scene.gd — 木桩场景

`extends Node2D`。当前阶段玩家和木桩都由服务端权威驱动创建。

### 职责
接 ClientStateMirror 的三个信号,管理所有实体(玩家+木桩)的 Role 创建/更新/删除:
- `state_replaced(entities: Array)` — 清空所有 Role,用快照重建(元素是 ClientEntityInfo)
- `entity_updated(info: ClientEntityInfo)` — 已存在则更新坐标/朝向/状态,不存在则创建新 Role
- `entity_removed(entity_id: String)` — queue_free + 从 _entities 删除

### _ready
- 连接 E_Back 按钮返回大厅
- 连接 StateMirror 三个信号(state_replaced / entity_updated / entity_removed)
- 如果 StateMirror 已有状态(进入场景前就收到了 GameState),主动刷一次 `mirror.all_entities()`

### _entities: Dictionary
`entity_id -> Role 实例`,所有可交互物体(玩家+木桩)都在这一张表里,和服务端 `_entities` 对齐。用它快速查找某个 entity_id 对应的 Role。

### _create_role(info: ClientEntityInfo)
`RoleScript.new()` 创建 → `role.setup(info)` 按 entity_type 分发挂组件 → `add_child(role)` 进场景 → 存进 `_entities[info.entity_id]`(强类型属性访问)。

### 场景结构
DeadManScene.tscn 里有个 E_Back 按钮用于返回 MainScene。Role 实例用 `Role.gd.new()` 创建后 add_child 到场景。

## CameraFollow.gd — 相机跟随

`extends Camera2D`。跟随本地玩家坐标,lerp 平滑过渡。
- `_ready`:从 `ClientStateMirror.local_entity_id()` 取本地玩家 ID,连接 `entity_updated` 信号
- `_process`:从镜像取本地玩家的 ClientEntityInfo,用 `_role.x` / `_role.y` 强类型访问坐标,lerp 到目标位置
- `follow_smoothing`:0=不平滑,1=瞬移(默认 1,即直接跟)
- 依赖 StateMirror:玩家信息没到时 `_find_role` 反复尝试(返回 null),拿到 ClientEntityInfo 后开始跟随
- `_role: ClientEntityInfo`(强类型,默认 null),不再用 Variant

## 依赖关系
- 依赖 client-net:ClientStateMirror(信号驱动 + local_entity_id)、MessageBus(LocalPlayerController 发消息)、ClientEntityInfo(数据载体)
- 依赖 InputIntentProvider(autoload,LocalPlayerController 读意图)
- 被 client-ui 依赖:MainUI 的"进入游戏"按钮 instantiate DeadManScene

## 当前状态
- 统一 Entity 模型 + 强类型 ClientEntityInfo 重构完成:Role 按 EntityType 枚举分发,玩家/木桩统一在 `_entities` 表管理,字段访问全用强类型属性
- 玩家同步闭环已跑通:两个客户端能互相看到对方移动+朝向(本地蓝箭头/远程棕箭头)
- 攻击流程已实现:LocalPlayerController 发 AttackStart,StateMirror 处理 AttackHit/AttackEnd,AnimStateMachine 支持 attack/hurt 状态
- **hurt 硬直已实现**:StateMirror 处理 AttackHit(进 hurt)+ HurtEnd(恢复 idle),纯服务端权威恢复(路径X);AnimStateMachine 的 change_state 加 `_reenter_state` 重入机制,HurtState override 后调 replay_cur_anim() 实现连击重启动画;StateBase 加 `_reenter_state` 虚方法(基类默认空)
- 动画状态机已实现:AnimStateMachine + Idle/Run/Attack/Hurt 四状态,根据服务端 state 切换动画(Body 是 AnimatedSprite2D,SpriteFrames 在预制体里配 4方向×多状态动画,PlayerVisual 按 facing 弧度拼出 "Down_Idle" 等播放)
- 木桩占位显示:复用 PlayerVisual,后续替换为 StakeVisual
- 键盘方向移动(WASD)+ 鼠标朝向已实现
- 自定义键位支持(InputBinding 模块,改键 UI 暂未做)
- 手柄输入未实现(InputDevice 抽象已就位,加 GamepadDevice 即可)
