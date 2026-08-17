extends RefCounted
class_name ConfigLoader

"""
文件: client/Script/game/ConfigLoader.gd
作用: 从 res://config/*.json 读取配置并构造对象(和服务端 config_loader.py 对称)

============================================================================
 为什么需要 ConfigLoader
============================================================================
双端共享配置采用「单数据源 + 复制」方案:
    - 单数据源在 shared_config/(只在这里改)
    - sync_config.py 同步到 server/config/ 和 client/res/config/
    - 服务端 config_loader.py 读 server/config/*.json
    - 客户端 ConfigLoader.gd 读 res://config/*.json

ConfigLoader 是客户端配置访问的唯一入口:
    - 读 res://config/*.json(Godot 资源路径,sync_config.py 同步过来)
    - 构造 inner class 对象返回(保持类型安全,IDE 可补全)
    - JSON 里下划线开头的字段(_comment / _desc / _shape_type_values 等)是注释,
      loader 读取时跳过

============================================================================
 和服务端 config_loader.py 的关系
============================================================================
完全对称:
    - ShapeType 枚举值(字符串): sector/rect/circle/ring
    - ShapeParams / SectorParams / CircleParams / RectParams 数据类
    - AttackShape / AttackConfig 攻击配置类
    - EntityCapability 实体能力+碰撞形状类
    - API: get_attack_config / get_capability / get_hurt_duration_ms 等

数据结构镜像约束:
    - 改配置只改 shared_config/*.json,然后跑 sync_config.py,双端一起更新
    - 改数据结构(加字段/改字段)要同时改 config_loader.py 和 ConfigLoader.gd

============================================================================
 GDScript 特殊处理
============================================================================
1. const 不能 new 对象:GDScript 的 const 只能存字面量,不能在 const 里 new 内部类。
   所以配置表用 static var + 懒加载(_ensure_cache),首次访问时构造。

2. 角度→弧度转换:JSON 里 angle 用角度存(人读直观),构造时转成弧度(代码计算用)。
   deg_to_rad(deg) = deg * PI / 180.0

3. JSON 解析:用 JSON.new() + parse_string(),失败时返回空字典兜底
"""



# ===========================================================================
# ShapeType 形状类型枚举(字符串值,和服务端 config_loader.ShapeType 对齐)
# ===========================================================================
# 实体碰撞形状和攻击形状共用这套枚举
const ShapeType_SECTOR: String = "sector"
const ShapeType_RECT: String = "rect"
const ShapeType_CIRCLE: String = "circle"
const ShapeType_RING: String = "ring"


# ===========================================================================
# 形状参数 inner class(和服务端 config_loader.py 的 dataclass 对齐)
# ===========================================================================
class ShapeParams:
	"""形状参数基类,实际参数由子类决定"""
	pass


class SectorParams:
	extends ShapeParams
	var radius: float = 35.0    # 扇形半径(像素)
	var angle: float = 2.094    # 扇形角度(弧度,默认 120°)


class CircleParams:
	extends ShapeParams
	var radius: float = 24.0    # 圆形半径(像素)


class RectParams:
	extends ShapeParams
	var width: float = 0.0
	var height: float = 0.0


# ===========================================================================
# 战斗属性 inner class(类型级基础值,EntityInfo 初始化时拷贝一份作为实例运行时状态)
# ===========================================================================
class CombatStats:
	"""
	实体战斗属性(类型级基础值)。

	语义:这里是「该类型的初始/基础战斗属性」,所有同类型实体共享同一份数值。
	运行时强化(玩家成长/敌人每波强化)应该改 EntityInfo 里拷贝出来的实例副本,
	不应该回写到这里(配置是只读的)。

	伤害公式在 StateMirror/game_room 算,不在这层:
		final = attacker.attack_power * atk_shape.damage_percent * 防御系数
	defense 参与防御系数计算。
	"""
	var max_hp: int = 0           # 最大血量
	var attack_power: int = 0     # 攻击力基础值(乘以攻击配置的 damage_percent 得最终伤害)
	var defense: int = 0          # 防御力(参与伤害减免公式)


