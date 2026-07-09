'''
自动加载类 UIManager
'''
extends Node

# 窗口类型
enum WindowType {
	GAME = 100, # 通常是镂空的， 镂空部分用来显示游戏内容
	FULLWINDOW = 200, # 全屏窗口1
	FULLWINDOW2 = 300, # 全屏窗口2
	SUBWINDOW = 400, # 弹窗
	TIPS = 500, # 提示框, 二确框
	BUBBLE = 600, # 气泡类型的提示   
}
	
