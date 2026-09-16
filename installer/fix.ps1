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
