extends RefCounted
class_name InputBinding

"""
文件: client/Script/role/input/InputBinding.gd
作用: 自定义键位映射 + 持久化

============================================================================
 设计思路
============================================================================
逻辑动作名(如 move_up) ↔ 物理键(如 KEY_W)的映射表。
    - 完全独立于 Godot InputMap——自己管一份映射表
    - 支持运行时改键(rebind)
    - 持久化到 user://input_binding.cfg,启动时自动加载

为什么不用 Godot InputMap:
    - InputMap 是 Godot 编辑器/全局概念,autoload 里改它有副作用
    - 用 InputMap 会让输入端绕过自己写的 InputBinding 层,破坏解耦
    - 自己管映射表,意图层抽象不破

============================================================================
 键位存储格式
============================================================================
_bindings: Dictionary
    key: 逻辑动作名(String, 如 "move_up")
    value: 绑定数组(Array[Dictionary]),每个绑定 = {"type": "key"|"mouse", "code": int}
    一个动作可绑多个绑定(如 WASD 和方向键双绑 = 两个 key 绑定)
    type="key": 键盘键,用 Input.is_key_pressed(code) 查询
    type="mouse": 鼠标键,用 Input.is_mouse_button_pressed(code) 查询
    未来加手柄:type="pad",用 Input.is_joy_button_pressed(code) 查询(类型化结构扩展不动)

cfg 文件格式:每行 "action:type:code,type:code"
    type 缩写:k=key, m=mouse(未来 p=pad)
    例:move_up:k:87,k:4194309   (WASD W + 方向键上)
    例:attack:m:1                (鼠标左键)

============================================================================
 持久化
============================================================================
存到 user://input_binding.cfg(Godot 用户配置路径,跨平台可写)
格式: 每行 "action:key1,key2"
    move_up:87,4194309
    move_down:83,4194306
    ...
"""

# 默认键位(WASD + 方向键双绑,attack 绑鼠标左键)
# 每个 binding 是 Dictionary: {"type": "key"|"mouse", "code": int}
# Godot 的 KEY_W / MOUSE_BUTTON_LEFT 等常量是 int,直接用
const DEFAULT_BINDINGS: Dictionary = {
	"move_up": [{"type": "key", "code": KEY_W}, {"type": "key", "code": KEY_UP}],
	"move_down": [{"type": "key", "code": KEY_S}, {"type": "key", "code": KEY_DOWN}],
	"move_left": [{"type": "key", "code": KEY_A}, {"type": "key", "code": KEY_LEFT}],
	"move_right": [{"type": "key", "code": KEY_D}, {"type": "key", "code": KEY_RIGHT}],
	"attack": [{"type": "mouse", "code": MOUSE_BUTTON_LEFT}]
}

# 配置文件路径(user:// 路径,Godot 自动映射到用户可写目录)
const CONFIG_PATH: String = "user://input_binding.cfg"

# 当前键位映射表: action -> Array[Dictionary](每个 Dictionary = {"type", "code"})
# static: 全局唯一一份,所有 device 共享
static var _bindings: Dictionary = {}

# 是否已加载过配置(避免重复加载)
static var _loaded: bool = false


## 获取指定动作的所有绑定(数组,每个元素是 {"type","code"} Dictionary)
## type="key": 键盘键; type="mouse": 鼠标键
static func get_bindings(action: String) -> Array:
	_ensure_loaded()
	return _bindings.get(action, [])


## 检查指定动作是否被按下(任意一个绑定触发即 true)
## 按 type 分发到对应 Input API:
##   key → Input.is_key_pressed
##   mouse → Input.is_mouse_button_pressed
## 未来 pad → Input.is_joy_button_pressed(在这里加 elif 分支即可)
static func is_action_pressed(action: String) -> bool:
	_ensure_loaded()
	var bindings: Array = _bindings.get(action, [])
	for b in bindings:
		var type: String = b["type"]
		var code: int = b["code"]
		if type == "key":
			if Input.is_key_pressed(code):
				return true
		elif type == "mouse":
			if Input.is_mouse_button_pressed(code):
				return true
	return false


