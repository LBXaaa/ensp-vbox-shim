# checks.ps1 - read-only environment probes for ensp-vbox-shim.
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

# --- install-tree discovery ------------------------------------------------
#
# The two probes every other probe is handed a directory for. Both are
# read-only: the registry is only ever read, never written.
#
# Neither function exits and neither prints. An unusable -Override returns
# $null exactly like any other miss, and the caller decides what to say about
# it. That is why these live here rather than in install.ps1: a
# function that calls exit takes the reporting decision away from whichever
# script dot-sourced it, and install.ps1 cannot be dot-sourced at all (it has
# top-level side effects and would run an install).
#
# $null rather than "" for the not-found case, so a caller can test the
# result directly instead of guessing which empty value it got.
function Find-EnspDir {
    param([string]$Override)
    if ($Override) {
        if (Test-Path (Join-Path $Override "tools")) { return $Override }
        return $null
    }
    # 1) the uninstall entry whose DisplayName mentions eNSP
    $uninstRoots = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $uninstRoots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -like "*eNSP*" -and $p.InstallLocation) { $p.InstallLocation }
        } | Where-Object { $_ -and (Test-Path (Join-Path $_ "tools")) } | Select-Object -First 1
        if ($hit) { return $hit.TrimEnd('\') }
    }
    # 2) default install locations
    $defaults = @(
        (Join-Path ${env:ProgramFiles(x86)} "Huawei\eNSP"),
        (Join-Path $env:ProgramFiles        "Huawei\eNSP")
    )
    foreach ($d in $defaults) {
        if ($d -and (Test-Path (Join-Path $d "tools"))) { return $d.TrimEnd('\') }
    }
    return $null
}

# A missing VBoxSVC.exe does NOT invalidate an -Override: the caller may be
# pointing at a tree that is still being repaired, and each probe that needs
# the exe tests for it on its own. Both branches therefore return the
# override; the test only decides whether the trailing separator is stripped.
function Find-VBoxDir {
    param([string]$Override)
    if ($Override) {
        if (Test-Path (Join-Path $Override "VBoxSVC.exe")) { return $Override }
        return $Override.TrimEnd('\')
    }
    # The InstallDir value survives the version spoof (which rewrites only
    # Version), so it still names the real tree.
    $keys = @(
        "HKLM:\SOFTWARE\Oracle\VirtualBox",
        "HKLM:\SOFTWARE\WOW6432Node\Oracle\VirtualBox"
    )
    foreach ($k in $keys) {
        if (-not (Test-Path $k)) { continue }
        $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if ($p.InstallDir -and (Test-Path $p.InstallDir)) { return $p.InstallDir.TrimEnd('\') }
    }
    $def = Join-Path $env:ProgramFiles "Oracle\VirtualBox"
    if (Test-Path $def) { return $def.TrimEnd('\') }
    return $null
}

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

# --- host-only DHCP servers ------------------------------------------------
#
# `VBoxManage list dhcpservers` prints one block per server:
#
#     NetworkName:    HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter
#     Dhcpd IP:       192.168.56.100
#     LowerIPAddress: 192.168.56.101
#     UpperIPAddress: 192.168.56.254
#     NetworkMask:    255.255.255.0
#     Enabled:        Yes
#     Global Configuration:
#         minLeaseTime:     default
#         ...
#             1/legacy: 255.255.255.0
#     Groups:               None
#     Individual Configs:   None
#
# Only the six top-level fields above are read. The "Global Configuration:"
# block is indented, and every field pattern below is anchored at column 0, so
# the nested "minLeaseTime:"-style lines and the odd "1/legacy:" entry cannot
# be picked up as fields. "Groups:" / "Individual Configs:" do sit at column 0
# like real fields and are skipped only because their labels are not in the
# list. Do not loosen the patterns into a generic "key: value" match without
# re-checking against build/testdata/dhcpservers_normal.txt.
#
# A block with no Enabled line reads as $false. VBoxManage always prints the
# line, so the missing case means a truncated capture, not a state to
# interpret; $false is the safe reading and keeps the field a real [bool].
function Parse-DhcpServers {
    param([string[]]$Lines)
    $out = @()
    $cur = $null
    foreach ($line in $Lines) {
        if ($line -match '^NetworkName:\s+(.+)$') {
            if ($cur) { $out += [pscustomobject]$cur }
            $cur = @{
                NetworkName = $Matches[1].Trim()
                DhcpdIP     = ""
                LowerIP     = ""
                UpperIP     = ""
                NetworkMask = ""
                Enabled     = $false
            }
            continue
        }
        if (-not $cur) { continue }
        if     ($line -match '^Dhcpd IP:\s+(.+)$')       { $cur.DhcpdIP     = $Matches[1].Trim() }
        elseif ($line -match '^LowerIPAddress:\s+(.+)$') { $cur.LowerIP     = $Matches[1].Trim() }
        elseif ($line -match '^UpperIPAddress:\s+(.+)$') { $cur.UpperIP     = $Matches[1].Trim() }
        elseif ($line -match '^NetworkMask:\s+(.+)$')    { $cur.NetworkMask = $Matches[1].Trim() }
        elseif ($line -match '^Enabled:\s+(\S+)\s*$')    { $cur.Enabled     = ($Matches[1] -eq "Yes") }
    }
    if ($cur) { $out += [pscustomobject]$cur }
    return $out
}

# Joins each DHCP server to the host-only adapter it serves.
#
# The join key is the FULL network name on both sides: a server's NetworkName
# and an adapter's VBoxNetworkName are the same
# "HostInterfaceNetworking-<adapter name>" string, so they compare directly
# with no normalisation.
#
# Neither a hand-built literal nor the adapter's Name may be used here. The
# adapter's name is the "VirtualBox Host-Only Ethernet Adapter" form with no
# prefix, so it never equals a NetworkName; and a literal
# "HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter" stops
# matching the moment the adapter carries a "#N" suffix, which is exactly the
# false alarm the deleted install.ps1 self-check used to produce. Feeding the
# parsed VBoxNetworkName avoids this: the suffix travels into VBoxNetworkName,
# so the two sides still compare equal.
#
# A server with no matching adapter is NOT an error and carries no verdict: it
# keeps Interface = $null / IfName = "" and the caller decides what to say.
function Join-DhcpServerToHostOnlyIf {
    param([object[]]$DhcpServers, [object[]]$HostOnlyIfs)
    $out = @()
    foreach ($s in @($DhcpServers)) {
        $match = $null
        foreach ($i in @($HostOnlyIfs)) {
            if ($i.VBoxNetworkName -and ($i.VBoxNetworkName -eq $s.NetworkName)) { $match = $i; break }
        }
        $out += [pscustomobject]@{
            NetworkName = $s.NetworkName
            DhcpdIP     = $s.DhcpdIP
            LowerIP     = $s.LowerIP
            UpperIP     = $s.UpperIP
            NetworkMask = $s.NetworkMask
            Enabled     = $s.Enabled
            Interface   = $match
            IfName      = $(if ($match) { $match.Name } else { "" })
        }
    }
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
# so it is NOT host-only specific. The adapter must be joined by
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
# perfectly healthy machine (verified 2026-09-15: only _V2Providers exists).
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
#
# HasAllowRule alone is not enough to call the requirement met. A rule is only
# effective on the profiles it covers, and Huawei's FAQ asks for Domain /
# Private / Public. A Public-only rule on a domain-joined machine is enabled,
# allows, and still does not apply. The matching block's Profile is
# returned alongside the verdict and the caller decides whether the covered
# set is good enough. This parser cannot decide it: which profile is ACTIVE
# depends on the machine, not on the rule text.
#
# Profile is "" when the text carried no Profile line at all (older callers,
# or a fixture that predates this field); that means "unknown", NOT "covers
# nothing".
function Parse-FirewallRulesForEnsp {
    param([string[]]$Lines)
    $text = ($Lines -join "`n")
    $blocks = [regex]::Split($text, '(\r?\n){2,}')
    foreach ($b in $blocks) {
        if ($b -match '(?m)^DisplayName\s*:\s*.*eNSP_VBoxServer' -and
            $b -match '(?m)^Enabled\s*:\s*True' -and
            $b -match '(?m)^Action\s*:\s*Allow') {
            $profile = ""
            if ($b -match '(?m)^Profile\s*:\s*(.+?)\s*$') { $profile = $Matches[1] }
            return [pscustomobject]@{ HasAllowRule = $true; Profile = $profile }
        }
    }
    return [pscustomobject]@{ HasAllowRule = $false; Profile = "" }
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

# Reads one named field out of an interface record regardless of how that
# record is shaped, trying the names in order and returning "" when none of
# them carries a value.
#
# Two record shapes have to be served, and neither is exotic:
#   - [pscustomobject] { Name, IPv4 }        -- hand-built, or projected
#   - raw Get-NetIPAddress                   -- { InterfaceAlias, IPAddress }
# Presence is tested with PSObject.Properties rather than `-ne $null` so that a
# property that exists but holds $null takes the same path as one that is
# absent, which is what lets the caller simply move on to the next name.
#
# Hashtables are a third shape and need their own probe: a Hashtable does NOT
# surface its keys through PSObject.Properties (it reports the Hashtable type's
# own members instead), so a Properties-only read would silently see every
# hashtable record as empty. Callers do pass hashtable literals, so the
# dictionary is checked separately.
function Get-InterfaceField {
    param([object]$Interface, [string[]]$Names)
    if ($null -eq $Interface) { return "" }
    foreach ($n in $Names) {
        $prop = $Interface.PSObject.Properties[$n]
        if ($null -ne $prop) { return [string]$prop.Value }
        if (($Interface -is [System.Collections.IDictionary]) -and $Interface.Contains($n)) {
            return [string]$Interface[$n]
        }
    }
    return ""
}

# Accepted record shapes, and why the name has to be resolved so carefully:
#   address: IPv4 if present, else IPAddress
#   name   : InterfaceAlias if present, else Name
#
# The name order is the counter-intuitive half. A raw Get-NetIPAddress object
# DOES carry a .Name property, so "prefer Name" looks safe and is not: on a
# non-English Windows .Name is mojibake (observed on this machine as
# ';C<8;@B8?@8;55><55;55;' rather than the adapter alias), while the real
# connection name is in .InterfaceAlias. Preferring Name would therefore print
# unreadable text in a report that is supposed to be read by a human.
# InterfaceAlias must win whenever the object has it.
#
# Getting the address wrong is worse than a cosmetic bug: feeding raw
# Get-NetIPAddress output to a parser that only understood { Name, IPv4 }
# produced OwnerCount = 0 on a machine where an adapter genuinely held
# 192.168.56.1, a false all-clear on a conflict check.
function Compare-SubnetOwners {
    param([object[]]$Interfaces, [string]$Prefix)
    $owners = @($Interfaces | Where-Object {
        (Get-InterfaceField -Interface $_ -Names @("IPv4", "IPAddress")) -like ($Prefix + "*")
    })
    return [pscustomobject]@{
        OwnerCount = $owners.Count
        Owners     = @($owners | ForEach-Object {
            Get-InterfaceField -Interface $_ -Names @("InterfaceAlias", "Name")
        })
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
# working: the classic "only AR is broken" report.
#
# Threshold rationale, and a correction to the usual telling: community write-ups
# describe a 1 MB factory default, but that came from the VirtualBox 5.0 era.
# Measured on eNSP V1.3.00.100 (2026-09-15): AR_Base.vbox = 16, vfw_usg.vbox = 12,
# WLAN_AC_Base.vbox = 16. No shipped template is anywhere near 1. So this check
# fires only when the value has been actively lowered: it is a guard against
# a bad edit, not against a factory state. Report the value regardless; the
# number is what makes the "only AR is broken" case diagnosable.
#
# Reads the LIVE hardware block only. Scanning the raw line list would return
# the snapshot's VRAMSize, because <Snapshot> comes first in the file, the
# same trap Parse-UartPorts documents, and it was live here too: both parsers
# were reading the snapshot and agreeing with reality only because the two
# values happened to be identical on every template measured.
function Get-VramSizeFromTemplate {
    param([string[]]$Lines)
    foreach ($l in (Get-LiveHardwareBlock -Lines $Lines)) {
        if ($l -match 'VRAMSize\s*=\s*"(\d+)"') { return [int]$Matches[1] }
    }
    return $null
}

# The parameter is deliberately UNTYPED. With `param([int]$VramSize)` the
# binder coerces $null to 0 before the body ever runs, and 0 < 9, so a template
# that has no VRAMSize element at all (Get-VramSizeFromTemplate returns $null
# for exactly that case) was reported as "too small". "Could not determine"
# is not the same finding as "too small": a probe must not invent a defect out
# of a missing value, so an unreadable size is reported as NOT too small and the
# caller decides what to say about the $null. The cast is moved into the body,
# where it happens only after the guard, and is written explicitly because
# `[int]$V -lt 9` is not the same expression as `([int]$V) -lt 9`; without
# the cast a string operand would compare as text ("10" -lt 9 is True).
function Test-VramTooSmall {
    param($VramSize)
    if ($null -eq $VramSize) { return $false }
    if ("$VramSize" -eq "")  { return $false }
    return (([int]$VramSize) -lt 9)
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
#
# Profile is emitted because a rule that does not cover the active profile is
# not an effective allow rule. Without it the parser could only ever say "an
# enabled allow rule exists", true and useless on a domain-joined machine
# whose rule covers Public only.
function Get-FirewallRuleTextForEnsp {
    # Pass a [ref] to find out whether the policy was actually enumerated.
    # An empty result has two very different meanings: "the policy was read,
    # nothing matched" and "the policy could not be read at all". A caller that
    # cannot tell them apart reports the wrong thing -- and, worse, a machine
    # with no eNSP rule whatsoever is exactly the one that needs the repair,
    # while an unreadable policy is the one where no judgement is possible.
    # Callers that do not pass -ReadOk keep the old behaviour.
    param([ref]$ReadOk)
    if ($ReadOk) { $ReadOk.Value = $false }
    $lines = @()
    try {
        # COM (HNetCfg.FwPolicy2) rather than Get-NetFirewallRule. Measured
        # 2026-09-16 on a 1274-rule machine: 6.98 s via the NetSecurity cmdlet
        # versus 0.08 s here. The cmdlet's cost is in the CIM provider and does
        # not shrink when a -DisplayName filter is supplied. The install-time
        # pre-check runs this on every install, so the 7 s was paid even on
        # healthy machines for a check that only ever reports.
        #
        # The COM properties are also already structured, so nothing has to be
        # inferred from formatted text: Action 1 = Allow, 0 = Block;
        # Profiles is a bitmask (1 = Domain, 2 = Private, 4 = Public).
        $fw = New-Object -ComObject HNetCfg.FwPolicy2
        foreach ($r in $fw.Rules) {
            $name = [string]$r.Name
            $app = [string]$r.ApplicationName
            if (-not (($name -like "*eNSP*") -or ($app -like "*eNSP*") -or
                      ($name -like "*VBoxServer*") -or ($app -like "*VBoxServer*"))) { continue }

            $profiles = @()
            $p = [int]$r.Profiles
            if ($p -band 1) { $profiles += "Domain" }
            if ($p -band 2) { $profiles += "Private" }
            if ($p -band 4) { $profiles += "Public" }
            if ($p -eq 0 -or $profiles.Count -eq 0) { $profiles += "Any" }

            $lines += "DisplayName  : " + $name
            $lines += "Enabled      : " + $(if ($r.Enabled) { "True" } else { "False" })
            $lines += "Direction    : " + $(if ([int]$r.Direction -eq 1) { "Inbound" } else { "Outbound" })
            $lines += "Action       : " + $(if ([int]$r.Action -eq 1) { "Allow" } else { "Block" })
            $lines += "Profile      : " + ($profiles -join ", ")
            $lines += ""
        }
        if ($ReadOk) { $ReadOk.Value = $true }
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

# ===========================================================================
# Device readiness: base VM registration, link snapshots, templates
# ===========================================================================
#
# Every AR / WLAN / USG device is a link clone of a base VM. Making the clone
# takes three things that are all invisible from the shim's own log when they
# are missing: the clonevm call is never reached, eNSP just reports error 40:
#
#   1. a registration entry for the base VM
#   2. a snapshot named "<VM>_Link" on the base disk (the clone source)
#   3. a template that still carries the wiring eNSP expects
#
# None of the three is checked by anything else in this file, and (1)+(2) are
# the ones that actually broke on 2026-09-16.

# The five base VMs eNSP link-clones from. The directory name under
# vboxserver\ is also the VM name, which is what makes the join below possible
# without asking VirtualBox anything.
function Get-BaseVmDirs {
    param(
        [string]$EnspDir,
        [string[]]$BaseVms = @("AR_Base", "WLAN_AC_Base", "WLAN_AD_Base", "WLAN_AP_Base", "WLAN_SAP_Base")
    )
    $items = @()
    if (-not $EnspDir) { return $items }
    $root = Join-Path $EnspDir "vboxserver"
    foreach ($vm in $BaseVms) {
        $dir = Join-Path $root $vm
        $present = Test-Path $dir
        $vboxFile = ""
        if ($present) {
            $vboxFile = Find-MachineConfig -Dir $dir
        }
        $items += [pscustomobject]@{
            Name       = $vm
            Dir        = $dir
            DirPresent = $present
            VBoxFile   = $vboxFile
        }
    }
    return $items
}

# Picks the machine config out of a base VM directory.
#
# A directory can hold several .vbox files: eNSP writes dated/suffixed copies
# next to the live one, and the live one is the SHORTEST name (the others carry
# extra suffixes). Sorting by name length and taking the first that actually
# parses as a machine reproduces register_vms.ps1's Select-VBoxFile, which is
# what the repair path will later act on. The two must agree or the report
# would describe a different file than the one that gets registered.
function Find-MachineConfig {
    param([string]$Dir)
    if (-not $Dir -or -not (Test-Path $Dir)) { return "" }
    $cands = Get-ChildItem -Path $Dir -Filter *.vbox -File -ErrorAction SilentlyContinue |
             Sort-Object { $_.Name.Length }
    foreach ($f in $cands) {
        $t = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($t -match '<Machine ') { return $f.FullName }
    }
    return ""
}

# `VBoxManage list vms` prints one line per registered VM:
#
#     "AR_Base" {0f3e5d1c-8a44-4b1e-9c2f-6d0a7b3e5f21}
#
# Returns name -> lowercased uuid. The name is the join key everywhere else in
# this file; the uuid is only needed to reach into the registry map below.
function Parse-VBoxListVms {
    param([string[]]$Lines)
    $m = @{}
    foreach ($line in $Lines) {
        if ($line -match '^"([^"]+)"\s+\{([0-9a-fA-F-]+)\}') {
            $m[$Matches[1]] = $Matches[2].ToLower()
        }
    }
    return $m
}

# The user's VirtualBox.xml keeps one entry per registered VM:
#
#     <MachineEntry uuid="{0f3e...}" src="C:\Program Files\...\AR_Base.vbox"/>
#
# This is the authoritative registered path, and reading it costs one file read
# instead of one `showvminfo` per VM. VirtualBox writes doubled backslashes and
# inconsistent casing here, hence the normalisation in Test-SameVmPath.
#
# Case matters in the pattern: VirtualBox writes both attribute names
# lowercase, and [regex]::Matches is case-sensitive where -match is not. A
# fixture that spells them differently will silently yield an empty map.
function Parse-VBoxMachineRegistry {
    param([string[]]$Lines)
    $m = @{}
    $text = ($Lines -join "`n")
    foreach ($mt in [regex]::Matches($text, 'uuid="\{([0-9a-fA-F-]+)\}"\s+src="([^"]+)"')) {
        $m[$mt.Groups[1].Value.ToLower()] = $mt.Groups[2].Value
    }
    return $m
}

# `VBoxManage snapshot <vm> list --machinereadable` prints, per snapshot:
#
#     SnapshotName="AR_Base_Link"
#     SnapshotUUID="..."
#     SnapshotName-1="AR_Base_Link"        <- nested children use a -N suffix
#
# Only the names are read. Note the command FAILS (non-zero exit) on a VM with
# no snapshots at all, so an empty result is the normal answer for a bare base
# disk and is not an error condition this parser can see.
function Parse-VBoxSnapshotList {
    param([string[]]$Lines)
    $names = @()
    foreach ($line in $Lines) {
        if ($line -match '^SnapshotName(-[0-9]+)?="([^"]+)"') { $names += $Matches[2] }
    }
    return $names
}

# `showvminfo <vm> --machinereadable` prints VMState="poweroff" among many
# other lines. Empty string means the VM could not be queried at all, which is
# a different thing from any state and is reported as such.
function Parse-VmState {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ($line -match '^VMState="([^"]+)"') { return $Matches[1] }
    }
    return ""
}

# eNSP's link clone needs the base disk to carry a snapshot literally named
# "<base VM name>_Link". Its absence is what makes a freshly re-registered base
# disk unusable: clonevm fails with "does not have any snapshots".
function Test-LinkSnapshotPresent {
    param([string[]]$SnapshotNames, [string]$VmName)
    if (-not $VmName) { return $false }
    return (@($SnapshotNames) -contains ($VmName + "_Link"))
}

# Two paths name the same file after folding the differences VirtualBox
# introduces: doubled separators in src, and casing that does not match disk.
# Both sides are normalised the same way, so this is symmetric.
function Test-SameVmPath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    $na = ($A.Trim() -replace '\\+', '\').TrimEnd('\').ToLower()
    $nb = ($B.Trim() -replace '\\+', '\').TrimEnd('\').ToLower()
    return ($na -eq $nb)
}

# Joins the three views into one record per base VM. Pure: every input is
# already-collected data, so the whole decision table is reachable from
# fixtures without a VirtualBox install.
#
# The verdict is deliberately split into two independent fields rather than one
# status string. "Registered but pointing at a deleted path" and "not
# registered at all" have the same repair (unregister if needed, then register)
# but different evidence, and the report prints the evidence.
function Resolve-BaseVmRegistration {
    param(
        [object[]]$BaseVmDirs,
        [hashtable]$RegisteredVms,
        [hashtable]$RegistrySrc,
        [hashtable]$VmStates,
        [hashtable]$VmSnapshots
    )
    if (-not $RegisteredVms) { $RegisteredVms = @{} }
    if (-not $RegistrySrc)   { $RegistrySrc   = @{} }
    if (-not $VmStates)      { $VmStates      = @{} }
    if (-not $VmSnapshots)   { $VmSnapshots   = @{} }

    $out = @()
    foreach ($b in @($BaseVmDirs)) {
        if ($null -eq $b) { continue }
        $name = $b.Name
        $isReg = $RegisteredVms.ContainsKey($name)
        $src = ""
        if ($isReg) {
            $u = $RegisteredVms[$name]
            if ($RegistrySrc.ContainsKey($u)) { $src = $RegistrySrc[$u] }
        }
        $pathOk = ($isReg -and (Test-SameVmPath -A $src -B $b.VBoxFile))
        $state = ""
        if ($VmStates.ContainsKey($name)) { $state = $VmStates[$name] }
        $snaps = @()
        if ($VmSnapshots.ContainsKey($name)) { $snaps = @($VmSnapshots[$name]) }

        $out += [pscustomobject]@{
            Name           = $name
            DirPresent     = [bool]$b.DirPresent
            VBoxFile       = $b.VBoxFile
            Registered     = $isReg
            RegisteredPath = $src
            PathValid      = $pathOk
            State          = $state
            # Only meaningful when registered: an unregistered VM is never
            # queried for snapshots, so $false here means "unknown", not "gone".
            LinkSnapshot   = $(if ($isReg) { Test-LinkSnapshotPresent -SnapshotNames $snaps -VmName $name } else { $false })
        }
    }
    return $out
}

# --- the live <Hardware> block ---------------------------------------------
#
# A .vbox repeats the ENTIRE hardware section inside every <Snapshot>, and the
# snapshot blocks come FIRST. Measured on a real AR_Base.vbox (2026-09-16):
# the <Snapshot> element sits at line 24 and the live <Hardware> only at line
# 75, so "take the first <Hardware>" silently returns the SNAPSHOT's hardware.
#
# That mistake is invisible while the two happen to agree, which they did on
# every template measured here, because the snapshot was taken moments after
# the live config was written. It stops being invisible the moment someone
# changes a setting after snapshotting: the report would then describe a saved
# state as if it were the current one, and the VRAM/UART checks would both be
# reading the past.
#
# Nesting is walked TAG BY TAG, not line by line. A line-at-a-time counter gets
# <Snapshot uuid="{a}"><Hardware>...</Hardware></Snapshot> wrong, because the
# line closes and reopens the depth in one go and the <Hardware> in the middle is
# then read as live. A fixture written that way caught it. Scanning tags left to
# right inside each line handles both layouts.
#
# Both spellings of the container are accepted. VirtualBox 7.2 writes
# <Snapshot> directly under <Machine>, with no wrapper element (verified on a
# real AR_Base.vbox), while other versions put them in <Snapshots>. The tag
# pattern covers either:
#
#   <Snapshots?[\s>]   <Snapshot ...>   <Snapshot>   <Snapshots>
#   </Snapshots?>      </Snapshot>      </Snapshots>
#
# <Hardware> is matched separately and only counts when the depth is zero, so
# every snapshot's copy is skipped regardless of how they are laid out.
function Get-LiveHardwareBlock {
    param([string[]]$Lines)
    $depth = 0
    $collecting = $false
    $out = @()
    foreach ($line in @($Lines)) {
        foreach ($m in [regex]::Matches($line, '<(/?)(Snapshots?|Hardware)[\s>]')) {
            $closing = ($m.Groups[1].Value -eq '/')
            if ($m.Groups[2].Value -eq 'Hardware') {
                if ((-not $closing) -and (-not $collecting) -and ($depth -eq 0)) { $collecting = $true }
            } elseif ($closing) {
                if ($depth -gt 0) { $depth-- }
            } else {
                $depth++
            }
        }
        if ($collecting) {
            $out += $line
            if ($line -match '</Hardware>') { break }
        }
    }
    return $out
}

# --- AR template UART / COM2 pipe ------------------------------------------
#
# A device template carries its serial ports inside <Hardware><UART>:
#
#     <UART>
#       <Port slot="1" enabled="true" IOBase="0x2f8" IRQ="3"
#             server="true" path="\\.\pipe\config" hostMode="HostPipe"/>
#     </UART>
#
# eNSP's console attaches to that named pipe. A template whose slot-1 port is
# missing or disabled leaves eNSP waiting on a pipe nothing ever creates: the
# device never reaches its CLI even though the VM itself booted fine.
#
# Attribute parsing stops at the first '>' and never at '/', because the pipe
# path itself contains slashes ("\\.\pipe\config"); a [^/>]* class would cut
# the match short mid-value and lose every attribute after "path".
function Parse-UartPorts {
    param([string[]]$Lines)
    $text = (Get-LiveHardwareBlock -Lines $Lines) -join "`n"
    $hw = ""
    if ($text -match '(?s)<Hardware>(.*)</Hardware>') { $hw = $Matches[1] }
    $ports = @()
    foreach ($m in [regex]::Matches($hw, '<Port\s+([^>]*?)\s*/?>')) {
        $attrs = $m.Groups[1].Value
        $slot = ""
        $enabled = $false
        $hostMode = ""
        $path = ""
        if ($attrs -match 'slot="(\d+)"')                { $slot     = $Matches[1] }
        if ($attrs -match 'enabled="(true|false)"')      { $enabled  = ($Matches[1] -eq "true") }
        if ($attrs -match 'hostMode="([^"]*)"')          { $hostMode = $Matches[1] }
        if ($attrs -match 'path="([^"]*)"')              { $path     = $Matches[1] }
        $ports += [pscustomobject]@{
            Slot     = $slot
            Enabled  = $enabled
            HostMode = $hostMode
            Path     = $path
        }
    }
    return $ports
}

# Slot 1 is COM2. The two fields that decide whether a pipe endpoint exists at
# all are enabled and path; hostMode is carried in the facts but NOT required,
# because a template from an older eNSP may simply omit it and would otherwise
# be reported as broken on the strength of a missing attribute.
function Test-UartPipePresent {
    param([object[]]$Ports)
    foreach ($p in @($Ports)) {
        if ($null -eq $p) { continue }
        if (($p.Slot -eq "1") -and $p.Enabled -and $p.Path) { return $true }
    }
    return $false
}

# --- x86 VC++ runtime ------------------------------------------------------
#
# 32-bit eNSP marshals IVirtualBox through x86\VBoxProxyStub-x86.dll, which
# (via VBoxRT-x86.dll) needs the x86 VCRUNTIME140.dll and MSVCP140.dll. A clean
# machine has neither, the loader then finds the x64 copies in the main
# VirtualBox directory through PATH, and the mismatch surfaces as
# ERROR_BAD_EXE_FORMAT (0x800700C1) -> error 40.
#
# The installer deploys both into VBox\x86\, so this checks for them there and
# NOT anywhere else: an x64 copy in the main directory is exactly the failure
# state, not a pass. VCRUNTIME140_1.dll is genuinely not needed, since the
# proxystub dependency tree does not include it, so its absence must not be
# reported.
function Get-X86VcRuntimeFacts {
    param([string]$VBoxDir)
    $x86 = ""
    if ($VBoxDir) { $x86 = Join-Path $VBoxDir "x86" }
    $dirOk = ($x86 -ne "") -and (Test-Path $x86)
    $files = @()
    foreach ($n in @("VCRUNTIME140.dll", "MSVCP140.dll")) {
        $ok = $false
        if ($dirOk) { $ok = Test-Path (Join-Path $x86 $n) }
        $files += [pscustomobject]@{ Name = $n; Present = $ok }
    }
    return [pscustomobject]@{
        X86Dir      = $x86
        X86DirFound = $dirOk
        Files       = $files
        Complete    = (@($files | Where-Object { -not $_.Present }).Count -eq 0)
    }
}

# --- vboxserver write permission -------------------------------------------
#
# eNSP installs under Program Files. VBoxHeadless runs unelevated and has to
# create <vboxserver>\<VM>\Logs\ and write NVRAM / saved state there; without
# write permission the VM fails to power on and eNSP reports error 40 with
# nothing in its own log to explain it. The installer grants Modify on the tree
# (install.ps1's Grant-VBoxServerWrite), so what this checks is whether that
# grant (or an equivalent one) is present.
#
# The ACL is READ, never exercised: opening the directory for write to test it
# would be a side effect, and this file is contractually side-effect free.
#
# Consequently this is an approximation, and the caller must treat it as one.
# Deny entries are not ordered against allow entries, and group nesting is not
# expanded, so a positive result is strong evidence while a negative one is
# only a hint. Both the verdict and the raw grant list are returned so the
# report can show what the verdict was drawn from.
#
# The SID list comes from the CURRENT process token. Running the diagnostic
# elevated answers a different question than running it as the account that
# starts eNSP, which is why the report says which account it was run as.
function Get-VBoxServerAclFacts {
    param([string]$EnspDir)
    $dir = ""
    if ($EnspDir) { $dir = Join-Path $EnspDir "vboxserver" }
    $exists = ($dir -ne "") -and (Test-Path $dir)

    $sidList = @()
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $sidList += $id.User.Value
        foreach ($g in $id.Groups) { $sidList += $g.Value }
    } catch { }

    $grants = @()
    $has = $false
    if ($exists) {
        try {
            $acl = Get-Acl $dir -ErrorAction Stop
            foreach ($ace in $acl.Access) {
                if ($ace.AccessControlType -ne "Allow") { continue }
                $rights = $ace.FileSystemRights
                $write = (($rights -band [System.Security.AccessControl.FileSystemRights]::WriteData) -ne 0) -or
                         (($rights -band [System.Security.AccessControl.FileSystemRights]::Modify)    -ne 0) -or
                         (($rights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0)
                if (-not $write) { continue }
                $sid = ""
                try {
                    $sid = $ace.IdentityReference.Translate(
                        [System.Security.Principal.SecurityIdentifier]).Value
                } catch { }
                $grants += [pscustomobject]@{ Account = $ace.IdentityReference.Value; Sid = $sid }
                if ($sid -and ($sidList -contains $sid)) { $has = $true }
            }
        } catch { }
    }
    return [pscustomobject]@{
        Directory       = $dir
        Exists          = $exists
        WriteGrants     = $grants
        CurrentUserHasWrite = $has
    }
}

# --- packet capture driver -------------------------------------------------
#
# eNSP's capture path recognises WinPcap only. Npcap ships a WinPcap-compatible
# wpcap.dll that eNSP does not accept, AND its presence blocks installing the
# real WinPcap ("a newer version is already installed"). So the two have to be
# told apart, not merely detected.
#
# The discriminator is which product owns the wpcap.dll that eNSP loads, not
# which driver services happen to exist.
#
# Counting driver services would be wrong. Measured on 2026-09-16: npf.sys
# (WinPcap's driver) RUNNING alongside npcap.sys STOPPED, with wpcap.dll still
# WinPcap 4.1.3 from Riverbed. That is a healthy pair; two packet drivers
# coexist quietly and eNSP works. Treating "an npcap service
# exists" as Npcap having displaced WinPcap reported a false conflict on a
# machine that was fine. Hence the services below are facts for the report,
# never inputs to the verdict.
#
# SysWOW64 is the copy that matters: eNSP is a 32-bit process and loads the
# 32-bit wpcap.dll. A 64-bit mismatch in System32 would not reach it.
#
# ProductName is the only thing that tells the two apart: both install as
# wpcap.dll, and Npcap sets its own product name even though the file name
# and exported API are identical.
function Get-PacketDriverFacts {
    $dll = Join-Path $env:SystemRoot "SysWOW64\wpcap.dll"
    $version = ""
    $product = ""
    $present = Test-Path $dll
    if ($present) {
        try {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dll)
            $version = [string]$vi.FileVersion
            $product = [string]$vi.ProductName
        } catch { }
    }

    # Npcap living in its own subdirectory leaves the system wpcap.dll alone,
    # so the capture path still works. Both the 32- and 64-bit Npcap folders
    # are looked for because Npcap may be installed for one architecture only.
    $npcapDir = (Test-Path (Join-Path $env:SystemRoot "SysWOW64\Npcap")) -or
                (Test-Path (Join-Path $env:SystemRoot "System32\Npcap"))
    $npfSvc   = Get-Service -Name "npf"   -ErrorAction SilentlyContinue
    $npcapSvc = Get-Service -Name "npcap" -ErrorAction SilentlyContinue

    $c = ClassifyPacketDllProduct -Product $product -Present $present
    # Only a displaced wpcap.dll breaks eNSP, so that alone feeds the verdict.
    $r = ClassifyPacketDriver -WinPcapVersion $(if ($c.IsWinPcap) { $version } else { "" }) `
                              -NpcapPresent $c.IsNpcap

    return [pscustomobject]@{
        DllPath         = $dll
        DllPresent      = $present
        Version         = $version
        Product         = $product
        NpfService      = [bool]$npfSvc
        NpcapService    = [bool]$npcapSvc
        # Any form of Npcap being present, reported so the reader can see why
        # a later WinPcap install would refuse ("a newer version is installed").
        NpcapInstalled  = ($c.IsNpcap -or $npcapDir -or [bool]$npcapSvc)
        NpcapDisplaced  = $c.IsNpcap
        WinPcapPresent  = $r.WinPcapPresent
        WinPcapUsable   = $r.WinPcapUsable
    }
}

# Which product owns the wpcap.dll that eNSP loads, decided from its version
# resource alone. Split out from Get-PacketDriverFacts so the rule below is
# reachable from a fixture instead of only from a machine that happens to have
# both products installed.
#
# ORDER MATTERS, and Windows-style matching is why. "WinPcap" CONTAINS "nPcap"
# (the n is the last letter of "Win"), and -like is case-insensitive, so
# testing for Npcap first classifies WinPcap as Npcap and reports a conflict on
# a healthy WinPcap-only machine. That is the exact false positive this pair of
# functions exists to avoid; it was caught on 2026-09-16 by running the probe
# against a machine with WinPcap installed, and the assertion in
# build/tests/checks.Tests.ps1 pins it. WinPcap is therefore tested first and
# Npcap only when it did not match.
function ClassifyPacketDllProduct {
    param([string]$Product, [bool]$Present)
    $isWinPcap = ($Product -like "*WinPcap*")
    $isNpcap   = ($Present -and (-not $isWinPcap) -and ($Product -like "*Npcap*"))
    return [pscustomobject]@{
        IsWinPcap = $isWinPcap
        IsNpcap   = $isNpcap
    }
}

# --- non-ASCII paths -------------------------------------------------------
#
# eNSP passes paths through ANSI code pages in places, so an install directory
# or a user profile containing non-ASCII characters breaks device startup. The
# rule applies to the WHOLE path, not to any one component: a Chinese user
# profile under an ASCII eNSP directory is just as broken as the reverse.
#
# Pure and per-path on purpose: the caller checks each root it knows about and
# names the one that failed, because the fix differs (move eNSP vs. the profile
# cannot be moved at all without a new account).
function Test-NonAsciiPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    foreach ($ch in $Path.ToCharArray()) {
        if ([int]$ch -gt 127) { return $true }
    }
    return $false
}

# --- leftover VirtualBox processes -----------------------------------------
#
# Closing eNSP sends `controlvm poweroff` to every device. The Linux-guest
# devices (CE / CX / NE40E / NE5000E / NE9000) tear down slowly (measured at
# over five minutes), and a few crash while doing it, holding 0.4-1.5 GB each
# until the "application error" dialog is dismissed. Nothing is leaked; the
# memory returns once they finish. But it makes a healthy machine look broken,
# and nothing else in this report would reveal it.
#
# Ownership is decided by the VM's config path, never by the process name: a
# VBoxHeadless the user started from VirtualBox's own GUI is not eNSP's
# leftover and must not be reported as one. Same boundary cleanup_orphans.ps1
# draws before it kills anything.
function Test-EnspOwnedVmPath {
    param([string]$CfgFile, [string]$EnspDir, [string]$LocalAppData)
    if (-not $CfgFile) { return $false }
    $p = ($CfgFile.Trim() -replace '\\+', '\').TrimEnd('\').ToLower()
    $roots = @($EnspDir)
    if ($LocalAppData) { $roots += (Join-Path $LocalAppData "eNSP") }
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $r = ($root.Trim() -replace '\\+', '\').TrimEnd('\').ToLower()
        if ($p.StartsWith($r + '\')) { return $true }
    }
    return $false
}

# Running VMs joined against the registry map, which is where the config path
# comes from, so this costs no extra VBoxManage call per VM.
function Resolve-RunningVmOwnership {
    param(
        [string[]]$RunningVmNames,
        [hashtable]$RegisteredVms,
        [hashtable]$RegistrySrc,
        [string]$EnspDir,
        [string]$LocalAppData
    )
    if (-not $RegisteredVms) { $RegisteredVms = @{} }
    if (-not $RegistrySrc)   { $RegistrySrc   = @{} }
    $out = @()
    foreach ($n in @($RunningVmNames)) {
        if (-not $n) { continue }
        $src = ""
        if ($RegisteredVms.ContainsKey($n)) {
            $u = $RegisteredVms[$n]
            if ($RegistrySrc.ContainsKey($u)) { $src = $RegistrySrc[$u] }
        }
        $out += [pscustomobject]@{
            Name    = $n
            CfgFile = $src
            EnspOwned = (Test-EnspOwnedVmPath -CfgFile $src -EnspDir $EnspDir -LocalAppData $LocalAppData)
        }
    }
    return $out
}

# `VBoxManage list runningvms` prints the same shape as `list vms`, so the
# names come out of Parse-VBoxListVms's key set rather than a second parser.
function Get-RunningVmNames {
    param([hashtable]$RegisteredVms)
    if (-not $RegisteredVms) { return @() }
    return @($RegisteredVms.Keys)
}

# Process facts for the two sides of the question: is eNSP up, and how many
# VirtualBox processes are holding memory. Get-Process is read-only and needs
# no elevation for other users' processes.
function Get-VBoxProcessFacts {
    $names = @("VBoxHeadless", "VBoxSVC", "VBoxSDS", "VirtualBoxVM")
    $items = @()
    foreach ($n in $names) {
        $procs = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            $mem = 0
            try { $mem = [math]::Round($p.WorkingSet64 / 1MB, 1) } catch { }
            $items += [pscustomobject]@{
                Name    = $n
                Id      = $p.Id
                MemMB   = $mem
                Started = $(try { $p.StartTime.ToString("yyyy-MM-dd HH:mm:ss") } catch { "" })
            }
        }
    }
    $ensp = @(Get-Process -Name "eNSP" -ErrorAction SilentlyContinue).Count -gt 0
    $srv  = @(Get-Process -Name "eNSP_VBoxServer" -ErrorAction SilentlyContinue).Count -gt 0
    return [pscustomobject]@{
        EnspRunning     = $ensp
        ServerRunning   = $srv
        Processes       = $items
        HeadlessCount   = @($items | Where-Object { $_.Name -eq "VBoxHeadless" }).Count
    }
}

# ===========================================================================
# VirtualBox release log and hardening log
# ===========================================================================
#
# Formats below were verified against VirtualBox source on 2026-09-16. The one
# thing to know before touching any of this: the DECIMAL negative rc form
# ("rc=-5657") exists only in VBoxHardening.log. VBox.log prints "%Rrc" and the
# CLI prints "code <SYMBOL> (0x<HEX>)", so grepping VBox.log for a bare -5657
# finds nothing, and a parser written against the wrong file looks correct while
# never matching. Anything that legitimately lives in both places is matched on
# the symbolic name instead.

# Names for the hardening codes worth naming at all. Source: include/VBox/err.h.
# -5600..-5679 is the VERR_SUP_VP_* block; -104 sits outside it -- it is IPRT's
# generic VERR_ACCESS_DENIED, and it lands in this log when the hardened child
# cannot be spawned at all (CreateProcessW refuses before any module is opened).
# An unrecognised code is reported as its bare number rather than guessed at.
function Get-HardeningCodeMeaning {
    param([int]$Code)
    switch ($Code) {
        -5657 { return "VERR_SUP_VP_NOT_SIGNED_WITH_BUILD_CERT" }
        -5640 { return "VERR_SUP_VP_THREAD_NOT_ALONE" }
        -5607 { return "VERR_SUP_VP_BAD_IMAGE_SIZE" }
        -104  { return "VERR_ACCESS_DENIED" }
        default { return "" }
    }
}

# enmWhat is the SUPINITOP step that failed (include/VBox/sup.h):
#   0 Invalid, 1 Integrity, 2 RootCheck, 3 Driver, 4 IPRT, 5 Misc
function Get-HardeningStepName {
    param([int]$What)
    switch ($What) {
        1 { return "Integrity" }
        2 { return "RootCheck" }
        3 { return "Driver" }
        4 { return "IPRT" }
        5 { return "Misc" }
        default { return "" }
    }
}

# VBoxHardening.log parser.
#
# Every line carries a "%x.%x: " prefix: hex process id, dot, hex thread id,
# e.g. "1f2c.1f30: supR3HardenedWinVerifyProcess: ...". The prefix is stripped
# before matching so the patterns below stay independent of it.
#
# Failure anchor, written by SUPR3HardenedMain.cpp as
# "Error %d in %s! (enmWhat=%d)":
#
#     Error -5657 in supR3HardenedWinReSpawn! (enmWhat=5)
#
# A second form, "Error (rc=-5657):", comes from supR3HardenedErrorV. Both are
# matched. There is NO end-of-log marker: a failing run simply stops after the
# error, and the file is capped at 16 MiB, so absence of an anchor, not the
# presence of an ending, means the run was clean.
#
# A rejected module is named on its own line. The `rejecting '<path>'` shape is
# the one that carries the file name; the slash-free pattern is used so that a
# path containing quotes or spaces cannot truncate the capture early.
function Parse-HardeningLog {
    param([string[]]$Lines)
    $errors = @()
    $rejected = @()
    $evidence = @()

    foreach ($raw in @($Lines)) {
        if (-not $raw) { continue }
        $body = $raw.Trim()
        if ($body -match '^[0-9a-fA-F]+\.[0-9a-fA-F]+:\s+(.*)$') { $body = $Matches[1] }

        if ($body -match '^Error\s+\(rc=(-?\d+)\)') {
            $code = [int]$Matches[1]
            $errors += [pscustomobject]@{
                Code   = $code
                Symbol = (Get-HardeningCodeMeaning -Code $code)
                Where  = ""
                Step   = ""
                Line   = $body
            }
            continue
        }
        if ($body -match '^Error\s+(-?\d+)\s+in\s+([A-Za-z0-9_]+)') {
            # Both groups are copied out BEFORE the next -match runs. $Matches is
            # a single automatic variable per scope: the enmWhat test below
            # overwrites it, and its pattern has only one group, so reading
            # $Matches[2] afterwards silently yields $null. Caught 2026-09-16 by
            # the assertion on Where: the code and the step both parsed fine,
            # which is exactly why the empty one was easy to miss.
            $code  = [int]$Matches[1]
            $where = $Matches[2]
            $step = ""
            $what = -1
            if ($body -match 'enmWhat=(\d+)') {
                $what = [int]$Matches[1]
                $step = Get-HardeningStepName -What $what
            }
            $errors += [pscustomobject]@{
                Code   = $code
                Symbol = (Get-HardeningCodeMeaning -Code $code)
                Where  = $where
                Step   = $(if ($step) { $step + " (" + $what + ")" } else { "" })
                Line   = $body
            }
            continue
        }
        if ($body -match "rejecting\s+'([^']+)'") {
            $rejected += $Matches[1]
            $evidence += $body
            continue
        }
        if ($body -match 'rejecting UNC name') {
            $rejected += $body
            $evidence += $body
            continue
        }
        # supR3HardenedErrorV / supR3HardenedFatalMsgV carry the same failure in
        # the release log's wording; keep them as evidence without parsing.
        if (($body -like "supR3HardenedErrorV*") -or ($body -like "supR3HardenedFatalMsgV*")) {
            $evidence += $body
            continue
        }
    }

    return [pscustomobject]@{
        Failed          = ($errors.Count -gt 0)
        Errors          = $errors
        RejectedModules = @($rejected | Select-Object -Unique)
        Evidence        = @($evidence | Select-Object -First 12)
    }
}

# Which execution backend the VM actually used.
#
# The trap, and the reason this is a parser rather than three greps: the line
# "HM: VT-x/AMD-V init method: Local" looks decisive and is not; it describes
# how the HM module initialised, not which backend ran the guest. It appears on
# NEM runs too. Only the lines below distinguish.
#
# Order of the tests matters. "HM: HMR3Init: Attempting fall back to NEM" also
# starts with "HM: HMR3Init:", so it has to be tested before the native pattern
# or a NEM run would be classified as native.
function Parse-VBoxLogBackend {
    param([string[]]$Lines)
    $native = ""
    $fallback = ""
    $nem = ""
    $iem = ""
    $forced = $false

    foreach ($raw in @($Lines)) {
        if (-not $raw) { continue }
        $line = $raw.Trim()
        if ($line -like "*HM: HMR3Init: Attempting fall back to NEM*") { $fallback = $line; continue }
        if ($line -like "*HM: Setting fHMEnabled to false because fUseNEMInstead is set*") { $forced = $true; continue }
        if ($line -like "*HM: HMR3Init: Falling back on IEM*") { $iem = $line; continue }
        if ($line -like "*NEM: NEMR3Init: Snail execution mode is active*") { $nem = $line; continue }
        if ($line -like "*NEM: NEMR3Init: Turtle execution mode is active*") { $nem = $line; continue }
        if ($line -like "*NEM: NEMR3Init: Not available*") { $nem = $line; continue }
        if ($line -like "*NEM: NEMR3Init: Disabled*") { $nem = $line; continue }
        if ($line -like "*HM: HMR3Init: VT-x*") { $native = $line; continue }
        if ($line -like "*HM: HMR3Init: AMD-V*") { $native = $line; continue }
    }

    # IEM is the last resort: both hardware and WHP were unavailable, the
    # guest is being interpreted, and every device will be unusably slow.
    $backend = "unknown"
    if ($iem) { $backend = "iem" }
    elseif ($nem -or $fallback) { $backend = "nem" }
    elseif ($native) { $backend = "native" }

    return [pscustomobject]@{
        Backend      = $backend
        NativeLine   = $native
        FallbackLine = $fallback
        NemLine      = $nem
        IemLine      = $iem
        ForcedNEM    = $forced
    }
}

# Literal strings VirtualBox writes into VBox.log that carry meaning for eNSP.
#
# Plain substrings, not regexes, because every one of these is copied verbatim
# from the source and a regex would only add ways to be wrong. Notes live in
# diag.ps1; this file is ASCII-only and the report is not.
#
# Deliberately absent: "Failed to create pipe". That string does not exist
# anywhere in the VirtualBox tree; the named-pipe driver writes
# "CreateNamedPipe failed" / "failed to create named pipe" instead. The
# "Failed to create pipe" wording observed in connection with eNSP comes from
# eNSP itself, so it cannot be found here and must not be claimed to be.
function Find-VBoxLogMarkers {
    param([string[]]$Lines)
    $pats = @(
        @{ Id = "intnet";        Text = "VERR_INTNET_FLT_IF_NOT_FOUND" }
        @{ Id = "nemNotAvail";   Text = "VERR_NEM_NOT_AVAILABLE" }
        @{ Id = "hardening";     Text = "supR3HardenedErrorV" }
        @{ Id = "hardeningFatal";Text = "supR3HardenedFatalMsgV" }
        @{ Id = "namedPipeSrv";  Text = "CreateNamedPipe failed" }
        @{ Id = "namedPipeSrv2"; Text = "failed to create named pipe" }
        @{ Id = "namedPipeCli";  Text = "failed to connect to named pipe" }
        @{ Id = "pdmConstruct";  Text = "PDM: Failed to construct" }
    )
    $out = @()
    foreach ($raw in @($Lines)) {
        if (-not $raw) { continue }
        $line = $raw.Trim()
        foreach ($p in $pats) {
            if ($line -like ("*" + $p.Text + "*")) {
                $out += [pscustomobject]@{ Id = $p.Id; Line = $line }
                break
            }
        }
    }
    return $out
}

# --- shim registration: the CLSID hijack ------------------------------------
#
# This is the fact that decides who eNSP ends up talking to, and nothing here
# checked it until now. The four VBox52.dll hashes in the report only prove the
# files were copied; they say nothing about whether anything ever loads them.
#
# When CLSID_VirtualBox's InprocServer32 points at the shim, COM activation
# inside the eNSP process is served by the shim and get_version answers 5.2.x.
# When it still points at Oracle's own proxy/stub, eNSP gets a genuine
# IVirtualBox, get_version answers 7.2.x, and that value is not one eNSP
# accepts -- it raises "VirtualBox version is not supported." and never reaches
# device startup at all.
#
# So the spoofer's registry Version value is a decoy. It is a string eNSP reads
# at one point; this key decides the object behind every call afterwards. Spoof
# the version and leave this key on Oracle's DLL, and the symptom is the same
# as not having spoofed anything -- which is exactly how a machine can produce
# a report with no failures and still refuse to start a device.
#
# eNSP is 32-bit, so the view it reads is the WOW6432Node one; the 64-bit view
# serves other callers. Both are returned, each with its own verdict, rather
# than being merged into one -- a reader needs to know which view is wrong.
#
# The stored value is compared against the shim path, not merely tested for
# presence. A stale absolute path left by an earlier install elsewhere is
# present, non-empty, and wrong.
function Test-SameRegPath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    # Same rules as register_vms.ps1's Norm: a stored path may carry doubled
    # separators, a trailing separator, and any casing.
    $na = ($A.Trim() -replace '\\+', '\').TrimEnd('\').ToLower()
    $nb = ($B.Trim() -replace '\\+', '\').TrimEnd('\').ToLower()
    return ($na -eq $nb)
}

function Get-ClsidHijackFacts {
    param(
        [string]$ClsidVbox = "",
        [string]$ExpectedDll = ""
    )
    if (-not $ClsidVbox) {
        return [pscustomobject]@{ Checked = $false; Views = @(); ExpectedDll = $ExpectedDll; AnyShim = $false; PrimaryShim = $false }
    }
    $views = @()
    foreach ($v in @(
        @{ Name = "64"; Key = "HKLM:\SOFTWARE\Classes\CLSID\$ClsidVbox\InprocServer32"; Primary = $false },
        @{ Name = "32"; Key = "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$ClsidVbox\InprocServer32"; Primary = $true }
    )) {
        $present = $false
        $server = ""
        $threading = ""
        $err = ""
        try {
            if (Test-Path $v.Key) {
                $p = Get-ItemProperty -Path $v.Key -ErrorAction Stop
                $present = $true
                $server = [string]$p.'(default)'
                $threading = [string]$p.ThreadingModel
            }
        } catch {
            $err = $_.Exception.Message
        }
        $points = $false
        if ($present -and $ExpectedDll -and $server) {
            $points = Test-SameRegPath -A $server -B $ExpectedDll
        }
        $views += [pscustomobject]@{
            Name           = $v.Name
            Key            = $v.Key
            Primary        = $v.Primary
            Present        = $present
            Server         = $server
            ThreadingModel = $threading
            PointsAtShim   = $points
            Error          = $err
        }
    }
    $any = (@($views | Where-Object { $_.Present -and $_.PointsAtShim }).Count -gt 0)
    $pri = (@($views | Where-Object { $_.Primary -and $_.PointsAtShim }).Count -gt 0)
    return [pscustomobject]@{
        Checked     = $true
        Views       = $views
        ExpectedDll = $ExpectedDll
        AnyShim     = $any
        PrimaryShim = $pri
    }
}

# --- hash of one file under the eNSP tree -----------------------------------
#
# Facts only: presence and hash. Which hash means which state is the caller's
# business, because those constants live in install.ps1 and keeping a second
# copy here is how the two drift apart -- the same reason the shim's own hash
# is read from install.ps1 rather than duplicated.
#
# A hash failure (file locked, permission) is returned as an error string
# rather than thrown: the report is worth more with one blank line in it than
# it is cut short.
function Get-TreeFileFact {
    param([string]$EnspDir = "", [string]$Rel = "")
    if ((-not $EnspDir) -or (-not $Rel)) {
        return [pscustomobject]@{ Rel = $Rel; Path = ""; Present = $false; Hash = ""; Error = "" }
    }
    $p = Join-Path $EnspDir $Rel
    $present = Test-Path $p
    $h = ""
    $err = ""
    if ($present) {
        try {
            $h = (Get-FileHash -Path $p -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
        } catch {
            $err = $_.Exception.Message
        }
    }
    return [pscustomobject]@{ Rel = $Rel; Path = $p; Present = $present; Hash = $h; Error = $err }
}
