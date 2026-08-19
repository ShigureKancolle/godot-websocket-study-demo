'''
HUD 主控脚本(纯客户端显示控制)

职责:
- 只负责显示,不读写网络/状态镜像,所有数据通过公开 API 注入
- 之后服务端接协议时,由场景适配层把 S2C 消息转成这里的 API 调用
- 限时状态(status)的倒计时只做显示层本地递减,服务端仍是权威

接入文档见 docs/client-hud.md
'''
extends Control

signal survival_reward_requested(index: int)
signal survival_result_shown(result: Dictionary)
signal result_return_requested

var survival_state: Dictionary = {}
var pending_reward_choices: Dictionary = {}
var _choice_panel: VBoxContainer
var _result_panel: VBoxContainer

func apply_survival_state(state: Dictionary) -> void:
	# 仅更新展示数据；权威值来自 ClientStateMirror，客户端不推进 Run 计时或经验。
	survival_state = state.duplicate()

func request_survival_reward(index: int) -> void:
	# 数据流：UI 点击 -> 上层发送 ChooseReward(C2S) -> 服务端校验 ->
	# SurvivalState/LevelUpChoices 回传；HUD 不直接改等级或奖励。
	survival_reward_requested.emit(index)

# 聊天框提交(回车或点发送按钮),由上层决定走 game.ChatMessage 还是本地测试
signal chat_submitted(text: String)
# 点击「角色详情」按钮
signal role_detail_requested
# 点击「菜单」按钮
signal menu_requested

const TeammateItemScene: PackedScene = preload("res://prefab/hud/TeammateItem.tscn")

# 战斗日志类型(颜色映射见 _LOG_COLORS)
enum LogType {
	NORMAL = 0, # 普通
	DAMAGE = 1, # 伤害
	KILL = 2,   # 击杀
	DEATH = 3,  # 死亡
}

# 雷达 blip 关系类型
enum BlipType {
	TEAMMATE = 0, # 队友(绿点)
	ENEMY = 1,    # 敌人(红点)
}

const _LOG_COLORS := {
	LogType.NORMAL: "black",
	LogType.DAMAGE: "orange",
	LogType.KILL: "green",
	LogType.DEATH: "red",
}

const ICON_SIZE := Vector2(24, 24)

# 雷达开关(左上雷达面板,中心=本地玩家)
@export var radar_visible: bool = true:
	set(v):
		radar_visible = v
		if is_node_ready():
			$Radar.visible = v
# 雷达量程:实际距离(世界像素)超过该值的目标显示在雷达边缘
@export var radar_range_px: float = 1000.0

@export var battle_log_max: int = 100 # 战斗日志最大行数
@export var chat_log_max: int = 50    # 聊天显示最大行数

var _teammates: Dictionary = {}  # entity_id -> TeammateItem 节点
var _status_effects: Array = []  # [{icon_id, remain_ms, node, label}]
var _buffs: Dictionary = {}      # icon_id -> icon 节点(局内永久 buff)
# 雷达数据(纯显示):entity_id -> {type: BlipType, rel: Vector2(相对本地玩家的世界偏移,像素)}
var _radar_blips: Dictionary = {}


func _ready() -> void:
	$TopRightButtons/BtnRoleDetail.pressed.connect(func(): role_detail_requested.emit())
	$TopRightButtons/BtnLog.pressed.connect(_on_toggle_battle_log)
	$TopRightButtons/BtnMenu.pressed.connect(func(): menu_requested.emit())
	$ChatPanel/VBox/InputRow/BtnSend.pressed.connect(_on_send_pressed)
	$ChatPanel/VBox/InputRow/InputLine.text_submitted.connect(_on_input_submitted)
	$Radar.visible = radar_visible
	$Radar.draw.connect(_draw_radar)
	_build_survival_panels()


func _process(delta: float) -> void:
	# 雷达需要跟随实体移动实时刷新
	if radar_visible:
		$Radar.queue_redraw()
	# 限时状态:显示层本地倒计时(仅显示,权威数据由服务端周期同步覆盖)
	var expired: Array = []
	for effect in _status_effects:
		effect["remain_ms"] -= int(delta * 1000.0)
		if effect["remain_ms"] <= 0:
			expired.append(effect)
		else:
			effect["label"].text = "%d" % int(ceil(effect["remain_ms"] / 1000.0))
	for effect in expired:
		effect["node"].queue_free()
		_status_effects.erase(effect)


# ---------------- 雷达(左上,中心=本地玩家) ----------------
# 数据注入的是「相对本地玩家的世界偏移」,适配层每帧(或位置变化时)调用
# update_radar_blip / set_radar_blips。超出量程的目标钳制显示在雷达边缘。

