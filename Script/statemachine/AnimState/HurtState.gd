extends StateBase
class_name HurtState

"""
文件: client/Script/statemachine/HurtState.gd
作用: 受击状态——玩家被攻击命中时播放 hurt 动画

进入状态时调 PlayerVisual.play_anim("hurt") 播放受击动画。
退出状态时不做事(下一个状态的 _enter_state 会接管动画)。

_reenter_state 处理连击场景:
	服务端 hurt 定时器被 cancel+restart 时不会重发 state="hurt"(state 没变),
    但客户端会再收到一次 AttackHit——AnimStateMachine.change_state 检测到
	"相同状态"时调 _reenter_state,这里重启动画实现受击反馈立即响应。
    (若不重启,连击时 hurt 动画只播第一次,后续命中无视觉反馈)
"""

func _enter_state() -> void:
	# machine 实际是 AnimStateMachine(由 AnimStateMachine._register_states 注入)
	# GDScript 动态分派,get_visual() 会调到 AnimStateMachine 的方法
	var visual = machine.get_visual()
	if visual != null:
		visual.play_anim("hurt")

func _reenter_state() -> void:
	var visual = machine.get_visual()
	if visual != null:
		visual.replay_cur_anim()
	
