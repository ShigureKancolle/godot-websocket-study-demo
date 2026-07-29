'''
文件: client/Script/tiledmap/InfiniteTileMap.gd
作用: 无限地图节点 —— 按 follow target 位置动态加载/卸载 chunk，调用 ChunkGenerator 生成 tile

============================================================================
 核心思路：Chunk-based Infinite Tilemap
============================================================================
"无限地图"的本质不是真的无限，而是【按需生成 + 按需卸载】：

    follow target 在某坐标
        ↓
    算出当前所在 chunk
        ↓
    生成周围 (2*load_radius+1)^2 个 chunk（若未生成）
        ↓
    卸载距离过远的 chunk

chunk 数据不存内存（TileMapLayer 已经存了 tile cell），
_loaded_chunks 只记录"哪些 chunk 坐标已加载"，是个位置集合。

============================================================================
 节点结构
============================================================================
    InfiniteTileMap (Node2D)  ← 本脚本
    └── TileMapLayer          ← 复用 TiledMap.tscn 里已有的，含 TileSet 资源

============================================================================
 接入方式
============================================================================
当前是独立调试模式：TiledMap.tscn 里有一个 DebugCursor 节点（箭头键控制），
作为 follow target 测试无限地图。

未来集成到 DeadManScene 时：
    var infinite_map = $InfiniteTileMap
    var local_role = _entities[ClientStateMirror.local_entity_id()]
    infinite_map.set_follow_target(local_role)

============================================================================
 架构位置（双端一致生成）
============================================================================
当前：纯客户端，seed 硬编码 = 12345
未来：服务器通过 MapInfo 消息下发 seed → 客户端调 setup(seed) → 双端一致生成
（详见 docs/client-ui.md 的"无限地图"章节）
'''

extends Node2D
class_name InfiniteTileMap


# ===========================================================================
# 配置常量
# ===========================================================================

# 地形类型 → atlas coord 映射（无过渡时的"纯地块"贴图，fallback 用）
# 用户确认过的坐标（从 Tileset.png 实际查看后调整）：
#   GRASS (4, 14) = 普通草地
#   SAND  (6, 10) = 普通沙地
#   DIRT  (1, 10) = 泥地（待确认）
#   BRICK (9, 10) = 砖地（待确认）
# atlas 布局：18 列 × 27 行，每个 tile 16×16 像素
const _TERRAIN_ATLAS: Dictionary = {
	ChunkGenerator.TerrainType.GRASS: Vector2i(4, 14),  # 普通草地
	ChunkGenerator.TerrainType.SAND: Vector2i(6, 10),   # 普通沙地（3×3 中心）
	ChunkGenerator.TerrainType.DIRT: Vector2i(1, 10),   # 泥地（占位）
	ChunkGenerator.TerrainType.BRICK: Vector2i(9, 10),  # 砖地（占位）
}

# 变体选择专用 hash seed。和地图 seed 分开（变体是纯渲染层的事）。
# 用固定值确保变体分布稳定，换地图 seed 不影响变体分布。
const _VARIANT_HASH_SEED: int = 98765

# ===========================================================================
# 2×2 block 渲染配置（草地过渡贴图系统）
# ===========================================================================
# 以 2×2 tile 的 block 为最小单位。草地 block 根据周围 8 邻居 block 类型
# 选择不同的 MyTiledCell（4 个 tile 的贴图组合），实现过渡效果。
#
# 草地形态查表 key = 8 位掩码（邻居是否非草地），旋转归一化后查 _GRASS_FORMS。
# 配置时只需定义基础形态（如"右边有沙地"），其他朝向（上/下/左）通过旋转派生。
#
# 8 位掩码 bit 顺序（顺时针，从上开始）：
#   bit 0=上 1=右上 2=右 3=右下 4=下 5=左下 6=左 7=左上
#   bit=1 表示该方向邻居是非草地（SAND）
#
# block 内位置编号（以左上角为原点）：
#   (0,0)=index 0  (0,1)=index 1
#   (1,0)=index 2  (1,1)=index 3
#
# ⚠️ 当前 _GRASS_FORMS 是占位配置（全用纯草地贴图）。
# 用户需要根据 Tileset.png 实际贴图配置每种形态的 4 个 tile。
# 缺失的形态会 fallback 到 form 0（全草地）。

# block 边长（tile 数），和 ChunkGenerator.BLOCK_SIZE 一致
const _BLOCK_SIZE: int = 2

# 草地形态表。key = 旋转归一化后的 8 位掩码，value = MyTiledCell
# 用户配置方式：
#   1. 先配 form 0（全草地，无 SAND 邻居）
#   2. 再配 form 1（上边 SAND）、form 3（上+右 SAND）等基础形态
#   3. 其他朝向通过旋转自动派生，无需配置
#   4. 缺失的 form 自动 fallback 到 form 0
#
# ⚠️ 不能用 const（MyTiledCell.new 是运行时构造），在 _ready 中由 _init_grass_forms 初始化
# 用户修改配置只需改 _init_grass_forms 函数内的 return 内容
var _GRASS_FORMS: Dictionary = {}

# 草地候选
# 其实有大量的重复配置 用8位掩码来表示
enum GRASS_MASKS {
	ALL_GRASS = 0b00000000,  # 全草地
	TOP_SAND = 0b00000001,   # 上边 SAND
	TOP_RIGHT_SAND = 0b00000101, # 上+右 SAND
	TOP_RIGHT_CORNER_SAND = 0b00000010, # 右上角 CORNER
}
var _grass_forms_tiled: Dictionary = {}

# 加载半径（chunk 数）。load_radius=3 → 加载 7×7=49 个 chunk
# 太小会看到边缘加载，太大会卡顿。3 是 2D 游戏常见值
const LOAD_RADIUS: int = 3

# 调试用：是否每帧打印 chunk 加载/卸载日志（验证逻辑时打开，正常游戏关闭）
const DEBUG_LOG: bool = true


# ===========================================================================
# 运行时状态
# ===========================================================================

