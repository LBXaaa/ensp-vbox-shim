# fix.ps1 -- repair primitives for ensp-vbox-shim.
#
# This is the only file in the project that changes the system. Everything else
# is read-only. The contract:
#
#   - Every function does one thing, checks its own preconditions first, and
#     returns an object of plain facts:
#         Ok       the precondition held and the desired state was reached
#                  (real run), or the plan is valid (dry run)
#         Changed  a modification was actually made
#         Skipped  the step was already satisfied, nothing to do
#         DryRun   nothing was executed
#         Reason   "" on success, otherwise why not
#         Commands the exact command lines, so a caller can display them
#     Nothing here throws, calls exit, or calls Read-Host. A caller decides what
#     to say about a result; that is why these are library functions and not a
#     script.
#
#   - Every function takes -DryRun, which prints the commands it would run and
#     changes nothing. Real mode runs SILENTLY. Showing the plan before running
#     it (design section 7, constraint 3) is the caller's job: call once with
#     -DryRun to display, then again without it to execute. Keeping real mode
#     quiet is what leaves the interactive menu the single owner of the output.
#
#   - Order is a hard dependency, not a preference:
#         1 Repair-InstallNetAdp     device instance for the host-only miniport
#         2 Repair-InstallNetLwf     NetService component for the NDIS6 filter
#         3 Repair-BounceAdapter     forces the rebind that puts the filter into
#                                    the data path
#         4 Repair-CreateHostOnlyIf  interface + IP + DHCP entry
#     Steps 1-2 install driver packages; neither alone puts the filter in the
#     data path, which is what step 3 is for. Run step 4 first and the interface
#     exists with no working stack under it -- a state whose symptom (startvm
#     fails with VERR_INTNET_FLT_IF_NOT_FOUND) is identical to having repaired
#     nothing at all. That false "fixed it and it did not help" is the single
#     most expensive way to get this wrong.
#
#   - Two further steps sit OUTSIDE that chain, because nothing else depends on
#     them and they depend on nothing else:
#         5 Repair-RebuildPerfCounters  rebuild damaged Windows performance counters
#         6 Repair-AllowEnspFirewall    inbound allow rule for eNSP_VBoxServer.exe
#     They repair the SAME symptom as the chain above -- a device that prints
#     '####' forever and never reaches a prompt -- from two different layers,
#     which is why the diagnostic probes both and why leaving them out looks
#     exactly like having repaired nothing. Neither touches the network stack or
#     anything else on the machine, so both are the "lossless" tier of design
#     section 7.1: reversible, no reboot, no effect on unrelated functions.
#
#   - Two different names belong to the same adapter and they are NOT
#     interchangeable:
#         VBox side     VBoxManage hostonlyif ... names it, as printed by
#                       `VBoxManage list hostonlyifs` -> "VirtualBox Host-Only
#                       Ethernet Adapter", possibly with a "#N" suffix.
#         Windows side  the connection name is LOCALIZED ("Ethernet 11"), so it
#                       can never be matched on. InterfaceDescription is the
#                       stable key; resolve through it and then act on the exact
#                       connection name.
#     Steps 1/2/4 and the DHCP functions below take the VBox-side name;
#     Repair-BounceAdapter takes the Windows-side name.
#
# ASCII-only and BOM-less, exactly like checks.ps1: PowerShell 5.1 reads a
# BOM-less file as ANSI, so a non-ASCII literal here would be misread on a
# non-English machine and break parsing.
#
# checks.ps1 is dot-sourced for its pure parsers, so that a repair and the
# diagnostic that recommended it read the system the same way. install.ps1 must
# NEVER be dot-sourced -- it has top-level side effects and would run an install.

$fixScriptDir = $PSScriptRoot
if (-not $fixScriptDir) { $fixScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$fixChecksFile = ""
if ($fixScriptDir) { $fixChecksFile = Join-Path $fixScriptDir "checks.ps1" }
if ($fixChecksFile -and (Test-Path $fixChecksFile)) { . $fixChecksFile }

# ===========================================================================
# process and result plumbing
# ===========================================================================

# True when checks.ps1's parsers are loaded. Every function that needs one
# tests this first: without it the failure would surface as "the term
# 'Parse-HostOnlyIfs' is not recognized", and a repair library that throws on a
# damaged install bundle is useless exactly when it is needed.
function Test-ChecksAvailable {
    return [bool](Get-Command Parse-HostOnlyIfs -ErrorAction SilentlyContinue)
}

# The result shape every function returns. Extra carries step-specific facts;
# the six common fields mean the same thing everywhere.
function New-RepairResult {
    param(
        [bool]$Ok,
        [string]$Reason = "",
        [bool]$Changed = $false,
        [bool]$Skipped = $false,
        [bool]$DryRun = $false,
        [string[]]$Commands = @(),
        [hashtable]$Extra = @{}
    )
    $fields = [ordered]@{
        Ok       = $Ok
        Changed  = $Changed
        Skipped  = $Skipped
        DryRun   = $DryRun
        Reason   = $Reason
        Commands = @($Commands)
    }
    foreach ($k in $Extra.Keys) { $fields[$k] = $Extra[$k] }
    return [pscustomobject]$fields
}

# Renders a command line for display. Arguments containing a space are quoted,
# because the paths this file deals with ("C:\Program Files\Oracle\VirtualBox")
# all do, and a plan the user cannot copy back into a shell is not a plan.
function Format-CommandLine {
    param([string]$Exe, [string[]]$Arguments = @())
    $parts = @()
    foreach ($a in (@($Exe) + @($Arguments))) {
        if ("$a" -match '[ \t]') { $parts += ('"' + $a + '"') } else { $parts += "$a" }
    }
    return ($parts -join " ")
}

# Runs an external command and returns its output and exit code. Failure is a
# result, not an exception. The ErrorActionPreference save is load-bearing: a
# native command writing to stderr is promoted to a terminating error when the
# caller has set "Stop", and VBoxDrvInst's release log goes to stderr on a
# perfectly normal run.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ Ok = $true; ExitCode = $LASTEXITCODE; Output = $out }
    } catch {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1; Output = @($_.Exception.Message) }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-Elevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# Every step below writes driver or network state, which needs an elevated
# session. Gating on it up front turns "netcfg returned 5" into a sentence the
# caller can act on. Deliberately checked only on the real run: a dry run
# changes nothing, so it does not need the rights to do so.
function Test-RepairRights {
    param([bool]$DryRun)
    if ($DryRun) { return $true }
    return (Test-Elevated)
}

function Write-DryRunLine {
    param([string]$Step, [string]$Text)
    Write-Host ("[dry-run] " + $Step + ": " + $Text)
}

# ===========================================================================
# precondition gate
# ===========================================================================

# Whether it is safe to run repairs at all. The network-component rebind in
# steps 2-3 interrupts devices that are currently up, so eNSP must be closed
# first: not a safety margin, a requirement.
#
# -ProcessNames exists so this decision is testable. The names are given WITH
# their .exe suffix because that is how the user sees them in Task Manager, and
# Get-Process wants them without it; the suffix is stripped for the lookup and
# the original spelling is what gets reported back.
#
# Elevated is an informational fact, NOT part of Ok. Being non-elevated does not
# make a repair unsafe, it makes it ineffective -- a different finding with a
# different remedy (re-run elevated), so the caller gets to distinguish them.
function Test-RepairPreconditions {
    param([string[]]$ProcessNames = @("eNSP.exe", "eNSP_VBoxServer.exe"))

    $running = @()
    foreach ($n in @($ProcessNames)) {
        $base = [IO.Path]::GetFileNameWithoutExtension($n)
        if (Get-Process -Name $base -ErrorAction SilentlyContinue) { $running += $n }
    }

    return [pscustomobject]@{
        Ok       = ($running.Count -eq 0)
        Running  = @($running)
        Elevated = (Test-Elevated)
    }
}

# ===========================================================================
# host-only state (read-only)
# ===========================================================================

function Resolve-VBoxManageExe {
    param([string]$VBoxDir)
    $dir = Find-VBoxDir -Override $VBoxDir
    if (-not $dir) { return "" }
    return (Join-Path $dir "VBoxManage.exe")
}