func set_radar_visible(v: bool) -> void:
	radar_visible = v


# 更新/添加一个雷达目标
# entity_id: 实体唯一ID;blip_type: BlipType.TEAMMATE(绿) / BlipType.ENEMY(红)
# rel_offset: 目标相对本地玩家的世界坐标偏移(像素),即 target_pos - local_pos
func update_radar_blip(entity_id: String, blip_type: int, rel_offset: Vector2) -> void:
	if entity_id == "":
		return
	_radar_blips[entity_id] = {"type": blip_type, "rel": rel_offset}


func remove_radar_blip(entity_id: String) -> void:
	_radar_blips.erase(entity_id)


# 全量设置雷达目标,entries: [{entity_id, type, rel_x, rel_y}]
func set_radar_blips(entries: Array) -> void:
	_radar_blips.clear()
	for e in entries:
		update_radar_blip(
			e.get("entity_id", ""),
			e.get("type", BlipType.TEAMMATE),
			Vector2(e.get("rel_x", 0.0), e.get("rel_y", 0.0))
		)


func clear_radar_blips() -> void:
	_radar_blips.clear()


# 挂在 $Radar.draw 信号上,在 Radar 控件的本地坐标系里绘制
func _draw_radar() -> void:
	var radar: Control = $Radar
	var center: Vector2 = radar.size / 2.0
	var radius: float = minf(center.x, center.y) - 4.0
	var scale: float = radius / radar_range_px # 世界像素 -> 雷达像素

	# 外环 + 中环 + 十字刻度(匹配初稿的同心圆+十字样式)
	var ring_color := Color(1, 1, 1, 0.85)
	radar.draw_arc(center, radius, 0.0, TAU, 48, ring_color, 2.0)
	radar.draw_arc(center, radius * 0.5, 0.0, TAU, 32, ring_color, 1.0)
	radar.draw_line(center + Vector2(-radius, 0), center + Vector2(radius, 0), Color(1, 1, 1, 0.4), 1.0)
	radar.draw_line(center + Vector2(0, -radius), center + Vector2(0, radius), Color(1, 1, 1, 0.4), 1.0)

	# 本地玩家(中心白点)
	radar.draw_circle(center, 3.0, Color(1, 1, 1, 1))

	# blips:绿=队友,红=敌人
	for entity_id in _radar_blips:
		var blip: Dictionary = _radar_blips[entity_id]
		var offset: Vector2 = blip["rel"] * scale
		# 超出量程钳制到雷达边缘(保留方向)
		if offset.length() > radius:
			offset = offset.normalized() * radius
		var color := Color(0.2, 0.9, 0.3, 1) if blip["type"] == BlipType.TEAMMATE else Color(0.95, 0.2, 0.2, 1)
		radar.draw_circle(center + offset, 3.0, color)


# ---------------- 本地玩家状态(底部红/绿条) ----------------

# 设置本地玩家血量(红条)
func set_local_hp(cur_hp: int, max_hp: int) -> void:
	var bar: ProgressBar = $PlayerStatus/HpBar
	bar.max_value = maxi(max_hp, 1)
	bar.value = clampi(cur_hp, 0, maxi(max_hp, 1))


# 设置绿色经验条(保留旧方法名，调用方应优先使用 set_local_experience)
func set_local_energy(cur: int, max_value: int) -> void:
	# 兼容旧 API 名称：现有绿色“能量槽”只显示服务端经验。
	var bar: ProgressBar = $PlayerStatus/EnergyBar
	bar.max_value = maxi(max_value, 1)
	bar.value = clampi(cur, 0, maxi(max_value, 1))


func set_local_experience(cur: int, next_value: int) -> void:
	"""显示服务端下发的当前经验/升级阈值，不在客户端计算经验。"""
	set_local_energy(cur, next_value)


