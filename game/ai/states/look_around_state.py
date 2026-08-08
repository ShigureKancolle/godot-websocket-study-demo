# coding=utf-8
# 攻击状态

import game.ai.ai_state_base as ai_state_base
class LookAroundState(ai_state_base.AIStateBase):
    def enter(self, target_entity_id: str = None):
        print(f"{self.entity_id} enters look around state {target_entity_id}")

    def exit(self):
        print(f"{self.entity_id} exits look around state")

    def update(self, dt: float):
        print(f"{self.entity_id} is looking around player {dt}")

