# coding=utf-8
"""
文件: server/config/config_loader.py
作用: 从 JSON 配置文件构造 Python 对象(单数据源在 shared_config/,由 sync_config.py 同步过来)

============================================================================
 为什么需要 config_loader
============================================================================
之前配置(ATTACK_CONFIG / ENTITY_CAPABILITIES / HURT_DURATION_MS)硬编码在代码里,
双端各写一份,易漏改。改成 JSON 单数据源后,需要 loader 读取 JSON 并构造对象。

config_loader 是配置访问的唯一入口:
    - 读取 server/config/*.json(sync_config.py 从 shared_config/ 复制过来)
    - 构造 dataclass 对象返回(保持类型安全,IDE 可补全)
    - JSON 里下划线开头的字段(_comment / _desc / _shape_type_values 等)是注释,
      loader 读取时跳过

============================================================================
 和 game_room / entity_config 的关系
============================================================================
config_loader 只负责"读 JSON + 构造对象",不包含业务逻辑。
game_room 和 entity_config 通过调 config_loader 获取配置,然后做自己的事:
    - game_room.get_attack_hits 用 config_loader 构造的 AttackShape 做碰撞判定
    - entity_config.get_capability 用 config_loader 构造的 EntityCapability 做能力校验

============================================================================
 热更影响
============================================================================
config_loader 在模块加载时一次性读取 JSON 缓存到模块级变量。
热更 reload config_loader 模块时会重新读 JSON,但引用旧对象的代码还是用旧配置。
如需运行时热更配置,要手动调 reload(),且 game_room/entity_config 也要一起 reload。
"""

'''
attack_mask / hit_layer: 阵营掩码(按位与,决定攻击能否命中目标)

攻击者用自身类型的 attack_mask,目标用自身类型的 hit_layer:
    attacker_cap.attack_mask & target_cap.hit_layer != 0 → 可命中

当前层级分配:
    1: player  (玩家层,被敌人打)
    2: enemy / stake (敌人/木桩层,被玩家打)

attack_mask 挂在实体类型上(玩家=2 打敌人层,敌人=1 打玩家层),
所以玩家和敌人可复用同一个 atk_id,各自打各自阵营——避免攻击配置耦合阵营。

'''

import json
import math
import os
from dataclasses import dataclass, field
from typing import Dict, List, Optional

# config 目录:server/config/(本文件就在这个目录下)
_CONFIG_DIR = os.path.dirname(os.path.abspath(__file__))


# ===========================================================================
# 形状类型枚举(共用,实体和攻击都用这个)
# ===========================================================================
# 原来叫 AttackShapeType,现在改名 ShapeType 表示"通用形状类型"
# 实体碰撞形状和攻击形状共用这套枚举
class ShapeType:
    SECTOR = "sector"   # 扇形
    RECT = "rect"       # 矩形
    CIRCLE = "circle"   # 圆形
    RING = "ring"       # 环形


# ===========================================================================
# 形状参数(攻击形状用,实体碰撞形状也用)
# ===========================================================================
@dataclass
class ShapeParams:
    """形状参数基类,实际参数由子类决定"""
    pass


@dataclass
class SectorParams(ShapeParams):
    radius: float = 35.0                     # 扇形半径,单位像素
    angle: float = math.pi / 2 * (4 / 3)     # 扇形角度(弧度),±60°


@dataclass
class CircleParams(ShapeParams):
    """圆形参数(实体碰撞用)"""
    radius: float = 24.0


@dataclass
class RectParams(ShapeParams):
    """矩形参数(未来扩展用,如矩形墙)"""
    width: float = 0.0
    height: float = 0.0


