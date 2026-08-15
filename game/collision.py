# coding=utf-8

"""
文件: server/game/collision.py
作用: 纯几何碰撞判定——形状定义 + 相交判定函数

============================================================================
 为什么单独一个文件
============================================================================
碰撞判定是纯数学(距离/角度/投影),不依赖 GameRoom 状态,也不依赖网络层。
独立出来有三个好处:
    1. GameRoom 保持"唯一状态持有者"职责,不混入几何计算
    2. 纯函数可独立单元测试(不启动服务器就能验证判定是否正确)
    3. 未来加矩形/射线判定只改本文件,不破坏现有结构

调用关系:
    GameRoom.get_attack_hits(attacker_id, atk_id)
        ↓ 取 attacker 状态(x/y/facing) + 目标状态
        ↓ 构造 Circle(目标) + Sector(攻击者)
    collision.intersect_circle_sector(circle, sector)
        ↓ 返回 bool
    GameRoom 收集命中者列表
"""

from dataclasses import dataclass
import math
from typing import List


# ===========================================================================
# 形状定义
# ===========================================================================

@dataclass
class Shape:
    """
    形状基类。
    pos 是形状在世界坐标中的锚点,具体含义由子类决定:
        - Circle:  pos = 圆心
        - Sector:  pos = 扇形圆心(两条翅膀的交汇点)
    """
    pos: tuple[float, float] = (0.0, 0.0)


@dataclass
class Circle(Shape):
    """圆形。pos 是圆心。用于被攻击目标的体积"""
    radius: float = 0.0


@dataclass
class Sector(Shape):
    """
    扇形。pos 是圆心。

    - radius:    扇形半径(从圆心到弧的距离)
    - angle:     扇形张角(弧度),direction 两侧各分 angle/2
    - direction: 扇形朝向(弧度),0=右,逆时针正
                 和 Godot Vector2.angle() / 服务端 PlayerInfo.facing 一致

    示例: direction=0, angle=π/3 (60°)
        → 扇形覆盖 [-30°, +30°] 范围,朝右
    """
    radius: float = 0.0
    angle: float = 0.0
    direction: float = 0.0

# 搞个简单点的向量 如果不够用 再改成Numpy
@dataclass
class Vector2:
    x: float = 0.0
    y: float = 0.0

    def __init__(self, x: float | tuple[float, float] | List[float] = 0.0, y: float = 0.0):
        if isinstance(x, (tuple, list)) and len(x) == 2:
            self.x = x[0]
            self.y = x[1]
        else:
            self.x = x
            self.y = y

    def normalized(self) -> "Vector2":
        """归一化向量"""
        return self / math.hypot(self.x, self.y)

    def dot(self, other: "Vector2") -> float:
        """向量点积"""
        return self.x * other.x + self.y * other.y

    def cross(self, other: "Vector2") -> float:
        """向量叉积(z 分量):0 平行/共线,>0 表示 other 在 self 左边(逆时针),<0 在右边(顺时针)"""
        return self.x * other.y - self.y * other.x

    @staticmethod
    def dot_static(v1: "Vector2", v2: "Vector2") -> float:
        """向量点积  点乘 判断是否垂直 0 垂直 >0 v2在v1的方向 夹角是锐角  <0 v2在v1的反方向 夹角是钝角"""
        return v1.x * v2.x + v1.y * v2.y

    @staticmethod
    def cross_static(v1: "Vector2", v2: "Vector2") -> float:
        """向量叉积(z 分量):0 平行/共线,>0 表示 v2 在 v1 左边(逆时针),<0 在右边(顺时针)"""
        return v1.x * v2.y - v1.y * v2.x
    
    def angle(self, zero: "tuple[float, float] | Vector2 | List[float]" = (1.0, 0.0)) -> float:
        """返回以zero为零的向量角度,区间 [-π, π]"""
        if self == Vector2(0.0, 0.0):
            raise ValueError("向量为零,无法计算角度") 
        if isinstance(zero, (tuple, list)) and len(zero) == 2:
            zero_vec = Vector2(*zero)
        elif isinstance(zero, Vector2):
            zero_vec = zero
        else:
            raise TypeError("zero must be tuple, list, or Vector2")
        angle = math.atan2(self.y, self.x) - math.atan2(zero_vec.y, zero_vec.x)
        angle = (angle + math.pi) % (2 * math.pi) - math.pi
        return angle
    
    def __mul__(self, other: float) -> "Vector2":
        """向量缩放"""
        return Vector2(self.x * other, self.y * other)

    def __add__(self, other: "Vector2") -> "Vector2":
        """向量加法"""
        return Vector2(self.x + other.x, self.y + other.y)

    def __sub__(self, other: "Vector2") -> "Vector2":
        """向量减法"""
        return Vector2(self.x - other.x, self.y - other.y)

    def __truediv__(self, other: float) -> "Vector2":
        """向量除法"""
        return Vector2(self.x / other, self.y / other)

    def __len__(self) -> float:
        """向量长度"""
        return math.hypot(self.x, self.y)

    def __str__(self) -> str:
        return f"({self.x:.2f}, {self.y:.2f})"

    def __eq__(self, other: "Vector2") -> bool:
        """向量相等"""
        return self.x == other.x and self.y == other.y

    def __ne__(self, other: "Vector2") -> bool:
        """向量不相等"""
        return not self.__eq__(other)
    


