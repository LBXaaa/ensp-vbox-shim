@echo off
chcp 936 >nul
cd /d "%~dp0"
title ensp-vbox-shim 一键安装

rem ---- 检测管理员权限,没有就自动提权重新运行本脚本 ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在请求管理员权限,请在弹出的 UAC 窗口点"是"...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================
echo   ensp-vbox-shim  一键安装
echo   让原版华为 eNSP 直接跑在 VirtualBox 7.x 上
echo ============================================================
echo.
echo 即将自动检测 eNSP / VirtualBox 安装位置并打补丁...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"

echo.
echo ------------------------------------------------------------
echo 安装流程结束。按任意键关闭本窗口。
pause >nul