# TileMapLayer 引用（@onready 确保场景树就绪后获取）
@onready var _tile_map_layer: TileMapLayer = $TileMapLayer

# 区块生成器（纯函数，持有 seed）
var _generator: ChunkGenerator = null

# 已加载 chunk 集合：Vector2i(chunk_x, chunk_y) -> true
# 用于快速判断哪些 chunk 已加载
var _loaded_chunks: Dictionary = {}

# chunk 类型数据缓存：Vector2i(chunk_x, chunk_y) -> PackedInt32Array
# 存每个已加载 chunk 的 tile 类型数据（ChunkGenerator 输出），用于：
#   1. 计算 tile 过渡形态时查邻居类型（跨 chunk 查询）
#   2. 卸载 chunk 后邻居 tile 过渡刷新仍能查到（直到本 chunk 被清出 cache）
# 加载 chunk 时写入，卸载 chunk 时清除
var _chunk_data_cache: Dictionary = {}

# 跟随目标（玩家 Role 或调试 cursor）。null 时静止在原点
var _follow_target: Node2D = null

# tile 像素大小（从 TileSet 读取，默认 16）
var _tile_size: int = 16

# 调试绘制开关：开启后 _draw 会画出每个已加载 chunk 的矩形边框 + chunk 坐标文字
# 由 DebugUI/DebugDrawButton 按钮切换
var _debug_draw: bool = false

# alternative_tile 缓存。key=(atlas_x, atlas_y, dir), value=alt_id
# 运行时动态创建旋转变体（dir 0/1/2/3 = 0°/90°/180°/270°），
# 避免用户在 TileSet 编辑器中手动创建旋转变体。
# dir=0 用默认 alt_id=0，dir>0 调 create_alternative_tile 创建。
var _alt_tile_cache: Dictionary = {}

# ===========================================================================
# 分帧加载配置（异步优化）
# ===========================================================================
# 移动时跨 chunk 边界会一次性需要加载多个 chunk（沿移动方向的整列/行）。
# 同步加载导致掉帧。改为分帧加载：每帧只处理 N 个，把卡顿分摊到多帧。
#
# _pending_loads: 待加载队列（按到 follow target 的距离排序，近的优先）
# _pending_unloads: 待卸载队列（卸载开销小，但也分帧避免单帧毛刺）
# MAX_LOADS_PER_FRAME: 每帧最大加载数（1-2 平衡帧率和加载速度）
# MAX_UNLOADS_PER_FRAME: 每帧最大卸载数（卸载比加载快，可以多些）
var _pending_loads: Array[Vector2i] = []
var _pending_unloads: Array[Vector2i] = []
const MAX_LOADS_PER_FRAME: int = 2
const MAX_UNLOADS_PER_FRAME: int = 4


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	# 当前阶段：纯客户端硬编码 seed。未来接服务器后改为：
	#   func setup(seed: int):
	#       _generator = ChunkGenerator.new(seed)
	#       _update_chunks_around(_world_to_chunk(_get_center_pos()))
	_generator = ChunkGenerator.new(12345)
	# 初始化草地形态表（含 MyTiledCell.new，不能放在 const）
	# 顺序：先 _grass_forms_tiled（被 _init_grass_forms 引用），再 _GRASS_FORMS
	_grass_forms_tiled = _init_grass_forms_tiled()
	_GRASS_FORMS = _init_grass_forms(_grass_forms_tiled)

	# 从 TileSet 读取 tile 像素大小（确保和 Tileset.png 的实际切分一致）
	if _tile_map_layer.tile_set != null:
		_tile_size = _tile_map_layer.tile_set.tile_size.x

	# 调试绘制浮在 tile 之上：TileMapLayer 是子节点，默认绘制在父节点 _draw 之后，
	# 会盖住调试内容。把 TileMapLayer 的 z_index 设为 -1（z_as_relative=false），
	# 让它在 InfiniteTileMap（z=0）之下绘制，调试内容就画在 tile 上面
	_tile_map_layer.z_index = -1
	_tile_map_layer.z_as_relative = false

	# 调试模式：如果场景里有 DebugCursor 子节点，自动设为 follow target
	# 这样 TiledMap.tscn 独立运行时能直接测试无限地图
	# 集成到 DeadManScene 时，外部会显式调 set_follow_target(role) 覆盖这个设置
	var cursor: Node = get_node_or_null("DebugCursor")
	if cursor != null:
		set_follow_target(cursor)

	# 连接调试绘制按钮（在 DebugUI CanvasLayer 里，不跟随相机移动）
	# 按钮点击切换 _debug_draw，_draw 画出 chunk 矩形 + 坐标
	var draw_btn: Node = get_node_or_null("DebugUI/DebugDrawButton")
	if draw_btn != null:
		draw_btn.pressed.connect(_on_debug_draw_toggled)
		_update_debug_button_text(draw_btn)

	# 启动时立即加载原点周围的 chunk（否则第一帧前是空的）
	_update_chunks_around(_world_to_chunk(_get_center_pos()))


func _process(_delta: float) -> void:
	# 每帧检查 follow target 位置，更新待加载/卸载队列
	var center_chunk: Vector2i = _world_to_chunk(_get_center_pos())
	_update_chunks_around(center_chunk)
	# 分帧处理队列：每帧加载/卸载少量 chunk，避免单帧卡顿
	_process_pending_chunks()


