'''
自动加载类  WebScoketMgr
'''

extends Node

var ws_path = "ws://127.0.0.1:8765"

func _init():
	_init_websocket()

func _register_gd_script_constants():
	var mb = MessageBus.instance()
	mb.register(preload("../gdproto/game.gd").GameMessage, "game")
	# mb.register(preload("../gdproto/chat.gd"), "chat")

func _process(_delta):
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
	print("MessageBus initialized: %s" % mb)
