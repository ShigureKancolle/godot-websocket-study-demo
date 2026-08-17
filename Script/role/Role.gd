extends Node2D
class_name Role

"""
文件: client/Script/role/Role.gd
作用: 通用实体容器——通过挂载不同组件复用为玩家/木桩/NPC 等

============================================================================
 设计思路(组件化 / ECS-lite)
============================================================================
Role 本身只是一个「位置容器」: 有坐标、能挂子节点。
它不知道自己是玩家还是木桩——「是什么」由 entity_type 决定挂载的组件。

组件分类:
    - Visual 组件: 负责显示(Sprite、动画等)
    - Controller 组件: 负责行为(本地玩家读输入、远程玩家读 StateMirror)
    - AnimStateMachine 组件: 负责动画状态切换(idle/run/attacking/hurt)

按 entity_type 分发(本次统一 Entity 模型 + 强类型重构):
    - player:
        - 本地玩家 → PlayerVisual + AnimStateMachine + LocalPlayerController
        - 远程玩家 → PlayerVisual + AnimStateMachine
    - stake:
        - 只挂 PlayerVisual(占位,未来可换 StakeVisual)
        - 不挂 AnimStateMachine(木桩目前只有 idle/hurt,hurt 由 StateMirror 信号直接改 state 字段)
        - 不挂 LocalPlayerController(木桩不被本地控制)

后续扩展:
    - 木桩 → StakeVisual(被动受击,有自己的贴图)
    - NPC → NpcVisual + NpcController(AI 驱动)

============================================================================
 和服务器权威状态同步的关系(半预测 + 软对账)
============================================================================
所有实体采用「服务端权威」;本地/远程的位置表现策略不同:

    - 本地玩家: LocalPlayerController 读输入 → 发 PlayerMove{dir_x, dir_y}
                发完立即本地预测 position += dir * speed * delta(消除 RTT 滞后和顿挫)
                → 服务端 apply_move_dir 记方向 → tick_movement 按实测 dt 推进权威位置 → 广播
                → StateMirror 更新 → entity_updated → Role 更新 target_pos
                → Role 软对账:回溯「RTT + 半个 tick」前的预测位置,与服务端坐标误差小则忽略,
                  误差大(服务端因碰撞/锁定没推进)才 lerp 平滑回正;
                  变向/急停后的宽限窗口内跳过回正(服务端还没按新方向推进,回正会折回)
    - 远程玩家/敌人: 同上,但 Role._process 用 lerp 平滑 30Hz 跳变(30Hz→60Hz)
    - 木桩: StateMirror 收到 GameState 快照 → state_replaced 信号 → Role 创建并定位

为什么本地是「预测 + 软对账」而不是「限速追赶」:
    纯追赶(本地追服务端坐标)有个结构性缺陷:追到位 → 停等 → 等下一个广播。
	30Hz 广播到达不均匀时(局域网 tick 也有 10-20ms 抖动),就变成"走走停停"的顿挫;
    方向切换时还追着旧方向坐标滑一小段再折回。本地玩家明明知道自己的方向,
    用方向自推进(预测)就没有停等;服务端坐标只做校验(软对账),误差超阈值才回正。

============================================================================
 强类型 ClientEntityInfo(本次重构)
============================================================================
setup/on_entity_updated 的参数从 Dictionary 改为 ClientEntityInfo:
	- 字段访问用 info.x / info.state 而非 info["x"] / info["state"]
    - entity_type 从 String 改为 ClientEntityInfo.EntityType 枚举
    - match 用 EntityType.PLAYER / EntityType.STAKE 做穷尽性检查
"""

# 这个 Role 对应的实体ID
# 用它和 StateMirror.local_entity_id() 对比,判断是本地玩家还是远程玩家
# entity_id 带类型前缀: "player:uuid-xxx" / "entity:stake_1"
var entity_id: String = ""

# 实体类型(枚举): PLAYER / STAKE / UNKNOWN
# setup 时从 info.entity_type 取出并缓存,用于决定挂什么组件、如何更新
# 用枚举而非字符串:match 有穷尽性检查,拼错编译期报错
var entity_type: ClientEntityInfo.EntityType = ClientEntityInfo.EntityType.UNKNOWN

