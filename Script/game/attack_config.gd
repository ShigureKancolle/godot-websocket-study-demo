extends RefCounted
class_name AttackCalc

"""
文件: client/Script/game/attack_config.gd
作用: 攻击配置访问 + 命中点计算(客户端特有几何逻辑)

============================================================================
 架构变化说明
============================================================================
本文件原来硬编码 ATTACK_CONFIG_RAW const 表,已迁移到 JSON 单数据源方案:
    - 配置数据: shared_config/attack_config.json(单数据源)
    - 加载层:   ConfigLoader.gd 读 res://config/attack_config.json
    - 本文件:  ConfigLoader 的薄包装,只保留 calc_hit_position 客户端特有逻辑

为什么不直接用 ConfigLoader,还要这层包装?
    - ConfigLoader 是通用配置访问层(攻击+实体+常量都走它)
    - attack_config.gd 专注攻击配置语义 + 命中点几何计算
    - 调用方代码 attack_config.get_config() 不用改,保持 API 兼容

============================================================================
 和服务端的关系
============================================================================
服务端没有"命中点计算"——服务端只算"是否命中"(collision.intersect_xxx),
客户端额外算"命中点坐标"用于播放命中特效(特效位置)。

calc_hit_position 算法:
    命中点 = 攻击者位置 + 朝向 * (radius / 2)
    - 用 radius/2 而非 radius:特效在攻击范围中间,视觉最自然
      (用 radius 会跑到攻击范围最远端,短半径显得太近、长半径跑太远)
    - 这是客户端预测/视觉层计算,和服务端判定无关
      服务端判定用 collision.intersect_xxx 算"是否相交",不算"命中点"

============================================================================
 多 shape 简化
============================================================================
当前一个 AttackConfig 可能有多个 shape(如 1002 双段斩有两个 sector)。
calc_hit_position 接收 shape_index 参数,从配置里取对应 shape 算命中点。
要求调用方从 AttackHit 消息的 atk_shape_idx 字段取得 shape_index 传入。
"""


# ===========================================================================
# 配置访问(转调 ConfigLoader,保持 API 兼容)
# ===========================================================================

## 获取某个 atk_id 的攻击配置;未知返回 null
static func get_config(atk_id: int) -> Variant:
	return ConfigLoader.get_attack_config(atk_id)


## 获取某个 atk_id 的第 shape_index 个形状;越界返回 null
static func get_shape(atk_id: int, shape_index: int) -> Variant:
	var cfg = ConfigLoader.get_attack_config(atk_id)
	if cfg == null:
		return null
	if shape_index < 0 or shape_index >= cfg.shape_list.size():
		return null
	return cfg.shape_list[shape_index]


# ===========================================================================
# 命中点计算(客户端特有,服务端不需要)
# ===========================================================================

## 计算攻击命中点坐标(用于播放命中特效)
##
## 算法:攻击者位置 + 朝向 * (radius / 2)
## - 用 radius/2 让特效出现在攻击范围中间,视觉最自然
##
## Args:
##     attacker_pos:    攻击者世界坐标(Vector2)
##     attacker_facing: 攻击者朝向(弧度,0=右,逆时针正——Godot 标准)
##     atk_id:          攻击ID(用于查 ATTACK_CONFIG)
##     shape_index:     该攻击的第几个 shape(从 AttackHit.atk_shape_idx 取得)
##
## Returns:
##     命中点世界坐标(Vector2)。配置不存在或 shape 非扇形时返回 attacker_pos 兜底
static func calc_hit_position(attacker_pos: Vector2, attacker_facing: float, atk_id: int, shape_index: int, hurt_pos: Vector2, hurt_shape: Collision.Circle) -> Vector2:
	var shape = get_shape(atk_id, shape_index)
	if shape == null:
		push_warning("AttackConfig: atk_id=" + str(atk_id) + " shape_index=" + str(shape_index) + " 配置不存在")
		return attacker_pos

	# 目前只支持扇形(和服务端一致),其他形状未来扩展
	if shape.shape != ConfigLoader.ShapeType_SECTOR:
		push_warning("AttackConfig: 暂不支持非扇形形状的命中点计算: " + shape.shape)
		return attacker_pos

	# shape_params 类型检查(is 而非 as,避免转换失败返回 null)
	if not (shape.shape_params is ConfigLoader.SectorParams):
		push_warning("AttackConfig: 扇形 shape_params 类型错误")
		return attacker_pos

	var sector: ConfigLoader.SectorParams = shape.shape_params
	# 朝向单位向量(0=右,逆时针正——Godot 标准)
	var dir: Vector2 = Vector2.RIGHT.rotated((hurt_pos - attacker_pos).angle())
	# 命中点 = 攻击者位置 + 朝向 * radius
	return attacker_pos + dir * sector.radius