# ===========================================================================
# 攻击配置 inner class
# ===========================================================================
class AttackShape:
	var shape: String = ShapeType_SECTOR       # 形状类型字符串(和 ShapeType_XXX 值对齐)
	var shape_params: Variant = null           # ShapeParams 子类对象,根据 shape 决定
	var duration: int = 583                    # 攻击持续时间(ms)
	var hit_time: int = 83                     # 判定帧时间(从发起算,ms)
	var damage_multiplier: float = 1.0         # 伤害倍率(和服务端 AttackShape.damage_multiplier 对齐)
	# 注:原 hit_mask 字段已移除。命中层级改由实体类型的 attack_mask 决定
	# (玩家=2 打敌人层,敌人=1 打玩家层),玩家和敌人可复用同一 atk_id

class AttackConfig:
	var shape_list: Array = []                 # Array[AttackShape]
	


# ===========================================================================
# 地形能力 inner class(地图 tile 类型 → 是否可通行等属性)
# ===========================================================================
# ChunkGenerator.get_tile_type_v3 返回 TerrainType 枚举值(int),
# 本配置表把枚举值映射成能力字段,供客户端调试/可视化寻路用。
# 服务端也有一份对称的实现(见 server/config/config_loader.py)
# 地形类型 → 名称映射(和 ChunkGenerator.TerrainType 枚举顺序对齐):
#   0=GRASS, 1=SAND, 2=DIRT, 3=BRICK, 4=WATER
const _TERRAIN_ID_TO_NAME: Dictionary = {
	0: "GRASS",
	1: "SAND",
	2: "DIRT",
	3: "BRICK",
	4: "WATER",
}


class TerrainCapability:
	"""
	单个地形类型的能力配置(和服务端 config_loader.TerrainCapability 对称)。

	字段:
		walkable: 是否可通行(AI 寻路用)。true=可通行,false=障碍。
		          ChunkGenerator 当前只生成 GRASS/SAND,都是 true;
		          BRICK 是预留的障碍地形(城墙/墙壁类)。
		move_cost: 通行代价(预留,当前未用)。A* 寻路默认每格代价 1。
	"""
	var walkable: bool = true
	var move_cost: int = 1


# ===========================================================================
# 视野(视锥)配置 inner class(和服务端 config_loader.VisionParams 对称)
# ===========================================================================
# 敌人视锥渲染用:半角 + 半径,按 AI 状态选 normal/chase 两套。
# JSON 里 half_angle_deg 用角度存(人读直观),构造时转弧度(代码计算用),
# 和服务端 config_loader 一致。
class VisionInfo:
	var half_angle: float = 0.0   # 视野半角(弧度,朝向左右各多少)
	var radius: float = 0.0       # 视野半径(像素)


# ===========================================================================
# 实体能力+碰撞形状 inner class
# ===========================================================================
class EntityCapability:
	# 能力字段
	var can_move: bool = false
	var can_attack: bool = false
	var can_be_hurt: bool = false
	var can_disconnect: bool = false
	var can_die: bool = false                  # 能否进入死亡流程(hp<=0 时判定)。player=false 暂不实现,敌人=true
	# 碰撞形状字段
	var body_shape: String = ShapeType_CIRCLE
	var body_params: Variant = null            # ShapeParams 子类对象
	var hit_layer: int = 0x00000000            # 被判定层掩码(和服务端 EntityConfig.hit_layer 对齐,默认 1=玩家)
	var attack_mask: int = 0x00000000           # 攻击判定掩码(和服务端 EntityConfig.attack_mask 对齐。玩家=2 打敌人层,敌人=1 打玩家层,木桩=0)
	# 移动速度(像素/秒,类型级基础值。can_move=false 时为 0。
	# LocalPlayerController 用 player_speed * delta 算每帧步长;
	# 运行时若有减速/加速 buff 应改实例副本,不回写配置)
	var speed: float = 0.0
	# 死亡动画时长(毫秒)。can_die=false 时为 0。
	# 和服务端 config_loader.EntityCapability.dead_duration_ms 对齐。
	var dead_duration_ms: int = 0
	# 基础战斗属性(类型级,EntityInfo 初始化时从这里拷贝一份作为实例运行时状态)
	var combat_stats: CombatStats = null       # _init 里保证 new 出来,避免 null 风险
	var body_color: String = "#ffffff"         # 角色身体颜色(HEX 字符串,纯客户端显示属性,服务端不传也不读)
	func _init():
		combat_stats = CombatStats.new()


