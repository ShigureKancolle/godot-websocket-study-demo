# 客户端角色组件 (client-role)

覆盖:`client/Script/role/*` + `client/Script/statemachine/*` + `client/Script/dead_man_scene.gd`
职责:组件化角色容器、视觉表现、本地玩家控制、场景管理 Role 实例

## 文件清单

| 文件 | 职责 |
|------|------|
| [role/Role.gd](file:///d:/work2/godot_demo/client/Script/role/Role.gd) | 通用实体容器(Node2D),按玩家类型挂载不同组件 |
| [role/PlayerVisual.gd](file:///d:/work2/godot_demo/client/Script/role/PlayerVisual.gd) | 玩家视觉组件(Node2D),预制体脚本,运行时切换贴图+设名字+转朝向箭头 |
| [role/LocalPlayerController.gd](file:///d:/work2/godot_demo/client/Script/role/LocalPlayerController.gd) | 本地玩家控制组件(Node),读 InputIntentProvider 意图发 PlayerMove+PlayerFacing |
| [role/input/InputIntent.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputIntent.gd) | 意图数据结构(RefCounted),move_dir + look_target |
| [role/input/InputBinding.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputBinding.gd) | 自定义键位映射(RefCounted+static),rebind+持久化到 user://input_binding.cfg |
| [role/input/InputDevice.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputDevice.gd) | 输入设备抽象基类(Node),定义 poll(intent) 接口 |
| [role/input/KeyboardMouseDevice.gd](file:///d:/work2/godot_demo/client/Script/role/input/KeyboardMouseDevice.gd) | 键鼠设备(extends InputDevice),读键盘+鼠标转意图 |
| [role/input/InputIntentProvider.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputIntentProvider.gd) | autoload 全局 Provider(Node),每帧采集+暴露 get_intent() |
| [statemachine/StateBase.gd](file:///d:/work2/godot_demo/client/Script/statemachine/StateBase.gd) | 状态基类(extends RefCounted,纯逻辑),machine/state_name 引用 + _enter_state/_exit_state/_process 虚方法 |
| [statemachine/StateMachineBase.gd](file:///d:/work2/godot_demo/client/Script/statemachine/StateMachineBase.gd) | 状态机基类(extends Node,可 add_child + 自动 _process),add_state/change_state/get_state/get_current_state_name |
| [statemachine/AnimStateMachine.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimStateMachine.gd) | 动画状态机(extends StateMachineBase),Role 平级组件,_ready 注册 IdleState/RunState + 进入 idle,update_state 转发服务端 state |
| [statemachine/IdleState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/IdleState.gd) | 静止状态(extends StateBase),_enter_state 调 visual.play_anim("idle") |
| [statemachine/RunState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/RunState.gd) | 移动状态(extends StateBase),_enter_state 调 visual.play_anim("run") |
| [dead_man_scene.gd](file:///d:/work2/godot_demo/client/Script/dead_man_scene.gd) | 木桩场景(Node2D),接 StateMirror 信号管理 Role 创建/更新/删除 |
| [prefab/role/Role.tscn](file:///d:/work2/godot_demo/client/prefab/role/Role.tscn) | Role 预制体(当前空 Node,实际用脚本 new()) |
| [prefab/role/PlayerVisual.tscn](file:///d:/work2/godot_demo/client/prefab/role/PlayerVisual.tscn) | PlayerVisual 预制体(Body + FacingArrow + NameLabel,静态视觉配置) |

## Role.gd — 通用实体容器

`extends Node2D`, `class_name Role`。组件化 / ECS-lite 设计。

### 核心思路
Role 本身只是"位置容器":有坐标、能挂子节点。它不知道自己是玩家还是木桩——"是什么"由挂载的组件决定。

### 组件分类
- **Visual 组件**:负责显示(Sprite、动画等)
- **Controller 组件**:负责行为(本地玩家读输入、远程玩家读 StateMirror)

### 当前实现
- 本地玩家 → PlayerVisual + AnimStateMachine + LocalPlayerController
- 远程玩家 → PlayerVisual + AnimStateMachine(只显示,不读输入)

### 后续扩展(未实现)
- 木桩 → StakeVisual(被动受击)
- NPC → NpcVisual + NpcController(AI 驱动)

### setup(info)
由 dead_man_scene 在创建/更新 Role 时调用:
1. 记录 player_id
2. 更新坐标(_update_position)
3. 移除旧组件(避免重复挂)
4. 挂 PlayerVisual(所有玩家都要显示)— 用预制体 `PlayerVisual.tscn.instantiate()`,静态视觉配置在预制体里
5. 挂 AnimStateMachine(所有玩家都挂,必须在 PlayerVisual 之后)— 状态机 `_ready` 进入 idle 时要访问 visual 调 `play_anim`,所以挂载顺序:先 PlayerVisual 后 AnimStateMachine(子节点 `_ready` 按添加顺序触发)
6. 判断是否本地玩家(`player_id == ClientStateMirror.local_player_id()`),是则额外挂 LocalPlayerController

### on_player_updated(info)
收到 StateMirror 的 player_updated 信号时调,更新坐标 + 朝向 + 动画状态。**Role 自己不改自己的状态**——永远由 StateMirror 信号驱动,这是服务器权威在客户端的最终体现。
- 坐标:调 _update_position(info)
- 朝向:如果 info 里有 facing 字段,转发给 PlayerVisual.update_facing
- 动画状态:如果 info 里有 state 字段(idle/run/...),转发给 AnimStateMachine.update_state

## PlayerVisual.gd — 视觉组件

`extends Node2D`, `class_name PlayerVisual`。作为预制体 `PlayerVisual.tscn` 的脚本:节点结构/Label 位置/颜色等静态视觉配置在预制体编辑器里配,运行时只处理动态逻辑(切换贴图、设名字文本、转朝向箭头)。

### 节点结构(预制体)
```
PlayerVisual (Node2D)
├── Body (AnimatedSprite2D)   角色身体动画(idle/run 帧,由 AnimStateMachine 驱动)
├── FacingArrow (Sprite2D)    朝向指示器箭头,绕 Body 旋转
└── NameLabel (Label)         名字标签
```

### setup(info)
- 记录 player_id, player_name
- 取预制体节点引用($Body / $FacingArrow / $NameLabel)— 不用 @onready 避免 _ready 时机问题(Role 在 add_child 后立即调 setup)
- Body 不再设 texture:已升级为 AnimatedSprite2D,SpriteFrames 在预制体里配 idle/run 两个动画,播放由 AnimStateMachine 通过 `play_anim` 驱动(本地/远程 Body 动画相同)
- 朝向箭头贴图:本地用蓝色(`arrowBlue_right.png`),远程用棕色(`arrowBrown_right.png`)— 仅靠箭头颜色区分本地/远程
- 设 FacingArrow.texture + NameLabel.text
- 初始朝向:从 info 取 facing(默认 0),调 update_facing
- 本地玩家名字加"(你)"前缀

### update_facing(facing)
- 设箭头 rotation = facing(贴图 _right 后缀表示指向右方,rotation=0 朝右,正好对应 facing=0)
- 设箭头 position = Vector2.RIGHT.rotated(facing) * ARROW_OFFSET(箭头绕 Body 外圈转,ARROW_OFFSET=35)

### play_anim(anim_name)
- 由 AnimStateMachine 的状态(IdleState/RunState)在 `_enter_state` 时调用
- 调 Body(AnimatedSprite2D).play(anim_name),anim_name 对应 SpriteFrames 里的动画名(idle/run)
- 防御:动画不存在时 push_warning;同名动画不重复 play(避免从头开始播)
- 动画切换的决策在状态机,播放的执行在这里——职责分离

### 为什么箭头用 _right 贴图 + rotation 转动
- _right 后缀:贴图本身指向右方(+x),所以 rotation=0 时箭头朝右
- facing 语义:弧度,0=朝右,逆时针正(Godot 标准)
- 箭头位置随 facing 转动,始终在 Body 外圈对应方向(不压在身体上)

### 为什么是组件而非直接写在 Role 里
Role 是通用容器,不该知道"玩家长什么样"。把显示逻辑抽成组件后:
- 木桩挂 StakeVisual,不挂 PlayerVisual
- 显示逻辑变更(换贴图、加动画)只改这一个文件

组件用 Node2D 而非 RefCounted:要被 add_child 到 Role 上,Sprite2D 要在场景树里显示。

## AnimStateMachine.gd — 动画状态机

`extends StateMachineBase`, `class_name AnimStateMachine`。Role 的平级组件(和 PlayerVisual/LocalPlayerController 一样 add_child 到 Role),根据服务端 state 切换动画。

### 架构位置(服务器权威的最终体现)
```
服务端 PlayerInfo.state(idle/run/attack/hurt/...)
    ↓ StateMirror._on_player_move 从 moving 推断 state
    ↓ player_updated 信号
Role.on_player_updated
    ↓ 转发 state 字段给 AnimStateMachine
AnimStateMachine.update_state(state_name)
    ↓ change_state
IdleState / RunState._enter_state
    ↓ machine.get_visual().play_anim("idle"/"run")
PlayerVisual 的 AnimatedSprite2D 播放对应动画
```

### _ready
- 调 `_register_states()` 注册所有状态:`add_state("idle", IdleState.new())` + `add_state("run", RunState.new())`
- 进入初始状态 "idle"(玩家默认静止)
- 时机保证:Role.setup 先 add PlayerVisual 再 add AnimStateMachine,子节点 `_ready` 按添加顺序触发,PlayerVisual 先于 AnimStateMachine,所以状态机 `_ready` 进入 idle 调 `play_anim` 时 visual 已就绪

### update_state(state_name)
由 Role.on_player_updated 调用,转发服务端 PlayerInfo.state 字段。内部调 `change_state`(带校验:不存在状态告警,相同状态不重复进入)。

### get_visual() -> PlayerVisual
状态对象(IdleState/RunState)通过这个方法访问显示层。AnimStateMachine add_child 到 Role,所以 `get_parent()` = Role,再 `get_node_or_null("PlayerVisual")` 拿到 PlayerVisual。

### 状态基类说明(StateBase / StateMachineBase)
- **StateBase**(extends RefCounted):纯逻辑状态对象,不进场景树。持有 `machine`/`state_name` 引用(add_state 时注入),三个虚方法 `_enter_state`/`_exit_state`/`_process` 由状态机回调。RefCounted 更轻量,切换时旧状态自动释放。
- **StateMachineBase**(extends Node):状态机基类,可 add_child 到宿主、自动 `_process` 驱动当前状态。管状态表(`_states: Dictionary`)、当前状态、切换(`change_state` 带校验)、查询(`get_state`/`get_current_state_name`)。状态机只负责「怎么切」,不决策「什么时候切」(切换由 Role 转发服务端 state 触发)。
- 旧版基类 extends Object,无法 add_child、无法自动 _process、用 state.name 当 key 会报错(Object 无 name 属性),已废弃。

### 未来扩展(加攻击/受击状态)
1. 新建 AttackState.gd / HurtState.gd(extends StateBase)
2. `_register_states()` 里 `add_state("attack", AttackState.new())`
3. 服务端加 apply_attack/apply_hurt 方法设 PlayerInfo.state
4. 本状态机自动支持(只要 state 名和动画名对应)

## input/ — 输入端模块

### 核心设计:意图层解耦
```
[KeyboardMouseDevice] ┐
[GamepadDevice(未来)]  ┤→ [InputIntentProvider] → InputIntent → [LocalPlayerController]
[其它设备(未来)]      ┘          (autoload)        (move_dir+     (接收端唯一代码)
                                                          look_target)
```
接收端只读 InputIntentProvider.get_intent(),**不知道也不关心**输入来自哪个设备、按了什么键、键位怎么配的。

### InputIntent.gd — 意图数据结构
`extends RefCounted`。只描述"玩家想做什么",不描述"按了什么键":
- `move_dir: Vector2` — 移动方向(归一化),零向量=不动
- `look_target: Vector2` — 朝向目标点(世界坐标)

### InputBinding.gd — 自定义键位映射
`extends RefCounted`, static 单例。逻辑动作名 ↔ 物理键的映射表。
- 默认键位:WASD + 方向键双绑(move_up: [KEY_W, KEY_UP], ...)
- `rebind(action, old_key, new_key)` 运行时改键 + 自动 save
- 持久化到 `user://input_binding.cfg`(格式:每行 `action:key1,key2`)
- **完全独立于 Godot InputMap**,自己管映射表(用 InputMap 会绕过意图层抽象)

### InputDevice.gd — 抽象基类
`extends Node`, `class_name InputDevice`。定义 `poll(intent)` 接口。
- Node 而非 RefCounted:需要 add_child 到 Provider,才能用 get_viewport() 拿相机
- poll 接收 intent 参数(共享对象写入),多个 device 往同一 intent 写各自字段

### KeyboardMouseDevice.gd — 键鼠设备
`extends InputDevice`。每帧 poll:
- 读键盘:按 InputBinding 查 move_up/down/left/right,累加成 move_dir(归一化,斜走不快 1.414 倍)
- 读鼠标:get_viewport().get_camera_2d().get_global_mouse_position() 转世界坐标写进 look_target

### InputIntentProvider.gd — autoload Provider
`extends Node`, autoload 全局单例。
- _ready 时默认注册一个 KeyboardMouseDevice
- _process 每帧:reset intent → 遍历所有 device 调 poll(intent) → 缓存最终 intent
- `get_intent() -> InputIntent` — 接收端唯一入口,返回缓存值不触发采集
- add_device(device) — 注册新设备(未来加手柄时用)

## LocalPlayerController.gd — 本地控制组件

`extends Node`, `class_name LocalPlayerController`。**接收端**——只读 InputIntentProvider.get_intent()。

### 核心设计(服务器权威 + 输入端解耦)
本地玩家想移动/转朝向,流程:
1. 读 intent(intent.move_dir + intent.look_target)
2. 发 PlayerMove(从 move_dir 算 target)/ PlayerFacing(从 look_target 算 facing)
3. 服务端 apply_move / apply_facing 更新权威状态,广播给所有人(含自己)
4. StateMirror 收到 → player_updated 信号 → Role.on_player_updated → 更新坐标 + 转发 facing 给 PlayerVisual

**注意第4步**:本地玩家的坐标和朝向也是由 StateMirror 信号更新的,不是这里直接改的。保证"本地玩家看到的自己"和"服务端认为的本地玩家"永远一致。

### 朝向和移动是两个独立状态维度
玩家可以一边移动(WASD 决定方向)一边朝任意方向攻击(鼠标决定朝向)。所以 PlayerMove 和 PlayerFacing 是两条独立的消息流,各自发各自的。

### 移动模型:方向移动 → target 坐标
- 当前 proto 的 PlayerMove 是「目标坐标」(target x/y),不是「方向」
- 键盘方向移动转换:target = 当前位置 + move_dir * MOVE_STEP(每帧 5 像素)
- 只有 move_dir 非零时才发包(避免静止时无意义发包)

### 朝向模型:鼠标位置 → facing 弧度
- look_target(世界坐标) - role_pos 得到方向向量
- Vector2.angle() 返回弧度(0=右,逆时针正),和 facing 语义完全一致
- 节流基于 **facing 弧度本身** 是否变化(超过 FACING_EPSILON 才发包),不是基于 look_target
  - 原因:facing = (look_target - role_pos).angle(),鼠标不动但人物在动时 role_pos 变了,facing 也会变
  - 若按 look_target 节流,会出现「鼠标不动人物动时朝向不更新」的 bug
- 首次有有效 look_target 时强制发包一次(_has_last_look 标记初始状态)

### setup(_info)
当前空实现,保留接口和 PlayerVisual.setup 对称。后续如需根据玩家信息调整控制参数(如不同角色移速不同),在这里实现。

## dead_man_scene.gd — 木桩场景

`extends Node2D`。当前阶段只做玩家同步,木桩暂未实现。

### 职责
接 ClientStateMirror 的三个信号,管理 Role 的创建/更新/删除:
- `state_replaced(players)` — 清空所有 Role,用快照重建
- `player_updated(info)` — 已存在则更新坐标,不存在则创建新 Role
- `player_removed(player_id)` — queue_free + 从 _roles 删除

### _ready
- 连接 E_Back 按钮返回大厅
- 连接 StateMirror 三个信号
- 如果 StateMirror 已有状态(进入场景前就收到了 GameState),主动刷一次

### _roles: Dictionary
`player_id -> Role 实例`,快速查找某个玩家对应的 Role。

### 场景结构
DeadManScene.tscn 里有个 E_Back 按钮用于返回 MainScene。Role 实例用 `RoleScript.new()` 创建后 add_child 到场景。

## 依赖关系
- 依赖 client-net:ClientStateMirror(信号驱动 + local_player_id)、MessageBus(LocalPlayerController 发消息)
- 依赖 InputIntentProvider(autoload,LocalPlayerController 读意图)
- 被 client-ui 依赖:MainUI 的"进入游戏"按钮 instantiate DeadManScene

## 当前状态
- 玩家同步闭环已跑通:两个客户端能互相看到对方移动+朝向(本地蓝箭头/远程棕箭头)
- 动画状态机已实现:AnimStateMachine + IdleState/RunState,根据服务端 state 切换 idle/run 动画(Body 升级为 AnimatedSprite2D,SpriteFrames 在预制体里配)
- 木桩玩法未实现(暂缓)
- 键盘方向移动(WASD)+ 鼠标朝向已实现
- 自定义键位支持(InputBinding 模块,改键 UI 暂未做)
- 手柄输入未实现(InputDevice 抽象已就位,加 GamepadDevice 即可)
