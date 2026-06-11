<#
.SYNOPSIS
    注册 / 重注册 eNSP 基础设备 VM 到 VirtualBox 7.x。

.DESCRIPTION
    eNSP 安装时会自动注册基础设备 VM(AR_Base / WLAN_*_Base),全新安装的机器上注册
    本就是好的,通常无需跑本脚本。本脚本用于卸载重装等导致注册失效的情况:残留项与新
    基础盘 UUID 冲突,注册项会指向失效的旧路径或一块无快照的裸盘,设备报"错误 40"。

    本脚本扫描 eNSP\vboxserver\ 下的已知基础盘,按需操作:
      - 未注册的           -> 直接注册;
      - 已注册且路径正确的 -> 保持不动,只核对快照(不做无谓的注销/重注册);
      - 已注册但路径失效/指向残留 -> 先注销(不加 --delete,不动磁盘)再用当前 .vbox 重注册。
    随后核对链接克隆所需的 <VM>_Link 快照:缺失才补建,已存在的绝不改动
    (它可能正被现有克隆挂载);补快照前会确认 VM 处于关机状态,否则跳过并告警。

    可逆:注销不带 --delete,只移除注册项,磁盘文件与已有快照原封不动。
    安全:正在运行的 VM 会被跳过(不强行注销);重注册或补快照失败会打印恢复命令。

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

