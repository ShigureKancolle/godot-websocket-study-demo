# coding=utf-8

"""
WebSocket 游戏客户端
使用 MessageBus 单例进行消息收发，业务代码只处理字典，不接触 protobuf
"""

import asyncio
import websockets
import time
from message_bus import MessageBus

# 获取全局消息总线单例
bus = MessageBus()


class GameClient:
    def __init__(self, uri: str = "ws://localhost:8765", player_name: str = "Player"):
        self.uri = uri
        self.player_name = player_name
        self.player_id = None  # 由服务器分配
        self.websocket = None
        self.is_running = False

    async def connect(self):
        """连接到服务器"""
        self.websocket = await websockets.connect(self.uri)
        self.is_running = True
        # 把连接交给消息总线，之后 bus.send 就能直接用
        bus.set_websocket(self.websocket)
        print(f"已连接到服务器: {self.uri}")

    async def send_join(self):
        """发送玩家加入消息（只需传字典，不用碰 protobuf）"""
        await bus.send("PlayerJoin", {
            "player_info": {
                "player_name": self.player_name,
                "level": 1,
                "score": 0,
                "x": 0.0,
                "y": 0.0
            }
        })
        print(f"发送加入消息，玩家名称: {self.player_name}")

    async def receive_loop(self):
        """持续接收服务器消息，全部交给 bus 分发"""
        while self.is_running:
            try:
                message = await self.websocket.recv()
                # 接收到的消息交给 bus，bus 会自动转成字典并调用对应 handler
                await bus.dispatch(message)
            except websockets.exceptions.ConnectionClosed:
                print("连接已关闭")
                break
            except Exception as e:
                print(f"接收消息时出错: {e}")
                break

    async def run(self):
        # 连接服务器
        await self.connect()
        # 发送加入消息
        await self.send_join()
        # 启动接收任务
        receive_task = asyncio.create_task(self.receive_loop())

        # 模拟一些游戏行为
        await asyncio.sleep(1)
        await bus.send("PlayerMove", {"x": 10.0, "y": 20.0, "speed": 1.0})
        await asyncio.sleep(1)
        await bus.send("PlayerMove", {"x": 15.0, "y": 25.0, "speed": 1.0})
        await asyncio.sleep(1)
        await bus.send("ChatMessage", {"content": "大家好！"})

        # 交互式输入
        print("\n输入消息发送到服务器，输入 'quit' 退出:")
        while self.is_running:
            try:
                user_input = await asyncio.get_event_loop().run_in_executor(None, input, "")
                if user_input.lower() == 'quit':
                    break
                elif user_input.startswith('move '):
                    parts = user_input.split()
                    if len(parts) == 3:
                        x, y = float(parts[1]), float(parts[2])
                        await bus.send("PlayerMove", {"x": x, "y": y, "speed": 1.0})
                else:
                    await bus.send("ChatMessage", {"content": user_input})
            except EOFError:
                break

        self.is_running = False
        receive_task.cancel()
        if self.websocket:
            await self.websocket.close()
        print("已断开连接")


# ==================== 消息处理器 ====================
# 使用 @bus.onproto 装饰器注册，函数参数是字典，完全屏蔽 protobuf
# 客户端的 handler 只接收一个参数（data 字典），不需要 ctx

@bus.onproto("PlayerJoin")
async def on_player_join(data: dict):
    """处理玩家加入消息"""
    player_info = data.get("player_info", {})
    name = player_info.get("player_name", "未知")
    pid = player_info.get("player_id", "")
    print(f"[系统] 玩家 {name} (ID: {pid}) 加入游戏")

    # 服务器会把自己分配的 player_id 回传，保存下来
    global client
    if client.player_id is None:
        client.player_id = pid
        print(f"[系统] 你的玩家ID是: {pid}")


@bus.onproto("PlayerLeave")
async def on_player_leave(data: dict):
    """处理玩家离开消息"""
    print(f"[系统] 玩家 {data.get('player_id', '')} 离开游戏")


@bus.onproto("PlayerMove")
async def on_player_move(data: dict):
    """处理玩家移动消息"""
    print(f"[移动] 玩家 {data.get('player_id', '')} 移动到 ({data.get('x')}, {data.get('y')})")


@bus.onproto("ChatMessage")
async def on_chat_message(data: dict):
    """处理聊天消息"""
    print(f"[聊天] {data.get('player_name', '未知')}: {data.get('content', '')}")


@bus.onproto("GameState")
async def on_game_state(data: dict):
    """处理游戏状态消息"""
    players = data.get("players", [])
    print(f"[状态] 当前在线玩家数: {len(players)}")
    for p in players:
        print(f"  - {p.get('player_name', '?')} (ID: {p.get('player_id', '?')}) "
              f"等级: {p.get('level', 0)} 分数: {p.get('score', 0)} "
              f"位置: ({p.get('x', 0)}, {p.get('y', 0)})")


@bus.onproto("Heartbeat")
async def on_heartbeat(data: dict):
    """处理心跳消息"""
    print(f"[心跳] 收到服务器心跳: {data.get('timestamp')}")


# 全局客户端实例（handler 里需要访问）
client = GameClient(uri="ws://localhost:8765", player_name="TestPlayer")


async def main():
    await client.run()


if __name__ == "__main__":
    asyncio.run(main())