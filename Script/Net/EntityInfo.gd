extends RefCounted
class_name ClientEntityInfo

"""
文件: client/Script/Net/EntityInfo.gd
作用: 客户端镜像实体信息(强类型),和服务端 EntityInfo dataclass 字段对齐

============================================================================
 为什么不用 Dictionary
============================================================================
之前 StateMirror._entities 存 Dictionary,字段was访问靠字符串 key(entity["state"]),
问题:
    - 字段名拼错运行时才报错,IDE 无法补全/检查
	- 类型不明确,entity["facing"] 是 float 还是 int 全sdsd靠记忆
	- 容易写出 entity["atk_id"] = ... 这种往字典塞非 EntityInfo 字段的代码

改用强类型 RefCounted:
    - 字段类型在编辑器/IDE 可见,拼错编译期报错
    - from_dict(d) 集中做 dict→强类型的转换,全工程只此一处写 .get()
    - 字段不可随意扩展:加字段必须改类定义,字段集合显式

============================================================================
 和服务端 EntityInfo 的关系
============================================================================
服务端是 Python dataclass(server/game/game_room.py),这里是 GDScript RefCounted。
字段对齐(服务端是权威,客户端镜像):
    - entity_id: String         (服务端 str)
	- entity_type: EntityType   (服务端 str "player"/"stake",客户端枚举)
    - x, y: float               (服务端 float)
    - facing: float             (服务端 float,弧度)
    - moving: bool              (服务端当前移动标志,供 Role 停止/预测对账)
    - state: String             (服务端 str: idle/run/attacking/hurt)
    - player_name: String       (服务端 str)
    - atk_id: int               (非 EntityInfo proto 字段,攻击消息携带,客户端临时存)

============================================================================
 EntityType 枚举
============================================================================
服务端 entity_type 是字符串("player"/"stake")。客户端用枚举更安全:
    - 比较时不会因字符串拼错出 bug
    - match 语句有穷尽性检查检查
    - EntityType.from_string() 做字符串→枚举转换,未知字符串→UNKNOWN

为什么不直接改 proto 加 enum?
    - 服务端目前 entity_type 是 string(proto 也是 string),改 proto 影响大
    - 客户端本地用枚举,网络层接收时做 str→enum 转换,服务端不动
    - 这种「服务端 string ↔ 客户端 enum」的边界转换是常见模式
"""


# ---------------------------------------------------------------------------
# EntityType 枚举
# ---------------------------------------------------------------------------
# 服务端 entity_type 字符串值: "player" / "stake"
# 客户端转成枚举做 match 比较,避免字符串拼错
enum EntityType {
	PLAYER,   # 玩家(可移动/可攻击/可被攻击)
	STAKE,    # 木桩(不可移动/不可攻击/可被攻击)
	ENEMY_SLIME, # 敌人(可移动/可攻击/可被攻击)
	ENEMY_SKELETON,	# 敌人(可移动/可攻击/可被攻击)
	UNKNOWN,  # 未知类型(兜底:from_string 找不到匹配时返回,match 走默认分支)
}


# ---------------------------------------------------------------------------
# 字段(和服务端 EntityInfo dataclass 对齐)
# ---------------------------------------------------------------------------

# 实体ID(带类型前缀: "player:uuid-xxx" / "entity:stake_1")
# 服务端在 add_entity 时分配,客户端通过 PlayerJoin / GameState 收到
var entity_id: String = ""

# 实体类型(枚举,从服务端字符串转换而来)
# 决定渲染层挂什么组件:PLAYER→PlayerVisual+AnimStateMachine+Controller,STAKE→只挂 PlayerVisual
var entity_type: EntityType = EntityType.UNKNOWN

# 坐标(世界坐标,像素)
var x: float = 0.0
var y: float = 0.0

# 朝向(弧度,0=朝右,逆时针正——Godot 标准)
var facing: float = 0.0

# 服务端当前移动标志；与动画 state 分开保存，避免战斗锁定状态覆盖它。
var moving: bool = false

