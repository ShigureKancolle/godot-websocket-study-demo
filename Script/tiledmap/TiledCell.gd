'''
文件: client/Script/tiledmap/TiledCell.gd
作用: 描述单个 tile 的渲染资源 —— atlas 坐标 + 旋转 + 权重

============================================================================
 设计说明
============================================================================
TiledCell 是 MyTiledCell 的子元素。一个 MyTiledCell 包含 4 个位置（2×2 block），
每个位置有一个候选数组（Array[TiledCell]），渲染时按权重随机抽一个。

字段含义：
    assets_pos: atlas 中的资源坐标（TileSetAtlasSource 的 atlas_coords）
    dir:        顺时针旋转次数（0/1/2/3 = 0°/90°/180°/270°）
                对应 Godot TileSet 的 alternative_tile transform：
                  0 = 无变换
                  1 = flip_h + transpose  (90° CW)
                  2 = flip_h + flip_v     (180°)
                  3 = flip_v + transpose  (270° CW)
    weight:     被抽选的权重（相对值，不需要加起来等于 100）

旋转的实现（InfiniteTileMap._get_or_create_alt_tile）：
    dir=0 → alternative_tile=0（默认，无变换）
    dir>0 → 运行时动态创建 alternative_tile，设置 flip_h/flip_v/transpose
    这样用户不需要在 TileSet 编辑器中手动创建旋转变体
'''

extends RefCounted
class_name TiledCell

# atlas 资源坐标
var assets_pos: Vector2i

# 顺时针旋转次数（0/1/2/3）
var dir: int

# 抽选权重
var weight: int


func _init(p_assets_pos: Vector2i = Vector2i.ZERO, p_dir: int = 0, p_weight: int = 1) -> void:
	assets_pos = p_assets_pos
	dir = p_dir
	weight = p_weight
