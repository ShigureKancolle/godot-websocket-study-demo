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

    def update(self, dt: float, room: game_room.GameRoom):
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
        if (target_pos[0] - entity_pos[0]) ** 2 + (target_pos[1] - entity_pos[1]) ** 2 < attack_distance ** 2:
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

        my_pos = (my_entity.x, my_entity.y)
        target_pos = (target_entity.x, target_entity.y)
        return ai_state_helper.find_path(room, my_pos, target_pos)
