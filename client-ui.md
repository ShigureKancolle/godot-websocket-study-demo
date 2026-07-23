# 客户端 UI 和场景 (client-ui)

覆盖:`client/Script/UI/*` + `client/Script/signal/*` + `client/Script/init.gd` + `client/Scene/*` + `client/prefab/*` + `client/Script/tiledmap/*` + `client/tiledmap/*`
职责:UI 层管理、场景跳转、信号系统、预制体资源、无限地图生成

## 文件清单

### 脚本
| 文件 | 职责 |
|------|------|
| [init.gd](file:///d:/work2/godot_demo/client/Script/init.gd) | 启动场景脚本,直接跳转 MainScene |
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
| [tiledmap/ChunkGenerator.gd](file:///d:/work2/godot_demo/client/Script/tiledmap/ChunkGenerator.gd) | 纯函数式区块生成器:hash + value noise + 阈值切分地形类型 |
| [tiledmap/TerrainTransition.gd](file:///d:/work2/godot_demo/client/Script/tiledmap/TerrainTransition.gd) | 地块过渡算法:4 邻居位掩码 → 16 形态枚举,纯函数 |
| [tiledmap/InfiniteTileMap.gd](file:///d:/work2/godot_demo/client/Script/tiledmap/InfiniteTileMap.gd) | 无限地图节点:按 follow target 动态加载/卸载 chunk,含过渡贴图计算 |
| [tiledmap/DebugCursor.gd](file:///d:/work2/godot_demo/client/Script/tiledmap/DebugCursor.gd) | 调试游标:箭头键控制,作为 InfiniteTileMap 的 follow target 测试 |

### 场景和预制体
| 文件 | 职责 |
|------|------|
| [Scene/init.tscn](file:///d:/work2/godot_demo/client/Scene/init.tscn) | 启动场景(挂 init.gd) |
| [Scene/DeadManScene.tscn](file:///d:/work2/godot_demo/client/Scene/DeadManScene.tscn) | 木桩场景(挂 dead_man_scene.gd) |
| [prefab/main/MainScene.tscn](file:///d:/work2/godot_demo/client/prefab/main/MainScene.tscn) | 主界面预制体(挂 MainUI.gd) |
| [prefab/chat/ChatMain.tscn](file:///d:/work2/godot_demo/client/prefab/chat/ChatMain.tscn) | 聊天界面预制体 |
| [prefab/tips/ConfirmDialog.tscn](file:///d:/work2/godot_demo/client/prefab/tips/ConfirmDialog.tscn) | 确认对话框预制体 |
| [prefab/role/Role.tscn](file:///d:/work2/godot_demo/client/prefab/role/Role.tscn) | Role 预制体(当前空,实际用脚本 new()) |
| [prefab/CommonTexture/](file:///d:/work2/godot_demo/client/prefab/CommonTexture/) | 通用贴图资源(buttonRound/panel/bar 等) |
| [prefab/chat/Tex/](file:///d:/work2/godot_demo/client/prefab/chat/Tex/) | 聊天界面贴图 |
| [tiledmap/TiledMap.tscn](file:///d:/work2/godot_demo/client/tiledmap/TiledMap.tscn) | 无限地图调试场景(InfiniteTileMap + TileMapLayer + DebugCursor + Camera2D) |
| [tiledmap/Tileset.png](file:///d:/work2/godot_demo/client/tiledmap/Tileset.png) | 地形贴图 atlas(18×27 tile,每块 16×16) |

## init.gd — 启动跳转

挂载在 init.tscn 上。`_ready` 里直接 `change_scene_to_file.call_deferred("res://prefab/main/MainScene.tscn")`。

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
- `_on_click_game()` — instantiate DeadManScene.tscn 加到当前场景
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
3. **阶段3**:服务端实现相同生成算法(`server/game/map_generator.py`),用于移动合法性校验(apply_move 加碰撞检查)
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

`extends RefCounted`, `class_name ChunkGenerator`。无状态(除 seed/noise_scale/ca_threshold),纯算逻辑。

#### 算法分层
```
_hash_2d(seed, x, y) → [0, 1]      整数哈希(底层噪声源,含 MurmurHash3 finalizer)
    ↓
_value_noise_2d(x, y) → [0, 1]     网格点采样 + smoothstep 双线性插值
    ↓
_raw_type_at(wx, wy) → int         原始 noise 类型(无 CA),3 独立噪声通道决策
    ↓
get_tile_type(wx, wy) → int        带 CA 的单点查询(查 8 邻居原始 noise,应用1次 CA)
    ↓
generate_chunk(cx, cy) → PackedInt32Array  生成整个 chunk(索引 = ly*CHUNK_SIZE+lx)
```

#### 地形生成:独立噪声通道
用 3 个独立 noise 通道(同一 noise 函数,不同采样偏移)决定 4 种地形分布:
- `n_main = noise(x, y)`:主 noise,决定 SAND vs GRASS 基础地形
- `n_dirt = noise(x+10000, y+10000)`:独立 noise,决定 DIRT patch 分布
- `n_brick = noise(x+20000, y+20000)`:独立 noise,决定 BRICK patch 分布

决策逻辑(`_raw_type_at`):
```
n_main < 0.25  → SAND   (~25%,基础低地)
n_dirt > 0.83  → DIRT   (~12.5%,独立 patch)
n_brick > 0.80 → BRICK  (~12.5%,独立 patch)
其他           → GRASS  (~50%,默认)
```

为什么用独立噪声通道(而非单 noise 阈值切分):
- 单 noise + 阈值切分时,DIRT 和 BRICK 在 noise 值上相邻(如 0.6-0.8 vs 0.8-1.0)
- value noise 是连续函数,相邻区间必然空间相邻 → BRICK 总被 DIRT 包围
- 独立噪声通道让 DIRT 和 BRICK 各自从独立随机分布产生
- 两个独立分布在空间上"碰巧挨着"的概率极低(如同两次独立掷骰子都到6 = 1/36)
- 万一相邻,CA 后处理会把边界 tile 变成 GRASS(少数派被多数派吞并)

偏移常量(双端必须一致):DIRT=(10000,10000),BRICK=(20000,20000)。
偏移足够大确保采样网格完全不重叠(noise_scale=0.1 时 10000 = 10万 tile 距离)。

目标占比:GRASS 50% / SAND 25% / DIRT 12.5% / BRICK 12.5%(草地为主,其他平分)。

#### Cellular Automata 后处理
原 noise 地形太碎,会产生大量单格孤岛(一个 tile 被异类包围)和单边细条。
用户的 tileset 资源里,过渡贴图基于 form4(4 边掩码)和 form8(8 邻居掩码),
孤岛(form4=0)和单边细条(form4=1/2/4/8)会导致贴图匹配失败或视觉突兀;
"4 边同类但 4 角全异"的对角孤岛(form8=85/17/51 等"只有边没有角"的形态)
也会让 form8 匹配不稳定。

CA 规则:tile 的【4条边邻居】和【4个对角邻居】分别约束,
同类少于阈值(默认2)就变成周围多数类型。边和对角都至少 2 个同类才保留。
额外要求横向(左+右)≥1、竖向(上+下)≥1、斜向(4角)≥1,保证三方向都有连接。
阈值2 同时消除边方向孤岛(form4=0/1/2/4/8)和对角方向孤岛(form8 只有边没有角),
横竖斜约束消除"同类集中在单一方向"的细条(如纯水平/垂直直线),
让地块在 8 邻居意义上成片,form4 + form8 过渡贴图匹配都稳定。

为什么加横竖斜各≥1约束:
- 只看总数(4边≥2)允许"同类集中在单一方向"的情况,如横向2连但竖向0连(form4=10/LR)
- 这种 tile 虽然边同类总数≥2,但在某个方向完全断开,视觉上是细条
- 要求横竖斜各≥1,保证每个 tile 在三个方向都有连接,地块更成片

#### CA 迭代次数(_ca_iterations)
- 1 次(默认):消除一阶孤岛(raw noise 产生的孤岛)。邻居查询用原始 noise,跨 chunk 确定性简单。
- 2 次:额外消除二阶孤岛(CA 把 tile A 变成多数类型后,邻居 B 因 A 变了反而不满足 CA,
  但 1 次迭代不会重新检查 B;2 次迭代会重新检查 B)。
- 权衡:>1 次时 get_tile_type(单点查询,跨 chunk 用)仍只迭代 1 次,
  chunk 边缘 tile 的 CA 深度可能和内部不一致(二阶孤岛在边缘不被消除),但内部一致。
- generate_chunk 用外扩 raw 数组支持 N 次迭代,每轮从数组查邻居(不原地更新,避免顺序依赖)。

#### DIRT/BRICK 间隔后处理(_terrain_spacing)
DIRT 和 BRICK 是独立噪声通道产生的,理论上很少相邻。但用户要求"至少隔 2 个草地",
后处理扫描进一步保证:DIRT/BRICK 切比雪夫距离 ≤ _terrain_spacing 内有另一类型 → 变 GRASS。
- _terrain_spacing=2 → DIRT 和 BRICK 距离 ≥ 3(中间至少 2 个草地 tile)
- 只在 chunk 内部扫描,跨 chunk 边界的间隔可能不完美(边缘 tile 的邻居在另一个 chunk)
- generate_chunk 阶段 3 执行,从 CA 后数组查邻居(含外扩圈)

配置(ChunkGenerator 构造参数):
- `_ca_threshold`(默认2):边邻居同类 < this 或对角邻居同类 < this 就变。边和对角共用同一阈值。
- `_ca_iterations`(默认1,当前配置2):CA 迭代次数。调大→消除更多二阶孤岛,但边缘不一致风险增加。
- `_terrain_spacing`(默认0,当前配置2):DIRT/BRICK 最小间隔 tile 数。0=不检查。
- 多数类型统计用 8 邻居合并 counts(边+角),选最大者
- 平局处理:遍历 0..TERRAIN_COUNT-1,>max 才更新(不 >=),平局取小枚举值,确定性
- 邻居统计用 Array 索引访问(非 Dictionary),避免双端顺序差异

#### generate_chunk 三阶段流水线(性能优化)
独立噪声通道让 _raw_type_at 从 1 次 noise 变 3 次,若仍对每个 tile 调 9 次 _raw_type_at
= 256×9 = 2304 次 noise 调用,卡顿严重。优化:三阶段流水线,用外扩 raw 数组。

```
阶段1: 算 raw 数组(外扩 M 圈, M = max(_ca_iterations, _terrain_spacing))
       只算 (CS+2M)² 次 raw_type,而非 256×9
阶段2: CA 迭代 _ca_iterations 次(在 CS×CS 区域做,从数组查邻居)
       每轮用 current 算 next(不原地更新,避免顺序依赖)
阶段3: 间隔后处理(DIRT/BRICK 距离 ≤ _terrain_spacing 内有另一类型 → GRASS)
       从 CA 后数组查邻居(含外扩圈)
```

get_tile_type 保持单点查询版(跨 chunk 查询用,无法批量优化)。
两个路径共享 _apply_ca,逻辑一致。

#### V2: 确定性生长算法(种子+2×2 核心+确定性生长,替代 V1 的 noise+CA)
V1 的 noise+CA 有连锁问题:CA 改 tile A 后邻居 B 可能不满足 CA(二阶孤岛),
间隔后处理可能破坏 CA 结果。V2 改用"确定性生长",前置检查替代后置修补。

设计原则:
1. 种子是生长起点和身份标识,不是固定结构
2. 从 2×2 核心开始,通过确定性生长规则长成随机大小和形状
3. 种子点异类互斥(距离 ≥ 2*MAX_GROWTH_RADIUS+3),保证生长后规则 A 天然满足
4. 生长每步检查规则 B,不满足则跳过该位置
5. 任何 chunk 只看自己范围内的种子点,完美跨边界

规则 A(间隔):异类特殊地形切比雪夫距离 ≥ 3
  → 种子互斥距离 ≥ 2*MAX_GROWTH_RADIUS + 3,生长范围限制保证
规则 B(成片):8 邻域 ≥3 同类且不全在一条直线
  → 2×2 核心天然满足;生长时检查新 tile 放入后是否满足

算法流程:
```
get_tile_type_v2(wx, wy):
  1. 遍历 tile 周围 3×3 种子点(覆盖最大生长范围 5×5)
  2. 对每个激活种子,查缓存或模拟生长,得到斑块所有 tile
  3. 检查 tile 是否在某个斑块内 → 返回该地形类型
  4. 都不在 → 返回 GRASS

_check_seed_activation(sgx, sgy):
  1. hash(sgx, sgy) < SEED_ACTIVATION_RATE → 通过
  2. hash(sgx+1, sgy) 决定类型(SAND/DIRT/BRICK 各 1/3)
  3. 异类互斥:查 SEED_MUTUAL_DIST 范围内已有种子
     有异类且优先级低 → 不激活
  优先级:hash 值大的赢;同值时坐标小的赢(确定性)

_simulate_growth(sgx, sgy, terrain) — 先定大小 → 放置 → 修剪:
  1. 放 2×2 核心
  2. hash 决定目标格子数 target_size ∈ [MIN_PATCH_SIZE, MAX_PATCH_SIZE]
  3. 生长到 target_size（不检查规则 B，直接放入）
     - hash 决定是否继续生长(< GROW_PROB 才继续)
     - 收集候选位置(patch 边界 tile 的空邻居,在生长范围内)
     - hash 决定选哪个候选,直接放入
  4. 修剪:反复删除不满足规则 B 的 tile,直到所有剩余 tile 都满足
     - 2×2 核心天然满足规则 B,不会被删
     - 删一个 tile 后其他 tile 邻居数 -1,可能产生新的不满足,所以反复修剪
  5. 返回斑块的所有 tile(Dictionary[world_pos -> terrain])

为什么不边生长边检查:
  2×2 核心周围的候选位置同类邻居最多 2 个,规则 B 要求 ≥3,
  边生长边检查会 100% 失败。先放入再修剪,让 tile 互相支撑
  (A 放入后 B 的同类邻居 +1),能生长出更大斑块。

generate_chunk_v2 批量优化:
  不对每个 tile 调 get_tile_type_v2(会重复算种子激活),
  而是先算 chunk 范围内所有激活种子(3×3 种子网格),
  模拟它们的 patch,把 patch 内的 tile 写入 data。
  性能:只算 ~9 个种子的激活,而非 256 tile × 9 种子。

缓存层:
  _seed_patch_cache: 种子斑块缓存(模拟生长结果)
  _seed_activation_cache: 种子激活缓存(异类互斥检查结果,15×15 范围开销大)
```

V2 配置:
- `SEED_GRID_SIZE=8`:种子粗网格大小(每 8×8 tile 一个候选点)
- `SEED_CORE_SIZE=2`:种子核心大小(2×2 起步)
- `SEED_ACTIVATION_RATE=0.35`:种子激活概率
- `MAX_GROWTH_STEPS=12`:每个种子最多生长步数
- `MAX_GROWTH_RADIUS=2`:生长范围(种子原点 ±2 tile,斑块最大 5×5)
- `GROW_PROB=0.7`:每步生长概率(斑块大小)
- `SEED_MUTUAL_DIST=7`:异类种子最小距离 = 2*MAX_GROWTH_RADIUS + 3
- `MIN_PATCH_SIZE=4`:斑块最小格子数(= 2×2 核心)
- `MAX_PATCH_SIZE=12`:斑块最大格子数(5×5 区域内)

概率控制(用户需求:草50% / 其他平分):
- SEED_ACTIVATION_RATE 控制种子激活率(特殊地形覆盖率)
- 激活后按 1/3 概率分给 SAND/DIRT/BRICK
- GROW_PROB 控制每步生长概率(斑块大小)

双端一致:纯整数 hash,无 RNG,生长顺序由 hash 决定(确定性)。

V1/V2 切换:InfiniteTileMap._use_v2 开关。true=V2 确定性生长,false=V1 noise+CA。
当前配置 _use_v2=true,验证 OK 后会删除 V1 代码。

#### 为什么不用 Godot FastNoiseLite
1. FastNoiseLite 是 C++ 实现,Python 端要用同名库才能一致,引入第三方依赖且需测试验证
2. 自定义 hash + value noise 算法简单(~50 行),可读性高
3. 学习项目目标:理解 noise 原理,而非黑盒调用
4. 后续如需更平滑地形,可在本框架上加 octave(分形叠加)

### TerrainTransition.gd — 地块过渡算法

`extends RefCounted`, `class_name TerrainTransition`。纯函数,无状态。

#### 核心设计:8 邻居 256 形态 autotiling + 渐进式 fallback
8 邻居有 2^8 = 256 种组合,贴图配置工作量大。采用分层 fallback:

1. 优先查 8 位掩码(0-255)对应的专用贴图
2. 缺失 → 取 4 边位(bit 0,2,4,6)算 4 位形态(0-15),查边形态贴图
3. 还缺失 → 用纯地块贴图

用户可渐进配置:先配 16 种边形态(基础过渡),再逐步加角形态(内角/外角细节),最终配满 256 种。

#### 8 邻居位掩码(顺时针,从上开始)
```
bit 0 (1)   = 上      (0, -1)  边
bit 1 (2)   = 右上    (1, -1)  角
bit 2 (4)   = 右      (1, 0)   边
bit 3 (8)   = 右下    (1, 1)   角
bit 4 (16)  = 下      (0, 1)   边
bit 5 (32)  = 左下    (-1, 1)  角
bit 6 (64)  = 左      (-1, 0)  边
bit 7 (128) = 左上    (-1, -1) 角
→ 0~255 共 256 种形态。bit 0,2,4,6 是边,bit 1,3,5,7 是角
```

#### 4 边 fallback 形态(16 种)
从 8 位掩码提取 bit 0,2,4,6 重新组合成连续 4 位掩码(0-15):
```
0=ISOLATED  1=TOP   2=RIGHT  3=TR    4=BOTTOM  5=TB   6=BR    7=TBR
8=LEFT      9=TL    10=LR    11=TLR  12=BL     13=TBL  14=BLR  15=FULL
```

#### 架构位置(纯客户端渲染层)
```
ChunkGenerator 输出 tile 类型
    ↓
InfiniteTileMap._compute_tile_atlas:
    1. 查当前 tile 类型 T
    2. 查 8 邻居类型(跨 chunk 查询)
    3. 算 8 位掩码 → form8 (0-255)
    4. 查 _TERRAIN_TRANSITION_ATLAS_8[T][form8] —— 优先完整 8 邻居贴图
    5. 缺失 → 取边位算 form4 (0-15),查 _TERRAIN_EDGE_ATLAS[T][form4]
    6. 还缺失 → 用 _TERRAIN_ATLAS[T] 纯地块贴图
    ↓
set_cell 写入 TileMapLayer
```

服务端不变:ChunkGenerator 仍只输出 4 种类型,过渡是纯客户端渲染层的事。

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
`_TERRAIN_ATLAS` Dictionary 硬编码。**当前是猜测值,需在编辑器看 Tileset.png 后调整**:
```
GRASS → Vector2i(0, 0)
SAND  → Vector2i(4, 0)
DIRT  → Vector2i(0, 1)
BRICK → Vector2i(8, 0)
```

#### 过渡贴图映射表(三层 fallback)
- `_TERRAIN_TRANSITION_ATLAS_8`: `[地形类型][form8(0-255)] → atlas coord`,8 邻居完整贴图(选配,按需添加)
- `_TERRAIN_EDGE_ATLAS`: `[地形类型][form4(0-15)] → atlas coord`,4 边形态贴图(基础过渡,必配)
- `_TERRAIN_ATLAS`: `[地形类型] → atlas coord`,纯地块贴图(最终 fallback)

fallback 链:`_TERRAIN_TRANSITION_ATLAS_8` → `_TERRAIN_EDGE_ATLAS` → `_TERRAIN_ATLAS`

#### 地形变体贴图(_TERRAIN_VARIANTS)
某些地形有多个"平替"贴图(视觉上都是同类地形,只是纹理不同),用来打破视觉重复。
变体只对 **form8=255(8邻居全同类,真正的内部纯地块)** 应用。边缘/角/内凹角等过渡贴图不变体
(否则每种形态×每种变体配置量爆炸)。

配置结构:`[地形类型] → Array[{atlas: Vector2i, weight: int}]`
- 权重是相对值,不需要加起来等于 100。比如 [70,5,5,5,5,4,3,2,1] 和 [14,1,1,1,1,1,1,1,1] 效果相同
- 空数组 = 该地形不变体,用 `_TERRAIN_ATLAS[T]` 固定贴图

选择算法 `_pick_variant(terrain, tile_x, tile_y)`:
1. 用 `_variant_hash(tile_x, tile_y)` 算 hash → [0,1)
2. `hash * 总权重 = target`(落在 [0, 总权重) 区间)
3. 累加权重,target 落在哪个变体的区间就选哪个

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

**草地(GRASS)变体已配置**(9 个平替贴图,权重待用户调整,当前都是 1=均匀):
- (1,17) 主变体 / (4,20) (5,20) (6,8) (7,8) (8,8) (9,8) (10,8) (11,8)

**沙地/泥地/砖地** 变体待配(当前空数组=不变体,用固定纯地块贴图)。

**沙地(SAND)过渡贴图已配置**(用户确认坐标):3×3 布局共 9 块,映射到 9 种 form4 形态:

```
3×3 沙地过渡布局(周围草地,中间沙地):
  (4,9)=BR(6)   (6,9)=BLR(14)  (7,9)=BL(12)
  (4,10)=TBR(7) (6,10)=FULL(15) (7,10)=TBL(13)
  (4,11)=TR(3)  (6,11)=TLR(11)  (7,11)=TL(9)
```

形态映射:
- FULL(15)=(6,10) 中心,四周沙地
- BLR(14)=(6,9) 上边缘,缺上(上面草地,下/左/右沙地)
- TBR(7)=(4,10) 左边缘,缺左
- TBL(13)=(7,10) 右边缘,缺右
- TLR(11)=(6,11) 下边缘,缺下
- BR(6)=(4,9) 左上 corner,下/右连
- BL(12)=(7,9) 右上 corner,下/左连
- TR(3)=(4,11) 左下 corner,上/右连
- TL(9)=(7,11) 右下 corner,上/左连
- 缺失形态(细条/孤岛)=fallback 到 FULL(6,10)

凹直角填充(4块):(10,6),(11,6),(10,7),(11,7) 拼成"四周沙地中间草地"。
**已配置到 _TERRAIN_TRANSITION_ATLAS_8[SAND]**(沙地内凹角):
- 247=(10,6) 草在右下:7邻居沙+1角草,form8=255-8
- 223=(11,6) 草在左下:form8=255-32
- 253=(10,7) 草在右上:form8=255-2
- 127=(11,7) 草在左上:form8=255-128

8 邻居位掩码:上=1 右上=2 右=4 右下=8 下=16 左下=32 左=64 左上=128
这 4 块是沙地贴图(沙地视角),只有 1 个角是草地,其他 7 个方向都是沙地。
form8 = 255 - 单角 bit。
4 邻居 fallback 无法区分这种形态,必须用 8 邻居表。

**沙地(SAND)8 邻居过渡贴图已配置**(5×5 完整布局):

5×5 完整布局(4 外角纯草地 + 4 边沙地过渡 + 中间 3×3 沙地+草地凸角内凹角)。
这是用户确认的沙地完整贴图坐标,**之后加新地形时按此布局帮用户填类型**:

```
5×5 沙地贴图坐标完整布局:
     0           1           2           3           4
  +-----------+-----------+-----------+-----------+-----------+
0 | 草(1,17)  | 沙(4,9)   | 沙(6,9)   | 沙(7,9)   | 草(1,17)  |
  +-----------+-----------+-----------+-----------+-----------+
1 | 沙(4,9)   | 沙(11,7)  | 沙(6,10)  | 沙(10,7)  | 沙(7,9)   |
  +-----------+-----------+-----------+-----------+-----------+
2 | 沙(4,10)  | 沙(6,10)  | 沙(6,10)  | 沙(6,10)  | 沙(7,10)  |
  +-----------+-----------+-----------+-----------+-----------+
3 | 沙(4,11)  | 沙(11,6)  | 沙(6,10)  | 沙(10,6)  | 沙(7,11)  |
  +-----------+-----------+-----------+-----------+-----------+
4 | 草(1,17)  | 沙(4,11)  | 沙(6,11)  | 沙(7,11)  | 草(1,17)  |
  +-----------+-----------+-----------+-----------+-----------+
```

布局解读:
- **4 外角(0,0)(0,4)(4,0)(4,4)** = 草(1,17):纯草地,沙地视角这里是异类,不需要沙地贴图
- **4 边中点(0,2)(2,0)(2,4)(4,2)** = 沙地边过渡(4,9/6,9/7,9/4,10/7,10/4,11/6,11/7,11):对应 5×5 旧 3×3 布局的 9 块
- **4 边邻角(0,1)(0,3)(1,0)(1,4)(3,0)(3,4)(4,1)(4,3)** = 沙地边角(复用 4,9/7,9/4,11/7,11)
- **中间 3×3 的 4 个内角(1,1)(1,3)(3,1)(3,3)** = 沙地内凹角贴图(10,6/11,6/10,7/11,7):
  - (1,1)=沙(11,7) 草在外角(左上方向):form8=127(255-128)
  - (1,3)=沙(10,7) 草在外角(右上方向):form8=253(255-2)
  - (3,1)=沙(11,6) 草在外角(左下方向):form8=223(255-32)
  - (3,3)=沙(10,6) 草在外角(右下方向):form8=247(255-8)
- **中间 3×3 的中心和边中(1,2)(2,1)(2,2)(2,3)(3,2)** = 纯沙地(6,10):form8=255 全连

沙地 form8 映射(完整):
- 28=(4,9) 左上沙角:右+右下+下连
- 124=(6,9) 上边中:右+右下+下+左下+左连(缺上和上角)
- 112=(7,9) 右上沙角:下+左下+左连
- 7=(4,11) 左下沙角:上+右上+右连
- 199=(6,11) 下边中:上+右上+右+左+左上连(缺下和下角)
- 193=(7,11) 右下沙角:上+左+左上连
- 30/31/15=(4,10) 左边3格(不同 form8 但同贴图)
- 240/241/225=(7,10) 右边3格(不同 form8 但同贴图)
- 127=(11,7) 沙地内凹角,草在左上:7邻居沙+1角草
- 253=(10,7) 沙地内凹角,草在右上:7邻居沙+1角草
- 223=(11,6) 沙地内凹角,草在左下:7邻居沙+1角草
- 247=(10,6) 沙地内凹角,草在右下:7邻居沙+1角草
- 中间3×3中心和边中:fallback 到 form4 FULL(15)=(6,10),form8=255 也指向 (6,10)

8 邻居位掩码:上=1 右上=2 右=4 右下=8 下=16 左下=32 左=64 左上=128
沙地内凹角 form8 = 255 - 单角 bit(只有 1 个角是草地,其他 7 个方向都是沙地)。
4 邻居 fallback 无法区分内凹角形态,必须用 8 邻居表。

**草地(GRASS)/泥地(DIRT)/砖地(BRICK)** 仍为占位值,待用户确认坐标后按相同 5×5 布局配置。

#### 跨 chunk 邻居查询(_get_tile_type_at)
计算过渡形态时,8 邻居可能在相邻 chunk 里。查询策略:
- chunk 已加载 → 从 `_chunk_data_cache` 取(数组索引,快)
- chunk 未加载 → 直接调 `_generator.get_tile_type` 单点查询(带 CA)

为什么不用 generate_chunk 临时生成整个 chunk:
- 之前版本这样做导致性能爆炸:每个 tile 查 8 邻居,未命中 cache 时
  generate_chunk 生成 256 个 tile 但只用 1 个,49 chunk 加载 → 上亿次
  hash+noise 调用,编辑器卡死
- 改成单点查询:只算需要的那个 tile(含 CA,CA 只查 8 邻居原始 noise 不递归)
- 开销 = 9 次 hash+noise per tile,可接受

#### _compute_tile_atlas 的内部 tile 快速路径(性能优化)
`_compute_tile_atlas` 对每个 tile 查 8 邻居。chunk 内部 tile(非边缘,local_x/y 都在 1..14)
的 8 邻居全在同一 chunk 的 data 里,直接用数组索引取,跳过 `_get_tile_type_at`。

- 196/256=77% 的 tile 走快速路径(8 次数组索引,零函数调用)
- 60 个边缘 tile 走通用 `_get_tile_type_at`(邻居可能跨 chunk)
- 结果完全相同:data 里的值就是 get_tile_type 的输出

为什么需要这个优化:加 MurmurHash3 finalizer 后 hash 开销增加约 50%,
内部 tile 如果仍走 `_get_tile_type_at`(Dictionary 查找 + 函数调用),
累积开销变大。直接数组索引避免所有函数调用开销。

#### chunk 加载/卸载不需要刷新邻居（关键洞察）
加载/卸载 chunk A 后,**不需要刷新邻居边缘 tile**。原因:
- 地形是 seed 确定的纯函数
- 邻居 B 边缘 tile 查 A 方向邻居时:
  - A 已加载 → 走 `_chunk_data_cache` 数组索引
  - A 未加载 → 走 `_generator.get_tile_type` 单点查询
- 两者结果**必然相同**(generate_chunk 内部就是调 get_tile_type)
- 所以加载/卸载 A 不改变任何 tile 的过渡形态,刷新是纯浪费

这个洞察大幅简化了代码:删除了 `_refresh_neighbor_borders` 和
`_refresh_chunk_tiles`,加载/卸载变成独立操作,不需要联动刷新。

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
- 无限地图模块已实现阶段1(纯客户端独立调试):ChunkGenerator + InfiniteTileMap + DebugCursor + TerrainTransition,在 TiledMap.tscn 独立场景跑通。4 邻居 16 形态过渡算法已实现(占位贴图,待用户配真实过渡贴图)。未来接服务器双端一致生成(阶段2-4)
