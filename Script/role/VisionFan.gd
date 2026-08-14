extends Polygon2D
class_name VisionFan

"""
文件: client/Script/role/VisionFan.gd
作用: 敌人视野(视锥)渲染组件——玩家可见的半透明扇形

============================================================================
  组件职责(纯显示)
============================================================================
1. 读 vision_config.json(normal/chase 两套视野)构造扇形顶点
2. 按 ai_state 切换形态:
     - chase(追逐态) → chase 视野(窄而远:半角 22.5°,半径 1000px)
     - 其余状态(patrol/look_around/attack) → normal 视野(宽而近:半角 30°,半径 750px)
3. 按 facing 旋转(通过节点 rotation,不用重算顶点)

纯显示组件,不做障碍物遮挡(后续可扩展射线遮挡)。由 Role._setup_enemy 挂载,
数据由 StateMirror 信号 → Role.on_entity_updated 转发(ai_state/facing)驱动。

============================================================================
  为什么用 Polygon2D + 顶点旋转而非手动 _draw
============================================================================
Polygon2D 的 polygon 是相对节点原点的局部坐标,顶点按 facing=0(朝右)生成一次,
之后朝向变化只改 rotation——避免每帧重算顶点。facing 语义:
弧度,0=朝右,逆时针正(Godot 标准,和服务端 EntityInfo.facing 对齐)。

============================================================================
  为什么是组件而非写在 Role 里
============================================================================
和 PlayerVisual 同思路:Role 是通用容器,视锥是"敌人"类型的专属显示,
抽成组件后只有敌人挂,玩家/木桩不挂,显示逻辑变更只改这一个文件。
"""

# 扇形边缘分段数:越多边缘越平滑(32 段对 750~1000px 半径足够圆滑)
const SEGMENTS: int = 32

# 视锥颜色(Inspector 可调,Godot 4 用 @export 暴露,响应编辑器修改)
@export var color_normal: Color = Color(1, 0, 0, 0.25)   # 常态:半透明红
@export var color_chase: Color = Color(1, 0.6, 0, 0.35)  # 追逐态:半透明橙(更醒目)

# 最近一次 AI 状态(缓存,供日志/调试)
var _ai_state: String = "idle"


## 初始化:由 Role._setup_enemy 在 add_child 后立即调用
func setup(ai_state: String) -> void:
	# 初始形态 + 顶点(默认朝右,由 set_facing 后续转正)
	set_ai_state(ai_state)


## 切换 AI 状态:chase → chase 视野(窄而远),其余 → normal 视野(宽而近)
## 由 Role.on_entity_updated 转发 StateMirror 的 ai_state 字段驱动
func set_ai_state(ai_state: String) -> void:
	_ai_state = ai_state
	var mode := "chase" if ai_state == "chase" else "normal"
	var vision := ConfigLoader.get_vision(mode)
	color = color_chase if mode == "chase" else color_normal
	_build_polygon(vision)


## 更新朝向:扇形整体绕原点旋转,facing=0 时朝右(Godot 标准)
## 由 Role.on_entity_updated 转发 StateMirror 的 facing 字段驱动
func set_facing(facing: float) -> void:
	rotation = facing


## 按视野配置生成扇形顶点(局部坐标,朝右方向;旋转交给节点 rotation)
## 顶点从圆心 Vector2.ZERO 开始,沿弧线从 -half_angle 到 +half_angle,
## 半径 radius 处均匀采样 SEGMENTS 段(首尾两点在弧两端,收口到圆心成扇形)。
func _build_polygon(vision: ConfigLoader.VisionInfo) -> void:
	var pts := PackedVector2Array()
	pts.append(Vector2.ZERO)  # 扇形圆心
	for i in range(SEGMENTS + 1):
		# 从 -half_angle 均匀扫到 +half_angle(共 SEGMENTS+1 个弧上点)
		var a: float = -vision.half_angle + vision.half_angle * 2.0 * float(i) / float(SEGMENTS)
		pts.append(Vector2.RIGHT.rotated(a) * vision.radius)
	polygon = pts