# ===========================================================================
# 几何辅助函数(内部使用,不对外暴露)
# ===========================================================================

def _angle_diff(a: float, b: float) -> float:
    """
    计算两个角度的最小差值,结果归一到 [-π, π]。

    用于判断"圆心相对扇形圆心的角度"是否落在扇形张角范围内。
    例: a=350°, b=10° → 差值 -20° (而非 340°)
    """
    return (a - b + math.pi) % (2 * math.pi) - math.pi


def _point_in_sector(point: tuple[float, float], sector: Sector) -> bool:
    """判断点是否在扇形区域内(含边界)"""
    dx = point[0] - sector.pos[0]
    dy = point[1] - sector.pos[1]
    dist = math.hypot(dx, dy)
    # 超出半径,不在扇形内
    if dist > sector.radius:
        return False
    # 在圆心上,必在扇形内
    if dist == 0:
        return True
    # 检查角度是否在 [direction - angle/2, direction + angle/2] 范围内
    angle = math.atan2(dy, dx)
    return abs(_angle_diff(angle, sector.direction)) <= sector.angle / 2


def _point_segment_dist(point: tuple[float, float],
                        seg_start: tuple[float, float],
                        seg_end: tuple[float, float]) -> float:
    """
    点到线段的最短距离。

    用于判断圆心到扇形"翅膀"(径向边)的距离是否 ≤ 圆半径。
    算法:把点投影到线段所在直线上,投影比例 t 限制在 [0,1](线段范围内),
         最近点 = seg_start + t * (seg_end - seg_start)。
    """
    sx = seg_end[0] - seg_start[0]
    sy = seg_end[1] - seg_start[1]
    seg_len_sq = sx * sx + sy * sy
    if seg_len_sq == 0:
        # 线段退化为点
        return math.hypot(point[0] - seg_start[0], point[1] - seg_start[1])
    # 投影比例
    t = ((point[0] - seg_start[0]) * sx + (point[1] - seg_start[1]) * sy) / seg_len_sq
    t = max(0.0, min(1.0, t))
    # 线段上最近点
    cx = seg_start[0] + t * sx
    cy = seg_start[1] + t * sy
    return math.hypot(point[0] - cx, point[1] - cy)


def _cross(a: tuple[float, float], b: tuple[float, float], p: tuple[float, float]) -> float:
    """
    计算向量 (b-a) × (p-a) 的 z 分量(叉积)。
    >0 表示 p 在 ab 左侧,<0 表示右侧,=0 表示共线。
    用于线段相交判定。
    """
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])


