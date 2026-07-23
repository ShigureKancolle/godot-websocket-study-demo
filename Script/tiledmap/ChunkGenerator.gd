'''
文件: client/Script/tiledmap/ChunkGenerator.gd
作用: 纯函数式区块生成器 —— 输入 chunk 坐标，输出该 chunk 内每个 tile 的地形类型

============================================================================
 核心设计：双端一致生成
============================================================================
本项目选择了"服务器持有种子，双端一致生成"的架构（详见 docs/client-ui.md）。
这意味着同一 chunk 坐标，Python 端和 GDScript 端必须产出【完全相同】的 tile 数据。

跨语言一致性的关键约束：
    1. 只用整数运算 + 32 位掩码（避免浮点数精度差异、避免整数宽度差异）
    2. 每个乘法后立即 & 0xFFFFFFFF（防止 64 位溢出在双端表现不同）
    3. hash 函数用同一组魔法常量 + MurmurHash3 finalizer（双端必须一字不差地复制）
    4. value noise 的插值顺序、floor 行为双端一致

本文件是客户端实现。未来服务端会在 server/game/map_generator.py 实现
【完全相同的算法】，用同一份 seed 产出相同结果。

============================================================================
 算法分层
============================================================================
    1. _hash_2d(seed, x, y) → [0, 1]
       整数哈希（含 MurmurHash3 finalizer），输入整数坐标，输出 [0, 1] 浮点。
       这是底层噪声源。
    2. _value_noise_2d(x, y) → [0, 1]
       对网格点采样 hash 值，双线性插值（smoothstep）得到连续噪声。
       value noise 比 Perlin 简单，但跨语言一致性更容易保证。
    3. _raw_type_at(world_tile_x, world_tile_y) → int
       原始 noise 类型（无 CA）。纯函数，跨 chunk 友好。
       用 3 个独立噪声通道（同一 noise，不同采样偏移）：
         - n_main < 0.25 → SAND（基础低地，~25%）
         - n_dirt > 0.83 → DIRT（独立 patch，~12.5%）
         - n_brick > 0.80 → BRICK（独立 patch，~12.5%）
         - 其他 → GRASS（默认，~50%）
       独立噪声通道让 DIRT 和 BRICK 从独立随机分布产生，几乎不相邻。
    4. get_tile_type(world_tile_x, world_tile_y) → int
       带 CA 的单点查询：查【4条边邻居 + 4个对角邻居】的原始 noise 类型，
       应用1次 cellular automata 规则。CA 条件（任一不满足→变成周围多数类型）：
         - 4 边同类 < 阈值（默认2）
         - 4 角同类 < 阈值
         - 横向(左+右)同类 < 1
         - 竖向(上+下)同类 < 1
         - 斜向(4角)同类 < 1
       注意：CA 只迭代1次，邻居查询用原始 noise 而非 CA 后值。
       这保证跨 chunk 边界确定性（不需要邻居 chunk 的 CA 结果）。
       规则保证每个 tile 在边/角/横/竖/斜方向都有足够连接，地块成片。
    5. generate_chunk(chunk_x, chunk_y) → PackedInt32Array
       生成整个 chunk 的 tile 数据，索引 = local_y * CHUNK_SIZE + local_x。

============================================================================
 为什么加 Cellular Automata 后处理
============================================================================
原 noise 地形太碎，会产生大量单格孤岛（一个 tile 被异类包围）和单边细条。
用户的 tileset 资源里，过渡贴图基于 form4（4 边掩码）和 form8（8 邻居掩码），
孤岛（form4=0）和单边细条（form4=1/2/4/8）会导致贴图匹配失败或视觉突兀；
"4 边同类但 4 角全异"的对角孤岛（form8=85/17/51 等"只有边没有角"的形态）
也会让 form8 匹配不稳定。

CA 规则：tile 的【4条边邻居】和【4个对角邻居】分别约束，
同类少于阈值（默认2）就变成周围多数类型。边和对角都至少 2 个同类才保留。
阈值2 同时消除边方向孤岛（form4=0/1/2/4/8）和对角方向孤岛（form8 只有边没有角），
让地块在 8 邻居意义上成片，form4 + form8 过渡贴图匹配都稳定。
迭代1次即可消除孤岛和细条，让地块至少成片。
迭代1次而非多次：多次迭代需要邻居的 CA 结果，跨 chunk 边界要外扩多圈；
1次迭代只需邻居的原始 noise，跨 chunk 用 _raw_type_at 即可，简单且双端一致。
'''

extends RefCounted
class_name ChunkGenerator


