# coding=utf-8

"""
文件: server/game/timer_mgr.py
作用: 攻击生命周期定时器——管判定帧(hit_time)和结束(duration)两个时间点的回调

============================================================================
 为什么需要单独的 timer 模块
============================================================================
判定帧模型下,一次攻击有两个时间点要触发:
  - hit_time: 判定帧到,做范围查询 + 广播 AttackHit
  - duration: 攻击结束,设 state=idle + 广播 AttackEnd

这两个时间点都需要 asyncio.sleep 等待,而 _process_tick 是同步逻辑(不能 await)。
所以必须用 asyncio.Task 异步等待——这就是 timer_mgr.py 的职责。

============================================================================
 时间单位:毫秒(ms)
============================================================================
本模块对外接口全部用毫秒(int):
  - 配置可读性:hit_time=80 比 hit_time=0.08 直观
  - 行业惯例:Unity/UE/技能编辑器普遍用毫秒
  - 避免浮点书写累积误差:0.1+0.2=0.30000004,毫秒整数无此问题

asyncio.sleep 内部用秒,所以 _run 里做一次 /1000.0 转换。
转换只在 timer_mgr.py 内部发生,调用方永远用毫秒。

注意:毫秒单位不提高 asyncio 调度精度(Windows ~15ms 误差仍存在),
只是可读性更好。对游戏战斗判定帧(80~500ms 量级),调度误差可接受。

============================================================================
 设计要点
============================================================================
1. 不依赖 GameRoom:timer 只管"到时间调回调",具体调什么由调用方传入。
   保持 timer 通用,GameRoom 仍是唯一状态持有者。

2. 每个攻击一个 task:单 task 两段 await。
   取消时一刀切——判定帧和结束都不会触发(玩家断连时合理)。

3. task 引用存 timer 对象里,TimerManager 用 player_id 做 key 管理所有 timer。
   玩家断连时调 TimerManager.cancel(player_id) 取消该玩家所有定时器。

4. 回调要能感知"已失效":
   - 玩家可能已断连(task 取消了,但回调可能已在等待中)
   - 玩家状态可能已变化(被强制 cancel_attack)
   所以 task 内部 try/except asyncio.CancelledError,回调由调用方自己检查状态。

5. 回调是 async 的:因为回调要调 GameRoom.apply_xxx + server.broadcast,都是 async。
   task 内部 await 回调。

============================================================================
 协作关系
============================================================================
  GameServer._process_tick
      ↓ apply_attack 存在 pending
      ↓ 调 TimerManager.start_attack(pid, hit_time_ms, duration_ms, hit_cb, end_cb)
      ↓ AttackTimer.start() 启动 asyncio.Task
  await asyncio.sleep(hit_time_ms / 1000)
      ↓ 调 hit_cb(apply_attack_hit + broadcast AttackHit)
  await asyncio.sleep((duration_ms - hit_time_ms) / 1000)
      ↓ 调 end_cb(apply_set_state idle + broadcast AttackEnd)

  玩家断连
      ↓ GameServer.cleanup_player
      ↓ 调 TimerManager.cancel(player_id)
      ↓ AttackTimer.cancel() → task.cancel()
      ↓ CancelledError,两个回调都不触发
"""

import asyncio
import logging
from typing import Callable, Coroutine, Any, Optional, Dict

logger = logging.getLogger(__name__)

# 回调类型:async 函数,无参数(调用方在闭包里绑定好 player_id 等上下文)
AsyncCallback = Callable[[], Coroutine[Any, Any, None]]