## 调试绘制：画出每个已加载 chunk 的矩形边框 + chunk 坐标文字
## 仅当 _debug_draw=true 时绘制。chunk 变化时通过 queue_redraw() 触发重绘
##
## 绘制内容：
##   - 红色矩形边框：chunk 在世界空间的范围
##   - 黄色文字 "chunk(cx, cy)"：chunk 左上角
##
## 为什么用 _draw 而非单独的 Line2D/Label 节点：
##   - chunk 数量动态变化（加载/卸载），用节点要频繁增删
##   - _draw 一次性画完，性能好且代码简单
##   - 调试功能不需要节点树的灵活性
func _draw() -> void:
	if not _debug_draw:
		return

	# 获取默认字体
	# Node2D 没有主题系统（get_theme_default_font 是 Control 的方法），
	# 用 ThemeDB 单例拿 fallback 字体
	# draw_string 必须传 Font，否则不画文字
	var font: Font = ThemeDB.fallback_font
	if font == null:
		push_warning("[InfiniteTileMap] 无法获取默认字体，跳过 chunk 文字绘制")
		return

	# chunk 在世界空间的像素大小
	var chunk_pixel_size: float = ChunkGenerator.CHUNK_SIZE * _tile_size
	# 防御：_tile_size 若为 0（TileSet 尚未就绪或读取失败），矩形会退化成一点
	# 此时用默认 16 兜底，至少能看到边框
	if chunk_pixel_size <= 0.0:
		chunk_pixel_size = ChunkGenerator.CHUNK_SIZE * 16.0
		push_warning("[InfiniteTileMap] _tile_size 为 0，调试绘制用默认 16 兜底")

	# 矩形边框颜色（半透明红色，不填充只画边）
	var rect_color: Color = Color(1.0, 0.0, 0.0, 0.8)
	# 文字颜色（黄色，在大多数地形上都显眼）
	var text_color: Color = Color(1.0, 0.9, 0.2, 1.0)
	# 文字字号
	var font_size: int = 14

	for chunk: Vector2i in _loaded_chunks.keys():
		# chunk 原点世界坐标（像素）
		var origin: Vector2 = Vector2(
			chunk.x * chunk_pixel_size,
			chunk.y * chunk_pixel_size
		)
		# 画矩形边框（filled=false, 边宽=2px）
		var rect: Rect2 = Rect2(origin, Vector2(chunk_pixel_size, chunk_pixel_size))
		draw_rect(rect, rect_color, false, 2.0)
		# 画 chunk 坐标文字（左上角偏移 4px, 16px 让文字在框内）
		var text: String = "chunk(%d, %d)" % [chunk.x, chunk.y]
		draw_string(font, origin + Vector2(4, 16), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)


# ===========================================================================
# 对外接口
# ===========================================================================

## 设置跟随目标。传入玩家 Role 或调试 cursor 节点。
## 传入后，_process 会自动跟随它的 global_position 加载/卸载 chunk。
func set_follow_target(node: Node2D) -> void:
	_follow_target = node


## 设置调试绘制开关。开启后画 chunk 矩形 + 坐标文字
func set_debug_draw(enabled: bool) -> void:
	_debug_draw = enabled
	queue_redraw()


## 调试绘制按钮的点击处理：切换 _debug_draw 并更新按钮文字
func _on_debug_draw_toggled() -> void:
	set_debug_draw(not _debug_draw)
	var btn: Node = get_node_or_null("DebugUI/DebugDrawButton")
	if btn != null:
		_update_debug_button_text(btn)


## 更新调试按钮文字，反映当前开关状态
func _update_debug_button_text(btn: Node) -> void:
	btn.text = "调试边框: " + ("开" if _debug_draw else "关")


# ===========================================================================
# 内部：坐标转换
# ===========================================================================

## 获取当前中心点世界坐标
## 有 follow target 时跟随它，否则静止在原点（便于独立调试空场景）
func _get_center_pos() -> Vector2:
	if _follow_target != null and is_instance_valid(_follow_target):
		return _follow_target.global_position
	return Vector2.ZERO


## 世界坐标 → chunk 坐标
## 步骤：世界像素 → tile 坐标 → chunk 坐标
##
## 为什么用 floor 而非 int：
##   - int() 是向零取整，对负数会出错（如 int(-1.5)=-1，但负坐标应进 -2 chunk）
##   - floor 配合 int 保证双端一致（Python 端用 math.floor + int）
func _world_to_chunk(world_pos: Vector2) -> Vector2i:
	var tile_x: int = int(floor(world_pos.x / _tile_size))
	var tile_y: int = int(floor(world_pos.y / _tile_size))
	return Vector2i(
		int(floor(float(tile_x) / ChunkGenerator.CHUNK_SIZE)),
		int(floor(float(tile_y) / ChunkGenerator.CHUNK_SIZE))
	)


# ===========================================================================
# 内部：chunk 加载/卸载
# ===========================================================================

## 增量更新：更新待加载/卸载队列（不实际加载，由 _process 分帧处理）
##
## 算法：
##   1. 算出 load_radius 范围内的所有 chunk 坐标 → needed 集合
##   2. needed 里有但 _loaded_chunks 里没有的 → 加入 _pending_loads
##   3. _loaded_chunks 里有但 needed 里没有的 → 加入 _pending_unloads
##
## 为什么用队列而非立即加载：
##   移动时跨 chunk 边界会一次性需要加载多个 chunk（沿移动方向的整列/行）。
##   同步加载导致掉帧。改为分帧：本方法只更新队列，_process 每帧处理 N 个。
##
## 为什么不需要刷新邻居：
##   地形是 seed 确定的纯函数。加载/卸载 chunk A 不改变邻居边缘 tile 的
##   过渡形态 —— 因为 A 的数据无论走 cache 还是单点查询结果都一样。
##   所以加载/卸载都是独立的，不需要联动刷新。
func _update_chunks_around(center: Vector2i) -> void:
	# 1. 算出需要的 chunk 集合
	var needed: Dictionary = {}
	for dy in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
		for dx in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
			needed[Vector2i(center.x + dx, center.y + dy)] = true

	# 2. 收集待加载 chunk（needed 里有的，但还没加载也没在队列里的）
	# 按到 center 的距离排序，近的优先（玩家视野中心先出现）
	var new_loads: Array = []
	for chunk in needed.keys():
		if not _loaded_chunks.has(chunk) and not _pending_loads.has(chunk):
			var dx: int = chunk.x - center.x
			var dy: int = chunk.y - center.y
			var dist: int = dx * dx + dy * dy
			new_loads.append({chunk = chunk, dist = dist})
	new_loads.sort_custom(func(a, b): return a.dist < b.dist)
	_pending_loads.clear()
	for entry in new_loads:
		_pending_loads.append(entry.chunk)

	# 3. 收集待卸载 chunk（已加载或在加载队列里，但不在 needed 里的）
	# 注意：遍历 _loaded_chunks 时不能直接 erase，先收集
	_pending_unloads.clear()
	for chunk in _loaded_chunks.keys():
		if not needed.has(chunk):
			_pending_unloads.append(chunk)
	# 加载队列里也不再需要的，移除（避免加载后又立刻卸载）
	var filtered_loads: Array[Vector2i] = []
	for chunk in _pending_loads:
		if needed.has(chunk):
			filtered_loads.append(chunk)
	_pending_loads = filtered_loads


