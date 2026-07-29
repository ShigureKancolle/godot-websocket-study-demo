'''
文件: client/Script/tiledmap/MyTiledCell.gd
作用: 描述一个 2×2 block（4 个 tile）的渲染资源组合

============================================================================
 设计说明
============================================================================
MyTiledCell 描述一个 2×2 block 内 4 个 tile 分别用什么贴图。
它是 V3 渲染系统的核心数据结构。

字段：
    tiledtype: 地形类型（ChunkGenerator.TerrainType 枚举）
    cell:      长度 4 或 1 的数组
               - 长度 4: cell[0]→(0,0), cell[1]→(0,1), cell[2]→(1,0), cell[3]→(1,1)
                 每个元素是 Array[TiledCell]，渲染时按权重抽一个
               - 长度 1: 省略形式，4 个位置都用 cell[0] 的候选数组

block 内位置编号（以左上角为原点）:
    (0,0)=index 0   (0,1)=index 1
    (1,0)=index 2   (1,1)=index 3

============================================================================
 旋转（整体旋转，Godot 式）
============================================================================
旋转一个 MyTiledCell = 4 个 cell 位置重排 + 每个 TiledCell 的 dir +1

顺时针 90° 位置映射：
    旧(0,0)→新(0,1), 旧(0,1)→新(1,1), 旧(1,0)→新(0,0), 旧(1,1)→新(1,0)
    即: 新[0]=旧[2], 新[1]=旧[0], 新[2]=旧[3], 新[3]=旧[1]

旋转由 InfiniteTileMap._rotate_my_tiled_cell 实现，配置时只需定义基础形态，
其他朝向通过旋转派生（减少配置量）。

============================================================================
 使用场景
============================================================================
1. 非草地 block（SAND/DIRT/BRICK）: 用纯地块 MyTiledCell（4 个 tile 同贴图）
2. 草地 block: 根据周围 8 邻居 block 类型，查草地形态表得到对应 MyTiledCell
   草地形态表 _GRASS_FORMS: 旋转归一化后的 8 位掩码 → MyTiledCell
'''

extends RefCounted
class_name MyTiledCell

# 地形类型（ChunkGenerator.TerrainType 枚举）
var tiledtype: int

# 2×2 cell 数组
# 长度 4: [candidates(0,0), candidates(0,1), candidates(1,0), candidates(1,1)]
# 长度 1: 省略形式，4 个位置都用 cell[0]
var cell: Array


func _init(p_tiledtype: int = 0, p_cell: Array = []) -> void:
	tiledtype = p_tiledtype
	cell = p_cell


## 获取指定位置的候选 TiledCell 数组
## local_idx: 0=(0,0), 1=(0,1), 2=(1,0), 3=(1,1)
## 返回 Array[TiledCell]
func get_candidates(local_idx: int) -> Array:
	# 省略形式：4 个位置都用 cell[0]
	if cell.size() == 1:
		return cell[0]
	# 完整形式
	if local_idx >= 0 and local_idx < cell.size():
		return cell[local_idx]
	return []
