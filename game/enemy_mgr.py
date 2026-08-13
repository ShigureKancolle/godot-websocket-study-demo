# coding=utf-8
"""
文件: server/game/enemy_mgr.py
作用: 敌人 AI 管理器(承载敌人专属逻辑,不重复存 EntityInfo)

============================================================================
 为什么需要 EnemyMgr(不直接用 GameRoom._entities)
============================================================================
GameRoom._entities 是「所有实体的统一状态表」(玩家/木桩/敌人/...),
它存的是「状态快照」:位置/朝向/动画状态/血量——这些是「渲染+判定」要用的。

但敌人还需要「AI 专属状态」,这些状态:
    - 不该塞进 EntityInfo(那是所有类型共用的结构,加敌人专属字段会污染)
    - 不该塞进 CombatComponent(那是战斗数值,和 AI 决策是两件事)
    - 客户端不需要知道(AI 是服务端逻辑,不用同步)

所以单独用 EnemyMgr 存一份「敌人 AI 状态」,以 entity_id 为 key 关联到 _entities。

============================================================================
 职责边界
============================================================================
EnemyMgr 只管「敌人特有」的事:
    - AI 状态机(巡逻/追击/攻击/逃跑...)
    - 寻路(目标点、路径、当前路径点索引)
    - 仇恨表(谁打了我、我追谁)
    - AI tick(每帧/定时决策)

不管「所有实体共有」的事(位置/血量/朝向/碰撞),那些都在 GameRoom._entities。
EnemyMgr.update 通过 entity_id 去 GameRoom 取这些共有状态来读,改状态也通过
GameRoom 的 apply_xxx 方法改——和客户端一样「不直接写 _entities」。

============================================================================
 与 GameRoom 的协作
============================================================================
    GameRoom.create_enemy(type, pos)
        ├─ GameRoom.add_entity(entity_id, EntityInfo)   # 共有状态入 _entities
        ├─ GameRoom.add_combat(...)                     # 战斗数值入 _combats(由 add_entity 自动)
        └─ EnemyMgr.on_enemy_created(entity_id, type)   # AI 状态入 _ai_states

    GameRoom.remove_entity(entity_id)
        ├─ _entities.pop(...)
        ├─ _combats.pop(...)
        └─ EnemyMgr.on_enemy_removed(entity_id)         # AI 状态清理

    GameServer._process_tick(dt)
        └─ EnemyMgr.update(dt, room)                    # 每帧驱动 AI
               └─ 内部:读 room.get_entity() 取位置 → 决策 → 调 room.apply_move_dir/apply_attack
============================================================================
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple
import game.ai.ai_state_base as ai_state_base
import game.ai.enemy_ai_machine as enemy_ai_machine
import typing
if typing.TYPE_CHECKING:
    from game.game_room import GameRoom, EntityInfo


# @dataclass
# class EnemyAIState:
#     """
#     单个敌人的 AI 状态(挂在 EnemyMgr 上,不进 EntityInfo)

#     字段语义:
#         entity_id:     对应 GameRoom._entities 里的 key,关联到共有状态
#         ai_state:      AI 状态机当前态(idle/patrol/chase/attack/flee...)
#                         先用字符串占位,后续要细化再拆成 enum + 状态机类
#         target_id:     当前追击/攻击目标的 entity_id(玩家或 null)
#         path:          寻路结果(路径点列表,空表示无路径/已到达)
#         path_index:    当前走到的路径点索引
#         rethink_timer: AI 决策冷却(秒),到 0 才重新决策,避免每帧重算寻路

#     注:这里只存「AI 决策需要且 EntityInfo 没有的」状态。
#     位置/血量/朝向这些「共有状态」永远从 GameRoom 取,不在这里存第二份——
#     避免双端数据不一致(单数据源原则)。
#     """
#     entity_id: str
#     ai_state: str = "idle"
#     target_id: Optional[str] = None
#     path: List[Tuple[float, float]] = field(default_factory=list)
#     path_index: int = 0
#     rethink_timer: float = 0.0


