extends Node
class_name LocalPlayerController

"""
文件: client/Script/role/LocalPlayerController.gd
作用: 本地玩家控制组件——读 InputIntentProvider 意图,发 PlayerMove + PlayerFacing

============================================================================
 设计思路(输入端/接收端解耦)
============================================================================
这是「接收端」——只读 InputIntentProvider.get_intent() 拿到归一化后的意图,
    完全不知道输入来自键鼠还是手柄、按了什么键、键位怎么配的。

输入端(InputBinding/KeyboardMouseDevice/InputIntentProvider)负责把物理输入
    归一化成 InputIntent(move_dir + look_target)。
    接收端只消费这个意图,输入端变更(换设备/改键位)对接收端透明。

============================================================================
 这是「服务器权威」在客户端最微妙的地方
============================================================================
本地玩家想移动/转朝向,流程:
    1. 这里读 intent,拿到方向向量
    2. 发 PlayerMove(dir_x/dir_y) / PlayerFacing 给服务端(这是「请求」,不是「声明」)
    3. 服务端 apply_move_dir 只记方向,tick_movement 每 tick 推进权威状态,广播给所有人
    4. 客户端 StateMirror 收到 → entity_updated 信号 → Role.on_entity_updated
       → 更新 target_pos,本地玩家做「软对账」(回溯预测轨迹,误差大才平滑回正)
    5. 本地玩家位置由本组件预测推进(第 2 步发完方向后),远程实体由 Role._process lerp 平滑

和旧模型的区别:
    旧:客户端发目标坐标 → 服务端直接落地 → 广播 → 客户端 set position
        问题:客户端 60Hz 发,服务端 30Hz 节流丢半,真实速度腰斩,每 tick 被拉回
    新:客户端发方向 → 服务端按方向推进 → 广播 → 客户端「预测 + 软对账」
        本地玩家用自己的方向自推进(预测),服务端坐标只做校验(软对账),
        预测与服务端打架时由 Role 平滑回正,而不是硬拉回(详见 Role._reconcile_prediction)

============================================================================
 朝向和移动是两个独立状态维度
============================================================================
玩家可以一边移动(WASD 决定方向)一边朝任意方向攻击(鼠标决定朝向)。
    所以 PlayerMove 和 PlayerFacing 是两条独立的消息流,各自发各自的。
    服务端 apply_move_dir 只记移动方向,apply_facing 只改 facing,互不干扰。

============================================================================
 移动模型:方向向量 + 本地预测(服务端权威 + 软对账)
============================================================================
客户端只发方向向量(dir_x/dir_y),不发目标坐标:
    - 客户端 60Hz 读 Input.get_vector 拿归一化方向 → 发 PlayerMove{dir_x, dir_y}
    - 发完立即本地预测:position += dir * speed * delta(不等服务端回传)
    - 服务端 30Hz tick 按 dir * speed * TICK_INTERVAL 推进权威位置并广播
    - Role 收到广播做「软对账」:回溯 RTT 前的预测位置比较,误差小忽略 / 大则平滑回正

为什么本地预测是安全的:
    两端用同一个 speed(entity_config.json),方向都是客户端发的,
    位移速度一致,正常移动预测与服务端推进误差很小。只有服务端拒绝移动
    (碰撞/attacking 锁定)时误差才超阈值,由 Role 软对账平滑回正。
    相比「纯追赶」(追到位→停等→广播抖动顿挫)和「方向×RTT 外推」(外推过头),
    轨迹历史回溯对账对 RTT 精度不敏感,是消除拉扯的正确做法。
"""

# 上次发送朝向时的 facing 弧度,用于判断是否变化(避免无变化时高频发消息)
var _last_facing: float = 0.0

# 上次是否有有效 look_target(用于区分"初始状态"和"鼠标没动")
var _has_last_look: bool = false

# facing 变化阈值(弧度):小于这个值不发包,避免浮点抖动导致的高频发包
const FACING_EPSILON: float = 0.01

