# coding=utf-8
"""
文件: server/game/map_generator.py
作用: Python 版区块生成器,和客户端 client/Script/tiledmap/ChunkGenerator.gd 算法一字不差

============================================================================
 核心约束:双端一致生成
============================================================================
项目采用「服务器持有种子,双端一致生成」的架构(详见 docs/client-ui.md 的无限地图章节)。
同一 chunk 坐标,Python 端和 GDScript 端必须产出【完全相同】的 tile 数据。

跨语言一致性的关键约束(任何一条被破坏,双端产出就会分歧):
    1. 只用整数运算 + 32 位掩码(避免浮点精度差异、避免整数宽度差异)
    2. 每个乘法后立即 & 0xFFFFFFFF(防止 64 位溢出在双端表现不同)
    3. hash 函数用同一组魔法常量 + MurmurHash3 finalizer(双端必须一字不差地复制)
    4. value noise 的插值顺序、floor 行为双端一致

修改本文件时【必须同步修改】client/Script/tiledmap/ChunkGenerator.gd,反之亦然。
任何单边修改都会导致双端地图数据分歧 → 服务端寻路判定和客户端显示对不上。

============================================================================
 和客户端的对应关系
============================================================================
    ChunkGenerator.gd                  map_generator.py
    ─────────────────────────────      ─────────────────────────────
    class_name ChunkGenerator          class ChunkGenerator
    enum TerrainType                   class TerrainType
    const CHUNK_SIZE / BLOCK_SIZE      类常量
    func _init(seed)                   def __init__(self, seed)
    func get_block_type_v3             def get_block_type_v3
    func get_tile_type_v3              def get_tile_type_v3
    func generate_chunk_v3             def generate_chunk_v3
    static func _hash_2d               @staticmethod _hash_2d
    func _value_noise_2d               def _value_noise_2d
    static func _smoothstep            @staticmethod _smoothstep

============================================================================
 一致性陷阱(已逐条核对)
============================================================================
1. 整数宽度
   - GDScript int 是 64 位有符号
   - Python int 是任意精度
   - 解法:每个乘法后立即 & 0xFFFFFFFF,把结果规范到 [0, 2^32-1]
   - 双端 & 0xFFFFFFFF 后值完全相同(都是低 32 位无符号值)

2. floor + int 取整
   - GDScript: int(floor(x)) —— floor 返回 float,int() 向零取整
     (floor 后已是整数,int() 是冗余的但安全)
   - Python: int(math.floor(x)) —— math.floor 在 Py3 直接返回 int
   - 双端结果一致(都向下取整)

3. 浮点精度
   - GDScript float 是 64 位 double
   - Python float 也是 64 位 double
   - 双端加减乘除结果位级相同

4. 位运算
   - GDScript: >> 是有符号右移,但 & 0xFFFFFFFF 后值非负,等价于无符号右移
   - Python: >> 对非负 int 是逻辑右移,结果相同

5. 0xFFFFFFFF 字面量
   - GDScript: 4294967295 (uint32 max)
   - Python: 4294967295 (int,任意精度但值相同)
   - float(0xFFFFFFFF) 双端都是 4294967295.0

6. lerp 实现
   - GDScript 内置 lerp(a, b, t) = a + (b - a) * t
   - Python 无内置,手动实现 a + (b - a) * t(必须用相同表达式,不能换形式)
     注意:a + (b - a) * t 和 a * (1 - t) + b * t 在浮点上【可能不同】!
     前者是 GDScript lerp 的实现,本文件必须用前者保持一致。

============================================================================
 使用方式
============================================================================
    import game.map_generator as map_generator
    gen = map_generator.ChunkGenerator(seed=12345)
    # 单点查询(用于寻路判定某个 tile 是否可通行)
    tile_type = gen.get_tile_type_v3(world_tile_x=100, world_tile_y=-50)
    # 整块生成(用于一次性载入某区域的地形数据)
    chunk_data = gen.generate_chunk_v3(chunk_x=0, chunk_y=0)
    # chunk_data 是 List[int],索引 = local_y * CHUNK_SIZE + local_x
"""

