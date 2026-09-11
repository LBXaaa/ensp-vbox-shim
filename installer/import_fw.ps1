<#
.SYNOPSIS
    导入 USG6000V 防火墙设备包,把 vfw_usg 基础 VM 建好并注册到 VirtualBox 7.x。

.DESCRIPTION
    华为 eNSP 的防火墙镜像 vfw_usg.vdi(约 940 MB)不随 eNSP 安装程序提供,需另行取得。
    eNSP 界面上有「导入设备包」对话框可以做这件事;本脚本是它的等价替代 —— 不必先在
    画布上拖出设备、等弹框、再选路径,一次把该有的状态做出来,也就是 eNSP 启动防火墙
    时所需要的样子:

      1. 把设备包里的 vfw_usg.vdi 复制到 <eNSP>\plugin\ngfw\Database\;
      2. 以 eNSP 自带的 vfw_usg_for_vbox5.0.vbox 为蓝本,生成
         <eNSP>\plugin\ngfw\tools\ngfw\vfw_usg\vfw_usg.vbox(磁盘路径改写为绝对路径);
      3. VBoxManage registervm 注册 vfw_usg;
      4. 补建链接克隆所需的 vfw_usg_Link 快照。

    导入后 eNSP 启动 USG6000V 时会执行
    `clonevm vfw_usg --snapshot vfw_usg_Link --options link ...`,与 AR/WLAN 基础盘
    同一套机制,运行期不再需要本脚本。

    第 1、2 步写 Program Files,需要管理员权限(脚本自行提权一次);第 3、4 步写当前
    用户的 .VirtualBox\VirtualBox.xml,必须与平时启动 eNSP 的账户一致,故留在非提权
    的原始上下文里执行 —— 与 install_all.ps1 的两段式权限模型相同。

    用法(一般经 导入防火墙包.bat 调用,也可把 vfw_usg.vdi 直接拖到那个 .bat 上):
      powershell -ExecutionPolicy Bypass -File import_fw.ps1 -Package "D:\USG6000V\vfw_usg.vdi"
      powershell -ExecutionPolicy Bypass -File import_fw.ps1 -Package ... -Check   # 只看会做什么

    可逆:撤销用 `VBoxManage unregistervm vfw_usg`(不加 --delete 不动磁盘)。
#>
[CmdletBinding()]
param(
    [string]$Package = "",
    [switch]$Check,
    [string]$EnspDir = "",
    [string]$VBoxDir = "",
    [switch]$StageFiles   # 内部使用:提权子进程只负责写文件那一段
)

$ErrorActionPreference = "Stop"

