<#
.SYNOPSIS
  A read-only security audit of this Windows installation.

.DESCRIPTION
  The Windows counterpart of the source's workstation-security-audit (ClamAV,
  UFW, rkhunter, Lynis): which antivirus is active and current, whether the
  firewall denies unsolicited inbound traffic on every profile, what has been
  excluded from scanning, and every place a program can make itself start
  with Windows. Nothing is changed; each finding says what to look at.

  Run it elevated to also see the Defender exclusions and the full threat
  history; without elevation those sections say they were skipped.

.PARAMETER Quiet
  Print findings only, not the sections that came back clean.
#>
[CmdletBinding()]
param([switch]$Quiet)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force
[void](Import-VivacStrings (Read-VivacSettings)['language'])

$findings = New-Object System.Collections.Generic.List[string]
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Section([string]$Key) { if (-not $Quiet) { Write-Host ''; Write-Host "== $(T $Key) ==" } }
function Ok([string]$Text) { if (-not $Quiet) { Write-Host "  ok    $Text" } }
function Finding([string]$Text) { $findings.Add($Text); Write-Host "  !!    $Text" -ForegroundColor Yellow }
function Info([string]$Text) { if (-not $Quiet) { Write-Host "        $Text" } }

# ---------------------------------------------------------------- antivirus
Section 'audit.antivirus'
$products = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction SilentlyContinue)
if (-not $products.Count) { Finding (T 'audit.no_antivirus') }
foreach ($av in $products) {
    # productState packs three bytes: owner, scanner state (0x10 = on) and
    # signature state (0x00 = up to date).
    $state = [int]$av.productState
    $on = (($state -shr 8) -band 0xFF) -band 0x10
    $current = (($state -band 0xFF) -eq 0)
    if (-not $on) { Info (T 'audit.av_off' @($av.displayName)) }
    elseif (-not $current) { Finding (T 'audit.av_stale' @($av.displayName)) }
    else { Ok (T 'audit.av_ok' @($av.displayName)) }
}
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($mp -and $mp.AntivirusEnabled) {
    if (-not $mp.RealTimeProtectionEnabled) { Finding (T 'audit.realtime_off') } else { Ok (T 'audit.realtime_on') }
    $age = [int]((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays
    if ($age -gt 3) { Finding (T 'audit.signatures_old' @($age)) } else { Ok (T 'audit.signatures_age' @($age)) }
    if (-not $mp.IsTamperProtected) { Finding (T 'audit.tamper_off') } else { Ok (T 'audit.tamper_on') }
    $threats = @(Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { $_.IsActive })
    if ($threats.Count) { foreach ($t in $threats) { Finding (T 'audit.active_threat' @($t.ThreatName)) } }
    else { Ok (T 'audit.no_active_threats') }
}

# ------------------------------------------------------------- exclusions
Section 'audit.exclusions'
if (-not $admin) {
    Info (T 'audit.needs_admin')
} else {
    $pref = Get-MpPreference
    $any = $false
    foreach ($kind in 'ExclusionPath', 'ExclusionProcess', 'ExclusionExtension') {
        foreach ($x in @($pref.$kind)) {
            if ($x) { $any = $true; Finding (T 'audit.exclusion' @($kind, $x)) }
        }
    }
    if (-not $any) { Ok (T 'audit.no_exclusions') }
}

# ----------------------------------------------------------------- firewall
Section 'audit.firewall'
foreach ($fp in @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
    if (-not $fp.Enabled) { Finding (T 'audit.firewall_off' @($fp.Name)) }
    elseif ([string]$fp.DefaultInboundAction -eq 'Allow') { Finding (T 'audit.firewall_inbound_allow' @($fp.Name)) }
    else { Ok (T 'audit.firewall_ok' @($fp.Name)) }
}
$listening = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalAddress -notmatch '^(127\.|::1)' -and $_.LocalPort -lt 49152 } |
    Sort-Object LocalPort -Unique)
foreach ($l in $listening) {
    $name = (Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    Info (T 'audit.listening' @($l.LocalPort, $name))
}

# ------------------------------------------------------------- persistence
# Everything that can start a program with Windows. Signed Microsoft entries
# are summarised; the rest are listed so a stranger stands out.
Section 'audit.autostart'
$runKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
foreach ($k in $runKeys) {
    $item = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
    if (-not $item) { continue }
    foreach ($prop in $item.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
        Info "$($prop.Name) = $($prop.Value)"
    }
}
foreach ($dir in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp") {
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) { Info (T 'audit.startup_file' @($f.FullName)) }
}
$winlogon = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
if ($winlogon -and $winlogon.Shell -ne 'explorer.exe') { Finding (T 'audit.winlogon_shell' @($winlogon.Shell)) }
if ($winlogon -and $winlogon.Userinit -notmatch '^C:\\Windows\\system32\\userinit\.exe,?$') { Finding (T 'audit.winlogon_userinit' @($winlogon.Userinit)) }
foreach ($ifeo in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' -ErrorAction SilentlyContinue)) {
    $dbg = (Get-ItemProperty -LiteralPath $ifeo.PSPath -ErrorAction SilentlyContinue).PSObject.Properties['Debugger']
    if ($dbg -and $dbg.Value) { Finding (T 'audit.ifeo' @($ifeo.PSChildName, $dbg.Value)) }
}
$consumers = @(Get-CimInstance -Namespace root\subscription -ClassName CommandLineEventConsumer -ErrorAction SilentlyContinue)
foreach ($c in $consumers) { Finding (T 'audit.wmi_consumer' @($c.Name, $c.CommandLineTemplate)) }

Section 'audit.tasks'
foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' })) {
    $actions = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' && '
    if ($actions -match '(?i)powershell.*(-enc|-encodedcommand|frombase64|iex|invoke-expression|downloadstring)|\\AppData\\Local\\Temp\\|\\Users\\Public\\') {
        Finding (T 'audit.task_suspicious' @("$($t.TaskPath)$($t.TaskName)", $actions))
    } else {
        Info "$($t.TaskPath)$($t.TaskName): $actions"
    }
}

Section 'audit.services'
foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName })) {
    $exe = ($s.PathName -replace '^"([^"]+)".*$', '$1') -replace '^(\S+\.exe).*$', '$1'
    if ($exe -match '(?i)\\(AppData|Temp|Users\\Public)\\') { Finding (T 'audit.service_userdir' @($s.Name, $exe)); continue }
    if (-not (Test-Path -LiteralPath $exe)) { continue }
    $sig = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction SilentlyContinue
    if ($sig -and $sig.Status -ne 'Valid') { Finding (T 'audit.service_unsigned' @($s.Name, $exe)) }
}

# -------------------------------------------------------------------- updates
Section 'audit.updates'
$last = Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
if ($last) {
    $days = [int]((Get-Date) - $last.InstalledOn).TotalDays
    if ($days -gt 45) { Finding (T 'audit.updates_old' @($days)) } else { Ok (T 'audit.updates_age' @($days, $last.HotFixID)) }
}
$uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
if ($uac -ne 1) { Finding (T 'audit.uac_off') } else { Ok (T 'audit.uac_on') }

Write-Host ''
if ($findings.Count) { Write-Host (T 'audit.summary_findings' @($findings.Count)) -ForegroundColor Yellow }
else { Write-Host (T 'audit.summary_clean') }
exit ([int]($findings.Count -gt 0))
