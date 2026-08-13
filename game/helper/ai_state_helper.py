# coding=utf-8
# AI 状态帮助类
from typing import TYPE_CHECKING, Optional
if TYPE_CHECKING:
    from game.game_room import GameRoom, EntityInfo
    from game.enemy_mgr import enemy_ai_machine

def find_nearest_entity_in_sight(room: "GameRoom", entity_id: str, entity_type: str = ""):
    """
    查找最近的敌人或玩家    
    """
    finder_entity = room.get_entity(entity_id)
    if not finder_entity:
        return ""

    entities: list[EntityInfo] = room.snapshot()
    nearest_entity_id = ""
    nearest_distance = None
    for idx, other_entity in enumerate(entities):
        if other_entity.entity_id == entity_id:
            continue
        if entity_type and other_entity.entity_type != entity_type:
            continue
        # 计算距离
        dx = other_entity.x - finder_entity.x
        dy = other_entity.y - finder_entity.y
        distance = (dx ** 2 + dy ** 2) ** 0.5
        if nearest_entity_id == "" or distance < nearest_distance:
            # 判断是否在视野中
            

            # 达不到的路径不算找到了
            move_path = find_path(room, (finder_entity.x, finder_entity.y), (other_entity.x, other_entity.y))
            if move_path is None:
                continue
            nearest_entity_id = other_entity.entity_id
            nearest_distance = distance

            # TODO 这里可以加上视野判断,比如角度范围、障碍物遮挡等
            
    return nearest_entity_id


def get_ai_machine(room: "GameRoom", entity_id: str) -> "Optional[enemy_ai_machine.EnemyAIMachine]":
    """取单个敌人的 AI 状态机"""
    return room.get_enemy_manager().get_ai_machine(entity_id)

def change_ai_state(room: "GameRoom", entity_id: str, state: str, target_entity_id: str = None):
    """改变单个敌人的 AI 状态"""
    ai_machine = get_ai_machine(room, entity_id)
    if ai_machine:
        ai_machine.change_state(state, target_entity_id)

def get_facing_by_vector2(vec: tuple[float, float] | list[float, float], zero: tuple[float, float] | list[float, float] = (1, 0)) -> int:
    """把向量转化为弧度方向（向右为0）"""
    import game.collision as collision
    return collision.Vector2(*vec).angle(collision.Vector2(*zero))

def find_path(room: "GameRoom", start_pos: tuple[float, float], end_pos: tuple[float, float]) -> Optional[list[tuple[float, float]]]:
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
    return pf.find_path(start_pos, end_pos)
