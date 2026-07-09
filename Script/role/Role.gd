extends Node2D
class_name Role

"""
文件: client/Script/role/Role.gd
作用: 通用实体容器——通过挂载不同组件复用为玩家/木桩/NPC 等

============================================================================
 设计思路（组件化 / ECS-lite）
============================================================================
Role 本身只是一个「位置容器」: 有坐标、能挂子节点。
它不知道自己是玩家还是木桩——「是什么」由挂载的组件决定。

组件分类:
    - Visual 组件: 负责显示（Sprite、动画等）
    - Controller 组件: 负责行为（本地玩家读输入、远程玩家读 StateMirror）

当前实现:
    - 本地玩家 → PlayerVisual + LocalPlayerController
    - 远程玩家 → PlayerVisual（只显示，不读输入）

后续扩展:
    - 木桩 → StakeVisual（被动受击）
    - NPC → NpcVisual + NpcController（AI 驱动）

============================================================================
 和服务器权威状态同步的关系
============================================================================
Role 的「坐标」不归自己管:
    - 本地玩家: LocalPlayerController 读输入 → 发 PlayerMove → 服务端 apply_move
                → 服务端广播 → StateMirror 更新 → player_updated 信号 → Role 更新坐标
                （注意: 本地玩家也走 StateMirror 更新，不直接本地改坐标——保证权威一致）
    - 远程玩家: StateMirror 收到 PlayerMove → player_updated 信号 → Role 更新坐标

所以 Role.position 永远是由 StateMirror 的信号驱动的，Role 自己不改自己的坐标。
这是「服务器权威」在客户端的最终体现: 连本地玩家的坐标都不自己算。
"""

# 这个 Role 对应的玩家ID
# 用它和 StateMirror.local_player_id() 对比，判断是本地玩家还是远程玩家
var player_id: String = ""


## 初始化 Role: 根据玩家信息决定挂什么组件
## 由 dead_man_scene 在创建/更新 Role 时调用
func setup(info: Dictionary) -> void:
	player_id = info.get("player_id", "")

	# 先更新坐标（setup 也可能携带最新坐标）
	_update_position(info)

	# 避免重复挂组件: 如果已经挂过同名组件，先移除
	# 这在 player_updated 信号重复触发时有用（虽然一般不会重复挂）
	_remove_component("PlayerVisual")
	_remove_component("LocalPlayerController")

	# 挂 PlayerVisual（所有玩家都要显示）
	var visual = preload("res://Script/role/PlayerVisual.gd").new()
	visual.name = "PlayerVisual"
	add_child(visual)
	# 调用组件的初始化（传入玩家信息，让它知道显示什么）
	visual.setup(info)

	# 判断是否本地玩家
	# 本地玩家额外挂 LocalPlayerController（读键盘输入发 PlayerMove）
	# 远程玩家不挂，它的坐标完全由 StateMirror 的 player_updated 信号驱动
	var local_pid = ClientStateMirror.instance().local_player_id()
	if player_id == local_pid and player_id != "":
		var controller = preload("res://Script/role/LocalPlayerController.gd").new()
		controller.name = "LocalPlayerController"
		add_child(controller)
		controller.setup(info)


## 收到 StateMirror 的 player_updated 信号时调用，更新坐标
func on_player_updated(info: Dictionary) -> void:
	_update_position(info)


## 更新坐标到 Role.position
func _update_position(info: Dictionary) -> void:
	var x: float = info.get("x", 0.0)
	var y: float = info.get("y", 0.0)
	position = Vector2(x, y)


## 移除指定名称的组件（如果存在）
func _remove_component(component_name: String) -> void:
	var node = get_node_or_null(component_name)
	if node != null:
		node.queue_free()
