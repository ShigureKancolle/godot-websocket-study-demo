@echo off
chcp 936 >nul
title 生成 diff 对比脚本(TortoiseMerge)
echo ================================================
echo  正在扫描各 git 仓库的未提交改动...
echo  生成后自动打开对比窗口(左=改前, 右=改后)
echo ================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gen_review_diff.ps1"
echo.
echo 对比脚本已生成: temp\review_diff\对比.bat
echo 现在自动打开它, 请逐个 review(关掉一个窗口自动下一个)
echo.
pause
start "" "%~dp0..\temp\review_diff\对比.bat"

pause

