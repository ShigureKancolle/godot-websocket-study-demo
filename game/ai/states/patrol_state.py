# coding=utf-8
# patrolling状态

import game.ai.ai_state_base as ai_state_base
import game.game_room as game_room
import game.helper.ai_state_helper as ai_state_helper
class PatrolState(ai_state_base.AIStateBase):
    def enter(self, target_entity_id: str = None):
        print(f"{self.entity_id} enters patrol state")

    def exit(self):
        print(f"{self.entity_id} exits patrol state")

    def update(self, dt: float, room: game_room.GameRoom):
        # print(f"{self.entity_id} is patrolling {dt}")
        target_entity_id = self._find_player_in_sight(room)
        if target_entity_id:
            ai_state_helper.change_ai_state(room, self.entity_id, "chase", target_entity_id)
        else:
            # 停在原地先
            room.apply_move_dir(self.entity_id, 0, 0, False, dt)
        

    def _find_player_in_sight(self, room: game_room.GameRoom):
        """查找最近的玩家"""
        player_id = ai_state_helper.find_nearest_entity_in_sight(room, self.entity_id, "player")
        return player_id
