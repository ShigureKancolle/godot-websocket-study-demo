'''
二次确认框（弹窗）
- 窗口类型：UIManager.WindowType.TIPS (500)
- 用法：instantiate() 后调用 setup(标题, 内容) 配置，监听 confirmed / cancelled 信号
- 纯本地 UI，不涉及网络通信
'''
extends Node

# 用户点击确定/取消时触发，调用方可 connect 监听
signal confirmed()
signal cancelled()

# 缓存 setup 传入的文本，_ready 时再赋值（防止 instantiate 后 setup 早于 _ready）
var _title_text: String = ""
var _content_text: String = ""


func _ready() -> void:
	# 连接两个按钮的点击信号
	$Mask/Bg/E_Confirm.pressed.connect(_on_confirm)
	$Mask/Bg/E_Cancel.pressed.connect(_on_cancel)
	# 节点就绪后把缓存的文本写进去
	$Mask/Bg/Title.text = _title_text
	$Mask/Bg/Content.text = _content_text


# 外部调用：配置标题和提示内容
func setup(p_title: String, p_content: String) -> void:
	_title_text = p_title
	_content_text = p_content
	# 如果 _ready 已经执行过（节点已就绪），直接更新显示
	if is_node_ready():
		$Mask/Bg/Title.text = p_title
		$Mask/Bg/Content.text = p_content


func _on_confirm() -> void:
	confirmed.emit()
	queue_free()


func _on_cancel() -> void:
	cancelled.emit()
	queue_free()
