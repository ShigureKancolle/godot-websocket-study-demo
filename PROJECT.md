# 项目索引

## 项目目的
学习各种游戏开发流程的项目。通过实际实现玩家同步、状态管理、消息契约等,学习游戏服务端架构(服务器权威模型、状态同步、组件化实体等)。

## 修改决策
在进行代码修改之后同步到相应的md文件中，并且不论是注释还是md文件，都只保留最新版本的描述，旧版描述需要清理。

## 技术栈
- 客户端: Godot 4 (GDScript)
- 服务端: Python + websockets + protobuf
- 通信: WebSocket + Protobuf

## 目录结构概览
```
d:\work2\godot_demo\
├── docs/           # 本目录:项目文档(按功能子系统分模块 md)
├── shared_config/  # 双端共享配置单数据源(改完跑 tools/sync_config.py 同步)
│   ├── attack_config.json     # 攻击配置表(shape_list + duration/hit_time)
│   ├── entity_config.json     # 实体能力+碰撞形状表(can_xxx + body_shape/params)
│   └── constants.json         # 全局常量(HURT_DURATION_MS 等)
├── server/         # Python 服务端
│   ├── main.py             # 唯一入口(实例创建+handler注册+启动)
│   ├── hotreload_config.py # 热更模块配置(声明 HOT_MODULES 列表)
│   ├── net/                # 网络层(web_server/message_bus/message_contract)
│   ├── game/               # 游戏逻辑层(game_room 唯一状态持有者)
│   ├── config/             # 配置加载层(config_loader 读 config/*.json 构造对象)
│   ├── proto/              # proto 定义+契约+编译脚本+生成代码
│   ├── tools/              # 工具脚本(client.py 测试客户端 + hotreload.py 热更 + console.py 交互控制台)
│   └── extension_example.py # 独立示例,不参与主线
└── client/         # Godot 客户端
    ├── Script/
    │   ├── Net/            # 网络层(WebSocket/MessageBus/StateMirror/MessageContract)
    │   ├── role/           # 角色组件(Role/PlayerVisual/LocalPlayerController)
    │   ├── game/           # 战斗层(ConfigLoader配置访问 + collision碰撞 + attack_config命中点)
    │   ├── UI/             # UI 层(UIManager/MainUI/chat_main + debug 调试控制台)
    │   ├── proto/          # 客户端 proto 副本+契约副本
    │   ├── gdproto/        # godobuf 生成的 GDScript proto 代码
    │   ├── signal/         # 信号管理(SignalMgr/SignalConst)
    │   ├── dead_man_scene.gd # 木桩场景(当前只做玩家同步)
    │   └── init.gd         # 启动后直接跳 MainScene
    ├── res/config/         # 客户端配置副本(sync_config.py 从 shared_config 复制)
    ├── Scene/              # 场景文件(.tscn)
    ├── prefab/             # 预制体(MainScene/ChatMain/Role/ConfirmDialog/CommonTexture)
    └── project.godot
```

## 配置同步机制
双端共享配置(攻击参数/实体能力/常量)采用 **JSON 单数据源 + 复制** 方案:
1. 只在 `shared_config/*.json` 改配置
2. 跑 `python tools/sync_config.py` 同步到 `server/config/` 和 `client/res/config/`
3. 双端各自用 ConfigLoader(config_loader.py / ConfigLoader.gd)读取本地副本构造对象
4. JSON 里下划线开头字段(`_comment` / `_desc`)是注释,loader 跳过
5. angle 用角度存(人读直观),loader 构造时转弧度(代码计算用)

