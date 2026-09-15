# checks.ps1 -- read-only environment probes for ensp-vbox-shim.
#
# Contract:
#   - NEVER modifies the system, never writes files, never prints.
#   - Every probe returns a [pscustomobject] of plain facts.
#   - Parsing is separated from collection on purpose: Parse-* are pure
#     (text in, object out) and covered by build/tests; Get-* only run
#     commands and hand the text to a parser.
#
# ASCII-only: PowerShell 5.1 reads BOM-less files as ANSI, so non-ASCII
# literals here would break parsing.

# --- VBoxDrvInst: driver registration -------------------------------------
#
# The 2026-09-15 failure was both VBox network driver packages missing from
# the driver store. `VBoxDrvInst.exe list` prints one OEM INF per block:
#
#     oem90.inf                                | 08/13/2026
#         VBoxNetAdp6.NTAMD64                  | sun_VBoxNetAdp
#     oem91.inf                                | 08/13/2026
#         VBoxNetLwf.NTAMD64                   | oracle_VBoxNetLwf
#
# Matching on the model name is enough; the OEM number is not stable.
function Parse-VBoxDrvInstList {
    param([string[]]$Lines)
    $text = ($Lines -join "`n")
    $netAdp = ($text -match 'VBoxNetAdp6\.NTAMD64')
    $netLwf = ($text -match 'VBoxNetLwf\.NTAMD64')
    return [pscustomobject]@{
        NetAdpPresent = $netAdp
        NetLwfPresent = $netLwf
        MissingBoth   = ((-not $netAdp) -and (-not $netLwf))
    }
}

# Services that must exist and run on VirtualBox 7.x.
# VBoxDrv is deliberately absent from this list: it is the 5.2-era driver and
# does not exist on a healthy 7.2 install, so its absence is NOT a defect.
#
# Note on scope: this file is dot-sourced, so the definition below carries the
# `script:` qualifier (dot-sourcing from inside a function would otherwise
# leave the variable in that function's local scope). The *reads* are
# deliberately unqualified: `$script:` inside a function resolves to the
# CALLER's script scope, so when a test or diag script calls these functions
# the qualified read returns $null. Unqualified reads follow the dynamic scope
# chain back to wherever the file was dot-sourced. Same trap harness.ps1
# documents for its counters.
$script:RequiredVBoxServices = @("VBoxSup", "VBoxNetAdp", "VBoxNetLwf", "VBoxUSBMon")

function Test-RequiredVBoxService {
    param([string]$Name)
    return ($RequiredVBoxServices -contains $Name)
}

# Layer 1 (driver registered) + Layer 2 (services present and running).
function Get-HostOnlyDriverLayers {
    param([string[]]$DrvInstLines)

    $drv = Parse-VBoxDrvInstList -Lines $DrvInstLines

    $services = @()
    foreach ($n in $RequiredVBoxServices) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        $services += [pscustomobject]@{
            Name      = $n
            Present   = [bool]$s
            Status    = $(if ($s) { $s.Status.ToString() } else { "Absent" })
            Running   = ($s -and $s.Status -eq "Running")
        }
    }

    return [pscustomobject]@{
        Layer1 = [pscustomobject]@{
            NetAdpPresent    = $drv.NetAdpPresent
            NetLwfPresent    = $drv.NetLwfPresent
            MissingBoth      = $drv.MissingBoth
            DriverRegistered = ($drv.NetAdpPresent -and $drv.NetLwfPresent)
        }
        Layer2 = [pscustomobject]@{
            Services        = $services
            AllRunning      = (@($services | Where-Object { -not $_.Running }).Count -eq 0)
        }
    }
}