# Reads both host-only listings once and joins them. Step 4 and the DHCP
# functions need the same pair, and the join must go through
# Join-DhcpServerToHostOnlyIf: a server's NetworkName equals an adapter's
# VBoxNetworkName, which is the only key that survives a "#N" suffix. A
# hand-built "HostInterfaceNetworking-..." literal is exactly the mistake the
# deleted install.ps1 self-check made, and it false-alarms the moment the
# adapter is renamed.
function New-HostOnlyStateError {
    param([string]$Message)
    return [pscustomobject]@{
        Ok = $false; Error = $Message; Interfaces = @(); Servers = @(); Joined = @()
    }
}

function Get-HostOnlyState {
    param([string]$VBoxManage)

    if (-not $VBoxManage) {
        return (New-HostOnlyStateError "VBoxManage.exe was not resolved")
    }
    if (-not (Test-Path $VBoxManage)) {
        return (New-HostOnlyStateError ("VBoxManage.exe not found: " + $VBoxManage))
    }

    $ifProbe = Invoke-Native -Exe $VBoxManage -Arguments @("list", "hostonlyifs")
    if (-not $ifProbe.Ok -or $ifProbe.ExitCode -ne 0) {
        return (New-HostOnlyStateError ("list hostonlyifs failed: " + ($ifProbe.Output -join " ")))
    }
    $dhcpProbe = Invoke-Native -Exe $VBoxManage -Arguments @("list", "dhcpservers")
    if (-not $dhcpProbe.Ok -or $dhcpProbe.ExitCode -ne 0) {
        return (New-HostOnlyStateError ("list dhcpservers failed: " + ($dhcpProbe.Output -join " ")))
    }

    $ifs     = @(Parse-HostOnlyIfs   -Lines $ifProbe.Output)
    $servers = @(Parse-DhcpServers   -Lines $dhcpProbe.Output)
    $joined  = @(Join-DhcpServerToHostOnlyIf -DhcpServers $servers -HostOnlyIfs $ifs)

    return [pscustomobject]@{
        Ok = $true; Error = ""; Interfaces = $ifs; Servers = $servers; Joined = $joined
    }
}

# Pure: VBoxManage prints exactly
#     Interface 'VirtualBox Host-Only Ethernet Adapter' was successfully created
# and the name must be read out of it rather than assumed. Assuming is what
# breaks after a fresh driver install, when the name comes back with a "#N"
# suffix and a hard-coded "VirtualBox Host-Only Ethernet Adapter" no longer
# names the adapter that was just created.
#
# The quote characters are matched through \u escapes so this file stays ASCII.
# VBoxManage emits the ASCII apostrophe; the curly forms are accepted too
# because a localized build could emit them, and a failed parse here silently
# costs the user the IP configuration that follows.
function Parse-CreatedHostOnlyIfName {
    param([string[]]$Lines)
    $text = ($Lines -join "`n")
    $m = [regex]::Match($text, "Interface\s+['\u2018\u2019](.+?)['\u2018\u2019]\s+was successfully created")
    if ($m.Success) { return $m.Groups[1].Value }
    return ""
}

# ===========================================================================
# step 1 -- install the host-only miniport
# ===========================================================================

