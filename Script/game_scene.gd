'''
游戏场景(接入无限地图)
继承自 dead_man_scene.gd,复用全部实体管理/血条/飘字/受击特效逻辑,
只增加 InfiniteTileMap 的接入:把 Camera2D 设为地图跟随目标。

木桩场景(DeadManScene)是测试用,纯色背景无地图;
游戏场景(GameScene)是正式玩法,接入无限地图 chunk 动态加载。

为什么跟随 Camera2D 而非 Role:
  - Camera2D 在场景里一直存在,不会因玩家创建时机晚而 null
  - 相机跟随玩家,地图跟随相机,间接跟随玩家——链路简单可靠
  - 不需要覆盖 _create_role 设 follow target,减少时序依赖
'''

extends "res://Script/dead_man_scene.gd"

var _hud: Control

func _ready() -> void:
	# 调用父类 _ready:连接 StateMirror 信号、初始化 EntityLayer/EffectLayer 等
	super._ready()
	# 把 Camera2D 设为无限地图的跟随目标
	# InfiniteTileMap._process 会读 follow_target.global_position 加载/卸载 chunk
	# Camera2D 由 CameraFollow 脚本驱动跟随本地玩家,所以地图间接跟随玩家
	var infinite_map: InfiniteTileMap = $InfiniteTileMap
	infinite_map.set_follow_target($Camera2D)
	_damage_layer = $DamageLayer
	_hud = preload("res://prefab/hud/HudMain.tscn").instantiate()
	$UILayer.add_child(_hud)
	var mirror := ClientStateMirror.instance()
	mirror.survival_state_updated.connect(_on_survival_state_updated)
	mirror.level_up_choices_received.connect(_on_level_up_choices_received)
	mirror.survival_result_received.connect(_on_survival_result_received)
	mirror.hp_changed.connect(_on_hud_hp_changed)
	_hud.survival_reward_requested.connect(_on_survival_reward_requested)
	_hud.result_return_requested.connect(_on_result_return_requested)
	# 进入场景前可能已经收到首个快照，主动用现有镜像同步 HUD。
	if mirror.get_combat(mirror.local_entity_id()) != null:
		_update_hud_hp(mirror.local_entity_id())
	if not mirror.survival_state().is_empty():
		_on_survival_state_updated(mirror.survival_state())
	if not mirror.last_level_up_choices().is_empty():
		_on_level_up_choices_received(mirror.last_level_up_choices())
	if not mirror.last_survival_result().is_empty():
		_on_survival_result_received(mirror.last_survival_result())


func _on_survival_state_updated(state: Dictionary) -> void:
	if _hud == null:
		return
	_hud.apply_survival_state(state)
	_hud.set_local_experience(int(state.get("experience", 0)), int(state.get("next_experience", 1)))
	_update_hud_hp(ClientStateMirror.instance().local_entity_id())


func _on_level_up_choices_received(choices: Dictionary) -> void:
	var local_id := ClientStateMirror.instance().local_entity_id()
	if str(choices.get("player_id", "")) == local_id:
		if choices.get("labels", []).is_empty():
			_hud.clear_level_up_choices()
		else:
			_hud.show_level_up_choices(choices)


func _on_survival_result_received(result: Dictionary) -> void:
	_hud.show_survival_result(result)


func _on_survival_reward_requested(index: int) -> void:
	# 升级选择只发送服务端请求，奖励和等级仍由 GameRoom 决定。
	MessageBus.instance().send("game.ChooseReward", {"index": index})


func _on_result_return_requested() -> void:
	_hud.clear_survival_ui()
	_on_back_pressed()


func _update_hud_hp(entity_id: String) -> void:
	if _hud == null or entity_id == "":
		return
	var combat := ClientStateMirror.instance().get_combat(entity_id)
	if combat != null:
		_hud.set_local_hp(combat.cur_hp, combat.max_hp)


func _on_hud_hp_changed(entity_id: String, _cur_hp: int, _damage: int, _attacker_id: String, _atk_id: int, _shape_idx: int) -> void:
	if entity_id == ClientStateMirror.instance().local_entity_id():
		_update_hud_hp(entity_id)