func _build_survival_panels() -> void:
	# 面板由 HUD 自己创建，保持预制体只负责基础布局，场景适配层只注入数据。
	_choice_panel = VBoxContainer.new()
	_choice_panel.name = "LevelUpChoices"
	_choice_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_choice_panel.set_anchors_preset(Control.PRESET_CENTER)
	_choice_panel.position = Vector2(-210, -90)
	_choice_panel.size = Vector2(420, 180)
	_choice_panel.add_theme_constant_override("separation", 8)
	_choice_panel.visible = false
	add_child(_choice_panel)
	var choice_title := Label.new()
	choice_title.name = "Title"
	choice_title.text = "选择升级"
	choice_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_choice_panel.add_child(choice_title)
	for index in 3:
		var button := Button.new()
		button.name = "Choice%d" % index
		button.mouse_filter = Control.MOUSE_FILTER_STOP
		button.custom_minimum_size = Vector2(420, 38)
		button.pressed.connect(_on_choice_pressed.bind(index))
		_choice_panel.add_child(button)

	_result_panel = VBoxContainer.new()
	_result_panel.name = "SurvivalResult"
	_result_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_result_panel.set_anchors_preset(Control.PRESET_CENTER)
	_result_panel.position = Vector2(-190, -130)
	_result_panel.size = Vector2(380, 260)
	_result_panel.add_theme_constant_override("separation", 10)
	_result_panel.visible = false
	add_child(_result_panel)
	var result_title := Label.new()
	result_title.name = "Title"
	result_title.text = "游戏结束"
	result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_panel.add_child(result_title)
	var result_text := Label.new()
	result_text.name = "Stats"
	result_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_panel.add_child(result_text)
	var back_button := Button.new()
	back_button.text = "返回大厅"
	back_button.pressed.connect(func(): result_return_requested.emit())
	_result_panel.add_child(back_button)


func show_level_up_choices(choices: Dictionary) -> void:
	pending_reward_choices = choices.duplicate()
	if _choice_panel == null:
		return
	_choice_panel.visible = true
	_result_panel.visible = false
	var labels: Array = choices.get("labels", [])
	for index in 3:
		var button: Button = _choice_panel.get_node("Choice%d" % index)
		button.text = str(labels[index]) if index < labels.size() else ""
		button.disabled = index >= labels.size()


func _on_choice_pressed(index: int) -> void:
	# 立即锁定按钮，避免网络往返期间重复发送同一个选择；奖励仍只由
	# 服务端应用，候选面板关闭等待下一条权威 LevelUpChoices 空事件。
	for child in _choice_panel.get_children():
		if child is Button:
			child.disabled = true
	request_survival_reward(index)


func clear_level_up_choices() -> void:
	"""收到服务端空候选确认后关闭选择面板，清除客户端暂存。"""
	pending_reward_choices.clear()
	if _choice_panel != null:
		_choice_panel.visible = false


func show_survival_result(result: Dictionary) -> void:
	# 结算面板只显示服务端统计；不在本地重新计算生存时间或击杀数。
	if _choice_panel != null:
		_choice_panel.visible = false
	if _result_panel != null:
		_result_panel.visible = true
		_result_panel.get_node("Stats").text = "存活时间：%d 秒\n波次：%d\n击杀：%d\n伤害：%d" % [
			int(result.get("survival_seconds", 0)), int(result.get("wave", 0)),
			int(result.get("kills", 0)), int(result.get("damage", 0))]
	survival_result_shown.emit(result.duplicate())


func clear_survival_ui() -> void:
	"""切换场景时清除本局候选和结算显示，避免下一局复用旧数据。"""
	survival_state.clear()
	pending_reward_choices.clear()
	if _choice_panel != null:
		_choice_panel.visible = false
	if _result_panel != null:
		_result_panel.visible = false


# ---------------- 限时状态 / 永久 buff(血条上方图标) ----------------

# 全量设置限时状态(时间到了自动消失,仅显示层)
# effects: [{icon_id: String, remain_ms: int, total_ms: int(可选)}]
func set_status_effects(effects: Array) -> void:
	_clear_children($PlayerStatus/IconRow/StatusRow)
	_status_effects.clear()
	for e in effects:
		add_status_effect(e.get("icon_id", ""), e.get("remain_ms", 0))


# 添加/刷新一个限时状态(同 icon_id 覆盖旧倒计时)
# icon: Texture2D 或贴图路径 String;为空则用占位圆点
func add_status_effect(icon_id: String, remain_ms: int, icon = null) -> void:
	for effect in _status_effects:
		if effect["icon_id"] == icon_id:
			effect["remain_ms"] = remain_ms
			return
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var icon_node := _make_icon(icon, ICON_SIZE)
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 11)
	label.text = "%d" % int(ceil(remain_ms / 1000.0))
	box.add_child(icon_node)
	box.add_child(label)
	$PlayerStatus/IconRow/StatusRow.add_child(box)
	_status_effects.append({"icon_id": icon_id, "remain_ms": remain_ms, "node": box, "label": label})


func remove_status_effect(icon_id: String) -> void:
	for effect in _status_effects:
		if effect["icon_id"] == icon_id:
			effect["node"].queue_free()
			_status_effects.erase(effect)
			return


# 全量设置局内永久 buff(本局不消失,无倒计时)
# buffs: [{icon_id: String, icon: Texture2D/String(可选), tips: String(可选)}]
func set_buffs(buffs: Array) -> void:
	_clear_children($PlayerStatus/IconRow/BuffRow)
	_buffs.clear()
	for b in buffs:
		add_buff(b.get("icon_id", ""), b.get("icon", null), b.get("tips", ""))