# ===========================================================================
# 地形类型枚举
# ===========================================================================
# 双端共享的"是什么"语义。服务端只需知道类型，不需要 atlas coord。
# atlas coord 映射是客户端渲染层的事（见 InfiniteTileMap.gd 的 _TERRAIN_ATLAS）。
enum TerrainType {
	GRASS,  # 草地
	SAND,   # 沙地
	DIRT,   # 泥地
	BRICK,  # 砖地
}

# Chunk 边长（tile 数）。双端必须一致。
const CHUNK_SIZE: int = 16

# 地形类型总数（对应 TerrainType 枚举数量）。CA 统计邻居时用。
const TERRAIN_COUNT: int = 4


# ===========================================================================
# 配置（构造时确定，运行时不变）
# ===========================================================================
var _seed: int = 0
var _noise_scale: float = 0.1  # 越大越碎。0.1 = 每 10 tile 一个噪声周期

# 邻居同类阈值：tile 的 4 条边邻居和 4 个对角邻居里，同类少于 this 就变成周围多数类型。
# 边和对角分别约束：两条都要 ≥ 阈值才保留当前类型。
# 2 = 4 边里至少 2 个同类 且 4 角里至少 2 个同类才保留。
# 同时消除边方向孤岛和对角方向孤岛，让地块在 8 邻居意义上成片，
# 过渡贴图（form4 + form8）匹配都稳定。
# 双端必须一致。
var _ca_threshold: int = 2

# CA 迭代次数（默认 1）。
# 1 次消除一阶孤岛（raw noise 产生的孤岛）。
# 2 次额外消除二阶孤岛（CA 把 tile A 变成多数类型后，邻居 B 因 A 变了反而不满足 CA，
# 但 1 次迭代不会重新检查 B；2 次迭代会重新检查 B）。
# 注意：>1 次时，get_tile_type（单点查询，跨 chunk 用）仍只迭代 1 次，
# chunk 边缘 tile 的 CA 深度可能和内部不一致（二阶孤岛在边缘不被消除），但内部一致。
# 双端必须一致。
var _ca_iterations: int = 1

# DIRT/BRICK 最小间隔 tile 数（默认 0=不检查）。
# >0 时，generate_chunk 后处理扫描：DIRT 和 BRICK 切比雪夫距离 ≤ this 内有另一类型 → 变 GRASS。
# 2 = DIRT 和 BRICK 距离 ≥ 3（中间至少 2 个草地 tile）。
# 只在 chunk 内部扫描，跨 chunk 边界的间隔可能不完美（边缘 tile 的邻居在另一个 chunk）。
# 双端必须一致。
var _terrain_spacing: int = 0

# V2 生长结果缓存：Vector2i(seed_gx, seed_gy) -> Dictionary[Vector2i(world_tile) -> terrain]
# 避免每次查询都重新模拟生长。生长是纯函数，缓存安全。
var _seed_patch_cache: Dictionary = {}

# V2 种子激活结果缓存：Vector2i(seed_gx, seed_gy) -> Dictionary{active, terrain}
# _check_seed_activation 的异类互斥检查开销大（15×15 范围），缓存避免重复计算
var _seed_activation_cache: Dictionary = {}


func _init(seed: int = 0, noise_scale: float = 0.1, ca_threshold: int = 2,
		ca_iterations: int = 1, terrain_spacing: int = 0) -> void:
	_seed = seed
	_noise_scale = noise_scale
	_ca_threshold = ca_threshold
	_ca_iterations = ca_iterations
	_terrain_spacing = terrain_spacing


# ===========================================================================
# 对外接口
# ===========================================================================

