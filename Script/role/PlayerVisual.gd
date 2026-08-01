extends Node2D
class_name PlayerVisual

"""
文件: client/Script/role/PlayerVisual.gd
作用: 玩家的视觉表现组件——负责显示角色 + 朝向指示器 + 播放动画

============================================================================
 设计思路
============================================================================
作为预制体 PlayerVisual.tscn 的脚本。静态视觉配置(节点结构、Label 位置/颜色、
箭头初始位置、SpriteFrames 动画)在预制体编辑器里配,
运行时只处理动态逻辑(播动画、设名字文本、转箭头朝向)。

节点结构:
    PlayerVisual (Node2D)
    ├── Body (AnimatedSprite2D)   角色身体动画(idle/run 帧,由 AnimStateMachine 驱动)
    ├── FacingArrow (Sprite2D)    朝向指示器箭头,绕 Body 旋转
    └── NameLabel (Label)         名字标签

动画播放:
    - Body 是 AnimatedSprite2D,SpriteFrames 在预制体里配 8 个动画:
	  4 方向(Down/Left/Right/Up) × 2 状态(Idle/Run),命名 "Down_Idle" 等
	- 状态机(AnimStateMachine)只传基础状态名 "idle"/"run",不知道方向
    - PlayerVisual 在 update_facing 里把弧度算成四方向,缓存进 _facing_dir
	- play_anim(anim_name) 缓存状态名到 _current_state,再拼成 "Down_Idle" 等播放
    - 朝向变了但状态没变时(如朝右跑→朝上跑)主动重播,切到新方向前缀
    - 动画切换的决策在状态机,播放的执行在这里(职责分离)

朝向指示器设计:
    - 贴图用 arrowBlue_right(本地)/arrowBrown_right(远程),和身体同色系
    - _right 后缀:贴图本身指向右方(+x),所以 rotation=0 时箭头朝右
    - facing 语义:弧度,0=朝右,逆时针正(Godot 标准)
    - 箭头位置随 facing 转动,始终在 Body 外圈对应方向(不压在身体上)

为什么是组件而不是直接在 Role 里写显示逻辑:
    Role 是通用容器,它不该知道「玩家长什么样」——那是「玩家」这个类型的职责。
    把显示逻辑抽成组件后:
    - 木桩挂 StakeVisual,不挂 PlayerVisual,各自管自己的显示
    - 显示逻辑变更(换贴图、加动画)只改这一个文件
"""

# 箭头距离 Body 中心的偏移量(像素)
# Body 用 buttonRound 贴图(约 64x64),半径约 32;箭头贴图约 50x50
# 设 35 让箭头刚好贴在 Body 外圈,不重叠
const ARROW_OFFSET: float = 35.0

# 实体ID(带类型前缀: "player:uuid" / "entity:stake_1")
# 用于和 StateMirror.local_entity_id() 对比,判断是否本地玩家
var entity_id: String = ""
# 玩家名字(只有 player 类型有,stake 等类型为空)
@export var player_name: String = ""

@export var color: Color = Color.WHITE

# 预制体里的节点引用(setup 时即时取,不用 @onready 避免 _ready 时机问题)
# 原因: Role.setup 在 add_child 后立即调 setup,@onready 要等 _ready 才赋值,会拿到 null
var _body: AnimatedSprite2D
var _body_color: Color = Color.WHITE
var _facing_arrow: Sprite2D
var _name_label: Label

# 当前朝向方向(Down/Left/Right/Up),由 update_facing 从 facing 弧度推断
# 默认 Down: 和预制体 Body.autoplay="Down_Idle" 一致,避免 setup 前访问到空值
var _facing_dir: String = "Down"
# 当前动画状态名(idle/run),由 play_anim 缓存
# 用途: facing 变化但 state 不变时(如朝右跑→朝上跑,state 一直是 run),
#       要用新方向前缀重新播放同一状态动画(切到 Up_Run)
var _current_state: String = "idle"

func set_entity_name(entity_name: String) -> void:
	player_name = entity_name
	if _name_label != null:
		_name_label.text = player_name


