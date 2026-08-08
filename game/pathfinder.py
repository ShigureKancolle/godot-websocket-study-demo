# coding=utf-8
"""
文件: server/game/pathfinder.py
作用: A* 网格寻路(服务端 AI 用,客户端不需要)

============================================================================
 架构位置
============================================================================
    ChaseState.find_move_path
        ↓
    ai_state_helper.find_path(room, start, end)
        ↓
    Pathfinder.find_path(start, end, radius)    ← 本文件
        ↓
    map_generator.get_tile_type_v3 + config_loader.is_walkable
        ↓
    返回 List[(x, y)] 路径点(像素坐标)

pathfinder 是纯算法模块,不依赖 GameRoom,只依赖:
    - map_generator.ChunkGenerator(查 tile 类型)
    - config_loader.is_walkable(判断 tile 是否可通行)

============================================================================
 为什么用 A* on grid(不用的方案为什么不选)
============================================================================
    - NavMesh:2D 网格游戏用 NavMesh 过度工程化,且生成复杂
    - JPS (Jump Point Search):A* 的优化版,大范围寻路快 10 倍,
      但实现复杂、调试难。当前搜索半径固定 500px(约 31×31 tile),
      A* 性能足够,JPS 的收益不值得复杂度代价
    - BFS:不考虑代价,所有方向等权,路径质量差(不走对角线)
    - 直线追击:当前 chase_state 的临时方案,绕不过障碍

A* 优势:
    - 支持对角线移动(路径自然,不像 BFS 那样锯齿)
    - 支持代价字段(未来 move_cost 可让 AI 绕开沙地走草地)
    - 实现直观,调试容易(可打印 open/closed 集合)

============================================================================
 搜索范围限定(无限地图不能全图搜索)
============================================================================
地图是无限的(ChunkGenerator 按 seed 生成任意 chunk),不能全图搜索 A*。
限定方法:以起点为中心,search_radius 像素为半径的矩形范围内搜索。

    search_radius = 500px(默认)
    tile_size = 16px
    → 搜索范围 = 63×63 tile(约 4 chunk 边长)

超出范围的终点:直接返回 None(放弃寻路,让 AI 切回巡逻)。
为什么是矩形不是圆形:矩形遍历更简单,A* 本身会优先走直线,
圆形边界的好处可忽略。

============================================================================
 对角移动防穿墙
============================================================================
8 方向移动允许对角线,但不能穿过墙角:
    若从 (x,y) 斜走到 (x+1,y+1),要求 (x+1,y) 和 (x,y+1) 都可通行。
    否则会出现「贴着墙角挤过去」的视觉bug。

示意(■=墙,□=可走):
    □ ■
    ■ □
    左上和右下都是可走,但右上和左下都是墙。
    此时不能从左上斜走到右下——会「穿过」墙角。
    强制走 L 形(先右后下,或先下后右)。
"""

import heapq
import math
from typing import List, Optional, Tuple

import config.config_loader as config_loader
import game.map_generator as map_generator


# ===========================================================================
# 常量
# ===========================================================================
# tile 像素边长(和 InfiniteTileMap._tile_size / TileSet.tile_size 一致)
# 当前硬编码 16,未来若 tile_size 可变,改从配置读
TILE_SIZE: int = 16

# 对角线移动代价 = sqrt(2) ≈ 1.414
# 用浮点而非预乘整数(如 10/14),保持精度简单
DIAGONAL_COST: float = math.sqrt(2.0)

# 8 方向偏移(4 正方向 + 4 对角方向)
# (dx, dy, is_diagonal)
# 顺序不重要,A* 会用 f_score 排序
_DIRECTIONS: List[Tuple[int, int, bool]] = [
    (0, -1, False),   # 上
    (0, 1, False),    # 下
    (-1, 0, False),   # 左
    (1, 0, False),    # 右
    (-1, -1, True),   # 左上
    (1, -1, True),    # 右上
    (-1, 1, True),    # 左下
    (1, 1, True),     # 右下
]


