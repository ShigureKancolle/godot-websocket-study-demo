extends Node

var cell_patch: Dictionary = {}
@onready var _tile_map_layer: TileMapLayer = $TileMapLayer

var target_size: int
var origin_x: int
var origin_y: int
var seed_gx: int
var seed_gy: int
var terrain: int

# 鼠标悬停时显示当前 cell 坐标的 Label（懒创建）
# 加在 TileMapLayer 下，位置跟随世界，相机移动也会跟着走
var _hover_label: Label

func _ready() -> void:
	$DebugUI/DebugDrawButton.pressed.connect(_create_seed)
	$DebugUI/DebugDrawButton2.pressed.connect(_pre)
	$DebugUI/DebugDrawButton3.pressed.connect(_next)
	_ensure_hover_label()

# 创建用于显示坐标的 Label 子节点（只创建一次）
# 加阴影/对比色，保证在亮/暗地形上都能看清
func _ensure_hover_label() -> void:
	if _hover_label != null:
		return
	_hover_label = Label.new()
	_hover_label.add_theme_font_size_override("font_size", 10)
	# 字体本体用白色
	_hover_label.add_theme_color_override("font_color", Color.WHITE)
	# 描边用黑色，让文字在任何地形上都清晰
	_hover_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_hover_label.add_theme_constant_override("outline_size", 4)
	# 默认水平居中，方便用偏移定位到 cell 中心
	_hover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hover_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hover_label.size = Vector2(60, 14)
	_hover_label.visible = false
	# 加到 TileMapLayer 下，Label 的 position 直接用 map_to_local 的结果
	_tile_map_layer.add_child(_hover_label)

# 每帧检测鼠标所在的 cell；如果在 cell_patch 中就显示坐标，否则隐藏
# 这是“按需查询”模式：默认画面完全干净，只有鼠标悬停的 cell 才显示一个坐标
func _process(_delta: float) -> void:
	if _hover_label == null:
		return
	# 没有 patch 时直接隐藏，省得 Label 留在屏幕上
	if cell_patch.is_empty():
		_hover_label.visible = false
		return
	# get_local_mouse_position 返回鼠标相对 TileMapLayer 本地的位置
	# （已考虑相机变换和 TileMapLayer 自身的 transform）
	var mouse_local: Vector2 = _tile_map_layer.get_local_mouse_position()
	# local_to_map：把本地像素坐标转成 cell 坐标（整数 Vector2i）
	var cell: Vector2i = _tile_map_layer.local_to_map(mouse_local)
	if cell_patch.has(cell):
		# map_to_local 返回 cell 中心在 TileMapLayer 本地坐标系下的位置
		var cell_center: Vector2 = _tile_map_layer.map_to_local(cell)
		# Label size 是 60×14，居中放置就减去半个 size
		_hover_label.position = cell_center - _hover_label.size * 0.5
		_hover_label.text = "(%d, %d)" % [cell.x, cell.y]
		_hover_label.visible = true
	else:
		_hover_label.visible = false
	
func _create_seed():
	cur_growth_step = 0
	var result = _simulate_growth(0, 0, 1)
	cell_patch = result[0]
	target_size = result[1]
	origin_x = result[2]
	origin_y = result[3]
	seed_gx = result[4]
	seed_gy = result[5]
	terrain = result[6]
	_draw_patch()

func _pre():
	pass

func _next():
	if cur_growth_step >= MAX_GROWTH_STEPS:
		cell_patch = _trim_patch(cell_patch, 1)
	else:
		cell_patch = _grow_patch(cell_patch, target_size, origin_x, origin_y, seed_gx, seed_gy, 1)
		# 递增生长步数，对应 ChunkGenerator._simulate_growth 的 for step in range(MAX_GROWTH_STEPS)
		# 每次 _grow_patch 用 cur_growth_step 算 hash，必须每步 +1 才能和 ChunkGenerator 一致
		if cur_growth_step < MAX_GROWTH_STEPS:
			cur_growth_step += 1
	_draw_patch()

func _draw_patch():
	# 先清空整个 layer，否则 trim 删掉的 cell 仍会留在画面上看不到效果
	# patch 最多十几格，整层 clear + 重画开销可忽略
	_tile_map_layer.clear()
	for pos in cell_patch.keys():
		_tile_map_layer.set_cell(pos, 0, Vector2i(1, 10))


# V2 配置常量
var _seed = 123456
const SEED_GRID_SIZE: int = 8       # 种子粗网格大小（每 8×8 tile 一个候选点）
const SEED_CORE_SIZE: int = 2       # 种子核心大小（2×2 起步）
const SEED_ACTIVATION_RATE: float = 0.35  # 种子激活概率
const MAX_GROWTH_STEPS: int = 12    # 每个种子最多生长步数
var cur_growth_step: int = 0
const MAX_GROWTH_RADIUS: int = 2    # 生长范围（种子原点周围 ±2 tile，斑块最大 5×5）
const GROW_PROB: float = 0.7        # 每步生长概率（hash < 此值才尝试生长）
const SEED_MUTUAL_DIST: int = 7     # 异类种子最小距离 = 2*MAX_GROWTH_RADIUS + 3
const MIN_PATCH_SIZE: int = 4       # 斑块最小格子数（= 2×2 核心）
const MAX_PATCH_SIZE: int = 12      # 斑块最大格子数（5×5 区域内）

