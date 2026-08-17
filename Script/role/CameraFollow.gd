extends Camera2D

# 平滑跟随系数(0=不平滑,1=瞬移;推荐 0.1~0.2)
# @export var follow_smoothing: float = 0.2
@export var follow_smoothing: float = 0.2

# 屏幕震动(攻击命中"重击感"):攻击判定生效瞬间随机偏移 2~3px 并立即衰减归零。
# 用 Camera2D.offset(屏幕空间偏移),和 position 的平滑跟随互不干扰:
#   - position: 跟随本地玩家(lerp 目标位置)
#   - offset:   震动偏移,每帧衰减,归零后复位(避免残留偏移)
# 触发: Role._on_attack_hit_moment 收到本地玩家攻击命中时刻(hit_time)后调 shake()

# 震动初始强度(像素)。2~3px 足够有"重击感"又不糊屏
const SHAKE_STRENGTH: float = 3.0
# 衰减速率(强度/秒):3.0 / 22 ≈ 0.14s 归零,短促不拖沓
const SHAKE_DECAY: float = 22.0
const SHAKE_EPSILON: float = 0.05

var _shake_strength: float = 0.0

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

func _process(delta: float) -> void:
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

	# 屏幕震动:随机方向偏移 × 当前强度,每帧衰减,归零复位
	if _shake_strength > SHAKE_EPSILON:
		offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake_strength
		_shake_strength = max(0.0, _shake_strength - SHAKE_DECAY * delta)
		if _shake_strength <= SHAKE_EPSILON:
			offset = Vector2.ZERO


## 触发一次屏幕震动(由 Role._on_attack_hit_moment 在攻击命中时刻调用)
## strength: 初始强度(像素),默认 3px;叠加取大(连续命中不减弱)
func shake(strength: float = SHAKE_STRENGTH) -> void:
	_shake_strength = max(_shake_strength, strength)
