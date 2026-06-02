<#
.SYNOPSIS
    注册 / 重注册 eNSP 基础设备 VM 到 VirtualBox 7.x。

.DESCRIPTION
    eNSP 在 VirtualBox 7.x 上无法自动注册基础设备 VM(AR_Base / WLAN_*_Base),
    必须手动或用脚本补注册。本脚本扫描 eNSP\vboxserver\ 下的已知基础盘:
      - 未注册的 -> 直接注册;
      - 已注册的 -> 先注销(不加 --delete,不动磁盘)再用同一 .vbox 重注册,
                    清掉 eNSP 留下的"不可访问/半坏"注册状态。

    可逆:注销不带 --delete,只移除注册项,磁盘文件原封不动。
    安全:正在运行的 VM 会被跳过(不强行注销);重注册失败会打印恢复命令。

    用法(一般经 注册设备.bat 调用):
      powershell -ExecutionPolicy Bypass -File register_vms.ps1          # 注册/重注册
      powershell -ExecutionPolicy Bypass -File register_vms.ps1 -Check   # 只看会做什么

    可选 -EnspDir / -VBoxDir 手动指定路径(自动检测失败时)。

    注意:本脚本【不提权】。VM 注册写入当前用户的 .VirtualBox\VirtualBox.xml,
    必须与平时启动 eNSP 的账户一致;用管理员身份跑可能写进别的账户、eNSP 看不到。
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [string]$EnspDir = "",
    [string]$VBoxDir = ""
)

$ErrorActionPreference = "Stop"

# eNSP 的 5 个基础设备 VM(vboxserver 下的目录名即 VM 名)
$BASE_VMS = @("AR_Base","WLAN_AC_Base","WLAN_AD_Base","WLAN_AP_Base","WLAN_SAP_Base")