# 战斗数据
var entity_combat: ClientStateMirror.ClientCombatStats = null

# ---------------------------------------------------------------------------
# 位置插值(服务端权威同步)
# ---------------------------------------------------------------------------
# 服务端权威位置(从 entity_updated 信号拿到,只读)
# 位置完全由服务端广播驱动——发 PlayerMove 只是告诉服务端"我想往哪走"。
var target_pos: Vector2 = Vector2.ZERO

# 是否是本地玩家(setup 时判断)
# 本地/远程的插值策略不同:
#   - 本地: 限速线性追赶 target_pos(移动连续不抖、到位即停不滑,见 _process)
#   - 远程: lerp 平滑(远端 30Hz 跳变需要插值平滑,滑一点反而是优点)
var _is_local: bool = false

# 位置是否已初始化(首次 _update_position 时直接 snap,不插值)
# 避免新创建的 Role 从 (0,0) lerp 飞到目标位置
var _position_initialized: bool = false

# 最近一次从服务端同步到的动画状态(缓存,供 _process 判断本地玩家是否在硬直中)
# 硬直(hurt)期间本地玩家不预测、不软对账,改为 lerp 跟随服务端位置(被击退时)
var _state: String = ""

# ---------------------------------------------------------------------------
# 本地玩家:预测轨迹历史 + 软对账(消除"拉扯")
# ---------------------------------------------------------------------------
# 本地玩家位置由 LocalPlayerController 每帧预测推进,这里记录预测轨迹,
# 收到服务端广播时回溯 RTT 前的预测位置与权威位置比较(软对账):
#   - 误差小:预测正确,忽略(不回正 → 不拉扯)
#   - 误差大:真脱节(服务端碰撞/锁定没推进),lerp 平滑回正
# 对比"限速追赶":追赶会"追到位→停等→等广播",广播抖动就顿挫;
# 预测自推进没有停等,是消除拉扯的核心。
var _pred_history: Array = []

# 预测轨迹记录窗口(毫秒):只留最近这段,RTT 回溯够用
# 60fps 下 1000ms ≈ 60 条
const PRED_HISTORY_WINDOW_MS: int = 1000

# 预测轨迹上限条数(防极端低帧率下窗口内条数爆炸)
const PRED_HISTORY_MAX_ENTRIES: int = 200

# 软对账阈值(像素):回溯 RTT 前预测位置与服务端位置误差超过它才回正
# 需盖住 RTT 偏差引起的回溯偏移(speed×偏差,300px/s×30ms≈9px),取 15px
const RECONCILE_THRESHOLD: float = 15.0

# 回正插值系数:脱节时 position.lerp(target_pos, 0.35) 平滑回正,不硬跳(避免瞬移)
const RECONCILE_LERP: float = 0.35

# ---------------------------------------------------------------------------
# 攻击后坐(纯视觉,不影响预测/对账)
# ---------------------------------------------------------------------------
# 攻击触发瞬间角色向后(朝向反方向)顿一下再回弹,配合大范围弧光形成"重击感"。
# 实现:只偏移 PlayerVisual 子节点位置,Role.position(预测/权威)完全不动——
# 不污染预测轨迹历史,不触发软对账,也不影响服务端判定。
# 衰减系数:lerp 回零,~12/s 约 0.15s 内回弹完
const RECOIL_PX: float = 12.0
const RECOIL_DECAY: float = 12.0
var _recoil_offset: Vector2 = Vector2.ZERO

# 服务端 tick 周期(毫秒),和服务端 GameServer.TICK_INTERVAL_MS 对齐
# 用于:对账回溯时刻修正(输入排队平均等半个 tick) + 变向宽限窗口计算
const SERVER_TICK_MS: float = 33.0

