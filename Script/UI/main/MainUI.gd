extends Node

var ddd_idx = 0
var delta_time = 0.0
var connect_time = 0.0

func _ready():
	SignalMgr.register_handler("websocket_connected", Callable(self, "_on_websocket_connected"))
	$Bg/E_Chat.pressed.connect(_on_click_chat)
	# 进入木桩测试场景的按钮
	$Bg/E_Game.pressed.connect(_on_click_game)
	# 进入无限地图调试场景的按钮
	# 无限地图当前是纯客户端独立场景（不需要 WebSocket），所以一开始就可见
	$Bg/E_Map.pressed.connect(_on_click_map)
	# 进入正式游戏场景的按钮(接入无限地图 + 玩家同步 + 战斗)
	$Bg/E_GameReal.pressed.connect(_on_click_game_real)
	# 进入地块选择/样式展示场景（TiledMap1）
	$Bg/E_Tilemap1.pressed.connect(_on_click_tilemap1)
	$Bg/E_Chat.visible = false
	$Bg/E_Game.visible = false
	$Bg/E_GameReal.visible = false

	# 返回大厅时 MainScene 会被重新实例化,WebSocket 是 autoload 跨场景存活
	# 所以这里要检查当前状态:已连就直接显示"已连接"+显示按钮,不用等信号
	# (信号 websocket_connected 只在首次连接时发一次,返回大厅时不会再发)
	if MyWebSocketClient.instance().is_connected_to_server():
		$Bg/E_WebScoketState.text = "已连接"
		$Bg/E_Chat.visible = true
		$Bg/E_Game.visible = true
		$Bg/E_GameReal.visible = true
		ddd_idx = 3  # 跳过"连接中..."动画

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
	$Bg/E_GameReal.visible = true


func _on_click_chat():
	# 进入聊天界面
	var target_scene = load("res://prefab/chat/ChatMain.tscn")
	var target_scene_instance = target_scene.instantiate()
	add_child(target_scene_instance)


func _on_click_game():
	# 进入木桩测试场景
	# 先发 PlayerJoin 让服务端创建实体,再切场景
	# 切场景前发消息:WebSocket 是异步的,消息会在切场景期间被服务端处理,
	# 切到 DeadManScene 时 _ready 会主动拉取 StateMirror 已有的镜像数据
	# 登录在 LoginScene 前置完成,这里做防御校验(正常流程必然已登录)
	var acc: Dictionary = AccountManager.instance().current_account()
	if acc.is_empty():
		push_warning("未登录，无法进入游戏（应先进登录场景）")
		return
	MessageBus.instance().send("game.PlayerJoin", {
		"entity_info": {
			"player_name": acc.get("name", ""),
			"account_id": acc.get("id", ""),
			"x": 0.0,
			"y": 0.0
		}
	})
	# 用 change_scene_to_file 真正切场景(替换当前场景树)
	# 原来用 add_child 叠加会导致 MainScene 按钮还能响应(背景场景仍存活)
	# call_deferred:确保消息发出后再切场景(避免切场景打断消息发送)
	get_tree().change_scene_to_file.call_deferred("res://Scene/DeadManScene.tscn")


func _on_click_game_real():
	# 进入正式游戏场景(接入无限地图)
	# 和木桩场景一样:先发 PlayerJoin,再切场景
	# GameScene 继承自 dead_man_scene,复用全部实体/战斗逻辑,额外接入 InfiniteTileMap
	# 登录在 LoginScene 前置完成,这里做防御校验(正常流程必然已登录)
	var acc: Dictionary = AccountManager.instance().current_account()
	if acc.is_empty():
		push_warning("未登录，无法进入游戏（应先进登录场景）")
		return
	MessageBus.instance().send("game.PlayerJoin", {
		"entity_info": {
			"player_name": acc.get("name", ""),
			"account_id": acc.get("id", ""),
			"x": 0.0,
			"y": 0.0
		}
	})
	get_tree().change_scene_to_file.call_deferred("res://Scene/GameScene.tscn")


func _on_click_map():
	# 进入无限地图调试场景
	# 当前是纯客户端独立场景：用 DebugCursor（箭头键控制）测试 chunk 动态加载/卸载
	# 不依赖 WebSocket，所以无需等待连接
	var target_scene = load("res://tiledmap/TiledMap.tscn")
	var target_scene_instance = target_scene.instantiate()
	add_child(target_scene_instance)


func _on_click_tilemap1():
	# 进入地块选择/样式展示场景（TiledMap1：选择地块 + 展示过渡形态）
	# 纯客户端独立场景，不依赖 WebSocket
	var target_scene = load("res://tiledmap/TiledMap1.tscn")
	var target_scene_instance = target_scene.instantiate()
	add_child(target_scene_instance)
	$Bg.hide()
