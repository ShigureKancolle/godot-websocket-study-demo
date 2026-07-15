extends Node
class_name _InputIntentProvider

"""
文件: client/Script/role/input/InputIntentProvider.gd
作用: 输入意图 Provider——接收端的唯一依赖(autoload 全局单例)

============================================================================
 核心设计
============================================================================
InputIntentProvider 是「输入端」和「接收端」之间的桥:
    - 输入端:各 InputDevice 子类(KeyboardMouseDevice/GamepadDevice...)
    - 接收端:LocalPlayerController(只调 InputIntentProvider.get_intent())

Provider 负责每帧合并所有 device 的输出,缓存最终 intent。
    接收端只调 get_intent() 拿到合并后的意图,完全不接触任何 device。

============================================================================
 为什么用 autoload
============================================================================
和 WebSocketMgr 同理(需要 _process 轮询的用 Node + autoload):
    - 全局只有一个 Provider,所有 LocalPlayerController 共享
    - 符合「接收端只有一份代码」的目标
    - 多本地玩家场景极少(除非做分屏),当前不考虑

============================================================================
 合并策略
============================================================================
每帧 _process:
    1. reset intent
    2. 遍历所有 device,调 poll(intent)
       多个 device 往同一个 intent 对象写各自负责的字段
       后注册的 device 可覆盖先注册的(如手柄覆盖键鼠)
    3. 缓存最终 intent,等接收端来取

接收端调 get_intent() 返回缓存值,不触发采集——
    采集是 Provider 自己在 _process 做的,接收端只读。
"""

# 当前缓存的意图(接收端通过 get_intent 读)
var _intent: InputIntent = null

# 已注册的输入设备列表(按注册顺序 poll,后注册的覆盖先注册的)
var _devices: Array[InputDevice] = []


func _ready() -> void:
	# 默认注册一个 KeyboardMouseDevice
	# 未来要加手柄时,在 _ready 里再加 GamepadDevice 即可
	var kb_mouse := KeyboardMouseDevice.new()
	add_device(kb_mouse)


func _process(_delta: float) -> void:
	# 每帧重新采集
	if _devices.is_empty():
		return

	_intent = InputIntent.new()
	for device in _devices:
		device.poll(_intent)


## 注册一个输入设备(添加到 _devices 并 add_child)
## 后注册的 device 在 poll 时排在后面,可以覆盖先注册的输出
func add_device(device: InputDevice) -> void:
	_devices.append(device)
	add_child(device)


## 获取当前输入意图(接收端唯一入口)
## 返回缓存的 intent,不触发采集——采集在 _process 里自动做
## 返回 null 的情况:还没跑过 _process(_ready 之前调用)
func get_intent() -> InputIntent:
	return _intent
