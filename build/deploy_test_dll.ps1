# deploy_test_dll.ps1 -- copy an experimental VBox52.dll into all 4 eNSP load
# locations, or roll back from the .pre-test.bak copies. A/B bisect helper only;
# NOT the real installer.
#
#   powershell -ExecutionPolicy Bypass -File deploy_test_dll.ps1 -Dll .\VBox52_noinject.dll
#   powershell -ExecutionPolicy Bypass -File deploy_test_dll.ps1 -Restore
#
# Needs administrator rights (writes to Program Files). On first deploy each
# existing VBox52.dll is saved as <name>.pre-test.bak; -Restore only reads those
# .pre-test.bak files and touches no other backup.
param(
    [string]$Dll,
    [switch]$Restore,
    [string]$EnspDir = "C:\Program Files\Huawei\eNSP"
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] Administrator rights required." -ForegroundColor Red
    exit 1
}

$running = Get-Process -Name eNSP_Client, eNSP_VBoxServer -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "[!] eNSP is running. Close it first (the DLL is loaded in-process)." -ForegroundColor Red
    exit 1
}

# All 4 load locations inside the eNSP tree.
$targets = @(
    (Join-Path $EnspDir "tools\VBox52.dll"),
    (Join-Path $EnspDir "vboxserver\VBox52.dll"),
    (Join-Path $EnspDir "VBox52.dll"),
    (Join-Path $EnspDir "plugin\ngfw\tools\ngfw\VBox52.dll")
)

function Sha([string]$p) {
    if (-not (Test-Path $p)) { return "(missing)" }
    (Get-FileHash $p -Algorithm SHA256).Hash.ToLower().Substring(0, 16)
}

if ($Restore) {
    Write-Host "=== rollback ===" -ForegroundColor Cyan
    foreach ($t in $targets) {
        $bak = "$t.pre-test.bak"
        if (Test-Path $bak) {
            Copy-Item $bak $t -Force
            Write-Host ("  {0}" -f $t.Replace($EnspDir, '<eNSP>'))
            Write-Host ("    restored from .pre-test.bak , sha256 = {0}" -f (Sha $t))
        } else {
            Write-Host ("  {0}  no .pre-test.bak, skipped" -f $t.Replace($EnspDir, '<eNSP>')) -ForegroundColor Yellow
        }
    }
    Write-Host "[+] rollback done."
    exit 0
}

if (-not $Dll) { Write-Host "[!] pass -Dll <path> or -Restore"; exit 1 }
if (-not (Test-Path $Dll)) { Write-Host "[!] not found: $Dll"; exit 1 }
$src = (Resolve-Path $Dll).Path

Write-Host ("=== deploy {0}" -f (Split-Path $src -Leaf)) -ForegroundColor Cyan
Write-Host ("  source sha256 = {0}" -f (Get-FileHash $src -Algorithm SHA256).Hash.ToLower())
foreach ($t in $targets) {
    if (Test-Path $t) {
        $bak = "$t.pre-test.bak"
        if (-not (Test-Path $bak)) { Copy-Item $t $bak -Force }
        Write-Host ("  {0}   old={1}  new={2}" -f $t.Replace($EnspDir, '<eNSP>'), (Sha $t), (Sha $src))
    } else {
        Write-Host ("  {0}  target missing, writing anyway" -f $t.Replace($EnspDir, '<eNSP>')) -ForegroundColor Yellow
    }
    Copy-Item $src $t -Force
}
Write-Host "[+] done. Start eNSP and test. Roll back with -Restore."
