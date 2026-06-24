# coding=utf-8

"""
扩展示例：如何添加新的消息类型

这个文件展示了使用消息处理器注册机制后，如何优雅地添加新的消息类型。
你不需要修改现有的 if-else 分支，只需：
1. 在 .proto 文件中定义新消息
2. 编译 .proto 文件
3. 在服务器和客户端中添加对应的处理器方法
4. 在 _setup_handlers() 中注册新处理器

"""

# ==================== 步骤 1: 在 game.proto 中定义新消息 ====================
# 在 game.proto 文件中添加以下内容：

"""
// 玩家攻击消息
message PlayerAttack {
  string attacker_id = 1;      // 攻击者ID
  string target_id = 2;        // 目标ID
  int32 damage = 3;            // 伤害值
  int32 attack_type = 4;       // 攻击类型
}

// 玩家升级消息
message PlayerLevelUp {
  string player_id = 1;        // 玩家ID
  int32 new_level = 2;         // 新等级
  int32 exp_gained = 3;        // 获得的经验值
}

// 在 GameMessage 的 oneof 中添加：
//   PlayerAttack player_attack = 7;
//   PlayerLevelUp player_level_up = 8;
"""

# ==================== 步骤 2: 编译 proto 文件 ====================
# 运行命令: protoc --python_out=. game.proto


# ==================== 步骤 3: 在服务器中添加处理器 ====================
# 在 web_server.py 的 GameServer 类中添加以下方法：

class GameServer:
    # ... 其他代码 ...
    
    # ========== 玩家攻击消息处理器 ==========
    async def handle_player_attack(self, player_id: str, attack_msg):
        """
        处理玩家攻击消息
        计算伤害并广播给相关玩家
        """
        # 验证攻击者
        if player_id not in self.player_infos:
            logger.warning(f"未知的攻击者: {player_id}")
            return
        
        # 验证目标
        if attack_msg.target_id not in self.player_infos:
            logger.warning(f"攻击目标不存在: {attack_msg.target_id}")
            return
        
        # 计算伤害（这里可以添加更复杂的伤害计算逻辑）
        damage = attack_msg.damage
        attacker_info = self.player_infos[player_id]
        target_info = self.player_infos[attack_msg.target_id]
        
        logger.info(f"玩家 {attacker_info.player_name} 攻击了 {target_info.player_name}，造成 {damage} 点伤害")
        
        # 广播攻击消息给所有玩家
        await self.broadcast_message(attack_msg)
    
    # ========== 玩家升级消息处理器 ==========
    async def handle_player_level_up(self, player_id: str, level_up_msg):
        """
        处理玩家升级消息
        更新玩家等级并广播
        """
        if player_id not in self.player_infos:
            logger.warning(f"未知的玩家: {player_id}")
            return
        
        # 更新玩家等级
        self.player_infos[player_id].level = level_up_msg.new_level
        
        player_info = self.player_infos[player_id]
        logger.info(f"玩家 {player_info.player_name} 升级到 {level_up_msg.new_level} 级！")
        
        # 广播升级消息给所有玩家
        await self.broadcast_message(level_up_msg)
    
    # ========== 在 _setup_handlers() 中注册新处理器 ==========
    def _setup_handlers(self):
        """手动注册所有消息处理器"""
        # 原有的处理器
        self._register_method_handler('player_move', self.handle_player_move)
        self._register_method_handler('chat_message', self.handle_chat_message)
        self._register_method_handler('heartbeat', self.handle_heartbeat)
        
        # 新增的处理器 - 只需添加这两行！
        self._register_method_handler('player_attack', self.handle_player_attack)
        self._register_method_handler('player_level_up', self.handle_player_level_up)


# ==================== 步骤 4: 在客户端中添加处理器 ====================
# 在 client.py 的 GameClient 类中添加以下方法：