## 原始 noise 类型（无 CA）。纯函数，跨 chunk 友好。
## 任何 tile 都能独立查询，是 CA 邻居查询的基础。
##
## 用 3 个独立 noise 通道（同一 noise 函数，不同采样偏移）：
##   - n_main:  主 noise，决定 SAND vs GRASS 基础地形
##   - n_dirt:  独立 noise，决定 DIRT patch 分布
##   - n_brick: 独立 noise，决定 BRICK patch 分布
##
## 为什么用独立噪声通道：
##   单 noise + 阈值切分时，DIRT 和 BRICK 在 noise 值上相邻（如 0.6-0.8 vs 0.8-1.0），
##   value noise 是连续函数，相邻区间必然空间相邻 → BRICK 总被 DIRT 包围。
##   独立噪声通道让 DIRT 和 BRICK 各自从独立随机分布中产生，
##   两个独立分布在空间上"碰巧挨着"的概率极低（如同两次独立掷骰子都到6 = 1/36）。
##   万一相邻，CA 后处理会把边界 tile 变成 GRASS（少数派被多数派吞并）。
##
## 偏移常量（双端必须一致）：
##   DIRT 采样偏移 (10000, 10000)
##   BRICK 采样偏移 (20000, 20000)
##   偏移足够大确保采样网格完全不重叠（noise_scale=0.1 时 10000 = 10万 tile 距离）
func _raw_type_at(world_tile_x: int, world_tile_y: int) -> int:
	var n_main: float = _value_noise_2d(
		world_tile_x * _noise_scale,
		world_tile_y * _noise_scale
	)
	# SAND vs GRASS 基础地形
	if n_main < 0.25:
		return TerrainType.SAND
	# 剩余 75% 区域里，用独立 noise 决定 DIRT/BRICK patch
	var n_dirt: float = _value_noise_2d(
		(world_tile_x + 10000) * _noise_scale,
		(world_tile_y + 10000) * _noise_scale
	)
	if n_dirt > 0.83:
		return TerrainType.DIRT
	# 剩余 62.5% 区域里，用独立 noise 决定 BRICK patch
	var n_brick: float = _value_noise_2d(
		(world_tile_x + 20000) * _noise_scale,
		(world_tile_y + 20000) * _noise_scale
	)
	if n_brick > 0.80:
		return TerrainType.BRICK
	# 默认草地
	return TerrainType.GRASS


## 带 CA 的单点查询：世界 tile 坐标 → 地形类型
## 这是无限地图的核心查询接口。任何 tile 都能独立查询，无需生成整个 chunk。
##
## 算法：
##   1. 取当前 tile 原始 noise 类型 current
##   2. 统计【4条边邻居】+【4个对角邻居】的原始 noise 类型（共 8 个）
##   3. 分别统计：
##      - edge_count_current: 4 边同类总数
##      - corner_count_current: 4 角同类总数
##      - horizontal_count: 横向(左+右)同类数
##      - vertical_count: 竖向(上+下)同类数
##   4. CA 规则（任一条件不满足 → 变成周围多数类型）：
##      - edge_count < _ca_threshold（4 边同类不足）
##      - corner_count < _ca_threshold（4 角同类不足）
##      - horizontal < 1（横向无连接）
##      - vertical < 1（竖向无连接）
##      - corner_count < 1（斜向无连接，被 < _ca_threshold 覆盖但显式写出）
##   5. 否则保留 current
##
## 为什么加横竖斜各≥1约束：
##   只看总数(4边≥2)允许"同类集中在单一方向"的情况，
##   如横向2连但竖向0连(form4=10/LR)，或竖向2连但横向0连(form4=5/TB)。
##   这种 tile 虽然边同类总数≥2，但在某个方向完全断开，视觉上是细条。
##   要求横竖斜各≥1，保证每个 tile 在三个方向都有连接，地块更成片。
##
## 多数类型统计：用 8 邻居合并 counts（边+角），选最大者。
## 平局处理：遍历 0..TERRAIN_COUNT-1，>max 才更新（不 >=），平局取小枚举值。确定性。
func get_tile_type(world_tile_x: int, world_tile_y: int) -> int:
	var current: int = _raw_type_at(world_tile_x, world_tile_y)
	# 单点查询版：8 邻居各调 _raw_type_at（跨 chunk 用，无法批量优化）
	var t_top: int = _raw_type_at(world_tile_x, world_tile_y - 1)
	var t_top_right: int = _raw_type_at(world_tile_x + 1, world_tile_y - 1)
	var t_right: int = _raw_type_at(world_tile_x + 1, world_tile_y)
	var t_bottom_right: int = _raw_type_at(world_tile_x + 1, world_tile_y + 1)
	var t_bottom: int = _raw_type_at(world_tile_x, world_tile_y + 1)
	var t_bottom_left: int = _raw_type_at(world_tile_x - 1, world_tile_y + 1)
	var t_left: int = _raw_type_at(world_tile_x - 1, world_tile_y)
	var t_top_left: int = _raw_type_at(world_tile_x - 1, world_tile_y - 1)
	return _apply_ca(current, t_top, t_top_right, t_right, t_bottom_right,
		t_bottom, t_bottom_left, t_left, t_top_left)


