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

# 交互层:控制台能力探测、控制台模式开关与还原、按键/鼠标事件读取、绘制原语。
# 纯机制,不含任何界面文案(文案在本文件里),因此它保持纯 ASCII 无 BOM。
#
# 两个刻意的选择:
#   1. 只在本次真的可能进菜单时加载。tui.ps1 顶层要 Add-Type 编译一段 C#(实测
#      ~800ms);-NoMenu 是自动化用的路径,不该为一份用不上的交互层付费,也就更
#      不可能碰到控制台模式。
#   2. dot-source 留在脚本作用域,不能挪进函数。tui.ps1 顶层有变量赋值
#      ($TuiInteropReady / $TuiSavedMode ...),dot-source 进函数会落到那个函数的
#      局部作用域,而它内部一律用 $script: 记号读写这几个变量 —— 两者对不上,
#      模式还原就会失效。缺文件只降级:菜单按函数在不在自行判断。
$TuiPath = Join-Path $ScriptDir "tui.ps1"
if ((-not $NoMenu) -and (Test-Path $TuiPath)) { . $TuiPath }

# 全部共用的两个记账变量:
#   $script:DiagFailCount —— 失败的探测数,由 Write-Fail 累加(见该函数处的说明)。
#      是全部的标量计数,读写在脚本作用域内完成,不涉及数组跨作用域绑定。
#   $sectionsOk           —— 实际产出内容的节号。只在顶层追加与读取,不跨函数。
$script:DiagFailCount = 0
$sectionsOk = @()

# ---------------------------------------------------------------------------
# 展示辅助
# ---------------------------------------------------------------------------

# 单个字符的显示宽度。中文/全角区段算 2 列,其余算 1 列。
# 只覆盖 CJK / 全角区段,足够本项目的中文标签使用。
# 单独成函数是因为折行也要按列数算:补位和折行用同一张表,两边的「宽度」才一致。
function Get-CharDisplayWidth {
    param([char]$Char)
    $c = [int]$Char
    if (($c -ge 0x1100 -and $c -le 0x115F) -or
        ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
        ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
        ($c -ge 0xF900 -and $c -le 0xFAFF) -or
        ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
        ($c -ge 0xFF00 -and $c -le 0xFF60) -or
        ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { return 2 }
    return 1
}

# 中文是双宽字符,PowerShell 的 "{0,-16}" 按字符数补齐会错位,这里按显示宽度补。
function Get-DisplayWidth {
    param([string]$Text)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) { $w += (Get-CharDisplayWidth -Char $ch) }
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
#
# 两条输入路径,判据是「有没有可交互的控制台」(设计 §9):
#   TUI  —— Test-TuiConsoleAvailable 为真且能绘制时走这条:方向键 / Enter / 数字键 /
#           A / Esc / 鼠标点击,全部可用;面板原地重画。
#   逐行 —— 其余情况(标准输入被重定向、远程控制台取不到控制台模式、控制台画不出来)
#           走这条:按提示逐行输入编号,不启用鼠标、不改控制台模式。
#           走到这条必须明说「只能用键盘」—— 默默吃掉点击会让用户以为程序坏了。
# 两条路解析出来的是同一份「编号列表」,执行那一段只有一份实现。
# ===========================================================================

# ---------------------------------------------------------------------------
# 输入:读不到就退出,不死等
#
# 下面两个函数只服务降级的那条路(非可交互控制台)。TUI 那条路完全不经过它们 ——
# 那一边的按键与鼠标由 tui.ps1 的事件通道读。
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

    # --- host-only 绑定失效(D1)----------------------------------------------
    #
    # 触发判据是【日志里的 VERR_INTNET_FLT_IF_NOT_FOUND】,不是绑定状态。
    #
    # 设计 §6.1 写明了 D1 的特征恰恰是「适配器存在且 Up、绑定项 Enabled=True」——
    # 失效的只是它背后的数据路径,绑定状态读出来是好的。所以拿绑定状态去判 D1
    # 永远判不出来,真正的证据只在日志里。这一条只有在日志解析接进来之后才成立,
    # 在此之前 fix.ps1 里那个 Repair-BounceAdapter 根本没人调用。
    #
    # 绑定确实显示为未启用的情形也一并收进来:那是另一条坏法,修法完全相同,
    # 分成两项只会让用户在两个几乎一样的条目之间做无意义的选择。
    try {
        $d1Why = @()
        $vbHomeD = $env:VBOX_USER_HOME
        if (-not $vbHomeD) { $vbHomeD = Join-Path $env:USERPROFILE ".VirtualBox" }
        $d1Logs = @()
        $d1VboxLog = Find-NewestVmLog -FileName "VBox.log" -VBoxUserHome $vbHomeD -EnspDir $EnspDir
        if ($d1VboxLog) { $d1Logs += $d1VboxLog }
        if ($EnspDir) {
            $d1MgmtLog = Join-Path $EnspDir "vboxserver\log\VBoxManage.log"
            if (Test-Path $d1MgmtLog) { $d1Logs += $d1MgmtLog }
        }
        foreach ($lp in $d1Logs) {
            $mk = @(Find-VBoxLogMarkers -Lines @(Get-Content -Path $lp -ErrorAction SilentlyContinue) |
                    Where-Object { $_.Id -eq "intnet" })
            if ($mk.Count -gt 0) {
                $d1Why += ("最近一次启动的日志(" + (Split-Path $lp -Leaf) + ")里出现 VERR_INTNET_FLT_IF_NOT_FOUND")
                break
            }
        }
        foreach ($bnd in @(Get-HostOnlyBindingFacts)) {
            if ((-not $bnd.Bound) -or (-not $bnd.Enabled)) {
                $d1Why += ("适配器 " + $bnd.InterfaceName + " 上的 oracle_VBoxNetLwf 未绑定或未启用")
            }
        }

        if ($d1Why.Count -gt 0) {
            $items += [pscustomobject]@{
                Id       = "hostonly-bind"
                Tier     = "confirm"
                TierLabel = "<有损,执行前单独确认>"
                Title    = "host-only 网络绑定失效"
                Symptom  = "设备起不来,或起来后连不通宿主(startvm 报 VERR_INTNET_FLT_IF_NOT_FOUND)"
                Evidence = ($d1Why -join "; ")
                Impact   = @(
                    "修复动作是【禁用再启用一次 host-only 网卡】,让过滤驱动重新进入数据路径 ——"
                    "本机网络会短暂中断(数秒)。"
                    "正在运行的设备、Tailscale / WireGuard 之类的常连隧道、"
                    "Hyper-V 虚拟交换机都会闪断。"
                    "这一项【不重装驱动包、也不重建接口】,只做重绑;驱动缺失的情形在上一项。"
                )
                Steps    = @( [pscustomobject]@{ Fn = "Repair-BounceAdapter"; Args = @{} } )
                Manual   = @()
            }
        }
    } catch { }

    # --- 基础 VM 注册 / _Link 快照 -------------------------------------------
    #
    # 判据与报告第 6 节共用 Get-BaseVmFactSheet 的同一份事实,不会出现
    # 「报告说要修、菜单说没问题」这种两处结论打架的情况。
    try {
        if ($EnspDir) {
            $vmSheet = Get-BaseVmFactSheet -EnspDir $EnspDir -VBoxManage $vboxManage
            $vmBad = @($vmSheet.Facts | Where-Object {
                $_.DirPresent -and ((-not $_.Registered) -or (-not $_.PathValid) -or (-not $_.LinkSnapshot))
            })
            if ($vmBad.Count -gt 0) {
                $items += [pscustomobject]@{
                    Id        = "basemvms"
                    Tier      = "confirm"
                    TierLabel = "<须用启动 eNSP 的账户>"
                    Title     = "基础设备 VM 未注册 / 缺 _Link 快照"
                    Symptom   = "设备一拉就报 40,而垫片日志里看不出任何异常"
                    Evidence  = ("待处理: " + (@($vmBad | ForEach-Object { $_.Name }) -join ", "))
                    Impact    = @(
                        "按需重注册,并给缺快照的基础盘补建 <VM>_Link —— 就是 注册设备.bat 做的事。"
                        "注销不带 --delete,磁盘文件与已有快照都不动;补快照只补【缺失】的那些。"
                        "补快照要求 VM 没有内存镜像(poweroff / aborted 满足,running 不满足)。"
                        "【必须用平时启动 eNSP 的那个账户运行】—— 注册写的是当前账户的"
                        "%USERPROFILE%\.VirtualBox\VirtualBox.xml,换了账户会写进另一个人的配置,eNSP 看不到。"
                    )
                    Steps     = @( [pscustomobject]@{ Fn = "Repair-RegisterBaseVms"; Args = @{ VBoxDir = $vboxDirFound; EnspDir = $EnspDir } } )
                    Manual    = @()
                }
            }
        }
    } catch { }

    # --- eNSP 关闭后残留的 VirtualBox 进程 -----------------------------------
    #
    # 只在【eNSP 已关】且【确有属于 eNSP 的 VM 还在跑】时才提供。用户自己从
    # VirtualBox GUI 起的 VM 不算 —— 那条线由 Get-EnspOrphanFacts 划,与
    # cleanup_orphans.ps1 是同一条。
    try {
        $orphan = Get-EnspOrphanFacts -EnspDir $EnspDir -VBoxManage $vboxManage
        $enspOwnedRunning = @($orphan.Owned | Where-Object { $_.EnspOwned })
        if ((-not $orphan.Proc.EnspRunning) -and ($enspOwnedRunning.Count -gt 0)) {
            $items += [pscustomobject]@{
                Id       = "orphans"
                Tier     = "confirm"
                TierLabel = "<有损,执行前单独确认>"
                Title    = "eNSP 关闭后残留的 VirtualBox 进程"
                Symptom  = "内存不释放;设备图标显示异常退出,可能弹出应用程序错误框"
                Evidence = ("eNSP 未运行,但仍有 " + $orphan.Proc.HeadlessCount + " 个 VBoxHeadless;" +
                            "其中属于 eNSP 的 VM: " + (@($enspOwnedRunning | ForEach-Object { $_.Name }) -join ", "))
                Impact   = @(
                    "会强制结束这些进程。CE / CX / NE 的客户机是 Linux,硬断电收尾本来就慢,"
                    "强杀时它们未保存的状态会丢 —— 那些设备此时本来也已经不可用了。"
                    "【不属于 eNSP 的 VM 一律不动】,清单以本项列出的为准。"
                    "不着急的话也可以什么都不做:它们退完后内存会正常归还,不是泄漏。"
                )
                Steps    = @( [pscustomobject]@{ Fn = "Repair-KillOrphans"; Args = @{} } )
                Manual   = @()
            }
        }
    } catch { }

    # --- AR 模板显存被改小 ---------------------------------------------------
    #
    # 与报告第 6 节读的是同一个函数、同一段(实况 <Hardware>)。挂 confirm 档
    # 是因为它会写 eNSP 安装目录下的文件,标签据此写成"会改写模板"而不是"有损"。
    try {
        if ($EnspDir) {
            $arTpl = Join-Path (Join-Path $EnspDir "vboxserver\AR_Base") "AR_Base.vbox"
            if (Test-Path $arTpl) {
                $arVram = Get-VramSizeFromTemplate -Lines @(Get-Content -Path $arTpl -ErrorAction SilentlyContinue)
                if (Test-VramTooSmall -VramSize $arVram) {
                    $items += [pscustomobject]@{
                        Id        = "vram"
                        Tier      = "confirm"
                        TierLabel = "<会改写 eNSP 模板>"
                        Title     = "AR 模板显存被改小"
                        Symptom   = "只有 AR 起不来,交换机和防火墙都正常"
                        Evidence  = ("AR_Base.vbox 的 Display VRAMSize = " + $arVram + " MB,低于 9")
                        Impact    = @(
                            "把 " + $arTpl + " 里的 VRAMSize 改回 16(eNSP 出厂的实测值)。"
                            "改之前先备份为 AR_Base.vbox.vrambak;该备份已存在时不覆盖,"
                            "以免把更早的那一份冲掉。"
                            "只改【实况】那一段,快照里的副本一个字都不动。"
                        )
                        Steps     = @( [pscustomobject]@{ Fn = "Repair-SetTemplateVram"; Args = @{ TemplatePath = $arTpl; VramSize = 16 } } )
                        Manual    = @()
                    }
                }
            }
        }
    } catch { }

    return $items
}

