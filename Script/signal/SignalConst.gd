extends Object
class_name SignalConst


class SignalName:
	const WEB_SOCKET_CONNECT_START: String = &"web_socket_connect_start"
	const WEB_SOCKET_CONNECT_FAILED: String = &"web_socket_connect_failed"
	const WEB_SOCKET_CONNECT_SUCCESS: String = &"web_socket_connect_success"

enum SignalPriority {
	HIGH = 100000,
	MEDIUM = 200000,
	LOW = 300000,
}
