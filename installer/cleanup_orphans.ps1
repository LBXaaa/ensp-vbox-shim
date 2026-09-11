# cleanup_orphans.ps1 — 清理 eNSP 退出后残留的 VirtualBox 后台进程
#
# 背景(2026-09-12 实测):关闭 eNSP 时,它会为每台设备补发
# `VBoxManage controlvm <vm> poweroff`。SVRP 那几台(CE / CX / NE40E /
# NE5000E / NE9000,都是 Linux 客户机)在硬断电收尾时:
#   - 退出极慢,实测要 5 分钟以上才陆续走完
#   - 个别进程会在收尾时访问空指针崩溃(0x...24 该内存不能为 read),
#     弹出「应用程序错误」框,不点掉就一直挂着不放内存
# 每台 VBoxHeadless 约占 0.4-1.5 GB。
#
# *** 安全边界 ***
# 本脚本**只处理 eNSP 自己的虚拟机**。判据是 VM 的配置文件(CfgFile)位于:
#   - eNSP 安装目录之下(如 <eNSP>\VBoxServer\... 与 <eNSP>\plugin\...\...)
#   - %LOCALAPPDATA%\eNSP 之下(eNSP 为每台设备创建的克隆)
# **用户自己的其他虚拟机一律跳过**,无论 eNSP 是否在运行。
# 无法确定归属的一律跳过 —— 宁可漏清,不可误杀。
#
# 清理范围还取决于 eNSP 是否在运行:
#   eNSP 在跑  -> 只清"VirtualBox 账本上已不在运行"的孤儿(正常使用的设备不动)
#   eNSP 已关  -> eNSP 的设备全部算残留,列出后确认即结束

param(
    [switch]$Force   # 跳过交互确认(供批处理自动调用)
)

$ErrorActionPreference = "Continue"

