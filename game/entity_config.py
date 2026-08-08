# coding=utf-8

"""
实体能力配置表
=============================================================================
所有可交互物体都是 Entity(玩家/木桩/箱子/陷阱...),区别在 entity_type 决定的行为能力。

配置数据来源
-----------------------------------------------------------------------------
本文件不再硬编码能力表,改从 config/config_loader.py 读取 JSON 配置(单数据源在
shared_config/entity_config.json,由 sync_config.py 同步过来)。
config_loader 返回的 EntityCapability 已经包含:
    - 能力字段(can_move / can_attack / can_be_hurt / can_disconnect)
    - 碰撞形状字段(body_shape / body_params)

本文件只是 config_loader 的薄包装,保持原有 API(get_capability)不变,
让 game_room / handlers 不需要关心配置是从哪来的。

设计原则
-----------------------------------------------------------------------------
- 能力是"白名单":某个 type 没列在表里 → 该 type 没有任何能力(安全的默认值)
- 状态变更方法先查能力再改状态:能拒绝就拒绝,而不是无脑改完才发现不该改
- 加新类型只改 shared_config/entity_config.json + 跑 sync_config.py,不用动代码

能力字段含义
-----------------------------------------------------------------------------
- can_move:     能否移动(apply_move_dir 校验)。玩家 True,木桩 False
- can_attack:   能否发起攻击(apply_attack_start 校验)。玩家 True,木桩 False
- can_be_hurt:  能否被攻击命中(get_attack_hits 过滤 + apply_hurt 校验)。
                玩家/木桩 True,墙/水地 False(它们是地形,不是可破坏物)
- can_disconnect:是否会断连(cleanup_player 用,避免误删非玩家实体)。
                  玩家 True,其他都 False
=============================================================================
"""

# 配置从 config_loader 加载(JSON 单数据源)
import config.config_loader as config_loader

# 复用 config_loader 的 EntityCapability 类型,保持 API 兼容
EntityCapability = config_loader.EntityCapability

# 类型常量(保持原有 API 兼容,外部代码引用 entity_config.EntityType.PLAYER 不用改)
class EntityType:
    PLAYER = "player"
    STAKE = "stake"


def get_capability(entity_type: str) -> EntityCapability:
    """
    取某个类型的能力配置(含碰撞形状)。

    未列在表里的类型返回"零能力"配置(安全的默认值),
    这样加新类型时如果忘记配能力,它会自动变成"啥都不能干",而不是崩溃。
    """
    return config_loader.get_capability(entity_type)
