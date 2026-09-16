# diag.ps1 -- eNSP x VirtualBox 环境诊断(只读)
#
# 分工:checks.ps1 只探测事实(纯只读、返回对象、不打印),
#       本文件负责判断与展示,并把全部输出落一份报告。
#
# 编码:本文件面向用户、含中文字面量,必须存为 UTF-8 带 BOM。
#       PowerShell 5.1 只对无 BOM 的文件按 ANSI 解码,无 BOM 时中文会乱码。
#
# 只读约定:
#   - 诊断与报告全程不启动任何虚拟机、不修改任何系统设置。
#   - 文件末尾的「修复」菜单是唯一会改动系统的地方:只在用户明确选择后才动手,
#     且另写一份 <报告名>.repair.txt。报告本体始终保持只读采集的形态 ——
#     交互内容不进报告,报告里也就不会出现半截的、读不出结论的会话记录。
#   - 绝不 dot-source install.ps1 —— 该文件有顶层副作用,一旦被 source 就会真的跑安装。
#   - fix.ps1 则可以 dot-source:它是纯函数库,顶层只有变量赋值与对 checks.ps1 的引入,
#     没有副作用,也不会自己执行任何修复(修复只在被调用时发生)。
#   - 读 install.ps1 只按文本读(取 $DLL_SHA256 常量),不执行。
#
# 降级约定:每个探测都可能失败(缺 VBox、缺 eNSP、权限不足)。
#           任何探测失败都不许中断整轮诊断 —— 诊断跑到一半死掉,
#           比只报出部分事实更糟。每节都包 try/catch,失败就地把原因打出来。

param(
    [string]$EnspDir = "",
    [string]$VBoxDir = "",
    [switch]$NoMenu,          # 只出报告,不进修复菜单(自动化/无人值守用这个)
    [switch]$Fix,             # 跳过报告,直接进修复菜单(环境检查.bat -Fix)
    [string]$ReportPath = ""  # 默认 %ProgramData%\ensp-vbox-shim\diag-<时间戳>.txt
)

$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ChecksPath = Join-Path $ScriptDir "checks.ps1"
if (-not (Test-Path $ChecksPath)) {
    Write-Host ("找不到 " + $ChecksPath + " —— 诊断脚本不完整,请重新解压整合包。")
    exit 1
}
. $ChecksPath

# 修复原语。缺了它不影响诊断与报告 —— 只读的那条路必须能单独跑通,
# 所以这里只降级,不 exit;真正要进菜单时,菜单自己按名字检查函数在不在。
$FixPath = Join-Path $ScriptDir "fix.ps1"
if (Test-Path $FixPath) { . $FixPath }

# 全部共用的两个记账变量:
#   $script:DiagFailCount —— 失败的探测数,由 Write-Fail 累加(见该函数处的说明)。
#      是全部的标量计数,读写在脚本作用域内完成,不涉及数组跨作用域绑定。
#   $sectionsOk           —— 实际产出内容的节号。只在顶层追加与读取,不跨函数。
$script:DiagFailCount = 0
$sectionsOk = @()

# ---------------------------------------------------------------------------
# 展示辅助
# ---------------------------------------------------------------------------

# 中文是双宽字符,PowerShell 的 "{0,-16}" 按字符数补齐会错位,这里按显示宽度补。
# 只覆盖 CJK / 全角区段,足够本项目的中文标签使用。
function Get-DisplayWidth {
    param([string]$Text)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Write-Fact {
    param([string]$Label, [string]$Value, [int]$Width = 16)
    $pad = $Width - (Get-DisplayWidth $Label)
    if ($pad -lt 1) { $pad = 1 }
    Write-Host ("  " + $Label + (" " * $pad) + ": " + $Value)
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 64)
    Write-Host ("  " + $Title)
    Write-Host ("=" * 64)
}

function Write-Note {
    param([string]$Text)
    Write-Host ("  " + $Text)
}

# 探测失败的统一落点:把失败打在受影响的节里,然后继续。
# 计数用 $script: —— 本函数定义在 diag.ps1 内、且只从 diag.ps1 的顶层调用,
# 所以 $script: 解析到的正是本文件的脚本作用域,不会踩 checks.ps1 那个
# 「$script: 落到调用方作用域」的坑(那个坑说的是被 dot-source 的库函数)。
# 这里写的是标量计数,不是数组。
function Write-Fail {
    param([string]$Where, [string]$Message)
    $script:DiagFailCount = $script:DiagFailCount + 1
    Write-Host ("  [探测失败] " + $Where + " : " + $Message)
}

# 只读地跑一个外部命令并取回文本行。失败返回对象,不抛出。
function Invoke-Probe {
    param([string]$Exe, [string[]]$Arguments)

    if ([string]::IsNullOrEmpty($Exe)) {
        return [pscustomobject]@{ Ok = $false; Lines = @(); Error = "未定位到该程序" }
    }
    if (-not (Test-Path $Exe)) {
        return [pscustomobject]@{ Ok = $false; Lines = @(); Error = "找不到 " + $Exe }
    }

    # 原生命令往 stderr 写东西时,$ErrorActionPreference = "Stop" 会把它升级成
    # 终止错误(VBoxDrvInst 的 release log 就走 stderr)。这里临时放回 Continue,
    # 成败由返回值自己表达。
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

# ===========================================================================
# 交互式修复(菜单)
#
# 这一段是本文件唯一会改动系统的地方,且只在用户明确选择后才动手;上面的诊断与报告
# 始终是只读的。三条硬约定:
#
#   1. 菜单一律在 Start-Transcript 之外运行。报告是「只读采集」的产物:交互提示与
#      用户键入混进去,报告既读不出结论、又与它抬头的「不修改任何系统设置」自相矛盾。
#      修复过程单独落一份 <报告名>.repair.txt,记录不会因此丢掉。
#   2. 任何失败都不许把诊断打断:报告在此之前就已落盘,菜单出错只影响它自己。
#   3. 读不到输入(EOF)就干净退出,绝不在无人应答的终端上死等。
#
# 修复能力全部来自 fix.ps1。这里只负责四件事:挑出「诊断真的发现问题」的那几项、
# 把将要执行的命令原样显示出来、按档位做确认、调用修复函数并把结果报出来。
#
# 档位(设计 §7.1,判据是「是否无损」):
#   lossless  无损可修      —— 选中即执行
#   confirm   有损但必需    —— 先明示影响,再单独确认一次,与菜单选择是两次输入
#   manual    有损且非必需  —— 不进菜单编号,只打印现状、原因与手动步骤
# ===========================================================================

# ---------------------------------------------------------------------------
# 输入:读不到就退出,不死等
# ---------------------------------------------------------------------------

# 控制台输入是否被重定向。取不到 Console 的宿主(无控制台的服务/计划任务)按
# 「已重定向」处理 —— 那种环境里等待输入必然等不到。
function Test-ConsoleInputRedirected {
    try { return [bool][Console]::IsInputRedirected } catch { return $true }
}

# 为整个菜单会话建一个读取器,只在输入被重定向时用。
# 必须复用同一个实例:StreamReader 一次会读进一整块,每次新建都会把上一轮多读进来
# 的行丢掉 —— 输入「1\nYES\n0\n」时,第二问就再也看不到 YES 了。
function New-MenuStdinReader {
    try { return (New-Object IO.StreamReader([Console]::OpenStandardInput())) } catch { return $null }
}

# 读一行输入。返回 $null 表示输入已结束(EOF),调用方据此干净退出。
#   键盘终端: 直接阻塞读 —— 对面有人在,不需要也不该有超时。
#   重定向:   有界等待。「管道既不送数据也不关闭」是唯一会把阻塞读永久挂住的情形,
#             超时把它兜住;超时与 EOF 一样按「没有输入了」处理。
#
# 重定向这一路刻意不用 [Console]::In:它在 .NET Framework 里是 SyncTextReader,
# 它的 ReadLineAsync() 就是同步 ReadLine() 套了一个已完成的任务(实测 IsCompleted
# 恒为 True)—— 拿它做 Wait(超时) 等于直接阻塞,兜不住任何东西。
# 自己包一层 StreamReader 才有真的异步读,超时才会到点返回。
#
# 也不用 Read-Host:它在 EOF 上返回空串而不是 $null,菜单会当成「无效输入」反复重问,
# 这正是无人值守时最常见的挂死形态。
function Read-MenuLine {
    param([bool]$Redirected = $false, [int]$TimeoutMs = 15000, [object]$Reader = $null)

    if (-not $Redirected) {
        try { return [Console]::ReadLine() } catch { return $null }
    }
    if (-not $Reader) { return $null }
    try {
        $task = $Reader.ReadLineAsync()
        if (-not $task.Wait($TimeoutMs)) { return $null }
        return $task.Result
    } catch {
        return $null
    }
}

# 纯函数:把一行输入解析成菜单选择。做成纯函数是为了能脱离终端核对各种写法。
# 返回 Ok / Quit / All / Indices / Reason。
function ConvertTo-MenuSelection {
    param([string]$Text = "", [int]$Max = 0)

    $t = "$Text".Trim()
    if ($t -eq "0") {
        return [pscustomobject]@{ Ok = $true; Quit = $true; All = $false; Indices = @(); Reason = "quit" }
    }
    if ($t -match '^[Aa]$') {
        return [pscustomobject]@{ Ok = $true; Quit = $false; All = $true; Indices = @(); Reason = "all" }
    }
    if ($t -eq "") {
        return [pscustomobject]@{ Ok = $false; Quit = $false; All = $false; Indices = @(); Reason = "empty" }
    }

    $indices = @()
    foreach ($part in ($t -split ",")) {
        $p = $part.Trim()
        $n = 0
        if (-not [int]::TryParse($p, [ref]$n)) {
            return [pscustomobject]@{ Ok = $false; Quit = $false; All = $false; Indices = @(); Reason = ("不是编号: " + $p) }
        }
        if ($n -lt 1 -or $n -gt $Max) {
            return [pscustomobject]@{ Ok = $false; Quit = $false; All = $false; Indices = @(); Reason = ("超出范围: " + $n) }
        }
        if ($indices -notcontains $n) { $indices += $n }
    }
    return [pscustomobject]@{ Ok = $true; Quit = $false; All = $false; Indices = @($indices | Sort-Object); Reason = "ok" }
}

# ---------------------------------------------------------------------------
# 虚拟化后端(第三档:只打印,不修)
# ---------------------------------------------------------------------------

# 纯只读,且刻意绕开 DISM:Get-WindowsOptionalFeature 在本机会挂住(TrustedInstaller
# 卡死,十分钟不返回),install.ps1 已为此改过一次。判据是「hypervisor 现在是否真的
# 在跑」,而不是「Hyper-V 功能装没装」—— 前者才决定 VBox 拿不拿得到原生 VT-x。
function Get-HypervisorFacts {
    $known   = $false
    $present = $false
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $present = [bool]$cs.HypervisorPresent
        $known   = $true
    } catch { }

    $launch = ""
    try {
        $bcd = Join-Path $env:SystemRoot "System32\bcdedit.exe"
        $probe = Invoke-Probe -Exe $bcd -Arguments @("/enum", "{current}")
        if ($probe.Ok) {
            foreach ($line in $probe.Lines) {
                if ($line -match 'hypervisorlaunchtype\s+(\S+)') { $launch = $Matches[1].Trim() }
            }
        }
    } catch { }

    $vbs = $false
    try {
        $dg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -ErrorAction Stop
        if ($dg.EnableVirtualizationBasedSecurity -eq 1) { $vbs = $true }
    } catch { }

    $hvci = $false
    try {
        $hv = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -ErrorAction Stop
        if ($hv.Enabled -eq 1) { $hvci = $true }
    } catch { }

    return [pscustomobject]@{
        Known      = $known
        Present    = $present
        LaunchType = $launch
        Vbs        = $vbs
        Hvci       = $hvci
        Any        = ($present -or $vbs -or $hvci -or ($launch -match 'Auto'))
    }
}

