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
