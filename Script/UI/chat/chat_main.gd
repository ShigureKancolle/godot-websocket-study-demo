extends Node

var data_array : Array[Dictionary] = []
var message_bus : MessageBus = null


func _ready() -> void:
	# 假设 $ScrollList 上挂了 ScorllDemo.gd
	var scroll_list = $Panel/ScrollList
	scroll_list.set_scroll_panel($Panel/ScrollList/ScrollContainer)          # 滚动面板
	scroll_list.set_scroll_item($Panel/ScrollList/ScrollItem)              # item 模板（Control）
	scroll_list.set_scroll_data_handler(_on_item_data)     # 设置数据的回调
	scroll_list.set_item_spacing(10.0)                      # 可选：间距
	$Control/Send.pressed.connect(_send_chat_message)
	$Control/E_Back.pressed.connect(_on_click_back)
	_register_msg_handler()

	# 回调签名：(item: Node, data: Dictionary)
func _on_item_data(item, data: Dictionary) -> void:
	item.get_node("Text").text = data.get("content", "")
	item.get_node("Name").text = data.get("player_name", "")

func _register_msg_handler() -> void:
	message_bus = MessageBus.instance()
	message_bus.onproto("game.ChatMessage", _on_chat_msg)

func _on_chat_msg(msg: Dictionary) -> void:
	data_array.append(msg)
	$Panel/ScrollList.refresh_scroll_panel(data_array)

func _send_chat_message() -> void:
	var text: String = $Control/Input.text
	var mb = MessageBus.instance()
	# ChatMessage 消息体的 player_id 字段名保留(proto 里就是 player_id,指代发送者ID)
	# 值用 ClientStateMirror.local_entity_id() 取(统一 Entity 模型后这是单一真相源)
	# MessageBus._player_id 仍保留作为兼容别名,但推荐用 mirror API
	mb.send("game.ChatMessage",
	{
		"content": text,
		"player_name": "测试名字",
		"player_id": ClientStateMirror.instance().local_entity_id(),
		"time": Time.get_unix_time_from_system()
	})

func _on_click_back() -> void:
	queue_free()
