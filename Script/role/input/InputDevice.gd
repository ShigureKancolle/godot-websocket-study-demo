extends Node
class_name InputDevice

"""
文件: client/Script/role/input/InputDevice.gd
作用: 输入设备采集器抽象基类

============================================================================
 设计思路
============================================================================
定义所有输入设备的统一接口:poll(intent)。
    - KeyboardMouseDevice 读键鼠,转成意图
    - 未来 GamepadDevice 读手柄,转成意图
    - 未来其它设备同理

InputIntentProvider 在 _process 里遍历所有已注册的 device,调它们的 poll,
    把多个设备的输出合并进同一个 intent。
    这样新增设备只要写一个 InputDevice 子类,Provider 和接收端都不用改。

============================================================================
 为什么是 Node 而非 RefCounted
============================================================================
需要被 add_child 到 InputIntentProvider 上(进场景树),才能用 get_viewport() 等
    Node 方法获取鼠标/相机信息。RefCounted 不在场景树里,拿不到这些。

============================================================================
 为什么 poll 接收 intent 参数而非返回 intent
============================================================================
让多个 device 共享同一个 intent 对象,各自往里写自己负责的字段。
    这样:
    - KeyboardMouseDevice 写 move_dir(键盘) 和 look_target(鼠标)
    - 未来 GamepadDevice 可以覆盖(后注册的覆盖先注册的)
    - Provider 最后把合并好的 intent 暴露给接收端

如果每个 device 返回自己的 intent,Provider 还要负责合并,逻辑复杂。
    共享对象写入是最简单的合并方式。
"""


## 每帧采集输入,写入 intent 的对应字段
## 由 InputIntentProvider._process 调用
## 子类必须实现此方法
## 注意:不要在这里 reset intent——Provider 在调用 poll 前会先 reset
func poll(_intent: InputIntent) -> void:
	# 基类空实现,子类覆盖
	pass
