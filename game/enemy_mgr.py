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
import config.config_loader as config_loader
import typing
if typing.TYPE_CHECKING:
    from game.game_room import GameRoom, EntityInfo


# 敌人 AI 激活距离:附近没有玩家(任意方向)在 AI_ACTIVATE_DISTANCE 内时,
# 敌人不执行 AI 逻辑,避免玩家还没进地图/已离开时敌人自己跑动或攻击。
AI_ACTIVATE_DISTANCE: float = float(config_loader.get_constant("AI_ACTIVATE_DISTANCE", 1500.0))


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
        # AI 状态变更回调(由 GameServer 在 __init__ 时注册,注入给每个状态机)。
        # 状态机切换状态时回调,网络层据此广播 AiStateChanged(客户端切换视锥形态)。
        self._ai_state_change_hook = None
        # A* 是全房间共享的昂贵操作；请求先入队，再由每个 tick 的预算统一消费。
        self._path_tasks = {}
        self._path_results = {}
        self._path_last_request = {}
        self._path_clock = 0.0
        self._astar_count_this_tick = 0
        self._path_result_drops = 0
        self._path_invalidations = 0

    def set_ai_state_change_hook(self, cb) -> None:
        """
        注册 AI 状态变更回调(由 GameServer 在初始化时调用)

        回调签名: cb(entity_id, new_state_name) -> None
        网络层实现为广播 AiStateChanged 消息(见 web_server._on_ai_state_changed)。

        为什么走 EnemyMgr 中转而非直接注册到每个状态机:
            状态机由 EnemyMgr 统一创建(on_enemy_created),这里注册一次,
            已存在的状态机立即注入,后续新建的由 on_enemy_created 注入——调用方不用管细节。
        """
        self._ai_state_change_hook = cb
        for machine in self._ai_machine.values():
            machine.set_ai_state_change_hook(cb)

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
        # 注入 AI 状态变更钩子(在 change_state("patrol") 之前,保证初始状态也走回调)
        if self._ai_state_change_hook is not None:
            state_machine.set_ai_state_change_hook(self._ai_state_change_hook)
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

    @property
    def path_invalidations(self) -> int:
        """累计因重定位丢弃的旧路径任务/结果数量。"""
        return self._path_invalidations

    @property
    def astar_count_this_tick(self) -> int:
        """最近一次 AI tick 实际执行的 A* 数量，供慢 tick 诊断读取。"""
        return self._astar_count_this_tick

    def mark_dirty(self, entity_id: str) -> None:
        """标记服务端主动重定位的实体，确保下一次增量广播包含新位置。"""
        self._dirty_entities.add(entity_id)

    def invalidate_paths(self, entity_id: str) -> None:
        """实体重定位后丢弃该实体所有旧 A* 任务/结果和 ChaseState 路径。"""
        if entity_id in self._path_tasks or entity_id in self._path_results:
            self._path_invalidations += 1
        self._path_tasks.pop(entity_id, None)
        self._path_results.pop(entity_id, None)
        self._path_last_request.pop(entity_id, None)
        machine = self._ai_machine.get(entity_id)
        if machine is not None:
            chase = machine.states.get("chase")
            if chase is not None:
                chase.path = None
                chase.last_check_time = chase.check_target_cooldown

    def request_path(self, entity_id: str, start, end, search_radius: float, room):
        """提交或领取一个敌人的路径结果。

        返回 ``(ready, path)``；未完成时不重复入队，ChaseState 会继续使用旧路径，
        没有旧路径则停在原地。冷却和 pending 集合共同保证同一 tick 只排一次任务。
        """
        key = (round(end[0], 1), round(end[1], 1))
        result = self._path_results.get(entity_id)
        if result is not None:
            self._path_results.pop(entity_id, None)
            return True, result[1]
        if entity_id in self._path_tasks:
            return False, None
        last = self._path_last_request.get(entity_id, -1e9)
        cooldown = float(config_loader.get_constant("ENEMY_PATH_RECALC_COOLDOWN", 0.5))
        if self._path_clock - last < cooldown:
            return False, None
        self._path_last_request[entity_id] = self._path_clock
        self._path_tasks[entity_id] = (key, start, end, search_radius)
        return False, None

    def _process_path_tasks(self, room) -> None:
        """在 AI 决策前按预算执行 A*，避免敌人数增加时单 tick 失控。"""
        budget = max(0, int(config_loader.get_constant("ENEMY_MAX_PATH_TASKS_PER_TICK", 2)))
        for entity_id in list(self._path_tasks.keys())[:budget]:
            key, start, end, radius = self._path_tasks.pop(entity_id)
            pathfinder = room.get_pathfinder()
            path = pathfinder.find_path(start, end, radius) if pathfinder is not None else None
            self._path_results[entity_id] = (key, path)
            self._astar_count_this_tick += 1

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
        self._path_clock += max(0.0, dt)
        self._astar_count_this_tick = 0
        self._process_path_tasks(room)
        # TODO: 
        # 1. 决策冷却:没到时间就跳过(节省算力,不必每帧重算)
        #
        # 
        # 预先收集玩家列表,避免每个敌人都遍历一遍全量快照
        player_entities = [e for e in room.snapshot() if e.entity_type == "player"]
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
            # returning 状态由 SurvivalRun 的牵引返程逻辑权威持有；返程期间
            # 普通战斗 AI 不得覆盖敌人的目标或移动方向。
            # returning 是 Run 的服务端专用状态：敌人仍保留原实体和属性，
            # 这里只跳过普通战斗决策，返程移动由 SurvivalRun 统一驱动。
            if entity.ai_state == "returning":
                continue
            # 只有未处于 returning 的敌人才进入普通 AI；该判断位于死亡过滤之后、
            # 激活距离判断之前，确保返程状态不会被“远离玩家停 AI”覆盖。
            # 附近没有玩家时不跑 AI:顺便停掉 AI 驱动的移动,等玩家靠近后再恢复。
            if not self._is_player_nearby(entity, player_entities, AI_ACTIVATE_DISTANCE):
                room.apply_move_dir(entity_id, 0, 0, False, dt)
                continue
            old_x, old_y = entity.x, entity.y
            old_facing = entity.facing
            machine.update(dt, room)
            new_entity = room.get_entity(entity_id)
            if new_entity is None:
                continue
            if (old_x, old_y) != (new_entity.x, new_entity.y) or old_facing != new_entity.facing:
                self._dirty_entities.add(entity_id)

    def _is_player_nearby(self, enemy: "EntityInfo", players: list, distance: float) -> bool:
        """检查 enemy 附近 distance 像素内是否存在玩家(纯距离判定,不看朝向/视野)"""
        if not players:
            return False
        for player in players:
            dx = player.x - enemy.x
            dy = player.y - enemy.y
            if dx * dx + dy * dy <= distance * distance:
                return True
        return False

    def clear(self) -> None:
        """清空所有敌人 AI 状态(房间重置/销毁时用)"""
        self._ai_machine.clear()
        self._path_tasks.clear()
        self._path_results.clear()
        self._path_last_request.clear()

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
