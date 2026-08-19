# 客户端 HUD (client-hud)

覆盖:`client/prefab/hud/*` + `client/Script/UI/hud/*`
职责:局内 HUD 预制体 + 纯客户端显示控制。HUD 本身**不含任何网络逻辑**,所有数据通过公开 API 注入,由场景适配层把服务端 S2C 消息转成 API 调用。

## 文件清单

| 文件 | 职责 |
|------|------|
| [prefab/hud/HudMain.tscn](file:///d:/work/godot_demo/client/prefab/hud/HudMain.tscn) | HUD 预制体(挂 hud_main.gd) |
| [prefab/hud/TeammateItem.tscn](file:///d:/work/godot_demo/client/prefab/hud/TeammateItem.tscn) | 队友列表项(头像+名字+血条) |
| [Script/UI/hud/hud_main.gd](file:///d:/work/godot_demo/client/Script/UI/hud/hud_main.gd) | HUD 显示控制脚本(纯客户端) |

## 预制体结构

按 `UI初稿png.png` 布局(1152×720 视口,anchor 自适应 stretch expand):

```
HudMain (Control, 全屏, mouse_filter=IGNORE 不挡游戏点击)
├── Radar (Control, 自绘)               左上:雷达(中心=本地玩家,绿点队友/红点敌人)
├── TeammateList (VBoxContainer)        左上雷达下方:队友列表(头像+名字+红血条)
├── TopRightButtons (HBoxContainer)     右上:圆形按钮
│   ├── BtnRoleDetail  角色详情
│   ├── BtnLog         日志(切换 BattleLogPanel 显隐)
│   └── BtnMenu        菜单
├── BattleLogPanel (PanelContainer)     右侧:战斗日志(战斗记录滚动列表)
│   └── LogText (RichTextLabel, bbcode)
├── ChatPanel (PanelContainer)          左下:聊天框
│   └── VBox
│       ├── ChatText (RichTextLabel)    消息显示("名字: 内容")
│       └── InputRow
│           ├── InputLine (LineEdit)    "请输入文本"
│           └── BtnSend                 发送
└── PlayerStatus (Control)              底部居中:本地玩家状态区
    ├── IconRow
    │   ├── StatusRow (HBox,左)         限时状态图标(带倒计时,到点自动消失)
    │   └── BuffRow (HBox,右)           局内永久 buff 图标(无倒计时)
    ├── HpBar (ProgressBar,红)          血条
    └── EnergyBar (ProgressBar,绿)      经验条(当前经验/升级所需经验)
```

雷达说明:中心固定为本地玩家,注入的是**相对本地玩家的世界偏移**(像素),按 `radar_range_px`(默认 1000 像素量程)等比缩放到雷达面板上,超出量程的目标钳制显示在雷达边缘(保留方向)。雷达每帧重绘跟随实体移动,`radar_visible` 控制开关。

## 显示 API(适配层调用入口)

`hud_main.gd` 全部公开方法,**纯显示**,无副作用:

| 方法 | 参数 | 说明 |
|------|------|------|
| `set_radar_visible(v)` | `v: bool` | 雷达开关 |
| `update_radar_blip(entity_id, blip_type, rel_offset)` | String, int(BlipType), Vector2 | 更新/添加雷达目标;`rel_offset` = 目标世界坐标 - 本地玩家世界坐标(像素);type:0队友(绿) 1敌人(红) |
| `remove_radar_blip(entity_id)` | String | 移除雷达目标 |
| `set_radar_blips(entries)` | `Array[Dictionary]` | 全量设置雷达目标(`{entity_id, type, rel_x, rel_y}`) |
| `clear_radar_blips()` | | 清空雷达 |
| `set_local_hp(cur_hp, max_hp)` | int, int | 本地玩家血条(红) |
| `set_local_energy(cur, max_value)` | int, int | 兼容旧名；绿色经验条 |
| `set_local_experience(cur, next_value)` | int, int | 本地玩家经验/升级阈值 |
| `set_status_effects(effects)` | `Array[Dictionary]` | 全量设置限时状态(见下) |
| `add_status_effect(icon_id, remain_ms, icon=null)` | String, int, Texture2D/String | 添加/刷新单个限时状态(同 icon_id 覆盖倒计时) |
| `remove_status_effect(icon_id)` | String | 移除限时状态 |
| `set_buffs(buffs)` | `Array[Dictionary]` | 全量设置局内永久 buff |
| `add_buff(icon_id, icon=null, tips="")` | String, Texture2D/String, String | 添加永久 buff(tips 为悬停提示) |
| `remove_buff(icon_id)` | String | 移除 buff |
| `set_teammates(teammates)` | `Array[Dictionary]` | 全量设置队友列表 |
| `update_teammate(entity_id, data)` | String, Dictionary | 添加/更新单个队友(name/hp/max_hp/icon 可选) |
| `remove_teammate(entity_id)` | String | 移除队友 |
| `add_battle_log(text, log_type=0)` | String, int(LogType) | 追加战斗日志;类型:0普通 1伤害 2击杀 3死亡(着色) |
| `clear_battle_log()` | | 清空日志 |
| `set_battle_log_visible(v)` | bool | 日志面板显隐 |
| `add_chat_message(player_name, content)` | String, String | 显示一条聊天(本地回显/他人消息都用它) |
| `clear_chat()` | | 清空聊天显示 |

数据格式:

```
# 限时状态(显示层本地倒计时,到 0 自动消失;服务端周期同步会覆盖)
{"icon_id": "poison", "remain_ms": 5000, "total_ms": 5000}   # icon 字段可选,不传用占位
# 永久 buff
{"icon_id": "war_horn", "icon": "res://...", "tips": "攻击+10%"}
# 队友
{"entity_id": "p_1002", "name": "队友名字", "hp": 80, "max_hp": 100, "icon": "res://..."}
```

## 信号(上层适配层监听)

| 信号 | 参数 | 触发 |
|------|------|------|
| `chat_submitted(text)` | String | 聊天框回车/点发送。HUD 只发信号,**不直接发网络包** |
| `role_detail_requested` | 无 | 点「角色详情」 |
| `menu_requested` | 无 | 点「菜单」 |

注意:`icon_id` → 贴图的映射是**纯渲染层**的事(和地形 atlas 映射同分层原则),服务端只下发 `icon_id` 字符串,客户端自己维护映射表,不走协议。

## 服务端协议数据需求(待实现消息)

HUD 需要的数据、建议的消息定义。已有 `game.ChatMessage`(C2S 发 + S2C 广播回传)可直接复用,**需要新增**的是:

| 建议消息 | 方向 | 触发时机 | 用途 / 对应 HUD API |
|----------|------|----------|---------------------|
| `game.EntityVital` | S2C | 血量变化时广播(或并入现有战斗结算消息) | `set_local_hp` / `update_teammate` |
| `game.StatusEffectSync` | S2C | 状态获得/刷新/消失时(消失也可靠 remain_ms 到期本地消失) | `set_status_effects` |
| `game.BuffSync` | S2C | 局内永久 buff 获得/移除时 | `set_buffs` |
| `game.BattleLogEvent` | S2C | 伤害结算/击杀/死亡时广播 | `add_battle_log` |
| `game.TeamInfoSync` | S2C | 入队/离队/队友血量变化时 | `set_teammates` / `remove_teammate` |

雷达数据源:**无需新增消息**,直接复用现有实体位置同步(`PlayerJoin` / `PlayerMove` / `GameState`,经 `ClientStateMirror` 镜像)。适配层在 `_process` 里遍历镜像实体算相对偏移后调 `update_radar_blip(entity_id, type, target_pos - local_pos)`;敌我关系由服务端实体数据(`entity_type` 或队伍字段)决定,客户端只做显示。

建议字段:

```
# EntityVital —— 实体血能同步(本地玩家和队友共用)
entity_id: String
hp: int          # 当前血量
max_hp: int      # 最大血量
energy: int      # 旧字段，仅为兼容；生存 HUD 经验来自 SurvivalState
max_energy: int

# StatusEffectSync —— 限时状态全量同步(变化时下发全量,客户端直接 set_status_effects 替换)
entity_id: String
effects: Array
  └─ icon_id: String    # 状态图标ID(客户端映射贴图)
  └─ remain_ms: int     # 剩余毫秒
  └─ total_ms: int      # 总时长(可选,用于环形进度等扩展)

# BuffSync —— 局内永久 buff 全量同步
entity_id: String
buffs: Array
  └─ icon_id: String
  └─ tips: String       # 悬停说明(可选)

# BattleLogEvent —— 战斗日志事件
log_type: int    # 0普通 1伤害 2击杀 3死亡(与客户端 LogType 枚举对齐)
text: String     # 服务端拼好的展示文本,如 "玩家A 对 敌人A 造成了 32 点伤害"
# (可选)结构化字段,便于客户端自己拼/做击杀播报:
attacker_id: String
target_id: String
value: int       # 伤害值等

# TeamInfoSync —— 队伍信息全量同步
teammates: Array
  └─ entity_id: String
  └─ name: String
  └─ hp: int
  └─ max_hp: int
```

约定(沿用项目既有原则):
- **服务端权威**:HUD 不做任何计算,倒计时只影响显示,消失以服务端同步为准
- **entity_id 是唯一键**:本地玩家用 `ClientStateMirror.local_entity_id()` 区分自己 vs 队友
- 消息注册进 `messages.json` 契约(方向/类别),双端跑 proto 编译脚本生成代码(见 server-proto.md)

## 接入示例(场景适配层)

HUD 实例化到游戏场景的 UILayer 下,适配层负责「S2C 消息 → HUD API」:

```gdscript
# game_scene.gd(或独立 adapter 脚本)
var hud = preload("res://prefab/hud/HudMain.tscn").instantiate()
$UILayer.add_child(hud)

# 聊天发送:HUD 信号 → 已有 game.ChatMessage 协议
hud.chat_submitted.connect(func(text):
	MessageBus.instance().send("game.ChatMessage", {
		"content": text,
		"player_name": "测试名字",
		"player_id": ClientStateMirror.instance().local_entity_id(),
		"time": Time.get_unix_time_from_system(),
	}))

# S2C 消息 → HUD API(等协议实现后)
# MessageBus.instance().onproto("game.EntityVital", _on_entity_vital)
# func _on_entity_vital(msg):
#     var local_id = ClientStateMirror.instance().local_entity_id()
#     if msg["entity_id"] == local_id:
#         hud.set_local_hp(msg["hp"], msg["max_hp"])
#     else:
#         hud.update_teammate(msg["entity_id"], {"hp": msg["hp"], "max_hp": msg["max_hp"]})
```

雷达接入(复用现有 ClientStateMirror 位置数据):

```gdscript
# 适配层 _process 里每帧刷新雷达
func _process(_delta):
	var mirror = ClientStateMirror.instance()
	var local_id = mirror.local_entity_id()
	var local_pos = ... # 本地玩家世界坐标
	for info in mirror.all_entities():
		if info.entity_id == local_id:
			continue
		var blip_type = hud.BlipType.ENEMY if info.entity_type == "stake" else hud.BlipType.TEAMMATE
		hud.update_radar_blip(info.entity_id, blip_type, Vector2(info.x, info.y) - local_pos)
```

纯客户端自测(不接网络):拿到 hud 实例后直接调 API 即可,如 `hud.set_local_hp(80, 100)`、`hud.add_battle_log("玩家A 杀死了 敌人A", 2)`、`hud.update_radar_blip("e1", hud.BlipType.ENEMY, Vector2(300, -500))`。
## 生存 HUD 接入（PLAN-20260818-003）

HUD 消费客户端镜像信号更新经验条、等级、波次、暂停提示和奖励选择；选择按钮立即锁定且只发送一次 `ChooseReward`，不在本地应用奖励，等待服务端空候选确认后关闭。不得从本地计时推导权威状态。结算数据直接来自服务端结果，返回大厅时清除本局节点和统计。