# ===========================================================================
# 内部辅助:从 dict 构造对象
# ===========================================================================

## 判断 JSON key 是否是注释(下划线开头)
static func _is_comment_key(key: String) -> bool:
	return key.begins_with("_")


## 从 dict 构造 ShapeParams 子类对象
## JSON 里 angle 用角度存,这里转成弧度(代码计算用)
static func _build_shape_params(shape_type: String, params_dict: Dictionary) -> Variant:
	match shape_type:
		ShapeType_SECTOR:
			var p = SectorParams.new()
			p.radius = float(params_dict.get("radius", 35.0))
			# 角度→弧度:rad = deg * π / 180
			p.angle = deg_to_rad(float(params_dict.get("angle", 120.0)))
			return p
		ShapeType_CIRCLE:
			var p = CircleParams.new()
			p.radius = float(params_dict.get("radius", 24.0))
			return p
		ShapeType_RECT:
			var p = RectParams.new()
			p.width = float(params_dict.get("width", 0.0))
			p.height = float(params_dict.get("height", 0.0))
			return p
		_:
			return null


## 从 dict 构造 AttackShape 对象
static func _build_attack_shape(shape_dict: Dictionary) -> AttackShape:
	var s = AttackShape.new()
	s.shape = shape_dict.get("shape", ShapeType_SECTOR)
	s.shape_params = _build_shape_params(s.shape, shape_dict.get("params", {}))
	s.duration = int(shape_dict.get("duration", 583))
	s.hit_time = int(shape_dict.get("hit_time", 83))
	s.damage_multiplier = float(shape_dict.get("damage_multiplier", 1.0))
	return s


## 从 dict 构造 AttackConfig 对象
static func _build_attack_config(entry_dict: Dictionary) -> AttackConfig:
	var cfg = AttackConfig.new()
	for shape_dict in entry_dict.get("shape_list", []):
		cfg.shape_list.append(_build_attack_shape(shape_dict))
	return cfg


## 从 dict 构造 CombatStats 对象(未配 combat_stats 时返回零值默认)
static func _build_combat_stats(stats_dict: Dictionary) -> CombatStats:
	var s = CombatStats.new()
	if stats_dict.is_empty():
		return s
	s.max_hp = int(stats_dict.get("max_hp", 0))
	s.attack_power = int(stats_dict.get("attack_power", 0))
	s.defense = int(stats_dict.get("defense", 0))
	return s


## 从 dict 构造 EntityCapability 对象
static func _build_entity_capability(entry_dict: Dictionary) -> EntityCapability:
	var cap = EntityCapability.new()
	var caps_dict: Dictionary = entry_dict.get("capabilities", {})
	cap.can_move = bool(caps_dict.get("can_move", false))
	cap.can_attack = bool(caps_dict.get("can_attack", false))
	cap.can_be_hurt = bool(caps_dict.get("can_be_hurt", false))
	cap.can_disconnect = bool(caps_dict.get("can_disconnect", false))
	cap.can_die = bool(caps_dict.get("can_die", false))
	cap.body_shape = entry_dict.get("body_shape", ShapeType_CIRCLE)
	cap.body_params = _build_shape_params(cap.body_shape, entry_dict.get("body_params", {}))
	cap.hit_layer = int(entry_dict.get("hit_layer", 0x00000000))
	cap.attack_mask = int(entry_dict.get("attack_mask", 0x00000000))
	cap.speed = float(entry_dict.get("speed", 0.0))
	cap.dead_duration_ms = int(entry_dict.get("dead_duration_ms", 0))
	cap.combat_stats = _build_combat_stats(entry_dict.get("combat_stats", {}))
	cap.body_color = entry_dict.get("body_color", "#8f0d6e")
	return cap


