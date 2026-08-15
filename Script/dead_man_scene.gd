'''
木桩场景
多个玩家进来打木桩

当前阶段: 玩家和木桩都由服务端权威驱动创建
    - 接 ClientStateMirror 的信号，管理所有实体(玩家/木桩)的 Role 创建/更新/删除
    - 本地玩家点击移动，远程玩家位置由服务端同步
    - 木桩由服务端在 main.py 注册,通过 GameState 快照下发到客户端动态创建
'''

extends Node2D

# Role 预加载: 用 Role.gd 作为脚本创建 Role 实例
# Role.tscn 目前只是个空 Node，用 .tscn 还是 .new() + 脚本都行
# 这里用脚本 new() 的方式，避免依赖 .tscn 文件的配置
const RoleScript = preload("res://Script/role/Role.gd")

# 实体节点表: entity_id -> Role 实例
# 所有可交互物体(玩家+木桩)都在这一张表里,和服务端 _entities 对齐
# 用它快速查找某个 entity_id 对应的 Role,收到 entity_updated 信号时更新它
var _entities: Dictionary[String, Role] = {}
var _entity_layer: Node2D = null  # 所有 Role 的父节点,方便统一管理
var _effect_layer: Node2D = null  # 所有 Effect 的父节点,方便统一管理
var _damage_layer: Node2D = null  # 所有 DamageEffect 的父节点,方便统一管理


func _ready() -> void:
	# 进入游戏场景:PlayerJoin 已作为首消息发出,现在可以安全开启 RTT 测量
	# (用于本地玩家移动对账外推,见 WebScoketMgr.start_rtt_measurement)
	WebScoketMgr.start_rtt_measurement()

	$UILayer/E_Back.connect("pressed", _on_back_pressed)
	_entity_layer = $EntityLayer
	_effect_layer = $EffectLayer
	
	# 连接 StateMirror 的三个信号
	# 信号定义见 StateMirror.gd
	var mirror = ClientStateMirror.instance()
	mirror.state_replaced.connect(_on_state_replaced)
	mirror.entity_updated.connect(_on_entity_updated)
	mirror.entity_removed.connect(_on_entity_removed)
	mirror.entity_hurt_effect.connect(_on_entity_hurt_effect)
	mirror.stats_inited.connect(_on_stats_inited)
	mirror.stats_changed.connect(_on_stats_changed)
	mirror.hp_changed.connect(_on_hp_changed)
	mirror.fire_damage_effect.connect(_on_fire_damage_effect)

	# 如果 StateMirror 里已经有状态（比如进入场景前就收到了 GameState），
	# 主动用现有状态刷一次——否则要等下一次 state_replaced 才显示
	# 这种「进入场景时主动拉取一次」的写法很常见，避免信号漏接
	if mirror.entity_count() > 0:
		_on_state_replaced(mirror.all_entities())

# StateMirror.state_replaced 信号: 全量替换
# 服务端发 GameState 快照时触发，收到一份完整的实体列表(玩家+木桩)
func _on_state_replaced(entities: Array) -> void:
	# 先清空所有现有 Role（因为要整体替换）
	for role in _entities.values():
		role.queue_free()
	_entities.clear()

	# 用快照重建所有 Role
	# entities 是 Array[ClientEntityInfo](强类型,不再传 dict)
	# 每个 ClientEntityInfo 里有 entity_type 字段,Role.setup 会按类型挂不同组件
	for info in entities:
		_create_role(info)


# StateMirror.entity_updated 信号: 单个实体变化
# 可能是「新实体加入」或「已有实体移动/朝向/状态变化」——两种情况统一处理:
#   - 不存在则创建
#   - 已存在则更新坐标/朝向/动画状态
func _on_entity_updated(info: ClientEntityInfo) -> void:
	var eid: String = info.entity_id
	if eid == "":
		return

	if _entities.has(eid):
		# 已存在: 更新坐标/朝向/动画状态
		_entities[eid].on_entity_updated(info)
	else:
		# 不存在: 创建新 Role(可能是新玩家加入,或 GameState 乱序补单)
		_create_role(info)


