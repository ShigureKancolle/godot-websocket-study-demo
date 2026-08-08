extends StateBase
class_name DeadState

"""
文件: client/Script/statemachine/AnimState/DeadState.gd
作用: 死亡状态——实体 hp 扣到 0 且 can_die=True 时播放 dead 动画

进入状态时调 PlayerVisual.play_anim("dead") 播放死亡动画。
死亡动画播完后不切回 idle——实体等 EntityRemove 消息来才 queue_free 移除节点。

和 HurtState 的区别:
    - HurtState: 硬直结束(服务端 HurtTimer 到期)→ state="idle" → 切回 IdleState
    - DeadState: 死亡动画播完不动 → 等 EntityRemove 消息 → queue_free(节点消失)

不实现 _reenter_state:死亡是终态,不会"重复死亡"(服务端 get_attack_hits 已过滤 dead 实体)。
"""

func _enter_state() -> void:
	# machine 实际是 AnimStateMachine(由 AnimStateMachine._register_states 注入)
	# GDScript 动态分派,get_visual() 会调到 AnimStateMachine 的方法
	var visual = machine.get_visual()
	if visual != null:
		visual.play_anim("die")
