# diag.ps1 -- eNSP x VirtualBox 环境诊断(只读)
#
# 分工:checks.ps1 只探测事实(纯只读、返回对象、不打印),
#       本文件负责判断与展示,并把全部输出落一份报告。
#
# 编码:本文件面向用户、含中文字面量,必须存为 UTF-8 带 BOM。
#       PowerShell 5.1 只对无 BOM 的文件按 ANSI 解码,无 BOM 时中文会乱码。
#
# 只读约定:
#   - 不带 -Fix 时全程只读:不启动任何虚拟机、不修改任何系统设置。
#   - -Fix 是唯一会改动系统的地方,且必须由命令行显式给出。它另写一份
#     <报告名>.repair.txt。报告本体始终保持只读采集的形态 —— 报告里没有半截的、
#     读不出结论的会话记录,可以原样附进 issue。
#   - 报告第 [9] 节给出本机查出的问题、影响、以及【确切的修复命令】,连同怎么执行。
#     这一节是刻意放进报告的:报告是唯一会被附进 issue 的东西,而远程会话、无人值守、
#     以及任何读报告的人,都需要能拿到可执行的东西,而不是只被告知「有问题」。
#   - 绝不 dot-source install.ps1 —— 该文件有顶层副作用,一旦被 source 就会真的跑安装。
#   - fix.ps1 则可以 dot-source:它是纯函数库,顶层只有变量赋值与对 checks.ps1 的引入,
#     没有副作用,也不会自己执行任何修复(修复只在被调用时发生)。
#   - 读 install.ps1 只按文本读(取常量),不执行。
#
# 降级约定:每个探测都可能失败(缺 VBox、缺 eNSP、权限不足)。
#           任何探测失败都不许中断整轮诊断 —— 诊断跑到一半死掉,
#           比只报出部分事实更糟。每节都包 try/catch,失败就地把原因打出来。

param(
    [string]$EnspDir = "",
    [string]$VBoxDir = "",
    # 修复。空 = 只出报告(默认)。
    #   lossless        只做无损档(环境检查.bat -Fix 不带参数时映射到这个)
    #   all             含需确认档,逐条确认
    #   <id>[,<id>...]  只做指定项,id 见报告第 [9] 节
    [string]$Fix = "",
    [switch]$Yes,             # 跳过逐条确认(无人值守;与 -Fix 合用)
    [switch]$DryRun,          # 只列计划,不执行任何修复
    [switch]$NoMenu,          # 旧参数:现在是默认行为,接受但不起作用
    [string]$ReportPath = "", # 默认 %ProgramData%\ensp-vbox-shim\diag-<时间戳>.txt
    # 把本机【可修】项写成清单(一行一条:<档位>\t<id>),供安装器攒修复计划。
    # 默认不写。
    [string]$PlanFile = ""
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
# 所以这里只降级,不 exit;真要修的时候,按名字检查函数在不在。
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
# 计数是标量,没有数组绑定那层问题。
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
# 修复
#
# 这一段是本文件唯一会改动系统的地方,且只在命令行给出 -Fix 时才走;上面的诊断与
# 报告始终是只读的。三条硬约定:
#
#   1. 一律在 Start-Transcript 之外运行。报告是「只读采集」的产物:修复过程与用户
#      键入混进去,报告既读不出结论、又与它抬头的「不修改任何系统设置」自相矛盾。
#      修复过程单独落一份 <报告名>.repair.txt,记录不会因此丢掉。
#   2. 任何失败都不许把诊断打断:报告在此之前就已落盘,修复出错只影响它自己。
#   3. 读不到输入就【不执行】,绝不在无人应答的终端上把有损操作跑掉。
#
# 修复能力全部来自 fix.ps1。这里只负责四件事:挑出「诊断真的发现问题」的那几项、
# 把将要执行的命令原样显示出来、按档位做确认、调用修复函数并把结果报出来。
#
# 档位(设计 §7.1,判据是「是否无损」):
#   lossless  无损可修      —— 选中即执行
#   confirm   有损但必需    —— 先明示影响,再放行一次;不想逐条确认就用 -Yes
#   manual    有损且非必需  —— 不进执行范围,只打印现状、原因与手动步骤
#
# 选择走【id】而不是编号。编号只在一份报告、一次运行里有意义,而 id 是稳定的:
# 可以从报告第 [9] 节抄下来、写进脚本、或者在 issue 里转述给另一个人照着跑。
# ===========================================================================
# 虚拟化后端(第三档:只打印,不修)
# ---------------------------------------------------------------------------

# 纯只读,且刻意绕开 DISM:Get-WindowsOptionalFeature 在本机会挂住(TrustedInstaller
# 卡死,十分钟不返回),install.ps1 已为此改过一次。判据取「hypervisor 现在是否真的
# 在跑」—— VBox 能不能拿到原生 VT-x 取决于这个,Hyper-V 功能装没装说明不了。
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
# 修复因此不会在健康机器上退化成一串空操作。
#
# 判据全部来自 checks.ps1 的同一批探测函数,和报告读的是同一套事实:报告里报缺的
# 条目,修复才会提。
#
# 触发项(与设计 §7.1 的档位对应):
#   host-only 驱动未注册 / 一个 host-only 接口都没有  -> 四步链,confirm 档
#   性能计数器不工作                                  -> lodctr /R,  lossless 档
#   没有「已启用 + 允许」的 eNSP 规则                  -> 加规则,     lossless 档
#
# 读不到防火墙配置时不下结论、也不提供修复:那既可能是真的没有规则,也可能是权限
# 不足;在「没读到」的基础上加一条规则,可能造出与已有规则重名的第二条。诊断本身
# 也是这么写的,修复与它保持一致。
#
# 探测本身失败(抛异常)时也不静默跳过:那会让修复把「没查到」说成「没问题」。
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
            "手动步骤: 先排除这条探测失败的原因(权限不足居多),再重跑本诊断。"
        )
    }
}

