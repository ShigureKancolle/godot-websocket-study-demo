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
#   WATER (10,14) = 水面（像素分析确认：蓝占比100% avg(54,164,200)，纯亮水蓝，已注册 base tile）
# atlas 布局：18 列 × 27 行，每个 tile 16×16 像素
const _TERRAIN_ATLAS: Dictionary = {
	ChunkGenerator.TerrainType.GRASS: Vector2i(4, 14),  # 普通草地
	ChunkGenerator.TerrainType.SAND: Vector2i(6, 10),   # 普通沙地（3×3 中心）
	ChunkGenerator.TerrainType.DIRT: Vector2i(1, 10),   # 泥地（占位）
	ChunkGenerator.TerrainType.BRICK: Vector2i(9, 10),  # 砖地（占位）
	ChunkGenerator.TerrainType.WATER: Vector2i(10, 14),  # 水面（亮水蓝，已确认）
}

# 变体选择专用 hash seed。和地图 seed 分开（变体是纯渲染层的事）。
# 用固定值确保变体分布稳定，换地图 seed 不影响变体分布。
const _VARIANT_HASH_SEED: int = 98765

# ===========================================================================
# 2×2 block 渲染配置（地形过渡贴图系统）
# ===========================================================================
# 以 2×2 tile 的 block 为最小单位。**过渡地形**（如沙地）的 block 根据周围
# 8 邻居 block 类型选择不同的 MyTiledCell（4 个 tile 的贴图组合），实现过渡。
#
# 地形分两类：
#   - 静态地形（草地）：不配形态表 → 永远用 _TERRAIN_ATLAS 纯贴图，不随邻居变化
#   - 过渡地形（沙地，未来水地）：配形态表 → 边缘根据邻居类型显示过渡贴图
#
# 形态查表 key = 8 位掩码（邻居是否与自身地形不同），旋转归一化后查形态表。
# 配置时只需定义基础形态（如"上边邻居异类"），其他朝向（上/下/左）通过旋转派生。
#
# 8 位掩码 bit 顺序（顺时针，从上开始）：
#   bit 0=上 1=右上 2=右 3=右下 4=下 5=左下 6=左 7=左上
#   bit=1 表示该方向邻居不是本地形（异类）
#
# block 内位置编号（以左上角为原点）：
#   (0,0)=index 0  (1,0)=index 1
#   (0,1)=index 2  (1,1)=index 3
#
# ⚠️ 缺失的形态会自动 fallback 到 form 0（纯地块）。

# block 边长（tile 数），和 ChunkGenerator.BLOCK_SIZE 一致
const _BLOCK_SIZE: int = 2

# 旋转同化排除「纯上边 bit0」：上(bit0=1) 独特（水是竖着 2 tile 素材）不能旋转。
# 右上(bit1)/左上(bit7) 不排除 —— 它们可被右/左覆盖同化（见 _rot_lookup_no_top）。

# 过渡地形形态表。key = 地形类型（TerrainType），value = 该地形的形态表
# （key = 旋转归一化后的 8 位掩码，value = MyTiledCell）。
# 只给"过渡地形"配表；草地等静态地形不在此表 → 永远纯贴图。
#
# ⚠️ 不能用 const（MyTiledCell.new 是运行时构造），在 _ready 中由 _init_terrain_forms 初始化
# 用户配置方式：改各地形候选贴图函数（如 _init_sand_tiled）的 return 内容
var _terrain_forms: Dictionary = {}

# 静态地形纯贴图变体表。key = 地形类型（TerrainType），value = Array[TiledCell]
# 静态地形（如草地）虽然不做过渡，但可以有多个纯贴图变体（如几种草地块），
# 按权重随机分布，避免大片区域看起来单调。
# 未配变体表的地形 → 用 _TERRAIN_ATLAS 默认贴图。
var _terrain_variants: Dictionary = {}

# 基础形态掩码。语义与具体地形无关，各过渡地形共用同一套基础形态定义，
# 只是候选贴图不同。用户配置地形样式时按这些 key 填贴图。
enum BASIC_MASKS {
	PURE = 0b00000000,      # 纯地块（周围全是同类地形）
	TOP = 0b00000001,       # 上边邻居是异类
	TOP_RIGHT = 0b00000101, # 上+右邻居是异类
	CORNER = 0b00000010,    # 右上角邻居是异类
}

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
	# 当前阶段：硬编码 seed=12345(调试模式,TiledMap.tscn 独立运行时用)
	# 正式集成到游戏场景时,外部会调 setup(seed) 覆盖这个默认值
	# (setup 来自服务端 MapInfo 消息下发的 seed,见 StateMirror._on_map_info)
	_generator = ChunkGenerator.new(12345)
	# 初始化地形形态表（含 MyTiledCell.new / TiledCell.new，不能放在 const）
	# 草地不配形态表 → 永远静态纯草地；沙地配形态表 → 过渡渲染
	_terrain_forms = _init_terrain_forms()
	# 初始化静态地形纯贴图变体表（草地多种变体，避免单调）
	_terrain_variants = _init_terrain_variants()

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

	# 监听 StateMirror 的 map_info_received 信号
	# 收到服务端下发的 MapInfo 时自动调 setup(seed) 初始化地图
	# 为什么放这里而不是让场景脚本调 setup:
	#   InfiniteTileMap 自包含——放哪个场景就在哪个场景生效,
	#   场景脚本不需要知道 InfiniteTileMap 的存在(职责分离)。
	# 调试模式(TiledMap.tscn 独立运行)不会收到 MapInfo(没连服务器),
	# 用 _ready 里的硬编码 seed 兜底;正式游戏收到 MapInfo 后 setup 覆盖
	ClientStateMirror.instance().map_info_received.connect(setup)

	# 启动时立即加载原点周围的 chunk（否则第一帧前是空的）
	_update_chunks_around(_world_to_chunk(_get_center_pos()))