# 虚拟化后端的说明。探测不到就不打印 —— 不写「未启用」这类会误导的结论。
# 措辞是本项目已经定下的立场:这不是故障,不要关。见 docs/troubleshooting-error40.md
# 与设计 §7.1:社区里「关 Hyper-V」的教程针对的是 VirtualBox 5.2(与 Hyper-V 互斥),
# 与本项目场景(7.x 靠 WHP 共存)正相反。
function Get-HypervisorNotes {
    param([object]$Facts = $null)

    $hv = $Facts
    if (-not $hv) { $hv = Get-HypervisorFacts }
    $lines = @()
    if (-not $hv.Any) { return $lines }

    $lines += "已探测到:"
    if ($hv.Present) { $lines += "  hypervisor 正在运行 (Win32_ComputerSystem.HypervisorPresent = True)" }
    if ($hv.LaunchType) { $lines += "  启动类型 hypervisorlaunchtype = " + $hv.LaunchType }
    if ($hv.Vbs)  { $lines += "  基于虚拟化的安全 (VBS) 已启用" }
    if ($hv.Hvci) { $lines += "  内存完整性 (HVCI / 内核隔离) 已启用" }
    $lines += "影响: VirtualBox 7.x 拿不到原生 VT-x,改走 WHP 后端 —— 设备启动会变慢,"
    $lines += "      单台 3-5 分钟属正常,不是故障,也不影响设备功能。"
    $lines += "处置: 不修复,也不建议关闭。"
    $lines += "  关掉 Hyper-V / VBS / 内存完整性需要重启,并且会连带影响本机上依赖它们的"
    $lines += "  其他功能(WDAG、WSL2、沙盒、Credential Guard)。"
    $lines += "  它不是 error 40 的成因。社区里「关 Hyper-V」的做法针对的是 VirtualBox 5.2,"
    $lines += "  5.2 与 Hyper-V 互斥;7.x 靠 WHP 与 Hyper-V 共存,开着 Hyper-V 正是本项目的场景。"
    return $lines
}

# ---------------------------------------------------------------------------
# 发现:诊断真的查出问题的那几项
# ---------------------------------------------------------------------------

# 只报「诊断确实发现的问题」,并给出对应的修复步骤。没查出问题就没有条目 ——
# 菜单因此不会在健康机器上退化成一串空操作。
#
# 判据全部来自 checks.ps1 的同一批探测函数,和报告读的是同一套事实:报告说缺、
# 菜单才会提;报告说好、菜单就不提。
#
# 触发项(与设计 §7.1 的档位对应):
#   host-only 驱动未注册 / 一个 host-only 接口都没有  -> 四步链,confirm 档
#   性能计数器不工作                                  -> lodctr /R,  lossless 档
#   没有「已启用 + 允许」的 eNSP 规则                  -> 加规则,     lossless 档
#
# 读不到防火墙配置时不下结论、也不提供修复:那既可能是真的没有规则,也可能是权限
# 不足;在「没读到」的基础上加一条规则,可能造出与已有规则重名的第二条。诊断本身
# 就是按这个口径写的,菜单跟着它走。
#
# 探测本身失败(抛异常)时也不静默跳过:那会让菜单把「没查到」说成「没问题」。
# 那种情形落成一条 manual 条目,把失败原因如实打出来。
function New-UnjudgedItem {
    param([string]$Id, [string]$Title, [string]$Why)
    return [pscustomobject]@{
        Id       = $Id
        Tier     = "manual"
        Title    = $Title
        Symptom  = ""
        Evidence = ""
        Impact   = @()
        Steps    = @()
        Manual   = @(
            ("未能判定: " + $Why)
            "手动步骤: 先排除这条探测失败的原因(权限不足居多),再重跑本菜单。"
        )
    }
}

function Get-RepairFindings {
    param([string]$VBoxDir = "", [string]$EnspDir = "")

    $items = @()
    $vboxDirFound = Find-VBoxDir -Override $VBoxDir
    $vboxManage = ""
    if ($vboxDirFound) { $vboxManage = Join-Path $vboxDirFound "VBoxManage.exe" }

    # --- host-only(第 1 层驱动注册 / 第 3 层接口是否存在)-------------------
    try {
        $drvLines = @()
        if ($vboxDirFound) {
            $probe = Invoke-Probe -Exe (Join-Path $vboxDirFound "VBoxDrvInst.exe") -Arguments @("list")
            if ($probe.Ok) { $drvLines = $probe.Lines }
        }
        $layers = Get-HostOnlyDriverLayers -DrvInstLines $drvLines

        # 接口数为 -1 表示没读到(和「读到 0 个」是两回事)。只有读到 0 才作为依据:
        # 「取不到」不是证据,判成的只是「取到了而且没有」。
        $ifCount = -1
        if ($vboxManage) {
            $probe = Invoke-Probe -Exe $vboxManage -Arguments @("list", "hostonlyifs")
            if ($probe.Ok) { $ifCount = @(Parse-HostOnlyIfs -Lines $probe.Lines).Count }
        }

        if ($vboxDirFound) {
            $why = @()
            if (-not $layers.Layer1.NetAdpPresent) { $why += "第 1 层: VBoxNetAdp6.NTAMD64 未注册" }
            if (-not $layers.Layer1.NetLwfPresent) { $why += "第 1 层: VBoxNetLwf.NTAMD64 未注册" }
            if ($ifCount -eq 0)                    { $why += "第 3 层: 一个 host-only 接口都没有" }

            if ($why.Count -gt 0) {
                $items += [pscustomobject]@{
                    Id      = "hostonly"
                    Tier    = "confirm"
                    Title   = "host-only 网络驱动 / 接口"
                    Symptom = "设备起不来,或起来后连不通宿主(VBoxManage startvm 报 VERR_INTNET_FLT_IF_NOT_FOUND)"
                    Evidence = ($why -join "; ")
                    Impact  = @(
                        "重装驱动包会重新注册网络组件,并禁用/启用一次 host-only 网卡 ——"
                        "本机网络会短暂中断(数秒到十几秒)。"
                        "正在运行的设备、Tailscale / WireGuard 之类的常连隧道、"
                        "Hyper-V 虚拟交换机都会闪断。"
                        "修复前请先关闭 eNSP(下面的前置校验会再确认一次)。"
                    )
                    Steps   = @(
                        [pscustomobject]@{ Fn = "Repair-InstallNetAdp";    Args = @{ VBoxDir = $vboxDirFound } }
                        [pscustomobject]@{ Fn = "Repair-InstallNetLwf";    Args = @{ VBoxDir = $vboxDirFound } }
                        [pscustomobject]@{ Fn = "Repair-BounceAdapter";    Args = @{} }
                        [pscustomobject]@{ Fn = "Repair-CreateHostOnlyIf"; Args = @{ VBoxDir = $vboxDirFound } }
                    )
                    Manual  = @()
                }
            }
        }
    } catch {
        $items += New-UnjudgedItem -Id "hostonly-unknown" -Title "host-only 网络状态:未能判定" `
            -Why ("探测出错 —— " + $_.Exception.Message)
    }

    # --- 性能计数器 ---------------------------------------------------------
    try {
        $perf = Test-PerfCountersFunctional
        if (-not $perf.Functional) {
            $items += [pscustomobject]@{
                Id      = "perfcounters"
                Tier    = "lossless"
                Title   = "Windows 性能计数器损坏"
                Symptom = "设备一直打印 #### ,进不到 <Huawei> 提示符"
                Evidence = ("计数器的实测调用失败: " + $perf.Reason)
                Impact  = @()
                Steps   = @( [pscustomobject]@{ Fn = "Repair-RebuildPerfCounters"; Args = @{} } )
                Manual  = @()
            }
        }
    } catch {
        $items += New-UnjudgedItem -Id "perfcounters-unknown" -Title "性能计数器状态:未能判定" `
            -Why ("探测出错 —— " + $_.Exception.Message)
    }

    # --- 防火墙放行 ---------------------------------------------------------
    try {
        $fwText = @(Get-FirewallRuleTextForEnsp)
        $fw = Parse-FirewallRulesForEnsp -Lines $fwText
        if (-not $fw.HasAllowRule) {
            if ($fwText.Count -eq 0) {
                $items += [pscustomobject]@{
                    Id      = "firewall-unknown"
                    Tier    = "manual"
                    Title   = "eNSP 防火墙放行规则:未能判定"
                    Symptom = ""
                    Evidence = ""
                    Impact  = @()
                    Steps   = @()
                    Manual  = @(
                        "原因: 一条 eNSP / VBoxServer 规则都没读到 —— 既可能是确实没有,"
                        "也可能是当前权限读不到防火墙配置,诊断不下结论。"
                        "手动步骤: 用管理员身份重跑一次环境检查;确认确实没有规则之后,"
                        "再回来让本菜单放行。"
                    )
                }
            } else {
                $items += [pscustomobject]@{
                    Id      = "firewall"
                    Tier    = "lossless"
                    Title   = "防火墙未放行 eNSP_VBoxServer"
                    Symptom = "设备一直打印 #### ,进不到 <Huawei> 提示符"
                    Evidence = "现有规则里没有一条同时满足「已启用 + 允许」的 eNSP / VBoxServer 规则"
                    Impact  = @()
                    Steps   = @( [pscustomobject]@{ Fn = "Repair-AllowEnspFirewall"; Args = @{ EnspDir = $EnspDir } } )
                    Manual  = @()
                }
            }
        }
    } catch { }

    return $items
}

