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
    var local_role = _roles[ClientStateMirror.local_player_id()]
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

# 过渡贴图映射表（8 邻居 256 形态）：[地形类型][form8(0-255)] → atlas coord
# 这是 autotiling 的完整配置。8 邻居 2^8=256 种组合，配满工作量大。
# 采用渐进式配置：用户按需添加，缺失时自动 fallback 到 16 边形态。
#
# ⚠️ 当前为空 Dictionary（占位）。用户配置方式：
#   1. 先配 _TERRAIN_EDGE_ATLAS 的 16 种边形态（基础过渡，必配）
#   2. 再按需在此表添加角形态（内角/外角细节，选配）
#   3. 8 位掩码计算参考 TerrainTransition.compute_form_8
#
# fallback 链：_TERRAIN_TRANSITION_ATLAS_8 → _TERRAIN_EDGE_ATLAS → _TERRAIN_ATLAS
const _TERRAIN_TRANSITION_ATLAS_8: Dictionary = {
	# 8 邻居位掩码：上=1 右上=2 右=4 右下=8 下=16 左下=32 左=64 左上=128
	ChunkGenerator.TerrainType.GRASS: {},
	# 沙地过渡贴图
	ChunkGenerator.TerrainType.SAND: {
		# === 5×5 布局：4 角草地 + 4 边沙地过渡 + 中间 3×3 ===
		#
		# 4 边沙地（form8 掩码，沙地视角同类=沙地）：
		# 上边 3 格（y=0 行，上边是草地）
		28: Vector2i(4, 9),    # (1,0) 左上沙角：右+右下+下连
		124: Vector2i(6, 9),   # (2,0) 上边中：右+右下+下+左下+左连
		112: Vector2i(7, 9),   # (3,0) 右上沙角：下+左下+左连
		# 下边 3 格（y=4 行，下边是草地）
		7: Vector2i(4, 11),    # (1,4) 左下沙角：上+右上+右连
		199: Vector2i(6, 11),  # (2,4) 下边中：上+右上+右+左+左上连
		193: Vector2i(7, 11),  # (3,4) 右下沙角：上+左+左上连
		# 左边 3 格（x=0 列，左边是草地）
		30: Vector2i(4, 9),   # (0,1) 左上边中：上(草)+右上+右+右下+下连
		31: Vector2i(4, 10),   # (0,2) 左边中：上+右上+右+右下+下连
		15: Vector2i(4, 11),   # (0,3) 左下边中：上+右上+右+右下连
		# 右边 3 格（x=4 列，右边是草地）
		240: Vector2i(7, 9),  # (4,1) 右上边中：下+左下+左+左上连
		241: Vector2i(7, 10),  # (4,2) 右边中：上+下+左下+左+左上连
		225: Vector2i(7, 11),  # (4,3) 右下边中：上+左下+左+左上连
		# 中间 3×3 纯沙地：form8=255 全连，fallback 到 form4 FULL(6,10)

		# === 沙地内凹角（7 邻居沙 + 1 角草地）===
		# 沙地视角同类=沙地。只有 1 个角是草地，其他 7 个方向都是沙地。
		# form8 = 255 - 单角 bit
		# 8 邻居位掩码：上=1 右上=2 右=4 右下=8 下=16 左下=32 左=64 左上=128
		#
		# 10,6 草在右下：缺右下(bit 3) → form8 = 255 - 8 = 247
		247: Vector2i(10, 6),
		# 11,6 草在左下：缺左下(bit 5) → form8 = 255 - 32 = 223
		223: Vector2i(11, 6),
		# 10,7 草在右上：缺右上(bit 1) → form8 = 255 - 2 = 253
		253: Vector2i(10, 7),
		# 11,7 草在左上：缺左上(bit 7) → form8 = 255 - 128 = 127
		127: Vector2i(11, 7),
	},
	ChunkGenerator.TerrainType.DIRT: {},
	ChunkGenerator.TerrainType.BRICK: {},
}

