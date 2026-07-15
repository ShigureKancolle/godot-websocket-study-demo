extends CanvasLayer

"""
文件: client/Script/UI/debug/DebugConsole.gd
作用: 客户端交互式调试控制台(游戏内浮层,` 键唤出)

============================================================================
 和服务端 console.py 的本质区别
============================================================================
服务端是 Python,有 code.InteractiveConsole,能执行任意表达式(真 REPL)。
GDScript 没有 eval,所以这里是「命令解析器」——
    输入 命令名 + 参数,匹配预定义命令执行,不是任意代码。
结构上更像游戏里的「作弊码控制台」。

============================================================================
 解耦设计(核心)
============================================================================
本脚本只「单向调用」现有单例:
    - ClientStateMirror.all_players() / local_player_id() 等只读方法
    - MessageBus.send() / list_messages() / list_handlers()
    - MessageContract.get_message() / is_loaded()
    - SignalMgr.fire_signal()
    - MyWebSocketClient 的连接状态
核心代码(Net/role/UI 主流程)完全不引用本脚本,改动为零。
是否启用由 DebugConsoleLoader autoload 根据 feature flag 决定。

三个文件都不用 class_name(避免 Godot 启动时全局索引预加载):
    - DebugConsoleLoader.gd 用 load() 加载本脚本
    - 本脚本用 load() 加载 DebugCommands.gd
    feature 关闭时 → loader queue_free → 三者都不加载,零开销

============================================================================
 命令系统
============================================================================
register_command(name, callable, desc, usage) 注册命令。
输入解析后,第一个 token 是命令名,其余作为 PackedStringArray 传给 callable。
callable 可以是 async(用 await 调用,支持发消息等异步操作)。
tokenize 支持引号包围的带空格参数(如 JSON 对象需用引号包住)。

============================================================================
 UI 结构
============================================================================
CanvasLayer (layer=100,确保在最顶层)
└── PanelContainer (半透明背景,占屏幕下方 ~45%)
    └── MarginContainer
        └── VBoxContainer
            ├── RichTextLabel (输出区,bbcode,自动滚动)
            └── LineEdit (输入区,回车执行,上下键翻历史)
"""

# 唤出键:反引号 ` (中文键盘左上角,和 ~ 同键)
# 用 _input 而非 _unhandled_input 监听:LineEdit 聚焦时会在 GUI 阶段消化 ` 字符,
# _unhandled_input 收不到。_input 在 GUI 之前触发,能稳定捕获。
const TOGGLE_KEY = KEY_QUOTELEFT

# CanvasLayer 层级:设很高,确保覆盖在所有游戏 UI 之上
const PANEL_LAYER = 100

# 命令表:name -> {callable, desc, usage}
var _commands: Dictionary = {}

# UI 节点(注意:_input 是方法名,LineEdit 成员改名为 _input_box 避免冲突)
var _output: RichTextLabel
var _input_box: LineEdit

# DebugCommands 实例,持有所有内置命令实现
var _commands_obj

# 输入历史(上下键翻看)
var _history: PackedStringArray = PackedStringArray()
var _history_idx: int = 0


func _ready() -> void:
	layer = PANEL_LAYER
	visible = false
	_build_ui()
	_register_builtin_commands()
	# 诊断:同时输出到 stdout,方便在编辑器 Output 面板看到
	print("[DebugConsole] _ready 完成, visible=", visible, ", layer=", layer)
	print("[DebugConsole] 按 ` 键(反引号,中文键盘左上角)切换显示")
	print_line("[color=#7fffff]调试控制台已就绪。输入 help 查看可用命令。[/color]")
	print_line("[color=#888888](按 ` 键隐藏/显示)[/color]")


# ---------------------------------------------------------------------------
# UI 构建
# ---------------------------------------------------------------------------
func _build_ui() -> void:
	# 半透明背景面板
	var panel := PanelContainer.new()
	panel.name = "ConsolePanel"
	panel.anchor_left = 0.0
	panel.anchor_top = 0.55
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 0
	panel.offset_top = 0
	panel.offset_right = 0
	panel.offset_bottom = 0
	# 半透明深色背景 + 蓝色边框,辨识度高
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.1, 0.88)
	sb.border_color = Color(0.3, 0.6, 1.0, 0.9)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	# 输出区
	_output = RichTextLabel.new()
	_output.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_output.bbcode_enabled = true
	_output.scroll_following = true
	_output.selection_enabled = true
	_output.context_menu_enabled = true
	vbox.add_child(_output)

	# 输入区
	_input_box = LineEdit.new()
	_input_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_box.placeholder_text = "输入命令 (help 查看可用命令)"
	_input_box.text_submitted.connect(_on_input_submitted)
	_input_box.gui_input.connect(_on_input_gui_input)
	vbox.add_child(_input_box)


# ---------------------------------------------------------------------------
# 命令注册
# ---------------------------------------------------------------------------
## 注册一个命令。callable 签名:func(args: PackedStringArray) -> void(可 async)
func register_command(cmd_name: String, callable: Callable, desc: String, usage: String) -> void:
	_commands[cmd_name] = {
		"callable": callable,
		"desc": desc,
		"usage": usage,
	}


