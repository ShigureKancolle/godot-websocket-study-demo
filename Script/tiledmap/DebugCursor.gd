'''
文件: client/Script/tiledmap/DebugCursor.gd
作用: 无限地图调试游标 —— 用箭头键/WASD 移动，作为 InfiniteTileMap 的 follow target

============================================================================
 为什么有这个文件
============================================================================
无限地图逻辑需要 follow target 来触发 chunk 加载/卸载。
在独立调试阶段（未集成到 DeadManScene），没有玩家 Role，
用这个简单游标模拟"玩家移动"，验证：
    1. 移动时周围 chunk 自动加载
    2. 走远后旧 chunk 自动卸载
    3. 同一 chunk 重新进入时内容一致（确定性生成）

集成到 DeadManScene 后本文件可删除（或保留作开发调试工具）。

============================================================================
 操作
============================================================================
    方向键 / WASD : 移动游标
    移动速度 : 200 像素/秒（可在 SPEED 常量调整）

游标画成一个红色十字 + 圆圈，便于在地图上看到位置。
'''

extends Node2D
class_name DebugCursor


# 移动速度（像素/秒）。调试时可调大以便快速穿越 chunk 边界
const SPEED: float = 200.0

# 标记大小（像素）
const MARKER_RADIUS: float = 12.0
const MARKER_ARM: float = 18.0


func _process(delta: float) -> void:
	# 读方向键 / WASD（ui_* 是 Godot 内置输入动作，默认绑定方向键）
	var dir: Vector2 = Vector2.ZERO
	if Input.is_action_pressed("ui_right"):
		dir.x += 1.0
	if Input.is_action_pressed("ui_left"):
		dir.x -= 1.0
	if Input.is_action_pressed("ui_down"):
		dir.y += 1.0
	if Input.is_action_pressed("ui_up"):
		dir.y -= 1.0

	# 归一化避免斜走 1.414 倍快
	if dir != Vector2.ZERO:
		dir = dir.normalized()
		global_position += dir * SPEED * delta

	# 触发重绘，确保 _draw 在 global_position 变化后重新执行
	# （_draw 只在节点 dirty 时调用，position 变化不会自动触发）
	queue_redraw()


func _draw() -> void:
	# 画红色圆圈 + 十字，便于在地图上定位
	draw_circle(Vector2.ZERO, MARKER_RADIUS, Color(1.0, 0.0, 0.0, 0.5))
	draw_line(Vector2(-MARKER_ARM, 0), Vector2(MARKER_ARM, 0), Color.RED, 2.0)
	draw_line(Vector2(0, -MARKER_ARM), Vector2(0, MARKER_ARM), Color.RED, 2.0)
