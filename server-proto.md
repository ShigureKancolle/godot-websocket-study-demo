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

### 消息类型(20 条,GameMessage oneof tag 1~20)
| 消息 | 字段 | 用途 |
|------|------|------|
| `EntityInfo` | entity_id, entity_type, x, y, facing, state, ai_state, player_name, moving, account_id | 实体状态(统一模型,player_name/moving/account_id 是 player 特有字段,其他类型不填)。ai_state 是 AI 状态(patrol/chase/attack/look_around,只有敌人填),和 state 动画状态是两个独立维度 |
| `PlayerJoin` | entity_info: EntityInfo | 加入请求/通知 |
| `PlayerLeave` | entity_id | 主动退出/断连通知 |
| `PlayerMove` | entity_id, x, y, speed, moving, dir_x, dir_y | 移动消息(双向语义,见下方说明) |
| `PlayerFacing` | entity_id, facing | 朝向事件(瞬时动作,和 PlayerMove 平行) |
| `AiStateChanged` | entity_id, ai_state | AI 状态变更(S2C 广播,敌人 AI 状态切换时实时发,和 PlayerFacing 平行;客户端据此切换视锥形态 normal/chase) |
| `AttackStart` | entity_id, atk_id | 攻击开始(C2S 发起 / S2C 广播,判定帧模型下 S2C 不带 hit_list) |
| `AttackHit` | attacker_id, hit_list, atk_id | 攻击命中(S2C 广播,判定帧到时通知命中列表。attacker_id 保持不变,语义就是攻击者) |
| `AttackEnd` | entity_id | 攻击结束(S2C 广播,客户端切回 IdleState) |
| `ChatMessage` | player_id, player_name, content, timestamp | 聊天事件(player_id 不改,聊天发送者就是玩家) |
| `GameState` | entities: repeated EntityInfo, timestamp | 全量状态快照(含玩家+木桩等所有实体) |
| `Heartbeat` | timestamp | 心跳保活 |
| `EntityDead` | entity_id, attacker_id, atk_id | 实体死亡(S2C 广播,tag=15)。服务端 apply_hurt 判定 hp<=0 且 can_die=True 时广播,客户端切 DeadState 播死亡动画 |
| `EntityRemove` | entity_id | 实体移除(S2C 广播,tag=16)。DeadTimer 到期后服务端调 remove_entity + 广播,客户端 queue_free 对应 Role |
| `GameMessage` | oneof message_type | 通用包装器 |

### 关键区分:EntityInfo(状态) vs PlayerMove/PlayerFacing(事件)
- EntityInfo 有 facing、state、ai_state 但没有 speed — 状态只存位置+朝向+动画/AI 状态
- EntityInfo.state 是动画状态(idle/run/attacking/hurt),是持久状态
- EntityInfo.ai_state 是 AI 状态(patrol/chase/attack/look_around,只有敌人有),和 state 是两个独立维度——动画状态里没有 chase,视锥形态必须靠 ai_state 切换
- EntityInfo.radius 是碰撞半径(用于攻击命中判定),不同实体类型可有不同半径
- EntityInfo.entity_type 决定行为能力(见 server-game.md 的 entity_config.py)
- PlayerMove 是**双向语义**消息(同一个 proto,C2S 和 S2C 字段含义不同,见下方"PlayerMove 双向语义"章节)
- PlayerMove.moving 两端都用:驱动动画状态 state=idle/run
- PlayerFacing 只有 facing — 独立朝向事件,和移动互不干扰
- 朝向和移动是两个独立状态维度——玩家可一边移动一边朝任意方向攻击
- 这个区分对应 GameRoom 的设计:状态 vs 事件不混(详见 server-game.md)

### PlayerMove 双向语义(本次重构:服务端权威移动)
同一个 PlayerMove 消息,C2S 和 S2C 字段含义不同:

| 字段 | C2S(客户端→服务端) | S2C(服务端→客户端) |
|------|--------------------|--------------------|
| `entity_id` | 必填 | 必填 |
| `dir_x` / `dir_y` | 必填(方向向量,-1~1) | 不填 |
| `moving` | 必填 | 必填 |
| `x` / `y` | 不填 | 必填(服务端算出的坐标) |
| `speed` | 已废弃(保留字段) | 不填 |

为什么改成双向语义:
- 旧模型:客户端发目标坐标(x/y)→ 服务端直接落地 → 广播
  问题:客户端 60Hz 算位置,服务端 30Hz tick 节流丢半,真实速度腰斩,每 tick 被拉回
