# coding=utf-8
# 攻击状态

import game.ai.ai_state_base as ai_state_base
import game.helper.ai_state_helper as ai_state_helper
import typing
import config.config_loader as config_loader
from typing import TYPE_CHECKING, Optional
if TYPE_CHECKING:
    from game.game_room import GameRoom
    from game.game_room import EntityInfo
    from game.ai.enemy_ai_machine import EnemyAIMachine

atk_id = 1001
class AttackState(ai_state_base.AIStateBase):
    def enter(self, target_entity_id: str = None):
        print(f"{self.entity_id} enters attack state {target_entity_id}")
        self.target_entity_id = target_entity_id
        self.attack_time = 0 # 攻击占用的时间 这段时间不能移动也不能转向
        self.attack_after_time = 0 # 发起攻击后经过的时间 要达到attack_time之后才能离开状态


    def exit(self):
        print(f"{self.entity_id} exits attack state")

    def update_state(self, dt: float, room: "GameRoom"):
        self.attack_after_time += dt
        if self.attack_after_time < self.attack_time:
            return
        entity = room.get_entity(self.entity_id)
        if entity is None:
            return

        # 上一次攻击的 AttackTimer 还没结束(state 还是 attacking):等下个 tick 再试。
        # 不手动调 apply_attack_end——攻击结束由 timer 的 end_cb 自动处理,
        # 手动 end 会和 end_cb 冲突(重复广播 AttackEnd + 提前清状态导致连击节奏错乱)
        if entity.state == "attacking":
            return

        self.attack_after_time = 0 # 重置攻击后时间

        # 先看看要不要继续攻击
        self_entity = room.get_entity(self.entity_id)
        target_entity = room.get_entity(self.target_entity_id)
        if target_entity is None:
            ai_state_helper.change_ai_state(room, self.entity_id, "patrol", self.target_entity_id)
            return

        # 看看距离
        if (self_entity.x - target_entity.x) ** 2 + (self_entity.y - target_entity.y) ** 2 > 100 ** 2:
            ai_state_helper.change_ai_state(room, self.entity_id, "chase", self.target_entity_id)
            return
    
        print(f"{self.entity_id} is attacking {dt}")
        # 调 trigger_attack 发动完整攻击流程(状态变更+广播+判定帧定时器+命中扣血),
        # 而非 apply_attack_start(那只改状态,不广播也不判定,敌人攻击会"空挥")
        # 停止移动
        room.apply_move_dir(self.entity_id, 0, 0, False, dt)
        next_facing = ai_state_helper.get_facing_by_vector2((target_entity.x - entity.x, target_entity.y - entity.y))
        room.apply_facing(self.entity_id, next_facing)
        room.trigger_attack(self.entity_id, atk_id)
        # self.attack_time = config_loader.get_attack_config(atk_id).get_attack_time() / 1000.0 # 转换为秒
        