## 用服务端下发的 seed 初始化 ChunkGenerator(双端一致生成的入口)
##
## 由游戏场景在收到 MapInfo 消息后调用(见 StateMirror._on_map_info → 场景调本方法)。
## 双端用同一份 seed + 同一份算法产出完全相同的地图(详见 map_generator.py)。
##
## 为什么 _ready 里已经有默认 seed 还要这个方法:
##   _ready 的硬编码 12345 是调试模式(TiledMap.tscn 独立运行时用)。
##   正式游戏时,seed 由服务端启动时生成并通过 MapInfo 下发,必须用本方法覆盖。
##
## 可重入:重复调用会清空已加载的 chunk 并用新 seed 重新生成。
## (断线重连换房间时可能重调,虽然当前没这个场景)
func setup(seed: int) -> void:
	# 用新 seed 构造生成器
	_generator = ChunkGenerator.new(seed)
	# 清空已加载 chunk 集合 + chunk 数据缓存(旧 seed 生成的数据不能留)
	_loaded_chunks.clear()
	_chunk_data_cache.clear()
	# 清空 TileMapLayer 上所有已设置的 cell(否则旧 tile 会残留)
	_tile_map_layer.clear()
	# 重新加载原点周围 chunk
	_update_chunks_around(_world_to_chunk(_get_center_pos()))
	if DEBUG_LOG:
		print("[InfiniteTileMap] setup(seed=%d) 完成,已重新加载 chunk" % seed)


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
# 2×2 block 渲染（地形过渡贴图系统）
# ===========================================================================
# 渲染流程：
#   1. 静态地形 tile（草地等，未配形态表）→ 用 _TERRAIN_ATLAS 默认贴图
#   2. 过渡地形 tile（沙地等）→ 查 block 的 8 邻居类型 → 算 form8 → 旋转归一化
#      → 查该地形的形态表得 MyTiledCell → 旋转 → 按 block 内位置抽 TiledCell
#      → 获取 alternative_tile（含旋转） → 返回 {atlas, alt}
#
# 旋转系统（减少配置量）：
#   - 8 位掩码旋转归一化：form 旋转 0/1/2/3 次取最小值作为查表 key
#   - MyTiledCell 整体旋转：4 个 cell 位置重排 + 每个 TiledCell 的 dir +1
#   - alternative_tile 动态创建：dir>0 时调 create_alternative_tile 设置 flip/transpose

## 初始化沙地候选 TiledCell 数组（★ 用户配置沙地样式的地方）
## 沙地是"过渡地形"，这里的贴图决定沙地怎么渲染：
##   - PURE：纯沙地块（周围全是沙地），也是任何"非过渡位置"的默认候选
##   - TOP / TOP_RIGHT / CORNER：沙地边缘的"沙→草"过渡贴图
##
## ⚠️ 当前 TOP/TOP_RIGHT/CORNER 用纯沙 (6,10) 占位（保证能渲染、不报错），
##    需要你根据 Tileset.png 找到"沙地→草地过渡"的贴图坐标后替换。
##
## 用户配置方式：在此函数的 return 内增删/修改 TiledCell。
## TiledCell.new(atlas坐标, dir, 权重)
##   - atlas坐标：Tileset.png 里 16×16 tile 在 18×27 网格中的 (列, 行)
##   - dir：顺时针旋转次数 0/1/2/3 = 0°/90°/180°/270°
##   - 权重：被抽到的相对概率（同一数组内比较）
static func _init_sand_tiled() -> Dictionary:
	var res = {
		# 纯沙地块（目前只有 (6,10) 一个确认坐标，可自行添加更多变体）
		BASIC_MASKS.PURE: [
			TiledCell.new(Vector2i(6, 10), 0, 100),
			TiledCell.new(Vector2i(6, 10), 1, 100),
			TiledCell.new(Vector2i(6, 10), 2, 100),
			TiledCell.new(Vector2i(6, 10), 3, 100),
			TiledCell.new(Vector2i(5, 10), 0, 1),
			TiledCell.new(Vector2i(5, 10), 1, 1),
			TiledCell.new(Vector2i(5, 10), 2, 1),
			TiledCell.new(Vector2i(5, 10), 3, 1),
		],
		# 上边过渡（沙地边缘朝上的一排 → 草地，待用户配置）
		# 示例：TiledCell.new(Vector2i(x, y), 0, 1)
		BASIC_MASKS.TOP: [
			TiledCell.new(Vector2i(5, 9), 0, 1),  # TODO(用户): 替换为沙→草过渡贴图
			TiledCell.new(Vector2i(6, 9), 0, 100),
			TiledCell.new(Vector2i(5, 11), 2, 1), 
			TiledCell.new(Vector2i(6, 11), 2, 1),
			TiledCell.new(Vector2i(4, 10), 1, 1), 
			TiledCell.new(Vector2i(7, 10), 3, 1),

		],
		# 上+右过渡（待用户配置）
		BASIC_MASKS.TOP_RIGHT: [
			TiledCell.new(Vector2i(7, 9), 0, 1),  # TODO(用户): 替换为沙→草过渡贴图
			TiledCell.new(Vector2i(4, 9), 1, 1),
			TiledCell.new(Vector2i(4, 11), 2, 1),
			TiledCell.new(Vector2i(7, 11), 3, 1),
		],
		# 右上角过渡（待用户配置）
		BASIC_MASKS.CORNER: [
			TiledCell.new(Vector2i(10, 7), 0, 1),  # TODO(用户): 替换为沙→草过渡贴图
			TiledCell.new(Vector2i(11, 7), 1, 1),
			TiledCell.new(Vector2i(11, 6), 2, 1),
			TiledCell.new(Vector2i(10, 6), 3, 1),
		],
	}
	return res

