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
    NGFW_Plugin.dll 不做处理:2026-09-10 的受控 A/B 实测显示,出厂原版与
    22 站点补丁版在启动结果上没有任何差异(失败签名相差不到 1 毫秒),
    且 host 上出厂原版即可正常启动 USG6000V。补丁器仍留在 patches/ 下备查,
    但安装器不碰华为的这个文件。


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

# checks.ps1 是纯只读探测库(只有函数定义,无顶层副作用),可安全 dot-source。
# 目录查找(Find-EnspDir / Find-VBoxDir)与 host-only 各层探测都取自它 ——
# 那份实现不打印、不 exit,找不到就返回 $null,由本文件的调用点决定怎么报错。
# 必须在 script 作用域(dot-source 会写入调用方作用域)执行,checks.ps1 里的
# $script: 变量才落在本脚本的作用域里,其函数读取时才解析得到。
. (Join-Path $ScriptDir "checks.ps1")

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
$CLSID_VBOX   = "{B1A7A4F2-47B9-4A1E-82B2-07CCD5323C3F}"  # CLSID_VirtualBox
$DLL_NAME     = "VBox52.dll"
$DLL_SHA256       = "6d2aadce202a740e128add181dcac1b81ae060c1b508f1a6d8cfdbb2fef69efe"
# NGFW_Plugin.dll 的三态哈希 —— 仅用于 Do-Check 报告状态,安装器不改这个文件。
# 必要性未经证实:2026-09-10 在 inst-51 上做的受控 A/B 显示,出厂原版与 22 站点
# 补丁版都以完全相同的签名失败(VM 存活 5546 vs 5547 ms),而 host 上出厂原版
# 即可正常启动。见 patches/README.md。
$NGFW_PRISTINE_SHA256 = "a71b488ed31c038aae39863d47f253de8c7c46c2881f52d7868a83809defa14a"
$NGFW_PATCHED_SHA256  = "8169f6169c86563f5ba8e2762cf579fad7eaab5374e76bb24bdce0d270641ec9"
$NGFW_LEGACY_SHA256   = "0696612468e533262e7325f3120a63601bfbd685b0d0d4477afcbc452c2e0da0"
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
$REAL_VER     = "7.2.8"      # 卸载还原时的兜底值;优先动态读取已装 VBox 的真实版本
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
# 路径检测 —— Find-EnspDir / Find-VBoxDir 已下沉到 checks.ps1(在文件开头 dot-source)。
# 那份实现只读、不打印、不 exit;调用点负责报错,见文件末尾的定位段。
# ---------------------------------------------------------------------------

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

# 从安装时留下的 .orig.bak 还原。
# 【只在确有备份时才动那个文件】—— 没有备份的绝不能先删:它可能是安装器根本
# 没碰过的华为原程序(例如 NGFW_Plugin.dll),删掉之后没有任何地方能找回来。
function Restore-FromBak($DestPath) {
    $bak = "$DestPath.orig.bak"
    if (-not (Test-Path $bak)) { Write-Info "无备份,跳过: $(Split-Path $DestPath -Leaf)"; return }
    if (Test-Path $DestPath) { Remove-Item $DestPath -Force }
    Copy-Item $bak $DestPath
    Write-OK "已还原: $(Split-Path $DestPath -Leaf)"
}