# 边形态贴图映射表（4 边 16 形态 fallback）：[地形类型][form4(0-15)] → atlas coord
# 这是基础过渡配置，16 种形态覆盖：孤岛/单边/两边/三边/完整。
# 当 _TERRAIN_TRANSITION_ATLAS_8 缺失某形态时，fallback 到此表。
#
# ⚠️ 当前是【占位值】——所有形态都指向纯地块贴图（无过渡效果）。
# 用户需替换为真实过渡贴图。
#
# form4 顺序（4 位掩码，bit 0=上 1=右 2=下 3=左）：
#   0=ISOLATED  1=TOP  2=RIGHT  3=TR    4=BOTTOM  5=TB   6=BR    7=TBR
#   8=LEFT      9=TL   10=LR    11=TLR  12=BL     13=TBL  14=BLR  15=FULL
const _TERRAIN_EDGE_ATLAS: Dictionary = {
	ChunkGenerator.TerrainType.GRASS: {
		0: Vector2i(1, 17), 1: Vector2i(1, 17), 2: Vector2i(1, 17), 3: Vector2i(1, 17),
		4: Vector2i(1, 17), 5: Vector2i(1, 17), 6: Vector2i(1, 17), 7: Vector2i(1, 17),
		8: Vector2i(1, 17), 9: Vector2i(1, 17), 10: Vector2i(1, 17), 11: Vector2i(1, 17),
		12: Vector2i(1, 17), 13: Vector2i(1, 17), 14: Vector2i(1, 17), 15: Vector2i(1, 17),
	},
	ChunkGenerator.TerrainType.SAND: {
		# 3×3 沙地过渡贴图映射到 form4（16 种边形态）
		# 3×3 布局（周围草地，中间沙地）：
		#   (4,9)=BR(6)  (6,9)=BLR(14)  (7,9)=BL(12)
		#   (4,10)=TBR(7) (6,10)=FULL(15) (7,10)=TBL(13)
		#   (4,11)=TR(3)  (6,11)=TLR(11)  (7,11)=TL(9)
		# 缺失形态（细条/孤岛）fallback 到 FULL(6,10)
		0: Vector2i(6, 10),   # ISOLATED → fallback FULL
		1: Vector2i(6, 10),   # TOP → fallback（细条：只有上连）
		2: Vector2i(6, 10),   # RIGHT → fallback（细条：只有右连）
		3: Vector2i(4, 11),   # TR = 左下 corner（上连+右连）
		4: Vector2i(6, 10),   # BOTTOM → fallback（细条：只有下连）
		5: Vector2i(6, 10),   # TB → fallback（细条：上下连）
		6: Vector2i(4, 9),    # BR = 左上 corner（下连+右连）
		7: Vector2i(4, 10),   # TBR = 左 edge（上+下+右连，缺左）
		8: Vector2i(6, 10),   # LEFT → fallback（细条：只有左连）
		9: Vector2i(7, 11),   # TL = 右下 corner（上连+左连）
		10: Vector2i(6, 10),  # LR → fallback（细条：左右连）
		11: Vector2i(6, 11),  # TLR = 下 edge（上+左+右连，缺下）
		12: Vector2i(7, 9),   # BL = 右上 corner（下连+左连）
		13: Vector2i(7, 10),  # TBL = 右 edge（上+下+左连，缺右）
		14: Vector2i(6, 9),   # BLR = 上 edge（下+左+右连，缺上）
		15: Vector2i(6, 10),  # FULL = center（四周都连）
	},
	ChunkGenerator.TerrainType.DIRT: {
		0: Vector2i(1, 10), 1: Vector2i(1, 10), 2: Vector2i(1, 10), 3: Vector2i(1, 10),
		4: Vector2i(1, 10), 5: Vector2i(1, 10), 6: Vector2i(1, 10), 7: Vector2i(1, 10),
		8: Vector2i(1, 10), 9: Vector2i(1, 10), 10: Vector2i(1, 10), 11: Vector2i(1, 10),
		12: Vector2i(1, 10), 13: Vector2i(1, 10), 14: Vector2i(1, 10), 15: Vector2i(1, 10),
	},
	ChunkGenerator.TerrainType.BRICK: {
		0: Vector2i(9, 10), 1: Vector2i(9, 10), 2: Vector2i(9, 10), 3: Vector2i(9, 10),
		4: Vector2i(9, 10), 5: Vector2i(9, 10), 6: Vector2i(9, 10), 7: Vector2i(9, 10),
		8: Vector2i(9, 10), 9: Vector2i(9, 10), 10: Vector2i(9, 10), 11: Vector2i(9, 10),
		12: Vector2i(9, 10), 13: Vector2i(9, 10), 14: Vector2i(9, 10), 15: Vector2i(9, 10),
	},
}

