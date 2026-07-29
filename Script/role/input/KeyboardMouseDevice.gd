extends InputDevice
class_name KeyboardMouseDevice

"""
文件: client/Script/role/input/KeyboardMouseDevice.gd
作用: 键鼠输入设备——读键盘+鼠标,转成 InputIntent

============================================================================
 职责
============================================================================
1. 读键盘:按 InputBinding 查 move_up/down/left/right 哪些键被按下,
   累加成 move_dir(多键同时按→向量相加→归一化)
2. 读鼠标:取鼠标世界坐标,写进 look_target

============================================================================
 为什么不直接用 Godot InputMap
============================================================================
项目要求支持自定义键位,且不依赖 Godot InputMap(避免绕过意图层抽象)。
    自己管 InputBinding 映射表,完全控制改键+持久化逻辑。
    详见 InputBinding.gd 的设计说明。

============================================================================
 鼠标世界坐标怎么获取
============================================================================
用 get_viewport().get_camera_2d() 拿当前活跃的 Camera2D,
    再调 camera.get_global_mouse_position() 转成世界坐标。
    如果当前没有 Camera2D(如在主菜单场景),look_target 保持零向量,
    接收端会忽略它(只在有有效 look_target 时才发朝向消息)。
"""

# 内部缓存:避免每帧重复查 InputBinding
# 注意:InputBinding 是 static,改键后下次 poll 自动生效(因为 is_action_pressed 每帧重查)
var _intent := InputIntent.new()

## 每帧采集键鼠输入,写入 intent
## 由 InputIntentProvider._process 调用
func poll(intent: InputIntent) -> void:
	# 1. 读键盘 → move_dir
	# 多键同时按时向量相加,最后归一化(避免斜走快 1.414 倍)
	var dir := Vector2.ZERO
	if InputBinding.is_action_pressed("move_up"):
		dir.y -= 1   # 上 = y 负方向(Godot 屏幕 y 向下为正)
	if InputBinding.is_action_pressed("move_down"):
		dir.y += 1
	if InputBinding.is_action_pressed("move_left"):
		dir.x -= 1
	if InputBinding.is_action_pressed("move_right"):
		dir.x += 1

	# 归一化(只有对角线移动时才改变向量长度,水平/垂直移动不受影响)
	if dir != Vector2.ZERO:
		dir = dir.normalized()
	intent.move_dir = dir

	# 2. 读鼠标 → look_target(世界坐标)
	# 用当前活跃的 Camera2D 把鼠标屏幕坐标转世界坐标
	# 没有相机时 look_target 保持零向量,接收端会忽略
	var camera := get_viewport().get_camera_2d()
	if camera != null:
		intent.look_target = camera.get_global_mouse_position()

	# 3. 读攻击键 → attack_pressed
	if InputBinding.is_action_pressed("attack"):
		print("attack pressed")
		intent.attack_pressed = true
		