## 每帧处理待加载/卸载队列（分帧加载的核心）
## 每帧最多加载 MAX_LOADS_PER_FRAME 个，卸载 MAX_UNLOADS_PER_FRAME 个
## 把单帧卡顿分摊到多帧，避免移动时掉帧
func _process_pending_chunks() -> void:
	# 1. 卸载（开销小，先处理释放资源）
	var unloaded_count: int = 0
	while unloaded_count < MAX_UNLOADS_PER_FRAME and _pending_unloads.size() > 0:
		var chunk: Vector2i = _pending_unloads.pop_front()
		if _loaded_chunks.has(chunk):
			_unload_chunk(chunk)
			unloaded_count += 1

	# 2. 加载（开销大，限制每帧数量）
	var loaded_count: int = 0
	while loaded_count < MAX_LOADS_PER_FRAME and _pending_loads.size() > 0:
		var chunk: Vector2i = _pending_loads.pop_front()
		if not _loaded_chunks.has(chunk):
			_load_chunk(chunk)
			loaded_count += 1

	# 3. 有变化时触发调试边框重绘
	if loaded_count > 0 or unloaded_count > 0:
		queue_redraw()


## 加载单个 chunk：生成数据 → 写入 cache → 用过渡 atlas coord 设 cell
##
## 关键步骤：
##   1. 生成 chunk 类型数据，写入 _chunk_data_cache（供邻居查询加速）
##   2. 对每个 tile，查 8 邻居类型 → 算过渡形态 → 查 atlas coord
##   3. set_cell 写入 TileMapLayer
##
## 为什么加载后不需要刷新邻居边缘：
##   地形是 seed 确定的纯函数。邻居 B 边缘 tile 在 A 加载前查 A 方向邻居
##   走 get_tile_type_v3 单点查询，A 加载后走 cache —— 两者结果必然相同
##   （generate_chunk_v3 内部就是调 get_tile_type_v3）。所以加载 A 不改变
##   任何 tile 的过渡形态，刷新邻居是纯浪费。
func _load_chunk(chunk: Vector2i) -> void:
	# 1. 生成数据并写入 cache
	var data: PackedInt32Array = _generator.generate_chunk_v3(chunk.x, chunk.y)
	_chunk_data_cache[chunk] = data

	# 2. 对每个 tile 算过渡形态并设 cell
	# source_id = 0（TileSet 里只有一个 TileSetAtlasSource）
	var source_id: int = 0
	for ly in ChunkGenerator.CHUNK_SIZE:
		for lx in ChunkGenerator.CHUNK_SIZE:
			var tile_x: int = chunk.x * ChunkGenerator.CHUNK_SIZE + lx
			var tile_y: int = chunk.y * ChunkGenerator.CHUNK_SIZE + ly
			var result: Dictionary = _compute_tile_atlas_v3(tile_x, tile_y, data, ly, lx)
			_tile_map_layer.set_cell(Vector2i(tile_x, tile_y), source_id, result.atlas, result.alt)

	_loaded_chunks[chunk] = true
	if DEBUG_LOG:
		print("[InfiniteTileMap] 加载 chunk ", chunk)


## 卸载单个 chunk：清除 cache + 清除 tile cell
##
## 为什么卸载后不需要刷新邻居边缘：
##   同 _load_chunk 的理由。邻居 B 边缘 tile 查 A 方向邻居，
##   卸载前走 cache，卸载后走 get_tile_type_v3 —— 结果必然相同。
##   地形永远不变，卸载后回来重新加载还是同样的 tile。
func _unload_chunk(chunk: Vector2i) -> void:
	# 1. 清除 tile cell
	for ly in ChunkGenerator.CHUNK_SIZE:
		for lx in ChunkGenerator.CHUNK_SIZE:
			var tile_x: int = chunk.x * ChunkGenerator.CHUNK_SIZE + lx
			var tile_y: int = chunk.y * ChunkGenerator.CHUNK_SIZE + ly
			# source_id = -1 表示清除该 cell
			_tile_map_layer.set_cell(Vector2i(tile_x, tile_y), -1)

	# 2. 清除 cache（后续邻居查询走单点查询，结果相同）
	_chunk_data_cache.erase(chunk)
	_loaded_chunks.erase(chunk)
	if DEBUG_LOG:
		print("[InfiniteTileMap] 卸载 chunk ", chunk)


# ===========================================================================
# 内部：tile 类型查询 + 过渡形态计算
# ===========================================================================