def _on_segment(seg_start: tuple[float, float], seg_end: tuple[float, float],
                point: tuple[float, float]) -> bool:
    """判断点是否在线段上(前提:已共线)。用包围盒法检查"""
    return (min(seg_start[0], seg_end[0]) <= point[0] <= max(seg_start[0], seg_end[0]) and
            min(seg_start[1], seg_end[1]) <= point[1] <= max(seg_start[1], seg_end[1]))


def _segment_segment_intersect(p1: tuple[float, float], p2: tuple[float, float],
                               p3: tuple[float, float], p4: tuple[float, float]) -> bool:
    """
    判断线段 p1-p2 和 p3-p4 是否相交(含端点)。
    用叉积法(straddle test):两条线段相交 ⟺ 每条线段的两个端点分别在另一条线段的两侧。
    """
    d1 = _cross(p3, p4, p1)
    d2 = _cross(p3, p4, p2)
    d3 = _cross(p1, p2, p3)
    d4 = _cross(p1, p2, p4)

    # 标准相交:两端点在对方线段两侧
    if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and \
       ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)):
        return True

    # 共线情况:叉积为 0 且端点在另一线段范围内
    if d1 == 0 and _on_segment(p3, p4, p1):
        return True
    if d2 == 0 and _on_segment(p3, p4, p2):
        return True
    if d3 == 0 and _on_segment(p1, p2, p3):
        return True
    if d4 == 0 and _on_segment(p1, p2, p4):
        return True

    return False


def _sector_wing_endpoints(sector: Sector) -> list[tuple[float, float]]:
    """
    返回扇形两条"翅膀"的远端点(弧上的两个端点)。
    翅膀 = 从圆心到弧的径向边,长度 = radius。
    """
    half = sector.angle / 2
    return [
        (sector.pos[0] + sector.radius * math.cos(sector.direction + half),
         sector.pos[1] + sector.radius * math.sin(sector.direction + half)),
        (sector.pos[0] + sector.radius * math.cos(sector.direction - half),
         sector.pos[1] + sector.radius * math.sin(sector.direction - half)),
    ]


def _segment_arc_intersect(p1: tuple[float, float], p2: tuple[float, float],
                           sector: Sector) -> bool:
    """
    判断线段是否穿过扇形的弧(圆弧部分)。
    解参数方程:P = p1 + t*(p2-p1),求 |P - center| = radius 的 t 值,
    再检查交点是否在扇形角度范围内。
    """
    dx = p2[0] - p1[0]
    dy = p2[1] - p1[1]
    fx = p1[0] - sector.pos[0]
    fy = p1[1] - sector.pos[1]
    a = dx * dx + dy * dy
    if a == 0:
        # p1 == p2,退化为点,不算穿过
        return False
    b = 2 * (fx * dx + fy * dy)
    c = fx * fx + fy * fy - sector.radius * sector.radius
    disc = b * b - 4 * a * c
    if disc < 0:
        return False
    sqrt_disc = math.sqrt(disc)
    for t in [(-b - sqrt_disc) / (2 * a), (-b + sqrt_disc) / (2 * a)]:
        if 0 <= t <= 1:
            # 交点在线段上,检查是否在扇形角度范围内
            ix = p1[0] + t * dx
            iy = p1[1] + t * dy
            angle = math.atan2(iy - sector.pos[1], ix - sector.pos[0])
            if abs(_angle_diff(angle, sector.direction)) <= sector.angle / 2:
                return True
    return False


def _segment_sector_intersect(p1: tuple[float, float], p2: tuple[float, float],
                              sector: Sector) -> bool:
    """
    判断线段是否穿过扇形区域(含边界)。
    三个条件任一满足即相交:
        1. 线段任一端点在扇形内
        2. 线段与扇形某条翅膀相交
        3. 线段穿过扇形的弧
    """
    # 1. 端点在扇形内
    if _point_in_sector(p1, sector) or _point_in_sector(p2, sector):
        return True
    # 2. 与翅膀相交
    for wing_end in _sector_wing_endpoints(sector):
        if _segment_segment_intersect(p1, p2, sector.pos, wing_end):
            return True
    # 3. 穿过弧
    if _segment_arc_intersect(p1, p2, sector):
        return True
    return False


