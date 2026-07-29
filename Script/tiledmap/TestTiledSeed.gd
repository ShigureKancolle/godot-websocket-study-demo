extends Node

var mycell_scroll_list: TiledCellList = null
var cell_patch: Dictionary = {}
var last_draw_tile_pos = null
var SAND_ATLAS = [
	Vector2i(5, 10), Vector2i(6, 10)
]
@onready var _tile_map_layer: TileMapLayer = $Grass

# 鼠标悬停时显示当前 cell 坐标的 Label（懒创建）
# 加在 TileMapLayer 下，位置跟随世界，相机移动也会跟着走
var _hover_label: Label

# ===========================================================================
# 经典样式展示
# ===========================================================================
# 在 TileMapLayer 上画出几种经典的草地-沙地过渡形态，验证贴图配置
# 每个样式 = 1 个中心草地 block + 周围按 form8 放沙地 block
var _v3_grass_forms: Dictionary = {}
var _v3_alt_cache: Dictionary = {}
const _BLOCK_SIZE: int = 2

# Debug 工具：tile 坐标 → TiledCell 映射，鼠标悬停时查表显示
var _tile_info_map: Dictionary = {}

func _ready() -> void:
	mycell_scroll_list = $DebugUI/CellSelectScroll2
	$DebugUI/DebugDrawButton.pressed.connect(_on_debug_draw)
	_ensure_hover_label()
	# 启动时直接展示经典样式（草地+沙地过渡贴图）
	_show_v3_samples()


## 展示经典草地-沙地过渡样式
## 每个样式占 6×6 tile（3×3 block），水平间隔 4 tile
func _show_v3_samples() -> void:
	_tile_map_layer.clear()
	cell_patch = {}
	_tile_info_map.clear()

	# 初始化配置（复用 InfiniteTileMap 的 static 函数）
	var tiled: Dictionary = InfiniteTileMap._init_grass_forms_tiled()
	_v3_grass_forms = InfiniteTileMap._init_grass_forms(tiled)

	# 经典 form8 列表（旋转归一化后的值）
	# 0=全草地, 1=单边, 2=单角, 5=两边L, 10=两角对, 21=三边, 42=三角, 85=四边, 170=四角
	var samples: Array = [0, 1, 2, 5, 10, 21, 42, 85, 170]

	# 每个样式水平排列，间距 10 tile（5 block）
	var sample_stride_tile: int = 10

	for i in range(samples.size()):
		var form8: int = samples[i]
		var base_tile_x: int = i * sample_stride_tile
		var base_tile_y: int = 0
		_draw_sample_form(form8, base_tile_x, base_tile_y)

	# 旋转测试：9 种 form 水平排列，4 行对应旋转 0/1/2/3 次
	_show_rotation_test()


## 旋转测试：每行一个旋转角度（0/1/2/3），9 种 form 水平排列
## 布局和 samples 一样，方便对比
func _show_rotation_test() -> void:
	var forms: Array = [0, 1, 2, 5, 10, 21, 42, 85, 170]
	var sand_atlas: Vector2i = InfiniteTileMap._TERRAIN_ATLAS[ChunkGenerator.TerrainType.SAND]

	# 起始 y（在 samples 下方留空 1 行）
	var start_y: int = 10
	# 每行间距和 samples 一样 10 tile
	var row_stride: int = 10

	var offsets: Array = [
		Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
		Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1),
	]

	for row in range(4):  # 4 行对应 0/1/2/3 次旋转
		var rotations: int = row
		for col in range(forms.size()):
			var base_form: int = forms[col]
			var mtc_base: MyTiledCell = _v3_grass_forms.get(base_form, null)
			if mtc_base == null:
				continue

			var mtc: MyTiledCell = mtc_base
			if rotations > 0:
				mtc = InfiniteTileMap._rotate_my_tiled_cell(mtc_base, rotations)

			# 中心草地 block 的左上角 tile 坐标（和 samples 一样的水平间距）
			var bx: int = col * 5  # 10 tile / 2 = 5 block 间距
			var by: int = start_y + row * row_stride

			# 1. 画周围沙地 block：根据旋转后的 form8
			var form8: int = base_form
			for _i in range(rotations):
				form8 = InfiniteTileMap._rotate_form8_cw(form8)

			for i in range(8):
				if form8 & (1 << i):
					var sbx: int = bx + offsets[i].x
					var sby: int = by + offsets[i].y
					for dy in _BLOCK_SIZE:
						for dx in _BLOCK_SIZE:
							var cell_pos: Vector2i = Vector2i(sbx * _BLOCK_SIZE + dx, sby * _BLOCK_SIZE + dy)
							_tile_map_layer.set_cell(cell_pos, 0, sand_atlas)
							_tile_info_map[cell_pos] = TiledCell.new(sand_atlas, 0, 0)

			# 2. 画中心草地 block 的 4 个 tile
			for local_idx in range(4):
				var local_bx: int = local_idx % 2
				var local_by: int = local_idx / 2
				var wx: int = bx * _BLOCK_SIZE + local_bx
				var wy: int = by * _BLOCK_SIZE + local_by

				var candidates: Array = mtc.get_candidates(local_idx)
				var tc: TiledCell = InfiniteTileMap._pick_tiled_cell(candidates, wx, wy)

				var alt: int = _get_or_create_alt_tile(tc.assets_pos, tc.dir)
				var cell_pos2: Vector2i = Vector2i(wx, wy)
				_tile_map_layer.set_cell(cell_pos2, 0, tc.assets_pos, alt)
				_tile_info_map[cell_pos2] = tc