# --- host-only interface listing ------------------------------------------
#
# `VBoxManage list hostonlyifs` prints one block per adapter:
#
#     Name:            VirtualBox Host-Only Ethernet Adapter
#     GUID:            fecbb409-...
#     DHCP:            Disabled
#     IPAddress:       192.168.56.1
#     ...
#     Status:          Up
#     VBoxNetworkName: HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter
#
# Note: the block-level "DHCP:" field is the Windows-side client setting and is
# unrelated to the VirtualBox DHCP server reported by `list dhcpservers`.
function Parse-HostOnlyIfs {
    param([string[]]$Lines)
    $out = @()
    $cur = $null
    foreach ($line in $Lines) {
        if ($line -match '^Name:\s+(.+)$') {
            $cur = @{ Name = $Matches[1].Trim(); IPAddress = ""; Status = ""; VBoxNetworkName = "" }
        } elseif ($cur) {
            if     ($line -match '^IPAddress:\s+(.+)$')       { $cur.IPAddress = $Matches[1].Trim() }
            elseif ($line -match '^Status:\s+(.+)$')          { $cur.Status = $Matches[1].Trim() }
            elseif ($line -match '^VBoxNetworkName:\s+(.+)$') {
                $cur.VBoxNetworkName = $Matches[1].Trim()
                $out += [pscustomobject]$cur
                $cur = $null
            }
        }
    }
    if ($cur) { $out += [pscustomobject]$cur }
    return $out
}

# --- layer 6: name comparison ---------------------------------------------
#
# A "#N" suffix is NOT itself a defect. What breaks eNSP is a mismatch between
# the name stored in the device template (.vbox) and the name VirtualBox
# actually reports. Re-registering the device rewrites the template name and
# resolves the mismatch, which is why the community fix works.
function Compare-HostOnlyName {
    param([string[]]$VBoxNames, [string[]]$TemplateNames)
    $matched = 0
    $missing = @()
    foreach ($t in $TemplateNames) {
        if ($VBoxNames -contains $t) { $matched++ } else { $missing += $t }
    }
    return [pscustomobject]@{
        MatchedCount   = $matched
        MissingInVBox  = $missing
        HasMismatch    = ($missing.Count -gt 0)
    }
}

# --- layer 4: the adapter as Windows sees it ------------------------------
#
# The connection name is LOCALIZED (observed as the Chinese for "Ethernet 11"),
# so it must never be matched on. InterfaceDescription is the stable key.
function Get-HostOnlyNetAdapterFacts {
    $items = @()
    try {
        $adapters = Get-NetAdapter -ErrorAction Stop |
            Where-Object { $_.InterfaceDescription -like "*VirtualBox Host-Only*" }
        foreach ($a in $adapters) {
            $ip = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
            $items += [pscustomobject]@{
                InterfaceName        = $a.Name
                InterfaceDescription = $a.InterfaceDescription
                Status               = $a.Status.ToString()
                IPv4                 = $(if ($ip.Count -gt 0) { $ip[0].IPAddress } else { "" })
            }
        }
    } catch { }
    return $items
}

# --- layer 5: NDIS filter binding -----------------------------------------
#
# The binding also sits on physical NICs and every Hyper-V vEthernet adapter,
# so it is NOT host-only specific -- the adapter must be joined by
# InterfaceDescription, not by name.
function Get-HostOnlyBindingFacts {
    $items = @()
    try {
        $adapters = Get-NetAdapter -ErrorAction Stop |
            Where-Object { $_.InterfaceDescription -like "*VirtualBox Host-Only*" }
        foreach ($a in $adapters) {
            $b = Get-NetAdapterBinding -Name $a.Name -ComponentID "oracle_VBoxNetLwf" -ErrorAction SilentlyContinue
            $items += [pscustomobject]@{
                InterfaceName = $a.Name
                Bound         = [bool]$b
                Enabled       = ($b -and $b.Enabled)
            }
        }
    } catch { }
    return $items
}

# --- performance counters --------------------------------------------------
#
# eNSP depends on Windows performance counters; when they are damaged devices
# print '####' forever. Detection MUST run a counter for real: on current
# Windows the classic Perflib\009\Counter registry check reports missing on a
# perfectly healthy machine (verified 2026-09-15 -- only _V2Providers exists).
function Test-PerfCountersFunctional {
    try {
        $c = Get-Counter -Counter "\Processor(_Total)\% Processor Time" -MaxSamples 1 -ErrorAction Stop
        $ok = ($c.CounterSamples.Count -gt 0)
        return [pscustomobject]@{ Functional = $ok; Reason = "Get-Counter succeeded" }
    } catch {
        return [pscustomobject]@{
            Functional = $false
            Reason     = $_.Exception.Message
        }
    }
}