# 卸载时清掉"安装器新建、机器上本来没有"的文件(即没有 .orig.bak 的那种)。
# 按哈希认脸:只删确实由安装器部署的那一份,同名但不是它的文件一律不动。
function Remove-DeployedFile($DestPath, $ExpectedSha256) {
    if (-not (Test-Path $DestPath)) { return }
    if (-not $ExpectedSha256) { return }
    if (Test-Path "$DestPath.orig.bak") { return }   # 有备份的交给 Restore-FromBak
    $h = (Get-FileHash $DestPath -Algorithm SHA256).Hash.ToLower()
    if ($h -eq $ExpectedSha256.ToLower()) {
        Remove-Item $DestPath -Force
        Write-OK "已移除安装器新建的文件: $(Split-Path $DestPath -Leaf)"
    } else {
        Write-Info "非安装器部署的文件,保留: $(Split-Path $DestPath -Leaf)"
    }
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

    Write-Step "1/6 还原版本字符串"
    # 动态读取已装 VBox 的真实版本(VBoxManage --version 形如 7.2.14r174565);
    # 读不到(如已卸载 VBox)才退回常量兜底值。
    $real = $REAL_VER; $realext = $REAL_VEREXT
    $vbm = Join-Path $VBoxDir "VBoxManage.exe"
    if (Test-Path $vbm) {
        try {
            $out = (& $vbm --version 2>$null | Select-Object -First 1)
            if ($out -match '^(\d+\.\d+\.\d+)r(\d+)$') {
                $real = $Matches[1]; $realext = $out.Trim()
            }
        } catch { }
    }
    Set-RegValue "HKLM:\SOFTWARE\Oracle\VirtualBox"            "Version"    $real
    Set-RegValue "HKLM:\SOFTWARE\Oracle\VirtualBox"            "VersionExt" $realext
    Set-RegValue "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" "Version"    $real
    Set-RegValue "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox" "VersionExt" $realext
    Write-OK "Version=$real"

    Write-Step "2/6 还原 AR 插件 VAR_Plugin.dll"
    $varp = Join-Path $EnspDir "plugin\ar1000v\VAR_Plugin.dll"
    Restore-FromBak $varp

    Write-Step "3/6 还原 NGFW 防火墙插件"
    # 安装器从不碰这个文件,所以这里通常无事可做,只会打印"无备份,跳过"。
    # 留这一步只为兜住"曾手工打过补丁并留下 .orig.bak"的情形;手工跑过
    # patches\patch_ngfw_plugin.py 的,用它的 --restore 还原即可。
    Restore-FromBak (Join-Path $EnspDir "plugin\ngfw\NGFW_Plugin.dll")

    Write-Step "4/6 还原所有位置的 VBox52.dll"
    $vboxDirs = @(
        (Join-Path $EnspDir "tools"),
        (Join-Path $EnspDir "vboxserver"),
        $EnspDir,
        (Join-Path $EnspDir "plugin\ngfw\tools\ngfw")
    )
    foreach ($dir in $vboxDirs) {
        $p = Join-Path $dir $DLL_NAME
        Restore-FromBak $p
        Remove-DeployedFile $p $DLL_SHA256
    }

    Write-Step "5/6 CLSID InprocServer32(需手动)"
    Write-Warn "CLSID 劫持指向的正确原始值随 VBox 构建而异,本脚本不擅自改写。"
    Write-Warn "请对 VirtualBox 7.2 跑一次【修复】(应用和功能 → VirtualBox → 修改/修复),"
    Write-Warn "它会把 $CLSID_VBOX 改回 Oracle 原生 proxy/stub。"

    Write-Step "6/6 还原 x86\ 子目录的 VC++ 运行时"
    if ($VBoxDir) {
        $x86sub = Join-Path $VBoxDir "x86"
        foreach ($f in $VCRT_X86_FILES) {
            $dest = Join-Path $x86sub $f.Name
            Restore-FromBak $dest
            # 期望值取自安装包里那一份:只有确实是我们部署的才删
            $srcF = Join-Path $ScriptDir "payload\msvcrt-x86\$($f.Name)"
            $want = if (Test-Path $srcF) { (Get-FileHash $srcF -Algorithm SHA256).Hash } else { $null }
            Remove-DeployedFile $dest $want
        }
    } else {
        Write-Info "未定位 VirtualBox 目录,跳过 VC++ 运行时清理。"
    }

    Write-Host "`n卸载流程完成(CLSID 项请按上面提示跑 VBox 修复)。`n" -ForegroundColor Green
}
# ---------------------------------------------------------------------------
# host-only 网络自检(只读,不改动)
#
# eNSP 的设备全靠 host-only 网络回连 192.168.56.1:资源文件(plugin\*\resource*.cfg)
# 写死 dest:192.168.56.1,VBox 还在这条链路上跑 DHCP(192.168.56.100,发 .101-.254)。
# 这台一旦坏了,现象和"补丁打错"完全一样 —— 设备起得来、VM 里一切正常、进度条永远
# 走不完、没有任何崩溃报告。极难分辨,所以必须显式检查。
#
# 已知坏法:Windows/VBox 允许存在多块**同名** host-only 适配器,而 VM 是按名字绑的
# (hostonlyadapterN="VirtualBox Host-Only Ethernet Adapter"),于是客机可能被挂到
# 没有 IP 的那一块(169.254.x.x)上,永远够不到 192.168.56.1。
#
# 事实采集全部来自 checks.ps1(与 diag.ps1 共用同一套解析与判据),本函数只负责展示。
# 六层:1 驱动包注册 / 2 服务 / 3 VBox 视角的接口 / 4 Windows 视角的网卡 /
#       5 NDIS 过滤驱动绑定 / 6 模板名 vs 实际接口名。
# 只报告,不擅自改网络配置。
# ---------------------------------------------------------------------------
function Write-EnvReportHostOnly {
    param([string]$VBoxDir, [string]$EnspDir)

    $vbm     = ""
    $drvInst = ""
    if ($VBoxDir) {
        $vbm     = Join-Path $VBoxDir "VBoxManage.exe"
        $drvInst = Join-Path $VBoxDir "VBoxDrvInst.exe"
    }

    Write-Info "host-only 网络(设备回连 192.168.56.1 的必经之路):"
    $problems = @()
    $ifNames  = @()

    # --- 第 1 层(驱动包注册)+ 第 2 层(服务)---
    # 第 1 层是 2026-09-15 的真实故障形态:两个驱动包都不在驱动库里。旧版自检完全没有
    # 这一层,所以那次故障只能靠人工想到去查 VBoxDrvInst。
    #
    # "两个包都注册了"的判据取自 checks.ps1 的 Layer1.DriverRegistered,不在本文件里
    # 重算 —— 判据只能有一份,否则两边迟早漂移。
    $drvLines = @()
    try {
        if ($drvInst -and (Test-Path $drvInst)) { $drvLines = @(& $drvInst list 2>$null) }
        $layers = Get-HostOnlyDriverLayers -DrvInstLines $drvLines

        # 一条输出都没取到时不许报"缺失" —— 那等于把"读不到"说成缺陷,是假警报。
        if ($drvLines.Count -eq 0) {
            Write-Info "  host-only 第 1 层(驱动注册): 取不到 VBoxDrvInst 输出,本层无法判定。"
        } else {
            Write-Info ("  host-only 第 1 层(驱动注册): VBoxNetAdp6={0}  VBoxNetLwf={1}" -f `
                        $(if ($layers.Layer1.NetAdpPresent) { "已注册" } else { "缺失" }), `
                        $(if ($layers.Layer1.NetLwfPresent) { "已注册" } else { "缺失" }))
            if (-not $layers.Layer1.DriverRegistered) {
                $problems += "VBox 网络驱动包没注册进驱动库 —— 这是 2026-09-15 的故障形态。" +
                             "禁启用适配器、重装驱动都修不好,必须重新注册驱动包(见 diag.ps1 第 1 层提示)"
            }
        }

        # 第 2 层只读服务,与驱动输出无关,取不到输出时照样列。
        foreach ($s in $layers.Layer2.Services) {
            Write-Info ("  host-only 第 2 层(服务): {0} = {1}" -f $s.Name.PadRight(12), $(if ($s.Present) { $s.Status.ToString() } else { "不存在" }))
        }
        if (-not $layers.Layer2.AllRunning) {
            $problems += "上面有 VBox 服务没有在运行(VBoxSup 不跑,虚拟机直接起不来)"
        }
    } catch { $problems += ("第 1/2 层读取失败: " + $_.Exception.Message) }

    # --- 第 3 层:VBox 视角的接口 ---
    try {
        if (-not ($vbm -and (Test-Path $vbm))) {
            Write-Info "  host-only 第 3 层(VBox 接口): 找不到 VBoxManage.exe,本层跳过。"
        } else {
            $ifs = @(Parse-HostOnlyIfs -Lines @(& $vbm list hostonlyifs 2>$null))
            if ($ifs.Count -eq 0) {
                $problems += "一块 host-only 适配器都没有 —— eNSP 设备无法回连宿主"
            }
            foreach ($i in $ifs) {
                Write-Info ("  host-only 第 3 层(VBox 接口): {0}  ->  {1}" -f $i.Name, $(if ($i.IPAddress) { $i.IPAddress } else { "(无 IP)" }))
                $ifNames += $i.Name
            }
            if ($ifs.Count -gt 1) {
                $problems += ("存在 {0} 块 host-only 适配器。VM 按名字绑(hostonlyadapterN),名字重复时" -f $ifs.Count) +
                             "VBox 选哪块不确定 —— 客机可能挂到没有 IP 的那块上"
            }
            # 192.168.56.1 必须真的配在某一块上
            $withIp = @($ifs | Where-Object { $_.IPAddress -eq "192.168.56.1" })
            if ($ifs.Count -gt 0 -and $withIp.Count -eq 0) {
                $problems += "没有任何一块 host-only 适配器配了 192.168.56.1 —— 设备回连必然超时(10060)"
            } elseif ($withIp.Count -gt 1) {
                $problems += "有多块适配器同时配着 192.168.56.1,会产生重复 IP 冲突"
            }
        }
    } catch { $problems += ("第 3 层读取失败: " + $_.Exception.Message) }

    # --- 第 4 层:Windows 视角的网卡 ---
    # 连接名是本地化的(如「以太网 11」),不可用于匹配;InterfaceDescription 才是稳定键。
    try {
        $adapters = @(Get-HostOnlyNetAdapterFacts)
        if ($adapters.Count -eq 0) {
            $problems += '没找到 InterfaceDescription 含 "VirtualBox Host-Only" 的网卡(驱动包可能没进数据路径)'
        }
        foreach ($a in $adapters) {
            Write-Info ("  host-only 第 4 层(Windows 网卡): {0}  ->  {1}  ({2})" -f $a.InterfaceName, $a.IPv4, $a.Status)
        }
    } catch { $problems += ("第 4 层读取失败: " + $_.Exception.Message) }

    # --- 第 5 层:NDIS 过滤驱动绑定 ---
    try {
        foreach ($b in @(Get-HostOnlyBindingFacts)) {
            Write-Info ("  host-only 第 5 层(NDIS 绑定): {0} = {1}" -f $b.InterfaceName, $(if ($b.Bound -and $b.Enabled) { "已绑定并启用" } else { "未绑定或未启用" }))
            if (-not ($b.Bound -and $b.Enabled)) {
                $problems += ("网卡 " + $b.InterfaceName + " 上没有启用 oracle_VBoxNetLwf 绑定 —— 流量进不了 VBox 的数据路径")
            }
        }
    } catch { $problems += ("第 5 层读取失败: " + $_.Exception.Message) }

    # --- 第 6 层:模板名 vs 实际接口名 ---
    # 这一层才是 "#2" 类问题的正确判据:带后缀本身不是故障,模板名和实际名对不上才是
    # (VM 是按 hostonlyadapterN 的名字绑的)。旧版用通配符 "Adapter*" 判名字,把带 #2 的
    # 适配器当成正常的,于是这一类问题从来没被报出来过。
    try {
        $tplPath = ""
        if ($EnspDir) { $tplPath = Join-Path $EnspDir "vboxserver\AR_Base\AR_Base.vbox" }
        if ($ifNames.Count -eq 0) {
            # 第 3 层没取到接口名,比对无意义,不做判定。
        } elseif (-not ($tplPath -and (Test-Path $tplPath))) {
            Write-Info "  host-only 第 6 层(模板名比对): 读不到 AR_Base.vbox,本层跳过。"
        } else {
            $tplNames = @()
            foreach ($line in (Get-Content -Path $tplPath -ErrorAction SilentlyContinue)) {
                if ($line -match 'HostOnlyInterface\s+name="([^"]*)"') { $tplNames += $Matches[1] }
            }
            if ($tplNames.Count -eq 0) {
                Write-Info "  host-only 第 6 层(模板名比对): 模板里没有主机专用接口名,无从比对。"
            } else {
                $cmp = Compare-HostOnlyName -VBoxNames $ifNames -TemplateNames $tplNames
                if ($cmp.HasMismatch) {
                    Write-Info ("  host-only 第 6 层(模板名比对): 匹配 {0} / {1}" -f $cmp.MatchedCount, $tplNames.Count)
                    $problems += ("模板里有 " + $cmp.MissingInVBox.Count + " 个接口名在实际接口中不存在:" + ($cmp.MissingInVBox -join " | ")) +
                                 '。修法是重新注册设备(会重写模板里的名字),而不是把 "#2" 本身当成故障'
                } else {
                    Write-Info ("  host-only 第 6 层(模板名比对): 一致({0} 个)。" -f $cmp.MatchedCount)
                }
            }
        }
    } catch { $problems += ("第 6 层读取失败: " + $_.Exception.Message) }

    if ($problems.Count -eq 0) {
        Write-OK "host-only 网络 : 正常(驱动已注册、服务在跑、接口名与模板一致)"
    } else {
        Write-Warn "host-only 网络异常 —— 这会让设备卡在进度条,且症状与补丁问题无法区分:"
        foreach ($p in $problems) { Write-Warn "       - $p" }
        Write-Warn "  修复思路(本脚本不擅自改网络,请手工处理):"
        Write-Warn "    1. VBoxManage list hostonlyifs 看有几块、名字分别是什么"
        Write-Warn "    2. 多余的同名适配器用 VBoxManage hostonlyif remove `"<名字>`" 删除"
        Write-Warn "       (该命令只认名字不认 GUID;同名时多删几次并逐次核对)"
        Write-Warn "    3. 保证剩下那块名字与设备模板一致、IP 为 192.168.56.1/24"
        Write-Warn "    4. VBoxManage list dhcpservers 确认 DHCP 的 NetworkName 指向该适配器"
        Write-Warn "       (本自检不含 DHCP 绑定,须手工核对)"
        Write-Warn "  另:设备起不来时先确认没有杀不掉的僵尸 eNSP_VBoxServer 进程,有就重启。"
        Write-Warn "  完整六层解读见 环境检查.bat(diag.ps1)。"
    }
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
    $ngfwp = Join-Path $EnspDir "plugin\ngfw\NGFW_Plugin.dll"
    if (Test-Path $ngfwp) {
        $h = (Get-FileHash $ngfwp -Algorithm SHA256).Hash.ToLower()
        # 安装器不再处理这个文件,这里只报状态供排查。
        $tag = if ($h -eq $NGFW_PRISTINE_SHA256) { "出厂原版(安装器不动它)" }
               elseif ($h -eq $NGFW_PATCHED_SHA256) { "被手工打过 22 站点补丁" }
               elseif ($h -eq $NGFW_LEGACY_SHA256) { "被手工打过旧 28 站点补丁" }
               else { "非标准版本(哈希不同)" }
        Write-Info "NGFW_Plugin.dll : $tag"
    } else { Write-Info "NGFW_Plugin.dll : 未找到(没装 USG6000V 包)" }


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
    param([string]$VBoxDir, [string]$EnspDir)
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
    Write-EnvReportHostOnly -VBoxDir $VBoxDir -EnspDir $EnspDir
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

# 嵌套虚拟化 —— 本机若【跑在 VM 内】(宿主 Hyper-V + 客户机 eNSP):
#   - Win10 客户机默认向上暴露 VT-x → VBox 走原生 HM → 二级嵌套下 VRP 古董内核
#     确定性 panic(c013e501),AR 卡满屏 #### 进不到 <Huawei>(error 40)。
#   - Win11 客户机报告 VT-x 不可用 → VBox 自动回退 NEM → 无此问题。
# 故此处只对【Win10 客户机】告警(build < 22000);Win11 客户机判为无此问题。
# 见 docs/troubleshooting-error40.md 根因 C。纯只读:只检测、只提示,绝不启用功能、
# 绝不重启。物理机不在 VM 内,直接跳过。
function Write-EnvReportNested {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $sig = ("{0} {1}" -f $cs.Manufacturer, $cs.Model)
        $inVM = $sig -match "VirtualBox|VMware|Virtual Machine|innotek|QEMU|KVM|Xen|Parallels|Bochs"
        if (-not $inVM) { return }   # 物理机:此根因不适用,不打印
        Write-Info ("嵌套环境  : 检测到本机运行在 VM 内({0})" -f $sig.Trim())
        # 客户机 OS 版本决定默认后端:Win11(build>=22000)自动走 NEM,不受此根因影响。
        $build = 0; [int]::TryParse((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).BuildNumber, [ref]$build) | Out-Null
        if ($build -ge 22000) {
            Write-Info "客户机为 Win11(build $build)→ VBox 自动回退 NEM 后端,无此根因,无需处理。"
            return
        }
        $whp = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction SilentlyContinue
        $whpOn = ($whp -and $whp.State -eq "Enabled")
        if ($whpOn) {
            Write-Info ("客户机为 Win10(build {0}),但 WHP 已启用 → VBox 走 NEM 后端,正常。" -f $build)
        } else {
            Write-Warn ("客户机为 Win10(build {0})且 WHP 未启用 —— 嵌套下 VBox 会走原生 VT-x," -f $build)
            Write-Warn "  AR 可能卡满屏 #### / 内核 panic(error 40)。修复(客户机内,需管理员,装完【必须重启】):"
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
    # checks.ps1 的 Find-EnspDir 只返回 $null,报错与退出由这里负责(原实现的
    # exit 正是在查找函数里,下沉后必须补回调用点,否则会带着空目录继续跑)。
    if ($EnspDir) {
        Write-Err "指定的 eNSP 目录无效(缺 tools\): $EnspDir"
    } else {
        Write-Err "未能自动定位 eNSP 安装目录。请用 -EnspDir 手动指定,例如:"
        Write-Err '  install.ps1 -EnspDir "D:\Program Files\Huawei\eNSP"'
    }
    exit 1
}
$vbox = Find-VBoxDir -Override $VBoxDir
if (-not $vbox) { Write-Warn "未能定位 VirtualBox 目录(版本伪装仍会写注册表)。" }

Write-Host "eNSP : $ensp"
Write-Host "VBox : $vbox"

Write-EnvReport -VBoxDir $vbox -EnspDir $ensp

if ($Check)         { Do-Check     -EnspDir $ensp -VBoxDir $vbox }
elseif ($Uninstall) { Do-Uninstall -EnspDir $ensp -VBoxDir $vbox }
else                { Do-Install   -EnspDir $ensp -VBoxDir $vbox -GrantSid $GrantSid }

Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
