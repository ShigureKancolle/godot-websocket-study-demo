extends Node2D
class_name Role

"""
文件: client/Script/role/Role.gd
作用: 通用实体容器——通过挂载不同组件复用为玩家/木桩/NPC 等

============================================================================
 设计思路(组件化 / ECS-lite)
============================================================================
Role 本身只是一个「位置容器」: 有坐标、能挂子节点。
它不知道自己是玩家还是木桩——「是什么」由 entity_type 决定挂载的组件。

组件分类:
    - Visual 组件: 负责显示(Sprite、动画等)
    - Controller 组件: 负责行为(本地玩家读输入、远程玩家读 StateMirror)
    - AnimStateMachine 组件: 负责动画状态切换(idle/run/attacking/hurt)

按 entity_type 分发(本次统一 Entity 模型 + 强类型重构):
    - player:
        - 本地玩家 → PlayerVisual + AnimStateMachine + LocalPlayerController
        - 远程玩家 → PlayerVisual + AnimStateMachine
    - stake:
        - 只挂 PlayerVisual(占位,未来可换 StakeVisual)
        - 不挂 AnimStateMachine(木桩目前只有 idle/hurt,hurt 由 StateMirror 信号直接改 state 字段)
        - 不挂 LocalPlayerController(木桩不被本地控制)

后续扩展:
    - 木桩 → StakeVisual(被动受击,有自己的贴图)
    - NPC → NpcVisual + NpcController(AI 驱动)

============================================================================
 和服务器权威状态同步的关系
============================================================================
Role 的「坐标」不归自己管:
    - 本地玩家: LocalPlayerController 读输入 → 发 PlayerMove → 服务端 apply_move
                → 服务端广播 → StateMirror 更新 → entity_updated 信号 → Role 更新坐标
                (注意: 本地玩家也走 StateMirror 更新,不直接本地改坐标——保证权威一致)
    - 远程玩家/木桩: StateMirror 收到 PlayerMove → entity_updated 信号 → Role 更新坐标
    - 木桩: StateMirror 收到 GameState 快照 → state_replaced 信号 → Role 创建并定位

所以 Role.position 永远是由 StateMirror 的信号驱动的,Role 自己不改自己的坐标。
这是「服务器权威」在客户端的最终体现: 连本地玩家的坐标都不自己算。

============================================================================
 强类型 ClientEntityInfo(本次重构)
============================================================================
setup/on_entity_updated 的参数从 Dictionary 改为 ClientEntityInfo:
	- 字段访问用 info.x / info.state 而非 info["x"] / info["state"]
    - entity_type 从 String 改为 ClientEntityInfo.EntityType 枚举
    - match 用 EntityType.PLAYER / EntityType.STAKE 做穷尽性检查
"""

# 这个 Role 对应的实体ID
# 用它和 StateMirror.local_entity_id() 对比,判断是本地玩家还是远程玩家
# entity_id 带类型前缀: "player:uuid-xxx" / "entity:stake_1"
var entity_id: String = ""

# 实体类型(枚举): PLAYER / STAKE / UNKNOWN
# setup 时从 info.entity_type 取出并缓存,用于决定挂什么组件、如何更新
# 用枚举而非字符串:match 有穷尽性检查,拼错编译期报错
var entity_type: ClientEntityInfo.EntityType = ClientEntityInfo.EntityType.UNKNOWN

# 战斗数据
var entity_combat: ClientStateMirror.ClientCombatStats = null


## 初始化 Role: 根据 ClientEntityInfo 决定挂什么组件
## 由 dead_man_scene 在创建/更新 Role 时调用
func setup(info: ClientEntityInfo) -> void:
	entity_id = info.entity_id
	entity_type = info.entity_type

	# 先更新坐标(setup 也可能携带最新坐标)
	_update_position(info)

	# 避免重复挂组件: 如果已经挂过同名组件,先移除
	# 这在 entity_updated 信号重复触发时有用(虽然一般不会重复挂)
	_remove_component("PlayerVisual")
	_remove_component("LocalPlayerController")
	_remove_component("AnimStateMachine")
	_remove_component("HpProgressBar")
	_remove_component("MpProgressBar")

	# 按 entity_type 分发挂载组件
	# 当前实现:
	#   - PLAYER: PlayerVisual + AnimStateMachine(本地玩家额外挂 LocalPlayerController)
	#   - STAKE:  只挂 PlayerVisual(占位,木桩目前不需要动画状态机和控制器)
	# 未来扩展时,在这里加新的分支或 dispatch 到专门的 _setup_xxx 方法
	match entity_type:
		ClientEntityInfo.EntityType.PLAYER:
			_setup_player(info)
		ClientEntityInfo.EntityType.STAKE:
			_setup_stake(info)
		ClientEntityInfo.EntityType.ENEMY_SLIME:
			_setup_enemy(info)
		ClientEntityInfo.EntityType.ENEMY_SKELETON:
			_setup_enemy(info)
		_:
			# 未知类型:按 player 处理(兼容性兜底,日志告警便于发现配置错误)
			push_warning("Role.setup: 未知 entity_type=%s,按 player 处理" % info.type_string())
			_setup_player(info)


