<#
.SYNOPSIS
    导入 eNSP 设备包(镜像),把对应设备的基础 VM 建好并注册到 VirtualBox 7.x。

.DESCRIPTION
    eNSP 有一批设备要外挂磁盘镜像,镜像不随 eNSP 安装程序提供,需自行取得。本脚本把
    用户的镜像和 eNSP 自带的 VM 模板拼成"设备能启动"所必需的状态:

      - 镜像放进该插件自己的 Database\ 目录;
      - 注册模板声明的那台 VM(防火墙还要额外补一个链接克隆快照)。

    支持六台设备(七种型号),由镜像文件名自动识别,也可用 -Device 指定:

      | -Device | 镜像          | 设备面板上的型号    |
      |---------|---------------|---------------------|
      | fw      | vfw_usg.vdi   | USG6000V            |
      | ce      | CE.img        | CE6800、CE12800     |
      | cx      | CX.img        | CX200               |
      | ne40e   | NE40E.img     | NE40E               |
      | ne5ke   | NE5000E.img   | NE5000E             |
      | ne9k    | NE9000.img    | NE9000              |

    用法(一般经 导入设备包.bat 调用,也可把镜像或它的 zip 直接拖到那个 .bat 上):

      powershell -ExecutionPolicy Bypass -File import_device.ps1 -Package "D:\设备包\USG6000V.zip"
      powershell -ExecutionPolicy Bypass -File import_device.ps1 -Package "D:\设备包\CE.img" -Check

    zip 会被就地读取,只需包里的那一个镜像,不额外占用解压空间。

    写 Program Files 那一段需要管理员权限(脚本自行提权一次);注册那一段写当前用户的
    .VirtualBox\VirtualBox.xml,必须与平时启动 eNSP 的账户一致,故留在非提权的原始
    上下文里执行 —— 与 install_all.ps1 的两段式权限模型相同。

    可逆:撤销用 `VBoxManage unregistervm <VM名>`(不加 --delete 不动磁盘)。
