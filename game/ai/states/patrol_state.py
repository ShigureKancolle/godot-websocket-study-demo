# coding=utf-8
# patrolling状态

import math
import random
import config.config_loader as config_loader
import game.ai.ai_state_base as ai_state_base
import game.game_room as game_room
import game.helper.ai_state_helper as ai_state_helper
class PatrolState(ai_state_base.AIStateBase):
    def __init__(self, entity_id: str):
        super().__init__(entity_id)
        self.init_x = 0
        self.init_y = 0
        self.cur_target_x = 0
        self.cur_target_y = 0

    def init_state(self, room: game_room.GameRoom):
        entity = room.get_entity(self.entity_id)
        if entity:
            self.init_x = entity.x
            self.init_y = entity.y

    def init_enter(self, room: game_room.GameRoom):
        self.cur_target_x, self.cur_target_y = self._get_random_patrol_pos()
        entity = room.get_entity(self.entity_id)
        if not entity:
            return
        # 朝向要和移动方向一致:方向从「当前位置」指向目标点,而不是出生点
        dir_x = self.cur_target_x - entity.x
        dir_y = self.cur_target_y - entity.y
        facing = ai_state_helper.get_facing_by_vector2((dir_x, dir_y))
        room.apply_facing(self.entity_id, facing)

    def enter(self, target_entity_id: str = None):
        print(f"{self.entity_id} enters patrol state")
        self.cur_target_x, self.cur_target_y = self._get_random_patrol_pos()

    def pre_exit(self):
        print(f"{self.entity_id} exits patrol state")
        self.cur_target_x, self.cur_target_y = self.init_x, self.init_y  # 重置到出生位置

    def update_state(self, dt: float, room: game_room.GameRoom):
        # print(f"{self.entity_id} is patrolling {dt}")
        target_entity_id = self._find_player_in_sight(room)
        if target_entity_id:
            dir_x = room.get_entity(target_entity_id).x - room.get_entity(self.entity_id).x
            dir_y = room.get_entity(target_entity_id).y - room.get_entity(self.entity_id).y
            facing = ai_state_helper.get_facing_by_vector2((dir_x, dir_y))
            room.apply_facing(self.entity_id, facing)
            ai_state_helper.change_ai_state(room, self.entity_id, "chase", target_entity_id)
        else:
            # 在出生点附近随机移动           
            cur_x, cur_y = room.get_entity(self.entity_id).x, room.get_entity(self.entity_id).y
            target_x, target_y = self.cur_target_x, self.cur_target_y
            if (cur_x - target_x) ** 2 + (cur_y - target_y) ** 2 < 10 ** 2:
                # 到达目标点后重新选择一个随机点
                self.cur_target_x, self.cur_target_y = self._get_random_patrol_pos()
                # ai_state_helper.change_ai_state(room, self.entity_id, "look_around", target_entity_id)
                return
            
            dir_x = self.cur_target_x - cur_x
            dir_y = self.cur_target_y - cur_y
            # 移动过程中朝向始终跟着移动方向,避免出生点朝向和实际走向不一致
            facing = ai_state_helper.get_facing_by_vector2((dir_x, dir_y))
            cur_facing = room.get_entity(self.entity_id).facing
            # facing 是 [-π, π],而 apply_facing 里把朝向存成了 [0, 2π),
            # 直接相减会在 ±π 附近得到接近 2π 的假差值。先归一到最短角差再判断。
            angle_diff = (facing - cur_facing + math.pi) % (2 * math.pi) - math.pi
            if abs(angle_diff) > 0.1:
                fact_speed = room.get_combat(self.entity_id).look_around_fact_speed
                # 用最短角差的符号决定转向,等价于原叉乘判断,但不受 wrap 影响
                turn_dir = 1 if angle_diff > 0 else -1
                step = fact_speed * dt * turn_dir
                # 防止一步跨过目标角导致来回震荡
                if abs(step) > abs(angle_diff):
                    next_facing = facing
                else:
                    next_facing = cur_facing + step
                room.apply_facing(self.entity_id, next_facing)
                room.apply_move_dir(self.entity_id, 0, 0, False, dt)
            else:
                room.apply_facing(self.entity_id, facing)
                room.apply_move_dir(self.entity_id, dir_x, dir_y, True, dt)
            

    def _find_player_in_sight(self, room: game_room.GameRoom):
        """查找最近的玩家"""
        chase_vision = config_loader.get_vision("normal")
        player_id = ai_state_helper.find_nearest_entity_in_sight(room, self.entity_id, "player", search_radius=chase_vision.radius)
        return player_id

    def _get_random_patrol_pos(self):
        """获取随机巡逻目的地"""
        random_offset_x = random.uniform(-200, 200)
        random_offset_y = random.uniform(-200, 200)

        return self.init_x + random_offset_x, self.init_y + random_offset_y