# 跑一遍 -DryRun,拿到这条发现项「将要执行的命令」。
#
# fix.ps1 的契约是调用方先 -DryRun 显示、再去掉开关执行;dry run 只列命令、
# 不改动任何东西,所以报告与执行两条路径都能先看计划。
#
# 抽成一份是因为两条路径都要它。分两份写迟早会说不一样的话:报告说「会跑这三条」、
# 实际只跑两条,而两边都自称是同一个计划。
function Get-RepairPlan {
    param([object]$Item)

    $planned = @()
    $ok = $true
    $reason = ""
    $alreadyDone = @()

    foreach ($step in @($Item.Steps)) {
        if (-not (Get-Command $step.Fn -ErrorAction SilentlyContinue)) {
            $ok = $false
            $reason = ("修复原语缺失:找不到 " + $step.Fn + "(整合包不完整)")
            break
        }
        $argMap = $step.Args
        try {
            # 6>$null 吃掉原语自己在 dry run 里打的那几行。
            #
            # fix.ps1 的约定是 dry run「prints the commands it would run」,那是给
            # 交互式调用方看的。报告这条路径上不要它:命令由调用方统一排版,
            # 原语再打一遍就是同一批命令出现两次,而且带着它自己的调试口吻
            # (「[dry-run] step 3 bounce: would run: ...」),一起落进要附给 issue 的
            # 那份文件里。Write-Host 走的是信息流(6),所以只按这个流抑制,
            # 返回值不受影响。
            $r = & $step.Fn @argMap -DryRun 6>$null
        } catch {
            $ok = $false
            $reason = ($step.Fn + " 计划阶段出错: " + $_.Exception.Message)
            break
        }
        if (-not $r.Ok) {
            $ok = $false
            $reason = ($step.Fn + ": " + $r.Reason)
            break
        }
        if ($r.Skipped) { $alreadyDone += $step.Fn }
        $planned += @($r.Commands)
    }

    return [pscustomobject]@{
        Ok          = $ok
        Reason      = $reason
        Commands    = @($planned)
        AlreadyDone = @($alreadyDone)
    }
}

