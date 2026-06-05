@echo off
chcp 936 >nul
cd /d "%~dp0"
title eNSP 设备 VM 注册

rem ============================================================
rem  注册 eNSP 基础设备 VM 到 VirtualBox 7.x
rem
rem  本步不要提权:注册脚本须以普通权限跑,VM 注册写入当前用户的
rem  .VirtualBox\VirtualBox.xml,必须与平时启动 eNSP 的
rem  账户一致;用管理员跑可能把数据写进别的账户,eNSP
rem  反而看不到。请用平时跑 eNSP 的那个账户直接双击本文件。
rem ============================================================

echo ============================================================
echo   eNSP 设备 VM 注册
echo   免费开源,发布于 https://github.com/LBXaaa/ensp-vbox-shim
echo   把 AR_Base / WLAN_*_Base 等注册进 VirtualBox 7.x
echo ============================================================
echo.
echo 已注册的会自动跳过,只补注册缺失的(幂等、可重复跑)。
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register_vms.ps1"

echo.
echo ------------------------------------------------------------
echo 注册流程结束,任意键关闭本窗口。
pause >nul
