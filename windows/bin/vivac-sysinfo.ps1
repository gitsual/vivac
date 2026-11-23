<#
.SYNOPSIS
  What the bar's gauge popups show beyond Zebar's own numbers.

.DESCRIPTION
    -Top   one line of JSON: the programs using the most processor and the
           most memory right now, five of each, a program's processes summed
           (twenty Edge processes are one Edge)
    -Gpu   one line of JSON: the NVIDIA card's name, load, memory, power,
           fan and clock, from nvidia-smi
    -Info  one line of JSON, asked once: the processor's name and its
           physical and logical core counts
    -Cores one line of JSON: the use of every logical processor (the same
           counters Task Manager's per-thread view reads), the number of
           processes and threads, and the processor queue length
    -GpuProcs one line of JSON: the programs holding the card's memory, a
           program's processes summed, each tagged compute (C), graphics (G)
           or both (C+G) by the engines the performance counters show it on

  The processor figures are the performance counters' formatted values, the
  ones Task Manager shows, read through CIM so the names are the same in
  every Windows language. zpack.json grants exactly these command lines.
#>
param(
    [switch]$Top,
    [switch]$Gpu,
    [switch]$Info,
    [switch]$Cores,
    [switch]$GpuProcs
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

if ($Info) {
    $cpus = @(Get-CimInstance Win32_Processor -Property Name, NumberOfCores, NumberOfLogicalProcessors)
    [ordered]@{
        model   = (($cpus | Select-Object -First 1).Name -replace '\s+', ' ').Trim()
        cores   = [int](($cpus | Measure-Object NumberOfCores -Sum).Sum)
        threads = [int](($cpus | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
    } | ConvertTo-Json -Compress
    exit 0
}

if ($Cores) {
    # "0,5" is processor group 0, logical processor 5; the "_Total" rows are
    # the sums. Sorted by number so the order is the one the system numbers them.
    $rows = @(Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Property Name, PercentProcessorTime |
        Where-Object { $_.Name -match '^\d+,\d+$' })
    $per = @($rows | Sort-Object { [int]($_.Name -split ',')[0] * 1000 + [int]($_.Name -split ',')[1] } |
        ForEach-Object { [int][math]::Min(100, [double]$_.PercentProcessorTime) })
    $os = Get-CimInstance Win32_PerfFormattedData_PerfOS_System -Property Processes, Threads, ProcessorQueueLength | Select-Object -First 1
    [ordered]@{
        threads = $per
        processes = [int]$os.Processes
        threadCount = [int]$os.Threads
        queue = [int]$os.ProcessorQueueLength
    } | ConvertTo-Json -Compress
    exit 0
}

if ($GpuProcs) {
    # Counter instances are named pid_<pid>_luid_<adapter>_phys_<n>[_eng_<n>_engtype_<type>].
    $pidOf = { param($n) if ($n -match '^pid_(\d+)_') { [int]$Matches[1] } else { -1 } }
    $mem = @{}
    foreach ($r in @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -Property Name, DedicatedUsage -ErrorAction SilentlyContinue)) {
        $id = & $pidOf $r.Name
        if ($id -lt 0) { continue }
        $mem[$id] = [double]$mem[$id] + [double]$r.DedicatedUsage
    }
    $kind = @{}
    foreach ($r in @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Property Name -ErrorAction SilentlyContinue)) {
        $id = & $pidOf $r.Name
        if ($id -lt 0 -or $r.Name -notmatch 'engtype_(\w+)$') { continue }
        $t = $Matches[1]
        if (-not $kind.ContainsKey($id)) { $kind[$id] = @{ c = $false; g = $false } }
        if ($t -match '^(Compute|Cuda)') { $kind[$id].c = $true } elseif ($t -match '^(3D|Graphics|Copy|Video)') { $kind[$id].g = $true }
    }
    $byName = @{}
    foreach ($id in $mem.Keys) {
        if ($mem[$id] -le 0) { continue }
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        $name = if ($p) { $p.ProcessName } else { "pid $id" }
        if (-not $byName.ContainsKey($name)) { $byName[$name] = @{ mb = 0.0; n = 0; c = $false; g = $false } }
        $byName[$name].mb += $mem[$id] / 1MB
        $byName[$name].n += 1
        if ($kind.ContainsKey($id)) { $byName[$name].c = $byName[$name].c -or $kind[$id].c; $byName[$name].g = $byName[$name].g -or $kind[$id].g }
    }
    $procs = @($byName.GetEnumerator() | Sort-Object { $_.Value.mb } -Descending | Select-Object -First 8 | ForEach-Object {
        $k = if ($_.Value.c -and $_.Value.g) { 'C+G' } elseif ($_.Value.c) { 'C' } else { 'G' }
        [ordered]@{ name = $_.Key; mb = [int][math]::Round($_.Value.mb); n = $_.Value.n; kind = $k }
    })
    [ordered]@{ procs = $procs } | ConvertTo-Json -Compress -Depth 4
    exit 0
}
