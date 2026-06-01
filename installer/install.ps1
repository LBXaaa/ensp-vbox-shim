<#
.SYNOPSIS
    ensp-vbox-shim 一键安装器 —— 让原版华为 eNSP 跑在 VirtualBox 7.x 上。

.DESCRIPTION
    自动检测 eNSP / VirtualBox 安装位置,部署 COM/vtable 垫片 VBox52.dll,
    写入版本伪装与 CLSID 注册表项(按检测到的真实路径动态生成),并对 AR
    路由器插件 VAR_Plugin.dll 施加可逆字节补丁。

    四座承重的桥(详见仓库 docs/):
      1. VBox52.dll        → eNSP\tools\
      2. 版本伪装           → 注册表 Oracle\VirtualBox Version=5.2.44
      3. CLSID InprocServer → 指向我们的 DLL(按真实路径生成)
      4. VAR_Plugin.dll     → 28 站点 vtable 偏移重映射(可逆)

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
$DLL_SHA256   = "0cfc86524b21d981b244b0026f7525e5312e79a9007f7e092fe198d6702ce8cc"

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
# VAR_Plugin.dll 字节补丁(复刻 patches/patch_var_plugin.py,逐字节等价)
# ---------------------------------------------------------------------------
$VARP_SIZE     = 393216
$VARP_PRISTINE = "5ae6817a9f2f05cfbb5f1f89af910007c22988c22bc02fdf2c44a67a9ff26eb5"
$VARP_PATCHED  = "f0107975ba1b04325af2d31189ee92833233c1163f4553600207789977f94451"

# 每项: @(file_offset, pristine_byte, patched_byte, method)
# disp/4 == vtable 槽位。checkFirmwarePresent 是唯一跨 0xFF 的双字节(0x00D0->0x0118)。
$VARP_TABLE = @(
    @(0x0168C8, 0x9C, 0xD8, "getExtraData"),
    @(0x0168DD, 0x9C, 0xD8, "getExtraData"),
    @(0x0172BA, 0xB4, 0xBC, "openMedium"),
    @(0x01754C, 0x88, 0xCC, "createSharedFolder"),
    @(0x0177DC, 0xB0, 0x9C, "openMachine"),
    @(0x017F03, 0x88, 0xCC, "createSharedFolder"),
    @(0x01BF35, 0x9C, 0xD8, "getExtraData"),
    @(0x01ED4B, 0x8C, 0xB4, "createUnattendedInstaller"),
    @(0x01ED99, 0x90, 0xE8, "findDHCPServerByNetworkName"),
    @(0x01EDF3, 0x94, 0xA4, "findMachine"),
    @(0x01EE4D, 0x98, 0xF4, "findNATNetworkByName"),
    @(0x01EEA7, 0x9C, 0xD8, "getExtraData"),
    @(0x01EF01, 0xA0, 0xD4, "getExtraDataKeys"),
    @(0x01EF5B, 0xA4, 0xC0, "getGuestOSType"),
    @(0x01EFB5, 0xA8, 0xAC, "getMachineStates"),
    @(0x01F00F, 0xAC, 0xA8, "getMachinesByGroups"),
    @(0x01F06C, 0xB0, 0x9C, "openMachine"),
    @(0x01F0C6, 0xB4, 0xBC, "openMedium"),
    @(0x01F114, 0xB8, 0xA0, "registerMachine"),
    @(0x01F162, 0xBC, 0xEC, "removeDHCPServer"),
    @(0x01F1BC, 0xC0, 0xF8, "removeNATNetwork"),
    @(0x01F216, 0xC4, 0xD0, "removeSharedFolder"),
    @(0x01F279, 0xC8, 0xDC, "setExtraData"),
    @(0x01F2D6, 0xCC, 0xE0, "setSettingsSecret"),
    @(0x01F32A, 0xD0, 0x18, "checkFirmwarePresent"),
    @(0x01F32B, 0x00, 0x01, "checkFirmwarePresent"),
    @(0x01FE99, 0x90, 0xE8, "findDHCPServerByNetworkName"),
    @(0x0216F8, 0x94, 0xA4, "findMachine"),
    @(0x021FFA, 0x88, 0xCC, "createSharedFolder")
)

function Get-Sha256Hex([byte[]]$bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "" }
    finally { $sha.Dispose() }
}

function Classify-Varp([byte[]]$bytes) {
    $h = Get-Sha256Hex $bytes
    if ($h -eq $VARP_PRISTINE) { return "pristine" }
    if ($h -eq $VARP_PATCHED)  { return "patched" }
    return "unknown"
}

# 返回不匹配的站点数(column 1=pristine 字节, 2=patched 字节)
function Test-VarpSites([byte[]]$bytes, [int]$column) {
    $bad = 0
    foreach ($row in $VARP_TABLE) {
        $off = $row[0]; $expect = if ($column -eq 1) { $row[1] } else { $row[2] }
        if ($bytes[$off] -ne $expect) { $bad++ }
    }
    return $bad
}