# ===========================================================================
# 相交判定函数(对外暴露)
# ===========================================================================

def intersect_circle_circle(circle1: Circle, circle2: Circle) -> bool:
    """判断两个圆形是否相交(含相切)"""
    dist = math.hypot(circle1.pos[0] - circle2.pos[0], circle1.pos[1] - circle2.pos[1])
    return dist <= circle1.radius + circle2.radius


def intersect_circle_sector(circle: Circle, sector: Sector) -> bool:
    """
    判断圆形和扇形是否相交。

    =========================================================================
     算法分四步(从便宜到贵,短路返回)
    =========================================================================
    1. 距离判定:圆心到扇形圆心 > 扇形半径+圆半径 → 不可能相交
    2. 圆心在扇形圆心(重合)→ 圆覆盖扇形圆心,相交
    3. 圆心在扇形角度范围内 → 距离已满足,相交
       (此时要么圆心在扇形内,要么圆心在弧外但圆与弧重叠)
    4. 圆心在角度范围外 → 只可能碰到扇形的"翅膀"(径向边)
       检查圆心到两条翅膀线段的距离是否 ≤ 圆半径

    为什么第4步只查翅膀不查弧:
        弧完全在角度范围内,圆心在角度范围外时,圆要碰到弧必须先越过翅膀。
        翅膀的远端点就在弧上,所以"圆碰到翅膀端点"="圆碰到弧端点",已覆盖。
    """
    dx = circle.pos[0] - sector.pos[0]
    dy = circle.pos[1] - sector.pos[1]
    dist = math.hypot(dx, dy)

    # 1. 距离太远,不可能相交
    if dist > sector.radius + circle.radius:
        return False

    # 2. 圆心在扇形圆心 → 相交
    if dist == 0:
        return True

    # 3. 圆心在扇形角度范围内 → 相交(距离已满足)
    angle_to_circle = math.atan2(dy, dx)
    if abs(_angle_diff(angle_to_circle, sector.direction)) <= sector.angle / 2:
        return True

    # 4. 圆心在角度范围外 → 检查圆是否碰到扇形的翅膀
    for wing_end in _sector_wing_endpoints(sector):
        if _point_segment_dist(circle.pos, sector.pos, wing_end) <= circle.radius:
            return True

    return False


def intersect_sector_sector(sector1: Sector, sector2: Sector) -> bool:
    """
    判断两个扇形是否相交。

    =========================================================================
     算法
    =========================================================================
    两个扇形相交的可能情况:
        a. 某方圆心在对方扇形内(含一方完全包含另一方)
        b. 某方翅膀与对方翅膀相交
        c. 某方翅膀进入对方扇形区域(穿过翅膀或弧)

    检查顺序(从便宜到贵):
        1. 圆心在对方扇形内?
        2. 翅膀线段两两相交?
        3. 翅膀线段穿过对方扇形区域?

    注:扇形-扇形相交在当前攻击系统中暂未使用(攻击判定是 圆 vs 扇形),
    此函数为对称完整性而实现,供未来扩展(如攻击互碰)使用。
    """
    # 1. 圆心在对方扇形内
    if _point_in_sector(sector1.pos, sector2):
        return True
    if _point_in_sector(sector2.pos, sector1):
        return True

    # 2. 翅膀线段两两相交
    wings1 = _sector_wing_endpoints(sector1)
    wings2 = _sector_wing_endpoints(sector2)
    for w1 in wings1:
        for w2 in wings2:
            if _segment_segment_intersect(sector1.pos, w1, sector2.pos, w2):
                return True

    # 3. 翅膀穿过对方扇形区域
    for w1 in wings1:
        if _segment_sector_intersect(sector1.pos, w1, sector2):
            return True
    for w2 in wings2:
        if _segment_sector_intersect(sector2.pos, w2, sector1):
            return True

    return False