# 一条发现项的档位标签。TierLabel 由发现项自己给(它最清楚该提醒什么),没给就按
# 档位出。
#
# manual 档【不】写成「有损且非必需」:这一档里除了真正的第三档,还有「探测失败、
# 未能判定」的条目 —— 后者根本没有档位可言,给它套一个「有损」的帽子是错的。
function Get-RepairTierText {
    param([object]$Item)
    if ($Item.TierLabel) { return [string]$Item.TierLabel }
    switch ([string]$Item.Tier) {
        "lossless" { return "<无损>" }
        "confirm"  { return "<有损,执行前单独确认>" }
        default    { return "<不自动修复>" }
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
        # 判成的只是「取到了,而且里面确实没有」。
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
                        "再回来让本工具放行。"
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
    # 「报告说要修、修复说不必」这种两处结论打架的情况。
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
    # 是因为它会写 eNSP 安装目录下的文件,标签据此写成「会改写模板」。
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
# 修复:执行
#
# 这一段是整套脚本里唯一会改动系统的地方,且只在命令行明确给出 -Fix 时才走。
# 三条约定:
#
#   1. 一律在 Start-Transcript 之外运行。报告是「只读采集」的产物:修复过程的
#      输出混进去,报告既读不出结论、又与它抬头的「不修改任何系统设置」自相矛盾。
#      修复单独落一份 <报告名>.repair.txt,记录不会因此丢掉。
#   2. 任何失败都不许把诊断打断:报告在此之前就已落盘,修复出错只影响它自己。
#   3. 每条执行过的命令都回显,进而进那份转录。这个工具会装驱动、改注册表、
#      劫持 COM,只留一句「[完成] Xxx」的话,事后没法核对它做过什么。
# ---------------------------------------------------------------------------

# 有损档的放行。回车 = 执行,输入 n = 跳过,读不到输入 = 跳过。
#
# 为什么「回车 = 执行」:要执行哪几项已经由命令行给定了(-Fix all 或点名 id),
# 这里是明示影响之后的放行,不是第二次选择 —— 与本项目其余处的确认语义一致。
#
# 读不到输入一律按【不执行】处理:无人值守时宁可什么都不做,也不能因为撞上 EOF
# 就把有损操作跑掉。要跳过确认请显式用 -Yes,而不是靠输入被重定向。
function Read-RepairGoAhead {
    param([object]$Item)

    Write-Host ""
    Write-Host ("  " + $Item.Title + "   " + (Get-RepairTierText $Item))
    if ($Item.Impact -and @($Item.Impact).Count -gt 0) {
        Write-Host "  影响:"
        foreach ($line in @($Item.Impact)) { Write-Host ("      " + $line) }
    }
    Write-Host ""
    Write-Host -NoNewline "  回车 = 执行这一项 / 输入 n 再回车 = 跳过: "

    # 用 [Console]::ReadLine(),不用 Read-Host。两者在 EOF 上不一样:
    # Read-Host 返回空串,与「用户按了一下回车」无从区分,于是无人值守时撞上
    # EOF 会被当成放行,把有损操作跑掉 —— 而这恰好是最不该发生的一种跑法。
    # [Console]::ReadLine() 在 EOF 上返回 $null、回车返回空串,两者分得开。
    #
    # 本项目在输入层已经踩过一次同类问题(旧 Read-MenuLine 的注释里记着),
    # 这里不重复踩。
    $ans = $null
    try { $ans = [Console]::ReadLine() } catch { $ans = $null }

    if ($null -eq $ans) {
        Write-Host ""
        Write-Note "[跳过] 读不到输入(标准输入已结束或不可用),按【不执行】处理。"
        Write-Note "       要跳过逐条确认请显式用 -Yes。"
        return $false
    }
    $t = ([string]$ans).Trim().ToLower()
    if (($t -eq "n") -or ($t -eq "no")) {
        Write-Note "已跳过这一项。"
        return $false
    }
    return $true
}

# 执行一批发现项。$Items 是已经选好的,顺序就是执行顺序。
# 返回 Done / Skipped / Failed 三个计数,由调用方汇总。
function Invoke-RepairRun {
    param(
        [object[]]$Items = @(),
        [bool]$AssumeYes = $false,
        [bool]$PlanOnly = $false
    )

    # 设计 §7 的前置校验,不可省:修复前必须确认 eNSP 已关闭。
    # 未通过时只把命令列出来,一步都不执行。
    $pre = $null
    try { $pre = Test-RepairPreconditions } catch { $pre = $null }

    $doneCount = 0
    $skipCount = 0
    $failCount = 0

    foreach ($it in @($Items)) {
        Write-Host ""
        Write-Host ("  ---- " + $it.Title + "   " + (Get-RepairTierText $it) + " ----")

        $plan = $null
        try { $plan = Get-RepairPlan -Item $it } catch { $plan = $null }

        if ($plan) {
            Write-Note ("步骤: " + (@($it.Steps | ForEach-Object { $_.Fn }) -join " -> "))
            if (@($plan.Commands).Count -gt 0) {
                Write-Note "将要执行的命令:"
                foreach ($c in @($plan.Commands)) { Write-Host ("      " + $c) }
            } else {
                Write-Note "这一步不需要外部命令。"
            }
            if (@($plan.AlreadyDone).Count -gt 0) {
                Write-Note ("计划阶段判定已满足(执行时还会再确认一次): " + (@($plan.AlreadyDone) -join ", "))
            }
        }

        if ($plan -and (-not $plan.Ok)) {
            Write-Note ("[跳过] 前置条件不成立,未执行: " + $plan.Reason)
            $skipCount++
            continue
        }

        if ($PlanOnly) {
            Write-Note "[计划] -DryRun:只列计划,未执行。"
            $skipCount++
            continue
        }

        if ($pre -and (-not $pre.Ok)) {
            Write-Note ("eNSP 正在运行(" + (@($pre.Running) -join ", ") + ")。按设计约定,修复前必须关闭")
            Write-Note "eNSP —— 网络组件重绑会打断正在运行的设备。本次只显示上面的命令,不执行。"
            Write-Note "关掉 eNSP 后重跑即可。"
            $skipCount++
            continue
        }

        # 有损档:命令行点名之外再放行一次,除非显式 -Yes。
        if (($it.Tier -eq "confirm") -and (-not $AssumeYes)) {
            $go = $false
            try { $go = [bool](Read-RepairGoAhead -Item $it) } catch { $go = $false }
            if (-not $go) { $skipCount++; continue }
        }

        # 执行。顺序是硬依赖:中间一步失败就停下 —— fix.ps1 明确写过,
        # 前面的步骤没成就去建接口,会留下「接口在、栈不通」的状态,
        # 症状与完全没修一模一样。
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

            # 实际执行过的内容逐条回显,进而进 <报告名>.repair.txt。
            #
            # 内容由各原语自己记(见 fix.ps1 的 Commands 字段)。多数是可直接复制的
            # 命令行;模板显存那一项是进程内的 XML 改写,记的是一句描述 —— 所以这里
            # 说的是「执行了什么」,不写成「命令」。
            if (-not $r.Skipped) {
                foreach ($c in @($r.Commands)) {
                    if ($c) { Write-Host ("      > " + $c) }
                }
            }
        }

        if ($failed) {
            Write-Note "后续步骤依赖前一步,已停下。排掉上面这条原因后重跑。"
            $failCount++
        } else {
            $doneCount++
        }
    }

    return [pscustomobject]@{ Done = $doneCount; Skipped = $skipCount; Failed = $failCount }
}

# -Fix 的入口:挑出要执行的项 → 跑 → 汇总。
#
# 选择由 id 给出,不用编号:编号只在一份报告、一次运行里有意义,而 id 是稳定的 ——
# 可以从报告第 [9] 节抄下来,也可以写进脚本、或者在 issue 里转述给另一个人。
function Invoke-RepairCli {
    param(
        [string]$Select = "",
        [string]$EnspDir = "",
        [string]$VBoxDir = "",
        [bool]$AssumeYes = $false,
        [bool]$PlanOnly = $false
    )

    $items = @()
    try { $items = @(Get-RepairFindings -VBoxDir $VBoxDir -EnspDir $EnspDir) } catch { $items = @() }

    $fixable = @($items | Where-Object { ($_.Tier -eq "lossless") -or ($_.Tier -eq "confirm") })
    $manual  = @($items | Where-Object { $_.Tier -eq "manual" })

    Write-Host ""
    Write-Host ("=" * 64)
    Write-Host "  修复"
    Write-Host ("=" * 64)
    Write-Host ""
    Write-Note "这一段会改动系统,且只在命令行点名之后才动手。报告是只读采集,已经写完。"

    # 第三档与未能判定的,照旧只打印:这一段里没有它们的执行入口。
    if ($manual.Count -gt 0) {
        Write-Host ""
        Write-Host "  以下项不由本工具自动修复(原因与手动步骤见各条):"
        Write-Host ""
        foreach ($it in $manual) {
            Write-Host ("  * [" + (Get-RepairTierText $it) + "] " + $it.Title)
            foreach ($line in @($it.Manual)) { Write-Note $line }
            Write-Host ""
        }
    }

    if ($fixable.Count -eq 0) {
        Write-Host ""
        Write-Note "没有发现可由本工具自动修复的问题,本次不改动任何系统设置。"
        return [pscustomobject]@{ Done = 0; Skipped = 0; Failed = 0; Refused = $false }
    }

    # --- 选择 ---
    $sel = @()
    if ($Select -eq "lossless") {
        $sel = @($fixable | Where-Object { $_.Tier -eq "lossless" })
        if ($sel.Count -eq 0) {
            Write-Note "本机没有【无损】档的问题。"
        }
    } elseif ($Select -eq "all") {
        $sel = @($fixable)
    } else {
        $bad = @()
        foreach ($w in @($Select -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $hit = @($fixable | Where-Object { $_.Id -eq $w })
            if ($hit.Count -eq 0) { $bad += $w } else { $sel += $hit }
        }
        if ($bad.Count -gt 0) {
            # 未知项不静默忽略。给出了一个不存在的 id 却照样把其余的都跑了,
            # 使用者会以为自己点名的那些全都执行过。
            Write-Host ("  [!!] 不认识的选择: " + ($bad -join ", "))
            Write-Host ("       本机可修的是: " + (@($fixable | ForEach-Object { $_.Id }) -join ", "))
            if ($manual.Count -gt 0) {
                Write-Host ("       不自动修的  : " + (@($manual | ForEach-Object { $_.Id }) -join ", "))
            }
            Write-Host ""
            Write-Host "  本次不执行任何修复(选择里含未知项)。"
            return [pscustomobject]@{ Done = 0; Skipped = 0; Failed = 0; Refused = $true }
        }
    }

    if ($sel.Count -eq 0) {
        Write-Host ""
        Write-Note "没有选中任何项,本次不改动任何系统设置。"
        Write-Host ("  本机可修的是: " + (@($fixable | ForEach-Object { $_.Id }) -join ", "))
        Write-Host "    只做无损档          : 环境检查.bat -Fix"
        Write-Host "    含需确认档          : 环境检查.bat -Fix all"
        Write-Host "    只做指定项          : 环境检查.bat -Fix <id>[,<id>]"
        return [pscustomobject]@{ Done = 0; Skipped = 0; Failed = 0; Refused = $false }
    }

    Write-Host ""
    Write-Host ("  本次将处理 " + $sel.Count + " 项:")
    foreach ($it in $sel) { Write-Host ("    - " + $it.Title + "   " + (Get-RepairTierText $it)) }
    Write-Host ""
    if ($PlanOnly) {
        Write-Host "  -DryRun:下面只列计划,不会执行。"
    } elseif (@($sel | Where-Object { $_.Tier -eq "confirm" }).Count -gt 0) {
        Write-Host "  标【有损】的项会先明示影响再放行;不想逐条确认就加 -Yes。"
    }

    $res = Invoke-RepairRun -Items $sel -AssumeYes $AssumeYes -PlanOnly $PlanOnly

    Write-Host ""
    if ($PlanOnly) {
        Write-Host "  -DryRun 结束:以上只是计划,没有执行任何修复。去掉 -DryRun 即执行。"
    } else {
        Write-Host ("  完成 " + $res.Done + " 项,跳过 " + $res.Skipped + " 项,失败 " + $res.Failed + " 项。")
        if ($res.Done -gt 0) {
            Write-Host "  修复后重跑一次 环境检查.bat 复核:报告第 [9] 节会按新的状态重新判定。"
        }
    }

    return [pscustomobject]@{
        Done = $res.Done; Skipped = $res.Skipped; Failed = $res.Failed; Refused = $false
    }
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
# 不给修法 —— 与 hyper-v 那一项同理。
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
$installerText = ""
try { $installerText = Get-Content -Raw -Path (Join-Path $ScriptDir "install.ps1") -ErrorAction Stop } catch { }

# 从 install.ps1 的文本里取一个字符串常量。取不到返回空串,由调用方决定怎么降级。
function Get-InstallerConst {
    param([string]$Name)
    if (-not $installerText) { return "" }
    if ($installerText -match ('\$' + [regex]::Escape($Name) + '\s*=\s*"([^"]*)"')) { return [string]$Matches[1] }
    return ""
}

$expectedSha = ([string](Get-InstallerConst "DLL_SHA256")).ToLower()
$varpSha     = ([string](Get-InstallerConst "VARP_SHA256")).ToLower()
$clsidVbox   = Get-InstallerConst "CLSID_VBOX"
$dllName     = Get-InstallerConst "DLL_NAME"
if (-not $dllName) { $dllName = "VBox52.dll" }

if ($expectedSha) {
    Write-Fact "垫片期望哈希" $expectedSha
} else {
    Write-Note "[提示] 未能从 install.ps1 读出 DLL_SHA256,下面只报实际哈希、不判定匹配。"
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

# --- CLSID 劫持 -------------------------------------------------------------
# 上面那四个哈希只说明文件放对了,不说明有人会去加载它们。真正把 eNSP 接到垫片上
# 的是 CLSID_VirtualBox 的 InprocServer32。
#
# 它仍指着 Oracle 原版 proxy/stub 时,eNSP 进程内激活出来的是真接口,get_version
# 回 7.2.x;eNSP 拿这个值去比它认的 4.2 / 4.3 / 5.0 / 5.1 / 5.2,都不符,于是弹
# 「VirtualBox version is not supported.」并停在启动设备之前。
#
# 所以注册表里那个 5.2.44 只是个幌子:它是 eNSP 在某一处读到的字符串,而这个键
# 决定的是此后每一次调用落到谁身上。版本号改对了、这个键没改,现象与完全没改一样 ——
# 一台机器因此可以跑出一份没有任何失败项的报告,却依然起不来设备。
try {
    Write-Host ""
    Write-Host "  -- CLSID 劫持 (决定 eNSP 连到谁) --"
    if (-not $clsidVbox) {
        Write-Note "[跳过] 未能从 install.ps1 读出 CLSID 常量,无法核对这一项。"
    } elseif (-not $EnspDir) {
        Write-Note "[跳过] 未定位到 eNSP 目录,无法与垫片路径比对。请用 -EnspDir 指定。"
    } else {
        $shimDll = Join-Path (Join-Path $EnspDir "tools") $dllName
        $cj = Get-ClsidHijackFacts -ClsidVbox $clsidVbox -ExpectedDll $shimDll
        Write-Note ("应指向: " + $shimDll)
        foreach ($v in $cj.Views) {
            $vn = "64 位视图"
            if ($v.Name -eq "32") { $vn = "32 位视图" }
            if (-not $v.Present) {
                Write-Host ("  [缺失] " + $vn + " : 没有 InprocServer32 项")
            } elseif ($v.PointsAtShim) {
                Write-Host ("  [ OK  ] " + $vn + " : " + $v.Server)
            } else {
                Write-Host ("  [不符] " + $vn + " : " + $v.Server)
            }
        }
        if (-not $cj.PrimaryShim) {
            Write-Note "  !! eNSP 是 32 位进程,读的正是上面那个 32 位视图。它不指向垫片时,"
            Write-Note "     eNSP 拿到的是 Oracle 的真接口,版本号报 7.x,于是弹那句"
            Write-Note "     「VirtualBox version is not supported.」,设备走不到启动这一步。"
            Write-Note "     修法: 重跑 安装.bat —— 它会重写这两个键。"
        }
    }
} catch {
    Write-Fail "CLSID 劫持" $_.Exception.Message
}

# --- 插件 DLL 的补丁状态 ----------------------------------------------------
# 这两份由安装器决定投放或保留,状态只能靠哈希分辨:它们没有能区分版本的版本资源,
# 时间戳在文件被复制过之后也不再说明任何事。
#
# VAR_Plugin.dll 是 AR 路由器的承重补丁(IVirtualBox 5.2 -> 7.2 的 vtable 重映射)。
# 少了它 AR 一拉就报 40,而垫片日志是干净的 —— 补丁不在,那些调用根本没发出来,
# 报告里除了这一处没有别的地方看得出来。
#
# NGFW_Plugin.dll 安装器不动它,这里只报状态:非原版说明有人手工打过补丁,
# 排查 USG6000V 时需要知道这一点。
try {
    Write-Host ""
    Write-Host "  -- 插件 DLL --"
    if (-not $EnspDir) {
        Write-Note "[跳过] 未定位到 eNSP 目录,无法核对插件。请用 -EnspDir 指定。"
    } else {
        # VAR_Plugin 的出厂哈希是外部产物的哈希(不是本项目发布的东西),install.ps1
        # 里也是一个字面量,没有可解析的常量名,这里只能各存一份。它与我们的构建
        # 无关,不会随本项目的版本漂移。
        $varFactorySha = "5ae6817a9f2f05cfbb5f1f89af910007c22988c22bc02fdf2c44a67a9ff26eb5"
        $varFact = Get-TreeFileFact -EnspDir $EnspDir -Rel "plugin\ar1000v\VAR_Plugin.dll"
        if (-not $varFact.Present) {
            Write-Host "  [缺失] VAR_Plugin.dll : 未找到(没装 AR 包)"
        } elseif ($varFact.Hash -and $varpSha -and ($varFact.Hash -eq $varpSha)) {
            Write-Host "  [ OK  ] VAR_Plugin.dll : 已补丁"
        } elseif ($varFact.Hash -and ($varFact.Hash -eq $varFactorySha)) {
            Write-Host "  [ !!  ] VAR_Plugin.dll : 出厂原版,未打补丁 —— AR 一拉就报 40"
            Write-Note "     修法: 重跑 安装.bat。"
        } elseif ($varFact.Hash) {
            Write-Host ("  [  ?  ] VAR_Plugin.dll : 非标准版本  " + $varFact.Hash)
            Write-Note "     既不是我们的补丁版也不是出厂版,可能被别的工具改过。"
        }
        if ($varFact.Error) { Write-Fail "VAR_Plugin.dll" $varFact.Error }

        $ngfwFact = Get-TreeFileFact -EnspDir $EnspDir -Rel "plugin\ngfw\NGFW_Plugin.dll"
        $ngfwPristine = ([string](Get-InstallerConst "NGFW_PRISTINE_SHA256")).ToLower()
        $ngfwPatched  = ([string](Get-InstallerConst "NGFW_PATCHED_SHA256")).ToLower()
        $ngfwLegacy   = ([string](Get-InstallerConst "NGFW_LEGACY_SHA256")).ToLower()
        if (-not $ngfwFact.Present) {
            Write-Host "  [缺失] NGFW_Plugin.dll : 未找到(没装 USG6000V 包)"
        } elseif ($ngfwFact.Hash -and $ngfwPristine -and ($ngfwFact.Hash -eq $ngfwPristine)) {
            Write-Host "  [ OK  ] NGFW_Plugin.dll : 出厂原版(安装器不动它)"
        } elseif ($ngfwFact.Hash -and $ngfwPatched -and ($ngfwFact.Hash -eq $ngfwPatched)) {
            Write-Host "  [  !  ] NGFW_Plugin.dll : 被手工打过 22 站点补丁"
        } elseif ($ngfwFact.Hash -and $ngfwLegacy -and ($ngfwFact.Hash -eq $ngfwLegacy)) {
            Write-Host "  [  !  ] NGFW_Plugin.dll : 被手工打过旧 28 站点补丁"
        } elseif ($ngfwFact.Hash) {
            Write-Host ("  [  ?  ] NGFW_Plugin.dll : 非标准版本  " + $ngfwFact.Hash)
        }
        if ($ngfwFact.Error) { Write-Fail "NGFW_Plugin.dll" $ngfwFact.Error }
    }
} catch {
    Write-Fail "插件 DLL" $_.Exception.Message
}

# --- x86 VC++ 运行时 --------------------------------------------------------
# 32 位 eNSP 经 COM marshal IVirtualBox 时加载 x86\VBoxProxyStub-x86.dll,它(经
# VBoxRT-x86.dll)依赖 VBox\x86\ 下的 x86 版 VCRUNTIME140 / MSVCP140。干净机这俩
# 都缺,加载器会沿 PATH 抓到主目录的 x64 版 → ERROR_BAD_EXE_FORMAT(0xC1) → error 40。
#
# 只认 x86\ 子目录:主目录里放着同名 x64 文件本身就是【故障态】,所以这一项绝不
# 去主目录找同名文件来凑齐。
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
                # 要喂 Name;VBoxNetworkName 带 "HostInterfaceNetworking-" 前缀,
                # 与模板里的名字永远不相等。
                $cmp = Compare-HostOnlyName -VBoxNames $ifNames -TemplateNames $tplNames
                Write-Fact "匹配" ($cmp.MatchedCount.ToString() + " / " + $tplNames.Count)
                if ($cmp.HasMismatch) {
                    Write-Host ("  [ !! ] 模板里有 " + $cmp.MissingInVBox.Count + " 个名字在实际接口中不存在:")
                    foreach ($m in $cmp.MissingInVBox) { Write-Host ("         " + $m) }
                    Write-Note "  这是 「#2」 类问题的正确判据。修法是重新注册设备(会重写模板中的名字);"
                    Write-Note "  名字一致时带后缀也能用,不用去动 「#2」 本身。"
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
        Write-Note "  因此上面只报状态。"
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
    Write-Note "  报成「计数器损坏」;这个检查只会误报,故不采用。"
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
# 第 6 节要打印它,-Fix 要用它挑出该修的项 —— 两处共用一份,而不是各探一遍。
# 探一次要跑 6 次 VBoxManage(1 次 list vms,加每台已注册 VM 各一次 snapshot),
# 修复在报告落盘之后才跑,那时再重探纯属浪费,而且两份结论还可能不一致。
#
# 缓存放脚本作用域。diag.ps1 是用 -File 跑的、不是被 dot-source 的,所以
# $script: 在这里就是文件级作用域,没有 checks.ps1 顶部记的那个坑。
#
# 探测失败与"没读到"分开回传,由调用方决定怎么说:修复那一侧只关心事实,
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
# 2026-09-16 实际踩到过:AR_Base.vbox 里留着 aborted="true",而旧版
# register_vms.ps1 只认 poweroff,于是跳过补建快照 —— 而 AR_Base 恰恰是拉路由器
# 要用的那台。补过后克隆恢复正常。
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
# 判据是「该插件 Database\ 下存在它自己的镜像文件」;目录本身存在说明不了什么,
# 全新安装时这些 Database\ 都是空的。
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
        # 版本取不到就不做约束判断:猜一个版本会报出错误的「需要升级」结论。
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
                # 不论是否告警都必须打印这个值 —— 「只有 AR 坏、交换机和防火墙
                # 都正常」那一类报告,要靠它定性。
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
            Write-Note "  没有任何一个模板靠近 1。所以这一项防的是「被改坏」,与出厂状态无关。"
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
# 第 7 节要打印它,修复要用它决定"要不要提供清残留这一项" —— 共用一份。
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
# 「应用程序错误」框,不点掉就一直挂着,每台占 0.4-1.5 GB。全部退完之后内存会正常
# 归还,不算泄漏;但它会让一台好机器看起来像坏的,而本报告其余各节都看不出。
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
            Write-Note "     全部退完后内存正常归还,本工具也不把它算作故障。"
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
# 定义放在本节最前面:本节开头的判读段要调用它,而 PowerShell 是顺序执行的 ——
# 函数定义在调用点之后,调用时就是 "not recognized"。这条实际踩过一次。
#
# 它找的是【某一次虚拟机启动】留下的日志:走了哪个执行后端、加固有没有拒绝、
# 网络 LUN 有没有建起来。这类事实只在启动当时存在,机器静止时任何只读探测都
# 看不到 —— 所以必须把日志本身带进报告。
#
# 不猜是哪台 VM:eNSP 每次拉设备都会新建克隆(在 %LOCALAPPDATA%\eNSP 下),
# 基础盘又在安装目录下,两个地方都可能有。按最后写入时间取最新的一份,
# 就是最近那次启动。
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
# 原始日志贴在下面,但结论先给:这两份日志里管用的就那么几行,让读者自己
# 在几百行里找,等于把该做的事推回给读者。
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

# 日志源用「访问器函数」返回:$script: 作用域的数组变量在函数里读不到 ——
# 从函数内部读 $script:Name 会绑定到调用方的作用域、拿到 $null
# (见 checks.ps1 顶部注释里记的那个坑),所以这里按参数取 EnspDir 现算。
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
        # 不代表加固没失败过 —— 判定看的是内容里有没有错误锚点,文件在不在说明不了。
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
# 第 9 节  本机发现
# ===========================================================================
Write-Section "[9] 本机发现"
$sectionsOk += "9"

# 上面八节是事实,这一节把它们收成「这台机器该做什么」。
#
# 它必须落在这里,不能留到修复阶段再说。报告是唯一会被附进 issue 的东西;修法与
# 命令只活在交互过程里的话,远程会话、无人值守、以及修复本身跑不起来这三种情形下,
# 读过报告的人手里就没有任何可执行的东西 —— 而远程恰恰是最常报障的场合。
#
# 命令由 -DryRun 产出(fix.ps1 的契约:dry run 只列命令、不改动任何东西),
# 所以本节仍然是只读采集的产物。
Write-Host ""
Write-Host "  下面是本机实际查出的问题,以及各自对应的处置。"
Write-Host "  命令取自 -DryRun 计划(只列不改),可直接复制执行。"
Write-Host ""

try {
    $findings = @(Get-RepairFindings -VBoxDir $VBoxDir -EnspDir $EnspDir)
} catch {
    $findings = @()
    Write-Fail "本机发现" $_.Exception.Message
}

# 分两拨:能修的进上面(带命令),不自动修的进下面(只给原因与手动步骤)。
$fxItems = @($findings | Where-Object { ($_.Tier -eq "lossless") -or ($_.Tier -eq "confirm") })
$mnItems = @($findings | Where-Object { $_.Tier -eq "manual" })
$fixIds  = @($fxItems | ForEach-Object { $_.Id })

# 可修项清单,一行一条:<档位>\t<id>。
#
# 给安装器用:在提权之前跑一遍检测,据此攒出"用户同意的计划",再把计划交给提权的
# 那一段执行。这是本项目的既有分工 —— 同意在提权之前征得,提权侧只执行计划、
# 不自行判断该修什么。
#
# 只写【可修】的那两档:manual 档里除了第三档,还有"探测失败、未能判定"的条目,
# 它们根本没有可执行的修复,写进去只会让下游以为有活可干。
#
# 写不成不是错误(没传这个开关是常态),但也【不静默】:调用方拿不到清单会以为
# 本机没有问题,而实际可能只是这个文件没落盘。故失败时打印一行并计入探测失败。
if ($PlanFile) {
    try {
        $lines = @($fxItems | ForEach-Object { ([string]$_.Tier) + "`t" + ([string]$_.Id) })
        $planDir = Split-Path -Parent $PlanFile
        if ($planDir -and -not (Test-Path $planDir)) {
            New-Item -ItemType Directory -Path $planDir -Force | Out-Null
        }
        Set-Content -Path $PlanFile -Value $lines -Encoding ASCII
        Write-Host ("  可修项清单: " + $PlanFile + " (" + $lines.Count + " 条)")
    } catch {
        Write-Fail "可修项清单" $_.Exception.Message
    }
}

if ($fxItems.Count -eq 0) {
    Write-Host "  没有发现可由本工具自动修复的问题。"
} else {
    Write-Host ("  可由本工具修复的共 " + $fxItems.Count + " 项:")
    Write-Host ""

    foreach ($it in $fxItems) {
        Write-Host ("  [" + (Get-RepairTierText $it) + "] " + $it.Title)

        if ($it.Symptom)  { Write-Host ("      现象 : " + $it.Symptom) }
        if ($it.Evidence) { Write-Host ("      依据 : " + $it.Evidence) }
        if ($it.Impact -and @($it.Impact).Count -gt 0) {
            Write-Host "      影响 :"
            foreach ($line in @($it.Impact)) { Write-Host ("             " + $line) }
        }

        $plan = $null
        try { $plan = Get-RepairPlan -Item $it } catch { $plan = $null }

        if (-not $plan) {
            Write-Host "      命令 : (计划阶段出错,未能生成)"
        } elseif (-not $plan.Ok) {
            # 前置条件不成立时说清楚,否则照着抄的人只会撞一次失败。
            Write-Host ("      命令 : 暂时不可执行 —— " + $plan.Reason)
        } elseif (@($plan.Commands).Count -eq 0) {
            Write-Host "      命令 : (这一步不需要外部命令)"
        } else {
            Write-Host "      命令 :"
            foreach ($c in @($plan.Commands)) { Write-Host ("             " + $c) }
        }
        if ($plan -and @($plan.AlreadyDone).Count -gt 0) {
            Write-Host ("      注   : 计划阶段已判定满足(执行时会再确认一次): " + (@($plan.AlreadyDone) -join ", "))
        }

        Write-Host ("      执行 : 环境检查.bat -Fix " + $it.Id)
        Write-Host ""
    }
}

if ($mnItems.Count -gt 0) {
    Write-Host "  以下项不由本工具自动修复(原因与手动步骤见各条):"
    Write-Host ""
    foreach ($it in $mnItems) {
        Write-Host ("    * [" + (Get-RepairTierText $it) + "] " + $it.Title)
        foreach ($line in @($it.Manual)) { Write-Host ("        " + $line) }
        Write-Host ""
    }
}

# 把「下一步敲什么」写在报告里。报告会被附进 issue,读它的人未必有本机访问权,
# 这两行让任何读到的人都能把建议原样转达给机器前的人。
Write-Host "  下一步:"
if ($fxItems.Count -eq 0) {
    Write-Host "    本机没有可自动修复的项,不需要执行修复。"
} else {
    Write-Host ("    只做无损项          : 环境检查.bat -Fix")
    Write-Host ("    只做指定项          : 环境检查.bat -Fix " + $fixIds[0] + "   (可逗号分隔多项)")
    Write-Host ("    含需确认项(逐条问)  : 环境检查.bat -Fix all")
    Write-Host ("    只看计划、不执行    : 环境检查.bat -Fix all -DryRun")
}
Write-Host ""

# ===========================================================================
# 第 10 节  收尾
# ===========================================================================
Write-Section "[10] 收尾"
$sectionsOk += "10"

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
Write-Host "  本报告全程为只读采集,不含任何交互内容 —— 修复在转录停止之后才运行,"
Write-Host "  它那一段另写一份 <报告名>.repair.txt,不会混进本文件。"
Write-Host ""
Write-Host ("  报告文件: " + $ReportPath)

if ($transcriptOn) {
    try { Stop-Transcript | Out-Null } catch { }
}
# 转录已停。这里把它记成事实而不是假设:下面这段若再写进报告,
# 报告就不再是「只读采集」,也就没法原样附进 issue 了。
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
# 修复(报告之后)
#
# 修复在报告落盘之后才跑,并另写一份 <报告名>.repair.txt —— 报告本体因此保持
# 「只读采集」的形态,可以原样附进 issue。
#
# 整段包 try/catch:它是报告之后的附加动作,出错不许影响已经落盘的报告,
# 也不许让调用方(环境检查.bat / 脚本)拿到一个假的失败退出码。
# ---------------------------------------------------------------------------
if ($Fix) {
    $repairLog = ""
    if ($ReportPath) { $repairLog = [System.IO.Path]::ChangeExtension($ReportPath, ".repair.txt") }

    $repairTranscript = $false
    if ($repairLog) {
        try {
            Start-Transcript -Path $repairLog -Force | Out-Null
            $repairTranscript = $true
        } catch { }
    }

    # 退出码是给调用方看的:安装器那一段要据此判断"这一段到底做成了没有"。
    # 只报 0 会让"计划里的 id 对不上、一项都没修"与"修好了"长得一模一样。
    #   0  执行完毕(含"本机没有可修项",那不算失败)
    #   2  没有执行任何修复,原因需要人看(选择里有未知项 / 修复出错)
    #   3  执行了,但有项失败
    $fixRc = 0
    try {
        $cliRes = Invoke-RepairCli -Select $Fix -EnspDir $EnspDir -VBoxDir $VBoxDir `
                                   -AssumeYes $Yes.IsPresent -PlanOnly $DryRun.IsPresent
        if ($cliRes) {
            if ($cliRes.Refused) { $fixRc = 2 }
            elseif ($cliRes.Failed -gt 0) { $fixRc = 3 }
        }
    } catch {
        Write-Host ""
        Write-Host ("[提示] 修复出错,已中止(报告已写好,不受影响): " + $_.Exception.Message)
        $fixRc = 2
    }

    if ($repairTranscript) { try { Stop-Transcript | Out-Null } catch { } }
    if ($repairLog -and (Test-Path $repairLog)) {
        Write-Host ("  修复过程记录: " + $repairLog)
    }
    exit $fixRc
} else {
    # 不带 -Fix 时到此为止,一个键都不读。指一句下一步就够 ——
    # 该修什么、怎么修,报告第 [9] 节已经逐条写清楚了。
    Write-Host ""
    Write-Host "  需要执行修复:重跑 环境检查.bat -Fix(逐条见报告第 [9] 节)。"
}
