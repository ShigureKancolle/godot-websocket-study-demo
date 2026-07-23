# 服务端 Proto 和契约 (server-proto)

覆盖:`server/proto/*`
职责:protobuf 消息定义、消息语义契约(messages.json)、编译脚本、生成代码

## 文件清单

| 文件 | 职责 |
|------|------|
| [proto/game.proto](file:///d:/work2/godot_demo/server/proto/game.proto) | protobuf 消息定义源文件 |
| [proto/messages.json](file:///d:/work2/godot_demo/server/proto/messages.json) | 消息语义契约(方向/类别/是否影响状态) |
| [proto/compile_proto.py](file:///d:/work2/godot_demo/server/proto/compile_proto.py) | 编译脚本(用 grpcio-tools) |
| [proto/generated/game_pb2.py](file:///d:/work2/godot_demo/server/proto/generated/game_pb2.py) | 生成的 Python protobuf 代码 |
| [proto/compile_proto.bat](file:///d:/work2/godot_demo/server/compile_proto.bat) | 编译快捷脚本 |

## game.proto — 消息定义

### 消息类型(8 个)
| 消息 | 字段 | 用途 |
|------|------|------|
| `PlayerInfo` | player_id, player_name, level, score, x, y, facing, state | 玩家状态(持续存在的属性,含朝向+动画状态) |
| `PlayerJoin` | player_info: PlayerInfo | 加入请求/通知 |
| `PlayerLeave` | player_id | 离开通知 |
| `PlayerMove` | player_id, x, y, speed, moving | 移动事件(瞬时动作,带是否在移动) |
| `PlayerFacing` | player_id, facing | 朝向事件(瞬时动作,和 PlayerMove 平行) |
| `ChatMessage` | player_id, player_name, content, timestamp | 聊天事件 |
| `GameState` | players: repeated PlayerInfo, timestamp | 全量状态快照 |
| `Heartbeat` | timestamp | 心跳保活 |
| `GameMessage` | oneof message_type | 通用包装器 |

### 关键区分:PlayerInfo(状态) vs PlayerMove/PlayerFacing(事件)
- PlayerInfo 有 facing、state 但没有 speed — 状态只存位置+朝向+动画状态
- PlayerInfo.state 是动画状态(idle/run/attack/hurt),是持久状态
- PlayerMove 有 speed、moving — 事件带瞬时属性
- PlayerMove.moving 是是否在移动,瞬时事件属性,服务端 apply_move 据 moving 设 PlayerInfo.state
- state 和 speed 一样遵循"状态 vs 事件"区分:moving 是事件属性不存入 PlayerInfo,state 是状态存入 PlayerInfo
- PlayerFacing 只有 facing — 独立朝向事件,和移动互不干扰
- 朝向和移动是两个独立状态维度——玩家可一边移动一边朝任意方向攻击
- 这个区分对应 GameRoom 的设计:状态 vs 事件不混(详见 server-game.md)

### package game
当前只有一个 package `game`。消息名可用短名(`PlayerJoin`)或全名(`game.PlayerJoin`)。多 package 时必须用全名。

## messages.json — 消息语义契约

proto 只描述消息"长什么样",契约描述消息"怎么用":
- **direction**: C2S(客户端发) / S2C(服务端发) / both(双向)
- **category**: meta(连接管理) / input(玩家输入) / event(瞬时事件) / snapshot(状态快照)
- **state_affecting**: true=handler 应调 GameRoom;false=handler 不碰 GameRoom

### 7 条消息契约
| 消息 | direction | category | state_affecting | 说明 |
|------|-----------|----------|-----------------|------|
| PlayerJoin | C2S | meta | true | 客户端发起,服务端处理后广播 |
| PlayerLeave | S2C | meta | true | 服务端广播,客户端不主动发 |
| PlayerMove | C2S | input | true | 客户端发请求,服务端 apply_move 后转发 |
| PlayerFacing | C2S | input | true | 客户端发朝向请求,服务端 apply_facing 后转发。和 PlayerMove 平行 |
| ChatMessage | both | event | false | 双向,不改状态 |
| GameState | S2C | snapshot | false | 快照是状态的表达不是变更 |
| Heartbeat | both | meta | false | 保活,不碰状态 |

### 契约共享机制
- 源文件在 `server/proto/messages.json`,和 game.proto 同目录
- 客户端副本在 `client/Script/proto/messages.json`(需手动复制)
- 理想:用 junction 把 server/proto 链到 client/Script/proto(见 client/create_proto_link.bat)
- 漂移风险后续可用"编译 proto 时自动同步 json"脚本消除,当前靠纪律保证

## compile_proto.py — 编译脚本

用 `grpcio-tools` 的 `grpc_tools.protoc` 编译,无需单独安装 protoc 编译器。

- `INPUT_DIR = "."` — proto 文件在脚本所在目录(server/proto/)
- `OUTPUT_DIR = "./generated"` — 输出到 server/proto/generated/
- 递归查找所有 .proto 文件
- 依赖:`pip install grpcio-tools`

运行:`py -3 proto\compile_proto.py`(从 server/ 目录)或 `compile_proto.bat`

## generated/game_pb2.py
- 由 compile_proto.py 生成,**不要手动编辑**
- 被 message_bus.py 通过 sys.path 注入后 import(详见 server-net.md 的"路径处理")
- 客户端对应物在 client/Script/gdproto/game.gd(godobuf 生成)

## 依赖关系
- 被 server-net 依赖:message_bus import game_pb2,message_contract 读 messages.json
- 被客户端复制:messages.json 和 game.proto 在 client/Script/proto/ 有副本

## 当前状态
- 8 个消息类型定义完整,PlayerInfo 含 8 个字段,覆盖当前所有功能
- 契约 6 条消息已登记
- 编译流程正常