function Write-Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Info($m){ Write-Host "  [..] $m" -ForegroundColor Gray }
function Write-Warn($m){ Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Write-Err($m) { Write-Host "  [XX] $m" -ForegroundColor Red }

function Find-EnspDir([string]$Override){
    if($Override){
        if(Test-Path (Join-Path $Override "plugin\ngfw")){ return $Override.TrimEnd('\') }
        Write-Err "指定的 eNSP 目录无效(缺 plugin\ngfw\): $Override"; exit 1
    }
    $roots=@(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")
    foreach($r in $roots){
        if(-not(Test-Path $r)){ continue }
        $hit=Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
            $p=Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if($p.DisplayName -like "*eNSP*" -and $p.InstallLocation){ $p.InstallLocation }
        } | Where-Object { $_ -and (Test-Path (Join-Path $_ "plugin\ngfw")) } | Select-Object -First 1
        if($hit){ return $hit.TrimEnd('\') }
    }
    foreach($d in @((Join-Path ${env:ProgramFiles(x86)} "Huawei\eNSP"),(Join-Path $env:ProgramFiles "Huawei\eNSP"))){
        if($d -and (Test-Path (Join-Path $d "plugin\ngfw"))){ return $d.TrimEnd('\') }
    }
    return $null
}

function Find-VBoxManage([string]$Override){
    $dir=$null
    if($Override){ $dir=$Override.TrimEnd('\') }
    else{
        foreach($k in @("HKLM:\SOFTWARE\Oracle\VirtualBox","HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox")){
            if(-not(Test-Path $k)){ continue }
            $p=Get-ItemProperty $k -ErrorAction SilentlyContinue
            if($p.InstallDir -and (Test-Path $p.InstallDir)){ $dir=$p.InstallDir.TrimEnd('\'); break }
        }
        if(-not $dir){ $def=Join-Path $env:ProgramFiles "Oracle\VirtualBox"; if(Test-Path $def){ $dir=$def } }
    }
    if(-not $dir){ return $null }
    $vbm=Join-Path $dir "VBoxManage.exe"
    if(Test-Path $vbm){ return $vbm }
    return $null
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 已注册 VM 名集合
function Get-RegisteredVMs($vbm){
    $s=@{}
    foreach($line in (& $vbm list vms 2>$null)){
        if($line -match '^"([^"]+)"\s+\{'){ $s[$Matches[1]]=$true }
    }
    return $s
}
function Get-RunningVMs($vbm){
    $s=@{}
    foreach($line in (& $vbm list runningvms 2>$null)){
        if($line -match '^"([^"]+)"'){ $s[$Matches[1]]=$true }
    }
    return $s
}
function Has-Snapshot($vbm,$vm,$snapName){
    $out = & $vbm snapshot "$vm" list --machinereadable 2>$null
    if($LASTEXITCODE -ne 0){ return $false }
    foreach($line in $out){
        if($line -match '^SnapshotName(-[0-9]+)?="([^"]+)"' -and $Matches[2] -eq $snapName){ return $true }
    }
    return $false
}

# ---- 路径 ----
$ensp = Find-EnspDir $EnspDir
if(-not $ensp){ Write-Err "未能定位 eNSP 安装目录(需含 plugin\ngfw\)。请用 -EnspDir 手动指定。"; exit 1 }
$vbm = Find-VBoxManage $VBoxDir
if(-not $vbm){ Write-Err "未能定位 VBoxManage.exe。请用 -VBoxDir 手动指定。"; exit 1 }

$ngfw  = Join-Path $ensp "plugin\ngfw"
$tpl   = Join-Path $ngfw "tools\ngfw\vfw_usg_for_vbox5.0.vbox"
$vmDir = Join-Path $ngfw "tools\ngfw\vfw_usg"
$vmBox = Join-Path $vmDir "vfw_usg.vbox"
$dbDir = Join-Path $ngfw "Database"
$dbVdi = Join-Path $dbDir "vfw_usg.vdi"

# ---- 前置检查 ----
if(-not (Test-Path $tpl)){
    Write-Err "eNSP 目录下缺模板 $tpl"
    Write-Err "该机可能没装 NGFW(防火墙)插件,或 eNSP 安装不完整。"
    exit 1
}
if(-not $Package){
    Write-Err "未指定设备包。请用 -Package 指向 vfw_usg.vdi。"
    Write-Err "例:powershell -ExecutionPolicy Bypass -File import_fw.ps1 -Package `"D:\USG6000V\vfw_usg.vdi`""
    exit 1
}
if(-not (Test-Path $Package)){
    Write-Err "设备包不存在:$Package"
    exit 1
}
$pkg = Get-Item $Package
if($pkg.Length -lt 100MB){
    Write-Err "设备包偏小($([math]::Round($pkg.Length/1MB,1)) MB),不像是防火墙镜像(正常约 940 MB)。"
    Write-Err "请确认指向的是 vfw_usg.vdi 本身,而不是压缩包。"
    exit 1
}

$running = Get-RunningVMs $vbm
if($running.ContainsKey("vfw_usg")){
    Write-Err "vfw_usg 正在运行。请先在 eNSP / VirtualBox 里关掉用到防火墙的拓扑,再重跑本脚本。"
    exit 1
}

Write-Host "eNSP       : $ensp"
Write-Host "VBoxManage : $vbm"
Write-Host "设备包     : $($pkg.FullName)  ($([math]::Round($pkg.Length/1MB,1)) MB)"

$registered = Get-RegisteredVMs $vbm
$alreadyReg = $registered.ContainsKey("vfw_usg")

# ---- 文件阶段(需管理员) ----
function Invoke-FileStage {
    Write-Step "写入设备包与 VM 配置(需要管理员权限)"
    New-Item -ItemType Directory -Force $dbDir  | Out-Null
    New-Item -ItemType Directory -Force $vmDir  | Out-Null

    $needCopy = $true
    if(Test-Path $dbVdi){
        $a = (Get-FileHash $dbVdi -Algorithm SHA256).Hash
        $b = (Get-FileHash $pkg.FullName -Algorithm SHA256).Hash
        if($a -eq $b){ $needCopy = $false; Write-Info "磁盘镜像已就位(哈希一致),跳过复制" }
        else { Write-Warn "已存在一份不同的 vfw_usg.vdi,将被覆盖:$dbVdi" }
    }
    if($needCopy){
        Write-Info "复制磁盘镜像 -> $dbVdi"
        Copy-Item $pkg.FullName $dbVdi -Force
        Write-OK "磁盘镜像就位($([math]::Round((Get-Item $dbVdi).Length/1MB,1)) MB)"
    }

    # 以 eNSP 自带模板为蓝本,只把磁盘路径改成绝对路径(模板在 ngfw\ 下,相对路径
    # ../../DataBase/ 是按 VM 配置放在 tools\ngfw\ 根目录来解析的;本脚本把配置放进
    # vfw_usg\ 子目录,相对路径会指错地方)。
    #
    # 【已注册的绝不覆盖】:注册后那份 .vbox 归 VirtualBox 管,里面有快照段、可能还有
    # 正在被克隆挂着的差分盘。拿模板去覆盖会把快照段冲掉(表现为重跑一次脚本就换一个
    # vfw_usg_Link),克隆链也可能跟着断。
    if($alreadyReg -and (Test-Path $vmBox)){
        Write-Info "vfw_usg 已注册,沿用现有 VM 配置(不覆盖,以免丢掉已有快照)"
        return
    }
    $text = Get-Content $tpl -Raw
    $relAbs = $dbVdi.Replace('\','/')
    $new = $text -replace 'location="[^"]*vfw_usg\.vdi"', "location=`"$relAbs`""
    if($new -notmatch [regex]::Escape($relAbs)){
        Write-Err "生成 VM 配置失败:模板里没找到预期形状的磁盘路径。"
        Write-Err "模板:$tpl"
        exit 1
    }
    [System.IO.File]::WriteAllText($vmBox, $new, (New-Object System.Text.UTF8Encoding($false)))
    Write-OK "VM 配置已生成:$vmBox"
}

$isAdmin = Test-IsAdmin

if($Check){
    Write-Step "检测(只看,不改动)"
    Write-Info "设备包    : $($pkg.FullName)  ($([math]::Round($pkg.Length/1MB,1)) MB)"
    Write-Info "磁盘镜像  : $(if(Test-Path $dbVdi){"已存在"}else{"未就位 -> 将复制到 $dbVdi"})"
    Write-Info "VM 配置   : $(if(Test-Path $vmBox){"已存在"}else{"未生成 -> 将写入 $vmBox"})"
    Write-Info "vfw_usg   : $(if($alreadyReg){"已注册"}else{"未注册 -> 将注册 $vmBox"})"
    if($alreadyReg){
        Write-Info "快照      : $(if(Has-Snapshot $vbm 'vfw_usg' 'vfw_usg_Link'){'vfw_usg_Link 已存在'}else{'缺 vfw_usg_Link -> 将补建'})"
    }
    Write-Host ""
    Write-Host "检测完成,未做任何改动。" -ForegroundColor Green
    exit 0
}

if($StageFiles){
    Invoke-FileStage
    exit 0
}

if(-not $isAdmin){
    Write-Step "第 1 步 / 共 2 步:写文件(需要管理员权限,UAC 会弹一次)"
    $self = $MyInvocation.MyCommand.Definition
    $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$self`"",
              "-Package","`"$($pkg.FullName)`"","-StageFiles",
              "-EnspDir","`"$ensp`"","-VBoxDir","`"$([System.IO.Path]::GetDirectoryName($vbm))`"")
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList ($args -join " ") `
                              -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        Write-Err "写文件需要管理员权限,已取消(未做任何改动)。"
        exit 1
    }
    if($proc.ExitCode -ne 0){ Write-Err "文件阶段失败(退出码 $($proc.ExitCode))。"; exit 1 }
} else {
    Invoke-FileStage
}

# ---- 注册阶段(必须是非提权的登录账户身份) ----
Write-Step "第 2 步 / 共 2 步:注册 vfw_usg 并补建快照"

$registered = Get-RegisteredVMs $vbm
if($registered.ContainsKey("vfw_usg")){
    Write-Info "vfw_usg 已注册,沿用现有注册项(不注销重注册)"
} else {
    $r = & $vbm registervm $vmBox 2>&1
    if($LASTEXITCODE -ne 0){
        Write-Err "注册失败:$r"
        Write-Err "手动重试:VBoxManage registervm `"$vmBox`""
        exit 1
    }
    Write-OK "已注册 vfw_usg"
}

if(Has-Snapshot $vbm "vfw_usg" "vfw_usg_Link"){
    Write-OK "快照 vfw_usg_Link 已存在,保持不动"
} else {
    Write-Info "补建链接克隆快照 vfw_usg_Link"
    $out = ""
    try {
        $old = $ErrorActionPreference
        $ErrorActionPreference = "Continue"   # 进度条走 stderr,别让它中断脚本
        $out = (& $vbm snapshot "vfw_usg" take "vfw_usg_Link" 2>$null | Out-String)
    } catch { $out = "" } finally { $ErrorActionPreference = $old }
    if(($out -notmatch 'Snapshot taken') -and -not (Has-Snapshot $vbm "vfw_usg" "vfw_usg_Link")){
        Write-Err "补建快照失败。手动重试:VBoxManage snapshot vfw_usg take vfw_usg_Link"
        exit 1
    }
    Write-OK "已补建快照 vfw_usg_Link"
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "  防火墙设备包导入完成。启动 eNSP,拉一台 USG6000V 试试。" -ForegroundColor Green
Write-Host "  撤销:VBoxManage unregistervm vfw_usg  (不加 --delete 不动磁盘)" -ForegroundColor Gray
Write-Host "============================================================`n" -ForegroundColor Green
