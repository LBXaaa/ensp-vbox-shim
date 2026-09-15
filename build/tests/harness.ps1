# harness.ps1 -- minimal assertion harness, no external dependencies.
# Pester 3.4.0 ships with Windows but its syntax is dated and absent on the
# test VMs; a 40-line harness keeps the whole suite dependency-free.

$script:Failures = 0
$script:Checks = 0

function Assert-Equal($Actual, $Expected, $Label) {
    $script:Checks++
    if ("$Actual" -eq "$Expected") {
        Write-Host ("  PASS  " + $Label) -ForegroundColor Green
    } else {
        $script:Failures++
        Write-Host ("  FAIL  " + $Label) -ForegroundColor Red
        Write-Host ("        expected: " + $Expected) -ForegroundColor Red
        Write-Host ("        actual  : " + $Actual) -ForegroundColor Red
    }
}

function Assert-True($Condition, $Label) {
    Assert-Equal ([bool]$Condition) $true $Label
}

function Assert-False($Condition, $Label) {
    Assert-Equal ([bool]$Condition) $false $Label
}

function Assert-Match($Actual, $Pattern, $Label) {
    $script:Checks++
    if ("$Actual" -match $Pattern) {
        Write-Host ("  PASS  " + $Label) -ForegroundColor Green
    } else {
        $script:Failures++
        Write-Host ("  FAIL  " + $Label) -ForegroundColor Red
        Write-Host ("        pattern : " + $Pattern) -ForegroundColor Red
        Write-Host ("        actual  : " + $Actual) -ForegroundColor Red
    }
}

function Get-TestDataPath($Name) {
    Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "testdata\$Name"
}

function Complete-TestRun {
    Write-Host ""
    # Counters are read defensively. A test script run as `& tests.ps1` gets
    # its own script scope; in that scope $script:Failures stays $null when
    # every assertion passed, because nothing ever incremented it there.
    # "$null -eq 0" is False, so without this guard a green run would report
    # a false failure and exit 1.
    $failures = 0
    $checks = 0
    if ($null -ne $script:Failures) { $failures = [int]$script:Failures }
    if ($null -ne $script:Checks)   { $checks = [int]$script:Checks }
    if ($failures -eq 0) {
        Write-Host ("ALL PASS (" + $checks + " assertions)") -ForegroundColor Green
        exit 0
    }
    Write-Host ($failures.ToString() + " FAILED of " + $checks + " assertions") -ForegroundColor Red
    exit 1
}
