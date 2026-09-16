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

# The profile the matching rule covers must survive into the result. Without it
# the check can only say "an allow rule exists", which is green even when that
# rule covers Public only and the machine is domain-joined.
$fwProfiled = @(
    "DisplayName  : eNSP_VBoxServer",
    "Enabled      : True",
    "Direction    : Inbound",
    "Action       : Allow",
    "Profile      : Public"
)
$fwP = Parse-FirewallRulesForEnsp -Lines $fwProfiled
Assert-True  $fwP.HasAllowRule "profiled block still satisfies the allow-rule test"
Assert-Match $fwP.Profile "Public" "profile of the matching rule is reported"

# A block with no Profile line (older text, or a fixture that predates the
# field) must read as unknown rather than as a crash or as "covers nothing".
Assert-Equal (Parse-FirewallRulesForEnsp -Lines $fwLines).Profile "" "missing profile line reads as unknown"
Assert-Equal $fwNone.Profile "" "no allow rule => profile empty"

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

Write-Host "=== Task 6: remaining checks ==="

# 192.168.56.0/24 must be carried by exactly one interface.
$c = Compare-SubnetOwners -Interfaces @(
    @{ Name = "Ethernet 11"; IPv4 = "192.168.56.1" },
    @{ Name = "VPN Adapter"; IPv4 = "192.168.56.1" }
) -Prefix "192.168.56."
Assert-Equal $c.OwnerCount 2 "two owners detected"
Assert-True  $c.Conflict    "conflict flagged"

$c1 = Compare-SubnetOwners -Interfaces @(@{ Name = "Ethernet 11"; IPv4 = "192.168.56.1" }) -Prefix "192.168.56."
Assert-False $c1.Conflict "single owner is fine"

# Raw Get-NetIPAddress shape: InterfaceAlias / IPAddress, plus a .Name property
# that is mojibake. The alias must win over Name, and the address must be found
# -- feeding this shape in unchanged used to report zero owners on a machine
# that really did have an adapter on the subnet.
$rawIfaces = @(
    [pscustomobject]@{ InterfaceAlias = "Ethernet 11"; IPAddress = "192.168.56.1"; Name = "!!mojibake!!" }
)
$cr = Compare-SubnetOwners -Interfaces $rawIfaces -Prefix "192.168.56."
Assert-Equal $cr.OwnerCount 1 "raw shape: owner is found"
Assert-Equal $cr.Owners[0] "Ethernet 11" "raw shape: alias wins over mojibake Name"
Assert-False $cr.Conflict "raw shape: single owner is fine"

# Same shape, with an out-of-subnet adapter that must not be counted.
$rawTwo = @(
    [pscustomobject]@{ InterfaceAlias = "Ethernet 11"; IPAddress = "192.168.56.1"; Name = "!!mojibake!!" },
    [pscustomobject]@{ InterfaceAlias = "VMnet1"; IPAddress = "192.168.56.1"; Name = "!!mojibake!!" },
    [pscustomobject]@{ InterfaceAlias = "Wi-Fi"; IPAddress = "10.0.0.5"; Name = "!!mojibake!!" }
)
$cr2 = Compare-SubnetOwners -Interfaces $rawTwo -Prefix "192.168.56."
Assert-Equal $cr2.OwnerCount 2 "raw shape: out-of-subnet adapter excluded"
Assert-True  $cr2.Conflict "raw shape: conflict flagged"

# eNSP version vs. the devices actually installed.
$v = Test-EnspVersionAgainstDevices -EnspVersion "1.2.00.500" -HasCeDevice $true -HasCx200 $true
Assert-True  $v.CeNeedsNewer  "1.2.00.500 is too old for CE"
Assert-True  $v.Cx200Removed  "1.2.00.500 removed CX200"

$v2 = Test-EnspVersionAgainstDevices -EnspVersion "1.3.00.100" -HasCeDevice $true -HasCx200 $false
Assert-False $v2.CeNeedsNewer "1.3.00.100 is fine for CE"

# VRAMSize in the AR template.
Assert-Equal (Get-VramSizeFromTemplate -Lines @("<Display VRAMSize=`"9`"/>")) 9 "vram parsed"
Assert-True  (Test-VramTooSmall -VramSize 1) "1MB flagged"
Assert-False (Test-VramTooSmall -VramSize 9) "9MB fine"

# A template with no VRAMSize element yields $null, which is "could not read",
# not "too small". Reporting it as a defect would be inventing one.
Assert-Equal (Get-VramSizeFromTemplate -Lines @("<Display/>")) $null "absent vram element parses to null"
Assert-False (Test-VramTooSmall -VramSize $null) "null vram is not flagged"
Assert-False (Test-VramTooSmall -VramSize "") "empty vram is not flagged"
Assert-True  (Test-VramTooSmall -VramSize "8") "string 8 is still flagged"
Assert-False (Test-VramTooSmall -VramSize "10") "string 10 is not flagged (numeric, not textual compare)"

# WinPcap vs Npcap must be distinguished, not merely "installed".
$p = ClassifyPacketDriver -WinPcapVersion "4.1.3" -NpcapPresent $true
Assert-True $p.NpcapConflict "npcap conflict flagged"
Assert-False $p.WinPcapUsable "winpcap not usable while npcap is present"

Complete-TestRun
