extends RefCounted
class_name ClientStateMirror

"""
文件: client/Script/Net/StateMirror.gd
作用: 客户端「只读」的游戏状态镜像

============================================================================
 为什么有这个文件（核心动机——和服务端 GameRoom 对照看）
============================================================================
服务端有 GameRoom（权威状态持有者），它有 add_player / apply_move 等方法——
    它是状态的「主人」，只有它能改状态。

客户端不能也搞一个能改状态的类，否则就成了「双端各写一份状态逻辑」，
    这正是我们最想避免的重复。客户端只能有一个「镜像」：
    服务端说什么，客户端就反映什么，绝不自己算。

所以 ClientStateMirror 的设计原则只有一条：
    【只接收、只镜像、只读暴露；绝不本地推演状态】

对比服务端 GameRoom：
    GameRoom.apply_move(pid, x, y)   ← 改状态（主人）
    ClientStateMirror._on_move(d)    ← 接收服务端广播，更新镜像（奴仆）
    两边方法名不同、职责不同、代码不重复。

============================================================================
 架构位置
============================================================================
    服务端 GameRoom（权威）
        ↓ bus.send 广播 GameState / PlayerJoin / PlayerMove / PlayerLeave
    网络（WebSocket bytes）
        ↓ MyWebSocketClient._dispatch_packet
    MessageBus.dispatch（反序列化 + 路由）
        ↓ onproto 注册的 handler
    ClientStateMirror._on_xxx(data)   ← 本文件：把服务端说的更新到本地镜像
        ↓ emit_signal 通知渲染层
    渲染层（dead_man_scene 等）读 mirror.all_players() 画角色

ClientStateMirror 自身不做任何网络 I/O（不调 bus.send），
    也不决定「该不该更新」——服务端说什么就更新什么。
    这种「无脑服从」是客户端镜像的正确姿态：权威在服务端，客户端不质疑。

============================================================================
 为什么用 RefCounted + 单例，而不是 Node / autoload
============================================================================
- 不需要进场景树：StateMirror 不参与 _process / _physics_process，
  纯数据容器 + 信号通知，用 RefCounted 更轻量
- 单例：全局只有一份状态镜像，任何场景（大厅、游戏场景）都看同一个
  实现：用 static var _instance，第一次访问时创建
- 不做 autoload：避免和 WebScoketMgr 的初始化顺序耦合
  （autoload 之间初始化顺序难控，StateMirror 依赖 MessageBus 已就绪，
   用懒加载更安全）
"""

# ---------------------------------------------------------------------------
# 信号：状态变化时通知渲染层
# ---------------------------------------------------------------------------
# Godot 的 signal 机制：emit_signal 时，所有 connect 到该信号的 Callable 会被调用。
# 渲染层（如 dead_man_scene）在 _ready 里 connect 这些信号，收到时刷新显示。

# 全量刷新信号：服务端发了 GameState 快照，本地镜像整体替换了。
# 渲染层收到后应「重新构建所有角色显示」。
# 参数：players（Array[Dictionary]），当前所有玩家信息
signal state_replaced(players: Array)

# 增量变化信号：单个玩家信息变了（加入/移动）。
# 渲染层收到后只需「更新这一个角色」，比全量刷新省。
# 参数：player_info（Dictionary），变化的玩家信息
signal player_updated(player_info: Dictionary)

# 玩家离开信号：某玩家离开了。
# 渲染层收到后「移除该角色的显示」。
# 参数：player_id（String），离开的玩家ID
signal player_removed(player_id: String)


# ---------------------------------------------------------------------------
# 单例
# ---------------------------------------------------------------------------
# 为什么用 static var 做单例而非 autoload：
#   见文件头说明。懒加载避免初始化顺序问题。
static var _instance: ClientStateMirror = null

static func instance() -> ClientStateMirror:
	if _instance == null:
		_instance = ClientStateMirror.new()
	return _instance


