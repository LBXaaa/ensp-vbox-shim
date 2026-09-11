# verify_zip_names.ps1 — 校验 zip 里的中文文件名解压后是否正确
# 只输出 ASCII 结果，避免控制台编码干扰判断。
$ErrorActionPreference = "Continue"
$zip = "F:\各种项目\逆向ensp\ensp-vbox-shim\Releases\ensp-vbox-shim-installer-v0.1.4-beta.zip"
$tmp = Join-Path $env:TEMP "zipnametest"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp | Out-Null

Expand-Archive -Path $zip -DestinationPath $tmp -Force

# 期望的中文文件名（本脚本带 BOM，字面量是准的）
$expected = @(
    "安装.bat",
    "卸载.bat",
    "注册设备.bat",
    "清理残留.bat"
)

$ok = 0
foreach ($n in $expected) {
    $p = Join-Path $tmp $n
    $exists = Test-Path -LiteralPath $p
    if ($exists) { $ok++ }
    Write-Output ("  " + $(if ($exists) { "OK  " } else { "MISS" }) + "  " + $n)
}

# 再反向列一遍实际落盘的名字，用码点表示（纯 ASCII 输出）
Write-Output "  --- actual entries (codepoints) ---"
Get-ChildItem -LiteralPath $tmp -File | Sort-Object Name | ForEach-Object {
    $cp = ($_.Name.ToCharArray() | ForEach-Object { "{0:X4}" -f [int]$_ }) -join " "
    Write-Output ("  " + $cp)
}

Write-Output ("RESULT: {0}/{1} expected names present" -f $ok, $expected.Count)
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