## CA 核心逻辑（纯函数，无 IO）
## 输入：当前 tile 类型 + 8 邻居类型（顺时针：上、右上、右、右下、下、左下、左、左上）
## 输出：CA 后的类型
##
## 两个调用路径共享此函数，保证逻辑一致：
##   - get_tile_type（单点查询，跨 chunk 用）
##   - generate_chunk（批量优化，用 raw 数组查邻居）
##
## CA 条件（任一不满足→变成周围多数类型）：
##   - 4 边同类 < 阈值
##   - 4 角同类 < 阈值
##   - 横向(左+右)同类 < 1
##   - 竖向(上+下)同类 < 1
##   - 斜向(4角)同类 < 1
func _apply_ca(current: int, t_top: int, t_top_right: int, t_right: int,
	t_bottom_right: int, t_bottom: int, t_bottom_left: int, t_left: int,
	t_top_left: int) -> int:
	var counts: Array = [0, 0, 0, 0]
	var edge_count_current: int = 0
	var corner_count_current: int = 0
	var horizontal_count: int = 0
	var vertical_count: int = 0

	# 4 边：上(竖) 右(横) 下(竖) 左(横)
	var edge_neighbors: Array = [t_top, t_right, t_bottom, t_left]
	for i in range(4):
		var nt: int = edge_neighbors[i]
		counts[nt] += 1
		if nt == current:
			edge_count_current += 1
			if i == 1 or i == 3:
				horizontal_count += 1
			else:
				vertical_count += 1

	# 4 角：右上 右下 左下 左上
	var corner_neighbors: Array = [t_top_right, t_bottom_right, t_bottom_left, t_top_left]
	for nt in corner_neighbors:
		counts[nt] += 1
		if nt == current:
			corner_count_current += 1

	if edge_count_current < _ca_threshold \
		or corner_count_current < _ca_threshold \
		or horizontal_count < 1 \
		or vertical_count < 1 \
		or corner_count_current < 1:
		var max_type: int = 0
		var max_count: int = -1
		for i in range(TERRAIN_COUNT):
			if counts[i] > max_count:
				max_count = counts[i]
				max_type = i
		return max_type
	return current


## 生成整个 chunk 的 tile 数据
## 返回 PackedInt32Array，长度 = CHUNK_SIZE * CHUNK_SIZE
## 索引 = local_y * CHUNK_SIZE + local_x，值 = TerrainType 枚举
##
## 性能优化（独立噪声通道后必须）：
##   独立噪声让 _raw_type_at 从 1 次 noise 变 3 次，generate_chunk 若仍对
##   每个 tile 调 9 次 _raw_type_at = 256×9 = 2304 次 noise 调用，卡顿严重。
##   优化：先算外扩 raw 数组，CA 和间隔扫描从数组取邻居。
##   只算 (CS+2M)² 次 raw_type（M=外扩圈数），而非 256×9。
##
## 三阶段流水线：
##   1. raw 数组（外扩 M 圈，M = max(_ca_iterations, _terrain_spacing)）
##   2. CA 迭代 _ca_iterations 次（在 CS×CS 区域做，从数组查邻居）
##   3. 间隔后处理（DIRT/BRICK 距离 ≤ _terrain_spacing 内有另一类型 → GRASS）
##
##   get_tile_type 保持单点查询版（跨 chunk 查询用，无法批量优化）。
##   两个路径共享 _apply_ca，逻辑一致。
func generate_chunk(chunk_x: int, chunk_y: int) -> PackedInt32Array:
	var CS: int = CHUNK_SIZE
	# 外扩圈数 = max(CA 迭代, 间隔扫描)。两者都需要外扩邻居。
	var margin: int = max(_ca_iterations, _terrain_spacing)
	var ES: int = CS + 2 * margin  # 外扩后的边长

	# === 阶段 1: 算 raw 数组（外扩 margin 圈）===
	# 索引 = (ly + margin) * ES + (lx + margin)，ly/lx ∈ [-margin, CS+margin-1]
	var current := PackedInt32Array()
	current.resize(ES * ES)
	for ly in range(-margin, CS + margin):
		for lx in range(-margin, CS + margin):
			var wx: int = chunk_x * CS + lx
			var wy: int = chunk_y * CS + ly
			current[(ly + margin) * ES + (lx + margin)] = _raw_type_at(wx, wy)

	# === 阶段 2: CA 迭代 ===
	# 每轮用 current 算 next（不原地更新，避免顺序依赖）
	# next 初始化为 current 的副本，只更新 CS×CS 区域，外扩圈保持 raw
	for _iter in range(_ca_iterations):
		var next := current.duplicate()
		for ly in CS:
			for lx in CS:
				var r_mid: int = (ly + margin) * ES + (lx + margin)
				var r_up: int = (ly + margin - 1) * ES + (lx + margin)
				var r_dn: int = (ly + margin + 1) * ES + (lx + margin)
				var t_top: int = current[r_up]
				var t_top_right: int = current[r_up + 1]
				var t_right: int = current[r_mid + 1]
				var t_bottom_right: int = current[r_dn + 1]
				var t_bottom: int = current[r_dn]
				var t_bottom_left: int = current[r_dn - 1]
				var t_left: int = current[r_mid - 1]
				var t_top_left: int = current[r_up - 1]
				next[r_mid] = _apply_ca(current[r_mid], t_top, t_top_right, t_right,
					t_bottom_right, t_bottom, t_bottom_left, t_left, t_top_left)
		current = next

	# === 阶段 3: 间隔后处理 ===
	# DIRT/BRICK 切比雪夫距离 ≤ _terrain_spacing 内有另一类型 → GRASS
	# 在 CS×CS 区域做，从 current 数组查邻居（含外扩圈）
	if _terrain_spacing > 0:
		var next := current.duplicate()
		for ly in CS:
			for lx in CS:
				var idx: int = (ly + margin) * ES + (lx + margin)
				var t: int = current[idx]
				if t == TerrainType.DIRT or t == TerrainType.BRICK:
					var has_conflict: bool = false
					for dy in range(-_terrain_spacing, _terrain_spacing + 1):
						for dx in range(-_terrain_spacing, _terrain_spacing + 1):
							if dx == 0 and dy == 0:
								continue
							var nidx: int = (ly + margin + dy) * ES + (lx + margin + dx)
							var nt: int = current[nidx]
							# DIRT 检查附近有无 BRICK，BRICK 检查附近有无 DIRT
							if (t == TerrainType.DIRT and nt == TerrainType.BRICK) \
				or (t == TerrainType.BRICK and nt == TerrainType.DIRT):
								has_conflict = true
								break
						if has_conflict:
							break
					if has_conflict:
						next[idx] = TerrainType.GRASS
		current = next

	# === 提取 CS×CS 结果 ===
	var data := PackedInt32Array()
	data.resize(CS * CS)
	for ly in CS:
		for lx in CS:
			data[ly * CS + lx] = current[(ly + margin) * ES + (lx + margin)]
	return data