# VBoxDrvInst installs the driver package AND creates a device instance for the
# miniport, which is what makes the adapter appear at all. This is the step that
# the 2026-09-15 failure needed: the package was missing from the driver store,
# and no amount of disabling/enabling an adapter that does not exist can help.
#
# "Already satisfied" is read from `VBoxDrvInst list` -- the same evidence the
# report's layer 1 uses, so the repair and the diagnostic agree on what
# "installed" means. Only a POSITIVE reading skips the step: an unreadable state
# is not evidence of health, so the step runs and reinstalls. Reinstalling a
# present package is harmless; skipping a needed one is the whole bug.
function Repair-InstallNetAdp {
    param([string]$VBoxDir = "", [switch]$DryRun)

    $step = "step 1 netadp6"
    if (-not (Test-ChecksAvailable)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "checks.ps1 is not loaded, so the current driver state cannot be read"
    }

    $dir = Find-VBoxDir -Override $VBoxDir
    if (-not $dir) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "VirtualBox install directory not found; pass -VBoxDir"
    }

    $exe = Join-Path $dir "VBoxDrvInst.exe"
    $inf = Join-Path $dir "drivers\network\netadp6\VBoxNetAdp6.inf"
    if (-not (Test-Path $exe)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason ("VBoxDrvInst.exe not found: " + $exe)
    }
    if (-not (Test-Path $inf)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason ("netadp6 INF not found: " + $inf)
    }

    $cmds = @(Format-CommandLine -Exe $exe -Arguments @("install", "--inf-file", $inf))

    $list = Invoke-Native -Exe $exe -Arguments @("list")
    if ($list.Ok -and $list.ExitCode -eq 0) {
        $drv = Parse-VBoxDrvInstList -Lines $list.Output
        if ($drv.NetAdpPresent) {
            if ($DryRun) { Write-DryRunLine $step "already registered (VBoxNetAdp6.NTAMD64 in the driver store); nothing to do" }
            return New-RepairResult -Ok $true -Skipped $true -DryRun ([bool]$DryRun) -Commands $cmds `
                -Extra @{ State = "VBoxNetAdp6.NTAMD64 already registered" }
        }
    }

    if ($DryRun) {
        Write-DryRunLine $step "would run: $($cmds[0])"
        return New-RepairResult -Ok $true -DryRun $true -Commands $cmds `
            -Extra @{ State = "VBoxNetAdp6.NTAMD64 not registered" }
    }
    if (-not (Test-RepairRights $false)) {
        return New-RepairResult -Ok $false -Commands $cmds -Reason "not elevated; installing a driver package needs administrator rights"
    }

    $run = Invoke-Native -Exe $exe -Arguments @("install", "--inf-file", $inf)
    if (-not $run.Ok -or $run.ExitCode -ne 0) {
        return New-RepairResult -Ok $false -Commands $cmds -Extra @{ ExitCode = $run.ExitCode } `
            -Reason ("VBoxDrvInst install failed (exit " + $run.ExitCode + "): " + ($run.Output -join " "))
    }
    return New-RepairResult -Ok $true -Changed $true -Commands $cmds
}

# ===========================================================================
# step 2 -- register the NDIS6 filter as a NetService component
# ===========================================================================

# This is the step people get wrong. `VBoxDrvInst install --inf-file
# ...\netlwf\VBoxNetLwf.inf` only PRE-INSTALLS the driver package. For an NDIS
# filter that is not enough: no NetService component instance is created, so the
# service stays Stopped and no VirtualBox component ever shows up in the
# adapter's bindings. INetCfg (netcfg) is the interface that creates the
# component, and it is the only command that works here.
#
# Note the two INF names differ by one letter -- netadp6 is the miniport,
# netlwf is the filter -- and mixing them up installs the wrong driver.
#
# "Already satisfied" is the existence of the VBoxNetLwf service, because
# creating that service is precisely what netcfg does. Whether the filter is
# actually carrying traffic is a different question and step 3's business; the
# report's layer 2 is what flags a stopped service. Get-Service is called with
# -Name on purpose: a bare Get-Service does not enumerate KernelDriver services.
function Repair-InstallNetLwf {
    param([string]$VBoxDir = "", [switch]$DryRun)

    $step = "step 2 netlwf"
    if (-not (Test-ChecksAvailable)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "checks.ps1 is not loaded, so the current filter state cannot be read"
    }

    $dir = Find-VBoxDir -Override $VBoxDir
    if (-not $dir) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "VirtualBox install directory not found; pass -VBoxDir"
    }

    $inf = Join-Path $dir "drivers\network\netlwf\VBoxNetLwf.inf"
    if (-not (Test-Path $inf)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason ("netlwf INF not found: " + $inf)
    }

    $netcfg = Join-Path $env:SystemRoot "System32\netcfg.exe"
    if (-not (Test-Path $netcfg)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason ("netcfg.exe not found: " + $netcfg)
    }

    $cmds = @(Format-CommandLine -Exe $netcfg -Arguments @("-v", "-l", $inf, "-c", "s", "-i", "oracle_VBoxNetLwf"))

    $svc = Get-Service -Name "VBoxNetLwf" -ErrorAction SilentlyContinue
    if ($svc) {
        if ($DryRun) {
            Write-DryRunLine $step ("already registered (VBoxNetLwf service present, status " + $svc.Status.ToString() + "); nothing to do")
        }
        return New-RepairResult -Ok $true -Skipped $true -DryRun ([bool]$DryRun) -Commands $cmds `
            -Extra @{ State = ("VBoxNetLwf service present, status " + $svc.Status.ToString()) }
    }

    if ($DryRun) {
        Write-DryRunLine $step "would run: $($cmds[0])"
        return New-RepairResult -Ok $true -DryRun $true -Commands $cmds `
            -Extra @{ State = "VBoxNetLwf service absent" }
    }
    if (-not (Test-RepairRights $false)) {
        return New-RepairResult -Ok $false -Commands $cmds -Reason "not elevated; registering a network component needs administrator rights"
    }

    $run = Invoke-Native -Exe $netcfg -Arguments @("-v", "-l", $inf, "-c", "s", "-i", "oracle_VBoxNetLwf")
    if (-not $run.Ok -or $run.ExitCode -ne 0) {
        return New-RepairResult -Ok $false -Commands $cmds -Extra @{ ExitCode = $run.ExitCode } `
            -Reason ("netcfg failed (exit " + $run.ExitCode + "): " + ($run.Output -join " "))
    }
    return New-RepairResult -Ok $true -Changed $true -Commands $cmds
}

# ===========================================================================
# step 3 -- bounce the adapter
# ===========================================================================

# Skipping this step is what produces the "I ran the repair and nothing
# changed" report. After step 2 the binding can read Enabled=True while the
# filter is still not in the data path, and startvm keeps failing with
# VERR_INTNET_FLT_IF_NOT_FOUND. Disabling and re-enabling the adapter forces the
# rebind; there is no way to get the same effect by inspecting anything.
#
# -AdapterName is the WINDOWS connection name, not the VBox one. It is resolved
# through InterfaceDescription because the connection name is localized and
# cannot be matched on. When it is omitted and exactly one host-only adapter
# exists, that one is used; when several exist the step refuses rather than
# picking one, because bouncing the wrong adapter is a real change to a machine
# whose only problem may be elsewhere.
#
# An adapter that arrives Disabled ends up Enabled. That is the intended
# outcome for a repair step -- a host-only adapter that is down cannot be
# carrying the filter either -- and WasStatus records it so the change is
# visible rather than silent.
function Repair-BounceAdapter {
    param([string]$AdapterName = "", [int]$SettleSeconds = 3, [switch]$DryRun)

    $step = "step 3 bounce"
    if (-not (Test-ChecksAvailable)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "checks.ps1 is not loaded, so the adapter cannot be resolved"
    }
    if (-not (Get-Command Disable-NetAdapter -ErrorAction SilentlyContinue)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "Disable-NetAdapter is unavailable; the NetAdapter module is missing"
    }

    $facts = @(Get-HostOnlyNetAdapterFacts)
    $target = $null
    if ($AdapterName) {
        foreach ($f in $facts) { if ($f.InterfaceName -eq $AdapterName) { $target = $f; break } }
        if (-not $target) {
            return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
                -Reason ("no VirtualBox Host-Only adapter with connection name '" + $AdapterName + "'")
        }
    } elseif ($facts.Count -eq 1) {
        $target = $facts[0]
    } elseif ($facts.Count -eq 0) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "no VirtualBox Host-Only adapter found; run steps 1-2 and step 4 first"
    } else {
        $names = @($facts | ForEach-Object { $_.InterfaceName })
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason ("several VirtualBox Host-Only adapters exist (" + ($names -join ", ") + "); pass -AdapterName to choose one")
    }

    $was = $target.Status
    $cmds = @(
        (Format-CommandLine -Exe "Disable-NetAdapter" -Arguments @("-Name", $target.InterfaceName, "-Confirm:`$false")),
        (Format-CommandLine -Exe "Enable-NetAdapter"  -Arguments @("-Name", $target.InterfaceName, "-Confirm:`$false"))
    )

    if ($DryRun) {
        Write-DryRunLine $step ("would run: " + $cmds[0])
        Write-DryRunLine $step ("would wait " + $SettleSeconds + "s, then run: " + $cmds[1])
        return New-RepairResult -Ok $true -DryRun $true -Commands $cmds `
            -Extra @{ AdapterName = $target.InterfaceName; InterfaceDescription = $target.InterfaceDescription; WasStatus = $was }
    }
    if (-not (Test-RepairRights $false)) {
        return New-RepairResult -Ok $false -Commands $cmds -Reason "not elevated; disabling a network adapter needs administrator rights"
    }

    try {
        Disable-NetAdapter -Name $target.InterfaceName -Confirm:$false -ErrorAction Stop
    } catch {
        return New-RepairResult -Ok $false -Commands $cmds -Extra @{ AdapterName = $target.InterfaceName; WasStatus = $was } `
            -Reason ("Disable-NetAdapter failed: " + $_.Exception.Message)
    }

    Start-Sleep -Seconds $SettleSeconds

    try {
        Enable-NetAdapter -Name $target.InterfaceName -Confirm:$false -ErrorAction Stop
    } catch {
        # The adapter is down at this point and staying down is worse than the
        # state we started in, so say so explicitly instead of reporting a
        # generic failure.
        return New-RepairResult -Ok $false -Commands $cmds `
            -Extra @{ AdapterName = $target.InterfaceName; WasStatus = $was; LeftDisabled = $true } `
            -Reason ("Enable-NetAdapter failed, adapter is left DISABLED: " + $_.Exception.Message)
    }

    return New-RepairResult -Ok $true -Changed $true -Commands $cmds `
        -Extra @{ AdapterName = $target.InterfaceName; InterfaceDescription = $target.InterfaceDescription; WasStatus = $was }
}

# ===========================================================================
# step 4 -- create the interface and configure it
# ===========================================================================

# Creates the host-only interface if none exists, points it at eNSP's subnet,
# and creates the VirtualBox DHCP server entry for it.
#
# The IP defaults are not invented: eNSP's own resources hard-code
# dest:192.168.56.1, and the pool below is what the installer has always used
# (and what a healthy machine reports). They are parameters so a machine that
# genuinely needs a different subnet is not blocked.
#
# ---------------------------------------------------------------------------
# DHCP IS CREATED DISABLED, ON PURPOSE -- DO NOT "FIX" THIS.
#
# Design section 10.1 lists "should the host-only DHCP server be enabled at
# all?" as an OPEN, UNVERIFIED question. Community guidance for VirtualBox 5.2
# says the server should be off; this project's installer creates and enables
# one; the two have never been reconciled by measurement. Creating it enabled
# here would silently pick a side of an open question and change behavior that
# nobody has tested.
#
# So this function leaves the entry DISABLED and never enables it. Enabling is
# Repair-EnableHostOnlyDhcp, a separate function, so a caller can offer it as
# its own distinct choice with its own explanation.
#
# Note that VirtualBox 7.2 REQUIRES one of --enable / --disable on
# `dhcpserver add` (the usage line brackets them as mandatory), so "leaving
# DHCP off" is the explicit --disable below, not the absence of a flag. The
# 5.x spellings --ifname / --ip / --lowerip / --upperip do not exist on 7.2;
# they were replaced by --interface / --server-ip / --lower-ip / --upper-ip.
# ---------------------------------------------------------------------------
function Repair-CreateHostOnlyIf {
    param(
        [string]$VBoxDir = "",
        [string]$InterfaceName = "",
        [string]$IPAddress = "192.168.56.1",
        [string]$NetMask = "255.255.255.0",
        [string]$DhcpServerIP = "192.168.56.100",
        [string]$DhcpLowerIP = "192.168.56.101",
        [string]$DhcpUpperIP = "192.168.56.254",
        [switch]$DryRun
    )

    $step = "step 4 hostonlyif"
    if (-not (Test-ChecksAvailable)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "checks.ps1 is not loaded, so the current interface state cannot be read"
    }

    $vbm = Resolve-VBoxManageExe -VBoxDir $VBoxDir
    if (-not $vbm) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "VirtualBox install directory not found; pass -VBoxDir"
    }
    if (-not (Test-Path $vbm)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason ("VBoxManage.exe not found: " + $vbm)
    }

    $state = Get-HostOnlyState -VBoxManage $vbm
    if (-not $state.Ok) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason $state.Error
    }

    # Decide whether an interface has to be created, and which one to configure.
    $needCreate = $false
    $target = $null
    if ($InterfaceName) {
        foreach ($i in $state.Interfaces) { if ($i.Name -eq $InterfaceName) { $target = $i; break } }
        if (-not $target -and $state.Interfaces.Count -gt 0) {
            $names = @($state.Interfaces | ForEach-Object { $_.Name })
            return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
                -Reason ("no host-only interface named '" + $InterfaceName + "'; present: " + ($names -join ", "))
        }
        if (-not $target) { $needCreate = $true }
    } elseif ($state.Interfaces.Count -eq 0) {
        $needCreate = $true
    } elseif ($state.Interfaces.Count -eq 1) {
        $target = $state.Interfaces[0]
    } else {
        $names = @($state.Interfaces | ForEach-Object { $_.Name })
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason ("several host-only interfaces exist (" + ($names -join ", ") + "); pass -InterfaceName to choose one")
    }

    # The interface name is unknown until the create runs, so the plan shows a
    # placeholder rather than pretending to know it. This is also why the name
    # is parsed out of the command's own output below instead of being assumed.
    $planName = $target.Name
    if ($needCreate) { $planName = "<created interface name>" }

    $cmds = @()
    if ($needCreate) {
        $cmds += (Format-CommandLine -Exe $vbm -Arguments @("hostonlyif", "create"))
    }

    $needIpConfig = $needCreate -or ($target.IPAddress -ne $IPAddress)
    if ($needIpConfig) {
        $cmds += (Format-CommandLine -Exe $vbm -Arguments @("hostonlyif", "ipconfig", $planName, ("--ip=" + $IPAddress), ("--netmask=" + $NetMask)))
    }

    # A DHCP server is matched to an interface through the adapter's real
    # VBoxNetworkName, never through its Name and never through a literal.
    $existingServer = $null
    foreach ($j in $state.Joined) {
        if ($target -and $j.Interface -and ($j.Interface.Name -eq $target.Name)) { $existingServer = $j; break }
    }
    $needDhcp = $needCreate -or (-not $existingServer)
    if ($needDhcp) {
        $cmds += (Format-CommandLine -Exe $vbm -Arguments @(
            "dhcpserver", "add",
            ("--interface=" + $planName),
            ("--server-ip=" + $DhcpServerIP),
            ("--netmask=" + $NetMask),
            ("--lower-ip=" + $DhcpLowerIP),
            ("--upper-ip=" + $DhcpUpperIP),
            "--disable"))
    }

    if ($DryRun) {
        if ($cmds.Count -eq 0) {
            Write-DryRunLine $step ("interface '" + $target.Name + "' already has " + $target.IPAddress + " and a DHCP entry; nothing to do")
        }
        foreach ($c in $cmds) { Write-DryRunLine $step ("would run: " + $c) }
        if ($needDhcp) { Write-DryRunLine $step "the DHCP entry is created DISABLED (design 10.1 is unresolved); enabling is Repair-EnableHostOnlyDhcp" }
        return New-RepairResult -Ok $true -DryRun $true -Commands $cmds -Skipped ($cmds.Count -eq 0) `
            -Extra @{ InterfaceName = $planName; NeedCreate = $needCreate; NeedIpConfig = $needIpConfig; NeedDhcp = $needDhcp; DhcpEnabled = $false }
    }
    if ($cmds.Count -eq 0) {
        return New-RepairResult -Ok $true -Skipped $true -Commands $cmds `
            -Extra @{ InterfaceName = $target.Name; DhcpEnabled = $false }
    }
    if (-not (Test-RepairRights $false)) {
        return New-RepairResult -Ok $false -Commands $cmds -Reason "not elevated; creating a host-only interface needs administrator rights"
    }

    $name = $planName
    if ($needCreate) {
        $create = Invoke-Native -Exe $vbm -Arguments @("hostonlyif", "create")
        if (-not $create.Ok -or $create.ExitCode -ne 0) {
            return New-RepairResult -Ok $false -Commands $cmds -Extra @{ ExitCode = $create.ExitCode } `
                -Reason ("hostonlyif create failed (exit " + $create.ExitCode + "): " + ($create.Output -join " "))
        }
        $name = Parse-CreatedHostOnlyIfName -Lines $create.Output
        if (-not $name) {
            # Fallback: whatever interface was not there before is the one that
            # was just created. Costs one extra listing and saves the user a
            # half-finished repair (interface made, no IP, still broken).
            $after = Get-HostOnlyState -VBoxManage $vbm
            if ($after.Ok) {
                foreach ($i in $after.Interfaces) {
                    $known = $false
                    foreach ($b in $state.Interfaces) { if ($b.Name -eq $i.Name) { $known = $true; break } }
                    if (-not $known) { $name = $i.Name; break }
                }
            }
        }
        if (-not $name) {
            return New-RepairResult -Ok $false -Commands $cmds `
                -Reason ("could not read the created interface name from VBoxManage output: " + ($create.Output -join " "))
        }
    }

    if ($needIpConfig) {
        $ip = Invoke-Native -Exe $vbm -Arguments @("hostonlyif", "ipconfig", $name, ("--ip=" + $IPAddress), ("--netmask=" + $NetMask))
        if (-not $ip.Ok -or $ip.ExitCode -ne 0) {
            return New-RepairResult -Ok $false -Commands $cmds -Extra @{ InterfaceName = $name; ExitCode = $ip.ExitCode } `
                -Reason ("hostonlyif ipconfig failed (exit " + $ip.ExitCode + "): " + ($ip.Output -join " "))
        }
    }

    if ($needDhcp) {
        $dhcp = Invoke-Native -Exe $vbm -Arguments @(
            "dhcpserver", "add",
            ("--interface=" + $name),
            ("--server-ip=" + $DhcpServerIP),
            ("--netmask=" + $NetMask),
            ("--lower-ip=" + $DhcpLowerIP),
            ("--upper-ip=" + $DhcpUpperIP),
            "--disable")
        if (-not $dhcp.Ok -or $dhcp.ExitCode -ne 0) {
            return New-RepairResult -Ok $false -Commands $cmds -Extra @{ InterfaceName = $name; ExitCode = $dhcp.ExitCode } `
                -Reason ("dhcpserver add failed (exit " + $dhcp.ExitCode + "): " + ($dhcp.Output -join " "))
        }
    }

    return New-RepairResult -Ok $true -Changed $true -Commands $cmds `
        -Extra @{ InterfaceName = $name; NeedCreate = $needCreate; NeedIpConfig = $needIpConfig; NeedDhcp = $needDhcp; DhcpEnabled = $false }
}

# ===========================================================================
# DHCP enable -- separate on purpose
# ===========================================================================

# Design section 10.1 leaves "should the host-only DHCP server be enabled" open,
# so it does not happen as a side effect of any other step. It lives here, alone
# and explicitly named, so a caller can offer it as a distinct choice with its
# own explanation and its own confirmation.
#
# Idempotent: an already-enabled server is reported as Skipped and nothing runs.
function Repair-EnableHostOnlyDhcp {
    param([string]$VBoxDir = "", [string]$InterfaceName = "", [switch]$DryRun)

    $step = "dhcp enable"
    if (-not (Test-ChecksAvailable)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "checks.ps1 is not loaded, so the current DHCP state cannot be read"
    }

    $vbm = Resolve-VBoxManageExe -VBoxDir $VBoxDir
    if (-not $vbm -or -not (Test-Path $vbm)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason "VBoxManage.exe was not found; pass -VBoxDir"
    }

    $state = Get-HostOnlyState -VBoxManage $vbm
    if (-not $state.Ok) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason $state.Error
    }

    # Resolved through the parsed VBoxNetworkName join, so a "#N" suffix is
    # harmless.
    $server = $null
    foreach ($j in $state.Joined) {
        if ($InterfaceName) {
            if ($j.Interface -and ($j.Interface.Name -eq $InterfaceName)) { $server = $j; break }
        } elseif ($j.Interface) {
            $server = $j; break
        }
    }
    if (-not $server) {
        if ($InterfaceName) {
            return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
                -Reason ("no DHCP server is attached to host-only interface '" + $InterfaceName + "'")
        }
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "no DHCP server is attached to any host-only interface; run step 4 first"
    }

    $cmds = @(Format-CommandLine -Exe $vbm -Arguments @("dhcpserver", "modify", ("--interface=" + $server.IfName), "--enable"))

    if ($server.Enabled) {
        if ($DryRun) { Write-DryRunLine $step ("already enabled on '" + $server.IfName + "'); nothing to do") }
        return New-RepairResult -Ok $true -Skipped $true -DryRun ([bool]$DryRun) -Commands $cmds `
            -Extra @{ InterfaceName = $server.IfName; NetworkName = $server.NetworkName; DhcpEnabled = $true }
    }

    if ($DryRun) {
        Write-DryRunLine $step "would run: $($cmds[0])"
        return New-RepairResult -Ok $true -DryRun $true -Commands $cmds `
            -Extra @{ InterfaceName = $server.IfName; NetworkName = $server.NetworkName; DhcpEnabled = $false }
    }
    if (-not (Test-RepairRights $false)) {
        return New-RepairResult -Ok $false -Commands $cmds -Reason "not elevated; changing the DHCP server needs administrator rights"
    }

    $run = Invoke-Native -Exe $vbm -Arguments @("dhcpserver", "modify", ("--interface=" + $server.IfName), "--enable")
    if (-not $run.Ok -or $run.ExitCode -ne 0) {
        return New-RepairResult -Ok $false -Commands $cmds -Extra @{ ExitCode = $run.ExitCode } `
            -Reason ("dhcpserver modify --enable failed (exit " + $run.ExitCode + "): " + ($run.Output -join " "))
    }
    return New-RepairResult -Ok $true -Changed $true -Commands $cmds `
        -Extra @{ InterfaceName = $server.IfName; NetworkName = $server.NetworkName; DhcpEnabled = $true }
}

# ===========================================================================
# performance counters
# ===========================================================================

# Damaged Windows performance counters make an eNSP device print '####' forever
# and never reach a prompt, which is the same symptom the host-only chain above
# produces from a completely different layer -- so it has to be repairable from
# here, and no amount of driver or adapter work will fix a damaged counter store.
#
# `lodctr /R` rebuilds the counter registration from the backup copies Windows
# keeps alongside the library files, and it fails without administrator rights.
# That is why elevation is checked rather than assumed.
#
# "Already satisfied" is read by RUNNING a counter (checks.ps1's
# Test-PerfCountersFunctional), never by looking for the Perflib registry key:
# that key is absent on current Windows on a perfectly healthy machine, so
# reading it would call every machine damaged. A healthy reading skips the step
# instead of rebuilding anyway -- rebuilding is not free, it rewrites the whole
# counter store, and there is nothing to gain from doing it to working counters.
#
# A note on what a result means. lodctr /R is known to return exit code 0 while
# having accomplished nothing, so the exit code alone is not treated as proof:
# the output is captured and returned, and the counters are probed AGAIN after
# the run. Only a functional reading afterwards is reported as a success; a
# still-broken reading after a 0 exit is reported as a failure with the command's
# own output attached, because that is what it is -- the desired state was not
# reached, and a caller told otherwise would stop looking.
function Repair-RebuildPerfCounters {
    param([string]$LodctrExe = "", [switch]$DryRun)

    $step = "perf counters"
    if (-not (Test-ChecksAvailable)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "checks.ps1 is not loaded, so the current counter state cannot be read"
    }

    $lodctr = $LodctrExe
    if (-not $lodctr) { $lodctr = Join-Path $env:SystemRoot "System32\lodctr.exe" }
    if (-not (Test-Path $lodctr)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason ("lodctr.exe not found: " + $lodctr)
    }

    $cmds = @(Format-CommandLine -Exe $lodctr -Arguments @("/R"))

    $before = Test-PerfCountersFunctional
    if ($before.Functional) {
        if ($DryRun) { Write-DryRunLine $step ("counters are functional (" + $before.Reason + "); nothing to do") }
        return New-RepairResult -Ok $true -Skipped $true -DryRun ([bool]$DryRun) -Commands $cmds `
            -Extra @{ State = "counters functional"; FunctionalBefore = $true }
    }

    if ($DryRun) {
        Write-DryRunLine $step "would run: $($cmds[0])"
        return New-RepairResult -Ok $true -DryRun $true -Commands $cmds `
            -Extra @{ State = ("counters not functional: " + $before.Reason); FunctionalBefore = $false }
    }
    if (-not (Test-RepairRights $false)) {
        return New-RepairResult -Ok $false -Commands $cmds `
            -Reason "not elevated; lodctr /R needs administrator rights to rewrite the counter store"
    }

    $run = Invoke-Native -Exe $lodctr -Arguments @("/R")
    if (-not $run.Ok -or $run.ExitCode -ne 0) {
        return New-RepairResult -Ok $false -Commands $cmds `
            -Extra @{ ExitCode = $run.ExitCode; Output = @($run.Output) } `
            -Reason ("lodctr /R failed (exit " + $run.ExitCode + "): " + ($run.Output -join " "))
    }

    $after = Test-PerfCountersFunctional
    if (-not $after.Functional) {
        return New-RepairResult -Ok $false -Changed $true -Commands $cmds `
            -Extra @{ ExitCode = $run.ExitCode; Output = @($run.Output); FunctionalAfter = $false } `
            -Reason ("lodctr /R exited 0 but the counters are still not functional (" + $after.Reason + "); output: " + ($run.Output -join " "))
    }

    return New-RepairResult -Ok $true -Changed $true -Commands $cmds `
        -Extra @{ ExitCode = $run.ExitCode; Output = @($run.Output); FunctionalAfter = $true }
}

# ===========================================================================
# firewall allow rule
# ===========================================================================

# Huawei's own FAQ lists the firewall not allowing eNSP as a cause of the same
# '####'-forever symptom, so it is repaired from here for the same reason as the
# counters: same symptom, different layer.
#
# The rule names the REAL executable, resolved through Find-EnspDir rather than
# hard-coded. A rule pointing at a path that does not exist never matches
# anything and still reads as "done" in every listing, which is worse than having
# no rule at all -- so a missing executable is a precondition failure, not
# something to work around by creating the rule anyway.
#
# "Already satisfied" is read through the diagnostic's own pair
# (Get-FirewallRuleTextForEnsp + Parse-FirewallRulesForEnsp), so the repair and
# the report that recommended it agree on what "the rule is there" means. The
# profile the existing rule covers is returned as a fact and is deliberately NOT
# part of the verdict: a Public-only rule is enabled, allows, and still does not
# apply on a domain-joined machine, but widening a rule is a different action
# from creating one, and it is not taken here behind an "already satisfied"
# verdict. A caller that sees CoversAllProfiles=$false can say so.
#
# A rule that carries the same name but is DISABLED or set to BLOCK is a third
# case, and it is reported rather than repaired: the fix for it is to correct
# that rule, and creating a second rule beside it would leave two rules whose
# display names collide, with no way for a later diagnostic to tell which one it
# read. A wrong duplicate is worse than none.
function Repair-AllowEnspFirewall {
    param([string]$EnspDir = "", [switch]$DryRun)

    $step = "firewall allow"
    if (-not (Test-ChecksAvailable)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "checks.ps1 is not loaded, so the current firewall state cannot be read"
    }
    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "New-NetFirewallRule is unavailable; the NetSecurity module is missing"
    }

    $dir = Find-EnspDir -Override $EnspDir
    if (-not $dir) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "eNSP install directory not found; pass -EnspDir"
    }
    $exe = Join-Path $dir "vboxserver\eNSP_VBoxServer.exe"
    if (-not (Test-Path $exe)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason ("eNSP_VBoxServer.exe not found: " + $exe)
    }

    # Created on all three profiles. Huawei's FAQ asks for Domain and Public, and
    # narrowing to the profile that happens to be active would recreate exactly
    # the false green the diagnostic warns about the moment the machine changes
    # network. Nothing about an inbound allow rule for one local program argues
    # for a narrower scope. Protocol is left unspecified on purpose, so the rule
    # covers TCP and UDP in one entry instead of the TCP/UDP pair the interactive
    # Windows prompt leaves behind.
    $profiles = @("Domain", "Private", "Public")
    $cmds = @(Format-CommandLine -Exe "New-NetFirewallRule" -Arguments @(
        "-DisplayName", "eNSP_VBoxServer",
        "-Direction", "Inbound",
        "-Action", "Allow",
        "-Program", $exe,
        "-Profile", ($profiles -join ","),
        "-Enabled", "True"))

    $fwText = @(Get-FirewallRuleTextForEnsp)
    $fw = Parse-FirewallRulesForEnsp -Lines $fwText

    if ($fw.HasAllowRule) {
        # "Any" is the whole set; otherwise all three names have to appear. An
        # empty Profile means the text carried no Profile line at all, which is
        # "unknown" and not "covers everything".
        $coversAll = $false
        if ($fw.Profile -match "Any") {
            $coversAll = $true
        } elseif (($fw.Profile -match "Domain") -and ($fw.Profile -match "Private") -and ($fw.Profile -match "Public")) {
            $coversAll = $true
        }
        $found = @($fwText | Where-Object { $_ -match '^DisplayName\s*:\s*.*VBoxServer' }).Count

        if ($DryRun) {
            Write-DryRunLine $step ("an enabled allow rule already exists (covers: " + $fw.Profile + "); nothing to do")
        }
        return New-RepairResult -Ok $true -Skipped $true -DryRun ([bool]$DryRun) -Commands $cmds `
            -Extra @{
                State             = ("enabled allow rule present, covers " + $fw.Profile)
                RulesFound        = $found
                Profile           = $fw.Profile
                CoversAllProfiles = $coversAll
            }
    }

    # The blocks are separated by a blank line by the collector above, so each is
    # evaluated whole for the same reason its enabled+allow case is: testing the
    # fields over the whole blob would let an unrelated rule satisfy them.
    #
    # (?i) is load-bearing, not decoration. The static [regex] methods are
    # case-SENSITIVE, unlike the -match operator that the parser above uses, and
    # the display name on a real machine is lowercase ("ensp_vboxserver") -- the
    # same trap checks.ps1 documents for its own literal. Without it this scan
    # finds nothing and the step happily creates the duplicate rule it exists to
    # prevent.
    $blocks = [regex]::Split(($fwText -join "`n"), '(\r?\n){2,}')
    foreach ($b in $blocks) {
        $m = [regex]::Match($b, '(?im)^DisplayName\s*:\s*(.*VBoxServer.*)$')
        if (-not $m.Success) { continue }
        $name = $m.Groups[1].Value.Trim()
        $enabled = "True"
        $action = "Allow"
        $ruleProfile = ""
        if ($b -match '(?m)^Enabled\s*:\s*(\S+)') { $enabled = $Matches[1] }
        if ($b -match '(?m)^Action\s*:\s*(\S+)') { $action = $Matches[1] }
        if ($b -match '(?m)^Profile\s*:\s*(.+?)\s*$') { $ruleProfile = $Matches[1] }
        if (($enabled -ne "False") -and ($action -ne "Block")) { continue }

        # A rule that exists but is disabled or blocking. Correct THAT rule
        # rather than adding a second one next to it -- but correct it, do not
        # hand the caller a command and stop.
        #
        # This used to return Ok=$false with the remedy as text, on the reasoning
        # that a repair should not rewrite a rule it did not create. The
        # reasoning is sound and the outcome was not: the diagnostic lists
        # "firewall not allowing eNSP" whenever no enabled+allow rule exists,
        # which covers BOTH "no rule at all" (this function fixes it) and "rule
        # present but disabled" (it refused). So the menu offered an item that
        # could never succeed and answered every attempt with "[skip]", which
        # reads as the tool being broken rather than as a deliberate refusal.
        #
        # Enabling is also the LESS invasive of the two available actions: the
        # alternative here is creating a second rule with the same display name
        # and leaving the first one dead beside it. Action is forced to Allow
        # because a rule that reads "set to block" would otherwise be enabled
        # into exactly the wrong state; Profile is widened to all three for the
        # same reason the create path uses all three (see the comment there).
        $why = "disabled"
        if ($enabled -ne "False") { $why = "set to block" }
        $remedyCmds = @(Format-CommandLine -Exe "Set-NetFirewallRule" -Arguments @(
            "-DisplayName", $name,
            "-Enabled", "True",
            "-Action", "Allow",
            "-Profile", ($profiles -join ",")))

        if ($DryRun) {
            Write-DryRunLine $step ("would enable and normalise the existing rule '" + $name + "' (" + $why + ")")
            return New-RepairResult -Ok $true -DryRun $true -Commands $remedyCmds `
                -Extra @{ DisplayName = $name; Enabled = $enabled; Action = $action
                          Profile = $ruleProfile; Mode = "enable existing rule" }
        }
        if (-not (Test-RepairRights $false)) {
            return New-RepairResult -Ok $false -Commands $remedyCmds `
                -Reason "not elevated; changing a firewall rule needs administrator rights"
        }
        try {
            Set-NetFirewallRule -DisplayName $name -Enabled True -Action Allow `
                -Profile $profiles -ErrorAction Stop | Out-Null
        } catch {
            return New-RepairResult -Ok $false -Commands $remedyCmds -Extra @{ DisplayName = $name } `
                -Reason ("Set-NetFirewallRule failed: " + $_.Exception.Message)
        }
        return New-RepairResult -Ok $true -Changed $true -Commands $remedyCmds `
            -Extra @{ DisplayName = $name; Enabled = "True"; Action = "Allow"
                      Profile = ($profiles -join ","); Mode = "enable existing rule" }
    }

    if ($DryRun) {
        Write-DryRunLine $step ("would run: " + $cmds[0])
        return New-RepairResult -Ok $true -DryRun $true -Commands $cmds `
            -Extra @{
                State      = "no enabled allow rule for eNSP_VBoxServer.exe"
                Program    = $exe
                Profile    = ($profiles -join ",")
                RulesFound = 0
            }
    }
    if (-not (Test-RepairRights $false)) {
        return New-RepairResult -Ok $false -Commands $cmds `
            -Reason "not elevated; creating a firewall rule needs administrator rights"
    }

    try {
        New-NetFirewallRule -DisplayName "eNSP_VBoxServer" -Direction "Inbound" -Action "Allow" `
            -Program $exe -Profile $profiles -Enabled "True" -ErrorAction Stop | Out-Null
    } catch {
        return New-RepairResult -Ok $false -Commands $cmds -Extra @{ Program = $exe } `
            -Reason ("New-NetFirewallRule failed: " + $_.Exception.Message)
    }
    return New-RepairResult -Ok $true -Changed $true -Commands $cmds `
        -Extra @{ DisplayName = "eNSP_VBoxServer"; Program = $exe; Profile = ($profiles -join ",") }
}

# ===========================================================================
# base device VM registration and orphan processes
# ===========================================================================
#
# These two repair eNSP's own lifecycle state rather than a component: a base
# device VM that is missing from VirtualBox (or lost the snapshot eNSP clones
# from), and the VirtualBox processes eNSP leaves behind when it closes. Both
# end in the same '####'-forever device as the steps above, from a third layer,
# which is why they are here.
#
# Both are calls into scripts that already own the logic -- register_vms.ps1 and
# cleanup_orphans.ps1 -- and neither is dot-sourced. Both have top-level side
# effects and both call exit; loading one to "look at it" would run a repair
# while the caller is still planning one, and a stray exit would take the whole
# repair menu down. One implementation also keeps this library and the .bat
# files the user is told to run by hand in agreement, which is the only thing
# that makes either of them trustworthy.

# fix.ps1 is ASCII-only (see the header), but the summary lines those scripts
# print are Chinese and their counters are what the verdicts below are read
# from. Building the labels from code points keeps this file ASCII AND the match
# exact: a literal here would be decoded through the ANSI code page on a machine
# whose console code page is not the one the file was written in, and the
# comparison would silently stop matching. The argument is hex code units, space
# separated and most significant first, so "65B0 6CE8 518C" is U+65B0 U+6CE8
# U+518C.
function ConvertFrom-HexString {
    param([string]$Hex)
    $s = ""
    foreach ($t in @($Hex -split '\s+')) {
        if ($t) { $s = $s + [char][Convert]::ToInt32($t, 16) }
    }
    return $s
}

# The eNSP base device VMs (AR_Base and the four WLAN_*_Base) have to be
# registered with the VirtualBox that eNSP talks to, and each needs its
# <VM>_Link snapshot: eNSP clonevm's from that snapshot, and a base disk without
# one fails with "does not have any snapshots" -- the device then reports error
# 40 and never starts. register_vms.ps1 scans for both and fixes only what is
# missing, without touching a registration that is already correct.
#
# WHO RUNS THIS MATTERS, and elevated is the wrong instinct. The registration is
# written into the CURRENT account's %USERPROFILE%\.VirtualBox\VirtualBox.xml,
# so this has to run as the account that normally starts eNSP. Repairing from an
# administrator account writes into that account's own VirtualBox.xml, and eNSP
# -- still running as the user -- never sees the registration. The result is
# indistinguishable from "the repair did nothing", which is the most expensive
# way for this step to be wrong. register_vms.ps1 deliberately does not elevate
# either, for the same reason.
#
# The paths are passed through only when the caller supplied them: the child's
# own detection looks in the uninstall registry keys, which this function does
# not, and replacing that with a guess would be worse than letting it search.
function Repair-RegisterBaseVms {
    param([string]$VBoxDir = "", [string]$EnspDir = "", [switch]$DryRun)

    $step = "base VM registration"

    $child = ""
    if ($fixScriptDir) { $child = Join-Path $fixScriptDir "register_vms.ps1" }
    if ((-not $child) -or (-not (Test-Path -LiteralPath $child))) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "register_vms.ps1 is missing next to fix.ps1; the install bundle is incomplete"
    }

    # -Check is the child's own plan-only switch: it scans and reports the same
    # counters without registering anything, so a dry run still costs one call
    # and still changes nothing.
    $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $child)
    if ($DryRun) { $psArgs += "-Check" }
    if ($EnspDir) { $psArgs += @("-EnspDir", $EnspDir) }
    if ($VBoxDir) { $psArgs += @("-VBoxDir", $VBoxDir) }
    $cmds = @(Format-CommandLine -Exe "powershell" -Arguments $psArgs)

    $run = Invoke-Native -Exe "powershell" -Arguments $psArgs
    $text = (@($run.Output) -join "`n")
    $extra = @{ ExitCode = $run.ExitCode; Output = @($run.Output) }

    # A non-zero exit is a precondition failure, not a partial repair: the child
    # exits 1 only when it cannot locate eNSP or VBoxManage.exe, and the real run
    # would fail on the same missing thing. The last few lines are carried in the
    # reason because that is where the child says which one it could not find.
    if ((-not $run.Ok) -or ($run.ExitCode -ne 0)) {
        $tail = @($run.Output | Where-Object { "$_".Trim() } | Select-Object -Last 3)
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Commands $cmds -Extra $extra `
            -Reason ("register_vms.ps1 exited " + $run.ExitCode + ": " + ($tail -join " | "))
    }

    # The child prints one summary line of six counters. Each count is followed
    # by a comma, and the label is matched WITH that comma on purpose: the per-VM
    # progress lines mention registration too ("... re-registered -> ..."), and
    # without the delimiter one of those could be read as the summary. A -Check
    # run labels the first counter differently from a real run, so both spellings
    # are listed -- it is the same counter either way.
    $lblNew   = ConvertFrom-HexString "65B0 6CE8 518C"       # registered (real run)
    $lblPend  = ConvertFrom-HexString "5F85 6CE8 518C"       # to register (-Check run)
    $lblRereg = ConvertFrom-HexString "91CD 6CE8 518C"       # re-registered
    $lblSnap  = ConvertFrom-HexString "8865 5EFA 5FEB 7167"  # link snapshots created

    $mReg   = [regex]::Match($text, ("(?:" + $lblNew + "|" + $lblPend + ")\s*([0-9]+)\s*,"))
    $mRereg = [regex]::Match($text, ($lblRereg + "\s*([0-9]+)\s*,"))
    $mSnap  = [regex]::Match($text, ($lblSnap + "\s*([0-9]+)\s*,"))
    $readable = ($mReg.Success -and $mRereg.Success -and $mSnap.Success)
    $extra["CountsRead"] = $readable
    if ($readable) {
        $extra["Registered"]   = [int]$mReg.Groups[1].Value
        $extra["Reregistered"] = [int]$mRereg.Groups[1].Value
        $extra["Snapshots"]    = [int]$mSnap.Groups[1].Value
    }

    # "Nothing to do" is read from the child's counters, never guessed. All three
    # zero is the only state reported as Skipped; an unreadable summary is
    # reported as a change instead, because "nothing was needed" is a claim the
    # output did not make, and a caller that believed it would stop looking at a
    # machine where a registration really was written. Unreadable is reachable --
    # the labels are Chinese and a console code page that cannot represent them
    # delivers '?' -- so the direction is chosen deliberately: over-reporting a
    # change only changes a sentence, while under-reporting one hides the repair.
    if ($readable -and ($extra["Registered"] -eq 0) -and ($extra["Reregistered"] -eq 0) -and ($extra["Snapshots"] -eq 0)) {
        if ($DryRun) { Write-DryRunLine $step "already registered, with the link snapshots in place; nothing to do" }
        return New-RepairResult -Ok $true -Skipped $true -DryRun ([bool]$DryRun) -Commands $cmds -Extra $extra
    }

    # A dry run still returns Changed = false. The counters say what the real run
    # WOULD do; this one ran -Check, so nothing was modified, and Changed means a
    # modification actually happened.
    if ($DryRun) {
        Write-DryRunLine $step ("would run: " + $cmds[0])
        return New-RepairResult -Ok $true -DryRun $true -Commands $cmds -Extra $extra
    }
    return New-RepairResult -Ok $true -Changed $true -Commands $cmds -Extra $extra
}

# Closing eNSP leaves VirtualBox background processes behind. The Linux guests
# (the CE / CX / NE devices) finish a hard power-off slowly, and one of them can
# crash on the way out behind a dialog nobody clicks -- each one holds 0.4-1.5 GB
# for as long as it is left alone.
#
# cleanup_orphans.ps1 owns the identification and the kill. Its safety boundary
# is what makes it callable from a repair menu: it acts only on VMs whose
# configuration file lives under the eNSP install directory or under
# %LOCALAPPDATA%\eNSP. A user's own VMs are skipped whether or not eNSP is
# running, and a VM whose owner cannot be determined is skipped too -- the script
# errs toward leaving a process alone, which is the only acceptable direction for
# a step that ends in Stop-Process.
#
# -Force is passed because there is no console here to answer the script's
# confirmation prompt: without it the child would sit waiting on a Read-Host that
# a non-interactive parent can never satisfy.
function Repair-KillOrphans {
    param([switch]$DryRun)

    $step = "orphan VBox processes"

    $child = ""
    if ($fixScriptDir) { $child = Join-Path $fixScriptDir "cleanup_orphans.ps1" }
    if ((-not $child) -or (-not (Test-Path -LiteralPath $child))) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "cleanup_orphans.ps1 is missing next to fix.ps1; the install bundle is incomplete"
    }

    $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $child, "-Force")
    $cmds = @(Format-CommandLine -Exe "powershell" -Arguments $psArgs)

    # Deliberately NOT invoked on a dry run. cleanup_orphans.ps1 has no plan-only
    # switch -- every route through it ends in Stop-Process -- so calling it here
    # would make the "plan" the very thing a plan exists to prevent. The command
    # line is returned instead and the caller decides what to do with it.
    if ($DryRun) {
        Write-DryRunLine $step ("would run: " + $cmds[0])
        return New-RepairResult -Ok $true -DryRun $true -Commands $cmds
    }

    $run = Invoke-Native -Exe "powershell" -Arguments $psArgs
    $text = (@($run.Output) -join "`n")
    $extra = @{ ExitCode = $run.ExitCode; Output = @($run.Output) }

    if ((-not $run.Ok) -or ($run.ExitCode -ne 0)) {
        $tail = @($run.Output | Where-Object { "$_".Trim() } | Select-Object -Last 3)
        return New-RepairResult -Ok $false -Commands $cmds -Extra $extra `
            -Reason ("cleanup_orphans.ps1 exited " + $run.ExitCode + ": " + ($tail -join " | "))
    }

    # Exit 0 covers both "stopped N" and "there was nothing to stop", so the two
    # are told apart by the final summary -- the only line the child prints that
    # carries a "<stopped> / <total>" pair. That pair is matched as the ASCII
    # skeleton rather than through the Chinese label in front of it, because the
    # digits and the slash survive every console code page while the label does
    # not. When no such line is present at all the child took one of its early
    # exits ("no VBoxHeadless process", "nothing left to clean"), which says the
    # same thing.
    $m = [regex]::Match($text, '([0-9]+)\s*/\s*([0-9]+)')
    $killed = $null
    if ($m.Success) { $killed = [int]$m.Groups[1].Value }
    if ($null -ne $killed) { $extra["Killed"] = $killed }

    if (($null -eq $killed) -or ($killed -eq 0)) {
        return New-RepairResult -Ok $true -Skipped $true -Commands $cmds -Extra $extra
    }
    return New-RepairResult -Ok $true -Changed $true -Commands $cmds -Extra $extra
}

# ===========================================================================
# device template VRAM
# ===========================================================================

# A template whose Display VRAMSize has been lowered boots its guest with too
# little video memory: the device prints '####' forever and never reaches a
# prompt. checks.ps1's Test-VramTooSmall reports it; this puts the value back.
#
# Two traps, both already documented by the reader this shares with the
# diagnostic, and both of them the writer's problem:
#
#   1. A .vbox repeats the ENTIRE <Hardware> section inside every <Snapshot>,
#      and the snapshot blocks come FIRST. A plain "replace the first VRAMSize"
#      therefore edits the SNAPSHOT and leaves the live configuration -- the one
#      VirtualBox actually boots from -- untouched. The edit is confined to the
#      block Get-LiveHardwareBlock returns for exactly that reason: a snapshot is
#      a saved state, and rewriting it would corrupt what eNSP clones from.
#   2. Get-LiveHardwareBlock returns the block's LINES, not its offsets, so the
#      block is located by scanning BACKWARDS for a run of lines equal to it.
#      Backwards because the live <Hardware> is the last one in the file, and by
#      full equality because the closing </Hardware> tag alone also matches every
#      snapshot's block. No match means no edit: the file is left alone.
#
# The value is written back as UTF-8 without a BOM, which is the form VirtualBox
# itself writes, and the read is pinned to UTF-8 for the same reason -- so that a
# template carrying non-ASCII text (a description, a path) round-trips instead of
# being decoded through the ANSI code page on the way in and re-encoded on the
# way out.
function Repair-SetTemplateVram {
    param([string]$TemplatePath = "", [int]$VramSize = 16, [switch]$DryRun)

    $step = "template VRAM"

    if (-not $TemplatePath) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason "no template given; pass -TemplatePath"
    }
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason ("template not found: " + $TemplatePath)
    }
    if (-not (Test-ChecksAvailable)) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason "checks.ps1 is not loaded, so the current value cannot be read"
    }

    # Resolved to an absolute path ONCE, because the write below goes through
    # [System.IO.File], which resolves a relative path against the PROCESS
    # directory -- and Set-Location does not move that. Without this, a relative
    # -TemplatePath would be read from one place and written to another.
    try {
        $path = (Resolve-Path -LiteralPath $TemplatePath -ErrorAction Stop).Path
    } catch {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason ("cannot resolve the template path: " + $_.Exception.Message)
    }

    $lines = @()
    try {
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop)
    } catch {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason ("cannot read the template: " + $_.Exception.Message)
    }
    if ($lines.Count -eq 0) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Reason ("the template is empty: " + $path)
    }

    $current = Get-VramSizeFromTemplate -Lines $lines
    if ($null -eq $current) {
        # A value that could not be read is not one to overwrite. The parser
        # returns $null for a template with no VRAMSize element at all, and
        # inserting one where the schema does not currently have it is a
        # different repair from raising a number that is already there.
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) `
            -Reason ("cannot read the live Display VRAMSize from " + $path + "; leaving the file untouched")
    }

    # There is no command line for "change one attribute in this file", so the
    # entry describes the edit precisely enough to be made by hand: the file, the
    # block it belongs to, and both values. Naming the block is not decoration --
    # without it the instruction reads as the snapshot's copy, which comes first.
    $cmds = @("edit " + $path + " : live <Hardware> Display VRAMSize " + $current + " -> " + $VramSize + " (leave every <Snapshot> copy alone)")
    $extra = @{ Path = $path; From = $current; To = $VramSize }
    $backup = $path + ".vrambak"
    $extra["Backup"] = $backup
    $extra["BackupCreated"] = $false

    if ($current -ge $VramSize) {
        # No command is returned for a step that has nothing to do: a caller
        # collects Commands into the plan it shows the user, and listing an edit
        # that will not happen reads as work still to be done.
        if ($DryRun) { Write-DryRunLine $step ("Display VRAMSize is already " + $current + "; nothing to do") }
        return New-RepairResult -Ok $true -Skipped $true -DryRun ([bool]$DryRun) -Extra $extra
    }

    $live = @(Get-LiveHardwareBlock -Lines $lines)
    $last = $live.Count - 1
    $start = -1
    if ($last -ge 0) {
        for ($i = $lines.Count - 1; $i -ge $last; $i--) {
            if ("$($lines[$i])" -cne "$($live[$last])") { continue }
            $s = $i - $last
            if ($s -lt 0) { continue }
            $same = $true
            for ($k = 0; $k -le $last; $k++) {
                if ("$($lines[$s + $k])" -cne "$($live[$k])") { $same = $false; break }
            }
            if ($same) { $start = $s; break }
        }
    }
    if ($start -lt 0) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Commands $cmds -Extra $extra `
            -Reason ("the live <Hardware> block could not be located in " + $path + "; leaving it untouched")
    }

    # Only the FIRST VRAMSize in the block is rewritten, mirroring the reader:
    # Get-VramSizeFromTemplate returns the first one it finds, so writing any
    # other would leave the number the diagnostic reports exactly as it was.
    $old = 'VRAMSize="' + $current + '"'
    $new = 'VRAMSize="' + $VramSize + '"'
    $updated = @()
    $done = $false
    foreach ($l in $live) {
        if ((-not $done) -and ("$l".Contains($old))) {
            $updated += "$l".Replace($old, $new)
            $done = $true
        } else {
            $updated += $l
        }
    }
    if (-not $done) {
        return New-RepairResult -Ok $false -DryRun ([bool]$DryRun) -Commands $cmds -Extra $extra `
            -Reason ("the live block does not spell " + $old + "; leaving the file untouched")
    }

    if ($DryRun) {
        Write-DryRunLine $step ("would set Display VRAMSize " + $current + " -> " + $VramSize + " in " + $path)
        return New-RepairResult -Ok $true -DryRun $true -Commands $cmds -Extra $extra
    }

    # The backup is taken before the first change and never overwritten. A second
    # run reads a value that is no longer the original, so re-copying would
    # replace the one file that still holds it with a copy of the repair -- which
    # is the only way back once the live value has been raised.
    if (-not (Test-Path -LiteralPath $backup)) {
        try {
            Copy-Item -LiteralPath $path -Destination $backup -ErrorAction Stop
            $extra["BackupCreated"] = $true
        } catch {
            return New-RepairResult -Ok $false -Commands $cmds -Extra $extra `
                -Reason ("cannot write the backup " + $backup + ": " + $_.Exception.Message)
        }
    }

    $out = @()
    if ($start -gt 0) { $out += @($lines[0..($start - 1)]) }
    $out += $updated
    if (($start + $last + 1) -le ($lines.Count - 1)) { $out += @($lines[($start + $last + 1)..($lines.Count - 1)]) }

    try {
        [System.IO.File]::WriteAllLines($path, $out, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        return New-RepairResult -Ok $false -Commands $cmds -Extra $extra `
            -Reason ("cannot write the template: " + $_.Exception.Message + " (the original is at " + $backup + ")")
    }

    return New-RepairResult -Ok $true -Changed $true -Commands $cmds -Extra $extra
}
