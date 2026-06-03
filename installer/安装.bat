@echo off
chcp 936 >nul
cd /d "%~dp0"
title ensp-vbox-shim

rem This launcher does NOT self-elevate; it stays in the double-clicking
rem user's context (the user who normally launches eNSP). Elevation happens
rem only inside install_all.ps1 when it relaunches install.ps1 as an elevated
rem child. The VM-registration step then runs under THIS non-elevated user
rem token, so the VMs register into the correct %USERPROFILE%.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_all.ps1"

echo.
pause
