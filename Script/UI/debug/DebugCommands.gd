extends RefCounted

"""
文件: client/Script/UI/debug/DebugCommands.gd
作用: 调试控制台的内置命令实现

============================================================================
 设计
============================================================================
每个 cmd_xxx 方法签名统一:func cmd_xxx(args: PackedStringArray) -> void
    - args 是命令名之后的参数(token 数组)
    - 可 async(用 await 调用 MessageBus.send 等)
    - 通过 console.print_line 输出结果

本文件只「单向调用」现有单例,不修改核心代码:
    - ClientStateMirror(只读:all_entities/local_entity_id/entity_count/get_entity)
    - MessageBus(send / list_messages / list_handlers)
    - MessageContract(get_message / is_loaded / is_valid_outbound)
    - SignalMgr(fire_signal)
    - MyWebSocketClient(连接状态)

命令分两类:
    - 查看类(只读):help/clear/state/me/count/ws/msg/bus/contract
    - 动作类(会改变状态或发网络消息):send/signal
"""

# 控制台引用(由 DebugConsole._register_builtin_commands 注入)
var console

# WebSocket 状态名映射(供 cmd_ws 用)
const _WS_STATE_NAMES = {
	WebSocketPeer.STATE_CONNECTING: "CONNECTING(连接中)",
	WebSocketPeer.STATE_OPEN: "OPEN(已连接)",
	WebSocketPeer.STATE_CLOSING: "CLOSING(关闭中)",
	WebSocketPeer.STATE_CLOSED: "CLOSED(已关闭)",
}


# ---------------------------------------------------------------------------
# 元命令
# ---------------------------------------------------------------------------
func cmd_help(_args: PackedStringArray) -> void:
	console.print_line("[color=#ffff7f]可用命令:[/color]")
	# 按命令名排序输出
	# .keys() 返回 Array 但无类型 Dictionary 推导不出,显式声明 Array
	var names: Array = console._commands.keys()
	names.sort()
	for name in names:
		var entry: Dictionary = console._commands[name]
		console.print_line("  [color=#7fffff]%-22s[/color] - %s" % [entry["usage"], entry["desc"]])


func cmd_clear(_args: PackedStringArray) -> void:
	console._output.clear()


# ---------------------------------------------------------------------------
# 查看类命令(只读)
# ---------------------------------------------------------------------------
func cmd_state(_args: PackedStringArray) -> void:
	var mirror = ClientStateMirror.instance()
	var entities = mirror.all_entities()
	console.print_line("[color=#ffff7f]镜像状态 (实体数: %d):[/color]" % entities.size())
	for e in entities:
		console.print_line("  %s" % str(e))


func cmd_me(_args: PackedStringArray) -> void:
	var mirror = ClientStateMirror.instance()
	var eid := mirror.local_entity_id()
	if eid == "":
		console.print_line("[color=#ff7f7f]本地玩家 entity_id 未设置(可能还没收到 PlayerJoin 响应)[/color]")
		return
	console.print_line("本地玩家 entity_id: %s" % eid)
	var e = mirror.get_entity(eid)
	if e != null:
		console.print_line("  信息: %s" % str(e))


func cmd_count(_args: PackedStringArray) -> void:
	var mirror = ClientStateMirror.instance()
	console.print_line("镜像实体数: %d" % mirror.entity_count())


func cmd_ws(_args: PackedStringArray) -> void:
	# _ws 是 static var,直接通过类名访问;未连接时为 null
	var ws = MyWebSocketClient._ws
	if ws == null:
		console.print_line("[color=#ff7f7f]WebSocket 未初始化(未调用 connect_to_url)[/color]")
		return
	var state = ws.get_ready_state()
	# .get() 返回 Variant,无法直接赋给 String,用 str() 转一下稳妥
	var state_name: String = str(_WS_STATE_NAMES.get(state, "UNKNOWN(%d)" % state))
	console.print_line("WebSocket 状态: %s" % state_name)
	# _is_connected 是实例变量,通过 instance 访问
	var wsc = MyWebSocketClient.instance()
	console.print_line("  _is_connected: %s" % str(wsc._is_connected))