# 变向宽限窗口 = RTT + DIR_CHANGE_GRACE_TICKS × tick + DIR_CHANGE_GRACE_MARGIN_MS
# 方向刚变过(含急停)时,服务端要等「输入排队(≤1 tick)+ tick 处理 + 半程 RTT 回传」
# 才按新方向推进,这期间广播的仍是旧方向轨迹,回正会把玩家"折回"旧方向 → 窗口内跳过。
# 1.5 个 tick 覆盖「排队最坏 1 tick + 处理/回传抖动」;margin 兜底时序噪声
const DIR_CHANGE_GRACE_TICKS: float = 1.5
const DIR_CHANGE_GRACE_MARGIN_MS: float = 30.0

# 远程实体 lerp 因子系数:lerp(position, target_pos, delta * LERP_FACTOR)
# 15.0 → 60fps 时 alpha≈0.25,约 4 帧(66ms)追上目标点,视觉平滑无卡顿
const LERP_FACTOR: float = 15.0


## 初始化 Role: 根据 ClientEntityInfo 决定挂什么组件
## 由 dead_man_scene 在创建/更新 Role 时调用
func setup(info: ClientEntityInfo) -> void:
	entity_id = info.entity_id
	entity_type = info.entity_type

	# 判断是否本地玩家(决定插值策略:本地 snap / 远程 lerp)
	var local_eid = ClientStateMirror.instance().local_entity_id()
	_is_local = (entity_id == local_eid and entity_id != "")

	# 先更新坐标(setup 也可能携带最新坐标)
	_update_position(info)

	# 避免重复挂组件: 如果已经挂过同名组件,先移除
	# 这在 entity_updated 信号重复触发时有用(虽然一般不会重复挂)
	_remove_component("PlayerVisual")
	_remove_component("LocalPlayerController")
	_remove_component("AnimStateMachine")
	_remove_component("HpProgressBar")
	_remove_component("MpProgressBar")
	_remove_component("VisionFan")
	_remove_component("AttackFan")

	# 按 entity_type 分发挂载组件
	# 当前实现:
	#   - PLAYER: PlayerVisual + AnimStateMachine(本地玩家额外挂 LocalPlayerController)
	#   - STAKE:  只挂 PlayerVisual(占位,木桩目前不需要动画状态机和控制器)
	# 未来扩展时,在这里加新的分支或 dispatch 到专门的 _setup_xxx 方法
	match entity_type:
		ClientEntityInfo.EntityType.PLAYER:
			_setup_player(info)
		ClientEntityInfo.EntityType.STAKE:
			_setup_stake(info)
		ClientEntityInfo.EntityType.ENEMY_SLIME:
			_setup_enemy(info)
		ClientEntityInfo.EntityType.ENEMY_SKELETON:
			_setup_enemy(info)
		_:
			# 未知类型:按 player 处理(兼容性兜底,日志告警便于发现配置错误)
			push_warning("Role.setup: 未知 entity_type=%s,按 player 处理" % info.type_string())
			_setup_player(info)