# ===========================================================================
# 战斗属性(类型级基础值,EntityInfo 初始化时拷贝一份作为实例运行时状态)
# ===========================================================================
@dataclass
class CombatStats:
    """
    实体战斗属性(类型级基础值)。

    语义:这里是「该类型的初始/基础战斗属性」,所有同类型实体共享同一份数值。
    运行时强化(玩家成长/敌人每波强化)应该改 EntityInfo 里拷贝出来的实例副本,
    不应该回写到这里(配置是只读的)。

    伤害公式(在 game_room 算,不在这层):
        final = attacker.attack_power * atk_shape.damage_percent * 防御系数
    defense 参与防御系数计算,具体公式由 game_room 决定。
    """
    max_hp: int = 0           # 最大血量
    attack_power: int = 0     # 攻击力基础值(乘以攻击配置的 damage_percent 得最终伤害)
    defense: int = 0          # 防御力(参与伤害减免公式)
    look_around_fact_speed: float = 0.5  # 朝向转转转速(弧度/秒)


# ===========================================================================
# 攻击形状 / 攻击配置
# ===========================================================================
@dataclass
class AttackShape:
    """单个攻击形状(一次攻击可由多个形状组成,如双段斩)"""
    shape: str = ShapeType.SECTOR            # 形状类型字符串(和 ShapeType.xxx 值对齐)
    shape_params: Optional[ShapeParams] = None  # 具体参数,根据 shape 决定
    duration: int = 583                      # 攻击持续时间(ms)
    hit_time: int = 83                       # 判定帧时间(从发起算,ms)
    damage_multiplier: float = 1.0           # 伤害倍率(乘以攻击者 attack_power 得原始伤害)
    # 击退距离(像素)。只在连段的最后一段配置:命中后把目标从攻击者中心向外推
    # 该距离,让被击者有反击/逃跑的机会(避免"硬直比攻击间隔短被连死")。
    # 0 表示该段不击退。服务端 web_server 只对"最后一段"应用击退(见 hit_cb)。
    knockback_distance: float = 0.0
    # 注:原 hit_mask 字段已移除。命中层级改由实体类型的 attack_mask 决定
    # (玩家=2 打敌人层,敌人=1 打玩家层),玩家和敌人可复用同一 atk_id


@dataclass
class AttackConfig:
    """攻击配置:一个 atk_id 对应一组形状列表"""
    shape_list: List[AttackShape] = field(default_factory=list)

    def get_attack_time(self) -> int:
        """返回攻击占用的时间(毫秒) = 所有形状的 duration 最大值""" 
        return max(shape.duration for shape in self.shape_list)

# ===========================================================================
# 地形能力配置(地图 tile 类型 → 是否可通行等属性)
# ===========================================================================
# ChunkGenerator.get_tile_type_v3 返回 TerrainType 枚举值(int),
# 本配置表把枚举值映射成能力字段,供寻路系统查询。
# 地形类型 → 名称映射(和 map_generator.TerrainType / ChunkGenerator.gd 的 TerrainType 对齐):
#   0=GRASS, 1=SAND, 2=DIRT, 3=BRICK, 4=WATER
_TERRAIN_ID_TO_NAME: Dict[int, str] = {
    0: "GRASS",
    1: "SAND",
    2: "DIRT",
    3: "BRICK",
    4: "WATER",
}


@dataclass
class TerrainCapability:
    """
    单个地形类型的能力配置。

    字段:
        walkable: 是否可通行(AI 寻路用)。true=可通行,false=障碍。
                  ChunkGenerator 当前只生成 GRASS/SAND,都是 true;
                  BRICK 是预留的障碍地形(城墙/墙壁类)。
        move_cost: 通行代价(预留,当前未用)。A* 寻路默认每格代价 1,
                   若想让沙地走得"慢",可设为 2 让 AI 优先走草地。
                   当前寻路只看 walkable,不看 move_cost(YAGNI)。
    """
    walkable: bool = True
    move_cost: int = 1