## 获取世界 tile 坐标处的地形类型
## 跨 chunk 查询：
##   - chunk 已加载 → 从 _chunk_data_cache 取（快，数组索引）
##   - chunk 未加载 → 直接调 _generator.get_tile_type_v3 单点查询
##
## 为什么不调 generate_chunk_v3 临时生成整个 chunk：
##   之前版本这样做，导致性能爆炸：
##     - 每个 tile 查 8 邻居 → 8 次 _get_tile_type_at
##     - 未命中 cache 时 generate_chunk_v3 生成 256 个 tile 数据
##     - 但只用其中 1 个 → 浪费 255 次计算
##     - 49 chunk 加载 → 上亿次 hash+noise 调用，编辑器卡死
##   改成单点查询 get_tile_type_v3(wx, wy)：
##     - 只算需要的那个 tile
##     - 开销 = 1 次 hash+noise per tile，可接受
func _get_tile_type_at(world_tile_x: int, world_tile_y: int) -> int:
	var chunk_x: int = int(floor(float(world_tile_x) / ChunkGenerator.CHUNK_SIZE))
	var chunk_y: int = int(floor(float(world_tile_y) / ChunkGenerator.CHUNK_SIZE))
	var chunk_key: Vector2i = Vector2i(chunk_x, chunk_y)

	if _chunk_data_cache.has(chunk_key):
		# cache 命中：已加载的 chunk，用数组索引（快）
		var data: PackedInt32Array = _chunk_data_cache[chunk_key]
		var lx: int = world_tile_x - chunk_x * ChunkGenerator.CHUNK_SIZE
		var ly: int = world_tile_y - chunk_y * ChunkGenerator.CHUNK_SIZE
		return data[ly * ChunkGenerator.CHUNK_SIZE + lx]
	# cache 未命中：单点查询（不生成整个 chunk）
	return _generator.get_tile_type_v3(world_tile_x, world_tile_y)


# ===========================================================================
# 2×2 block 渲染（草地过渡贴图系统）
# ===========================================================================
# 渲染流程：
#   1. 非草地 tile（SAND 等）→ 用 _TERRAIN_ATLAS 默认贴图
#   2. 草地 tile → 查 block 的 8 邻居类型 → 算 form8 → 旋转归一化
#      → 查 _GRASS_FORMS 得 MyTiledCell → 旋转 → 按 block 内位置抽 TiledCell
#      → 获取 alternative_tile（含旋转） → 返回 {atlas, alt}
#
# 旋转系统（减少配置量）：
#   - 8 位掩码旋转归一化：form 旋转 0/1/2/3 次取最小值作为查表 key
#   - MyTiledCell 整体旋转：4 个 cell 位置重排 + 每个 TiledCell 的 dir +1
#   - alternative_tile 动态创建：dir>0 时调 create_alternative_tile 设置 flip/transpose

## 初始化纯草地候选 TiledCell 数组
## 这是 form 0（全草地）的几十个变体，也是任何"非过渡位置"的默认候选。
## 任何需要纯草地贴图的位置都引用此数组，避免重复配置。
## 旋转时 _rotate_tiled_cells_cw 创建新数组，不修改原数组，共享引用安全。
##
## 用户配置方式：在此函数的 return 内增删 TiledCell。
static func _init_grass_forms_tiled() -> Dictionary:
	var res = {
		GRASS_MASKS.ALL_GRASS: [
		TiledCell.new(Vector2i(3, 20), 0, 300),
		TiledCell.new(Vector2i(3, 20), 1, 300),
		TiledCell.new(Vector2i(3, 20), 2, 300),
		TiledCell.new(Vector2i(3, 20), 3, 300),
		TiledCell.new(Vector2i(4, 20), 0, 50),
		TiledCell.new(Vector2i(4, 20), 1, 50),
		TiledCell.new(Vector2i(4, 20), 2, 50),
		TiledCell.new(Vector2i(4, 20), 3, 50),
		TiledCell.new(Vector2i(5, 20), 0, 50),
		TiledCell.new(Vector2i(5, 20), 1, 50),
		TiledCell.new(Vector2i(5, 20), 2, 50),
		TiledCell.new(Vector2i(5, 20), 3, 50),
		TiledCell.new(Vector2i(6, 8), 0, 1),
		TiledCell.new(Vector2i(6, 8), 1, 1),
		TiledCell.new(Vector2i(6, 8), 2, 1),
		TiledCell.new(Vector2i(6, 8), 3, 1),
		TiledCell.new(Vector2i(7, 8), 0, 1),
		TiledCell.new(Vector2i(7, 8), 1, 1),
		TiledCell.new(Vector2i(7, 8), 2, 1),
		TiledCell.new(Vector2i(7, 8), 3, 1),
		TiledCell.new(Vector2i(8, 8), 0, 1),
		TiledCell.new(Vector2i(8, 8), 1, 1),
		TiledCell.new(Vector2i(8, 8), 2, 1),
		TiledCell.new(Vector2i(8, 8), 3, 1),
		TiledCell.new(Vector2i(9, 8), 0, 1),
		TiledCell.new(Vector2i(9, 8), 1, 1),
		TiledCell.new(Vector2i(9, 8), 2, 1),
		TiledCell.new(Vector2i(9, 8), 3, 1),
		TiledCell.new(Vector2i(10, 8), 0, 1),
		TiledCell.new(Vector2i(10, 8), 1, 1),
		TiledCell.new(Vector2i(10, 8), 2, 1),
		TiledCell.new(Vector2i(10, 8), 3, 1),
		TiledCell.new(Vector2i(11, 8), 0, 1),
		TiledCell.new(Vector2i(11, 8), 1, 1),
		TiledCell.new(Vector2i(11, 8), 2, 1),
		TiledCell.new(Vector2i(11, 8), 3, 1),
		],
		GRASS_MASKS.TOP_SAND: [
			TiledCell.new(Vector2i(5, 11), 0, 1), 
			TiledCell.new(Vector2i(6, 11), 0, 1), 
			# TiledCell.new(Vector2i(5, 9), 2, 1), 
			# TiledCell.new(Vector2i(6, 9), 2, 1),
			# TiledCell.new(Vector2i(4, 10), 1, 1),
			# TiledCell.new(Vector2i(7, 10), 3, 1),
		],
		GRASS_MASKS.TOP_RIGHT_SAND: [
			TiledCell.new(Vector2i(11, 6), 0, 1),
			# TiledCell.new(Vector2i(11, 7), 1, 1),
			# TiledCell.new(Vector2i(10, 7), 2, 1),
			# TiledCell.new(Vector2i(10, 6), 3, 1),
		],
		GRASS_MASKS.TOP_RIGHT_CORNER_SAND: [
			TiledCell.new(Vector2i(4, 11), 0, 1), 
			# TiledCell.new(Vector2i(7, 11), 1, 1), 
			# TiledCell.new(Vector2i(7, 9), 2, 1), 
			# TiledCell.new(Vector2i(4, 9), 3, 1),
		]
	}

	return res