func cmd_msg(_args: PackedStringArray) -> void:
	var bus = MessageBus.instance()
	var msgs = bus.list_messages()
	console.print_line("[color=#ffff7f]已注册消息 (%d):[/color]" % msgs.size())
	# 按名排序方便查找
	var names: Array = msgs.keys()
	names.sort()
	for name in names:
		console.print_line("  %s" % name)


func cmd_bus(_args: PackedStringArray) -> void:
	var bus = MessageBus.instance()
	var handlers = bus.list_handlers()
	console.print_line("[color=#ffff7f]已注册 handler (%d):[/color]" % handlers.size())
	var names: Array = handlers.keys()
	names.sort()
	for name in names:
		console.print_line("  %s" % name)


func cmd_contract(args: PackedStringArray) -> void:
	var c = MessageContract.instance()
	if not c.is_loaded():
		console.print_line("[color=#ff7f7f]契约未加载(运行不依赖契约,但查看功能不可用)[/color]")
		return
	# 有参数:查询单条消息契约
	if args.size() >= 1:
		var short_name := args[0]
		var info = c.get_message(short_name)
		if info == null:
			console.print_line("[color=#ff7f7f]消息 %s 未在契约中登记[/color]" % short_name)
		else:
			console.print_line("%s: %s" % [short_name, str(info)])
		return
	# 无参数:列出所有契约(按名排序)
	var names: Array = c._messages.keys()
	names.sort()
	for name in names:
		console.print_line("  %s: %s" % [name, str(c._messages[name])])
	console.print_line("[color=#ffff7f]契约共 %d 条[/color]" % names.size())


# ---------------------------------------------------------------------------
# 动作类命令(会改变状态/发网络消息)
# ---------------------------------------------------------------------------
func cmd_send(args: PackedStringArray) -> void:
	if args.size() < 2:
		console.print_line("[color=#ff7f7f]用法: send <name> <json>[/color]")
		console.print_line("例: send PlayerMove '{\"entity_id\":\"player:xxx\",\"x\":100,\"y\":200}'")
		return
	var name := args[0]
	var json_str := args[1]
	var json := JSON.new()
	var err := json.parse(json_str)
	if err != OK:
		console.print_line("[color=#ff7f7f]JSON 解析失败 (行 %d): %s[/color]" % [json.get_error_line(), json.get_error_message()])
		return
	var data = json.data
	if not data is Dictionary:
		console.print_line("[color=#ff7f7f]参数必须是 JSON 对象,如 {\"x\":100}[/color]")
		return
	# 出站方向校验(告警但不阻止,和 MessageContract 的设计一致)
	var c = MessageContract.instance()
	if c.is_loaded() and not c.is_valid_outbound(name):
		console.print_line("[color=#ff7f7f]警告: 消息 %s 出站方向校验未通过,仍尝试发送[/color]" % name)
	var bus = MessageBus.instance()
	await bus.send(name, data)
	console.print_line("[color=#7fff7f]已发送 %s: %s[/color]" % [name, str(data)])


func cmd_signal(args: PackedStringArray) -> void:
	if args.size() < 1:
		console.print_line("[color=#ff7f7f]用法: signal <name> [json][/color]")
		console.print_line("例: signal websocket_connected {\"message\":\"测试\"}")
		return
	var name := args[0]
	var data := {}
	if args.size() >= 2:
		var json := JSON.new()
		if json.parse(args[1]) == OK and json.data is Dictionary:
			data = json.data
		else:
			console.print_line("[color=#ff7f7f]JSON 参数解析失败,用空字典触发[/color]")
	SignalMgr.fire_signal(name, data)
	console.print_line("[color=#7fff7f]已触发信号 %s: %s[/color]" % [name, str(data)])