# 地形变体贴图表：[地形类型] → Array[{atlas: Vector2i, weight: int}]
# 只对 form8=255（8邻居全同类，真正的内部纯地块）应用变体，打破视觉重复。
# 边缘/角/内凹角等过渡贴图不变体（否则每种形态×每种变体配置量爆炸）。
#
# 选择算法：_pick_variant 用 hash(tile_x, tile_y) * 总权重 落区间选变体，
# 确保同一 tile 永远是同一变体（移动时不跳变）。
#
# 权重是相对值，不需要加起来等于 100。比如 [70, 5, 5, 5, 5, 4, 3, 2, 1]
# 和 [14, 1, 1, 1, 1, 1, 1, 1, 1] 效果相同（比例一致）。
# 空数组 = 该地形不变体，用 _TERRAIN_ATLAS[T] 固定贴图。
#
# ⚠️ 当前所有变体 weight=1（均匀分布），用户自行调整实际权重。
const _TERRAIN_VARIANTS: Dictionary = {
	ChunkGenerator.TerrainType.GRASS: [
		# 草地 9 个平替贴图。第一个是主变体（1,17），建议权重最高。
		# 权重待用户配置，当前都是 1（均匀），改成实际权重后按比例分布。
		{"atlas": Vector2i(1, 17), "weight": 300},
		{"atlas": Vector2i(4, 20), "weight": 100},
		{"atlas": Vector2i(5, 20), "weight": 100},
		{"atlas": Vector2i(6, 8), "weight": 1},
		{"atlas": Vector2i(7, 8), "weight": 1},
		{"atlas": Vector2i(8, 8), "weight": 1},
		{"atlas": Vector2i(9, 8), "weight": 1},
		{"atlas": Vector2i(10, 8), "weight": 1},
		{"atlas": Vector2i(11, 8), "weight": 1},
	],
	ChunkGenerator.TerrainType.SAND: [],     # 待配
	ChunkGenerator.TerrainType.DIRT: [],     # 待配
	ChunkGenerator.TerrainType.BRICK: [],    # 待配
}

# 变体选择专用 hash seed。和地图 seed 分开（变体是纯渲染层的事）。
# 用固定值确保变体分布稳定，换地图 seed 不影响变体分布。
const _VARIANT_HASH_SEED: int = 98765

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

# 区块生成器（纯函数，持有 seed 和 noise 参数）
var _generator: ChunkGenerator = null

# 算法版本开关：true=V2 确定性放置（种子+模板），false=V1 noise+CA
var _use_v2: bool = false

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
	#   func setup(seed: int, noise_scale: float = 0.1):
	#       _generator = ChunkGenerator.new(seed, noise_scale, ca_threshold, ca_iterations, terrain_spacing)
	#       _update_chunks_around(_world_to_chunk(_get_center_pos()))
	# 参数：seed=12345, noise_scale=0.1, ca_threshold=2, ca_iterations=2, terrain_spacing=2
	# ca_iterations=2 消除二阶孤岛；terrain_spacing=2 让 DIRT/BRICK 间隔至少 2 草地
	_generator = ChunkGenerator.new(12345, 0.1, 2, 2, 2)
	# V2 切换开关：设 true 用确定性放置算法（种子+模板），设 false 用 V1（noise+CA）
	# V2 天然满足规则 A（异类间隔≥3）和规则 B（8邻域≥3同类且不全在一条直线），无需后处理
	_use_v2 = true

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
##   走 get_tile_type 单点查询，A 加载后走 cache —— 两者结果必然相同
##   （generate_chunk 内部就是调 get_tile_type）。所以加载 A 不改变
##   任何 tile 的过渡形态，刷新邻居是纯浪费。
func _load_chunk(chunk: Vector2i) -> void:
	# 1. 生成数据并写入 cache
	var data: PackedInt32Array
	if _use_v2:
		data = _generator.generate_chunk_v2(chunk.x, chunk.y)
	else:
		data = _generator.generate_chunk(chunk.x, chunk.y)
	_chunk_data_cache[chunk] = data

	# 2. 对每个 tile 算过渡形态并设 cell
	# source_id = 0（TileSet 里只有一个 TileSetAtlasSource）
	var source_id: int = 0
	for ly in ChunkGenerator.CHUNK_SIZE:
		for lx in ChunkGenerator.CHUNK_SIZE:
			var tile_x: int = chunk.x * ChunkGenerator.CHUNK_SIZE + lx
			var tile_y: int = chunk.y * ChunkGenerator.CHUNK_SIZE + ly
			var atlas: Vector2i = _compute_tile_atlas(tile_x, tile_y, data, ly, lx)
			_tile_map_layer.set_cell(Vector2i(tile_x, tile_y), source_id, atlas)

	_loaded_chunks[chunk] = true
	if DEBUG_LOG:
		print("[InfiniteTileMap] 加载 chunk ", chunk)


