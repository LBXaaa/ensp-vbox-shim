<#
.SYNOPSIS
    ensp-vbox-shim 一键安装器 —— 让原版华为 eNSP 跑在 VirtualBox 7.x 上。

.DESCRIPTION
    自动检测 eNSP / VirtualBox 安装位置,用预构建的垫片 DLL 和已补丁的
    插件 DLL 覆盖目标文件(备份原文件为 .orig.bak,可逆),写版本伪装与
    CLSID 注册表项。

    五座承重的桥(详见仓库 docs/):
      1. VBox52.dll        → 覆盖全部加载位置(tools/ vboxserver/ 根 ngfw/)
      2. 版本伪装           → 注册表 Oracle\VirtualBox Version=5.2.44
      3. CLSID InprocServer → 指向我们的 DLL(按真实路径生成)
      4. VAR_Plugin.dll     → 覆盖 payload 中预构建的已补丁版本
      5. VC++ 运行时(x86) → 部署到 VBox\x86\ 子目录(干净机缺它会 error 40 / 0x800700C1)

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
    [string]$VBoxDir = "",
    # 交互登录用户的 SID(由 install_all.ps1 传入)。eNSP 装在受保护的 Program Files,
    # 非提权运行的 VBoxHeadless 要往 vboxserver\<VM>\ 写日志/运行态,需要该账户对那棵树有
    # "修改"权限,否则建不出 Logs\ 目录 -> VERR_FILE_NOT_FOUND -> error 40。
    # 留空则回退授权给本地 Users 组(well-known SID S-1-5-32-545)。
    [string]$GrantSid = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
$CLSID_VBOX   = "{B1A7A4F2-47B9-4A1E-82B2-07CCD5323C3F}"  # CLSID_VirtualBox
$DLL_NAME     = "VBox52.dll"
$DLL_SHA256       = "73c89b3ee1efda481d7b1c57bc12f59a78b8c0ce9ae9067be67360d1dab7cb18"
$VARP_SHA256      = "f0107975ba1b04325af2d31189ee92833233c1163f4553600207789977f94451"