# ===========================================================================
# V2: 确定性生长算法（种子 + 2×2 核心 + 确定性生长，替代 V1 的 noise + CA）
# ===========================================================================
# 设计原则：
#   1. 种子是生长起点和身份标识，不是固定结构
#   2. 从 2×2 核心开始，通过确定性生长规则长成随机大小和形状
#   3. 种子点异类互斥（距离 ≥ 2*MAX_GROWTH_RADIUS+3），保证生长后规则 A 天然满足
#   4. 生长每步检查规则 B，不满足则跳过该位置
#   5. 任何 chunk 只看自己范围内的种子点，完美跨边界
#
# 规则 A（间隔）：异类特殊地形切比雪夫距离 ≥ 3
#   → 种子互斥距离 ≥ 2*MAX_GROWTH_RADIUS + 3，生长范围限制保证
# 规则 B（成片）：8 邻域 ≥3 同类且不全在一条直线
#   → 2×2 核心天然满足；生长时检查新 tile 放入后是否满足
#
# 概率控制（草50% / 其他平分）：
#   - SEED_ACTIVATION_RATE 控制种子激活率（特殊地形覆盖率）
#   - 激活后按 1/3 概率分给 SAND/DIRT/BRICK
#   - GROW_PROB 控制每步生长概率（斑块大小）

# V2 配置常量
const SEED_GRID_SIZE: int = 8       # 种子粗网格大小（每 8×8 tile 一个候选点）
const SEED_CORE_SIZE: int = 2       # 种子核心大小（2×2 起步）
const SEED_ACTIVATION_RATE: float = 0.35  # 种子激活概率
const MAX_GROWTH_STEPS: int = 12    # 每个种子最多生长步数
const MAX_GROWTH_RADIUS: int = 2    # 生长范围（种子原点周围 ±2 tile，斑块最大 5×5）
const GROW_PROB: float = 0.7        # 每步生长概率（hash < 此值才尝试生长）
const SEED_MUTUAL_DIST: int = 7     # 异类种子最小距离 = 2*MAX_GROWTH_RADIUS + 3
const MIN_PATCH_SIZE: int = 4       # 斑块最小格子数（= 2×2 核心）
const MAX_PATCH_SIZE: int = 12      # 斑块最大格子数（5×5 区域内）