class StateTimer:
    def __init__(self, *args, **kwargs):
        # asyncio.Task 引用,start 时 create,cancel/done 时置 None
        self._task: Optional[asyncio.Task] = None
        # 是否已取消(防 cancel 重复调用 + 状态查询)
        self._cancelled = False

    def start(self) -> None:
        """启动定时器(创建 asyncio.Task,立即返回)"""
        if self._task is not None:
            # 已经启动过,不重复启动(防御)
            return
        self._task = asyncio.create_task(self._run())

    def cancel(self) -> None:
        """取消定时器,两个回调都不触发(若还没触发的话)"""
        if self._cancelled:
            return
        self._cancelled = True
        if self._task is not None and not self._task.done():
            self._task.cancel()
        self._task = None

    def is_done(self) -> bool:
        """是否已结束(自然结束或被取消)"""
        return self._task is None or self._task.done()

    async def _run(self) -> None:
        raise NotImplementedError("Subclasses must implement _run")

class AttackTimer(StateTimer):
    """
    单次攻击的定时器
    管判定帧(hit_time)和结束(duration)两个时间点

    生命周期:
        start() → await hit_time → 调 hit_cb → await (duration-hit_time) → 调 end_cb
        cancel() 可在任意时刻取消,两个回调都不触发

    注意:cancel 后 task 内部的回调不会触发,但若 hit_cb 已经触发过,
          end_cb 仍会被 cancel 掉——这是合理的(攻击被强制中断,不该再发 End)。

    时间单位:毫秒(ms),所有对外参数都是 int 毫秒
    """

    def __init__(self, hit_time_ms: int, duration_ms: int,
                 hit_callback: AsyncCallback, end_callback: AsyncCallback):
        """
        Args:
            hit_time_ms: 判定帧时间(毫秒,从 start 算)
            duration_ms: 攻击总时长(毫秒,从 start 算),必须 >= hit_time_ms
            hit_callback: 判定帧到时调用的 async 回调
            end_callback: 攻击结束时调用的 async 回调
        """
        super().__init__()
        self._hit_time_ms = hit_time_ms
        self._duration_ms = duration_ms
        self._hit_cb = hit_callback
        self._end_cb = end_callback

    async def _run(self) -> None:
        """
        定时器主逻辑(在 asyncio.Task 里执行)

        两段 await:
            1. await hit_time → 调 hit_cb
            2. await (duration - hit_time) → 调 end_cb

        任何一段 await 被取消(CancelledError),整个 task 结束,后续回调不触发。
        hit_cb / end_cb 内部的异常会被捕获并记录,不让 task 静默挂掉。

        asyncio.sleep 接收秒,这里把毫秒转秒(/1000.0)。
        """
        try:
            # 第一段:等到判定帧(毫秒转秒)
            await asyncio.sleep(self._hit_time_ms / 1000.0)

            # 判定帧回调(异常不传播,避免影响后续 end 等待)
            try:
                await self._hit_cb()
            except Exception as e:
                logger.exception(f"AttackTimer hit_callback 异常: {e}")

            # 第二段:等到结束(duration_ms - hit_time_ms)
            # 用 max 防御 duration < hit_time 的配置错误(不阻塞,立即触发 end)
            remaining_ms = max(0, self._duration_ms - self._hit_time_ms)
            await asyncio.sleep(remaining_ms / 1000.0)

            # 结束回调
            try:
                await self._end_cb()
            except Exception as e:
                logger.exception(f"AttackTimer end_callback 异常: {e}")

        except asyncio.CancelledError:
            # 被 cancel 了——正常情况,静默退出
            # 不重新 raise CancelledError:task 已被取消,不必再传播
            logger.debug("AttackTimer 被取消,回调不再触发")
            return

class HurtTimer(StateTimer):

    def __init__(self, duration_ms: int, end_callback: AsyncCallback):
        super().__init__()
        self._duration_ms = duration_ms
        self._end_cb = end_callback

    async def _run(self) -> None:
        try:
            await asyncio.sleep(self._duration_ms / 1000.0)
            try:
                await self._end_cb()
            except Exception as e:
                logger.exception(f"HurtTimer end_callback 异常: {e}")
        except asyncio.CancelledError:
            logger.debug("HurtTimer 被取消,回调不再触发")
            return