# ---------------------------------------------------------------------------
# 菜单
# ---------------------------------------------------------------------------

function Show-RepairMenu {
    param(
        [object[]]$Items = @(),
        [bool]$InputRedirected = $false,
        [int]$InputTimeoutMs = 15000,
        [object]$StdinReader = $null
    )

    $fixable = @($Items | Where-Object { ($_.Tier -eq "lossless") -or ($_.Tier -eq "confirm") })
    $manual  = @($Items | Where-Object { $_.Tier -eq "manual" })

    Write-Host ""
    Write-Host ("=" * 64)
    Write-Host "  修复"
    Write-Host ("=" * 64)
    Write-Host ""
    Write-Note "这一段会改动系统,且只在明确选择之后才动手。报告是只读采集,已经写完。"
    if ($InputRedirected) {
        Write-Note "[提示] 标准输入是重定向的:读到输入结束即退出菜单,不会在这里等。"
    }

    if ($fixable.Count -eq 0) {
        Write-Host ""
        Write-Note "没有发现可由本工具自动修复的问题。"
        Write-Note "三项可修项(host-only 驱动 / 性能计数器 / 防火墙放行)本次都已满足,"
        Write-Note "或者根本没被判定为问题 —— 菜单不列空操作,本次也不改动任何系统设置。"
    } else {
        Write-Host ""
        Write-Host ("  发现 " + $fixable.Count + " 个可由本工具修复的问题:")
        Write-Host ""
        for ($i = 0; $i -lt $fixable.Count; $i++) {
            $it = $fixable[$i]
            $tierText = "无损"
            if ($it.Tier -eq "confirm") { $tierText = "有损,执行前单独确认" }
            Write-Host ("  [" + ($i + 1) + "] " + $it.Title + "   <" + $tierText + ">")
            Write-Note ("症状: " + $it.Symptom)
            Write-Note ("依据: " + $it.Evidence)
            Write-Host ""
        }
    }

    # 第三档永远只打印。它不占编号,也不出现在选择里 —— 这里没有它的修复入口。
    if ($manual.Count -gt 0) {
        Write-Host "  以下项不自动修复:"
        Write-Host ""
        foreach ($it in $manual) {
            Write-Host ("  * " + $it.Title)
            foreach ($line in $it.Manual) { Write-Note $line }
            Write-Host ""
        }
    }

    if ($fixable.Count -eq 0) { return }

    # ---------------- 选择与执行 ----------------
    while ($true) {
        Write-Host "  输入编号修复(多项用逗号分隔,如 1,3);[A] 全部;[0] 退出:"
        Write-Host -NoNewline "  > "
        $text = Read-MenuLine -Redirected $InputRedirected -TimeoutMs $InputTimeoutMs -Reader $StdinReader
        # 提示行是用 -NoNewline 写的,回车由终端回显补上;重定向时没有回显,
        # 自己把这一行收尾,否则后续输出会黏在 "> " 后面。
        if ($null -eq $text -or $InputRedirected) { Write-Host "" }
        if ($null -eq $text) {
            Write-Note "输入结束(或等待输入超时),退出修复菜单。已写好的报告不受影响。"
            return
        }
        $sel = ConvertTo-MenuSelection -Text $text -Max $fixable.Count
        if ($sel.Quit) {
            Write-Note "已选择退出,未做任何改动。"
            return
        }
        if (-not $sel.Ok) {
            Write-Note ("无效输入「" + $text.Trim() + "」(" + $sel.Reason + ")。")
            Write-Note ("请输入 1 到 " + $fixable.Count + " 之间的编号、逗号分隔的多个编号、A 或 0。")
            continue
        }

        $chosen = @()
        if ($sel.All) {
            for ($i = 1; $i -le $fixable.Count; $i++) { $chosen += $i }
        } else {
            $chosen = @($sel.Indices)
        }

        # 设计 §7 的前置校验,不可省:修复前必须确认 eNSP 已关闭。
        # 未通过时只把命令列出来,一步都不执行。
        $pre = $null
        try { $pre = Test-RepairPreconditions } catch { $pre = $null }

        foreach ($idx in $chosen) {
            $it = $fixable[$idx - 1]
            Write-Host ""
            Write-Host ("  ---- [" + $idx + "] " + $it.Title + " ----")

            # 先跑一遍 -DryRun。既是「显示将要执行的命令」那条约束的落点
            # (fix.ps1 的约定:调用方先 -DryRun 显示、再去掉开关执行),也顺带
            # 确认每一步的前置条件都成立 —— 前置不成立就不该动手。
            $planned = @()
            $planOk = $true
            $planReason = ""
            $alreadyDone = @()
            foreach ($step in $it.Steps) {
                if (-not (Get-Command $step.Fn -ErrorAction SilentlyContinue)) {
                    $planOk = $false
                    $planReason = ("修复原语缺失:找不到 " + $step.Fn + "(整合包不完整)")
                    break
                }
                $argMap = $step.Args
                try {
                    $r = & $step.Fn @argMap -DryRun
                } catch {
                    $planOk = $false
                    $planReason = ($step.Fn + " 计划阶段出错: " + $_.Exception.Message)
                    break
                }
                if (-not $r.Ok) {
                    $planOk = $false
                    $planReason = ($step.Fn + ": " + $r.Reason)
                    break
                }
                if ($r.Skipped) { $alreadyDone += $step.Fn }
                $planned += @($r.Commands)
            }

            Write-Note ("步骤: " + (@($it.Steps | ForEach-Object { $_.Fn }) -join " -> "))
            if ($planned.Count -gt 0) {
                Write-Note "将要执行的命令:"
                foreach ($c in $planned) { Write-Host ("      " + $c) }
            } else {
                Write-Note "计划阶段没有产生任何命令。"
            }
            if ($alreadyDone.Count -gt 0) {
                Write-Note ("计划阶段判定已满足(真正执行时会再确认一次): " + ($alreadyDone -join ", "))
            }

            if (-not $planOk) {
                Write-Note ("[跳过] 前置条件不成立,未执行: " + $planReason)
                continue
            }

            if ($pre -and (-not $pre.Ok)) {
                Write-Host ""
                Write-Note ("eNSP 正在运行(" + ($pre.Running -join ", ") + ")。按设计约定,修复前必须关闭")
                Write-Note "eNSP —— 网络组件重绑会打断正在运行的设备。本次只显示上面的命令,不执行。"
                Write-Note "关闭 eNSP 后重跑本菜单即可。"
                continue
            }

            # 第二档:与「选择」分开的第二次确认。
            if ($it.Tier -eq "confirm") {
                Write-Host ""
                Write-Note "!! 这一项属于「有损但必需」—— 执行前请先看清影响:"
                foreach ($line in $it.Impact) { Write-Note ("   " + $line) }
                Write-Host ""
                Write-Host -NoNewline "  确认执行?输入 YES 继续,其他任何输入都跳过这一项: "
                $ans = Read-MenuLine -Redirected $InputRedirected -TimeoutMs $InputTimeoutMs -Reader $StdinReader
                if ($null -eq $ans -or $InputRedirected) { Write-Host "" }
                if ($null -eq $ans) {
                    Write-Note "输入结束,跳过这一项。"
                    continue
                }
                if ($ans.Trim() -ne "YES") {
                    Write-Note "未确认(输入不是 YES),已跳过这一项。"
                    continue
                }
            }

            # 执行。顺序是硬依赖:中间一步失败就停下 —— fix.ps1 明确写过,
            # 前面的步骤没成就去建接口,会留下「接口在、栈不通」的状态,
            # 症状与完全没修一模一样,是最难查的一种「修了没用」。
            $failed = $false
            foreach ($step in $it.Steps) {
                $argMap = $step.Args
                try {
                    $r = & $step.Fn @argMap
                } catch {
                    Write-Note ("[失败] " + $step.Fn + " 抛出异常: " + $_.Exception.Message)
                    $failed = $true
                    break
                }
                if (-not $r.Ok) {
                    Write-Note ("[失败] " + $step.Fn + ": " + $r.Reason)
                    if ($r.Commands -and $r.Commands.Count -gt 0) {
                        Write-Note "  该步的命令行(可手动执行):"
                        foreach ($c in @($r.Commands)) { Write-Host ("      " + $c) }
                    }
                    $failed = $true
                    break
                }
                if ($r.Skipped) {
                    Write-Note ("[跳过] " + $step.Fn + ": 已满足,无需执行")
                } elseif ($r.Changed) {
                    Write-Note ("[完成] " + $step.Fn)
                } else {
                    Write-Note ("[完成] " + $step.Fn + "(没有需要改动的项)")
                }
            }
            if ($failed) {
                Write-Note "后续步骤依赖前一步,已停下。排掉上面这条原因后重跑本菜单。"
            }
        }

        Write-Host ""
        Write-Note "可继续选择其它编号,或输入 0 退出。修完重跑一次环境检查即可核对结果。"
    }
}