## 水的完整形态表（★ 直接在这里配 MyTiledCell 的 4 个资源）
## 水是"过渡地形"，过渡固定一套（竖着 2 tile），不随机。
##
## MyTiledCell.new(main_type, [4 个位置的候选数组])，4 个位置：
##   index 0 = (0,0) 上左    index 1 = (1,0) 上右
##   index 2 = (0,1) 下左    index 3 = (1,1) 下右
##
## 竖着 2 tile 过渡：上排 = 岸/过渡上半，下排 = 水/过渡下半。
## 查找策略（_compute_tile_atlas_v3）：先按「原始 form8」精确查表，命中就用、
## 不旋转；没命中才走旋转归一化派生。所以：
##   - form 1 = 上边异类（bit0）→ 用竖着 2 tile 岸线
##   - 若右/下/左的岸线素材不同，可额外配独立 form：
##       form 4  = 右边异类（bit2）
##       form 16 = 下边异类（bit4）
##       form 64 = 左边异类（bit6）
##     配了就走精确匹配（不旋转），没配就 fallback 到 form 1 旋转派生。
## form 0 是纯水（可多格变体），form 2/5 是角过渡（可选）。
## 缺失的复杂 form（9/10/11/17/21/34/42/170/85）自动退化到简单 form。
static func _build_water_forms() -> Dictionary:
	# ★ 你改这里：纯水（form 0 用，可多格变体随机）
	var pure_water: Array = [
		TiledCell.new(Vector2i(10, 14), 0, 100),  # 主水面
		TiledCell.new(Vector2i(10, 20), 0, 1),
		TiledCell.new(Vector2i(11, 20), 0, 1),
	]
	# ★ 你改这里：岸/过渡上半（form 1 上排用）
	var shore1: Array = [TiledCell.new(Vector2i(10, 12), 0, 1)]
	# ★ 你改这里：水/过渡下半（form 1 下排用）
	var water1: Array = [TiledCell.new(Vector2i(10, 13), 0, 1)]

	# ★ 两邻边是其他 上半
	var shore5: Array = [TiledCell.new(Vector2i(11, 12), 0, 1)]
	var water5: Array = [TiledCell.new(Vector2i(11, 13), 0, 1)]
	# 下半
	var water5_down: Array = [TiledCell.new(Vector2i(11, 15), 0, 1)]
	var shore5_left: Array = [TiledCell.new(Vector2i(9, 12), 0, 1)]
	var water5_left: Array = [TiledCell.new(Vector2i(9, 13), 0, 1)]

	# ★ 两邻边是水 角是其他
	var shore2: Array = [TiledCell.new(Vector2i(9, 18), 0, 1)]
	var water2: Array = [TiledCell.new(Vector2i(9, 19), 0, 1)]
	# 下半
	var water2_down: Array = [TiledCell.new(Vector2i(9, 16), 0, 1)]
	# 左侧
	var shore2_left: Array = [TiledCell.new(Vector2i(11, 18), 0, 1)]
	var water2_left: Array = [TiledCell.new(Vector2i(11, 19), 0, 1)]
	

	# 左或右或下是岸
	var shore4: Array = [TiledCell.new(Vector2i(11, 14), 0, 1)]

	# 右下是岸
	var shore8: Array = [TiledCell.new(Vector2i(9, 16), 0, 1)]

	# 下+右是岸
	var shore20: Array = [TiledCell.new(Vector2i(11, 15), 0, 1)]

	return {
		# form 0：纯水（周围全是水）
		0: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [pure_water]),
		# form 1：上边异类 → 上排岸 + 下排水（竖着 2 tile 过渡）
		1: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore1,       # (0,0) 上左：岸
			shore1,       # (1,0) 上右：岸
			water1,       # (0,1) 下左：水
			water1,       # (1,1) 下右：水
		]),
		# form 2：右上角异类（上右=岸，其余水）
		2: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			pure_water,       # (0,0) 上左：水
			shore2,       # (1,0) 上右：岸
			pure_water,       # (0,1) 下左：水
			water2,       # (1,1) 下右：水
		]),
		# form 5：上 + 右异类（上排岸 + 下排水）
		5: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore1,       # (0,0) 上左：岸
			shore5,       # (1,0) 上右：岸
			water1,       # (0,1) 下左：水
			water5,       # (1,1) 下右：水
		]),
		# form 9：上边异类 + 右下角异类（上排岸 + 右下角过渡）
		9: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore1,       # (0,0) 上左：岸
			shore1,       # (1,0) 上右：岸
			water1,       # (0,1) 下左：水
			water2_down,  # (1,1) 下右：右下角过渡
		]),
		# form 10: 右上角 + 右下角异类 实际不会出现 退化到4 右边是岸 
		4: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			pure_water,       # (0,0) 上左：水
			shore4,       # (1,0) 上右：右上角过渡
			pure_water,       # (0,1) 下左：水
			shore4,  # (1,1) 下右：右下角过渡
		]),
		# form 11: 上边 + 右上角 + 右下角异类 实际不会出现退化到5
		# 11: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
		# 	shore1,       # (0,0) 上左：岸
		# 	shore1,       # (1,0) 上右：岸
		# 	water1,       # (0,1) 下左：水
		# 	water2,  # (1,1) 下右：右下角过渡
		# ]),
		# form 17：上边 + 下边异类（上下都是岸） 实际不会出现退化到1
		# 17: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
		# 	shore1,       # (0,0) 上左：岸（上边过渡）
		# 	shore1,       # (1,0) 上右：岸（上边过渡）
		# 	_rotate_tiled_cell(shore1, 2),  # (0,1) 下左：岸（下边过渡）
		# 	_rotate_tiled_cell(shore1, 2),  # (1,1) 下右：岸（下边过渡）
		# ]),
		# form 21：上 + 右 + 下 三边异类 实际不会出现 退化到 上+右 5  或者下+右20
		20: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			pure_water,       # (0,0) 上左：水
			_rotate_tiled_cell(shore4, 0),      # (1,0) 上右：右岸
			_rotate_tiled_cell(shore4, 1),      # (0,1) 下左：下岸
			shore20,  # (1,1) 下右：下+右角
		]),
		# form 34：右上角 + 左下角（对角角）异类
		34: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			pure_water,       # (0,0) 上左：水
			shore2,       # (1,0) 上右：右上角过渡
			_rotate_tiled_cell(water2_down, 1),  # (0,1) 下左：左下角过渡
			water2,       # (1,1) 下右：水
		]),
		# form 42：左下 + 右上 + 右下 三角异类 不会出现 实际是左下+右边 36
		36: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			pure_water,       # (0,0) 上左：水
			_rotate_tiled_cell(shore4, 1),       # (1,0) 上右：右上角过渡
			_rotate_tiled_cell(water2_down, 1),  # (0,1) 下左：左下角过渡
			_rotate_tiled_cell(shore4, 1),  # (1,1) 下右：右下角过渡
		]),
		# form 170：四角异类
		170: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			_rotate_tiled_cell(shore2, 3),  # (0,0) 上左：左上角过渡
			shore2,       # (1,0) 上右：右上角过渡
			_rotate_tiled_cell(shore2, 2),  # (0,1) 下左：左下角过渡
			_rotate_tiled_cell(shore2, 1),  # (1,1) 下右：右下角过渡
		]),
		# form 85：四边异类
		85: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			_rotate_tiled_cell(shore5, 3),  # (0,0) 上左：左上边过渡
			shore5,       # (1,0) 上右：右上边过渡
			_rotate_tiled_cell(shore5, 2),  # (0,1) 下左：左下边过渡
			_rotate_tiled_cell(shore5, 1),  # (1,1) 下右：右下边过渡
		]),
		# ===== 新增：涉及上边（bit0/bit1/bit7）的独立掩码 =====
		# 位置 = [上左, 上右, 下左, 下右]
		# 旋转约定：右=shore4(0°) 下=rotate(shore4,1) 左=rotate(shore4,2)
		#         右下=shore8 左下=rotate(shore8,1) 上+右=shore5 上+左=shore5_left
		#         右上=shore2 左上=shore2_left
		18: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			pure_water,                          # (0,0) 上左：水
			shore2,                              # (1,0) 上右：右上角
			_rotate_tiled_cell(shore4, 1),       # (0,1) 下左：下岸
			_rotate_tiled_cell(shore4, 1),       # (1,1) 下右：下岸
		]),  # 右上+下
		33: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore1,                              # (0,0) 上左：上边岸
			shore1,                              # (1,0) 上右：上边岸
			_rotate_tiled_cell(shore8, 1),       # (0,1) 下左：左下角
			pure_water,                          # (1,1) 下右：水
		]),  # 上+左下
		37: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore1,                              # (0,0) 上左：上边岸
			shore5,                              # (1,0) 上右：上+右角
			_rotate_tiled_cell(shore8, 1),       # (0,1) 下左：左下角
			shore4,                              # (1,1) 下右：右岸
		]),  # 上+右+左下
		41: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore1,                              # (0,0) 上左：上边岸
			shore1,                              # (1,0) 上右：上边岸
			_rotate_tiled_cell(shore8, 1),       # (0,1) 下左：左下角
			shore8,                              # (1,1) 下右：右下角
		]),  # 上+右下+左下
		65: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore5_left,                         # (0,0) 上左：左上角
			shore1,                          # (1,0) 上右：水
			water5_left,                          # (0,1) 下左：水
			water1,                          # (1,1) 下右：水
		]),  # 左+上
		66: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			_rotate_tiled_cell(shore4, 2),       # (0,0) 上左：左岸
			shore2,                              # (1,0) 上右：右上角
			_rotate_tiled_cell(shore4, 2),       # (0,1) 下左：左岸
			pure_water,                          # (1,1) 下右：水
		]),  # 左+右上
		69: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore5_left,                         # (0,0) 上左：上+左角
			shore5,                              # (1,0) 上右：上+右角
			_rotate_tiled_cell(shore4, 2),       # (0,1) 下左：左岸
			shore4,                              # (1,1) 下右：右岸
		]),  # 左+上+右
		73: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore5_left,                         # (0,0) 上左：上+左角
			shore1,                              # (1,0) 上右：上边岸
			_rotate_tiled_cell(shore4, 2),       # (0,1) 下左：左岸
			shore8,                              # (1,1) 下右：右下角
		]),  # 左+上+右下
		82: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			_rotate_tiled_cell(shore4, 2),       # (0,0) 上左：左岸
			shore2,                              # (1,0) 上右：右上角
			_rotate_tiled_cell(shore20, 1),      # (0,1) 下左：下+左角（边优先：左、下都临岸）
			_rotate_tiled_cell(shore4, 1),       # (1,1) 下右：下岸
		]),  # 左+右上+下
		128: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore2_left,                         # (0,0) 上左：左上角
			pure_water,                          # (1,0) 上右：水
			water2_left,                          # (0,1) 下左：水
			pure_water,                          # (1,1) 下右：水
		]),  # 左上
		
		130: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore2_left,                         # (0,0) 上左：左上角
			shore2,                              # (1,0) 上右：右上角
			pure_water,                          # (0,1) 下左：水
			pure_water,                          # (1,1) 下右：水
		]),  # 左上+右上
		132: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore2_left,                         # (0,0) 上左：左上角
			shore4,                              # (1,0) 上右：右岸
			water2_left,                          # (0,1) 下左：水
			shore4,                              # (1,1) 下右：右岸
		]),  # 左上+右
		136: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore2_left,                         # (0,0) 上左：左上角
			pure_water,                          # (1,0) 上右：水
			water2_left,                          # (0,1) 下左：水
			shore8,                              # (1,1) 下右：右下角
		]),  # 左上+右下
		144: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore2_left,                         # (0,0) 上左：左上角
			pure_water,                          # (1,0) 上右：水
			_rotate_tiled_cell(shore4, 1),       # (0,1) 下左：下岸
			_rotate_tiled_cell(shore4, 1),       # (1,1) 下右：下岸
		]),  # 左上+下
		146: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore2_left,                         # (0,0) 上左：左上角
			shore2,                              # (1,0) 上右：右上角
			_rotate_tiled_cell(shore4, 1),       # (0,1) 下左：下岸
			_rotate_tiled_cell(shore4, 1),       # (1,1) 下右：下岸
		]),  # 左上+右上+下
		148: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			shore2_left,                         # (0,0) 上左：左上角
			shore4,                              # (1,0) 上右：右岸
			_rotate_tiled_cell(shore4, 1),       # (0,1) 下左：下岸
			shore20,                             # (1,1) 下右：下+右角（边优先：右、下都临岸）
		]),  # 左上+右+下
		# ===== 不涉及上边的通用掩码（归并代表，供旋转复用）=====
		8: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			pure_water,                          # (0,0) 上左：水
			pure_water,                          # (1,0) 上右：水
			pure_water,                          # (0,1) 下左：水
			shore8,                              # (1,1) 下右：右下角
		]),  # 右下角
		40: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			pure_water,                          # (0,0) 上左：水
			pure_water,                          # (1,0) 上右：水
			_rotate_tiled_cell(shore8, 1),       # (0,1) 下左：左下角
			shore8,                              # (1,1) 下右：右下角
		]),  # 右下+左下
		68: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			_rotate_tiled_cell(shore4, 2),       # (0,0) 上左：左岸
			shore4,                              # (1,0) 上右：右岸
			_rotate_tiled_cell(shore4, 2),       # (0,1) 下左：左岸
			shore4,                              # (1,1) 下右：右岸
		]),  # 右+左（对称）
		72: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			_rotate_tiled_cell(shore4, 2),       # (0,0) 上左：左岸
			pure_water,                          # (1,0) 上右：水
			_rotate_tiled_cell(shore4, 2),       # (0,1) 下左：左岸
			shore8,                              # (1,1) 下右：右下角
		]),  # 右下+左
		84: MyTiledCell.new(ChunkGenerator.TerrainType.WATER, [
			_rotate_tiled_cell(shore4, 2),       # (0,0) 上左：左岸
			shore4,                              # (1,0) 上右：右岸
			_rotate_tiled_cell(shore20, 1),      # (0,1) 下左：下+左角（边优先：左、下都临岸）
			shore20,                             # (1,1) 下右：下+右角（边优先：右、下都临岸）
		]),  # 右+下+左
		
	}


