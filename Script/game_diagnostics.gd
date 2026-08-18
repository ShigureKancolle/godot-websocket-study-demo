extends Label

"""正式 GameScene 的轻量本地诊断显示。

只读取 WebScoketMgr 和 ClientStateMirror，不进入服务端协议，也不参与任何
权威状态计算。刷新限为每秒一次，避免调试文本本身在高刷场景制造开销。
"""

var _elapsed: float = 0.0


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 1.0:
		return
	_elapsed = 0.0
	var mirror := ClientStateMirror.instance()
	var connected := MyWebSocketClient.instance().is_connected_to_server()
	var room_state := "未入房" if mirror.local_entity_id() == "" else "实体 %d" % mirror.entity_count()
	var rtt_text := "--" if not connected else "%d" % int(WebScoketMgr.get_rtt_ms())
	text = "RTT: %s ms  FPS: %d  %s" % [rtt_text, Engine.get_frames_per_second(), room_state]
