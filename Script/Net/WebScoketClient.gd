extends RefCounted
class_name MyWebSocketClient

static var _instance: MyWebSocketClient = null

static var _ws: WebSocketPeer = null

var _is_connected: bool = false

func _init():
	pass

static func instance() -> MyWebSocketClient:
	if _instance == null:
		_instance = MyWebSocketClient.new()
	return _instance

func connect_to_url(url: String):
	_ws = WebSocketPeer.new()
	print("连接服务器: %s" % url)
	_ws.connect_to_url(url)

## 当前是否已连上(供 UI 层查询,避免 MainScene 重建后状态显示错误)
func is_connected_to_server() -> bool:
	return _is_connected and _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN
	
func poll() -> WebSocketPeer.State:
	_ws.poll()
	var state = _ws.get_ready_state()
	if state == WebSocketPeer.STATE_CONNECTING:
		# 没连上 等10秒还连不上就退出
		pass

	elif state == WebSocketPeer.STATE_OPEN:
		if not _is_connected:
			print("连接成功")
			_is_connected = true
			# PlayerJoin 不在这里自动发——改为用户点击「开始游戏」时发
			# 原因:自动发会导致一开游戏就进游戏流程,没有大厅停留
			# 且 DeadManScene 还没实例化时 StatsInit 信号无人接收,造成时序问题
			SignalMgr.fire_signal("websocket_connected", {"message": "WebSocket 已连接"})
		while _ws.get_available_packet_count():
			var packet = _ws.get_packet()
			# print("数据包：", packet)
			# 处理数据包
			_dispatch_packet(packet)
			
		
	elif state == WebSocketPeer.STATE_CLOSING:
		# 继续轮询才能正确关闭。
		pass
	elif state == WebSocketPeer.STATE_CLOSED:
		var code = _ws.get_close_code()
		var reason = _ws.get_close_reason()
		print("WebSocket 已关闭。 code: %d, reason: %s. code != -1: %s" % [code, reason, code != -1])

	return state

func _dispatch_packet(packet: PackedByteArray):
	MessageBus.instance().dispatch(packet)
