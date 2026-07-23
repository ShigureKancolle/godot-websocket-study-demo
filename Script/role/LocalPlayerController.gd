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
    1. 这里读 intent,算出「想移动到哪个坐标」「想朝哪个方向」
    2. 发 PlayerMove / PlayerFacing 消息给服务端(这是「请求」,不是「声明」)
    3. 服务端 apply_move / apply_facing 更新权威状态,广播给所有人(含自己)
    4. 客户端 StateMirror 收到 → player_updated 信号 → Role.on_player_updated
       → 更新坐标 + 转发 facing 给 PlayerVisual

注意第4步:本地玩家的坐标和朝向也是由 StateMirror 信号更新的,不是这里直接改的。
    这保证了「本地玩家看到的自己」和「服务端认为的本地玩家」永远一致。
    如果这里直接改 Role.position 或箭头 rotation,就会和服务端状态脱节。

============================================================================
 朝向和移动是两个独立状态维度
============================================================================
玩家可以一边移动(WASD 决定方向)一边朝任意方向攻击(鼠标决定朝向)。
    所以 PlayerMove 和 PlayerFacing 是两条独立的消息流,各自发各自的。
    服务端 apply_move 只改 x/y,apply_facing 只改 facing,互不干扰。

============================================================================
 移动模型:方向移动 → target 坐标
============================================================================
当前 proto 的 PlayerMove 是「目标坐标」(target x/y),不是「方向」。
    键盘方向移动要转换:target = 当前位置 + move_dir * 固定步长。
    每帧发一次(或间隔发),服务端收到后直接落地目标坐标(简化模型)。

未来做连续移动模型时,服务端按 tick 推进 new_pos = old_pos + velocity * dt,
    那时 proto 可以加 direction 字段,但当前保持 target 模型不变。
"""

# 移动步长(每帧发一次 target = 当前位置 + move_dir * MOVE_STEP)
# 当前服务端是「直接落地目标坐标」模型,所以步长就是实际移动距离
# 第3步做 tick 限速后会改成「服务端按速度积分」,这里发的是方向+速度
const MOVE_STEP: float = 5.0

# 移动速度(proto 的 speed 字段,当前服务端未使用,但按 proto 要求发)
const MOVE_SPEED: float = 100.0

# 上次发送朝向时的 facing 弧度,用于判断是否变化(避免无变化时高频发消息)
var _last_facing: float = 0.0

# 上次是否有有效 look_target(用于区分"初始状态"和"鼠标没动")
var _has_last_look: bool = false

# facing 变化阈值(弧度):小于这个值不发包,避免浮点抖动导致的高频发包
const FACING_EPSILON: float = 0.01

# 上一帧是否在移动(用于检测"刚停止"的瞬间,发一次 moving=false 让服务端切 idle)
# 不加这个的话:玩家松开键盘后不再发 PlayerMove,服务端 state 永远停在 "run"
var _was_moving: bool = false


## 初始化: 接收玩家信息(当前未使用,但保留接口和 PlayerVisual.setup 对称)
## 后续如需根据玩家信息调整控制参数(如不同角色移速不同),在这里实现
func setup(_info: Dictionary) -> void:
	pass


func _process(_delta: float) -> void:
	# 从 InputIntentProvider 获取归一化意图
	# 这是接收端和输入端的唯一接口——输入端变更对接收端透明
	var intent: InputIntent = InputIntentProvider.get_intent()
	if intent == null:
		return  # Provider 还没初始化(第一帧前),跳过

	# 1. 移动(从 intent.move_dir 算 target)
	# moving 状态机:
	#   - 正在移动(move_dir 非零):每帧发 moving=true,服务端设 state="run"
	#   - 刚停止(上一帧在动,这帧不动):发一次 moving=false,服务端设 state="idle"
	#   - 持续静止:不发(避免无意义发包)
	# 这样停止时只发一次停止信号,不会高频发包
	var role_pos: Vector2 = get_parent().position  # Role 的位置
	var moving: bool = intent.move_dir != Vector2.ZERO
	if moving:
		var target: Vector2 = role_pos + intent.move_dir * MOVE_STEP
		MessageBus.instance().send("game.PlayerMove", {
			"x": target.x,
			"y": target.y,
			"speed": MOVE_SPEED,
			"moving": true
		})
	elif _was_moving:
		# 刚从移动切到静止:发一次 moving=false,让服务端把 state 从 "run" 切回 "idle"
		# target 就是当前位置(不动)
		MessageBus.instance().send("game.PlayerMove", {
			"x": role_pos.x,
			"y": role_pos.y,
			"speed": MOVE_SPEED,
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