func _register_builtin_commands() -> void:
	# 用 load 而非 preload:运行时加载,feature 关闭时连本脚本都不加载,更彻底解耦
	var DebugCommandsScript = load("res://Script/UI/debug/DebugCommands.gd")
	_commands_obj = DebugCommandsScript.new()
	_commands_obj.console = self

	register_command("help",     Callable(_commands_obj, "cmd_help"),     "列出所有命令",                 "help")
	register_command("clear",   Callable(_commands_obj, "cmd_clear"),     "清屏",                         "clear")
	register_command("state",   Callable(_commands_obj, "cmd_state"),    "查看镜像状态(所有玩家)",       "state")
	register_command("me",      Callable(_commands_obj, "cmd_me"),       "查看本地玩家ID和信息",         "me")
	register_command("count",   Callable(_commands_obj, "cmd_count"),    "查看镜像玩家数",               "count")
	register_command("ws",      Callable(_commands_obj, "cmd_ws"),        "查看 WebSocket 连接状态",      "ws")
	register_command("msg",     Callable(_commands_obj, "cmd_msg"),      "列出所有可发消息名",           "msg")
	register_command("bus",     Callable(_commands_obj, "cmd_bus"),      "列出已注册 handler",           "bus")
	register_command("contract", Callable(_commands_obj, "cmd_contract"), "查看契约(无参列全部,有参查单条)", "contract [short_name]")
	register_command("send",    Callable(_commands_obj, "cmd_send"),     "发任意 C2S 消息",              "send <name> <json>")
	register_command("signal",  Callable(_commands_obj, "cmd_signal"),  "触发信号(测 UI 反应)",        "signal <name> [json]")


# ---------------------------------------------------------------------------
# 输入处理
# ---------------------------------------------------------------------------
## 监听 ` 键切换显示/隐藏。用 _input(GUI 之前)确保 LineEdit 聚焦时也能捕获。
func _input(event: InputEvent) -> void:
	# 诊断:打印所有按键事件,确认 _input 是否被调用 + 看 ` 键的真实 keycode
	# (中文输入法可能拦截或改变 keycode)
	if event is InputEventKey and event.pressed and not event.echo:
		print("[DebugConsole] _input 收到按键: keycode=", event.keycode, " physical_keycode=", event.physical_keycode, " unicode=", event.unicode)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == TOGGLE_KEY:
			visible = not visible
			if visible:
				_input_box.grab_focus()
				# 清空可能因 ` 键被输入到 LineEdit 的字符
				_input_box.clear()
			get_viewport().set_input_as_handled()


## 输入框回车:执行命令
func _on_input_submitted(text: String) -> void:
	_input_box.clear()
	var stripped := text.strip_edges()
	if stripped == "":
		return
	# 记入历史
	_history.append(stripped)
	_history_idx = _history.size()
	# 回显输入(绿色)
	print_line("[color=#7fff7f]> %s[/color]" % stripped)
	await _execute(stripped)


## 输入框 GUI 输入:上下键翻历史
func _on_input_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	if event.keycode == KEY_UP:
		if _history.size() > 0 and _history_idx > 0:
			_history_idx -= 1
			_input_box.text = _history[_history_idx]
			_input_box.caret_column = _input_box.text.length()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_DOWN:
		if _history.size() > 0:
			if _history_idx < _history.size() - 1:
				_history_idx += 1
				_input_box.text = _history[_history_idx]
				_input_box.caret_column = _input_box.text.length()
			elif _history_idx < _history.size():
				_history_idx = _history.size()
				_input_box.clear()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# 命令执行
# ---------------------------------------------------------------------------
func _execute(line: String) -> void:
	var args := _tokenize(line)
	if args.is_empty():
		return
	var cmd_name: String = args[0]
	var rest := PackedStringArray()
	for i in range(1, args.size()):
		rest.append(args[i])
	if not _commands.has(cmd_name):
		print_line("[color=#ff7f7f]未知命令: %s  (输入 help 查看可用命令)[/color]" % cmd_name)
		return
	var entry: Dictionary = _commands[cmd_name]
	var callable: Callable = entry["callable"]
	await callable.call(rest)


## 简单 tokenizer:空格分隔,支持双引号/单引号包围的带空格参数
## 例:send PlayerMove '{"x":100, "y":200}' → ["send", "PlayerMove", '{"x":100, "y":200}']
func _tokenize(line: String) -> PackedStringArray:
	var tokens := PackedStringArray()
	var cur := ""
	var in_quote := false
	var quote_ch := ""
	for ch in line:
		if in_quote:
			if ch == quote_ch:
				in_quote = false
			else:
				cur += ch
		else:
			if ch == "\"" or ch == "'":
				in_quote = true
				quote_ch = ch
			elif ch == " " or ch == "\t":
				if cur != "":
					tokens.append(cur)
					cur = ""
			else:
				cur += ch
	if cur != "":
		tokens.append(cur)
	return tokens


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
## 向输出区追加一行(bbcode 支持)
func print_line(text: String) -> void:
	_output.append_text(text + "\n")
