# coding=utf-8

"""
实体能力配置表
=============================================================================
所有可交互物体都是 Entity(玩家/木桩/箱子/陷阱...),区别在 entity_type 决定的行为能力。
本文件是"类型 → 能力"的映射表,GameRoom 的 apply_xxx 方法据此做能力校验。

设计原则
-----------------------------------------------------------------------------
- 能力是"白名单":某个 type 没列在表里 → 该 type 没有任何能力(安全的默认值)
- 状态变更方法先查能力再改状态:能拒绝就拒绝,而不是无脑改完才发现不该改
- 加新类型只改本文件 + ROLE_SHAPES,不用动 GameRoom/handlers 逻辑

能力字段含义
-----------------------------------------------------------------------------
- can_move:     能否移动(apply_move 校验)。玩家 True,木桩 False
- can_attack:   能否发起攻击(apply_attack_start 校验)。玩家 True,木桩 False
- can_be_hurt:  能否被攻击命中(get_attack_hits 过滤 + apply_attack_hurt 校验)。
                玩家/木桩 True,墙/水地 False(它们是地形,不是可破坏物)
- can_disconnect:是否会断连(cleanup_player 用,避免误删非玩家实体)。
                  玩家 True,其他都 False
=============================================================================
"""

from typing import Dict

# 能力配置:dataclass 替代嵌套 dict,字段更明确
from dataclasses import dataclass

class EntityType:
    PLAYER = "player"
    STAKE = "stake"


@dataclass
class EntityCapability:
    """实体能力描述"""
    can_move: bool = False
    can_attack: bool = False
    can_be_hurt: bool = False
    can_disconnect: bool = False


# 类型 → 能力映射表
# 加新类型只需在这里加一行
ENTITY_CAPABILITIES: Dict[str, EntityCapability] = {
    EntityType.PLAYER: EntityCapability(
        can_move=True,
        can_attack=True,
        can_be_hurt=True,
        can_disconnect=True,
    ),
    EntityType.STAKE: EntityCapability(
        can_move=False,
        can_attack=False,
        can_be_hurt=True,
        can_disconnect=False,
    ),
}


def get_capability(entity_type: str) -> EntityCapability:
    """
    取某个类型的能力配置。

    未列在表里的类型返回"零能力"配置(安全的默认值),
    这样加新类型时如果忘记配能力,它会自动变成"啥都不能干",而不是崩溃。
    """
    return ENTITY_CAPABILITIES.get(entity_type, EntityCapability())
