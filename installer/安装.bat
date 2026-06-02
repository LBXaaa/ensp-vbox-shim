@echo off
chcp 936 >nul
cd /d "%~dp0"
title ensp-vbox-shim 一键安装

rem ---- 检测管理员权限,没有就自动提权重新运行本脚本 ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ============================================================
    echo   ! 需要管理员权限!
    echo.
    echo   安装垫片需要写入注册表(HKLM)和 Program Files,
    echo   请关闭本窗口,右键点击 安装.bat,选择
    echo   "以管理员身份运行"。
    echo ============================================================
    echo.
    pause
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