# ---------------------------------------------------------------------------
# 菜单:行模型与渲染(纯函数)
#
# 渲染刻意做成纯函数 —— 输入是「行数组 + 当前选中项」,输出是「整块面板文本」。
# 两个好处:布局可以脱离终端核对(没有控制台也能把它打印出来看对不对),
# 以及「画出来的行」与「鼠标点得到的行」读的是同一份行数据,两者不可能对不上。
#
# 边框一律用 ASCII 的 + - |。设计 §9 已记下:制表符依赖 TrueType 字体,
# 不保证所有机器都有。菜单在任何字体下都不该显示成乱码。
# ---------------------------------------------------------------------------

# 面板宽度:控制台宽度留出边距,并夹在 44..78。
# 太窄会把中文说明折成碎句;太宽在 80 列控制台上会贴着最后一格写,
# 而在屏幕底部写最后一格会触发滚动,把面板顶走。
function Get-RepairMenuWidth {
    param([int]$ConsoleWidth = 80)
    $w = $ConsoleWidth - 6
    if ($w -lt 44) { $w = 44 }
    if ($w -gt 78) { $w = 78 }
    return $w
}

# 按显示宽度折行。返回字符串数组(至少一行)。-Hang 是续行前缀。
# 折行上限逐行收窄:续行多了一个前缀,内容部分就得相应地少占几列,
# 否则补位之后总宽会超出去,右边框会被顶歪。
function Split-DisplayText {
    param([string]$Text = "", [int]$Width = 74, [string]$Hang = "")

    if ($Width -lt 4) { $Width = 4 }
    $hangW = 0
    if ($Hang) { $hangW = Get-DisplayWidth $Hang }
    if ($hangW -ge ($Width - 2)) { $Hang = ""; $hangW = 0 }

    $out = @()
    $cur = ""
    $curW = 0
    $prefix = ""
    $limit = $Width

    foreach ($ch in ("$Text").ToCharArray()) {
        $cw = Get-CharDisplayWidth -Char $ch
        if ((($curW + $cw) -gt $limit) -and ($curW -gt 0)) {
            $out += ($prefix + $cur)
            $prefix = $Hang
            $limit = $Width - $hangW
            $cur = ""
            $curW = 0
        }
        $cur += $ch
        $curW += $cw
    }
    $out += ($prefix + $cur)
    return @($out)
}

# 把右栏贴到左栏同一行的右端。贴不下就并成一行交给折行 ——
# 宁可折行也不能把右栏截掉:档位标记正是用户判断「这一项会不会断网」的依据。
function Join-MenuColumns {
    param([string]$Left = "", [string]$Right = "", [int]$Width = 74)
    if (-not $Right) { return $Left }
    $gap = $Width - (Get-DisplayWidth $Left) - (Get-DisplayWidth $Right)
    if ($gap -ge 2) { return ($Left + (" " * $gap) + $Right) }
    return ($Left + "  " + $Right)
}

# 面板的一行。Kind 决定它能不能被选中、要不要画选中标记:
#   text / gap —— 说明与留白,不参与选择
#   item       —— 条目标题行;Index 是它在可修项里的 0 基下标,选中的那行画 "> "
#   note       —— 条目续行(症状、依据);Index 与它的标题相同,点它也算选中同一项
# 命中测试只看 Index 是否为 -1,所以以后新增行类型不会漏掉鼠标。
function New-MenuRow {
    param([string]$Kind = "text", [string]$Text = "", [int]$Index = -1)
    return [pscustomobject]@{ Kind = $Kind; Text = $Text; Index = $Index }
}

# 条目行文本。空串是合法的(那一项没有对应内容),不打印。
function Get-RepairMenuRows {
    param([object[]]$Fixable = @(), [int]$Width = 74, [bool]$Mouse = $false)

    $inner = $Width - 4
    $rows = @()

    for ($i = 0; $i -lt $Fixable.Count; $i++) {
        $it = $Fixable[$i]
        # 档位标签默认由档位推出来,但允许条目自带一个更准确的说法。
        # Tier 决定的是【机制】(要不要第二次确认),标签说明的是【代价】——
        # 两者在新增的几项上不再重合:VM 注册要动的是"用哪个账户跑",
        # 改模板要动的是"会写 eNSP 的文件",都不是"有损"。继续套用
        # 「有损」会让人为一件不疼的事多担一次心,而让人误判代价与让人误判
        # 风险一样糟。
        $tierText = "<无损>"
        if ($it.Tier -eq "confirm") { $tierText = "<有损,执行前单独确认>" }
        if ($it.TierLabel) { $tierText = $it.TierLabel }

        $head = ("  [" + ($i + 1) + "] " + $it.Title)
        $rows += New-MenuRow -Kind "item" -Index $i -Text (Join-MenuColumns -Left $head -Right $tierText -Width $inner)

        foreach ($l in @(Split-DisplayText -Text ("  症状: " + $it.Symptom) -Width $inner -Hang "        ")) {
            $rows += New-MenuRow -Kind "note" -Index $i -Text $l
        }
        foreach ($l in @(Split-DisplayText -Text ("  依据: " + $it.Evidence) -Width $inner -Hang "        ")) {
            $rows += New-MenuRow -Kind "note" -Index $i -Text $l
        }
    }

    # 操作提示固定成两行。挤在一行时会在任意位置折行(中文没有词边界,
    # 折出来的半截词比换行更难看),而两行既放得下也不随控制台宽度变形。
    $rows += New-MenuRow -Kind "gap"
    $rows += New-MenuRow -Kind "text" -Text "  方向键 移动   Enter 执行   数字键 直选   A 全选   Esc / 0 退出"
    if ($Mouse) {
        $rows += New-MenuRow -Kind "text" -Text "  鼠标: 左键点击选择,滚轮上下移动"
    }
    return $rows
}

# 行 → 面板文本。每行的显示宽度都补齐到 inner,右边框因此一定对齐。
# 选中项那一行的行首两个空格被换成 "> ",两者同宽,不会把右边框挤歪。
#
# 返回「一行一个对象」而不是纯字符串:@Index 是这一行对应的条目下标(供鼠标命中
# 测试),@Sel 表示这一行属于当前选中项(供反显)。画出来的行与点得到的行
# 因此是同一份数据算出来的,不存在两套坐标。
function Format-RepairMenuPanel {
    param([object[]]$Rows = @(), [int]$Selected = 0, [int]$Width = 74)

    $inner = $Width - 4
    if ($inner -lt 8) { $inner = 8 }

    $border = "+" + ("-" * ($Width - 2)) + "+"
    $out = @([pscustomobject]@{ Text = $border; Index = -1; Sel = $false })

    foreach ($r in $Rows) {
        $firstLine = $true
        foreach ($l in @(Split-DisplayText -Text $r.Text -Width $inner -Hang "  ")) {
            $t = $l
            $sel = $false
            if ($firstLine -and ($r.Kind -eq "item") -and ($r.Index -eq $Selected)) {
                if ($t.Length -ge 2) { $t = "> " + $t.Substring(2) } else { $t = "> " }
                $sel = $true
            }
            $firstLine = $false
            $pad = $inner - (Get-DisplayWidth $t)
            if ($pad -lt 0) { $pad = 0 }
            $out += [pscustomobject]@{ Text = ("| " + $t + (" " * $pad) + " |"); Index = [int]$r.Index; Sel = $sel }
        }
    }

    $out += [pscustomobject]@{ Text = $border; Index = -1; Sel = $false }
    return $out
}