function Find-VBoxManage {
    foreach ($k in @("HKLM:\SOFTWARE\Oracle\VirtualBox", "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox")) {
        $d = (Get-ItemProperty $k -ErrorAction SilentlyContinue).InstallDir
        if ($d) {
            $p = Join-Path $d "VBoxManage.exe"
            if (Test-Path $p) { return $p }
        }
    }
    foreach ($p in @("C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
                     "C:\Program Files (x86)\Oracle\VirtualBox\VBoxManage.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Find-EnspDir {
    $keys = @("HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
              "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")
    # 注意:必须用 foreach 而非 ForEach-Object 管道 —— 管道里的 return 只退出脚本块,
    # 函数会继续跑,结果被重复追加(eNSP 目录曾因此出现两次)。
    foreach ($k in $keys) {
        foreach ($it in (Get-ChildItem $k -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $it.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -like "*eNSP*" -and $p.InstallLocation) {
                if (Test-Path (Join-Path $p.InstallLocation "tools")) { return $p.InstallLocation.TrimEnd('\') }
            }
        }
    }
    foreach ($p in @("C:\Program Files\Huawei\eNSP", "C:\Program Files (x86)\Huawei\eNSP")) {
        if (Test-Path (Join-Path $p "tools")) { return $p }
    }
    return $null
}

$vbox = Find-VBoxManage
if (-not $vbox) { Write-Host "[!] 找不到 VBoxManage.exe。" -ForegroundColor Red; exit 1 }
Write-Host "VBoxManage: $vbox"

$enspDir = Find-EnspDir
if (-not $enspDir) { Write-Host "[!] 找不到 eNSP 安装目录,无法判定归属,已中止。" -ForegroundColor Red; exit 1 }
Write-Host "eNSP 目录 : $enspDir"

# eNSP 的虚拟机只可能落在这两处之下
$enspRoots = @($enspDir, (Join-Path $env:LOCALAPPDATA "eNSP")) |
             Where-Object { $_ -and $_.Trim() } |
             ForEach-Object { $_.TrimEnd('\').ToLower() }
Write-Host ("归属范围  : {0}" -f ($enspRoots -join "  |  "))

# ---- eNSP 是否在运行 ----
$enspRunning = [bool](Get-Process eNSP_Client, eNSP_VBoxServer -ErrorAction SilentlyContinue)
if ($enspRunning) {
    Write-Host "eNSP 正在运行 —— 只清理孤儿进程,正在使用的设备不会被动。" -ForegroundColor Cyan
} else {
    Write-Host "eNSP 未运行 —— eNSP 的设备都算残留,待确认后结束。" -ForegroundColor Cyan
}

# ---- 账本上正在运行的 VM ----
$running = @()
foreach ($line in (& $vbox list runningvms 2>&1)) {
    if ($line -match '\{([0-9a-fA-F-]{36})\}') { $running += $matches[1].ToLower() }
}
Write-Host ("VirtualBox 账本上正在运行: {0} 台" -f $running.Count)

# ---- UUID -> VM 名 / CfgFile ----
$nameOf = @{}
$cfgOf  = @{}
foreach ($line in (& $vbox list vms 2>&1)) {
    if ($line -match '"([^"]+)"\s+\{([0-9a-fA-F-]{36})\}') {
        $nameOf[$matches[2].ToLower()] = $matches[1]
    }
}
foreach ($n in $nameOf.Values) {
    $cfg = (& $vbox showvminfo $n --machinereadable 2>$null |
            Where-Object { $_ -like 'CfgFile=*' } | Select-Object -First 1)
    if ($cfg) { $cfgOf[$n] = ($cfg -replace '^CfgFile="', '' -replace '"$', '') }
}

function Test-IsEnspVm([string]$vmName) {
    if (-not $vmName) { return $false }
    $cfg = $cfgOf[$vmName]
    if (-not $cfg) { return $false }          # 查不到归属 -> 当作不属于 eNSP
    $lc = $cfg.Replace('\\', '\').ToLower()
    foreach ($r in $enspRoots) { if ($lc.StartsWith($r)) { return $true } }
    return $false
}

# ---- 扫描 VBoxHeadless ----
$procs = Get-CimInstance Win32_Process -Filter "Name='VBoxHeadless.exe'" -ErrorAction SilentlyContinue
if (-not $procs) { Write-Host ""; Write-Host "没有 VBoxHeadless 进程,无需清理。" -ForegroundColor Green; exit 0 }

$targets = @(); $foreign = @(); $inuse = @()
foreach ($p in $procs) {
    $uuid = $null
    if ($p.CommandLine -match '--startvm\s+([0-9a-fA-F-]{36})') { $uuid = $matches[1].ToLower() }
    $vm  = if ($uuid) { $nameOf[$uuid] } else { $null }
    $ws  = [int]((Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue).WorkingSet64 / 1MB)
    $row = [PSCustomObject]@{ PID = $p.ProcessId; VM = $(if ($vm) { $vm } else { "(无法识别)" }); MB = $ws }

    if (-not (Test-IsEnspVm $vm)) {
        $foreign += $row                       # 用户自己的虚拟机 / 无法识别 -> 绝不碰
    } elseif ($enspRunning -and $uuid -and ($running -contains $uuid)) {
        $inuse += $row                         # eNSP 在跑且设备正被使用
    } else {
        $targets += $row
    }
}

Write-Host ""
if ($foreign.Count -gt 0) {
    Write-Host "不属于 eNSP、不会被碰的进程:" -ForegroundColor Green
    $foreign | Format-Table -AutoSize | Out-String | Write-Host
}
if ($inuse.Count -gt 0) {
    Write-Host "正在正常使用、不会被碰的 eNSP 设备:" -ForegroundColor Green
    $inuse | Format-Table -AutoSize | Out-String | Write-Host
}
if ($targets.Count -eq 0) {
    Write-Host "没有需要清理的 eNSP 残留进程。" -ForegroundColor Green
    exit 0
}

$totalMB = ($targets | Measure-Object MB -Sum).Sum
Write-Host ("待清理 {0} 个 eNSP 残留进程,共占约 {1:N0} MB:" -f $targets.Count, $totalMB) -ForegroundColor Yellow
$targets | Format-Table -AutoSize | Out-String | Write-Host

if (-not $Force) {
    Write-Host "是否强制结束这些进程? (Y/N) " -NoNewline
    $ans = Read-Host
    if ($ans -notmatch '^[Yy]') { Write-Host "已取消。"; exit 0 }
}

$killed = 0
foreach ($o in $targets) {
    try {
        Stop-Process -Id $o.PID -Force -ErrorAction Stop
        Write-Host ("  已结束 PID {0}  ({1})" -f $o.PID, $o.VM) -ForegroundColor Green
        $killed++
    } catch {
        Write-Host ("  结束 PID {0} 失败: {1}" -f $o.PID, $_.Exception.Message) -ForegroundColor Red
    }
}

Start-Sleep -Seconds 2
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ""
Write-Host ("已结束 {0} / {1} 个进程,当前可用内存 {2:N1} GB" -f $killed, $targets.Count, ($os.FreePhysicalMemory / 1MB)) -ForegroundColor Green