import math
from typing import List


# ===========================================================================
# 地形类型枚举
# ===========================================================================
# 双端共享的「是什么」语义。服务端只需知道类型,不需要 atlas coord。
# atlas coord 映射是客户端渲染层的事(见 InfiniteTileMap.gd 的 _TERRAIN_ATLAS)。
#
# 值必须和 ChunkGenerator.gd 的 TerrainType 枚举顺序一致:
#   GRASS = 0, SAND = 1, DIRT = 2, BRICK = 3
class TerrainType:
    GRASS = 0   # 草地(可通行)
    SAND = 1    # 沙地(可通行)
    DIRT = 2    # 泥地(预留,可通行)
    BRICK = 3   # 砖地(预留,可能不可通行)


# ===========================================================================
# 算法常量(双端必须一字不差)
# ===========================================================================
# Chunk 边长(tile 数)。双端必须一致。
CHUNK_SIZE: int = 16

# block 边长(tile 数)。2 = 每 block 含 2×2=4 个 tile。
# 双端必须一致。CHUNK_SIZE=16 能被 BLOCK_SIZE=2 整除,chunk 边界和 block 边界对齐。
BLOCK_SIZE: int = 2

# block type 生成的 noise scale。
# 0.15 = 每 ~7 个 block 一个噪声周期,产生中等大小的区域(约 7×7 block = 14×14 tile)
# 调大 → 更碎;调小 → 更大片。
V3_NOISE_SCALE: float = 0.15

# SAND 激活阈值。noise < 此值 → SAND,否则 GRASS。
# 0.35 = ~35% SAND 覆盖率。
V3_SAND_THRESHOLD: float = 0.35