## 画一个经典样式
## form8: 中心草地 block 的 8 邻居掩码
## base_tile_x, base_tile_y: 中心草地 block 左上角 tile 的世界坐标
func _draw_sample_form(form8: int, base_tile_x: int, base_tile_y: int) -> void:
	var bx: int = base_tile_x / _BLOCK_SIZE
	var by: int = base_tile_y / _BLOCK_SIZE

	# 1. 放置周围的沙地 block（根据 form8 的 bit）
	# 8 邻居偏移（顺时针：上、右上、右、右下、下、左下、左、左上）
	var offsets: Array = [
		Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
		Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1),
	]
	var sand_atlas: Vector2i = InfiniteTileMap._TERRAIN_ATLAS[ChunkGenerator.TerrainType.SAND]
	for i in range(8):
		if form8 & (1 << i):
			var sbx: int = bx + offsets[i].x
			var sby: int = by + offsets[i].y
			for dy in _BLOCK_SIZE:
				for dx in _BLOCK_SIZE:
					var cell_pos: Vector2i = Vector2i(sbx * _BLOCK_SIZE + dx, sby * _BLOCK_SIZE + dy)
					_tile_map_layer.set_cell(cell_pos, 0, sand_atlas)
					# 沙地没有走 TiledCell 流程，记录一个简易信息便于 debug
					_tile_info_map[cell_pos] = TiledCell.new(sand_atlas, 0, 0)

	# 2. 放置中心草地 block（用渲染逻辑算贴图）
	# 算归一化
	var norm: Dictionary = InfiniteTileMap._normalize_form8(form8)
	var base_form: int = norm.form
	var rotations: int = norm.rotations

	# 查表（先查 8 邻居，没找到退化到 4 正方向）
	var mtc: MyTiledCell = _v3_grass_forms.get(base_form, null)
	if mtc == null:
		var form4: int = form8 & 0b01010101
		var norm4: Dictionary = InfiniteTileMap._normalize_form8(form4)
		mtc = _v3_grass_forms.get(norm4.form, null)
		rotations = norm4.rotations
	if mtc == null:
		mtc = _v3_grass_forms.get(0, null)
		rotations = 0
	if mtc == null:
		return

	# 旋转 MyTiledCell
	# 归一化时 form8 顺时针转 N 次得到 min_form，mtc 需顺时针转 (4-N) 次回到原方向
	if rotations > 0:
		mtc = InfiniteTileMap._rotate_my_tiled_cell(mtc, (4 - rotations) % 4)

	# 画 4 个 tile
	for local_idx in range(4):
		# 和 InfiniteTileMap 保持一致：local_idx = local_bx + local_by * 2
		# 0=TL, 1=TR, 2=BL, 3=BR
		var local_bx: int = local_idx % 2
		var local_by: int = local_idx / 2
		var wx: int = bx * _BLOCK_SIZE + local_bx
		var wy: int = by * _BLOCK_SIZE + local_by

		var candidates: Array = mtc.get_candidates(local_idx)
		var tc: TiledCell = InfiniteTileMap._pick_tiled_cell(candidates, wx, wy)

		var alt: int = _get_or_create_alt_tile(tc.assets_pos, tc.dir)
		var cell_pos2: Vector2i = Vector2i(wx, wy)
		_tile_map_layer.set_cell(cell_pos2, 0, tc.assets_pos, alt)
		_tile_info_map[cell_pos2] = tc