# ===========================================================================
# 实体能力配置
# ===========================================================================
@dataclass
class EntityCapability:
    """实体能力 + 碰撞形状描述 + 移动速度 + 死亡配置"""
    # 能力字段(原 entity_config.py 的 EntityCapability)
    can_move: bool = False
    can_attack: bool = False
    can_be_hurt: bool = False
    can_disconnect: bool = False
    can_die: bool = False                    # 能否进入死亡流程(hp<=0 时判定)。player=false 暂不实现,stake=false 木桩不会死,敌人=true
    # 碰撞形状字段(本次新增,原 EntityInfo.radius 删除后挪到这里)
    body_shape: str = ShapeType.CIRCLE       # 碰撞形状类型字符串
    body_params: Optional[ShapeParams] = None  # 碰撞形状参数
    # 碰撞掩码
    hit_layer: int = 0x00000000  # 被判定层掩码(按位与,决定该实体被哪些攻击命中)
    attack_mask: int = 0x00000000  # 攻击判定掩码(发起攻击时打哪些 hit_layer。玩家=2 打敌人层,敌人=1 打玩家层,木桩=0 不能攻击)
    # 移动速度(像素/秒,类型级基础值。can_move=False 时为 0。
    # EnemyMgr 推进敌人位移用 enemy_speed * dt;客户端 LocalPlayerController 用
    # player_speed * dt 算每帧步长。运行时若有减速/加速 buff 应改实例副本,不回写这里)
    speed: float = 0.0
    # 死亡动画时长(毫秒)。can_die=False 时为 0。
    # DeadTimer 到期后 remove_entity + 广播 EntityRemove,让客户端有时间播死亡动画。
    # 服务端"立即判定死亡"但"延迟移除实体",和 hurt 的"立即设 state + 定时器到期恢复"是同一模式。
    dead_duration_ms: int = 0


# ===========================================================================
# 视野配置(敌人视锥)
# ===========================================================================
@dataclass
class VisionParams:
    """
    敌人视野(视锥)参数。

    字段:
        half_angle: 视野半角(弧度),朝向左右各多少。JSON 里 half_angle_deg 用角度存,
                    构造时转弧度。常态(normal)=30°,追逐(chase)=22.5°(追逐更窄)。
        radius:     视野半径(像素)。常态=750,追逐=1000(追逐更远,盯死目标)。
    """
    half_angle: float = math.radians(30.0)
    radius: float = 750.0


# ===========================================================================
# 内部辅助:从 dict 构造对象
# ===========================================================================

def _is_comment_key(key: str) -> bool:
    """判断 JSON key 是否是注释(下划线开头,如 _comment / _desc / _unit)"""
    return key.startswith("_")


def _build_shape_params(shape_type: str, params_dict: dict) -> Optional[ShapeParams]:
    """
    从 dict 构造 ShapeParams 子类对象。
    JSON 里 angle 用角度存(人读直观),这里转成弧度(代码用弧度计算)。
    """
    if shape_type == ShapeType.SECTOR:
        return SectorParams(
            radius=float(params_dict.get("radius", 35.0)),
            # 角度→弧度:rad = deg * π / 180
            angle=math.radians(float(params_dict.get("angle", 120.0))),
        )
    elif shape_type == ShapeType.CIRCLE:
        return CircleParams(
            radius=float(params_dict.get("radius", 24.0)),
        )
    elif shape_type == ShapeType.RECT:
        return RectParams(
            width=float(params_dict.get("width", 0.0)),
            height=float(params_dict.get("height", 0.0)),
        )
    else:
        return None


def _build_attack_shape(shape_dict: dict) -> AttackShape:
    """从 dict 构造 AttackShape 对象"""
    shape_type = shape_dict.get("shape", ShapeType.SECTOR)
    return AttackShape(
        shape=shape_type,
        shape_params=_build_shape_params(shape_type, shape_dict.get("params", {})),
        duration=int(shape_dict.get("duration", 583)),
        hit_time=int(shape_dict.get("hit_time", 83)),
        damage_multiplier=float(shape_dict.get("damage_multiplier", 1.0)),
        # 击退距离(像素),未配置默认 0(不击退)
        knockback_distance=float(shape_dict.get("knockback_distance", 0.0)),
    )