## 初始化: 传入 ClientEntityInfo 强类型实体信息,设置动态视觉
## 由 Role.setup 在 add_child 后立即调用
## info 字段:entity_id / entity_type / x / y / facing / player_name 等(强类型,IDE 可补全)
func setup(info: ClientEntityInfo) -> void:
	entity_id = info.entity_id
	player_name = info.player_name if info.player_name != "" else "?"

	# 取预制体里的节点引用(instantiate + add_child 后子节点已存在,$ 可取到)
	_body = $Body
	_facing_arrow = $FacingArrow
	_name_label = $NameLabel

	# 判断是否本地玩家——本地用蓝色贴图,远程用棕色,便于区分
	# 这只是视觉区分,不影响逻辑(逻辑上本地/远程的区别在 Controller 组件)
	# 木桩等非 player 类型永远走「远程」配色(其实没影响,因为木桩没本地控制器)
	var local_eid = ClientStateMirror.instance().local_entity_id()
	var is_local: bool = (entity_id == local_eid and entity_id != "")

	# Body 动画:由 AnimStateMachine 驱动(IdleState/RunState 调 play_anim)
	# 本地/远程区分通过箭头颜色体现,Body 动画相同

	# 朝向箭头贴图:本地蓝/远程棕(和身体同色系)
	# 用 _right 后缀的贴图:贴图本身指向右方,rotation=0 时箭头朝右
	var arrow_tex = "res://prefab/CommonTexture/arrowBlue_right.png" if is_local \
		else "res://prefab/CommonTexture/arrowBrown_right.png"
	_facing_arrow.texture = load(arrow_tex)

	# 初始朝向(从实体信息取,默认 0=朝右)
	update_facing(info.facing)

	# 名字标签
	_name_label.text = player_name
	# 如果是本地玩家,名字加个前缀「(你)」,更直观
	if is_local:
		_name_label.text = player_name + " (你)"

	# body_color 是「类型级显示属性」,由 entity_type 决定,走本地 ConfigLoader 查表。
	# 不从服务端消息读——服务端 proto 不传 body_color(它是纯客户端显示信息)。
	# 和 speed 同原则:类型属性本地查表,实例状态才走服务端同步。
	# enum_type_string() 把 EntityType 枚举转成 "player"/"enemy_slime" 等字符串给 ConfigLoader 用;
	# 未知类型走 ConfigLoader 的零值兜底(body_color="#ffffff"),不会崩。
	var body_color_hex: String = ConfigLoader.get_capability(info.enum_type_string()).body_color
	_body_color = Color(body_color_hex)
	_body.modulate = _body_color


## 更新朝向指示器 + 切换四方向动画
## 由 Role.on_entity_updated 在收到 StateMirror 的 entity_updated 信号时调用
## facing: 朝向角度(弧度),0=朝右,逆时针正
func update_facing(facing: float) -> void:
	# 箭头旋转:rotation = facing(贴图 _right 时 rotation=0 朝右,正好对应 facing=0)
	_facing_arrow.rotation = facing
	# 箭头位置:绕 Body 中心转,始终在外圈对应方向
	# Vector2.RIGHT.rotated(facing) 得到朝向单位向量,乘偏移量得到箭头位置
	_facing_arrow.position = Vector2.RIGHT.rotated(facing) * ARROW_OFFSET

	# 把弧度映射到四方向字符串,方向变了才重播(避免每帧都 play 一次)
	var new_dir := _facing_to_dir(facing)
	if new_dir != _facing_dir:
		_facing_dir = new_dir
		# 朝向变了但 state 没变(如一直 run,从朝右变成朝上),
		# 主动重播当前状态动画,切到新方向前缀(Up_Run)
		_play_current()


## 把朝向弧度映射到四方向字符串(Down/Left/Right/Up)
## facing 语义: 0=右, π/2=下(Godot 逆时针正), π/-π=左, -π/2=上
## 用 ±45° 分界,每 90° 一档;归一化后用区间判定
func _facing_to_dir(facing: float) -> String:
	# wrapf 把任意弧度归一到 [-π, π),处理 facing 累加或为负的情况
	var a: float = wrapf(facing, -PI, PI)
	# 四象限判定(以 ±45° 为分界):
	#   [-45°, 45°)               → Right
	#   [45°, 135°)               → Down
	#   [135°, 180°) ∪ [-180°, -135°) → Left
	#   [-135°, -45°)             → Up
	if a >= -PI / 4 and a < PI / 4:
		return "Right"
	elif a >= PI / 4 and a < 3 * PI / 4:
		return "Down"
	elif a >= 3 * PI / 4 or a < -3 * PI / 4:
		return "Left"
	else:
		return "Up"


## 播放指定动画
## 由 AnimStateMachine 的状态(IdleState/RunState)在 _enter_state 时调用
## anim_name: 基础状态名(idle/run),内部拼成方向_动画(如 "Down_Idle")再播放
## 动画切换的决策在状态机,播放的执行在这里——职责分离
func play_anim(anim_name: String) -> void:
	# 缓存当前状态名,facing 变化时要用它拼新方向动画
	_current_state = anim_name
	_play_current()
	
func replay_cur_anim() -> void:
	if _body == null:
		return
	_body.set_frame(0)


## 实际播放: 用 _facing_dir + _current_state 拼出动画名(如 "Down_Idle")
## 抽出来是因为 play_anim 和 update_facing 都要用它:
##   - play_anim: state 变了,用当前方向播放新状态
##   - update_facing: 方向变了,用新方向播放当前状态
func _play_current() -> void:
	if _body == null:
		return
	# capitalize("idle")="Idle",capitalize("run")="Run",拼成预制体里的动画名
	var full_name: String = _facing_dir + "_" + _current_state.capitalize()
	# 防御:SpriteFrames 里没配的动画名会告警
	if _body.sprite_frames.has_animation(full_name):
		# 避免重复播放当前动画(AnimatedSprite2D.play 同名动画会从头开始,这里只想继续)
		if _body.animation != full_name:
			_body.play(full_name)
	else:
		push_warning("PlayerVisual: 动画不存在: " + full_name)
