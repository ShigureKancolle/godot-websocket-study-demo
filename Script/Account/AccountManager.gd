extends RefCounted
class_name AccountManager

"""
文件: client/Script/Account/AccountManager.gd
作用: 本地用户存档(账号系统)

============================================================================
 设计
============================================================================
玩家只输入名字即可登录,账号 id(uuid)是底层细节,存在本地存档文件里:
    - 名字已存在  -> 加载已有账号(更新最近登录时间),作为用户存档继续使用
    - 名字不存在  -> 分配新账号 id 并保存新存档
主界面据此显示下拉框快捷登录(按最近登录时间排序,默认选中最近登录的)。

账号 id 由客户端本地生成并持久化。登录时随 PlayerJoin 发给服务端,
服务端优先用它作为 player_id——这样同一账号跨会话/跨重启 player_id 稳定,
服务端日志、未来的持久化都能识别"是同一个人"。

存档文件: user://player_accounts.json
  {
    "version": 1,
    "accounts": [
      { "name": "Alice", "id": "player:xxx-...", "last_login_time": 1750000000 },
      ...
    ]
  }

============================================================================
 为什么用 RefCounted + static var 单例
============================================================================
和 StateMirror / MessageContract 一致:纯数据容器 + 文件读写,不参与 _process,
不需要 autoload。懒加载(_instance 为 null 时才 new + _load),避免初始化顺序问题。
"""

# 存档文件路径(user:// 是 Godot 用户数据目录,跨运行保留)
const SAVE_PATH := "user://player_accounts.json"
const SAVE_VERSION := 1

static var _instance: AccountManager = null

# 所有账号(元素是 Dictionary: {name, id, last_login_time})
var _accounts: Array = []

# 当前登录的账号({name, id, last_login_time});未登录为空 Dictionary
var _current: Dictionary = {}


static func instance() -> AccountManager:
	if _instance == null:
		_instance = AccountManager.new()
		_instance._load()
	return _instance


# ---------------------------------------------------------------------------
# 存档读写
# ---------------------------------------------------------------------------

func _load() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return  # 无存档,首次运行
	var data: Variant = JSON.parse_string(file.get_as_text())
	if data is Dictionary:
		var accounts: Variant = data.get("accounts", [])
		if accounts is Array:
			_accounts = accounts


func _save() -> void:
	var data := {
		"version": SAVE_VERSION,
		"accounts": _accounts,
	}
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("无法写入存档: " + SAVE_PATH)
		return
	file.store_string(JSON.stringify(data, "\t"))


# ---------------------------------------------------------------------------
# 账号操作
# ---------------------------------------------------------------------------

## 登录:名字不存在 -> 分配新账号 id 并保存(is_new=true);
## 名字已存在 -> 加载已有账号(is_new=false)。返回 {name, id, last_login_time, is_new}
func login(name: String) -> Dictionary:
	var trimmed := name.strip_edges()
	if trimmed == "":
		push_warning("账号名为空,拒绝登录")
		return {}
	var account := _find_account(trimmed)
	if account.is_empty():
		account = {
			"name": trimmed,
			"id": _generate_id(),
			"last_login_time": int(Time.get_unix_time_from_system()),
		}
		_accounts.append(account)
		account["is_new"] = true
	else:
		account["last_login_time"] = int(Time.get_unix_time_from_system())
		account["is_new"] = false
	_current = account
	_save()
	return account


## 下拉框快捷登录:按名字找已有账号并更新最近登录时间(不新建)。
## 找不到返回空 Dictionary。玩家在下拉框里点选的都是已存在账号,所以走这里。
func quick_login(name: String) -> Dictionary:
	var trimmed := name.strip_edges()
	if trimmed == "":
		return {}
	var account := _find_account(trimmed)
	if account.is_empty():
		push_warning("快捷登录失败,存档中不存在账号: " + trimmed)
		return {}
	account["last_login_time"] = int(Time.get_unix_time_from_system())
	_current = account
	_save()
	return account


# ---------------------------------------------------------------------------
# 只读查询
# ---------------------------------------------------------------------------

## 按最近登录时间降序返回所有账号(最近登录的排最前),供下拉框用
func get_recent_accounts() -> Array:
	var sorted: Array = _accounts.duplicate()
	sorted.sort_custom(func(a, b): return a.get("last_login_time", 0) > b.get("last_login_time", 0))
	return sorted


## 当前登录账号 {name, id, last_login_time};未登录返回空 Dictionary
func current_account() -> Dictionary:
	return _current


## 当前登录账号 id;未登录返回 ""
func current_account_id() -> String:
	return _current.get("id", "")


## 当前登录名字;未登录返回 ""
func current_account_name() -> String:
	return _current.get("name", "")


func _find_account(name: String) -> Dictionary:
	for acc in _accounts:
		if acc.get("name", "") == name:
			return acc
	return {}


## 生成账号 id:带 "player:" 前缀(和服务端 entity_id 格式一致)
## 机器唯一 id + 微秒时间戳 + 随机数 组合,保证跨运行唯一
func _generate_id() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "player:%s-%d-%d" % [
		OS.get_unique_id(),
		Time.get_ticks_usec(),
		rng.randi_range(0, 2147483647),
	]