static func _rotate_tiled_cell(p_tiled_cell: Array, step: int = 0) -> Array:
	# ⚠️ 不能用 duplicate(true)：RefCounted 对象只复制引用，修改 dir 会污染原对象
	# 必须创建新的 TiledCell 实例
	var result: Array = []
	for cell in p_tiled_cell:
		result.append(TiledCell.new(cell.assets_pos, (cell.dir + step) % 4, cell.weight))
	return result



## 聚合所有过渡地形的形态表（★ 新增过渡地形的入口）
## 草地是静态地形，不在此表 → 永远纯草地贴图。
## 新增过渡地形（如水）时在此加一条，并写对应的 _init_xxx_tiled 函数。
static func _init_terrain_forms() -> Dictionary:
	return {
		# 沙地：过渡地形（边缘显示沙→草过渡贴图，贴图见 _init_sand_tiled）
		ChunkGenerator.TerrainType.SAND: _build_terrain_forms(
			_init_sand_tiled(), ChunkGenerator.TerrainType.SAND
		),
		# 水：过渡固定一套（竖着 2 tile），直接在 _build_water_forms 里配 MyTiledCell
		ChunkGenerator.TerrainType.WATER: _build_water_forms(),
	}


## 聚合所有静态地形的纯贴图变体表（★ 用户配置静态地形样式的地方）
## 静态地形：不随邻居变化，但可以有多个纯贴图变体避免单调。
static func _init_terrain_variants() -> Dictionary:
	return {
		# 草地：多种草地块随机分布（变体见 _init_grass_variants）
		ChunkGenerator.TerrainType.GRASS: _init_grass_variants(),
	}


