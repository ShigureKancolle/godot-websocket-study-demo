extends RefCounted
class_name ClientStateMirror

"""
文件: client/Script/Net/StateMirror.gd
作用: 客户端「只读」的游戏状态镜像

============================================================================
 为什么有这个文件(核心动机——和服务端 GameRoom 对照看)
============================================================================
服务端有 GameRoom(权威状态持有者),它有 add_entity / apply_move_dir 等方法——
    它是状态的「主人」,只有它能改状态。

客户端不能也搞一个能改状态的类,否则就成了「双端各写一份状态逻辑」,
    这正是我们最想避免的重复。客户端只能有一个「镜像」:
    服务端说什么,客户端就反映什么,绝不自己算。

所以 ClientStateMirror 的设计原则只有一条:
    【只接收、只镜像、只读暴露;绝不本地推演状态】

对比服务端 GameRoom:
    GameRoom.apply_move_dir(eid, dir_x, dir_y, moving, dt)    ← 改状态(主人)
    ClientStateMirror._on_move(d)     ← 接收服务端广播,更新镜像(奴仆)
    两边方法名不同、职责不同、代码不重复。

============================================================================
 统一 Entity 模型 + 强类型 ClientEntityInfo(本次重构)
============================================================================
和服务端对齐:所有可交互物体(玩家/木桩/箱子/陷阱)统一用 _entities 一张表存,
    不再区分 _players。
	- entity_id 带类型前缀: "player:uuid-xxx" / "entity:stake_1"
    - entity_type 用 ClientEntityInfo.EntityType 枚举(从服务端字符串转换)
    - _entities 存的是 ClientEntityInfo(强类型 RefCounted),不再存 Dictionary
	- 字段访问用 info.x / info.state 而非 info["x"] / info["state"]

为什么改强类型:见 EntityInfo.gd 文件头说明。简言之:拼错字段名编译期报错、
IDE 补全、字段集合显式。

============================================================================
 架构位置
============================================================================
    服务端 GameRoom(权威)
        ↓ bus.send 广播 GameState / EnterRoom / PlayerMove / LeaveRoom
    网络(WebSocket bytes)
        ↓ MyWebSocketClient._dispatch_packet
    MessageBus.dispatch(反序列化 + 路由)
        ↓ onproto 注册的 handler
    ClientStateMirror._on_xxx(data: Dictionary)   ← 本文件:把 dict 转成 ClientEntityInfo 存
        ↓ emit_signal 通知渲染层(信号携带 ClientEntityInfo)
    渲染层(dead_man_scene 等)读 mirror.all_entities() 创建对应实体

ClientStateMirror 自身不做任何网络 I/O(不调 bus.send),
    也不决定「该不该更新」——服务端说什么就更新什么。
    这种「无脑服从」是客户端镜像的正确姿态:权威在服务端,客户端不质疑。

============================================================================
 为什么用 RefCounted + 单例,而不是 Node / autoload
============================================================================
- 不需要进场景树:StateMirror 不参与 _process / _physics_process,
  纯数据容器 + 信号通知,用 RefCounted 更轻量
- 单例:全局只有一份状态镜像,任何场景(大厅、游戏场景)都看同一个
  实现:用 static var _instance,第一次访问时创建
- 不做 autoload:避免和 WebScoketMgr 的初始化顺序耦合
  (autoload 之间初始化顺序难控,StateMirror 依赖 MessageBus 已就绪,
   用懒加载更安全)
"""

# ---------------------------------------------------------------------------
# 信号:状态变化时通知渲染层
# ---------------------------------------------------------------------------
# Godot 的 signal 机制:emit_signal 时,所有 connect 到该信号的 Callable 会被调用。
# 渲染层(如 dead_man_scene)在 _ready 里 connect 这些信号,收到时刷新显示。

# 全量刷新信号:服务端发了 GameState 快照,本地镜像整体替换了。
# 渲染层收到后应「重新构建所有实体显示」。
# 参数:entities(Array[ClientEntityInfo]),当前所有实体信息
signal state_replaced(entities: Array)

# 增量变化信号:单个实体信息变了(加入/移动/朝向/动画状态)。
# 渲染层收到后只需「更新这一个实体」,比全量刷新省。
# 参数:entity_info(ClientEntityInfo),变化的实体信息
signal entity_updated(entity_info: ClientEntityInfo)
signal entity_relocated(entity_info: ClientEntityInfo)

# 实体离开信号:某实体离开了(玩家断连;木桩不会走这个路径,被破坏时另议)。
# 渲染层收到后「移除该实体的显示」。
# 参数:entity_id(String),离开的实体ID
signal entity_removed(entity_id: String)