static func _rotate_tiled_cell(p_tiled_cell: Array, step: int = 0) -> Array:
	# ⚠️ 不能用 duplicate(true)：RefCounted 对象只复制引用，修改 dir 会污染原对象
	# 必须创建新的 TiledCell 实例
	var result: Array = []
	for cell in p_tiled_cell:
		result.append(TiledCell.new(cell.assets_pos, (cell.dir + step) % 4, cell.weight))
	return result



## 初始化草地形态表
## 因为 MyTiledCell.new / TiledCell.new 是运行时构造，不能用在 const 赋值中，
## 所以用普通 var + _ready 调用此函数初始化。
##
## 用户配置方式：修改此函数内的 return 内容。
## - key = 旋转归一化后的 8 位掩码（邻居非草地 → bit=1）
## - value = MyTiledCell
## - 只需定义基础形态（如"上边 SAND"），其他朝向通过旋转自动派生
## - 缺失的 form 自动 fallback 到 form 0
## - 任何需要"纯草地"的位置直接引用 _grass_variants（form 0 的几十个变体）
static func _init_grass_forms(grass_forms_tiled: Dictionary) -> Dictionary:
	return {
		# form 0: 全草地（8 邻居都是草地）
		# 省略形式：4 个位置都用 _grass_variants（几十个变体）
		0: MyTiledCell.new(ChunkGenerator.TerrainType.GRASS, [grass_forms_tiled[GRASS_MASKS.ALL_GRASS]]),
		# form 1: 上边 SAND（归一化形态，右边/下边/左边的 SAND 通过旋转派生）
		# 上边 2 个 tile 需要草地→沙地过渡贴图，下边 2 个 tile 用纯草地
		# ⚠️ 占位值，用户替换为实际过渡贴图坐标
		1: MyTiledCell.new(ChunkGenerator.TerrainType.GRASS, [
			grass_forms_tiled[GRASS_MASKS.TOP_SAND],                          # (0,0) 上左：待配
			grass_forms_tiled[GRASS_MASKS.TOP_SAND],
			grass_forms_tiled[GRASS_MASKS.ALL_GRASS],                          # (1,0) 下左：复用纯草地变体
			grass_forms_tiled[GRASS_MASKS.ALL_GRASS],                          # (1,1) 下右：复用纯草地变体
		]),
		# form 2: 右上角 CORNER
		2: MyTiledCell.new(ChunkGenerator.TerrainType.GRASS, [
			grass_forms_tiled[GRASS_MASKS.ALL_GRASS],  # (0,0) 上左：待配
			grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND],  # (0,1) 上右：待配
			grass_forms_tiled[GRASS_MASKS.ALL_GRASS],                          # (1,0) 下左：复用纯草地变体
			grass_forms_tiled[GRASS_MASKS.ALL_GRASS],                          # (1,1) 下右：复用纯草地变体
		]),

		# 上+右
		5: MyTiledCell.new(ChunkGenerator.TerrainType.GRASS, [
			grass_forms_tiled[GRASS_MASKS.TOP_SAND],  # (0,0) 上左：待配
			grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_SAND],  # (0,1) 上右：待配
			grass_forms_tiled[GRASS_MASKS.ALL_GRASS],                          # (1,0) 下左：复用纯草地变体
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_SAND], 1),  # (1,1) 下右：待配
		]),

		# 上边 右下角
		9: MyTiledCell.new(ChunkGenerator.TerrainType.GRASS, [
			grass_forms_tiled[GRASS_MASKS.TOP_SAND],  # (0,0) 上左：待配
			grass_forms_tiled[GRASS_MASKS.TOP_SAND],  # (0,1) 上右：待配			                         
			grass_forms_tiled[GRASS_MASKS.ALL_GRASS], 
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND], 1), 
		]),

		#  右上 右下 两角沙
		10: MyTiledCell.new(ChunkGenerator.TerrainType.GRASS, [
			grass_forms_tiled[GRASS_MASKS.ALL_GRASS],
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND], 0),  # (0,0) 上左：待配
			grass_forms_tiled[GRASS_MASKS.ALL_GRASS],
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND], 1),
		]),
		# form  : 上 右 下 3边都是沙
		21: MyTiledCell.new(ChunkGenerator.TerrainType.GRASS, [
			grass_forms_tiled[GRASS_MASKS.TOP_SAND],
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_SAND], 0),
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_SAND], 2),
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_SAND], 1),
		]),

		# form  : 左下 右上 右下 3角都是沙
		42: MyTiledCell.new(ChunkGenerator.TerrainType.GRASS, [
			grass_forms_tiled[GRASS_MASKS.ALL_GRASS],
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND], 0),  # (0,0) 上左：待配
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND], 2),  # (0,1) 上右：待配
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND], 1),  # (1,1) 下右：待配
		]),

		# form  : 4角都是沙
		170: MyTiledCell.new(ChunkGenerator.TerrainType.GRASS, [
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND], 3),  # (0,0) 上左：待配
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND], 0),  # (0,1) 上右：待配
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND], 2),  # (1,0) 下左：待配
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_CORNER_SAND], 1),  # (1,1) 下右：待配
		]),

		# form  : 4边全是沙
		85: MyTiledCell.new(ChunkGenerator.TerrainType.GRASS, [
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_SAND], 3),
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_SAND], 0),
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_SAND], 2),
			_rotate_tiled_cell(grass_forms_tiled[GRASS_MASKS.TOP_RIGHT_SAND], 1),
		]),
	}


