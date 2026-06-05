@echo off
chcp 936 >nul
cd /d "%~dp0"
title ensp-vbox-shim 卸载还原

rem ---- 需管理员权限,没有就自动提权重启本批脚本 ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 即将申请管理员权限,请在弹出的 UAC 窗口点"是"...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================
echo   ensp-vbox-shim 卸载还原
echo   免费开源,发布于 https://github.com/LBXaaa/ensp-vbox-shim
echo   还原版本伪装 / VAR_Plugin.dll / 移除垫片 DLL
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall

echo.
echo ------------------------------------------------------------
echo 卸载流程结束,任意键关闭本窗口。
pause >nul