## 设置玩家类型实体: 挂 PlayerVisual + AnimStateMachine,本地玩家额外挂 Controller
func _setup_player(info: ClientEntityInfo) -> void:
	# 挂 PlayerVisual(所有玩家都要显示)
	# 用预制体实例化:节点结构/Label 位置/颜色等静态配置在 PlayerVisual.tscn 里
	# 先挂 visual,再挂状态机:状态机 _ready 时要访问 visual 播初始动画
	var visual = preload("res://prefab/role/PlayerVisual.tscn").instantiate()
	visual.name = "PlayerVisual"
	add_child(visual)
	# 调用组件的初始化(传入玩家信息,让它知道显示什么)
	visual.setup(info)

	# 挂 AnimStateMachine(所有玩家都要挂动画状态机)
	# 必须在 PlayerVisual 之后挂:_ready 进入 idle 状态时要调 visual.play_anim
	var anim_machine = preload("res://Script/statemachine/AnimState/AnimStateMachine.gd").new()
	anim_machine.name = "AnimStateMachine"
	add_child(anim_machine)
	anim_machine.setup(info)
	# 注:anim_machine._ready 会在进场景树时自动触发(注册状态 + 进入 idle)
	# Role 此刻可能还没 add_child 到场景树(dead_man_scene 的创建顺序),
	# _ready 会延迟到 Role 进场景树时触发,那时 PlayerVisual 也已就绪

	# 判断是否本地玩家
	# 本地玩家额外挂 LocalPlayerController(读键盘输入发 PlayerMove)
	# 远程玩家不挂,它的坐标完全由 StateMirror 的 entity_updated 信号驱动
	var local_eid = ClientStateMirror.instance().local_entity_id()
	if entity_id == local_eid and entity_id != "":
		var controller = preload("res://Script/role/LocalPlayerController.gd").new()
		controller.name = "LocalPlayerController"
		add_child(controller)
		controller.setup(info)

	# 血条
	var hp_bar = preload("res://prefab/role/ProgressBar.tscn").instantiate()
	hp_bar.name = "HpProgressBar"
	add_child(hp_bar)
	hp_bar.set_type("hp")
	hp_bar.set_auto_hide(false)
	hp_bar.position = Vector2(0, -39)

	# 攻击扇形弧光(玩家/敌人都攻击,统一挂;木桩不走 _setup_player 不挂)
	# 攻击触发时按攻击形状配置渲染范围 + 命中时刻(颜色按身份:本人蓝白/队友绿/敌人红)
	# 数据流:AttackStart 广播 → StateMirror 设 state="attacking" → on_entity_updated → show_attack
	var attack_fan = preload("res://Script/role/AttackFan.gd").new()
	attack_fan.name = "AttackFan"
	add_child(attack_fan)
	attack_fan.hit_moment.connect(_on_attack_hit_moment)


## 设置木桩类型实体: 当前简化为只挂 PlayerVisual(占位)
## 未来可换成专门的 StakeVisual(用木桩贴图,不挂 AnimatedSprite2D)
func _setup_stake(info: ClientEntityInfo) -> void:
	# 木桩目前复用 PlayerVisual 作为占位显示
	# 它会显示圆形角色贴图 + 名字标签 + 朝向箭头,虽然不完美但能跑通统一 Entity 模型
	# 后续替换为专门 StakeVisual 时只改本方法,不影响其他 entity_type 的逻辑
	var visual = preload("res://prefab/role/PlayerVisual.tscn").instantiate()
	visual.name = "PlayerVisual"
	add_child(visual)
	visual.setup(info)
	visual.set_entity_name("木桩")
	# AnimStateMachine(没有动画状态切换需求,简化)
	var anim_machine = preload("res://Script/statemachine/AnimState/AnimStateMachine.gd").new()
	anim_machine.name = "AnimStateMachine"
	add_child(anim_machine)
	anim_machine.setup(info)
	# 木桩不挂 LocalPlayerController(不被本地控制)
	# 如果未来木桩需要 hurt 动画,通过 entity_updated 信号里的 state 字段驱动即可
	# (StateMirror._on_attack_hit 会设 state="hurt" 并 emit entity_updated)

	# 血条
	var hp_bar = preload("res://prefab/role/ProgressBar.tscn").instantiate()
	hp_bar.name = "HpProgressBar"
	add_child(hp_bar)
	hp_bar.set_type("hp")
	hp_bar.set_auto_hide(false)
	hp_bar.position = Vector2(0, -39)

func _setup_enemy(info: ClientEntityInfo) -> void:
	_setup_player(info)
	var visual = get_node_or_null("PlayerVisual")
	if visual != null:
		visual.set_entity_name(info.enum_type_string())

	# 挂载视锥渲染组件(敌人专属:玩家可见的半透明扇形警戒范围,潜行玩法)
	# 和 PlayerVisual 一样脚本 new() + add_child。初始形态从 info.ai_state 带:
	#   - chase → chase 视野(窄而远)
	#   - 其余(patrol/look_around/attack) → normal 视野(宽而近)
	# 之后由 on_entity_updated 转发 AiStateChanged 增量消息实时切换。
	# 视锥开关 VISION_ENABLED=false 时不挂载:服务端敌人已无视视锥,显示扇形会误导。
	if ConfigLoader.is_vision_enabled():
		var vision_fan = preload("res://Script/role/VisionFan.gd").new()
		vision_fan.name = "VisionFan"
		add_child(vision_fan)
		vision_fan.setup(info.ai_state)
		vision_fan.set_facing(info.facing)
		vision_fan.z_index = 1  # 显示在角色/地形之上(半透明,不遮挡操作)

