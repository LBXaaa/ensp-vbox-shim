@echo off
chcp 936 >nul
cd /d "%~dp0"
title ensp-vbox-shim 卸载还原

rem ---- 检测管理员权限,没有就自动提权重新运行本脚本 ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在请求管理员权限,请在弹出的 UAC 窗口点"是"...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================
echo   ensp-vbox-shim  卸载还原
echo   还原版本伪装 / VAR_Plugin.dll / 移除垫片 DLL
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall

echo.
echo ------------------------------------------------------------
echo 卸载流程结束。按任意键关闭本窗口。
pause >nul
