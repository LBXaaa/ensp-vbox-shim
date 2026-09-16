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

# VRAMSize in the AR template. The lines are wrapped in <Hardware> because that
# is where the element actually lives -- the parser reads the live hardware
# block, so a bare <Display> line is not a shape any real template produces.
Assert-Equal (Get-VramSizeFromTemplate -Lines @("<Hardware>", "<Display VRAMSize=`"9`"/>", "</Hardware>")) 9 "vram parsed"
Assert-True  (Test-VramTooSmall -VramSize 1) "1MB flagged"
Assert-False (Test-VramTooSmall -VramSize 9) "9MB fine"

# A template with no VRAMSize element yields $null, which is "could not read",
# not "too small". Reporting it as a defect would be inventing one.
Assert-Equal (Get-VramSizeFromTemplate -Lines @("<Hardware>", "<Display/>", "</Hardware>")) $null "absent vram element parses to null"
Assert-False (Test-VramTooSmall -VramSize $null) "null vram is not flagged"
Assert-False (Test-VramTooSmall -VramSize "") "empty vram is not flagged"
Assert-True  (Test-VramTooSmall -VramSize "8") "string 8 is still flagged"
Assert-False (Test-VramTooSmall -VramSize "10") "string 10 is not flagged (numeric, not textual compare)"

# WinPcap vs Npcap must be distinguished, not merely "installed".
$p = ClassifyPacketDriver -WinPcapVersion "4.1.3" -NpcapPresent $true
Assert-True $p.NpcapConflict "npcap conflict flagged"
Assert-False $p.WinPcapUsable "winpcap not usable while npcap is present"

Write-Host "=== DHCP servers (list dhcpservers parser) ==="

# The real capture: one server, six top-level fields, then an indented
# "Global Configuration:" block whose "minLeaseTime:" / "1/legacy:" lines look
# like fields but are not. Only the six top-level fields may be read.
$dh = @(Parse-DhcpServers -Lines (Get-Content (Get-TestDataPath "dhcpservers_normal.txt")))
Assert-Equal $dh.Count 1 "normal: one server parsed"
Assert-Equal $dh[0].NetworkName "HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter" "normal: network name"
Assert-Equal $dh[0].DhcpdIP "192.168.56.100" "normal: dhcpd ip"
Assert-Equal $dh[0].LowerIP "192.168.56.101" "normal: lower ip"
Assert-Equal $dh[0].UpperIP "192.168.56.254" "normal: upper ip"
Assert-Equal $dh[0].NetworkMask "255.255.255.0" "normal: mask"
Assert-True  $dh[0].Enabled "normal: Enabled Yes reads as true"

# Enabled has to be a real [bool], not the string "Yes": the report renders it
# as a yes/no word, and a truthy string would make that branch unconditional.
Assert-Equal ($dh[0].Enabled -is [bool]) $true "normal: Enabled is a boolean"

# The nested "Global Configuration:" lines must not be read as fields. The real
# fixture cannot show this by itself -- its nested "1/legacy:" entry carries the
# same 255.255.255.0 as the genuine NetworkMask, so a leaking parser would land
# on an identical value. An indented NetworkMask is fed in explicitly, since
# indentation is the only thing that distinguishes it from the real field.
$nested = @(
    "NetworkName:    HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter",
    "NetworkMask:    255.255.255.0",
    "Global Configuration:",
    "    NetworkMask: 10.0.0.0",
    "Groups:               None"
)
Assert-Equal @(Parse-DhcpServers -Lines $nested)[0].NetworkMask "255.255.255.0" "indented lines are not read as fields"

# "One block per server" is the parser's whole contract, and the real capture
# holds a single server, so the block boundary is exercised here: a machine
# with two host-only adapters gets two servers, and no field may bleed from one
# block into the next.
$two = @(
    "NetworkName:    HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter",
    "Dhcpd IP:       192.168.56.100",
    "Enabled:        Yes",
    "Groups:               None",
    "NetworkName:    HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter #2",
    "Dhcpd IP:       192.168.99.100",
    "LowerIPAddress: 192.168.99.101",
    "Enabled:        No"
)
$twoP = @(Parse-DhcpServers -Lines $two)
Assert-Equal $twoP.Count 2 "two servers parsed as two records"
Assert-Equal $twoP[0].LowerIP "" "first block keeps its own (absent) lower ip"
Assert-Equal $twoP[1].LowerIP "192.168.99.101" "second block keeps its own lower ip"
Assert-False $twoP[1].Enabled "Enabled No reads as false"

# The join key is the adapter's VBoxNetworkName -- never its Name, and never a
# hand-built literal. The suffixed fixture is the discriminating case: its
# VBoxNetworkName ends in "#2", which no literal could ever match. That is the
# exact shape of the false alarm the deleted install.ps1 self-check produced.
$ifsSfx = Get-Content (Get-TestDataPath "hostonlyifs_suffixed.txt")
$sfxNetName = @(Parse-HostOnlyIfs -Lines $ifsSfx)[0].VBoxNetworkName
$sfxDhcp = @(
    ("NetworkName:    " + $sfxNetName),
    "Dhcpd IP:       192.168.56.100",
    "LowerIPAddress: 192.168.56.101",
    "UpperIPAddress: 192.168.56.254",
    "NetworkMask:    255.255.255.0",
    "Enabled:        Yes"
)
$join = @(Join-DhcpServerToHostOnlyIf -DhcpServers @(Parse-DhcpServers -Lines $sfxDhcp) `
                                     -HostOnlyIfs @(Parse-HostOnlyIfs -Lines $ifsSfx))
Assert-Equal $join.Count 1 "suffixed: one join record"
Assert-Equal $join[0].IfName "VirtualBox Host-Only Ethernet Adapter #2" "suffixed: server joins to the #2 adapter"
Assert-True  $join[0].Enabled "suffixed: enabled survives the join"

# A server with no matching adapter carries no verdict: it comes back empty
# rather than crashing or attaching itself to the wrong adapter.
$orphan = @(Join-DhcpServerToHostOnlyIf -DhcpServers @($dh[0]) -HostOnlyIfs @())
Assert-Equal $orphan.Count 1 "orphan: record still returned"
Assert-Equal $orphan[0].IfName "" "orphan: no adapter name"
Assert-Equal $orphan[0].Interface $null "orphan: no adapter object"

Write-Host "=== Task 7: base VM registration and link snapshots ==="

# Fixtures here are real captures from a machine with the shim installed, so
# the parsers are exercised against the shapes VirtualBox actually emits --
# including the aborted state that the 2026-09-16 snapshot bug turned on.
$vms = Parse-VBoxListVms -Lines (Get-Content (Get-TestDataPath "vbox_list_vms.txt"))
Assert-Equal $vms.Count 5 "list vms: five base VMs"
Assert-True  $vms.ContainsKey("AR_Base") "list vms: AR_Base present"

$reg = Parse-VBoxMachineRegistry -Lines (Get-Content (Get-TestDataPath "vbox_machine_registry.xml"))
Assert-True $reg.ContainsKey($vms["AR_Base"]) "registry: AR_Base uuid resolves to a src"
Assert-Match $reg[$vms["AR_Base"]] 'AR_Base\.vbox$' "registry: src names AR_Base.vbox"

$snaps = Parse-VBoxSnapshotList -Lines (Get-Content (Get-TestDataPath "vbox_snapshots_with_link.txt"))
Assert-Equal @($snaps).Count 1 "snapshot list: one name collected"
Assert-Equal @($snaps)[0] "AR_Base_Link" "snapshot list: link snapshot read verbatim"
Assert-True  (Test-LinkSnapshotPresent -SnapshotNames $snaps -VmName "AR_Base") "link snapshot found"
Assert-False (Test-LinkSnapshotPresent -SnapshotNames $snaps -VmName "WLAN_AC_Base") "another VM is not credited with it"
Assert-False (Test-LinkSnapshotPresent -SnapshotNames @() -VmName "AR_Base") "empty list => absent"

# Nested snapshots carry a -N suffix; the name still has to come through.
Assert-True (Test-LinkSnapshotPresent -SnapshotNames (Parse-VBoxSnapshotList -Lines @('SnapshotName-1="AR_Base_Link"')) -VmName "AR_Base") `
            "nested snapshot name is read"
Assert-Equal (Parse-VmState -Lines (Get-Content (Get-TestDataPath "vbox_showvminfo_state.txt"))) "aborted" `
             "showvminfo: aborted is read verbatim"
Assert-Equal (Parse-VmState -Lines @('name="x"')) "" "showvminfo: no state line reads as empty"

Assert-True  (Test-SameVmPath -A 'C:\a\\b\AR_Base.vbox' -B 'c:\A\b\AR_Base.vbox') "path: separators and case fold"
Assert-True  (Test-SameVmPath -A 'C:\a\b\' -B 'C:\a\b') "path: trailing separator folds"
Assert-False (Test-SameVmPath -A 'C:\a\b.vbox' -B 'C:\a\c.vbox') "path: different files differ"
Assert-False (Test-SameVmPath -A '' -B 'C:\a') "path: an empty side is never equal"

# The join is pure, so the whole decision table is reachable here: registered
# with a good path, registered with a stale path, registered but snapshotless,
# and not installed at all.
$dirs = @(
    [pscustomobject]@{ Name = "AR_Base";       DirPresent = $true;  VBoxFile = 'C:\e\AR_Base.vbox' },
    [pscustomobject]@{ Name = "WLAN_AC_Base"; DirPresent = $true;  VBoxFile = 'C:\e\WLAN_AC_Base.vbox' },
    [pscustomobject]@{ Name = "WLAN_AD_Base"; DirPresent = $true;  VBoxFile = 'C:\e\WLAN_AD_Base.vbox' },
    [pscustomobject]@{ Name = "WLAN_AP_Base"; DirPresent = $false; VBoxFile = '' }
)
$res = @(Resolve-BaseVmRegistration -BaseVmDirs $dirs `
        -RegisteredVms @{ "AR_Base" = "u-ar"; "WLAN_AC_Base" = "u-ac"; "WLAN_AD_Base" = "u-ad" } `
        -RegistrySrc   @{ "u-ar" = 'C:\e\AR_Base.vbox'; "u-ac" = 'C:\STALE\WLAN_AC_Base.vbox'; "u-ad" = 'C:\e\WLAN_AD_Base.vbox' } `
        -VmStates      @{ "AR_Base" = "poweroff" } `
        -VmSnapshots   @{ "AR_Base" = @("AR_Base_Link") })

Assert-Equal $res.Count 4 "join: one record per base VM"
Assert-True  $res[0].PathValid "join: good registration has a valid path"
Assert-True  $res[0].LinkSnapshot "join: snapshot present"
Assert-Equal $res[0].State "poweroff" "join: state carried"
Assert-True  $res[1].Registered "join: stale registration is still registered"
Assert-False $res[1].PathValid "join: stale path is flagged"
Assert-True  $res[2].PathValid "join: second good registration"
Assert-False $res[2].LinkSnapshot "join: missing snapshot is flagged"
Assert-False $res[3].DirPresent "join: absent device package"
Assert-False $res[3].Registered "join: absent package is not registered"
# An unregistered VM is never queried for snapshots, so its false here means
# "unknown" rather than "gone" -- the report has to phrase it that way.
Assert-False $res[3].LinkSnapshot "join: unregistered VM reports no snapshot"

Write-Host "=== Task 8: device templates and install-tree facts ==="

$uOk = @(Parse-UartPorts -Lines (Get-Content (Get-TestDataPath "arbase_uart_ok.vbox")))
Assert-Equal $uOk.Count 1 "uart ok: one port parsed"
Assert-Equal $uOk[0].Slot "1" "uart ok: slot 1"
Assert-True  $uOk[0].Enabled "uart ok: enabled"
Assert-Equal $uOk[0].HostMode "HostPipe" "uart ok: host pipe"
Assert-Match $uOk[0].Path 'pipe\\config$' "uart ok: pipe path survives its own slashes"
Assert-True  (Test-UartPipePresent -Ports $uOk) "uart ok: pipe present"

$uDis = Parse-UartPorts -Lines (Get-Content (Get-TestDataPath "arbase_uart_disabled.vbox"))
Assert-False (Test-UartPipePresent -Ports $uDis) "uart disabled: no pipe"

# Every template repeats <Hardware> inside each <Snapshot>, and the snapshot
# comes FIRST in the file. The fixtures therefore carry OPPOSITE values in the
# two blocks, so reading the wrong one cannot pass by coincidence -- which is
# exactly how this bug survived its first round: all three real templates had
# identical values in both blocks, and "take the first <Hardware>" looked right.
$uOkAll = @(Parse-UartPorts -Lines (Get-Content (Get-TestDataPath "arbase_uart_ok.vbox")))
Assert-Equal $uOkAll.Count 1 "uart: the snapshot's port is not counted twice"
Assert-True  (Test-UartPipePresent -Ports $uOkAll) `
             "uart: the live block wins over the snapshot's disabled port"
Assert-False (Test-UartPipePresent -Ports @()) "uart: no ports => no pipe"

# Same trap for VRAMSize, and the fixture flips the values the other way: the
# snapshot holds the healthy 16 and the live block the lowered 8. A parser that
# read the snapshot would report "fine" on a template that is actively broken.
$snapVram = Get-VramSizeFromTemplate -Lines (Get-Content (Get-TestDataPath "arbase_vram_small.vbox"))
Assert-Equal $snapVram 8 "vram: the live block is read, not the snapshot's 16"
Assert-True  (Test-VramTooSmall -VramSize $snapVram) "vram: the lowered live value is flagged"

# The scanner must not be confused by <Snapshots> (a different tag) or by a
# nested <Snapshot> tree, where naive non-greedy matching removes too little.
$nested = @(
    '<Machine>',
    '  <Snapshot uuid="{a}" name="outer">',
    '    <Hardware><Display VRAMSize="4"/></Hardware>',
    '    <Snapshots>',
    '      <Snapshot uuid="{b}" name="inner">',
    '        <Hardware><Display VRAMSize="2"/></Hardware>',
    '      </Snapshot>',
    '    </Snapshots>',
    '  </Snapshot>',
    '  <Hardware><Display VRAMSize="16"/></Hardware>',
    '</Machine>')
Assert-Equal (Get-VramSizeFromTemplate -Lines $nested) 16 "vram: a nested snapshot tree is skipped"

# <Snapshot[\s>] must not fire on <Snapshots>; if it did, the depth would never
# return to zero and the live block would go unread.
$snapshotsTag = @(
    '<Machine>',
    '  <Snapshots>',
    '    <Snapshot uuid="{a}"><Hardware><Display VRAMSize="4"/></Hardware></Snapshot>',
    '  </Snapshots>',
    '  <Hardware><Display VRAMSize="16"/></Hardware>',
    '</Machine>')
Assert-Equal (Get-VramSizeFromTemplate -Lines $snapshotsTag) 16 "vram: a <Snapshots> wrapper is handled too"

# Built from char codes because this file must stay ASCII-only.
$cjk = [string]([char]0x5F20) + [string]([char]0x4E09)
Assert-False (Test-NonAsciiPath -Path 'C:\Program Files\Huawei\eNSP') "path check: ascii passes"
Assert-True  (Test-NonAsciiPath -Path ('C:\Users\' + $cjk + '\Desktop')) "path check: non-ascii profile is flagged"
Assert-True  (Test-NonAsciiPath -Path ('C:\eNSP' + $cjk)) "path check: non-ascii install dir is flagged"
Assert-False (Test-NonAsciiPath -Path '') "path check: empty is not flagged"

$xEmpty = Get-X86VcRuntimeFacts -VBoxDir ""
Assert-False $xEmpty.X86DirFound "x86 vcrt: no VBox dir => no x86 dir"
Assert-Equal @($xEmpty.Files).Count 2 "x86 vcrt: both files still reported"
Assert-False $xEmpty.Complete "x86 vcrt: missing dir is not complete"
$xGone = Get-X86VcRuntimeFacts -VBoxDir 'C:\definitely\not\here'
Assert-False $xGone.X86DirFound "x86 vcrt: nonexistent dir"
Assert-False $xGone.Complete "x86 vcrt: nonexistent dir is not complete"

# Ownership decides whether a VBoxHeadless is eNSP's leftover or the user's own
# VM, so the two must never be confused in either direction.
Assert-True  (Test-EnspOwnedVmPath -CfgFile 'C:\Program Files\Huawei\eNSP\vboxserver\AR_Base\AR_Base.vbox' `
                                   -EnspDir 'C:\Program Files\Huawei\eNSP') "owned: under the install tree"
Assert-True  (Test-EnspOwnedVmPath -CfgFile 'C:\Users\u\AppData\Local\eNSP\AR_1\AR_1.vbox' `
                                   -EnspDir 'C:\Program Files\Huawei\eNSP' `
                                   -LocalAppData 'C:\Users\u\AppData\Local') "owned: clone under LOCALAPPDATA"
Assert-False (Test-EnspOwnedVmPath -CfgFile 'D:\VMs\MyOwn\MyOwn.vbox' `
                                   -EnspDir 'C:\Program Files\Huawei\eNSP') "owned: the user's own VM is not eNSP's"
Assert-False (Test-EnspOwnedVmPath -CfgFile '' -EnspDir 'C:\e') "owned: an unknown path is never claimed"
# A sibling directory sharing the prefix must not match.
Assert-False (Test-EnspOwnedVmPath -CfgFile 'C:\Program Files\Huawei\eNSP2\x.vbox' `
                                   -EnspDir 'C:\Program Files\Huawei\eNSP') "owned: prefix must end on a separator"

$own = @(Resolve-RunningVmOwnership -RunningVmNames @("AR_1", "MyOwn") `
        -RegisteredVms @{ "AR_1" = "u1"; "MyOwn" = "u2" } `
        -RegistrySrc   @{ "u1" = 'C:\Program Files\Huawei\eNSP\vboxserver\AR_1\AR_1.vbox'; "u2" = 'D:\VMs\MyOwn\MyOwn.vbox' } `
        -EnspDir 'C:\Program Files\Huawei\eNSP')
Assert-Equal $own.Count 2 "ownership: one record per running VM"
Assert-True  $own[0].EnspOwned "ownership: eNSP clone is claimed"
Assert-False $own[1].EnspOwned "ownership: the user's VM is left alone"

Write-Host "=== Task 9: packet capture driver ==="

# "WinPcap" contains "nPcap", and -like is case-insensitive. Testing for Npcap
# first reports a conflict on a machine where WinPcap is working perfectly;
# this assertion is the one that caught it.
$pWin = ClassifyPacketDllProduct -Product "WinPcap" -Present $true
Assert-True  $pWin.IsWinPcap "packet dll: WinPcap is WinPcap"
Assert-False $pWin.IsNpcap   "packet dll: WinPcap is NOT misread as Npcap"
$pNp = ClassifyPacketDllProduct -Product "Npcap" -Present $true
Assert-True  $pNp.IsNpcap   "packet dll: Npcap is Npcap"
Assert-False $pNp.IsWinPcap "packet dll: Npcap is not WinPcap"
$pNone = ClassifyPacketDllProduct -Product "" -Present $false
Assert-False $pNone.IsWinPcap "packet dll: absent file is neither"
Assert-False $pNone.IsNpcap   "packet dll: absent file is neither (npcap)"
# A present file with an unrecognised product name is not silently called WinPcap.
$pOther = ClassifyPacketDllProduct -Product "Some Vendor Capture" -Present $true
Assert-False $pOther.IsWinPcap "packet dll: unknown product is not WinPcap"
Assert-False $pOther.IsNpcap   "packet dll: unknown product is not Npcap"

Write-Host "=== Task 10: VBox.log / VBoxHardening.log parsers ==="

$beNative = Parse-VBoxLogBackend -Lines (Get-Content (Get-TestDataPath "vboxlog_backend_native.txt"))
Assert-Equal $beNative.Backend "native" "backend: the real capture reads as native"
Assert-Match $beNative.NativeLine 'VT-x w/ nested paging' "backend: the native line is kept"

$beNem = Parse-VBoxLogBackend -Lines (Get-Content (Get-TestDataPath "vboxlog_backend_nem.txt"))
Assert-Equal $beNem.Backend "nem" "backend: a fallback reads as nem"
Assert-Match $beNem.FallbackLine 'Attempting fall back to NEM' "backend: the fallback line is kept"
Assert-Match $beNem.NemLine 'Snail execution mode' "backend: the NEM line is kept"
Assert-False $beNem.ForcedNEM "backend: an automatic fallback is not a forced NEM"
# This is the trap the parser exists for. The fallback line begins with
# "HM: HMR3Init:" exactly like the native one, so a parser that tests the
# native pattern first classifies every NEM run as native -- and NEM runs are
# the normal case on any machine with Hyper-V enabled.
Assert-Equal $beNem.NativeLine "" "backend: a NEM run records no native line"

# "HM: VT-x/AMD-V init method: Local" describes module init, not the backend,
# and appears on NEM runs too. It must never produce a verdict on its own.
$beTrap = Parse-VBoxLogBackend -Lines @('00:00:01.000000 HM: VT-x/AMD-V init method: Local')
Assert-Equal $beTrap.Backend "unknown" "backend: the init-method line is not a verdict"

$beForced = Parse-VBoxLogBackend -Lines @(
    '00:00:01.100000 HM: Setting fHMEnabled to false because fUseNEMInstead is set.',
    '00:00:01.200000 NEM: NEMR3Init: Snail execution mode is active!')
Assert-True  $beForced.ForcedNEM "backend: a forced NEM is flagged as such"
Assert-Equal $beForced.Backend "nem" "backend: a forced NEM still reads as nem"

# IEM is the last resort and outranks the others in the verdict.
$beIem = Parse-VBoxLogBackend -Lines @(
    '00:00:01.100000 HM: HMR3Init: VT-x w/ nested paging',
    '00:00:01.200000 HM: HMR3Init: Falling back on IEM: No HM, no NEM.')
Assert-Equal $beIem.Backend "iem" "backend: IEM wins over a native line earlier in the log"

# TWO lines in that block carry VERR_INTNET_FLT_IF_NOT_FOUND -- the VMSetError
# one and the PDM "Failed to construct 'e1000'" one, which reports the same
# failure from the device side. Both are returned: this function is a finder
# and must not drop evidence to make the report tidier. Collapsing them into
# one conclusion is the report's job, not the parser's.
$mk = @(Find-VBoxLogMarkers -Lines (Get-Content (Get-TestDataPath "vboxlog_intnet_error.txt")))
Assert-Equal $mk.Count 2 "markers: both lines carrying the code are returned"
Assert-Equal $mk[0].Id "intnet" "markers: classified as intnet"
Assert-Match $mk[0].Line 'VERR_INTNET_FLT_IF_NOT_FOUND' "markers: the raw line is kept"
Assert-Equal $mk[1].Id "intnet" "markers: the PDM line reads as the same root cause"
Assert-True ($mk[0].Line -ne $mk[1].Line) "markers: the two lines are distinct evidence"
Assert-Equal @(Find-VBoxLogMarkers -Lines @('00:00:01.000000 nothing to see here')).Count 0 `
             "markers: a clean line matches nothing"

$hp = Parse-HardeningLog -Lines (Get-Content (Get-TestDataPath "hardening_5657.txt"))
Assert-True  $hp.Failed "hardening: failure detected"
Assert-Equal @($hp.Errors).Count 1 "hardening: one error"
Assert-Equal @($hp.Errors)[0].Code -5657 "hardening: the code is read"
Assert-Equal @($hp.Errors)[0].Symbol "VERR_SUP_VP_NOT_SIGNED_WITH_BUILD_CERT" "hardening: the code is named"
Assert-Equal @($hp.Errors)[0].Where "supR3HardenedWinReSpawn" "hardening: the failing function is read"
Assert-Match @($hp.Errors)[0].Step 'Misc' "hardening: enmWhat=5 reads as Misc"
Assert-Equal @($hp.RejectedModules).Count 1 "hardening: one rejected module"
Assert-Match @($hp.RejectedModules)[0] 'FileSyncShell64\.dll$' "hardening: the rejected module is named"

$hc = Parse-HardeningLog -Lines (Get-Content (Get-TestDataPath "hardening_clean.txt"))
Assert-False $hc.Failed "hardening: a clean log reports no failure"
Assert-Equal @($hc.RejectedModules).Count 0 "hardening: a clean log names no module"

# The decimal negative rc form exists ONLY in VBoxHardening.log. VBox.log
# prints symbolic names, so this parser must find nothing in a release log --
# and that assertion is what stops anyone later "helpfully" pointing it at
# VBox.log to look for -NNNN, where it would silently never match.
$hpVbox = Parse-HardeningLog -Lines (Get-Content (Get-TestDataPath "vboxlog_intnet_error.txt"))
Assert-False $hpVbox.Failed "hardening: a VBox.log yields no hardening verdict"
Assert-True  (Parse-HardeningLog -Lines @('1f2c.1f30: Error (rc=-5640):')).Failed `
             "hardening: the 'Error (rc=N)' form is detected"
Assert-Equal @((Parse-HardeningLog -Lines @('1f2c.1f30: Error (rc=-5640):')).Errors)[0].Code -5640 `
             "hardening: code from the rc= form"
Assert-Equal @((Parse-HardeningLog -Lines @('1f2c.1f30: Error (rc=-5640):')).Errors)[0].Symbol `
             "VERR_SUP_VP_THREAD_NOT_ALONE" "hardening: the rc= form is named"

# An unrecognised code is reported as a bare number. Naming it would be
# inventing a meaning, which is worse than admitting the code is unknown.
$hpUnk = Parse-HardeningLog -Lines @('1f2c.1f30: Error -9999 in supR3HardenedWinReSpawn! (enmWhat=3)')
Assert-True  $hpUnk.Failed "hardening: an unknown code still counts as a failure"
Assert-Equal @($hpUnk.Errors)[0].Symbol "" "hardening: an unknown code gets no invented name"
Assert-Match @($hpUnk.Errors)[0].Step 'Driver' "hardening: enmWhat=3 reads as Driver"

# The "%x.%x: " pid.thread prefix is optional for the parser.
Assert-True (Parse-HardeningLog -Lines @('Error -5657 in supR3HardenedWinReSpawn! (enmWhat=5)')).Failed `
            "hardening: matches with no pid.thread prefix"

Write-Host "=== Task 11: diag.ps1 report-verb call shape ==="

# A trap that produced three silent bugs in one session and that no syntax check
# can see. Putting an ASCII double quote inside a double-quoted Chinese string
# does not break the parse -- PowerShell happily reads
#
#     Write-Note "  ... with "a quoted bit" here."
#
# as THREE arguments. Write-Note takes one, so the first becomes the message and
# the other two disappear into $args. The result is half a sentence on screen
# and exit code 0.
#
# The parser cannot flag it (the syntax is valid), so this walks the real AST of
# diag.ps1 and counts each report verb's arguments against what the function
# actually accepts. A split string shows up as an argument count nothing else
# produces. The only edit needed to keep this passing is to reword the message
# or use the full-width bracket characters, which is the intended habit anyway.
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
$diagPath = Join-Path $repoRoot "installer\diag.ps1"

# Verb -> the argument counts that are legitimate. Write-Fact takes a label and
# a value, plus an optional column width, which is why it has two.
$allowed = @{
    "Write-Note"    = @(1)
    "Write-Section" = @(1)
    "Write-Fact"    = @(2, 3)
    "Write-Fail"    = @(2)
}
$shapeErrors = @()
if (Test-Path $diagPath) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($diagPath, [ref]$null, [ref]$null)
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (-not $name -or -not $allowed.ContainsKey($name)) { continue }
        $n = $c.CommandElements.Count - 1
        if ($allowed[$name] -notcontains $n) {
            # Message kept in English on purpose. This file must stay ASCII:
            # PowerShell 5.1 decodes a BOM-less file as ANSI, and a multi-byte
            # Chinese character can then decode into a stray 0x22 that
            # terminates the literal early. That is the very rule this project
            # documents for .ps1 files, and breaking it here produced a parse
            # error whose reported line number pointed somewhere else entirely.
            $shapeErrors += ($name + " line " + $c.Extent.StartLineNumber +
                             ": got " + $n + " arguments")
        }
    }
} else {
    $shapeErrors += "diag.ps1 not found at " + $diagPath
}
Assert-True (Test-Path $diagPath) "report verbs: diag.ps1 is reachable from the tests"
if ($shapeErrors.Count -gt 0) { $shapeErrors | ForEach-Object { Write-Host ("        " + $_) -ForegroundColor Red } }
Assert-Equal $shapeErrors.Count 0 "report verbs: every call passes the argument count the verb accepts"