# StateMirror.entity_removed 信号: 实体离开
# 玩家断连会触发;木桩目前不会被移除(没有"木桩被破坏"逻辑)
func _on_entity_removed(entity_id: String) -> void:
	if _entities.has(entity_id):
		_entities[entity_id].queue_free()
		_entities.erase(entity_id)

# StateMirror.entity_hurt_effect 信号: 实体受击特效
# 播受击特效(渲染层监听这个信号,在受击者位置播特效)
func _on_entity_hurt_effect(pos: Vector2, atk_id: int) -> void:
	# 播受击特效(在受击者位置播特效
	# TODO 后期再改造成effectmgr用对象池
	if atk_id == 1001:
		var effect = preload("res://prefab/effect/PlayerHitEffect.tscn").instantiate()
		effect.position = pos
		effect.get_node("AnimatedSprite2D").animation_finished.connect(effect.queue_free)  # 播完自动删除
		_effect_layer.add_child(effect)

func _on_stats_inited(combats: Array[ClientStateMirror.ClientCombatStats]) -> void:
	for combat in combats:
		if _entities.has(combat.entity_id):
			_entities[combat.entity_id].on_stats_updated(combat)

func _on_stats_changed(combat: ClientStateMirror.ClientCombatStats) -> void:
	if _entities.has(combat.entity_id):
		_entities[combat.entity_id].on_stats_updated(combat)

func _on_hp_changed(entity_id: String, cur_hp: int, damage: int, attacker_id: String, atk_id: int, atk_shape_idx: int) -> void:
	if damage != 0:
		print("Damage:", damage)
	if _entities.has(entity_id):
		_entities[entity_id].on_hp_changed(cur_hp, damage, attacker_id, atk_id, atk_shape_idx)

func _on_fire_damage_effect(pos: Vector2, _atk_id: int, damage: int) -> void:
	# 播伤害飘字(在受击者位置播特效)
	# TODO 后期再改造成effectmgr用对象池
	if _damage_layer == null:
		return
	var effect = preload("res://prefab/effect/FireDamageEffect.tscn").instantiate()
	effect.get_node("AnimationPlayer").play("fire")
	var on_animation_finished = func(anim_name: String) -> void:
		if anim_name == "fire":
			effect.queue_free()
	effect.get_node("AnimationPlayer").animation_finished.connect(on_animation_finished)  # 播完自动删除
	var random_offset = Vector2(randf_range(-10, 10), randf_range(-10, 10))
	effect.position = pos + random_offset
	_damage_layer.add_child(effect)
	effect.get_node("Label").text = "%d" % damage


# 创建一个 Role 实例并加入场景
# info 是 ClientEntityInfo(强类型),含 entity_id / entity_type / x / y / facing / state 等
# Role.setup 会根据 entity_type 分发到 _setup_player / _setup_stake
func _create_role(info: ClientEntityInfo) -> void:
	var role = RoleScript.new()
	role.setup(info)
	_entity_layer.add_child(role)
	_entities[info.entity_id] = role
	var mirror = ClientStateMirror.instance()
	if mirror.get_combat(info.entity_id) != null:
		role.on_stats_updated(mirror.get_combat(info.entity_id))
		role.on_hp_changed(mirror.get_combat(info.entity_id).cur_hp, 0, "", 0, 0)
	role.on_entity_updated(info)


func _on_back_pressed() -> void:
	# 先通知服务端真正退出房间:移除服务端实体并广播 LeaveRoom,
	# 否则服务端房间仍保留这个玩家,AI 会继续把他当目标。
	var mirror: ClientStateMirror = ClientStateMirror.instance()
	var local_id: String = mirror.local_entity_id()
	if local_id != "":
		MessageBus.instance().send("game.LeaveRoom", {"entity_id": local_id})

	# 清空 StateMirror 镜像数据,避免跨场景脏数据
	# (木桩场景和正式地图场景共享同一个 StateMirror 单例,不清空会残留旧实体)
	mirror.clear()
	# 返回大厅
	get_tree().change_scene_to_file.call_deferred("res://prefab/main/MainScene.tscn")
