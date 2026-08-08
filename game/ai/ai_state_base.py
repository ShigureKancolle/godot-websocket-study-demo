# coding=utf-8
import game.game_room as game_room
class AIStateBase:
    def __init__(self, entity_id: str):
        self.entity_id = entity_id
        self.state_name = self.__class__.__name__.replace("State", "").lower()
        
    def get_state_name(self):
        return self.state_name
        
    def enter(self, target_entity_id: str = None):
        pass

    def exit(self):
        pass

    def update(self, dt: float, room: game_room.GameRoom):
        pass