# --- firewall --------------------------------------------------------------
#
# Get-NetFirewallRule text output groups each rule into a block separated by a
# blank line. Testing the three fields independently over the whole blob lets an
# unrelated rule satisfy them, so a DISABLED+BLOCK eNSP rule would be reported
# as an allow rule whenever any other rule happens to be enabled+allow.
# Each block is therefore evaluated whole.
#
# The literal below matches a lowercase rule name (observed as
# "ensp_vboxserver") only because -match is case-insensitive by default.
# Do not switch to -cmatch without normalising case first.
function Parse-FirewallRulesForEnsp {
    param([string[]]$Lines)
    $text = ($Lines -join "`n")
    $blocks = [regex]::Split($text, '(\r?\n){2,}')
    foreach ($b in $blocks) {
        if ($b -match '(?m)^DisplayName\s*:\s*.*eNSP_VBoxServer' -and
            $b -match '(?m)^Enabled\s*:\s*True' -and
            $b -match '(?m)^Action\s*:\s*Allow') {
            return [pscustomobject]@{ HasAllowRule = $true }
        }
    }
    return [pscustomobject]@{ HasAllowRule = $false }
}

# --- eNSP server ports -----------------------------------------------------
function Parse-PortOccupancy {
    param([int[]]$OccupiedPorts, [int[]]$RequiredPorts)
    $conflicts = @()
    foreach ($p in $RequiredPorts) {
        if ($OccupiedPorts -contains $p) { $conflicts += $p }
    }
    return [pscustomobject]@{ Conflicts = $conflicts; AllFree = ($conflicts.Count -eq 0) }
}

# --- device backend facts --------------------------------------------------
#
# eNSP devices split across three backends. Host-side devices (S5700 and the
# like) are plain user-mode processes and never touch VirtualBox, so their
# availability is a free discriminator: if they work and AR does not, the fault
# is in the VirtualBox layer; if they also fail, look at eNSP itself.
function Get-DeviceBackendFacts {
    param([hashtable]$Probe)
    $hostSide = [bool]$Probe.HasSwitchExe
    $vboxAr   = [bool]$Probe.HasArBase
    $vboxFw   = [bool]$Probe.HasVfwUsg
    $vboxAny  = ($vboxAr -or $vboxFw)
    $allVbox  = ($vboxAr -and $vboxFw)

    $hint = "unknown"
    if ($hostSide -and $vboxAny) { $hint = "vbox-layer" }
    elseif (-not $hostSide)      { $hint = "ensp-native-layer" }

    return [pscustomobject]@{
        HostSideDevicesPresent = $hostSide
        VBoxDevicesPresent     = $vboxAny
        AllVBoxDevicesPresent  = $allVbox
        SplitHint              = $hint
    }
}

function Get-DeviceBackendProbe {
    param([string]$EnspDir)
    if (-not $EnspDir) { $EnspDir = Find-EnspDir }
    $probe = @{ HasSwitchExe = $false; HasArBase = $false; HasVfwUsg = $false }
    if ($EnspDir) {
        $probe.HasSwitchExe = Test-Path (Join-Path $EnspDir "vboxserver\devices\LSW\s5700\eNSP_Switch.exe")
        $probe.HasArBase    = Test-Path (Join-Path $EnspDir "vboxserver\AR_Base\AR_Base.vbox")
        $probe.HasVfwUsg    = Test-Path (Join-Path $EnspDir "plugin\ngfw\tools\ngfw\vfw_usg.vbox")
    }
    return $probe
}

# --- 192.168.56.x ownership -------------------------------------------------
#
# A VPN or VMware VMnet adapter holding an address in the same subnet breaks
# device connectivity: traffic to 192.168.56.1 gets routed into the wrong
# adapter. eNSP's own resources hard-code dest:192.168.56.1.
function Compare-SubnetOwners {
    param([object[]]$Interfaces, [string]$Prefix)
    $owners = @($Interfaces | Where-Object { $_.IPv4 -like ($Prefix + "*") })
    return [pscustomobject]@{
        OwnerCount = $owners.Count
        Owners     = @($owners | ForEach-Object { $_.Name })
        Conflict   = ($owners.Count -gt 1)
    }
}

