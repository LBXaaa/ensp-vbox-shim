@echo off
chcp 936 >nul
cd /d "%~dp0"
title ensp-vbox-shim 环境检查

rem ============================================================
rem  环境检查 —— 采集 eNSP 与 VirtualBox 的运行环境,生成报告文件
rem
rem  采集的是当前用户的 VirtualBox 配置,请用平时跑 eNSP 的那个
rem  账户直接双击本文件;换管理员账户跑会读到别的账户的数据,
rem  和平时跑 eNSP 的情况对不上。
rem
rem  只读采集,不修改任何系统设置。
rem ============================================================

echo ============================================================
echo   ensp-vbox-shim 环境检查
echo   开源地址 https://github.com/LBXaaa/ensp-vbox-shim
echo ------------------------------------------------------------
echo   用途:采集 eNSP 与 VirtualBox 的运行环境,生成一份报告文件,
echo         可直接附进 issue,便于在没有远程协助的情况下定位问题。
echo   安全性:只读采集,不修改任何系统设置。
echo   报告默认落在 %ProgramData%\ensp-vbox-shim\ 下。
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diag.ps1" %*

set "RC=%errorlevel%"
if not "%RC%"=="0" (
    echo.
    echo ------------------------------------------------------------
    echo 检查未正常结束,退出码 %RC%。
    echo 请把上面的输出截图,连同刚生成的报告文件一起反馈到:
    echo https://github.com/LBXaaa/ensp-vbox-shim/issues
)

echo.
echo ------------------------------------------------------------
echo 检查流程结束,按任意键关闭本窗口。
pause >nul