## V2: 单点查询。世界 tile 坐标 → 地形类型
##
## 算法：
##   1. 遍历 tile 周围 3×3 种子点（覆盖最大生长范围 5×5）
##   2. 对每个激活种子，查缓存或模拟生长，得到斑块所有 tile
##   3. 检查 tile 是否在某个斑块内 → 返回该地形类型
##   4. 都不在 → 返回 GRASS
##
## 双端一致：纯整数 hash，无 RNG，生长顺序由 hash 决定（确定性）
func get_tile_type_v2(world_tile_x: int, world_tile_y: int) -> int:
	var GS: int = SEED_GRID_SIZE
	var base_gx: int = int(floor(float(world_tile_x) / GS))
	var base_gy: int = int(floor(float(world_tile_y) / GS))
	# 遍历 3×3 种子点（斑块最大 5×5，半径 2，GS=8 时 3×3 足够覆盖）
	for gy in range(-1, 2):
		for gx in range(-1, 2):
			var sgx: int = base_gx + gx
			var sgy: int = base_gy + gy
			var info: Dictionary = _check_seed_activation(sgx, sgy)
			if not info.active:
				continue
			var patch: Dictionary = _get_seed_patch(sgx, sgy, info.terrain)
			if patch.has(Vector2i(world_tile_x, world_tile_y)):
				return info.terrain
	return TerrainType.GRASS


## V2: 检查种子点是否激活
## 返回 {active: bool, terrain: int}
##
## 算法：
##   1. hash(sgx, sgy) < SEED_ACTIVATION_RATE → 通过
##   2. hash(sgx+1, sgy) 决定类型（SAND/DIRT/BRICK 各 1/3）
##   3. 异类互斥：查 SEED_MUTUAL_DIST 范围内已有种子
##      有异类且优先级低 → 不激活
##
## 优先级（确定性）：hash 值大的赢；同值时坐标小的赢
func _check_seed_activation(seed_gx: int, seed_gy: int) -> Dictionary:
	# 缓存命中（异类互斥检查开销大，15×15 范围 = 450 次 hash）
	var cache_key: Vector2i = Vector2i(seed_gx, seed_gy)
	if _seed_activation_cache.has(cache_key):
		return _seed_activation_cache[cache_key]
	var result: Dictionary = _check_seed_activation_uncached(seed_gx, seed_gy)
	_seed_activation_cache[cache_key] = result
	return result


## _check_seed_activation 的无缓存版（实际计算）
func _check_seed_activation_uncached(seed_gx: int, seed_gy: int) -> Dictionary:
	var self_hash: float = _hash_2d(_seed, seed_gx, seed_gy)
	if self_hash >= SEED_ACTIVATION_RATE:
		return {active = false, terrain = TerrainType.GRASS}
	var type_hash: float = _hash_2d(_seed + 1, seed_gx, seed_gy)
	var terrain: int
	if type_hash < 0.3333:
		terrain = TerrainType.SAND
	elif type_hash < 0.6666:
		terrain = TerrainType.DIRT
	else:
		terrain = TerrainType.BRICK
	# 异类互斥：查周围 SEED_MUTUAL_DIST 范围
	var md: int = SEED_MUTUAL_DIST
	for dy in range(-md, md + 1):
		for dx in range(-md, md + 1):
			if dx == 0 and dy == 0:
				continue
			# 切比雪夫距离检查（方阵）
			if max(abs(dx), abs(dy)) < md:
				var ngx: int = seed_gx + dx
				var ngy: int = seed_gy + dy
				var n_info: Dictionary = _check_seed_activation_simple(ngx, ngy)
				if not n_info.active or n_info.terrain == terrain:
					continue
				# 异类冲突，比优先级
				var n_hash: float = _hash_2d(_seed, ngx, ngy)
				if n_hash > self_hash:
					return {active = false, terrain = TerrainType.GRASS}
				if n_hash == self_hash:
					if ngx < seed_gx or (ngx == seed_gx and ngy < seed_gy):
						return {active = false, terrain = TerrainType.GRASS}
	return {active = true, terrain = terrain}


## 简化版种子激活检查（用于异类互斥查询，避免递归）
## 只查自身 hash + 类型，不查邻居
func _check_seed_activation_simple(seed_gx: int, seed_gy: int) -> Dictionary:
	var self_hash: float = _hash_2d(_seed, seed_gx, seed_gy)
	if self_hash >= SEED_ACTIVATION_RATE:
		return {active = false, terrain = TerrainType.GRASS}
	var type_hash: float = _hash_2d(_seed + 1, seed_gx, seed_gy)
	var terrain: int
	if type_hash < 0.3333:
		terrain = TerrainType.SAND
	elif type_hash < 0.6666:
		terrain = TerrainType.DIRT
	else:
		terrain = TerrainType.BRICK
	return {active = true, terrain = terrain}