# ---------------------------------------------------------------------------
# 内部状态
# ---------------------------------------------------------------------------
# 玩家镜像表：player_id -> 玩家信息字典
# 和服务端 GameRoom._players 结构完全一致——这保证了镜像形状 = 权威形状。
# 不同点：服务端能改它（通过 apply_move 等），客户端只能整体替换/接收更新。
var _players: Dictionary = {}

# 本地玩家的 player_id（服务端在 PlayerJoin 响应里回传的）
# 渲染层用它区分「自己」和「别人」（比如自己的角色高亮显示）
# 为什么放这里而不是放某个场景脚本：玩家ID是跨场景的状态，放镜像里最合适
var _local_player_id: String = ""


# ---------------------------------------------------------------------------
# 只读访问（给渲染层用）
# ---------------------------------------------------------------------------

## 获取所有玩家信息（只读意图）。返回内部字典的 values，调用方不应修改。
func all_players() -> Array:
	return _players.values()

## 获取单个玩家信息。不存在则返回 null。
func get_player(player_id: String) -> Variant:
	return _players.get(player_id)

## 获取本地玩家ID
func local_player_id() -> String:
	return _local_player_id

## 当前镜像中的玩家数
func player_count() -> int:
	return _players.size()


# ---------------------------------------------------------------------------
# 状态更新（被 MessageBus handler 调用，不是给业务代码调的）
# ---------------------------------------------------------------------------
# 以下 _on_xxx 方法都以下划线开头，表示「内部方法」——
# 它们由 StateMirror 自己在 _register_handlers 里注册给 MessageBus，
# 业务代码不应直接调用它们，只应通过 bus 的正常分发流程触发。

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


## 收到 GameState 快照：整体替换本地镜像
##
## 这是「服务器权威」最纯粹的体现：
## 服务端发来一份完整状态，客户端不质疑、不合并、不增量，
## 直接用这份快照覆盖本地所有数据。
##
## 为什么敢直接覆盖：
##   服务端是唯一权威，它说的就是真相。客户端本地哪怕有缓存，
##   只要服务端发了快照，就以服务端为准——本地缓存可能过期了。
##
## 什么时候收到快照：
##   - 刚加入房间时（服务端发当前所有人状态给新玩家，见 web_server.on_player_join）
##   - 未来可加定时快照做「对账」（防止增量更新累积误差）
func _on_game_state(data: Dictionary) -> void:
	# 清空旧镜像，用快照重建
	# 为什么不 _players.clear() 后逐个 add：直接重建更清晰，且避免 clear 过程中
	# 渲染层读到半空状态的窗口期（信号在最后一次性发，中间状态不暴露）
	_players.clear()
	var players: Array = data.get("players", [])
	for p in players:
		var pid: String = p.get("player_id", "")
		if pid != "":
			# 这里也做 copy()，和服务端 snapshot() 对称：
			# 服务端发出的字典是浅拷贝，客户端收到后再存一份拷贝，
			# 保证本地修改（如果有的话）不会反向影响——虽然客户端本就不该改。
			_players[pid] = p.duplicate()

	# 通知渲染层：状态被整体替换了，请全量刷新
	state_replaced.emit(_players.values())


## 收到 PlayerJoin：增量添加一个玩家
##
## 注意：服务端在 on_player_join 里对「新玩家自己」发的是 GameState（全量），
##       对「其他已在线玩家」发的是 PlayerJoin（增量）。
## 所以这个 handler 主要处理「别人加入」的情况。
##
## 但有个细节：本地玩家的 player_id 是从 PlayerJoin 里提取的（见 _init 里
## MessageBus 的 _on_player_join）。这里也兼容——如果本地 _local_player_id
## 还没设置，且收到 PlayerJoin，尝试提取。
func _on_player_join(data: Dictionary) -> void:
	var player_info: Dictionary = data.get("player_info", {})
	var pid: String = player_info.get("player_id", "")
	if pid == "":
		return

	# 增量更新：直接覆盖该玩家条目
	# 为什么覆盖而非报错「已存在」：服务端可能重发 PlayerJoin（如断线重连），
	# 客户端镜像应宽容处理——以最新信息为准。这与服务端 GameRoom.add_player
	# 的「重复加入报错」相反：服务端要防 bug，客户端要容错。
	_players[pid] = player_info.duplicate()

	# 兼容本地玩家ID提取（见 MessageBus._on_player_join 的逻辑）
	# 这里不重复设置，只是兜底——正常情况下 MessageBus 已经设过了
	if _local_player_id == "":
		_local_player_id = pid

	# 通知渲染层：单个玩家更新了
	player_updated.emit(player_info)


