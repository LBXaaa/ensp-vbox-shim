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

Write-Host "=== Task 3: host-only layers 3-6 ==="

$ifsNormal = Get-Content (Get-TestDataPath "hostonlyifs_normal.txt")
$p = Parse-HostOnlyIfs -Lines $ifsNormal
Assert-Equal @($p).Count 1 "normal: one adapter"
Assert-Equal @($p)[0].Name "VirtualBox Host-Only Ethernet Adapter" "normal: clean name"
Assert-Equal @($p)[0].IPAddress "192.168.56.1" "normal: ip"
Assert-Equal @($p)[0].Status "Up" "normal: status"
Assert-Equal @($p)[0].VBoxNetworkName "HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter" "normal: vboxnetname"

$ifsSuffixed = Get-Content (Get-TestDataPath "hostonlyifs_suffixed.txt")
$p2 = Parse-HostOnlyIfs -Lines $ifsSuffixed
Assert-Match @($p2)[0].Name '#2$' "suffixed fixture keeps the suffix"

# Name comparison must flag the mismatch against the template name.
$cmp = Compare-HostOnlyName -VBoxNames @("VirtualBox Host-Only Ethernet Adapter #2") `
                            -TemplateNames @("VirtualBox Host-Only Ethernet Adapter")
Assert-True $cmp.HasMismatch "mismatch detected"
Assert-Equal $cmp.MatchedCount 0 "no match"

$cmpOk = Compare-HostOnlyName -VBoxNames @("VirtualBox Host-Only Ethernet Adapter") `
                              -TemplateNames @("VirtualBox Host-Only Ethernet Adapter")
Assert-False $cmpOk.HasMismatch "clean case has no mismatch"

Complete-TestRun
