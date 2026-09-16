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

    install 必须提权(机器级),register 必须用登录用户令牌(写用户级
    %USERPROFILE%\.VirtualBox\VirtualBox.xml,否则 eNSP 看不到)。两段权限上下文不同,
    所以拆成两个进程跑。

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
# 暴露,那时用户已经装完并认为成功了。
#
# 范围是穷举的固定集合(设计 §8.1),不含启发式判断:
#     host-only 驱动包缺失 / VBox 目录 / eNSP 目录 / 目标目录可写 / VBox 主版本 < 7
#     + 性能计数器、防火墙放行
# 后两项在 §8.1 里原本不进安装前检查(「不阻断安装,报出来只是噪音」)。现在纳入,
# 是因为它们从"只报"变成了"能自动修好"(设计 §7.1 的无损档),修这两项用户不承担
# 任何风险。
# 端口占用、抓包驱动、子网冲突、VRAMSize 仍不在这里 —— 它们既不阻断安装,也没有
# 自动修复手段,由独立的 环境检查.bat 承担。
#
# 发现问题后按【是否无损】(设计 §7.1)分三档处置,而不是按严重程度:
#     report   没有自动修复手段          -> 只报,问用户是否还要继续装
#     confirm  可修,但会打断在用的东西   -> 打印影响,问过才修
#     silent   可修、可撤销、不打断任何东西 -> 不问,直接修
#
# 三档的【判断】全在本文件完成,而【执行】在提权后的 install.ps1 —— 因为本检查
# 刻意不提权(要能在 UAC 弹出来之前拦住用户),而每一项修复都要管理员权限。于是
# 这里产出的是"商定好的修复计划"(一串令牌),原样传给提权的子进程;提权侧只执行
# 计划,不再自行判断该修什么。计划就是用户同意的记录,提权侧多修一项都是越权。
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
# 只取真实版本,绝不读注册表 —— 注册表的 Version 就是本垫片伪装改写的那个值,
# 装过垫片的机器上它是 5.2.x,拿它判定会把每台正常机器都拦下。VBoxManage
# --version 输出的才是真实版本(2026-09-16 在本机核对过:注册表 5.2.44,
# VBoxManage 报 7.2.16r174877)。
#
# 逐行锚定行首匹配 "N.N",所以带 release log 的输出里 "Log opened 2026-09-16T..."
# 与 "OS Release: 10.0.29667.1000" 都不会被误取(两者行首都不是数字)。取不到
# 返回 $null —— "无法确定"不是缺陷,由调用方决定怎么说。
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
# 会挡住安装的是"连管理员都写不进去"(只读卷、拒绝 Administrators 的 ACL),
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

    # 性能计数器:判据是【实跑一次计数器】,不是去看 Perflib 注册表键 —— 那个键
    # 在健康的当前 Windows 上本来就不存在(checks.ps1 里记了这条实测)。探测抛错
    # 记 $null(无法判定),不记 $false。
    $perf = $null
    try { $perf = [bool](Test-PerfCountersFunctional).Functional } catch { $perf = $null }

    # 防火墙:同样只取正读。读到 0 条规则时【不】下"缺规则"的结论 —— 那既可能是
    # 确实没有,也可能是当前权限读不到防火墙配置,两种情形在这里分不开。宁可
    # 留给 环境检查.bat 以更高权限复核,也不据此去建一条可能重复的规则。
    #
    # 这一步在非提权下要枚举全部规则(本机实测 1274 条,约 7 秒),是本次检查里
    # 最慢的一步,所以调用点会先打印一行提示,免得用户以为卡死了。
    $fwCount = -1
    $fwAllow = $false
    try {
        $fwLines = @(Get-FirewallRuleTextForEnsp)
        $fwCount = $fwLines.Count
        if ($fwCount -gt 0) { $fwAllow = [bool](Parse-FirewallRulesForEnsp -Lines $fwLines).HasAllowRule }
    } catch {
        $fwCount = -1
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
        PerfFunctional = $perf
        # -1 表示没读到(与"读到 0 条"是两回事)。
        FirewallRuleCount    = $fwCount
        FirewallHasAllowRule = $fwAllow
    }
}