class DeadTimer(StateTimer):
    """
    单次死亡的定时器
    管死亡动画时长(duration),到期后调 end_cb(remove_entity + 广播 EntityRemove)

    生命周期:
        start() → await duration → 调 end_cb
        cancel() 可在任意时刻取消,end_cb 不触发

    和 HurtTimer 结构完全一样(单段 await + 到期回调),但语义独立:
        - HurtTimer:硬直结束,恢复 idle
        - DeadTimer:死亡动画播完,移除实体
    保持独立类而非复用 HurtTimer,因为死亡流程未来可能加逻辑(如死亡时还能被推动、
    死亡时播放特定音效等),届时只改 DeadTimer 不影响 hurt 逻辑。

    时间单位:毫秒(ms),和 HurtTimer 一致
    """

    def __init__(self, duration_ms: int, end_callback: AsyncCallback):
        super().__init__()
        self._duration_ms = duration_ms
        self._end_cb = end_callback

    async def _run(self) -> None:
        try:
            await asyncio.sleep(self._duration_ms / 1000.0)
            try:
                await self._end_cb()
            except Exception as e:
                logger.exception(f"DeadTimer end_callback 异常: {e}")
        except asyncio.CancelledError:
            logger.debug("DeadTimer 被取消,回调不再触发")
            return