func on_hp_changed(cur_hp: int, damage: int, attacker_id: String, atk_id: int, atk_shape_idx: int) -> void:
	# damage为0时是初始化 不跳字
	var hp_bar = get_node_or_null("HpProgressBar")
	if hp_bar != null:
		hp_bar.set_value(cur_hp)
		hp_bar.set_percentage(cur_hp * 1.0 / entity_combat.max_hp)

func on_stats_updated(combat: ClientStateMirror.ClientCombatStats) -> void:
	if entity_combat == null:
		# 只有init的时候需要赋值一下 其他时候已经更新了combat了 直接处理其他逻辑
		entity_combat = combat

	# 显示之类的逻辑
	var hp_bar = get_node_or_null("HpProgressBar")
	if hp_bar != null:
		hp_bar.set_max(combat.max_hp)


## 收到 StateMirror 的 entity_updated 信号时调用,更新坐标、朝向、动画状态
func on_entity_updated(info: ClientEntityInfo) -> void:
	# 先记旧状态,再更新:攻击弧光只在「进入 attacking」瞬间触发一次
	# (attacking 期间后续广播 state 不变,不能每次广播都重触发)
	var was_attacking: bool = (_state == "attacking")
	_state = info.state  # 缓存动画状态(hurt 硬直判断用,见 _process / _update_position)
	_update_position(info)
	# 朝向更新:转发给 PlayerVisual(如果已挂载)
	# facing 是独立状态维度,和坐标分开更新,但走同一个 entity_updated 信号
	var visual = get_node_or_null("PlayerVisual")
	if visual != null:
		visual.update_facing(info.facing)
	# 视锥朝向 + AI 状态更新:转发给 VisionFan(如果已挂载,只有敌人有)
	# ai_state 由 StateMirror._on_ai_state_changed 增量更新(切换即广播),
	# 视锥形态(normal/chase)必须实时跟随,不能等低频快照
	var vision_fan = get_node_or_null("VisionFan")
	if vision_fan != null:
		vision_fan.set_facing(info.facing)
		vision_fan.set_ai_state(info.ai_state)
	# 攻击弧光:进入 attacking 瞬间按攻击配置渲染扇形范围(颜色按攻击者身份)
	if info.state == "attacking" and not was_attacking:
		_trigger_attack_fan(info)
	# 动画状态更新:转发给 AnimStateMachine(如果已挂载)
	# state 字段由 StateMirror 从 moving 推断(或 GameState 快照带),服务端权威
	# 木桩没挂 AnimStateMachine,跳过(木桩的 state 变化目前不影响显示)
	var anim_machine = get_node_or_null("AnimStateMachine")
	if anim_machine != null and info.state != "":
		anim_machine.update_state(info.state)


## 攻击弧光触发:atk_id/朝向来自服务端广播,颜色按攻击者身份
## 本人淡蓝白 / 队友绿 / 敌人红(敌人攻击也显示红色威胁弧光)
func _trigger_attack_fan(info: ClientEntityInfo) -> void:
	var attack_fan = get_node_or_null("AttackFan")
	if attack_fan == null or info.atk_id <= 0:
		return
	var identity: int = AttackFan.Identity.ENEMY
	if _is_local:
		identity = AttackFan.Identity.SELF
	elif info.entity_type == ClientEntityInfo.EntityType.PLAYER:
		identity = AttackFan.Identity.TEAM
	attack_fan.show_attack(info.atk_id, 0, info.facing, identity)
	# 本地玩家攻击:角色后坐(朝向反方向顿一下再回弹,纯视觉偏移)
	if _is_local:
		_recoil_offset = -Vector2.RIGHT.rotated(info.facing) * RECOIL_PX