## 初始化草地纯贴图变体候选数组（★ 用户配置草地样式的地方）
## 同一位置的草地永远选同一个变体（用 _variant_hash，移动/重载不跳变）。
## 用户配置方式：在此函数的 return 内增删/修改 TiledCell。
## TiledCell.new(atlas坐标, dir, 权重)：dir=0/1/2/3 = 0°/90°/180°/270°
static func _init_grass_variants() -> Array:
	return [
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
	]


## 通用：给定某过渡地形的候选贴图 dict + 地形类型，生成该地形的完整形态表
## key = 旋转归一化后的 8 位掩码，value = MyTiledCell
## - form 0 = 纯地块（省略形式，4 个位置都用 PURE 候选）
## - 只需定义基础形态（上边/上+右/角），其他朝向通过旋转自动派生
## - 缺失的 form 自动 fallback 到 form 0（见 _compute_tile_atlas_v3）
static func _build_terrain_forms(tiled: Dictionary, main_type: int) -> Dictionary:
	return {
		# form 0: 纯地块（8 邻居都是同类地形）
		# 省略形式：4 个位置都用 PURE 候选
		0: MyTiledCell.new(main_type, [tiled[BASIC_MASKS.PURE]]),
		# form 1: 上边异类（归一化形态，右边/下边/左边的异类通过旋转派生）
		# 上边 2 个 tile 用过渡贴图，下边 2 个用纯地块
		1: MyTiledCell.new(main_type, [
			tiled[BASIC_MASKS.TOP],    # index 0 = (0,0) 上左
			tiled[BASIC_MASKS.TOP],    # index 1 = (1,0) 上右
			tiled[BASIC_MASKS.PURE],   # index 2 = (0,1) 下左
			tiled[BASIC_MASKS.PURE],   # index 3 = (1,1) 下右
		]),
		# form 2: 右上角异类
		2: MyTiledCell.new(main_type, [
			tiled[BASIC_MASKS.PURE],   # index 0 = (0,0) 上左
			tiled[BASIC_MASKS.CORNER], # index 1 = (1,0) 上右
			tiled[BASIC_MASKS.PURE],   # index 2 = (0,1) 下左
			tiled[BASIC_MASKS.PURE],   # index 3 = (1,1) 下右
		]),
		# form 5: 上边 + 右边异类
		5: MyTiledCell.new(main_type, [
			tiled[BASIC_MASKS.TOP],       # index 0 = (0,0) 上左
			tiled[BASIC_MASKS.TOP_RIGHT], # index 1 = (1,0) 上右
			tiled[BASIC_MASKS.PURE],      # index 2 = (0,1) 下左
			_rotate_tiled_cell(tiled[BASIC_MASKS.TOP], 1),  # index 3 = (1,1) 下右
		]),
		# form 9: 上边异类 + 右下角异类
		9: MyTiledCell.new(main_type, [
			tiled[BASIC_MASKS.TOP],   # index 0 = (0,0) 上左
			tiled[BASIC_MASKS.TOP],   # index 1 = (1,0) 上右
			tiled[BASIC_MASKS.PURE],  # index 2 = (0,1) 下左
			_rotate_tiled_cell(tiled[BASIC_MASKS.CORNER], 1),  # index 3 = (1,1) 下右
		]),
		# form 10: 右上角 + 右下角异类
		10: MyTiledCell.new(main_type, [
			tiled[BASIC_MASKS.PURE],   # index 0 = (0,0) 上左
			tiled[BASIC_MASKS.CORNER], # index 1 = (1,0) 上右
			tiled[BASIC_MASKS.PURE],   # index 2 = (0,1) 下左
			_rotate_tiled_cell(tiled[BASIC_MASKS.CORNER], 1),  # index 3 = (1,1) 下右
		]),
		# form 11: 上边 + 右上角 + 右下角异类
		11: MyTiledCell.new(main_type, [
			tiled[BASIC_MASKS.TOP],   # index 0 = (0,0) 上左
			tiled[BASIC_MASKS.TOP], # index 1 = (1,0) 上右
			tiled[BASIC_MASKS.PURE],   # index 2 = (0,1) 下左
			_rotate_tiled_cell(tiled[BASIC_MASKS.CORNER], 1),  # index 3 = (1,1) 下右
		]),
		# form 17: 上边 + 下边（相对两边）异类
		17: MyTiledCell.new(main_type, [
			tiled[BASIC_MASKS.TOP],                        # index 0 = (0,0) 上左：上边过渡
			tiled[BASIC_MASKS.TOP],                        # index 1 = (1,0) 上右：上边过渡
			_rotate_tiled_cell(tiled[BASIC_MASKS.TOP], 2), # index 2 = (0,1) 下左：下边过渡
			_rotate_tiled_cell(tiled[BASIC_MASKS.TOP], 2), # index 3 = (1,1) 下右：下边过渡
		]),
		# form 21: 上 + 右 + 下 三边异类
		21: MyTiledCell.new(main_type, [
			tiled[BASIC_MASKS.TOP],        # index 0 = (0,0) 上左
			tiled[BASIC_MASKS.TOP_RIGHT],  # index 1 = (1,0) 上右
			_rotate_tiled_cell(tiled[BASIC_MASKS.TOP], 2),  # index 2 = (0,1) 下左
			_rotate_tiled_cell(tiled[BASIC_MASKS.TOP_RIGHT], 1),  # index 3 = (1,1) 下右
		]),
		# form 34: 右上角 + 左下角（对角角）异类
		34: MyTiledCell.new(main_type, [
			tiled[BASIC_MASKS.PURE],                          # index 0 = (0,0) 上左：纯地块
			tiled[BASIC_MASKS.CORNER],                        # index 1 = (1,0) 上右：右上角过渡
			_rotate_tiled_cell(tiled[BASIC_MASKS.CORNER], 2), # index 2 = (0,1) 下左：左下角过渡
			tiled[BASIC_MASKS.PURE],                          # index 3 = (1,1) 下右：纯地块
		]),
		# form 42: 左下 + 右上 + 右下 三角异类
		42: MyTiledCell.new(main_type, [
			tiled[BASIC_MASKS.PURE],   # index 0 = (0,0) 上左
			tiled[BASIC_MASKS.CORNER], # index 1 = (1,0) 上右
			_rotate_tiled_cell(tiled[BASIC_MASKS.CORNER], 2),  # index 2 = (0,1) 下左
			_rotate_tiled_cell(tiled[BASIC_MASKS.CORNER], 1),  # index 3 = (1,1) 下右
		]),
		# form 170: 四角异类
		170: MyTiledCell.new(main_type, [
			_rotate_tiled_cell(tiled[BASIC_MASKS.CORNER], 3),  # index 0 = (0,0) 上左
			tiled[BASIC_MASKS.CORNER],       # index 1 = (1,0) 上右
			_rotate_tiled_cell(tiled[BASIC_MASKS.CORNER], 2),  # index 2 = (0,1) 下左
			_rotate_tiled_cell(tiled[BASIC_MASKS.CORNER], 1),  # index 3 = (1,1) 下右
		]),
		# form 85: 四边异类
		85: MyTiledCell.new(main_type, [
			_rotate_tiled_cell(tiled[BASIC_MASKS.TOP_RIGHT], 3),  # index 0 = (0,0) 上左
			tiled[BASIC_MASKS.TOP_RIGHT],        # index 1 = (1,0) 上右
			_rotate_tiled_cell(tiled[BASIC_MASKS.TOP_RIGHT], 2),  # index 2 = (0,1) 下左
			_rotate_tiled_cell(tiled[BASIC_MASKS.TOP_RIGHT], 1),  # index 3 = (1,1) 下右
		]),
	}