class Pathfinder:
    """
    A* 网格寻路器。

    持有 ChunkGenerator 引用(查 tile 类型),不持有任何状态——
    find_path 是纯函数,同输入永远同输出,线程安全。

    使用方式:
        gen = map_generator.ChunkGenerator(seed=12345)
        pf = Pathfinder(gen)
        path = pf.find_path(start=(100, 100), end=(200, 200))
        if path:
            # 沿 path 走
    """

    def __init__(self, generator: map_generator.ChunkGenerator, tile_size: int = TILE_SIZE):
        """
        Args:
            generator: ChunkGenerator 实例(查 tile 类型用)
            tile_size: tile 像素边长(默认 16,和客户端 TileSet 一致)
        """
        self._gen = generator
        self._tile_size = tile_size

    # -------------------------------------------------------------------
    # 对外接口
    # -------------------------------------------------------------------

    def find_path(
        self,
        start_pos: Tuple[float, float],
        end_pos: Tuple[float, float],
        search_radius: float = 500.0,
    ) -> Optional[List[Tuple[float, float]]]:
        """
        A* 寻路:从 start_pos 走到 end_pos,返回路径点列表。

        Args:
            start_pos: 起点世界坐标(像素,如 (100.0, 200.0))
            end_pos:   终点世界坐标(像素)
            search_radius: 搜索半径(像素)。以起点为中心的矩形范围内搜索。
                           超出范围的终点直接返回 None。
                           默认 500px(约 31×31 tile),足够敌人追击视野内的玩家。

        Returns:
            路径点列表 List[(x, y)](像素坐标),不含起点,含终点。
            找不到路径时返回 None。
            起点和终点在同一 tile 时返回空列表 [](表示已到达)。

        路径点含义:
            每个 path point 是一个 tile 的中心点(像素坐标)。
            敌人沿路径走时,每到达一个 path point,取下一个继续走。
            路径已做「视线简化」(line-of-sight 优化),合并共线段,
            减少路径点数量,让敌人走得 smoother。
        """
        # 1. 像素坐标 → tile 坐标
        start_tile = self._world_to_tile(start_pos)
        end_tile = self._world_to_tile(end_pos)

        # 起点和终点在同一 tile:已到达,返回空列表
        # (调用方据此判断「不需要再走」)
        if start_tile == end_tile:
            return []

        # 2. 检查终点是否在搜索范围内(超出范围放弃寻路)
        # 用 tile 坐标算距离,避免浮点误差
        # search_radius_px / tile_size = search_radius_tiles
        radius_tiles = int(search_radius / self._tile_size)
        dx = abs(end_tile[0] - start_tile[0])
        dy = abs(end_tile[1] - start_tile[1])
        if dx > radius_tiles or dy > radius_tiles:
            return None

        # 3. 检查终点本身是否可通行
        # 终点不可通行时,A* 会找不到路径(终点在 closed_set 里永远进不去)
        # 提前返回 None,省得跑完整轮 A*
        if not self._is_walkable(end_tile[0], end_tile[1]):
            # 终点在墙里:尝试找终点周围最近的 walkable tile 作为替代
            # (玩家站在墙边时,敌人需要走到能攻击的位置)
            alt_end = self._find_nearest_walkable(end_tile, radius_tiles=3)
            if alt_end is None:
                return None
            end_tile = alt_end

        # 4. 起点也要检查:如果起点在墙里(不该发生,但防御性处理),
        # 直接返回 None 避免卡死
        if not self._is_walkable(start_tile[0], start_tile[1]):
            return None

        # 5. 跑 A*
        tile_path = self._astar(start_tile, end_tile, radius_tiles)
        if tile_path is None:
            return None

        # 6. tile 坐标 → 像素坐标(每个 tile 的中心点)
        pixel_path = [self._tile_to_world_center(t) for t in tile_path]

        # 7. 路径简化:用 line-of-sight 合并共线段
        # 减少 path point 数量,敌人走得 smoother,也减少 apply_move_dir 调用
        pixel_path = self._simplify_path(pixel_path)

        # 8. 去掉起点(敌人当前就在起点,不需要走过去)
        # 保留终点(需要走到终点)
        if pixel_path and len(pixel_path) > 1:
            pixel_path = pixel_path[1:]

        return pixel_path

    # -------------------------------------------------------------------
    # 内部:坐标转换
    # -------------------------------------------------------------------

    def _world_to_tile(self, world_pos: Tuple[float, float]) -> Tuple[int, int]:
        """像素坐标 → tile 坐标(左上角原点,向右向下为正)"""
        # 用 floor 而非 int:负坐标时 int() 向零取整会出错
        # (int(-1.5) = -1,但 -1.5px 应该在 -1 tile 还是 -2 tile?
        #  floor(-1.5) = -2,即 -1.5px 属于 [-16, 0) 区间的 -1 tile...
        #  实际上 -1.5px 在 tile(-1) 的 [-16, 0) 范围内,但 floor(-1.5/16)=floor(-0.09)=-1
        #  这里和 InfiniteTileMap._world_to_chunk 保持一致的 floor 逻辑)
        tx = int(math.floor(world_pos[0] / self._tile_size))
        ty = int(math.floor(world_pos[1] / self._tile_size))
        return (tx, ty)

    def _tile_to_world_center(self, tile_pos: Tuple[int, int]) -> Tuple[float, float]:
        """tile 坐标 → 该 tile 中心的像素坐标"""
        # tile 中心 = tile 原点 + tile_size/2
        cx = tile_pos[0] * self._tile_size + self._tile_size / 2.0
        cy = tile_pos[1] * self._tile_size + self._tile_size / 2.0
        return (cx, cy)

    # -------------------------------------------------------------------
    # 内部:可通行性查询
    # -------------------------------------------------------------------

    def _is_walkable(self, tile_x: int, tile_y: int) -> bool:
        """
        判定某个 tile 是否可通行。

        封装了 map_generator + config_loader 的两步查询:
            1. map_generator.get_tile_type_v3(tile_x, tile_y) → 地形类型 ID
            2. config_loader.is_walkable(terrain_id) → 是否可通行
        """
        terrain_id = self._gen.get_tile_type_v3(tile_x, tile_y)
        return config_loader.is_walkable(terrain_id)

    def _find_nearest_walkable(
        self, center_tile: Tuple[int, int], radius_tiles: int = 3
    ) -> Optional[Tuple[int, int]]:
        """
        在 center_tile 周围 radius_tiles 范围内找最近的 walkable tile。

        用于终点本身在墙里时,找替代终点(让敌人走到墙边能攻击的位置)。

        搜索方式:螺旋向外扩展(从距离 1 开始,逐圈扩大)。
        """
        for r in range(1, radius_tiles + 1):
            # 在距离 r 的菱形边界上搜索(曼哈顿距离 = r)
            for dx in range(-r, r + 1):
                dy = r - abs(dx)
                # 上下两个候选
                for sign in (-1, 1):
                    nx = center_tile[0] + dx
                    ny = center_tile[1] + sign * dy
                    if self._is_walkable(nx, ny):
                        return (nx, ny)
        return None

    # -------------------------------------------------------------------
    # 内部:A* 核心算法
    # -------------------------------------------------------------------

    def _astar(
        self,
        start: Tuple[int, int],
        goal: Tuple[int, int],
        radius_tiles: int,
    ) -> Optional[List[Tuple[int, int]]]:
        """
        A* 核心搜索。

        Args:
            start: 起点 tile 坐标
            goal:  终点 tile 坐标
            radius_tiles: 搜索半径(tile 数)。超出此范围的 tile 不扩展。

        Returns:
            tile 坐标路径(含起点和终点),或 None(找不到)。
        """
        # open_set: 优先队列,元素 = (f_score, counter, tile)
        # counter 是唯一递增的序号,用于在 f_score 相同时保持插入顺序
        # (heapq 不支持 dict 比较,加 counter 避免 "TypeError: '<' not supported")
        counter = 0
        open_heap: List[Tuple[float, int, Tuple[int, int]]] = []
        heapq.heappush(open_heap, (0.0, counter, start))

        # came_from: tile → 它是从哪个 tile 来的(路径重建用)
        came_from: dict = {}

        # g_score: 起点到当前 tile 的实际代价
        # 用 dict 存,默认无穷大(表示未访问)
        g_score: dict = {start: 0.0}

        # closed_set: 已确定最短路径的 tile(不再扩展)
        # 用 set 比 dict 更省内存
        closed_set: set = set()

        while open_heap:
            # 取 f_score 最小的 tile
            _, _, current = heapq.heappop(open_heap)

            # 已到达终点:重建路径
            if current == goal:
                return self._reconstruct_path(came_from, current)

            # 已在 closed 里:跳过(可能是同一 tile 被多次 push,取最小的那次已处理)
            if current in closed_set:
                continue
            closed_set.add(current)

            # 扩展 8 邻居
            for dx, dy, is_diagonal in _DIRECTIONS:
                neighbor = (current[0] + dx, current[1] + dy)

                # 已在 closed 里:跳过
                if neighbor in closed_set:
                    continue

                # 搜索半径限制:超出范围的 tile 不扩展
                # 用相对起点的曼哈顿距离,避免 A* 跑到地图边缘
                if abs(neighbor[0] - start[0]) > radius_tiles or \
                   abs(neighbor[1] - start[1]) > radius_tiles:
                    continue

                # 邻居必须可通行
                if not self._is_walkable(neighbor[0], neighbor[1]):
                    continue

                # 对角移动防穿墙:两个相邻正方向必须都可通行
                # 示意:从 current 斜走到 neighbor,
                #   current=(x,y), neighbor=(x+dx, y+dy)
                #   要求 (x+dx, y) 和 (x, y+dy) 都可通行
                if is_diagonal:
                    if not self._is_walkable(current[0] + dx, current[1]) or \
                       not self._is_walkable(current[0], current[1] + dy):
                        continue

                # 算 g_score:正方向代价 1,对角方向代价 sqrt(2)
                step_cost = DIAGONAL_COST if is_diagonal else 1.0
                tentative_g = g_score[current] + step_cost

                # 如果是更短的路径,更新
                # (g_score.get(neighbor, inf) 表示未访问过的 tile 默认无穷大)
                if tentative_g < g_score.get(neighbor, float('inf')):
                    came_from[neighbor] = current
                    g_score[neighbor] = tentative_g
                    f_score = tentative_g + self._heuristic(neighbor, goal)
                    counter += 1
                    heapq.heappush(open_heap, (f_score, counter, neighbor))

        # open_set 空了还没到终点:找不到路径
        return None

    def _heuristic(
        self, tile: Tuple[int, int], goal: Tuple[int, int]
    ) -> float:
        """
        A* 启发式函数:估计从 tile 到 goal 的代价。

        用「对角线距离」(octile distance),适合 8 方向移动:
            h = max(dx, dy) + (sqrt(2)-1) * min(dx, dy)
        其中 dx, dy 是两个轴的距离。

        这个启发式是 admissible(不高估)且 consistent(单调),
        保证 A* 找到最优路径。
        """
        dx = abs(tile[0] - goal[0])
        dy = abs(tile[1] - goal[1])
        return float(max(dx, dy)) + (DIAGONAL_COST - 1.0) * float(min(dx, dy))

    def _reconstruct_path(
        self, came_from: dict, current: Tuple[int, int]
    ) -> List[Tuple[int, int]]:
        """
        从 came_from 表重建路径:从终点回溯到起点,再反转。

        返回的路径含起点和终点,顺序是从起点到终点。
        """
        path = [current]
        while current in came_from:
            current = came_from[current]
            path.append(current)
        path.reverse()
        return path

    # -------------------------------------------------------------------
    # 内部:路径简化(line-of-sight 优化)
    # -------------------------------------------------------------------

    def _simplify_path(
        self, pixel_path: List[Tuple[float, float]]
    ) -> List[Tuple[float, float]]:
        """
        用 line-of-sight 算法简化路径:合并可以直走的连续段。

        原始 A* 路径可能有很多中间点(每个 tile 一个),
        其中很多是冗余的——如果从 A 能直线走到 C(中间不穿墙),
        就不需要经过 B。

        算法:
            从起点开始,尽量往后看——找到能直走的「最远点」,
            作为下一个 path point。然后从该点重复。

        示意:
            原始:A → B → C → D → E
            若 A 能直走 D(中间不穿墙),简化为:A → D → E

        这个优化让敌人走得更自然(不锯齿),也减少 apply_move_dir 调用。
        """
        if len(pixel_path) <= 2:
            # 路径太短,无需简化
            return pixel_path

        simplified = [pixel_path[0]]
        i = 0
        while i < len(pixel_path) - 1:
            # 从 i 往后找能直走的最远点 j
            j = len(pixel_path) - 1  # 先假设能直走到终点
            while j > i + 1:
                if self._has_line_of_sight(pixel_path[i], pixel_path[j]):
                    break
                j -= 1
            simplified.append(pixel_path[j])
            i = j

        return simplified

    def _has_line_of_sight(
        self, pos_a: Tuple[float, float], pos_b: Tuple[float, float]
    ) -> bool:
        """
        判断从 pos_a 到 pos_b 是否有直线视线(中间没有墙)。

        用 Bresenham 算法遍历两点连线上的所有 tile,
        任何一个 tile 不可通行就返回 False。

        用于路径简化:如果 A 能直线走到 B,就不需要中间点。
        """
        tile_a = self._world_to_tile(pos_a)
        tile_b = self._world_to_tile(pos_b)

        # Bresenham 直线算法(整数版本,双端一致)
        x0, y0 = tile_a
        x1, y1 = tile_b
        dx = abs(x1 - x0)
        dy = abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx - dy

        while True:
            # 当前 tile 不可通行:视线被挡
            if not self._is_walkable(x0, y0):
                return False
            # 到达终点
            if x0 == x1 and y0 == y1:
                return True
            e2 = 2 * err
            if e2 > -dy:
                err -= dy
                x0 += sx
            if e2 < dx:
                err += dx
                y0 += sy


