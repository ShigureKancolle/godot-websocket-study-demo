extends Object
class_name MessageBus

# 基础常量来源（任何 proto .gd 都行，取 game.gd）
const game_pb = preload("../gdproto/game.gd")

# proto 生成代码目录（相对当前脚本的路径）
const _PROTO_DIR_REL = "../gdproto"

# 消息上下文：携带连接相关信息
class MessageContext:
	extends RefCounted
	var websocket
	var player_id: String = ""
	var is_server: bool = false

	func _init(ws = null, pid: String = "", server: bool = false):
		websocket = ws
		player_id = pid
		is_server = server

	func _to_string() -> String:
		return "MessageContext(player_id=%s, is_server=%s)" % [player_id, is_server]

# 单例
static var _instance: MessageBus = null
static var _handlers: Dictionary = {}
# full_name -> {script, field_name, gm_class, package}
static var _registry: Dictionary = {}
# (package + "." + field_name) -> full_name（接收时反查）
static var _field_to_name: Dictionary = {}
# 短名 -> [全名列表]
static var _short_to_full: Dictionary = {}
# 所有已加载的 GameMessage 类：[{class, package}]
static var _gm_classes: Array = []
static var _websocket = null
static var _initialized: bool = false
# 尚未注册的消息处理器：protoname -> handler，register() 后再绑定
static var _pending_handlers: Dictionary = {}

static var _player_id: String = ""

static func instance() -> MessageBus:
	if _instance == null:
		_instance = MessageBus.new()
	return _instance

func _init():
	if not MessageBus._initialized:
		MessageBus._initialized = true
		_auto_register()
		onproto("game.EnterRoom", _on_enter_room)

# 收到 EnterRoom 广播时,把服务端分配的 entity_id 提取出来,存到 ClientStateMirror
# 的 _local_entity_id(渲染层用这个区分本地玩家 vs 远程玩家)
#
# 字段从 entity_info.entity_id 取(统一 Entity 模型后,proto 用 EntityInfo 替代 PlayerInfo):
#   - 之前是 msg["player_info"]["player_id"]
#   - 现在是 msg["entity_info"]["entity_id"]
#
# _player_id 静态变量保留作为兼容别名(部分老代码如 chat_main 仍引用),
# 但推荐用 ClientStateMirror.local_entity_id() 访问——那里是「单一真相源」
static func _on_enter_room(msg: Dictionary):
	var entity_info: Dictionary = msg.get("entity_info", {})
	var eid: String = entity_info.get("entity_id", "")
	if eid == "":
		return
	MessageBus._player_id = eid
	ClientStateMirror.instance()._local_entity_id = eid

# snake_case -> PascalCase（enter_room -> EnterRoom）
static func _snake_to_pascal(s: String) -> String:
	var result := ""
	var cap := true
	for ch in s:
		if ch == "_":
			cap = true
		elif cap:
			result += ch.to_upper()
			cap = false
		else:
			result += ch
	return result

# 尝试从已加载脚本中取出内部类（依赖 get_script_constant_list，部分 Godot 版本可能没有）
static func _get_inner_class(script: GDScript, class_name_str: String):
	if not script.has_method("get_script_constant_list"):
		return null
	for c in script.get_script_constant_list():
		if c is Dictionary and c.get("name", "") == class_name_str:
			return c.get("value")
	return null

# 自动扫描 gdproto 目录下所有 .gd 文件，尽力注册其中的 GameMessage
# 注意：依赖 get_script_constant_list，老版本 Godot 可能扫描不到，此时用 register() 手动注册
func _auto_register() -> void:
	var base_dir: String = get_script().resource_path.get_base_dir()
	var proto_dir: String = base_dir.path_join(_PROTO_DIR_REL).simplify_path()
	var dir = DirAccess.open(proto_dir)
	if dir == null:
		push_error("无法打开 proto 目录: " + proto_dir)
		return
	dir.list_dir_begin()
	var file: String = dir.get_next()
	var found: bool = false
	while file != "":
		if file.ends_with(".gd") and not file.ends_with(".uid"):
			var path: String = proto_dir + "/" + file
			var script = load(path)
			if script != null:
				var gm_class = _get_inner_class(script, "GameMessage")
				if gm_class != null:
					register(gm_class, file.get_basename())
					found = true
		file = dir.get_next()
	dir.list_dir_end()
	if not found:
		push_warning("自动扫描未注册任何 GameMessage（当前 Godot 版本可能不支持 get_script_constant_list），请手动调用 register()，例如：\n  MessageBus.instance().register(preload(\"../gdproto/game.gd\").GameMessage, \"game\")")