# ===========================================================================
# 区块生成器
# ===========================================================================
class ChunkGenerator:
    """
    纯函数式区块生成器。输入 chunk 坐标,输出该 chunk 内每个 tile 的地形类型。

    实例只持有 seed,所有方法都是确定性的纯函数:
        同一 seed + 同一坐标 → 永远相同输出(跨语言、跨进程一致)

    使用方式见模块顶部文档字符串。
    """

    def __init__(self, seed: int = 0) -> None:
        """
        构造生成器。

        Args:
            seed: 地图种子。服务端启动时生成(或硬编码),通过 MapInfo 消息下发给客户端。
                  客户端 InfiniteTileMap.setup(seed) 用相同 seed 构造 ChunkGenerator。
        """
        self._seed: int = seed

    # -------------------------------------------------------------------
    # 对外接口
    # -------------------------------------------------------------------

    def get_block_type_v3(self, block_x: int, block_y: int) -> int:
        """
        查询 block 的地形类型。纯函数,跨 chunk 友好。

        用 value noise 产生成片区域,避免碎块。
        当前只区分 SAND 和 GRASS。扩展时在此函数增加 DIRT/BRICK 判断。

        Args:
            block_x, block_y: block 坐标(世界 tile 坐标 / BLOCK_SIZE)

        Returns:
            TerrainType.GRASS 或 TerrainType.SAND
        """
        n: float = self._value_noise_2d(
            block_x * V3_NOISE_SCALE,
            block_y * V3_NOISE_SCALE,
        )
        if n < V3_SAND_THRESHOLD:
            return TerrainType.SAND
        return TerrainType.GRASS

    def get_tile_type_v3(self, world_tile_x: int, world_tile_y: int) -> int:
        """
        单点查询。世界 tile 坐标 → 地形类型。

        同一个 block 的 4 个 tile 返回相同类型(由 get_block_type_v3 保证)。
        寻路判定某个 tile 是否可通行时调本方法。

        Args:
            world_tile_x, world_tile_y: 世界 tile 坐标(可为负)

        Returns:
            TerrainType.GRASS / SAND / DIRT / BRICK
        """
        # floor 后转 int,双端一致(Python int() 向零取整,必须先 floor)
        # 和 ChunkGenerator.gd 的 int(floor(float(x) / BLOCK_SIZE)) 一致
        bx: int = int(math.floor(float(world_tile_x) / BLOCK_SIZE))
        by: int = int(math.floor(float(world_tile_y) / BLOCK_SIZE))
        return self.get_block_type_v3(bx, by)

    def generate_chunk_v3(self, chunk_x: int, chunk_y: int) -> List[int]:
        """
        生成整个 chunk 的 tile 数据。

        Args:
            chunk_x, chunk_y: chunk 坐标(可为负)

        Returns:
            List[int],长度 = CHUNK_SIZE * CHUNK_SIZE。
            索引 = local_y * CHUNK_SIZE + local_x
            (和 ChunkGenerator.gd 的 PackedInt32Array 索引规则一致)
        """
        cs: int = CHUNK_SIZE
        data: List[int] = [0] * (cs * cs)
        for ly in range(cs):
            for lx in range(cs):
                wx: int = chunk_x * cs + lx
                wy: int = chunk_y * cs + ly
                data[ly * cs + lx] = self.get_tile_type_v3(wx, wy)
        return data

    # -------------------------------------------------------------------
    # 内部算法:hash + value noise
    # -------------------------------------------------------------------

    @staticmethod
    def _hash_2d(seed: int, x: int, y: int) -> float:
        """
        整数哈希:输入 (seed, x, y) → [0, 1] 浮点。

        跨语言一致性的关键:每步乘法后立即掩码到 32 位无符号整数。

        结构:三维度独立乘法混合 → XOR 合并 → MurmurHash3 finalizer 打乱

        为什么加 finalizer(avalanche):
            纯 XOR (seed*A)^(x*B)^(y*C) 没有位间扩散,分布质量低。
            相邻输入(如 x 和 x+1)只改变 hash 的部分位,输出相关性高,
            会导致某些区域系统性偏向某地形类型。
            finalizer 让「输入差 1 → 输出约一半位翻转」,分布均匀。

        双端一致约束:GDScript 端必须一字不差复制整个函数(含 finalizer)。
        finalizer 是纯整数运算(XOR-shift + 乘法 + 掩码),Python 可直接实现。

        常数含义:
            - 73856093 / 19349663 / 83492791 = SPICE library hash 质数(初始混合)
            - 0x85EBCA6B / 0xC2B2AE35 = MurmurHash3 finalizer 乘法常数(avalanche)
        """
        # 每个乘法后立即掩码,防止 64 位溢出在 GDScript/Python 表现不同
        # GDScript int 是 64 位有符号,Python int 是任意精度
        # & 0xFFFFFFFF 在双端都把结果规范到 [0, 2^32-1]
        h1: int = (seed * 73856093) & 0xFFFFFFFF
        h2: int = (x * 19349663) & 0xFFFFFFFF
        h3: int = (y * 83492791) & 0xFFFFFFFF
        h: int = (h1 ^ h2 ^ h3) & 0xFFFFFFFF
        # MurmurHash3 finalizer:三轮 XOR-shift + 乘法,avalanche 打乱所有位
        h ^= h >> 16
        h = (h * 0x85EBCA6B) & 0xFFFFFFFF
        h ^= h >> 13
        h = (h * 0xC2B2AE35) & 0xFFFFFFFF
        h ^= h >> 16
        # 归一化到 [0, 1)。用 float(u32_max) 而非 4294967295.0 显得自解释
        return float(h) / float(0xFFFFFFFF)

    def _value_noise_2d(self, x: float, y: float) -> float:
        """
        value noise 2D:对网格点采样 hash,双线性插值得到连续噪声。

        输入是浮点坐标(通常 = tile 坐标 * noise_scale)
        输出 [0, 1]

        算法步骤:
            1. 取 floor(x), floor(y) 得到网格点整数坐标
            2. 计算 4 个角的 hash 值
            3. 用 smoothstep 插值(比线性插值更平滑,避免方块感)
        """
        # floor 后转 int,双端一致(GDScript int() 是向零取整,必须先 floor)
        xi: int = int(math.floor(x))
        yi: int = int(math.floor(y))
        # 小数部分,范围 [0, 1)
        # 用 x - xi 而非 fmod,避免负数取模在双端行为差异
        xf: float = x - xi
        yf: float = y - yi

        # 4 个角的 hash 值
        v00: float = self._hash_2d(self._seed, xi, yi)
        v10: float = self._hash_2d(self._seed, xi + 1, yi)
        v01: float = self._hash_2d(self._seed, xi, yi + 1)
        v11: float = self._hash_2d(self._seed, xi + 1, yi + 1)

        # smoothstep 插值权重:3t^2 - 2t^3,比线性插值更平滑
        u: float = self._smoothstep(xf)
        v: float = self._smoothstep(yf)

        # 双线性插值
        # 注意:必须用 a + (b - a) * t 形式,和 GDScript 内置 lerp 实现一致。
        # 不能换成 a * (1 - t) + b * t —— 浮点运算不满足结合律,两种写法结果可能不同!
        a: float = v00 + (v10 - v00) * u
        b: float = v01 + (v11 - v01) * u
        return a + (b - a) * v

    @staticmethod
    def _smoothstep(t: float) -> float:
        """
        smoothstep:3t^2 - 2t^3

        标准图形学平滑函数,双端实现一致即可。
        """
        return t * t * (3.0 - 2.0 * t)


