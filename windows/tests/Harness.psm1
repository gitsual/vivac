# A test harness small enough to read in one sitting. Windows ships Pester
# 3.4, ten years old and with a syntax nothing current documents, so the
# gates use this instead: a case is a name and a script block, an assertion
# throws, and the case file exits non-zero if any case failed.

Set-StrictMode -Version 2.0
$script:Failed = 0
$script:Passed = 0
$script:Repo = Split-Path -Parent $PSScriptRoot

function Get-RepoRoot { $script:Repo }

function Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:Passed++
        Write-Host "  PASS  $Name"
    } catch {
        $script:Failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Complete-Cases {
    if ($script:Failed) { exit 1 }
    exit 0
}

function Assert-True($Condition, [string]$Message = 'expected true') {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Expected, $Actual, [string]$Message = '') {
    if ($Expected -is [array] -or $Actual -is [array]) {
        $e = @($Expected) -join "`n"; $a = @($Actual) -join "`n"
        if ($e -cne $a) { throw "$Message`n--- expected`n$e`n--- actual`n$a" }
        return
    }
    if ([string]$Expected -cne [string]$Actual) { throw "$Message expected '$Expected', got '$Actual'" }
}

function Assert-Throws([scriptblock]$Body, [string]$Pattern = '') {
    $threw = $false
    try { & $Body } catch {
        $threw = $true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) {
            throw "threw '$($_.Exception.Message)', which does not match '$Pattern'"
        }
    }
    if (-not $threw) { throw "expected an error matching '$Pattern'" }
}

# A scratch profile: the three roots every vivac path derives from, pointed
# at an empty directory, so a test can deploy for real and touch nothing of
# the user's.
function New-TempProfile {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('vivac-test-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    foreach ($d in 'profile', 'roaming', 'local') { New-Item -ItemType Directory -Force -Path (Join-Path $dir $d) | Out-Null }
    $env:VIVAC_PROFILE = Join-Path $dir 'profile'
    $env:VIVAC_APPDATA = Join-Path $dir 'roaming'
    $env:VIVAC_LOCALAPPDATA = Join-Path $dir 'local'
    $dir
}

function Remove-TempProfile([string]$Dir) {
    Remove-Item Env:VIVAC_PROFILE, Env:VIVAC_APPDATA, Env:VIVAC_LOCALAPPDATA -ErrorAction SilentlyContinue
    if ($Dir -and (Test-Path -LiteralPath $Dir)) { Remove-Item -LiteralPath $Dir -Recurse -Force }
}

# Every file a gate should look at: the checkout minus what is generated or
# fetched (dist/, .git/).
function Get-RepoFiles([string[]]$Include = @('*')) {
    # -Include is silently ignored together with -LiteralPath, so the patterns
    # are applied here instead.
    Get-ChildItem -LiteralPath $script:Repo -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\(\.git|dist)\\' } |
        Where-Object { $n = $_.Name; @($Include | Where-Object { $n -like $_ }).Count -gt 0 }
}

Export-ModuleMember -Function *
