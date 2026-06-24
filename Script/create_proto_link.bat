@echo off
chcp 65001 >nul
REM ============================================================
REM  生成 proto 文件夹外链（junction）脚本
REM  
REM  作用：把服务器端的 proto 文件夹以"目录链接"形式链接到客户端
REM        这样双端共享同一份 proto 源文件和生成的 _pb2.py
REM        修改 proto 后只需在任一端编译一次即可
REM ============================================================

REM ==================== 用户配置区 ====================
REM 外链源路径：proto 文件夹的真实位置（服务器端）
REM 修改这个变量即可改变外链指向
set "PROTO_SOURCE=d:\work\chat_server_demo\proto"

REM 外链目标路径：在客户端目录下创建的链接名
set "PROTO_LINK=D:\work\godot_test_client\Script\proto"
REM ============================================================

echo.
echo ============================================================
echo  proto 外链生成工具
echo ============================================================
echo  源路径 (PROTO_SOURCE): %PROTO_SOURCE%
echo  目标路径 (PROTO_LINK): %PROTO_LINK%
echo ------------------------------------------------------------

REM 检查源路径是否存在
if not exist "%PROTO_SOURCE%" (
    echo [错误] 源路径不存在: %PROTO_SOURCE%
    echo 请检查 PROTO_SOURCE 变量配置是否正确
    pause
    exit /b 1
)

REM 如果目标已存在（可能是之前的链接或真实目录），先删除
if exist "%PROTO_LINK%" (
    echo [提示] 目标路径已存在，将先删除旧链接...
    rmdir "%PROTO_LINK%"
    if errorlevel 1 (
        echo [错误] 删除旧链接失败，可能需要管理员权限
        pause
        exit /b 1
    )
)

REM 创建 junction 链接
REM junction 不需要管理员权限，比 symlink 更方便
mklink /J "%PROTO_LINK%" "%PROTO_SOURCE%"
if errorlevel 1 (
    echo [错误] 创建外链失败
    pause
    exit /b 1
)

echo.
echo [成功] proto 外链已创建！
echo  %PROTO_LINK%  -^>  %PROTO_SOURCE%
echo.
echo 现在客户端可以直接使用 proto\generated\game_pb2.py
echo 修改 proto 后，在任一端运行 compile_proto.py 即可同步
echo.
pause