# VC++ 运行时(x86)—— error 40 / 0x800700C1 的修法。
# 32 位 eNSP 经 COM marshal IVirtualBox 时加载 x86\VBoxProxyStub-x86.dll,它(经 VBoxRT-x86.dll)
# 需要 x86 的 VCRUNTIME140.dll + MSVCP140.dll。干净机这俩都缺 → 加载器沿 PATH 抓到主目录的 x64 版
# → ERROR_BAD_EXE_FORMAT(0xC1)。必须放进 x86\ 子目录(DLL 搜索顺序第一步命中,不受 PATH 污染)。
# 已活验证:把这俩 x86 版放进 x86\ 后,LoadLibraryEx(proxystub) 从 err=193 翻成 OK。
# VCRUNTIME140_1.dll 非必需(proxystub 依赖树不含它)。
$VCRT_X86_FILES = @(
    @{ Name = "VCRUNTIME140.dll"; Hash = "87fc734e0f2884985514edace58cf649a8ad67cb058dc7b7a4068f77af86810a" },
    @{ Name = "MSVCP140.dll";     Hash = "546ee2af2ffff02a34dbc1139bc6eb0eb5d67d83b3be782cfead374d29c8e01e" }
)

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
# 授予登录用户对 vboxserver\ 树的"修改"权限
# eNSP 装在受保护的 Program Files。非提权 VBoxHeadless 要在 vboxserver\<VM>\ 下
# 建 Logs\ 并写日志/NVRAM/saved-state;无写权限时建目录静默失败 ->
# "Failed to open release log (VERR_FILE_NOT_FOUND)" -> PowerUp E_FAIL -> error 40。
# (OI)(CI) 继承,让将来 VBox 自建的子目录也自动可写。
# ---------------------------------------------------------------------------
function Resolve-GrantAccount([string]$Sid) {
    if ($Sid) {
        try { return (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value }
        catch { Write-Warn "传入的 SID 无法解析($Sid),回退授权给本地 Users 组。" }
    }
    # 回退:本地 Users 组(well-known SID,语言无关)
    return (New-Object Security.Principal.SecurityIdentifier("S-1-5-32-545")).Translate([Security.Principal.NTAccount]).Value
}

function Grant-VBoxServerWrite([string]$EnspDir, [string]$GrantSid) {
    $vbsrv = Join-Path $EnspDir "vboxserver"
    if (-not (Test-Path $vbsrv)) { Write-Warn "无 vboxserver\ 目录,跳过授权(未装设备包?)。"; return }
    $acct = Resolve-GrantAccount $GrantSid
    # icacls 比 Set-Acl 更稳、继承标记直观;/T 递归已存在项,继承标记管将来新建项
    $out = & icacls "$vbsrv" /grant "${acct}:(OI)(CI)M" /T /C /Q 2>&1
    if ($LASTEXITCODE -eq 0) { Write-OK "已授权 '$acct' 对 vboxserver\ 修改权限(含子目录继承)" }
    else { Write-Err "授权失败(icacls rc=$LASTEXITCODE):$out" }
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
    param([string]$EnspDir, [string]$VBoxDir, [string]$GrantSid = "")

    Write-Step "1/6 部署 VBox52.dll 垫片(覆盖全部加载位置)"
    $vboxDirs = @(
        (Join-Path $EnspDir "tools"),
        (Join-Path $EnspDir "vboxserver"),
        $EnspDir,
        (Join-Path $EnspDir "plugin\ngfw\tools\ngfw")
    )
    foreach ($dir in $vboxDirs) {
        Deploy-PayloadFile $DLL_NAME (Join-Path $dir $DLL_NAME) $DLL_SHA256
    }

    Write-Step "2/6 写入版本伪装(注册表 $SPOOF_VER)"
    Set-RegValue "HKLM:\SOFTWARE\Oracle\VirtualBox"            "Version"    $SPOOF_VER
    Set-RegValue "HKLM:\SOFTWARE\Oracle\VirtualBox"            "VersionExt" $SPOOF_VEREXT
    Set-RegValue "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" "Version"    $SPOOF_VER
    Set-RegValue "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" "VersionExt" $SPOOF_VEREXT
    Write-OK "Version=$SPOOF_VER(64 位 + 32 位视图)"

    Write-Step "3/6 劫持 CLSID InprocServer32 -> 我们的 DLL"
    # 关键:路径按检测到的真实 eNSP 位置动态生成,不写死
    # 指向 tools\ 下那一份(第 1 步必定已部署),COM 激活按此绝对路径加载
    $destDll = Join-Path $EnspDir "tools\$DLL_NAME"
    if (-not (Test-Path $destDll)) {
        Write-Err "CLSID 目标 DLL 不存在: $destDll(第 1 步部署可能失败)"; exit 1
    }
    $base64 = "HKLM:\SOFTWARE\Classes\CLSID\$CLSID_VBOX\InprocServer32"
    $base32 = "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$CLSID_VBOX\InprocServer32"
    foreach ($k in @($base64, $base32)) {
        Set-RegValue $k ""                $destDll
        Set-RegValue $k "ThreadingModel"  "Both"
    }
    Write-OK "InprocServer32 -> $destDll"

    Write-Step "4/6 部署 AR 路由器插件(预构建 VAR_Plugin.dll)"
    $varp = Join-Path $EnspDir "plugin\ar1000v\VAR_Plugin.dll"
    Deploy-PayloadFile "VAR_Plugin.dll" $varp $VARP_SHA256

    Write-Step "5/6 部署 x86 VC++ 运行时到 VBox\x86\ 子目录"
    if ($VBoxDir) {
        # proxystub-x86.dll(经 VBoxRT-x86.dll)需要 x86 VCRUNTIME140 + MSVCP140。
        # 放进 x86\ 子目录是 DLL 搜索顺序第一步,修 0x800700C1。
        # x86\ 是 VBox 7.x 自带的 32 位组件目录,正常安装必有;不在则跳过(疑似异常安装)。
        $x86sub = Join-Path $VBoxDir "x86"
        if (Test-Path $x86sub) {
            foreach ($f in $VCRT_X86_FILES) {
                Deploy-PayloadFile "msvcrt-x86\$($f.Name)" (Join-Path $x86sub $f.Name) $f.Hash
            }
            Write-OK "x86 运行时已就位(32 位 COM 激活不再 0x800700C1)"
        } else {
            Write-Warn "VBox\x86\ 子目录不存在,跳过 x86 运行时部署(VBox 安装异常?)。"
        }
    } else {
        Write-Warn "未定位 VirtualBox 目录,跳过 x86 运行时部署。"
        Write-Warn "若设备启动报 0x800700C1,手动把 payload\msvcrt-x86\*.dll"
        Write-Warn "复制到 VBoxSVC.exe 同目录的 x86\ 子目录。"
    }

    Write-Step "6/6 授予登录用户对 vboxserver\ 的写权限"
    # eNSP 装在 C:\Program Files 时,非提权的 VBoxHeadless 无法在
    # vboxserver\<VM>\Logs 下建目录/写日志 -> VERR_FILE_NOT_FOUND -> error 40。
    # 提权阶段一次性把整棵 vboxserver\ 树的修改权赋给登录用户(可继承)。
    Grant-VBoxServerWrite -EnspDir $EnspDir -GrantSid $GrantSid

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

    Write-Step "1/5 还原版本字符串 -> $REAL_VER"
    Set-RegValue "HKLM:\SOFTWARE\Oracle\VirtualBox"            "Version"    $REAL_VER
    Set-RegValue "HKLM:\SOFTWARE\Oracle\VirtualBox"            "VersionExt" $REAL_VEREXT
    Set-RegValue "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" "Version"    $REAL_VER
    Set-RegValue "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" "VersionExt" $REAL_VEREXT
    Write-OK "Version=$REAL_VER"

    Write-Step "2/5 还原 AR 插件 VAR_Plugin.dll"
    $varp = Join-Path $EnspDir "plugin\ar1000v\VAR_Plugin.dll"
    Restore-FromBak $varp

    Write-Step "3/5 还原所有位置的 VBox52.dll"
    $vboxDirs = @(
        (Join-Path $EnspDir "tools"),
        (Join-Path $EnspDir "vboxserver"),
        $EnspDir,
        (Join-Path $EnspDir "plugin\ngfw\tools\ngfw")
    )
    foreach ($dir in $vboxDirs) {
        Restore-FromBak (Join-Path $dir $DLL_NAME)
    }

    Write-Step "4/5 CLSID InprocServer32(需手动)"
    Write-Warn "CLSID 劫持指向的正确原始值随 VBox 构建而异,本脚本不擅自改写。"
    Write-Warn "请对 VirtualBox 7.2 跑一次【修复】(应用和功能 → VirtualBox → 修改/修复),"
    Write-Warn "它会把 $CLSID_VBOX 改回 Oracle 原生 proxy/stub。"

    Write-Step "5/5 还原 x86\ 子目录的 VC++ 运行时"
    if ($VBoxDir) {
        $x86sub = Join-Path $VBoxDir "x86"
        foreach ($f in $VCRT_X86_FILES) {
            Restore-FromBak (Join-Path $x86sub $f.Name)
        }
    } else {
        Write-Info "未定位 VirtualBox 目录,跳过 VC++ 运行时清理。"
    }

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

    if ($VBoxDir) {
        Write-Info "VC++ 运行时 x86(x86\ 子目录,修 0x800700C1):"
        $x86sub = Join-Path $VBoxDir "x86"
        foreach ($f in $VCRT_X86_FILES) {
            $dst = Join-Path $x86sub $f.Name
            if (Test-Path $dst) {
                $h = (Get-FileHash $dst -Algorithm SHA256).Hash.ToLower()
                $tag = if ($h -eq $f.Hash.ToLower()) { "已部署 ✓" } else { "存在(版本不同,亦可)" }
            } else { $tag = "缺失 ★(干净机会 error 40 / 0x800700C1)" }
            Write-Info "  x86\$($f.Name) : $tag"
        }
    }
}

# ---------------------------------------------------------------------------
# 环境快照(纯采集,不改动系统,绝不阻断部署)
# 聚焦 error 40 的三类已知根因:嵌套虚拟化抢 VT-x、x86 VCRT 缺失、版本伪装状态。
# 经 Start-Transcript 镜像,以下 Write-Host 同时上终端和进日志。
# ---------------------------------------------------------------------------
function Write-EnvReport {
    param([string]$VBoxDir)
    Write-Step "环境检测(仅排查用,不改动系统)"

    # --- 操作系统 ---
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        Write-Info ("OS    : {0} (Build {1})" -f $os.Caption, $os.BuildNumber)
    } catch { Write-Warn "OS    : 读取失败 ($($_.Exception.Message))" }

    # --- CPU 虚拟化扩展 ---
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $vmFw = $cpu.VirtualizationFirmwareEnabled
        $vmMon = $cpu.VMMonitorModeExtensions
        Write-Info ("CPU   : {0}" -f $cpu.Name.Trim())
        Write-Info ("VT-x  : 固件已启用={0}  VMX扩展={1}" -f $vmFw, $vmMon)
        if ($vmFw -eq $false) {
            Write-Info "固件 VT-x 报未启用 —— 若本机开了 Hyper-V/WSL,这是 hypervisor 接管所致,属正常(VBox 走 WHP)。"
            Write-Info "仅当本机【没开】任何 hypervisor 时,这才意味着 BIOS/UEFI 虚拟化没开,需进固件打开。"
        }
    } catch { Write-Warn "CPU   : 读取失败 ($($_.Exception.Message))" }
    Write-EnvReportHyperV
    Write-EnvReportNested
    Write-EnvReportVcrt -VBoxDir $VBoxDir
    Write-EnvReportSpoof
}

