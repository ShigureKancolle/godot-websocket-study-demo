extends Node

var ddd_idx = 0
var delta_time = 0.0

func _ready():
	SignalMgr.register_handler("websocket_connected", Callable(self, "_on_websocket_connected"))
	$Bg/E_Chat.pressed.connect(_on_click_chat)
	# 进入游戏场景（木桩场景）的按钮
	# 当前 dead_man_scene 只做玩家同步验证，后续会加木桩玩法
	$Bg/E_Game.pressed.connect(_on_click_game)

func _process(_delta):
	if ddd_idx < 3: 
		delta_time += _delta
		if delta_time > 0.3:
			var ddd = [".", "..", "..."]
			$Bg/E_WebScoketState.text = "连接中" + ddd[ddd_idx]
			ddd_idx = (ddd_idx + 1) % 3
			delta_time = 0.0

func _on_websocket_connected(data: Dictionary):
	print("WebSocket 已连接: %s" % data)
	$Bg/E_WebScoketState.text = "已连接"
	ddd_idx = 3
	
	
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
