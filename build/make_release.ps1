# make_release.ps1 -- 生成发布包 Releases\ensp-vbox-shim-installer-<version>.zip
#
#   powershell -ExecutionPolicy Bypass -File build\make_release.ps1 -Version v0.2.0
#   powershell -ExecutionPolicy Bypass -File build\make_release.ps1 -Version v0.2.0 -Force
#
# 开发侧脚本,不随发布包分发。职责三件:
#
#   1. 按**显式白名单**从 installer\ 收集文件,不做目录扫描。installer\ 下有
#      .claude-flow\ 这类不该发布的目录,扫描会误收;白名单则相反 —— 漏收一个
#      文件必须表现为本文件的一次显式改动,而不是 zip 内容悄悄变少。
#
#   2. 校验 payload\ 下 DLL 的 SHA256 与 install.ps1 里的常量一致。这个坑发生过:
#      v0.1.3 重编译 VBox52.dll 后未同步 $DLL_SHA256,用户机器上装到一半报
#      "哈希不符"并退出。校验不过就不产出 zip —— 一个装不上的 zip 比没有 zip 更糟。
#
#   3. 校验中文文件名在 zip 中未损坏,再输出 zip 的 SHA256 与字节数,供 release
#      notes 引用。原 build\verify_zip_names.ps1 只验单一硬编码版本,逻辑已并入本
#      脚本并按 -Version 参数化,该文件随之删除。
#
# install.ps1 只按文本解析,绝不 dot-source:它顶层有副作用(建日志目录、开
# transcript,末尾还会按参数分支去跑 Do-Install / Do-Check / Do-Uninstall)。
# 同理,本脚本也不会去执行 install.ps1。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Version,

    # 发布件是对外产物,默认拒绝覆盖;确认要重打才加 -Force。
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

# ---------------------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------------------
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "  [..] $msg" -ForegroundColor Gray }
function Write-Warn($msg) { Write-Host "  [!!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [XX] $msg" -ForegroundColor Red }

# 临时 zip 的路径。失败路径要靠它清理,所以放脚本作用域,Fail 里能读到。
$script:TmpZip = $null

function Fail($msg) {
    Write-Err $msg
    if ($script:TmpZip -and (Test-Path -LiteralPath $script:TmpZip)) {
        Remove-Item -LiteralPath $script:TmpZip -Force -ErrorAction SilentlyContinue
    }
    Write-Host ""
    Write-Host "打包中止,未产出 zip。" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 路径与版本
# ---------------------------------------------------------------------------
$BuildDir     = $PSScriptRoot
$RepoRoot     = Split-Path -Parent $BuildDir
$InstallerDir = Join-Path $RepoRoot 'installer'
$ReleasesDir  = Join-Path $RepoRoot 'Releases'
$InstallPs1   = Join-Path $InstallerDir 'install.ps1'

if (-not (Test-Path -LiteralPath $InstallerDir -PathType Container)) {
    Fail ("找不到 installer 目录: " + $InstallerDir)
}
if (-not (Test-Path -LiteralPath $InstallPs1 -PathType Leaf)) {
    Fail ("找不到 install.ps1: " + $InstallPs1)
}

$ver = $Version.Trim()
if ($ver -match '^[vV]') { $ver = 'v' + $ver.Substring(1) } else { $ver = 'v' + $ver }
# 版本号会进文件名,先卡死形状,顺带挡掉路径穿越。
if ($ver -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$') {
    Fail ("版本号格式不合法: '" + $Version + "'。期望形如 v0.2.0 或 v0.2.0-beta。")
}

$ZipName = "ensp-vbox-shim-installer-$ver.zip"
$ZipPath = Join-Path $ReleasesDir $ZipName
$NotesPath = Join-Path $ReleasesDir ("ensp-vbox-shim-installer-" + $ver + ".md")

Write-Step ("打包 ensp-vbox-shim " + $ver)
Write-Info ("installer\ : " + $InstallerDir)
Write-Info ("产物       : " + $ZipPath)

# ---------------------------------------------------------------------------
# 覆盖保护 —— 在动手之前就判,别等 zip 都打好了才拒绝
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $ZipPath -PathType Leaf) {
    if (-not $Force) {
        Write-Err ("已存在同名发布件: " + $ZipPath)
        Write-Host "        发布件一旦对外,静默替换不可回收。确认要重打请加 -Force。" -ForegroundColor Red
        Write-Host ""
        Write-Host "打包中止,未产出 zip。" -ForegroundColor Red
        exit 1
    }
    Write-Warn ("-Force: 将覆盖已存在的 " + $ZipName)
}