## 计算单个 tile 的 atlas coord + alternative_tile
## 返回 Dictionary {atlas: Vector2i, alt: int}
##
## 非草地 tile：用 _TERRAIN_ATLAS 默认贴图，alt=0
## 草地 tile：根据 block 8 邻居类型选 MyTiledCell，按权重抽 TiledCell
func _compute_tile_atlas_v3(world_tile_x: int, world_tile_y: int, data: PackedInt32Array, local_y: int, local_x: int) -> Dictionary:
	var CS: int = ChunkGenerator.CHUNK_SIZE
	var terrain: int = data[local_y * CS + local_x]

	# 非草地：用默认贴图（无过渡，无旋转）
	if terrain != ChunkGenerator.TerrainType.GRASS:
		var default_atlas: Vector2i = _TERRAIN_ATLAS.get(terrain, Vector2i.ZERO)
		return {atlas = default_atlas, alt = 0}

	# 草地：根据 block 8 邻居类型算形态
	var bx: int = int(floor(float(world_tile_x) / _BLOCK_SIZE))
	var by: int = int(floor(float(world_tile_y) / _BLOCK_SIZE))

	# 算 block 的 8 邻居掩码（邻居非草地 → bit=1）
	var form8: int = _compute_form8_for_block(bx, by)

	# 旋转归一化：取 4 次旋转中的最小值作为查表 key
	var norm: Dictionary = _normalize_form8(form8)
	var base_form: int = norm.form
	var rotations: int = norm.rotations

	# 查草地形态表（先查 8 邻居表，没找到退化到 4 正方向）
	var mtc: MyTiledCell = _GRASS_FORMS.get(base_form, null)
	if mtc == null:
		# 退化：丢弃 4 个对角方向（bit 1/3/5/7），只保留 4 正方向（bit 0/2/4/6）
		# 例如 form 7（上+右上+右）退化成 form 5（上+右），用 2 边贴图近似 3 邻居情况
		var form4: int = form8 & 0b01010101
		var norm4: Dictionary = _normalize_form8(form4)
		mtc = _GRASS_FORMS.get(norm4.form, null)
		rotations = norm4.rotations
	if mtc == null:
		# fallback 到全草地
		mtc = _GRASS_FORMS.get(0, null)
		rotations = 0
	if mtc == null:
		return {atlas = _TERRAIN_ATLAS.get(terrain, Vector2i.ZERO), alt = 0}

	# 旋转 MyTiledCell（整体旋转：位置重排 + dir+1）
	# 归一化时 form8 顺时针转 N 次得到 min_form，所以 mtc 需要顺时针转 (4-N) 次回到 form8 方向
	if rotations > 0:
		mtc = _rotate_my_tiled_cell(mtc, (4 - rotations) % 4)

	# 算 tile 在 block 内的局部位置 → index 0=TL, 1=TR, 2=BL, 3=BR
	var local_bx: int = world_tile_x - bx * _BLOCK_SIZE
	var local_by: int = world_tile_y - by * _BLOCK_SIZE
	var local_idx: int = local_bx + local_by * 2

	# 从候选数组按权重抽取 TiledCell
	var candidates: Array = mtc.get_candidates(local_idx)
	var tc: TiledCell = _pick_tiled_cell(candidates, world_tile_x, world_tile_y)

	# 获取或创建 alternative_tile（dir>0 时动态创建旋转变体）
	var alt: int = _get_or_create_alt_tile(tc.assets_pos, tc.dir)
	return {atlas = tc.assets_pos, alt = alt}


## 计算 block 的 8 邻居掩码
## bit 0=上 1=右上 2=右 3=右下 4=下 5=左下 6=左 7=左上
## bit=1 表示该方向邻居是非草地（非 GRASS）
func _compute_form8_for_block(block_x: int, block_y: int) -> int:
	# 8 邻居偏移（顺时针：上、右上、右、右下、下、左下、左、左上）
	const offsets: Array = [
		Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
		Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1),
	]
	var form: int = 0
	for i in range(8):
		var nx: int = block_x + offsets[i].x
		var ny: int = block_y + offsets[i].y
		var nt: int = _get_block_type_at(nx, ny)
		if nt != ChunkGenerator.TerrainType.GRASS:
			form |= (1 << i)
	return form


## 查询 block 类型（优先从 cache，否则单点查询）
func _get_block_type_at(block_x: int, block_y: int) -> int:
	# block 的世界 tile 坐标 = block * BLOCK_SIZE（取 block 左上角 tile）
	var wx: int = block_x * _BLOCK_SIZE
	var wy: int = block_y * _BLOCK_SIZE
	return _get_tile_type_at(wx, wy)


## 8 位掩码顺时针旋转 90°
## bit 映射：上(0)→右(2), 右上(1)→右下(3), 右(2)→下(4), 右下(3)→左下(5)
##           下(4)→左(6), 左下(5)→左上(7), 左(6)→上(0), 左上(7)→右上(1)
static func _rotate_form8_cw(form: int) -> int:
	var result: int = 0
	if form & (1 << 0): result |= (1 << 2)  # 上→右
	if form & (1 << 1): result |= (1 << 3)  # 右上→右下
	if form & (1 << 2): result |= (1 << 4)  # 右→下
	if form & (1 << 3): result |= (1 << 5)  # 右下→左下
	if form & (1 << 4): result |= (1 << 6)  # 下→左
	if form & (1 << 5): result |= (1 << 7)  # 左下→左上
	if form & (1 << 6): result |= (1 << 0)  # 左→上
	if form & (1 << 7): result |= (1 << 1)  # 左上→右上
	return result


## 旋转归一化 —— 取 4 次旋转中的最小值作为查表 key
## 返回 {form: int, rotations: int}
## form = 最小值（查表 key），rotations = 从原 form 旋转到最小值的次数
## 配置时只需定义最小值形态，其他朝向自动派生
static func _normalize_form8(form: int) -> Dictionary:
	var min_form: int = form
	var rotations: int = 0
	var current: int = form
	for i in range(1, 4):
		current = _rotate_form8_cw(current)
		if current < min_form:
			min_form = current
			rotations = i
	return {form = min_form, rotations = rotations}


