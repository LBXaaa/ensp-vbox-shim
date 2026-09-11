# cleanup_orphans.ps1 — 清理 eNSP / VirtualBox 遗留的孤儿 VBoxHeadless 进程
#
# 背景(2026-09-12 实测):关闭 eNSP 时,它会为每台设备补发
# `VBoxManage controlvm <vm> poweroff`。SVRP 那几台(CE / CX / NE40E /
# NE5000E / NE9000,都是 Linux 客户机)在硬断电收尾时:
#   - 退出极慢,实测要 5 分钟以上才陆续走完
#   - 个别进程会在收尾时访问空指针崩溃(0x...24 该内存不能为 read),
#     弹出「应用程序错误」框,不点掉就一直挂着不放内存
# 每台 VBoxHeadless 约占 1.2-1.5 GB,五台就是 6-7 GB。
#
# 本脚本只杀「孤儿」:进程还在,但它所跑的 VM 已经不在
# `VBoxManage list runningvms` 里 —— 也就是 VirtualBox 账本上已经结束、
# 进程却没退干净的。正在正常运行的 VM 不会被碰。
#
# 实测正常退完后 runningvms 会变空、VBoxHeadless 也会自己消失,
# 所以这个脚本是兜底,不是常规步骤。

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

$vbox = Find-VBoxManage
if (-not $vbox) { Write-Host "[!] 找不到 VBoxManage.exe,无法判断哪些进程是孤儿。" -ForegroundColor Red; exit 1 }

Write-Host "VBoxManage: $vbox"

# ---- eNSP 还在跑就先提醒 ----
$ensp = Get-Process eNSP_Client, eNSP_VBoxServer -ErrorAction SilentlyContinue
if ($ensp) {
    Write-Host ""
    Write-Host "[!] eNSP 仍在运行。请先关闭 eNSP 再清理," -ForegroundColor Yellow
    Write-Host "    否则正在启动/运行的设备可能被误判。" -ForegroundColor Yellow
    if (-not $Force) { Write-Host "    按回车继续,或 Ctrl+C 退出..."; [void](Read-Host) }
}

# ---- 取 VirtualBox 账本上正在运行的 VM ----
$running = @()
$out = & $vbox list runningvms 2>&1
foreach ($line in $out) {
    if ($line -match '\{([0-9a-fA-F-]{36})\}') { $running += $matches[1].ToLower() }
}
Write-Host ("VirtualBox 账本上正在运行: {0} 台" -f $running.Count)

# ---- 找 VBoxHeadless 进程,按 --startvm 的 UUID 判断是否为孤儿 ----
$procs = Get-CimInstance Win32_Process -Filter "Name='VBoxHeadless.exe'" -ErrorAction SilentlyContinue
if (-not $procs) { Write-Host ""; Write-Host "没有 VBoxHeadless 进程,无需清理。" -ForegroundColor Green; exit 0 }

$orphans = @()
$alive   = @()
foreach ($p in $procs) {
    $uuid = $null
    if ($p.CommandLine -match '--startvm\s+([0-9a-fA-F-]{36})') { $uuid = $matches[1].ToLower() }
    $ws = [int]((Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue).WorkingSet64 / 1MB)
    if ($uuid -and ($running -contains $uuid)) {
        $alive += [PSCustomObject]@{ PID = $p.ProcessId; VM = $uuid; MB = $ws }
    } else {
        $orphans += [PSCustomObject]@{ PID = $p.ProcessId; VM = $(if ($uuid) { $uuid } else { "(未知)" }); MB = $ws }
    }
}

Write-Host ""
if ($alive.Count -gt 0) {
    Write-Host "正在正常运行、不会被动:" -ForegroundColor Green
    $alive | Format-Table -AutoSize | Out-String | Write-Host
}
if ($orphans.Count -eq 0) {
    Write-Host "没有发现孤儿进程。" -ForegroundColor Green
    exit 0
}

$totalMB = ($orphans | Measure-Object MB -Sum).Sum
Write-Host ("发现 {0} 个孤儿进程,共占约 {1:N0} MB:" -f $orphans.Count, $totalMB) -ForegroundColor Yellow
$orphans | Format-Table -AutoSize | Out-String | Write-Host

if (-not $Force) {
    Write-Host "是否强制结束这些进程? (Y/N) " -NoNewline
    $ans = Read-Host
    if ($ans -notmatch '^[Yy]') { Write-Host "已取消。"; exit 0 }
}

$killed = 0
foreach ($o in $orphans) {
    try {
        Stop-Process -Id $o.PID -Force -ErrorAction Stop
        Write-Host ("  已结束 PID {0}" -f $o.PID) -ForegroundColor Green
        $killed++
    } catch {
        Write-Host ("  结束 PID {0} 失败: {1}" -f $o.PID, $_.Exception.Message) -ForegroundColor Red
    }
}

Start-Sleep -Seconds 2
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ""
Write-Host ("已结束 {0} / {1} 个进程,当前可用内存 {2:N1} GB" -f $killed, $orphans.Count, ($os.FreePhysicalMemory / 1MB)) -ForegroundColor Green
