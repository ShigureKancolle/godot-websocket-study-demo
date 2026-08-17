# coding=utf-8

'''
整合一局游戏的所有实例， 管控游戏的整个生命周期
'''
import game.game_room as game_room
import game.enemy_mgr as enemy_mgr

class GameManager:
    _game_rooms: list[game_room.GameRoom]
    _enemy_mgrs: list[enemy_mgr.EnemyMgr]

    def __init__(self):
        self.clear()

    def clear(self):
        self._game_rooms = []
        self._enemy_mgrs = []

    def init_game(self):
        pass

    def start_game(self):
        pass

    def end_game(self):
        pass

