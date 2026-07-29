extends RefCounted
class_name ClientStateMirror

"""
文件: client/Script/Net/StateMirror.gd
作用: 客户端「只读」的游戏状态镜像

============================================================================
 为什么有这个文件(核心动机——和服务端 GameRoom 对照看)
============================================================================
服务端有 GameRoom(权威状态持有者),它有 add_entity / apply_move 等方法——
    它是状态的「主人」,只有它能改状态。

客户端不能也搞一个能改状态的类,否则就成了「双端各写一份状态逻辑」,
    这正是我们最想避免的重复。客户端只能有一个「镜像」:
    服务端说什么,客户端就反映什么,绝不自己算。

所以 ClientStateMirror 的设计原则只有一条:
    【只接收、只镜像、只读暴露;绝不本地推演状态】

对比服务端 GameRoom:
    GameRoom.apply_move(eid, x, y)    ← 改状态(主人)
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
        ↓ bus.send 广播 GameState / PlayerJoin / PlayerMove / PlayerLeave
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

# 实体离开信号:某实体离开了(玩家断连;木桩不会走这个路径,被破坏时另议)。
# 渲染层收到后「移除该实体的显示」。
# 参数:entity_id(String),离开的实体ID
signal entity_removed(entity_id: String)


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
# 不同点:服务端能改它(通过 apply_move 等,存的是 EntityInfo dataclass),
#         客户端只能整体替换/接收更新(存的是 ClientEntityInfo RefCounted)。
# 强类型:不再存 Dictionary,所有字段访问走 ClientEntityInfo 的属性
var _entities: Dictionary = {}

# 本地玩家的 entity_id(服务端在 PlayerJoin 响应里回传的)
# 渲染层用它区分「自己」和「别人」(比如自己的角色高亮显示)
# 为什么放这里而不是放某个场景脚本:entity_id 是跨场景的状态,放镜像里最合适
var _local_entity_id: String = ""


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
	mb.onproto("game.PlayerJoin", _on_player_join)
	mb.onproto("game.PlayerMove", _on_player_move)
	mb.onproto("game.PlayerFacing", _on_player_facing)
	mb.onproto("game.PlayerLeave", _on_player_leave)
	mb.onproto("game.Heartbeat", _on_heartbeat)
	mb.onproto("game.AttackStart", _on_attack_start)
	mb.onproto("game.AttackEnd", _on_attack_end)
	mb.onproto("game.AttackHit", _on_attack_hit)
	mb.onproto("game.HurtEnd", _on_hurt_end) 


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


## 收到 PlayerJoin:增量添加一个实体(通常是玩家)
##
## 注意:服务端在 on_player_join 里对「新玩家自己」发的是 GameState(全量),
##       对「其他已在线实体」发的是 PlayerJoin(增量)。
## 所以这个 handler 主要处理「别人加入」的情况。
##
## 但有个细节:本地玩家的 entity_id 是从 PlayerJoin 里提取的(见 MessageBus._on_player_join)。
## 这里也兼容——如果本地 _local_entity_id 还没设置,且收到 PlayerJoin,尝试提取。
func _on_player_join(data: Dictionary) -> void:
	var entity_info: Dictionary = data.get("entity_info", {})
	var eid: String = entity_info.get("entity_id", "")
	if eid == "":
		return

	# 增量更新:直接覆盖该实体条目
	# 为什么覆盖而非报错「已存在」:服务端可能重发 PlayerJoin(如断线重连),
	# 客户端镜像应宽容处理——以最新信息为准。这与服务端 GameRoom.add_entity
	# 的「重复加入报错」相反:服务端要防 bug,客户端要容错。
	# dict→强类型转换:from_dict 集中处理字段名/类型
	var info := ClientEntityInfo.from_dict(entity_info)
	_entities[eid] = info

	# 兼容本地 entity_id 提取(见 MessageBus._on_player_join 的逻辑)
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
		# 镜像里没这个实体:可能是 PlayerJoin 丢了或乱序。
		# 客户端容错策略:忽略这次移动,等全量快照来时自动修正。
		# 不主动请求服务端重发——保持客户端「无脑服从」的简单性。
		return

	# 更新坐标(只改这两个字段,不动其他)
	# 为什么不整体替换 entity_info:PlayerMove 消息里只有 entity_id/x/y/speed/moving,
	# 没有 player_name 等字段,整体替换会丢信息。
	entity.x = data.get("x", 0.0)
	entity.y = data.get("y", 0.0)

	# 动画状态:从 moving 字段推断 state
	# 服务端 apply_move 也是用 moving 推 state(moving=true→"run", false→"idle"),
	# 客户端这里做同样的映射,保证镜像 state 和服务端 EntityInfo.state 一致。
	# 这不算"状态逻辑重复"——只是字段映射,真正的状态权威在服务端
	# (GameState 快照会带服务端的 state 字段,可对账)。
	var moving: bool = data.get("moving", false)
	entity.state = "run" if moving else "idle"

	# 通知渲染层:这个实体变了
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


## 收到 PlayerLeave:移除某实体
func _on_player_leave(data: Dictionary) -> void:
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
	##
	## 注意:attacker_id 是攻击者,不是被攻击者——
	## 客户端不需要在这里处理攻击者(攻击者的 state 由 AttackStart 设为 "attacking")
	## 只需要处理被命中者
	var hit_list: Array = data.get("hit_list", [])
	for hurt_id in hit_list:
		var entity: ClientEntityInfo = _entities.get(hurt_id)
		if entity == null:
			continue
		# 服务端 apply_hurt 设 state="hurt",客户端镜像同步
		entity.state = "hurt"
		entity_updated.emit(entity)

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
