extends RefCounted
class_name Collision

"""
文件: client/Script/game/collision.gd
作用: 纯几何碰撞判定——形状定义 + 相交判定函数(完整复刻服务端 collision.py)

============================================================================
 为什么客户端也要一份 collision
============================================================================
服务端是权威,命中判定在服务端做。但客户端要做命中特效等视觉反馈,特效位置
需要几何计算(如扇形中心点),这些计算和碰撞判定共用形状定义和几何辅助函数。

所以客户端完整复刻服务端 collision.py,保持算法和函数签名一致。
服务端改了 collision.py,客户端也要同步改。

和服务端 collision.py 的差异:
    - Python 用 dataclass,GDScript 用 inner class + extends RefCounted
    - Python 用 tuple 存坐标,GDScript 用 Vector2(更符合 Godot 习惯)
    - Python 用 math.atan2/hypot,GDScript 用 Vector2.angle()/distance_to
    - 几何算法逻辑完全一致,只是语法适配
"""

# ===========================================================================
# 形状定义(复刻服务端 dataclass)
# ===========================================================================

# 形状基类。pos 是形状在世界坐标中的锚点,具体含义由子类决定:
#   - Circle:  pos = 圆心
#   - Sector:  pos = 扇形圆心(两条翅膀的交汇点)
class Shape:
	extends RefCounted
	var pos: Vector2 = Vector2.ZERO


# 圆形。pos 是圆心。用于被攻击目标的体积
class Circle:
	extends Shape
	var radius: float = 0.0

	func _init(_pos: Vector2, _radius: float) -> void:
		pos = _pos
		radius = _radius


# 扇形。pos 是圆心。
# - radius:    扇形半径(从圆心到弧的距离)
# - angle:     扇形张角(弧度),direction 两侧各分 angle/2
# - direction: 扇形朝向(弧度),0=右,逆时针正
#              和 Godot Vector2.angle() / 服务端 PlayerInfo.facing 一致
#
# 示例: direction=0, angle=π/3 (60°)
#     → 扇形覆盖 [-30°, +30°] 范围,朝右
class Sector:
	extends Shape
	var radius: float = 0.0
	var angle: float = 0.0
	var direction: float = 0.0


# ===========================================================================
# 几何辅助函数(内部使用,不对外暴露,函数名前缀 _)
# ===========================================================================

## 计算两个角度的最小差值,结果归一到 [-π, π]。
## 用于判断"圆心相对扇形圆心的角度"是否落在扇形张角范围内。
## 例: a=350°, b=10° → 差值 -20° (而非 340°)
static func _angle_diff(a: float, b: float) -> float:
	# Python: (a - b + math.pi) % (2 * math.pi) - math.pi
	# GDScript 的 % 对浮点也是取模,行为一致
	return fmod(a - b + PI, 2.0 * PI) - PI


## 判断点是否在扇形区域内(含边界)
static func _point_in_sector(point: Vector2, sector: Sector) -> bool:
	var d: Vector2 = point - sector.pos
	var dist: float = d.length()
	# 超出半径,不在扇形内
	if dist > sector.radius:
		return false
	# 在圆心上,必在扇形内
	if dist == 0.0:
		return true
	# 检查角度是否在 [direction - angle/2, direction + angle/2] 范围内
	var angle: float = d.angle()
	return abs(_angle_diff(angle, sector.direction)) <= sector.angle / 2.0


## 点到线段的最短距离。
## 用于判断圆心到扇形"翅膀"(径向边)的距离是否 ≤ 圆半径。
## 算法:把点投影到线段所在直线上,投影比例 t 限制在 [0,1](线段范围内),
##      最近点 = seg_start + t * (seg_end - seg_start)。
static func _point_segment_dist(point: Vector2, seg_start: Vector2, seg_end: Vector2) -> float:
	var seg_vec: Vector2 = seg_end - seg_start
	var seg_len_sq: float = seg_vec.length_squared()
	if seg_len_sq == 0.0:
		# 线段退化为点
		return point.distance_to(seg_start)
	# 投影比例
	var t: float = (point - seg_start).dot(seg_vec) / seg_len_sq
	t = clamp(t, 0.0, 1.0)
	# 线段上最近点
	var closest: Vector2 = seg_start + seg_vec * t
	return point.distance_to(closest)


