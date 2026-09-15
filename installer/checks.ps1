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
