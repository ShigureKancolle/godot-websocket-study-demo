extends RefCounted
class_name MessageContract

"""
文件: client/Script/Net/MessageContract.gd
作用: 加载 messages.json 契约文件，提供消息方向查询与校验（客户端版）

============================================================================
 和服务端 message_contract.py 的对照
============================================================================
这是服务端 message_contract.py 的客户端对应物。两者:
    - 加载同一个 messages.json（结构一致，内容一致）
    - 提供相似的查询接口（is_valid_outbound 等）
    - 都做成独立模块，不塞进 MessageBus（职责分离）

不同点:
    - 服务端校验「入站方向」(is_valid_inbound)：收到 S2C 消息拒绝
    - 客户端校验「出站方向」(is_valid_outbound)：发送 C2S-only 消息前检查
      （如客户端不该主动发 GameState）
    - 服务端用 Python，客户端用 GDScript

双端都加载同一份契约文件，是「共享常量」的最纯粹形式——
    不生成代码、不跨语言调用，只共享一份文本数据，各自解读。

============================================================================
 当前只做「方向查询」，校验是轻量的
============================================================================
和服务端一样，这里也是「增强而非必需」——契约文件缺失时系统照常运行。
客户端的校验更偏向「开发期提醒」而非「运行期拦截」:
    - 注册 handler 时如果消息方向是 C2S（客户端发的），告警「你注册了永远不会收到的消息」
    - send 时如果方向不对，告警但不阻止（避免阻断开发流程）

============================================================================
 为什么用 RefCounted + 单例
============================================================================
和 StateMirror 一样：纯数据容器、被动响应、不进场景树、不参与 _process。
详见 StateMirror.gd 的同类说明。
"""

# 方向常量（和服务端 message_contract.py 保持一致）
const DIR_C2S = "C2S"    # 客户端 → 服务端
const DIR_S2C = "S2C"    # 服务端 → 客户端
const DIR_BOTH = "both"  # 双向

# 单例
static var _instance: MessageContract = null

static func instance() -> MessageContract:
	if _instance == null:
		_instance = MessageContract.new()
	return _instance

# 契约表：短名 -> {direction, category, state_affecting, comment}
var _messages: Dictionary = {}

# 是否已加载（未加载时校验方法直接放行）
var _loaded: bool = false


## 加载 messages.json
## path 不传则用默认位置（相对当前脚本的 ../proto/messages.json）
func load(path: String = "") -> bool:
	if path == "":
		# 默认路径：本脚本在 client/Script/Net/，proto 在 client/Script/proto/
		# 用 get_script().resource_path 拿到当前脚本路径，再 path_join
		var base_dir: String = get_script().resource_path.get_base_dir()
		var proto_dir: String = base_dir.path_join("../proto").simplify_path()
		path = proto_dir + "/messages.json"

	# Godot 的 FileAccess 读取资源路径
	# 注意：客户端运行时 res:// 路径是只读的，但读 JSON 没问题
	if not FileAccess.file_exists(path):
		push_warning("消息契约文件不存在: %s，跳过方向校验" % path)
		_loaded = false
		return false

	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("无法打开消息契约文件: %s" % path)
		_loaded = false
		return false

	var text: String = file.get_as_text()
	file.close()

	# Godot 4 内置 JSON 解析器，无需第三方库
	var json = JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		push_error("消息契约 JSON 解析失败: %s (行 %d): %s" % [path, json.get_error_line(), json.get_error_message()])
		_loaded = false
		return false

	var data: Variant = json.data
	if not data is Dictionary:
		push_error("消息契约格式错误：根对象不是 Dictionary")
		_loaded = false
		return false

	# 取 messages 字段，_doc 字段只是文档说明，运行时不使用
	_messages = data.get("messages", {})
	_loaded = true

	print("消息契约已加载: %s，共 %d 条消息: %s" % [path, _messages.size(), _messages.keys()])
	return true


## 契约是否已成功加载（未加载时校验方法直接放行）
func is_loaded() -> bool:
	return _loaded


## 获取某消息的契约信息。未登记返回 null。
func get_message(short_name: String) -> Variant:
	return _messages.get(short_name)


## 校验消息是否可作为「客户端发出的出站消息」
##
## 客户端 send 时调用（或在注册 handler 时反查）。规则：
##     - direction=C2S 或 both：合法（客户端有权发）
##     - direction=S2C：非法（这是服务端发的，客户端不该发）
##     - 消息未登记：放行但告警
##
## 和服务端 is_valid_inbound 镜像：
##     服务端 is_valid_inbound("GameState") = False（不该收到 S2C 消息）
##     客户端 is_valid_outbound("GameState") = False（不该发出 S2C 消息）
##     两者规则一致：S2C 消息只由服务端发，双向消息两边都能发。
func is_valid_outbound(full_name: String) -> bool:
	if not _loaded:
		return true

	# 从全名提取短名：game.PlayerMove → PlayerMove
	var short_name: String = full_name.rsplit(".", true, 1)[-1] if full_name.contains(".") else full_name

	var contract: Variant = _messages.get(short_name)
	if contract == null:
		push_warning("消息 %s 未在契约中登记，放行但建议补充" % short_name)
		return true

	var direction: String = contract.get("direction", "")
	# PlayerLeave 支持客户端主动退出房间(C2S),也支持断连广播(S2C),
	# 这里显式放行,避免契约方向字段未及时同步时误拦主动退出。
	if short_name == "PlayerLeave":
		return true

	if direction == DIR_S2C:
		push_warning("拒绝出站消息 %s：方向是 S2C（服务端→客户端），客户端不该发送此消息" % short_name)
		return false

	return true


## 校验消息是否可作为「客户端注册 handler 的入站消息」
##
## 客户端 onproto 注册时调用。规则：
##     - direction=S2C 或 both：合法（客户端能收到）
##     - direction=C2S：告警「你注册了永远不会收到的消息」
##       （C2S 是客户端发的，客户端不会收到自己发的消息——除非服务端回显）
##
## 为什么这个校验比 outbound 更宽松（只告警不阻止）:
##     outbound 校验防的是「真的发错消息」，后果在服务端。
##     handler 注册是本地行为，注册了多余的 handler 没有实际危害，只是浪费。
##     所以这里只 push_warning，不阻止注册。
func is_valid_inbound_handler(full_name: String) -> bool:
	if not _loaded:
		return true

	var short_name: String = full_name.rsplit(".", true, 1)[-1] if full_name.contains(".") else full_name
	var contract: Variant = _messages.get(short_name)
	if contract == null:
		return true  # 未登记放行，不重复告警（outbound 那边已告警过）

	var direction: String = contract.get("direction", "")
	if direction == DIR_C2S:
		# C2S 消息客户端不会收到（除非服务端回显，但那是 both 不是 C2S）
		push_warning("消息 %s 方向是 C2S（客户端→服务端），客户端注册 handler 可能永远不会被触发" % short_name)

	return true


## 查询某消息是否影响状态（和服务端同名方法对称）
func is_state_affecting(short_name: String) -> bool:
	if not _loaded:
		return false
	var contract: Variant = _messages.get(short_name)
	if contract == null:
		return false
	return bool(contract.get("state_affecting", false))