func add_buff(icon_id: String, icon = null, tips: String = "") -> void:
	if _buffs.has(icon_id):
		return
	var icon_node := _make_icon(icon, ICON_SIZE)
	icon_node.tooltip_text = tips
	$PlayerStatus/IconRow/BuffRow.add_child(icon_node)
	_buffs[icon_id] = icon_node


func remove_buff(icon_id: String) -> void:
	if _buffs.has(icon_id):
		_buffs[icon_id].queue_free()
		_buffs.erase(icon_id)


# ---------------- 队友列表(左侧) ----------------

# 全量设置队友列表
# teammates: [{entity_id: String, name: String, hp: int, max_hp: int, icon: Texture2D/String(可选)}]
func set_teammates(teammates: Array) -> void:
	_clear_children($TeammateList)
	_teammates.clear()
	for t in teammates:
		update_teammate(t.get("entity_id", ""), t)


# 添加/更新单个队友(不存在则创建)
func update_teammate(entity_id: String, data: Dictionary) -> void:
	if entity_id == "":
		return
	var item: HBoxContainer
	if _teammates.has(entity_id):
		item = _teammates[entity_id]
	else:
		item = TeammateItemScene.instantiate()
		$TeammateList.add_child(item)
		_teammates[entity_id] = item
	if data.has("name"):
		item.get_node("Info/NameLabel").text = data["name"]
	var hp: int = data.get("hp", -1)
	var max_hp: int = data.get("max_hp", -1)
	if hp >= 0 or max_hp > 0:
		var bar: ProgressBar = item.get_node("Info/HpBar")
		if max_hp > 0:
			bar.max_value = max_hp
		if hp >= 0:
			bar.value = clampi(hp, 0, int(bar.max_value))
	if data.has("icon") and data["icon"] != null:
		var avatar: TextureRect = item.get_node("Avatar")
		if data["icon"] is Texture2D:
			avatar.texture = data["icon"]
		elif data["icon"] is String and data["icon"] != "":
			avatar.texture = load(data["icon"])


func remove_teammate(entity_id: String) -> void:
	if _teammates.has(entity_id):
		_teammates[entity_id].queue_free()
		_teammates.erase(entity_id)


# ---------------- 战斗日志(右侧面板) ----------------

# 追加一条战斗日志,如 "玩家A 对 敌人A 造成了 xx 点伤害"
func add_battle_log(text: String, log_type: int = LogType.NORMAL) -> void:
	var log_text: RichTextLabel = $BattleLogPanel/LogText
	var color: String = _LOG_COLORS.get(log_type, "black")
	log_text.append_text("[color=%s]%s[/color]\n" % [color, text])
	_trim_lines(log_text, battle_log_max)


func clear_battle_log() -> void:
	$BattleLogPanel/LogText.clear()


func set_battle_log_visible(v: bool) -> void:
	$BattleLogPanel.visible = v


func _on_toggle_battle_log() -> void:
	$BattleLogPanel.visible = not $BattleLogPanel.visible


# ---------------- 聊天(左下角) ----------------

# 显示一条聊天消息(本地回显或他人消息都走这里)
func add_chat_message(player_name: String, content: String) -> void:
	var chat_text: RichTextLabel = $ChatPanel/VBox/ChatText
	chat_text.append_text("[color=blue]%s[/color]: %s\n" % [player_name, content])
	_trim_lines(chat_text, chat_log_max)


func clear_chat() -> void:
	$ChatPanel/VBox/ChatText.clear()


func _on_send_pressed() -> void:
	_on_input_submitted($ChatPanel/VBox/InputRow/InputLine.text)


func _on_input_submitted(text: String) -> void:
	text = text.strip_edges()
	if text == "":
		return
	$ChatPanel/VBox/InputRow/InputLine.clear()
	# 只发信号,由上层适配层决定发 game.ChatMessage 还是本地处理
	chat_submitted.emit(text)


# ---------------- 内部工具 ----------------

func _make_icon(icon, size: Vector2) -> TextureRect:
	var tex: Texture2D = null
	if icon is Texture2D:
		tex = icon
	elif icon is String and icon != "":
		tex = load(icon)
	var tr := TextureRect.new()
	tr.custom_minimum_size = size
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.texture = tex
	return tr


func _clear_children(node: Node) -> void:
	for child in node.get_children():
		child.queue_free()


func _trim_lines(label: RichTextLabel, max_lines: int) -> void:
	var line_count: int = label.get_line_count()
	if line_count > max_lines:
		label.remove_paragraph(0)
