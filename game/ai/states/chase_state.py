# coding=utf-8
# 追逐状态

attack_distance = 30.0  # 攻击距离阈值
import game.ai.ai_state_base as ai_state_base
import game.game_room as game_room
import game.helper.ai_state_helper as ai_state_helper
import config.config_loader as config_loader
import typing
if typing.TYPE_CHECKING:
    from game.game_room import EntityInfo

max_chase_distance = 1000.0  # 最大追击距离,超过这个距离就放弃追击


def _get_circle_radius(entity_type: str) -> float:
    """取实体类型的圆形碰撞半径(非圆形/未配置返回 0)。
    攻击距离判定用:圆心距离阈值 = attack_distance + 双方半径之和,
    这样体型大的敌人边缘刚接触玩家就转攻击态,视觉合理。"""
    cap = config_loader.get_capability(entity_type)
    if cap.body_shape == config_loader.ShapeType.CIRCLE and isinstance(cap.body_params, config_loader.CircleParams):
        return cap.body_params.radius
    return 0.0


class ChaseState(ai_state_base.AIStateBase):
    def __init__(self, entity_id: str):
        super().__init__(entity_id)
        self.target_entity_id = None  # 追击目标的 entity_id, 可能为 None
        self.check_target_cooldown = 0.5  # 检查目标的冷却时间(秒)
        self.last_check_time = 0.0  # 上次检查目标的时间(秒)
        self.path = None  # 移动路径, 可能为 None
        
    def enter(self, target_entity_id: str = None):
        self.target_entity_id = target_entity_id
        self.last_check_time = self.check_target_cooldown
        print(f"{self.entity_id} enters chase state {target_entity_id}")

    def exit(self):
        print(f"{self.entity_id} exits chase state")

    def update_state(self, dt: float, room: game_room.GameRoom):
        # print(f"{self.entity_id} is chasing {dt}")
        if self.target_entity_id is None or room.get_entity(self.target_entity_id) is None:
            # 这种情况可能发生在玩家死亡或离开房间时, 需要切换回巡逻状态
            ai_state_helper.change_ai_state(room, self.entity_id, "patrol")
            return

        # 每隔一段时间重新算路径(目标会移动,路径要跟着更新)
        if self.check_target(dt, room):
            self.last_check_time = 0.0
            self.path = self.find_move_path(room.get_entity(self.entity_id), room.get_entity(self.target_entity_id), room)

        # path 语义:
        #   None  :找不到路径(超距离 / 起终点在墙里 / 被墙包围)→ 切回巡逻
        #   []    :起点和终点在同一 tile(已到达)→ 落到下面的攻击距离判定
        #   [p1..]:正常路径,沿路径点走
        if self.path is None:
            ai_state_helper.change_ai_state(room, self.entity_id, "patrol")
            return

        entity_pos = (room.get_entity(self.entity_id).x, room.get_entity(self.entity_id).y)
        target_pos = (room.get_entity(self.target_entity_id).x, room.get_entity(self.target_entity_id).y)
        # 攻击距离判定:圆心距离 < attack_distance + 目标半径
        # 为什么加目标半径:攻击命中判定是"攻击形状(扇形/圆)从攻击者圆心发出,扫到目标 body 圆"。
        #   目标 body 边缘进入攻击范围就能被打到,所以目标越近越容易打中,加目标半径让"刚够得着"
        #   的临界提前到目标边缘接触攻击范围时(而非目标圆心进入攻击范围时)。
        # 为什么不加攻击者半径:攻击从圆心发出,攻击者体积不参与命中判定。
        #   若加攻击者半径,会出现"动画显示够得着但实际判定够不着"的偏差(动画范围和实际范围错位)。
        # 例:enemy(20) 攻击 player(24),attack_distance=30 → 阈值 = 30+24 = 54px
        target_radius = _get_circle_radius(room.get_entity(self.target_entity_id).entity_type)
        attack_threshold = attack_distance + target_radius
        if (target_pos[0] - entity_pos[0]) ** 2 + (target_pos[1] - entity_pos[1]) ** 2 < attack_threshold ** 2:
            # 到达攻击距离
            ai_state_helper.change_ai_state(room, self.entity_id, "attack", self.target_entity_id)
            return

        # 弹掉已经走到的路径点(防止敌人卡在 path[0] 附近来回抖动)
        # 到达判定阈值用 speed*dt:本帧能走的距离,小于这个就是「已到达」
        entity = room.get_entity(self.entity_id)
        speed = config_loader.get_speed(entity.entity_type)
        arrive_threshold = max(speed * dt, 1.0)
        while self.path:
            wp = self.path[0]
            dx = wp[0] - entity_pos[0]
            dy = wp[1] - entity_pos[1]
            if dx * dx + dy * dy > arrive_threshold * arrive_threshold:
                break
            self.path.pop(0)

        if not self.path:
            # 路径走完了但还没进攻击距离(可能在等下一次 check_target 重算)
            # 不切巡逻,原地等下一帧重新算路径
            return

        # 朝向始终对着下一个路径点(不是最终目标,这样绕墙时朝向跟路径走)
        next_pos = self.get_next_frame_pos(dt, room)
        next_facing = ai_state_helper.get_facing_by_vector2((next_pos[0] - entity_pos[0], next_pos[1] - entity_pos[1]))
        # 服务端权威移动:用方向推进,不用目标坐标
        # 方向 = 下一帧位置 - 当前位置(归一化由 apply_move_dir 内部处理)
        dir_x = next_pos[0] - entity_pos[0]
        dir_y = next_pos[1] - entity_pos[1]
        room.apply_move_dir(self.entity_id, dir_x, dir_y, True, dt)
        room.apply_facing(self.entity_id, next_facing)


    def get_next_frame_pos(self, dt: float, room: game_room.GameRoom) -> tuple[float, float]:
        """获取下一帧的位置(沿 path[0] 方向走一步)"""
        entity = room.get_entity(self.entity_id)
        if not self.path:
            # path 为空(已到达或还没算出路径):原地不动
            return (entity.x, entity.y)
        entity_pos = (entity.x, entity.y)
        speed = config_loader.get_speed(entity.entity_type)
        target_pos = self.path[0]
        distance = ((target_pos[0] - entity_pos[0]) ** 2 + (target_pos[1] - entity_pos[1]) ** 2) ** 0.5
        if distance < 0.1:
            return entity_pos

        step = min(speed * dt, distance)
        dx = target_pos[0] - entity_pos[0]
        dy = target_pos[1] - entity_pos[1]
        return (entity.x + dx / distance * step, entity.y + dy / distance * step)

    def check_target(self, dt: float, room: game_room.GameRoom) -> bool:
        """是否需要检查目标"""
        self.last_check_time += dt
        if self.last_check_time >= self.check_target_cooldown:
            if self.target_entity_id and room.get_entity(self.target_entity_id):
                return True
        return False

    def find_move_path(self, my_entity: "EntityInfo", target_entity: "EntityInfo", room: game_room.GameRoom):
        """
        查找移动路径(委托 ai_state_helper.find_path → Pathfinder.find_path)

        返回值语义和 Pathfinder.find_path 一致:
            None:找不到路径(超 max_chase_distance / 超搜索半径 / 起终点在墙里)
            []  :起点和终点在同一 tile(已到达)
            [p1, p2, ...]:A* 路径点(像素坐标,不含起点,含终点,已做视线简化)
        """
        if my_entity is None or target_entity is None:
            return None

        # 检查距离 太远了不追了
        if (target_entity.x - my_entity.x) ** 2 + (target_entity.y - my_entity.y) ** 2 > max_chase_distance ** 2:
            return None

        # 已经离开视野范围 也不追了 进入警戒

        my_pos = (my_entity.x, my_entity.y)
        target_pos = (target_entity.x, target_entity.y)
        return ai_state_helper.find_path(room, my_pos, target_pos)
