# Requires: . build/tests/harness.ps1 ; . installer/checks.ps1
Write-Host "=== Task 1: VBoxDrvInst list parser ==="

$healthy = Get-Content (Get-TestDataPath "vboxdrvinst_healthy.txt")
$missing = Get-Content (Get-TestDataPath "vboxdrvinst_missing.txt")

$r = Parse-VBoxDrvInstList -Lines $healthy
Assert-True  $r.NetAdpPresent "healthy: NetAdp present"
Assert-True  $r.NetLwfPresent "healthy: NetLwf present"
Assert-False $r.MissingBoth   "healthy: not missing both"

$r2 = Parse-VBoxDrvInstList -Lines $missing
Assert-False $r2.NetAdpPresent "missing: NetAdp absent"
Assert-False $r2.NetLwfPresent "missing: NetLwf absent"
Assert-True  $r2.MissingBoth   "missing: flags both missing"

Complete-TestRun
