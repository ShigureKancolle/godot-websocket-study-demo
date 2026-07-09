extends Node
# 滚动项模板
var _scroll_item: Node = null
# 滚动项池子（已实例化的item，循环复用）
var _scroll_item_pool: Array[Node] = []
# 滚动面板（ScrollContainer）
var _scroll_panel: ScrollContainer = null
# 给滚动项传数据的方法
var _scroll_data_handler: Callable

# 数据列表
var _data_list: Array[Dictionary] = []
# 内容容器（承载所有item，决定滚动范围）
var _content: Control = null
# 单个item尺寸
var _item_size: Vector2 = Vector2.ZERO
# item之间的间距
var _item_spacing: float = 0.0
# 排列方向：true=垂直，false=水平
var _vertical: bool = true
# 视口外额外预渲染的缓冲item数量
var _buffer_count: int = 2
# 池子里第一个item对应的数据索引
var _first_index: int = 0
# 脏标记，数据或配置变化时需要重新布局
var _dirty: bool = true
# 是否已完成初始化
var _initialized: bool = false


func _init() -> void:
	pass


func _ready() -> void:
	_init_scroll()


func _process(_delta: float) -> void:
	if not _initialized:
		_init_scroll()
	if not _initialized:
		return
	# 模板进入场景树后才能拿到正确的尺寸
	if _item_size == Vector2.ZERO:
		_measure_item_size()
	if _item_size == Vector2.ZERO:
		return
	_refresh_if_needed()


# 设置滚动面板（ScrollContainer）
func set_scroll_panel(panel: Node) -> void:
	_scroll_panel = panel
	_initialized = false
	_init_scroll()

# 设置一个Node作为滚动项
func set_scroll_item(item: Node):
	_scroll_item = item
	_initialized = false
	_init_scroll()

# 设置单个滚动项的数据
func set_scroll_item_data(item: Node, data: Dictionary):
	if _scroll_data_handler and _scroll_data_handler.is_valid():
		_scroll_data_handler.call(item, data)

func set_scroll_data_handler(cb: Callable):
	_scroll_data_handler = cb

# 设置item间距
func set_item_spacing(spacing: float) -> void:
	_item_spacing = spacing
	_update_content_size()
	_dirty = true

# 设置排列方向：vertical=true 垂直排列，false 水平排列
func set_vertical(vertical: bool) -> void:
	_vertical = vertical
	_update_content_size()
	_dirty = true

# 设置缓冲数量（越大滚动越平滑，占用越多item实例）
func set_buffer_count(count: int) -> void:
	_buffer_count = max(0, count)
	_dirty = true

# 手动指定item尺寸（模板无法自动测量时使用）
func set_item_size(size: Vector2) -> void:
	_item_size = size
	_update_content_size()
	_dirty = true

# 传入一个数据列表，刷新滚动面板
func refresh_scroll_panel(data_list: Array[Dictionary]):
	_data_list = data_list
	_init_scroll()
	_update_content_size()
	if _scroll_panel:
		_scroll_panel.scroll_vertical = 0
		_scroll_panel.scroll_horizontal = 0
	_first_index = -1
	_dirty = true
	_refresh_if_needed()


# ===== 内部实现 =====

# 初始化：创建内容容器，把模板挂到容器下并隐藏
func _init_scroll() -> void:
	if _initialized:
		return
	if _scroll_panel == null or _scroll_item == null:
		return
	if not (_scroll_panel is ScrollContainer):
		push_warning("ScorllDemo: scroll_panel 不是 ScrollContainer，可能无法正常滚动")
		return
	if _content == null:
		_content = Control.new()
		_content.name = "ScrollContent"
		_scroll_panel.add_child(_content)
	# 模板从原父节点移除，加入内容容器并隐藏，仅作为复制源
	if _scroll_item.get_parent() != _content:
		if _scroll_item.get_parent() != null:
			_scroll_item.get_parent().remove_child(_scroll_item)
		_content.add_child(_scroll_item)
	_scroll_item.visible = false
	_initialized = true

# 测量模板尺寸
func _measure_item_size() -> void:
	if not (_scroll_item is Control):
		return
	var ctrl: Control = _scroll_item as Control
	var s: Vector2 = ctrl.size
	if s.x <= 0 or s.y <= 0:
		s = ctrl.get_combined_minimum_size()
	if s.x > 0 and s.y > 0:
		_item_size = s
		_update_content_size()

# 单个item的步进（尺寸+间距）
func _get_step() -> float:
	var base: float = _item_size.y if _vertical else _item_size.x
	return base + _item_spacing

# 更新内容容器总尺寸，决定滚动范围
func _update_content_size() -> void:
	if _content == null or _item_size == Vector2.ZERO:
		return
	var count: int = _data_list.size()
	var step: float = _get_step()
	var total: float = step * count
	if count > 0:
		total -= _item_spacing
	if _vertical:
		_content.custom_minimum_size = Vector2(_item_size.x, total)
	else:
		_content.custom_minimum_size = Vector2(total, _item_size.y)

# 计算某个数据索引对应的item位置
func _get_item_position(data_index: int) -> Vector2:
	var offset: float = _get_step() * data_index
	if _vertical:
		return Vector2(0, offset)
	return Vector2(offset, 0)

# 确保池子里有足够数量的item实例
func _ensure_pool_size(need_count: int) -> void:
	while _scroll_item_pool.size() < need_count:
		var item: Node = _scroll_item.duplicate()
		item.visible = false
		_content.add_child(item)
		_scroll_item_pool.append(item)
	for i in range(need_count, _scroll_item_pool.size()):
		_scroll_item_pool[i].visible = false

# 每帧检查是否需要刷新可见item
func _refresh_if_needed() -> void:
	var step: float = _get_step()
	if step <= 0:
		return
	var scroll_value: float = _scroll_panel.scroll_vertical if _vertical else _scroll_panel.scroll_horizontal
	var first_index: int = int(scroll_value / step) - _buffer_count
	first_index = clamp(first_index, 0, _data_list.size())
	if first_index == _first_index and not _dirty:
		return
	_first_index = first_index
	_dirty = false
	_layout_items()

# 布局当前可见的item（复用池子里的实例）
func _layout_items() -> void:
	var step: float = _get_step()
	var viewport_size: float = _scroll_panel.size.y if _vertical else _scroll_panel.size.x
	var visible_count: int = int(ceil(viewport_size / step)) + 1
	var need_count: int = visible_count + _buffer_count * 2
	need_count = clamp(need_count, 0, _data_list.size())
	_ensure_pool_size(need_count)
	for i in range(need_count):
		var data_index: int = _first_index + i
		var item: Node = _scroll_item_pool[i]
		if data_index >= 0 and data_index < _data_list.size():
			item.visible = true
			if item is Control:
				(item as Control).position = _get_item_position(data_index)
			set_scroll_item_data(item, _data_list[data_index])
		else:
			item.visible = false