# ---------------------------------------------------------------------------
# 菜单总入口
# ---------------------------------------------------------------------------

# -Fix(跳过报告)与默认路径(报告之后)共用这一段。
function Invoke-RepairMenuEntry {
    param(
        [string]$EnspDir = "",
        [string]$VBoxDir = "",
        [string]$ReportPath = "",
        [bool]$TranscriptActive = $false
    )

    if ($TranscriptActive) {
        Write-Host ""
        Write-Host "[提示] 报告转录仍在进行,为避免把交互内容写进报告,跳过修复菜单。"
        return
    }
    if (-not (Get-Command Repair-InstallNetAdp -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "[提示] 未加载 fix.ps1(修复原语),本次只出报告、不做修复。"
        Write-Host "       整合包不完整时重新解压即可;只读诊断不受影响。"
        return
    }

    # 菜单在报告转录之外,所以它自己起一段转录:否则整个交互过程在磁盘上不留任何
    # 记录,「修了没用」这类问题就无从复查。写不进去也不影响菜单本身。
    $repairLog = ""
    $menuTranscript = $false
    try {
        if ($ReportPath) {
            $repairLog = [IO.Path]::ChangeExtension($ReportPath, ".repair.txt")
        } else {
            $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
            $repairLog = Join-Path (Join-Path $env:ProgramData "ensp-vbox-shim") ("repair-" + $stamp + ".txt")
        }
        $repairDir = Split-Path -Parent $repairLog
        if ($repairDir -and -not (Test-Path $repairDir)) {
            New-Item -ItemType Directory -Path $repairDir -Force | Out-Null
        }
        Start-Transcript -Path $repairLog -Force | Out-Null
        $menuTranscript = $true
    } catch {
        $menuTranscript = $false
        $repairLog = ""
    }

    $items = @()
    try { $items += @(Get-RepairFindings -VBoxDir $VBoxDir -EnspDir $EnspDir) } catch { }

    # 第三档:虚拟化冲突类。只打印,永不给出修复入口 —— 见 Get-HypervisorNotes 的说明。
    try {
        $hvLines = @(Get-HypervisorNotes)
        if ($hvLines.Count -gt 0) {
            $items += [pscustomobject]@{
                Id       = "hypervisor"
                Tier     = "manual"
                Title    = "Hyper-V / VBS / 内核隔离 正在运行(第三档:有损且非必需)"
                Symptom  = ""
                Evidence = ""
                Impact   = @()
                Steps    = @()
                Manual   = $hvLines
            }
        }
    } catch { }

    try {
        # 读取器按「输入是否被重定向」二选一:键盘终端走 [Console]::ReadLine(),
        # 重定向走一个整场复用的 StreamReader(理由见 Read-MenuLine)。
        $redirected = Test-ConsoleInputRedirected
        $stdinReader = $null
        if ($redirected) { $stdinReader = New-MenuStdinReader }

        # 修复步骤连同各自的参数都挂在 finding 上(见 Get-RepairFindings),
        # 所以菜单不需要 VBoxDir / EnspDir。
        Show-RepairMenu -Items $items -InputRedirected $redirected -InputTimeoutMs 15000 -StdinReader $stdinReader
    } catch {
        Write-Host ""
        Write-Host ("[提示] 修复菜单自身出错,已中止交互(报告与已完成的改动都不受影响): " + $_.Exception.Message)
    }

    if ($menuTranscript) { try { Stop-Transcript | Out-Null } catch { } }

    if ($repairLog) { Write-Host ("  修复过程记录: " + $repairLog) }
}

# ---------------------------------------------------------------------------
# 路径定位(只读)
#
# Find-EnspDir / Find-VBoxDir 由 checks.ps1 提供(见上方 dot-source)—— 与 install.ps1
# 共用同一份实现。它们不打印、不 exit,找不到返回 $null,由下面的各节自行降级。
# 这也是本文件绝不能 dot-source install.ps1 的原因:那个文件有顶层副作用,
# 一旦被 source 就会真的跑一遍安装。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# -Fix:跳过报告,直接进菜单
#
# 报告那一整段是只读的,这里提前离开就不会产出报告文件 —— 用户要的是修,不是再看
# 一遍已经看过的报告。菜单本身会把它发现的项、以及将要执行的命令完整打印出来。
# 放在这里(而不是包住整段报告)是为了不打乱只读路径:报告那一节一行都不用改,
# 也就不存在「加了菜单之后报告坏了」这种风险。
# ---------------------------------------------------------------------------
# 两个开关互相矛盾时以 -NoMenu 为准。-NoMenu 是自动化用的「绝不读输入」保证,
# 不该被另一个开关悄悄推翻;这里明说一句,而不是沉默地挑一个执行。
if ($Fix -and $NoMenu) {
    Write-Host ""
    Write-Host "[提示] -NoMenu 与 -Fix 同时给出,按 -NoMenu 处理:只出报告,不进修复菜单。"
    Write-Host ""
}
if ($Fix -and (-not $NoMenu)) {
    Write-Host ("=" * 64)
    Write-Host "  eNSP x VirtualBox 环境诊断 —— 修复模式(-Fix)"
    Write-Host "  已跳过诊断报告,直接进入修复菜单。"
    Write-Host "  需要报告请改跑 环境检查.bat(不带参数)或 diag.ps1 -NoMenu。"
    Write-Host ("=" * 64)

    $FixEnspDir = Find-EnspDir -Override $EnspDir
    $FixVBoxDir = Find-VBoxDir -Override $VBoxDir

    try {
        Invoke-RepairMenuEntry -EnspDir $FixEnspDir -VBoxDir $FixVBoxDir -ReportPath "" -TranscriptActive $false
    } catch {
        Write-Host ""
        Write-Host ("[提示] 修复菜单出错: " + $_.Exception.Message)
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------------------
# 报告落盘
# ---------------------------------------------------------------------------
$LogDir = Join-Path $env:ProgramData "ensp-vbox-shim"
if (-not $ReportPath) {
    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $ReportPath = Join-Path $LogDir ("diag-" + $stamp + ".txt")
}

$transcriptOn = $false
try {
    $reportDir = Split-Path -Parent $ReportPath
    if ($reportDir -and -not (Test-Path $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
    Start-Transcript -Path $ReportPath -Force | Out-Null
    $transcriptOn = $true
} catch {
    Write-Host ("[警告] 报告文件无法写入,本次只输出到屏幕: " + $_.Exception.Message)
}

Write-Host ("=" * 64)
Write-Host "  eNSP x VirtualBox 环境诊断报告"
Write-Host ("  生成时间 : " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
Write-Host "  本报告为只读采集,不修改任何系统设置。"
Write-Host "  可直接附进 issue;除系统用户名外不含个人信息。"
Write-Host ("=" * 64)

$EnspDir = Find-EnspDir -Override $EnspDir
$VBoxDir = Find-VBoxDir -Override $VBoxDir

# VBox 的两个可执行文件在这里统一解析:第 1 节要跑 VBoxManage 取真实版本,
# 第 3 节要跑 VBoxManage 与 VBoxDrvInst。解析一次,两节共用。
$vboxManageExe = ""
$vboxDrvInstExe = ""
if ($VBoxDir) {
    $vboxManageExe = Join-Path $VBoxDir "VBoxManage.exe"
    $vboxDrvInstExe = Join-Path $VBoxDir "VBoxDrvInst.exe"
} else {
    Write-Note "[提示] 未定位到 VBox 目录,VBoxManage / VBoxDrvInst 都取不到。请用 -VBoxDir 指定。"
}

# ===========================================================================
# 第 1 节  基础事实
# ===========================================================================
Write-Section "[1] 基础事实"
$sectionsOk += "1"

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    Write-Fact "操作系统" ($os.Caption + "  (Build " + $os.BuildNumber + ")")
    Write-Fact "系统架构" ($os.OSArchitecture + "  /  PowerShell " + $PSVersionTable.PSVersion.ToString())
} catch {
    Write-Fail "操作系统" $_.Exception.Message
}

# VirtualBox 在注册表里的版本。7.x 装在 64 位视图,某些历史安装只写了 WOW6432Node,
# 两个键都读、各自如实报出。
$vboxVerKeys = @("HKLM:\SOFTWARE\Oracle\VirtualBox", "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox")
$vboxVerSeen = $false
foreach ($k in $vboxVerKeys) {
    try {
        if (-not (Test-Path $k)) { continue }
        $v = (Get-ItemProperty $k -ErrorAction Stop).Version
        if ($v) {
            Write-Fact "注册表版本" ($v + "   <- " + $k)
            $vboxVerSeen = $true
        }
    } catch {
        Write-Fail ("注册表版本 " + $k) $_.Exception.Message
    }
}
if (-not $vboxVerSeen) {
    Write-Fact "注册表版本" "(两个注册表键都没有 Version)"
}
Write-Note "该注册表值是 eNSP 看到的那一个 —— 装有本垫片时它被改写为 5.2.x,"
Write-Note "属伪装值,不等于真实 VBox 版本。真实版本单独探测如下。"

# 真实版本必须自己跑一次 VBoxManage 才拿得到。只报注册表值等于把真实版本
# 从报告里丢掉 —— 本报告是给人独立阅读的,不能要求读者自己补敲命令。
try {
    $verProbe = Invoke-Probe -Exe $vboxManageExe -Arguments @("--version")
    if (-not $verProbe.Ok) {
        Write-Fact "真实版本" ("无法确定 —— " + $verProbe.Error)
    } else {
        $realVer = @($verProbe.Lines | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1)
        if ($realVer.Count -gt 0) {
            Write-Fact "真实版本" ($realVer[0].Trim() + "   <- VBoxManage --version")
        } else {
            Write-Fact "真实版本" "(VBoxManage --version 没有输出)"
        }
    }
} catch {
    Write-Fail "真实版本" $_.Exception.Message
    Write-Fact "真实版本" "无法确定(探测抛错,原因见上一行)"
}

Write-Fact "VBox 目录" $(if ($VBoxDir) { $VBoxDir } else { "(未定位到)" })
Write-Fact "eNSP 目录" $(if ($EnspDir) { $EnspDir } else { "(未定位到)" })

# 垫片 DLL 的四个投放位置。期望值按文本从 install.ps1 里取,不执行该文件。
$expectedSha = ""
try {
    $installerText = Get-Content -Raw -Path (Join-Path $ScriptDir "install.ps1") -ErrorAction Stop
    if ($installerText -match '\$DLL_SHA256\s*=\s*"([0-9a-fA-F]{64})"') {
        $expectedSha = $Matches[1].ToLower()
    }
} catch { }
if ($expectedSha) {
    Write-Fact "垫片期望哈希" $expectedSha
} else {
    Write-Note "[提示] 未能从 install.ps1 读出 $DLL_SHA256,下面只报实际哈希、不判定匹配。"
}

if (-not $EnspDir) {
    Write-Note "[跳过] 未定位到 eNSP 目录,无法核对垫片 DLL。请用 -EnspDir 指定。"
} else {
    $dllRelPaths = @(
        "VBox52.dll",
        "tools\VBox52.dll",
        "vboxserver\VBox52.dll",
        "plugin\ngfw\tools\ngfw\VBox52.dll"
    )
    foreach ($rel in $dllRelPaths) {
        try {
            $p = Join-Path $EnspDir $rel
            if (-not (Test-Path $p)) {
                Write-Host ("  [缺失] " + $rel)
                continue
            }
            $h = (Get-FileHash -Path $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
            if (-not $expectedSha) {
                Write-Host ("  [  ?  ] " + $rel + "  " + $h)
            } elseif ($h -eq $expectedSha) {
                Write-Host ("  [ OK  ] " + $rel + "  " + $h)
            } else {
                Write-Host ("  [不符] " + $rel + "  " + $h)
            }
        } catch {
            Write-Fail $rel $_.Exception.Message
        }
    }
}

# ===========================================================================
# 第 2 节  分流:设备后端
# ===========================================================================
Write-Section "[2] 分流:设备后端"
$sectionsOk += "2"

# 探测表在本文件里自己拼。不用 checks.ps1 的 Get-DeviceBackendProbe:
# 那个函数只回三个布尔值的汇总,而本节要逐个文件打印「有/无」。
# (查找函数已下沉到 checks.ps1,如今它不传 -EnspDir 也能自己定位;
#  只需要汇总结论的场合可以直接用它。)
$probe = @{ HasSwitchExe = $false; HasArBase = $false; HasVfwUsg = $false }
$probeRel = @(
    @{ Key = "HasSwitchExe"; Rel = "vboxserver\devices\LSW\s5700\eNSP_Switch.exe" },
    @{ Key = "HasArBase";    Rel = "vboxserver\AR_Base\AR_Base.vbox" },
    @{ Key = "HasVfwUsg";    Rel = "plugin\ngfw\tools\ngfw\vfw_usg.vbox" }
)

if (-not $EnspDir) {
    Write-Note "[跳过] 未定位到 eNSP 目录,无法判断设备后端。请用 -EnspDir 指定。"
} else {
    foreach ($item in $probeRel) {
        try {
            $probe[$item.Key] = Test-Path (Join-Path $EnspDir $item.Rel)
        } catch {
            Write-Fail $item.Rel $_.Exception.Message
        }
        Write-Host ("  [" + $(if ($probe[$item.Key]) { "有" } else { "无" }) + "] " + $item.Rel)
    }

    try {
        $backend = Get-DeviceBackendFacts -Probe $probe
        Write-Host ""
        Write-Fact "宿主侧设备" $(if ($backend.HostSideDevicesPresent) { "可用" } else { "不可用" })
        Write-Fact "VBox 设备" $(if ($backend.AllVBoxDevicesPresent) { "AR + USG 都在" } elseif ($backend.VBoxDevicesPresent) { "只有一部分" } else { "都不可用" })
        Write-Fact "分流结论" $backend.SplitHint
    } catch {
        Write-Fail "分流判定" $_.Exception.Message
    }
}

Write-Host ""
Write-Note "分流怎么看: 宿主侧设备(S5700 等)是普通用户态进程,完全不经过 VirtualBox。"
Write-Note "  宿主侧可用、AR 不可用  -> 故障在 VirtualBox 层,往下看第 3 节。"
Write-Note "  宿主侧也不可用          -> 先看 eNSP 本体(安装、性能计数器、防火墙、端口)。"
Write-Note "  上表只说明设备包在不在,不代表设备能起来;它用来缩小范围,不用于下结论。"

# 虚拟化后端(Hyper-V / VBS / 内核隔离)。这一段是【信息】,不是故障判定:
# 它们把 VirtualBox 7.x 推到 WHP 后端,代价只是设备启动变慢。此处只报事实,
# 绝不给「关闭」建议 —— 见 Get-HypervisorNotes 的说明与设计 §7.1 第三档。
Write-Host ""
Write-Note "虚拟化后端(信息,不是故障判定):"
try {
    $hvFacts = Get-HypervisorFacts
    if (-not $hvFacts.Known) {
        Write-Note "  未能探测(读取 Win32_ComputerSystem 失败),此处不做判断。"
    } elseif (-not $hvFacts.Any) {
        Write-Note "  未探测到运行中的 hypervisor —— VirtualBox 拿得到原生 VT-x。"
    } else {
        foreach ($line in @(Get-HypervisorNotes -Facts $hvFacts)) { Write-Note ("  " + $line) }
    }
} catch {
    Write-Fail "虚拟化后端" $_.Exception.Message
}

# ===========================================================================
# 第 3 节  host-only 网络(六层)
# ===========================================================================
Write-Section "[3] host-only 网络(六层)"
$sectionsOk += "3"

# $vboxManageExe / $vboxDrvInstExe 已在第 1 节之前解析完毕,这里直接用。
$ifsProbe = Invoke-Probe -Exe $vboxManageExe -Arguments @("list", "hostonlyifs")
$drvProbe = Invoke-Probe -Exe $vboxDrvInstExe -Arguments @("list")

$ifNames = @()

# --- 第 1 层:驱动注册 ------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- 第 1 层:驱动注册 (VBoxDrvInst list) --"
    if (-not $drvProbe.Ok) {
        Write-Fail "第 1 层" $drvProbe.Error
    } else {
        $drv = Parse-VBoxDrvInstList -Lines $drvProbe.Lines
        Write-Host ("  [" + $(if ($drv.NetAdpPresent) { " OK " } else { "缺失" }) + "] VBoxNetAdp6.NTAMD64")
        Write-Host ("  [" + $(if ($drv.NetLwfPresent) { " OK " } else { "缺失" }) + "] VBoxNetLwf.NTAMD64")

        if (-not ($drv.NetAdpPresent -and $drv.NetLwfPresent)) {
            Write-Host ""
            Write-Note "  !! 这就是 2026-09-15 的故障形态:VBox 网络驱动包不在驱动库里。"
            Write-Note "     禁用它再启用、或重新注册驱动,都修不好 —— 必须重装驱动包:"
            Write-Note "       VBoxDrvInst.exe install --inf-file <VBoxDir>\netadp6\VBoxNetAdp6.inf"
            Write-Note "       netcfg.exe -v -l <VBoxDir>\netlwf\VBoxNetLwf.inf -c s -i oracle_VBoxNetLwf"
            Write-Note "     之后还要做一次适配器禁用/启用,否则驱动不会进入数据路径。"
            if ($drv.NetAdpPresent -and (-not $drv.NetLwfPresent)) {
                Write-Note "     已知陷阱: 只补 netadp6 不补 netlwf 时,hostonlyif create 会成功,"
                Write-Note "     但接口名变成 \"...Adapter #2\",而 eNSP 按精确名绑定 —— 症状与完全缺失一样。"
            }
        }
    }
} catch {
    Write-Fail "第 1 层" $_.Exception.Message
}

# --- 第 2 层:服务 ----------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- 第 2 层:服务 --"
    if (-not $drvProbe.Ok) {
        Write-Fail "第 2 层" ("VBoxDrvInst 未取到输出,驱动层事实同上;服务仍单独列出。")
    }
    $layers = Get-HostOnlyDriverLayers -DrvInstLines $drvProbe.Lines
    foreach ($s in $layers.Layer2.Services) {
        $state = $(if ($s.Present) { $s.Status } else { "不存在" })
        Write-Host ("  [" + $(if ($s.Running) { " OK " } else { " !! " }) + "] " + $s.Name.PadRight(12) + $state)
    }
    if (-not $layers.Layer2.AllRunning) {
        Write-Note "  上面标 !! 的服务没有在运行。VBoxSup 不跑,虚拟机直接起不来。"
    }
    Write-Note "  VBoxDrv(5.2 时代的驱动)不在检查范围内 —— 7.2 上本来就没有它,不是缺陷。"
} catch {
    Write-Fail "第 2 层" $_.Exception.Message
}

# --- 第 3 层:VBox 视图 -----------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- 第 3 层:VBox 视角的接口 (VBoxManage list hostonlyifs) --"
    if (-not $ifsProbe.Ok) {
        Write-Fail "第 3 层" $ifsProbe.Error
    } else {
        $ifs = @(Parse-HostOnlyIfs -Lines $ifsProbe.Lines)
        if ($ifs.Count -eq 0) {
            Write-Note "  一个 host-only 接口都没有 —— 适配器可能根本不存在(见第 1 层)。"
        }
        foreach ($i in $ifs) {
            Write-Host ("  * " + $i.Name)
            Write-Fact "IP" $i.IPAddress 20
            Write-Fact "状态" $i.Status 20
            Write-Fact "VBox 网络名" $i.VBoxNetworkName 20
            $ifNames += $i.Name
        }
    }
} catch {
    Write-Fail "第 3 层" $_.Exception.Message
}

# --- 第 4 层:Windows 视图 --------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- 第 4 层:Windows 视角的网卡 (Get-NetAdapter) --"
    $adapters = @(Get-HostOnlyNetAdapterFacts)
    if ($adapters.Count -eq 0) {
        Write-Note "  没找到 InterfaceDescription 含 \"VirtualBox Host-Only\" 的网卡。"
    }
    foreach ($a in $adapters) {
        Write-Host ("  * " + $a.InterfaceDescription)
        Write-Fact "连接名" $a.InterfaceName 20
        Write-Fact "状态" $a.Status 20
        Write-Fact "IPv4" $a.IPv4 20
    }
    Write-Note "  连接名是本地化的(如「以太网 11」),不可用于匹配;InterfaceDescription 才是稳定键。"
} catch {
    Write-Fail "第 4 层" $_.Exception.Message
}

# --- 第 5 层:NDIS 绑定 -----------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- 第 5 层:NDIS 过滤驱动绑定 (oracle_VBoxNetLwf) --"
    $binds = @(Get-HostOnlyBindingFacts)
    if ($binds.Count -eq 0) {
        Write-Note "  没有可检查的适配器(第 4 层同样为空)。"
    }
    foreach ($b in $binds) {
        Write-Host ("  [" + $(if ($b.Bound -and $b.Enabled) { " OK " } else { " !! " }) + "] " + $b.InterfaceName + "   绑定=" + $b.Bound + "  启用=" + $b.Enabled)
    }
    Write-Note "  该绑定同时挂在物理网卡与全部 Hyper-V vEthernet 上,并非 host-only 专属;"
    Write-Note "  这里只列 host-only 适配器上的那一条。"
} catch {
    Write-Fail "第 5 层" $_.Exception.Message
}

# --- 第 6 层:名字比对 ------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- 第 6 层:模板名 vs 实际接口名 --"
    if (-not $EnspDir) {
        Write-Fail "第 6 层" "未定位到 eNSP 目录,读不了 AR_Base 模板。"
    } else {
        $tplPath = Join-Path $EnspDir "vboxserver\AR_Base\AR_Base.vbox"
        if (-not (Test-Path $tplPath)) {
            Write-Fail "第 6 层" ("找不到模板 " + $tplPath)
        } else {
            $tplNames = @()
            foreach ($line in (Get-Content -Path $tplPath -ErrorAction Stop)) {
                if ($line -match 'HostOnlyInterface\s+name="([^"]*)"') { $tplNames += $Matches[1] }
            }
            Write-Fact "模板中的接口名" $(if ($tplNames.Count) { ($tplNames -join " | ") } else { "(模板里没有 HostOnlyInterface 项)" })

            if ($ifNames.Count -eq 0) {
                Write-Note "  [跳过] 第 3 层没有取到任何接口名,比对结果无意义,不做判定。"
            } elseif ($tplNames.Count -eq 0) {
                Write-Note "  [跳过] 模板里没有主机专用接口名,无从比对。"
            } else {
                # 必须喂 Name,不能喂 VBoxNetworkName —— 后者带
                # "HostInterfaceNetworking-" 前缀,与模板里的名字永远不相等。
                $cmp = Compare-HostOnlyName -VBoxNames $ifNames -TemplateNames $tplNames
                Write-Fact "匹配" ($cmp.MatchedCount.ToString() + " / " + $tplNames.Count)
                if ($cmp.HasMismatch) {
                    Write-Host ("  [ !! ] 模板里有 " + $cmp.MissingInVBox.Count + " 个名字在实际接口中不存在:")
                    foreach ($m in $cmp.MissingInVBox) { Write-Host ("         " + $m) }
                    Write-Note "  这是 \"#2\" 类问题的正确判据。修法是重新注册设备(会重写模板中的名字),"
                    Write-Note "  而不是把 \"#2\" 本身当成故障 —— 名字一致时带后缀也能用。"
                } else {
                    Write-Host "  [ OK ] 模板中的接口名与实际接口一致。"
                }
            }
        }
    }
} catch {
    Write-Fail "第 6 层" $_.Exception.Message
}