function Write-Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Info($m){ Write-Host "  [..] $m" -ForegroundColor Gray }
function Write-Warn($m){ Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Write-Err($m) { Write-Host "  [XX] $m" -ForegroundColor Red }

function Find-EnspDir([string]$Override){
    if($Override){
        if(Test-Path (Join-Path $Override "vboxserver")){ return $Override.TrimEnd('\') }
        Write-Err "指定的 eNSP 目录无效(缺 vboxserver\): $Override"; exit 1
    }
    $roots=@(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")
    foreach($r in $roots){
        if(-not(Test-Path $r)){ continue }
        $hit=Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
            $p=Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if($p.DisplayName -like "*eNSP*" -and $p.InstallLocation){ $p.InstallLocation }
        } | Where-Object { $_ -and (Test-Path (Join-Path $_ "vboxserver")) } | Select-Object -First 1
        if($hit){ return $hit.TrimEnd('\') }
    }
    foreach($d in @((Join-Path ${env:ProgramFiles(x86)} "Huawei\eNSP"),(Join-Path $env:ProgramFiles "Huawei\eNSP"))){
        if($d -and (Test-Path (Join-Path $d "vboxserver"))){ return $d.TrimEnd('\') }
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

# name -> uuid(已注册)
function Get-RegisteredUuids($vbm){
    $m=@{}
    foreach($line in (& $vbm list vms 2>$null)){
        if($line -match '^"([^"]+)"\s+\{([0-9a-fA-F-]+)\}'){ $m[$Matches[1]]=$Matches[2].ToLower() }
    }
    return $m
}

# uuid -> src(从 VirtualBox.xml 的 MachineRegistry 直接读,快且权威,避开慢的 showvminfo)
function Get-UuidSrcMap(){
    $vbHome=$env:VBOX_USER_HOME
    if(-not $vbHome){ $vbHome=Join-Path $env:USERPROFILE ".VirtualBox" }
    $xml=Join-Path $vbHome "VirtualBox.xml"
    $m=@{}
    if(-not(Test-Path $xml)){ return $m }
    $txt=Get-Content $xml -Raw -ErrorAction SilentlyContinue
    foreach($mt in [regex]::Matches($txt,'uuid="\{([0-9a-fA-F-]+)\}"\s+src="([^"]+)"')){
        $m[$mt.Groups[1].Value.ToLower()]=$mt.Groups[2].Value
    }
    return $m
}

# 运行中的 VM 名集合
function Get-RunningVMs($vbm){
    $s=@{}
    foreach($line in (& $vbm list runningvms 2>$null)){
        if($line -match '^"([^"]+)"'){ $s[$Matches[1]]=$true }
    }
    return $s
}

# 目录里要注册的 .vbox:文件名最短的有效机器配置(更长后缀的是历史残留副本)
function Select-VBoxFile([string]$dir){
    $cands=Get-ChildItem -Path $dir -Filter *.vbox -File -ErrorAction SilentlyContinue | Sort-Object { $_.Name.Length }
    foreach($f in $cands){
        $t=Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if($t -match '<Machine '){ return $f.FullName }
    }
    return $null
}

# ---- 主流程 ----
$ensp=Find-EnspDir $EnspDir
if(-not $ensp){ Write-Err "未能定位 eNSP 安装目录。请用 -EnspDir 手动指定。"; exit 1 }
$vbm=Find-VBoxManage $VBoxDir
if(-not $vbm){ Write-Err "未能定位 VBoxManage.exe。请用 -VBoxDir 手动指定。"; exit 1 }
$vbsrv=Join-Path $ensp "vboxserver"

Write-Host "eNSP       : $ensp"
Write-Host "VBoxManage : $vbm"
Write-Host "注册写入   : 当前用户的 .VirtualBox\VirtualBox.xml(须与启动 eNSP 的账户一致)"

$uuids=Get-RegisteredUuids $vbm
$srcmap=Get-UuidSrcMap
$running=Get-RunningVMs $vbm

Write-Step $(if($Check){"检测(只看,不改动)"}else{"注册 / 重注册基础设备 VM"})
$reg=0; $rereg=0; $skiprun=0; $miss=0
foreach($vm in $BASE_VMS){
    $dir=Join-Path $vbsrv $vm
    if(-not(Test-Path $dir)){ Write-Info "$vm : 无此目录,跳过(未装该设备包)"; $miss++; continue }
    if($running.ContainsKey($vm)){ Write-Warn "$vm : 正在运行,跳过(请先在 eNSP/VBox 里关掉再跑本脚本)"; $skiprun++; continue }

    $isReg=$uuids.ContainsKey($vm)

    # 目标 .vbox:已注册的优先沿用当前注册路径(最忠实),拿不到再回退最短有效 .vbox
    $target=$null
    if($isReg){
        $u=$uuids[$vm]
        if($srcmap.ContainsKey($u) -and (Test-Path $srcmap[$u])){ $target=$srcmap[$u] }
    }
    if(-not $target){ $target=Select-VBoxFile $dir }
    if(-not $target){ Write-Warn "$vm : 目录里没有有效的 .vbox,跳过"; $miss++; continue }

    if($isReg){
        if($Check){ Write-Info "$vm : 已注册 -> 将【先注销再重注册】-> $target"; $rereg++; continue }
        $u1=& $vbm unregistervm "$vm" 2>&1
        if($LASTEXITCODE -ne 0){ Write-Err "$vm : 注销失败,未改动:$u1"; continue }
        $r1=& $vbm registervm "$target" 2>&1
        if($LASTEXITCODE -eq 0){ Write-OK "$vm : 已重注册 -> $(Split-Path $target -Leaf)"; $rereg++ }
        else{
            Write-Err "$vm : 重注册失败!该 VM 现处于已注销状态。请手动恢复:"
            Write-Err "       VBoxManage registervm `"$target`""
            Write-Err "       VBox 报错:$r1"
        }
    } else {
        if($Check){ Write-Info "$vm : 未注册 -> 将注册 -> $target"; $reg++; continue }
        $r2=& $vbm registervm "$target" 2>&1
        if($LASTEXITCODE -eq 0){ Write-OK "$vm : 已注册 -> $(Split-Path $target -Leaf)"; $reg++ }
        else{ Write-Err "$vm : 注册失败:$r2" }
    }
}

Write-Step "当前已注册的 VM"
& $vbm list vms 2>$null | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "  $_" }

Write-Host ""
if($Check){ Write-Host "检测完成:待注册 $reg,待重注册 $rereg,运行中跳过 $skiprun,缺目录/无配置 $miss。" -ForegroundColor Green }
else{ Write-Host "完成:新注册 $reg,重注册 $rereg,运行中跳过 $skiprun,缺目录/无配置 $miss。" -ForegroundColor Green }
Write-Host "撤销某台:VBoxManage unregistervm `"<VM名>`"(不加 --delete 不会动磁盘)。" -ForegroundColor Gray