# 实体受击特效信号:某实体被击中了(玩家被攻击)。
# 渲染层收到后「播放受击特效」。
# 参数:pos(Vector2),受击特效位置
signal entity_hurt_effect(pos: Vector2, atk_id: int)

# 战斗属性全量同步信号:收到 StatsInit,本地 _combats 表整体替换了。
# 渲染层收到后初始化所有血条。
# 参数:combats(Array[ClientCombatStats]),当前所有战斗属性
signal stats_inited(combats: Array[ClientCombatStats])

# 单个实体战斗属性变更信号:强化或新玩家加入时触发。
# 渲染层收到后更新对应血条的最大值。
# 参数:combat(ClientCombatStats),变更的战斗属性
signal stats_changed(combat: ClientCombatStats)

# 血量变更信号:某实体扣血了,渲染层收到后更新血条 + 播伤害飘字。
# 参数:entity_id(被打的人), cur_hp(剩余血量), damage(本次伤害,0=非伤害性同步),
#       attacker_id(谁打的,飘字定位用), atk_id, atk_shape_idx(算命中点用)
signal hp_changed(entity_id: String, cur_hp: int, damage: int, attacker_id: String, atk_id: int, atk_shape_idx: int)

# 伤害字信号:某实体扣血了,渲染层收到后播放伤害飘字。
# 参数:pos(Vector2),伤害字位置
signal fire_damage_effect(pos: Vector2, atk_id: int, damage: int)

# 地图信息信号:收到 MapInfo(服务端下发的地图种子)。
# 渲染层(游戏场景)收到后调 InfiniteTileMap.setup(seed) 初始化地图。
# 参数:seed(int),地图种子
# 为什么单独发信号而不是直接调 InfiniteTileMap:
#   StateMirror 是纯数据镜像,不应该知道场景里有什么节点(职责分离)。
#   场景监听这个信号,自己决定怎么用 seed(当前是调 InfiniteTileMap.setup,
#   未来可能还会做别的:如生成小地图、初始化寻路可视化等)。
signal map_info_received(seed: int)
signal survival_state_updated(state: Dictionary)
signal level_up_choices_received(choices: Dictionary)
signal experience_orb_received(orb: Dictionary)
signal survival_result_received(result: Dictionary)


# ===========================================================================
# ClientCombatStats: 客户端镜像战斗属性(强类型,和服务端 CombatComponent 字段对齐)
# ===========================================================================
# 和 ConfigLoader.CombatStats 的区别:
#   - ConfigLoader.CombatStats 是「类型级基础值」(从 JSON 读,只读)
#   - ClientCombatStats 是「实例运行时状态」(从服务端镜像,会变:cur_hp 每次受伤都变)
# 和 ClientEntityInfo 一样用 RefCounted + 强类型字段,from_dict 集中转换
class ClientCombatStats:
	extends RefCounted
	var entity_id: String = ""
	var max_hp: int = 0
	var cur_hp: int = 0
	var attack_power: int = 0
	var defense: int = 0

	static func from_dict(d: Dictionary) -> ClientCombatStats:
		var s = ClientCombatStats.new()
		s.entity_id = d.get("entity_id", "")
		s.max_hp = int(d.get("max_hp", 0))
		s.cur_hp = int(d.get("cur_hp", 0))
		s.attack_power = int(d.get("attack_power", 0))
		s.defense = int(d.get("defense", 0))
		return s

	func _to_string() -> String:
		return "ClientCombatStats(id=%s, hp=%d/%d, atk=%d, def=%d)" % [entity_id, cur_hp, max_hp, attack_power, defense]


# ---------------------------------------------------------------------------
# 单例
# ---------------------------------------------------------------------------
# 为什么用 static var 做单例而非 autoload:
#   见文件头说明。懒加载避免初始化顺序问题。
static var _instance: ClientStateMirror = null

static func instance() -> ClientStateMirror:
	if _instance == null:
		_instance = ClientStateMirror.new()
	return _instance


# ---------------------------------------------------------------------------
# 内部状态
# ---------------------------------------------------------------------------
# 实体镜像表:entity_id -> ClientEntityInfo
# 和服务端 GameRoom._entities 结构对齐——这保证了镜像形状 = 权威形状。
# 不同点:服务端能改它(通过 apply_move_dir 等,存的是 EntityInfo dataclass),
#         客户端只能整体替换/接收更新(存的是 ClientEntityInfo RefCounted)。
# 强类型:不再存 Dictionary,所有字段访问走 ClientEntityInfo 的属性
var _entities: Dictionary = {}

