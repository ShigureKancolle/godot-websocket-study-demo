# 客户端战斗层(client/Script/game/)

## 覆盖范围
- `Script/game/ConfigLoader.gd` — 配置访问层:读 res://config/*.json 构造对象(双端共享配置)
- `Script/game/collision.gd` — 纯几何碰撞判定(完整复刻服务端 collision.py)
- `Script/game/attack_config.gd` — 攻击配置访问 + 命中坐标计算(转调 ConfigLoader)

## 定位
服务端是权威,命中判定在服务端做。但客户端收到 AttackHit 后要做视觉反馈(命中特效、伤害飘字等),需要知道"本次命中的攻击形状参数"和几何计算能力。

所以客户端复刻一份战斗层(碰撞 + 攻击配置),和服务端 `server/game/` 对称:
- 服务端 game/ = 状态权威 + 命中判定
- 客户端 game/ = 配置访问 + 视觉坐标计算

## 配置同步方案(本次重构新方案)

### 单数据源 + 复制(JSON)
双端共有配置(攻击参数/实体能力/常量)采用单数据源方案:

```
shared_config/                  ← 单数据源(只在这里改)
├── attack_config.json
├── entity_config.json
└── constants.json
        ↓ tools/sync_config.py
├── server/config/*.json        ← 服务端读取
└── client/res/config/*.json    ← 客户端读取(Godot 打包)
```

- 改配置只改 `shared_config/*.json` + 跑 `python tools/sync_config.py`
- 双端各自有 ConfigLoader 读取本地副本,构造对象返回
- JSON 里下划线开头字段(`_comment` / `_desc` / `_xxx`)是注释,loader 跳过
- angle 用角度存(人读直观),loader 构造时转弧度(代码计算用)

### 为什么选这个方案(而非代码镜像/代码生成/服务端下发)
- 代码镜像:易漏改,双端不一致出 bug
- 代码生成:需要构建步骤,学习项目过度工程化
- 服务端下发:增加启动延迟 + proto 复杂度,当前不需要
- JSON 共享 + 复制:简单、双端原生支持、无额外依赖

## 文件清单