## 设置玩家类型实体: 挂 PlayerVisual + AnimStateMachine,本地玩家额外挂 Controller
func _setup_player(info: ClientEntityInfo) -> void:
	# 挂 PlayerVisual(所有玩家都要显示)
	# 用预制体实例化:节点结构/Label 位置/颜色等静态配置在 PlayerVisual.tscn 里
	# 先挂 visual,再挂状态机:状态机 _ready 时要访问 visual 播初始动画
	var visual = preload("res://prefab/role/PlayerVisual.tscn").instantiate()
	visual.name = "PlayerVisual"
	add_child(visual)
	# 调用组件的初始化(传入玩家信息,让它知道显示什么)
	visual.setup(info)

	# 挂 AnimStateMachine(所有玩家都要挂动画状态机)
	# 必须在 PlayerVisual 之后挂:_ready 进入 idle 状态时要调 visual.play_anim
	var anim_machine = preload("res://Script/statemachine/AnimState/AnimStateMachine.gd").new()
	anim_machine.name = "AnimStateMachine"
	add_child(anim_machine)
	anim_machine.setup(info)
	# 注:anim_machine._ready 会在进场景树时自动触发(注册状态 + 进入 idle)
	# Role 此刻可能还没 add_child 到场景树(dead_man_scene 的创建顺序),
	# _ready 会延迟到 Role 进场景树时触发,那时 PlayerVisual 也已就绪

	# 判断是否本地玩家
	# 本地玩家额外挂 LocalPlayerController(读键盘输入发 PlayerMove)
	# 远程玩家不挂,它的坐标完全由 StateMirror 的 entity_updated 信号驱动
	var local_eid = ClientStateMirror.instance().local_entity_id()
	if entity_id == local_eid and entity_id != "":
		var controller = preload("res://Script/role/LocalPlayerController.gd").new()
		controller.name = "LocalPlayerController"
		add_child(controller)
		controller.setup(info)

	# 血条
	var hp_bar = preload("res://prefab/role/ProgressBar.tscn").instantiate()
	hp_bar.name = "HpProgressBar"
	add_child(hp_bar)
	hp_bar.set_type("hp")
	hp_bar.set_auto_hide(false)
	hp_bar.position = Vector2(0, -39)


## 设置木桩类型实体: 当前简化为只挂 PlayerVisual(占位)
## 未来可换成专门的 StakeVisual(用木桩贴图,不挂 AnimatedSprite2D)
func _setup_stake(info: ClientEntityInfo) -> void:
	# 木桩目前复用 PlayerVisual 作为占位显示
	# 它会显示圆形角色贴图 + 名字标签 + 朝向箭头,虽然不完美但能跑通统一 Entity 模型
	# 后续替换为专门 StakeVisual 时只改本方法,不影响其他 entity_type 的逻辑
	var visual = preload("res://prefab/role/PlayerVisual.tscn").instantiate()
	visual.name = "PlayerVisual"
	add_child(visual)
	visual.setup(info)
	visual.set_entity_name("木桩")
	# AnimStateMachine(没有动画状态切换需求,简化)
	var anim_machine = preload("res://Script/statemachine/AnimState/AnimStateMachine.gd").new()
	anim_machine.name = "AnimStateMachine"
	add_child(anim_machine)
	anim_machine.setup(info)
	# 木桩不挂 LocalPlayerController(不被本地控制)
	# 如果未来木桩需要 hurt 动画,通过 entity_updated 信号里的 state 字段驱动即可
	# (StateMirror._on_attack_hit 会设 state="hurt" 并 emit entity_updated)

	# 血条
	var hp_bar = preload("res://prefab/role/ProgressBar.tscn").instantiate()
	hp_bar.name = "HpProgressBar"
	add_child(hp_bar)
	hp_bar.set_type("hp")
	hp_bar.set_auto_hide(false)
	hp_bar.position = Vector2(0, -39)

func _setup_enemy(info: ClientEntityInfo) -> void:
	_setup_player(info)
	var visual = get_node_or_null("PlayerVisual")
	if visual != null:
		visual.set_entity_name(info.enum_type_string())

func on_hp_changed(cur_hp: int, damage: int, attacker_id: String, atk_id: int, atk_shape_idx: int) -> void:
	# damage为0时是初始化 不跳字
	var hp_bar = get_node_or_null("HpProgressBar")
	if hp_bar != null:
		hp_bar.set_value(cur_hp)
		hp_bar.set_percentage(cur_hp * 1.0 / entity_combat.max_hp)

func on_stats_updated(combat: ClientStateMirror.ClientCombatStats) -> void:
	if entity_combat == null:
		# 只有init的时候需要赋值一下 其他时候已经更新了combat了 直接处理其他逻辑
		entity_combat = combat

	# 显示之类的逻辑
	var hp_bar = get_node_or_null("HpProgressBar")
	if hp_bar != null:
		hp_bar.set_max(combat.max_hp)


## 收到 StateMirror 的 entity_updated 信号时调用,更新坐标、朝向、动画状态
func on_entity_updated(info: ClientEntityInfo) -> void:
	_update_position(info)
	# 朝向更新:转发给 PlayerVisual(如果已挂载)
	# facing 是独立状态维度,和坐标分开更新,但走同一个 entity_updated 信号
	var visual = get_node_or_null("PlayerVisual")
	if visual != null:
		visual.update_facing(info.facing)
	# 动画状态更新:转发给 AnimStateMachine(如果已挂载)
	# state 字段由 StateMirror 从 moving 推断(或 GameState 快照带),服务端权威
	# 木桩没挂 AnimStateMachine,跳过(木桩的 state 变化目前不影响显示)
	var anim_machine = get_node_or_null("AnimStateMachine")
	if anim_machine != null and info.state != "":
		anim_machine.update_state(info.state)


## 更新坐标到 Role.position
func _update_position(info: ClientEntityInfo) -> void:
	position = Vector2(info.x, info.y)


## 移除指定名称的组件(如果存在)
func _remove_component(component_name: String) -> void:
	var node = get_node_or_null(component_name)
	if node != null:
		node.queue_free()
