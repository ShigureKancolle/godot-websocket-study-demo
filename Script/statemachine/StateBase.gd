extends RefCounted
class_name StateBase

"""
文件: client/Script/statemachine/StateBase.gd
作用: 状态基类——所有具体状态(Idle/Run/Attack/...)的父类

============================================================================
 设计说明
============================================================================
用 RefCounted 而非 Node:
    - 状态是纯逻辑对象(进入/退出/每帧更新),不需要进场景树
    - 不需要 _ready/_process 等 Node 生命周期(由 StateMachineBase 统一驱动)
    - RefCounted 更轻量,状态切换时旧状态自动释放(引用计数归零)

状态和状态机的关系:
    - 状态持有 machine 引用(状态机 add_state 时注入)
    - 状态通过 machine 访问状态机,再通过状态机访问宿主(Role/PlayerVisual)
    - 状态不直接持有场景节点引用——节点引用由状态机提供 getter

三个虚方法:
    - _enter_state: 进入状态时调用(播动画、初始化状态数据)
    - _exit_state: 退出状态时调用(清理、播退出动画)
    - _process: 每帧调用(由状态机 _process 转发,用于状态内逻辑推进)
"""

# 所属状态机引用(add_state 时由状态机注入)
# 状态通过它访问状态机,再访问宿主节点
var machine: StateMachineBase = null

# 状态名(add_state 时由状态机注入,状态机用这个名字当 key)
var state_name: String = ""


## 进入状态时调用(由 StateMachineBase.change_state 触发)
func _enter_state() -> void:
	pass


## 退出状态时调用(由 StateMachineBase.change_state 触发)
func _exit_state() -> void:
	pass


## 每帧调用(由 StateMachineBase._process 转发)
func _process(_delta: float) -> void:
	pass