# 一条发现的形状。Tier 三档见文件上方说明;Token 是提权侧认得的修复令牌
# (report 档为空 —— 它没有可执行的修复);Impact 只在 confirm 档有内容,那是要
# 用户点头之前必须先看到的那段话。
function New-PreInstallFinding {
    param(
        [string]$Id,
        [string]$Tier,
        [string]$Detail,
        [string]$Token = "",
        [string[]]$Impact = @()
    )
    return [pscustomobject]@{
        Id     = $Id
        Tier   = $Tier
        Detail = $Detail
        Token  = $Token
        Impact = @($Impact)
    }
}

# 判据(纯函数):事实进,发现清单出。不采集、不打印、不退出。
#
# $Driver / $VBoxMajor / $TargetWritable / $PerfFunctional 为 $null 一律表示
# "取不到、无法判定",不当作缺陷 —— 探测拿不到值就判成有问题,是在凭空制造故障
# (checks.ps1 的 Test-VramTooSmall 记的是同一条教训)。同理,防火墙读到 0 条
# ($FirewallRuleCount 为 0)不下结论:它和"读不到"分不开。
#
# 清单顺序固定为 report -> confirm -> silent:打印时先出最需要用户做决定的那几条。
function Get-PreInstallFindings {
    param(
        [string]$EnspDir,
        [string]$VBoxDir,
        $VBoxMajor,
        $Driver,
        $TargetWritable,
        $PerfFunctional,
        [int]$FirewallRuleCount = -1,
        [bool]$FirewallHasAllowRule = $false
    )

    $found = @()

    # --- report 档:没有自动修复手段,只报 ------------------------------------
    if (-not $EnspDir) {
        $found += New-PreInstallFinding -Id "enspdir" -Tier "report" `
            -Detail "找不到 eNSP 安装目录(可用 -EnspDir 手动指定)"
    }
    if (-not $VBoxDir) {
        $found += New-PreInstallFinding -Id "vboxdir" -Tier "report" `
            -Detail "找不到 VirtualBox 安装目录(可用 -VBoxDir 手动指定)"
    }
    # 垫片面向 7.x;5.2 是 eNSP 原生支持的版本,不需要也不该装本垫片。
    if ($null -ne $VBoxMajor -and [int]$VBoxMajor -lt 7) {
        $found += New-PreInstallFinding -Id "vboxver" -Tier "report" `
            -Detail "VirtualBox 主版本是 $VBoxMajor,垫片只适用于 7.x"
    }
    if ($TargetWritable -eq $false) {
        $found += New-PreInstallFinding -Id "writable" -Tier "report" `
            -Detail "eNSP 目录不可写(连管理员都写不进去): $EnspDir"
    }

    # --- confirm 档:可修,但会打断正在使用的东西 ------------------------------
    # 只检查"这两个驱动包在不在驱动库里"。服务是否在跑不在这里 —— 它不阻断安装。
    # 两个包无论缺哪个,修复都是同一条四步链(见 fix.ps1 头部:顺序是硬依赖),
    # 所以只出一个发现、一个令牌。
    $drvWhy = @()
    if ($null -ne $Driver) {
        if (-not $Driver.NetAdpPresent) { $drvWhy += "VBoxNetAdp6" }
        if (-not $Driver.NetLwfPresent) { $drvWhy += "VBoxNetLwf" }
    }
    if ($drvWhy.Count -gt 0) {
        $found += New-PreInstallFinding -Id "hostonly" -Tier "confirm" -Token "hostonly" `
            -Detail ("host-only 驱动包缺失: " + ($drvWhy -join "、") + "(设备会起不来,或起来连不通宿主)") `
            -Impact @(
                "重装驱动包会重新注册网络组件,并禁用/启用一次 host-only 网卡 ——"
                "本机网络会短暂中断(数秒到十几秒)。"
                "正在运行的设备、Tailscale / WireGuard 之类的常连隧道、"
                "Hyper-V 虚拟交换机都会闪断。修复前请先关闭 eNSP。"
            )
    }

    # --- silent 档:无损可修,不问 --------------------------------------------
    if ($PerfFunctional -eq $false) {
        $found += New-PreInstallFinding -Id "perfcounters" -Tier "silent" -Token "perfcounters" `
            -Detail "Windows 性能计数器损坏(会导致设备一直打印 ####,进不到命令行)"
    }
    if ($FirewallRuleCount -gt 0 -and (-not $FirewallHasAllowRule)) {
        $found += New-PreInstallFinding -Id "firewall" -Tier "silent" -Token "firewall" `
            -Detail "防火墙未放行 eNSP_VBoxServer(会导致设备一直打印 ####,进不到命令行)"
    }

    return $found
}