## 计算单个 tile 的 atlas coord + alternative_tile
## 返回 Dictionary {atlas: Vector2i, alt: int}
##
## 静态地形 tile（草地等）：用 _TERRAIN_ATLAS 默认贴图，alt=0
## 过渡地形 tile（沙地等）：根据 block 8 邻居类型选 MyTiledCell，按权重抽 TiledCell
func _compute_tile_atlas_v3(world_tile_x: int, world_tile_y: int, data: PackedInt32Array, local_y: int, local_x: int) -> Dictionary:
	var CS: int = ChunkGenerator.CHUNK_SIZE
	var terrain: int = data[local_y * CS + local_x]

	# 静态地形（未配形态表，如草地）：用纯贴图变体（无过渡）
	# 有配变体表 → 按权重抽一个；没配 → 用 _TERRAIN_ATLAS 默认贴图
	var forms: Dictionary = _terrain_forms.get(terrain, {})
	if forms.is_empty():
		var variants: Array = _terrain_variants.get(terrain, [])
		if variants.is_empty():
			var default_atlas: Vector2i = _TERRAIN_ATLAS.get(terrain, Vector2i.ZERO)
			return {atlas = default_atlas, alt = 0}
		var variant_tc: TiledCell = _pick_tiled_cell(variants, world_tile_x, world_tile_y)
		var variant_alt: int = _get_or_create_alt_tile(variant_tc.assets_pos, variant_tc.dir)
		return {atlas = variant_tc.assets_pos, alt = variant_alt}

	# 过渡地形（沙地等）：根据 block 8 邻居类型算形态
	var bx: int = int(floor(float(world_tile_x) / _BLOCK_SIZE))
	var by: int = int(floor(float(world_tile_y) / _BLOCK_SIZE))

	# 算 block 的 8 邻居掩码（邻居不是本地形 → bit=1）
	var form8: int = _compute_form8_for_block(bx, by, terrain)

	# 通用查找（先精确 → 非上边旋转 → 归一化 → 覆盖角退化 → fallback form0）
	var found: Dictionary = _lookup_form_mtc(forms, form8)
	if found.is_empty():
		return {atlas = _TERRAIN_ATLAS.get(terrain, Vector2i.ZERO), alt = 0}
	var mtc: MyTiledCell = found.mtc
	var rotations: int = found.rotations

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
## bit=1 表示该方向邻居不是 main_type（异类）
func _compute_form8_for_block(block_x: int, block_y: int, main_type: int) -> int:
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
		if nt != main_type:
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


