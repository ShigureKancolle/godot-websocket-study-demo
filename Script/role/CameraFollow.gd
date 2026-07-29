extends Camera2D

# 平滑跟随系数(0=不平滑,1=瞬移;推荐 0.1~0.2)
@export var follow_smoothing: float = 1

# 目标节点Role ID
var _target_id: String = ""
# 缓存本地玩家的 ClientEntityInfo(强类型),坐标访问用 .x / .y
var _role: ClientEntityInfo = null
var _target_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	_target_id = ClientStateMirror.instance().local_entity_id()
	ClientStateMirror.instance().entity_updated.connect(_on_entity_updated)

func _on_entity_updated(_info: ClientEntityInfo) -> void:
	pass

func _find_role() -> void:
	# 从镜像里取本地玩家的 ClientEntityInfo(含 x/y 坐标,强类型)
	_role = ClientStateMirror.instance().get_entity(_target_id)

func _process(_delta: float) -> void:
	if _target_id == "":
		return
	if _role == null:
		_find_role()
		if _role == null:
			return

	# 强类型字段访问,不再用 dict 索引
	_target_pos = Vector2(_role.x, _role.y)

	# 平滑跟随
	# 平滑插值(lerp)
	global_position = global_position.lerp(_target_pos, follow_smoothing)
