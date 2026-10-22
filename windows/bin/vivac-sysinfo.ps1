<#
.SYNOPSIS
  What the bar's gauge popups show beyond Zebar's own numbers.

.DESCRIPTION
    -Top   one line of JSON: the programs using the most processor and the
           most memory right now, five of each, a program's processes summed
           (twenty Edge processes are one Edge)
    -Gpu   one line of JSON: the NVIDIA card's name, load, memory, power,
           fan and clock, from nvidia-smi

  The processor figures are the performance counters' formatted values, the
  ones Task Manager shows, read through CIM so the names are the same in
  every Windows language. zpack.json grants exactly these command lines.
#>
param(
    [switch]$Top,
    [switch]$Gpu
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Top) {
    $cores = [Environment]::ProcessorCount
    $rows = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Property Name, PercentProcessorTime, WorkingSetPrivate |
        Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' }
    $byName = @{}
    foreach ($r in $rows) {
        $name = $r.Name -replace '#\d+$', ''
        if (-not $byName.ContainsKey($name)) { $byName[$name] = @{ cpu = 0.0; mem = 0.0 } }
        $byName[$name].cpu += [double]$r.PercentProcessorTime / $cores
        $byName[$name].mem += [double]$r.WorkingSetPrivate
    }
    $cpu = @($byName.GetEnumerator() | Sort-Object { $_.Value.cpu } -Descending | Select-Object -First 5 |
        ForEach-Object { [ordered]@{ name = $_.Key; value = [math]::Round($_.Value.cpu, 1) } })
    $mem = @($byName.GetEnumerator() | Sort-Object { $_.Value.mem } -Descending | Select-Object -First 5 |
        ForEach-Object { [ordered]@{ name = $_.Key; value = [math]::Round($_.Value.mem / 1MB) } })
    [ordered]@{ cpu = $cpu; memory = $mem } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

if ($Gpu) {
    $fields = 'name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,power.limit,fan.speed,clocks.gr'
    $line = (& nvidia-smi "--query-gpu=$fields" '--format=csv,noheader,nounits' | Select-Object -First 1)
    $v = @($line -split ',\s*')
    $num = { param($s) $d = 0.0; if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $d } else { $null } }
    [ordered]@{
        name = $v[0]; temp = & $num $v[1]; load = & $num $v[2]
        memUsed = & $num $v[3]; memTotal = & $num $v[4]
        power = & $num $v[5]; powerLimit = & $num $v[6]; fan = & $num $v[7]; clock = & $num $v[8]
    } | ConvertTo-Json -Compress
    exit 0
}