class TimerManager:
    """
    按玩家管理 AttackTimer 集合
    玩家发起攻击时 start_attack,断连时 cancel(player_id) 清理所有定时器

    为什么按 player_id 管理:
        - 一个玩家同时可能有多个攻击定时器(连击/多段攻击)
        - 玩家断连时要一次取消所有(避免对已删除玩家操作状态)

    时间单位:毫秒(ms),和 AttackTimer 一致
    """

    def __init__(self):
        # player_id -> List[AttackTimer]
        # 用 List 而非单个:支持连击等多段攻击(当前项目一段攻击只有一个 timer,但留接口)
        self._timers: Dict[str, list] = {}
        # 同时只会有一个hurt_timer
        self._hurt_timers: Dict[str, HurtTimer] = {}
        # 同时只会有一个dead_timer(死亡期间不会再死)
        self._dead_timers: Dict[str, DeadTimer] = {}

    def start_attack(self, player_id: str,
                     hit_time_ms: int, duration_ms: int,
                     hit_callback: AsyncCallback, end_callback: AsyncCallback) -> AttackTimer:
        """
        为玩家启动一次攻击定时器

        Args:
            player_id: 发起攻击的玩家 ID
            hit_time_ms: 判定帧时间(毫秒)
            duration_ms: 攻击总时长(毫秒)
            hit_callback: 判定帧回调(apply_attack_hit + broadcast AttackHit)
            end_callback: 结束回调(apply_set_state idle + broadcast AttackEnd)

        Returns:
            创建的 AttackTimer(调用方一般不需要保存,TimerManager 内部已管理)
        """
        timer = AttackTimer(hit_time_ms, duration_ms, hit_callback, end_callback)
        timer.start()

        if player_id not in self._timers:
            self._timers[player_id] = []
        self._timers[player_id].append(timer)

        logger.debug(f"玩家 {player_id} 启动攻击定时器: hit_time={hit_time_ms}ms, duration={duration_ms}ms")
        return timer

    def cancel(self, player_id: str) -> None:
        """
        取消该玩家的所有攻击定时器 + hurt 定时器 + dead 定时器
        玩家断连时调(cleanup_player 里),防止对已删除玩家操作状态

        玩家不存在或无定时器时静默返回(幂等)

        命名提醒:本方法叫 cancel,范围是该玩家的所有定时器(attack/hurt/dead)。
        断连清理需要全覆盖,避免任意一种定时器到期对已删除实体操作状态。
        """
        # 1. 攻击定时器(可能有多个,如连击)
        timers = self._timers.pop(player_id, None)
        if timers:
            for timer in timers:
                timer.cancel()
            logger.debug(f"玩家 {player_id} 的 {len(timers)} 个攻击定时器已取消")

        # 2. hurt 定时器(同时只有一个)
        hurt_timer = self._hurt_timers.pop(player_id, None)
        if hurt_timer is not None:
            hurt_timer.cancel()
            logger.debug(f"玩家 {player_id} 的 hurt 定时器已取消")

        # 3. dead 定时器(同时只有一个)
        dead_timer = self._dead_timers.pop(player_id, None)
        if dead_timer is not None:
            dead_timer.cancel()
            logger.debug(f"玩家 {player_id} 的 dead 定时器已取消")

    def cancel_all(self) -> None:
        """取消当前房间全部攻击、受击和死亡定时器。

        Run 结束时由 GameServer 调用，确保旧房间的异步回调不会在新 Run
        创建后继续写入状态。逐个调用已有幂等 cancel，避免重复维护三类表。
        """
        player_ids = set(self._timers) | set(self._hurt_timers) | set(self._dead_timers)
        for player_id in player_ids:
            self.cancel(player_id)

    def cleanup_done(self, player_id: str) -> None:
        """
        清理该玩家已结束的定时器(自然结束的 task 引用)
        定期调用避免 _timers 字典无限增长

        当前项目无定期调用——start_attack 时同玩家若已有结束的 timer,
        会被这里清掉。可选操作,不调也不会出错(只是 _timers 略大)
        """
        if player_id not in self._timers:
            return
        # 保留未结束的,清掉已结束的
        self._timers[player_id] = [t for t in self._timers[player_id] if not t.is_done()]
        # 如果清空了,删 key 避免空 list 堆积
        if not self._timers[player_id]:
            del self._timers[player_id]

    def has_active(self, player_id: str) -> bool:
        """该玩家是否有未结束的攻击定时器(可用于判断是否在攻击中)"""
        if player_id not in self._timers:
            return False
        return any(not t.is_done() for t in self._timers[player_id])


    def start_hurt(self, player_id: str, duration_ms: int, end_callback: AsyncCallback) -> HurtTimer:
        timer = HurtTimer(duration_ms, end_callback)
        timer.start()

        if player_id in self._timers:
            self.cancel(player_id)  # 剩余的攻击被打断了

        if self._hurt_timers.get(player_id, None) is not None:
            # 打断之前的 HurtTimer
            self._hurt_timers[player_id].cancel()
            del self._hurt_timers[player_id]

        self._hurt_timers[player_id] = timer
        return timer

    def start_dead(self, player_id: str, duration_ms: int, end_callback: AsyncCallback) -> DeadTimer:
        """
        为实体启动死亡定时器

        死亡打断一切:内部先 cancel 该玩家的 attack timers + hurt timer,
        再启 DeadTimer。理由:死亡是终态,之前的攻击/硬直都不该再继续。

        DeadTimer 到期后调 end_callback(由调用方传入,通常是
        room.remove_entity + 广播 EntityRemove)。

        和 start_hurt 的区别:
            - start_hurt:cancel 旧 hurt(连击重置硬直),不 cancel dead
              (硬直期间不会被死亡打断——死亡实体不会走 hurt 分支)
            - start_dead:cancel 所有 attack + hurt(死亡是最高优先级终态)

        Args:
            player_id: 死亡的实体ID
            duration_ms: 死亡动画时长(毫秒,从 entity_config.get_dead_duration_ms 取)
            end_callback: 到期回调(remove_entity + 广播 EntityRemove)

        Returns:
            创建的 DeadTimer
        """
        timer = DeadTimer(duration_ms, end_callback)
        timer.start()

        # 死亡打断一切:cancel 所有 attack + hurt timers
        # (不能让攻击判定帧/结束广播在死亡后还触发,也不能让 hurt 恢复 idle)
        self.cancel(player_id)

        # cancel 已经把 _dead_timers 里的旧条目也清了(防御性),
        # 但理论上死亡期间不会再死,这里再兜底一次
        old_dead = self._dead_timers.pop(player_id, None)
        if old_dead is not None:
            old_dead.cancel()

        self._dead_timers[player_id] = timer
        logger.debug(f"实体 {player_id} 启动死亡定时器: duration={duration_ms}ms")
        return timer