## 攻击命中时刻(hit_time 判定帧)到达:本地玩家震屏(重击感,最廉价的"范围大"暗示)
## 只震本机,不震远程攻击者的屏幕
func _on_attack_hit_moment() -> void:
	if not _is_local:
		return
	var cam = get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		cam.shake()


## 每帧更新:
## - 本地玩家: 记录预测轨迹供软对账(位置由 LocalPlayerController 预测推进)
## - 远程/敌人: lerp 平滑 30Hz 跳变(远端滑一点是优点,视觉更顺)
func _process(delta: float) -> void:
	if not _position_initialized:
		return  # 首次位置还没设(setup 之前),跳过

	if _is_local:
		if _state == "hurt":
			# 硬直中:位置由服务端权威(击退等),本地不预测,lerp 跟随 target_pos
			# 预测是"我按自己的方向走",硬直中我被推走,不能自己推自己;
			# 软对账阈值(15px)也追不上单 tick 几像素的小步击退位移,直接 lerp 最稳
			position = position.lerp(target_pos, min(delta * LERP_FACTOR, 1.0))
		else:
			# 本地:位置由 LocalPlayerController 每帧预测推进(LocalPlayerController._process
			# 是子节点,本帧 Role 之后执行),这里只记录预测轨迹供收到广播时对账
			# 不做"限速追赶"——那是顿挫根源(追到位→停等→再追,广播抖动就走走停停)
			_record_prediction()
	else:
		# 远程:插值模式
		# 服务端 30Hz 给出 target_pos,客户端 60Hz lerp 向它平滑过渡
		# alpha = delta * LERP_FACTOR:60fps 时 ≈0.25,约 4 帧追上(66ms 延迟,视觉平滑)
		# min 截断到 1.0:防止低帧率时 delta 过大导致 alpha>1(overshoot)
		position = position.lerp(target_pos, min(delta * LERP_FACTOR, 1.0))

	# 攻击后坐:只偏移 PlayerVisual 子节点(纯视觉),Role.position(预测/权威)不动,
	# 不污染预测轨迹、不触发软对账;指数衰减回零(约 0.15s 内回弹完)
	var visual = get_node_or_null("PlayerVisual")
	if _recoil_offset.length() > 0.01:
		if visual != null:
			visual.position = _recoil_offset
		_recoil_offset = _recoil_offset.lerp(Vector2.ZERO, min(delta * RECOIL_DECAY, 1.0))
	elif visual != null and visual.position != Vector2.ZERO:
		visual.position = Vector2.ZERO


## 更新坐标:从 entity_updated 信号拿到服务端权威位置,更新 target_pos
## - 首次调用(初始化):直接 snap position = target_pos(避免从原点飞过去)
## - 后续:只更新 target_pos,position 由 _process 对齐(本地 snap / 远程 lerp)
func _update_position(info: ClientEntityInfo) -> void:
	target_pos = Vector2(info.x, info.y)
	if not _position_initialized:
		# 首次定位:直接 snap(不插值,避免新 Role 从 (0,0) lerp 到目标点)
		position = target_pos
		_position_initialized = true
	elif _is_local and _state != "hurt":
		# 本地玩家且不在硬直中:软对账——回溯 RTT 前的预测位置与服务端权威位置比较,
		# 误差小则忽略(正常移动信任本地预测,不回正→不拉扯),
		# 误差大才平滑回正(服务端因碰撞/锁定没推进,预测跑偏了)
		_reconcile_prediction()
	# 硬直中(hurt):只设 target_pos,由 _process lerp 跟随服务端位置(不软对账)
	# 远程:只设 target_pos,由 _process lerp 插值趋近


## 记录当前预测位置到轨迹历史(本地玩家每帧调用)
## 条目: [time_ms, x, y](扁平数组,避免每帧分配 Vector2 对象)
## 只在本地玩家调用;远程实体不需要预测轨迹(lerp 就行)
func _record_prediction() -> void:
	var now: int = Time.get_ticks_msec()
	_pred_history.append([now, position.x, position.y])
	# 裁剪窗口外的旧条目(按时间,窗口内通常 <100 条,单次遍历够快)
	while _pred_history.size() > 0 and now - int(_pred_history[0][0]) > PRED_HISTORY_WINDOW_MS:
		_pred_history.pop_front()
	if _pred_history.size() > PRED_HISTORY_MAX_ENTRIES:
		_pred_history.pop_front()


