# The updates panel: winget's table is read by column position, whatever
# language its header is in, and the panel builds.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Updates.psm1') -Force

# As winget prints it to a pipe: CRLF line ends, a spinner before the header
# behind carriage returns, an accented header, the count and a note after.
$o = [string][char]0x00F3
$table = "   - `r   \ `rNombre            Id               Versi${o}n             Disponible               Origen`r`n" +
    ('-' * 86) + "`r`n" +
    "Git               Git.Git          2.53.0              2.55.0.5                 winget`r`n" +
    "Spotify           Spotify.Spotify  1.3.3.264.gdaf3b824 1.3.5.3058.g5d40d5480152 winget`r`n" +
    "2 actualizaciones disponibles.`r`n" +
    "1 paquetes tienen anclajes que impiden la actualizaci${o}n.`r`n"

Case 'winget upgrade is read by column, in any language' {
    $rows = @(ConvertFrom-VivacWingetTable $table)
    Assert-Equal 2 $rows.Count 'two packages, not the count or the note'
    Assert-Equal 'Git' $rows[0].Name
    Assert-Equal 'Git.Git' $rows[0].Id
    Assert-Equal '2.53.0' $rows[0].Version
    Assert-Equal '2.55.0.5' $rows[0].Available
    Assert-Equal 'winget' $rows[0].Source
    Assert-Equal '1.3.5.3058.g5d40d5480152' $rows[1].Available
}
Case 'nothing to update is no rows' {
    Assert-Equal 0 @(ConvertFrom-VivacWingetTable "No se encontr${o} ninguna actualizaci${o}n disponible.`r`n").Count
    Assert-Equal 0 @(ConvertFrom-VivacWingetTable '').Count
}
Case 'the updates panel builds, titled vivac' {
    $w = Show-Updates -NoShow
    Assert-True ($w -is [Windows.Window]) 'a window'
    Assert-True ($w.Title -match '^vivac') 'titled vivac, so GlazeWM leaves it alone'
    $w.Close()
}
Complete-Cases