# 把面板画到 (X, Y)。选中行反显 —— 前景背景互换,不写死颜色,
# 深色与浅色两种控制台主题下对比度都成立。
function Write-RepairMenuPanel {
    param([object[]]$Lines = @(), [int]$X = 0, [int]$Y = 0)

    if ($Lines.Count -eq 0) { return $false }

    $revFg = [ConsoleColor]::Black
    $revBg = [ConsoleColor]::Gray
    try {
        $revFg = [Console]::BackgroundColor
        $revBg = [Console]::ForegroundColor
    } catch { }

    $any = $false
    for ($k = 0; $k -lt $Lines.Count; $k++) {
        $wargs = @{ X = $X; Y = ($Y + $k); Text = [string]$Lines[$k].Text }
        if ($Lines[$k].Sel) {
            $wargs["Color"] = $revFg
            $wargs["BackColor"] = $revBg
        }
        if (Write-TuiAt @wargs) { $any = $true }
    }
    return $any
}

# 面板要占的屏幕区域先占好,再取原点。
#
# 不能直接拿当前光标当原点:剩余高度不够时,绘制本身会把屏幕顶上去,
# 而我们记下的原点还停在原处,之后每一次重画都会画错地方。
# 先写 need 个空行,光标就确定前进了 need 行(该滚就滚);此时「光标上方 need-1 行」
# 就是这块面板的第一行 —— 滚了多少都不影响这个关系。
# 面板高度在一轮菜单里是常数,所以原点算一次就够。
function Reserve-RepairMenuArea {
    param([int]$Need = 0, [int]$X = 2)

    if ($Need -lt 1) { return $null }
    for ($k = 0; $k -lt $Need; $k++) { Write-Host "" }

    $y = 0
    try { $y = [int][Console]::CursorTop - ($Need - 1) } catch { $y = 0 }
    if ($y -lt 0) { $y = 0 }
    return [pscustomobject]@{ X = $X; Y = $y; Height = $Need }
}

# ---------------------------------------------------------------------------
# 菜单:选择
# ---------------------------------------------------------------------------

