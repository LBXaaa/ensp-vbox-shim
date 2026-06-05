@echo off
chcp 936 >nul
cd /d "%~dp0"
title ensp-vbox-shim

echo ============================================================
echo   ensp-vbox-shim  -  让 eNSP 跑在 VirtualBox 7.x 上
echo   免费开源,发布于 https://github.com/LBXaaa/ensp-vbox-shim
echo   若本工具系付费获得,则为他人倒卖,请到上方地址免费下载
echo ============================================================
echo.

rem This launcher does NOT self-elevate; it stays in the double-clicking
rem user's context (the user who normally launches eNSP). Elevation happens
rem only inside install_all.ps1 when it relaunches install.ps1 as an elevated
rem child. The VM-registration step then runs under THIS non-elevated user
rem token, so the VMs register into the correct %USERPROFILE%.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_all.ps1"

echo.
pause