# 战斗属性镜像表:entity_id -> ClientCombatStats
# 和服务端 GameRoom._combats 结构对齐(独立组件,不嵌在 EntityInfo 里)
# 和 _entities 平级,通过 entity_id 关联
var _combats: Dictionary[String, ClientCombatStats] = {}

# 本地玩家的 entity_id(服务端在 EnterRoom 响应里回传的)
# 渲染层用它区分「自己」和「别人」(比如自己的角色高亮显示)
# 为什么放这里而不是放某个场景脚本:entity_id 是跨场景的状态,放镜像里最合适
var _local_entity_id: String = ""
# 最近一次服务端 Run 快照/候选/结算，供场景晚于网络消息创建时补刷 UI。
var _survival_state: Dictionary = {}
var _last_level_up_choices: Dictionary = {}
var _last_survival_result: Dictionary = {}


# ---------------------------------------------------------------------------
# 只读访问(给渲染层用)
# ---------------------------------------------------------------------------

## 获取所有实体信息(只读意图)。返回内部字典的 values,调用方不应修改。
## 返回 Array,元素是 ClientEntityInfo
func all_entities() -> Array:
	return _entities.values()

## 获取单个实体信息。不存在则返回 null。
func get_entity(entity_id: String) -> ClientEntityInfo:
	return _entities.get(entity_id)

## 获取本地玩家 entity_id
func local_entity_id() -> String:
	return _local_entity_id

## 当前镜像中的实体数
func entity_count() -> int:
	return _entities.size()

## 清空镜像数据(返回大厅/切换场景时调用)
## 清空 _entities / _combats / _local_entity_id,避免跨场景脏数据
## 不清信号连接(信号连接由各场景 _ready 自行管理,切场景时旧场景的连接自动销毁)
func clear() -> void:
	_entities.clear()
	_combats.clear()
	_local_entity_id = ""
	_survival_state.clear()
	_last_level_up_choices.clear()
	_last_survival_result.clear()

func survival_state() -> Dictionary:
	"""返回最近的服务端 Run 快照副本，客户端不得据此反写权威状态。"""
	return _survival_state.duplicate()

func last_level_up_choices() -> Dictionary:
	"""返回最近的服务端升级候选副本。"""
	return _last_level_up_choices.duplicate()

func last_survival_result() -> Dictionary:
	"""返回最近的服务端结算副本。"""
	return _last_survival_result.duplicate()


## 获取单个实体的战斗属性。不存在则返回 null。
func get_combat(entity_id: String) -> ClientCombatStats:
	return _combats.get(entity_id)

## 获取所有战斗属性(只读意图)。返回 Array,元素是 ClientCombatStats
func all_combats() -> Array[ClientCombatStats]:
	return _combats.values()


# ---------------------------------------------------------------------------
# 状态更新(被 MessageBus handler 调用,不是给业务代码调的)
# ---------------------------------------------------------------------------
# 以下 _on_xxx 方法都以下划线开头,表示「内部方法」——
# 它们由 StateMirror 自己在 register_handlers 里注册给 MessageBus,
# 业务代码不应直接调用它们,只应通过 bus 的正常分发流程触发。

## 注册消息处理器到 MessageBus
## 在 MessageBus 初始化完成后调用一次即可
func register_handlers() -> void:
	var mb = MessageBus.instance()
	# 这里注册会影响状态的消息。
	# ChatMessage 和 Heartbeat 不影响状态,不在这里注册——
	# 它们由各自的 UI(如 chat_main)单独处理。
	mb.onproto("game.GameState", _on_game_state)
	mb.onproto("game.EnterRoom", _on_enter_room)
	mb.onproto("game.PlayerMove", _on_player_move)
	mb.onproto("game.MovementBatch", _on_movement_batch)
	mb.onproto("game.EntityRelocated", _on_entity_relocated)
	mb.onproto("game.PlayerFacing", _on_player_facing)
	mb.onproto("game.LeaveRoom", _on_leave_room)
	mb.onproto("game.Heartbeat", _on_heartbeat)
	mb.onproto("game.AttackStart", _on_attack_start)
	mb.onproto("game.AttackEnd", _on_attack_end)
	mb.onproto("game.AttackHit", _on_attack_hit)
	mb.onproto("game.HurtEnd", _on_hurt_end) 
	mb.onproto("game.StatsInit", _on_stats_init)
	mb.onproto("game.StatsChanged", _on_stats_changed)
	mb.onproto("game.HpChanged", _on_hp_changed)
	mb.onproto("game.EntityRemove", _on_entity_remove)
	mb.onproto("game.EntityDead", _on_entity_dead)
	mb.onproto("game.EntitySpawn", _on_entity_spawn)
	mb.onproto("game.MapInfo", _on_map_info)
	mb.onproto("game.AiStateChanged", _on_ai_state_changed)
	# 数据流：服务端 S2C -> MessageBus -> 本镜像 -> 信号 -> HUD/UI；镜像不改 Run 状态。
	mb.onproto("game.SurvivalState", _on_survival_state)
	mb.onproto("game.LevelUpChoices", _on_level_up_choices)
	mb.onproto("game.ExperienceOrb", _on_experience_orb)
	mb.onproto("game.SurvivalResult", _on_survival_result)


