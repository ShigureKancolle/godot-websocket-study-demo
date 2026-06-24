# WebSocket 游戏服务器（使用 Protocol Buffers）

这是一个使用 WebSocket 和 Protocol Buffers 实现的简单游戏服务器示例。

## 项目结构

```
chat_server_demo/
├── game.proto          # Protocol Buffers 消息定义文件
├── web_server.py       # WebSocket 游戏服务器
├── client.py           # 测试客户端
└── requirements.txt    # Python 依赖包
```

## 安装依赖

```bash
pip install -r requirements.txt
```

## 编译 Protocol Buffers 文件

在运行服务器之前，需要先编译 `.proto` 文件生成 Python 代码：

```bash
# 安装 protobuf 编译器（如果还没有安装）
# Windows: 下载 protoc.exe 并添加到 PATH
# 或者使用 pip 安装: pip install grpcio-tools

# 编译 proto 文件
protoc --python_out=. game.proto
```

这将生成 `game_pb2.py` 文件。

## 运行服务器

```bash
python web_server.py
```

服务器将在 `0.0.0.0:8765` 上监听连接。

## 运行测试客户端

打开一个新的终端窗口：

```bash
python client.py
```

客户端会自动连接到服务器，发送加入消息，然后模拟一些游戏行为。

## Protocol Buffers 消息类型

### PlayerInfo
玩家基本信息，包含：
- player_id: 玩家唯一ID
- player_name: 玩家名称
- level: 玩家等级
- score: 玩家分数
- x, y: 玩家坐标

### ChatMessage
聊天消息，包含：
- player_id: 发送者ID
- player_name: 发送者名称
- content: 消息内容
- timestamp: 时间戳

### PlayerMove
玩家移动消息，包含：
- player_id: 玩家ID
- x, y: 目标坐标
- speed: 移动速度

### PlayerJoin / PlayerLeave
玩家加入/离开消息

### GameState
游戏状态，包含所有玩家的信息

### Heartbeat
心跳消息，用于保持连接

## 客户端交互

在客户端中，你可以：
- 直接输入文本发送聊天消息
- 输入 `move x y` 移动玩家位置（例如：`move 100 200`）
- 输入 `quit` 退出客户端

## 服务器功能

- 管理多个玩家连接
- 广播玩家加入/离开消息
- 实时同步玩家位置
- 聊天消息广播
- 心跳检测
- 完整的日志记录

## 学习要点

1. **Protocol Buffers 使用**：如何定义消息结构、序列化和反序列化
2. **WebSocket 异步编程**：使用 asyncio 处理多个并发连接
3. **消息路由**：根据消息类型分发到不同的处理函数
4. **状态管理**：维护玩家信息和游戏状态
5. **广播机制**：向所有连接的客户端发送消息
6. **错误处理**：处理连接断开、超时等异常情况