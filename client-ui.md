# 客户端 UI 和场景 (client-ui)

覆盖:`client/Script/UI/*` + `client/Script/signal/*` + `client/Script/init.gd` + `client/Scene/*` + `client/prefab/*` + `client/Script/tiledmap/*` + `client/tiledmap/*`
职责:UI 层管理、场景跳转、信号系统、预制体资源、无限地图生成

## 文件清单

### 脚本
| 文件 | 职责 |
|------|------|
| [init.gd](file:///d:/work2/godot_demo/client/Script/init.gd) | 启动场景脚本,先跳 LoginScene(登录场景) |
| [Account/AccountManager.gd](file:///d:/work2/godot_demo/client/Script/Account/AccountManager.gd) | 本地用户存档(账号系统):名字→账号id 映射,登录/新建/最近登录排序,存 user://player_accounts.json |
| [UI/login/login_scene.gd](file:///d:/work2/godot_demo/client/Script/UI/login/login_scene.gd) | 登录场景逻辑:选择/输入名字→登录→进主界面 |
| [UI/UIManager.gd](file:///d:/work2/godot_demo/client/Script/UI/UIManager.gd) | autoload,窗口类型枚举(WindowType) |
| [UI/main/MainUI.gd](file:///d:/work2/godot_demo/client/Script/UI/main/MainUI.gd) | 主界面逻辑:连接状态显示+进聊天/进游戏按钮 |
| [UI/chat/chat_main.gd](file:///d:/work2/godot_demo/client/Script/UI/chat/chat_main.gd) | 聊天界面逻辑 |
| [UI/Base/ScorllDemo.gd](file:///d:/work2/godot_demo/client/Script/UI/Base/ScorllDemo.gd) | 滚动列表 demo |
| [UI/tips/confirm_dialog.gd](file:///d:/work2/godot_demo/client/Script/UI/tips/confirm_dialog.gd) | 确认对话框 |
| [signal/SignalMgr.gd](file:///d:/work2/godot_demo/client/Script/signal/SignalMgr.gd) | 信号管理器(autoload) |
| [signal/SignalConst.gd](file:///d:/work2/godot_demo/client/Script/signal/SignalConst.gd) | 信号名常量 |
| [UI/debug/DebugConsoleLoader.gd](file:///d:/work2/godot_demo/client/Script/UI/debug/DebugConsoleLoader.gd) | autoload,feature flag 检查,决定是否实例化控制台 |
| [UI/debug/DebugConsole.gd](file:///d:/work2/godot_demo/client/Script/UI/debug/DebugConsole.gd) | 调试控制台面板:`键唤出+UI构建+命令解析器 |
| [UI/debug/DebugCommands.gd](file:///d:/work2/godot_demo/client/Script/UI/debug/DebugCommands.gd) | 内置命令实现(state/me/ws/send/signal 等) |
| [UI/hud/hud_main.gd](file:///d:/work2/godot_demo/client/Script/UI/hud/hud_main.gd) | HUD 显示控制(纯客户端,详见 client-hud.md) |
| [tiledmap/ChunkGenerator.gd](file:///d:/work2/godot_demo/client/Script/tiledmap/ChunkGenerator.gd) | 纯函数式区块生成器:hash + value noise + 阈值切分地形类型(2×2 block 为单位) |
| [tiledmap/InfiniteTileMap.gd](file:///d:/work2/godot_demo/client/Script/tiledmap/InfiniteTileMap.gd) | 无限地图节点:按 follow target 动态加载/卸载 chunk,含草地过渡贴图计算 |
| [tiledmap/DebugCursor.gd](file:///d:/work2/godot_demo/client/Script/tiledmap/DebugCursor.gd) | 调试游标:箭头键控制,作为 InfiniteTileMap 的 follow target 测试 |
| [tiledmap/TestTiledSeed.gd](file:///d:/work2/godot_demo/client/Script/tiledmap/TestTiledSeed.gd) | 草地过渡贴图调试工具:画经典 form8 样式 + 旋转测试 + 鼠标悬停查 TiledCell 信息 |
| [tiledmap/TiledCell.gd](file:///d:/work2/godot_demo/client/Script/tiledmap/TiledCell.gd) | 单 tile 资源描述(assets_pos/dir/weight) |
| [tiledmap/MyTiledCell.gd](file:///d:/work2/godot_demo/client/Script/tiledmap/MyTiledCell.gd) | 2×2 block 资源描述(tiledtype + cell[4] 候选数组) |

### 场景和预制体
| 文件 | 职责 |
|------|------|
| [Scene/init.tscn](file:///d:/work2/godot_demo/client/Scene/init.tscn) | 启动场景(挂 init.gd) |
| [Scene/DeadManScene.tscn](file:///d:/work2/godot_demo/client/Scene/DeadManScene.tscn) | 木桩场景(挂 dead_man_scene.gd) |
| [prefab/login/LoginScene.tscn](file:///d:/work2/godot_demo/client/prefab/login/LoginScene.tscn) | 登录场景预制体(挂 login_scene.gd) |
| [prefab/main/MainScene.tscn](file:///d:/work2/godot_demo/client/prefab/main/MainScene.tscn) | 主界面预制体(挂 MainUI.gd) |
| [prefab/chat/ChatMain.tscn](file:///d:/work2/godot_demo/client/prefab/chat/ChatMain.tscn) | 聊天界面预制体 |
| [prefab/tips/ConfirmDialog.tscn](file:///d:/work2/godot_demo/client/prefab/tips/ConfirmDialog.tscn) | 确认对话框预制体 |
| [prefab/hud/HudMain.tscn](file:///d:/work2/godot_demo/client/prefab/hud/HudMain.tscn) | 局内 HUD 预制体(详见 client-hud.md) |
| [prefab/hud/TeammateItem.tscn](file:///d:/work2/godot_demo/client/prefab/hud/TeammateItem.tscn) | HUD 队友列表项预制体 |
| [prefab/role/Role.tscn](file:///d:/work2/godot_demo/client/prefab/role/Role.tscn) | Role 预制体(当前空,实际用脚本 new()) |
| [prefab/CommonTexture/](file:///d:/work2/godot_demo/client/prefab/CommonTexture/) | 通用贴图资源(buttonRound/panel/bar 等) |
| [prefab/chat/Tex/](file:///d:/work2/godot_demo/client/prefab/chat/Tex/) | 聊天界面贴图 |
| [tiledmap/TiledMap.tscn](file:///d:/work2/godot_demo/client/tiledmap/TiledMap.tscn) | 无限地图调试场景(InfiniteTileMap + TileMapLayer + DebugCursor + Camera2D) |
| [tiledmap/Tileset.png](file:///d:/work2/godot_demo/client/tiledmap/Tileset.png) | 地形贴图 atlas(18×27 tile,每块 16×16) |

## init.gd — 启动跳转

挂载在 init.tscn 上。`_ready` 里先跳 `res://prefab/login/LoginScene.tscn`(登录场景),选择完名字后再进 MainScene。

## LoginScene — 登录场景(login_scene.gd / LoginScene.tscn)

启动流程:`init.tscn → LoginScene.tscn(选择名字) → MainScene.tscn(主界面)`。
登录场景是**唯一入口**:未选择名字就无法进行任何其他操作,登录成功(输入/选中名字)后才跳转主界面。

节点:Title + AccLabel + NameInput(LineEdit 输入名字) + RecentSelect(OptionButton 最近登录下拉框) + LoginButton + LoginState(提示文案)。

流程:
- 玩家**只输入名字**登录。名字不存在 → `AccountManager.login` 分配新账号 id 并存档;存在 → 加载已有账号(更新最近登录时间)
- 下拉框列出本地存档全部账号(按最近登录时间降序,最近登录的默认选中并把名字填入输入框);没有存档则下拉框为空
- 下拉框点选某账号 → `quick_login` 快捷登录(不新建)并跳主界面;输入名字 + 点登录/回车 → `login`(新建或加载)并跳主界面
- 登录成功后 LoginState 显示"欢迎回来,xxx" / "已创建新账号,欢迎 xxx"

账号 id 由 `AccountManager._generate_id()` 生成(机器唯一id+时间戳+随机数,带 `player:` 前缀),登录时随 PlayerJoin 的 `entity_info.account_id` 发给服务端作 player_id——服务端因此能跨会话识别同一账号(详见 client-net.md)。

## UIManager.gd — 窗口类型枚举

`extends Node`,autoload。定义 `WindowType` 枚举:
- GAME=100(镂空,显示游戏内容)
- FULLWINDOW=200/FULLWINDOW2=300(全屏窗口)
- SUBWINDOW=400(弹窗)
- TIPS=500(提示/二确框)
- BUBBLE=600(气泡提示)

## MainUI.gd — 主界面

`extends Node`,挂载在 MainScene.tscn 上。

### 功能
- 显示 WebSocket 连接状态("连接中..." → "已连接" / "连接超时")
- 连接成功后显示两个按钮:E_Chat(进聊天)、E_Game(进游戏)
- E_Map(进地图)按钮一开始就可见——无限地图当前是纯客户端独立场景,不依赖 WebSocket
- 监听 `websocket_connected` 信号(WebScoketClient 连上后 fire)

### _process
连接中时每 0.3 秒切换 "连接中." / "连接中.." / "连接中...",30 秒后显示"连接超时"。

### 按钮处理
- `_on_click_chat()` — instantiate ChatMain.tscn 加到当前场景
- `_on_click_game()` — 发 PlayerJoin(带真实名字+账号id) → instantiate DeadManScene.tscn。登录已在 LoginScene 前置完成,此处仅防御校验
- `_on_click_game_real()` — 同上,进正式游戏场景 GameScene.tscn
- `_on_click_map()` — instantiate TiledMap.tscn 加到当前场景(纯客户端无限地图调试)

## SignalMgr / SignalConst — 信号系统

SignalMgr 是 autoload 单例,提供 `register_handler` / `fire_signal` 等方法。SignalConst 定义信号名常量。

当前使用的信号:
- `websocket_connected` — WebSocket 连上时 fire,MainUI 监听

## 调试控制台(可选,feature flag 控制)

覆盖:`client/Script/UI/debug/*`
职责:运行时调试入口——查看镜像状态、发任意 C2S 消息、触发信号测 UI

### 和服务端 console.py 的区别
服务端是 Python,用 `code.InteractiveConsole` 能执行任意表达式(真 REPL)。GDScript 没有 eval,所以客户端是**命令解析器**:输入 `命令名 + 参数`,匹配预定义命令执行,不是任意代码。结构上更像游戏里的「作弊码控制台」。

### 解耦设计(核心约束)
- 控制台只**单向调用**现有单例(StateMirror/MessageBus/MessageContract/SignalMgr/MyWebSocketClient),核心代码(Net/role/UI 主流程)完全不引用控制台,**改动为零**
- 三个文件都**不用 class_name**,用 `load()` 运行时加载:feature 关闭时连脚本都不加载,零开销
- 唯一接触点是 `DebugConsoleLoader` autoload,`_ready` 检查 `OS.has_feature("debug_console")`:不通过就 `queue_free()`,不实例化任何 UI

### 三个文件
| 文件 | 职责 |
|------|------|
| DebugConsoleLoader.gd | autoload:`_ready` 检查 feature flag,通过则 `load`+实例化 DebugConsole |
| DebugConsole.gd | extends CanvasLayer:`键唤出 + UI 构建(Panel/RichTextLabel/LineEdit) + 命令解析器 + 命令注册器 |
| DebugCommands.gd | extends RefCounted:内置命令实现(cmd_help/cmd_state/cmd_send 等) |

### 启用方式(两个开关,任一为 true 即启用)
Godot 有两套独立的 feature 机制,用途不同:

- **编辑器调试开关**(ProjectSettings 自定义键):`project.godot` 里 `[debug_console] enabled=true`。编辑器运行时 `OS.has_feature` 读不到 export preset 的 custom features,所以编辑器调试必须用 ProjectSettings。UI 编辑:项目设置(Project Settings)→ 右上角「高级/Advanced」→ 滚到底部能看到 [debug_console] 段。直接改 project.godot 文件也行。
- **打包开关**(export preset custom features):编辑器菜单 → 项目(Project)→ 导出(Export)→ 选预设 → 自定义功能/Custom Features 字段加 `debug_console`。打包后运行时 `OS.has_feature("debug_console")` 返回 true。

**为什么不用 config/features**:它是 Godot 引擎特性标记(如 "4.6"、"GL Compatibility"),自定义 tag 会触发「不支持的特性」警告,Godot 会自动删掉。

### 三种运行形态
- **编辑器运行调试**:`[debug_console] enabled=true`(默认已设为 true)
- **打包带控制台**:`enabled=false` + export preset custom features 加 `debug_console`
- **打包不带**:`enabled=false` + 不加 custom feature。autoload 自检不通过,queue_free,零开销

### 自动化打包
CI 维护两个 export preset(release 不带 feature / debug 带 feature),用 `godot --headless --export-release "preset_name"` 分别打包即可。无需脚本改文件,纯靠 Godot 原生 custom features 机制。

### 内置命令
| 命令 | 作用 | 类别 |
|------|------|------|
| `help` | 列出所有命令 | 元 |
| `clear` | 清屏 | 元 |
| `state` | 查看镜像所有玩家 | 查看 |
| `me` | 查看本地玩家ID和信息 | 查看 |
| `count` | 查看镜像玩家数 | 查看 |
| `ws` | 查看 WebSocket 连接状态 | 查看 |
| `msg` | 列出所有可发消息名 | 查看 |
| `bus` | 列出已注册 handler | 查看 |
| `contract [name]` | 查看契约(无参列全部,有参查单条) | 查看 |
| `send <name> <json>` | 发任意 C2S 消息(过出站方向校验,告警但不阻止) | 动作 |
| `signal <name> [json]` | 触发信号测 UI 反应 | 动作 |

命令格式:`<cmd> [arg1] [arg2] ...`,参数支持引号包围的带空格串(JSON 需用引号包住,如 `send PlayerMove '{"x":100}'`)。上下键翻输入历史。

### UI 结构与 ` 键监听
CanvasLayer(layer=100)→ 半透明 Panel(占屏幕下方 ~45%)→ MarginContainer → VBoxContainer(RichTextLabel 输出 + LineEdit 输入)。默认隐藏,按 ` 键切换。

` 键用 `_input`(GUI 之前)监听而非 `_unhandled_input`:LineEdit 聚焦时会在 GUI 阶段把 ` 消化成输入字符,`_unhandled_input` 收不到。`_input` 在 GUI 之前触发,能稳定捕获。

## 无限地图模块(tiledmap)

覆盖:`client/Script/tiledmap/*` + `client/tiledmap/*`
职责:区块化无限地图生成 + 动态加载/卸载 + 调试游标

### 核心设计:Chunk-based Infinite Tilemap

"无限地图"本质是**按需生成 + 按需卸载**:
```
follow target 在某坐标
    ↓
算出当前所在 chunk(16×16 tile 为一个 chunk)
    ↓
生成周围 (2*LOAD_RADIUS+1)^2 = 49 个 chunk(若未生成)
    ↓
卸载距离过远的 chunk
```

chunk 数据不存内存(TileMapLayer 已存 tile cell),`_loaded_chunks` 只记录"哪些 chunk 坐标已加载"。

### 当前阶段:纯客户端独立调试

当前实现是**纯客户端**,硬编码 seed=12345,在 [TiledMap.tscn](file:///d:/work2/godot_demo/client/tiledmap/TiledMap.tscn) 独立场景里用 DebugCursor(箭头键控制)测试无限地图。

未来演进路径(已和用户对齐):
1. **阶段1(当前)**:客户端独立生成,验证 chunk 加载/卸载逻辑
2. **阶段2**:服务器持有 seed,通过新增 MapInfo 消息(S2C/meta)下发,客户端调 `setup(seed)` 接收
3. **阶段3**:服务端实现相同生成算法(`server/game/map_generator.py`),用于移动合法性校验(apply_move_dir 加碰撞检查)
4. **阶段4**:加水的碰撞地形(当前只有无碰撞的草/泥/沙/砖)

### 双端一致生成的关键技术约束

选择"服务器持有种子,双端一致生成"架构,要求 Python 端和 GDScript 端对同一 chunk 产出**完全相同**的 tile 数据。实现选择:**自定义 hash + value noise**(而非 FastNoiseLite 库)。

跨语言一致性的关键约束(在 ChunkGenerator.gd 里):
1. 只用整数运算 + 32 位掩码(避免浮点精度差异、整数宽度差异)
2. 每个乘法后立即 `& 0xFFFFFFFF`(防止 64 位溢出在双端表现不同)
3. hash 函数用同一组魔法常数(73856093 / 19349663 / 83492791) + MurmurHash3 finalizer(0x85EBCA6B / 0xC2B2AE35),双端必须一字不差
4. value noise 的 floor + smoothstep + 双线性插值顺序双端一致
5. 地形阈值切分用 if-else(避免 Dictionary 迭代顺序问题)

#### hash 函数为什么加 finalizer
纯 XOR `(seed*A)^(x*B)^(y*C)` 没有位间扩散,分布质量低。相邻输入(如 x 和 x+1)只改变 hash 的部分位,输出相关性高,会导致某些区域系统性偏向某地形类型(如 seed=12345 时 (0,0) 附近 hash 值整体偏低,几乎没有砖地)。

MurmurHash3 finalizer(三轮 XOR-shift + 乘法)让"输入差 1 → 输出约一半位翻转",avalanche 属性让全局分布均匀。finalizer 是纯整数运算,Python 可直接实现,不破坏双端一致。

### 分层洞察:类型 vs atlas coord

- **服务端**只需知道"tile 类型 X 是否可碰撞"——不需要 atlas coord
- **客户端**需要知道"tile 类型 X 画成哪个 atlas coord"——纯渲染层的事
- 双端共享的是**地形类型枚举**(GRASS/SAND/DIRT/BRICK),atlas coord 映射只在客户端硬编码

### ChunkGenerator.gd — 纯函数式生成器

`extends RefCounted`, `class_name ChunkGenerator`。无状态(除 seed),纯算逻辑。

#### 算法分层
```
_hash_2d(seed, x, y) → [0, 1]      整数哈希(底层噪声源,含 MurmurHash3 finalizer)
    ↓
_value_noise_2d(x, y) → [0, 1]     网格点采样 + smoothstep 双线性插值
    ↓
get_block_type_v3(bx, by) → int    block 级地形类型(value noise 阈值切分)
    ↓
get_tile_type_v3(wx, wy) → int     单点查询(算 block 坐标后调 get_block_type_v3)
    ↓
generate_chunk_v3(cx, cy) → PackedInt32Array  生成整个 chunk(索引 = ly*CHUNK_SIZE+lx)
```

#### 2×2 block 生成算法(以 block 为最小单位,草地过渡贴图)
**以 2×2 tile 的 block 为最小生成单位,过渡贴图在草地上做**。

核心设计(用户决策):
1. **block 为最小单位**:每 2×2 tile 是一个 block,4 个 tile 同类型。block 以左上角为原点
2. **唯一规则**:异类非草地地形之间必须有草地间隔(当前只有 SAND+GRASS,自然满足)
3. **过渡在草地**:草地 block 根据 8 邻居 block 类型选不同贴图组合,适应任意形状
4. **无规则 B/无修剪**:2×2 block 天然成片,不需要规则 B 检查

block 坐标系:
- block 坐标 = floor(world_tile / BLOCK_SIZE),BLOCK_SIZE=2
- block 内局部坐标 = world_tile - block × 2 ∈ {0,1}
- block 原点 = block 坐标 × 2(左上角 tile 世界坐标)

V3 配置(ChunkGenerator):
- `BLOCK_SIZE=2` — block 边长
- `V3_NOISE_SCALE=0.15` — block type noise scale(每 ~7 block 一个周期)
- `V3_SAND_THRESHOLD=0.35` — SAND 覆盖率 ~35%

V3 函数(ChunkGenerator):
- `get_block_type_v3(bx, by)` — 查 block 类型(value noise)
- `get_tile_type_v3(wx, wy)` — 单点查询(算 block 坐标后调 get_block_type_v3)
- `generate_chunk_v3(cx, cy)` — 生成整个 chunk(每个 tile 调 get_tile_type_v3)

#### 草地过渡贴图系统

数据结构:
- `TiledCell`(TiledCell.gd):单 tile 资源描述
  - `assets_pos: Vector2i` — atlas 坐标
  - `dir: int` — 旋转次数(0/1/2/3 = 0°/90°/180°/270°)
  - `weight: int` — 抽选权重
- `MyTiledCell`(MyTiledCell.gd):2×2 block 资源描述
  - `tiledtype: int` — 地形类型
  - `cell: Array` — 长度 4 或 1
    - 长度 4: `[candidates(0,0), candidates(0,1), candidates(1,0), candidates(1,1)]`
    - 长度 1: 省略形式,4 个位置都用 cell[0]

草地形态表 `_GRASS_FORMS`(InfiniteTileMap):
- key = 旋转归一化后的 8 位掩码(邻居非草地 → bit=1)
- value = MyTiledCell
- 8 位掩码 bit 顺序:0=上 1=右上 2=右 3=右下 4=下 5=左下 6=左 7=左上
- 缺失的 form 自动 fallback 到 form 0(全草地)

旋转系统(减少配置量):
1. **8 位掩码旋转归一化**:`_normalize_form8` 取 4 次旋转中的最小值作为查表 key
2. **MyTiledCell 整体旋转**:`_rotate_my_tiled_cell` 每次 90° 顺时针
   - 4 个 cell 位置重排:旧(0,0)→新(0,1),旧(0,1)→新(1,1),旧(1,0)→新(0,0),旧(1,1)→新(1,0)
   - 每个 TiledCell 的 dir+1(mod 4)
3. **alternative_tile 动态创建**:`_get_or_create_alt_tile`
   - dir=0 → alt=0(默认)
   - dir=1 → transpose+flip_h(90° CW)
   - dir=2 → flip_h+flip_v(180°)
   - dir=3 → transpose+flip_v(270° CW)
   - 运行时调 `create_alternative_tile` 创建,无需在 TileSet 编辑器手动配置

渲染流程(InfiniteTileMap._compute_tile_atlas_v3):
```
1. 非草地 tile → 用 _TERRAIN_ATLAS 默认贴图,alt=0
2. 草地 tile:
   a. 算 block 坐标 (bx, by)
   b. 算 block 的 8 邻居掩码 form8
   c. 旋转归一化 → {base_form, rotations}
   d. 查 _GRASS_FORMS[base_form] → MyTiledCell(缺失 → fallback form 0)
   e. 旋转 MyTiledCell rotations 次
   f. 算 tile 在 block 内的局部位置 → local_idx(0-3)
   g. 从 MyTiledCell.cell[local_idx] 按权重抽 TiledCell
   h. 获取 alternative_tile(含旋转) → 返回 {atlas, alt}
```

⚠️ _GRASS_FORMS 当前为占位配置(全用纯草地贴图)。用户需根据 Tileset.png 配置:
- form 0:全草地(已配 3 个变体)
- form 1:上边 SAND(占位,待配过渡贴图)
- form 3:上+右 SAND(占位,待配过渡贴图)
- 其他基础形态(如 form 7, form 15 等)按需添加

#### 为什么不用 Godot FastNoiseLite
1. FastNoiseLite 是 C++ 实现,Python 端要用同名库才能一致,引入第三方依赖且需测试验证
2. 自定义 hash + value noise 算法简单(~50 行),可读性高
3. 学习项目目标:理解 noise 原理,而非黑盒调用
4. 后续如需更平滑地形,可在本框架上加 octave(分形叠加)

### InfiniteTileMap.gd — 无限地图节点

`extends Node2D`, `class_name InfiniteTileMap`。挂在 TiledMap.tscn 根节点。

#### 节点结构
```
TiledMap (InfiniteTileMap.gd)
├── TileMapLayer       复用 tscn 里已有的,含 TileSet 资源
├── DebugUI (CanvasLayer, layer=10)  不跟随相机移动的 UI 层
│   └── DebugDrawButton              调试边框开关按钮(左上角)
└── DebugCursor        调试游标(箭头键控制)
    └── Camera2D       相机跟随 cursor
```

#### 核心状态
- `_generator: ChunkGenerator` — 生成器(持有 seed)
- `_loaded_chunks: Dictionary` — 已加载 chunk 集合(Vector2i → true)
- `_chunk_data_cache: Dictionary` — chunk 类型数据缓存(Vector2i → PackedInt32Array),供跨 chunk 邻居查询
- `_follow_target: Node2D` — 跟随目标(DebugCursor 或未来玩家 Role)
- `_tile_size: int` — 从 TileSet 读取,默认 16
- `_debug_draw: bool` — 调试绘制开关,由 DebugDrawButton 切换

#### _process 流程
1. 获取 follow target 的 global_position
2. 算出当前所在 chunk(`_world_to_chunk`)
3. `_update_chunks_around(center_chunk)`:
   - 算出 LOAD_RADIUS 范围内的 needed 集合(49 个 chunk)
   - needed 里有但 _loaded_chunks 没有的 → `_load_chunk`(调 generator 生成 + set_cell 写入)
   - _loaded_chunks 里有但 needed 没有的 → `_unload_chunk`(set_cell(-1) 清除)

#### 调试绘制(_draw)
点击 DebugUI/DebugDrawButton 切换 `_debug_draw`。开启后:
- 画红色矩形边框(2px)标示每个已加载 chunk 的世界范围
- 画黄色文字 "chunk(cx, cy)" 在 chunk 左上角

实现细节:
- 字体用 `ThemeDB.fallback_font`(Node2D 没有主题系统,不能用 get_theme_default_font)
- `_load_chunk` / `_unload_chunk` 末尾调 `queue_redraw()`,确保 chunk 增删时调试边框实时更新
- 按钮文字反映当前状态:"调试边框: 开" / "调试边框: 关"
- 为什么用 `_draw` 而非 Line2D/Label 节点:chunk 数量动态变化,用节点要频繁增删;`_draw` 一次性画完,性能好且代码简单
- **z_index 陷阱**:TileMapLayer 是 InfiniteTileMap 的子节点,默认子节点绘制在父节点 `_draw` 之后,会盖住调试内容。
  - 踩坑:给父节点设 z_index=10 + z_as_relative=false 没用——因为子节点默认 z_as_relative=true,有效 z = 父 z + 自己 z = 10 + 0 = 10,两者相等仍按树顺序,子节点还是盖住父节点
  - 正确修复:把 TileMapLayer 的 z_index 设为 -1(z_as_relative=false),让它在 InfiniteTileMap(z=0)之下绘制,调试内容就画在 tile 上面
  - 为什么不画在 DebugUI(CanvasLayer)上:chunk 矩形是世界坐标内容,需跟随相机移动;CanvasLayer 是屏幕坐标,画上去要手动做世界→屏幕坐标变换(还要处理 zoom),反而复杂

#### 世界坐标 → chunk 坐标
```
世界像素 → tile 坐标:int(floor(world_pos / tile_size))
tile 坐标 → chunk 坐标:int(floor(tile_pos / CHUNK_SIZE))
```
用 floor 而非 int:负数坐标必须进更小的 chunk(如 tile -1 → chunk -1)

#### 地形 → atlas coord 映射
`_TERRAIN_ATLAS` Dictionary 硬编码(非草地 tile 的默认贴图):
```
GRASS → Vector2i(4, 14)  # 普通草地(纯地块 fallback)
SAND  → Vector2i(6, 10)  # 普通沙地(3×3 中心)
DIRT  → Vector2i(1, 10)  # 泥地(占位)
BRICK → Vector2i(9, 10)  # 砖地(占位)
```
草地 tile 通常不直接用此映射,而是走 `_GRASS_FORMS` 草地过渡贴图系统。

#### 草地变体选择(_pick_tiled_cell + _variant_hash)
草地的每个 block 位置,根据 form8 查到 MyTiledCell,MyTiledCell 的 `cell[local_idx]` 是
TiledCell 候选数组(每个候选含 `assets_pos / dir / weight`)。`_pick_tiled_cell` 按权重
抽取一个,用 `_variant_hash(tile_x, tile_y)` 确保**同一 tile 永远选同一候选**(移动时不跳变)。

- 权重是相对值,不需要加起来等于 100。比如 [300,50,50] 和 [6,1,1] 效果相同
- 单候选数组直接返回(零开销)
- 空候选数组返回默认 `TiledCell.new()`(空资源)

为什么用 tile 坐标 hash 而非随机数:
- 同一 tile 每次加载必须是同一变体(否则移动时 tile 跳变很难看)
- hash 是纯函数,跨 chunk 确定性,不需要 cache

为什么用 `_variant_hash` 而非 `ChunkGenerator._hash_2d`:
- `_hash_2d` 是 `(seed*A) ^ (x*B) ^ (y*C)` 简单 XOR 结构,设计用于 value noise(通过 smoothstep 插值产生平滑噪声)
- 变体选择是单点查询无插值,相邻 tile 的 hash 值相关性高,会导致权重小的变体大片连续出现(空间聚集)
- 变体是纯渲染层,不需要双端一致(服务端不关心贴图),可以用更强的 hash
- `_variant_hash` 用 MurmurHash3 finalizer(avalanche),相邻 tile 输入差 1 输出约一半位翻转,分布均匀

变体是纯渲染层的事,ChunkGenerator 不变(服务端不关心贴图)。
`_VARIANT_HASH_SEED=98765` 和地图 seed 分开,换地图 seed 不影响变体分布。

#### 跨 chunk 邻居查询(_get_tile_type_at)
计算草地形态时,8 邻居 block 可能在相邻 chunk 里。查询策略:
- chunk 已加载 → 从 `_chunk_data_cache` 取(数组索引,快)
- chunk 未加载 → 直接调 `_generator.get_tile_type_v3` 单点查询

为什么不用 generate_chunk_v3 临时生成整个 chunk:
- 之前版本这样做导致性能爆炸:每个 tile 查 8 邻居,未命中 cache 时
  generate_chunk_v3 生成 256 个 tile 但只用 1 个,49 chunk 加载 → 上亿次
  hash+noise 调用,编辑器卡死
- 改成单点查询:只算需要的那个 tile(算 block 坐标后调 get_block_type_v3)
- 开销 = 1 次 hash+noise per tile,可接受

#### chunk 加载/卸载不需要刷新邻居（关键洞察）
加载/卸载 chunk A 后,**不需要刷新邻居边缘 tile**。原因:
- 地形是 seed 确定的纯函数
- 邻居 B 边缘 tile 查 A 方向邻居时:
  - A 已加载 → 走 `_chunk_data_cache` 数组索引
  - A 未加载 → 走 `_generator.get_tile_type_v3` 单点查询
- 两者结果**必然相同**(generate_chunk_v3 内部就是调 get_tile_type_v3)
- 所以加载/卸载 A 不改变任何 tile 的过渡形态,刷新是纯浪费

加载/卸载是独立操作,不需要联动刷新。

#### 分帧加载(异步优化)
移动时跨 chunk 边界会一次性需要加载多个 chunk(沿移动方向的整列/行),
同步加载导致掉帧。改为分帧加载:

- `_pending_loads`: 待加载队列(按到 follow target 距离排序,近的优先)
- `_pending_unloads`: 待卸载队列
- `_update_chunks_around`: 只更新队列,不实际加载
- `_process_pending_chunks`: 每帧处理少量 chunk(MAX_LOADS_PER_FRAME=2,
  MAX_UNLOADS_PER_FRAME=4),把单帧卡顿分摊到多帧

效果:跨 chunk 边界时不再单帧加载 7 个 chunk,而是分 4 帧(2+2+2+1),
每帧开销小到不影响帧率。

#### set_cell 调用
- 加载:256 次 set_cell(coords, 0, atlas_coord) 每 chunk
- 卸载:256 次 set_cell(coords, -1) 每 chunk
- 邻居刷新:最多 8*256 次 set_cell(仅邻居已加载时)
- source_id = 0(TileSet 里只有一个 TileSetAtlasSource)
- source_id = -1 表示清除该 cell

### DebugCursor.gd — 调试游标

`extends Node2D`, `class_name DebugCursor`。箭头键/WASD 移动,速度 200 像素/秒。`_draw` 画红色圆圈+十字标记位置。

Camera2D 作为 DebugCursor 子节点,自动跟随 cursor 移动。

集成到 DeadManScene 后可删除本文件(或保留作开发调试工具)。

### 接入 DeadManScene 的方式(未来)
```gdscript
# 在 dead_man_scene.gd 里
var infinite_map = preload("res://Script/tiledmap/InfiniteTileMap.gd").new()
add_child(infinite_map)
var local_role = _roles[ClientStateMirror.local_player_id()]
infinite_map.set_follow_target(local_role)
```

## 场景跳转流程
```
启动 → init.tscn → init.gd._ready → MainScene.tscn
                                    ↓
                              MainUI 显示连接状态 + 三个按钮(E_Chat/E_Game/E_Map)
                                    ↓ WebSocket 连上
                              E_Chat / E_Game 变可见(E_Map 一开始就可见,不依赖 WebSocket)
                                    ↓ 点击 E_Game          ↓ 点击 E_Map
                              instantiate DeadManScene   instantiate TiledMap.tscn
                                    ↓                        ↓
                              dead_man_scene.gd 接 StateMirror  InfiniteTileMap + DebugCursor(箭头键移动)
                              信号显示玩家                       测试 chunk 动态加载/卸载
                                    ↓ 点击 E_Back
                              返回 MainScene
```

## 依赖关系
- 依赖 client-net:监听 `websocket_connected` 信号
- 依赖 client-role:instantiate DeadManScene
- addons/godobuf:proto 编译插件(生成 GDScript proto 代码,非运行时依赖)

## 当前状态
- 主界面+连接状态显示+场景跳转已实现
- 聊天界面已有(chat_main.gd)
- 木桩场景只做玩家同步,木桩玩法暂缓
- 调试控制台已实现(DebugConsole/DebugCommands/DebugConsoleLoader),默认关闭,需在 project features 或 export preset 加 `debug_console` 启用
- 无限地图模块已实现阶段1(纯客户端独立调试):ChunkGenerator + InfiniteTileMap + DebugCursor + TestTiledSeed,在 TiledMap.tscn 独立场景跑通。2×2 block 生成 + 草地过渡贴图系统(form8 旋转归一化 + MyTiledCell 候选权重抽取)已实现,占位贴图待用户配真实过渡贴图。未来接服务器双端一致生成(阶段2-4)
## 生存 UI 接入（PLAN-20260818-003）

## GameScene 诊断信息（PLAN-20260818-008）

正式 `GameScene/UILayer` 增加轻量诊断 Label，每秒最多刷新一次，显示 WebSocket RTT、Engine FPS 和 `ClientStateMirror.entity_count()`。断线显示 RTT `--`，未入房显示“未入房”；该脚本只读本地连接与镜像，不增加协议字段，也不参与服务端权威状态。

局内 UI 显示服务端 Run 时间、波次、经验和等级；收到候选后显示三选一。单人暂停由服务端状态驱动，多人模式不阻塞世界。结算页只显示存活时间、波次、击杀、伤害。