详见 [client-game.md](file:///d:/work2/godot_demo/docs/client-game.md) 的「配置同步方案」章节。

## 模块文档索引
按功能子系统划分,读哪个模块就加载对应 md:

| 模块 md | 覆盖范围 | 职责 |
|---------|---------|------|
| [server-net.md](file:///d:/work2/godot_demo/docs/server-net.md) | main.py + net/* | 服务端入口装配、WebSocket 服务、消息总线、契约校验 |
| [server-game.md](file:///d:/work2/godot_demo/docs/server-game.md) | game/* | 服务端唯一状态持有者 GameRoom |
| [server-proto.md](file:///d:/work2/godot_demo/docs/server-proto.md) | proto/* | proto 定义、消息契约 messages.json、编译脚本、生成代码 |
| [client-net.md](file:///d:/work2/godot_demo/docs/client-net.md) | Script/Net/* + proto + gdproto | 客户端 WebSocket 管理、消息总线、状态镜像、契约 |
| [client-role.md](file:///d:/work2/godot_demo/docs/client-role.md) | Script/role/* + dead_man_scene | 角色容器、视觉组件、本地控制、场景管理 Role |
| [client-game.md](file:///d:/work2/godot_demo/docs/client-game.md) | Script/game/* | 客户端战斗层:攻击配置镜像、命中坐标计算 |
| [client-ui.md](file:///d:/work2/godot_demo/docs/client-ui.md) | Script/UI/* + Scene + prefab + signal + init | UI 层、场景跳转、信号管理 |

## 全局架构
```
客户端 (Godot)                          服务端 (Python)
┌─────────────────────┐                ┌─────────────────────┐
│ LocalPlayerController│                │                     │
│  (读输入,发 PlayerMove)│                │  web_server.py      │
│         ↓            │   WebSocket    │  (handle_client)    │
│ MessageBus.gd        │ ←──────────→  │     ↓               │
│  (序列化/分发)        │   Protobuf    │  MessageBus         │
│         ↓            │                │  (dispatch 路由)     │
│ ClientStateMirror    │                │     ↓               │
│  (只读镜像)           │                │  handlers           │
│         ↓            │                │     ↓               │
│ Role (player_updated)│                │  GameRoom           │
│  (更新坐标+显示)      │                │  (唯一状态持有者)     │
└─────────────────────┘                └─────────────────────┘
```

### 状态同步模型(当前)
- **服务器权威**:客户端发的是「请求」不是「声明」,所有状态由服务端 GameRoom 决定
- **混合模型**:PlayerJoin/PlayerMove 用事件增量广播,GameState 用全量快照(仅给新玩家)
- **客户端半预测 + 软对账**:本地玩家用自己发出的方向自推进(消除 RTT 滞后与"追-停"顿挫),服务端广播坐标只做校验,误差超过阈值才平滑回正;远程实体用 lerp 插值(详见 client-role.md「位置同步」)
- **状态收口**:服务端 GameRoom 是唯一能改状态的地方;客户端 ClientStateMirror 只能镜像不能算

### 消息流向
- C2S: PlayerJoin, PlayerMove, ChatMessage, Heartbeat
- S2C: PlayerLeave, GameState, (PlayerJoin/PlayerMove/ChatMessage/Heartbeat 的广播回传)
- 方向校验:双端都加载 messages.json 契约,服务端校验入站方向,客户端校验出站方向

## 关键设计决策
1. **GameRoom 收口状态**:避免双端各写一份状态逻辑,handler 只做"取参数→调方法→发结果"
2. **ClientStateMirror 只读**:客户端无 apply_move_dir 等变更方法,结构上杜绝状态逻辑重复
3. **messages.json 契约共享**:proto 只描述形状,契约描述语义(方向/类别/是否影响状态)
4. **Python 热更约束**:所有项目模块用 `import xxx` + `xxx.def`,禁止 `from xxx import def`
5. **GDScript 单例选择**:纯数据容器(StateMirror/MessageContract)用 RefCounted+static;需 _process 的(WebScoketMgr)用 Node+autoload
6. **组件化 Role**:Role 是通用容器,按玩家类型挂不同组件(本地玩家+Controller,远程玩家只 Visual)
7. **JSON 单数据源配置同步**:双端共有配置(攻击/实体/常量)只改 `shared_config/*.json`,跑 `sync_config.py` 同步到双端,避免代码镜像易漏改
8. **碰撞形状是类型属性**:EntityInfo 不存 radius,改由 entity_type 查 entity_config 决定(所有玩家一样大,所有木桩一样大)
9. **ShapeType 共用**:原 AttackShapeType 改名 ShapeType,实体碰撞和攻击形状共用一套枚举

## 待办/暂缓
- 客户端预测+对账(留到真感觉到延迟时)
- 木桩玩法(暂缓)
- test_vectors.json 测试向量(暂缓)