# --- DHCP 服务器 ------------------------------------------------------------
# 设计 §10.1 把「host-only 的 DHCP 到底该不该启用」列为【待核实项】:社区资料称
# 5.2 上「启用服务器」应不勾选,而本项目安装器主动创建并启用了它,两者场景不同
# (5.2 与 7.2),从未用实测对齐过。所以这一段只如实呈现状态与作用域,
# 不判对错、不给通过/失败、不写「应该关掉」。
#
# 与接口的对应关系用适配器【真实的 VBoxNetworkName】(DHCP 的 NetworkName 与它
# 是同一种完整形式)。绝不手搓 "HostInterfaceNetworking-..." 字面量:适配器带
# "#N" 后缀时,字面量精确比对必然全不匹配 —— 老 install.ps1 的自检就是这么误报的。
#
# 第 3 层的接口在这里重新解析一次(纯函数,代价为零),而不是去读那一节的局部
# 变量:各节要能独立降级,第 3 层没跑成时这一段仍应给出 DHCP 本身的事实。
try {
    Write-Host ""
    Write-Host "  -- DHCP 服务器 (VBoxManage list dhcpservers) --"
    $dhcpProbe = Invoke-Probe -Exe $vboxManageExe -Arguments @("list", "dhcpservers")

    if (-not $dhcpProbe.Ok) {
        Write-Fail "DHCP 服务器" $dhcpProbe.Error
    } else {
        $dhcpServers = @(Parse-DhcpServers -Lines $dhcpProbe.Lines)
        if ($dhcpServers.Count -eq 0) {
            Write-Note "  没有取到任何 DHCP 服务器 —— VBox 当前没有为 host-only 网段提供 DHCP。"
        } else {
            $ifRecords = @()
            if ($ifsProbe.Ok) { $ifRecords = @(Parse-HostOnlyIfs -Lines $ifsProbe.Lines) }

            foreach ($d in @(Join-DhcpServerToHostOnlyIf -DhcpServers $dhcpServers -HostOnlyIfs $ifRecords)) {
                Write-Host ("  * " + $d.NetworkName)
                Write-Fact "地址池" ($d.LowerIP + " - " + $d.UpperIP) 20
                Write-Fact "掩码" $d.NetworkMask 20
                Write-Fact "服务器地址" $d.DhcpdIP 20
                Write-Fact "启用" $(if ($d.Enabled) { "是" } else { "否" }) 20
                if ($d.IfName) {
                    Write-Fact "对应接口" ($d.IfName + "   (VBox 网络名与之一致)") 20
                } else {
                    Write-Fact "对应接口" "(没有 VBoxNetworkName 与之一致的 host-only 接口)" 20
                }
            }
        }

        # 中立的收尾说明:没有它,读者无从知道上面那行「启用: 是」算不算问题。
        Write-Note "  DHCP 该不该启用,本项目的设计(§10.1)把它列为【未核实】:"
        Write-Note "  社区资料称 host-only 的「启用服务器」应不勾选,而本项目安装器主动创建"
        Write-Note "  并启用了它;两者场景不同(5.2 与 7.2),尚未用实测对齐。"
        Write-Note "  因此上面只报状态,不判定这个状态是对是错。"
    }
} catch {
    Write-Fail "DHCP 服务器" $_.Exception.Message
}

