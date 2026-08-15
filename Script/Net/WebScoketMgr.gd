'''
自动加载类  WebScoketMgr
'''

extends Node

var ws_path = "ws://127.0.0.1:8765"

# 是否已发送 Login（连接后/登录后自动补发）
var _login_sent: bool = false

# ---------------------------------------------------------------------------
# 网络延迟测量(Ping/Pong)
# ---------------------------------------------------------------------------
# 原理:客户端每 PING_INTERVAL_MS 发一次 game.Ping{t}(t=本地发送时刻ms),
#       服务端原样回 game.Pong{t},客户端 now - t 即一次往返延迟(RTT)。
# 作用:本地玩家移动软对账用——Role._reconcile_prediction 收到服务端广播时,
#       回溯 now-RTT 时刻自己预测的位置再与服务端坐标比较,抵消传输延迟。
# EMA 平滑(alpha=RTT_SMOOTH_ALPHA)抗单次抖动;首个 Pong 到达前用默认值(局域网经验 50ms)。
# 250ms 发一次 Ping:RTT 更新更频繁、收敛更快,对账回溯的时刻偏移更小。
# 旧值 1000ms:局域网 RTT 突变后要等 1s 才修正,期间回溯偏差大易误判脱节
const PING_INTERVAL_MS: int = 250
const RTT_SMOOTH_ALPHA: float = 0.2

# 当前估计的往返延迟(毫秒),已平滑。Role 对账时读它。
var _rtt_ms: float = 50.0
# 上次发 Ping 的时刻(ms),用于按 PING_INTERVAL_MS 节流
var _last_ping_ms: int = 0
# 是否开始 RTT 测量。默认关闭——服务端要求第一条消息必须是 Login,
# 一连接就发 Ping 会抢首消息被踢;玩家进入游戏场景后由 start_rtt_measurement 开启
var _rtt_active: bool = false

func _init():
	_init_websocket()

func _register_gd_script_constants():
	var mb = MessageBus.instance()
	mb.register(preload("../gdproto/game.gd").GameMessage, "game")
	# mb.register(preload("../gdproto/chat.gd"), "chat")

func _process(_delta):
	# 网络延迟探测:每 PING_INTERVAL_MS 发一次 Ping
	# 只在 WebSocket 已连接(STATE_OPEN)时发——未连接时 WebSocketPeer.send 会返回 FAILED 并刷错误日志
	# _rtt_active 控制:进入游戏场景前不发(避免抢 Login 首消息被服务端踢,见 start_rtt_measurement)
	var now: int = Time.get_ticks_msec()
	# 连接已建立但还没发过 Login 时，等登录完成后自动补发（启动时可能还没选账号）
	if not _login_sent and MyWebSocketClient.instance().is_connected_to_server():
		var acc: Dictionary = AccountManager.instance().current_account()
		if not acc.is_empty():
			_send_login(acc)

	if _rtt_active and now - _last_ping_ms >= PING_INTERVAL_MS:
		_last_ping_ms = now
		if MyWebSocketClient.instance().is_connected_to_server():
			MessageBus.instance().send("game.Ping", {"t": now})
		# 未连接:跳过本次发送(连上后下一个 1s 周期自然恢复,无需特殊处理)

	var state = MyWebSocketClient.instance().poll()
	if state == WebSocketPeer.STATE_CLOSED:
		# 不用 set_process(false) 停止轮询——
		# 后续要做断线重连,需要持续 poll 触发重连逻辑
		# 现在先只打印日志,重连功能留待后面实现
		# (原代码 set_process(false) 会让 WebSocket 永远无法恢复)
		pass

func _init_websocket():
	var mb = MessageBus.instance()
	var myws = MyWebSocketClient.instance()
	myws.connect_to_url(ws_path)
	mb.set_websocket(myws._ws)
	_register_gd_script_constants()
	# 加载消息契约（和服务端 message_contract.py 对称）
	# 在注册 handler 之前加载——这样 handler 注册时就能用契约做方向校验
	# 契约文件缺失时不影响运行（详见 MessageContract.gd 的 load 方法注释）
	MessageContract.instance().load()
	# 注册客户端状态镜像的处理器
	# 必须在 _register_gd_script_constants 之后调用——StateMirror.register_handlers
	# 依赖 MessageBus 已完成消息类型注册（_try_resolve 才能解析消息名）
	# 否则 onproto 会把 handler 暂存到 _pending_handlers，虽然也能工作，
	# 但显式顺序更清晰，避免依赖暂存机制的隐式行为
	ClientStateMirror.instance().register_handlers()
	# 注册 Pong 处理器(测量网络延迟)
	# 必须在 _register_gd_script_constants 之后——onproto 需要消息类型已注册才能解析
	MessageBus.instance().onproto("game.Pong", _on_pong)
	# 连接建立后自动发 Login，让客户端进入大厅（之后才能聊天/进房）
	SignalMgr.register_handler("websocket_connected", Callable(self, "_on_websocket_connected"))
	print("MessageBus initialized: %s" % mb)


## WebSocket 连上后自动发送 Login（建立服务器会话/进入大厅）
func _on_websocket_connected(_data: Dictionary) -> void:
	_login_sent = false
	var acc: Dictionary = AccountManager.instance().current_account()
	if not acc.is_empty():
		_send_login(acc)


func _send_login(acc: Dictionary) -> void:
	MessageBus.instance().send("game.Login", {
		"account_id": acc.get("id", ""),
		"player_name": acc.get("name", ""),
	})
	_login_sent = true


## 收到服务端回传的 Pong:算一次 RTT 并做 EMA 平滑
func _on_pong(data: Dictionary) -> void:
	var t: int = int(data.get("t", 0))
	if t == 0:
		return  # 无效时间戳(理论上不会发生),跳过
	var rtt: float = float(Time.get_ticks_msec() - t)
	if rtt < 0.0:
		return  # 时钟异常(如客户端重启后收到旧包),跳过
	# EMA 平滑:新样本占 20%,抗网络抖动造成的单次异常值
	_rtt_ms = lerpf(_rtt_ms, rtt, RTT_SMOOTH_ALPHA)

## 当前估计的往返延迟(毫秒)。供 Role 对账外推使用。
func get_rtt_ms() -> float:
	return _rtt_ms


## 开始 RTT 测量(进入游戏场景后由场景 _ready 调用)
## 为什么不在连接成功时就开始:服务端校验「第一条消息必须是 Login」,
## 一连接就发 Ping 会抢首消息被踢;进游戏时 EnterRoom 已发出,此时再测 RTT 安全,
## 且 RTT 也只在本地玩家移动对账时才真正需要。
func start_rtt_measurement() -> void:
	_rtt_active = true
