<#
.SYNOPSIS
    ensp-vbox-shim 一键安装器 —— 让原版华为 eNSP 跑在 VirtualBox 7.x 上。

.DESCRIPTION
    自动检测 eNSP / VirtualBox 安装位置,用预构建的垫片 DLL 和已补丁的
    插件 DLL 覆盖目标文件(备份原文件为 .orig.bak,可逆),写版本伪装与
    CLSID 注册表项。

    四座承重的桥(详见仓库 docs/):
      1. VBox52.dll        → 覆盖全部加载位置(tools/ vboxserver/ 根 ngfw/)
      2. 版本伪装           → 注册表 Oracle\VirtualBox Version=5.2.44
      3. CLSID InprocServer → 指向我们的 DLL(按真实路径生成)
      4. VAR_Plugin.dll     → 覆盖 payload 中预构建的已补丁版本

    用法(一般经 安装.bat / 卸载.bat 自动提权调用):
      powershell -ExecutionPolicy Bypass -File install.ps1            # 安装
      powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall # 卸载
      powershell -ExecutionPolicy Bypass -File install.ps1 -Check     # 只检测,不改动

    可选 -EnspDir / -VBoxDir 手动指定路径(自动检测失败时)。
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Check,
    [string]$EnspDir = "",
    [string]$VBoxDir = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
$CLSID_VBOX   = "{B1A7A4F2-47B9-4A1E-82B2-07CCD5323C3F}"  # CLSID_VirtualBox
$DLL_NAME     = "VBox52.dll"
$DLL_SHA256       = "4cbb1ace15f768291a6d3da4afcbf11201a4a630e738bd2c2d69fe68e8af3306"
$VARP_SHA256      = "f0107975ba1b04325af2d31189ee92833233c1163f4553600207789977f94451"

$SPOOF_VER    = "5.2.44"
$SPOOF_VEREXT = "5.2.44r139111"
$REAL_VER     = "7.2.8"
$REAL_VEREXT  = "7.2.8r173730"