# 注册一个 GameMessage 内部类（gm_class）及其所属 package
# 推荐用法（编译期解析，100% 可靠）：
#   MessageBus.instance().register(preload("../gdproto/game.gd").GameMessage, "game")
func register(gm_class, package: String) -> void:
	MessageBus._gm_classes.append({"class": gm_class, "package": package})
	var game_msg = gm_class.new()
	for tag in game_msg.data:
		var service = game_msg.data[tag]
		var field = service.field
		var field_name: String = field.name
		var short_name := _snake_to_pascal(field_name)
		var full_name := package + "." + short_name
		MessageBus._registry[full_name] = {
			"field_name": field_name,
			"gm_class": gm_class,
			"package": package,
		}
		MessageBus._field_to_name[package + "." + field_name] = full_name
		if not MessageBus._short_to_full.has(short_name):
			MessageBus._short_to_full[short_name] = []
		MessageBus._short_to_full[short_name].append(full_name)
	_flush_pending_handlers()

# 解析消息名：支持全名 "game.ChatMessage" 和短名 "ChatMessage"（找不到时不报错，返回 ""）
func _try_resolve(name: String) -> String:
	if MessageBus._registry.has(name):
		return name
	if MessageBus._short_to_full.has(name):
		var full_names: Array = MessageBus._short_to_full[name]
		if full_names.size() == 1:
			return full_names[0]
	return ""

# 解析消息名：支持全名 "game.ChatMessage" 和短名 "ChatMessage"
func _resolve_name(name: String) -> String:
	var full_name := _try_resolve(name)
	if full_name != "":
		return full_name
	if MessageBus._short_to_full.has(name):
		var full_names: Array = MessageBus._short_to_full[name]
		push_error("消息名 '%s' 有歧义: %s，请用全名（package.MessageName）区分" % [name, full_names])
		return ""
	push_error("未知的消息类型: %s" % name)
	return ""

# 设置默认 websocket 连接（客户端用）
func set_websocket(ws) -> void:
	MessageBus._websocket = ws

# 注册消息处理器（替代 Python 的装饰器用法）
# 用法：bus.onproto("ChatMessage", on_chat)
# 可在 register() 之前调用：未注册的会暂存，待 register() 后自动绑定
func onproto(protoname: String, handler: Callable) -> void:
	var full_name := _try_resolve(protoname)
	if full_name == "":
		MessageBus._pending_handlers[protoname] = handler
		return
	MessageBus._handlers[full_name] = handler

# 把暂存的处理器绑定到已注册的消息上（register() 后调用）
func _flush_pending_handlers() -> void:
	if MessageBus._pending_handlers.is_empty():
		return
	var done: Array = []
	for protoname in MessageBus._pending_handlers:
		var full_name := _try_resolve(protoname)
		if full_name != "":
			MessageBus._handlers[full_name] = MessageBus._pending_handlers[protoname]
			done.append(protoname)
	for protoname in done:
		MessageBus._pending_handlers.erase(protoname)

# 字典 -> protobuf 消息对象（递归）
func _fill_message(msg, data: Dictionary) -> void:
	if data == null:
		return
	for key in data:
		var value = data[key]
		if msg.has_method("new_" + key):
			var sub = msg.call("new_" + key)
			_fill_message(sub, value)
		elif msg.has_method("add_" + key):
			for item in value:
				var element = msg.call("add_" + key)
				_fill_message(element, item)
		elif msg.has_method("set_" + key):
			msg.call("set_" + key, value)
		elif msg.has_method("get_" + key):
			var arr = msg.call("get_" + key)
			if value is Array:
				for item in value:
					arr.append(item)
			else:
				arr.append(value)

