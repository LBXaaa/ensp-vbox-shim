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

Write-Host "=== Task 4: eNSP-native layer ==="

$fwLines = @(
    "DisplayName  : eNSP_VBoxServer",
    "Enabled      : True",
    "Direction    : Inbound",
    "Action       : Allow",
    "",
    "DisplayName  : SomethingElse",
    "Enabled      : True",
    "Direction    : Inbound",
    "Action       : Allow"
)
$fw = Parse-FirewallRulesForEnsp -Lines $fwLines
Assert-True  $fw.HasAllowRule "allow rule for eNSP_VBoxServer found"

$fwNone = Parse-FirewallRulesForEnsp -Lines @("DisplayName  : Other", "Action       : Allow")
Assert-False $fwNone.HasAllowRule "no rule => false"

$ports = Parse-PortOccupancy -OccupiedPorts @(54012) -RequiredPorts @(54012, 54013, 54014)
Assert-Equal $ports.Conflicts.Count 1 "one conflict"
Assert-Equal $ports.Conflicts[0] 54012 "conflict is 54012"

# A disabled+blocked eNSP rule must NOT be satisfied by an unrelated rule.
$fwDecoy = @(
    "DisplayName  : eNSP_VBoxServer",
    "Enabled      : False",
    "Direction    : Inbound",
    "Action       : Block",
    "",
    "DisplayName  : SomeUnrelatedRule",
    "Enabled      : True",
    "Direction    : Inbound",
    "Action       : Allow"
)
Assert-False (Parse-FirewallRulesForEnsp -Lines $fwDecoy).HasAllowRule "disabled eNSP rule is not rescued by another rule"

# The real rule name on this machine is lowercase; -match is case-insensitive.
$fwLower = @(
    "DisplayName  : ensp_vboxserver",
    "Enabled      : True",
    "Direction    : Inbound",
    "Action       : Allow"
)
Assert-True (Parse-FirewallRulesForEnsp -Lines $fwLower).HasAllowRule "lowercase rule name matches"

Write-Host "=== Task 5: backend split ==="

$dirs = @{
    HasSwitchExe = $true
    HasArBase    = $true
    HasVfwUsg    = $false
}
$b = Get-DeviceBackendFacts -Probe $dirs
Assert-True  $b.HostSideDevicesPresent "switch exe present"
Assert-True  $b.VBoxDevicesPresent     "ar base present"
Assert-False $b.AllVBoxDevicesPresent  "not all vbox devices present"
Assert-Equal $b.SplitHint "vbox-layer" "split hint points at vbox layer"

Complete-TestRun
