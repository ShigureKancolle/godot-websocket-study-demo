extends Node2D
class_name PlayerVisual

"""
文件: client/Script/role/PlayerVisual.gd
作用: 玩家的视觉表现组件——负责显示角色

============================================================================
 为什么是组件而不是直接在 Role 里写显示逻辑
============================================================================
Role 是通用容器，它不该知道「玩家长什么样」——那是「玩家」这个类型的职责。
把显示逻辑抽成组件后:
    - 木桩挂 StakeVisual，不挂 PlayerVisual，各自管自己的显示
    - 显示逻辑变更（换贴图、加动画）只改这一个文件，Role 不受影响

组件用 Node2D 而非 RefCounted: 因为它要被 add_child 到 Role 上，
    且 Sprite2D 要作为它的子节点显示在场景树里。
"""

# 玩家ID，用于在头顶显示名字
var player_id: String = ""
# 玩家名字
var player_name: String = ""

# Sprite 节点引用
var _sprite: Sprite2D = null
# 名字标签引用
var _name_label: Label = null


## 初始化: 传入玩家信息字典，构建视觉表现
func setup(info: Dictionary) -> void:
	player_id = info.get("player_id", "")
	player_name = info.get("player_name", "?")

	# 判断是否本地玩家——本地用蓝色贴图，远程用棕色，便于区分
	# 这只是视觉区分，不影响逻辑（逻辑上本地/远程的区别在 Controller 组件）
	var local_pid = ClientStateMirror.instance().local_player_id()
	var is_local: bool = (player_id == local_pid and player_id != "")

	# 创建 Sprite
	# 用 prefab/CommonTexture 里的 buttonRound 贴图当占位角色
	# 本地玩家用蓝色 buttonRound_blue，远程用棕色 buttonRound_brown
	_sprite = Sprite2D.new()
	var tex_path = "res://prefab/CommonTexture/buttonRound_blue.png" if is_local \
		else "res://prefab/CommonTexture/buttonRound_brown.png"
	_sprite.texture = load(tex_path)
	add_child(_sprite)

	# 创建名字标签（显示在角色上方）
	_name_label = Label.new()
	_name_label.text = player_name
	_name_label.position = Vector2(-30, -50)  # 稍微偏上，让名字显示在角色头顶
	_name_label.add_theme_color_override("font_color", Color.BLACK)
	add_child(_name_label)

	# 如果是本地玩家，名字加个前缀「(你)」，更直观
	if is_local:
		_name_label.text = player_name + " (你)"
