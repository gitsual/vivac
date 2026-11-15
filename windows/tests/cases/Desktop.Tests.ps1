# The snapshot of what Windows drew before vivac (lib/Desktop.psm1), in a
# scratch profile: it is taken once, a value vivac starts to manage later
# joins it flat (Windows PowerShell hands a JSON array over as one object,
# which once nested the file), and a second pass leaves it alone. Only the
# registry is read here; nothing on the desktop is changed.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Desktop.psm1') -Force

$dir = New-TempProfile
try {
    $path = Join-Path (Get-VivacPaths).State 'windows-original.json'
    $managed = @(& (Get-Module Desktop) { $script:RegistryValues } | ForEach-Object { $_.Key + '|' + $_.Name })
    function Read-Snapshot { @(Get-Content -Raw -LiteralPath $path | ConvertFrom-Json | ForEach-Object { $_ }) }

    Case 'the first snapshot holds every managed value, flat' {
        & (Get-Module Desktop) { Save-VivacWindowsOriginal }
        $entries = Read-Snapshot
        Assert-Equal $managed.Count $entries.Count 'one entry per managed value'
        foreach ($e in $entries) { Assert-True ($null -ne $e.PSObject.Properties['Key']) 'every entry names its key' }
        Assert-Equal 0 @($entries | Where-Object { $_.PSObject.Properties['Count'] }).Count 'no entry is a nested array'
    }
    Case 'a value managed later joins an older snapshot, flat' {
        $older = @(Read-Snapshot | Select-Object -Skip 2)
        $dropped = @(Read-Snapshot | Select-Object -First 2 | ForEach-Object { $_.Key + '|' + $_.Name })
        [IO.File]::WriteAllText($path, (($older | ConvertTo-Json -Depth 4) + "`n"))
        & (Get-Module Desktop) { Save-VivacWindowsOriginal }
        $entries = Read-Snapshot
        Assert-Equal $managed.Count $entries.Count 'the missing values were added'
        foreach ($d in $dropped) { Assert-True (@($entries | Where-Object { ($_.Key + '|' + $_.Name) -eq $d }).Count -eq 1) "$d is back, once" }
        Assert-Equal 0 @($entries | Where-Object { $_.PSObject.Properties['Count'] }).Count 'no entry is a nested array'
    }
    Case 'a second pass changes nothing' {
        $before = [IO.File]::ReadAllText($path)
        & (Get-Module Desktop) { Save-VivacWindowsOriginal }
        Assert-Equal $before ([IO.File]::ReadAllText($path)) 'the snapshot is never rewritten once complete'
    }
    Case 'an opaque colour is a DWord, not a string' {
        $colour = @(Read-Snapshot | Where-Object { $_.Name -eq 'AccentColor' -and $_.Present })
        foreach ($c in $colour) { Assert-Equal 'DWord' $c.Kind 'AccentColor above 0x7FFFFFFF keeps its kind' }
    }
} finally {
    Remove-TempProfile $dir
}
Complete-Cases
