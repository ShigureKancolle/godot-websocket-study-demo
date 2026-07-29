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

### 统一 Entity 模型(本次重构)
所有可交互物体(玩家/木桩/箱子/陷阱)统一用 `EntityInfo` 描述,不再区分 PlayerInfo/EntityInfo。
区别在 `entity_type` 字段决定行为能力(见 server-game.md 的 entity_config.py)。

### 消息类型(8 个)
| 消息 | 字段 | 用途 |
|------|------|------|
| `EntityInfo` | entity_id, entity_type, x, y, facing, state, radius, player_name, moving | 实体状态(统一模型,player_name/moving 是 player 特有字段,其他类型不填) |
| `PlayerJoin` | entity_info: EntityInfo | 加入请求/通知 |
| `PlayerLeave` | entity_id | 离开通知 |
| `PlayerMove` | entity_id, x, y, speed, moving | 移动事件(瞬时动作,带是否在移动) |
| `PlayerFacing` | entity_id, facing | 朝向事件(瞬时动作,和 PlayerMove 平行) |
| `AttackStart` | entity_id, atk_id | 攻击开始(C2S 发起 / S2C 广播,判定帧模型下 S2C 不带 hit_list) |
| `AttackHit` | attacker_id, hit_list, atk_id | 攻击命中(S2C 广播,判定帧到时通知命中列表。attacker_id 保持不变,语义就是攻击者) |
| `AttackEnd` | entity_id | 攻击结束(S2C 广播,客户端切回 IdleState) |
| `ChatMessage` | player_id, player_name, content, timestamp | 聊天事件(player_id 不改,聊天发送者就是玩家) |
| `GameState` | entities: repeated EntityInfo, timestamp | 全量状态快照(含玩家+木桩等所有实体) |
| `Heartbeat` | timestamp | 心跳保活 |
| `GameMessage` | oneof message_type | 通用包装器 |

### 关键区分:EntityInfo(状态) vs PlayerMove/PlayerFacing(事件)
- EntityInfo 有 facing、state 但没有 speed — 状态只存位置+朝向+动画状态
- EntityInfo.state 是动画状态(idle/run/attacking/hurt),是持久状态
- EntityInfo.radius 是碰撞半径(用于攻击命中判定),不同实体类型可有不同半径
- EntityInfo.entity_type 决定行为能力(见 server-game.md 的 entity_config.py)
- PlayerMove 有 speed、moving — 事件带瞬时属性
- PlayerMove.moving 是是否在移动,瞬时事件属性,服务端 apply_move 据 moving 设 EntityInfo.state
- PlayerFacing 只有 facing — 独立朝向事件,和移动互不干扰
- 朝向和移动是两个独立状态维度——玩家可一边移动一边朝任意方向攻击
- 这个区分对应 GameRoom 的设计:状态 vs 事件不混(详见 server-game.md)

### ID 格式约定
所有 entity_id 统一带类型前缀:
- `"player:uuid-xxx"` — 玩家(连接分配的 uuid 加前缀)
- `"entity:stake_1"` — 木桩(服务端硬编码 ID)
- `"entity:box_1"` — 箱子(未来扩展)

前缀的作用:
- 调试时一眼看出 ID 类型
- 避免不同类型 ID 撞名
- 不影响逻辑(统一用 entity_id 查表)

### package game
当前只有一个 package `game`。消息名可用短名(`PlayerJoin`)或全名(`game.PlayerJoin`)。多 package 时必须用全名。

## messages.json — 消息语义契约

proto 只描述消息"长什么样",契约描述消息"怎么用":
- **direction**: C2S(客户端发) / S2C(服务端发) / both(双向)
- **category**: meta(连接管理) / input(玩家输入) / event(瞬时事件) / snapshot(状态快照)
- **state_affecting**: true=handler 应调 GameRoom;false=handler 不碰 GameRoom

### 10 条消息契约
| 消息 | direction | category | state_affecting | 说明 |
|------|-----------|----------|-----------------|------|
| PlayerJoin | C2S | meta | true | 客户端发起,服务端处理后广播 |
| PlayerLeave | S2C | meta | true | 服务端广播,客户端不主动发 |
| PlayerMove | C2S | input | true | 客户端发请求,服务端 apply_move 后转发 |
| PlayerFacing | C2S | input | true | 客户端发朝向请求,服务端 apply_facing 后转发。和 PlayerMove 平行 |
| AttackStart | C2S | input | true | 客户端发攻击请求(带 atk_id),服务端 apply_attack_start 后广播 |
| AttackHit | S2C | event | true | 服务端判定帧到时调 apply_hurt 设被命中者 state=hurt 后广播命中列表 |
| AttackEnd | S2C | snapshot | true | 服务端攻击结束定时器到,调 apply_attack_end 设 state=idle 后广播 |
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
- 11 个消息类型定义完整,EntityInfo 统一描述所有实体(9 个字段含 entity_type/radius/player_name/moving)
- ID 格式统一带类型前缀(player: / entity:)
- AttackStart/AttackHit/AttackEnd 三条攻击协议已加入(判定帧模型)
- 契约 10 条消息已登记,AttackHit 的 state_affecting=true(调 apply_hurt 改状态)
- 编译流程正常
