# coding=utf-8

"""
消息总线单例：屏蔽 protobuf 细节，提供字典式 API

设计目标：
    发送：await MessageBus().send("ChatMessage", {"content": "hello"})
    接收：@MessageBus().onproto("ChatMessage")
         async def on_chat(data):
             print(data["content"])

多 proto 文件同名 message 处理：
    当多个 .proto 文件中有同名 message 时，用 "package.MessageName" 全名区分。
    例如：game.ChatMessage 和 chat.ChatMessage 不会冲突。
    - 如果只用短名 "ChatMessage" 且全局唯一，能正常工作
    - 若存在歧义（多个 package 都有同名 message），必须用全名

底层原理：
    send:    字典 --ParseDict--> protobuf对象 --SerializeToString--> bytes --send--> 网络
    接收:    网络 --recv--> bytes --ParseFromString--> protobuf对象 --MessageToDict--> 字典 --dispatch--> handler
"""

import os
import sys
import inspect
import logging
from typing import Dict, Callable, Optional, List
from collections import defaultdict

# 把 proto/generated 加入搜索路径，确保能 import game_pb2
# 本文件在 server/net/，proto/generated 在 server/proto/generated，所以要往上跳一层
_HERE = os.path.dirname(os.path.abspath(__file__))        # server/net
_SERVER_ROOT = os.path.dirname(_HERE)                       # server
_GENERATED_DIR = os.path.join(_SERVER_ROOT, "proto", "generated")
if os.path.isdir(_GENERATED_DIR) and _GENERATED_DIR not in sys.path:
    sys.path.insert(0, _GENERATED_DIR)

from google.protobuf.json_format import MessageToDict, ParseDict
import game_pb2

logger = logging.getLogger(__name__)


class MessageContext:
    """
    消息上下文：携带连接相关信息
    服务器端的 handler 可以通过第二个参数接收它
    """

    def __init__(self, websocket=None, player_id: str = None, is_server: bool = False):
        self.websocket = websocket  # 该消息来源的 websocket 连接
        self.player_id = player_id  # 发送方的玩家ID
        self.is_server = is_server  # 当前是服务器端还是客户端

    def __repr__(self):
        return f"MessageContext(player_id={self.player_id}, is_server={self.is_server})"


