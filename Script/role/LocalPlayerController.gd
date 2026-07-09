extends Node
class_name LocalPlayerController

"""
文件: client/Script/role/LocalPlayerController.gd
作用: 本地玩家控制组件——读键盘输入，发 PlayerMove 消息

============================================================================
 这是「服务器权威」在客户端最微妙的地方
============================================================================
本地玩家想移动，流程是:
    1. 这里读键盘，算出「想移动到哪个坐标」
    2. 发 PlayerMove 消息给服务端（这是「请求」，不是「声明」）
    3. 服务端 apply_move 更新权威状态，广播 PlayerMove 给所有人（含自己）
    4. 客户端 StateMirror 收到 PlayerMove → player_updated 信号 → Role.on_player_updated → 更新坐标

注意第4步: 本地玩家的坐标也是由 StateMirror 信号更新的，不是这里直接改的。
    这保证了「本地玩家看到的自己」和「服务端认为的本地玩家」永远一致。
    如果这里直接改 Role.position，就会和服务端状态脱节——
    虽然看着像是「延迟更低」，但一旦脱节就很难对账。

============================================================================
 当前是「点击移动」而非「键盘移动」——为什么
============================================================================
简化起见，这里先实现「点击移动」: 鼠标左键点击屏幕，发 PlayerMove 到点击位置。
    - 键盘连续移动要处理「按住时持续发移动消息 + 速度积分」，复杂度高
    - 点击移动是「瞬时目标坐标」，和当前 proto 的 PlayerMove (target x/y) 模型最贴合
    - 后续做键盘移动时，只需在这里改输入读取逻辑，Role 和服务端都不用动

这也是「状态逻辑收口到服务端」的回报:
    不管这里用什么输入方式（点击/键盘/手柄），服务端 apply_move 都不变。
"""

# 移动速度（发消息时带的 speed 字段，当前服务端未使用，但按 proto 要求发）
# 未来服务端做连续移动模型时会用到
const MOVE_SPEED: float = 100.0


func _input(event: InputEvent) -> void:
	# 只处理鼠标左键按下
	if not event is InputEventMouseButton:
		return
	var mouse_event: InputEventMouseButton = event
	if mouse_event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not mouse_event.pressed:
		return  # 只在按下时触发，松开不处理

	# 算出点击位置: 鼠标的全局坐标 → 相对父节点（Role）的本地坐标
	# 因为 Role 是 Node2D，它的 position 就是世界坐标，所以要把鼠标坐标转成全局坐标
	# get_global_mouse_position 返回 viewport 坐标，需要考虑场景的 transform
	# 简化: 直接用鼠标在 viewport 的坐标作为目标坐标（假设场景没有缩放/偏移）
	var target_pos: Vector2 = get_viewport().get_mouse_position()

	# 发 PlayerMove 消息
	# 这里不直接改 Role.position——等 StateMirror 收到服务端广播后再改
	# 这就是「服务器权威」: 本地玩家发的是「请求」，等服务端确认后才移动
	MessageBus.instance().send("game.PlayerMove", {
		"x": target_pos.x,
		"y": target_pos.y,
		"speed": MOVE_SPEED
	})