# 上一帧是否在移动(用于检测"刚停止"的瞬间,发一次 moving=false 让服务端切 idle)
# 不加这个的话:玩家松开键盘后不再发 PlayerMove,服务端 state 永远停在 "run"
var _was_moving: bool = false

# 本地预测速度(像素/秒),setup 时从 ConfigLoader 读
# 必须和服务端 speed 一致(同一 shared_config/entity_config.json 同步),
# 否则预测位移对不上服务端推进 → 对账误判脱节 → 回正抖动
var _speed: float = 0.0

# 实体圆形碰撞半径(像素),setup 时从 ConfigLoader 读
# 用于算「脚点」(圆底部)做预测阻挡判定,和服务端 _is_blocked 用同一个点
# 阻挡判定点 = 圆心 (x, y + _radius),脚点所在 tile 不可通行 → 不推进该轴
var _radius: float = 0.0

# InfiniteTileMap 引用缓存(预测阻挡查询用)
# 懒查找 + 缓存:首次需要查阻挡时从场景树找一次,之后复用
# 为什么不 setup 时取:setup 在 Role 创建早期调,此时可能还没挂到场景树,
# get_tree() 返回 null;懒查找避免时序依赖
var _tile_map_cache: InfiniteTileMap = null
var _tile_map_looked_up: bool = false  # 是否已尝试查找(区分"没找过"和"找过但null")

# 上一帧的移动方向(用于检测变向;零向量表示静止)
var _last_move_dir: Vector2 = Vector2.ZERO

# 最近一次移动方向突变(含 moving→stop)的时刻(Time.get_ticks_msec())
# Role 软对账用它做变向宽限:服务端要等一个 tick + 半程 RTT 才按新方向推进,
# 这期间广播的仍是旧方向轨迹,回正会把玩家"折回"旧方向 → 宽限窗口内跳过回正
var _last_dir_change_ms: int = 0

# 方向变化判定阈值(点积):上一帧方向与当前方向点积低于它视为"变向"
# 0.5 ≈ 夹角 > 60° 才算变向(小角度修正不算,避免高频误触发宽限)
const DIR_CHANGE_DOT_THRESHOLD: float = 0.5


## 初始化: 接收玩家信息
## 取移动速度用于本地预测推进(speed 是类型属性,本地查表,不进网络消息)
func setup(_info: ClientEntityInfo) -> void:
	_speed = ConfigLoader.get_speed("player")
	# 取圆形碰撞半径,用于算「脚点」做预测阻挡判定
	# 必须和服务端一致(同一份 entity_config.json),否则预测会和服务端阻挡判定错位
	var cap: ConfigLoader.EntityCapability = ConfigLoader.get_capability("player")
	if cap.body_shape == ConfigLoader.ShapeType_CIRCLE and cap.body_params is ConfigLoader.CircleParams:
		_radius = cap.body_params.radius


## 懒查找 InfiniteTileMap 节点(预测阻挡查询用)
## 场景树结构:GameScene → InfiniteTileMap / EntityLayer / Role → LocalPlayerController
## Role 在 EntityLayer 下,InfiniteTileMap 是 Role 的叔伯节点。
## 用 find_child 从根节点找,找不到返回 null(调用方兜底不挡)。
## 查找结果缓存:正常场景下一旦找到就稳定,不会反复 null
func _get_tile_map() -> InfiniteTileMap:
	if _tile_map_looked_up:
		return _tile_map_cache
	_tile_map_looked_up = true
	var tree := get_tree()
	if tree == null:
		return null  # 还没挂到场景树
	var root := tree.current_scene
	if root == null:
		return null
	# find_child 在整棵子树递归找第一个匹配节点名
	# 用 InfiniteTileMap 的 class_name 做类型断言,确保返回的是正确类型
	var node := root.find_child("InfiniteTileMap", true, false)
	if node is InfiniteTileMap:
		_tile_map_cache = node
	return _tile_map_cache