## 收到 GameState 快照:整体替换本地镜像
##
## 这是「服务器权威」最纯粹的体现:
## 服务端发来一份完整状态,客户端不质疑、不合并、不增量,
## 直接用这份快照覆盖本地所有数据。
##
## 为什么敢直接覆盖:
##   服务端是唯一权威,它说的就是真相。客户端本地哪怕有缓存,
##   只要服务端发了快照,就以服务端为准——本地缓存可能过期了。
##
## 什么时候收到快照:
##   - 刚加入房间时(服务端发当前所有实体状态给新玩家)
##   - 未来可加定时快照做「对账」(防止增量更新累积误差)
func _on_game_state(data: Dictionary) -> void:
	# 清空旧镜像,用快照重建
	# 为什么不 _entities.clear() 后逐个 add:直接重建更清晰,且避免 clear 过程中
	# 渲染层读到半空状态的窗口期(信号在最后一次性发,中间状态不暴露)
	_entities.clear()
	var entities: Array = data.get("entities", [])
	for e in entities:
		# e 是 Dictionary(EntityInfo proto 反序列化的 dict)
		# 转成 ClientEntityInfo 强类型对象后存
		# 转换集中在 ClientEntityInfo.from_dict,这是 dict→强类型的唯一入口
		var info := ClientEntityInfo.from_dict(e)
		if info.entity_id != "":
			_entities[info.entity_id] = info

	# 通知渲染层:状态被整体替换了,请全量刷新
	state_replaced.emit(_entities.values())


## 收到 EntitySpawn：单实体出生增量，原子更新实体和战斗镜像。
## 服务端先完成 GameRoom 创建，再经 MessageBus 到这里；不触发 state_replaced，
## 因而已有 Role 不会被全量 free/rebuild。重复 ID 采用最新数据幂等覆盖。
func _on_entity_spawn(data: Dictionary) -> void:
	var entity_data: Dictionary = data.get("entity_info", {})
	var combat_data: Dictionary = data.get("combat", {})
	var eid: String = entity_data.get("entity_id", "")
	if eid == "":
		return
	var info := ClientEntityInfo.from_dict(entity_data)
	_entities[eid] = info
	var combat := ClientCombatStats.from_dict(combat_data)
	if combat.entity_id == "":
		combat.entity_id = eid
	_combats[eid] = combat
	entity_updated.emit(info)
	stats_changed.emit(combat)

## 服务端重定位控制事件：更新权威镜像并单独通知渲染层，不能被 MovementBatch 插值吞掉。
func _on_entity_relocated(data: Dictionary) -> void:
	var eid: String = data.get("entity_id", "")
	var entity: ClientEntityInfo = _entities.get(eid)
	if entity == null:
		return
	entity.x = data.get("x", entity.x)
	entity.y = data.get("y", entity.y)
	entity.moving = false
	entity_relocated.emit(entity)


## 收到 EnterRoom:增量添加一个实体(通常是玩家进入房间)
##
## 注意:服务端在 on_enter_room 里对「新玩家自己」发的是 GameState(全量),
##       对「其他已在线实体」发的是 EnterRoom(增量)。
## 所以这个 handler 主要处理「别人加入」的情况。
##
## 但有个细节:本地玩家的 entity_id 是从 EnterRoom 里提取的(见 MessageBus._on_enter_room)。
## 这里也兼容——如果本地 _local_entity_id 还没设置,且收到 EnterRoom,尝试提取。
func _on_enter_room(data: Dictionary) -> void:
	var entity_info: Dictionary = data.get("entity_info", {})
	var eid: String = entity_info.get("entity_id", "")
	if eid == "":
		return

	# 增量更新:直接覆盖该实体条目
	# 为什么覆盖而非报错「已存在」:服务端可能重发 EnterRoom(如断线重连),
	# 客户端镜像应宽容处理——以最新信息为准。这与服务端 GameRoom.add_entity
	# 的「重复加入报错」相反:服务端要防 bug,客户端要容错。
	# dict→强类型转换:from_dict 集中处理字段名/类型
	var info := ClientEntityInfo.from_dict(entity_info)
	_entities[eid] = info

	# 兼容本地 entity_id 提取(见 MessageBus._on_enter_room 的逻辑)
	# 这里不重复设置,只是兜底——正常情况下 MessageBus 已经设过了
	if _local_entity_id == "":
		_local_entity_id = eid

	# 通知渲染层:单个实体更新了
	entity_updated.emit(info)