# ===========================================================================
# 第 4 节  eNSP 本体层
#
# 前三节看的是 VirtualBox 侧。这一节换一条轴:设备一直打印 '####' 不进 CLI,
# 除了 VBox 层,还有三个纯 eNSP 本体的成因 —— 性能计数器、防火墙放行、端口冲突。
# 它们的症状一模一样,只能靠逐项探测区分。
# ===========================================================================
Write-Section "[4] eNSP 本体层"
$sectionsOk += "4"

# --- 性能计数器 -------------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- 性能计数器 --"
    $perf = Test-PerfCountersFunctional
    Write-Fact "功能状态" $(if ($perf.Functional) { "正常" } else { "异常" })
    Write-Fact "判定依据" $perf.Reason

    if (-not $perf.Functional) {
        Write-Host ""
        Write-Note "  !! Windows 性能计数器损坏时,设备会一直打印 '####' 而不进入 CLI。"
        Write-Note "     修法(需要管理员权限): lodctr /R"
        Write-Note "     该命令从备份重建计数器注册信息;跑完重开 eNSP 再看。"
    }

    Write-Host ""
    Write-Note "  判定方式说明: 这里是真的去跑了一次计数器,而不是查注册表键"
    Write-Note "  HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\009。"
    Write-Note "  那个键在当前 Windows 上并不存在,照它判断会把每一台健康机器都"
    Write-Note "  报成「计数器损坏」—— 是个只会误报、不会漏报的检查,故不采用。"
} catch {
    Write-Fail "性能计数器" $_.Exception.Message
}