# protobuf 消息对象 -> 字典（递归）
func _message_to_dict(msg) -> Dictionary:
	var result := {}
	if msg == null:
		return result
	for tag in msg.data:
		var service = msg.data[tag]
		var field = service.field
		var name: String = field.name
		if field.type == game_pb.PB_DATA_TYPE.MESSAGE:
			if field.rule == game_pb.PB_RULE.REPEATED:
				if field.value == null or field.value.is_empty():
					continue
				var arr: Array = []
				for item in field.value:
					arr.append(_message_to_dict(item))
				result[name] = arr
			else:
				if field.value == null:
					continue
				result[name] = _message_to_dict(field.value)
		else:
			if field.rule == game_pb.PB_RULE.REPEATED:
				if field.value == null or field.value.is_empty():
					continue
				result[name] = field.value.duplicate()
			else:
				if field.value == null:
					continue
				result[name] = field.value
	return result

# 发送消息：字典 -> protobuf -> bytes -> 发送
func send(protoname: String, protodata: Dictionary = {}, websocket = null) -> void:
	var full_name := _resolve_name(protoname)
	if full_name == "":
		return
	var entry: Dictionary = MessageBus._registry[full_name]
	var gm_class = entry["gm_class"]
	var field_name: String = entry["field_name"]

	var game_msg = gm_class.new()
	var sub_msg = game_msg.call("new_" + field_name)
	_fill_message(sub_msg, protodata)

	var data: PackedByteArray = game_msg.to_bytes()

	var ws = websocket if websocket != null else MessageBus._websocket
	if ws == null:
		push_error("未设置 websocket 连接，请先调用 set_websocket 或传入 websocket 参数")
		return
	# 连接未就绪时跳过发送:WebSocketPeer.send 在 ready_state != OPEN 时会返回 FAILED 并刷 C++ 错误
	# 场景:UI 点击/定时器在连接建立前发包(如 CONNECTING 阶段点"开始游戏"、启动瞬间的 Ping)
	# 消息直接丢弃,连上后业务逻辑自然重发(用户再点一次 / 下一个周期)
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("WebSocket 未连接(ready_state=%s),跳过发送 %s" % [ws.get_ready_state(), full_name])
		return
	if "Attack" in full_name:
		print("发送消息C->S %s" % [full_name])
	await ws.send(data)

# 分发接收到的消息：bytes -> protobuf -> 字典 -> 调用 handler
# 遍历所有已注册的 GameMessage 类尝试解析，找到匹配的分发
func dispatch(data: PackedByteArray, ctx: MessageContext = null) -> bool:
	for entry in MessageBus._gm_classes:
		var gm_class = entry["class"]
		var package: String = entry["package"]
		var game_msg = gm_class.new()
		var err: int = game_msg.from_bytes(data)
		if err != game_pb.PB_ERR.NO_ERRORS:
			continue

		# 收集匹配的已填充字段（field_name 必须在该 package 的注册表里）
		var matched: Array = []
		for tag in game_msg.data:
			var service = game_msg.data[tag]
			if service.state != game_pb.PB_SERVICE_STATE.FILLED:
				continue
			var field_name: String = service.field.name
			print("package: ", package, "  field_name: ", field_name)
			if MessageBus._field_to_name.has(package + "." + field_name):
				matched.append(service)

		if matched.is_empty():
			continue  # 该 GameMessage 不匹配，尝试下一个

		for service in matched:
			var field_name: String = service.field.name
			var full_name: String = MessageBus._field_to_name[package + "." + field_name]
			var sub_msg = service.field.value
			var data_dict := _message_to_dict(sub_msg)

			if MessageBus._handlers.has(full_name):
				if "Attack" in full_name:
					print("接收消息S->C %s" % [full_name])
				var handler: Callable = MessageBus._handlers[full_name]
				if ctx != null:
					await handler.call(data_dict, ctx)
				else:
					await handler.call(data_dict)
			else:
				push_warning("未找到消息 %s 的处理器" % full_name)

		return true

	push_error("无法解析消息：没有匹配的 GameMessage")
	return false

# 获取所有已注册的处理器（调试用）
func list_handlers() -> Dictionary:
	return MessageBus._handlers.duplicate()

# 列出所有已注册的消息类型（调试用）
func list_messages() -> Dictionary:
	return MessageBus._registry.duplicate()
