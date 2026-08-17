extends Polygon2D
class_name AttackFan

"""
文件: client/Script/role/AttackFan.gd
作用: 攻击扇形弧光组件——攻击触发时渲染攻击范围 + 命中时刻提示(纯显示)

============================================================================
  设计思路(方案: 动态扇形弧光)
============================================================================
1. 不画整圆,画攻击形状配置的扇形(radius / angle),更符合"挥砍/斩击"直觉。
2. 顶点色渐变: 圆心 alpha=0(完全透明) → 弧上 alpha=峰值(半透明),
   视觉上不是一坨色块,而是"剑气外放"的渐隐效果。
3. 颜色按攻击者身份区分(调用方传入):
     - 本人(SELF):   淡蓝白
     - 队友(TEAM):   绿色
     - 敌人(ENEMY):  红色
4. 出场动画(零贴图): 0.15s 快速膨胀(scale 0.3→1.0, 圆心不动向外炸开)
   → 保持到命中时刻(hit_time)附近最亮 → 攻击结束(duration)淡出归零。
5. 命中时刻发 hit_moment 信号,外部(如本地玩家震屏/后坐)据此做"重击感"表现。

============================================================================
  数据来源
============================================================================
形状参数(radius/angle/hit_time/duration)从攻击配置读:
    AttackCalc.get_shape(atk_id, shape_index) → ConfigLoader.AttackShape
所以渲染完全跟随配置:时间/角度/范围都由 shared_config/attack_config.json 决定。
未来若攻击范围改为服务端广播(combat 动态修饰),只需把取数函数换成广播值,
组件本身不需要改结构(show_attack 接收的是已解析好的形状参数)。

============================================================================
  层级
============================================================================
z_index = 1(和 VisionFan 同级,实体之上、UI 之下,半透明效果层):
  - 盖住角色/怪物但半透明,不影响怪物受击闪白等反馈可见
  - 不依赖场景树把玩家/敌人分层(俯视角遮挡靠 y-sort,效果层统一用 z_index)
"""

# 弧上顶点数: 越多边缘越平滑,顶点色渐变也越顺(20 对 35~60px 半径足够)
const SEGMENTS: int = 20

# 膨胀时长(秒): 0.15s 内 scale 0.3→1.0(圆心不动,弧向外爆开)
const EXPAND_TIME: float = 0.15

# 弧上顶点峰值透明度(0~1): 配合 modulate 淡出,顶点色乘 modulate
# 150/255 ≈ 0.59 偏重会盖住受击反馈,取 0.45 半透明即可(参数可调)
const PEAK_ALPHA: float = 0.45

# 身份颜色(仅 RGB,alpha 由顶点渐变控制)
const COLOR_SELF: Color = Color(0.75, 0.88, 1.0)    # 本人: 淡蓝白
const COLOR_TEAM: Color = Color(0.45, 0.95, 0.55)   # 队友: 绿
const COLOR_ENEMY: Color = Color(1.0, 0.35, 0.35)   # 敌人: 红

# 攻击者身份(调用方 Role 判断后传入)
enum Identity { SELF, TEAM, ENEMY }

# 命中时刻信号: 判定帧(hit_time)到达时发,供震屏/其他"重击感"表现用
signal hit_moment

var _tween: Tween = null


func _init() -> void:
	# 效果层: 实体之上、UI 之下(和 VisionFan 同级)
	z_index = 1
	# 默认隐藏,show_attack 时才显示
	visible = false


## 显示一次攻击弧光
## 形状参数全部来自攻击配置(时间/角度/范围由配置决定)
## Args:
##     atk_id:      攻击ID(查配置)
##     shape_index: 该攻击的第几个 shape(多段攻击取对应段,目前 AttackStart 只有
##                 atk_id,统一用第 0 段做主挥砍范围;AttackHit 带 atk_shape_idx 可后续扩展)
##     facing:      攻击者朝向(弧度,0=右,逆时针正)
##     identity:    Identity.SELF / TEAM / ENEMY(决定颜色)
func show_attack(atk_id: int, shape_index: int, facing: float, identity: int) -> void:
	var shape = AttackCalc.get_shape(atk_id, shape_index)
	if shape == null:
		return  # 配置不存在:不渲染(防御)
	if shape.shape != ConfigLoader.ShapeType_SECTOR:
		return  # 目前只支持扇形(和服务端判定一致)
	if not (shape.shape_params is ConfigLoader.SectorParams):
		return
	var sector: ConfigLoader.SectorParams = shape.shape_params

	# 顶点 + 顶点色(圆心透明 → 弧上峰值,剑气外放渐隐)
	_build_polygon(sector.radius, sector.angle, _identity_color(identity))
	rotation = facing

	# 时间轴(全部来自配置): 膨胀 → [保持到命中] → 命中时刻发信号 → 淡出
	var hit_s: float = float(shape.hit_time) / 1000.0
	var duration_s: float = float(shape.duration) / 1000.0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	visible = true
	scale = Vector2(0.3, 0.3)
	modulate.a = 1.0
	_tween = create_tween()
	# 1. 快速膨胀 + 透明度爬升(圆心不动,弧向外炸开)
	_tween.tween_property(self, "scale", Vector2.ONE, EXPAND_TIME).from(Vector2(0.3, 0.3))
	_tween.parallel().tween_property(self, "modulate:a", 1.0, EXPAND_TIME)
	# 2. 保持到命中时刻附近(判定帧前亮度顶点;判定帧在膨胀期内则膨胀完即触发)
	if hit_s > EXPAND_TIME:
		_tween.tween_interval(hit_s - EXPAND_TIME)
	_tween.tween_callback(hit_moment.emit)
	# 3. 命中后淡出(剩余时间),攻击结束隐藏
	var fade_s: float = max(duration_s - hit_s, 0.05)
	_tween.tween_property(self, "modulate:a", 0.0, fade_s)
	_tween.tween_callback(func() -> void: visible = false)


## 按身份取基础颜色(RGB;alpha 由顶点渐变控制)
func _identity_color(identity: int) -> Color:
	match identity:
		Identity.SELF:
			return COLOR_SELF
		Identity.TEAM:
			return COLOR_TEAM
		_:
			return COLOR_ENEMY


## 生成扇形顶点 + 顶点色(局部坐标,朝右方向;旋转交给节点 rotation)
## 顶点从圆心 Vector2.ZERO 开始,沿弧从 -angle/2 到 +angle/2 均匀采样
## SEGMENTS 段(首尾两点在弧两端,收口到圆心成扇形)
func _build_polygon(radius: float, angle: float, base_color: Color) -> void:
	var pts := PackedVector2Array()
	var colors := PackedColorArray()
	pts.append(Vector2.ZERO)  # 扇形圆心
	colors.append(Color(base_color.r, base_color.g, base_color.b, 0.0))  # 圆心完全透明
	for i in range(SEGMENTS + 1):
		# 从 -angle/2 均匀扫到 +angle/2(共 SEGMENTS+1 个弧上点)
		var a: float = -angle * 0.5 + angle * float(i) / float(SEGMENTS)
		pts.append(Vector2.RIGHT.rotated(a) * radius)
		colors.append(Color(base_color.r, base_color.g, base_color.b, PEAK_ALPHA))
	polygon = pts
	vertex_colors = colors
