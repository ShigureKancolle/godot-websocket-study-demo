# 客户端角色组件 (client-role)

覆盖:`client/Script/role/*` + `client/Script/statemachine/*` + `client/Script/dead_man_scene.gd`
职责:组件化实体容器、视觉表现、本地玩家控制、动画状态机、场景管理 Role 实例

## 文件清单

| 文件 | 职责 |
|------|------|
| [role/Role.gd](file:///d:/work2/godot_demo/client/Script/role/Role.gd) | 通用实体容器(Node2D),按 entity_type 分发挂载不同组件 |
| [role/PlayerVisual.gd](file:///d:/work2/godot_demo/client/Script/role/PlayerVisual.gd) | 视觉组件(Node2D),预制体脚本,运行时切换贴图+设名字+转朝向箭头+按四方向拼动画 |
| [role/VisionFan.gd](file:///d:/work2/godot_demo/client/Script/role/VisionFan.gd) | 敌人视锥渲染组件(Polygon2D),读 vision_config + 按 ai_state 切 normal/chase + 按 facing 旋转,半透明扇形(纯显示,敌人专属) |
| [role/AttackFan.gd](file:///d:/work2/godot_demo/client/Script/role/AttackFan.gd) | 攻击扇形弧光组件(Polygon2D),按攻击形状配置(radius/angle/hit_time/duration)渲染攻击范围+命中时刻,顶点色渐变(圆心透明→弧上峰值),颜色按身份(本人蓝白/队友绿/敌人红),膨胀+淡出动画,命中时刻发 hit_moment 信号(纯显示,玩家敌人通用) |
| [role/LocalPlayerController.gd](file:///d:/work2/godot_demo/client/Script/role/LocalPlayerController.gd) | 本地玩家控制组件(Node),读 InputIntentProvider 意图发 PlayerMove+PlayerFacing+AttackStart |
| [role/CameraFollow.gd](file:///d:/work2/godot_demo/client/Script/role/CameraFollow.gd) | 相机平滑跟随组件(Camera2D),跟随本地玩家坐标 lerp + 屏幕震动(shake:攻击命中时刻随机偏移 2~3px 衰减归零) |
| [role/input/InputIntent.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputIntent.gd) | 意图数据结构(RefCounted),move_dir + look_target + attack_pressed |
| [role/input/InputBinding.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputBinding.gd) | 自定义键位映射(RefCounted+static),类型化绑定(key/mouse)支持键盘+鼠标,rebind+持久化到 user://input_binding.cfg |
| [role/input/InputDevice.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputDevice.gd) | 输入设备抽象基类(Node),定义 poll(intent) 接口 |
| [role/input/KeyboardMouseDevice.gd](file:///d:/work2/godot_demo/client/Script/role/input/KeyboardMouseDevice.gd) | 键鼠设备(extends InputDevice),读键盘+鼠标转意图 |
| [role/input/InputIntentProvider.gd](file:///d:/work2/godot_demo/client/Script/role/input/InputIntentProvider.gd) | autoload 全局 Provider(Node),每帧采集+暴露 get_intent() |
| [statemachine/StateBase.gd](file:///d:/work2/godot_demo/client/Script/statemachine/StateBase.gd) | 状态基类(extends RefCounted,纯逻辑),machine/state_name 引用 + _enter_state/_exit_state/_process 虚方法 |
| [statemachine/StateMachineBase.gd](file:///d:/work2/godot_demo/client/Script/statemachine/StateMachineBase.gd) | 状态机基类(extends Node,可 add_child + 自动 _process),add_state/change_state/get_state/get_current_state_name |
| [statemachine/AnimState/AnimStateMachine.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/AnimStateMachine.gd) | 动画状态机(extends StateMachineBase),Role 平级组件,注册 Idle/Run/Attack/Hurt/Dead 状态,update_state 转发服务端 state |
| [statemachine/AnimState/IdleState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/IdleState.gd) | 静止状态(extends StateBase),_enter_state 调 visual.play_anim("idle") |
| [statemachine/AnimState/RunState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/RunState.gd) | 移动状态(extends StateBase),_enter_state 调 visual.play_anim("run") |
| [statemachine/AnimState/AttackState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/AttackState.gd) | 攻击状态(extends StateBase),_enter_state 调 visual.play_anim("attack") |
| [statemachine/AnimState/HurtState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/HurtState.gd) | 受击状态(extends StateBase),_enter_state 调 visual.play_anim("hurt"),_reenter_state 调 visual.replay_cur_anim() 处理连击重启 |
| [statemachine/AnimState/DeadState.gd](file:///d:/work2/godot_demo/client/Script/statemachine/AnimState/DeadState.gd) | 死亡状态(extends StateBase),_enter_state 调 visual.play_anim("dead") 播死亡动画,播完不切回(等 EntityRemove 消息来 queue_free) |
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
| PLAYER(本地) | PlayerVisual + AttackFan | ✓ | LocalPlayerController | 本地额外挂 Controller |
| PLAYER(远程) | PlayerVisual + AttackFan | ✓ | — | 只显示,坐标由 StateMirror 驱动 |
| STAKE | PlayerVisual(占位) | — | — | 未来可换 StakeVisual |
| ENEMY(史莱姆/骷髅) | PlayerVisual + AttackFan + VisionFan | ✓ | — | _setup_enemy:复用玩家显示 + 挂视锥(ai_state 驱动 normal/chase 形态) |

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
4. 挂 **AttackFan**(攻击扇形弧光,玩家/敌人都攻击所以统一挂,木桩不走本方法不挂):
   - `hit_moment` 信号连到 `_on_attack_hit_moment`(本地玩家命中时刻震屏)

### _setup_stake(info)
当前简化:只挂 PlayerVisual(占位,显示圆形角色贴图 + 名字标签 + 朝向箭头)。
- 不挂 AnimStateMachine:木桩目前没有动画状态切换需求
- 不挂 LocalPlayerController:木桩不被本地控制
- 未来木桩的 hurt 状态由 StateMirror 的 `entity_updated` 信号直接改 state 字段驱动(无动画状态机介入)
- 后续替换为 StakeVisual 时只改本方法,不影响其他 entity_type

### _setup_enemy(info)
复用玩家组件(`_setup_player`:PlayerVisual + AnimStateMachine + 血条),再额外挂 **VisionFan**(视锥渲染组件):
- `preload("res://Script/role/VisionFan.gd").new()` + add_child,和 PlayerVisual 一样脚本挂载
- `setup(info.ai_state)` 按初始 AI 状态生成视锥形态(chase → 窄而远,其余 → normal 宽而近)
- `set_facing(info.facing)` 初始朝向;`z_index = 1` 显示在角色/地形之上(半透明)
- **视锥开关**:`ConfigLoader.is_vision_enabled()`(VISION_ENABLED)为 false 时不挂载——服务端敌人已无视视锥,显示扇形会误导玩家;未挂载时 `on_entity_updated` 的 `get_node_or_null("VisionFan")` 自然跳过转发

### VisionFan.gd — 敌人视锥渲染组件
`extends Polygon2D`, `class_name VisionFan`。纯显示组件,不做障碍物遮挡(后续可扩展射线遮挡)。
- 数据来源:视锥参数(半角/半径)读 `ConfigLoader.get_vision(mode)`(vision_config.json);ai_state/facing 由 Role.on_entity_updated 转发 StateMirror 信号驱动
- 形态切换:`set_ai_state(ai_state)` 按 `"chase" if ai_state == "chase" else "normal"` 选视野 + 换颜色(normal 半透明红 / chase 半透明橙)
- 朝向:`set_facing(facing)` 设节点 rotation(facing=0 朝右,Godot 标准)——顶点按朝右生成一次,之后只转节点,不重算顶点
- 顶点生成:圆心 Vector2.ZERO + 弧上 SEGMENTS=32 段,从 `-half_angle` 扫到 `+half_angle`,`Vector2.RIGHT.rotated(a) * radius`
- 为什么是组件:Role 是通用容器,视锥是"敌人"类型专属显示,抽成组件只有敌人挂

### AttackFan.gd — 攻击扇形弧光组件
`extends Polygon2D`, `class_name AttackFan`。纯显示组件,攻击触发时渲染攻击范围 + 命中时刻提示。
- **数据来源(时间/角度/范围全部由攻击配置决定)**:`AttackCalc.get_shape(atk_id, shape_index)` 取 AttackShape(radius/angle/hit_time/duration),和攻击判定用同一份 shared_config/attack_config.json
- **顶点色渐变(剑气外放)**:圆心 alpha=0(完全透明)→ 弧上 alpha=0.45(峰值),`vertex_colors` 按顶点插值
- **颜色按攻击者身份**(Role._trigger_attack_fan 判断):本人 SELF 淡蓝白 / 队友 TEAM 绿 / 敌人 ENEMY 红(敌人攻击也显示红色威胁弧光)
- **时间轴(零贴图)**:0.15s 膨胀(scale 0.3→1.0,圆心不动向外炸开)→ 保持到命中时刻(hit_time)最亮 → 命中时刻发 `hit_moment` 信号(本地玩家震屏锚点)→ 攻击结束(duration)淡出归零隐藏
- **触发**:Role.on_entity_updated 检测 state 进入 "attacking" 瞬间调 `show_attack(atk_id, 0, facing, identity)`(AttackStart 广播带 atk_id;shape_index 固定 0=主挥砍段,AttackHit 带 atk_shape_idx 可后续扩展多段切换)
- **层级**:z_index=1(和 VisionFan 同级,实体之上 UI 之下,半透明效果层)——不依赖场景树分层,俯视角遮挡靠 y-sort,弧光统一盖实体层且半透明不影响受击反馈可见
- **后坐联动**:本地玩家攻击时 Role 设 `_recoil_offset`(朝向反方向 12px),`_process` 只偏移 PlayerVisual 子节点并指数衰减回零——Role.position(预测/权威)不动,不污染预测轨迹/软对账

### on_entity_updated(info: ClientEntityInfo)
收到 StateMirror 的 `entity_updated` 信号时调(Role 自己不改状态——永远由 StateMirror 信号驱动,这是服务器权威在客户端的最终体现):
- 坐标:调 `_update_position(info)` — **只更新 target_pos,不直接改 position**(见下方"位置同步")
- 朝向:转发 `info.facing` 给 `PlayerVisual.update_facing` + `VisionFan.set_facing`(有视锥时)
- AI 状态:`info.ai_state` 转发给 `VisionFan.set_ai_state`(只有敌人挂了视锥;由 StateMirror._on_ai_state_changed 增量更新,切换即广播)
- 攻击弧光:**state 进入 "attacking" 瞬间**(was_attacking 判定防重复触发)调 `_trigger_attack_fan` → `AttackFan.show_attack(atk_id, 0, facing, identity)`
- 动画状态:`info.state` 非空则转发给 `AnimStateMachine.update_state`(木桩没挂状态机时跳过)

### 位置同步(服务端权威,本地预测+软对账 / 远程 lerp)
本地玩家与远程实体共用 `target_pos`(服务端权威位置),但表现策略不同:

- **本地玩家**:半预测 + 软对账
  - LocalPlayerController 发方向后立即本地预测推进(`position += dir * speed * delta`)
  - Role._process 每帧把预测位置记入 `_pred_history`(预测轨迹,窗口 1000ms)
  - 收到服务端广播时,`_reconcile_prediction` 回溯「RTT + 半个 tick」前的预测位置,
    与服务端权威 `target_pos` 比较:
    - 误差 ≤ 15px:预测正确,忽略(不回正 → 不拉扯)
    - 误差 > 15px:真脱节(服务端因碰撞/attacking 锁定没推进),`position.lerp(target_pos, 0.35)` 平滑回正 + 清空历史
  - **变向宽限**:LocalPlayerController 检测到方向突变(夹角>60° 或 移动→停止)时记录时刻 `_last_dir_change_ms`;变向后 `RTT + 1.5×tick + 30ms` 的宽限窗口内 `_reconcile_prediction` 跳过回正(轨迹照常记录)——服务端要等「输入排队 ≤1 tick + tick 处理 + 半程 RTT 回传」才按新方向推进,这期间广播的仍是旧方向轨迹,回正会把玩家"折回"旧方向。窗口外恢复正常对账,真脱节仅延迟一个窗口仍会被回正
  - 回溯时刻为什么是「RTT + 半个 tick」而非「RTT」:服务端收到输入后要在 pending 里排队等下一个 tick(平均半个 tick)才生效,推进起步比客户端预测晚这一段,回溯要覆盖它,否则匀速移动也有 speed×tick/2≈5px 的稳态误差
  - 效果:位置由本地方向自推进,无"追-停"顿挫、无 RTT 输入滞后;服务端坐标只做校验

- **硬直(hurt)期间(含击退)**:本地玩家停止预测,改为 lerp 跟随服务端位置
  - 硬直中 LocalPlayerController 已因 state=="hurt" 停预测,若仍靠软对账,
    单 tick 击退位移(~3px)小于 15px 阈值不会触发回正 → 本地玩家视觉上不会被推走
  - Role 缓存 `_state`(on_entity_updated 更新),`_process` 里 `_state=="hurt"` 时
    `position = position.lerp(target_pos, delta*LERP_FACTOR)`(和远程一样跟随),
    `_update_position` 跳过软对账、`_record_prediction` 停止
  - 硬直结束(HurtEnd → state="idle")后恢复预测,此时 position 已跟上服务端,衔接平滑

- **远程实体(敌人/其他玩家)**:插值模式
  - 服务端 30Hz 给出 target_pos,客户端 60Hz lerp 向它平滑过渡
  - `position = position.lerp(target_pos, min(delta * LERP_FACTOR, 1.0))`
  - LERP_FACTOR=15.0 → 60fps 时 alpha≈0.25,约 4 帧(66ms)追上目标点,视觉平滑无卡顿
  - min 截断到 1.0:防止低帧率时 delta 过大导致 alpha>1(overshoot)

- **首次定位**:直接 snap position = target_pos(避免新 Role 从 (0,0) lerp 飞到目标位置)
  - 用 `_position_initialized` 标记,只在首次 _update_position 时 snap

> 方案演进(本地玩家位置同步,踩过的坑):
> | 方案 | 问题 |
> |------|------|
> | 指数 lerp | 追赶匀速目标有稳定滞后 → "被往前拖";松键停止滑行 → "脚滑" |
> | 纯 snap(position=target_pos) | 30Hz 广播每 33ms 跳 10px → 步进抖动 |
> | 限速线性追赶(speed×1.2) | 追到位→停等→等广播;30Hz 广播到达不均匀(局域网 tick 也有 10-20ms 抖动)→ 本地玩家"走走停停"顿挫;方向切换追着旧方向坐标滑一段再折回 → 回跳 |
> | 预测+软对账(初版) | Windows 15.6ms 定时粒度下服务端 tick 实际约 47ms + 固定 dt 积分 → 服务端移速只有 71% → 匀速移动周期性回拉;变向时服务端推进滞后(排队等 tick + RTT)未被对账覆盖 → 变向折回 |
> | 预测+软对账(当前) | ✅ 服务端实测 dt 积分 + timeBeginPeriod(1) 提频(移速与墙钟一致);客户端对账回溯修正为 RTT+半个 tick;变向/急停后宽限窗口内跳过回正。本地方向自推进无停等,服务端坐标只做校验,误差>15px 才 lerp 平滑回正 |

新增字段/常量:
- `target_pos: Vector2` — 服务端权威位置(从 entity_updated 信号拿到,只读)
- `_is_local: bool` — 是否本地玩家(setup 时判断,决定预测对账还是 lerp)
- `_state: String` — 最近一次从服务端同步到的动画状态(缓存,hurt 硬直判断用)
- `_position_initialized: bool` — 位置是否已初始化(首次直接 snap)
- `_pred_history: Array` — 本地预测轨迹历史(条目 [time_ms, x, y]),供软对账回溯
- `PRED_HISTORY_WINDOW_MS = 1000` / `PRED_HISTORY_MAX_ENTRIES = 200` — 轨迹窗口/上限
- `RECONCILE_THRESHOLD = 15.0` — 软对账阈值(需盖住 RTT 偏差引起的回溯偏移,speed×偏差≈9px)
- `RECONCILE_LERP = 0.35` — 回正插值系数(平滑回正,不硬跳)
- `LERP_FACTOR = 15.0` — 远程实体 lerp 因子系数
- `SERVER_TICK_MS = 33.0` — 服务端 tick 周期(和服务端 TICK_INTERVAL_MS 对齐),对账回溯修正 + 宽限窗口计算用
- `DIR_CHANGE_GRACE_TICKS = 1.5` / `DIR_CHANGE_GRACE_MARGIN_MS = 30.0` — 变向宽限窗口 = RTT + 1.5×tick + 30ms
- `_last_dir_change_ms`(LocalPlayerController) — 最近一次方向突变(夹角>60° 或 移动→停止)的时刻,`get_last_dir_change_ms()` 暴露给 Role 对账做宽限判断;`DIR_CHANGE_DOT_THRESHOLD = 0.5` 是变向夹角阈值(点积)

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
- 调 `_register_states()` 注册所有状态:`add_state("idle", IdleState.new())` + `add_state("run", RunState.new())` + `add_state("attack", AttackState.new())` + `add_state("hurt", HurtState.new())` + `add_state("dead", DeadState.new())`
- 进入初始状态 "idle"(玩家默认静止)
- 时机保证:Role.setup 先 add PlayerVisual 再 add AnimStateMachine,子节点 `_ready` 按添加顺序触发,PlayerVisual 先于 AnimStateMachine,所以状态机 `_ready` 进入 idle 调 `play_anim` 时 visual 已就绪
- "dead" 状态对应服务端 apply_hurt 判定 hp<=0 且 can_die=True 时设的 state;DeadState 播死亡动画后不切回,等 EntityRemove 消息来才 queue_free(详见下方 DeadState.gd 说明)

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

## DeadState.gd — 死亡状态

`extends StateBase`, `class_name DeadState`。实体 hp 扣到 0 且 can_die=True 时进入(由服务端 apply_hurt 判定后广播 EntityDead,StateMirror 设 state="dead" 触发)。

- `_enter_state` 调 `visual.play_anim("dead")` 播放死亡动画
- **播完不切回 idle**:死亡是终态,等 EntityRemove 消息来才 queue_free 移除节点(服务端 DeadTimer 到期后广播 EntityRemove)
- 不实现 `_reenter_state`:死亡不会"重复死亡"(服务端 get_attack_hits 已过滤 state=="dead" 的实体,不会再被命中)
- 和 HurtState 的区别:HurtState 硬直结束(服务端 HurtTimer 到期)→ state="idle" → 切回 IdleState;DeadState 死亡动画播完不动 → 等 EntityRemove → queue_free

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

### 核心设计(服务器权威 + 输入端解耦 + 本地预测)
本地玩家想移动/转朝向/攻击,流程:
1. 读 intent(intent.move_dir + intent.look_target + intent.attack_pressed)
2. 发 PlayerMove(发方向向量 dir_x/dir_y,不发目标坐标)/ PlayerFacing(从 look_target 算 facing)/ AttackStart(攻击键按下时)
3. **本地预测**:发完方向后立即 `position += dir * speed * delta` 推进自己(不等服务端回传,消除延迟感)
4. 服务端 apply_move_dir 只记住方向(不推进位移),tick_movement 每 tick 持续推进;apply_facing / apply_attack_start 更新权威状态,广播给所有人(含自己)
5. StateMirror 收到 → `entity_updated` 信号 → Role.on_entity_updated → 更新 target_pos(不直接改 position)
6. Role 软对账:收到广播回溯 RTT 前预测位置,与服务端位置误差小则忽略,大则 lerp 平滑回正(撞墙/hurt 锁定导致服务端没推进,预测跑偏了)

**为什么本地预测不违反服务器权威**:预测是临时手段,服务端回传后 Role 软对账。两端用同一个 speed(entity_config.json),服务端 tick_movement 每 tick 按 dir * speed * TICK_INTERVAL 推进,客户端每帧按 dir * speed * delta 预测,1 秒总位移一致,误差很小。只有服务端拒绝了移动(如 hurt/attacking/撞墙)时,误差超过阈值才平滑回正(lerp,不是硬 snap)。

### 攻击流程
1. 检查 `mirror.get_entity(mirror.local_entity_id()).state`,若已是 `"attacking"` 则跳过(防连点)
2. `intent.attack_pressed` 为 true 时发 `game.AttackStart`,字段 `entity_id` + `atk_id`
3. **预判**:`player.state = "attacking"`(直接改 ClientEntityInfo 强类型对象的字段,不等服务端广播回来才切,避免输入延迟感)
4. 服务端走 AttackStart → hit_cb → end_cb 三段定时器,期间广播 AttackHit/AttackEnd
5. 客户端收到 AttackHit 时,StateMirror 遍历 hit_list 把被命中者的 `ClientEntityInfo.state` 设为 `"hurt"`

> 字段名:统一 Entity 模型后用 `entity_id`(原 `role_id` 已废弃)。注:服务端 handler 实际用 `ctx.player_id` 而非读 client 发的 entity_id,但为了契约一致性,客户端仍然填上 entity_id 字段。
> 字段访问:从 dict 索引 `player["state"]` 改为强类型属性 `player.state`,IDE 可补全、拼错编译期报错。

### 朝向和移动是两个独立状态维度
玩家可以一边移动(WASD 决定方向)一边朝任意方向攻击(鼠标决定朝向)。所以 PlayerMove 和 PlayerFacing 是两条独立的消息流,各自发各自的。**输入锁定状态(attacking/hurt/dead)期间两者都禁发,也不做本地预测推进**(和服务端 `_INPUT_LOCKED_STATES` 对齐)。hurt 期间不锁会导致客户端预测跑偏而服务端不动,软对账每次 lerp 拉一点 → "被打一次拉回一点"。

### 移动模型:方向向量 + 本地预测(服务端权威移动)
- 客户端只发方向向量(dir_x/dir_y),不发目标坐标
- 键盘方向(Input.get_vector 已归一化)直接作为 dir_x/dir_y 发出
- 发完后立即本地预测:`get_parent().position += move_dir * speed * delta`(speed 来自 ConfigLoader.get_speed("player"))
- 只有 move_dir 非零时才发包(避免静止时无意义发包)
- `moving` 字段状态机:
  - 正在移动:每帧发 moving=true + 方向,服务端设 state="run"
  - 刚停止(`_was_moving` true → false):发一次 moving=false,服务端设 state="idle"
  - 持续静止:不发(避免无意义发包)

为什么改成方向 + 预测(旧模型的问题):
- 旧:客户端发目标坐标 → 服务端直接落地 → 广播
  问题:客户端 60Hz 发,服务端 30Hz tick 节流丢半,真实速度腰斩,每 tick 被拉回
- 新:客户端发方向 + 本地预测 → 服务端按方向推进 → 广播 → 客户端对账
  两端用同一个 speed,位移速度一致,无拉回

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
- **服务端权威移动 + 本地预测软对账已实现**:LocalPlayerController 发方向(dir_x/dir_y)+ 本地预测(position += dir * speed * delta);Role 记预测轨迹 + 软对账(回溯 RTT+半个 tick 前预测位置,误差>15px 才 lerp 平滑回正;变向/急停后宽限窗口内跳过回正)/ 远程 lerp 插值(30Hz→60Hz 平滑);服务端 apply_move_dir 只记方向 + tick_movement 按实测 dt 持续推进,解决"丢 tick → 误差累积 → 拉回"和"Windows 定时粒度 → 移速漂移 → 周期性回拉"问题;本地玩家不再"限速追赶"(那会追到位→停等→广播抖动顿挫)
- 玩家同步闭环已跑通:两个客户端能互相看到对方移动+朝向(本地蓝箭头/远程棕箭头)
- 攻击流程已实现:LocalPlayerController 发 AttackStart,StateMirror 处理 AttackHit/AttackEnd,AnimStateMachine 支持 attack/hurt 状态
- **hurt 硬直已实现**:StateMirror 处理 AttackHit(进 hurt)+ HurtEnd(恢复 idle),纯服务端权威恢复(路径X);AnimStateMachine 的 change_state 加 `_reenter_state` 重入机制,HurtState override 后调 replay_cur_anim() 实现连击重启动画;StateBase 加 `_reenter_state` 虚方法(基类默认空)
- 动画状态机已实现:AnimStateMachine + Idle/Run/Attack/Hurt 四状态,根据服务端 state 切换动画(Body 是 AnimatedSprite2D,SpriteFrames 在预制体里配 4方向×多状态动画,PlayerVisual 按 facing 弧度拼出 "Down_Idle" 等播放)
- 木桩占位显示:复用 PlayerVisual,后续替换为 StakeVisual
- 键盘方向移动(WASD)+ 鼠标朝向已实现
- 自定义键位支持(InputBinding 模块,改键 UI 暂未做)
- 手柄输入未实现(InputDevice 抽象已就位,加 GamepadDevice 即可)
- **敌人视锥渲染已实现**:Role._setup_enemy 挂 VisionFan(Polygon2D 半透明扇形,纯显示);VisionFan 按 ai_state 切 normal/chase(读 ConfigLoader.get_vision)+ rotation 跟随 facing;数据由 StateMirror._on_ai_state_changed(AiStateChanged 增量广播)→ entity_updated → on_entity_updated 转发(详见 tools/视锥渲染方案.md)
- **视锥开关联动已实现**:ConfigLoader.is_vision_enabled() 读 constants.json 的 VISION_ENABLED(默认 true);false 时 _setup_enemy 不挂 VisionFan(服务端敌人无视视锥,显示扇形会误导),on_entity_updated 的 get_node_or_null 自然跳过
- **攻击扇形弧光已实现**:新建 AttackFan.gd(Polygon2D,玩家/敌人都挂)——按攻击形状配置(radius/angle/hit_time/duration)渲染扇形范围,顶点色渐变(圆心透明→弧上峰值,"剑气外放"),颜色按身份(本人淡蓝白/队友绿/敌人红),0.15s 膨胀+保持到命中时刻最亮+淡出(零贴图);Role.on_entity_updated 检测 state 进入 attacking 瞬间触发(was_attacking 防重复);命中时刻发 hit_moment 信号
- **屏幕震动 + 攻击后坐已实现**:CameraFollow.gd 加 shake()(攻击命中时刻随机偏移 3px 衰减归零,只震本机);本地玩家攻击时 Role 设 _recoil_offset(朝向反方向 12px)只偏移 PlayerVisual 子节点并衰减回零,Role.position(预测/权威)不动、不污染软对账
## 生存实体表现（PLAN-20260818-003）

敌人的 `ai_state=returning` 仅作为服务端镜像状态，客户端负责表现返程移动；实体 ID 生命周期由快照/移除事件驱动，不因离开激活距离而重建或清血。
