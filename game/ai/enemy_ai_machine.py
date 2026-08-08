# coding=utf-8
import game.ai.ai_state_base as ai_state_base

# 一些配置参数 之后移到json里
attack_distance = 30.0  # 攻击距离阈值

class EnemyAIMachine:
    def __init__(self, entity_id: str):
        self.entity_id = entity_id
        self.target_entity_id = None  # 追击目标的 entity_id, 可能为 None
        self.current_state = None
        self.states: dict[str, ai_state_base.AIStateBase] = {}

    def add_state(self, state_name: str, state: ai_state_base.AIStateBase):
        self.states[state_name] = state

    def change_state(self, state_name: str, target_entity_id: str = None):
        if self.current_state:
            self.current_state.exit()
        self.current_state = self.states.get(state_name)
        if self.current_state:
            self.current_state.enter(target_entity_id)

    def update(self, dt: float, room):
        if self.current_state:
            self.current_state.update(dt, room)


       