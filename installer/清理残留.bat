@echo off
chcp 936 >nul
cd /d "%~dp0"
title ensp-vbox-shim 清理残留进程

rem ---- 需要管理员权限,没有就自动提权后重跑本脚本 ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在申请管理员权限,请在 UAC 窗口点"是"...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================
echo   ensp-vbox-shim 清理残留进程
echo   开源地址 https://github.com/LBXaaa/ensp-vbox-shim
echo ------------------------------------------------------------
echo   用途:关闭 eNSP 后,若 VirtualBox 的 VBoxHeadless 进程没退干净
echo         (每台约 1.2-1.5 GB),用本脚本把它们收掉。
echo   安全性:只结束"VirtualBox 账本上已不在运行"的孤儿进程,
echo           正在正常运行的虚拟机会被跳过。
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup_orphans.ps1"

echo.
echo ------------------------------------------------------------
echo 清理流程结束,按任意键关闭本窗口。
pause >nul