# ===========================================================================
# 自测:用 seed=12345 跑几个 chunk,打印结果供和客户端对比
# ===========================================================================
# 运行方式:
#     cd server
#     python -m game.map_generator
#
# 输出会打印 (0,0) / (1,0) / (-1,0) 三个 chunk 的 tile 数据(16×16 矩阵)。
# 在 Godot 编辑器里跑对应的 GDScript 测试(详见下方注释),对比输出是否一致。
def _self_test() -> None:
    """简单自测:验证算法可运行,打印若干 chunk 的数据供人工对比"""
    gen = ChunkGenerator(seed=12345)

    print("=" * 60)
    print("Python 版 map_generator 自测")
    print(f"seed = 12345, CHUNK_SIZE = {CHUNK_SIZE}, BLOCK_SIZE = {BLOCK_SIZE}")
    print(f"V3_NOISE_SCALE = {V3_NOISE_SCALE}, V3_SAND_THRESHOLD = {V3_SAND_THRESHOLD}")
    print("=" * 60)

    # 测试若干单点查询
    print("\n[单点查询 get_tile_type_v3]")
    test_points = [(0, 0), (1, 0), (0, 1), (15, 15), (16, 0), (-1, -1), (100, -50)]
    for wx, wy in test_points:
        t = gen.get_tile_type_v3(wx, wy)
        type_name = {0: "GRASS", 1: "SAND", 2: "DIRT", 3: "BRICK"}.get(t, "?")
        print(f"  get_tile_type_v3({wx:>4}, {wy:>4}) = {t} ({type_name})")

    # 测试 chunk 生成,打印成矩阵方便和客户端对比
    print("\n[chunk 生成 generate_chunk_v3] (G=GRASS, S=SAND)")
    test_chunks = [(0, 0), (1, 0), (-1, 0)]
    for cx, cy in test_chunks:
        data = gen.generate_chunk_v3(cx, cy)
        print(f"\n  chunk({cx}, {cy}):")
        for ly in range(CHUNK_SIZE):
            row = "".join(
                "G" if data[ly * CHUNK_SIZE + lx] == TerrainType.GRASS else "S"
                for lx in range(CHUNK_SIZE)
            )
            print(f"    {row}")

    # 打印一个 hash 值,用于和 GDScript 端逐字节对比
    print("\n[hash_2d 一致性验证点]")
    test_hashes = [(12345, 0, 0), (12345, 1, 0), (12345, 0, 1), (12345, 100, -50)]
    for seed, x, y in test_hashes:
        h = ChunkGenerator._hash_2d(seed, x, y)
        # 打印足够多的小数位(20 位),便于和 GDScript 端逐位对比
        print(f"  _hash_2d(seed={seed}, x={x:>4}, y={y:>4}) = {h:.20f}")


if __name__ == "__main__":
    _self_test()