## 计算向量 (b-a) × (p-a) 的 z 分量(叉积)。
## >0 表示 p 在 ab 左侧,<0 表示右侧,=0 表示共线。
## 用于线段相交判定。
static func _cross(a: Vector2, b: Vector2, p: Vector2) -> float:
	return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)


## 判断点是否在线段上(前提:已共线)。用包围盒法检查
static func _on_segment(seg_start: Vector2, seg_end: Vector2, point: Vector2) -> bool:
	return (min(seg_start.x, seg_end.x) <= point.x and point.x <= max(seg_start.x, seg_end.x)
		and min(seg_start.y, seg_end.y) <= point.y and point.y <= max(seg_start.y, seg_end.y))


## 判断线段 p1-p2 和 p3-p4 是否相交(含端点)。
## 用叉积法(straddle test):两条线段相交 ⟺ 每条线段的两个端点分别在另一条线段的两侧。
static func _segment_segment_intersect(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var d1: float = _cross(p3, p4, p1)
	var d2: float = _cross(p3, p4, p2)
	var d3: float = _cross(p1, p2, p3)
	var d4: float = _cross(p1, p2, p4)

	# 标准相交:两端点在对方线段两侧
	if ((d1 > 0.0 and d2 < 0.0) or (d1 < 0.0 and d2 > 0.0)) and \
	   ((d3 > 0.0 and d4 < 0.0) or (d3 < 0.0 and d4 > 0.0)):
		return true

	# 共线情况:叉积为 0 且端点在另一线段范围内
	if d1 == 0.0 and _on_segment(p3, p4, p1):
		return true
	if d2 == 0.0 and _on_segment(p3, p4, p2):
		return true
	if d3 == 0.0 and _on_segment(p1, p2, p3):
		return true
	if d4 == 0.0 and _on_segment(p1, p2, p4):
		return true

	return false


## 返回扇形两条"翅膀"的远端点(弧上的两个端点)。
## 翅膀 = 从圆心到弧的径向边,长度 = radius。
static func _sector_wing_endpoints(sector: Sector) -> Array:
	var half: float = sector.angle / 2.0
	# Godot 的 Vector2.rotated() 和 Python 的 cos/sin 语义一致(0=右,逆时针正)
	return [
		sector.pos + Vector2.RIGHT.rotated(sector.direction + half) * sector.radius,
		sector.pos + Vector2.RIGHT.rotated(sector.direction - half) * sector.radius,
	]


## 判断线段是否穿过扇形的弧(圆弧部分)。
## 解参数方程:P = p1 + t*(p2-p1),求 |P - center| = radius 的 t 值,
## 再检查交点是否在扇形角度范围内。
static func _segment_arc_intersect(p1: Vector2, p2: Vector2, sector: Sector) -> bool:
	var d: Vector2 = p2 - p1
	var f: Vector2 = p1 - sector.pos
	var a: float = d.dot(d)
	if a == 0.0:
		# p1 == p2,退化为点,不算穿过
		return false
	var b: float = 2.0 * f.dot(d)
	var c: float = f.dot(f) - sector.radius * sector.radius
	var disc: float = b * b - 4.0 * a * c
	if disc < 0.0:
		return false
	var sqrt_disc: float = sqrt(disc)
	for t in [(-b - sqrt_disc) / (2.0 * a), (-b + sqrt_disc) / (2.0 * a)]:
		if 0.0 <= t and t <= 1.0:
			# 交点在线段上,检查是否在扇形角度范围内
			var i: Vector2 = p1 + d * t
			var angle: float = (i - sector.pos).angle()
			if abs(_angle_diff(angle, sector.direction)) <= sector.angle / 2.0:
				return true
	return false


## 判断线段是否穿过扇形区域(含边界)。
## 三个条件任一满足即相交:
##     1. 线段任一端点在扇形内
##     2. 线段与扇形某条翅膀相交
##     3. 线段穿过扇形的弧
static func _segment_sector_intersect(p1: Vector2, p2: Vector2, sector: Sector) -> bool:
	# 1. 端点在扇形内
	if _point_in_sector(p1, sector) or _point_in_sector(p2, sector):
		return true
	# 2. 与翅膀相交
	for wing_end in _sector_wing_endpoints(sector):
		if _segment_segment_intersect(p1, p2, sector.pos, wing_end):
			return true
	# 3. 穿过弧
	if _segment_arc_intersect(p1, p2, sector):
		return true
	return false


# ===========================================================================
# 相交判定函数(对外暴露)
# ===========================================================================

## 判断两个圆形是否相交(含相切)
static func intersect_circle_circle(circle1: Circle, circle2: Circle) -> bool:
	return circle1.pos.distance_to(circle2.pos) <= circle1.radius + circle2.radius


## 判断圆形和扇形是否相交。
##
## 算法分四步(从便宜到贵,短路返回):
## 1. 距离判定:圆心到扇形圆心 > 扇形半径+圆半径 → 不可能相交
## 2. 圆心在扇形圆心(重合)→ 圆覆盖扇形圆心,相交
## 3. 圆心在扇形角度范围内 → 距离已满足,相交
##    (此时要么圆心在扇形内,要么圆心在弧外但圆与弧重叠)
## 4. 圆心在角度范围外 → 只可能碰到扇形的"翅膀"(径向边)
##    检查圆心到两条翅膀线段的距离是否 ≤ 圆半径
##
## 为什么第4步只查翅膀不查弧:
##     弧完全在角度范围内,圆心在角度范围外时,圆要碰到弧必须先越过翅膀。
##     翅膀的远端点就在弧上,所以"圆碰到翅膀端点"="圆碰到弧端点",已覆盖。
static func intersect_circle_sector(circle: Circle, sector: Sector) -> bool:
	var offset: Vector2 = circle.pos - sector.pos
	var dist: float = offset.length()

	# 1. 距离太远,不可能相交
	if dist > sector.radius + circle.radius:
		return false

	# 2. 圆心在扇形圆心 → 相交
	if dist == 0.0:
		return true

	# 3. 圆心在扇形角度范围内 → 相交(距离已满足)
	var angle_to_circle: float = offset.angle()
	if abs(_angle_diff(angle_to_circle, sector.direction)) <= sector.angle / 2.0:
		return true

	# 4. 圆心在角度范围外 → 检查圆是否碰到扇形的翅膀
	for wing_end in _sector_wing_endpoints(sector):
		if _point_segment_dist(circle.pos, sector.pos, wing_end) <= circle.radius:
			return true

	return false


## 判断两个扇形是否相交。
##
## 算法:
## 两个扇形相交的可能情况:
##     a. 某方圆心在对方扇形内(含一方完全包含另一方)
##     b. 某方翅膀与对方翅膀相交
##     c. 某方翅膀进入对方扇形区域(穿过翅膀或弧)
##
## 检查顺序(从便宜到贵):
##     1. 圆心在对方扇形内?
##     2. 翅膀线段两两相交?
##     3. 翅膀线段穿过对方扇形区域?
##
## 注:扇形-扇形相交在当前攻击系统中暂未使用(攻击判定是 圆 vs 扇形),
## 此函数为对称完整性而实现,供未来扩展(如攻击互碰)使用。
static func intersect_sector_sector(sector1: Sector, sector2: Sector) -> bool:
	# 1. 圆心在对方扇形内
	if _point_in_sector(sector1.pos, sector2):
		return true
	if _point_in_sector(sector2.pos, sector1):
		return true

	# 2. 翅膀线段两两相交
	var wings1: Array = _sector_wing_endpoints(sector1)
	var wings2: Array = _sector_wing_endpoints(sector2)
	for w1 in wings1:
		for w2 in wings2:
			if _segment_segment_intersect(sector1.pos, w1, sector2.pos, w2):
				return true

	# 3. 翅膀穿过对方扇形区域
	for w1 in wings1:
		if _segment_sector_intersect(sector1.pos, w1, sector2):
			return true
	for w2 in wings2:
		if _segment_sector_intersect(sector2.pos, w2, sector1):
			return true

	return false