- 新模型:客户端发方向(dir_x/dir_y)→ 服务端 apply_move_dir 记住方向 → tick_movement 每 tick 持续推进 → 广播算出的坐标
  服务端不依赖输入是否到达(记住方向后持续推进),无累积误差,无拉回
- `speed` 字段保留但废弃:避免删字段导致 proto 编号错乱,服务端不再读,改由 config_loader.get_speed(entity_type) 查配置

### EntityDead 和 EntityRemove 的关系(死亡流程)
死亡流程拆成两条消息,实现"立即判定死亡 + 延迟移除实体":
- **EntityDead(tag=15)**:服务端 apply_hurt 判定 hp<=0 且 can_die=True 时**立即广播**。客户端收到后设 state="dead" + 切 DeadState 播死亡动画,但**不移除节点**。
- **EntityRemove(tag=16)**:服务端 DeadTimer 到期后(时长 = `entity_config.get_dead_duration_ms()`)调 remove_entity + **广播**。客户端收到后 queue_free 对应 Role 节点。

为什么拆两条:让客户端有时间播死亡动画。服务端"立即判定死亡"但"延迟移除实体",和 hurt 的"立即设 state + 定时器到期恢复"是同一模式。

和 PlayerLeave 的区别:PlayerLeave 是主动退出/断连(实体消失,无死亡动画),EntityRemove 是死亡(播完动画后移除)。

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
| PlayerLeave | both | meta | true | 客户端主动退出房间时发 C2S,服务端移除实体后广播 S2C;断连时服务端也会广播 |
| PlayerMove | C2S | input | true | 客户端发请求,服务端 apply_move_dir 记住方向 + tick_movement 推进后转发 |
| PlayerFacing | C2S | input | true | 客户端发朝向请求,服务端 apply_facing 后转发。和 PlayerMove 平行 |
| AiStateChanged | S2C | event | false | 服务端广播敌人 AI 状态切换(EnemyAIMachine.change_state 真正切换时,由 GameServer 钩子广播)。客户端只改镜像 ai_state,渲染层切视锥形态 |
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
- 消息类型定义完整,EntityInfo 统一描述所有实体(字段含 entity_type/player_name/moving/account_id,radius 已删除)
- account_id:客户端本地存档生成的账号ID,随 PlayerJoin 传入,服务端优先用它作 player_id(跨会话稳定识别同一账号)
- ID 格式统一带类型前缀(player: / entity:)
- AttackStart/AttackHit/AttackEnd 三条攻击协议已加入(判定帧模型)
- 契约 20 条消息已登记,AttackHit 的 state_affecting=true(调 apply_hurt 改状态)
- EntityInfo 加 ai_state 字段 + AiStateChanged 消息(tag=20):AI 状态切换即广播,客户端据此切换敌人视锥形态(详见 tools/视锥渲染方案.md)
- 编译流程正常
## 生存协议扩展（PLAN-20260818-003）

生存协议由 `GameRoom.survival_run` 产生，客户端只接收镜像。`SurvivalState` 是服务端按 tick 发送的玩家快照；`ExperienceOrb` 是敌死后的表现事件，只有服务端确认球抵达才增加经验；`LevelUpChoices` 只描述指定玩家队列首项；`ChooseReward` 是客户端提交的下标请求，服务端检查玩家身份、队列存在、下标有效以及是否重复/过期；`SurvivalResult` 在全员死亡后发送封存的四项统计。

数据流为：GameRoom/Run 状态变更 → WebServer 广播 S2C → ClientStateMirror 发出信号 → HUD 展示；选择则反向为 HUD → ChooseReward C2S → handler/Run 校验 → GameRoom 应用奖励 → 新快照回传。协议源文件的字段注释和 oneof 23--27 tag 必须与双端保持一致，生成的 Python/GDScript 文件只能由既有工具产生。

### PLAN-20260818-004 验证记录

Godobuf 使用项目内 `godobuf_cmdln.gd` 和 Godot 4.6.3 headless 成功生成 `client/Script/gdproto/game.gd`；生成文件包含五个生存消息及 23--27 标签。Godot headless editor 检查、服务端 py_compile、protobuf 编译和 SurvivalRun smoke 均通过。配置同步脚本成功，抽查的 constants/entity 配置在 shared/server/client 三处哈希一致。