| 文件 | 作用 |
|------|------|
| [game/ConfigLoader.gd](file:///d:/work2/godot_demo/client/Script/game/ConfigLoader.gd) | 配置访问层:读 res://config/*.json,构造 AttackConfig/EntityCapability 等对象返回 |
| [game/collision.gd](file:///d:/work2/godot_demo/client/Script/game/collision.gd) | 纯几何碰撞判定:形状定义(Circle/Sector)+ 相交判定函数(完整复刻服务端 collision.py) |
| [game/attack_config.gd](file:///d:/work2/godot_demo/client/Script/game/attack_config.gd) | ConfigLoader 的薄包装(class_name `AttackCalc`),保留 calc_hit_position 客户端特有几何计算 |

## ConfigLoader.gd — 配置访问层

### 和服务端 config_loader.py 对称
- 数据结构镜像:ShapeType / ShapeParams / SectorParams / CircleParams / RectParams / AttackShape / AttackConfig / EntityCapability / CombatStats
- API 镜像:`get_attack_config` / `get_capability` / `get_combat_stats` / `get_constant` / `get_hurt_duration_ms`
- 数据来源:`res://config/*.json`(sync_config.py 从 shared_config/ 复制)

### inner class 数据结构
| 类 | 说明 |
|---|---|
| `ShapeParams` | 形状参数基类(空) |
| `SectorParams` | 扇形参数(radius / angle 弧度) |
| `CircleParams` | 圆形参数(radius) |
| `RectParams` | 矩形参数(width / height,未来扩展) |
| `AttackShape` | 单个攻击形状(shape / shape_params / duration / hit_time) |
| `AttackConfig` | 攻击配置(shape_list 数组) |
| `EntityCapability` | 实体能力 + 碰撞形状 + 基础战斗属性(can_move/can_attack/can_be_hurt/can_disconnect + body_shape/body_params + combat_stats) |
| `CombatStats` | 类型级基础战斗属性(max_hp/attack_power/defense);EntityInfo 初始化时拷贝一份作实例运行时状态 |
### const 常量
| 常量 | 值 |
|---|---|
| `ShapeType_SECTOR` | "sector" |
| `ShapeType_RECT` | "rect" |
| `ShapeType_CIRCLE` | "circle" |
| `ShapeType_RING` | "ring" |

### GDScript 特殊处理
1. **const 不能 new 对象**:配置表用 `static var + _ensure_cache()` 懒加载,首次访问时构造
2. **角度→弧度转换**:`deg_to_rad(deg) = deg * PI / 180.0`
3. **JSON 解析**:`JSON.new()` + `parse_string()`,失败返回空字典兜底

### 对外 API
| 方法 | 作用 |
|------|------|
| `get_attack_config(atk_id) -> AttackConfig` | 取攻击配置;未知返回 null |
| `get_all_attack_configs() -> Dictionary` | 取全部攻击配置(只读) |
| `get_capability(entity_type) -> EntityCapability` | 取实体能力+形状+战斗属性;未知返回零能力配置 |
| `get_combat_stats(entity_type) -> CombatStats` | 取实体基础战斗属性;未知返回零值(max_hp=0 → 直接死,bug 早暴露) |
| `get_constant(name, default) -> Variant` | 取全局常量 |
| `get_hurt_duration_ms() -> int` | 取 hurt 硬直时长(语法糖) |

## collision.gd

### 设计原则
纯几何碰撞判定,不依赖场景/状态/网络,可独立单元测试。复刻服务端 [collision.py](file:///d:/work2/godot_demo/server/game/collision.py) 的全部函数,算法逻辑一致。

### 和服务端 collision.py 的差异
| 方面 | 服务端 Python | 客户端 GDScript |
|---|---|---|
| 数据结构 | `@dataclass` | `inner class + extends RefCounted` |
| 坐标类型 | `tuple[float, float]` | `Vector2`(更符合 Godot 习惯) |
| 距离计算 | `math.hypot(dx, dy)` | `Vector2.length()` / `Vector2.distance_to()` |
| 角度计算 | `math.atan2(dy, dx)` | `Vector2.angle()` |
| 取模 | `%` | `fmod()`(浮点取模) |

几何算法逻辑完全一致,只是语法适配。

### 形状定义(inner class)
| 类 | 作用 |
|---|---|
| `Shape` | 形状基类,pos 是锚点 |
| `Circle` | 圆形(extends Shape),用于被攻击目标体积 |
| `Sector` | 扇形(extends Shape),用于攻击范围 |

### 对外 API
| 方法 | 作用 |
|------|------|
| `intersect_circle_circle(c1, c2) -> bool` | 圆-圆相交 |
| `intersect_circle_sector(circle, sector) -> bool` | 圆-扇形相交(攻击命中判定用) |
| `intersect_sector_sector(s1, s2) -> bool` | 扇形-扇形相交(当前未用,留作未来攻击互碰) |

内部辅助函数(`_` 前缀)不对外暴露,和服务端 collision.py 一致。

## attack_config.gd — ConfigLoader 薄包装(class_name AttackCalc)

### 为什么还需要这个文件
ConfigLoader 是通用配置访问层(攻击+实体+常量都走它),attack_config.gd(class_name `AttackCalc`)专注攻击配置语义 + 命中点几何计算。

### 为什么 class_name 用 AttackCalc 而非 AttackConfig
ConfigLoader.gd 里有 inner class `AttackConfig`(和服务端 config_loader.py 的 `AttackConfig` dataclass 对称)。如果本文件也用 `class_name AttackConfig`,全局类会隐藏 inner class,Godot 报警告 "hides a global script class"。改用 `AttackCalc` 避免冲突,且更准确反映职责(命中点**计算**)。

### 对外 API
| 方法 | 作用 |
|------|------|
| `get_config(atk_id) -> AttackConfig` | 转调 ConfigLoader.get_attack_config |
| `get_shape(atk_id, shape_index) -> AttackShape` | 取第 shape_index 个形状;越界返回 null |
| `calc_hit_position(attacker_pos, facing, atk_id, shape_index) -> Vector2` | 算命中特效坐标 |

### calc_hit_position 算法
```gdscript
static func calc_hit_position(attacker_pos: Vector2, attacker_facing: float, atk_id: int, shape_index: int) -> Vector2
```

**命中点选择**:`attacker_pos + Vector2.RIGHT.rotated(facing) * (radius / 2.0)`

为什么用 `radius / 2`:
- 用 `radius`(攻击范围最远端):短半径显得太近、长半径跑太远,视觉不自然
- 用 `0`(攻击者圆心):特效在脚下,不合理
- 用 `radius / 2`(攻击范围中间):视觉最自然

### shape_index 参数
来自 AttackHit 消息的 `atk_shape_idx` 字段(协议字段,标识本次命中是 atk_id 的第几段 shape)。
多段攻击(如 1002 双段斩)形状不同时,客户端据此从 shape_list 取对应 AttackShape 算坐标。

### facing 弧度的获取
PlayerVisual 没缓存原始 facing 弧度(只存四方向字符串 `_facing_dir`),但 [update_facing 里 `_facing_arrow.rotation = facing`](file:///d:/work2/godot_demo/client/Script/role/PlayerVisual.gd),所以箭头节点的 rotation 就是原始弧度。

调用示例:
```gdscript
var attacker_role = _entities[attack_hit_data.attacker_id]
var hit_pos = AttackCalc.calc_hit_position(
    attacker_role.position,
    attacker_role.get_node("PlayerVisual").get_node("FacingArrow").rotation,
    attack_hit_data.atk_id,
    attack_hit_data.atk_shape_idx  # AttackHit 消息字段
)
```

更干净的做法是在 PlayerVisual 加 `var _facing: float = 0.0` 缓存 + 提供 `get_facing()` getter,避免依赖箭头节点的 rotation。这属于 role 模块的事,留待按需改造。

## 使用场景
当前用途:dead_man_scene 收到 AttackHit 后,调 calc_hit_position 算命中特效坐标,在 EffectsRoot 下实例化特效。

未来扩展:
- 伤害飘字坐标(可复用 calc_hit_position,或加偏移)
- 攻击范围调试可视化(用 angle 字段 + collision.Sector 画扇形辅助线)
- 多种攻击形状的命中坐标计算(目前只支持扇形)
- 攻击互碰判定(用 intersect_sector_sector,如弹反/格挡)

## 同步约束
**双端配置必须一致**:改配置只改 `shared_config/*.json`,然后跑 `python tools/sync_config.py`。
**数据结构镜像约束**:加字段/改字段要同时改 config_loader.py 和 ConfigLoader.gd。