# Hyper-V / WHP / 内存完整性 —— 任一启用都会拉起 hypervisor,VBox 7.x 随之走 WHP 后端。
# VBox 5 与 Hyper-V 冲突起不来,7.x 靠 WHP 共存,启动会慢。
# 因此这里只做信息提示(启动会慢),不当故障、不劝用户关 Hyper-V。
function Write-EnvReportHyperV {
    try {
        $hvPresent = $false
        $f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Hypervisor -ErrorAction SilentlyContinue
        if ($f -and $f.State -eq "Enabled") { $hvPresent = $true }
        $hvLaunch = (bcdedit /enum "{current}" 2>$null | Select-String -Pattern "hypervisorlaunchtype")
        Write-Info ("Hyper-V特性 : {0}" -f $(if ($hvPresent) {"已启用"} else {"未启用"}))
        if ($hvLaunch) { Write-Info ("启动类型    : {0}" -f ($hvLaunch -replace '\s+',' ').Trim()) }
        if ($hvPresent -or ($hvLaunch -match "Auto")) {
            Write-Info "Hyper-V 在跑,VBox 7.x 走 WHP 后端运行(VBox 5 与 Hyper-V 冲突,7.x 靠 WHP 共存)。"
            Write-Info "代价仅是设备启动变慢(单台 3-5 分钟),不是故障,耐心等即可。"
        }
        # 内存完整性(HVCI)也会拉起 hypervisor,同样落到 WHP 后端,行为同上(慢,非故障)。
        $hvci = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -ErrorAction SilentlyContinue
        if ($hvci -and $hvci.Enabled -eq 1) {
            Write-Info "内存完整性(HVCI)已开,同样拉起 hypervisor → 走 WHP 后端(慢,非故障)。"
        }
        # WSL2 / 虚拟机平台
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
        if ($vmp -and $vmp.State -eq "Enabled") {
            Write-Info "虚拟机平台  : 已启用(WSL2/WSA/沙盒会用,同样经 WHP 后端,正常)"
        }
    } catch { Write-Warn "Hyper-V : 检测失败 ($($_.Exception.Message))" }
}

