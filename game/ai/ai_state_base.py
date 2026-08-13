# coding=utf-8
import game.game_room as game_room
class AIStateBase:
    def __init__(self, entity_id: str):
        self.is_init = False
        self.enter_init = False
        self.entity_id = entity_id
        self.state_name = self.__class__.__name__.replace("State", "").lower()
        
    def get_state_name(self):
        return self.state_name
        
    def enter(self, target_entity_id: str = None):
        pass

    def exit(self):
        self.pre_exit()
        self.enter_init = False

    def update(self, dt: float, room: game_room.GameRoom):
        if not self.is_init:
            self.is_init = True
            self.init_state(room)

        if not self.enter_init:
            self.enter_init = True
            self.init_enter(room)

        self.update_state(dt, room)

    def init_state(self, room: game_room.GameRoom):
        """初始化状态"""
        pass

    def update_state(self, dt: float, room: game_room.GameRoom):
        pass

    def init_enter(self, room: game_room.GameRoom):
        """进入状态时的初始化操作"""
        pass

    def pre_exit(self):
        """退出状态前的操作"""
        pass