# --- eNSP version vs. installed device packages ----------------------------
#
# Two hard constraints from the official changelog:
#   - CE/NE/CX need >= 1.3.00.100 (that release fixed "second start fails").
#   - CX200 and NE5000E were REMOVED in 1.2.00.500.
function Test-EnspVersionAgainstDevices {
    param([string]$EnspVersion, [bool]$HasCeDevice, [bool]$HasCx200)
    $needsNewer = $false
    $cxRemoved  = $false
    if ($EnspVersion) {
        try {
            $v = [version]($EnspVersion -replace '[^0-9\.]', '')
            if ($HasCeDevice -and $v -lt [version]"1.3.0.100") { $needsNewer = $true }
            if ($HasCx200 -and $v -ge [version]"1.2.0.500")    { $cxRemoved  = $true }
        } catch { }
    }
    return [pscustomobject]@{ CeNeedsNewer = $needsNewer; Cx200Removed = $cxRemoved }
}

# --- AR template VRAMSize --------------------------------------------------
#
# A VRAM size small enough makes AR fail while switches and the firewall keep
# working -- the classic "only AR is broken" report.
#
# Threshold rationale, and a correction to the usual telling: community write-ups
# describe a 1 MB factory default, but that came from the VirtualBox 5.0 era.
# Measured on eNSP V1.3.00.100 (2026-09-15): AR_Base.vbox = 16, vfw_usg.vbox = 12,
# WLAN_AC_Base.vbox = 16. No shipped template is anywhere near 1. So this check
# fires only when the value has been actively lowered -- it is a guard against
# a bad edit, not against a factory state. Report the value regardless; the
# number is what makes the "only AR is broken" case diagnosable.
function Get-VramSizeFromTemplate {
    param([string[]]$Lines)
    foreach ($l in $Lines) {
        if ($l -match 'VRAMSize\s*=\s*"(\d+)"') { return [int]$Matches[1] }
    }
    return $null
}

function Test-VramTooSmall {
    param([int]$VramSize)
    return ($VramSize -lt 9)
}

# --- packet capture driver -------------------------------------------------
#
# eNSP recognises WinPcap only; Npcap's WinPcap compatibility layer is not
# sufficient. Presence of Npcap therefore blocks a working capture path even
# when WinPcap's files are also present.
function ClassifyPacketDriver {
    param([string]$WinPcapVersion, [bool]$NpcapPresent)
    $hasWin = (-not [string]::IsNullOrEmpty($WinPcapVersion))
    return [pscustomobject]@{
        WinPcapPresent  = $hasWin
        NpcapPresent    = $NpcapPresent
        NpcapConflict   = ($NpcapPresent)
        WinPcapUsable   = ($hasWin -and (-not $NpcapPresent))
    }
}

# Firewall rules are queried as OBJECTS and re-emitted as canonical text.
# Taking Format-List output directly would make the "Enabled" field's spelling
# depend on the OS display language; synthesising it from the enum keeps it
# stable. The tested parser then consumes this text.
function Get-FirewallRuleTextForEnsp {
    $lines = @()
    try {
        $rules = Get-NetFirewallRule -ErrorAction Stop | Where-Object {
            $_.DisplayName -like "*eNSP*" -or $_.DisplayName -like "*VBoxServer*"
        }
        foreach ($r in $rules) {
            $lines += "DisplayName  : " + $r.DisplayName
            $lines += "Enabled      : " + $r.Enabled.ToString()
            $lines += "Direction    : " + $r.Direction.ToString()
            $lines += "Action       : " + $r.Action.ToString()
            $lines += ""
        }
    } catch { }
    return $lines
}

# InterfaceDescription is the only stable key: connection names are localized.
function Get-AdapterPropertyFacts {
    $items = @()
    try {
        foreach ($a in (Get-NetAdapter -ErrorAction Stop)) {
            $ndis = Get-NetAdapterBinding -Name $a.Name -ComponentID "oracle_VBoxNetLwf" -ErrorAction SilentlyContinue
            $v6   = Get-NetAdapterBinding -Name $a.Name -ComponentID "ms_tcpip6" -ErrorAction SilentlyContinue
            $items += [pscustomobject]@{
                InterfaceName = $a.Name
                Description   = $a.InterfaceDescription
                Ndis6Bound    = ($ndis -and $ndis.Enabled)
                IPv6Enabled   = ($v6 -and $v6.Enabled)
            }
        }
    } catch { }
    return $items
}

function Get-EnspServerPortsInUse {
    param([int[]]$RequiredPorts = @(54012, 54013, 54014))
    $occupied = @()
    foreach ($p in $RequiredPorts) {
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        if ($conn) { $occupied += $p }
    }
    return $occupied
}