# 判据(纯函数):发现清单 + "要不要修有损项"的答复 -> 交给提权侧执行的令牌计划。
#
# 这个计划就是用户同意的记录,install.ps1 只执行它、不增删。silent 档不受答复
# 影响(它本来就无需征得同意);confirm 档只有答复为真才进计划。
#
# 顺序按 install.ps1 的执行顺序固定下来,与该清单的排列无关 —— 计划是确定性的
# 才好逐步核对。每个令牌最多进计划一次:计划里若出现两次同一个令牌,提权侧会把
# 整条链跑两遍(host-only 那条链会因此重绑两次网卡)。返回空数组时 PowerShell 会
# 把它摊平成一无所有,调用方要用 @(Get-PreInstallRepairPlan ...) 接住。
function Get-PreInstallRepairPlan {
    param($Findings, [bool]$ConfirmAnswer = $false)

    $order = @("hostonly", "perfcounters", "firewall")
    $plan = @()
    foreach ($token in $order) {
        foreach ($f in @($Findings)) {
            if ($f.Token -ne $token) { continue }
            if ($f.Tier -eq "silent") { $plan += $token; break }
            if (($f.Tier -eq "confirm") -and $ConfirmAnswer) { $plan += $token; break }
        }
    }
    return @($plan)
}

# 读一次"要不要修有损项"的确认。
#
# 读不到输入(非交互会话里 stdin 被重定向,Read-Host 会立刻返回空串)时不能
# 无限重问,否则脚本会卡死;问满 3 次按【不修】处理(不修只是维持原样)。
function Read-PreInstallConfirm {
    Write-Host -NoNewline "  回车 = 执行 / 输入 n 再回车 = 跳过: "

    # 用 [Console]::ReadLine(),不用 Read-Host。后者在 EOF 上返回空串,与"用户按了
    # 一下回车"无从区分 —— 于是无人值守时撞上 EOF 会被当成放行,把装驱动、重绑网卡
    # 这类动作跑掉。[Console]::ReadLine() 在 EOF 上返回 $null,两者分得开。
    $a = $null
    try { $a = [Console]::ReadLine() } catch { $a = $null }

    if ($null -eq $a) {
        Write-Host ""
        Write-Info "读不到输入,按【跳过修复】处理(不改动系统)。"
        return $false
    }
    $t = ([string]$a).Trim().ToLower()
    if (($t -eq "n") -or ($t -eq "no")) { return $false }
    return $true
}

# 读一次"还要不要继续装"。只在那几条【没有自动修复手段】的发现出现时才问。
#
# 默认按【退出】处理,与原来那个三选一菜单里"退出"的取向一致。
function Read-PreInstallContinue {
    for ($i = 0; $i -lt 3; $i++) {
        $a = ""
        try { $a = Read-Host "  仍要继续安装吗? 输入 C 继续 / Q 退出" } catch { $a = "" }
        switch ("$a".Trim().ToUpper()) {
            "C" { return $true }
            "CONTINUE" { return $true }
            "Q" { return $false }
            "QUIT" { return $false }
            default { Write-Host "  请输入 C 或 Q。" -ForegroundColor Yellow }
        }
    }
    Write-Info "读不到输入,按【退出】处理。"
    return $false
}

