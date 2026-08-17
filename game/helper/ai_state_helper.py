# coding=utf-8
# AI 状态帮助类
import math
from typing import TYPE_CHECKING, Optional
import config.config_loader as config_loader
import game.collision as collision
if TYPE_CHECKING:
    from game.game_room import GameRoom, EntityInfo
    from game.enemy_mgr import enemy_ai_machine

def find_nearest_entity_in_sight(room: "GameRoom", entity_id: str, entity_type: str = "", vision_mode: str = "normal", search_radius: float = 500) -> str:
    """
    查找视野(视锥)内最近的目标实体。

    视野参数由 vision_mode 决定(常态 normal / 追逐 chase),判定维度:
        距离(视锥半径) + 角度(视锥半角)。
    遮挡判断不在此做(由 find_path 可达性承担:墙后目标即使可见,find_path 返回 None 也会被过滤)。

    视锥关闭时(VISION_ENABLED=false,见 config_loader.is_vision_enabled):
        跳过角度/半径过滤,搜索范围放宽到 AI_ACTIVATE_DISTANCE(激活距离),
        即激活距离内「无论多远」都按最近目标算,与 chase 不因距离放弃追击一致。
    """
    finder_entity = room.get_entity(entity_id)
    if not finder_entity:
        return ""

    vision_enabled = config_loader.is_vision_enabled()
    if vision_enabled:
        # 取当前状态的视野参数(常态 30°/750px,追逐 22.5°/1000px)
        vision = config_loader.get_vision(vision_mode)
    else:
        # 视锥关闭:搜索半径放宽到 AI 激活距离,保证激活范围内的玩家都能被找到
        search_radius = config_loader.get_constant("AI_ACTIVATE_DISTANCE", 1500.0)

    entities: list[EntityInfo] = room.snapshot()
    nearest_entity_id = ""
    nearest_distance = None
    for other_entity in entities:
        if other_entity.entity_id == entity_id:
            continue
        if entity_type and other_entity.entity_type != entity_type:
            continue

        # 视锥判定:距离 + 角度(目标必须在朝向的视锥内)。视锥关闭时跳过
        if vision_enabled and not is_in_sight(finder_entity, other_entity, vision):
            continue

        # 达不到的路径不算找到了(墙后/被包围的目标即使可见也追不到)
        move_path = find_path(room, (finder_entity.x, finder_entity.y), (other_entity.x, other_entity.y), search_radius)
        if move_path is None:
            continue

        # 取最近的可达目标
        dx = other_entity.x - finder_entity.x
        dy = other_entity.y - finder_entity.y
        distance = (dx ** 2 + dy ** 2) ** 0.5
        if nearest_entity_id == "" or distance < nearest_distance:
            nearest_entity_id = other_entity.entity_id
            nearest_distance = distance

    return nearest_entity_id


def is_in_sight(finder_entity: "EntityInfo", other_entity: "EntityInfo", vision: config_loader.VisionParams) -> bool:
    """
    判断目标是否在发现者的视锥内(纯几何:距离 + 角度)。

    Args:
        finder_entity: 发现者(用它的 x/y/facing)
        other_entity:  目标
        vision:        config_loader.VisionParams(half_angle 弧度 / radius 像素)

    说明:
        - 只判"角度 + 距离",不做视线遮挡(遮挡由调用方 find_path 可达性承担)
        - 和目标重合(距离 0)视为在视野内
    """
    dx = other_entity.x - finder_entity.x
    dy = other_entity.y - finder_entity.y
    dist_sq = dx * dx + dy * dy
    # 距离过滤:超出视野半径直接不在视锥内
    if dist_sq > vision.radius * vision.radius:
        return False
    if dist_sq == 0:
        # 和目标重合,必在视野内
        return True
    # 角度过滤:目标方向与朝向的夹角(归一到 [-π, π]),须落在半角范围内
    to_target = collision.Vector2(dx, dy)
    facing_vec = collision.Vector2(math.cos(finder_entity.facing), math.sin(finder_entity.facing))
    angle_diff = to_target.angle(facing_vec)
    return abs(angle_diff) <= vision.half_angle


def get_ai_machine(room: "GameRoom", entity_id: str) -> "Optional[enemy_ai_machine.EnemyAIMachine]":
    """取单个敌人的 AI 状态机"""
    return room.get_enemy_manager().get_ai_machine(entity_id)

def change_ai_state(room: "GameRoom", entity_id: str, state: str, target_entity_id: str = None):
    """改变单个敌人的 AI 状态"""
    ai_machine = get_ai_machine(room, entity_id)
    if ai_machine:
        ai_machine.change_state(state, target_entity_id)

def get_facing_by_vector2(vec: tuple[float, float] | list[float, float], zero: tuple[float, float] | list[float, float] = (1, 0)) -> float:
    """把向量转化为弧度方向(向右为0),归一化到 [0, 2π),与 apply_facing 的存储区间一致"""
    import game.collision as collision
    angle = collision.Vector2(*vec).angle(collision.Vector2(*zero))
    return angle % (2 * math.pi)

def find_path(room: "GameRoom", start_pos: tuple[float, float], end_pos: tuple[float, float], search_radius: float = 500) -> Optional[list[tuple[float, float]]]:
    """
    A* 寻路:返回从 start_pos 到 end_pos 的像素坐标路径点列表。

    内部转调 GameRoom 持有的 Pathfinder(由 GameServer 注入),基于双端一致的
    ChunkGenerator 判断 tile 可通行性。返回值语义:
        None  :找不到路径(超出搜索半径 / 起点或终点在墙里 / 被墙完全包围)
        []    :起点和终点在同一 tile(已到达,调用方应直接进攻击距离判定)
        [p1, p2, ...]:路径点列表(像素坐标,不含起点,含终点)

    未注入 Pathfinder 时(room.get_pathfinder() is None)降级为直线追击:
    返回 [end_pos],让敌人直接朝目标走(兼容旧逻辑,不阻断 AI)。
    """
    pf = room.get_pathfinder()
    if pf is None:
        # 寻路器未注入:降级为直线追击(不绕障,但 AI 不会卡死)
        return [end_pos]
    return pf.find_path(start_pos, end_pos, search_radius)