# 施加或还原补丁。$Restore=$true 走 patched->pristine。返回 $true=成功/无需改动。
function Invoke-VarpPatch {
    param([string]$Path, [switch]$Restore, [switch]$Backup)

    if (-not (Test-Path $Path)) { Write-Err "找不到 VAR_Plugin.dll: $Path"; return $false }
    $data = [IO.File]::ReadAllBytes($Path)

    # 第 1 层:文件大小
    if ($data.Length -ne $VARP_SIZE) {
        Write-Err "大小 $($data.Length) != $VARP_SIZE,不是已知的 VAR_Plugin.dll。中止。"
        return $false
    }

    # 第 2 层:整文件哈希分类
    $state   = Classify-Varp $data
    $wantTo  = if ($Restore) { "pristine" } else { "patched" }
    $wantFrom= if ($Restore) { "patched" }  else { "pristine" }
    $fromCol = if ($Restore) { 2 } else { 1 }

    if ($state -eq $wantTo)   { Write-OK "VAR_Plugin.dll 已是 $wantTo,无需改动。"; return $true }
    if ($state -ne $wantFrom) {
        Write-Err "VAR_Plugin.dll 状态为 '$state',期望 '$wantFrom'。拒绝操作未知二进制。"
        return $false
    }

    # 第 3 层:逐字节验证(纵深防御,哈希已过仍逐字节核对)
    $bad = Test-VarpSites $data $fromCol
    if ($bad -gt 0) {
        Write-Err "$bad 个站点字节与预期不符,未写入即中止。"
        return $false
    }

    # 备份
    if ($Backup) {
        $bak = "$Path.bak"
        if (-not (Test-Path $bak)) { Copy-Item $Path $bak; Write-OK "已备份 -> $bak" }
        else { Write-Info "备份已存在 -> $bak(保留)" }
    }

    # 写入(内存中改字节)
    foreach ($row in $VARP_TABLE) {
        $off = $row[0]
        $data[$off] = if ($Restore) { [byte]$row[1] } else { [byte]$row[2] }
    }

    # 第 4 层:写盘前重新校验哈希
    $result = Classify-Varp $data
    if ($result -ne $wantTo) {
        Write-Err "改后哈希为 '$result',期望 '$wantTo'。不保存。"
        return $false
    }

    [IO.File]::WriteAllBytes($Path, $data)
    $verb = if ($Restore) { "还原" } else { "打补丁" }
    Write-OK "VAR_Plugin.dll 已$verb($($VARP_TABLE.Count) 字节)。"
    return $true
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

    Write-Step "1/4 部署 VBox52.dll 垫片"
    $payload = Join-Path $ScriptDir "payload\$DLL_NAME"
    if (-not (Test-Path $payload)) { Write-Err "整合包损坏:缺 payload\$DLL_NAME"; exit 1 }
    $got = (Get-FileHash $payload -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $DLL_SHA256) {
        Write-Err "payload\$DLL_NAME 哈希不符,整合包可能被篡改。"
        Write-Info "期望 $DLL_SHA256"
        Write-Info "实际 $got"
        exit 1
    }
    $toolsDir = Join-Path $EnspDir "tools"
    $destDll  = Join-Path $toolsDir $DLL_NAME
    if (Test-Path $destDll) {
        $bak = "$destDll.orig.bak"
        if (-not (Test-Path $bak)) { Copy-Item $destDll $bak; Write-Info "原 $DLL_NAME 已备份 -> $bak" }
    }
    Copy-Item $payload $destDll -Force
    Write-OK "已部署 -> $destDll"

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

    Write-Step "4/4 给 AR 路由器插件打补丁(VAR_Plugin.dll)"
    $varp = Join-Path $EnspDir "plugin\ar1000v\VAR_Plugin.dll"
    if (Test-Path $varp) {
        $ok = Invoke-VarpPatch -Path $varp -Backup
        if (-not $ok) { Write-Warn "AR 插件补丁未施加(见上)。AR 设备可能无法启动,但其它设备不受影响。" }
    } else {
        Write-Warn "未找到 ar1000v 插件,跳过(没装 AR 设备包则正常): $varp"
    }

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
    if (Test-Path $varp) {
        $ok = Invoke-VarpPatch -Path $varp -Restore -Backup
        if (-not $ok) { Write-Warn "自动还原未成功;可手动用同目录 .bak 覆盖回去。" }
    } else { Write-Info "无 ar1000v 插件,跳过。" }

    Write-Step "3/4 移除我们的 VBox52.dll"
    $destDll = Join-Path $EnspDir "tools\$DLL_NAME"
    if (Test-Path $destDll) {
        Remove-Item $destDll -Force
        Write-OK "已删除 $destDll"
        $orig = "$destDll.orig.bak"
        if (Test-Path $orig) { Copy-Item $orig $destDll; Write-Info "已还原原始 $DLL_NAME" }
    } else { Write-Info "$DLL_NAME 不在 tools\,跳过。" }

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

    $destDll = Join-Path $EnspDir "tools\$DLL_NAME"
    if (Test-Path $destDll) {
        $h = (Get-FileHash $destDll -Algorithm SHA256).Hash.ToLower()
        $tag = if ($h -eq $DLL_SHA256) { "我们的垫片 ✓" } else { "存在但哈希不同" }
        Write-Info "tools\$DLL_NAME : $tag"
    } else { Write-Info "tools\$DLL_NAME : 未部署" }

    $vk = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" -ErrorAction SilentlyContinue
    if ($vk) { Write-Info "注册表 Version : $($vk.Version)  (伪装目标 $SPOOF_VER)" }

    $clsid = Get-ItemProperty "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$CLSID_VBOX\InprocServer32" -ErrorAction SilentlyContinue
    if ($clsid) { Write-Info "CLSID InprocServer32 : $($clsid.'(default)')" }

    $varp = Join-Path $EnspDir "plugin\ar1000v\VAR_Plugin.dll"
    if (Test-Path $varp) {
        $data = [IO.File]::ReadAllBytes($varp)
        if ($data.Length -eq $VARP_SIZE) {
            Write-Info "VAR_Plugin.dll : $(Classify-Varp $data)"
        } else { Write-Info "VAR_Plugin.dll : 大小 $($data.Length)(非标准出厂版)" }
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