# ---------------------------------------------------------------------------
# 1. 白名单
# ---------------------------------------------------------------------------
# 顺序即 zip 内顺序;'/' 是 zip 内的分隔符,取源文件时再换成 '\'。
# 布局对齐既有发布件:发布内容平铺在 zip 根,payload\ 保持子目录。
$Allowlist = @(
    # --- 顶层:文档 + 入口脚本 ---
    'README.md'
    'install.ps1'            # 安装/卸载主体(卸载.bat 走 -Uninstall)
    'install_all.ps1'        # 安装.bat 的入口
    'checks.ps1'             # 只读探测库,被 install.ps1 / diag.ps1 / fix.ps1 dot-source
    'cleanup_orphans.ps1'    # 清理残留.bat 的入口
    'register_vms.ps1'       # 注册设备.bat 的入口
    'diag.ps1'               # 环境检查.bat 的入口
    'fix.ps1'                # 修复原语,由 diag.ps1 dot-source
    'tui.ps1'                # 控制台交互层,由 diag.ps1 在可能进菜单时 dot-source
    # --- 顶层:中文名入口(编码已在下方往返校验里守住) ---
    '安装.bat'
    '卸载.bat'
    '注册设备.bat'
    '清理残留.bat'
    '环境检查.bat'
    # --- payload ---
    'payload/VBox52.dll'
    'payload/VAR_Plugin.dll'
    'payload/msvcrt-x86/VCRUNTIME140.dll'
    'payload/msvcrt-x86/MSVCP140.dll'
)

Write-Step ("收集文件(白名单 " + $Allowlist.Count + " 项)")
$missing = @()
foreach ($rel in $Allowlist) {
    $src = Join-Path $InstallerDir ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { $missing += $rel }
}
if ($missing.Count -gt 0) {
    Write-Err ("白名单里有 " + $missing.Count + " 个文件在 installer\ 下不存在:")
    foreach ($m in $missing) { Write-Host ("        " + $m) -ForegroundColor Red }
    Fail "白名单与 installer\ 实际内容不一致,先补齐文件或改白名单。"
}
Write-OK ([string]$Allowlist.Count + " 项全部就位")

# ---------------------------------------------------------------------------
# 2. 从 install.ps1 里解析哈希常量(纯文本,不 dot-source)
# ---------------------------------------------------------------------------
Write-Step "解析 install.ps1 的哈希常量(文本解析,不执行该脚本)"
$instText = Get-Content -LiteralPath $InstallPs1 -Raw

function Get-HashConstant($Text, $Name) {
    $pattern = '\$' + [regex]::Escape($Name) + '\s*=\s*"([0-9A-Fa-f]{64})"'
    $m = [regex]::Match($Text, $pattern)
    if (-not $m.Success) {
        Fail ("install.ps1 里找不到常量 `$" + $Name + "(或它的值不是 64 位十六进制串)")
    }
    return $m.Groups[1].Value.ToLower()
}

# 期望值 = install.ps1 的常量;文件路径 = payload 内的相对路径
$expected = @()
$expected += @{
    Path  = 'payload/VBox52.dll'
    Hash  = (Get-HashConstant $instText 'DLL_SHA256')
    Const = '$DLL_SHA256'
}
$expected += @{
    Path  = 'payload/VAR_Plugin.dll'
    Hash  = (Get-HashConstant $instText 'VARP_SHA256')
    Const = '$VARP_SHA256'
}

# $VCRT_X86_FILES 是 @{ Name = "..."; Hash = "..." } 的数组,逐对抠出来。
$vcrBlock = [regex]::Match($instText, '\$VCRT_X86_FILES\s*=\s*@\((?<body>.*?)\r?\n\)', 'Singleline')
if (-not $vcrBlock.Success) { Fail 'install.ps1 里找不到 $VCRT_X86_FILES 数组' }
$vcrPairs = [regex]::Matches($vcrBlock.Groups['body'].Value,
                             'Name\s*=\s*"([^"]+)"\s*;\s*Hash\s*=\s*"([0-9A-Fa-f]{64})"')
if ($vcrPairs.Count -eq 0) { Fail '$VCRT_X86_FILES 里没解析出任何 Name/Hash 对' }
foreach ($p in $vcrPairs) {
    $expected += @{
        Path  = ('payload/msvcrt-x86/' + $p.Groups[1].Value)
        Hash  = $p.Groups[2].Value.ToLower()
        Const = ('$VCRT_X86_FILES[' + $p.Groups[1].Value + ']')
    }
}
foreach ($e in $expected) { Write-Info ($e.Const + "  ->  " + $e.Path) }