## 从 dict 构造 TerrainCapability 对象(未配 walkable 时默认可通行,安全默认)
static func _build_terrain_capability(entry_dict: Dictionary) -> TerrainCapability:
	var cap = TerrainCapability.new()
	cap.walkable = bool(entry_dict.get("walkable", true))
	cap.move_cost = int(entry_dict.get("move_cost", 1))
	return cap


## 读取 res://config/ 下的 JSON 文件
static func _load_json(filename: String) -> Dictionary:
	var path: String = "res://res/config/" + filename
	if not FileAccess.file_exists(path):
		push_warning("ConfigLoader: 配置文件不存在: " + path)
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	var json = JSON.new()
	var err = json.parse(text)
	if err != OK:
		push_warning("ConfigLoader: JSON 解析失败 " + path + ": " + json.get_error_message())
		return {}
	return json.data


# ===========================================================================
# 配置缓存(首次访问时懒加载,因为 GDScript const 不能 new 对象)
# ===========================================================================
static var _attack_config_cache: Dictionary = {}     # {atk_id: AttackConfig}
static var _entity_capability_cache: Dictionary = {} # {entity_type: EntityCapability}
static var _terrain_capability_cache: Dictionary = {} # {terrain_name: TerrainCapability}
static var _vision_cache: Dictionary = {}            # {mode: VisionInfo}(normal/chase)
static var _constants_cache: Dictionary = {}
static var _cache_loaded: bool = false


## 懒加载所有配置(只在首次访问时调一次)
static func _ensure_cache() -> void:
	if _cache_loaded:
		return

	# 攻击配置
	var attack_raw: Dictionary = _load_json("attack_config.json")
	for key in attack_raw.keys():
		if _is_comment_key(key):
			continue  # 跳过 _comment / _shape_type_values 等注释字段
		# atk_id 字符串 → int
		var atk_id = int(key)
		if str(atk_id) != key:
			continue  # 跳过非数字 key(防御性)
		_attack_config_cache[atk_id] = _build_attack_config(attack_raw[key])

	# 实体配置
	var entity_raw: Dictionary = _load_json("entity_config.json")
	for key in entity_raw.keys():
		if _is_comment_key(key):
			continue
		_entity_capability_cache[key] = _build_entity_capability(entity_raw[key])

	# 地形配置
	# terrain_config.json 顶层只有 "terrains" 一个数据字段(其余是 _comment 等注释)
	var terrain_raw: Dictionary = _load_json("terrain_config.json")
	var terrains_dict: Dictionary = terrain_raw.get("terrains", {})
	for key in terrains_dict.keys():
		if _is_comment_key(key):
			continue
		_terrain_capability_cache[key] = _build_terrain_capability(terrains_dict[key])

	# 视野配置(敌人视锥)
	# vision_config.json 顶层是 normal/chase 两个数据段(其余是 _comment 等注释)
	# JSON 里 half_angle_deg 用角度存,这里转弧度(和服务端 config_loader 一致)
	var vision_raw: Dictionary = _load_json("vision_config.json")
	for key in vision_raw.keys():
		if _is_comment_key(key):
			continue
		var vision = VisionInfo.new()
		vision.half_angle = deg_to_rad(float(vision_raw[key].get("half_angle_deg", 30.0)))
		vision.radius = float(vision_raw[key].get("radius", 750.0))
		_vision_cache[key] = vision

	# 常量
	var constants_raw: Dictionary = _load_json("constants.json")
	for key in constants_raw.keys():
		if _is_comment_key(key):
			continue
		_constants_cache[key] = constants_raw[key]

	_cache_loaded = true


# ===========================================================================
# 对外 API(和服务端 config_loader.py 对齐)
# ===========================================================================

## 获取某个 atk_id 的攻击配置(含 shape_list);未知返回 null
static func get_attack_config(atk_id: int) -> Variant:
	_ensure_cache()
	return _attack_config_cache.get(atk_id, null)


## 获取全部攻击配置(只读视图,不要修改返回的 dict)
static func get_all_attack_configs() -> Dictionary:
	_ensure_cache()
	return _attack_config_cache


