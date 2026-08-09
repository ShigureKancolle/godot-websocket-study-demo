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
    3. get_block_type_v3(block_x, block_y) → int
       block 级别的地形类型。用 value noise 产生成片区域，避免碎块。
       当前只区分 SAND 和 GRASS。扩展时在此函数增加 DIRT/BRICK 判断。
    4. get_tile_type_v3(world_tile_x, world_tile_y) → int
       单点查询。同一个 block 的 4 个 tile 返回相同类型。
    5. generate_chunk_v3(chunk_x, chunk_y) → PackedInt32Array
       生成整个 chunk 的 tile 数据，索引 = local_y * CHUNK_SIZE + local_x。

============================================================================
 2×2 block 生成算法
============================================================================
设计原则（用户决策）：
   1. 地图以 2×2 tile 的 block 为最小生成单位，每个 block 的 4 个 tile 同类型
   2. 唯一规则：异类非草地地形之间必须有草地间隔（当前只有 SAND+GRASS，自然满足）
   3. 过渡贴图在草地上做（改变草地贴图适应邻居），而非改变沙地贴图
   4. 不需要 CA、不需要修剪

block 坐标系：
   block 坐标 = floor(world_tile / BLOCK_SIZE)
   block 内局部坐标 = world_tile - block * BLOCK_SIZE ∈ {0, 1}
   block 原点 = block 坐标 × BLOCK_SIZE（左上角 tile 的世界坐标）

渲染流程（在 InfiniteTileMap 中）：
   1. generate_chunk_v3 生成每个 tile 的 block type
   2. 非草地 tile → 用默认贴图
   3. 草地 tile → 查 block 的 8 邻居类型 → 算 form8 → 旋转归一化 → 查草地形态表
      → 选 MyTiledCell → 旋转 → 按 block 内位置抽 TiledCell → set_cell

扩展性：
   当前只做 SAND 一种非草地。加入 DIRT/BRICK 时：
   - get_block_type_v3 增加类型判断
   - 草地形态表的 key 从"是否非草地"改为"具体哪种非草地"（可拆成多个掩码）
   - 异类间隔规则需要检查（种子点距离或后处理）
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
	WATER,  # 水(障碍,以宏块为单位生成:竖排 2 block = 8 tile)
}

# Chunk 边长（tile 数）。双端必须一致。
const CHUNK_SIZE: int = 16

# block 边长（tile 数）。2 = 每 block 含 2×2=4 个 tile。
# 双端必须一致。CHUNK_SIZE=16 能被 BLOCK_SIZE=2 整除，chunk 边界和 block 边界对齐。
const BLOCK_SIZE: int = 2

# block type 生成的 noise scale。
# 0.15 = 每 ~7 个 block 一个噪声周期，产生中等大小的区域（约 7×7 block = 14×14 tile）
# 调大 → 更碎；调小 → 更大片。
const V3_NOISE_SCALE: float = 0.15

# SAND 激活阈值。noise < 此值 → SAND，否则 GRASS。
# 0.35 = ~35% SAND 覆盖率。
const V3_SAND_THRESHOLD: float = 0.35

# ---------------------------------------------------------------------------
# 水地形（以「水宏块」为单位生成）
# ---------------------------------------------------------------------------
# 水的特殊规则：每次生成占 1 block 宽 × 2 block 高 = 2×4 = 8 tile，
# 样式是「竖着排列的两个 block」。因此不能像沙地那样每 block 独立判定，
# 而是以更大的「水宏块」为判定单位 —— 同一宏块内的 2 个 block 永远同类型。
#
# 双端一致约束：宏块坐标公式、噪声调用、阈值必须和 map_generator.py 一字不差。
# 宏块坐标 = floor(block / WATER_MACRO)，天然保证竖排 2 block 成对共享同一 mb_y。

# 水宏块尺寸（block 数）。W=1 宽 × H=2 高 = 2×4 tile = 8 tile。
const WATER_MACRO_W: int = 1
const WATER_MACRO_H: int = 2

# 水生成的独立噪声尺度。和沙地噪声（V3_NOISE_SCALE）分开，水有自己独立的分布。
# 0.08 = 每 ~12 个宏块一个噪声周期，产生中等大小的水域。
const WATER_NOISE_SCALE: float = 0.08

# 水激活阈值（固定值，不开放配置）。noise < 此值 → WATER。
# 独立噪声层，水可能覆盖原本的 SAND/GRASS 区域。
# 0.25：seed=12345 时玩家起始 3chunk 范围内可见水域（原 0.15 太稀，看不到水）
const WATER_THRESHOLD: float = 0.25


# ===========================================================================
# 配置（构造时确定，运行时不变）
# ===========================================================================
var _seed: int = 0


func _init(seed: int = 0) -> void:
	_seed = seed


# ===========================================================================
# 对外接口
# ===========================================================================

## 查询 block 的地形类型
## 纯函数，跨 chunk 友好。用 value noise 产生成片区域，避免碎块。
##
## 当前区分 SAND / GRASS / WATER。扩展时在此函数增加 DIRT/BRICK 判断。
##
## 判定优先级：
##   1. 水宏块判定（最高）：水以「竖排 2 block = 8 tile」为整体生成，
##      用独立噪声层。同一宏块内的 2 个 block 算出相同 mb_y → 同类型。
##   2. 原有 SAND/GRASS 判定：value noise 每 block 独立。
func get_block_type_v3(block_x: int, block_y: int) -> int:
	# 1. 水宏块判定（优先级最高，独立噪声层）
	#    宏块 = WATER_MACRO_W block 宽 × WATER_MACRO_H block 高。
	#    竖排 2 block 成对共享 mb_y（floor 除法，双端一致）。
	var mb_x: int = int(floor(float(block_x) / WATER_MACRO_W))
	var mb_y: int = int(floor(float(block_y) / WATER_MACRO_H))
	var n_water: float = _value_noise_2d(
		mb_x * WATER_NOISE_SCALE,
		mb_y * WATER_NOISE_SCALE
	)
	if n_water < WATER_THRESHOLD:
		return TerrainType.WATER

	# 2. 原有 SAND/GRASS 判定
	var n: float = _value_noise_2d(
		block_x * V3_NOISE_SCALE,
		block_y * V3_NOISE_SCALE
	)
	if n < V3_SAND_THRESHOLD:
		return TerrainType.SAND
	return TerrainType.GRASS


## 单点查询。世界 tile 坐标 → 地形类型
## 同一个 block 的 4 个 tile 返回相同类型。
func get_tile_type_v3(world_tile_x: int, world_tile_y: int) -> int:
	var bx: int = int(floor(float(world_tile_x) / BLOCK_SIZE))
	var by: int = int(floor(float(world_tile_y) / BLOCK_SIZE))
	return get_block_type_v3(bx, by)


## 生成整个 chunk 的 tile 数据
## 返回 PackedInt32Array，索引 = local_y * CHUNK_SIZE + local_x
## 同一个 block 的 4 个 tile 类型相同（由 get_block_type_v3 保证）
func generate_chunk_v3(chunk_x: int, chunk_y: int) -> PackedInt32Array:
	var CS: int = CHUNK_SIZE
	var data := PackedInt32Array()
	data.resize(CS * CS)
	for ly in CS:
		for lx in CS:
			var wx: int = chunk_x * CS + lx
			var wy: int = chunk_y * CS + ly
			data[ly * CS + lx] = get_tile_type_v3(wx, wy)
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
	# 归一化到 [0, 1)。用 float(u32_max) 而非 4294967295.0 显得自解释
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