# The argument walk above has a blind spot, and this second check exists because
# of it. When the stray quote is followed by a '#', as in  ...\"#2\"...  the rest
# of the line becomes a COMMENT: the call parses as a tidy one-argument form and
# the walk passes it. Measured on the first run of this task -- it caught two of
# the four broken lines and missed the other two, which were exactly that shape.
#
# This check has no such gap. A backslash is NOT PowerShell's escape character
# (the backtick is), so a backslash sitting immediately before a double quote
# inside a double-quoted string always means the quote terminates the string
# early. Zero occurrences is the only passing count.
#
# If a legitimate need for those two characters ever appears -- a literal path
# ending in a backslash, say -- reword the message rather than relaxing this.
# Weakening the guard would restore exactly the silent truncation it was added
# to prevent.
$bsQuote = [string][char]0x5C + [string][char]0x22
$bsQuoteCount = ([regex]::Matches((Get-Content -Path $diagPath -Raw), [regex]::Escape($bsQuote))).Count
Assert-Equal $bsQuoteCount 0 "report verbs: no backslash-escaped quote survives in diag.ps1"

Write-Host "=== Task 12: the menu's repair primitives exist ==="

# The menu refers to repair primitives by NAME, as a string inside Steps. A typo
# or a renamed function therefore fails at the worst possible moment: when a
# user picks that item on a machine that is already broken, and the only thing
# they see is the "repair primitive missing" skip line. Neither file's syntax
# check catches it: both parse perfectly, and the string is just data.
#
# This walks diag.ps1 for Fn = "..." and requires each name to be defined in
# fix.ps1. It is the guard that would have caught Repair-BounceAdapter sitting
# unused for a whole release while the diagnostic had a finding it applied to.
$fixPath = Join-Path $repoRoot "installer\fix.ps1"
$stepFns = @()
if ((Test-Path $diagPath) -and (Test-Path $fixPath)) {
    $stepFns = @([regex]::Matches((Get-Content -Path $diagPath -Raw), 'Fn\s*=\s*"([A-Za-z][\w-]*)"') |
                 ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}
Assert-True ($stepFns.Count -gt 0) "repair steps: diag.ps1 names at least one repair primitive"

$fixText = ""
if (Test-Path $fixPath) { $fixText = Get-Content -Path $fixPath -Raw }
$missingFns = @()
foreach ($fn in $stepFns) {
    if ($fixText -notmatch ('(?m)^function\s+' + [regex]::Escape($fn) + '\b')) { $missingFns += $fn }
}
if ($missingFns.Count -gt 0) {
    $missingFns | ForEach-Object { Write-Host ("        not defined in fix.ps1: " + $_) -ForegroundColor Red }
}
Assert-Equal $missingFns.Count 0 "repair steps: every Fn named by the menu exists in fix.ps1"

Write-Host "=== Task 13: shim registration (CLSID hijack + plugin hashes) ==="

# --- path identity -----------------------------------------------------------
# The stored InprocServer32 value is compared against the shim path rather than
# merely tested for presence, so the comparison has to tolerate everything the
# registry legitimately does to a path: different casing, doubled separators,
# a trailing separator.
Assert-True  (Test-SameRegPath "C:\a\b\VBox52.dll" "c:\A\B\vbox52.dll")   "regpath: case is not significant"
Assert-True  (Test-SameRegPath "C:\\a\\b\\VBox52.dll" "C:\a\b\VBox52.dll") "regpath: doubled separators collapse"
Assert-True  (Test-SameRegPath "C:\a\b\VBox52.dll\" "C:\a\b\VBox52.dll")  "regpath: trailing separator ignored"
Assert-False (Test-SameRegPath "C:\a\b\VBox52.dll" "C:\a\b\other.dll")    "regpath: different files do not match"
Assert-False (Test-SameRegPath "" "C:\a\b\VBox52.dll")                    "regpath: empty side never matches"
Assert-False (Test-SameRegPath "C:\a\b\VBox52.dll" "")                    "regpath: empty side never matches (reversed)"

# A stale absolute path left behind by an install at some earlier location is
# present, non-empty, and wrong. Presence alone would call that healthy, which
# is why the comparison above exists and why it is asserted here.
Assert-False (Test-SameRegPath "D:\old\eNSP\tools\VBox52.dll" "C:\eNSP\tools\VBox52.dll") "regpath: a stale path does not match"

# --- no CLSID constant means nothing is guessed ------------------------------
$noClsid = Get-ClsidHijackFacts -ClsidVbox "" -ExpectedDll "C:\x\VBox52.dll"
Assert-False $noClsid.Checked  "clsid: an empty CLSID reports not-checked"
Assert-Equal @($noClsid.Views).Count 0 "clsid: an empty CLSID yields no views"
Assert-False $noClsid.PrimaryShim "clsid: an empty CLSID is not a passing 32-bit check"

# --- both views are reported, and 32-bit is the one that decides -------------
# eNSP is a 32-bit process, so the view it reads is the WOW6432Node one. If this
# ever collapses into a single merged verdict the report can no longer say WHICH
# view is wrong -- and calling a machine fine because the 64-bit view happens to
# match is exactly the false-green this check was added to prevent.
$otherClsid = "{00000000-0000-0000-0000-000000000000}"
$anyClsid = Get-ClsidHijackFacts -ClsidVbox $otherClsid -ExpectedDll "C:\x\VBox52.dll"
Assert-True $anyClsid.Checked "clsid: a CLSID yields a check"
Assert-Equal @($anyClsid.Views).Count 2 "clsid: both registry views are reported"
Assert-Equal @($anyClsid.Views | Where-Object { $_.Primary }).Count 1 "clsid: exactly one view is primary"
$clsidPrimary = @($anyClsid.Views | Where-Object { $_.Primary })[0]
Assert-True  ($clsidPrimary.Key -like "*WOW6432Node*") "clsid: the primary view is the 32-bit one"
Assert-False $clsidPrimary.PointsAtShim "clsid: an unregistered CLSID does not point at the shim"
foreach ($v in $anyClsid.Views) {
    Assert-True ($v.Key -like "*\$otherClsid\*") "clsid: each view addresses the CLSID it was given"
}

# --- file facts degrade instead of throwing ----------------------------------
# Every probe in this file has to survive the environments the report is meant
# for, which is wherever eNSP is currently broken -- missing directories, no
# permission, half-installed trees.
$absent = Get-TreeFileFact -EnspDir "C:\definitely-not-here-9f3a" -Rel "plugin\ar1000v\VAR_Plugin.dll"
Assert-False $absent.Present "treefile: a missing file reports absent"
Assert-Equal $absent.Hash ""  "treefile: a missing file has no hash"
Assert-Equal $absent.Error "" "treefile: absence is not an error"

$noDir = Get-TreeFileFact -EnspDir "" -Rel "plugin\ar1000v\VAR_Plugin.dll"
Assert-False $noDir.Present "treefile: no eNSP dir reports absent, not a throw"
Assert-Equal $noDir.Path ""    "treefile: no eNSP dir yields no path"

# --- the wiring this task exists for ------------------------------------------
# Section 1 used to verify the four deployed DLL files and stop there. That
# proves the files are on disk; it does not prove anything loads them. A machine
# whose CLSID still pointed at Oracle's own proxy/stub therefore produced a
# report containing no failures and still could not start a device -- eNSP got a
# real IVirtualBox, read 7.2.x, and refused the version before ever reaching
# device startup.
#
# These assertions keep the check wired: delete the call, rename the function,
# or drop the definition and they fail. Neither file's syntax check can do that,
# because a missing call parses perfectly.
$checksText = Get-Content -Path (Join-Path $repoRoot "installer\checks.ps1") -Raw
Assert-True ($checksText -match '(?m)^function\s+Get-ClsidHijackFacts\b') "clsid: the probe is defined in checks.ps1"
Assert-True ((Get-Content -Path $diagPath -Raw) -match 'Get-ClsidHijackFacts') "clsid: diag.ps1 actually calls the probe"
Assert-True ((Get-Content -Path $diagPath -Raw) -match 'VAR_Plugin\.dll') "plugins: diag.ps1 reports the AR plugin state"

# --- the constants diag.ps1 reads out of install.ps1 --------------------------
# diag.ps1 must not dot-source install.ps1 (that file has top-level side effects
# and would really run an install), so it reads these constants by text. Reform
# that constant block -- switch to single quotes, wrap a value across lines --
# and the read returns empty, which makes the check SKIP silently rather than
# fail.
#
# That is the same shape of hole this task was written to close, so the shape of
# the read is pinned from the installer's side too.
$installerText = Get-Content -Path (Join-Path $repoRoot "installer\install.ps1") -Raw
foreach ($constName in @("DLL_SHA256", "DLL_NAME", "CLSID_VBOX", "VARP_SHA256",
                         "NGFW_PRISTINE_SHA256", "NGFW_PATCHED_SHA256", "NGFW_LEGACY_SHA256")) {
    $cm = [regex]::Match($installerText, ('\$' + [regex]::Escape($constName) + '\s*=\s*"([^"]*)"'))
    Assert-True ($cm.Success -and ($cm.Groups[1].Value.Length -gt 0)) ("const: install.ps1 still yields " + $constName)
}

# The shim path diag.ps1 compares against is built as <eNSP>\tools\<DLL_NAME>.
# That is the location install.ps1's step 3 writes into the CLSID, so the two
# files have to agree on it or every healthy machine reads as a mismatch.
$dllNameConst = [regex]::Match($installerText, '\$DLL_NAME\s*=\s*"([^"]*)"').Groups[1].Value
Assert-Equal $dllNameConst "VBox52.dll" "const: the CLSID target filename is unchanged"

Complete-TestRun