def _build_attack_config(entry_dict: dict) -> AttackConfig:
    """从 dict 构造 AttackConfig 对象"""
    shape_list = []
    for shape_dict in entry_dict.get("shape_list", []):
        shape_list.append(_build_attack_shape(shape_dict))
    return AttackConfig(shape_list=shape_list)


def _build_combat_stats(stats_dict: dict) -> CombatStats:
    """从 dict 构造 CombatStats 对象(未配 combat_stats 时返回零值默认)"""
    if not stats_dict:
        return CombatStats()
    return CombatStats(
        max_hp=int(stats_dict.get("max_hp", 0)),
        attack_power=int(stats_dict.get("attack_power", 0)),
        defense=int(stats_dict.get("defense", 0)),
        look_around_fact_speed=float(stats_dict.get("look_around_fact_speed", 0.5)),
    )


def _build_entity_capability(entry_dict: dict) -> EntityCapability:
    """从 dict 构造 EntityCapability 对象"""
    caps_dict = entry_dict.get("capabilities", {})
    body_shape = entry_dict.get("body_shape", ShapeType.CIRCLE)
    return EntityCapability(
        can_move=bool(caps_dict.get("can_move", False)),
        can_attack=bool(caps_dict.get("can_attack", False)),
        can_be_hurt=bool(caps_dict.get("can_be_hurt", False)),
        can_disconnect=bool(caps_dict.get("can_disconnect", False)),
        can_die=bool(caps_dict.get("can_die", False)),
        body_shape=body_shape,
        body_params=_build_shape_params(body_shape, entry_dict.get("body_params", {})),
        hit_layer=int(entry_dict.get("hit_layer", 0x00000000)),
        attack_mask=int(entry_dict.get("attack_mask", 0x00000000)),
        speed=float(entry_dict.get("speed", 0.0)),
        dead_duration_ms=int(entry_dict.get("dead_duration_ms", 0)),
    )


def _build_terrain_capability(entry_dict: dict) -> TerrainCapability:
    """从 dict 构造 TerrainCapability 对象(未配 walkable 时默认可通行,安全默认)"""
    return TerrainCapability(
        walkable=bool(entry_dict.get("walkable", True)),
        move_cost=int(entry_dict.get("move_cost", 1)),
    )


def _build_vision(entry_dict: dict) -> VisionParams:
    """从 dict 构造 VisionParams(JSON 里 half_angle_deg 用角度存,这里转弧度)"""
    return VisionParams(
        half_angle=math.radians(float(entry_dict.get("half_angle_deg", 30.0))),
        radius=float(entry_dict.get("radius", 750.0)),
    )


# ===========================================================================
# 配置缓存(模块加载时一次性读取)
# ===========================================================================

def _load_json(filename: str) -> dict:
    """读取 server/config/ 下的 JSON 文件"""
    filepath = os.path.join(_CONFIG_DIR, filename)
    with open(filepath, "r", encoding="utf-8") as f:
        return json.load(f)


def _build_attack_config_map(raw: dict) -> Dict[int, AttackConfig]:
    """从 attack_config.json 原始数据构造 {atk_id: AttackConfig} 表"""
    result = {}
    for key, value in raw.items():
        if _is_comment_key(key):
            continue  # 跳过 _comment / _shape_type_values 等注释字段
        try:
            atk_id = int(key)
        except ValueError:
            continue  # 跳过非数字 key(理论上不会有,防御性)
        result[atk_id] = _build_attack_config(value)
    return result


def _build_entity_capability_map(raw: dict) -> Dict[str, EntityCapability]:
    """从 entity_config.json 原始数据构造 {entity_type: EntityCapability} 表"""
    result = {}
    for key, value in raw.items():
        if _is_comment_key(key):
            continue
        result[key] = _build_entity_capability(value)
    return result