## V2: 获取种子的斑块（带缓存）
## 返回 Dictionary[Vector2i(world_tile) -> terrain]
func _get_seed_patch(seed_gx: int, seed_gy: int, terrain: int) -> Dictionary:
	var cache_key: Vector2i = Vector2i(seed_gx, seed_gy)
	if _seed_patch_cache.has(cache_key):
		return _seed_patch_cache[cache_key]
	var patch: Dictionary = _simulate_growth(seed_gx, seed_gy, terrain)
	_seed_patch_cache[cache_key] = patch
	return patch


## V2: 模拟种子生长
## 策略（用户建议）：先定大小 → 放置 → 修剪
##   1. hash 决定目标格子数 target_size ∈ [MIN_PATCH_SIZE, MAX_PATCH_SIZE]
##   2. 从 2×2 核心开始，hash 决定生长方向，不检查规则 B 直接放入
##   3. 放到 target_size 后，反复修剪不满足规则 B 的 tile，直到所有剩余 tile 都满足
##   4. 2×2 核心天然满足规则 B（每个 tile 有 3 个同类邻居，横竖斜各 1），不会被修剪
##
## 为什么不边生长边检查：
##   2×2 核心周围的候选位置同类邻居最多 2 个，规则 B 要求 ≥3，边生长边检查会 100% 失败。
##   先放入再修剪，让 tile 互相支撑（A 放入后 B 的同类邻居 +1），能生长出更大斑块。
##
## 修剪的连锁安全性：
##   2×2 核心 4 个 tile 互为邻居，每个有 3 个同类（满足规则 B），不会被删。
##   只有生长的 tile 可能被删。删一个 tile 后，其他 tile 的邻居数 -1，
##   可能产生新的不满足，所以反复修剪直到稳定。
##
## 确定性：生长和修剪顺序由 hash 决定，任一查询模拟相同结果
func _simulate_growth(seed_gx: int, seed_gy: int, terrain: int) -> Dictionary:
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

	# 3. 生长到 target_size（不检查规则 B，直接放入）
	for step in range(MAX_GROWTH_STEPS):
		if patch.size() >= target_size:
			break
		# 3.1 hash 决定是否继续生长
		var grow_hash: float = _hash_2d(_seed + 100, seed_gx * 1000 + step, seed_gy)
		if grow_hash >= GROW_PROB:
			continue
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
			break
		# 3.3 hash 决定选哪个候选，直接放入（不检查规则 B）
		var pick_hash: float = _hash_2d(_seed + 200, seed_gx * 1000 + step, seed_gy)
		var idx: int = int(pick_hash * float(candidates.size()))
		if idx >= candidates.size():
			idx = candidates.size() - 1
		patch[candidates[idx]] = terrain

	# 4. 修剪：反复删除不满足规则 B 的 tile，直到所有剩余 tile 都满足
	var changed: bool = true
	while changed:
		changed = false
		var to_remove: Array = []
		for pos in patch.keys():
			if not _check_rule_b(pos, terrain, patch):
				to_remove.append(pos)
		for pos in to_remove:
			patch.erase(pos)
			changed = true

	return patch


## V2: 规则 B 检查
## 新 tile 放入后，它的 8 邻域中同类（在 patch 中）的数量 ≥3，
## 且不全在一条直线（横/竖/斜）上
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