## 卸载单个 chunk：清除 cache + 清除 tile cell
##
## 为什么卸载后不需要刷新邻居边缘：
##   同 _load_chunk 的理由。邻居 B 边缘 tile 查 A 方向邻居，
##   卸载前走 cache，卸载后走 get_tile_type —— 结果必然相同。
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
##   - chunk 未加载 → 直接调 _generator.get_tile_type 单点查询（带 CA）
##
## 为什么不调 generate_chunk 临时生成整个 chunk：
##   之前版本这样做，导致性能爆炸：
##     - 每个 tile 查 8 邻居 → 8 次 _get_tile_type_at
##     - 未命中 cache 时 generate_chunk 生成 256 个 tile 数据
##     - 但只用其中 1 个 → 浪费 255 次计算
##     - 49 chunk 加载 → 上亿次 hash+noise 调用，编辑器卡死
##   改成单点查询 get_tile_type(wx, wy)：
##     - 只算需要的那个 tile（含 CA，CA 只查 8 邻居原始 noise，不递归）
##     - 开销 = 9 次 hash+noise per tile，可接受
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
	# cache 未命中：单点查询（带 CA，不生成整个 chunk）
	return _generator.get_tile_type(world_tile_x, world_tile_y) if not _use_v2 \
		else _generator.get_tile_type_v2(world_tile_x, world_tile_y)


## 计算单个 tile 的 atlas coord（8 邻居 + fallback 链）
## 输入：世界 tile 坐标 + 当前 chunk 的 data（避免重复查 cache）
## 输出：atlas coord
##
## 算法：
##   1. 取当前 tile 类型 T
##   2. 查 8 邻居类型（跨 chunk 查询）
##   3. 算 8 位掩码 form8 (0-255)
##   4. 查 _TERRAIN_TRANSITION_ATLAS_8[T][form8] —— 优先用完整 8 邻居贴图
##   5. 缺失 → 取边位算 form4 (0-15)，查 _TERRAIN_EDGE_ATLAS[T][form4] —— fallback 到边形态
##   6. 还缺失 → 用 _TERRAIN_ATLAS[T] 纯地块贴图
##
## fallback 链的好处：用户可渐进配置
##   - 先配 16 种边形态（基础过渡）
##   - 再按需加 8 邻居角形态（内角/外角细节）
func _compute_tile_atlas(world_tile_x: int, world_tile_y: int, data: PackedInt32Array, local_y: int, local_x: int) -> Vector2i:
	var CS: int = ChunkGenerator.CHUNK_SIZE
	var terrain: int = data[local_y * CS + local_x]

	# 查 8 邻居类型（顺时针：上、右上、右、右下、下、左下、左、左上）
	var t_top: int
	var t_top_right: int
	var t_right: int
	var t_bottom_right: int
	var t_bottom: int
	var t_bottom_left: int
	var t_left: int
	var t_top_left: int

	# 性能优化：chunk 内部 tile（非边缘）的 8 邻居全在同一 chunk 的 data 里，
	# 直接用数组索引取，跳过 _get_tile_type_at（省掉 Dictionary 查找 + 函数调用）。
	# 196/256=77% 的 tile 走这条快速路径。结果完全相同（data 里的值就是 get_tile_type 的输出）。
	if local_x > 0 and local_x < CS - 1 and local_y > 0 and local_y < CS - 1:
		var row_up: int = (local_y - 1) * CS
		var row_mid: int = local_y * CS
		var row_dn: int = (local_y + 1) * CS
		t_top = data[row_up + local_x]
		t_top_right = data[row_up + local_x + 1]
		t_right = data[row_mid + local_x + 1]
		t_bottom_right = data[row_dn + local_x + 1]
		t_bottom = data[row_dn + local_x]
		t_bottom_left = data[row_dn + local_x - 1]
		t_left = data[row_mid + local_x - 1]
		t_top_left = data[row_up + local_x - 1]
	else:
		# 边缘 tile：邻居可能跨 chunk，走通用查询
		t_top = _get_tile_type_at(world_tile_x, world_tile_y - 1)
		t_top_right = _get_tile_type_at(world_tile_x + 1, world_tile_y - 1)
		t_right = _get_tile_type_at(world_tile_x + 1, world_tile_y)
		t_bottom_right = _get_tile_type_at(world_tile_x + 1, world_tile_y + 1)
		t_bottom = _get_tile_type_at(world_tile_x, world_tile_y + 1)
		t_bottom_left = _get_tile_type_at(world_tile_x - 1, world_tile_y + 1)
		t_left = _get_tile_type_at(world_tile_x - 1, world_tile_y)
		t_top_left = _get_tile_type_at(world_tile_x - 1, world_tile_y - 1)

	# 算 8 位掩码
	var form8: int = TerrainTransition.compute_form_8(
		t_top == terrain, t_top_right == terrain,
		t_right == terrain, t_bottom_right == terrain,
		t_bottom == terrain, t_bottom_left == terrain,
		t_left == terrain, t_top_left == terrain
	)

	# 纯地块变体：form8=255（8邻居全同类）= 真正的内部 tile
	# 用变体打破视觉重复（如草地有多个平替贴图，按权重分布）
	if form8 == 255 and _TERRAIN_VARIANTS.has(terrain) and not _TERRAIN_VARIANTS[terrain].is_empty():
		return _pick_variant(terrain, world_tile_x, world_tile_y)

	# fallback 链 1：查 8 邻居完整贴图表
	var table_8: Dictionary = _TERRAIN_TRANSITION_ATLAS_8.get(terrain, {})
	if table_8.has(form8):
		return table_8[form8]

	# fallback 链 2：取边位算 4 边形态，查边形态贴图表
	var form4: int = TerrainTransition.extract_edge_form(form8)
	var table_edge: Dictionary = _TERRAIN_EDGE_ATLAS.get(terrain, {})
	if table_edge.has(form4):
		return table_edge[form4]

	# fallback 链 3：纯地块贴图
	return _TERRAIN_ATLAS.get(terrain, Vector2i.ZERO)


