extends Node2D

func _ready():
	# 启动先进入登录场景,选择完名字后再进主界面(见 login_scene.gd)
	get_tree().change_scene_to_file.call_deferred("res://prefab/login/LoginScene.tscn")
