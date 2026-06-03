<#
.SYNOPSIS
    ensp-vbox-shim 一键安装编排器 —— 打补丁 + 自动注册基础设备 VM,只点一次。

.DESCRIPTION
    本脚本【不提权】,以双击它的那个用户(= 平时启动 eNSP 的人)身份运行,分两段:

      第 1 段:把 install.ps1 作为子进程【提权】运行(写 HKLM + Program Files,机器级)。
               UAC 在此弹一次。等它结束并检查退出码。
      第 2 段:仅当第 1 段成功。回到本【非提权】上下文,判定"当前账户是否就是登录用
               eNSP 的那个交互用户"(SID 比对):
                 - 是 -> 直接跑 register_vms.ps1,VM 注册写进正确的 %USERPROFILE%。
                 - 否 -> 跳过注册,提示用户用登录账户双击 注册设备.bat。

    为什么这么绕:install 必须提权(机器级),register 必须用登录用户令牌(写用户级
    %USERPROFILE%\.VirtualBox\VirtualBox.xml,否则 eNSP 看不到)。两段权限上下文不同,
    本编排器保证 register 全程不被提权。

    一般经 安装.bat 调用(安装.bat 不再自提权)。
#>
[CmdletBinding()]
param(
    [string]$EnspDir = "",
    [string]$VBoxDir = ""
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Write-Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Info($m){ Write-Host "  [..] $m" -ForegroundColor Gray }
function Write-Warn($m){ Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Write-Err($m) { Write-Host "  [XX] $m" -ForegroundColor Red }

# 当前进程用户 SID 是否就是某个交互登录用户(explorer.exe 属主)的 SID。
# 看 SID 而非"是否提权":同一用户提权后 %USERPROFILE% 不变,注册仍安全;
# 只有"借了另一个管理员账户"提权时 SID 才不同,才需跳过。
function Test-CurrentUserIsInteractive {
    $curSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    try {
        $explorers = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop
        foreach ($p in $explorers) {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue
            if ($o -and $o.ReturnValue -eq 0 -and $o.Sid -eq $curSid) { return $true }
        }
    } catch {
        # 拿不到交互用户信息时,保守认为"不是",走手动注册提示(绝不写错 profile)。
        return $false
    }
    return $false
}

# --- 段 0:前置检查 ---
$installPs1  = Join-Path $ScriptDir "install.ps1"
$registerPs1 = Join-Path $ScriptDir "register_vms.ps1"
if (-not (Test-Path $installPs1))  { Write-Err "整合包损坏:缺 install.ps1";    exit 1 }
if (-not (Test-Path $registerPs1)) { Write-Err "整合包损坏:缺 register_vms.ps1"; exit 1 }

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ensp-vbox-shim  一键安装(打补丁 + 注册设备)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# --- 段 1:提权跑 install.ps1 ---
# Start-Process -ArgumentList 用单一字符串,含空格路径必须自己加引号。
Write-Step "第 1 步 / 共 2 步:打补丁(需要管理员权限,UAC 会弹一次)"
$installArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$installPs1`""
if ($EnspDir) { $installArgs += " -EnspDir `"$EnspDir`"" }
if ($VBoxDir) { $installArgs += " -VBoxDir `"$VBoxDir`"" }
try {
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $installArgs `
                          -Verb RunAs -Wait -PassThru -ErrorAction Stop
} catch {
    Write-Err "安装需要管理员权限,已取消(未做任何改动)。"
    Write-Info "重新双击 安装.bat,在 UAC 窗口点【是】即可。"
    exit 1
}
if ($proc.ExitCode -ne 0) {
    Write-Err "打补丁步骤失败(退出码 $($proc.ExitCode)),已跳过注册。"
    Write-Info "详情见日志: $env:TEMP\ensp-vbox-shim-install.log"
    exit 1
}
Write-OK "补丁部署完成。"

# --- 段 2:非提权跑 register_vms.ps1(仅当账户就是登录用户) ---
# 调用操作符 & 用数组,每个元素自动加引号,【不要】再手动加。
Write-Step "第 2 步 / 共 2 步:注册基础设备 VM"
if (Test-CurrentUserIsInteractive) {
    $regArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$registerPs1)
    if ($EnspDir) { $regArgs += @("-EnspDir",$EnspDir) }
    if ($VBoxDir) { $regArgs += @("-VBoxDir",$VBoxDir) }
    & powershell.exe @regArgs
    Write-OK "注册步骤结束(详见上方逐台结果)。"
} else {
    Write-Warn "检测到当前不是登录用 eNSP 的账户(疑似右键用了别的管理员运行)。"
    Write-Warn "为避免把 VM 注册写进错误的用户配置,已跳过自动注册。"
    Write-Warn "请用【平时启动 eNSP 的账户】双击本目录里的  注册设备.bat  完成注册。"
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "  全部完成。启动 eNSP,拉一台设备试试。" -ForegroundColor Green
Write-Host "  要还原:双击 卸载.bat。" -ForegroundColor Green
Write-Host "============================================================`n" -ForegroundColor Green