# 嵌套虚拟化 —— 本机若【跑在 VM 内】(宿主 Hyper-V + 客户机 eNSP),且客户机里 WHP
# 未启用,VBox 7.x 会走原生 VT-x,二级嵌套下 VRP 古董内核确定性 panic(c013e501),
# AR 卡满屏 #### 进不到 <Huawei>。见 docs/troubleshooting-error40.md 根因 C。
# 纯只读:只检测、只提示,绝不启用功能、绝不重启。物理机不在 VM 内,直接跳过。
function Write-EnvReportNested {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $sig = ("{0} {1}" -f $cs.Manufacturer, $cs.Model)
        $inVM = $sig -match "VirtualBox|VMware|Virtual Machine|innotek|QEMU|KVM|Xen|Parallels|Bochs"
        if (-not $inVM) { return }   # 物理机:此根因不适用,不打印
        $whp = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction SilentlyContinue
        $whpOn = ($whp -and $whp.State -eq "Enabled")
        Write-Info ("嵌套环境  : 检测到本机运行在 VM 内({0})" -f $sig.Trim())
        if ($whpOn) {
            Write-Info "WHP(虚拟机监控程序平台)已启用 → VBox 应走 NEM 后端,嵌套下正常。"
        } else {
            Write-Warn "WHP 未启用 —— 嵌套下 VBox 会走原生 VT-x,AR 可能卡满屏 #### / 内核 panic(error 40)。"
            Write-Warn "修复(客户机内,需管理员,装完【必须重启】):"
            Write-Warn "  Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All"
            Write-Warn "  (若宿主是 Hyper-V,还需先在宿主对本 VM: Set-VMProcessor -ExposeVirtualizationExtensions `$true)"
            Write-Warn "  详见 docs/troubleshooting-error40.md 根因 C。"
        }
    } catch { Write-Warn "嵌套检测 : 失败 ($($_.Exception.Message))" }
}

