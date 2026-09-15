# diag.ps1 -- eNSP x VirtualBox 环境诊断(只读)
#
# 分工:checks.ps1 只探测事实(纯只读、返回对象、不打印),
#       本文件负责判断与展示,并把全部输出落一份报告。
#
# 编码:本文件面向用户、含中文字面量,必须存为 UTF-8 带 BOM。
#       PowerShell 5.1 只对无 BOM 的文件按 ANSI 解码,无 BOM 时中文会乱码。
#
# 只读约定:
#   - 全程不启动任何虚拟机、不修改任何系统设置。
#   - 绝不 dot-source install.ps1 —— 该文件有顶层副作用,一旦被 source 就会真的跑安装。
#   - 读 install.ps1 只按文本读(取 $DLL_SHA256 常量),不执行。
#
# 降级约定:每个探测都可能失败(缺 VBox、缺 eNSP、权限不足)。
#           任何探测失败都不许中断整轮诊断 —— 诊断跑到一半死掉,
#           比只报出部分事实更糟。每节都包 try/catch,失败就地把原因打出来。

param(
    [string]$EnspDir = "",
    [string]$VBoxDir = "",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ChecksPath = Join-Path $ScriptDir "checks.ps1"
if (-not (Test-Path $ChecksPath)) {
    Write-Host ("找不到 " + $ChecksPath + " —— 诊断脚本不完整,请重新解压整合包。")
    exit 1
}
. $ChecksPath

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
function Write-Fail {
    param([string]$Where, [string]$Message)
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

# ---------------------------------------------------------------------------
# 路径定位(只读)
#
# install.ps1 里有同名函数,但那份带 exit、且文件本身有顶层副作用,不可 dot-source。
# 这里只做只读定位,找不到就返回空串,交给各节降级。
# TODO(Task 9): 按计划把查找函数下沉到 checks.ps1,届时本处改为调用。
# ---------------------------------------------------------------------------
function Resolve-EnspDirReadOnly {
    param([string]$Override)
    if ($Override) { return $Override.TrimEnd('\') }

    $roots = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $roots) {
        try {
            if (-not (Test-Path $root)) { continue }
            $hit = Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($p.DisplayName -like "*eNSP*" -and $p.InstallLocation) { $p.InstallLocation }
            } | Where-Object { $_ -and (Test-Path (Join-Path $_ "tools")) } | Select-Object -First 1
            if ($hit) { return $hit.TrimEnd('\') }
        } catch { }
    }

    try {
        $defaults = @(
            (Join-Path ${env:ProgramFiles(x86)} "Huawei\eNSP"),
            (Join-Path $env:ProgramFiles        "Huawei\eNSP")
        )
        foreach ($d in $defaults) {
            if ($d -and (Test-Path (Join-Path $d "tools"))) { return $d.TrimEnd('\') }
        }
    } catch { }
    return ""
}

function Resolve-VBoxDirReadOnly {
    param([string]$Override)
    if ($Override) { return $Override.TrimEnd('\') }

    foreach ($k in @("HKLM:\SOFTWARE\Oracle\VirtualBox", "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox")) {
        try {
            if (-not (Test-Path $k)) { continue }
            $d = (Get-ItemProperty $k -ErrorAction SilentlyContinue).InstallDir
            if ($d -and (Test-Path $d)) { return $d.TrimEnd('\') }
        } catch { }
    }
    try {
        $def = Join-Path $env:ProgramFiles "Oracle\VirtualBox"
        if (Test-Path $def) { return $def.TrimEnd('\') }
    } catch { }
    return ""
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

$EnspDir = Resolve-EnspDirReadOnly -Override $EnspDir
$VBoxDir = Resolve-VBoxDirReadOnly -Override $VBoxDir

# ===========================================================================
# 第 1 节  基础事实
# ===========================================================================
Write-Section "[1] 基础事实"

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
            Write-Fact "VBox 版本" ($v + "   <- " + $k)
            $vboxVerSeen = $true
        }
    } catch {
        Write-Fail ("VBox 版本 " + $k) $_.Exception.Message
    }
}
if (-not $vboxVerSeen) {
    Write-Fact "VBox 版本" "(两个注册表键都没有 Version)"
}
Write-Note "注意: 装有本垫片时该值被改写为 5.2.x(伪装给 eNSP 看),"
Write-Note "      不一定等于真实 VBox 版本;真实版本用 VBoxManage --version 查看。"

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

# 探测表在本文件里自己拼。不用 checks.ps1 的 Get-DeviceBackendProbe:
# 那个函数依赖 Find-EnspDir,而查找函数尚未下沉到 checks.ps1。
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

# ===========================================================================
# 第 3 节  host-only 网络(六层)
# ===========================================================================
Write-Section "[3] host-only 网络(六层)"

$vboxManageExe = ""
$vboxDrvInstExe = ""
if ($VBoxDir) {
    $vboxManageExe = Join-Path $VBoxDir "VBoxManage.exe"
    $vboxDrvInstExe = Join-Path $VBoxDir "VBoxDrvInst.exe"
} else {
    Write-Note "[提示] 未定位到 VBox 目录,VBoxManage / VBoxDrvInst 都取不到。请用 -VBoxDir 指定。"
}

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

# ===========================================================================
# TODO(Task 7b): 其余分层在本行之后追加 ——
#   - eNSP 本体层:性能计数器 / 防火墙放行 eNSP_VBoxServer / 端口 54012-54014
#   - AR_Base 模板层:VRAMSize、模板路径、注册与快照
#   - eNSP 版本 x 已装设备包
#   - 192.168.56.x 归属冲突 / 网卡属性 / 抓包驱动(WinPcap vs Npcap)
#   - 日志尾部采集(install.log、vbox52_proxy.log、vboxmanage_wrapper.log、
#     VBoxSVC.log、<eNSP>\vboxserver\log\VBoxManage.log)
#   采集时只取当前文件并截断尾部 —— ensp-vbox-shim\ 下有数十个历史 .bak_*,不可全量打包。
# ===========================================================================

Write-Host ""
Write-Host ("=" * 64)
Write-Host "  本次诊断到此结束(第 1-3 节)。"
Write-Host ("  报告文件: " + $ReportPath)
Write-Host ("=" * 64)

if ($transcriptOn) {
    try { Stop-Transcript | Out-Null } catch { }
}