## 收到 PlayerMove:增量更新某实体坐标
##
## 这是「事件模型」的增量更新——服务端转发了某实体的移动事件,
## 客户端据此更新本地镜像里该实体的位置。
##
## 与 _on_game_state 的对比:
##   _on_game_state 是「全量快照」——服务端说「现在所有实体是这样」
##   _on_player_move 是「增量事件」——服务端说「刚才某实体移动了」
## 增量更新省流量,但累积误差风险(丢包会丢状态)——所以偶尔需要全量快照对账。
func _on_player_move(data: Dictionary) -> void:
	var eid: String = data.get("entity_id", "")
	if eid == "":
		return

	var entity: ClientEntityInfo = _entities.get(eid)
	if entity == null:
		# 镜像里没这个实体:可能是 EnterRoom 丢了或乱序。
		# 客户端容错策略:忽略这次移动,等全量快照来时自动修正。
		# 不主动请求服务端重发——保持客户端「无脑服从」的简单性。
		return

	# 更新坐标(只改这两个字段,不动其他)
	# 为什么不整体替换 entity_info:PlayerMove 消息里只有 entity_id/x/y/speed/moving,
	# 没有 player_name 等字段,整体替换会丢信息。
	entity.x = data.get("x", 0.0)
	entity.y = data.get("y", 0.0)
	entity.moving = bool(data.get("moving", false))

	# 动画状态:从 moving 字段推断 state
	# 服务端 apply_move_dir 也是用 moving 推 state(moving=true→"run", false→"idle"),
	# 客户端这里做同样的映射,保证镜像 state 和服务端 EntityInfo.state 一致。
	# 这不算"状态逻辑重复"——只是字段映射,真正的状态权威在服务端
	# (GameState 快照会带服务端的 state 字段,可对账)。
	#
	# 防御:锁定状态(attacking/hurt/dead)不采纳移动广播的 state 覆盖。
	# - attacking:移动中点击攻击时,残留 PlayerMove 广播可能晚于 AttackStart 到达,
	#   若不防御会把 state 从 "attacking" 挤回 "run",攻击动画被移动动画吞掉。
	# - hurt:击退期间服务端仍每 tick 广播被推走的位置(PlayerMove),若不防御,
	#   state 会被挤回 run/idle,受击动画被掐断、本地玩家提前恢复预测(和服务端
	#   _INPUT_LOCKED_STATES 对齐)。
	# - dead:死亡状态同理,不该被移动广播覆盖。
	# 这些状态由各自的结束广播(AttackEnd/HurtEnd)恢复,这里只更新坐标、不动 state。
	if entity.state != "attacking" and entity.state != "hurt" and entity.state != "dead":
		var moving: bool = data.get("moving", false)
		entity.state = "run" if moving else "idle"

	# 通知渲染层:这个实体变了
	entity_updated.emit(entity)


## 原子应用服务端一个 tick 的移动批次；状态锁定时只更新坐标，不覆盖战斗动画状态。
func _on_movement_batch(data: Dictionary) -> void:
	var pending_updates: Array = []
	for entry in data.get("entries", []):
		var eid: String = entry.get("entity_id", "")
		var entity: ClientEntityInfo = _entities.get(eid)
		if eid == "" or entity == null:
			continue
		entity.x = entry.get("x", entity.x)
		entity.y = entry.get("y", entity.y)
		entity.moving = bool(entry.get("moving", false))
		if entity.state != "attacking" and entity.state != "hurt" and entity.state != "dead":
			entity.state = "run" if entry.get("moving", false) else "idle"
		pending_updates.append(entity)
	# 全部镜像字段写入后再发信号，避免渲染层看到半批次状态。
	for entity in pending_updates:
		entity_updated.emit(entity)