## 退化辅助：去掉"被相邻边覆盖的角"，只保留"孤立角"（两条相邻边都同类）
##
## 规则：一个角若至少有一条相邻边是异类，则该角可由边过渡贴图覆盖，
## 不需要单独的角过渡；只有两条相邻边都同类（角是孤立突出）时才保留角。
## 例：form 46（右+右上+右下+左下）→ 右上/右下角被右边覆盖去掉，
##     剩 右+左下 → 归一化后 = form 9（与 46 视觉一致，无需单独配 46）
static func _reduce_covered_corners(form: int) -> int:
	# 先只留 4 条边（正方向位 bit0/2/4/6），再按规则把孤立角加回来
	var result: int = form & 0b01010101
	# 右上角(bit1)：相邻边上(bit0)、右(bit2)
	if form & (1 << 1) and (form & (1 << 0)) == 0 and (form & (1 << 2)) == 0:
		result |= (1 << 1)
	# 右下角(bit3)：相邻边右(bit2)、下(bit4)
	if form & (1 << 3) and (form & (1 << 2)) == 0 and (form & (1 << 4)) == 0:
		result |= (1 << 3)
	# 左下角(bit5)：相邻边下(bit4)、左(bit6)
	if form & (1 << 5) and (form & (1 << 4)) == 0 and (form & (1 << 6)) == 0:
		result |= (1 << 5)
	# 左上角(bit7)：相邻边左(bit6)、上(bit0)
	if form & (1 << 7) and (form & (1 << 6)) == 0 and (form & (1 << 0)) == 0:
		result |= (1 << 7)
	return result


