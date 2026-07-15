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
    value: 物理键数组(Array[int], 如 [KEY_W, KEY_UP])
    一个动作可绑多个键(如 WASD 和方向键双绑)

============================================================================
 持久化
============================================================================
存到 user://input_binding.cfg(Godot 用户配置路径,跨平台可写)
格式: 每行 "action:key1,key2"
    move_up:87,4194309
    move_down:83,4194306
    ...
"""

# 默认键位(WASD + 方向键双绑)
# Godot 的 KEY_W 等常量是 int,直接用
const DEFAULT_BINDINGS: Dictionary = {
	"move_up": [KEY_W, KEY_UP],
	"move_down": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
}

# 配置文件路径(user:// 路径,Godot 自动映射到用户可写目录)
const CONFIG_PATH: String = "user://input_binding.cfg"

# 当前键位映射表: action -> Array[int]
# static: 全局唯一一份,所有 device 共享
static var _bindings: Dictionary = {}

# 是否已加载过配置(避免重复加载)
static var _loaded: bool = false


## 获取指定动作绑定的所有物理键(数组,可能为空)
static func get_keys(action: String) -> Array:
	_ensure_loaded()
	return _bindings.get(action, [])


## 检查指定动作的某个键是否被按下(用 Input.is_key_pressed)
## 任意一个绑定键被按下即返回 true
static func is_action_pressed(action: String) -> bool:
	_ensure_loaded()
	var keys: Array = _bindings.get(action, [])
	for key in keys:
		if Input.is_key_pressed(key):
			return true
	return false


## 运行时改键:把动作的 old_key 替换成 new_key
## 返回 True 表示成功;False 表示 old_key 没绑在该动作上
static func rebind(action: String, old_key: int, new_key: int) -> bool:
	_ensure_loaded()
	if not _bindings.has(action):
		return false
	var keys: Array = _bindings[action]
	var idx: int = keys.find(old_key)
	if idx == -1:
		return false
	keys[idx] = new_key
	save()
	return true


## 给动作添加一个额外绑定键(不替换原有键)
static func add_binding(action: String, key: int) -> void:
	_ensure_loaded()
	if not _bindings.has(action):
		_bindings[action] = []
	if key not in _bindings[action]:
		_bindings[action].append(key)
		save()


## 移除动作上的某个绑定键
## 如果动作只剩 0 个键,恢复默认(避免动作完全失能)
static func remove_binding(action: String, key: int) -> void:
	_ensure_loaded()
	if not _bindings.has(action):
		return
	_bindings[action].erase(key)
	if _bindings[action].is_empty() and DEFAULT_BINDINGS.has(action):
		_bindings[action] = DEFAULT_BINDINGS[action].duplicate()
	save()


## 持久化到配置文件
static func save() -> void:
	var file = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		push_error("无法写入键位配置: " + CONFIG_PATH)
		return
	for action in _bindings:
		var keys: Array = _bindings[action]
		var key_strs: Array = []
		for k in keys:
			key_strs.append(str(k))
		file.store_line(action + ":" + ",".join(key_strs))
	file.close()


## 从配置文件加载(如果文件不存在,用默认键位)
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
		var parts: PackedStringArray = line.split(":")
		if parts.size() != 2:
			continue
		var action: String = parts[0]
		var key_strs: PackedStringArray = parts[1].split(",")
		var keys: Array = []
		for ks in key_strs:
			if ks.is_valid_int():
				keys.append(int(ks))
		if action != "" and not keys.is_empty():
			_bindings[action] = keys
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