## 取某个类型的能力配置(含碰撞形状)。
## 未列在表里的类型返回"零能力"配置(安全默认值),不会返回 null。
static func get_capability(entity_type: String) -> EntityCapability:
	_ensure_cache()
	return _entity_capability_cache.get(entity_type, EntityCapability.new())


## 取某个类型的基础战斗属性(max_hp/attack_power/defense)。
## 未列在表里的类型返回零值 CombatStats(max_hp=0 → 直接死,bug 早暴露)。
## 返回的是配置里的对象,调用方不要修改;EntityInfo 初始化时应该自己拷贝一份。
static func get_combat_stats(entity_type: String) -> CombatStats:
	_ensure_cache()
	var cap: EntityCapability = _entity_capability_cache.get(entity_type, EntityCapability.new())
	return cap.combat_stats


## 取某个类型的移动速度(像素/秒)。
## 未列在表里的类型返回 0(不会动,安全默认值)。
## LocalPlayerController 算每帧步长走这里。
static func get_speed(entity_type: String) -> float:
	_ensure_cache()
	var cap: EntityCapability = _entity_capability_cache.get(entity_type, EntityCapability.new())
	return cap.speed


## 取全局常量(如 HURT_DURATION_MS);未知返回 default
static func get_constant(name: String, default: Variant = null) -> Variant:
	_ensure_cache()
	return _constants_cache.get(name, default)


## 取 hurt 硬直时长(毫秒),语法糖
static func get_hurt_duration_ms() -> int:
	_ensure_cache()
	return int(_constants_cache.get("HURT_DURATION_MS", 666))


# ===========================================================================
# 地形能力 API(寻路用,和服务端 config_loader.py 对齐)
# ===========================================================================

## 取某个地形名称的能力配置。
## 未列在表里的地形返回默认值(walkable=true,安全默认)。
static func get_terrain_capability(terrain_name: String) -> TerrainCapability:
	_ensure_cache()
	var cap: Variant = _terrain_capability_cache.get(terrain_name)
	if cap == null:
		return TerrainCapability.new()
	return cap


## 判定某个 tile 类型是否可通行(客户端调试/可视化寻路用)。
## terrain_id 是 ChunkGenerator.get_tile_type_v3 返回值(int)。
## 未知 ID 默认 true(和服务端一致,安全默认)。
## 注意:寻路权威在服务端,客户端这个 API 仅用于调试可视化或预测显示。
static func is_walkable(terrain_id: int) -> bool:
	_ensure_cache()
	var terrain_name: String = _TERRAIN_ID_TO_NAME.get(terrain_id, "")
	if terrain_name == "":
		push_warning("is_walkable 收到未知 terrain_id=%d,默认返回 true" % terrain_id)
		return true
	var cap: TerrainCapability = _terrain_capability_cache.get(terrain_name)
	if cap == null:
		return true  # 未配置的地形默认可通行
	return cap.walkable


# ===========================================================================
# 视野(视锥)API(和服务端 config_loader.get_vision 对称)
# ===========================================================================

## 取敌人视野(视锥)配置。
## mode: "normal"(常态:除 chase 外的所有 AI 状态,如 patrol/look_around/attack)/
##        "chase"(追逐态,窄而远)。未知 mode 回退 normal(安全默认)。
## 返回 VisionInfo(half_angle 弧度 / radius 像素)。VisionFan 渲染视锥用。
static func get_vision(mode: String = "normal") -> VisionInfo:
	_ensure_cache()
	var vision: Variant = _vision_cache.get(mode)
	if vision == null:
		vision = _vision_cache.get("normal")
	if vision == null:
		return VisionInfo.new()
	return vision


## 敌人视锥功能总开关(shared_config/constants.json 的 VISION_ENABLED)。
## 默认 true(配置缺失时按开启处理,保持既有行为)。
## 关闭后:服务端敌人无视视锥追击最近玩家,客户端不挂载/不渲染视锥扇形
## (Role._setup_enemy 据此跳过 VisionFan 挂载,避免显示误导)。
static func is_vision_enabled() -> bool:
	_ensure_cache()
	return bool(_constants_cache.get("VISION_ENABLED", true))