## 通用查找：在形态表里按 form8 找 MyTiledCell（沙地/水等所有过渡地形共用）
## 查找顺序（与 _compute_tile_atlas_v3 一致，供调试场景复用保证不漂移）：
##   1. 原始 form8 精确匹配 —— 用户配的独立素材（如水涉及上边的掩码）直接命中，不旋转
##   2. 未命中且【不含纯上边 bit0】→ 旋转同化（右上/左上角可被右/左覆盖），
##      优先命中专门配置的边素材（如 form6 → form4 右岸），避免落回上边素材旋转
##   3. 未命中 → 旋转归一化查表
##   4. 再没找到 → 退化（覆盖角）后先试旋转同化（form6 → reduce → form4 右岸）再归一化
##   5. 仍没找到 → fallback 到 form 0（纯地块）
## 返回 {mtc: MyTiledCell, rotations: int}；形态表连 form 0 都没有时返回 {}
static func _lookup_form_mtc(forms: Dictionary, form8: int) -> Dictionary:
	var mtc: MyTiledCell = forms.get(form8, null)
	var rotations: int = 0
	if mtc == null:
		# 步骤 2：掩码不含「上边区域 bit0/bit1/bit7」→ 旋转同化（下边区域之间归并）
		# 排除整个上边区域：右上/左上用独立上边素材，不能旋转同化到它们（否则 form32
		# 左下角会落到 form128 左上角素材）。下边区域角可旋转归并（form32 → form8 右下角）。
		# form6（右+右上）这类"角被边覆盖"的不靠这里，走步骤4 reduce 精确命中 form4
		var r2: Dictionary = _rot_lookup_no_top(forms, form8)
		if not r2.is_empty():
			mtc = forms[r2.form]
			rotations = r2.rotations
		# 步骤 3：旋转归一化查表
		if mtc == null:
			var norm: Dictionary = _normalize_form8(form8)
			var base_form: int = norm.form
			rotations = norm.rotations
			mtc = forms.get(base_form, null)
			if mtc == null:
				# 步骤 4：退化（去掉被相邻边覆盖的角）后再查，按优先级：
				#   1) 精确匹配 reduced —— 如 form71 → reduce → 69（右上被右覆盖），69 是已配置
				#      独立 form，直接命中（之前漏了这一步，导致 69 含纯上边走不了旋转同化，
				#      归一化到 21 又不在表 → 错误 fallback 到 form0 纯水）
				#   2) 非纯上边旋转同化 —— form6 → reduce → form4 右岸
				#   3) 归一化
				var reduced: int = _reduce_covered_corners(form8)
				mtc = forms.get(reduced, null)
				if mtc != null:
					rotations = 0
				else:
					var r4: Dictionary = _rot_lookup_no_top(forms, reduced)
					if not r4.is_empty():
						mtc = forms[r4.form]
						rotations = r4.rotations
					else:
						var norm_r: Dictionary = _normalize_form8(reduced)
						mtc = forms.get(norm_r.form, null)
						rotations = norm_r.rotations
	# 步骤 5：fallback 到纯地块（form 0）
	if mtc == null:
		mtc = forms.get(0, null)
		rotations = 0
	if mtc == null:
		return {}
	return {mtc = mtc, rotations = rotations}


## 非上边区域旋转同化：在 4 个顺时针旋转里找「不含上边区域 bit0/bit1/bit7 + 已配置」的 form
## 返回 {form, rotations}；找不到返回 {}
## 规则：下边区域（右4/下16/左64 + 右下8/左下32）之间可旋转同化；
##      上边区域（上1/右上2/左上128）用独立上边素材，出现时不能旋转。
## 例：form32（左下角）旋转族 {32,128,2,8}，128/2 属上边区域排除，8 命中 → 右下角素材
##     （之前只排除 bit0，form32 会落到 form128 左上角素材 → 显示成"128旋转"）
##     form6（右+右上）含右上 → 返回 {}（由步骤4 reduce 到 form4 精确匹配处理）
static func _rot_lookup_no_top(forms: Dictionary, form8: int) -> Dictionary:
	const TOP_REGION: int = 1 | 2 | 128
	if (form8 & TOP_REGION) != 0:
		return {}
	var cur: int = form8
	for r in range(4):
		if (cur & TOP_REGION) == 0 and forms.has(cur):
			return {form = cur, rotations = r}
		cur = _rotate_form8_cw(cur)
	return {}


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
