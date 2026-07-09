'''
木桩场景
多个玩家进来打木桩

当前阶段: 只做玩家同步，木桩暂未实现
    - 接 ClientStateMirror 的信号，管理 Role 的创建/更新/删除
    - 本地玩家点击移动，远程玩家位置由服务端同步
'''

extends Node2D

# Role 预加载: 用 Role.gd 作为脚本创建 Role 实例
# Role.tscn 目前只是个空 Node，用 .tscn 还是 .new() + 脚本都行
# 这里用脚本 new() 的方式，避免依赖 .tscn 文件的配置
const RoleScript = preload("res://Script/role/Role.gd")

# 玩家节点表: player_id -> Role 实例
# 用来快速查找某个玩家对应的 Role，收到 player_updated 信号时更新它
var _roles: Dictionary = {}


func _ready() -> void:
	# 连接 StateMirror 的三个信号
	# 信号定义见 StateMirror.gd
	var mirror = ClientStateMirror.instance()
	mirror.state_replaced.connect(_on_state_replaced)
	mirror.player_updated.connect(_on_player_updated)
	mirror.player_removed.connect(_on_player_removed)

	# 如果 StateMirror 里已经有状态（比如进入场景前就收到了 GameState），
	# 主动用现有状态刷一次——否则要等下一次 state_replaced 才显示
	# 这种「进入场景时主动拉取一次」的写法很常见，避免信号漏接
	if mirror.player_count() > 0:
		_on_state_replaced(mirror.all_players())


# StateMirror.state_replaced 信号: 全量替换
# 服务端发 GameState 快照时触发，收到一份完整的玩家列表
func _on_state_replaced(players: Array) -> void:
	# 先清空所有现有 Role（因为要整体替换）
	for role in _roles.values():
		role.queue_free()
	_roles.clear()

	# 用快照重建所有 Role
	for info in players:
		_create_role(info)


# StateMirror.player_updated 信号: 单个玩家变化
# 可能是「新玩家加入」或「已有玩家移动」——两种情况统一处理:
#   - 不存在则创建
#   - 已存在则更新坐标
func _on_player_updated(info: Dictionary) -> void:
	var pid: String = info.get("player_id", "")
	if pid == "":
		return

	if _roles.has(pid):
		# 已存在: 更新坐标
		_roles[pid].on_player_updated(info)
	else:
		# 不存在: 创建新 Role
		_create_role(info)


# StateMirror.player_removed 信号: 玩家离开
func _on_player_removed(player_id: String) -> void:
	if _roles.has(player_id):
		_roles[player_id].queue_free()
		_roles.erase(player_id)


# 创建一个 Role 实例并加入场景
func _create_role(info: Dictionary) -> void:
	var role = RoleScript.new()
	role.setup(info)
	add_child(role)
	_roles[info.get("player_id", "")] = role