def _build_terrain_capability_map(raw: dict) -> Dict[str, TerrainCapability]:
    """
    从 terrain_config.json 原始数据构造 {terrain_name: TerrainCapability} 表。

    JSON 结构:
        {
            "_comment": "...",
            "terrains": {
                "GRASS": {"walkable": true, ...},
                "BRICK": {"walkable": false, ...}
            }
        }

    顶层只有 _comment / _terrain_type_values 等注释字段和 "terrains" 一个数据字段。
    """
    result = {}
    terrains_dict = raw.get("terrains", {})
    for key, value in terrains_dict.items():
        if _is_comment_key(key):
            continue
        result[key] = _build_terrain_capability(value)
    return result


def _build_constants(raw: dict) -> dict:
    """从 constants.json 读取常量,跳过注释字段"""
    return {k: v for k, v in raw.items() if not _is_comment_key(k)}


def _build_vision_map(raw: dict) -> Dict[str, VisionParams]:
    """从 vision_config.json 原始数据构造 {mode: VisionParams} 表(mode=normal/chase)"""
    result = {}
    for key, value in raw.items():
        if _is_comment_key(key):
            continue
        result[key] = _build_vision(value)
    return result


# 模块加载时一次性读取并缓存
_ATTACK_CONFIG_RAW = _load_json("attack_config.json")
_ENTITY_CONFIG_RAW = _load_json("entity_config.json")
_CONSTANTS_RAW = _load_json("constants.json")
_TERRAIN_CONFIG_RAW = _load_json("terrain_config.json")
_VISION_CONFIG_RAW = _load_json("vision_config.json")

_ATTACK_CONFIG_MAP: Dict[int, AttackConfig] = _build_attack_config_map(_ATTACK_CONFIG_RAW)
_ENTITY_CAPABILITY_MAP: Dict[str, EntityCapability] = _build_entity_capability_map(_ENTITY_CONFIG_RAW)
_CONSTANTS: dict = _build_constants(_CONSTANTS_RAW)
_TERRAIN_CAPABILITY_MAP: Dict[str, TerrainCapability] = _build_terrain_capability_map(_TERRAIN_CONFIG_RAW)
_VISION_MAP: Dict[str, VisionParams] = _build_vision_map(_VISION_CONFIG_RAW)


# ===========================================================================
# 对外 API
# ===========================================================================

def get_attack_config(atk_id: int) -> Optional[AttackConfig]:
    """获取某个 atk_id 的攻击配置(含 shape_list);未知返回 None"""
    return _ATTACK_CONFIG_MAP.get(atk_id)


def get_all_attack_configs() -> Dict[int, AttackConfig]:
    """获取全部攻击配置(只读视图,不要修改返回的 dict)"""
    return _ATTACK_CONFIG_MAP


def get_capability(entity_type: str) -> EntityCapability:
    """
    取某个类型的能力配置。
    未列在表里的类型返回"零能力"配置(安全的默认值)——
    加新类型时如果忘记配能力,它会自动变成"啥都不能干",而不是崩溃。
    """
    return _ENTITY_CAPABILITY_MAP.get(entity_type, EntityCapability())


def get_combat_stats(entity_type: str) -> CombatStats:
    """
    取某个类型的基础战斗属性(max_hp/attack_power/defense)。
    未列在表里的类型返回零值 CombatStats(max_hp=0 → 直接死,bug 早暴露)。
    返回的是配置里的对象,调用方不要修改;EntityInfo 初始化时应该自己拷贝一份。
    """
    combat_stats = _build_combat_stats(_ENTITY_CONFIG_RAW[entity_type].get("combat_stats", {}))
    return combat_stats


def get_speed(entity_type: str) -> float:
    """
    取某个类型的移动速度(像素/秒)。
    未列在表里的类型返回 0(不会动,安全默认值)。
    EnemyMgr 推进敌人位移、客户端 LocalPlayerController 算每帧步长都走这里。
    """
    return get_capability(entity_type).speed


