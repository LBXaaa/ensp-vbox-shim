@echo off
chcp 936 >nul
cd /d "%~dp0"
title ensp-vbox-shim 环境检查

rem ============================================================
rem  环境检查 —— 采集 eNSP 与 VirtualBox 的环境事实,产出一份报告文件
rem
rem  采集的是当前用户的 VirtualBox 配置,必须与平时启动 eNSP 的那个
rem  账户直接双击本文件;换管理员账户可能会读到另一个账户的配置,结论
rem  与平时启动 eNSP 的情形对不上。
rem
rem  不带 -Fix 时全程只读,不修改任何系统设置。
rem ============================================================

echo ============================================================
echo   ensp-vbox-shim 环境检查
echo   开源地址 https://github.com/LBXaaa/ensp-vbox-shim
echo   若是付费获得,则为他人倒卖,请到上述地址免费下载
echo ------------------------------------------------------------
echo   用途:采集 eNSP 与 VirtualBox 的环境事实,产出一份报告文件,
echo         可直接附进 issue。报告第 [9] 节列出本机查出的问题、
echo         影响、以及确切的修复命令。
echo   安全性:不带 -Fix 时全程只读,不修改任何系统设置。
echo
echo   参数:
echo     不带参数               只出报告(只读)
echo     -Fix                  执行全部【无损】档的修复
echo     -Fix all              含需确认档,逐条确认后执行
echo     -Fix firewall         只做指定项(id 见报告第 [9] 节)
echo     -Fix all -DryRun      只列计划,不执行
echo     -Fix all -Yes         跳过逐条确认(无人值守)
echo   报告默认落在 %ProgramData%\ensp-vbox-shim\ 下。
echo ============================================================
echo.

rem 裸 -Fix 后面没跟值时补成 lossless(只做无损档)。
rem diag.ps1 的 -Fix 是字符串参数,直接给一个不带值的开关会被 PowerShell
rem 判为「缺少参数」而报错,所以在这一层把默认值补上。
set "ARGS=%*"
if /i "%~1"=="-fix" if "%~2"=="" set "ARGS=-Fix lossless"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0diag.ps1" %ARGS%

set "RC=%errorlevel%"
if not "%RC%"=="0" (
    echo.
    echo ------------------------------------------------------------
    echo 本次诊断出现问题,退出码 %RC%。
    echo 若需要报告与日志,请连同生成的报告文件一起提交:
    echo https://github.com/LBXaaa/ensp-vbox-shim/issues
)

echo.
echo ------------------------------------------------------------
echo 诊断与修复结束,按任意键关闭本窗口。
pause >nul