## 获取或创建 alternative_tile（旋转变体）
## 和 InfiniteTileMap._get_or_create_alt_tile 逻辑一致，但用 TestTiledSeed 自己的缓存
func _get_or_create_alt_tile(atlas_coord: Vector2i, dir: int) -> int:
	if dir == 0:
		return 0
	var key: Array = [atlas_coord.x, atlas_coord.y, dir]
	if _v3_alt_cache.has(key):
		return _v3_alt_cache[key]

	var tile_set: TileSet = _tile_map_layer.tile_set
	if tile_set == null:
		return 0
	var source: TileSetAtlasSource = tile_set.get_source(0)
	if not source.has_tile(atlas_coord):
		push_warning("[TestTiledSeed] atlas %s 处没有 base tile，无法创建旋转变体" % atlas_coord)
		return 0
	var alt_id: int = source.create_alternative_tile(atlas_coord)
	if alt_id < 0:
		return 0
	var tile_data: TileData = source.get_tile_data(atlas_coord, alt_id)
	if tile_data == null:
		return 0
	match dir:
		1:  # 90° CW = flip_h + transpose
			tile_data.flip_h = true
			tile_data.transpose = true
		2:  # 180° = flip_h + flip_v
			tile_data.flip_h = true
			tile_data.flip_v = true
		3:  # 270° CW = flip_v + transpose
			tile_data.flip_v = true
			tile_data.transpose = true
	_v3_alt_cache[key] = alt_id
	return alt_id

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
	_hover_label.size = Vector2(140, 56)
	_hover_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hover_label.visible = false
	# 加到 TileMapLayer 下，Label 的 position 直接用 map_to_local 的结果
	_tile_map_layer.add_child(_hover_label)

# 每帧检测鼠标所在的 cell；如果在 _tile_info_map 中就显示 TiledCell 信息
func _process(_delta: float) -> void:
	if _hover_label == null:
		return
	# 没有 tile 信息时直接隐藏
	if _tile_info_map.is_empty():
		_hover_label.visible = false
		return
	# get_local_mouse_position 返回鼠标相对 TileMapLayer 本地的位置
	var mouse_local: Vector2 = _tile_map_layer.get_local_mouse_position()
	# local_to_map：把本地像素坐标转成 cell 坐标（整数 Vector2i）
	var cell: Vector2i = _tile_map_layer.local_to_map(mouse_local)
	if _tile_info_map.has(cell):
		var tc: TiledCell = _tile_info_map[cell]
		var cell_center: Vector2 = _tile_map_layer.map_to_local(cell)
		# Label 显示在 cell 右下方，避免遮挡 tile 贴图
		_hover_label.position = cell_center - _hover_label.size * 0.5
		_hover_label.text = "(%d, %d)\natlas(%d,%d)\ndir=%d weight=%d" % [
			cell.x, cell.y, tc.assets_pos.x, tc.assets_pos.y, tc.dir, tc.weight,
		]
		_hover_label.visible = true
	else:
		_hover_label.visible = false

# 鼠标左键点击 TileMapLayer 时触发
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			# 复用 _process 里的坐标换算：本地像素 → cell 坐标
			var mouse_local: Vector2 = _tile_map_layer.get_local_mouse_position()
			var tile_pos: Vector2i = _tile_map_layer.local_to_map(mouse_local)

			_on_tile_clicked(tile_pos)
			# 标记事件已处理，防止继续冒泡到其他节点
			get_viewport().set_input_as_handled()

		elif event.button_index == MOUSE_BUTTON_RIGHT:
			# 复理右键点击事件
			mycell_scroll_list.clear_cur_select()

func _on_tile_clicked(tile_pos: Vector2i) -> void:
	print ("点击 tile 坐标: ", tile_pos)
	var tc: TiledCellList.tile_data = mycell_scroll_list.get_cur_select_tile_data()
	if tc == null:
		print("当前没有选中 tile 数据")
		return
	print("当前选中 tile 数据: ", tc.tiles[0].assets_pos)

	# 设置 tile_map_layer 的 cell
	# 把起始坐标归一到偶数
	var wx: int = tile_pos.x / 2 * 2
	var wy: int = tile_pos.y / 2 * 2
	for i in range(4):
		var cell_pos2: Vector2i = Vector2i(wx + i % 2, wy + i / 2)
		_tile_map_layer.set_cell(cell_pos2, 0, tc.tiles[i].assets_pos)
		_tile_info_map[cell_pos2] = tc.tiles[i]
	
	last_draw_tile_pos = Vector2i(wx, wy)

