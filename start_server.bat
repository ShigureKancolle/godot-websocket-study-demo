@echo off
chcp 65001 >nul
REM ============================================================
REM  游戏服务器启动脚本
REM  --console 参数开启交互式 Python 控制台
REM  如不需要控制台，删除 --console 即可
REM ============================================================
py -3 web_server.py --console
pause