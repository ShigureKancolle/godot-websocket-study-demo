extends StateBase
class_name DeadState

"""
文件: client/Script/statemachine/DeadState.gd
作用: 死亡状态——玩家死亡时播放 dead 动画

进入状态时调 PlayerVisual.play_anim("dead") 播放死亡动画。
退出状态时不做事(下一个状态的 _enter_state 会接管动画)。
"""

func _enter_state() -> void:
	# machine 实际是 AnimStateMachine(由 AnimStateMachine._register_states 注入)
	# GDScript 动态分派,get_visual() 会调到 AnimStateMachine 的方法
	var visual = machine.get_visual()
	if visual != null:
		visual.play_anim("dead")
