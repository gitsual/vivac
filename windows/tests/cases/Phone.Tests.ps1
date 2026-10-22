# The phone through KDE Connect (lib/Phone.psm1, bin/vivac-phone.ps1,
# docs/bridge.md at the product root, "The phone"): against a fake
# kdeconnect-cli (VIVAC_KDECONNECT_CLI), in a scratch profile, with nothing
# reaching the screen (VIVAC_PHONE_SINK). Without KDE Connect every part is
# silent: the bar gets null, the menu has no Phone category.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$utf8 = New-Object Text.UTF8Encoding $false

$dir = New-TempProfile
$fakes = Join-Path $dir 'fakes'
[void](New-Item -ItemType Directory -Force -Path $fakes)
$fake = Join-Path $fakes 'kdeconnect-cli.ps1'
# The fake: the reachable devices are the lines of FAKE_DEVICES ("id name");
# anything else it is asked is written to FAKE_CALLS, one line per call, and
# fails when FAKE_FAIL is set. FAKE_SLEEP makes it hang.
[IO.File]::WriteAllText($fake, @'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
if ($env:FAKE_SLEEP) { Start-Sleep -Seconds ([int]$env:FAKE_SLEEP) }
if (($args -join ' ') -eq '--list-available --id-name-only') {
    if (Test-Path -LiteralPath $env:FAKE_DEVICES) { [Console]::Out.Write([IO.File]::ReadAllText($env:FAKE_DEVICES)) }
    exit 0
}
Add-Content -LiteralPath $env:FAKE_CALLS -Value ($args -join ' ') -Encoding UTF8
if ($env:FAKE_FAIL) { exit 1 }
exit 0
'@, $utf8)
$env:FAKE_DEVICES = Join-Path $dir 'devices.txt'
$env:FAKE_CALLS = Join-Path $dir 'calls.txt'
$env:VIVAC_PHONE_SINK = Join-Path $dir 'sink.txt'
$phoneScript = Join-Path $root 'bin\vivac-phone.ps1'
# A name with what could break JSON, a tooltip or a command line, and accents.
$name = 'Test "phone" <&> ' + [char]0x00F1
[IO.File]::WriteAllText($env:FAKE_DEVICES, "a1b2c3d4e5f60718_29 $name`n../evil x`n", $utf8)

function Invoke-Phone([string[]]$PhoneArgs) {
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $phoneScript @PhoneArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out | ForEach-Object { "$_" }) -join "`n") }
}
function Reset-Calls { foreach ($f in $env:FAKE_CALLS, $env:VIVAC_PHONE_SINK) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
function Read-Lines([string]$Path) { if (Test-Path -LiteralPath $Path) { @([IO.File]::ReadAllLines($Path, $utf8)) } else { @() } }

try {
    Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
    Import-Module (Join-Path $root 'lib\Phone.psm1') -Force
    # What is said is checked in English, whatever this machine speaks.
    Set-VivacSetting language en

    Case 'an argument is quoted the way the C runtime reads it back' {
        Assert-Equal 'plain' (ConvertTo-VivacArgument 'plain')
        Assert-Equal '""' (ConvertTo-VivacArgument '')
        Assert-Equal '"a b"' (ConvertTo-VivacArgument 'a b')
        Assert-Equal '"say \"hi\""' (ConvertTo-VivacArgument 'say "hi"')
        Assert-Equal '"C:\a dir\\"' (ConvertTo-VivacArgument 'C:\a dir\')
    }

    # ---- without KDE Connect: nothing anywhere ---------------------------
    $env:VIVAC_KDECONNECT_CLI = Join-Path $dir 'no-such-cli.exe'
    Case 'without KDE Connect the bar gets null and the menu has no phone' {
        Assert-Equal $null (Get-VivacPhoneCli)
        $r = Invoke-Phone @('-Status')
        Assert-Equal 0 $r.Code $r.Text
        Assert-Equal 'null' $r.Text
        Assert-Equal 0 @(Get-VivacPhoneMenuEntries { param($g) $g }).Count 'menu entries without KDE Connect'
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        Assert-Equal 0 @(Get-VivacMenuEntries | Where-Object { $_.Group -eq 'phone' }).Count
        $cats = (Show-Menu -NoShow -Category phone).FindName('Cats')
        Assert-True (-not @($cats.ItemsSource | Where-Object { $_.Group -eq 'phone' }).Count) 'a Phone category without KDE Connect'
        Assert-Equal 'all' $cats.SelectedItem.Group 'an unknown category opens on everything'
        $r = Invoke-Phone @('-Ring', '-Device', 'a1b2c3d4e5f60718_29')
        Assert-True ($r.Code -ne 0) 'ringing without KDE Connect succeeded'
        Assert-True (@(Read-Lines $env:VIVAC_PHONE_SINK) -match 'not installed') 'not said that KDE Connect is missing'
    }

    # ---- with the fake ----------------------------------------------------
    $env:VIVAC_KDECONNECT_CLI = $fake
    Case 'the bar gets the reachable phones as JSON, and the menu its copy' {
        $r = Invoke-Phone @('-Status')
        Assert-Equal 0 $r.Code $r.Text
        $s = $r.Text | ConvertFrom-Json
        Assert-Equal 1 @($s.phones).Count "a device id with a path in it was kept: $($r.Text)"
        Assert-Equal 'a1b2c3d4e5f60718_29' $s.phones[0].id
        Assert-Equal $name $s.phones[0].name 'the name, UTF-8 and quotes intact'
        Assert-True (Test-Path -LiteralPath (Get-VivacPhoneStatePath)) 'phone.json was not written'
        Assert-Equal 1 @(Read-VivacPhoneState).Count
    }
    Case 'no phone in reach: an empty list, and only pairing in the menu' {
        [IO.File]::WriteAllText($env:FAKE_DEVICES, '', $utf8)
        $r = Invoke-Phone @('-Status')
        Assert-Equal 0 @(($r.Text | ConvertFrom-Json).phones).Count $r.Text
        $entries = @(Get-VivacPhoneMenuEntries { param($g, $n, $k, $t) [pscustomobject]@{ Target = $t } })
        Assert-Equal 'manage||' (@($entries | ForEach-Object { $_.Target }) -join ',')
        [IO.File]::WriteAllText($env:FAKE_DEVICES, "a1b2c3d4e5f60718_29 $name`n", $utf8)
        [void](Invoke-Phone @('-Status'))
    }
    Case 'a daemon that hangs is given up on, not waited for' {
        $env:FAKE_SLEEP = '20'
        try {
            $t = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-VivacPhoneCli @('--list-available', '--id-name-only') 2000
            Assert-Equal -1 $r.Code
            Assert-True ($t.Elapsed.TotalSeconds -lt 10) "waited $($t.Elapsed.TotalSeconds) s"
        } finally { Remove-Item Env:FAKE_SLEEP }
    }
    Case 'a stale copy is not offered' {
        $p = Get-VivacPhoneStatePath
        $saved = [IO.File]::ReadAllText($p, $utf8)
        try {
            $old = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
            [IO.File]::WriteAllText($p, ($saved -replace '"time":"[^"]+"', "`"time`":`"$old`""), $utf8)
            Assert-Equal 0 @(Read-VivacPhoneState).Count
        } finally { [IO.File]::WriteAllText($p, $saved, $utf8) }
    }
    Case 'the menu has a Phone category with what the phone can do' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $entries = @(Get-VivacMenuEntries | Where-Object { $_.Group -eq 'phone' })
        $targets = @($entries | ForEach-Object { $_.Target }) -join ','
        Assert-Equal "ring|a1b2c3d4e5f60718_29|$name,send-file|a1b2c3d4e5f60718_29|$name,send-clip|a1b2c3d4e5f60718_29|$name,manage||" $targets
        Assert-True (-not @($entries | Where-Object { $_.Confirm }).Count) 'a phone action asks for confirmation'
        $w = Show-Menu -NoShow -Category phone
        Assert-Equal 'phone' $w.FindName('Cats').SelectedItem.Group 'the menu did not open on the Phone category'
        $w.Close()
    }
    Case 'ring, the clipboard and a file go to the chosen phone, and are said' {
        Reset-Calls
        $r = Invoke-Phone @('-Ring', '-Device', 'a1b2c3d4e5f60718_29', '-Name', 'Test phone')
        Assert-Equal 0 $r.Code $r.Text
        Assert-Equal '--device a1b2c3d4e5f60718_29 --ring' (Read-Lines $env:FAKE_CALLS)
        Assert-Equal 'notify|Test phone is ringing' (Read-Lines $env:VIVAC_PHONE_SINK)
        Reset-Calls
        [void](Invoke-Phone @('-SendClipboard', '-Device', 'a1b2c3d4e5f60718_29'))
        Assert-Equal '--device a1b2c3d4e5f60718_29 --send-clipboard' (Read-Lines $env:FAKE_CALLS)
        Reset-Calls
        $file = Join-Path $dir 'a file.txt'
        [IO.File]::WriteAllText($file, 'x')
        $env:VIVAC_PHONE_FILE = $file
        try { [void](Invoke-Phone @('-SendFile', '-Device', 'a1b2c3d4e5f60718_29')) } finally { Remove-Item Env:VIVAC_PHONE_FILE }
        Assert-Equal "--device a1b2c3d4e5f60718_29 --share $file" (Read-Lines $env:FAKE_CALLS)
        Reset-Calls
        $env:VIVAC_PHONE_FILE = Join-Path $dir 'missing.txt'
        try { [void](Invoke-Phone @('-SendFile', '-Device', 'a1b2c3d4e5f60718_29')) } finally { Remove-Item Env:VIVAC_PHONE_FILE }
        Assert-Equal 0 @(Read-Lines $env:FAKE_CALLS).Count 'a file that is not there was sent'
    }
    Case 'a phone out of reach is said, and a bad device id refused' {
        Reset-Calls
        $env:FAKE_FAIL = '1'
        try { $r = Invoke-Phone @('-Ring', '-Device', 'a1b2c3d4e5f60718_29', '-Name', 'Test phone') } finally { Remove-Item Env:FAKE_FAIL }
        Assert-True ($r.Code -ne 0) 'a failed ring exited 0'
        Assert-Equal 'notify|KDE Connect could not reach Test phone' (Read-Lines $env:VIVAC_PHONE_SINK)
        Reset-Calls
        foreach ($bad in '', '../x', 'a b', '--ring') {
            $r = Invoke-Phone @('-Ring', '-Device', $bad)
            Assert-True ($r.Code -ne 0) "device '$bad' was accepted"
        }
        Assert-Equal 0 @(Read-Lines $env:FAKE_CALLS).Count 'a bad device id reached KDE Connect'
    }
    Case 'the bar may run -Status and nothing else of it; the menu verb is granted' {
        $pack = [IO.File]::ReadAllText((Join-Path $root 'static\zebar\vivac\zpack.json')) | ConvertFrom-Json
        $grants = @($pack.widgets | Where-Object { $_.name -eq 'bar' } | ForEach-Object { $_.privileges.shellCommands } | Where-Object { $_.program -eq 'powershell.exe' })
        $allowed = { param($a) @($grants | Where-Object { $a -match $_.argsRegex }).Count -gt 0 }
        $base = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\vivac\windows\bin\vivac-phone.ps1'
        Assert-True (& $allowed "$base -Status") '-Status is not granted'
        foreach ($a in "$base -Ring -Device x", "$base -SendFile -Device x", "$base -Status -Ring", "$base -Manage") {
            Assert-True (-not (& $allowed $a)) "granted: $a"
        }
        $cmd = @($pack.widgets[0].privileges.shellCommands | Where-Object { $_.program -eq 'cmd.exe' -and $_.argsRegex -match 'pipe' })[0].argsRegex
        Assert-True ('/c echo phone>\\.\pipe\vivac-x 2>nul || conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\v\bin\vivac.ps1 phone' -match $cmd) 'the phone verb is not granted'
    }
    Case 'KDE Connect is an optional package, never part of the base' {
        $phoneIds = @([IO.File]::ReadAllLines((Join-Path $root 'packages\phone.txt')) | Where-Object { $_ -notmatch '^\s*(#|$)' })
        Assert-Equal 'KDE.KDEConnect' ($phoneIds -join ',')
        Assert-True (-not ([IO.File]::ReadAllText((Join-Path $root 'packages\base.txt')) -match 'KDEConnect')) 'KDE Connect is in the base profile'
    }
} finally {
    Remove-Item Env:VIVAC_KDECONNECT_CLI, Env:FAKE_DEVICES, Env:FAKE_CALLS, Env:VIVAC_PHONE_SINK -ErrorAction SilentlyContinue
    Remove-TempProfile $dir
}
Complete-Cases
