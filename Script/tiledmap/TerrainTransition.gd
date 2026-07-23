'''
文件: client/Script/tiledmap/TerrainTransition.gd
作用: 地块过渡算法 —— 8 邻居 256 形态 autotiling，带 4 边 fallback

============================================================================
 核心设计：8 邻居 autotiling + 渐进式 fallback
============================================================================
8 邻居有 2^8 = 256 种组合，贴图配置工作量大。采用分层 fallback：

    1. 优先查 8 位掩码（0-255）对应的专用贴图
    2. 缺失 → 取 4 边位（bit 0,2,4,6）算 4 位形态（0-15），查边形态贴图
    3. 还缺失 → 用纯地块贴图

这样用户可以渐进配置：先配 16 种边形态（基础过渡），
再逐步加角形态（内角/外角细节），最终配满 256 种。

============================================================================
 8 邻居位掩码定义（顺时针，从上开始）
============================================================================
    bit 0 (1)   = 上      (0, -1)  边
    bit 1 (2)   = 右上    (1, -1)  角
    bit 2 (4)   = 右      (1, 0)   边
    bit 3 (8)   = 右下    (1, 1)   角
    bit 4 (16)  = 下      (0, 1)   边
    bit 5 (32)  = 左下    (-1, 1)  角
    bit 6 (64)  = 左      (-1, 0)  边
    bit 7 (128) = 左上    (-1, -1) 角

0~255 共 256 种形态。bit 0,2,4,6 是边邻居，bit 1,3,5,7 是角邻居。

============================================================================
 4 边 fallback 形态（16 种）
============================================================================
    边位提取：bit 0(上) bit 2(右) bit 4(下) bit 6(左) → 4 位掩码 0-15

    0=ISOLATED  1=TOP   2=RIGHT  3=TR    4=BOTTOM  5=TB   6=BR    7=TBR
    8=LEFT      9=TL    10=LR    11=TLR  12=BL     13=TBL  14=BLR  15=FULL

============================================================================
 架构位置
============================================================================
    ChunkGenerator 输出 tile 类型
        ↓
    InfiniteTileMap._compute_tile_atlas:
        1. 查当前 tile 类型 T
        2. 查 8 邻居类型（跨 chunk 查询）
        3. 算 8 位掩码 → form8 (0-255)
        4. 查 _TERRAIN_TRANSITION_ATLAS_8[T][form8]
        5. 缺失 → 取边位算 form4 (0-15)，查 _TERRAIN_EDGE_ATLAS[T][form4]
        6. 还缺失 → 用 从v[T] 纯地块贴图
'''

extends RefCounted
class_name TerrainTransition


# ===========================================================================
# 8 邻居位掩码常量
# ===========================================================================
const BIT_TOP: int = 1          # bit 0 (边)
const BIT_TOP_RIGHT: int = 2    # bit 1 (角)
const BIT_RIGHT: int = 4        # bit 2 (边)
const BIT_BOTTOM_RIGHT: int = 8 # bit 3 (角)
const BIT_BOTTOM: int = 16      # bit 4 (边)
const BIT_BOTTOM_LEFT: int = 32 # bit 5 (角)
const BIT_LEFT: int = 64        # bit 6 (边)
const BIT_TOP_LEFT: int = 128   # bit 7 (角)

# 4 边位掩码（用于 fallback）
const BIT_EDGE_TOP: int = 1     # = BIT_TOP
const BIT_EDGE_RIGHT: int = 4   # = BIT_RIGHT
const BIT_EDGE_BOTTOM: int = 16 # = BIT_BOTTOM
const BIT_EDGE_LEFT: int = 64   # = BIT_LEFT


# ===========================================================================
# 4 边 fallback 形态枚举（值 = 4 边位掩码，0-15）
# ===========================================================================
# 命名规则：T=上 R=右 B=下 L=左，组合表示哪些方向有同类型连接
enum Form {
	ISOLATED = 0,        # 0000 孤岛：四周都不同
	TOP = 1,             # 0001 只连上
	RIGHT = 4,           # 0100 只连右
	TR = 5,              # 0101 上右角
	BOTTOM = 16,         # 10000 只连下
	TB = 17,             # 10001 上下直通
	BR = 20,             # 10100 下右角
	TBR = 21,            # 10101 T 型（缺左）
	LEFT = 64,           # 1000000 只连左
	TL = 65,             # 1000001 上左角
	LR = 68,             # 1000100 左右直通
	TLR = 69,            # 1000101 T 型（缺下）
	BL = 80,             # 1010000 下左角
	TBL = 81,            # 1010001 T 型（缺右）
	BLR = 84,            # 1010100 T 型（缺上）
	FULL = 85,           # 1010101 完整：四周都同类型
	NRB = 0x11101111,    # 只有右下不同
	NLB = 0x11111011,    # 只有左下不同
	NRT = 0x10111111,    # 只有右上不同
	NLT = 0x11101111,    # 只有左上不同
}