## 最近一次移动方向突变(含 moving→stop)的时刻(ms),供 Role 软对账做变向宽限
func get_last_dir_change_ms() -> int:
	return _last_dir_change_ms


## 检测移动方向突变并记录时刻(每帧调用一次)
## 判定:移动中方向夹角 > 60°(点积 < 阈值),或从移动→停止
## 静止→移动不算变向(从静止起步没有旧轨迹可折回,服务端也从同一位置推进)
func _track_dir_change(move_dir: Vector2) -> void:
	if move_dir != Vector2.ZERO and _last_move_dir != Vector2.ZERO:
		# 双移动帧:比较方向夹角(move_dir 已归一化,dot 直接是夹角余弦)
		if _last_move_dir.dot(move_dir) < DIR_CHANGE_DOT_THRESHOLD:
			_last_dir_change_ms = Time.get_ticks_msec()
	elif move_dir == Vector2.ZERO and _last_move_dir != Vector2.ZERO:
		# 移动→停止:服务端在收到 moving=false 前会按旧方向多推进一段 → 折回风险
		_last_dir_change_ms = Time.get_ticks_msec()
	_last_move_dir = move_dir


func _process(delta: float) -> void:
	# 从 InputIntentProvider 获取归一化意图
	# 这是接收端和输入端的唯一接口——输入端变更对接收端透明
	var intent: InputIntent = InputIntentProvider.get_intent()
	if intent == null:
		return  # Provider 还没初始化(第一帧前),跳过

	# 攻击(从 intent.attack_pressed 发 AttackStart)
	# 用 local_entity_id() / get_entity() 替代旧的 local_player_id() / get_player()
	# (统一 Entity 模型重构后,API 名字和服务端对齐)
	# get_entity 返回 ClientEntityInfo 强类型,字段访问用 .state 而非 ["state"]
	var mirror = ClientStateMirror.instance()
	var player: ClientEntityInfo = mirror.get_entity(mirror.local_entity_id())
	if player == null:
		return  # 镜像还没拿到本地玩家信息(PlayerJoin 未到),跳过
	var my_state: String = player.state
	# 输入锁定状态:attacking/hurt/dead 期间禁止移动/朝向/攻击
	# 和服务端 _INPUT_LOCKED_STATES 对齐。hurt 期间不锁会导致:
	#   客户端持续发 PlayerMove + 本地预测推进位置,但服务端 apply_move_dir 拒绝(hurt 锁),
	#   服务端位置不动 → 广播旧位置 → 客户端软对账 lerp 拉回 → "被打一次拉回一点"
	if my_state == "attacking" or my_state == "hurt" or my_state == "dead":
		return

	if intent.attack_pressed:
		print("attack pressed, send AttackStart")
		# 发送字段名用 entity_id(和 proto 一致,原 role_id 已废弃)
		# 注:服务端 handler 实际用 ctx.player_id 而非读 client 发的 entity_id,
		# 但为了契约一致性,客户端仍然填上 entity_id 字段
		MessageBus.instance().send("game.AttackStart", {
			"entity_id": mirror.local_entity_id(),
			"atk_id": 1001
		})

		# 预判玩家状态为攻击中,不发移动和朝向消息
		# 用 "attacking" 和服务端对齐(避免等 AttackStart 广播回来才切状态造成的延迟感)
		# 注意:这里直接改 mirror 里的 ClientEntityInfo(强类型对象的字段),
		# 不是改 dict——StateMirror 的 _on_attack_start 也会改,但本地预判先改避免延迟感
		player.state = "attacking"
		return


	# 1. 移动(发方向向量 + 本地预测)
	# 服务端权威移动:
	#   - 客户端只发方向向量 dir_x/dir_y,不发目标坐标
	#   - 服务端按 dir * speed * 实测 tick dt 推进权威位置并广播
	#   - 发完立即本地预测推进(下方 position += dir * speed * delta),
	#     服务端坐标只做软对账(Role._reconcile_prediction)
	#
	# moving 状态机:
	#   - 正在移动(move_dir 非零):每帧发 moving=true + 方向,服务端设 state="run"
	#   - 刚停止(上一帧在动,这帧不动):发一次 moving=false,服务端设 state="idle"
	#   - 持续静止:不发(避免无意义发包)
	var role_pos: Vector2 = get_parent().position  # Role 的位置(用于朝向计算)
	var moving: bool = intent.move_dir != Vector2.ZERO
	_track_dir_change(intent.move_dir)  # 记录变向时刻(Role 软对账宽限用)
	if moving:
		# 发方向向量(Input.get_vector 已归一化)
		MessageBus.instance().send("game.PlayerMove", {
			"dir_x": intent.move_dir.x,
			"dir_y": intent.move_dir.y,
			"moving": true
		})
		# 本地预测:发完方向立即按 dir * speed * delta 推进自己,不等服务端回传
		# 消除"追-停"顿挫和 RTT 输入滞后;服务端坐标只做软对账(Role._reconcile_prediction)
		#
		# 地形阻挡(脚点判定):和服务端 _is_blocked 用同一个判定点
		#   - 脚点 = 圆心 (x, y + _radius),圆的最低点
		#   - 脚点所在 tile 不可通行 → 该轴不推进
		#   - 分轴尝试(先 X 后 Y):某轴被挡只推另一轴 → 贴墙滑行
		#   - 两轴都被挡(正面撞墙)→ 不推进,等下一帧玩家改方向
		# 预测和服务端用同一判定点 + 同一份 terrain_config,正常情况下两端
		# 阻挡结果一致,不会出现"客户端推进了服务端又拉回"的抖动
		var role_node: Node2D = get_parent()
		var step: Vector2 = intent.move_dir * _speed * delta
		var tile_map: InfiniteTileMap = _get_tile_map()
		if tile_map == null:
			# InfiniteTileMap 还没找到(场景未初始化完)→ 不挡,直接推进
			# 这种情况只在首帧边界场景出现,正常游戏不会发生
			role_node.position += step
		else:
			# 分轴尝试:先 X 后 Y。用脚点 (x, y + _radius) 查阻挡
			var foot_y: float = role_node.position.y + _radius
			if tile_map.is_walkable_at(role_node.position.x + step.x, foot_y):
				role_node.position.x += step.x
			if tile_map.is_walkable_at(role_node.position.x, role_node.position.y + step.y + _radius):
				role_node.position.y += step.y
	elif _was_moving:
		# 刚从移动切到静止:发一次 moving=false,让服务端把 state 从 "run" 切回 "idle"
		MessageBus.instance().send("game.PlayerMove", {
			"dir_x": 0.0,
			"dir_y": 0.0,
			"moving": false
		})
	_was_moving = moving

	# 2. 朝向(从 intent.look_target 算 facing)
	# 节流必须基于 facing 本身,而不是 look_target!
	#   因为 facing = (look_target - role_pos).angle()
	#   鼠标不动(look_target 不变)但人物在移动(role_pos 变了)时,facing 实际已经变了。
	#   如果只看 look_target 是否变化来节流,就会漏发——表现为「鼠标不动人物动时朝向不更新」。
	# 正确做法:每帧算出当前 facing,只有 facing 变化超过阈值才发包。
	if intent.look_target != Vector2.ZERO or _has_last_look:		
		var dir: Vector2 = intent.look_target - role_pos
		# Vector2.angle() 返回弧度,0=右,逆时针正——和 facing 语义完全一致
		var facing: float = dir.angle()
		# 首次发包 或 facing 变化超过阈值时才发(避免静止/微小抖动时高频发包)
		if not _has_last_look or abs(facing - _last_facing) > FACING_EPSILON:
			MessageBus.instance().send("game.PlayerFacing", {
				"facing": facing
			})
			_last_facing = facing
			_has_last_look = true
