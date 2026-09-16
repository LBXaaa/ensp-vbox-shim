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
    # 只读检测:不提权,直接把 -Check 转交给 install.ps1,两段都不跑。
    [switch]$Check,
    [string]$EnspDir = "",
    [string]$VBoxDir = ""
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# checks.ps1 是纯只读探测库(只有函数定义,无顶层副作用),可安全 dot-source。
# 目录查找(Find-EnspDir / Find-VBoxDir)、VBoxDrvInst 输出解析都取自它 —— 与
# install.ps1 / diag.ps1 共用同一份实现,本文件不重复任何探测逻辑。
# 必须在 script 作用域执行:checks.ps1 里的 $script: 变量才落在本脚本的作用域里,
# 其函数读取时才解析得到。
#
# 缺这个文件同样是"整合包损坏",且必须在这里就报 —— 这一行早于下面几个 Write-*
# 辅助函数的定义,所以只用 Write-Host,不能调 Write-Err。
$checksPs1 = Join-Path $ScriptDir "checks.ps1"
if (-not (Test-Path $checksPs1)) { Write-Host "  [XX] 整合包损坏:缺 checks.ps1" -ForegroundColor Red; exit 1 }
. $checksPs1

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

# ---------------------------------------------------------------------------
# 安装前检查(只读,不提权)
#
# 目的:把问题提到"提权安装之前"报出来。v0.1.4 的教训是故障要到设备启动阶段才
# 暴露,那时用户已经装完并认为成功了 —— 本检查让问题在装之前就浮出水面。
#
# 范围是穷举的固定集合(设计 §8.1),共五项,不含启发式判断:
#     host-only 驱动包缺失 / VBox 目录 / eNSP 目录 / 目标目录可写 / VBox 主版本 < 7
# 性能计数器、防火墙、端口占用、抓包驱动、子网冲突、VRAMSize 都不在这里:它们不
# 阻断安装,在安装阶段报出来只是噪音,由独立的 环境检查.bat 承担。
#
# 探测函数一律只读、不打印、不退出;判据单独成一个纯函数(事实进、问题清单出),
# 这样每一条判据都能用手工构造的假事实核对,而不必真去弄坏一台机器。
# ---------------------------------------------------------------------------

