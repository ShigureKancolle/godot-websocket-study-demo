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
    - Body 是 AnimatedSprite2D,SpriteFrames 在预制体里配(idle/run 两个动画)
    - play_anim(anim_name) 由 AnimStateMachine 的状态(IdleState/RunState)调用
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

# 玩家ID,用于在头顶显示名字
var player_id: String = ""
# 玩家名字
var player_name: String = ""

# 预制体里的节点引用(setup 时即时取,不用 @onready 避免 _ready 时机问题)
# 原因: Role.setup 在 add_child 后立即调 setup,@onready 要等 _ready 才赋值,会拿到 null
var _body: AnimatedSprite2D
var _facing_arrow: Sprite2D
var _name_label: Label


## 初始化: 传入玩家信息字典,设置动态视觉
## 由 Role.setup 在 add_child 后立即调用
func setup(info: Dictionary) -> void:
	player_id = info.get("player_id", "")
	player_name = info.get("player_name", "?")

	# 取预制体里的节点引用(instantiate + add_child 后子节点已存在,$ 可取到)
	_body = $Body
	_facing_arrow = $FacingArrow
	_name_label = $NameLabel

	# 判断是否本地玩家——本地用蓝色贴图,远程用棕色,便于区分
	# 这只是视觉区分,不影响逻辑(逻辑上本地/远程的区别在 Controller 组件)
	var local_pid = ClientStateMirror.instance().local_player_id()
	var is_local: bool = (player_id == local_pid and player_id != "")

	# Body 动画:由 AnimStateMachine 驱动(IdleState/RunState 调 play_anim)
	# 本地/远程区分通过箭头颜色体现,Body 动画相同

	# 朝向箭头贴图:本地蓝/远程棕(和身体同色系)
	# 用 _right 后缀的贴图:贴图本身指向右方,rotation=0 时箭头朝右
	var arrow_tex = "res://prefab/CommonTexture/arrowBlue_right.png" if is_local \
		else "res://prefab/CommonTexture/arrowBrown_right.png"
	_facing_arrow.texture = load(arrow_tex)

	# 初始朝向(从玩家信息取,默认 0=朝右)
	var facing: float = info.get("facing", 0.0)
	update_facing(facing)

	# 名字标签
	_name_label.text = player_name
	# 如果是本地玩家,名字加个前缀「(你)」,更直观
	if is_local:
		_name_label.text = player_name + " (你)"


## 更新朝向指示器
## 由 Role.on_player_updated 在收到 StateMirror 的 player_updated 信号时调用
## facing: 朝向角度(弧度),0=朝右,逆时针正
func update_facing(facing: float) -> void:
	# 箭头旋转:rotation = facing(贴图 _right 时 rotation=0 朝右,正好对应 facing=0)
	_facing_arrow.rotation = facing
	# 箭头位置:绕 Body 中心转,始终在外圈对应方向
	# Vector2.RIGHT.rotated(facing) 得到朝向单位向量,乘偏移量得到箭头位置
	_facing_arrow.position = Vector2.RIGHT.rotated(facing) * ARROW_OFFSET


## 播放指定动画
## 由 AnimStateMachine 的状态(IdleState/RunState)在 _enter_state 时调用
## anim_name: 动画名(对应 AnimatedSprite2D 的 SpriteFrames 动画名,如 "idle"/"run")
## 动画切换的决策在状态机,播放的执行在这里——职责分离
func play_anim(anim_name: String) -> void:
	if _body == null:
		return
	# 检查动画是否存在(防御:SpriteFrames 里没配的动画名会告警)
	if _body.sprite_frames.has_animation(anim_name):
		# 避免重复播放当前动画(AnimatedSprite2D.play 同名动画会从头开始,这里只想继续)
		if _body.animation != anim_name:
			_body.play(anim_name)
	else:
		push_warning("PlayerVisual: 动画不存在: " + anim_name)