class EnemyMgr:
    """
    敌人 AI 管理器(由 GameRoom 持有,不是单例)

    为什么由 GameRoom 持有而非全局单例:
        和 _entities / _combats 一样,敌人 AI 状态是「房间内状态」,
        未来支持多房间时,每个 GameRoom 实例应有自己的 EnemyMgr。
        (项目记忆里 TimerManager 也是同样决策:由 GameServer/GameRoom 持有,不挂单例)
    """

    def __init__(self):
        # entity_id -> EnemyAIState
        # 用 Dict 而非 List:O(1) 按 entity_id 查 AI 状态(AI tick 频繁查)
        self._ai_machine: Dict[str, enemy_ai_machine.EnemyAIMachine] = {}
        self._dirty_entities: set[str] = set()

    # ------------------------------------------------------------------
    # 生命周期回调(由 GameRoom.create_enemy / remove_entity 调用)
    # ------------------------------------------------------------------

    def on_enemy_created(self, entity_id: str, entity_type: str) -> enemy_ai_machine.EnemyAIMachine:
        """
        敌人创建回调:在 GameRoom.add_entity 之后调用,挂上 AI 状态

        Args:
            entity_id: 敌人 entity_id(GameRoom 已分配好)
            entity_type: 敌人类型(未来不同类型可用不同 AI 策略,这里先记下)

        Returns:
            创建的 EnemyAIState(调用方一般不需要,留着便于调试)
        """
        if entity_id in self._ai_machine:
            # 重复创建通常是 bug,早暴露
            raise ValueError(f"敌人 AI 状态已存在: {entity_id}")
        state_machine = enemy_ai_machine.EnemyAIMachine(entity_id=entity_id)
        # state_machine.add_state("idle", ai_state_base.IDLEState())
        self.add_enemy_ai_state(state_machine)
        state_machine.change_state("patrol")  # 默认巡逻,后续可按类型改
        # entity_type 暂未使用,预留:后续可按类型选 AI 策略
        # (如 enemy_slime 用近战追击、enemy_ranged 用风筝射击)
        self._ai_machine[entity_id] = state_machine
        return state_machine

    def on_enemy_removed(self, entity_id: str) -> Optional[enemy_ai_machine.EnemyAIMachine]:
        """
        敌人移除回调:在 GameRoom.remove_entity 里调用,清理 AI 状态

        幂等:不存在时不报错(和 GameRoom.remove_entity 的容错策略一致)。
        """
        return self._ai_machine.pop(entity_id, None)

    # ------------------------------------------------------------------
    # 查询
    # ------------------------------------------------------------------

    def get_ai_machine(self, entity_id: str) -> Optional[enemy_ai_machine.EnemyAIMachine]:
        """取单个敌人的 AI 状态机"""
        return self._ai_machine.get(entity_id)

    def is_enemy(self, entity_id: str) -> bool:
        """快速判断某个 entity_id 是不是敌人(AI tick 时过滤用)"""
        return entity_id in self._ai_machine

    def get_all_enemy_ids(self) -> List[str]:
        """所有敌人的 entity_id 列表(快照,迭代期间安全)"""
        return list(self._ai_machine.keys())

    def get_enemy_count(self) -> int:
        return len(self._ai_machine)

    # ------------------------------------------------------------------
    # AI 主循环(由 GameServer._process_tick 每帧调用)
    # ------------------------------------------------------------------

    def update(self, dt: float, room: "GameRoom") -> None:
        """
        AI 主循环:每帧推进所有敌人的 AI 决策与寻路

        参数:
            dt:   距上一帧的秒数(用于 rethink_timer 递减、移动插值)
            room: GameRoom 实例,用于读实体共有状态 + 调 apply_xxx 改状态

        当前实现:空壳(下一步实现寻路时填充)
        预期流程:
            for entity_id, state in self._ai_states.items():
                # 1. 决策冷却:没到时间就跳过(节省算力,不必每帧重算)
                state.rethink_timer -= dt
                if state.rethink_timer > 0:
                    self._follow_path(entity_id, state, room)
                    continue

                # 2. 重新决策:选目标 → 算路径 → 设 state
                state.target_id = self._pick_target(entity_id, room)
                state.path = self._compute_path(entity_id, state.target_id, room)
                state.path_index = 0
                state.rethink_timer = 0.5   # 0.5 秒重算一次

                # 3. 沿路径走一步
                self._follow_path(entity_id, state, room)
        """
        # TODO: 
        # 1. 决策冷却:没到时间就跳过(节省算力,不必每帧重算)
        #
        # 
        for entity_id, machine in self._ai_machine.items():
            entity = room.get_entity(entity_id)
            if entity is None:
                continue
            # 死亡后立即冻结 AI:实体 state=="dead" 到 DeadTimer 到期被 remove_entity
            # 清理 AI 之间,实体仍挂在 _entities/_ai_machine 里。若不跳过,AI 状态机
            # (chase/attack/patrol)在死亡动画期间仍每 tick 执行决策+打日志。
            # apply_xxx 虽会被 _is_input_locked 拒绝,但决策逻辑与日志不该再跑。
            if entity.state == "dead":
                continue
            old_x, old_y = entity.x, entity.y
            old_facing = entity.facing
            machine.update(dt, room)
            new_entity = room.get_entity(entity_id)
            if new_entity is None:
                continue
            if (old_x, old_y) != (new_entity.x, new_entity.y) or old_facing != new_entity.facing:
                self._dirty_entities.add(entity_id)

    def clear(self) -> None:
        """清空所有敌人 AI 状态(房间重置/销毁时用)"""
        self._ai_machine.clear()

    def pop_dirty_entities(self) -> set[str]:
        """取脏实体列表并清空(供 GameRoom._process_tick 用)"""
        dirty = self._dirty_entities
        self._dirty_entities = set()
        return dirty

    def add_enemy_ai_state(self, state_machine: enemy_ai_machine.EnemyAIMachine) -> None:
        """添加敌人 AI 状态机(由 on_enemy_created 调用)"""
        import game.ai.states.patrol_state as patrol_state
        import game.ai.states.chase_state as chase_state
        import game.ai.states.attack_state as attack_state
        import game.ai.states.look_around_state as look_around_state
        state_machine.add_state("patrol", patrol_state.PatrolState(state_machine.entity_id))
        state_machine.add_state("chase", chase_state.ChaseState(state_machine.entity_id))
        state_machine.add_state("attack", attack_state.AttackState(state_machine.entity_id))
        state_machine.add_state("look_around", look_around_state.LookAroundState(state_machine.entity_id))
