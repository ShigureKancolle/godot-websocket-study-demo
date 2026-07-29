extends Node

var ddd_idx = 0
var delta_time = 0.0
var connect_time = 0.0

func _ready():
	SignalMgr.register_handler("websocket_connected", Callable(self, "_on_websocket_connected"))
	$Bg/E_Chat.pressed.connect(_on_click_chat)
	# 进入游戏场景（木桩场景）的按钮
	# 当前 dead_man_scene 只做玩家同步验证，后续会加木桩玩法
	$Bg/E_Game.pressed.connect(_on_click_game)
	# 进入无限地图调试场景的按钮
	# 无限地图当前是纯客户端独立场景（不需要 WebSocket），所以一开始就可见
	$Bg/E_Map.pressed.connect(_on_click_map)
	$Bg/E_Chat.visible = false
	$Bg/E_Game.visible = false

func _process(_delta):
	if ddd_idx < 3:
		connect_time += _delta
		delta_time += _delta
		if delta_time > 0.3:
			var ddd = [".", "..", "..."]
			$Bg/E_WebScoketState.text = "连接中" + ddd[ddd_idx]
			ddd_idx = (ddd_idx + 1) % 3
			delta_time = 0.0

		if connect_time > 30.0:
			$Bg/E_WebScoketState.text = "连接超时"
			ddd_idx = 3

func _on_websocket_connected(data: Dictionary):
	print("WebSocket 已连接: %s" % data)
	$Bg/E_WebScoketState.text = "已连接"
	ddd_idx = 3

	$Bg/E_Chat.visible = true
	$Bg/E_Game.visible = true


func _on_click_chat():
	# 进入聊天界面
	var target_scene = load("res://prefab/chat/ChatMain.tscn")
	var target_scene_instance = target_scene.instantiate()
	add_child(target_scene_instance)


func _on_click_game():
	# 进入游戏场景（木桩场景）
	# 和聊天界面一样用 instantiate 方式加到当前场景
	# dead_man_scene.gd 的 _ready 会自动连接 StateMirror 信号显示玩家
	var target_scene = load("res://Scene/DeadManScene.tscn")
	var target_scene_instance = target_scene.instantiate()
	add_child(target_scene_instance)


func _on_click_map():
	# 进入无限地图调试场景
	# 当前是纯客户端独立场景：用 DebugCursor（箭头键控制）测试 chunk 动态加载/卸载
	# 不依赖 WebSocket，所以无需等待连接
	var target_scene = load("res://tiledmap/TiledMap.tscn")
	var target_scene_instance = target_scene.instantiate()
	add_child(target_scene_instance)
	$Bg.hide()