# TUI 路径取一次选择。一次调用只取一个决定 ——
# 取到就返回,执行输出会把屏幕往下推、旧原点随即失效,所以每次执行之后
# 重新占一块新区域,比追踪滚动量可靠得多。
#
# 返回 @{ Action; Indices },Action 取值:
#   "select"  Indices 是选中项的 1 基编号(与用户看到的编号一致)
#   "cancel"  Esc / 0
#   "eof"     控制台不可用、控制台消失、或读输入出错
function Read-RepairChoiceTui {
    param([object[]]$Fixable = @(), [bool]$Mouse = $false)

    $size = $null
    try { $size = Get-TuiSize } catch { $size = $null }
    if ((-not $size) -or (-not $size.Ok)) { return @{ Action = "eof"; Indices = @() } }

    $width = Get-RepairMenuWidth -ConsoleWidth $size.Width
    $rows  = @(Get-RepairMenuRows -Fixable $Fixable -Width $width -Mouse $Mouse)
    $panel = @(Format-RepairMenuPanel -Rows $rows -Selected 0 -Width $width)

    $origin = Reserve-RepairMenuArea -Need $panel.Count -X 2
    if (-not $origin) { return @{ Action = "eof"; Indices = @() } }

    # 命中表按行号索引,与画出来的行一一对应。
    $indexMap = @($panel | ForEach-Object { [int]$_.Index })

    $draw = {
        param($sel)
        $p = @(Format-RepairMenuPanel -Rows $rows -Selected $sel -Width $width)
        [void](Write-RepairMenuPanel -Lines $p -X $origin.X -Y $origin.Y)
    }.GetNewClosure()

    $hitTest = {
        param($mx, $my)
        $r = $my - $origin.Y
        if ($r -lt 0 -or $r -ge $indexMap.Count) { return -1 }
        if ($mx -lt $origin.X) { return -1 }
        if ($mx -ge ($origin.X + $width)) { return -1 }
        return [int]$indexMap[$r]
    }.GetNewClosure()

    while ($true) {
        $res = $null
        try {
            $res = Read-TuiChoice -ItemCount $Fixable.Count -RenderScript $draw `
                     -MouseHitTest $hitTest -KeyMap @{ "A" = "all" }
        } catch {
            return @{ Action = "eof"; Indices = @() }
        }

        $action = [string]$res.Action
        if ($action -eq "select") { return @{ Action = "select"; Indices = @([int]$res.Index + 1) } }
        if ($action -eq "all") {
            $all = @()
            for ($i = 1; $i -le $Fixable.Count; $i++) { $all += $i }
            return @{ Action = "select"; Indices = $all }
        }
        if ($action -eq "cancel")  { return @{ Action = "cancel"; Indices = @() } }
        if ($action -eq "eof")     { return @{ Action = "eof"; Indices = @() } }
        if ($action -eq "timeout") { return @{ Action = "cancel"; Indices = @() } }
        # 其余是未映射的可打印字符:不理它,重新等一次。
        # 重进 Read-TuiChoice 会让面板原地重画一遍,内容不变,看不出来。
    }
}

# 逐行路径取一次选择。编号的解析仍走 ConvertTo-MenuSelection(纯函数,
# 逗号分隔 / A / 0 / 范围判断都在那里),这里只负责把一行文本拿回来。
# 这一条路才是自动化真正会走的那条(标准输入被重定向),必须和以前一样:
# 读到输入结束就干净退出,绝不在无人应答的终端上死等。
function Read-RepairChoiceLine {
    param(
        [object[]]$Fixable = @(),
        [bool]$InputRedirected = $false,
        [int]$InputTimeoutMs = 15000,
        [object]$StdinReader = $null
    )

    Write-Host "  输入编号修复(多项用逗号分隔,如 1,3);[A] 全部;[0] 退出:"
    Write-Host -NoNewline "  > "
    $text = Read-MenuLine -Redirected $InputRedirected -TimeoutMs $InputTimeoutMs -Reader $StdinReader
    # 提示行是用 -NoNewline 写的,回车由终端回显补上;重定向时没有回显,
    # 自己把这一行收尾,否则后续输出会黏在 "> " 后面。
    if ($null -eq $text -or $InputRedirected) { Write-Host "" }
    if ($null -eq $text) { return @{ Action = "eof"; Indices = @() } }

    $sel = ConvertTo-MenuSelection -Text $text -Max $Fixable.Count
    if ($sel.Quit) { return @{ Action = "cancel"; Indices = @() } }
    if (-not $sel.Ok) {
        Write-Note ("无效输入「" + $text.Trim() + "」(" + $sel.Reason + ")。")
        Write-Note ("请输入 1 到 " + $Fixable.Count + " 之间的编号、逗号分隔的多个编号、A 或 0。")
        return @{ Action = "invalid"; Indices = @() }
    }

    if ($sel.All) {
        $all = @()
        for ($i = 1; $i -le $Fixable.Count; $i++) { $all += $i }
        return @{ Action = "select"; Indices = $all }
    }
    return @{ Action = "select"; Indices = @($sel.Indices) }
}

# 第二档的独立确认。返回 $true 才执行。
#
# 「独立」是设计要求(§7.1):它与选中那一项必须是两次输入。选中是 Enter 或点击,
# 而这里只有真的按下 Y 才算确认 —— 回车、Esc、鼠标、其它任何键一律跳过。
# 默认落在「跳过」上,误按的代价因此是「这次没修」,而不是「网断了」。
function Read-RepairConfirm {
    param(
        [object]$Item = $null,
        [bool]$Tui = $false,
        [bool]$InputRedirected = $false,
        [int]$InputTimeoutMs = 15000,
        [object]$StdinReader = $null
    )

    Write-Host ""
    # 这里以前写死「属于有损但必需」。档位标签与档位解耦之后那句话就不准了 ——
    # 重注册基础 VM、改模板显存都要单独确认,却都不是"有损"。把条目自己的标签
    # 嵌进来,让这一次确认与菜单上看到的那一行说的是同一件事。
    $tierHint = $(if ($Item.TierLabel) { $Item.TierLabel } else { "<有损,执行前单独确认>" })
    Write-Note ("!! 这一项需要单独确认 " + $tierHint + " —— 执行前请先看清影响:")
    foreach ($line in $Item.Impact) { Write-Note ("   " + $line) }
    Write-Host ""

    if (-not $Tui) {
        # 降级路径沿用原来的问法(输入 YES),不为了统一而引入第二种约定。
        Write-Host -NoNewline "  确认执行?输入 YES 继续,其他任何输入都跳过这一项: "
        $ans = Read-MenuLine -Redirected $InputRedirected -TimeoutMs $InputTimeoutMs -Reader $StdinReader
        if ($null -eq $ans -or $InputRedirected) { Write-Host "" }
        if ($null -eq $ans) {
            Write-Note "输入结束,跳过这一项。"
            return $false
        }
        if ($ans.Trim() -ne "YES") {
            Write-Note "未确认(输入不是 YES),已跳过这一项。"
            return $false
        }
        return $true
    }

    Write-Host -NoNewline "  确认执行?[Y] 执行 / 其他任意键跳过: "
    $ev = $null
    try { $ev = Read-TuiEvent } catch { $ev = @{ Kind = "eof" } }
    Write-Host ""
    # 决定已经拿到,把队列里剩下的按键丢掉:否则下一次选择会被上一次
    # 多按的键替用户作答。
    [void](Clear-TuiInput)

    if ((-not $ev) -or ([string]$ev.Kind -eq "eof")) {
        Write-Note "输入结束,跳过这一项。"
        return $false
    }
    if (([string]$ev.Kind -eq "key") -and (([string]$ev.Char -eq "Y") -or ([string]$ev.Char -eq "y"))) {
        return $true
    }
    Write-Note "未确认(没有按 Y),已跳过这一项。"
    return $false
}

# ---------------------------------------------------------------------------
# 菜单:执行
# ---------------------------------------------------------------------------

# 执行一批选中项。$Indices 是 1 基编号(与用户看到的编号一致),这里换算成下标。
# 两条输入路径共用这一段:选择是怎么来的与执行无关,修复的行为必须一致。
function Invoke-RepairSelection {
    param(
        [object[]]$Fixable = @(),
        [int[]]$Indices = @(),
        [bool]$Tui = $false,
        [bool]$InputRedirected = $false,
        [int]$InputTimeoutMs = 15000,
        [object]$StdinReader = $null
    )

    # 设计 §7 的前置校验,不可省:修复前必须确认 eNSP 已关闭。
    # 未通过时只把命令列出来,一步都不执行。
    $pre = $null
    try { $pre = Test-RepairPreconditions } catch { $pre = $null }

    foreach ($idx in @($Indices)) {
        if ($idx -lt 1 -or $idx -gt $Fixable.Count) { continue }
        $it = $Fixable[$idx - 1]
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
            $ok = $false
            try {
                $ok = [bool](Read-RepairConfirm -Item $it -Tui $Tui -InputRedirected $InputRedirected `
                            -InputTimeoutMs $InputTimeoutMs -StdinReader $StdinReader)
            } catch {
                $ok = $false
            }
            if (-not $ok) { continue }
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

    # 第三档永远只打印。它不占编号,也不进选择与命中测试的范围 ——
    # 这一段里没有它的修复入口,措辞保持「不修复、也不建议关闭」不变。
    # 刻意排在面板之前:面板是原地重画的,它下面不能再追加滚动输出,
    # 否则面板原点就废了(原点由 Reserve-RepairMenuArea 在画之前定下)。
    if ($manual.Count -gt 0) {
        Write-Host ""
        Write-Host "  以下项本菜单不提供修复入口(第三档:有损且非必需,只报原因与手动步骤):"
        Write-Host ""
        foreach ($it in $manual) {
            Write-Host ("  * " + $it.Title)
            foreach ($line in $it.Manual) { Write-Note $line }
            Write-Host ""
        }
    }

    if ($fixable.Count -eq 0) {
        Write-Host ""
        Write-Note "没有发现可由本工具自动修复的问题。"
        Write-Note "三项可修项(host-only 驱动 / 性能计数器 / 防火墙放行)本次都已满足,"
        Write-Note "或者根本没被判定为问题 —— 菜单不列空操作,本次也不改动任何系统设置。"
        return
    }

    Write-Host ""
    Write-Host ("  发现 " + $fixable.Count + " 个可由本工具修复的问题:")

    # ---------------- 能力探测:决定走 TUI 还是逐行 ----------------
    # 探测本身不改任何东西;Enter-TuiMode 只在探测通过之后才调用,
    # 所以「控制台不可用」这条路上一个控制台模式位都不会被碰。
    $tuiOk = $false
    if (Get-Command Test-TuiConsoleAvailable -ErrorAction SilentlyContinue) {
        try { $tuiOk = [bool](Test-TuiConsoleAvailable) } catch { $tuiOk = $false }
    }
    if ($tuiOk) {
        $size = $null
        try { $size = Get-TuiSize } catch { $size = $null }
        if ((-not $size) -or (-not $size.Ok)) { $tuiOk = $false }
    }

    # 降级必须是显式的(设计 §9):探测失败要说出来,不能默默吃掉点击 ——
    # 否则用户会以为程序坏了,而不是知道自己在纯键盘模式下。
    if (-not $tuiOk) {
        if (-not (Get-Command Test-TuiConsoleAvailable -ErrorAction SilentlyContinue)) {
            # 整合包里缺 tui.ps1。单说出来,否则会被当成「这台机器控制台不行」。
            Write-Note "[提示] 未加载 tui.ps1(交互层),菜单只能用键盘操作(逐行输入编号)。"
            Write-Note "       整合包不完整时重新解压即可;只读诊断与下面的修复都不受影响。"
        } else {
            Write-Note "[提示] 当前不是可交互控制台(标准输入被重定向,或控制台能力不可用):"
            Write-Note "       鼠标不可用,菜单只能用键盘操作 —— 这里按「逐行输入编号」接收选择。"
            Write-Note "       读到输入结束即退出菜单,不会在这里等。"
        }

        # 逐行路径【必须把条目自己打出来】。
        #
        # TUI 那条路由渲染层画行;这里以前只说了「发现 N 个」就直奔提示符 ——
        # 用户看得到编号、看不到编号对应什么,只能靠猜。菜单不列空操作是设计,
        # 但列了又不显示等于没列,而且这一条恰恰是自动化与远程会话唯一会走的路。
        #
        # 复用同一份行模型,不另写一套渲染:两套迟早会说不一样的话。只取
        # item / note 两类 —— 那条「方向键 / 鼠标」的操作提示在这一路不成立。
        Write-Host ""
        try {
            $fbWidth = 74
            try {
                $cw = [Console]::WindowWidth
                if ($cw -gt 0) { $fbWidth = [Math]::Max(50, [Math]::Min(100, $cw - 4)) }
            } catch { }
            foreach ($row in @(Get-RepairMenuRows -Fixable $fixable -Width $fbWidth -Mouse $false)) {
                $k = [string]$row.Kind
                if (($k -eq "item") -or ($k -eq "note")) { Write-Host ("  " + $row.Text) }
            }
        } catch {
            # 渲染本身出错也不能让菜单卡死:退回只列标题,至少编号还能用。
            for ($fi = 0; $fi -lt $fixable.Count; $fi++) {
                Write-Host ("  [" + ($fi + 1) + "] " + $fixable[$fi].Title)
            }
        }
        Write-Host ""
    } else {
        Write-Note "       方向键移动,Enter 执行,数字键直选,A 全选,Esc 退出。"
    }

    # ---------------- 选择与执行 ----------------
    $mouseOn = $false
    try {
        if ($tuiOk) {
            try { $mouseOn = [bool](Enter-TuiMode) } catch { $mouseOn = $false }
            if (-not $mouseOn) {
                Write-Note "[提示] 控制台没有接受鼠标模式:菜单只能用键盘操作,"
                Write-Note "       方向键 / 数字键 / Enter / Esc 均可用。"
            }
        }

        while ($true) {
            $choice = $null
            if ($tuiOk) {
                $choice = Read-RepairChoiceTui -Fixable $fixable -Mouse $mouseOn
            } else {
                $choice = Read-RepairChoiceLine -Fixable $fixable -InputRedirected $InputRedirected `
                            -InputTimeoutMs $InputTimeoutMs -StdinReader $StdinReader
            }

            $action = [string]$choice.Action
            if ($action -eq "eof") {
                Write-Note "输入结束(或等待输入超时),退出修复菜单。已写好的报告不受影响。"
                return
            }
            if ($action -eq "cancel") {
                Write-Note "已选择退出,未做任何改动。"
                return
            }
            if ($action -eq "invalid") { continue }

            # -Tui 传的是「输入走哪条通道」,不是「鼠标有没有开」。二者必须分开:
            # 控制台在、鼠标模式没开时,菜单仍然是 TUI,第二档确认也得按键读,
            # 不能掉回「输入 YES」那种逐行问法 —— 那会让同一个菜单里出现两套操作。
            Invoke-RepairSelection -Fixable $fixable -Indices @($choice.Indices) -Tui $tuiOk `
                -InputRedirected $InputRedirected -InputTimeoutMs $InputTimeoutMs -StdinReader $StdinReader

            Write-Host ""
            Write-Note "可继续选择其它编号,或按 Esc / 0 退出。修完重跑一次环境检查即可核对结果。"
        }
    } finally {
        # 模式还原只有这一条路是可靠的:正常退出、中途抛错、用户 Ctrl+C 都走它。
        # Exit-TuiMode 自己按「是否真的进过模式」判断,没进过就是空操作,
        # 所以这里无条件调用 —— 关掉快速编辑却不还原,那个窗口里就再也不能
        # 拖拽选字,而且用户无从知道原因。
        if (Get-Command Restore-TuiMode -ErrorAction SilentlyContinue) {
            try { Restore-TuiMode } catch { }
        }
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
        # 这两个只服务降级的那条路(非可交互控制台);TUI 那条路不经过它们。
        # 读取器按「输入是否被重定向」二选一:控制台终端走 [Console]::ReadLine(),
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

# 非 ASCII 路径。判据是【整条路径】而不是某一段:eNSP 装在纯英文目录、用户目录却带
# 中文,一样会坏。用户目录几乎没法改(要新建账户才能换),所以这一项只报影响面,
# 不给修法 —— 与 hyper-v 那一项同理,报事实比报一个做不到的建议有用。
$nonAsciiRoots = @()
foreach ($pair in @(@("eNSP 目录", $EnspDir), @("VBox 目录", $VBoxDir), @("用户目录", $env:USERPROFILE))) {
    if ($pair[1] -and (Test-NonAsciiPath -Path $pair[1])) { $nonAsciiRoots += $pair[0] }
}
if ($nonAsciiRoots.Count -eq 0) {
    Write-Fact "非 ASCII 路径" "无"
} else {
    Write-Host ("  [ !! ] 非 ASCII 路径: " + ($nonAsciiRoots -join " / "))
    Write-Note "     eNSP 调用链上有若干处按 ANSI 代码页传路径,带中文的目录会让设备起不来。"
    Write-Note "     eNSP 与 VBox 目录可以改(重装到纯英文路径);用户目录要新建账户才能改。"
}

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

# --- x86 VC++ 运行时 --------------------------------------------------------
# 32 位 eNSP 经 COM marshal IVirtualBox 时加载 x86\VBoxProxyStub-x86.dll,它(经
# VBoxRT-x86.dll)依赖 VBox\x86\ 下的 x86 版 VCRUNTIME140 / MSVCP140。干净机这俩
# 都缺,加载器会沿 PATH 抓到主目录的 x64 版 → ERROR_BAD_EXE_FORMAT(0xC1) → error 40。
#
# 只认 x86\ 子目录:主目录里放着同名 x64 文件正是【故障态】而不是通过,所以这一项
# 绝不去主目录找同名文件来"凑齐"。
try {
    Write-Host ""
    Write-Host "  -- x86 VC++ 运行时 (VBox\x86\) --"
    if (-not $VBoxDir) {
        Write-Note "[跳过] 未定位到 VBox 目录,无法核对。请用 -VBoxDir 指定。"
    } else {
        $vc = Get-X86VcRuntimeFacts -VBoxDir $VBoxDir
        if (-not $vc.X86DirFound) {
            Write-Host ("  [ !! ] 没有 " + $vc.X86Dir)
            Write-Note "     VBox 7.x 正常安装自带这个目录;它不在说明 VBox 安装异常。"
        } else {
            foreach ($vf in $vc.Files) {
                Write-Host ("  [" + $(if ($vf.Present) { " OK " } else { "缺失" }) + "] " + $vf.Name)
            }
            if (-not $vc.Complete) {
                Write-Note "  !! 缺的这几份会让 32 位 COM 激活失败(0x800700C1),AR 一拉就报 40。"
                Write-Note "     修法: 重跑 安装.bat,或把 payload\msvcrt-x86\*.dll 复制到上面这个目录。"
            }
        }
    }
} catch {
    Write-Fail "x86 VC++ 运行时" $_.Exception.Message
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
                Write-Note "     但接口名变成 「...Adapter #2」,而 eNSP 按精确名绑定 —— 症状与完全缺失一样。"
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
        Write-Note "  没找到 InterfaceDescription 含 「VirtualBox Host-Only」 的网卡。"
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
                    Write-Note "  这是 「#2」 类问题的正确判据。修法是重新注册设备(会重写模板中的名字),"
                    Write-Note "  而不是把 「#2」 本身当成故障 —— 名字一致时带后缀也能用。"
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

# --- 抓包驱动 (WinPcap / Npcap) ---------------------------------------------
# eNSP 的抓包只认 WinPcap;Npcap 的兼容层不被接受。
#
# 判据是【谁占着系统 wpcap.dll】,不是谁的服务在跑。这两件事实测会分叉(2026-09-16):
# npf.sys(WinPcap 的驱动)与 npcap.sys(Npcap 的驱动)可以并存且互不干扰,此时
# wpcap.dll 仍是 WinPcap 4.1.3,eNSP 抓包完全正常 —— 把"存在 npcap 服务"当成冲突,
# 会在一台健康机器上报出假警。所以服务只作为事实列出,不参与判定。
try {
    Write-Host ""
    Write-Host "  -- 抓包驱动 (WinPcap / Npcap) --"
    $pk = Get-PacketDriverFacts
    Write-Fact "wpcap.dll" ($(if ($pk.DllPresent) { $pk.DllPath } else { "(不存在)" }))
    if ($pk.DllPresent) {
        Write-Fact "版本 / 产品" ($pk.Version + "   " + $pk.Product)
    }
    Write-Host ("  [" + $(if ($pk.NpfService) { "运行" } else { "  - " }) + "] npf 服务 (WinPcap 的驱动)")
    Write-Host ("  [" + $(if ($pk.NpcapService) { "有  " } else { "  - " }) + "] npcap 服务 (Npcap 的驱动)")

    if ($pk.NpcapDisplaced) {
        Write-Host ""
        Write-Note "  !! 系统 wpcap.dll 是 Npcap 提供的 —— eNSP 抓包不认它。"
        Write-Note "     而且 Npcap 在装时会让 WinPcap 安装程序报『已有更新版本』而拒绝安装。"
        Write-Note "     修法: 卸载 Npcap(或只保留其独立模式),再把 wpcap.dll 换回 WinPcap 4.1.3。"
    } elseif ($pk.WinPcapUsable) {
        Write-Note "  WinPcap 就位,eNSP 抓包路径可用。"
        if ($pk.NpcapInstalled) {
            Write-Note "    另外装了 Npcap,但它没抢走系统 wpcap.dll,两者并存不影响 —— 不用动它。"
        }
    } else {
        Write-Note "  没有可用的 WinPcap。抓包与部分设备的启动会失败。"
        Write-Note "     修法: 安装 WinPcap 4.1.3。装之前若报『已有更新版本』,先卸载 Npcap。"
    }
} catch {
    Write-Fail "抓包驱动" $_.Exception.Message
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

# ---------------------------------------------------------------------------
# 基础 VM 注册与快照的事实表
#
# 第 6 节要打印它,修复菜单要用它挑出该修的项 —— 两处共用一份,而不是各探一遍。
# 探一次要跑 6 次 VBoxManage(1 次 list vms,加每台已注册 VM 各一次 snapshot),
# 菜单在报告落盘之后才跑,那时再重探纯属浪费,而且两份结论还可能不一致。
#
# 缓存放脚本作用域。diag.ps1 是用 -File 跑的、不是被 dot-source 的,所以
# $script: 在这里就是文件级作用域,没有 checks.ps1 顶部记的那个坑。
#
# 探测失败与"没读到"分开回传,由调用方决定怎么说:菜单那一侧只关心事实,
# 报告那一侧必须把"没查到"如实写出来,不能让读者以为查过了。
$script:BaseVmSheet = $null

function Get-BaseVmFactSheet {
    param([string]$EnspDir, [string]$VBoxManage)
    if ($null -ne $script:BaseVmSheet) { return $script:BaseVmSheet }

    $sheet = [pscustomobject]@{
        Facts       = @()
        ProbeErrors = @()
        XmlPath     = ""
        XmlPresent  = $false
    }
    if (-not $EnspDir) { $script:BaseVmSheet = $sheet; return $sheet }

    $baseDirs = @(Get-BaseVmDirs -EnspDir $EnspDir)

    $regVms = @{}
    if ($VBoxManage -and (Test-Path $VBoxManage)) {
        $vmsProbe = Invoke-Probe -Exe $VBoxManage -Arguments @("list", "vms")
        if ($vmsProbe.Ok) { $regVms = Parse-VBoxListVms -Lines $vmsProbe.Lines }
        else { $sheet.ProbeErrors += ("VBoxManage list vms: " + $vmsProbe.Error) }
    }

    # 注册路径取自 VirtualBox.xml 的 MachineRegistry:一次文件读换来全部已注册
    # 路径,省掉每台一次 showvminfo。
    $regSrc = @{}
    $vbHome = $env:VBOX_USER_HOME
    if (-not $vbHome) { $vbHome = Join-Path $env:USERPROFILE ".VirtualBox" }
    $vbXml = Join-Path $vbHome "VirtualBox.xml"
    $sheet.XmlPath = $vbXml
    $sheet.XmlPresent = Test-Path $vbXml
    if ($sheet.XmlPresent) {
        try {
            $regSrc = Parse-VBoxMachineRegistry -Lines @(Get-Content -Path $vbXml -ErrorAction Stop)
        } catch {
            $sheet.ProbeErrors += ("VirtualBox.xml: " + $_.Exception.Message)
        }
    }

    $vmStates = @{}
    $vmSnapshots = @{}
    foreach ($b in $baseDirs) {
        if (-not $b.DirPresent) { continue }
        if (-not $regVms.ContainsKey($b.Name)) { continue }
        $snProbe = Invoke-Probe -Exe $VBoxManage -Arguments @("snapshot", $b.Name, "list", "--machinereadable")
        $snaps = @()
        # VM 无快照时该命令返回非 0 且什么都不输出 —— 那是正常答案,不是故障。
        if ($snProbe.Ok) { $snaps = @(Parse-VBoxSnapshotList -Lines $snProbe.Lines) }
        $vmSnapshots[$b.Name] = $snaps
        if (-not (Test-LinkSnapshotPresent -SnapshotNames $snaps -VmName $b.Name)) {
            $stProbe = Invoke-Probe -Exe $VBoxManage -Arguments @("showvminfo", $b.Name, "--machinereadable")
            if ($stProbe.Ok) { $vmStates[$b.Name] = Parse-VmState -Lines $stProbe.Lines }
        }
    }

    $sheet.Facts = @(Resolve-BaseVmRegistration -BaseVmDirs $baseDirs `
                     -RegisteredVms $regVms -RegistrySrc $regSrc `
                     -VmStates $vmStates -VmSnapshots $vmSnapshots)
    $script:BaseVmSheet = $sheet
    return $sheet
}

# ===========================================================================
# 第 6 节  设备就绪:注册、快照与模板
# ===========================================================================
Write-Section "[6] 设备就绪:注册、快照与模板"
$sectionsOk += "6"

# --- 基础 VM 注册与 _Link 快照 ----------------------------------------------
#
# 每台 AR / WLAN / USG 都是基础 VM 的链接克隆,克隆要成立必须有注册项与
# <VM>_Link 快照。缺任何一样时【垫片日志都是干净的】—— clonevm 根本没被调到,
# eNSP 直接报 40,报告里也就只剩这一处能看出问题。
#
# 这不是理论缺口,是 2026-09-16 实际踩到的:AR_Base.vbox 里留着 aborted="true",
# 而旧版 register_vms.ps1 只认 poweroff,于是跳过补建快照 —— 而 AR_Base 恰恰是
# 拉路由器要用的那台。补过后克隆恢复正常。
#
# 探测是逐台跑的,所以能省则省:只查【已注册】的 VM,且只有当快照确实缺失时才去
# 查电源状态(状态只用于判断"现在能不能补",健康机器上不需要)。
try {
    Write-Host ""
    Write-Host "  -- 基础 VM 注册与 _Link 快照 --"
    if (-not $EnspDir) {
        Write-Note "[跳过] 未定位到 eNSP 目录,无法核对注册与快照。请用 -EnspDir 指定。"
    } else {
        $sheet = Get-BaseVmFactSheet -EnspDir $EnspDir -VBoxManage $vboxManageExe
        foreach ($pe in @($sheet.ProbeErrors)) { Write-Fail "基础 VM 探测" $pe }
        if (-not $sheet.XmlPresent) {
            Write-Note ("  [ !! ] 找不到 " + $sheet.XmlPath)
            Write-Note "     这个文件按账户存放,须用【平时启动 eNSP 的那个账户】跑本诊断。"
        }
        $vmFacts = @($sheet.Facts)

        foreach ($vm in $vmFacts) {
            if (-not $vm.DirPresent) {
                Write-Note ("  - " + $vm.Name + " : 未装该设备包,跳过")
                continue
            }
            Write-Host ("  * " + $vm.Name)
            if (-not $vm.Registered) {
                Write-Host "      [ !! ] 注册: 未注册"
            } elseif (-not $vm.PathValid) {
                Write-Host "      [ !! ] 注册: 已注册,但注册路径已失效"
                Write-Host ("             现指向: " + $vm.RegisteredPath)
                Write-Host ("             应为  : " + $vm.VBoxFile)
            } else {
                Write-Host "      [ OK ] 注册: 已注册且路径正确"
            }
            if (-not $vm.Registered) {
                Write-Host "      [ -- ] _Link 快照: 未注册,无法查询"
            } elseif ($vm.LinkSnapshot) {
                Write-Host "      [ OK ] _Link 快照: 有"
            } else {
                Write-Host ("      [ !! ] _Link 快照: 缺   (当前状态 " + $(if ($vm.State) { $vm.State } else { "取不到" }) + ")")
            }
        }

        $badReg  = @($vmFacts | Where-Object { $_.DirPresent -and ((-not $_.Registered) -or (-not $_.PathValid)) })
        $badSnap = @($vmFacts | Where-Object { $_.DirPresent -and $_.Registered -and (-not $_.LinkSnapshot) })
        if (($badReg.Count -gt 0) -or ($badSnap.Count -gt 0)) {
            Write-Host ""
            Write-Note "  !! 上面标 !! 的项会让对应设备一拉就报 40,而垫片日志里看不出异常。"
            Write-Note "     修法: 双击 注册设备.bat —— 它按需重注册并补建缺失的 _Link 快照,"
            Write-Note "     幂等且不删磁盘。补快照要求 VM 没有内存镜像:poweroff 与 aborted"
            Write-Note "     都满足,running / paused / saved 不满足(那几种状态请先关掉设备)。"
        }
    }
} catch {
    Write-Fail "基础 VM 注册" $_.Exception.Message
}

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

# --- 设备模板 UART / COM2 命名管道 ------------------------------------------
#
# 模板里的 <UART><Port slot="1" ... hostMode="HostPipe" path="\\.\pipe\config"/>
# 就是 eNSP 控制台挂上去的那根管道。端口没开时管道两端没有任何一端被创建,
# 设备【虚拟机启动是正常的】,只是永远进不了 CLI —— 现象与"卡在启动"一模一样。
#
# 解析器只读第一个 <Hardware> 块:带快照的 .vbox 会在每个 <Snapshot> 里重复整段
# 硬件配置,读进去就会把某个存档态里的端口当成实况。
try {
    Write-Host ""
    Write-Host "  -- 设备模板 UART / COM2 管道 --"
    if (-not $EnspDir) {
        Write-Note "[跳过] 未定位到 eNSP 目录。请用 -EnspDir 指定。"
        $uartTargets = @()
    } else {
        $uartTargets = @()
        foreach ($b in @(Get-BaseVmDirs -EnspDir $EnspDir)) {
            if ($b.VBoxFile) { $uartTargets += @{ Name = $b.Name; File = $b.VBoxFile } }
        }
        $ngfwTpl = Join-Path $EnspDir "plugin\ngfw\tools\ngfw\vfw_usg.vbox"
        if (Test-Path $ngfwTpl) { $uartTargets += @{ Name = "vfw_usg"; File = $ngfwTpl } }

        if ($uartTargets.Count -eq 0) {
            Write-Note "  没找到任何设备模板,跳过。"
        }
        $uartBad = 0
        foreach ($t in $uartTargets) {
            $ports = @(Parse-UartPorts -Lines (Get-Content -Path $t.File -ErrorAction Stop))
            $ok = Test-UartPipePresent -Ports $ports
            $p1 = @($ports | Where-Object { $_.Slot -eq "1" })
            $desc = $(if ($p1.Count -eq 0) { "模板里没有 slot 1 端口" }
                      else { "slot 1 enabled=" + $p1[0].Enabled + "  path=" + $(if ($p1[0].Path) { $p1[0].Path } else { "(空)" }) })
            Write-Host ("  [" + $(if ($ok) { " OK " } else { " !! " }) + "] " + $t.Name.PadRight(14) + $desc)
            if (-not $ok) { $uartBad++ }
        }
        if ($uartBad -gt 0) {
            Write-Note "  !! 上面标 !! 的模板没有可用的 COM2 命名管道,对应设备进不了 CLI。"
            Write-Note "     模板由 eNSP 安装时生成,改动它属【有损且非必需】,本工具不自动做。"
            Write-Note "     手动修法见 docs\troubleshooting-error40.md,或重装该设备包恢复模板。"
        }
    }
} catch {
    Write-Fail "设备模板 UART" $_.Exception.Message
}

# --- vboxserver 写权限 -------------------------------------------------------
#
# eNSP 装在 Program Files 下,普通账户默认不可写。而 VBoxHeadless 是非提权进程,
# 它必须在 <vboxserver>\<VM>\ 下建 Logs\ 并写 NVRAM / saved-state —— 写不进去时
# 建目录静默失败,VM 起不来,eNSP 报 40,而 eNSP 自己的日志里什么都没有。
try {
    Write-Host ""
    Write-Host "  -- vboxserver 目录写权限 --"
    if (-not $EnspDir) {
        Write-Note "[跳过] 未定位到 eNSP 目录。请用 -EnspDir 指定。"
    } else {
        $acl = Get-VBoxServerAclFacts -EnspDir $EnspDir
        if (-not $acl.Exists) {
            Write-Note "[跳过] 没有 vboxserver 目录(未装设备包?)。"
        } else {
            Write-Fact "目录" $acl.Directory
            foreach ($g in @($acl.WriteGrants)) {
                Write-Host ("        可写: " + $g.Account)
            }
            if ($acl.CurrentUserHasWrite) {
                Write-Host "  [ OK ] 当前账户在可写列表里"
            } else {
                Write-Host "  [ !! ] 当前账户【不在】可写列表里"
                Write-Note "     修法: 重跑 安装.bat(它会授权 vboxserver\ 树);"
                Write-Note "     手动等价命令见 installer\README.md 的权限一节。"
            }
            Write-Host ""
            Write-Note "  判据说明: 这里读的是 ACL,并没有真去写一次 —— 本诊断承诺全程只读。"
            Write-Note "  因此 deny 项与组的嵌套没有按系统的方式展开,结论偏保守:"
            Write-Note "  显示可写时基本确实可写;显示不可写时,请用【平时启动 eNSP 的账户】"
            Write-Note "  重跑本节确认后再下结论。"
        }
    }
} catch {
    Write-Fail "vboxserver 写权限" $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 残留进程的事实
#
# 第 7 节要打印它,修复菜单要用它决定"要不要提供清残留这一项" —— 共用一份。
# 归属按 VM 配置文件的路径判定,与 cleanup_orphans.ps1 划的是同一条线:
# eNSP 已关时任何 VBoxHeadless 都算残留,但用户自己从 VirtualBox GUI 起的
# VM 不算,绝不能碰。
$script:OrphanSheet = $null

function Get-EnspOrphanFacts {
    param([string]$EnspDir, [string]$VBoxManage)
    if ($null -ne $script:OrphanSheet) { return $script:OrphanSheet }

    $sheet = [pscustomobject]@{
        Proc         = Get-VBoxProcessFacts
        Owned        = @()
        RunningCount = 0
        ProbeError   = ""
    }

    if ($VBoxManage -and (Test-Path $VBoxManage)) {
        $runProbe = Invoke-Probe -Exe $VBoxManage -Arguments @("list", "runningvms")
        if ($runProbe.Ok) {
            $runningMap = Parse-VBoxListVms -Lines $runProbe.Lines
            $vbHome = $env:VBOX_USER_HOME
            if (-not $vbHome) { $vbHome = Join-Path $env:USERPROFILE ".VirtualBox" }
            $regSrc = @{}
            $xml = Join-Path $vbHome "VirtualBox.xml"
            if (Test-Path $xml) {
                try { $regSrc = Parse-VBoxMachineRegistry -Lines @(Get-Content -Path $xml -ErrorAction Stop) } catch { }
            }
            $sheet.Owned = @(Resolve-RunningVmOwnership `
                             -RunningVmNames @(Get-RunningVmNames -RegisteredVms $runningMap) `
                             -RegisteredVms $runningMap -RegistrySrc $regSrc `
                             -EnspDir $EnspDir -LocalAppData $env:LOCALAPPDATA)
            $sheet.RunningCount = $runningMap.Count
        } else {
            $sheet.ProbeError = $runProbe.Error
        }
    }
    $script:OrphanSheet = $sheet
    return $sheet
}

# ===========================================================================
# 第 7 节  残留进程
# ===========================================================================
Write-Section "[7] 残留进程"
$sectionsOk += "7"

# 关闭 eNSP 时它会为每台设备补发 controlvm poweroff。CE / CX / NE 那几台的客户机
# 是 Linux,硬断电收尾极慢(实测 5 分钟以上),个别进程还会在收尾时崩溃并弹出
# 「应用程序错误」框,不点掉就一直挂着,每台占 0.4-1.5 GB。这不是泄漏 —— 全部退完
# 内存会正常归还 —— 但它会让一台好机器看起来像坏的,而本报告其余各节都看不出。
#
# 归属按【VM 配置文件的路径】判,不按进程名:eNSP 已关时任何 VBoxHeadless 都算残留,
# 但用户自己从 VirtualBox GUI 起的 VM 不算。这与 清理残留.bat 划的是同一条线。
try {
    Write-Host ""
    Write-Host "  -- VirtualBox 进程 --"
    $orphanSheet = Get-EnspOrphanFacts -EnspDir $EnspDir -VBoxManage $vboxManageExe
    $proc = $orphanSheet.Proc
    Write-Fact "eNSP 主程序" $(if ($proc.EnspRunning) { "运行中" } else { "未运行" })
    Write-Fact "eNSP_VBoxServer" $(if ($proc.ServerRunning) { "运行中" } else { "未运行" })
    if ($proc.HeadlessCount -eq 0) {
        Write-Fact "VBoxHeadless" "无"
    } else {
        Write-Host ("  VBoxHeadless: " + $proc.HeadlessCount + " 个")
        foreach ($p in @($proc.Processes | Where-Object { $_.Name -eq "VBoxHeadless" })) {
            Write-Host ("      PID " + $p.Id + "   " + $p.MemMB + " MB   启动于 " + $p.Started)
        }
    }

    if ($orphanSheet.ProbeError) {
        Write-Fail "VBoxManage list runningvms" $orphanSheet.ProbeError
    } else {
        $owned = @($orphanSheet.Owned)

        if ($owned.Count -eq 0) {
            Write-Fact "正在运行的 VM" "无"
        } else {
            Write-Host ("  正在运行的 VM: " + $owned.Count + " 台")
            foreach ($o in $owned) {
                Write-Host ("      " + $o.Name.PadRight(20) + $(if ($o.EnspOwned) { "<- eNSP 的客户机" } else { "<- 非 eNSP 所有,不动" }))
            }
        }

        if ((-not $proc.EnspRunning) -and ($proc.HeadlessCount -gt 0)) {
            Write-Host ""
            Write-Note "  eNSP 已关闭,但仍有 VBoxHeadless 占着内存。"
            Write-Note "     CE / CX / NE 的客户机是 Linux,硬断电收尾慢,实测 5 分钟以上;"
            Write-Note "     期间内存不释放,个别进程崩溃后弹出的「应用程序错误」框不点掉会一直挂住。"
            Write-Note "     全部退完后内存正常归还,【不是永久泄漏】,本工具也不把它算作故障。"
            Write-Note "     不想等就双击 清理残留.bat —— 它按归属列清单后确认,不碰用户自己的 VM。"
        } elseif ($proc.EnspRunning -and ($owned.Count -gt 0)) {
            Write-Note "  eNSP 正在运行,上面这些 VM 是它的在用设备,属正常。"
        }
    }
} catch {
    Write-Fail "残留进程" $_.Exception.Message
}

# ===========================================================================
# 第 8 节  日志尾部
# ===========================================================================
Write-Section "[8] 日志尾部"
$sectionsOk += "8"

# 最近被写过的那份 VM 日志。
#
# 定义放在本节最前面,而不是紧挨着下面的日志源列表:本节开头的判读段要调用它,
# 而 PowerShell 是顺序执行的 —— 函数定义在调用点之后,调用时就是 "not recognized"。
# 这不是风格问题,踩过一次。
#
# 它找的是【某一次虚拟机启动】留下的日志:走了哪个执行后端、加固有没有拒绝、
# 网络 LUN 有没有建起来。这类事实只在启动当时存在,机器静止时任何只读探测都
# 看不到 —— 所以必须把日志本身带进报告。
#
# 不猜是哪台 VM:eNSP 每次拉设备都会新建克隆(在 %LOCALAPPDATA%\eNSP 下),
# 基础盘又在安装目录下,两个地方都可能有。按最后写入时间取最新的一份,
# 那正是"最近那次启动"。
function Find-NewestVmLog {
    param([string]$FileName, [string]$VBoxUserHome, [string]$EnspDir)
    if (-not $FileName) { return "" }
    # VirtualBox 把 Logs\ 放在【VM 配置文件所在目录】下,所以搜索根就是三类配置文件
    # 的所在地,而不是想当然的 .VirtualBox\VMs:
    #   - eNSP 安装目录下的基础盘(AR_Base 等)——它们的 Logs\ 就在 AR_Base\ 里
    #   - %LOCALAPPDATA%\eNSP 下的克隆
    #   - .VirtualBox\VMs(从默认机器目录注册的 VM;本机为空,但别的机器会有)
    # 漏掉前两个会让这份日志在任何一台按本项目方式安装的机器上都取不到。
    $roots = @()
    if ($EnspDir)         { $roots += (Join-Path $EnspDir "vboxserver") }
    if ($env:LOCALAPPDATA){ $roots += (Join-Path $env:LOCALAPPDATA "eNSP") }
    if ($VBoxUserHome)    { $roots += (Join-Path $VBoxUserHome "VMs") }
    $best = ""
    $bestTime = [datetime]::MinValue
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        try {
            $f = Get-ChildItem -Path $r -Filter $FileName -Recurse -File -Depth 4 -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($f -and $f.LastWriteTime -gt $bestTime) {
                $best = $f.FullName
                $bestTime = $f.LastWriteTime
            }
        } catch { }
    }
    return $best
}

Write-Note "采集范围: 只取下列【当前】文件并截断尾部。同目录下数十个历史 .bak_*"
Write-Note "一律不采 —— 全量打包会把报告撑成几十 MB 的噪音。"
Write-Host ""
Write-Note "后面七份里,有三份是故障定性的关键证据所在:"
Write-Note "  * eNSP 的 vboxserver\log\VBoxManage.log —— VERR_INTNET_FLT_IF_NOT_FOUND 只在它这里出现;"
Write-Note "  * VBox.log(最近一次启动)—— 走的是 HM 还是 NEM、网络 LUN 建没建起来,都在这里;"
Write-Note "  * VBoxHardening.log —— 加固拒绝加载时才有,写的是【是哪个 DLL 被拒的】。"
Write-Note "后两份取自最近被写过的那一次设备启动,因此它们反映的是【最近一次失败现场】。"

# --- 最近一次启动的判读 ------------------------------------------------------
#
# 原始日志贴在下面,但结论先给:这两份日志里真正决定性的就那么几行,让读者自己
# 在几百行里找,等于把该做的事推回给读者 —— 而本报告存在的理由正是别让人靠翻日志。
#
# 格式都是照 VirtualBox 源码核过的(2026-09-16)。一条要点:十进制负号形式的 rc
# **只出现在加固日志里**;VBox.log 打的是符号名(rc=VERR_...),VBoxManage 打的是
# "code VERR_... (0x...)"。所以 VBox.log 里找不到裸的 -5657,按数字去找会一无所获。
try {
    Write-Host ""
    Write-Host "  -- 最近一次启动的判读 --"

    $vbHome3 = $env:VBOX_USER_HOME
    if (-not $vbHome3) { $vbHome3 = Join-Path $env:USERPROFILE ".VirtualBox" }
    $vboxLogPath = Find-NewestVmLog -FileName "VBox.log" -VBoxUserHome $vbHome3 -EnspDir $EnspDir
    $hardLogPath = Find-NewestVmLog -FileName "VBoxHardening.log" -VBoxUserHome $vbHome3 -EnspDir $EnspDir

    # ---- VBox.log ----
    if (-not $vboxLogPath) {
        Write-Note "  没有 VBox.log —— 本机还没启动过任何设备时属正常,设备一启动就会有。"
    } else {
        $vl = @(Get-Content -Path $vboxLogPath -ErrorAction Stop)
        Write-Fact "VBox.log" ($vboxLogPath + "   (" + $vl.Count + " 行)")
        Write-Host ""

        $be = Parse-VBoxLogBackend -Lines $vl
        if ($be.Backend -eq "native") {
            Write-Fact "执行后端" "原生硬件虚拟化 (VT-x / AMD-V)"
            Write-Note "     走的是硬件加速。"
        } elseif ($be.Backend -eq "nem") {
            Write-Fact "执行后端" "NEM / WHP (与 Hyper-V 共用虚拟化)"
            if ($be.ForcedNEM) {
                Write-Note "     依据: HM: Setting fHMEnabled to false because fUseNEMInstead is set."
                Write-Note "     —— 这是【被显式要求】走 NEM 的,不是自动回退。"
            } elseif ($be.FallbackLine) {
                Write-Note ("     依据: " + $be.FallbackLine)
            }
            if ($be.NemLine) { Write-Note ("     " + $be.NemLine) }
            Write-Note "     这不是故障:设备功能完全正常,代价只是慢(单台 3-5 分钟属正常),"
            Write-Note "     也不需要「修」—— 见 README 里关于 Hyper-V 的那一节。"
        } elseif ($be.Backend -eq "iem") {
            Write-Fact "执行后端" "IEM (纯解释执行)"
            Write-Host ("      [ !! ] " + $be.IemLine)
            Write-Note "     硬件与 WHP 都用不上,guest 正被逐条解释执行 —— 会慢到不可用。"
            Write-Note "     常见成因是嵌套虚拟化没打开:宿主没给这台客户机暴露 VT-x,"
            Write-Note "     客户机内又没有可用的 WHP。"
        } else {
            Write-Fact "执行后端" "未能判定"
            Write-Note "     两份判据行都没出现 —— 日志可能被截断,或这次启动没走到后端初始化。"
            Write-Note "     注意不要拿 'HM: VT-x/AMD-V init method: Local' 当判据:"
            Write-Note "     它说的是 HM 模块怎么初始化的,走 NEM 时也会出现。"
        }

        $markers = @(Find-VBoxLogMarkers -Lines $vl)
        Write-Host ""
        if ($markers.Count -eq 0) {
            Write-Fact "关键标记" "无"
        } else {
            Write-Host ("  [ !! ] 关键标记: " + $markers.Count + " 处")
            $markerNotes = @{
                "intnet"          = "host-only 网络:过滤驱动没有进入数据路径,startvm 起不来。见第 3 节第 5 层与 docs 的根因 D1。"
                "nemNotAvail"     = "NEM 不可用:嵌套环境下宿主没给这台机器暴露 VT-x,任何 VM 都起不来。"
                "hardening"       = "加固拒绝加载了某个模块 —— 具体是哪个看下面的加固日志。"
                "hardeningFatal"  = "加固致命错误,原因同上。"
                "namedPipeSrv"    = "COM2 命名管道(服务端)创建失败。"
                "namedPipeSrv2"   = "COM2 命名管道创建失败。"
                "namedPipeCli"    = "COM2 命名管道(客户端)连接失败。"
                "pdmConstruct"    = "设备构造失败;同一块里前面那行的 rc= 才是根因。"
            }
            # 同一个根因常常在多行上报出来(VMSetError 一行、PDM 构造失败一行),
            # 行都列出来当证据,但【结论只说一次】—— 重复三遍同一句话会把报告读成噪音。
            $notedIds = @{}
            foreach ($m in $markers) {
                Write-Host ("      " + $m.Line)
                $note = $markerNotes[$m.Id]
                if ($note -and (-not $notedIds.ContainsKey($m.Id))) {
                    Write-Note ("        -> " + $note)
                    $notedIds[$m.Id] = $true
                }
            }
        }
    }

    # ---- VBoxHardening.log ----
    Write-Host ""
    if (-not $hardLogPath) {
        Write-Note "  没有 VBoxHardening.log —— 本机从未启动过设备时属正常。"
    } else {
        $hl = @(Get-Content -Path $hardLogPath -ErrorAction Stop)
        Write-Fact "VBoxHardening.log" ($hardLogPath + "   (" + $hl.Count + " 行)")
        $hp = Parse-HardeningLog -Lines $hl

        $hardenNotes = @{
            -5657 = "被加载的模块没有用与 VirtualBox 相同的证书签名 —— 原版 VBox 遇到非 Oracle 签名的 DLL 就是这样。"
            -5640 = "进程里出现了第二个线程,通常是第三方软件注入所致(安全软件 / DLP / 反作弊驱动)。"
            -5607 = "镜像大小与预期不符。"
        }

        if (-not $hp.Failed) {
            Write-Fact "加固判定" "未发现加固失败"
            Write-Note "     加固日志每次启动都会生成,它没有「结尾行」—— 判定靠的是【找不到错误"
            Write-Note "     锚点】,不是靠找到某个成功标记。"
        } else {
            Write-Host "  [ !! ] 加固判定: 失败"
            foreach ($e in @($hp.Errors)) {
                $sym = $(if ($e.Symbol) { $e.Symbol } else { "(未收录的错误码)" })
                Write-Host ("      rc=" + $e.Code + "   " + $sym)
                if ($e.Where) { Write-Host ("          位置: " + $e.Where + $(if ($e.Step) { "   步骤: " + $e.Step } else { "" })) }
                $note = $hardenNotes[$e.Code]
                if ($note) { Write-Note ("          -> " + $note) }
            }
            Write-Note "     加固是 VirtualBox 自身的行为,不是本垫片引入的;原版 VBox 同样会拒绝。"
            Write-Note "     它无法由本工具修复 —— 要动的是【被拒的那个模块】(卸载它 / 换签名版),"
            Write-Note "     或用 VirtualBox 认可的方式加载。"
        }

        if (@($hp.RejectedModules).Count -gt 0) {
            Write-Host ""
            Write-Host "      被拒的模块:"
            foreach ($m in @($hp.RejectedModules)) { Write-Host ("        " + $m) }
        }
    }
} catch {
    Write-Fail "启动日志判读" $_.Exception.Message
}

# 日志源用「访问器函数」返回,而不是 $script: 作用域的数组变量。
# 从函数内部读 $script:Name 会绑定到调用方的作用域、拿到 $null
# (这正是 checks.ps1 顶部注释里记的那个坑),所以这里按参数取 EnspDir 现算。
#
# 每项带一个 Why:路径为空时用它解释原因。
#
# 原来只有一句「eNSP 目录未定位到」,那是当时唯一可能的原因;现在源变多了,
# 再把"这台机器还没启动过设备"说成"eNSP 目录没找到"就是纯粹的误导 ——
# 用户会去修一个根本不存在的路径问题。
function Get-DiagLogSources {
    param([string]$EnspDir)
    $vbHome = $env:VBOX_USER_HOME
    if (-not $vbHome) { $vbHome = Join-Path $env:USERPROFILE ".VirtualBox" }
    $noEnsp  = "未定位到 eNSP 目录,请用 -EnspDir 指定。"
    $noStart = "未找到该日志 —— 本机还没启动过任何 eNSP 设备时属正常(设备一启动就会有)。"
    return @(
        @{ Label = "shim install";    Path = "$env:ProgramData\ensp-vbox-shim\install.log";            Tail = 200; Why = "路径未确定。" },
        @{ Label = "shim proxy";      Path = "$env:ProgramData\ensp-vbox-shim\vbox52_proxy.log";       Tail = 200; Why = "路径未确定。" },
        @{ Label = "shim wrapper";    Path = "$env:ProgramData\ensp-vbox-shim\vboxmanage_wrapper.log"; Tail = 200; Why = "路径未确定。" },
        @{ Label = "VBoxSVC";         Path = (Join-Path $vbHome "VBoxSVC.log");                        Tail = 300; Why = "路径未确定。" },
        @{ Label = "eNSP VBoxManage"; Path = $(if ($EnspDir) { Join-Path $EnspDir "vboxserver\log\VBoxManage.log" } else { "" }); Tail = 200; Why = $noEnsp },
        # 最近一次 VM 启动的两份日志。VBox.log 回答"走的 HM 还是 NEM、网络 LUN 建没建
        # 起来";VBoxHardening.log 只在加固拒绝时才有内容,回答"是哪个 DLL 被拒的"。
        @{ Label = "VBox.log(最近一次启动)";     Path = (Find-NewestVmLog -FileName "VBox.log" -VBoxUserHome $vbHome -EnspDir $EnspDir);           Tail = 150; Why = $noStart },
        # 加固日志【每次启动都会生成】(MachineImpl::launchVMProcess 先删旧的再传
        # --sup-hardening-log)。所以"文件不在"只说明这台机器还没启动过设备,
        # 不代表加固没失败过 —— 判定要看内容里有没有错误锚点,不是看文件在不在。
        @{ Label = "VBoxHardening.log(最近一次)"; Path = (Find-NewestVmLog -FileName "VBoxHardening.log" -VBoxUserHome $vbHome -EnspDir $EnspDir); Tail = 80;  Why = "未找到该日志 —— 本机还没启动过任何 eNSP 设备时属正常(该文件每次启动都会生成)。" }
    )
}

try {
    foreach ($src in @(Get-DiagLogSources -EnspDir $EnspDir)) {
        Write-Host ""
        Write-Host ("  == " + $src.Label + " ==")
        try {
            if (-not $src.Path) {
                Write-Note $(if ($src.Why) { $src.Why } else { "路径未确定。" })
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
# 第 9 节  收尾
# ===========================================================================
Write-Section "[9] 收尾"
$sectionsOk += "9"

Write-Host ""
Write-Host ("  本次诊断到此结束,已产出第 " + ($sectionsOk -join " / ") + " 节。")
if ($script:DiagFailCount -eq 0) {
    Write-Host "  全部没有出现探测失败。"
} else {
    Write-Host ("  全部共有 " + $script:DiagFailCount + " 处探测失败,逐条标在各节里(以 [探测失败] 开头)。")
}
Write-Host ""
Write-Host "  本报告只覆盖上面列出的这些节,不表示环境完全无问题:"
Write-Host "  未覆盖的是安装器自身的校验与设备包镜像内容 —— 前者由 安装.bat 自己核对,"
Write-Host "  后者不随本工具分发。报告里没报错,只说明已覆盖的这些项没发现问题。"
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
