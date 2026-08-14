# coding=utf-8
import game.ai.ai_state_base as ai_state_base
from typing import Callable, Optional

# 一些配置参数 之后移到json里
attack_distance = 30.0  # 攻击距离阈值

class EnemyAIMachine:
    def __init__(self, entity_id: str):
        self.entity_id = entity_id
        self.target_entity_id = None  # 追击目标的 entity_id, 可能为 None
        self.current_state = None
        self.states: dict[str, ai_state_base.AIStateBase] = {}
        # AI 状态变更回调(由 EnemyMgr 统一注册,GameServer 在 __init__ 时设置)。
        # 为什么用钩子(而不让状态机直接广播):状态机是纯 AI 决策层,不知道网络层存在。
        # 和 GameRoom._attack_trigger / _entity_spawn_hook 同一模式——网络层把"广播
        # AiStateChanged"作为回调注册进来,状态机对调用方透明。
        # 签名: cb(entity_id, new_state_name)
        self._ai_state_change_hook: Optional[Callable[[str, str], None]] = None

    def add_state(self, state_name: str, state: ai_state_base.AIStateBase):
        self.states[state_name] = state

    def set_ai_state_change_hook(self, cb: Callable[[str, str], None]) -> None:
        """注册 AI 状态变更回调(由 EnemyMgr 在创建状态机时注入)"""
        self._ai_state_change_hook = cb

    def change_state(self, state_name: str, target_entity_id: str = None):
        old_state_name = self.current_state.get_state_name() if self.current_state else None
        if self.current_state:
            self.current_state.exit()
        self.current_state = self.states.get(state_name)
        if self.current_state:
            self.current_state.enter(target_entity_id)

        # 状态真正切换(old != new)才触发回调,避免重复广播:
        #   - old == new:重复进入(重入),不算切换,不广播
        #   - old == None → 首个状态(如创建时 patrol):是初始状态,广播也无妨
        #     (客户端此时可能还没有该实体,StateMirror 会忽略,等全量快照带初始 ai_state)
        if self._ai_state_change_hook is not None and old_state_name != state_name:
            self._ai_state_change_hook(self.entity_id, state_name)

    def update(self, dt: float, room):
        if self.current_state:
            self.current_state.update(dt, room)


       