def get_dead_duration_ms(entity_type: str) -> int:
    """
    取某个类型的死亡动画时长(毫秒)。
    can_die=False 的类型返回 0(不会死,无死亡动画)。
    DeadTimer 用这个值计时,到期后 remove_entity + 广播 EntityRemove。
    """
    return get_capability(entity_type).dead_duration_ms


def get_constant(name: str, default=None):
    """取全局常量(如 HURT_DURATION_MS);未知返回 default"""
    return _CONSTANTS.get(name, default)


def get_hurt_duration_ms() -> int:
    """取 hurt 硬直时长(毫秒),语法糖"""
    return int(_CONSTANTS.get("HURT_DURATION_MS", 666))


def get_vision(mode: str = "normal") -> VisionParams:
    """
    取敌人视野(视锥)配置。

    Args:
        mode: "normal"(常态:除追逐外的所有状态,如巡逻/张望/攻击) / "chase"(追逐态)。
              未知 mode 回退 normal(安全默认)。

    Returns:
        VisionParams(half_angle 弧度 / radius 像素)
    """
    return _VISION_MAP.get(mode, _VISION_MAP.get("normal", VisionParams()))


def is_vision_enabled() -> bool:
    """
    敌人视锥功能总开关(shared_config/constants.json 的 VISION_ENABLED)。

    默认 True(配置缺失时按开启处理,保持既有行为)。
    关闭后:敌人无视视锥角度/半径限制与追击距离上限,追击最近的玩家
    (AI_ACTIVATE_DISTANCE 激活距离仍生效)。调用方据此跳过 is_in_sight 判定。
    """
    return bool(_CONSTANTS.get("VISION_ENABLED", True))


# ===========================================================================
# 地形能力 API(寻路用)
# ===========================================================================

def get_terrain_capability(terrain_name: str) -> TerrainCapability:
    """
    取某个地形名称的能力配置。

    Args:
        terrain_name: 地形名称字符串,如 "GRASS" / "SAND" / "DIRT" / "BRICK"
                      (和 terrain_config.json 的 key 对齐)

    Returns:
        TerrainCapability 对象。未列在表里的地形返回默认值(walkable=True,
        安全默认——未配置的地形默认可通行,避免寻路把整张地图当障碍)。
    """
    return _TERRAIN_CAPABILITY_MAP.get(terrain_name, TerrainCapability())


def is_walkable(terrain_id: int) -> bool:
    """
    判定某个 tile 类型是否可通行(AI 寻路核心 API)。

    Args:
        terrain_id: ChunkGenerator.get_tile_type_v3 返回的地形类型 ID(int)
                    0=GRASS, 1=SAND, 2=DIRT, 3=BRICK
                    (和 map_generator.TerrainType 枚举值对齐)

    Returns:
        True=可通行,False=障碍。未知 ID 默认 True(安全默认,避免新地形
        忘配置时寻路把整张地图当障碍)。

    用法:
        gen = map_generator.ChunkGenerator(seed)
        if config_loader.is_walkable(gen.get_tile_type_v3(wx, wy)):
            # 这个 tile 可通行,A* 可以走过
    """
    terrain_name = _TERRAIN_ID_TO_NAME.get(terrain_id)
    if terrain_name is None:
        # 未知地形 ID(ChunkGenerator 扩展了新枚举但 terrain_config.json 没配)
        # 默认可通行,避免寻路卡死。同时打 warning 提示开发者补配置
        import logging
        logging.getLogger(__name__).warning(
            f"is_walkable 收到未知 terrain_id={terrain_id},默认返回 True。"
            f"请在 shared_config/terrain_config.json 补配置"
        )
        return True
    return _TERRAIN_CAPABILITY_MAP.get(terrain_name, TerrainCapability()).walkable
