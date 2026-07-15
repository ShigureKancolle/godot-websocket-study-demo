extends Node

"""
文件: client/Script/UI/debug/DebugConsoleLoader.gd
作用: autoload 入口,根据开关决定是否实例化调试控制台

============================================================================
 解耦的关键(这是「核心代码零改动」的唯一接触点)
============================================================================
本文件是「调试控制台」和「核心游戏」之间的唯一桥梁:
    - 核心代码(Net/role/UI 主流程)不引用本文件
    - 本文件在 _ready 检查开关
    - 开关关闭时,queue_free() 销毁自己,不加载任何控制台代码

============================================================================
 启用方式(两个开关,任一为 true 即启用)
============================================================================
Godot 有两套独立的 feature 机制,用途不同:

1. 编辑器调试开关 —— ProjectSettings 自定义键(本文件读这个)
   project.godot 里加 [debug_console] enabled=true/false
   编辑器运行时 OS.has_feature 读不到 export preset 的 custom features,
   所以编辑器调试必须用 ProjectSettings。
   UI 编辑:项目设置(Project Settings)→ 右上角「高级/Advanced」开关
            → 滚到底部能看到 [debug_console] 段
   直接改 project.godot 文件也行。

2. 打包开关 —— export preset 的 custom features(运行时 OS.has_feature 读)
   编辑器菜单 → 项目(Project)→ 导出(Export)→ 选预设
   → 自定义功能/Custom Features 字段加 "debug_console"
   打包后运行时 OS.has_feature("debug_console") 返回 true

为什么不能用 config/features:
   config/features 是 Godot 引擎特性标记(如 "4.6"、"GL Compatibility"),
   自定义 tag 加在这里会触发「不支持的特性」警告,Godot 会自动删掉。
   所以编辑器调试改用 ProjectSettings 自定义键。

============================================================================
 三种运行形态
============================================================================
1. 编辑器运行调试:
   project.godot 里 [debug_console] enabled=true
   (默认已设为 true,直接运行游戏即可)

2. 打包带控制台(给开发/测试用的 build):
   project.godot 里 enabled=false + export preset custom features 加 "debug_console"

3. 打包不带控制台(发布 build):
   project.godot 里 enabled=false + export preset 不加 custom feature
   autoload 脚本仍在包里,但 _ready 自检不通过,queue_free,零开销

============================================================================
 自动化打包
============================================================================
CI 维护两个 export preset:
	- "release"(不加 debug_console feature)→ 发布版
	- "debug"(加 debug_console feature)→ 测试版
用 godot --headless --export-release "preset_name" 分别打包即可。
project.godot 里 enabled=false 即可,两个 preset 共用同一份 project.godot。
"""

const CONSOLE_SCRIPT_PATH = "res://Script/UI/debug/DebugConsole.gd"
const SETTINGS_KEY = "debug_console/enabled"
const FEATURE_NAME = "debug_console"


func _ready() -> void:
	# 两个开关任一为 true 即启用:
	# 1. ProjectSettings 的 debug_console/enabled(编辑器调试用)
	# 2. OS.has_feature("debug_console")(export preset custom features,打包用)
	var enabled_by_settings: bool = bool(ProjectSettings.get_setting(SETTINGS_KEY, false))
	var enabled_by_feature: bool = OS.has_feature(FEATURE_NAME)

	# 诊断:打印开关状态(改完 project.godot 必须重启编辑器才生效)
	print("[DebugConsoleLoader] 开关状态: settings=", enabled_by_settings, " feature=", enabled_by_feature)

	if not (enabled_by_settings or enabled_by_feature):
		# 未启用:销毁自己,不加载控制台(连 load 都不执行)
		print("[DebugConsoleLoader] 控制台未启用,跳过加载")
		queue_free()
		return

	print("[DebugConsoleLoader] 控制台已启用,加载脚本...")
	# 启用:用 load(运行时加载),拿到 DebugConsole 脚本资源
	var DebugConsoleScript = load(CONSOLE_SCRIPT_PATH)
	if DebugConsoleScript == null:
		push_error("无法加载调试控制台脚本: " + CONSOLE_SCRIPT_PATH)
		queue_free()
		return
	var console = DebugConsoleScript.new()
	add_child(console)
	print("[DebugConsoleLoader] 控制台已实例化, layer=", console.layer)
