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
			MessageBus.instance().send("game.PlayerJoin", {
				"player_info": {
					"player_name": "测试名字",
					"level": 1,
					"score": 0,
					"x": 0.0,
					"y": 0.0
				}
			})
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
		print("WebSocket 已关闭，代码：%d，原因 %s。干净得体：%s" % [code, reason, code != -1])

	return state

func _dispatch_packet(packet: PackedByteArray):
	MessageBus.instance().dispatch(packet)
