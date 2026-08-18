# coding=utf-8
"""生存模式 Run 的服务端状态机。

本模块只保存 Run 专属状态，GameRoom 仍是房间实体和战斗状态的唯一权威；
客户端收到的快照、经验球和奖励事件都只是这个状态的只读镜像。
"""

import math
import random
from dataclasses import dataclass, field
from typing import Dict, List, Optional

import config.config_loader as config_loader


@dataclass
class ExperienceOrb:
    """服务端经验球记录；球到达玩家前不改变其经验。

    ``owner_id`` 是首选吸附目标，目标失效时 Run 才改投最近活跃玩家；
    ``entity_id`` 在本局内唯一，坐标由服务端推进，客户端只用于表现。
    """
    entity_id: str
    owner_id: str
    value: int
    x: float
    y: float


@dataclass
class RewardChoice:
    """一次升级候选，value 只由服务端应用到 GameRoom 战斗组件。"""
    reward_id: str
    label: str
    value: float


class SurvivalRun:
    """单个房间的一局生存流程。

    Run 的生命周期从进入房间开始，到全员死亡或清理时结束。敌人仍由
    GameRoom/entity manager 持有，本类只维护目标绑定、返程集合、经验球、
    奖励队列和统计，避免形成第二套实体权威。
    """

    RETURN_DISTANCE = 1500.0
    RESUME_DISTANCE = 1200.0
    RETURN_SPEED = 220.0
    WAVE_SECONDS = 30.0
    SAFETY_XP_SECONDS = 15.0

    def __init__(self, room):
        self.room = room
        self.elapsed = 0.0
        self.wave = 0
        self.spawn_budget = 0.0
        self.spawn_accumulator = 0.0
        self.safety_xp_accumulator = 0.0
        self.active = True
        self.paused = False
        self.ended = False
        self.enemy_targets: Dict[str, Optional[str]] = {}
        self.returning: set[str] = set()
        self.orbs: Dict[str, ExperienceOrb] = {}
        self.pending_rewards: Dict[str, List[List[RewardChoice]]] = {}
        self.stats = {"kills": 0, "damage": 0}
        self._next_orb = 1

    def active_players(self) -> list:
        """返回当前仍可参与 Run 的玩家实体；死亡玩家不参与刷怪和吸附。"""
        return [e for e in self.room.snapshot()
                if e.entity_type == "player" and e.state != "dead"]

    def active_player_count(self) -> int:
        """供暂停和全员死亡判断使用，状态来源始终是 GameRoom 快照。"""
        return len(self.active_players())

    def should_pause(self) -> bool:
        """单人有待选奖励才暂停；多人即使某人有队列也继续推进全局。"""
        # 只有唯一活跃玩家且存在待选奖励时暂停整局；多人必须继续运行，
        # 这样一个人的升级选择不会冻结同房间其他玩家的战斗。
        return any(self.pending_rewards.values()) and self.active_player_count() == 1

    def update(self, dt: float) -> None:
        """推进一帧 Run。

        WebServer 在普通敌人 AI 前调用本方法，顺序为暂停判断、计时/波次、
        刷怪、牵引返程、经验球和安全经验；没有活跃玩家时封存结果。
        """
        # WebServer 在普通 AI tick 前调用这里；paused 时连刷怪、返程、球
        # 和安全经验计时都停止，保证“单人暂停”覆盖整个 Run 时钟。
        if not self.active or self.ended:
            return
        self.paused = self.should_pause()
        if self.paused:
            return
        self.elapsed += max(0.0, dt)
        self.wave = int(self.elapsed // self.WAVE_SECONDS) + 1
        self._spawn(dt)
        self._update_leashes(dt)
        self._update_orbs(dt)
        self.safety_xp_accumulator += dt
        if self.safety_xp_accumulator >= self.SAFETY_XP_SECONDS:
            self.safety_xp_accumulator -= self.SAFETY_XP_SECONDS
            for player in self.active_players():
                self.add_experience(player.entity_id, self.level(player.entity_id))
        if self.active_player_count() == 0 and any(e.entity_type == "player" for e in self.room.snapshot()):
            self.end()

    def _spawn(self, dt: float) -> None:
        """按持续预算生成敌人；生成实体交给 GameRoom，Run 不复制实体状态。"""
        players = self.active_players()
        if not players:
            return
        self.spawn_accumulator += dt * (1.0 + self.elapsed / 120.0)
        while self.spawn_accumulator >= 1.0:
            self.spawn_accumulator -= 1.0
            target = random.choice(players)
            angle = random.random() * math.tau
            radius = 850.0 + random.random() * 250.0
            self.room.create_enemy("enemy_slime", (
                target.x + math.cos(angle) * radius,
                target.y + math.sin(angle) * radius,
            ))

    def _update_leashes(self, dt: float) -> None:
        """维护目标绑定与返程状态。

        首次绑定后保持目标；超过 1500px 进入 returning，低于 1200px 才恢复
        普通追击，形成滞回。目标失效改绑最近活跃玩家，无目标时冻结。
        """
        # enemy_targets 是首次索敌后的服务端归属记录。1500/1200 两个阈值
        # 构成滞回，防止边界抖动；returning 只改变 AI 服务状态，不重建实体、
        # 不清血、不重置难度属性或统计。
        players = self.active_players()
        player_by_id = {p.entity_id: p for p in players}
        for enemy_id in list(self.room.get_enemy_manager().get_all_enemy_ids()):
            enemy = self.room.get_entity(enemy_id)
            if enemy is None or enemy.state == "dead":
                self.enemy_targets.pop(enemy_id, None)
                self.returning.discard(enemy_id)
                continue
            target_id = self.enemy_targets.get(enemy_id)
            target = player_by_id.get(target_id)
            if target is None:
                target = min(players, key=lambda p: (p.x - enemy.x) ** 2 + (p.y - enemy.y) ** 2, default=None)
                target_id = target.entity_id if target else None
                self.enemy_targets[enemy_id] = target_id
            if target is None:
                # 没有可用玩家时冻结返程实体；玩家重新活跃后下一 tick 再绑定。
                self.returning.add(enemy_id)
                enemy.ai_state = "returning"
                self.room.apply_move_dir(enemy_id, 0, 0, False, dt)
                continue
            distance = math.hypot(target.x - enemy.x, target.y - enemy.y)
            if enemy_id in self.returning:
                if distance < self.RESUME_DISTANCE:
                    self.returning.discard(enemy_id)
                    enemy.ai_state = "chase"
                else:
                    self._move_toward(enemy_id, target, dt)
            elif distance > self.RETURN_DISTANCE:
                self.returning.add(enemy_id)
                enemy.ai_state = "returning"
                self._move_toward(enemy_id, target, dt)

    def _move_toward(self, enemy_id: str, target, dt: float) -> None:
        """以固定返程速度写入 GameRoom 移动入口，不重置敌人任何运行时属性。"""
        enemy = self.room.get_entity(enemy_id)
        if enemy is None:
            return
        dx, dy = target.x - enemy.x, target.y - enemy.y
        length = math.hypot(dx, dy)
        if length > 0.001:
            self.room.apply_move_dir(enemy_id, dx / length, dy / length, True, dt)
            self.room.apply_facing(enemy_id, math.atan2(dy, dx))

    def on_enemy_dead(self, enemy_id: str, attacker_id: str) -> Optional[ExperienceOrb]:
        """处理敌人死亡后的掉落和击杀统计；真正加经验延后至球被吸收。"""
        # 击杀只生成逻辑经验球；经验在球抵达玩家前不结算，避免“掉落即加经验”。
        enemy = self.room.get_entity(enemy_id)
        if enemy is None or enemy.entity_type == "player":
            return None
        self.stats["kills"] += 1
        value = max(1, self.level(attacker_id))
        orb_id = f"xp:{self._next_orb}"
        self._next_orb += 1
        orb = ExperienceOrb(orb_id, attacker_id, value, enemy.x, enemy.y)
        self.orbs[orb_id] = orb
        return orb

    def _update_orbs(self, dt: float) -> None:
        """推进球向归属玩家吸附，只有距离阈值内才调用 add_experience。"""
        # 球的移动和吸收由服务端推进。原归属玩家失效时才改投最近活跃玩家，
        # 客户端只负责显示 ExperienceOrb 事件，不能本地增加经验。
        for orb_id, orb in list(self.orbs.items()):
            player = self.room.get_entity(orb.owner_id)
            if player is None or player.state == "dead":
                player = min(self.active_players(), key=lambda p: (p.x - orb.x) ** 2 + (p.y - orb.y) ** 2, default=None)
            if player is None:
                continue
            dx, dy = player.x - orb.x, player.y - orb.y
            distance = math.hypot(dx, dy)
            if distance <= 28.0:
                self.add_experience(player.entity_id, orb.value)
                del self.orbs[orb_id]
                continue
            step = min(distance, 320.0 * dt)
            orb.x += dx / distance * step
            orb.y += dy / distance * step

    def level(self, player_id: str) -> int:
        """读取 GameRoom 中玩家的 Run 等级，找不到时安全返回 1。"""
        return int(getattr(self.room.get_survival_player(player_id), "level", 1))

    def add_experience(self, player_id: str, amount: int) -> None:
        """累加经验并把每次升级追加到该玩家独立队列。"""
        # 升级可以连续发生；每次升级追加独立队列项，多人时各玩家队列互不影响。
        state = self.room.get_survival_player(player_id)
        if state is None or state.dead:
            return
        state.experience += max(0, amount)
        while state.experience >= state.next_experience:
            state.experience -= state.next_experience
            state.level += 1
            state.next_experience = state.level * state.level * 10
            choices = self._choices()
            self.pending_rewards.setdefault(player_id, []).append(choices)

    def _choices(self) -> List[RewardChoice]:
        """生成本次升级候选；候选内容服务端决定，客户端只收展示文本。"""
        pool = [
            RewardChoice("attack_percent", "攻击力 +15%", 0.15),
            RewardChoice("max_hp", "最大生命 +20", 20),
            RewardChoice("range_percent", "攻击范围 +10%", 0.10),
            RewardChoice("defense", "防御 +10", 10),
        ]
        random.shuffle(pool)
        return pool[:3]

    def choose_reward(self, player_id: str, index: int) -> bool:
        """消费队列首项的合法选择；越界、重复和过期请求返回 False。"""
        # 请求必须命中该玩家当前队列的首项和有效索引；因此重复、乱序或过期
        # 选择会被拒绝，奖励只在服务端应用一次。
        queues = self.pending_rewards.get(player_id)
        if not queues or index < 0 or index >= len(queues[0]):
            return False
        choice = queues.pop(0)[index]
        self.room.apply_survival_reward(player_id, choice.reward_id, choice.value)
        if not queues:
            self.pending_rewards.pop(player_id, None)
        self.paused = self.should_pause()
        return True

    def on_player_dead(self, player_id: str) -> None:
        """标记玩家死亡并移除其待选队列；最后一名活跃玩家死亡即结束 Run。"""
        # 死亡玩家不能再消费奖励；最后一名活跃玩家死亡时封存结果，供结算消息使用。
        state = self.room.get_survival_player(player_id)
        if state is not None:
            state.dead = True
        self.pending_rewards.pop(player_id, None)
        if self.active_player_count() == 0:
            self.end()

    def end(self) -> dict:
        """封存 Run 并返回结算快照；调用方负责广播 SurvivalResult。"""
        self.ended = True
        self.active = False
        return self.result()

    def result(self) -> dict:
        """构造只读结算数据，不包含可被客户端反写的运行时对象。"""
        return {"survival_seconds": int(self.elapsed), "wave": self.wave,
                "kills": self.stats["kills"], "damage": self.stats["damage"]}

    def clear(self) -> None:
        """清理回大厅/重开所需的目标、返程、球和奖励引用。"""
        # 回大厅/重开必须清除所有 Run 引用，避免旧局的目标、球或奖励泄漏到新局。
        self.active = False
        self.ended = True
        self.enemy_targets.clear()
        self.returning.clear()
        self.orbs.clear()
        self.pending_rewards.clear()
