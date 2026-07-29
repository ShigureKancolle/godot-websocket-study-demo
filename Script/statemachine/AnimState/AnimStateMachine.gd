extends StateMachineBase
class_name AnimStateMachine

"""
文件: client/Script/statemachine/AnimStateMachine.gd
作用: 动画状态机——Role 的平级组件,根据服务端 state 切换动画

============================================================================
 架构位置(服务器权威的最终体现)
============================================================================
    服务端 EntityInfo.state(idle/run/attacking/hurt/...)
        ↓ StateMirror._on_player_move 从 moving 推断 state
        ↓ entity_updated 信号
    Role.on_entity_updated
        ↓ 转发 state 字段给 AnimStateMachine
    AnimStateMachine.update_state(state_name)
        ↓ change_state
    IdleState / RunState / AttackState / HurtState._enter_state
        ↓ machine.get_visual().play_anim("idle"/"run"/"attack"/"hurt")
    PlayerVisual 的 AnimatedSprite2D 播放对应动画

============================================================================
 设计说明
============================================================================
作为 Role 的平级组件(和 PlayerVisual/LocalPlayerController 一样 add_child 到 Role):
    - 不持有状态权威:state 由服务端定,这里只做「state → 动画」的映射
    - 不做状态切换决策:切换由 Role 转发服务端 state 触发,状态机只负责「怎么切」
    - 状态对象(IdleState/RunState)通过 machine.get_visual() 访问 PlayerVisual

初始状态:
    _ready 时自动注册状态 + 进入 "idle"(玩家默认静止)
    此时 PlayerVisual 已 setup 完(Role.setup 先 add PlayerVisual 再 add 状态机,
    子节点 _ready 按添加顺序触发,PlayerVisual 先于 AnimStateMachine)

状态名 vs 动画名:
    状态名(注册 key)和服务端 EntityInfo.state 严格对齐:
      - "idle" / "run" / "attacking" / "hurt"
    动画名(传给 PlayerVisual.play_anim)是 PlayerVisual 拼 "Down_xxx" 的基础名:
      - "idle" / "run" / "attack" / "hurt"
    "attacking" 状态 → AttackState._enter_state 调 play_anim("attack") → 拼 "Down_attack"
    这样状态名和动画名解耦:服务端 state 名可读(带 ing 后缀表进行时),
    动画资源名短(无 ing 后缀,和 SpriteFrames 配置一致)
"""


func _ready() -> void:
	_register_states()
	# 进入初始状态 idle(玩家默认静止)
	# 此时 PlayerVisual 已 setup(Role.setup 先 add visual 再 add 状态机)
	change_state("idle")


## 注册所有动画状态
## 在 _ready 调用一次。新增状态时在这里加 add_state
## key 必须和服务端 EntityInfo.state 字段值一致(否则 update_state 找不到对应状态)
func _register_states() -> void:
	add_state("idle", IdleState.new())
	add_state("run", RunState.new())
	# "attacking" 对应服务端 apply_attack_start 设的 state(带 ing 后缀表进行时)
	# AttackState._enter_state 内部调 play_anim("attack") 播动画(动画名无 ing)
	add_state("attacking", AttackState.new())
	add_state("hurt", HurtState.new())


## 保留接口和 PlayerVisual.setup 对称(当前未使用)
## 后续如需根据玩家信息初始化状态,在这里实现
func setup(_info: ClientEntityInfo) -> void:
	pass


## 由 Role.on_entity_updated 调用,转发服务端的 state 字段
## state_name: 服务端 EntityInfo.state 的值(idle/run/attacking/hurt/...)
func update_state(state_name: String) -> void:
	change_state(state_name)


## 获取 PlayerVisual(状态对象通过这个访问显示层)
## AnimStateMachine add_child 到 Role,所以 get_parent() = Role
## PlayerVisual 是 Role 的 "PlayerVisual" 子节点
func get_visual() -> PlayerVisual:
	var role = get_parent()
	if role == null:
		return null
	return role.get_node_or_null("PlayerVisual")