## 收到 PlayerFacing:增量更新某实体朝向
##
## 和 _on_player_move 平行,但只改 facing 不改坐标。
## 朝向和移动是独立状态维度——玩家可以一边移动一边朝任意方向攻击。
##
## 复用 entity_updated 信号通知渲染层(不新增 entity_facing_updated 信号):
##   - Role 已经监听 entity_updated 做坐标更新,朝向更新走同一信号链路最简单
##   - Role.on_entity_updated 里判断 facing 字段,变了就调 PlayerVisual.update_facing
##   - 信号越少,连接关系越简单
func _on_player_facing(data: Dictionary) -> void:
	var eid: String = data.get("entity_id", "")
	if eid == "":
		return

	var entity: ClientEntityInfo = _entities.get(eid)
	if entity == null:
		# 镜像里没这个实体:忽略,等全量快照修正(和 _on_player_move 一致的容错)
		return

	# 更新朝向(只改 facing,不动 x/y)
	entity.facing = data.get("facing", 0.0)

	# 通知渲染层:这个实体变了(复用 entity_updated 信号)
	entity_updated.emit(entity)


## 收到 LeaveRoom:移除某实体
func _on_leave_room(data: Dictionary) -> void:
	var eid: String = data.get("entity_id", "")
	if eid == "":
		return

	# 不存在也 erase,erase 对不存在的 key 是安全的(no-op)
	_entities.erase(eid)

	# 通知渲染层:移除该实体显示
	entity_removed.emit(eid)

func _on_heartbeat(_data: Dictionary) -> void:
	# 心跳消息,告知服务端还存活
	var mb: MessageBus = MessageBus.instance()
	mb.send("game.Heartbeat", {})

func _on_attack_start(data: Dictionary) -> void:
	var eid: String = data.get("entity_id", "")
	if eid == "":
		return

	var atk_id: int = data.get("atk_id", 0)
	if atk_id == 0:
		return

	# 通知渲染层:这个实体发动了攻击
	var entity: ClientEntityInfo = _entities.get(eid)
	if entity == null:
		return

	# 服务端 apply_attack_start 设 state="attacking",客户端镜像同步
	# (这里直接用 "attacking" 和服务端对齐,而不是 "attack"——之前用 "attack" 是误称)
	entity.state = "attacking"
	entity.atk_id = atk_id
	entity_updated.emit(entity)

func _on_attack_end(data: Dictionary) -> void:
	var eid: String = data.get("entity_id", "")
	if eid == "":
		return

	# 通知渲染层:这个实体攻击结束了
	var entity: ClientEntityInfo = _entities.get(eid)
	if entity == null:
		return

	# 服务端 apply_attack_end 设 state="idle",客户端镜像同步
	entity.state = "idle"
	entity_updated.emit(entity)

func _on_attack_hit(data: Dictionary) -> void:
	## 收到攻击命中广播:服务端已算好 hit_list(被命中者 entity_id 列表)
	## 遍历 hit_list 把每个被命中者的 state 设为 "hurt"
	## (注:扣血/飘字数据走 HpChanged 消息,不走这里。这里只处理状态+受击特效)
	##
	## 注意:attacker_id 是攻击者,不是被攻击者——
	## 客户端不需要在这里处理攻击者(攻击者的 state 由 AttackStart 设为 "attacking")
	## 只需要处理被命中者
	var hit_list: Array = data.get("hit_list", [])
	var attacker_id: String = data.get("attacker_id", "")
	var atk_id: int = data.get("atk_id", 1001)
	var atk_shape_idx: int = data.get("atk_shape_idx", 0)
	# 取攻击者位置/朝向算命中点(飘字/特效定位用)
	var attacker: ClientEntityInfo = _entities.get(attacker_id)
	for hurt_id in hit_list:
		var entity: ClientEntityInfo = _entities.get(hurt_id)
		if entity == null:
			continue
		# 服务端 apply_hurt 设 state="hurt" 或 "dead",客户端镜像同步
		# (死亡状态也由 HpChanged 触发,但 state 在这里设最直接)
		# 注:apply_hurt 死亡时 state="dead",这里先设 hurt,死亡由 entity_updated 修正
		if entity.state != "dead":
			entity.state = "hurt"
		entity_updated.emit(entity)
		# 受击特效位置:用攻击者位置+朝向算命中点(更贴合"攻击打到的位置")
		# 攻击者不存在时用被命中者位置兜底
		var hurt_pos: Vector2
		if attacker != null:
			hurt_pos = AttackCalc.calc_hit_position(
				Vector2(attacker.x, attacker.y), attacker.facing,
				atk_id, atk_shape_idx,
				Vector2(entity.x, entity.y), null)
		else:
			hurt_pos = Vector2(entity.x, entity.y)
		entity_hurt_effect.emit(hurt_pos, atk_id)  # 播受击特效(渲染层监听这个信号,在受击者位置播特效)