# 路径规整:用于比较两个路径是否指向同一个文件。VirtualBox.xml 里的 src 可能含
# 双反斜杠且大小写与磁盘不一致,故把连续反斜杠折叠为一个、去尾斜杠、转小写后再比较。
function Norm([string]$p){
    if(-not $p){ return "" }
    $s=$p.Trim() -replace '\\+','\'
    return $s.TrimEnd('\').ToLower()
}

# VM 当前电源状态(powermachinereadable 的 VMState),取不到返回 ""
function Get-VMState($vbm,[string]$vm){
    foreach($line in (& $vbm showvminfo "$vm" --machinereadable 2>$null)){
        if($line -match '^VMState="([^"]+)"'){ return $Matches[1] }
    }
    return ""
}

# 该 VM 是否已存在指定名字的快照
function Has-Snapshot($vbm,[string]$vm,[string]$snapName){
    $out = & $vbm snapshot "$vm" list --machinereadable 2>$null
    if($LASTEXITCODE -ne 0){ return $false }   # "does not have any snapshots" -> 非0
    foreach($line in $out){
        if($line -match '^SnapshotName(-[0-9]+)?="([^"]+)"' -and $Matches[2] -eq $snapName){ return $true }
    }
    return $false
}

# eNSP 链接克隆需要基础盘有名为 <VM>_Link 的快照。eNSP 安装时本应建好并写入 .vbox,
# 但若安装时撞 UUID 冲突(幽灵残留)注册失败,会留下无快照的裸盘 -> clonevm 报
# "does not have any snapshots" -> 设备起不来(error 40)。本函数仅在【缺失】时补建,
# 【绝不】删除或改动已存在的快照(它可能正被已有克隆挂载,删除会破坏克隆链)。
#
# 返回: "ok"(已有,未动) / "created"(补建成功) / "skip-running"(非poweroff跳过) /
#       "fail"(补建失败) / "no-vm"(VM不存在)
function Ensure-LinkSnapshot($vbm,[string]$vm,[bool]$checkOnly){
    $snap = "${vm}_Link"
    if(Has-Snapshot $vbm $vm $snap){ return "ok" }

    # 缺快照。补建前必须确认 VM 处于 poweroff —— 对在线/saved 状态拍快照会把
    # 内存状态拍进去,污染本应纯净的基础盘。
    $state = Get-VMState $vbm $vm
    if($state -eq ""){ return "no-vm" }
    if($state -ne "poweroff"){ return "skip-running" }

    if($checkOnly){ return "created" }   # -Check: 报告将补建,不实际动手

    # snapshot take 会把进度条(0%..100%)写到 stderr。在 $ErrorActionPreference=Stop
    # 下,原生 exe 只要往 stderr 写东西就会被 PS 包成 NativeCommandError 抛出并中断
    # 脚本(即便用 2>$null 也拦不住)。故此处局部降级为 Continue,并用 try 兜底,
    # 仅凭 stdout 的 "Snapshot taken" 判定成败。(unregister/register 不写进度条,不受影响。)
    $out = ""
    try {
        $old = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $out = (& $vbm snapshot "$vm" take "$snap" 2>$null | Out-String)
    } catch {
        $out = ""
    } finally {
        $ErrorActionPreference = $old
    }
    # VBoxManage 快照操作退出码不可靠,靠输出判断:成功必含 "Snapshot taken"
    if($out -match 'Snapshot taken'){ return "created" }
    # 输出没抓到关键字时,回查一次实际状态(take 可能成功了只是输出被吞)
    if(Has-Snapshot $vbm $vm $snap){ return "created" }
    return "fail"
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
$reg=0; $rereg=0; $skiprun=0; $miss=0; $snapMade=0; $snapWarn=0

# 注册成功后调用:确保基础盘有 <VM>_Link 快照(eNSP 链接克隆所必需),缺则补建。
# 更新 $script:snapMade / $script:snapWarn 计数。
function Reconcile-Snapshot([string]$vm){
    $s = Ensure-LinkSnapshot $vbm $vm $Check.IsPresent
    switch($s){
        "ok"           { }   # 已有快照,不动
        "created"      { if($Check){ Write-Info "$vm :   ↳ 缺 ${vm}_Link 快照 -> 将补建"; $script:snapMade++ }
                         else      { Write-OK   "$vm :   ↳ 已补建快照 ${vm}_Link"; $script:snapMade++ } }
        "skip-running" { Write-Warn "$vm :   ↳ 缺快照但 VM 非关机状态,跳过补建(请在 eNSP/VBox 里关掉后重跑)"; $script:snapWarn++ }
        "fail"         { Write-Err  "$vm :   ↳ 缺 ${vm}_Link 快照且补建失败!设备可能起不来。手动补建:"
                         Write-Err  "         VBoxManage snapshot `"$vm`" take `"${vm}_Link`""; $script:snapWarn++ }
        "no-vm"        { Write-Warn "$vm :   ↳ 查不到该 VM,无法检查快照"; $script:snapWarn++ }
    }
}

foreach($vm in $BASE_VMS){
    $dir=Join-Path $vbsrv $vm
    if(-not(Test-Path $dir)){ Write-Info "$vm : 无此目录,跳过(未装该设备包)"; $miss++; continue }
    if($running.ContainsKey($vm)){ Write-Warn "$vm : 正在运行,跳过(请先在 eNSP/VBox 里关掉再跑本脚本)"; $skiprun++; continue }

    $isReg=$uuids.ContainsKey($vm)

    # 目标 .vbox:已注册的优先沿用当前注册路径(最忠实),拿不到再回退最短有效 .vbox
    $target=$null
    $regSrc=$null
    if($isReg){
        $u=$uuids[$vm]
        if($srcmap.ContainsKey($u)){ $regSrc=$srcmap[$u] }
        if($regSrc -and (Test-Path $regSrc)){ $target=$regSrc }
    }
    if(-not $target){ $target=Select-VBoxFile $dir }
    if(-not $target){ Write-Warn "$vm : 目录里没有有效的 .vbox,跳过"; $miss++; continue }

    if($isReg){
        # 已注册。收紧:仅当注册状态确有问题(路径失效/指向别处)才注销重注册;
        # 路径正确则不动注册项,直接进入快照核对 —— 避免对好端端的 VM 做无谓的
        # 注销/重注册写操作(中途若出意外反而会把可用的 VM 弄成已注销状态)。
        $regPathOk = $regSrc -and (Test-Path $regSrc) -and ((Norm $regSrc) -eq (Norm $target))
        if($regPathOk){
            Write-Info "$vm : 已注册且路径正确,保留不动"
            Reconcile-Snapshot $vm
            continue
        }
        # 路径不对(指向已失效的旧路径/幽灵)-> 注销重注册到当前 .vbox
        if($Check){ Write-Info "$vm : 已注册但路径失效($regSrc)-> 将【注销并重注册】-> $target"; $rereg++; Reconcile-Snapshot $vm; continue }
        $u1=& $vbm unregistervm "$vm" 2>&1
        if($LASTEXITCODE -ne 0){ Write-Err "$vm : 注销失败,未改动:$u1"; continue }
        $r1=& $vbm registervm "$target" 2>&1
        if($LASTEXITCODE -eq 0){ Write-OK "$vm : 已重注册 -> $(Split-Path $target -Leaf)"; $rereg++; Reconcile-Snapshot $vm }
        else{
            Write-Err "$vm : 重注册失败!该 VM 现处于已注销状态。请手动恢复:"
            Write-Err "       VBoxManage registervm `"$target`""
            Write-Err "       VBox 报错:$r1"
        }
    } else {
        if($Check){ Write-Info "$vm : 未注册 -> 将注册 -> $target"; $reg++; Reconcile-Snapshot $vm; continue }
        $r2=& $vbm registervm "$target" 2>&1
        if($LASTEXITCODE -eq 0){ Write-OK "$vm : 已注册 -> $(Split-Path $target -Leaf)"; $reg++; Reconcile-Snapshot $vm }
        else{ Write-Err "$vm : 注册失败:$r2" }
    }
}

Write-Step "当前已注册的 VM"
& $vbm list vms 2>$null | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "  $_" }

Write-Host ""
if($Check){ Write-Host "检测完成:待注册 $reg,待重注册 $rereg,待补建快照 $snapMade,缺快照告警 $snapWarn,运行中跳过 $skiprun,缺目录/无配置 $miss。" -ForegroundColor Green }
else{
    $color = if($snapWarn -gt 0){"Yellow"}else{"Green"}
    Write-Host "完成:新注册 $reg,重注册 $rereg,补建快照 $snapMade,缺快照告警 $snapWarn,运行中跳过 $skiprun,缺目录/无配置 $miss。" -ForegroundColor $color
}
Write-Host "撤销某台:VBoxManage unregistervm `"<VM名>`"(不加 --delete 不会动磁盘)。" -ForegroundColor Gray