class MessageBus:
    """
    消息总线单例

    自动扫描 GameMessage 的 oneof 字段，注册所有消息类型。
    支持 "package.MessageName" 全名 和 "MessageName" 短名两种用法。

    使用示例：
        bus = MessageBus()

        @bus.onproto("ChatMessage")          # 短名（唯一时可用）
        async def on_chat(data):
            print(data["content"])

        @bus.onproto("game.PlayerMove")      # 全名（有歧义时用）
        async def on_move(data, ctx):
            print(ctx.player_id)

        await bus.send("ChatMessage", {"content": "hello"})
    """

    _instance = None

    def __new__(cls):
        # 单例模式：保证全局只有一个 MessageBus 实例
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        # 避免重复初始化
        if self._initialized:
            return
        self._initialized = True

        # 消息处理器注册表：全名 -> handler函数
        self._handlers: Dict[str, Callable] = {}

        # 消息类型注册表：全名 -> (protobuf类, GameMessage oneof字段名)
        self._registry: Dict[str, tuple] = {}

        # 反向映射：GameMessage oneof字段名 -> 全名（接收时反查）
        self._field_to_name: Dict[str, str] = {}

        # 短名 -> [全名列表]（用于短名解析，处理同名冲突）
        self._short_to_full: Dict[str, List[str]] = defaultdict(list)

        # 默认 websocket 连接（客户端用，服务器端在 send 时显式传入）
        self._websocket = None

        # 入站消息校验钩子（可选）
        # 服务端启动时设置它做方向校验，客户端保持 None（不校验）
        # 详见 dispatch 方法里的 2.5 步注释
        self._inbound_validator: Optional[Callable[[str], bool]] = None

        # 自动扫描 GameMessage 的 oneof 字段，注册所有消息类型
        self._auto_register()

        logger.debug(f"MessageBus 初始化完成，已注册 {len(self._registry)} 种消息类型: {list(self._registry.keys())}")

    def _auto_register(self):
        """
        自动扫描 GameMessage 的 oneof 字段，注册所有消息类型
        添加新 message 到 proto 后，无需手动注册，重启即可生效
        """
        game_msg = game_pb2.GameMessage()
        # 遍历 GameMessage 的所有 oneof（这里只有一个 message_type）
        for oneof in game_msg.DESCRIPTOR.oneofs:
            for field in oneof.fields:
                # field.name: oneof 字段名，如 'player_join'
                # field.message_type.full_name: 消息全名，如 'game.PlayerJoin'
                # field.message_type.name: 消息短名，如 'PlayerJoin'
                full_name = field.message_type.full_name
                short_name = field.message_type.name
                message_class = getattr(game_pb2, short_name, None)
                if message_class is None:
                    logger.warning(f"在 game_pb2 中找不到消息类: {short_name}")
                    continue

                self._registry[full_name] = (message_class, field.name)
                self._field_to_name[field.name] = full_name
                self._short_to_full[short_name].append(full_name)

    def _resolve_name(self, name: str) -> str:
        """
        解析消息名：支持全名和短名

        - 全名（含 '.'）直接查注册表
        - 短名查 _short_to_full：唯一则返回全名，多个则报错要求用全名

        Args:
            name: 消息名（全名或短名）

        Returns:
            解析后的全名

        Raises:
            ValueError: 名字有歧义或未知
        """
        # 全名直接命中
        if name in self._registry:
            return name

        # 尝试短名
        full_names = self._short_to_full.get(name, [])
        if len(full_names) == 1:
            return full_names[0]
        elif len(full_names) > 1:
            raise ValueError(
                f"消息名 '{name}' 有歧义，存在多个同名消息: {full_names}，"
                f"请用全名（package.MessageName）区分"
            )
        else:
            raise ValueError(f"未知的消息类型: {name}，请检查 proto 文件或调用 register_message 注册")

    def set_websocket(self, ws):
        """
        设置默认 websocket 连接（客户端用）
        服务器端不需要设置，因为有多条连接，在 send 时显式传入
        """
        self._websocket = ws

    def set_inbound_validator(self, validator: Callable[[str], bool]):
        """
        设置入站消息校验钩子（服务端用）

        传入一个函数，签名为 (full_name: str) -> bool。
        dispatch 时会调用它，返回 False 则跳过该消息不调 handler。
        客户端不调用此方法，_inbound_validator 保持 None，dispatch 行为不变。

        用法（服务端启动时）：
            from message_contract import MessageContract
            contract = MessageContract()
            contract.load()
            bus.set_inbound_validator(contract.is_valid_inbound)
        """
        self._inbound_validator = validator

    def register_message(self, message_class, field_name: str):
        """
        手动注册消息类型（用于非 GameMessage oneof 的独立消息）

        Args:
            message_class: protobuf 生成的类
            field_name: 该消息在 GameMessage oneof 中的字段名
        """
        full_name = message_class.DESCRIPTOR.full_name
        short_name = message_class.DESCRIPTOR.name
        self._registry[full_name] = (message_class, field_name)
        self._field_to_name[field_name] = full_name
        self._short_to_full[short_name].append(full_name)
        logger.debug(f"手动注册消息类型: {full_name} -> {field_name}")

    def onproto(self, protoname: str):
        """
        装饰器：注册消息处理器，支持全名和短名

        使用示例：
            @bus.onproto("ChatMessage")           # 短名
            async def on_chat(data):
                print(data["content"])

            @bus.onproto("game.PlayerMove")      # 全名（有歧义时用）
            async def on_move(data, ctx):
                print(ctx.player_id)

        Args:
            protoname: 消息类型名（全名或短名）
        """

        def decorator(func: Callable):
            full_name = self._resolve_name(protoname)
            self._handlers[full_name] = func
            logger.debug(f"注册处理器: {protoname} -> {func.__name__} (全名: {full_name})")
            return func

        return decorator

    async def send(self, protoname: str, protoprama: dict = None, websocket=None):
        """
        发送消息：字典 -> protobuf -> bytes -> 发送

        Args:
            protoname: 消息类型名（全名或短名），如 "ChatMessage" 或 "game.ChatMessage"
            protoprama: 消息内容（字典），如 {"content": "hello"}
            websocket: 目标连接（服务器端广播时指定，客户端用默认连接）
        """
        full_name = self._resolve_name(protoname)
        msg_class, field_name = self._registry[full_name]

        # 1. 创建 protobuf 消息对象
        msg = msg_class()

        # 2. 字典 -> protobuf 对象（用反射批量设置属性）
        if protoprama:
            ParseDict(protoprama, msg, ignore_unknown_fields=True)

        # 3. 包装成 GameMessage（oneof 字段）
        game_msg = game_pb2.GameMessage()
        getattr(game_msg, field_name).CopyFrom(msg)

        # 4. 序列化为字节
        data = game_msg.SerializeToString()

        # 5. 发送
        ws = websocket or self._websocket
        if ws is None:
            raise RuntimeError("未设置 websocket 连接，请先调用 set_websocket 或传入 websocket 参数")
        await ws.send(data)

    async def dispatch(self, data: bytes, ctx: MessageContext = None) -> bool:
        """
        分发接收到的消息：bytes -> protobuf -> 字典 -> 调用 handler

        Args:
            data: 接收到的字节数据
            ctx: 消息上下文（服务器端传入，包含 websocket/player_id）

        Returns:
            True 表示成功分发，False 表示失败
        """
        try:
            # 1. bytes -> protobuf 对象
            game_msg = game_pb2.GameMessage()
            game_msg.ParseFromString(data)

            # 2. 遍历 oneof 字段，找到实际设置的字段
            for field_descriptor, field_value in game_msg.ListFields():
                # field_descriptor.name 是 GameMessage 中的字段名，如 'player_move'
                full_name = self._field_to_name.get(field_descriptor.name)
                if not full_name:
                    continue

                # 2.5 契约校验（可选）
                # inbound_validator 是一个可选的钩子：服务端启动时设置它做方向校验，
                # 客户端不设置（None），行为不变。
                # 为什么不直接在 MessageBus 里 import message_contract：
                #   MessageBus 是双端共用的概念，契约模块是服务端特有。
                #   硬编码依赖会让双端 MessageBus 不再对称，且客户端引入无用依赖。
                #   用钩子保持解耦：MessageBus 只提供「插入点」，不关心校验逻辑。
                if self._inbound_validator is not None:
                    if not self._inbound_validator(full_name):
                        # 校验失败：跳过这条消息，不调 handler
                        # 不抛异常，只是跳过——非法消息不该让整个 dispatch 崩掉
                        continue

                # 3. protobuf 对象 -> 字典
                data_dict = MessageToDict(field_value, preserving_proto_field_name=True)

                # 4. 调用对应的处理器
                handler = self._handlers.get(full_name)
                if handler:
                    # 根据 handler 的参数个数，决定是否传入 ctx
                    # 这样 func(data) 和 func(data, ctx) 两种签名都支持
                    param_count = len(inspect.signature(handler).parameters)
                    try:
                        if param_count >= 2 and ctx is not None:
                            await handler(data_dict, ctx)
                        else:
                            await handler(data_dict)
                    except Exception as e:
                        logger.error(f"处理器 {full_name} 执行出错: {e}")
                else:
                    logger.warning(f"未找到消息 {full_name} 的处理器")

            return True
        except Exception as e:
            logger.error(f"分发消息失败: {e}")
            return False

    def list_handlers(self) -> Dict[str, Callable]:
        """获取所有已注册的处理器（调试用）"""
        return self._handlers.copy()

    def list_messages(self) -> Dict[str, tuple]:
        """列出所有已注册的消息类型（调试用）"""
        return self._registry.copy()