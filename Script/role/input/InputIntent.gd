extends RefCounted
class_name InputIntent

"""
文件: client/Script/role/input/InputIntent.gd
作用: 输入意图数据结构——输入端和接收端之间的「唯一接口」

============================================================================
 核心设计:意图层解耦
============================================================================
InputIntent 只描述「玩家想做什么」,不描述「按了什么键/用什么设备」。
    - 输入端(KeyboardMouseDevice/GamepadDevice)把物理输入归一化成意图
    - 接收端(LocalPlayerController)只读意图,不知道也不关心输入来自哪

这样:
    - 换输入设备(键鼠→手柄)只改输入端,接收端一行不动
    - 改键位只改 InputBinding,接收端无感知
    - 接收端逻辑稳定,不被输入层变更影响

============================================================================
 为什么用 Vector2 而非 Vector3
============================================================================
当前是 2D 项目,所有 Godot API(Camera2D/Role.position/proto 的 x/y)都是 Vector2。
转 3D 时再升级类型即可——解耦的价值在于「输入设备和接收端互不感知」,
不在于「未来不用改类型」。详见设计讨论。
"""

# 移动方向(归一化向量),零向量=不动
# 由键盘 WASD/方向键 或 手柄左摇杆 归一化得到
var move_dir: Vector2 = Vector2.ZERO

# 朝向目标点(世界坐标)
# 由鼠标位置 或 手柄右摇杆 转成世界坐标得到
var look_target: Vector2 = Vector2.ZERO


## 重置所有意图字段(每帧采集前调用)
func reset() -> void:
	move_dir = Vector2.ZERO
	look_target = Vector2.ZERO
