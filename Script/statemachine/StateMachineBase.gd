extends Node
class_name StateMachineBase

"""
文件: client/Script/statemachine/StateMachineBase.gd
作用: 状态机基类——状态管理 + 状态切换 + 每帧驱动

============================================================================
 设计说明
============================================================================
用 Node 而非 RefCounted/Object:
    - 状态机要 add_child 到宿主节点(Role/PlayerVisual),进场景树
    - 要自动 _process 驱动当前状态(RefCounted 没有 _process)
    - 作为宿主的组件存在,和 PlayerVisual/LocalPlayerController 平级

和 StateBase 的分工:
    - StateMachineBase(本类):管状态表、当前状态、切换、每帧驱动
    - StateBase(状态):管具体状态的进入/退出/每帧逻辑
    - 状态机不关心"什么时候该切什么状态"——切换决策由上层(如 Role 转发 state)
      调用 change_state 触发,状态机只负责"怎么切"(校验+回调)

和旧版的区别:
    - 旧版 extends Object:无法 add_child,无法自动 _process,已废弃
    - 旧版 add_state 用 state.name 当 key:Object 没有 name 属性,会报错
    - 旧版没有 change_state:只有 set_current_state(无校验、无相同状态判断)
"""

# 当前状态(null 表示还没进入任何状态)
var current_state: StateBase = null

# 状态表: state_name(String) -> StateBase
# 用显式传入的 name 当 key,不依赖 Node.name(Object 没有 name 属性)
var _states: Dictionary = {}


func _process(delta: float) -> void:
	# 每帧驱动当前状态
	# 状态机自己不写逻辑,只把 _process 转发给当前状态
	if current_state != null:
		current_state._process(delta)


## 添加状态到状态表
## state_name: 状态名(后续 change_state 用这个名字切换)
## state: 状态实例(StateBase 子类)
func add_state(state_name: String, state: StateBase) -> void:
	state.state_name = state_name
	state.machine = self
	_states[state_name] = state


## 切换状态(带校验)
## state_name: 目标状态名
## - 不存在的状态:告警,不切
## - 和当前相同的状态:不重复进入(避免 _enter_state 重复触发)
## - 正常切换:先 _exit_state 旧状态,再 _enter_state 新状态
func change_state(state_name: String) -> void:
	if not _states.has(state_name):
		push_warning("状态机切换到不存在的状态: " + state_name)
		return
	var new_state: StateBase = _states[state_name]
	if current_state == new_state:
		return  # 相同状态不重复进入
	if current_state != null:
		current_state._exit_state()
	current_state = new_state
	current_state._enter_state()


## 获取状态(不存在返回 null)
func get_state(state_name: String) -> StateBase:
	return _states.get(state_name)


## 获取当前状态名(无状态返回空串)
func get_current_state_name() -> String:
	if current_state == null:
		return ""
	return current_state.state_name