# --- 防火墙放行 -------------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- 防火墙放行规则 --"
    # 取文本再交给纯解析器:解析器按「整块规则」判断,不会被别的规则顶替满足。
    $fwText = @(Get-FirewallRuleTextForEnsp)
    $fw = Parse-FirewallRulesForEnsp -Lines $fwText

    # 规则覆盖哪些配置文件也要报出来。「已启用 + 允许」但只覆盖 Public 的规则,
    # 在加域机器上并不生效 —— 只报 HasAllowRule 会是假绿。
    $fwProfileText = $(if ($fw.Profile) { $fw.Profile } else { "(未读取到)" })
    Write-Fact "eNSP 放行规则" $(if ($fw.HasAllowRule) { "存在(已启用 + 允许), 覆盖配置文件: " + $fwProfileText } else { "未找到" })

    if ($fw.HasAllowRule) {
        Write-Note "  规则 eNSP_VBoxServer 存在,且处于「已启用 + 允许」状态。"
    } else {
        if ($fwText.Count -eq 0) {
            Write-Host ""
            Write-Note "  未取到任何与 eNSP / VBoxServer 相关的规则。这既可能是确实没有,"
            Write-Note "  也可能是当前权限读不到防火墙配置 —— 请用管理员身份重跑本节确认后再下结论。"
        }
        Write-Host ""
        Write-Note "  !! eNSP 官方 FAQ 把这一条列为与性能计数器损坏相同的 '####' 卡死成因。"
        Write-Note "     规则需要在【Domain】和【Public】两个配置文件上都处于启用状态;"
        Write-Note "     只启用其中一个、或规则被禁用/阻止,都不算数。"
        Write-Note "     目标规则名形如 ensp_vboxserver / eNSP_VBoxServer。"
    }
} catch {
    Write-Fail "防火墙" $_.Exception.Message
}

# --- 服务端口 ---------------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- eNSP 服务端口 (54012 / 54013 / 54014) --"
    $requiredPorts = @(54012, 54013, 54014)
    $occupiedPorts = @(Get-EnspServerPortsInUse -RequiredPorts $requiredPorts)
    $portFacts = Parse-PortOccupancy -OccupiedPorts $occupiedPorts -RequiredPorts $requiredPorts

    foreach ($p in $requiredPorts) {
        Write-Host ("  [" + $(if ($occupiedPorts -contains $p) { "占用" } else { "空闲" }) + "] " + $p)
    }

    if ($portFacts.AllFree) {
        Write-Note "  三个端口都没有被占用。"
    } else {
        Write-Host ""
        Write-Note ("  !! 被占用的端口: " + ($portFacts.Conflicts -join ", "))
        Write-Note "     修法: eNSP 菜单 Tools -> Options -> Server,把端口号往上加,"
        Write-Note "     一直加到不再冲突为止,然后重启 eNSP。"
    }
    Write-Host ""
    Write-Note "  注意: eNSP 正在运行时,它本来就该占着这几个端口 ——"
    Write-Note "  判断「冲突」之前先确认 eNSP 没在跑,否则会把自己的进程算成冲突。"
} catch {
    Write-Fail "服务端口" $_.Exception.Message
}

# ===========================================================================
# 第 5 节  网络补充
# ===========================================================================
Write-Section "[5] 网络补充"
$sectionsOk += "5"

# --- 192.168.56.x 归属 ------------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- 192.168.56.x 归属 --"

    # Compare-SubnetOwners 认的是 { Name, IPv4 } 两个字段,而 Get-NetIPAddress
    # 给的是 InterfaceAlias / IPAddress:直接把后者喂进去,每个对象的 .IPv4 都是
    # 空,结果必然是「零个持有者」的假绿。这里显式投影成解析器要的形状。
    $ipv4Facts = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Name = $_.InterfaceAlias; IPv4 = $_.IPAddress }
    })
    $subnetFacts = Compare-SubnetOwners -Interfaces $ipv4Facts -Prefix "192.168.56."

    Write-Fact "持有者数量" $subnetFacts.OwnerCount.ToString()
    foreach ($o in $subnetFacts.Owners) { Write-Host ("         " + $o) }

    if ($subnetFacts.Conflict) {
        Write-Host ""
        Write-Note "  !! 有不止一块网卡持有 192.168.56.x 网段的地址。eNSP 的资源文件把"
        Write-Note "     dest:192.168.56.1 写死在模板里;VPN 或 VMware 的 VMnet 适配器只要"
        Write-Note "     占住同一网段,发往 192.168.56.1 的流量就会被路由到那块网卡上,"
        Write-Note "     设备因而连不上宿主。修法: 改掉或禁用那块多余网卡的地址。"
    } elseif ($subnetFacts.OwnerCount -eq 0) {
        Write-Note "  没有任何网卡持有 192.168.56.x 的地址 —— host-only 适配器可能没配上 IP,"
        Write-Note "  回看第 3 节的第 3 / 第 4 层。"
    } else {
        Write-Note "  只有一块网卡持有该网段,无冲突。"
    }
} catch {
    Write-Fail "192.168.56.x 归属" $_.Exception.Message
}

# --- host-only 网卡属性 -----------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- host-only 网卡属性 --"

    # 只按 Description(即 InterfaceDescription)挑。连接名是本地化的
    # —— 本机报的是「以太网 11」—— 拿它当匹配键在别的语言、别的机器上必然落空。
    $adapterFacts = @(Get-AdapterPropertyFacts)
    $hostOnlyFacts = @($adapterFacts | Where-Object { $_.Description -like "*VirtualBox Host-Only*" })

    if ($hostOnlyFacts.Count -eq 0) {
        Write-Note "  没有 InterfaceDescription 含 'VirtualBox Host-Only' 的网卡(与第 3 节第 4 层一致)。"
    }
    foreach ($a in $hostOnlyFacts) {
        Write-Host ("  * " + $a.Description)
        Write-Fact "连接名" $a.InterfaceName 20
        Write-Fact "NDIS6 绑定" $(if ($a.Ndis6Bound) { "已绑定且启用" } else { "未绑定 / 未启用" }) 20
        Write-Fact "IPv6" $(if ($a.IPv6Enabled) { "启用" } else { "已关闭" }) 20

        if (-not $a.Ndis6Bound) {
            Write-Host ""
            Write-Note "  !! oracle_VBoxNetLwf 未绑定到这块网卡,设备进不了宿主的网络栈 ——"
            Write-Note "     单这一条就足以让设备起不来或连不通。修法见第 3 节第 1 / 第 5 层。"
        }
        if ($a.IPv6Enabled) {
            Write-Note "  这块适配器上 IPv6 处于启用状态。社区流传的做法是把它取消勾选后"
            Write-Note "  设备连通性恢复 —— 属经验做法,不代表本机存在缺陷,仅作记录。"
        }
    }
    Write-Note "  连接名只用于显示:它是本地化的,不能当匹配键。"
} catch {
    Write-Fail "host-only 网卡属性" $_.Exception.Message
}

# ===========================================================================
# 第 6 节  设备包与版本
# ===========================================================================
Write-Section "[6] 设备包与版本"
$sectionsOk += "6"

# --- eNSP 版本 --------------------------------------------------------------
$enspVersion = ""
$enspVersionKnown = $false
try {
    Write-Host ""
    Write-Host "  -- eNSP 版本 --"
    foreach ($root in @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -like "*eNSP*" -and $p.DisplayVersion) { $p.DisplayVersion }
        } | Select-Object -First 1
        if ($hit) { $enspVersion = $hit; break }
    }
    $enspVersionKnown = [bool]$enspVersion
    Write-Fact "eNSP 版本" $(if ($enspVersionKnown) { $enspVersion } else { "unknown" })
} catch {
    Write-Fail "eNSP 版本" $_.Exception.Message
    $enspVersion = ""
    $enspVersionKnown = $false
}

# --- 已装设备包 -------------------------------------------------------------
#
# CE / CX200 的判据取自 installer\README.md 的设备对照表,并已在本机核对:
#   plugin\svrp -> CE6800 / CE12800,镜像落在 Database\CE.img
#   plugin\cx   -> CX200,          镜像落在 Database\CX.img
# 即判据是「该插件 Database\ 下存在它自己的镜像文件」,而不是目录本身存在
# —— 全新安装时这些 Database\ 都是空的。
$ceRel = "plugin\svrp\Database\CE.img"
$cxRel = "plugin\cx\Database\CX.img"
$hasCeDevice = $false
$hasCx200 = $false
try {
    Write-Host ""
    Write-Host "  -- 已装设备包 --"
    if (-not $EnspDir) {
        Write-Note "[跳过] 未定位到 eNSP 目录,无法判断设备包。请用 -EnspDir 指定。"
    } else {
        $cePath = Join-Path $EnspDir $ceRel
        $cxPath = Join-Path $EnspDir $cxRel
        $hasCeDevice = Test-Path $cePath
        $hasCx200 = Test-Path $cxPath
        Write-Host ("  [" + $(if ($hasCeDevice) { "有" } else { "无" }) + "] " + $ceRel + "   (CE6800 / CE12800)")
        Write-Host ("  [" + $(if ($hasCx200) { "有" } else { "无" }) + "] " + $cxRel + "   (CX200)")
        Write-Note "  上面两行就是本次判定所依据的完整路径。"
    }
} catch {
    Write-Fail "已装设备包" $_.Exception.Message
}