# x86 VCRT —— 32 位 eNSP marshal IVirtualBox 时加载 x86 proxystub,依赖 VBox\x86\
# 下的 x86 版 VCRUNTIME140/MSVCP140。缺它 → ERROR_BAD_EXE_FORMAT(0xC1) → error 40。
# 这里只读不写,真正的部署由 Do-Install 负责;此处仅暴露当前状态供排查。
function Write-EnvReportVcrt {
    param([string]$VBoxDir)
    try {
        if (-not $VBoxDir) { Write-Warn "VCRT  : VBox 目录未知,跳过 x86 运行时检测。"; return }
        $x86Dir = Join-Path $VBoxDir "x86"
        foreach ($n in @("VCRUNTIME140.dll","MSVCP140.dll")) {
            $p = Join-Path $x86Dir $n
            if (Test-Path $p) {
                Write-Info ("VCRT  : x86\{0} 存在" -f $n)
            } else {
                Write-Warn ("VCRT  : 缺 x86\{0} —— 干净机会 0x800700C1 / error 40(安装步骤会补上)。" -f $n)
            }
        }
    } catch { Write-Warn "VCRT  : 检测失败 ($($_.Exception.Message))" }
}

# 版本伪装 —— 注册表 Oracle\VirtualBox\Version 应被改成 5.2.x,eNSP 才认。
# 仅读取当前值供排查;实际写入由 Do-Install 负责。
function Write-EnvReportSpoof {
    try {
        $keys = @("HKLM:\SOFTWARE\Oracle\VirtualBox","HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox")
        $found = $false
        foreach ($k in $keys) {
            $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).Version
            if ($v) { Write-Info ("版本伪装 : {0} = {1}" -f $k, $v); $found = $true }
        }
        if (-not $found) { Write-Info "版本伪装 : 注册表暂无 Oracle\VirtualBox\Version(安装步骤会写)。" }
    } catch { Write-Warn "版本伪装 : 检测失败 ($($_.Exception.Message))" }
}

# 提权后 install 常在独立窗口里跑,成功一闪而过、失败直接关,用户看不到原因。
# 留一份日志,供编排器(install_all.ps1)在失败时指给用户看。
# 注意:install 经 RunAs 提权运行,$env:TEMP 会落到提权账户(可能是另一管理员或 SYSTEM)
# 的 Temp,登录用户在自己的 %TEMP% 里根本找不到。固定写到 ProgramData,两个语境都能访问。
$LogDir = Join-Path $env:ProgramData "ensp-vbox-shim"
try { if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null } } catch {}
$LogPath = Join-Path $LogDir "install.log"
Start-Transcript -Path $LogPath -Force -ErrorAction SilentlyContinue | Out-Null

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

Write-EnvReport -VBoxDir $vbox

if ($Check)         { Do-Check     -EnspDir $ensp -VBoxDir $vbox }
elseif ($Uninstall) { Do-Uninstall -EnspDir $ensp -VBoxDir $vbox }
else                { Do-Install   -EnspDir $ensp -VBoxDir $vbox -GrantSid $GrantSid }

Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