# 安装前检查全流程:采集 -> 判定 -> 分档处置 -> 出计划。
#
# 全程只读,且【只返回决定、不 exit】—— 退出由调用点做。原来那几个分支是直接
# exit 的,那样整段逻辑就没法被调用核对(调用一次会把核对用的进程一起结束掉)。
# 现在返回 @{ Plan; Proceed },两件事分开:
#   Plan     商定好要修的令牌清单(report 档永远不进计划;confirm 档看答复)
#   Proceed  用户在 report 档面前选了继续还是退出
function Invoke-PreInstallCheck {
    param([string]$EnspDir, [string]$VBoxDir)

    # 这一步里防火墙要枚举全部规则,非提权下约 7 秒(本机 1274 条实测)。先说一声,
    # 免得用户以为卡死了。
    Write-Info "正在采集(其中防火墙规则枚举约需数秒)⋯"
    $facts = Get-PreInstallFacts -EnspDir $EnspDir -VBoxDir $VBoxDir
    $found = @(Get-PreInstallFindings -EnspDir $facts.EnspDir -VBoxDir $facts.VBoxDir `
                                      -VBoxMajor $facts.VBoxMajor `
                                      -Driver $facts.Driver `
                                      -TargetWritable $facts.TargetWritable `
                                      -PerfFunctional $facts.PerfFunctional `
                                      -FirewallRuleCount $facts.FirewallRuleCount `
                                      -FirewallHasAllowRule $facts.FirewallHasAllowRule)

    # 探测取不到值不等于有问题(不阻断、也不算发现),但也不能装作查过了 ——
    # 明说这一层没判成,与干净路径那句"通过"要分得开。
    if ($facts.VBoxDir -and (-not $facts.DriverProbeOk)) {
        Write-Info "host-only 驱动层取不到 VBoxDrvInst 输出,本层未判定(不阻断安装)。"
    }
    if ($null -eq $facts.PerfFunctional) {
        Write-Info "性能计数器探测失败,本层未判定(不阻断安装)。"
    }
    if ($facts.FirewallRuleCount -lt 0) {
        Write-Info "防火墙规则读不到,本层未判定(不阻断安装)。"
    }

    if ($found.Count -eq 0) {
        # 干净机器上只说一句通过,不逐条罗列非问题 —— 健康用户不该在这里被拦下问话,
        # 更不该被问到修复。
        $verText = if ($null -ne $facts.VBoxMajor) { "VBox 主版本 $($facts.VBoxMajor)" } else { "VBox 版本未知" }
        Write-OK "通过:eNSP 与 VirtualBox 均可定位,host-only 驱动齐全,性能计数器与防火墙放行正常,$verText。"
        return [pscustomobject]@{ Plan = @(); Proceed = $true }
    }

    $report  = @($found | Where-Object { $_.Tier -eq "report" })
    $confirm = @($found | Where-Object { $_.Tier -eq "confirm" })
    $silent  = @($found | Where-Object { $_.Tier -eq "silent" })

    Write-Warn ("安装前检查发现 " + $found.Count + " 个问题:")
    foreach ($f in $report)  { Write-Warn ("  [无法自动修复] " + $f.Detail) }
    foreach ($f in $confirm) { Write-Warn ("  [可修复,会影响网络] " + $f.Detail) }
    foreach ($f in $silent)  { Write-Warn ("  [可修复] " + $f.Detail) }
    if ($silent.Count -gt 0) {
        Write-Info "  标 [可修复] 的无需确认,安装时会一并修好。"
    }

    # 有损档:先把影响说清楚,再问。答复只影响这一档进不进计划。
    $answer = $false
    if ($confirm.Count -gt 0) {
        Write-Host ""
        Write-Warn "修复下面这项会短暂中断本机网络:"
        foreach ($f in $confirm) { foreach ($line in @($f.Impact)) { Write-Warn ("  " + $line) } }
        $answer = Read-PreInstallConfirm
    }

    # 无解档:没有自动修复手段,只能如实说明并让用户决定要不要带着它继续。
    $proceed = $true
    if ($report.Count -gt 0) {
        Write-Host ""
        Write-Warn "标 [无法自动修复] 的问题没有自动修复手段,只能手动处理(或带着它继续)。"
        $proceed = Read-PreInstallContinue
    }

    $plan = @(Get-PreInstallRepairPlan -Findings $found -ConfirmAnswer $answer)
    if ($plan.Count -gt 0) {
        Write-Info ("本次安装会先修复: " + ($plan -join ", "))
    } elseif ($confirm.Count -gt 0) {
        Write-Info "按你的选择跳过该项修复(环境保持不变,继续安装)。"
    }

    return [pscustomobject]@{ Plan = $plan; Proceed = $proceed }
}