func _on_debug_draw() -> void:
	# 自适应最近画上的8格tile资源
	if last_draw_tile_pos == null:
		return

	# 获取最近画上的 2×2 block 的 9个格子的tile左上角 坐标
	var tile_pos: Vector2i = last_draw_tile_pos
	var from8: Array = [		
		Vector2i(0, -2),
		Vector2i(2, -2),
		Vector2i(2, 0),
		Vector2i(2, 2),
		Vector2i(0, 2),
		Vector2i(-2, 2),
		Vector2i(-2, 0),
		Vector2i(-2, -2),
		Vector2i.ZERO,
	]

	var block_vector: Array = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)
	]

	var pos_list: Array = []
	for i in from8:
		pos_list.append(tile_pos + i)

	# 根据这9个格子的tiledtype 刷新这9个格子的资源
	for pos in pos_list:
		var tc: TiledCell = _tile_info_map.get(pos, null)
		if tc == null:
			continue  
		var is_sand: bool = (tc.assets_pos in SAND_ATLAS)
		var block_type: int = ChunkGenerator.TerrainType.SAND if is_sand else ChunkGenerator.TerrainType.GRASS
		if is_sand:
			continue  # 沙地不需要刷新
		# 计算周围8个格子的掩码
		var from8_mask: int = 0
		for i in from8:
			if i == Vector2i.ZERO:
				continue
			var neighbor_pos: Vector2i = pos + i
			var neighbor_tc: TiledCell = _tile_info_map.get(neighbor_pos, null)
			if neighbor_tc == null:
				continue
			var neighbor_is_sand: bool = (neighbor_tc.assets_pos in SAND_ATLAS)
			if neighbor_is_sand:
				from8_mask |= (1 << from8.find(i))  # 计算掩码，正上方为bit0，顺时针

		# 对from8_mask归一化，获得最小值
		var result = null
		var norm: Dictionary = InfiniteTileMap._normalize_form8(from8_mask)
		var base_form: int = norm.form
		var rotations: int = norm.rotations
		var mtc: MyTiledCell = _v3_grass_forms.get(base_form, null)
		if mtc == null:
			# 退化：丢弃 4 个对角方向（bit 1/3/5/7），只保留 4 正方向（bit 0/2/4/6）
			# 例如 form 7（上+右上+右）退化成 form 5（上+右），用 2 边贴图近似 3 邻居情况
			var form4: int = from8_mask & 0b01010101
			var norm4: Dictionary = InfiniteTileMap._normalize_form8(form4)
			mtc = _v3_grass_forms.get(norm4.form, null)
			rotations = norm4.rotations
		if mtc == null:
			# fallback 到全草地
			mtc = _v3_grass_forms.get(0, null)
			rotations = 0
		if mtc == null:
			result = [
				{atlas = InfiniteTileMap._TERRAIN_ATLAS.get(ChunkGenerator.TerrainType.GRASS, Vector2i.ZERO), alt = 0},
				{atlas = InfiniteTileMap._TERRAIN_ATLAS.get(ChunkGenerator.TerrainType.GRASS, Vector2i.ZERO), alt = 0},
				{atlas = InfiniteTileMap._TERRAIN_ATLAS.get(ChunkGenerator.TerrainType.GRASS, Vector2i.ZERO), alt = 0},
				{atlas = InfiniteTileMap._TERRAIN_ATLAS.get(ChunkGenerator.TerrainType.GRASS, Vector2i.ZERO), alt = 0}
			]
		
		if result == null:
			result = []
			if rotations > 0:
				mtc = InfiniteTileMap._rotate_my_tiled_cell(mtc, (4 - rotations) % 4)
			# var bx = pos.x / _BLOCK_SIZE
			# var by = pos.y / _BLOCK_SIZE
			# var local_bx: int = pos.x - bx * _BLOCK_SIZE
			# var local_by: int = pos.y - by * _BLOCK_SIZE
			# var local_idx: int = local_bx + local_by * 2

			# 从候选数组按权重抽取 TiledCell
			
			for i in range(4):
				var local_idx: int = i
				var candidates: Array = mtc.get_candidates(local_idx)
				var _tc: TiledCell = InfiniteTileMap._pick_tiled_cell(candidates, pos.x, pos.y)

				# 获取或创建 alternative_tile（dir>0 时动态创建旋转变体）
				var alt: int = _get_or_create_alt_tile(_tc.assets_pos, _tc.dir)
				result.append({atlas = _tc.assets_pos, alt = alt})

		for i in range(4):
			var cell_pos: Vector2i = pos + block_vector[i]
			_tile_map_layer.set_cell(cell_pos, 0, result[i].atlas, result[i].alt)

		