## 软对账:收到服务端广播时,回溯对应时刻的预测位置,与服务端权威位置比较
## 误差 <= 阈值:预测正确,忽略(不回正——回正就是"拉扯")
## 误差 > 阈值:真脱节(服务端因碰撞/attacking 锁定没推进,预测跑偏),
##   用 lerp 平滑回正(不是硬 snap,避免视觉瞬移),并清空轨迹
##   (必须清空:回正后旧错误轨迹会继续误判脱节,见项目 memory 记录)
##
## 变向宽限:方向刚变过(含急停)时,服务端要等「输入排队 ≤1 tick + tick 处理 +
##   半程 RTT 回传」才按新方向推进,这期间广播的仍是旧方向轨迹,
##   此刻回正会把玩家"折回"旧方向 → 宽限窗口内跳过回正(轨迹照常记录,
##   避免窗口结束后轨迹空洞)。窗口外恢复正常对账:真脱节仅延迟一个窗口仍会被回正。
func _reconcile_prediction() -> void:
	if _pred_history.is_empty():
		return  # 无轨迹可回溯(刚开始/刚回正清空),跳过——首次靠 snap,之后靠预测
	var now: int = Time.get_ticks_msec()
	# 变向宽限判断(只有本地玩家挂了 LocalPlayerController 才会走到这里)
	var controller = get_node_or_null("LocalPlayerController")
	if controller != null:
		var grace_ms: float = WebScoketMgr.get_rtt_ms() \
			+ SERVER_TICK_MS * DIR_CHANGE_GRACE_TICKS + DIR_CHANGE_GRACE_MARGIN_MS
		if now - controller.get_last_dir_change_ms() < grace_ms:
			return  # 宽限窗口内:跳过回正,继续信任本地预测
	# 回溯时刻:服务端推进比客户端预测晚起步「RTT(输入上行+广播下行)+ 平均半个 tick
	# (输入在 pending 里排队等 tick)」,所以要回溯相同跨度,对比的才是同一运动时刻
	var lookup_time: float = float(now) - WebScoketMgr.get_rtt_ms() - SERVER_TICK_MS * 0.5
	var predicted: Vector2 = _lookup_prediction_at(lookup_time)
	if predicted.distance_to(target_pos) > RECONCILE_THRESHOLD:
		# 真脱节:平滑回正(不用硬 snap,避免视觉瞬移)
		position = position.lerp(target_pos, RECONCILE_LERP)
		_pred_history.clear()


## 在预测轨迹历史中回溯某时刻的预测位置
## 找到相邻两条记录线性插值;目标时刻在窗口外则返回边界记录位置(退化)
func _lookup_prediction_at(t: float) -> Vector2:
	if _pred_history.is_empty():
		return position  # 退化:无历史,返回当前
	var first: Array = _pred_history[0]
	if t <= float(first[0]):
		return Vector2(first[1], first[2])  # 早于最旧记录
	var last: Array = _pred_history[_pred_history.size() - 1]
	if t >= float(last[0]):
		return Vector2(last[1], last[2])  # 晚于最新记录
	# 线性扫描找区间并插值(窗口内 <100 条,线性足够)
	for i in range(1, _pred_history.size()):
		var prev: Array = _pred_history[i - 1]
		var cur: Array = _pred_history[i]
		if t <= float(cur[0]):
			var span: float = float(cur[0]) - float(prev[0])
			var f: float = (t - float(prev[0])) / span if span > 0.0 else 0.0
			return Vector2(lerpf(prev[1], cur[1], f), lerpf(prev[2], cur[2], f))
	return Vector2(last[1], last[2])


## 移除指定名称的组件(如果存在)
func _remove_component(component_name: String) -> void:
	var node = get_node_or_null(component_name)
	if node != null:
		node.queue_free()
