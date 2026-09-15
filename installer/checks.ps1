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
function Parse-FirewallRulesForEnsp {
    param([string[]]$Lines)
    $text = ($Lines -join "`n")
    $has = ($text -match '(?m)^DisplayName\s*:\s*.*eNSP_VBoxServer' -and
            $text -match '(?m)^Enabled\s*:\s*True' -and
            $text -match '(?m)^Action\s*:\s*Allow')
    return [pscustomobject]@{ HasAllowRule = $has }
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