## 收到 PlayerMove：增量更新某玩家坐标
##
## 这是「事件模型」的增量更新——服务端转发了某玩家的移动事件，
## 客户端据此更新本地镜像里该玩家的位置。
##
## 与 _on_game_state 的对比：
##   _on_game_state 是「全量快照」——服务端说「现在所有玩家是这样」
##   _on_player_move 是「增量事件」——服务端说「刚才某人移动了」
## 增量更新省流量，但累积误差风险（丢包会丢状态）——所以偶尔需要全量快照对账。
func _on_player_move(data: Dictionary) -> void:
	var pid: String = data.get("player_id", "")
	if pid == "":
		return

	var player: Variant = _players.get(pid)
	if player == null:
		# 镜像里没这个玩家：可能是 PlayerJoin 丢了或乱序。
		# 客户端容错策略：忽略这次移动，等全量快照来时自动修正。
		# 不主动请求服务端重发——保持客户端「无脑服从」的简单性。
		return

	# 更新坐标（只改这两个字段，不动其他）
	# 为什么不整体替换 player_info：PlayerMove 消息里只有 player_id/x/y/speed/moving，
	# 没有 player_name/level/score，整体替换会丢信息。
	player["x"] = data.get("x", 0.0)
	player["y"] = data.get("y", 0.0)

	# 动画状态:从 moving 字段推断 state
	# 服务端 apply_move 也是用 moving 推 state(moving=true→"run", false→"idle"),
	# 客户端这里做同样的映射,保证镜像 state 和服务端 PlayerInfo.state 一致。
	# 这不算"状态逻辑重复"——只是字段映射,真正的状态权威在服务端
	# (GameState 快照会带服务端的 state 字段,可对账)。
	var moving: bool = data.get("moving", false)
	player["state"] = "run" if moving else "idle"

	# 通知渲染层：这个玩家变了
	player_updated.emit(player)


## 收到 PlayerFacing：增量更新某玩家朝向
##
## 和 _on_player_move 平行,但只改 facing 不改坐标。
## 朝向和移动是独立状态维度——玩家可以一边移动一边朝任意方向攻击。
##
## 复用 player_updated 信号通知渲染层(不新增 player_facing_updated 信号):
##   - Role 已经监听 player_updated 做坐标更新,朝向更新走同一信号链路最简单
##   - Role.on_player_updated 里判断 facing 字段,变了就调 PlayerVisual.update_facing
##   - 信号越少,连接关系越简单
func _on_player_facing(data: Dictionary) -> void:
	var pid: String = data.get("player_id", "")
	if pid == "":
		return

	var player: Variant = _players.get(pid)
	if player == null:
		# 镜像里没这个玩家:忽略,等全量快照修正(和 _on_player_move 一致的容错)
		return

	# 更新朝向(只改 facing,不动 x/y)
	player["facing"] = data.get("facing", 0.0)

	# 通知渲染层:这个玩家变了(复用 player_updated 信号)
	player_updated.emit(player)


## 收到 PlayerLeave：移除某玩家
func _on_player_leave(data: Dictionary) -> void:
	var pid: String = data.get("player_id", "")
	if pid == "":
		return

	# 不存在也 erase，erase 对不存在的 key 是安全的（no-op）
	_players.erase(pid)

	# 通知渲染层：移除该角色显示
	player_removed.emit(pid)

func _on_heartbeat(_data: Dictionary) -> void:
	# 心跳消息，告知服务端还存活
	var mb: MessageBus = MessageBus.instance()
	mb.send("game.Heartbeat", {})
