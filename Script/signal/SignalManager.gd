'''
信号管理器
用于注册和分发信号
自动加载类  SignalMgr
'''

extends Node
class_name SignalManager

var SignalPriority = SignalConst.SignalPriority

# 单例
static var _initialized: bool = false

var _handlers: Dictionary = {} 

func _init():
	if not SignalManager._initialized:
		SignalManager._initialized = true
		_initialize_handlers()

func _initialize_handlers():
	# 初始化信号处理器字典
	for priority in SignalPriority.values():
		_handlers[priority] = {}

func _register_signal(signal_name: StringName, priority: int = SignalPriority.MEDIUM):
	if not _handlers.has(priority):
		push_error("错误的优先级 Invalid priority: %s" % priority)
		return false

	if not _handlers[priority].has(signal_name):
		_handlers[priority][signal_name] = []

	return true

func register_handler(signal_name: StringName, handler: Callable, priority: int = SignalPriority.MEDIUM):
	if not _register_signal(signal_name, priority):
		return

	_handlers[priority][signal_name].append(handler)

func fire_signal(signal_name: StringName, args: Dictionary = {}):
	for handlers in _handlers.values():
		if handlers.has(signal_name):
			for handler in handlers[signal_name]:
				handler.call(args)