# ===========================================================================
# 自测:用 seed=12345 跑几个寻路场景
# ===========================================================================
# 运行方式:
#     cd server
#     python -m game.pathfinder
def _self_test() -> None:
    """简单自测:验证寻路能跑通"""
    gen = map_generator.ChunkGenerator(seed=12345)
    pf = Pathfinder(gen)

    print("=" * 60)
    print("Pathfinder 自测 (seed=12345)")
    print("=" * 60)

    # 测试 1:短距离寻路(同 chunk 内)
    start = (100.0, 100.0)
    end = (200.0, 200.0)
    path = pf.find_path(start, end)
    print(f"\n[测试1] 短距离寻路 {start} → {end}")
    print(f"  路径点数: {len(path) if path else 'None'}")
    if path:
        for i, p in enumerate(path):
            print(f"    [{i}] ({p[0]:.1f}, {p[1]:.1f})")

    # 测试 2:超远距离(超出搜索半径)
    start = (0.0, 0.0)
    end = (5000.0, 5000.0)
    path = pf.find_path(start, end)
    print(f"\n[测试2] 超远距离 {start} → {end} (应返回 None)")
    print(f"  结果: {path}")

    # 测试 3:同 tile
    start = (100.0, 100.0)
    end = (105.0, 105.0)  # 同一 tile 内
    path = pf.find_path(start, end)
    print(f"\n[测试3] 同 tile {start} → {end} (应返回空列表)")
    print(f"  结果: {path}")

    # 测试 4:中距离寻路
    start = (0.0, 0.0)
    end = (300.0, 100.0)
    path = pf.find_path(start, end)
    print(f"\n[测试4] 中距离寻路 {start} → {end}")
    print(f"  路径点数: {len(path) if path else 'None'}")
    if path:
        for i, p in enumerate(path):
            print(f"    [{i}] ({p[0]:.1f}, {p[1]:.1f})")

    # 测试 5:可通行性查询(打印几个 tile 的状态)
    print(f"\n[测试5] 可通行性查询")
    test_tiles = [(0, 0), (1, 0), (0, 1), (10, 10), (-5, -5)]
    for tx, ty in test_tiles:
        terrain = gen.get_tile_type_v3(tx, ty)
        walkable = config_loader.is_walkable(terrain)
        terrain_name = {0: "GRASS", 1: "SAND", 2: "DIRT", 3: "BRICK"}.get(terrain, "?")
        print(f"  tile({tx:>3}, {ty:>3}) = {terrain_name} walkable={walkable}")


if __name__ == "__main__":
    _self_test()