func _on_hurt_end(data: Dictionary) -> void:
	var eid: String = data.get("hurt_id", "")
	var _attacker_id: String = data.get("attacker_id", "")
	var _atk_id: int = data.get("atk_id", 0)
	var _hurt_duration: int = data.get("hurt_duration", 0)

	var entity: ClientEntityInfo = _entities.get(eid)
	if entity == null:
		return

	# 服务端 apply_hurt_end 设 state="idle",客户端镜像同步
	entity.state = "idle"	
	entity_updated.emit(entity)

func _on_stats_init(data: Dictionary) -> void:
	## 收到 StatsInit:战斗属性全量快照(新玩家加入时服务端发来)
	## 整体替换本地 _combats 表(和 _on_game_state 整体替换 _entities 同理)
	##
	## 为什么敢直接覆盖:服务端是唯一权威,它发的就是真相。本地缓存可能过期。
	## 为什么不和 _on_game_state 合并:战斗属性是独立组件,走独立消息流,
	## 避免每次 GameState 快照都带战斗属性(低频数据走增量,高频数据走快照)
	var entries: Array = data.get("entries", [])
	_combats.clear()
	for e in entries:
		var combat = ClientCombatStats.from_dict(e)
		if combat.entity_id != "":
			_combats[combat.entity_id] = combat
	# 通知渲染层:战斗属性整体替换了,请全量刷新血条
	stats_inited.emit(_combats.values())


func _on_stats_changed(data: Dictionary) -> void:
	## 收到 StatsChanged:单个实体战斗属性变更(强化时广播,或新玩家加入时给其他人发)
	## 增量更新 _combats 表里该实体的 max_hp/attack_power/defense
	## (不含 cur_hp,cur_hp 走 HpChanged)
	var eid: String = data.get("entity_id", "")
	if eid == "":
		return

	# 取现有 combat 或新建(新玩家加入时本地还没有它的 combat)
	var combat: ClientCombatStats = _combats.get(eid)
	if combat == null:
		combat = ClientCombatStats.new()
		combat.entity_id = eid
		_combats[eid] = combat

	# 只更新 max_hp/attack_power/defense,不动 cur_hp
	# (cur_hp 走 HpChanged 单独同步,避免强化时把当前血量重置)
	combat.max_hp = int(data.get("max_hp", 0))
	combat.attack_power = int(data.get("attack_power", 0))
	combat.defense = int(data.get("defense", 0))

	# 通知渲染层:这个实体的战斗属性变了(更新血条最大值)
	stats_changed.emit(combat)


func _on_hp_changed(data: Dictionary) -> void:
	## 收到 HpChanged:某实体扣血了(或新玩家加入时初始化血量)
	## 更新 _combats 表的 cur_hp + 发 hp_changed 信号(血条更新 + 伤害飘字)
	##
	## damage=0 表示非伤害性血量同步(如新玩家加入时让别人知道新玩家满血),
	## 渲染层收到 damage=0 时只更新血条不播飘字
	var eid: String = data.get("entity_id", "")
	if eid == "":
		return

	var cur_hp: int = int(data.get("cur_hp", 0))
	var damage: int = int(data.get("damage", 0))
	var attacker_id: String = data.get("attacker_id", "")
	var atk_id: int = int(data.get("atk_id", 0))
	var atk_shape_idx: int = int(data.get("atk_shape_idx", 0))

	# 更新 combat 的 cur_hp
	# combat 不存在时新建(容错:StatsInit 丢了或乱序时 HpChanged 先到)
	var combat: ClientCombatStats = _combats.get(eid)
	if combat == null:
		combat = ClientCombatStats.new()
		combat.entity_id = eid
		_combats[eid] = combat
	combat.cur_hp = cur_hp

	# 通知渲染层:血量变了(血条更新 + 飘字)
	# 渲染层通过 damage==0 判断要不要播飘字
	hp_changed.emit(eid, cur_hp, damage, attacker_id, atk_id, atk_shape_idx)
	var hurt_pos: Vector2
	var attacker: ClientEntityInfo = _entities.get(attacker_id)
	var entity: ClientEntityInfo = _entities.get(eid)
	if entity == null:
		return
	if attacker != null:
		hurt_pos = AttackCalc.calc_hit_position(
			Vector2(attacker.x, attacker.y), attacker.facing,
			atk_id, atk_shape_idx,
			Vector2(entity.x, entity.y), null)
	else:
		hurt_pos = Vector2(entity.x, entity.y)
	if damage != 0:
		fire_damage_effect.emit(hurt_pos, atk_id, damage)  # 播伤害字(渲染层监听这个信号,在受击者位置播字)

