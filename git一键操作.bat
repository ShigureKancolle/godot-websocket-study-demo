@echo off
chcp 65001 >nul
title Git 一键操作(5 仓库)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0git_onekey.ps1"
pause
