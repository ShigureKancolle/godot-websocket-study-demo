extends Node

"""
文件: client/Script/UI/login/login_scene.gd
作用: 登录场景(独立预制体)——进入游戏先在此选择/输入名字,登录成功后才进入主界面

流程:
    init.tscn → LoginScene.tscn(本场景,选择名字) → MainScene.tscn(主界面)
玩家**只输入名字**登录:
    - 名字不存在 -> AccountManager.login 分配新账号 id 并存档
    - 名字已存在 -> 加载已有账号(更新最近登录时间)
    - 下拉框点选已存在账号 -> quick_login 快捷登录(不新建)
本场景是唯一入口:未选择名字(未登录)就无法进行任何其他操作,
登录成功(输入/选中名字)后才会跳转主界面。
"""

func _ready():
	# 下拉框:按最近登录时间排序,默认选中最近登录的一个并把名字填入输入框
	$Bg/LoginButton.pressed.connect(_on_login)
	$Bg/NameInput.text_submitted.connect(func(_text): _on_login())
	$Bg/RecentSelect.item_selected.connect(_on_recent_selected)
	var recent: Array = AccountManager.instance().get_recent_accounts()
	if recent.size() > 0:
		var last_name: String = recent[0].get("name", "")
		_refresh_recent_select(last_name)
		$Bg/NameInput.text = last_name


## 点「登录」或输入框回车:名字不存在则新建账号,存在则加载已有账号,然后进主界面
func _on_login() -> void:
	var acc: Dictionary = AccountManager.instance().login($Bg/NameInput.text)
	if acc.is_empty():
		$Bg/LoginState.text = "名字不能为空"
		return
	_refresh_recent_select(acc.get("name", ""))
	_apply_login_state(acc)
	# 登录成功才进入主界面
	get_tree().change_scene_to_file.call_deferred("res://prefab/main/MainScene.tscn")


## 下拉框快捷登录:点选的都是已存在账号,直接加载并更新最近登录时间,然后进主界面
func _on_recent_selected(index: int) -> void:
	var recent: Array = AccountManager.instance().get_recent_accounts()
	if index < 0 or index >= recent.size():
		return
	var acc_name: String = recent[index].get("name", "")
	$Bg/NameInput.text = acc_name
	var acc: Dictionary = AccountManager.instance().quick_login(acc_name)
	_apply_login_state(acc)
	get_tree().change_scene_to_file.call_deferred("res://prefab/main/MainScene.tscn")


## 刷新下拉框内容(按最近登录排序),并选中 selected_name(默认选最近登录的)
func _refresh_recent_select(selected_name: String = "") -> void:
	var select: OptionButton = $Bg/RecentSelect
	select.clear()
	var recent: Array = AccountManager.instance().get_recent_accounts()
	var sel_idx := -1
	for i in recent.size():
		var acc_name: String = recent[i].get("name", "")
		select.add_item(acc_name)
		if acc_name == selected_name:
			sel_idx = i
	if sel_idx >= 0:
		select.select(sel_idx)
	elif recent.size() > 0:
		select.select(0)


## 登录成功后更新提示文案(is_new: 新账号/老账号)
func _apply_login_state(acc: Dictionary) -> void:
	if acc.is_empty():
		return
	if acc.get("is_new", false):
		$Bg/LoginState.text = "已创建新账号，欢迎 %s" % acc.get("name", "")
	else:
		$Bg/LoginState.text = "欢迎回来，%s" % acc.get("name", "")