class GameClient:
    # ... 其他代码 ...
    
    # ========== 玩家攻击消息处理器 ==========
    async def handle_player_attack(self, attack_msg):
        """
        处理玩家攻击消息
        显示攻击信息
        """
        print(f"[战斗] 玩家 {attack_msg.attacker_id} 攻击了玩家 {attack_msg.target_id}，造成 {attack_msg.damage} 点伤害")
    
    # ========== 玩家升级消息处理器 ==========
    async def handle_player_level_up(self, level_up_msg):
        """
        处理玩家升级消息
        显示升级信息
        """
        print(f"[升级] 玩家 {level_up_msg.player_id} 升级到 {level_up_msg.new_level} 级！获得 {level_up_msg.exp_gained} 经验值")
    
    # ========== 在 _setup_handlers() 中注册新处理器 ==========
    def _setup_handlers(self):
        """手动注册所有消息处理器"""
        # 原有的处理器
        self._register_method_handler('player_join', self.handle_player_join)
        self._register_method_handler('player_leave', self.handle_player_leave)
        self._register_method_handler('player_move', self.handle_player_move)
        self._register_method_handler('chat_message', self.handle_chat_message)
        self._register_method_handler('game_state', self.handle_game_state)
        self._register_method_handler('heartbeat', self.handle_heartbeat)
        
        # 新增的处理器 - 只需添加这两行！
        self._register_method_handler('player_attack', self.handle_player_attack)
        self._register_method_handler('player_level_up', self.handle_player_level_up)


# ==================== 步骤 5: 在客户端中添加发送新消息的方法 ====================
# 在 client.py 的 GameClient 类中添加以下方法：

class GameClient:
    # ... 其他代码 ...
    
    async def send_attack_message(self, target_id: str, damage: int, attack_type: int = 1):
        """发送攻击消息"""
        attack_msg = game_pb2.PlayerAttack()
        attack_msg.attacker_id = self.player_id
        attack_msg.target_id = target_id
        attack_msg.damage = damage
        attack_msg.attack_type = attack_type
        
        game_msg = game_pb2.GameMessage()
        game_msg.player_attack.CopyFrom(attack_msg)
        
        await self.websocket.send(game_msg.SerializeToString())
        print(f"发送攻击消息: 目标={target_id}, 伤害={damage}")
    
    async def send_level_up_message(self, new_level: int, exp_gained: int):
        """发送升级消息"""
        level_up_msg = game_pb2.PlayerLevelUp()
        level_up_msg.player_id = self.player_id
        level_up_msg.new_level = new_level
        level_up_msg.exp_gained = exp_gained
        
        game_msg = game_pb2.GameMessage()
        game_msg.player_level_up.CopyFrom(level_up_msg)
        
        await self.websocket.send(game_msg.SerializeToString())
        print(f"发送升级消息: 新等级={new_level}, 经验={exp_gained}")


# ==================== 总结 ====================
"""
对比旧方法和新方法：

【旧方法 - 使用 if-else】
- 每次添加新消息类型，都需要：
  1. 在 process_message() 方法中添加新的 if 分支
  2. 在客户端的 handle_message() 方法中添加新的 if 分支
  3. 修改核心逻辑，容易出错
  4. 违反开闭原则（对扩展开放，对修改关闭）

【新方法 - 使用注册机制】
- 每次添加新消息类型，只需要：
  1. 在 .proto 中定义新消息
  2. 编译 .proto
  3. 在服务器中添加处理器方法
  4. 在 _setup_handlers() 中注册（一行代码）
  5. 在客户端中添加处理器方法
  6. 在 _setup_handlers() 中注册（一行代码）
- 不需要修改任何现有的 if-else 分支
- 符合开闭原则
- 代码更清晰、更易维护
- 添加新功能时不会影响现有功能

优势：
✅ 符合 SOLID 原则（特别是开闭原则）
✅ 代码更清晰、更易维护
✅ 添加新功能时不修改现有代码
✅ 减少出错的可能性
✅ 更容易测试（每个处理器独立测试）
✅ 支持动态注册和卸载处理器
"""