# ===========================================================================
# 8 邻居方向偏移（世界 tile 坐标系，顺时针从上开始）
# ===========================================================================
const NEIGHBOR_OFFSETS_8: Array[Vector2i] = [
	Vector2i(0, -1),    # 0: 上 (边)
	Vector2i(1, -1),    # 1: 右上 (角)
	Vector2i(1, 0),     # 2: 右 (边)
	Vector2i(1, 1),     # 3: 右下 (角)
	Vector2i(0, 1),     # 4: 下 (边)
	Vector2i(-1, 1),    # 5: 左下 (角)
	Vector2i(-1, 0),    # 6: 左 (边)
	Vector2i(-1, -1),   # 7: 左上 (角)
]

# 4 边邻居方向偏移（fallback 用，对应 bit 0,2,4,6）
const NEIGHBOR_OFFSETS_4: Array[Vector2i] = [
	Vector2i(0, -1),    # 上
	Vector2i(1, 0),     # 右
	Vector2i(0, 1),     # 下
	Vector2i(-1, 0),    # 左
]


# ===========================================================================
# 对外接口
# ===========================================================================

## 计算 8 邻居形态（完整版）
## 输入：8 个 bool，按顺时针顺序：上、右上、右、右下、下、左下、左、左上
## 输出：8 位掩码 (0-255)
##
## 用法：
##   var form8 = TerrainTransition.compute_form_8(
##       same_top, same_top_right, same_right, same_bottom_right,
##       same_bottom, same_bottom_left, same_left, same_top_left
##   )
##   var atlas = _TERRAIN_TRANSITION_ATLAS_8[terrain].get(form8, fallback)
static func compute_form_8(
	same_top: bool, same_top_right: bool, same_right: bool, same_bottom_right: bool,
	same_bottom: bool, same_bottom_left: bool, same_left: bool, same_top_left: bool
) -> int:
	var mask: int = 0
	if same_top: mask |= BIT_TOP
	if same_top_right: mask |= BIT_TOP_RIGHT
	if same_right: mask |= BIT_RIGHT
	if same_bottom_right: mask |= BIT_BOTTOM_RIGHT
	if same_bottom: mask |= BIT_BOTTOM
	if same_bottom_left: mask |= BIT_BOTTOM_LEFT
	if same_left: mask |= BIT_LEFT
	if same_top_left: mask |= BIT_TOP_LEFT
	return mask


## 从 8 位掩码提取 4 边形态（fallback 用）
## 取 bit 0,2,4,6（上、右、下、左），重新组合成连续的 4 位掩码 (0-15)
##
## 算法：
##   edge_top    = (form8 >> 0) & 1   → bit 0
##   edge_right  = (form8 >> 2) & 1   → bit 1
##   edge_bottom = (form8 >> 4) & 1   → bit 2
##   edge_left   = (form8 >> 6) & 1   → bit 3
##   result = edge_top | (edge_right<<1) | (edge_bottom<<2) | (edge_left<<3)
static func extract_edge_form(form8: int) -> int:
	var edge_top: int = (form8 >> 0) & 1
	var edge_right: int = (form8 >> 2) & 1
	var edge_bottom: int = (form8 >> 4) & 1
	var edge_left: int = (form8 >> 6) & 1
	return edge_top | (edge_right << 1) | (edge_bottom << 2) | (edge_left << 3)


## 计算 4 边形态（仅边邻居，fallback 用）
## 输入：4 个 bool（上、右、下、左）
## 输出：4 位掩码 (0-15)，连续编码
static func compute_form_4(same_top: bool, same_right: bool, same_bottom: bool, same_left: bool) -> int:
	var mask: int = 0
	if same_top: mask |= 1
	if same_right: mask |= 2
	if same_bottom: mask |= 4
	if same_left: mask |= 8
	return mask


## 获取 4 边形态的人类可读名称（调试用）
static func form_name(form: int) -> String:
	match form:
		0: return "ISOLATED"
		1: return "TOP"
		2: return "RIGHT"
		3: return "TR"
		4: return "BOTTOM"
		5: return "TB"
		6: return "BR"
		7: return "TBR"
		8: return "LEFT"
		9: return "TL"
		10: return "LR"
		11: return "TLR"
		12: return "BL"
		13: return "TBL"
		14: return "BLR"
		15: return "FULL"
		_: return "UNKNOWN(%d)" % form