func _simulate_growth(seed_gx: int, seed_gy: int, terrain: int):
	var patch: Dictionary = {}
	var origin_x: int = seed_gx * SEED_GRID_SIZE
	var origin_y: int = seed_gy * SEED_GRID_SIZE

	# 1. 放 2×2 核心
	for dy in SEED_CORE_SIZE:
		for dx in SEED_CORE_SIZE:
			patch[Vector2i(origin_x + dx, origin_y + dy)] = terrain

	# 2. hash 决定目标格子数
	var size_hash: float = _hash_2d(_seed + 300, seed_gx, seed_gy)
	var target_size: int = MIN_PATCH_SIZE + int(size_hash * float(MAX_PATCH_SIZE - MIN_PATCH_SIZE + 1))
	if target_size > MAX_PATCH_SIZE:
		target_size = MAX_PATCH_SIZE

	return [patch, target_size, origin_x, origin_y, seed_gx, seed_gy, terrain]

func _grow_patch(patch: Dictionary, target_size: int, origin_x: int, origin_y: int, seed_gx: int, seed_gy: int, terrain: int) -> Dictionary:
	# 3. 生长到 target_size（不检查规则 B，直接放入）
	print("生长  cur_growth_step  ", cur_growth_step)
	if patch.size() >= target_size:
		cur_growth_step = MAX_GROWTH_STEPS
		return patch
	# 3.1 hash 决定是否继续生长
	var grow_hash: float = _hash_2d(_seed + 100, seed_gx * 1000 + cur_growth_step, seed_gy)
	if grow_hash >= GROW_PROB:
		return patch
	# 3.2 收集候选位置（patch 边界 tile 的空邻居，在生长范围内）
	var candidates: Array = []
	for pos in patch.keys():
		for ddy in range(-1, 2):
			for ddx in range(-1, 2):
				if ddx == 0 and ddy == 0:
					continue
				var npos: Vector2i = pos + Vector2i(ddx, ddy)
				if patch.has(npos):
					continue
				if max(abs(npos.x - origin_x), abs(npos.y - origin_y)) > MAX_GROWTH_RADIUS:
					continue
				if not candidates.has(npos):
					candidates.append(npos)
	if candidates.is_empty():
		cur_growth_step = MAX_GROWTH_STEPS
		return patch
	# 3.3 hash 决定选哪个候选，直接放入（不检查规则 B）
	var pick_hash: float = _hash_2d(_seed + 200, seed_gx * 1000 + cur_growth_step, seed_gy)
	var idx: int = int(pick_hash * float(candidates.size()))
	if idx >= candidates.size():
		idx = candidates.size() - 1
	patch[candidates[idx]] = terrain
	return patch

func _trim_patch(patch: Dictionary, terrain: int) -> Dictionary:
	# 4. 修剪：反复删除不满足规则 B 的 tile，直到所有剩余 tile 都满足	
	var to_remove: Array = []
	for pos in patch.keys():
		if not _check_rule_b(pos, terrain, patch):
			to_remove.append(pos)
			
	for pos in to_remove:
		print("修剪  pos",  pos)
		patch.erase(pos)			

	return patch	



static func _hash_2d(seed: int, x: int, y: int) -> float:
	# 每个乘法后立即掩码，防止 64 位溢出在 GDScript/Python 表现不同
	# GDScript int 是 64 位有符号，Python int 是任意精度
	# & 0xFFFFFFFF 在双端都把结果规范到 [0, 2^32-1]
	var h1: int = (seed * 73856093) & 0xFFFFFFFF
	var h2: int = (x * 19349663) & 0xFFFFFFFF
	var h3: int = (y * 83492791) & 0xFFFFFFFF
	var h: int = (h1 ^ h2 ^ h3) & 0xFFFFFFFF
	# MurmurHash3 finalizer：三轮 XOR-shift + 乘法，avalanche 打乱所有位
	h ^= h >> 16
	h = (h * 0x85EBCA6B) & 0xFFFFFFFF
	h ^= h >> 13
	h = (h * 0xC2B2AE35) & 0xFFFFFFFF
	h ^= h >> 16
	# 归一化到 [0, 1]。用 float(u32_max) 而非 4294967295.0 显得自解释
	return float(h) / float(0xFFFFFFFF)	


func _check_rule_b(pos: Vector2i, terrain: int, patch: Dictionary) -> bool:
	# 统计 8 邻域中同类的位置
	var same_neighbors: Array = []
	const offsets: Array = [
		Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
		Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1),
	]
	for off in offsets:
		var npos: Vector2i = pos + off
		if patch.has(npos):
			same_neighbors.append(off)

	# 规则 B：同类邻居 ≥3
	if same_neighbors.size() < 3:
		return false

	# 检查是否全在一条直线
	# 横线：所有邻居的 y 偏移都为 0（只有左/右）
	# 竖线：所有邻居的 x 偏移都为 0（只有上/下）
	# 斜线1：所有邻居 dx == dy（左上+右下方向）
	# 斜线2：所有邻居 dx == -dy（右上+左下方向）
	var all_horizontal: bool = true
	var all_vertical: bool = true
	var all_diag_down: bool = true
	var all_diag_up: bool = true
	for off in same_neighbors:
		if off.y != 0:
			all_horizontal = false
		if off.x != 0:
			all_vertical = false
		if off.x != off.y:
			all_diag_down = false
		if off.x != -off.y:
			all_diag_up = false
	# 全在一条直线 → 不满足规则 B
	if all_horizontal or all_vertical or all_diag_down or all_diag_up:
		return false
	return true