# ---------------------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------------------
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "  [..] $msg" -ForegroundColor Gray }
function Write-Warn($msg) { Write-Host "  [!!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [XX] $msg" -ForegroundColor Red }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Err "需要管理员权限。请通过 安装.bat / 卸载.bat 运行(会自动提权)。"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 路径检测
# ---------------------------------------------------------------------------
function Find-EnspDir {
    param([string]$Override)
    if ($Override) {
        if (Test-Path (Join-Path $Override "tools")) { return $Override }
        Write-Err "指定的 eNSP 目录无效(缺 tools\): $Override"; exit 1
    }
    # 1) 卸载注册表项里找 DisplayName 含 eNSP 的
    $uninstRoots = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $uninstRoots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -like "*eNSP*" -and $p.InstallLocation) { $p.InstallLocation }
        } | Where-Object { $_ -and (Test-Path (Join-Path $_ "tools")) } | Select-Object -First 1
        if ($hit) { return $hit.TrimEnd('\') }
    }
    # 2) 默认安装位置回退
    $defaults = @(
        (Join-Path ${env:ProgramFiles(x86)} "Huawei\eNSP"),
        (Join-Path $env:ProgramFiles        "Huawei\eNSP")
    )
    foreach ($d in $defaults) {
        if ($d -and (Test-Path (Join-Path $d "tools"))) { return $d.TrimEnd('\') }
    }
    return $null
}

function Find-VBoxDir {
    param([string]$Override)
    if ($Override) {
        if (Test-Path (Join-Path $Override "VBoxSVC.exe")) { return $Override }
        Write-Warn "指定的 VirtualBox 目录缺 VBoxSVC.exe: $Override"
        return $Override.TrimEnd('\')
    }
    # InstallDir 注册表项(版本伪装只改 Version,InstallDir 保留真实值)
    $keys = @(
        "HKLM:\SOFTWARE\Oracle\VirtualBox",
        "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox"
    )
    foreach ($k in $keys) {
        if (-not (Test-Path $k)) { continue }
        $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if ($p.InstallDir -and (Test-Path $p.InstallDir)) { return $p.InstallDir.TrimEnd('\') }
    }
    $def = Join-Path $env:ProgramFiles "Oracle\VirtualBox"
    if (Test-Path $def) { return $def.TrimEnd('\') }
    return $null
}

# ---------------------------------------------------------------------------
# 文件部署辅助 —— 用 payload 中预构建好的 DLL 直接覆盖(不字节补丁)
# ---------------------------------------------------------------------------
function Deploy-PayloadFile($PayloadName, $DestPath, $ExpectedHash) {
    $src = Join-Path $ScriptDir "payload\$PayloadName"
    if (-not (Test-Path $src)) { Write-Err "整合包损坏:缺 payload\$PayloadName"; exit 1 }
    $got = (Get-FileHash $src -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $ExpectedHash.ToLower()) {
        Write-Err "payload\$PayloadName 哈希不符,整合包可能被篡改。"
        Write-Info "期望 $ExpectedHash"
        Write-Info "实际 $got"
        exit 1
    }
    $destDir = Split-Path $DestPath -Parent
    if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
    if (Test-Path $DestPath) {
        $destHash = (Get-FileHash $DestPath -Algorithm SHA256).Hash.ToLower()
        if ($destHash -eq $ExpectedHash.ToLower()) { Write-OK "已是最新版,跳过: $(Split-Path $DestPath -Leaf)"; return }
        $bak = "$DestPath.orig.bak"
        if (-not (Test-Path $bak)) { Copy-Item $DestPath $bak; Write-Info "原文件已备份 -> $(Split-Path $bak -Leaf)" }
    }
    Copy-Item $src $DestPath -Force
    Write-OK "已部署 -> $DestPath"
}

function Restore-FromBak($DestPath) {
    if (Test-Path $DestPath) { Remove-Item $DestPath -Force }
    $bak = "$DestPath.orig.bak"
    if (Test-Path $bak) { Copy-Item $bak $DestPath; Write-OK "已还原: $(Split-Path $DestPath -Leaf)" }
    else { Write-Info "无备份,跳过: $(Split-Path $DestPath -Leaf)" }
}

# ---------------------------------------------------------------------------
# 注册表写入辅助(两个视图)
# ---------------------------------------------------------------------------
function Set-RegValue($Path, $Name, $Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    if ($Name -eq "") {
        New-ItemProperty -Path $Path -Name "(default)" -Value $Value -PropertyType String -Force | Out-Null
    } else {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
function Do-Install {
    param([string]$EnspDir, [string]$VBoxDir)

    Write-Step "1/4 部署 VBox52.dll 垫片(覆盖全部加载位置)"
    $vboxDirs = @(
        (Join-Path $EnspDir "tools"),
        (Join-Path $EnspDir "vboxserver"),
        $EnspDir,
        (Join-Path $EnspDir "plugin\ngfw\tools\ngfw")
    )
    foreach ($dir in $vboxDirs) {
        Deploy-PayloadFile $DLL_NAME (Join-Path $dir $DLL_NAME) $DLL_SHA256
    }

    Write-Step "2/4 写入版本伪装(注册表 $SPOOF_VER)"
    Set-RegValue "HKLM:\SOFTWARE\Oracle\VirtualBox"            "Version"    $SPOOF_VER
    Set-RegValue "HKLM:\SOFTWARE\Oracle\VirtualBox"            "VersionExt" $SPOOF_VEREXT
    Set-RegValue "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" "Version"    $SPOOF_VER
    Set-RegValue "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" "VersionExt" $SPOOF_VEREXT
    Write-OK "Version=$SPOOF_VER(64 位 + 32 位视图)"

    Write-Step "3/4 劫持 CLSID InprocServer32 -> 我们的 DLL"
    # 关键:路径按检测到的真实 eNSP 位置动态生成,不写死
    $base64 = "HKLM:\SOFTWARE\Classes\CLSID\$CLSID_VBOX\InprocServer32"
    $base32 = "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$CLSID_VBOX\InprocServer32"
    foreach ($k in @($base64, $base32)) {
        Set-RegValue $k ""                $destDll
        Set-RegValue $k "ThreadingModel"  "Both"
    }
    Write-OK "InprocServer32 -> $destDll"

    Write-Step "4/4 部署 AR 路由器插件(预构建 VAR_Plugin.dll)"
    $varp = Join-Path $EnspDir "plugin\ar1000v\VAR_Plugin.dll"
    Deploy-PayloadFile "VAR_Plugin.dll" $varp $VARP_SHA256

    Write-Host "`n============================================================" -ForegroundColor Green
    Write-Host "  安装完成。启动 eNSP,拉起一台设备试试。" -ForegroundColor Green
    Write-Host "  要还原:双击 卸载.bat。" -ForegroundColor Green
    Write-Host "============================================================`n" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
function Do-Uninstall {
    param([string]$EnspDir, [string]$VBoxDir)

    Write-Step "1/4 还原版本字符串 -> $REAL_VER"
    Set-RegValue "HKLM:\SOFTWARE\Oracle\VirtualBox"            "Version"    $REAL_VER
    Set-RegValue "HKLM:\SOFTWARE\Oracle\VirtualBox"            "VersionExt" $REAL_VEREXT
    Set-RegValue "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" "Version"    $REAL_VER
    Set-RegValue "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" "VersionExt" $REAL_VEREXT
    Write-OK "Version=$REAL_VER"

    Write-Step "2/4 还原 AR 插件 VAR_Plugin.dll"
    $varp = Join-Path $EnspDir "plugin\ar1000v\VAR_Plugin.dll"
    Restore-FromBak $varp

    Write-Step "3/4 还原所有位置的 VBox52.dll"
    $vboxDirs = @(
        (Join-Path $EnspDir "tools"),
        (Join-Path $EnspDir "vboxserver"),
        $EnspDir,
        (Join-Path $EnspDir "plugin\ngfw\tools\ngfw")
    )
    foreach ($dir in $vboxDirs) {
        Restore-FromBak (Join-Path $dir $DLL_NAME)
    }

    Write-Step "4/4 CLSID InprocServer32(需手动)"
    Write-Warn "CLSID 劫持指向的正确原始值随 VBox 构建而异,本脚本不擅自改写。"
    Write-Warn "请对 VirtualBox 7.2 跑一次【修复】(应用和功能 → VirtualBox → 修改/修复),"
    Write-Warn "它会把 $CLSID_VBOX 改回 Oracle 原生 proxy/stub。"

    Write-Host "`n卸载流程完成(CLSID 项请按上面提示跑 VBox 修复)。`n" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 检测(只读,不改动)
# ---------------------------------------------------------------------------
function Do-Check {
    param([string]$EnspDir, [string]$VBoxDir)

    Write-Step "环境检测(只读)"
    Write-Info "eNSP    : $EnspDir"
    Write-Info "VBox    : $VBoxDir"

    Write-Info "VBox52.dll 部署状态(4 个加载位置):"
    $vboxDirs = @(
        (Join-Path $EnspDir "tools"),
        (Join-Path $EnspDir "vboxserver"),
        $EnspDir,
        (Join-Path $EnspDir "plugin\ngfw\tools\ngfw")
    )
    foreach ($dir in $vboxDirs) {
        $dll = Join-Path $dir $DLL_NAME
        $rel = $dll.Substring($EnspDir.Length + 1)
        if (Test-Path $dll) {
            $h = (Get-FileHash $dll -Algorithm SHA256).Hash.ToLower()
            $tag = if ($h -eq $DLL_SHA256.ToLower()) { "我们的垫片 ✓" } else { "存在但哈希不同" }
        } else { $tag = "未部署" }
        Write-Info "  $rel : $tag"
    }

    $vk = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" -ErrorAction SilentlyContinue
    if ($vk) { Write-Info "注册表 Version : $($vk.Version)  (伪装目标 $SPOOF_VER)" }

    $clsid = Get-ItemProperty "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$CLSID_VBOX\InprocServer32" -ErrorAction SilentlyContinue
    if ($clsid) { Write-Info "CLSID InprocServer32 : $($clsid.'(default)')" }

    $varp = Join-Path $EnspDir "plugin\ar1000v\VAR_Plugin.dll"
    if (Test-Path $varp) {
        $h = (Get-FileHash $varp -Algorithm SHA256).Hash.ToLower()
        $tag = if ($h -eq $VARP_SHA256.ToLower()) { "已补丁 ✓" }
               elseif ($h -eq "5ae6817a9f2f05cfbb5f1f89af910007c22988c22bc02fdf2c44a67a9ff26eb5") { "出厂版(需补丁)" }
               else { "非标准版本(哈希不同)" }
        Write-Info "VAR_Plugin.dll : $tag"
    } else { Write-Info "VAR_Plugin.dll : 未找到(没装 AR 包)" }
}

# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------
Assert-Admin

$ensp = Find-EnspDir -Override $EnspDir
if (-not $ensp) {
    Write-Err "未能自动定位 eNSP 安装目录。请用 -EnspDir 手动指定,例如:"
    Write-Err '  install.ps1 -EnspDir "D:\Program Files\Huawei\eNSP"'
    exit 1
}
$vbox = Find-VBoxDir -Override $VBoxDir
if (-not $vbox) { Write-Warn "未能定位 VirtualBox 目录(版本伪装仍会写注册表)。" }

Write-Host "eNSP : $ensp"
Write-Host "VBox : $vbox"

if ($Check)         { Do-Check     -EnspDir $ensp -VBoxDir $vbox }
elseif ($Uninstall) { Do-Uninstall -EnspDir $ensp -VBoxDir $vbox }
else                { Do-Install   -EnspDir $ensp -VBoxDir $vbox }