func _on_entity_remove(data: Dictionary) -> void:
	## 收到 EntityRemove:某实体被移除了(或新玩家加入时服务端发来)
	## 从 _entities 表里移除该实体
	var eid: String = data.get("entity_id", "")
	if eid == "":
		return
	_entities.erase(eid)
	_combats.erase(eid)
	entity_removed.emit(eid)

func _on_entity_dead(data: Dictionary) -> void:
	## 收到 EntityDead:某实体死亡了(服务端算好死亡条件后发来)
	## 只改 state="dead",不移除实体(实体还在场景里,只是死了)
	var eid: String = data.get("entity_id", "")
	if eid == "":
		return
	var entity: ClientEntityInfo = _entities.get(eid)
	if entity == null:
		return
	entity.state = "dead"
	entity_updated.emit(entity)


## 收到 AiStateChanged:增量更新某实体 AI 状态
##
## 和 _on_player_facing 平行,但只改 ai_state 不改坐标/朝向。
## AI 状态(patrol/chase/attack/look_around)是独立维度,由服务端 EnemyAIMachine
## 状态切换时实时广播——客户端据此切换敌人视锥形态(normal/chase),不能等低频快照。
##
## 复用 entity_updated 信号通知渲染层(和 facing 同一信号链路):
##   - Role.on_entity_updated 里转发 ai_state 给 VisionFan
func _on_ai_state_changed(data: Dictionary) -> void:
	var eid: String = data.get("entity_id", "")
	if eid == "":
		return

	var entity: ClientEntityInfo = _entities.get(eid)
	if entity == null:
		# 镜像里没这个实体:忽略,等全量快照修正(和 _on_player_facing 一致的容错)
		return

	# 更新 AI 状态(只改 ai_state,不动 x/y/facing)
	entity.ai_state = data.get("ai_state", "idle")

	# 通知渲染层:这个实体变了(复用 entity_updated 信号)
	entity_updated.emit(entity)


func _on_map_info(data: Dictionary) -> void:
	## 收到 MapInfo:服务端下发的地图种子(新玩家加入时单播)
	## 不改 _entities / _combats(地图种子和实体状态无关),
	## 只发 map_info_received 信号通知渲染层(游戏场景)调 InfiniteTileMap.setup(seed)
	##
	## 为什么放 StateMirror 而不是放 MessageBus:
	##   StateMirror 是「客户端状态镜像」的统一入口,所有 S2C 状态消息都走这里,
	##   地图 seed 虽然不是实体状态,但也是「服务端权威下发」的状态(地图是什么样),
	##   放这里和 GameState/StatsInit 一致(都是服务端下发的初始状态)。
	##
	## 为什么不存到 StateMirror 的成员变量:
	##   当前没有其他代码需要读 seed(只有 InfiniteTileMap.setup 用)。
	##   如果未来需要(如小地图组件),再加 var _map_seed: int 存储。
	##   YAGNI,先只发信号。
	var seed: int = int(data.get("seed", 0))
	if seed == 0:
		push_warning("[StateMirror] MapInfo 收到 seed=0,可能是服务端没配 seed,跳过地图初始化")
		return
	map_info_received.emit(seed)

func _on_survival_state(data: Dictionary) -> void:
	# Run 状态是服务端快照；镜像只复制并发信号，不在客户端计算暂停、经验或等级。
	_survival_state = data.duplicate()
	survival_state_updated.emit(_survival_state.duplicate())

func _on_level_up_choices(data: Dictionary) -> void:
	# 奖励队列归服务端所有，客户端只展示当前玩家的可选项。
	_last_level_up_choices = data.duplicate()
	level_up_choices_received.emit(_last_level_up_choices.duplicate())

func _on_experience_orb(data: Dictionary) -> void:
	# 经验球事件用于表现层跟随；实际吸收和加经验由服务端确认。
	experience_orb_received.emit(data.duplicate())

func _on_survival_result(data: Dictionary) -> void:
	# 结算数据不可由客户端推导，直接转发服务端封存的最终统计。
	_last_survival_result = data.duplicate()
	survival_result_received.emit(_last_survival_result.duplicate())