# --- 版本 x 设备包 约束 -----------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- 版本 x 设备包 约束 --"
    if (-not $enspVersionKnown) {
        # 版本取不到就不做约束判断。猜一个版本会给出错误的「需要升级」结论,
        # 那比不判断更糟。
        Write-Note "[跳过] eNSP 版本未取到(unknown),不做版本约束判断 —— 不猜。"
    } else {
        $vc = Test-EnspVersionAgainstDevices -EnspVersion $enspVersion -HasCeDevice $hasCeDevice -HasCx200 $hasCx200
        Write-Fact "CE 需更新版本" $(if ($vc.CeNeedsNewer) { "是" } else { "否" })
        Write-Fact "CX200 已被移除" $(if ($vc.Cx200Removed) { "是" } else { "否" })
        Write-Host ""
        Write-Note "  判据: CE / NE / CX 需要 eNSP >= 1.3.00.100 —— 该版本修掉了「第二次启动失败」。"
        Write-Note "        CX200 与 NE5000E 在 1.2.00.500 中已被移除。"

        if ($vc.CeNeedsNewer) {
            Write-Host ""
            Write-Note "  !! 本机装了 CE 设备包,但 eNSP 版本低于 1.3.00.100:CE 会第二次启动失败。"
            Write-Note "     修法: 升级 eNSP 到 1.3.00.100 或更高。"
        }
        if ($vc.Cx200Removed) {
            Write-Host ""
            Write-Note "  说明: 本机 plugin\cx 下留着 CX200 的镜像,而当前 eNSP 版本(>= 1.2.00.500)"
            Write-Note "  已经移除了 CX200 —— 这份多半是旧版安装残留,面板上的 CX200 起不来。"
            Write-Note "  要保留 CX200,需要把 eNSP 退到 1.2.00.390 或更早。"
        }
    }
} catch {
    Write-Fail "版本 x 设备包 约束" $_.Exception.Message
}

# --- AR_Base 模板 VRAMSize --------------------------------------------------
try {
    Write-Host ""
    Write-Host "  -- AR_Base 模板 VRAMSize --"
    if (-not $EnspDir) {
        Write-Note "[跳过] 未定位到 eNSP 目录,读不了 AR_Base 模板。请用 -EnspDir 指定。"
    } else {
        $arBaseVbox = Join-Path $EnspDir "vboxserver\AR_Base\AR_Base.vbox"
        if (-not (Test-Path $arBaseVbox)) {
            Write-Fail "AR_Base 模板" ("找不到 " + $arBaseVbox)
        } else {
            $vram = Get-VramSizeFromTemplate -Lines (Get-Content -Path $arBaseVbox -ErrorAction Stop)
            if ($null -eq $vram) {
                Write-Fact "VRAMSize" ("(模板里没有 VRAMSize 项)   <- " + $arBaseVbox)
            } else {
                # 不论是否告警都必须打印这个值 —— 它正是「只有 AR 坏、交换机和
                # 防火墙都正常」那一类报告唯一能定性的数据。
                Write-Fact "VRAMSize" ($vram.ToString() + " MB   <- " + $arBaseVbox)
                # 先判 $null 再判阈值: $null 传进 [int] 参数会被转成 0,而 0 小于
                # 阈值,不先挡一道就会把「没读到」误报成「太小」。
                if (Test-VramTooSmall -VramSize $vram) {
                    Write-Host ""
                    Write-Note "  !! VRAMSize 低于 9 MB: AR 会起不来,而交换机和防火墙照常 ——"
                    Write-Note "     正是「只有 AR 坏」那一类报告的成因。改回 16 即可。"
                }
            }
            Write-Host ""
            Write-Note "  订正一条流传很广的说法: 「出厂默认 1 MB」出自 VirtualBox 5.0 时代。"
            Write-Note "  eNSP V1.3.00.100 上实测: AR_Base=16、vfw_usg=12、WLAN_AC_Base=16,"
            Write-Note "  没有任何一个模板靠近 1。所以这一项防的是「被改坏」,不是防出厂状态。"
        }
    }
} catch {
    Write-Fail "AR_Base 模板 VRAMSize" $_.Exception.Message
}

# ===========================================================================
# 第 7 节  日志尾部
# ===========================================================================
Write-Section "[7] 日志尾部"
$sectionsOk += "7"

Write-Note "采集范围: 只取下列【当前】文件并截断尾部。同目录下数十个历史 .bak_*"
Write-Note "一律不采 —— 全量打包会把报告撑成几十 MB 的噪音。"
Write-Host ""
Write-Note "VBoxSVC.log 与 eNSP 的 vboxserver\log\VBoxManage.log 是网络层故障的决定性"
Write-Note "证据所在: 例如 VERR_INTNET_FLT_IF_NOT_FOUND 只在后者里出现。"

# 日志源用「访问器函数」返回,而不是 $script: 作用域的数组变量。
# 从函数内部读 $script:Name 会绑定到调用方的作用域、拿到 $null
# (这正是 checks.ps1 顶部注释里记的那个坑),所以这里按参数取 EnspDir 现算。
function Get-DiagLogSources {
    param([string]$EnspDir)
    return @(
        @{ Label = "shim install";    Path = "$env:ProgramData\ensp-vbox-shim\install.log";            Tail = 200 },
        @{ Label = "shim proxy";      Path = "$env:ProgramData\ensp-vbox-shim\vbox52_proxy.log";       Tail = 200 },
        @{ Label = "shim wrapper";    Path = "$env:ProgramData\ensp-vbox-shim\vboxmanage_wrapper.log"; Tail = 200 },
        @{ Label = "VBoxSVC";         Path = "$env:USERPROFILE\.VirtualBox\VBoxSVC.log";               Tail = 300 },
        @{ Label = "eNSP VBoxManage"; Path = $(if ($EnspDir) { Join-Path $EnspDir "vboxserver\log\VBoxManage.log" } else { "" }); Tail = 200 }
    )
}

try {
    foreach ($src in @(Get-DiagLogSources -EnspDir $EnspDir)) {
        Write-Host ""
        Write-Host ("  == " + $src.Label + " ==")
        try {
            if (-not $src.Path) {
                Write-Note "路径未确定(eNSP 目录未定位到,请用 -EnspDir 指定)。"
            } elseif (-not (Test-Path $src.Path)) {
                Write-Note ("不存在: " + $src.Path)
            } else {
                $totalLines = @(Get-Content -Path $src.Path -ErrorAction Stop).Count
                # 拼接必须整体加括号。写成 Write-Note "路径: " + $src.Path 时,
                # PowerShell 只把 "路径: " 绑给 $Text,后面的 + 与值被静默丢掉,
                # 既不报错也不进 catch —— 报告里会剩一个光秃秃的「路径: 」。
                Write-Note ("路径: " + $src.Path)
                Write-Note ("行数: " + $totalLines + "  (下面只列最后 " + $src.Tail + " 行)")
                Write-Host ""
                foreach ($line in @(Get-Content -Path $src.Path -Tail $src.Tail -ErrorAction Stop)) {
                    Write-Host ("    " + $line)
                }
            }
        } catch {
            Write-Fail $src.Label $_.Exception.Message
        }
    }
} catch {
    Write-Fail "日志尾部" $_.Exception.Message
}

# ===========================================================================
# 第 8 节  收尾
# ===========================================================================
Write-Section "[8] 收尾"
$sectionsOk += "8"

Write-Host ""
Write-Host ("  本次诊断到此结束,已产出第 " + ($sectionsOk -join " / ") + " 节。")
if ($script:DiagFailCount -eq 0) {
    Write-Host "  全部没有出现探测失败。"
} else {
    Write-Host ("  全部共有 " + $script:DiagFailCount + " 处探测失败,逐条标在各节里(以 [探测失败] 开头)。")
}
Write-Host ""
Write-Host "  本报告只覆盖上面列出的这些节,不表示环境完全无问题:"
Write-Host "  未覆盖的还有抓包驱动(WinPcap / Npcap),以及安装器自身的校验。"
Write-Host "  报告里没报错,只说明已覆盖的这些项没发现问题。"
Write-Host ""
Write-Host "  本报告全程为只读采集,不含任何交互内容 —— 修复菜单在转录停止之后才运行,"
Write-Host "  它那一段另写一份 <报告名>.repair.txt,不会混进本文件。"
Write-Host ""
Write-Host ("  报告文件: " + $ReportPath)

if ($transcriptOn) {
    try { Stop-Transcript | Out-Null } catch { }
}
# 转录已停。把它记成事实而不是假设:下面的菜单靠这个变量决定能不能读输入 ——
# 交互提示写进报告,报告就不再是「只读采集」,也没法直接附进 issue。
$transcriptOn = $false

# 这一行在 Stop-Transcript 之后,只出现在屏幕上、不进报告 ——
# 文件大小必须等落盘停下才算得出来,放进报告只会是半截数字。
try {
    $reportSize = (Get-Item -Path $ReportPath -ErrorAction Stop).Length
    Write-Host ("  报告大小: " + $reportSize + " 字节 (" + [math]::Round($reportSize / 1KB, 1) + " KB)")
} catch {
    Write-Host ("  [提示] 报告文件大小取不到: " + $_.Exception.Message)
}

# ---------------------------------------------------------------------------
# 修复菜单(报告之后)
#
# -NoMenu 在自动化里用:报告写完就结束,一个键都不读。
# 菜单整段包 try/catch:它是报告之后的附加动作,出错不许影响已经落盘的报告,
# 也不许让调用方(环境检查.bat / 脚本)拿到一个假的失败退出码。
# ---------------------------------------------------------------------------
if (-not $NoMenu) {
    try {
        Invoke-RepairMenuEntry -EnspDir $EnspDir -VBoxDir $VBoxDir -ReportPath $ReportPath -TranscriptActive $transcriptOn
    } catch {
        Write-Host ""
        Write-Host ("[提示] 修复菜单出错,已中止交互(报告已写好,不受影响): " + $_.Exception.Message)
    }
}
