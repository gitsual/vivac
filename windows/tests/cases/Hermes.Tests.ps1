# Hermes across the dual boot (lib/Hermes.psm1, bin/vivac-hermes.ps1, docs/bridge.md
# at the product root): the home is the profile's .hermes unless HERMES_HOME
# says otherwise, the marker both sides write is key=value with LF and no BOM
# and keeps the other side's lines, Linux counts as sharing only while its
# line says so, status knows what Ollama still lacks, and a dry run of install
# or ollama names what it would do and does nothing.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Hermes.psm1') -Force
$tool = Join-Path $root 'bin\vivac-hermes.ps1'

$dir = New-TempProfile
$savedHome = $env:HERMES_HOME
Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue
try {
    Case 'the home is .hermes in the profile, HERMES_HOME when set' {
        $userLevel = [Environment]::GetEnvironmentVariable('HERMES_HOME', 'User')
        if (-not $userLevel) { Assert-Equal (Join-Path $env:VIVAC_PROFILE '.hermes') (Get-VivacHermesHome) }
        $env:HERMES_HOME = Join-Path $dir 'elsewhere'
        try { Assert-Equal (Join-Path $dir 'elsewhere') (Get-VivacHermesHome) } finally { Remove-Item Env:HERMES_HOME }
        Assert-Equal (Join-Path (Join-Path $env:VIVAC_LOCALAPPDATA 'hermes') 'hermes-agent') (Get-VivacHermesInstallDir) 'the code lives outside the home'
        Assert-Equal (Join-Path (Join-Path $env:VIVAC_LOCALAPPDATA 'hermes') 'runtime') (Get-VivacHermesRuntimeDir) 'so does the tool store'
    }
    Case 'the marker is key=value, LF, no BOM, and keeps the other side''s lines' {
        $hermesHome = Join-Path $dir 'home1'
        Write-VivacHermesMarker $hermesHome @{ windows_home = $hermesHome; windows_shared = '20261109-200000' }
        $path = Get-VivacHermesMarkerPath $hermesHome
        $bytes = [IO.File]::ReadAllBytes($path)
        Assert-True ($bytes[0] -ne 0xEF) 'no BOM'
        Assert-True (-not ([Text.Encoding]::UTF8.GetString($bytes).Contains("`r"))) 'LF only'
        # Linux writes its lines the same way; a rewrite from here keeps them.
        [IO.File]::AppendAllText($path, "linux_home=/home/someone/.hermes`nlinux_shared=20261109-201500`n")
        Write-VivacHermesMarker $hermesHome @{ windows_shared = '20261109-210000' }
        $m = Read-VivacHermesMarker $hermesHome
        Assert-Equal '20261109-210000' $m['windows_shared']
        Assert-Equal '/home/someone/.hermes' $m['linux_home']
        Assert-Equal 4 @([IO.File]::ReadAllLines($path) | Where-Object { $_ }).Count 'one line per key, both sides kept'
    }
    Case 'Linux shares only while its line says so' {
        $hermesHome = Join-Path $dir 'home2'
        Assert-True (-not (Test-VivacHermesLinuxShared $hermesHome)) 'no marker: not shared'
        Write-VivacHermesMarker $hermesHome @{ linux_shared = '20261109-201500' }
        Assert-True (Test-VivacHermesLinuxShared $hermesHome) 'a stamp: shared'
        Write-VivacHermesMarker $hermesHome @{ linux_shared = 'none' }
        Assert-True (-not (Test-VivacHermesLinuxShared $hermesHome)) 'none: it brought its home back'
    }
    Case 'status sees the home, the launcher and what Ollama lacks' {
        $hermesHome = Join-Path $dir 'home3'
        $s = Get-VivacHermesStatus $hermesHome
        Assert-True (-not $s.Exists) 'no home yet'
        New-Item -ItemType Directory -Force -Path (Join-Path $hermesHome 'bin') | Out-Null
        Set-Content -LiteralPath (Join-Path $hermesHome 'bin\hermes.exe') -Value 'not really'
        $s = Get-VivacHermesStatus $hermesHome
        Assert-True $s.Exists
        Assert-Equal (Join-Path $hermesHome 'bin\hermes.exe') $s.Launcher 'the staged launcher wins over the PATH'
        $wanted = Get-VivacHermesOllamaEnv
        Assert-Equal '65536' $wanted['OLLAMA_CONTEXT_LENGTH'] 'Hermes refuses below 64,000 tokens'
        Assert-Equal '1' $wanted['OLLAMA_FLASH_ATTENTION']
        Assert-Equal 'q8_0' $wanted['OLLAMA_KV_CACHE_TYPE']
        foreach ($k in $wanted.Keys) {
            if ([Environment]::GetEnvironmentVariable($k, 'User') -ne $wanted[$k]) { Assert-True $s.OllamaMissing.Contains($k) "$k is reported missing" }
            else { Assert-True (-not $s.OllamaMissing.Contains($k)) "$k is set already" }
        }
    }
    Case 'a dry run of install and of ollama names what it would do and does nothing' {
        $hermesHome = Join-Path $dir 'home4'
        $env:HERMES_HOME = $hermesHome
        try {
            $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool install -DryRun 2>&1 | ForEach-Object { "$_" })
            Assert-Equal 0 $LASTEXITCODE "install -DryRun exit: $($out -join ' | ')"
            Assert-True (($out -join "`n") -match 'install\.ps1') "names the installer: $($out -join ' | ')"
            Assert-True (($out -join "`n") -match '-NonInteractive') 'unattended'
            Assert-True (($out -join "`n") -match [regex]::Escape($hermesHome)) 'with the home here'
            Assert-True (-not (Test-Path -LiteralPath $hermesHome)) 'created nothing'
            $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool ollama -DryRun 2>&1 | ForEach-Object { "$_" })
            Assert-Equal 0 $LASTEXITCODE "ollama -DryRun exit: $($out -join ' | ')"
            Assert-True (($out -join "`n") -match 'OLLAMA_CONTEXT_LENGTH=65536') "names the context: $($out -join ' | ')"
            $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool available 2>&1)
            Assert-True ($LASTEXITCODE -in 0, 1) 'available answers with 0 or 1'
        } finally { Remove-Item Env:HERMES_HOME -ErrorAction SilentlyContinue }
    }
} finally {
    if ($savedHome) { $env:HERMES_HOME = $savedHome }
    Remove-TempProfile $dir
}
Complete-Cases
