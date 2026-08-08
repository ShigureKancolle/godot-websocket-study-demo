'''
游戏场景(接入无限地图)
继承自 dead_man_scene.gd,复用全部实体管理/血条/飘字/受击特效逻辑,
只增加 InfiniteTileMap 的接入:把 Camera2D 设为地图跟随目标。

木桩场景(DeadManScene)是测试用,纯色背景无地图;
游戏场景(GameScene)是正式玩法,接入无限地图 chunk 动态加载。

为什么跟随 Camera2D 而非 Role:
  - Camera2D 在场景里一直存在,不会因玩家创建时机晚而 null
  - 相机跟随玩家,地图跟随相机,间接跟随玩家——链路简单可靠
  - 不需要覆盖 _create_role 设 follow target,减少时序依赖
'''

extends "res://Script/dead_man_scene.gd"


func _ready() -> void:
	# 调用父类 _ready:连接 StateMirror 信号、初始化 EntityLayer/EffectLayer 等
	super._ready()
	# 把 Camera2D 设为无限地图的跟随目标
	# InfiniteTileMap._process 会读 follow_target.global_position 加载/卸载 chunk
	# Camera2D 由 CameraFollow 脚本驱动跟随本地玩家,所以地图间接跟随玩家
	var infinite_map: InfiniteTileMap = $InfiniteTileMap
	infinite_map.set_follow_target($Camera2D)
	_damage_layer = $DamageLayer
