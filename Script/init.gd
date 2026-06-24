extends Node2D

func _init():

	# 初始化 MessageBus 单例
	var mb = MessageBus.instance()
	var myws = MyWebSocketClient.instance()
	myws.connect_to_url("ws://localhost:8765")
	mb.set_websocket(myws._ws)
	register_gd_script_constants()
	print("MessageBus initialized: %s" % mb)

func register_gd_script_constants():
	var mb = MessageBus.instance()
	mb.register(preload("../Script/gdproto/game.gd").GameMessage, "game")
	# mb.register(preload("../gdproto/chat.gd"), "chat")

func _process(_delta):
	var state = MyWebSocketClient.instance().poll()
	set_process(state != WebSocketPeer.STATE_CLOSED)
