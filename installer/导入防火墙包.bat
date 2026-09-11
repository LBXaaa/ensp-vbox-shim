@echo off
chcp 936 >nul
cd /d "%~dp0"
title eNSP 防火墙设备包导入

rem ============================================================
rem  导入 USG6000V 防火墙设备包(vfw_usg.vdi)
rem
rem  用法一:把 vfw_usg.vdi 直接拖到本文件上
rem  用法二:双击本文件,按提示把路径粘贴进来
rem
rem  需要管理员权限(要往 Program Files 写文件),UAC 会弹一次。
rem ============================================================

echo ============================================================
echo   USG6000V 防火墙设备包导入
echo   本工具开源于 https://github.com/LBXaaa/ensp-vbox-shim
echo   若是付费获得,则为他人倒卖,请到上述地址免费下载
echo ============================================================
echo.

set PKG=%~1
if "%PKG%"=="" (
  echo 请把设备包 vfw_usg.vdi^(约 940 MB^)的完整路径拖到本窗口后按回车:
  set /p PKG=路径: 
)
set PKG=%PKG:"=%

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0import_fw.ps1" -Package "%PKG%"

echo.
echo ------------------------------------------------------------
echo 导入流程结束,可以直接关闭本窗口。
pause >nul