## 变体选择：根据 tile 世界坐标 hash，按权重选一个变体贴图
## 输入：地形类型 + tile 世界坐标
## 输出：atlas coord
##
## 算法：
##   1. 用 _variant_hash 算 hash(tile_x, tile_y) → [0, 1)
##   2. hash * 总权重 = target（落在 [0, 总权重) 区间）
##   3. 累加权重，target 落在哪个变体的区间就选哪个
##
## 为什么不用 ChunkGenerator._hash_2d：
##   - _hash_2d 是 (seed*A) ^ (x*B) ^ (y*C) 简单 XOR 结构，
##     设计用于 value noise（通过 smoothstep 插值产生平滑噪声）
##   - 变体选择是单点查询无插值，相邻 tile 的 hash 值相关性高，
##     会导致权重小的变体大片连续出现（空间聚集）
##   - 变体是纯渲染层，不需要双端一致（服务端不关心贴图），可以用强 hash
##
## _variant_hash 用 MurmurHash3 finalizer（avalanche）：
##   输入差 1，输出约一半位翻转，相邻 tile hash 差异极大，分布均匀。
static func _pick_variant(terrain: int, tile_x: int, tile_y: int) -> Vector2i:
	var variants: Array = _TERRAIN_VARIANTS.get(terrain, [])
	if variants.is_empty():
		return _TERRAIN_ATLAS.get(terrain, Vector2i.ZERO)

	# 算总权重
	var total_weight: int = 0
	for v in variants:
		total_weight += v.weight
	if total_weight <= 0:
		return _TERRAIN_ATLAS.get(terrain, Vector2i.ZERO)

	# hash → [0, 1) → target ∈ [0, total_weight)
	var h: float = _variant_hash(tile_x, tile_y)
	var target: int = int(h * total_weight)

	# 累加权重找区间
	var acc: int = 0
	for v in variants:
		acc += v.weight
		if target < acc:
			return v.atlas

	# 兜底（浮点精度边界，理论上不会到这）
	return variants.back().atlas


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