# 动画状态(idle/run/attacking/hurt)
# 和服务端 EntityInfo.state 严格对齐:服务端 apply_xxx 设什么,客户端就存什么
var state: String = "idle"

# AI 状态(patrol/chase/attack/look_around,只有敌人有,玩家/木桩为空)
# 和服务端 EntityInfo.ai_state 对齐。注意:和 state(动画状态)是两个独立维度——
# 动画状态里没有 chase,视锥形态(normal/chase)必须靠 ai_state 切换。
# 由 GameState 快照带初始值 + AiStateChanged 增量消息实时更新。
var ai_state: String = "idle"

# 玩家名字(只有 player 类型有,其他类型为空)
var player_name: String = ""

# 账号ID(本地存档生成,跨会话稳定;登录时随 PlayerJoin 发给服务端作 player_id)
# 只有 player 类型有,其他类型为空
var account_id: String = ""

# 攻击ID(攻击消息携带,非 EntityInfo proto 字段,客户端临时存)
# 默认 0 表示无攻击;服务端 AttackStart 广播带 atk_id,客户端存下供后续逻辑用
# 注:目前客户端没有读取此字段的逻辑,保留是为了和原 dict 行为一致
var atk_id: int = 0

# 注:body_color 不在这里——它是「类型级显示属性」,由 entity_type 决定,
# 走 ConfigLoader.get_capability(entity_type).body_color 本地查表,不进网络消息、不进状态镜像。
# 和 speed 同原则:类型属性本地查表,实例状态才走服务端同步。


# ---------------------------------------------------------------------------
# 静态构造(从 dict 转换)
# ---------------------------------------------------------------------------

## 从服务端字典(EntityInfo proto 反序列化的 dict)构造 ClientEntityInfo
## 集中处理字段名/类型转换,全工厂数 dict 访问只在此处
## 调用方:StateMirror._on_game_state / _on_player_join
static func from_dict(d: Dictionary) -> ClientEntityInfo:
	var info := ClientEntityInfo.new()
	info.entity_id = d.get("entity_id", "")
	info.entity_type = from_string(d.get("entity_type", ""))
	info.x = float(d.get("x", 0.0))
	info.y = float(d.get("y", 0.0))
	info.facing = float(d.get("facing", 0.0))
	info.moving = bool(d.get("moving", false))
	info.state = d.get("state", "idle")
	info.ai_state = d.get("ai_state", "idle")
	info.player_name = d.get("player_name", "")
	info.account_id = d.get("account_id", "")
	info.atk_id = int(d.get("atk_id", 0))
	return info


## 字符串 → EntityType 枚举(网络层接收时做转换)
## 未知字符串返回 UNKNOWN(兜底,不报错——服务端未来可能加新类型,客户端容错)
static func from_string(s: String) -> EntityType:
	match s:
		"player":
			return EntityType.PLAYER
		"stake":
			return EntityType.STAKE
		"enemy_slime":
			return EntityType.ENEMY_SLIME
		"enemy_skeleton":
			return EntityType.ENEMY_SKELETON
		_:
			return EntityType.UNKNOWN


## EntityType 枚举 → 字符串(给日志/调试用)
static func type_to_string(t: EntityType) -> String:
	match t:
		EntityType.PLAYER:
			return "player"
		EntityType.STAKE:
			return "stake"
		EntityType.ENEMY_SLIME:
			return "enemy_slime"
		EntityType.ENEMY_SKELETON:
			return "enemy_skeleton"
		_:
			return "unknown"


# ---------------------------------------------------------------------------
# 实例方法
# ---------------------------------------------------------------------------

## 返回 entity_type 的字符串表示(给日志用)
func enum_type_string() -> String:
	return type_to_string(entity_type)


## 调试输出(print / str 调用时自动调用)
func _to_string() -> String:
	return "ClientEntityInfo(id=%s, type=%s, pos=(%.1f,%.1f), facing=%.2f, state=%s, name=%s)" % [
		entity_id, enum_type_string(), x, y, facing, state, player_name
	]