#>
[CmdletBinding()]
param(
    [string]$Package = "",
    [string]$Device  = "",
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

# ---------------------------------------------------------------------------
# 设备表
#   Image  : 镜像文件名(必须与模板里 location="../../Database/<名>" 写死的一致)
#   DbDir  : 镜像落地的插件目录(相对 eNSP 根)
#   Tpl    : VM 模板
#   VmName : 模板里声明的 VM 名
#   RelTpl : $true 表示模板的相对路径能自己解析对,原地注册即可;
#            $false 表示模板要挪位置(防火墙:配置放进 vfw_usg\ 子目录,相对路径会指错)
#   Snap   : 是否需要 <VmName>_Link 快照(防火墙的插件 clonevm --snapshot <VmName>_Link)
# ---------------------------------------------------------------------------
$DEVICES = [ordered]@{
    "fw"    = @{ Label="USG6000V 防火墙"; Image="vfw_usg.vdi"; DbDir="plugin\ngfw\Database"; Tpl="plugin\ngfw\tools\ngfw\vfw_usg_for_vbox5.0.vbox"; VmName="vfw_usg"; RelTpl=$false; Snap=$true  }
    "ce"    = @{ Label="CE6800 / CE12800"; Image="CE.img";      DbDir="plugin\svrp\Database"; Tpl="plugin\svrp\Tools\svrp\CE.xml";      VmName="CE";      RelTpl=$true;  Snap=$false }
    "cx"    = @{ Label="CX200";            Image="CX.img";      DbDir="plugin\cx\Database";   Tpl="plugin\cx\Tools\svrp\CX.xml";        VmName="CX";      RelTpl=$true;  Snap=$false }
    "ne40e" = @{ Label="NE40E";            Image="NE40E.img";   DbDir="plugin\ne\Database";   Tpl="plugin\ne\Tools\svrp\NE40E.xml";    VmName="NE40E";   RelTpl=$true;  Snap=$false }
    "ne5ke" = @{ Label="NE5000E";          Image="NE5000E.img"; DbDir="plugin\ne5ke\Database";Tpl="plugin\ne5ke\Tools\svrp\NE5KE.xml"; VmName="NE5000E"; RelTpl=$true;  Snap=$false }
    "ne9k"  = @{ Label="NE9000";           Image="NE9000.img";  DbDir="plugin\ne9k\Database"; Tpl="plugin\ne9k\Tools\svrp\NE9K.xml";   VmName="NE9000";  RelTpl=$true;  Snap=$false }
}

function Find-EnspDir([string]$Override){
    if($Override){
        if(Test-Path (Join-Path $Override "plugin")){ return $Override.TrimEnd('\') }
        Write-Err "指定的 eNSP 目录无效(缺 plugin\): $Override"; exit 1
    }
    $roots=@(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")
    foreach($r in $roots){
        if(-not(Test-Path $r)){ continue }
        $hit=Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
            $p=Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if($p.DisplayName -like "*eNSP*" -and $p.InstallLocation){ $p.InstallLocation }
        } | Where-Object { $_ -and (Test-Path (Join-Path $_ "plugin")) } | Select-Object -First 1
        if($hit){ return $hit.TrimEnd('\') }
    }
    foreach($d in @((Join-Path ${env:ProgramFiles(x86)} "Huawei\eNSP"),(Join-Path ${env:ProgramFiles} "Huawei\eNSP"))){
        if($d -and (Test-Path (Join-Path $d "plugin"))){ return $d.TrimEnd('\') }
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
        if(-not $dir){ $def=Join-Path ${env:ProgramFiles} "Oracle\VirtualBox"; if(Test-Path $def){ $dir=$def } }
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

# 从 zip 里只取出镜像那一条,直接落盘到 $Dest;不整包解压。
# 返回落盘后的字节数。若 $Dest 已存在且大小一致,视为已就位。
function Expand-ImageFromZip([string]$ZipPath, [string]$ImageName, [string]$Dest){
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.Name -ieq $ImageName } | Select-Object -First 1
        if(-not $entry){
            $names = ($zip.Entries | ForEach-Object { $_.Name }) -join ", "
            throw "zip 里没有 $ImageName(包内有:$names)"
        }
        if((Test-Path $Dest) -and ((Get-Item $Dest).Length -eq $entry.Length)){
            return @{ Length = $entry.Length; Skipped = $true }
        }
        $src = $entry.Open()
        $dst = [System.IO.File]::Create($Dest)
        try { $src.CopyTo($dst) } finally { $dst.Dispose(); $src.Dispose() }
        return @{ Length = $entry.Length; Skipped = $false }
    } finally { $zip.Dispose() }
}

# ---- 路径与环境 ----
$ensp = Find-EnspDir $EnspDir
if(-not $ensp){ Write-Err "未能定位 eNSP 安装目录。请用 -EnspDir 手动指定。"; exit 1 }
$vbm = Find-VBoxManage $VBoxDir
if(-not $vbm){ Write-Err "未能定位 VBoxManage.exe。请用 -VBoxDir 手动指定。"; exit 1 }

# ---- 识别设备 ----
if(-not $Package){
    Write-Err "未指定设备包。请用 -Package 指向镜像(.img/.vdi)或它的 zip。"
    Write-Err "例:powershell -ExecutionPolicy Bypass -File import_device.ps1 -Package `"D:\设备包\USG6000V.zip`""
    exit 1
}
if(-not (Test-Path $Package)){ Write-Err "设备包不存在:$Package"; exit 1 }
$pkg = Get-Item $Package
$isZip = $pkg.Extension -ieq ".zip"

if(-not $Device){
    # 从文件名认设备:zip 用包名,否则用镜像名
    $probe = if($isZip){ $pkg.BaseName } else { $pkg.Name }
    foreach($k in $DEVICES.Keys){
        $img = $DEVICES[$k].Image
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($img)
        if($probe -ieq $stem -or $probe -ieq $img){ $Device = $k; break }
    }
    if(-not $Device){
        # 再退回按镜像名匹配(例如 USG6000V.zip 里是 vfw_usg.vdi)
        foreach($k in $DEVICES.Keys){
            if($probe -match 'USG6000V' -and $k -eq 'fw'){ $Device = $k; break }
        }
    }
    if(-not $Device){
        Write-Err "无法从 `"$probe`" 判断是哪个设备,请用 -Device 指定。"
        Write-Err ("可选:" + (($DEVICES.Keys | ForEach-Object { "$_($($DEVICES[$_].Label))" }) -join "  "))
        exit 1
    }
}
if(-not $DEVICES.Contains($Device)){
    Write-Err "未知设备 '$Device'。可选:$(($DEVICES.Keys) -join ', ')"
    exit 1
}
$dev     = $DEVICES[$Device]
$dbDir   = Join-Path $ensp $dev.DbDir
$imgDest = Join-Path $dbDir $dev.Image
$tplPath = Join-Path $ensp $dev.Tpl
$vmName  = $dev.VmName
$snapName = "${vmName}_Link"

if(-not (Test-Path $tplPath)){
    Write-Err "eNSP 目录下缺模板:$tplPath"
    Write-Err "该机可能没装对应插件,或 eNSP 安装不完整。"
    exit 1
}

$running = Get-RunningVMs $vbm
if($running.ContainsKey($vmName)){
    Write-Err "$vmName 正在运行。请先在 eNSP / VirtualBox 里关掉用到它的拓扑,再重跑本脚本。"
    exit 1
}
$registered = Get-RegisteredVMs $vbm
$alreadyReg = $registered.ContainsKey($vmName)

# 防火墙要把 VM 配置生成到 vfw_usg\ 子目录;其余五台原地注册模板
$vmBox = if($dev.RelTpl){ $tplPath } else { Join-Path (Join-Path $ensp "plugin\ngfw\tools\ngfw\vfw_usg") "vfw_usg.vbox" }

Write-Host "eNSP       : $ensp"
Write-Host "VBoxManage : $vbm"
Write-Host "设备       : $($dev.Label)  (VM 名 $vmName)"
Write-Host "设备包     : $($pkg.FullName)  ($([math]::Round($pkg.Length/1MB,1)) MB$(if($isZip){", zip"}))"

# ---- 文件阶段(需管理员) ----
function Invoke-FileStage {
    Write-Step "写入镜像与 VM 配置(需要管理员权限)"
    New-Item -ItemType Directory -Force $dbDir | Out-Null

    if($isZip){
        Write-Info "从 zip 取出 $($dev.Image) -> $imgDest"
        $r = Expand-ImageFromZip $pkg.FullName $dev.Image $imgDest
        if($r.Skipped){ Write-Info "镜像已就位(大小一致),跳过解压" }
        else { Write-OK "镜像已就位($([math]::Round($r.Length/1MB,1)) MB)" }
    } else {
        if($pkg.Name -ine $dev.Image){
            Write-Warn "文件名不叫 $($dev.Image),按内容当作 $($dev.Label) 的镜像处理,落地时改名为 $($dev.Image)"
        }
        if($pkg.Length -lt 100MB){
            Write-Err "文件偏小($([math]::Round($pkg.Length/1MB,1)) MB),不像是设备镜像。"
            exit 1
        }
        $need = $true
        if(Test-Path $imgDest){
            if((Get-FileHash $imgDest -Algorithm SHA256).Hash -eq (Get-FileHash $pkg.FullName -Algorithm SHA256).Hash){
                $need = $false; Write-Info "镜像已就位(哈希一致),跳过复制"
            } else { Write-Warn "已存在一份不同的 $($dev.Image),将被覆盖:$imgDest" }
        }
        if($need){
            Write-Info "复制镜像 -> $imgDest"
            Copy-Item $pkg.FullName $imgDest -Force
            Write-OK "镜像已就位($([math]::Round((Get-Item $imgDest).Length/1MB,1)) MB)"
        }
    }

    if($dev.RelTpl){ return }   # 原地注册模板,无需生成配置

    # 防火墙:以 eNSP 自带模板为蓝本,把磁盘路径改成绝对路径。
    # 模板里的 ../../DataBase/ 是按配置放在 tools\ngfw\ 根目录解析的;本脚本把配置
    # 放进 vfw_usg\ 子目录,相对路径会指错地方。
    #
    # 【已注册的绝不覆盖】:注册后那份 .vbox 归 VirtualBox 管,里面有快照段、可能还有
    # 正在被克隆挂着的差分盘。拿模板覆盖会把快照段冲掉(表现为重跑一次脚本就换一个
    # vfw_usg_Link),克隆链也可能跟着断。
    if($alreadyReg -and (Test-Path $vmBox)){
        Write-Info "$vmName 已注册,沿用现有 VM 配置(不覆盖,以免丢掉已有快照)"
        return
    }
    $vmDir = Split-Path $vmBox -Parent
    New-Item -ItemType Directory -Force $vmDir | Out-Null
    $text = Get-Content $tplPath -Raw
    $abs  = $imgDest.Replace('\','/')
    $new  = $text -replace 'location="[^"]*vfw_usg\.vdi"', "location=`"$abs`""
    if($new -notmatch [regex]::Escape($abs)){
        Write-Err "生成 VM 配置失败:模板里没找到预期形状的磁盘路径。"
        Write-Err "模板:$tplPath"
        exit 1
    }
    [System.IO.File]::WriteAllText($vmBox, $new, (New-Object System.Text.UTF8Encoding($false)))
    Write-OK "VM 配置已生成:$vmBox"
}

$isAdmin = Test-IsAdmin

if($Check){
    Write-Step "检测(只看,不改动)"
    Write-Info "设备      : $($dev.Label)  (VM 名 $vmName)"
    Write-Info "设备包    : $($pkg.FullName)$(if($isZip){"  (zip,将取出 $($dev.Image))"})"
    Write-Info "镜像      : $(if(Test-Path $imgDest){"已就位"}else{"未就位 -> 将写入 $imgDest"})"
    if(-not $dev.RelTpl){
        Write-Info "VM 配置   : $(if(Test-Path $vmBox){"已存在"}else{"未生成 -> 将写入 $vmBox"})"
    }
    Write-Info "VM 注册   : $(if($alreadyReg){"$vmName 已注册"}else{"未注册 -> 将注册 $vmBox"})"
    if($dev.Snap -and $alreadyReg){
        Write-Info "快照      : $(if(Has-Snapshot $vbm $vmName $snapName){"$snapName 已存在"}else{"缺 $snapName -> 将补建"})"
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
    $a = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$self`"",
           "-Package","`"$($pkg.FullName)`"","-Device","$Device","-StageFiles",
           "-EnspDir","`"$ensp`"","-VBoxDir","`"$([System.IO.Path]::GetDirectoryName($vbm))`"")
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList ($a -join " ") `
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
Write-Step "第 2 步 / 共 2 步:注册 $vmName$(if($dev.Snap){" 并补建快照"})"

$registered = Get-RegisteredVMs $vbm
if($registered.ContainsKey($vmName)){
    Write-Info "$vmName 已注册,沿用现有注册项(不注销重注册)"
} else {
    $r = & $vbm registervm $vmBox 2>&1
    if($LASTEXITCODE -ne 0){
        Write-Err "注册失败:$r"
        Write-Err "手动重试:VBoxManage registervm `"$vmBox`""
        exit 1
    }
    Write-OK "已注册 $vmName"
}

if($dev.Snap){
    if(Has-Snapshot $vbm $vmName $snapName){
        Write-OK "快照 $snapName 已存在,保持不动"
    } else {
        Write-Info "补建链接克隆快照 $snapName"
        $out = ""
        try {
            $old = $ErrorActionPreference
            $ErrorActionPreference = "Continue"   # 进度条走 stderr,别让它中断脚本
            $out = (& $vbm snapshot "$vmName" take "$snapName" 2>$null | Out-String)
        } catch { $out = "" } finally { $ErrorActionPreference = $old }
        if(($out -notmatch 'Snapshot taken') -and -not (Has-Snapshot $vbm $vmName $snapName)){
            Write-Err "补建快照失败。手动重试:VBoxManage snapshot $vmName take $snapName"
            exit 1
        }
        Write-OK "已补建快照 $snapName"
    }
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "  $($dev.Label) 设备包导入完成。启动 eNSP,拉一台出来试试。" -ForegroundColor Green
Write-Host "  撤销:VBoxManage unregistervm $vmName  (不加 --delete 不动磁盘)" -ForegroundColor Gray
Write-Host "============================================================`n" -ForegroundColor Green
