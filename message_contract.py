# coding=utf-8

"""
文件: server/message_contract.py
作用: 加载 messages.json 契约文件，提供消息方向/类别查询与校验

============================================================================
 为什么单独抽这个模块（而不是塞进 MessageBus）
============================================================================
MessageBus 的职责是「传输」：序列化、路由、分发——它不该关心「消息该不该出现」。
契约校验是「规则」：这个消息方向对不对、该不该改状态——这是另一层关注点。

把两者混在一起会让 MessageBus 越来越胖，且双端 MessageBus 实现差异大，
    契约逻辑嵌进去后很难保持对称。
抽成独立模块后，MessageBus 只管「把 bytes 送到 handler」，
    契约校验器只管「这个 handler 该不该被调」——职责清晰。

============================================================================
 当前只做「方向校验」，后续可扩展
============================================================================
现在校验：服务端 dispatch 时，如果消息 direction 是 S2C（如 GameState），
    说明这是「服务端发给客户端」的消息，客户端不该把它发给服务端——
    收到就拒绝并告警，防止逻辑错误。

后续可加：
    - state_affecting 校验：handler 如果调了 GameRoom 但消息标记是 false，告警
    - 未注册消息告警：proto 里有但 messages.json 里没登记的消息
    - 双向校验：send 时也查方向（服务端发 C2S 消息就反了）

============================================================================
 加载位置
============================================================================
契约文件在 server/proto/messages.json，和 game.proto 同目录。
本模块在 server/ 下，用相对路径 ../proto/messages.json 找不到——
    实际是 ./proto/messages.json（相对 server/ 目录）。
所以用 __file__ 定位：本文件所在目录的 proto 子目录。
"""

import os
import json
import logging
from typing import Dict, Optional

logger = logging.getLogger(__name__)


# 方向常量（用字符串而非 enum，因为 JSON 里就是字符串，直接比对最简单）
DIR_C2S = "C2S"   # 客户端 → 服务端
DIR_S2C = "S2C"   # 服务端 → 客户端
DIR_BOTH = "both"  # 双向


class MessageContract:
    """
    消息契约加载器（单例）

    使用：
        contract = MessageContract()
        contract.load()                          # 启动时加载一次

        # 校验方向（服务端 dispatch 时用）
        if contract.is_valid_inbound("GameState"):
            # GameState 是 S2C 消息，客户端不该发给服务端——is_valid_inbound 返回 False
            ...
    """

    _instance = None

    def __new__(cls):
        # 单例：契约文件只需加载一次，全局共享
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        if self._initialized:
            return
        self._initialized = True

        # 契约表：短名 -> {direction, category, state_affecting, comment}
        self._messages: Dict[str, dict] = {}

        # 是否已加载（未加载时校验方法直接放行，避免阻断启动流程）
        self._loaded = False

    def load(self, path: Optional[str] = None) -> bool:
        """
        加载 messages.json

        Args:
            path: 契约文件路径。不传则用默认位置（本文件同目录的 proto/messages.json）

        Returns:
            True 加载成功，False 失败（文件不存在或格式错误）
        """
        if path is None:
            # 默认路径：本文件所在目录下的 proto/messages.json
            # __file__ 是 server/message_contract.py，所以 proto 在同目录的子文件夹
            here = os.path.dirname(os.path.abspath(__file__))
            path = os.path.join(here, "proto", "messages.json")

        if not os.path.isfile(path):
            # 契约文件不存在：不报错，只告警。
            # 设计决策：契约校验是「增强」而非「必需」——没有契约文件时系统应能正常运行，
            # 只是少了方向校验。这样开发初期可以不写契约，后期再补上。
            # 代价：契约文件缺失时不会被发现。这个代价用「启动日志打印加载状态」缓解。
            logger.warning(f"消息契约文件不存在: {path}，跳过方向校验")
            self._loaded = False
            return False

        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)

            # 取 messages 字段，_doc 字段只是文档说明，运行时不使用
            self._messages = data.get("messages", {})
            self._loaded = True

            logger.info(
                f"消息契约已加载: {path}，共 {len(self._messages)} 条消息: "
                f"{list(self._messages.keys())}"
            )
            return True

        except Exception as e:
            # 加载失败比文件不存在更严重——文件在但格式坏了，说明有人改错了
            logger.error(f"加载消息契约失败: {e}")
            self._loaded = False
            return False

    def is_loaded(self) -> bool:
        """契约是否已成功加载（未加载时校验方法会直接放行）"""
        return self._loaded

    def get_message(self, short_name: str) -> Optional[dict]:
        """
        获取某消息的契约信息

        Args:
            short_name: 消息短名，如 "PlayerMove"

        Returns:
            契约字典 {direction, category, state_affecting, comment}，
            消息未登记时返回 None
        """
        return self._messages.get(short_name)

    def is_valid_inbound(self, full_name: str) -> bool:
        """
        校验消息是否可作为「服务端收到的入站消息」

        服务端 dispatch 时调用。规则：
            - direction=C2S 或 both：合法（客户端有权发）
            - direction=S2C：非法（这是服务端发的，客户端不该发回来）
            - 消息未登记：放行（兼容契约未覆盖的新消息，只告警）

        Args:
            full_name: 消息全名，如 "game.PlayerMove"

        Returns:
            True 合法，False 非法（应拒绝该消息）
        """
        if not self._loaded:
            # 未加载契约：放行所有消息（不阻断功能，见 load 的设计决策）
            return True

        # 从全名提取短名：game.PlayerMove → PlayerMove
        # 用 rfind 而非 split，避免消息名里有点号的边缘情况（虽然 proto 规范不允许）
        short_name = full_name.rsplit(".", 1)[-1] if "." in full_name else full_name

        contract = self._messages.get(short_name)
        if contract is None:
            # 消息未登记：放行但告警
            # 不报错是因为新消息可能在 proto 里加了但契约文件还没更新——
            # 阻断会让开发流程变重。告警让开发者知道「该补契约了」。
            logger.warning(f"消息 {short_name} 未在契约中登记，放行但建议补充")
            return True

        direction = contract.get("direction", "")
        if direction == DIR_S2C:
            # 严格拒绝：服务端收到了「本应由服务端发出」的消息，一定是客户端逻辑错了
            logger.warning(
                f"拒绝入站消息 {short_name}：方向是 S2C（服务端→客户端），"
                f"客户端不该发送此消息"
            )
            return False

        # C2S 或 both：合法
        return True

    def is_state_affecting(self, short_name: str) -> bool:
        """
        查询某消息是否影响状态

        后续可用于：handler 里断言「如果调了 GameRoom，消息必须 state_affecting=true」。
        当前未强制使用，预留接口。

        Args:
            short_name: 消息短名

        Returns:
            True 影响状态，False 或未登记时返回 False
        """
        if not self._loaded:
            return False
        contract = self._messages.get(short_name)
        if contract is None:
            return False
        return bool(contract.get("state_affecting", False))