# 跑一个只读外部命令并取回文本行。失败返回对象,不抛出。
function Invoke-ReadOnlyProbe {
    param([string]$Exe, [string[]]$Arguments)

    if ([string]::IsNullOrEmpty($Exe)) {
        return [pscustomobject]@{ Ok = $false; Lines = @(); Error = "未定位到该程序" }
    }
    if (-not (Test-Path $Exe)) {
        return [pscustomobject]@{ Ok = $false; Lines = @(); Error = "找不到 " + $Exe }
    }

    # 原生命令往 stderr 写东西时,$ErrorActionPreference = "Stop" 会把它升级成终止
    # 错误(VBoxDrvInst 的 release log 就走 stderr)。这里临时放回 Continue,成败由
    # 返回值自己表达 —— 与 diag.ps1 的 Invoke-Probe 同一处理。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ Ok = $true; Lines = $lines; Error = "" }
    } catch {
        return [pscustomobject]@{ Ok = $false; Lines = @(); Error = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# 纯解析:从命令输出里取 VBox 主版本号。
#
# 只取真实版本,绝不读注册表 —— 注册表的 Version 正是本垫片伪装改写的那个值,
# 装过垫片的机器上它是 5.2.x,拿它判定会把每台正常机器都拦下。VBoxManage
# --version 输出的才是真实版本(2026-09-16 在本机核对过:注册表 5.2.44,
# VBoxManage 报 7.2.16r174877)。
#
# 逐行锚定行首匹配 "N.N",所以带 release log 的输出里 "Log opened 2026-09-16T..."
# 与 "OS Release: 10.0.29667.1000" 都不会被误取(前者行首不是数字,后者行首不是
# 数字)。取不到返回 $null —— "无法确定"不是缺陷,由调用方决定怎么说。
function Get-VBoxMajorVersion {
    param([string[]]$Lines)
    foreach ($l in @($Lines)) {
        $m = [regex]::Match("$l", '^\s*(\d+)\.(\d+)')
        if ($m.Success) { return [int]$m.Groups[1].Value }
    }
    return $null
}

function Test-CurrentProcessElevated {
    try {
        $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# 目标目录可写性。返回 $true / $false / $null(无法判定,不算缺陷)。
#
# 判据必须区分"谁去写"。第 1 段是【提权】跑的,而本检查【不提权】——未提权双击
# 安装.bat 时,C:\Program Files\Huawei\eNSP 本来就写不进去。若据此阻断,等于每台
# 正常机器都被拦下,与"干净机器静默通过"直接冲突。
#
# 真正会挡住安装的是"连管理员都写不进去"(只读卷、拒绝 Administrators 的 ACL),
# 所以只有当前进程【已提权】时,写探测失败才算判定为不可写;未提权时的失败一律
# 记作"无法判定",交给提权后的第 1 段去写 —— 那里失败有明确报错和日志。
function Get-TargetWritableFact {
    param([string]$EnspDir)

    if (-not $EnspDir) { return $null }

    $probeFile = Join-Path $EnspDir ".ensp-vbox-shim-writeprobe.tmp"
    $wrote = $false
    try {
        [System.IO.File]::WriteAllText($probeFile, "")
        $wrote = $true
    } catch {
        $wrote = $false
    } finally {
        # 探测文件必删。删不掉也不改变判定,但绝不能留下来。
        try { if (Test-Path -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force } } catch { }
    }

    if ($wrote) { return $true }
    if (Test-CurrentProcessElevated) { return $false }
    return $null
}

# 采集事实(只读)。不在里面判定、不打印 —— 判定是 Get-PreInstallBlockers 的事。
function Get-PreInstallFacts {
    param([string]$EnspDir, [string]$VBoxDir)

    $ensp = Find-EnspDir -Override $EnspDir
    $vbox = Find-VBoxDir -Override $VBoxDir

    # 驱动与版本都要跑 VBox 目录里的程序,定位不到就都留 $null(无法判定)。
    $driver = $null
    $major  = $null
    $drvOk  = $false
    if ($vbox) {
        $drvProbe = Invoke-ReadOnlyProbe -Exe (Join-Path $vbox "VBoxDrvInst.exe") -Arguments @("list")
        if ($drvProbe.Ok) {
            $driver = Parse-VBoxDrvInstList -Lines $drvProbe.Lines
            $drvOk  = $true
        }

        $verProbe = Invoke-ReadOnlyProbe -Exe (Join-Path $vbox "VBoxManage.exe") -Arguments @("--version")
        if ($verProbe.Ok) { $major = Get-VBoxMajorVersion -Lines $verProbe.Lines }
    }

    return [pscustomobject]@{
        EnspDir        = $ensp
        VBoxDir        = $vbox
        VBoxMajor      = $major
        Driver         = $driver
        # 驱动层是否真的判过。取不到值不阻断,但也不能装作查过 —— 干净路径据此多
        # 说一句话(见下方调用点)。
        DriverProbeOk  = $drvOk
        TargetWritable = (Get-TargetWritableFact -EnspDir $ensp)
    }
}

# 判据(纯函数):事实进,阻断项清单出。不采集、不打印、不退出。
#
# $Driver / $VBoxMajor / $TargetWritable 为 $null 一律表示"取不到、无法判定",
# 不当作缺陷 —— 探测拿不到值就判成有问题,是在凭空制造故障(checks.ps1 的
# Test-VramTooSmall 记的是同一条教训)。
function Get-PreInstallBlockers {
    param(
        [string]$EnspDir,
        [string]$VBoxDir,
        $VBoxMajor,
        $Driver,
        $TargetWritable
    )

    $problems = @()

    if (-not $EnspDir) {
        $problems += "找不到 eNSP 安装目录(可用 -EnspDir 手动指定)"
    }
    if (-not $VBoxDir) {
        $problems += "找不到 VirtualBox 安装目录(可用 -VBoxDir 手动指定)"
    }
    # 垫片面向 7.x;5.2 是 eNSP 原生支持的版本,不需要也不该装本垫片。
    if ($null -ne $VBoxMajor -and [int]$VBoxMajor -lt 7) {
        $problems += "VirtualBox 主版本是 $VBoxMajor,垫片只适用于 7.x"
    }
    # 只检查"这两个驱动包在不在驱动库里"。服务是否在跑不在这里 —— 它不阻断安装。
    if ($null -ne $Driver) {
        if (-not $Driver.NetAdpPresent) { $problems += "host-only 驱动包缺失: VBoxNetAdp6" }
        if (-not $Driver.NetLwfPresent) { $problems += "host-only 驱动包缺失: VBoxNetLwf" }
    }
    if ($TargetWritable -eq $false) {
        $problems += "eNSP 目录不可写(连管理员都写不进去): $EnspDir"
    }

    return $problems
}

function Write-PreInstallBlockers($Blockers) {
    Write-Warn "安装前检查发现 $($Blockers.Count) 个问题:"
    foreach ($b in $Blockers) { Write-Warn "  - $b" }
}

# 读一次菜单选择。返回 1 / 2 / 3。
#
# 读不到输入(非交互会话里 stdin 被重定向,Read-Host 会立刻返回空串)时不能
# 无限重问,否则脚本会卡死;问满 3 次就按【退出】处理 —— 没装总比乱装好。
function Read-PreInstallChoice {
    Write-Host ""
    Write-Host "  怎么处理?" -ForegroundColor Yellow
    Write-Host "    [1] 修复后继续 —— 先双击 环境检查.bat 按提示修好环境,再回来重装(推荐)"
    Write-Host "    [2] 仍要继续 —— 带着这些问题继续安装"
    Write-Host "    [3] 退出"
    for ($i = 0; $i -lt 3; $i++) {
        $a = ""
        try { $a = Read-Host "  请输入 1 / 2 / 3" } catch { $a = "" }
        switch ("$a".Trim()) {
            "1" { return 1 }
            "2" { return 2 }
            "3" { return 3 }
            default { Write-Host "  请输入 1、2 或 3。" -ForegroundColor Yellow }
        }
    }
    Write-Info "读不到输入,按【退出】处理。"
    return 3
}

# 依选择动作。单独成函数,好让三个分支都能被逐条核对。
function Invoke-PreInstallChoice {
    param([int]$Choice)

    switch ($Choice) {
        1 {
            # 不在这里修:修复要提权,还要求 eNSP 已关闭,那是 环境检查.bat 的活。
            Write-Info "已停止安装。请先双击本目录里的  环境检查.bat ,按提示修复环境,"
            Write-Info "修好后重新双击 安装.bat 即可。"
            exit 1
        }
        2 {
            Write-Warn "按你的选择继续安装。上面列出的问题可能导致装完仍然起不来设备。"
        }
        3 {
            Write-Info "已退出,未做任何改动。"
            exit 0
        }
    }
}

# 安装前检查全流程:采集 -> 判定 -> 有阻断就问用户。
# 单独成函数,好让整段(含干净机器上那句话)都能被直接调用核对。
function Invoke-PreInstallCheck {
    param([string]$EnspDir, [string]$VBoxDir)

    $facts    = Get-PreInstallFacts -EnspDir $EnspDir -VBoxDir $VBoxDir
    $blockers = @(Get-PreInstallBlockers -EnspDir $facts.EnspDir -VBoxDir $facts.VBoxDir `
                                         -VBoxMajor $facts.VBoxMajor `
                                         -Driver $facts.Driver `
                                         -TargetWritable $facts.TargetWritable)

    if ($blockers.Count -gt 0) {
        Write-PreInstallBlockers $blockers
        Invoke-PreInstallChoice -Choice (Read-PreInstallChoice)
        return
    }

    # 干净机器上只说一句通过,不逐条罗列非问题 —— 健康用户不该在这里被拦下问话。
    $verText = if ($null -ne $facts.VBoxMajor) { "VBox 主版本 $($facts.VBoxMajor)" } else { "VBox 版本未知" }
    if ($facts.VBoxDir -and (-not $facts.DriverProbeOk)) {
        # 探测取不到值不等于有问题(不阻断),但也不能装作查过了 —— 明说这一层没判成。
        Write-Info "host-only 驱动层取不到 VBoxDrvInst 输出,本层未判定(不阻断安装)。"
        Write-OK "其余安装前检查通过($verText)。"
    } else {
        Write-OK "通过:eNSP 与 VirtualBox 均可定位,host-only 驱动齐全,$verText。"
    }
}

# --- 段 0:前置检查 ---
$installPs1  = Join-Path $ScriptDir "install.ps1"
$registerPs1 = Join-Path $ScriptDir "register_vms.ps1"
if (-not (Test-Path $installPs1))  { Write-Err "整合包损坏:缺 install.ps1";    exit 1 }
if (-not (Test-Path $registerPs1)) { Write-Err "整合包损坏:缺 register_vms.ps1"; exit 1 }

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ensp-vbox-shim  一键安装(打补丁 + 注册设备)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# --- -Check:只读检测,不提权,两段都不跑 ---
# 检测路径不改动系统,不需要管理员权限,所以【绝不】走 RunAs —— 用户只是想知道
# 环境什么样,不该为此吃一个 UAC。register_vms.ps1 同样跳过:检测不写任何东西。
if ($Check) {
    Write-Step "只读检测:不提权,直接转交 install.ps1 -Check"
    # 调用操作符 & 用数组,每个元素自动加引号,【不要】再手动加。
    $checkArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$installPs1,"-Check")
    if ($EnspDir) { $checkArgs += @("-EnspDir",$EnspDir) }
    if ($VBoxDir) { $checkArgs += @("-VBoxDir",$VBoxDir) }
    & powershell.exe @checkArgs
    exit $LASTEXITCODE
}

# --- 安装前检查:五项阻断条件,有问题先问用户 ---
# 放在提权之前 —— 这就是它的全部意义:别让用户装完才发现问题。
Write-Step "安装前检查(只读)"
Invoke-PreInstallCheck -EnspDir $EnspDir -VBoxDir $VBoxDir

# --- 段 1:提权跑 install.ps1 ---
# Start-Process -ArgumentList 用单一字符串,含空格路径必须自己加引号。
Write-Step "第 1 步 / 共 2 步:打补丁(需要管理员权限,UAC 会弹一次)"
$installArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$installPs1`""
if ($EnspDir) { $installArgs += " -EnspDir `"$EnspDir`"" }
if ($VBoxDir) { $installArgs += " -VBoxDir `"$VBoxDir`"" }
# 本编排器本身【非提权】运行,当前 SID 就是交互登录用户的 SID。
# 传给提权的 install.ps1,让它把 vboxserver\ 树的写权限授给这个账户
# (eNSP 在 Program Files 时,非提权的 VBoxHeadless 否则建不出 Logs\ -> error 40)。
$mySid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
$installArgs += " -GrantSid `"$mySid`""
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
    Write-Info "详情见日志: $env:ProgramData\ensp-vbox-shim\install.log"
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
