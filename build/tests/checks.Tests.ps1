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

Write-Host "=== Task 2: host-only driver layers ==="

# Layer 1 uses the parser from Task 1, so the fixture drives the assertion.
$layers = Get-HostOnlyDriverLayers -DrvInstLines $missing
Assert-False $layers.Layer1.DriverRegistered "missing fixture: layer1 false"
Assert-False $layers.Layer1.NetAdpPresent    "missing fixture: netadp false"
Assert-False $layers.Layer1.NetLwfPresent    "missing fixture: netlwf false"

$layersOk = Get-HostOnlyDriverLayers -DrvInstLines $healthy
Assert-True $layersOk.Layer1.DriverRegistered "healthy fixture: layer1 true"

# VBoxDrv must never be reported as required.
Assert-False (Test-RequiredVBoxService -Name "VBoxDrv") "VBoxDrv is not required on 7.x"
Assert-True  (Test-RequiredVBoxService -Name "VBoxNetAdp") "VBoxNetAdp is required"

Complete-TestRun
