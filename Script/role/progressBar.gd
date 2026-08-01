extends Node2D
class_name MyProgressBar

var prog = null
var fill_color = null
var prog_text = null
var cur_value = 0
var max_value = 0
var auto_hide: bool = true

func _ready() -> void:
	prog = $ProgressBar
	prog_text = $ProgressBar/ProgressValue
	if fill_color != null:
		set_color(fill_color)
	
func set_max(_max_value: float) -> void:
	max_value = _max_value

func set_value(_cur_value: float) -> void:
	if max_value <= 0:
		prog_text.visible = false
		return
	cur_value = clamp(_cur_value, 0, max_value)
	set_percentage(cur_value / max_value)

func set_percentage(percent: float) -> void:
	prog_text.visible = max_value > 0
	if max_value > 0:
		prog_text.text = "%d/%d" % [int(percent * max_value), max_value]
	
	percent = clamp(percent, 0.0, 1.0)
	prog.value = percent * 100

func set_color(color: Color) -> void:
	fill_color = color
	if prog == null:
		return
	var style = prog.get_theme_stylebox("fill").duplicate()
	style.bg_color = color
	prog.add_theme_stylebox_override("fill", style)

func set_type(type: String) -> void:
	if type == "hp":
		set_color(Color(0.725, 0.169, 0.082, 1.0))
	elif type == "mp":
		set_color(Color(0.125, 0.333, 1.0, 1.0))

func set_auto_hide(_auto_hide: bool) -> void:
	auto_hide = _auto_hide

	