# --- 段 0:前置检查 ---
$installPs1  = Join-Path $ScriptDir "install.ps1"
$registerPs1 = Join-Path $ScriptDir "register_vms.ps1"
if (-not (Test-Path $installPs1))  { Write-Err "整合包损坏:缺 install.ps1";    exit 1 }
if (-not (Test-Path $registerPs1)) { Write-Err "整合包损坏:缺 register_vms.ps1"; exit 1 }

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ensp-vbox-shim  一键安装(打补丁 + 注册设备 + 环境检测)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# --- -Check:只读检测,不提权,两段都不跑 ---
# 检测路径不改动系统,不需要管理员权限,所以【绝不】走 RunAs —— 用户只是想知道
# 环境什么样,不该为此吃一个 UAC。register_vms.ps1 同样跳过:检测不写任何东西。
#
# 同样地,-Check 也【绝不】进下面的 Invoke-PreInstallCheck:那条路径会问出修复
# 计划来,而 -Check 只报不修。整个分支在本行以下、安装前检查以上就 exit 掉了。
if ($Check) {
    Write-Step "只读检测:不提权,直接转交 install.ps1 -Check"
    # 调用操作符 & 用数组,每个元素自动加引号,【不要】再手动加。
    $checkArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$installPs1,"-Check")
    if ($EnspDir) { $checkArgs += @("-EnspDir",$EnspDir) }
    if ($VBoxDir) { $checkArgs += @("-VBoxDir",$VBoxDir) }
    & powershell.exe @checkArgs
    exit $LASTEXITCODE
}

# --- 安装前检查:只读采集 + 分档处置,同意在这里征得 ---
# 放在提权之前:别让用户装完才发现问题,也别让用户在一个没有上下文的提权窗口里
# 被问话。用户在这里点头,提权侧才动手。
Write-Step "安装前检查(只读)"
$pre = Invoke-PreInstallCheck -EnspDir $EnspDir -VBoxDir $VBoxDir
if (-not $pre.Proceed) {
    Write-Info "已退出,未做任何改动。"
    exit 0
}
$repairPlan = @($pre.Plan)

# --- 段 1:提权跑 install.ps1 ---
# Start-Process -ArgumentList 用单一字符串,含空格路径必须自己加引号。
Write-Step "第 1 步 / 共 3 步:打补丁(需要管理员权限,UAC 会弹一次)"
$installArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$installPs1`""
if ($EnspDir) { $installArgs += " -EnspDir `"$EnspDir`"" }
if ($VBoxDir) { $installArgs += " -VBoxDir `"$VBoxDir`"" }
# 商定好的修复计划,令牌逗号分隔。为空就【不传这个开关】—— 提权侧把"没传"和
# "传了空串"都当"一项都不修",但少一个参数在命令行里更好核对。
if ($repairPlan.Count -gt 0) { $installArgs += " -Repair `"$($repairPlan -join ',')`"" }
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
    # 两种失败共用这个出口:安装前商定的修复没做成,或打补丁本身失败。两者都不该
    # 当作装好了继续往下走,所以都停在这里,并指向同一份日志。
    Write-Err "提权步骤失败(退出码 $($proc.ExitCode)),已跳过注册。"
    Write-Info "可能是打补丁失败,也可能是上面商定的修复没有全部完成(日志里搜 [修复])。"
    Write-Info "详情见日志: $env:ProgramData\ensp-vbox-shim\install.log"
    Write-Info "若想先装上垫片、环境稍后再修:重跑 安装.bat,修复那一步选 N 跳过即可。"
    exit 1
}
Write-OK "补丁部署完成。"

# --- 段 2:非提权跑 register_vms.ps1(仅当账户就是登录用户) ---
# 调用操作符 & 用数组,每个元素自动加引号,【不要】再手动加。
Write-Step "第 2 步 / 共 3 步:注册基础设备 VM"
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

# --- 段 3:运行时环境检测(只读,非提权) ---
# 装完立刻采一遍环境事实,并据此征得修复同意。
#
# 同意在这里征得,与安装前检查同一个理由:别让用户在一个没有上下文的提权窗口里
# 被问话。提权侧只执行计划,不自行判断该修什么 —— 计划就是用户同意的记录。
#
# 为什么要有这一步:此前装完就结束了,只留下一句"启动 eNSP 拉一台设备试试"。
# 环境行不行,使用者得自己试;试不出来,报障时手里又什么都没有。装完立刻采一次,
# 当场的状态就被固定下来了,而报告第 [9] 节自带每一项对应的确切命令。
Write-Step "第 3 步 / 共 3 步:运行时环境检测(只读)"
$logDir   = Join-Path $env:ProgramData "ensp-vbox-shim"
$planFile = Join-Path $logDir "runtime-plan.txt"
$diagPs1  = Join-Path $ScriptDir "diag.ps1"
$runPlan  = @()

