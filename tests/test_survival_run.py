# coding=utf-8
"""PLAN-20260818-004 生存敌人上限、追逐目标和重定位事件的回归测试。"""

import math
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, __import__("pathlib").Path(__file__).resolve().parents[1].as_posix())

import game.game_room as game_room
import game.survival_run as survival_run
import game.ai.states.chase_state as chase_state


def entity(eid, etype="player", x=0.0, y=0.0, **kwargs):
    return SimpleNamespace(entity_id=eid, entity_type=etype, x=x, y=y,
                           state="idle", moving=False, move_dir_x=0.0,
                           move_dir_y=0.0, facing=kwargs.get("facing", 0.0))


class SpawnRoom:
    def __init__(self, entities):
        self.entities = list(entities)
        self.created = 0

    def snapshot(self):
        return self.entities

    def create_enemy(self, entity_type, pos):
        self.created += 1
        self.entities.append(entity(f"enemy:{self.created}", entity_type, *pos))


class SurvivalRunTests(unittest.TestCase):
    def test_spawn_cap_is_active_players_times_five(self):
        room = SpawnRoom([entity("p1"), entity("p2"), entity("p3")])
        run = survival_run.SurvivalRun(room)
        run.spawn_accumulator = 100.0
        run._spawn(0.0)
        self.assertEqual(room.created, 15)

    def test_chase_path_uses_real_target_even_when_still_and_facing_changes(self):
        state = chase_state.ChaseState("enemy:1")
        mine = entity("enemy:1", "enemy_slime", 0, 0)
        target = entity("p1", x=300, y=120, facing=math.pi)
        captured = []
        room = SimpleNamespace(
            is_terrain_path_clear=lambda start, end, etype: captured.append(end) or True,
            get_enemy_manager=lambda: None,
        )
        with patch.object(chase_state.config_loader, "is_vision_enabled", return_value=False):
            first = state.find_move_path(mine, target, room)
            target.facing = 0.0
            second = state.find_move_path(mine, target, room)
        self.assertEqual(first, [(300, 120)])
        self.assertEqual(second, [(300, 120)])
        self.assertEqual(captured, [(300, 120), (300, 120)])

    def test_relocation_checks_all_players_and_walkability(self):
        # p2 放在首个向右候选点上，验证逻辑会检查所有玩家，而不是只检查追逐目标。
        players = [entity("p1", x=0, y=0), entity("p2", x=850, y=0)]
        players[0].moving = players[1].moving = True
        players[0].move_dir_x = players[1].move_dir_x = 1.0
        enemy = entity("enemy:1", "enemy_slime", x=-2500, y=0)
        room = SpawnRoom(players + [enemy])
        run = survival_run.SurvivalRun(room)
        run.room.is_position_walkable = lambda x, y, etype: True
        run.room.relocate_entity = lambda eid, x, y: (setattr(enemy, "x", x) or setattr(enemy, "y", y) or True)
        self.assertTrue(run._try_front_reschedule("enemy:1", enemy, players[0]))
        self.assertGreaterEqual(math.hypot(enemy.x - players[0].x, enemy.y - players[0].y), 850)
        self.assertGreaterEqual(math.hypot(enemy.x - players[1].x, enemy.y - players[1].y), 850)

    def test_zero_direction_never_relocates_even_if_marked_moving(self):
        player = entity("p1", x=0, y=0)
        player.moving = True
        enemy = entity("enemy:1", "enemy_slime", x=-2500, y=0)
        room = SpawnRoom([player, enemy])
        run = survival_run.SurvivalRun(room)
        self.assertFalse(run._try_front_reschedule("enemy:1", enemy, player))

    def test_attacking_enemy_never_relocates(self):
        player = entity("p1", x=0, y=0)
        player.moving = True
        player.move_dir_x = 1.0
        enemy = entity("enemy:1", "enemy_slime", x=-2500, y=0)
        enemy.state = "attacking"
        room = SpawnRoom([player, enemy])
        run = survival_run.SurvivalRun(room)
        self.assertFalse(run._try_front_reschedule("enemy:1", enemy, player))

    def test_relocation_records_are_consumed_once(self):
        room = game_room.GameRoom()
        room.is_position_walkable = lambda x, y, etype: True
        info = game_room.EntityInfo("enemy:1", "enemy_slime", x=0, y=0)
        room.add_entity(info.entity_id, info)
        self.assertTrue(room.relocate_entity("enemy:1", 900, 0))
        first = room.consume_relocations()
        second = room.consume_relocations()
        self.assertEqual(first, [{"entity_id": "enemy:1", "x": 900.0, "y": 0.0}])
        self.assertEqual(second, [])


if __name__ == "__main__":
    unittest.main()