## 旋转 MyTiledCell（整体旋转，Godot 式）
## 每次 90° 顺时针：
##   1. 4 个 cell 位置重排（旧(0,0)→新(0,1), 旧(0,1)→新(1,1), 旧(1,0)→新(0,0), 旧(1,1)→新(1,0)）
##   2. 每个 TiledCell 的 dir +1（mod 4）
## 省略形式（cell 长度 1）：4 个位置都一样，旋转后还是省略形式（只加 dir）
static func _rotate_my_tiled_cell(mtc: MyTiledCell, times: int) -> MyTiledCell:
	var result: MyTiledCell = mtc
	for _i in range(times):
		result = _rotate_my_tiled_cell_90(result)
	return result


static func _rotate_my_tiled_cell_90(mtc: MyTiledCell) -> MyTiledCell:
	# 省略形式（cell 长度 1）：4 个位置都一样，只加 dir
	if mtc.cell.size() == 1:
		var new_candidates: Array = _rotate_tiled_cells_cw(mtc.cell[0])
		return MyTiledCell.new(mtc.tiledtype, [new_candidates])

	# 完整形式（cell 长度 4）：位置重排 + dir+1
	# cell index: 0=TL(0,0), 1=TR(1,0), 2=BL(0,1), 3=BR(1,1)
	# 顺时针 90°：TL←BL, TR←TL, BL←BR, BR←TR
	# 新[0]=旧[2], 新[1]=旧[0], 新[2]=旧[3], 新[3]=旧[1]
	var new_cell: Array = [
		_rotate_tiled_cells_cw(mtc.cell[2]),
		_rotate_tiled_cells_cw(mtc.cell[0]),
		_rotate_tiled_cells_cw(mtc.cell[3]),
		_rotate_tiled_cells_cw(mtc.cell[1]),
	]
	return MyTiledCell.new(mtc.tiledtype, new_cell)


## 旋转候选 TiledCell 数组（每个 dir +1 mod 4）
static func _rotate_tiled_cells_cw(candidates: Array) -> Array:
	var result: Array = []
	for tc in candidates:
		result.append(TiledCell.new(tc.assets_pos, (tc.dir + 1) % 4, tc.weight))
	return result


## 按权重从候选 TiledCell 数组中抽取一个
## 用 _variant_hash 确保同一 tile 永远选同一个（移动时不跳变）
static func _pick_tiled_cell(candidates: Array, tile_x: int, tile_y: int) -> TiledCell:
	if candidates.is_empty():
		return TiledCell.new()
	if candidates.size() == 1:
		return candidates[0]

	var total_weight: int = 0
	for tc in candidates:
		total_weight += tc.weight
	if total_weight <= 0:
		return candidates[0]

	var h: float = _variant_hash(tile_x, tile_y)
	var target: int = int(h * total_weight)

	var acc: int = 0
	for tc in candidates:
		acc += tc.weight
		if target < acc:
			return tc
	return candidates.back()


## 获取或创建 alternative_tile（旋转变体）
## dir=0 → alt=0（默认，无变换）
## dir=1 → 90° CW = transpose + flip_h
## dir=2 → 180° = flip_h + flip_v
## dir=3 → 270° CW = transpose + flip_v
##
## 运行时动态创建，避免用户在 TileSet 编辑器中手动创建旋转变体。
func _get_or_create_alt_tile(atlas_coord: Vector2i, dir: int) -> int:
	if dir == 0:
		return 0
	var key: Array = [atlas_coord.x, atlas_coord.y, dir]
	if _alt_tile_cache.has(key):
		return _alt_tile_cache[key]

	var tile_set: TileSet = _tile_map_layer.tile_set
	if tile_set == null:
		push_warning("[InfiniteTileMap] TileSet 为 null，无法创建旋转变体")
		return 0
	var source: TileSetAtlasSource = tile_set.get_source(0)
	if not source.has_tile(atlas_coord):
		push_warning("[InfiniteTileMap] atlas %s 处没有 base tile，无法创建旋转变体" % atlas_coord)
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
	_alt_tile_cache[key] = alt_id
	return alt_id


## 变体专用 hash：比 ChunkGenerator._hash_2d 更强的随机分布
## 变体是纯渲染层，不需要双端一致（服务端不关心贴图），可以用强 hash
##
## 算法：MurmurHash3 finalizer（avalanche 函数）
##   1. 初始混合：x, y, seed 三个维度用黄金比例常数独立混合
##   2. MurmurHash3 finalizer 三轮：XOR-shift + 乘法，打乱所有位
##   3. 归一化到 [0, 1)
##
## avalanche 属性：输入差 1，输出约一半位翻转。相邻 tile 的 hash 值差异极大，
## 避免权重小的变体在空间上大片连续出现。
##
## 常数含义：
##   - 0x9E3779B9 = 2^32 / 黄金比例（hash 常用初始混合常数）
##   - 0x85EBCA77 / 0x85EBCA6B / 0xC2B2AE35 = MurmurHash3 finalizer 乘法常数
static func _variant_hash(tile_x: int, tile_y: int) -> float:
	# 初始混合：x, y, seed 各自乘黄金比例常数后相加，三维独立影响
	var h: int = ((tile_x & 0xFFFFFFFF) * 0x9E3779B9) & 0xFFFFFFFF
	var hy: int = ((tile_y & 0xFFFFFFFF) * 0x85EBCA77) & 0xFFFFFFFF
	h = (h + hy) & 0xFFFFFFFF
	h = (h ^ _VARIANT_HASH_SEED) & 0xFFFFFFFF
	# MurmurHash3 finalizer：三轮 XOR-shift + 乘法，avalanche 打乱
	h ^= h >> 16
	h = (h * 0x85EBCA6B) & 0xFFFFFFFF
	h ^= h >> 13
	h = (h * 0xC2B2AE35) & 0xFFFFFFFF
	h ^= h >> 16
	return float(h) / float(0xFFFFFFFF)