## V2: 生成整个 chunk 的 tile 数据
## 优化：批量处理，避免每个 tile 重复算种子激活
##   1. data 全填 GRASS
##   2. 算 chunk 范围内的所有激活种子（3×3 种子网格，覆盖 chunk 边界）
##   3. 对每个激活种子，模拟 patch，把 patch 内的 tile 写入 data
##   4. 返回 data
##
## 性能：只算 ~9 个种子的激活（3×3 种子网格），而非 256 tile × 9 种子
func generate_chunk_v2(chunk_x: int, chunk_y: int) -> PackedInt32Array:
	var CS: int = CHUNK_SIZE
	var data := PackedInt32Array()
	data.resize(CS * CS)
	# 1. 全填 GRASS
	for i in range(CS * CS):
		data[i] = TerrainType.GRASS

	# 2. 算 chunk 覆盖的种子网格范围
	# chunk 世界 tile 范围：[cx*CS, cx*CS+CS-1] × [cy*CS, cy*CS+CS-1]
	# 种子原点 = sgx * GS，patch 最大范围 = 原点 ± (GS + MAX_GROWTH_RADIUS)
	# 所以要查的种子网格范围 = chunk tile 范围外扩 GS+MAX_GROWTH_RADIUS
	var GS: int = SEED_GRID_SIZE
	var margin: int = GS + MAX_GROWTH_RADIUS
	var min_wx: int = chunk_x * CS - margin
	var min_wy: int = chunk_y * CS - margin
	var max_wx: int = chunk_x * CS + CS - 1 + margin
	var max_wy: int = chunk_y * CS + CS - 1 + margin
	var min_sgx: int = int(floor(float(min_wx) / GS))
	var min_sgy: int = int(floor(float(min_wy) / GS))
	var max_sgx: int = int(floor(float(max_wx) / GS))
	var max_sgy: int = int(floor(float(max_wy) / GS))

	# 3. 遍历种子网格，对激活种子模拟 patch 并写入 data
	var chunk_origin_wx: int = chunk_x * CS
	var chunk_origin_wy: int = chunk_y * CS
	for sgy in range(min_sgy, max_sgy + 1):
		for sgx in range(min_sgx, max_sgx + 1):
			var info: Dictionary = _check_seed_activation(sgx, sgy)
			if not info.active:
				continue
			var patch: Dictionary = _get_seed_patch(sgx, sgy, info.terrain)
			# 把 patch 内属于本 chunk 的 tile 写入 data
			for pos: Vector2i in patch.keys():
				var lx: int = pos.x - chunk_origin_wx
				var ly: int = pos.y - chunk_origin_wy
				if lx >= 0 and lx < CS and ly >= 0 and ly < CS:
					data[ly * CS + lx] = info.terrain
	return data


# ===========================================================================
# 内部算法：hash + value noise
# ===========================================================================

## 整数哈希：输入 (seed, x, y) → [0, 1] 浮点
## 跨语言一致性的关键：每步乘法后立即掩码到 32 位无符号整数
##
## 结构：三维度独立乘法混合 → XOR 合并 → MurmurHash3 finalizer 打乱
##
## 为什么加 finalizer（avalanche）：
##   纯 XOR (seed*A)^(x*B)^(y*C) 没有位间扩散，分布质量低。
##   相邻输入（如 x 和 x+1）只改变 hash 的部分位，输出相关性高，
##   会导致某些区域系统性偏向某地形类型（如 seed=12345 时 (0,0) 附近
##   hash 值整体偏低，几乎没有砖地）。
##   finalizer 让"输入差 1 → 输出约一半位翻转"，分布均匀。
##
## 双端一致约束：Python 端必须一字不差复制整个函数（含 finalizer）。
## finalizer 是纯整数运算（XOR-shift + 乘法 + 掩码），Python 可直接实现。
##
## 常数含义：
##   - 73856093 / 19349663 / 83492791 = SPICE library hash 质数（初始混合）
##   - 0x85EBCA6B / 0xC2B2AE35 = MurmurHash3 finalizer 乘法常数（avalanche）
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


## value noise 2D：对网格点采样 hash，双线性插值得到连续噪声
## 输入是浮点坐标（通常 = tile 坐标 * noise_scale）
## 输出 [0, 1]
##
## 算法步骤：
##   1. 取 floor(x), floor(y) 得到网格点整数坐标
##   2. 计算 4 个角的 hash 值
##   3. 用 smoothstep 插值（比线性插值更平滑，避免方块感）
func _value_noise_2d(x: float, y: float) -> float:
	# floor 后转 int，双端一致（GDScript int() 是向零取整，必须先 floor）
	var xi: int = int(floor(x))
	var yi: int = int(floor(y))
	# 小数部分，范围 [0, 1)
	# 用 x - xi 而非 fmod，避免负数取模在双端行为差异
	var xf: float = x - xi
	var yf: float = y - yi

	# 4 个角的 hash 值
	var v00: float = _hash_2d(_seed, xi, yi)
	var v10: float = _hash_2d(_seed, xi + 1, yi)
	var v01: float = _hash_2d(_seed, xi, yi + 1)
	var v11: float = _hash_2d(_seed, xi + 1, yi + 1)

	# smoothstep 插值权重：3t^2 - 2t^3，比线性插值更平滑
	var u: float = _smoothstep(xf)
	var v: float = _smoothstep(yf)

	# 双线性插值
	var a: float = lerp(v00, v10, u)
	var b: float = lerp(v01, v11, u)
	return lerp(a, b, v)


## smoothstep：3t^2 - 2t^3
## 标准图形学平滑函数，双端实现一致即可
static func _smoothstep(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)
