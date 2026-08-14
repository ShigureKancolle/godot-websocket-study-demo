# coding=utf-8
# 攻击状态

import math
import game.helper.ai_state_helper as ai_state_helper
import game.ai.ai_state_base as ai_state_base
import game.game_room as game_room

fact_speed = 1.0  # 角速度 1弧度1秒
class LookAroundState(ai_state_base.AIStateBase):
    def __init__(self, entity_id: str):
        super().__init__(entity_id)
        self.left_facing = None
        self.right_facing = None

    def enter(self, target_entity_id: str = None):
        print(f"{self.entity_id} enters look around state {target_entity_id}")

    def pre_exit(self):
        print(f"{self.entity_id} exits look around state")

    def update_state(self, dt: float, room: game_room.GameRoom):
        # 张望过程中持续寻找玩家(常态视野 30°/750px),发现就切追逐
        player_id = self._find_nearest_entity_in_sight(room)
        if player_id:
            ai_state_helper.change_ai_state(room, self.entity_id, "chase", player_id)
            return

        # 朝向转转
        cur_facing = room.get_entity(self.entity_id).facing
        
        if self.left_facing is not None: 
            next_facing = (cur_facing - fact_speed * dt) % (2 * math.pi)
            room.apply_facing(self.entity_id, next_facing)
            # 这里要判断是否足够接近 并且之后是远离
            if abs(next_facing - self.left_facing) < 0.1:
                # 转到左边了,该往右边转了
                self.left_facing = None
                
           
        elif self.right_facing is not None:
            next_facing = (cur_facing + fact_speed * dt) % (2 * math.pi)
            room.apply_facing(self.entity_id, next_facing)
            if abs(next_facing - self.right_facing) < 0.1:
                # 转到右边了,该往左边转了
                self.right_facing = None
                

        elif self.left_facing is None and self.right_facing is None:
            # 左右都转完了,回到巡逻状态
            ai_state_helper.change_ai_state(room, self.entity_id, "patrol")
            
           

    def init_enter(self, room: game_room.GameRoom):
        room.apply_move_dir(self.entity_id, 0, 0, False, 0)  # 停止移动
        self.left_facing = (room.get_entity(self.entity_id).facing - math.pi / 2) % (2 * math.pi)
        self.right_facing = (room.get_entity(self.entity_id).facing + math.pi / 2) % (2 * math.pi)


    def _find_nearest_entity_in_sight(self, room: game_room.GameRoom):
        """查找朝向范围内的玩家"""
        player_id = ai_state_helper.find_nearest_entity_in_sight(room, self.entity_id, "player")
        return player_id