## 运行时改键:把动作的 (old_type, old_code) 替换成 (new_type, new_code)
## 返回 True 表示成功;False 表示 old 绑定不存在
static func rebind(action: String, old_type: String, old_code: int, new_type: String, new_code: int) -> bool:
	_ensure_loaded()
	if not _bindings.has(action):
		return false
	var bindings: Array = _bindings[action]
	for i in range(bindings.size()):
		var b: Dictionary = bindings[i]
		if b["type"] == old_type and b["code"] == old_code:
			b["type"] = new_type
			b["code"] = new_code
			save()
			return true
	return false


## 给动作添加一个额外绑定(不替换原有绑定)
## 同一 (type, code) 不重复添加
static func add_binding(action: String, type: String, code: int) -> void:
	_ensure_loaded()
	if not _bindings.has(action):
		_bindings[action] = []
	for b in _bindings[action]:
		if b["type"] == type and b["code"] == code:
			return  # 已存在,不重复加
	_bindings[action].append({"type": type, "code": code})
	save()


## 移除动作上的某个绑定
## 如果动作清空了,恢复默认(避免动作完全失能)
static func remove_binding(action: String, type: String, code: int) -> void:
	_ensure_loaded()
	if not _bindings.has(action):
		return
	var bindings: Array = _bindings[action]
	for i in range(bindings.size()):
		if bindings[i]["type"] == type and bindings[i]["code"] == code:
			bindings.remove_at(i)
			break
	if bindings.is_empty() and DEFAULT_BINDINGS.has(action):
		_bindings[action] = DEFAULT_BINDINGS[action].duplicate(true)
	save()


## 持久化到配置文件
## 格式:每行 "action:type:code,type:code"(type 缩写 k/m)
static func save() -> void:
	var file = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		push_error("无法写入键位配置: " + CONFIG_PATH)
		return
	for action in _bindings:
		var bindings: Array = _bindings[action]
		var parts: Array = []
		for b in bindings:
			# type 缩写:仅 key/mouse 两种,三目够用;未来加 pad 时改 match
			var type_abbr: String = "k" if b["type"] == "key" else "m"
			parts.append(type_abbr + ":" + str(b["code"]))
		file.store_line(action + ":" + ",".join(parts))
	file.close()


## 从配置文件加载(如果文件不存在,用默认键位)
## 格式:每行 "action:type:code,type:code"(type 缩写 k/m)
## 老格式(action:code,code)无法解析会被静默丢弃——开发期不做迁移,用户重置一次即可
static func _load() -> void:
	_bindings = DEFAULT_BINDINGS.duplicate(true)  # 深拷贝,避免改到常量
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var file = FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if file == null:
		return
	while not file.eof_reached():
		var line: String = file.get_line()
		if line.strip_edges() == "":
			continue
		# 格式:action:type:code,type:code
		# 先按第一个 ":" 分出 action,剩下的是绑定列表
		# 用 find+substr 而非 split(":"):code 是 int 不含 ":",但 action 名理论上可能含 ":"
		# 当前 action 名都是 snake_case 不含 ":",但写法稳健点没坏处
		var first_colon: int = line.find(":")
		if first_colon == -1:
			continue
		var action: String = line.substr(0, first_colon)
		var rest: String = line.substr(first_colon + 1)
		if action == "" or rest == "":
			continue
		var binding_strs: PackedStringArray = rest.split(",")
		var bindings: Array = []
		for bs in binding_strs:
			# 每个 binding 格式 "type:code"(type 缩写 k/m)
			var tc: PackedStringArray = bs.split(":")
			if tc.size() != 2:
				continue
			var type_abbr: String = tc[0]
			var code_str: String = tc[1]
			var type_val: String
			match type_abbr:
				"k": type_val = "key"
				"m": type_val = "mouse"
				_: continue  # 未知类型,跳过(未来 p=pad 时在这里加)
			if not code_str.is_valid_int():
				continue
			bindings.append({"type": type_val, "code": int(code_str)})
		if not bindings.is_empty():
			_bindings[action] = bindings
	file.close()


## 确保已加载(懒加载,首次访问时触发)
static func _ensure_loaded() -> void:
	if not _loaded:
		_load()
		_loaded = true


## 强制重新加载(调试/测试用,如刚改了配置文件想立即生效)
static func reload() -> void:
	_loaded = false
	_ensure_loaded()