if (-not (Test-Path $diagPs1)) {
    Write-Warn "整合包缺 diag.ps1,跳过运行时检测与修复。"
} else {
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    # 上一轮的清单必须先删掉:留着的话,本次检测即便一条都没查出来,下面也会照着
    # 旧清单去修——而那份清单描述的是上一次运行时的机器状态。
    if (Test-Path $planFile) { Remove-Item $planFile -Force -ErrorAction SilentlyContinue }

    $diagArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$diagPs1,"-PlanFile",$planFile)
    if ($EnspDir) { $diagArgs += @("-EnspDir",$EnspDir) }
    if ($VBoxDir) { $diagArgs += @("-VBoxDir",$VBoxDir) }
    & powershell.exe @diagArgs

    if (Test-Path $planFile) {
        $runPlan = @(Get-Content -Path $planFile | Where-Object { $_ -match '\S' } | ForEach-Object {
            $parts = $_ -split "`t", 2
            if ($parts.Count -eq 2) {
                [pscustomobject]@{ Tier = $parts[0].Trim(); Id = $parts[1].Trim() }
            }
        })
    } else {
        # 清单没落盘 != 本机没问题。不静默跳过:说清楚,并据此不执行任何修复。
        Write-Warn "运行时检测没有产出可修项清单,本次不做任何修复(报告仍然有效)。"
    }
}

# --- 段 4:执行运行时检测商定的修复(提权,按需) ---
#
# 只在真的检出可修项时才提权。正常路径下安装前检查已经把无损档与有损档都处理过
# 了,这里通常是空的 —— 那就不该为一次空跑再弹一个 UAC。
$silentItems  = @($runPlan | Where-Object { $_.Tier -eq "lossless" })
$confirmItems = @($runPlan | Where-Object { $_.Tier -eq "confirm" })
$agreed = @($silentItems | ForEach-Object { $_.Id })

if ($confirmItems.Count -gt 0) {
    Write-Host ""
    Write-Warn ("下面 " + $confirmItems.Count + " 项修复会短暂中断本机网络(影响见上面第 [9] 节):")
    foreach ($it in $confirmItems) { Write-Warn ("  * " + $it.Id) }
    if (Read-PreInstallConfirm) {
        $agreed += @($confirmItems | ForEach-Object { $_.Id })
    } else {
        Write-Info "按你的选择跳过(环境保持不变)。"
    }
}

if ($agreed.Count -eq 0) {
    Write-OK "运行时检测没有需要执行的修复。"
} elseif (-not (Test-Path $diagPs1)) {
    Write-Warn "整合包缺 diag.ps1,无法执行修复。"
} else {
    # 空数组在 PowerShell 里会被展平成一无所有,所以这里先接住再判空。
    $idList = @($agreed) -join ','
    Write-Step "继续:执行运行时检测商定的修复(需要管理员权限,会再弹一次 UAC)"
    Write-Info ("本次执行: " + $idList)

    $fixArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$diagPs1`" -Fix `"$idList`" -Yes"
    if ($EnspDir) { $fixArgs += " -EnspDir `"$EnspDir`"" }
    if ($VBoxDir) { $fixArgs += " -VBoxDir `"$VBoxDir`"" }

    $fixProc = $null
    try {
        $fixProc = Start-Process -FilePath "powershell.exe" -ArgumentList $fixArgs `
                                 -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        Write-Warn "取消或无法提权,已跳过修复(环境保持不变)。"
        Write-Info "稍后可双击 环境检查.bat -Fix 单独执行。"
    }
    if ($fixProc) {
        if ($fixProc.ExitCode -eq 0) {
            Write-OK "修复步骤完成(详见上方逐条结果)。"
        } else {
            # 非 0 有两种:某一项修复失败,或计划里的 id 在提权侧对不上(环境在这两步
            # 之间变了)。两种都不该当作已修好,所以都指到同一份记录。
            Write-Warn "修复步骤未全部成功(退出码 $($fixProc.ExitCode))。"
            Write-Info "逐条结果见上方输出与 修复过程记录 那两行;"
            Write-Info "也可以双击 环境检查.bat 重新采一份报告看现状。"
        }
    }
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "  全部完成。启动 eNSP,拉一台设备试试。" -ForegroundColor Green
Write-Host "  要还原:双击 卸载.bat。" -ForegroundColor Green
Write-Host "  环境报告在 $logDir 下,报障时可直接附进 issue。" -ForegroundColor Green
Write-Host "============================================================`n" -ForegroundColor Green