# payload 白名单里每个文件都必须被某个常量覆盖 —— 将来往白名单加了 payload 文件
# 却忘了在 install.ps1 里加常量,这里就会挡住。
$covered = @($expected | ForEach-Object { $_.Path })
$uncovered = @($Allowlist | Where-Object { $_ -like 'payload/*' } | Where-Object { $covered -notcontains $_ })
if ($uncovered.Count -gt 0) {
    Write-Err "白名单里的这些 payload 文件没有任何哈希常量覆盖:"
    foreach ($u in $uncovered) { Write-Host ("        " + $u) -ForegroundColor Red }
    Fail "install.ps1 缺少对应常量(或常量名/格式变了)。"
}

# ---------------------------------------------------------------------------
# 3. 校验哈希 —— 期望值取自 install.ps1,实际值取自文件,单向比对
# ---------------------------------------------------------------------------
Write-Step "校验 payload 哈希"
$mismatch = 0
foreach ($e in $expected) {
    $src    = Join-Path $InstallerDir ($e.Path -replace '/', '\')
    $actual = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLower()
    if ($actual -eq $e.Hash) {
        Write-OK ($e.Path + "  " + $actual)
    } else {
        $mismatch++
        Write-Err ($e.Path + "  哈希不符")
        Write-Host ("        期望(install.ps1 的 " + $e.Const + "): " + $e.Hash)   -ForegroundColor Red
        Write-Host ("        实际(" + $src + "): " + $actual) -ForegroundColor Red
    }
}
if ($mismatch -gt 0) {
    Fail ("有 " + $mismatch + " 个 payload 文件与 install.ps1 的常量不符。" +
          "重编译过 DLL 就要同步改 install.ps1 里的常量,否则用户机器上会报'哈希不符'并退出。")
}
Write-OK ([string]$expected.Count + " 个 payload 文件的哈希与 install.ps1 一致")

# ---------------------------------------------------------------------------
# 4. 生成 zip
# ---------------------------------------------------------------------------
Write-Step "生成 zip"
if (-not (Test-Path -LiteralPath $ReleasesDir -PathType Container)) {
    New-Item -ItemType Directory -Path $ReleasesDir | Out-Null
}

# 先写到临时文件,全部校验通过后再落到 Releases\ —— 失败路径下 Releases\ 不留半成品。
$script:TmpZip = Join-Path $env:TEMP ("make_release_" + $ver + "_" + [Guid]::NewGuid().ToString('N') + ".zip")
$tmpZip = $script:TmpZip

try {
    $fs = [System.IO.File]::Open($tmpZip, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        # 注意:这里**不传** entryNameEncoding。默认构造遇到非 ASCII 名字时会写 UTF-8
        # 字节并置通用位 11(UTF-8 标志);而显式传 [Text.Encoding]::UTF8 反而只写
        # UTF-8 字节、不置位 —— 解压端(资源管理器 / Expand-Archive)会按本地 ANSI
        # 代码页(简中 = GBK)去解读,中文名当场变乱码。两种写法都实测过,见提交说明。
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($rel in $Allowlist) {
                $src   = Join-Path $InstallerDir ($rel -replace '/', '\')
                $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = (Get-Item -LiteralPath $src).LastWriteTime
                $out = $entry.Open()
                try {
                    $bytes = [System.IO.File]::ReadAllBytes($src)
                    $out.Write($bytes, 0, $bytes.Length)
                } finally { $out.Dispose() }
                Write-Info ($rel + "  " + $bytes.Length + " 字节")
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }

    # -----------------------------------------------------------------------
    # 5. 读回 zip,校验条目集合与中文名往返
    # -----------------------------------------------------------------------
    Write-Step "读回 zip,校验条目与中文文件名"

    # 走中央目录,不逐字节扫 local file header —— 后者会在压缩数据里撞出假签名。
    $zb = [System.IO.File]::ReadAllBytes($tmpZip)
    $eocd = -1
    for ($i = $zb.Length - 22; $i -ge 0; $i--) {
        if ([BitConverter]::ToUInt32($zb, $i) -eq 0x06054b50) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { Fail ("zip 里找不到中央目录(End of Central Directory): " + $tmpZip) }

    $entryCount = [BitConverter]::ToUInt16($zb, $eocd + 10)
    $p = [int][BitConverter]::ToUInt32($zb, $eocd + 16)
    $entries = @()
    for ($n = 0; $n -lt $entryCount; $n++) {
        if ([BitConverter]::ToUInt32($zb, $p) -ne 0x02014b50) {
            Fail ("zip 中央目录结构异常,偏移 " + $p)
        }
        $flags = [BitConverter]::ToUInt16($zb, $p + 8)
        $nlen  = [BitConverter]::ToUInt16($zb, $p + 28)
        $elen  = [BitConverter]::ToUInt16($zb, $p + 30)
        $clen  = [BitConverter]::ToUInt16($zb, $p + 32)
        $rawName = New-Object byte[] $nlen
        [Array]::Copy($zb, $p + 46, $rawName, 0, $nlen)
        $isAscii = $true
        foreach ($b in $rawName) { if ($b -gt 127) { $isAscii = $false; break } }
        $entries += @{
            Name  = [System.Text.Encoding]::UTF8.GetString($rawName)
            Bytes = (($rawName | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
            Utf8  = [bool]($flags -band 0x800)
            Ascii = $isAscii
        }
        $p = $p + 46 + $nlen + $elen + $clen
    }

    # 5a. 条目集合必须与白名单完全一致(不多、不少)
    if ($entryCount -ne $Allowlist.Count) {
        Fail ("zip 条目数 " + $entryCount + " 与白名单 " + $Allowlist.Count + " 不一致")
    }
    $bad = $false
    foreach ($rel in $Allowlist) {
        if (@($entries | ForEach-Object { $_.Name }) -notcontains $rel) {
            Write-Err ("zip 中缺条目: " + $rel); $bad = $true
        }
    }
    foreach ($e in $entries) {
        if ($Allowlist -notcontains $e.Name) {
            Write-Err ("zip 中有白名单之外的条目: " + $e.Name); $bad = $true
        }
    }
    if ($bad) { Fail "zip 内容与白名单不一致" }

    # 5b. 非 ASCII 名必须置 bit 11,且按 UTF-8 解出的码点要与白名单字面量逐字相等
    foreach ($e in $entries) {
        $cp = (($e.Name.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' ')
        if ($e.Ascii) {
            Write-Info ("ASCII  " + $e.Name)
        } elseif (-not $e.Utf8) {
            Write-Err ("中文名未置 UTF-8 标志(bit 11),解压端会按本地代码页解读: " + $e.Name)
            Write-Host ("        zip 内原始字节: " + $e.Bytes) -ForegroundColor Red
            Fail "中文文件名未按 UTF-8 标记,放弃打包。"
        } else {
            Write-OK ("UTF-8  " + $e.Name + "   码点 " + $cp)
        }
    }

    # 5c. 真解压一遍 —— 只验 zip 内部字节不够,要证明解压端拿到的就是这些名字
    $exDir = Join-Path $env:TEMP ("make_release_ex_" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $exDir | Out-Null
    try {
        Expand-Archive -Path $tmpZip -DestinationPath $exDir -Force
        foreach ($rel in $Allowlist) {
            $dst = Join-Path $exDir ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
                Fail ("解压往返失败,解不出: " + $rel)
            }
        }
        Write-OK ("解压往返 " + $Allowlist.Count + " 项全部还原成功")
    } finally {
        Remove-Item $exDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # -----------------------------------------------------------------------
    # 6. 落盘 + 输出指纹
    # -----------------------------------------------------------------------
    if (Test-Path -LiteralPath $ZipPath -PathType Leaf) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    Move-Item -LiteralPath $tmpZip -Destination $ZipPath -Force

    $fi   = Get-Item -LiteralPath $ZipPath
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLower()

    Write-Step "产物"
    Write-Host ("  路径   : " + $fi.FullName)
    Write-Host ("  条目   : " + $entryCount + " / 白名单 " + $Allowlist.Count)
    Write-Host ("  字节   : " + $fi.Length) -ForegroundColor Yellow
    Write-Host ("  SHA256 : " + $hash)     -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  上面两个值就是 release notes 要引用的:" -ForegroundColor Gray
    Write-Host ("    Size   : " + $fi.Length) -ForegroundColor Gray
    Write-Host ("    SHA256 : " + $hash)     -ForegroundColor Gray
    if (Test-Path -LiteralPath $NotesPath -PathType Leaf) {
        Write-Info ("发布说明已存在: " + $NotesPath + "(记得同步里面的字节数与 SHA256)")
    } else {
        Write-Info ("发布说明待写: " + $NotesPath)
    }
} finally {
    if (Test-Path -LiteralPath $script:TmpZip) {
        Remove-Item -LiteralPath $script:TmpZip -Force -ErrorAction SilentlyContinue
    }
}
