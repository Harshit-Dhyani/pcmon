#region --- CLI Parameters ---
param(
    [switch]$NoOpen,
    [switch]$ApiOnly,
    [switch]$Wallpaper,
    [switch]$Tray,
    [switch]$Help
)

if ($Help) {
    @"
pcmon - Local-first Windows system monitoring and diagnostics

Usage:
    .\pcmon.ps1 [-NoOpen] [-ApiOnly] [-Tray] [-Help]

Options:
    -NoOpen      Start the server without opening the browser (API-only mode)
    -ApiOnly     Same as -NoOpen
    -Tray        Run in system tray mode
    -Help        Show this help message

Examples:
    .\pcmon.ps1            Standard mode, opens browser automatically
    .\pcmon.ps1 -NoOpen    API-only, browser stays closed
    .\pcmon.ps1 -Tray      Run with system tray icon

Requirements:
    - Windows with PowerShell 5.1+ or PowerShell Core (pwsh)
    - Web browser for the dashboard

"@
    exit 0
}

if ($Wallpaper -and -not $Tray) {
    Write-Host "[pcmon] -Wallpaper requires -Tray to be enabled." -ForegroundColor Red
    exit 1
}
#endregion

#region --- Setup ---
$ErrorActionPreference = "Continue"
$script:ErrorCount = 0
$HOSTNAME = "localhost"
$Port = 9876
$OPEN_BROWSER = -not ($NoOpen -or $ApiOnly)
for ($i = 0; $i -lt 20; $i++) {
    $test = New-Object System.Net.HttpListener
    $test.Prefixes.Add("http://${HOSTNAME}:$Port/")
    try { $test.Start(); $test.Stop(); break } catch { $Port++; $test.Abort() }
}
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$WEB_DIR = Join-Path $SCRIPT_DIR "web"
$LOG_FILE = Join-Path $env:TEMP "pcmon_errors.log"

$script:StartTime = Get-Date
$script:CachedStatic = $null
$script:StaticCacheExpiry = [DateTime]::MinValue
$script:StaticFiles = @{}
$script:CachedVideo = $null
$script:CommandLines = @{}
$script:LiveCacheTime = [DateTime]::MinValue
$script:ProcessCacheTime = [DateTime]::MinValue
$script:ProcessCache = @()
$script:ProcessCacheTime = [DateTime]::MinValue
$script:Errors = @()
$script:LiveDataCache = $null
$script:LiveDataCacheExpiry = [DateTime]::MinValue
$script:LiveDataCollectionStatus = "idle"
$SNAPSHOTS_DIR = Join-Path $SCRIPT_DIR "snapshots"
if (-not (Test-Path $SNAPSHOTS_DIR)) { New-Item -ItemType Directory -Path $SNAPSHOTS_DIR -Force | Out-Null }

$PROTECTED_PROCESSES = @('System', 'Idle', 'csrss', 'smss', 'wininit', 'services', 'lsass', 'svchost', 'winlogon', 'dwm', 'explorer', 'taskhostw', 'sihost', 'ctfmon', 'fontdrvhost', 'Memory Compression')

$script:AlertThresholds = @{
    ram_pct = 85
    commit_pct = 80
    pages_sec = 1000
    non_paged_mb = 1500
    disk_pct = 90
    cpu_pct = 90
}

$configPath = Join-Path $SCRIPT_DIR "config.json"
if (Test-Path $configPath) {
    try {
        $saved = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($key in $saved.PSObject.Properties.Name) {
            $script:AlertThresholds[$key] = $saved.$key
        }
    } catch { }
}
#endregion

#region --- Snapshots & Compare ---
function Get-SnapshotFiles {
    param([string]$Pattern = "*.json")
    if (Test-Path $SNAPSHOTS_DIR) {
        return @(Get-ChildItem $SNAPSHOTS_DIR -Filter $Pattern -File | Sort-Object LastWriteTime -Descending)
    }
    return @()
}

function Save-Snapshot {
    param([string]$Label = "")
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $filename = "snapshot_$timestamp.json"
    $filepath = Join-Path $SNAPSHOTS_DIR $filename
    $data = Get-LiveData
    $snapshot = @{
        id = $timestamp
        ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        label = $Label
        summary = @{
            hostname   = $data.hostname
            ram_pct    = $data.ram_pct; ram_used_gb = $data.ram_used_gb; ram_total_gb = $data.ram_total_gb
            cpu_pct    = $data.cpu_pct; cpu_queue = $data.cpu_queue
            commit_pct = $data.commit_pct; commit_gb = $data.commit_gb; commit_limit_gb = $data.commit_limit_gb
            paged_pool_mb = $data.paged_pool_mb; non_paged_mb = $data.non_paged_mb
            pages_sec  = $data.pages_sec; disk_pct = $data.disk_pct
            total_procs = $data.total_procs; insights = $data.insights
            gpu_pct = if ($data.gpu.available) { $data.gpu.eng_type_totals.'3d' } else { 0 }
        }
        top_ram  = @($data.top_ram    | Select-Object -First 30 | ForEach-Object { @{ name = $_.name; pid = $_.pid; ws_mb = $_.ws_mb; cpu_s = $_.cpu_s; threads = $_.threads; handles = $_.handles } })
        top_cpu  = @($data.top_cpu    | Select-Object -First 30 | ForEach-Object { @{ name = $_.name; pid = $_.pid; ws_mb = $_.ws_mb; cpu_s = $_.cpu_s; threads = $_.threads; handles = $_.handles } })
        top_priv = @($data.top_private | Select-Object -First 30 | ForEach-Object { @{ name = $_.name; pid = $_.pid; ws_mb = $_.ws_mb; priv_mb = $_.private_mb; cpu_s = $_.cpu_s } })
        groups   = $data.groups
        gpu      = if ($data.gpu.available) { @{ adapters = $data.gpu.adapters; eng_totals = $data.gpu.eng_type_totals } } else { @{ available = $false } }
    }
    $snapshot | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $filepath -Encoding UTF8
    return @{ id = $timestamp; ts = $snapshot.ts; label = $Label; filename = $filename }
}

function Compare-Snapshots {
    param([string]$SnapshotId)
    $files = Get-SnapshotFiles
    $snapshotFile = $files | Where-Object { $_.BaseName -eq "snapshot_$SnapshotId" } | Select-Object -First 1
    if (-not $snapshotFile) { return @{ error = "Snapshot not found" } }
    $snapshot = Get-Content $snapshotFile.FullName | ConvertFrom-Json
    $current = Get-LiveData
    $compare = @{
        snapshot_id = $SnapshotId
        snapshot_ts = $snapshot.ts
        current_ts = $current.ts
        changes = @()
    }
    $snapshotData = $snapshot.summary
    $currentData = $current
    if ($snapshotData.ram_pct -ne $currentData.ram_pct) {
        $compare.changes += @{
            type = "ram"
            name = "RAM Usage"
            old = $snapshotData.ram_pct
            new = $currentData.ram_pct
            diff = [math]::Round($currentData.ram_pct - $snapshotData.ram_pct, 1)
            direction = if ($currentData.ram_pct -gt $snapshotData.ram_pct) { "increased" } else { "decreased" }
        }
    }
    if ($snapshotData.cpu_pct -ne $currentData.cpu_pct) {
        $compare.changes += @{
            type = "cpu"
            name = "CPU Usage"
            old = $snapshotData.cpu_pct
            new = $currentData.cpu_pct
            diff = [math]::Round($currentData.cpu_pct - $snapshotData.cpu_pct, 1)
            direction = if ($currentData.cpu_pct -gt $snapshotData.cpu_pct) { "increased" } else { "decreased" }
        }
    }
    if ($snapshotData.commit_pct -ne $currentData.commit_pct) {
        $compare.changes += @{
            type = "commit"
            name = "Commit Charge"
            old = $snapshotData.commit_pct
            new = $currentData.commit_pct
            diff = [math]::Round($currentData.commit_pct - $snapshotData.commit_pct, 1)
            direction = if ($currentData.commit_pct -gt $snapshotData.commit_pct) { "increased" } else { "decreased" }
        }
    }
    if ($snapshotData.ram_used_gb -ne $currentData.ram_used_gb) {
        $compare.changes += @{
            type = "ram_used"
            name = "RAM Used (GB)"
            old = $snapshotData.ram_used_gb
            new = $currentData.ram_used_gb
            diff = [math]::Round($currentData.ram_used_gb - $snapshotData.ram_used_gb, 2)
            direction = if ($currentData.ram_used_gb -gt $snapshotData.ram_used_gb) { "increased" } else { "decreased" }
        }
    }
    $snapProcs = @{}
    foreach ($p in $snapshotData.top_ram) { $snapProcs[$p.name] = $p }
    $currProcs = @{}
    foreach ($p in $currentData.top_ram) { $currProcs[$p.name] = $p }
    $newProcs = @($currProcs.Keys | Where-Object { -not $snapProcs.ContainsKey($_) })
    $goneProcs = @($snapProcs.Keys | Where-Object { -not $currProcs.ContainsKey($_) })
    if ($newProcs.Count -gt 0) {
        $newProcDetails = @()
        foreach ($np in $newProcs) { $newProcDetails += @{ name = $np; ws_mb = $currProcs[$np].ws_mb } }
        $compare.changes += @{
            type = "new_processes"
            name = "New Processes"
            count = $newProcs.Count
            processes = $newProcDetails
            direction = "new"
        }
    }
    if ($goneProcs.Count -gt 0) {
        $goneProcDetails = @()
        foreach ($gp in $goneProcs) { $goneProcDetails += @{ name = $gp; ws_mb = $snapProcs[$gp].ws_mb } }
        $compare.changes += @{
            type = "gone_processes"
            name = "Gone Processes"
            count = $goneProcs.Count
            processes = $goneProcDetails
            direction = "gone"
        }
    }
    if ($snapshotData.disks -and $currentData.disks) {
        $snapDisk = @{}
        foreach ($d in $snapshotData.disks) { $snapDisk[$d.drive] = $d }
        $currDisk = @{}
        foreach ($d in $currentData.disks) { $currDisk[$d.drive] = $d }
        foreach ($drive in $currDisk.Keys) {
            if ($snapDisk.ContainsKey($drive)) {
                if ($snapDisk[$drive].pct -ne $currDisk[$drive].pct) {
                    $compare.changes += @{
                        type = "disk"
                        name = "Disk $($drive) Usage"
                        old = $snapDisk[$drive].pct
                        new = $currDisk[$drive].pct
                        diff = [math]::Round($currDisk[$drive].pct - $snapDisk[$drive].pct, 1)
                        direction = if ($currDisk[$drive].pct -gt $snapDisk[$drive].pct) { "increased" } else { "decreased" }
                    }
                }
            }
        }
    }
    if ($currentData.pages_sec -gt 0 -and $snapshotData.pages_sec -gt 0) {
        if ($currentData.pages_sec -ne $snapshotData.pages_sec) {
            $compare.changes += @{
                type = "paging"
                name = "Paging (pages/sec)"
                old = $snapshotData.pages_sec
                new = $currentData.pages_sec
                diff = [math]::Round($currentData.pages_sec - $snapshotData.pages_sec, 2)
                direction = if ($currentData.pages_sec -gt $snapshotData.pages_sec) { "increased" } else { "decreased" }
            }
        }
    }
    return $compare
}
#endregion

#region --- Utilities ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    $script:Errors += $entry
    if ($script:Errors.Count -gt 100) { $script:Errors = $script:Errors[-100..-1] }
    $entry | Out-File -FilePath $LOG_FILE -Append -Encoding UTF8
}

function Write-Err {
    param([string]$Message)
    Write-Log -Message $Message -Level "ERROR"
}

$global:LAST_ERROR = $null

function Stop-ProcessById {
    param([int]$ProcessId, [switch]$Force)
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return @{ success = $false; error = "Process not found" } }
    if ($PROTECTED_PROCESSES -contains $proc.ProcessName) { return @{ success = $false; error = "Cannot terminate protected system process" } }
    try {
        Stop-Process -Id $ProcessId -Force:$Force -ErrorAction Stop
        return @{ success = $true; message = "Process $($proc.ProcessName) terminated" }
    } catch {
        return @{ success = $false; error = "Operation failed" }
    }
}

function Suspend-ProcessById {
    param([int]$ProcessId)
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return @{ success = $false; error = "Process not found" } }
    if ($PROTECTED_PROCESSES -contains $proc.ProcessName) { return @{ success = $false; error = "Cannot suspend protected system process" } }
    try {
        $proc.Suspend()
        return @{ success = $true; message = "Process $($proc.ProcessName) suspended" }
    } catch {
        return @{ success = $false; error = "Operation failed" }
    }
}

function Resume-ProcessById {
    param([int]$ProcessId)
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return @{ success = $false; error = "Process not found" } }
    try {
        $proc.Resume()
        return @{ success = $true; message = "Process $($proc.ProcessName) resumed" }
    } catch {
        return @{ success = $false; error = "Operation failed" }
    }
}
#endregion

#region --- Data Collection ---
function Get-CachedStaticData {
    $now = Get-Date
    if ($script:StaticCacheExpiry -gt $now) { return }
    $script:CachedStatic = @{
        Drives = @(Get-CimInstance Win32_LogicalDisk -Property DeviceID, VolumeName, FileSystem, Size, FreeSpace | Where-Object { $_.DriveType -eq 3 })
        Services = @(Get-CimInstance Win32_Service -Property Name, DisplayName, State, StartMode, ProcessId)
        Startup = @(Get-CimInstance Win32_StartupCommand -Property Name, Command, Location, User)
        OS = Get-CimInstance Win32_OperatingSystem
        Video = @(Get-CimInstance Win32_VideoController -Property Name, AdapterRAM, Status)
    }
    $script:StaticCacheExpiry = $now.AddSeconds(30)
}

function Get-CachedCommandLines {
    param($Pids)
    $now = Get-Date
    if ($script:ProcessCacheTime -gt $now.AddSeconds(-5)) {
        $missing = @($Pids | Where-Object { -not $script:CommandLines.ContainsKey($_) })
        if ($missing.Count -eq 0) { return }
    }
    $script:ProcessCacheTime = $now
    $cmds = Get-CimInstance Win32_Process -Property ProcessId, CommandLine -ErrorAction SilentlyContinue
    foreach ($c in $cmds) {
        $script:CommandLines[$c.ProcessId] = $c.CommandLine
    }
}

function Get-LiveData {
    $now = Get-Date
    $cacheAge = ($now - $script:LiveCacheTime).TotalSeconds
    if ($cacheAge -lt 3 -and $null -ne $script:LiveDataCache) {
        return $script:LiveDataCache
    }
    $script:LiveDataCache = _CollectLiveData
    $script:LiveCacheTime = $now
    return $script:LiveDataCache
}

function _CollectLiveData {
    if ($null -eq $script:CachedStatic) { Get-CachedStaticData }
    $cs = $script:CachedStatic
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $samples = @()
    try {
        $systemCounters = Get-Counter '\Memory\Available MBytes','\Memory\Committed Bytes','\Memory\Commit Limit','\Memory\Pool Paged Bytes','\Memory\Pool Nonpaged Bytes','\Memory\Pages/sec','\Memory\Page Reads/sec','\Processor(_Total)\% Processor Time','\System\Processor Queue Length','\PhysicalDisk(_Total)\% Disk Time','\PhysicalDisk(_Total)\Avg. Disk Queue Length','\PhysicalDisk(_Total)\Disk Read Bytes/sec','\PhysicalDisk(_Total)\Disk Write Bytes/sec','\Network Interface(*)\Bytes Sent/sec','\Network Interface(*)\Bytes Received/sec' -ErrorAction SilentlyContinue

        $gpuCounters = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue
        $samples = @()
        if ($systemCounters) { $samples += $systemCounters.CounterSamples }
        if ($gpuCounters) { $samples += $gpuCounters.CounterSamples }
    } catch {}

    $sw.Stop(); $collectMs = $sw.ElapsedMilliseconds
    $sw.Restart()

    $os = $cs.OS
    $s = @{}
    foreach ($sm in $samples) { $s[$sm.Path] = $sm.CookedValue }

    $totalRAMMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
    $memAvailMB = [math]::Round([double]$s['\Memory\Available MBytes'], 2)
    $usedRAMMB = $totalRAMMB - $memAvailMB
    $ramPct = if ($totalRAMMB -gt 0) { [math]::Round(($usedRAMMB / $totalRAMMB) * 100, 1) } else { 0 }
    $commitBytes = [double]$s['\Memory\Committed Bytes']
    $commitLimitBytes = [double]$s['\Memory\Commit Limit']
    $commitPct = if ($commitLimitBytes -gt 0) { [math]::Round(($commitBytes / $commitLimitBytes) * 100, 1) } else { 0 }
    $cpuPct = [math]::Round([double]$s['\Processor(_Total)\% Processor Time'], 1)

    $netSentKB = 0; $netRecvKB = 0
    foreach ($k in $s.Keys) {
        if ($k -like '*Bytes Sent*') { $netSentKB += $s[$k] }
        elseif ($k -like '*Bytes Received*') { $netRecvKB += $s[$k] }
    }

    $processes = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{ name = $_.ProcessName; pid = $_.Id; ws_mb = [math]::Round($_.WorkingSet64 / 1MB, 1); private_mb = [math]::Round($_.PrivateMemorySize64 / 1MB, 1); cpu_s = [math]::Round($_.CPU, 1); threads = $_.Threads.Count; handles = $_.Handles }
    })
    $sw.Stop()

    $by_ram = @($processes | Sort-Object ws_mb -Descending | Select-Object -First 30)
    $by_private = @($processes | Sort-Object private_mb -Descending | Select-Object -First 30)
    $by_cpu = @($processes | Sort-Object cpu_s -Descending | Select-Object -First 20)

    $browserGroup = @{ ws_mb = 0; count = 0 }
    $devGroup = @{ ws_mb = 0; count = 0 }
    $secGroup = @{ ws_mb = 0; count = 0 }
    $browserPattern = 'msedge|arc|chrome|opera|brave|firefox|electron|librewolf'
    $devPattern = 'node|bun|python|java|code|webstorm|rider|idea|pycharm|goland|datagrip|phpstorm|ruby|rust|cargo|opencode|codex|chatgpt|pieces|os-server'
    $secPattern = 'msmpeng|malware|mbam|glasswire|portmaster|defender|avast|kaspersky|bitdefender|eset'
    foreach ($p in $processes) {
        $n = $p.name.ToLowerInvariant()
        if ($n -match $browserPattern) { $browserGroup.ws_mb += $p.ws_mb; $browserGroup.count++ }
        elseif ($n -match $devPattern) { $devGroup.ws_mb += $p.ws_mb; $devGroup.count++ }
        elseif ($n -match $secPattern) { $secGroup.ws_mb += $p.ws_mb; $secGroup.count++ }
    }
    $browserGroup.ws_mb = [math]::Round($browserGroup.ws_mb, 1)
    $devGroup.ws_mb = [math]::Round($devGroup.ws_mb, 1)
    $secGroup.ws_mb = [math]::Round($secGroup.ws_mb, 1)

    $adapters = $cs.Video
    $gpuResult = @{ available = $false; adapters = @(); eng_type_totals = @{ '3d' = 0; 'videodecode' = 0; 'videoprocessing' = 0; 'copy' = 0; 'videoencode' = 0; 'security' = 0; 'vr' = 0; 'other' = 0 }; dedicated_used_gb = 0; dedicated_total_gb = 0 }
    foreach ($adapter in $adapters) {
        $totalGB = if ($adapter.AdapterRAM -and $adapter.AdapterRAM -gt 0) { [math]::Round($adapter.AdapterRAM / 1GB, 1) } else { 0 }
        $gpuResult.adapters += @{ name = $adapter.Name; status = $adapter.Status; dedicated_gb = 0; total_gb = $totalGB; pct = 0 }
        $gpuResult.dedicated_total_gb += $totalGB
    }
    foreach ($sm in $samples) {
        if ($sm.Path -like '*GPU*Engtype_3d*') { $gpuResult.eng_type_totals['3d'] += $sm.CookedValue }
        elseif ($sm.Path -like '*GPU*Engtype_videodecode*') { $gpuResult.eng_type_totals['videodecode'] += $sm.CookedValue }
        elseif ($sm.Path -like '*GPU*Engtype_videoencode*') { $gpuResult.eng_type_totals['videoencode'] += $sm.CookedValue }
    }
    $gpuResult.available = $gpuResult.adapters.Count -gt 0

    $insights = @()
    $memAvailGB = [math]::Round($memAvailMB / 1024, 1)
    $nonPagedMB = [math]::Round([double]$s['\Memory\Pool Nonpaged Bytes'] / 1MB, 0)
    if ($memAvailMB -lt 1024) { $insights += "CRITICAL: Less than 1GB RAM available ($memAvailGB GB)." }
    elseif ($memAvailMB -lt 2048) { $insights += "Low available RAM ($memAvailGB GB)." }
    if ($commitPct -ge 90) { $insights += "Commit charge > 90%." }
    if ([double]$s['\Memory\Pages/sec'] -ge 1000) { $insights += "Heavy paging." }
    if ($nonPagedMB -ge 1500) { $insights += "Non-paged pool high ($nonPagedMB MB)." }
    if ($cpuPct -ge 90) { $insights += "CPU at ${cpuPct}%." }
    if ($browserGroup.count -gt 0 -and $browserGroup.ws_mb -gt 2000) { $insights += "Browsers: $($browserGroup.count) procs, ~$($browserGroup.ws_mb) MB." }
    if ($devGroup.count -gt 0 -and $devGroup.ws_mb -gt 1000) { $insights += "Dev tools: $($devGroup.count) procs, ~$($devGroup.ws_mb) MB." }
    if ($secGroup.count -gt 0 -and $secGroup.ws_mb -gt 500) { $insights += "Security: $($secGroup.count) procs, ~$($secGroup.ws_mb) MB." }
    if (-not $insights) { $insights += 'System healthy.' }

    $disks = @($cs.Drives | ForEach-Object {
        $used = $_.Size - $_.FreeSpace; $pct = if ($_.Size -gt 0) { [math]::Round(($used / $_.Size) * 100, 1) } else { 0 }
        [PSCustomObject]@{ drive = $_.DeviceID; label = $_.VolumeName; fs = $_.FileSystem; total_gb = [math]::Round($_.Size / 1GB, 1); used_gb = [math]::Round($used / 1GB, 1); free_gb = [math]::Round($_.FreeSpace / 1GB, 1); pct = $pct; state = if ($pct -ge 90) { 'bad' } elseif ($pct -ge 80) { 'warn' } else { 'ok' } }
    })

    return @{
        ts = (Get-Date -Format 'HH:mm:ss'); hostname = $env:COMPUTERNAME; os_caption = $os.Caption; total_procs = $processes.Count; ram_pct = $ramPct
        ram_used_gb = [math]::Round($usedRAMMB / 1024, 2); ram_total_gb = [math]::Round($totalRAMMB / 1024, 2); ram_avail_mb = $memAvailMB
        commit_pct = $commitPct; commit_gb = [math]::Round($commitBytes / 1GB, 2); limit_gb = [math]::Round($commitLimitBytes / 1GB, 2)
        paged_pool_mb = [math]::Round([double]$s['\Memory\Pool Paged Bytes'] / 1MB, 2); non_paged_mb = $nonPagedMB
        pages_sec = [math]::Round([double]$s['\Memory\Pages/sec'], 2); page_reads_sec = [math]::Round([double]$s['\Memory\Page Reads/sec'], 2)
        cpu_pct = $cpuPct; cpu_queue = [math]::Round([double]$s['\System\Processor Queue Length'], 2)
        disk_pct = [math]::Round([double]$s['\PhysicalDisk(_Total)\% Disk Time'], 1); disk_queue = [math]::Round([double]$s['\PhysicalDisk(_Total)\Avg. Disk Queue Length'], 2)
        disk_read_mb = [math]::Round([double]$s['\PhysicalDisk(_Total)\Disk Read Bytes/sec'] / 1MB, 2)
        disk_write_mb = [math]::Round([double]$s['\PhysicalDisk(_Total)\Disk Write Bytes/sec'] / 1MB, 2)
        net_sent_kb = [math]::Round($netSentKB / 1KB, 1); net_recv_kb = [math]::Round($netRecvKB / 1KB, 1)
        top_ram = $by_ram; top_private = $by_private; top_cpu = $by_cpu; suspicious = @()
        disks = $disks; startup = $cs.Startup; pagefile = @(); heavy_services = @(); ps_profiles = @()
        insights = $insights; gpu = $gpuResult; groups = @{ browser = $browserGroup; dev_tools = $devGroup; security = $secGroup }
        _perf_ms = $collectMs
    }
}
#endregion

#region --- HTTP Server ---
$modeLabel = if ($ApiOnly) { "API-Only" } else { "Dashboard" }
$browserLabel = if ($OPEN_BROWSER) { "Auto-open" } else { "No browser" }
$trayLabel = if ($Tray) { "$([char]0x1B)[92m[Tray]$([char]0x1B)[0m" } else { "" }
$wallpaperLabel = if ($Wallpaper) { "$([char]0x1B)[93m[Wallpaper]$([char]0x1B)[0m" } else { "" }

Write-Host ""
Write-Host "  =========================================" -ForegroundColor DarkGray
Write-Host "   $([char]0x1B)[92mPCMON v1.0$([char]0x1B)[0m  $([char]0x1B)[96m$modeLabel$([char]0x1B)[0m $trayLabel $wallpaperLabel" -NoNewline; Write-Host ""
Write-Host "   $([char]0x1B)[2m  Local-first Windows system monitor$([char]0x1B)[0m"
Write-Host "  =========================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host ""
$base = "http://${HOSTNAME}:$Port"
Write-Host "  $([char]0x1B)[2mOpen in browser (Ctrl+Click):$([char]0x1B)[0m"
Write-Host "  $base/"
if (-not $ApiOnly) {
    Write-Host "  $base/dashboard.js"
    Write-Host "  $base/dashboard.css"
}
Write-Host "  $base/data"
Write-Host "  $base/api/snapshots"
Write-Host "  $base/api/report"
Write-Host "  $base/api/report/download"
Write-Host "  $base/health"
Write-Host "  $base/errors"
Write-Host "  $base/debug"
Write-Host "  $base/logs"
Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
if ($Tray) {
    Write-Host "  Stop      : $([char]0x1B)[93mRight-click tray -> Exit$([char]0x1B)[0m" -NoNewline; Write-Host ""
} else {
    Write-Host "  Stop      : $([char]0x1B)[93mCtrl+C$([char]0x1B)[0m" -NoNewline; Write-Host ""
}
Write-Host ""

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://${HOSTNAME}:$Port/")
$listener.TimeoutManager.RequestQueue = New-Object System.TimeSpan(0, 2, 0)

foreach ($f in @('index.html', 'dashboard.css', 'dashboard.js')) {
    $fp = Join-Path $WEB_DIR $f
    if (Test-Path $fp) { $script:StaticFiles[$f] = @{ data = [System.IO.File]::ReadAllBytes($fp); type = if ($f -like '*.css') { 'text/css' } elseif ($f -like '*.js') { 'application/javascript' } else { 'text/html; charset=utf-8' } } }
}

$listener.Start()

if ($OPEN_BROWSER -and -not $Tray) {
    Start-Process "http://${HOSTNAME}:$Port"
}

if ($Tray) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:TrayIcon = $null
    $script:WallpaperTimer = $null

    function New-TrayIcon {
        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
        $notifyIcon.Text = "PCMON - System Monitor"
        $notifyIcon.Visible = $true

        $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

        $openItem = New-Object System.Windows.Forms.ToolStripMenuItem("Open Dashboard")
        $openItem.Add_Click({ Start-Process "http://${HOSTNAME}:$Port" })
        $contextMenu.Items.Add($openItem)

        if ($Wallpaper) {
            $wallpaperItem = New-Object System.Windows.Forms.ToolStripMenuItem("Open Wallpaper")
            $wallpaperItem.Add_Click({ 
                $wallpaperUrl = "http://${HOSTNAME}:$Port/wallpaper.html"
                Start-Process $wallpaperUrl 
            })
            $contextMenu.Items.Add($wallpaperItem)
        }

        $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
        $exitItem.Add_Click({ 
            $script:shuttingDown = $true
            $listener.Stop()
            if ($script:TrayIcon) { $script:TrayIcon.Visible = $false }
            if ($script:WallpaperTimer) { $script:WallpaperTimer.Stop() }
            exit 0
        })
        $contextMenu.Items.Add($exitItem)

        $notifyIcon.ContextMenuStrip = $contextMenu

        $notifyIcon.Add_DoubleClick({ Start-Process "http://${HOSTNAME}:$Port" })

        return $notifyIcon
    }

    $script:TrayIcon = New-TrayIcon
    Write-Host "  System tray icon enabled." -ForegroundColor Green
}

Get-CachedStaticData

Write-Host "  Pre-collecting live data..." -NoNewline
$sw = [Diagnostics.Stopwatch]::StartNew()
$script:LiveDataCache = _CollectLiveData
$script:LiveCacheTime = Get-Date
$sw.Stop()
Write-Host " $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green
Write-Host ""

try {
    while ($listener.IsListening -and -not $script:shuttingDown) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $path = $request.Url.LocalPath

        if ($path -eq "/health") {
            $uptime = ((Get-Date) - $script:StartTime).TotalSeconds
            $ts = Get-Date -Format 'HH:mm:ss'
            $json = "{\`"status\`":\`"ok\`",\`"ts\`":\`"$ts\`",\`"uptime_seconds\`":$([math]::Round($uptime))}"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/errors") {
            $errJson = @{
                error_count = $script:ErrorCount
                uptime = [math]::Round(((Get-Date) - $script:StartTime).TotalSeconds)
                errors = $script:Errors[-20..-1]
                sysinfo = @{
                    ps_version = $PSVersionTable.PSVersion.ToString()
                    os = $script:CachedStatic.OS.Caption
                    hostname = $env:COMPUTERNAME
                }
            } | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($errJson)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/logs") {
            $buffer = [System.Text.Encoding]::UTF8.GetBytes(($script:Errors -join "`n"))
            $response.ContentType = "text/plain"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/debug") {
            $debug = @{
                start_time = $script:StartTime.ToString('o')
                cache_expiry = $script:StaticCacheExpiry.ToString('o')
                cached_services_count = $script:CachedStatic.Services.Count
                cached_drives_count = $script:CachedStatic.Drives.Count
                commandlines_cached = $script:CommandLines.Count
                static_files = $script:StaticFiles.Keys
            } | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($debug)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/data") {
            $data = Get-LiveData
            $json = $data | ConvertTo-Json -Depth 20 -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -match '^/api/snapshots$' -and $request.HttpMethod -eq "GET") {
            $files = Get-SnapshotFiles
            $list = @($files | ForEach-Object {
                $content = Get-Content $_.FullName -Raw | ConvertFrom-Json
                @{ id = $content.id; ts = $content.ts; label = $content.label; filename = $_.Name }
            })
            $json = $list | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -match '^/api/snapshots$' -and $request.HttpMethod -eq "POST") {
            $label = ""
            try {
                $body = [System.IO.StreamReader]::new($request.InputStream).ReadToEnd()
                if ($body) { $parsed = $body | ConvertFrom-Json; if ($parsed.label) { $label = $parsed.label } }
            } catch {}
            $result = Save-Snapshot -Label $label
            $json = $result | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -match '^/api/snapshots/([^/]+)$') {
            $snapId = $matches[1]
            $files = Get-SnapshotFiles
            $snapshotFile = $files | Where-Object { $_.BaseName -eq "snapshot_$snapId" } | Select-Object -First 1
            if ($snapshotFile) {
                $content = Get-Content $snapshotFile.FullName -Raw
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($content)
                $response.ContentType = "application/json"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } else {
                $response.StatusCode = 404
                $response.ContentLength64 = 0
            }
        }
        elseif ($path -match '^/api/snapshots/([^/]+)/compare$' -and $request.HttpMethod -eq "POST") {
            $snapId = $matches[1]
            $result = Compare-Snapshots -SnapshotId $snapId
            $json = $result | ConvertTo-Json -Depth 20 -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -match '^/api/snapshots/([^/]+)/export$') {
            $snapId = $matches[1]
            $files = Get-SnapshotFiles
            $snapshotFile = $files | Where-Object { $_.BaseName -eq "snapshot_$snapId" } | Select-Object -First 1
            if ($snapshotFile) {
                $content = Get-Content $snapshotFile.FullName -Raw
                $jsonObj = $content | ConvertFrom-Json
                $label = if ($jsonObj.label) { $jsonObj.label -replace '[^\w\-_]', '_' } else { 'no_label' }
                $filename = "pcmon_snapshot_${snapId}_${label}.json"
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($content)
                $response.ContentType = "application/json"
                $response.Headers.Add("Content-Disposition", "attachment; filename=`"$filename`"")
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } else {
                $response.StatusCode = 404
                $response.ContentLength64 = 0
            }
        }
        elseif ($path -match '^/api/snapshots/([^/]+)/export\.csv$') {
            $snapId = $matches[1]
            $files = Get-SnapshotFiles
            $snapshotFile = $files | Where-Object { $_.BaseName -eq "snapshot_$snapId" } | Select-Object -First 1
            if ($snapshotFile) {
                $content = Get-Content $snapshotFile.FullName -Raw
                $jsonObj = $content | ConvertFrom-Json
                $label = if ($jsonObj.label) { $jsonObj.label -replace '[^\w\-_]', '_' } else { 'no_label' }
                $filename = "pcmon_snapshot_${snapId}_${label}.csv"
                $topRam = @()
                if ($jsonObj.top_ram) {
                    $topRam = $jsonObj.top_ram | Sort-Object ws_mb -Descending | Select-Object -First 50
                }
                $csvLines = @("Name,PID,Working Set (MB),CPU Time,Threads,Handles")
                foreach ($p in $topRam) {
                    $name = if ($p.name) { $p.name.Replace(',', '_') } else { 'N/A' }
                    $pid = if ($p.pid) { $p.pid } else { 0 }
                    $ws = if ($p.ws_mb) { $p.ws_mb } else { 0 }
                    $cpu = if ($p.cpu_s) { $p.cpu_s } else { 0 }
                    $threads = if ($p.threads) { $p.threads } else { 0 }
                    $handles = if ($p.handles) { $p.handles } else { 0 }
                    $csvLines += "$name,$pid,$ws,$cpu,$threads,$handles"
                }
                $csvContent = $csvLines -join "`n"
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($csvContent)
                $response.ContentType = "text/csv"
                $response.Headers.Add("Content-Disposition", "attachment; filename=`"$filename`"")
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } else {
                $response.StatusCode = 404
                $response.ContentLength64 = 0
            }
        }
        elseif ($path -match '^/api/process/(\d+)/kill$') {
            $pid = [int]$matches[1]
            $result = Stop-ProcessById -ProcessId $pid -Force
            $json = $result | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -match '^/api/process/(\d+)/suspend$') {
            $pid = [int]$matches[1]
            $result = Suspend-ProcessById -ProcessId $pid
            $json = $result | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -match '^/api/process/(\d+)/resume$') {
            $pid = [int]$matches[1]
            $result = Resume-ProcessById -ProcessId $pid
            $json = $result | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/api/report") {
            $data = Get-LiveData
            $html = @"
<!DOCTYPE html>
<html>
<head>
<title>PCMON System Report - $($data.ts)</title>
<style>
body { font-family: Arial, sans-serif; padding: 20px; max-width: 1200px; margin: 0 auto; }
h1 { color: #333; }
h2 { border-bottom: 1px solid #ccc; padding-bottom: 5px; margin-top: 30px; }
table { width: 100%; border-collapse: collapse; margin-bottom: 20px; }
th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
th { background: #f5f5f5; }
.metric { display: inline-block; margin: 10px 20px 10px 0; }
.metric-value { font-size: 24px; font-weight: bold; }
.insight { background: #fff3cd; padding: 10px; margin: 5px 0; border-left: 3px solid #ffc107; }
.system-info { background: #f8f9fa; padding: 15px; margin: 10px 0; border-radius: 5px; }
.system-info p { margin: 5px 0; }
@media print { .no-print { display: none; } body { padding: 0; } }
</style>
</head>
<body>
<h1>PCMON System Report</h1>
<p>Generated: $($data.ts) | Host: $($data.hostname)</p>

<div class="system-info">
<p><strong>OS:</strong> $($data.os_caption)</p>
<p><strong>Total Processes:</strong> $($data.total_procs)</p>
</div>

<h2>System Overview</h2>
<div class="metric"><div class="metric-value">$([math]::Round($data.ram_pct))%</div><div>RAM Usage</div></div>
<div class="metric"><div class="metric-value">$([math]::Round($data.cpu_pct))%</div><div>CPU Usage</div></div>
<div class="metric"><div class="metric-value">$([math]::Round($data.commit_pct))%</div><div>Commit Charge</div></div>
<div class="metric"><div class="metric-value">$($data.total_procs)</div><div>Processes</div></div>

<h2>Memory Details</h2>
<table>
<tr><th>Metric</th><th>Value</th></tr>
<tr><td>RAM Used</td><td>$([math]::Round($data.ram_used_gb, 2)) GB / $([math]::Round($data.ram_total_gb, 2)) GB</td></tr>
<tr><td>Available RAM</td><td>$([math]::Round($data.ram_avail_mb / 1024, 2)) GB</td></tr>
<tr><td>Commit Charge</td><td>$([math]::Round($data.commit_gb, 2)) GB / $([math]::Round($data.limit_gb, 2)) GB</td></tr>
<tr><td>Paged Pool</td><td>$([math]::Round($data.paged_pool_mb, 0)) MB</td></tr>
<tr><td>Non-Paged Pool</td><td>$([math]::Round($data.non_paged_mb, 0)) MB</td></tr>
<tr><td>Pages/sec</td><td>$([math]::Round($data.pages_sec, 2))</td></tr>
</table>

<h2>Insights</h2>
$($data.insights | ForEach-Object { "<div class='insight'>$_</div>" })

<h2>Top Processes (RAM)</h2>
<table>
<tr><th>Name</th><th>PID</th><th>Working Set (MB)</th><th>Private (MB)</th><th>CPU Time (s)</th></tr>
$($data.top_ram | Select-Object -First 20 | ForEach-Object { "<tr><td>$($_.name)</td><td>$($_.pid)</td><td>$([math]::Round($_.ws_mb))</td><td>$([math]::Round($_.private_mb))</td><td>$([math]::Round($_.cpu_s))</td></tr>" })
</table>

<h2>Top Processes (CPU)</h2>
<table>
<tr><th>Name</th><th>PID</th><th>CPU Time (s)</th><th>Working Set (MB)</th></tr>
$($data.top_cpu | Select-Object -First 20 | ForEach-Object { "<tr><td>$($_.name)</td><td>$($_.pid)</td><td>$([math]::Round($_.cpu_s))</td><td>$([math]::Round($_.ws_mb))</td></tr>" })
</table>

<h2>Drives</h2>
<table>
<tr><th>Drive</th><th>Label</th><th>Total GB</th><th>Free GB</th><th>Used GB</th><th>Usage %</th></tr>
$($data.disks | ForEach-Object { "<tr><td>$($_.drive)</td><td>$($_.label)</td><td>$([math]::Round($_.total_gb))</td><td>$([math]::Round($_.free_gb))</td><td>$([math]::Round($_.used_gb))</td><td>$([math]::Round($_.pct))%</td></tr>" })
</table>

<h2>Process Groups</h2>
<table>
<tr><th>Group</th><th>Count</th><th>Working Set (MB)</th></tr>
<tr><td>Browser / Electron</td><td>$($data.groups.browser.count)</td><td>$([math]::Round($data.groups.browser.ws_mb))</td></tr>
<tr><td>Dev Tools</td><td>$($data.groups.dev_tools.count)</td><td>$([math]::Round($data.groups.dev_tools.ws_mb))</td></tr>
<tr><td>Security Tools</td><td>$($data.groups.security.count)</td><td>$([math]::Round($data.groups.security.ws_mb))</td></tr>
</table>

<div class="no-print" style="margin-top: 20px;">
<button onclick="window.print()" style="padding: 10px 20px; font-size: 14px; cursor: pointer;">Print / Save as PDF</button>
<button onclick="window.close()" style="padding: 10px 20px; font-size: 14px; cursor: pointer; margin-left: 10px;">Close</button>
</div>
</body>
</html>
"@
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
            $response.ContentType = "text/html; charset=utf-8"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/api/report/download") {
            $data = Get-LiveData
            $html = @"
<!DOCTYPE html>
<html>
<head>
<title>PCMON System Report - $($data.ts)</title>
<style>
body { font-family: Arial, sans-serif; padding: 20px; max-width: 1200px; margin: 0 auto; }
h1 { color: #333; }
h2 { border-bottom: 1px solid #ccc; padding-bottom: 5px; margin-top: 30px; }
table { width: 100%; border-collapse: collapse; margin-bottom: 20px; }
th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
th { background: #f5f5f5; }
.metric { display: inline-block; margin: 10px 20px 10px 0; }
.metric-value { font-size: 24px; font-weight: bold; }
.insight { background: #fff3cd; padding: 10px; margin: 5px 0; border-left: 3px solid #ffc107; }
.system-info { background: #f8f9fa; padding: 15px; margin: 10px 0; border-radius: 5px; }
.system-info p { margin: 5px 0; }
</style>
</head>
<body>
<h1>PCMON System Report</h1>
<p>Generated: $($data.ts) | Host: $($data.hostname)</p>

<div class="system-info">
<p><strong>OS:</strong> $($data.os_caption)</p>
<p><strong>Total Processes:</strong> $($data.total_procs)</p>
</div>

<h2>System Overview</h2>
<div class="metric"><div class="metric-value">$([math]::Round($data.ram_pct))%</div><div>RAM Usage</div></div>
<div class="metric"><div class="metric-value">$([math]::Round($data.cpu_pct))%</div><div>CPU Usage</div></div>
<div class="metric"><div class="metric-value">$([math]::Round($data.commit_pct))%</div><div>Commit Charge</div></div>
<div class="metric"><div class="metric-value">$($data.total_procs)</div><div>Processes</div></div>

<h2>Memory Details</h2>
<table>
<tr><th>Metric</th><th>Value</th></tr>
<tr><td>RAM Used</td><td>$([math]::Round($data.ram_used_gb, 2)) GB / $([math]::Round($data.ram_total_gb, 2)) GB</td></tr>
<tr><td>Available RAM</td><td>$([math]::Round($data.ram_avail_mb / 1024, 2)) GB</td></tr>
<tr><td>Commit Charge</td><td>$([math]::Round($data.commit_gb, 2)) GB / $([math]::Round($data.limit_gb, 2)) GB</td></tr>
<tr><td>Paged Pool</td><td>$([math]::Round($data.paged_pool_mb, 0)) MB</td></tr>
<tr><td>Non-Paged Pool</td><td>$([math]::Round($data.non_paged_mb, 0)) MB</td></tr>
<tr><td>Pages/sec</td><td>$([math]::Round($data.pages_sec, 2))</td></tr>
</table>

<h2>Insights</h2>
$($data.insights | ForEach-Object { "<div class='insight'>$_</div>" })

<h2>Top Processes (RAM)</h2>
<table>
<tr><th>Name</th><th>PID</th><th>Working Set (MB)</th><th>Private (MB)</th><th>CPU Time (s)</th></tr>
$($data.top_ram | Select-Object -First 20 | ForEach-Object { "<tr><td>$($_.name)</td><td>$($_.pid)</td><td>$([math]::Round($_.ws_mb))</td><td>$([math]::Round($_.private_mb))</td><td>$([math]::Round($_.cpu_s))</td></tr>" })
</table>

<h2>Top Processes (CPU)</h2>
<table>
<tr><th>Name</th><th>PID</th><th>CPU Time (s)</th><th>Working Set (MB)</th></tr>
$($data.top_cpu | Select-Object -First 20 | ForEach-Object { "<tr><td>$($_.name)</td><td>$($_.pid)</td><td>$([math]::Round($_.cpu_s))</td><td>$([math]::Round($_.ws_mb))</td></tr>" })
</table>

<h2>Drives</h2>
<table>
<tr><th>Drive</th><th>Label</th><th>Total GB</th><th>Free GB</th><th>Used GB</th><th>Usage %</th></tr>
$($data.disks | ForEach-Object { "<tr><td>$($_.drive)</td><td>$($_.label)</td><td>$([math]::Round($_.total_gb))</td><td>$([math]::Round($_.free_gb))</td><td>$([math]::Round($_.used_gb))</td><td>$([math]::Round($_.pct))%</td></tr>" })
</table>

<h2>Process Groups</h2>
<table>
<tr><th>Group</th><th>Count</th><th>Working Set (MB)</th></tr>
<tr><td>Browser / Electron</td><td>$($data.groups.browser.count)</td><td>$([math]::Round($data.groups.browser.ws_mb))</td></tr>
<tr><td>Dev Tools</td><td>$($data.groups.dev_tools.count)</td><td>$([math]::Round($data.groups.dev_tools.ws_mb))</td></tr>
<tr><td>Security Tools</td><td>$($data.groups.security.count)</td><td>$([math]::Round($data.groups.security.ws_mb))</td></tr>
</table>
</body>
</html>
"@
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $filename = "pcmon_report_$timestamp.html"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
            $response.ContentType = "text/html; charset=utf-8"
            $response.Headers.Add("Content-Disposition", "attachment; filename=`"$filename`"")
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/api/config" -and $request.HttpMethod -eq "GET") {
            $json = $script:AlertThresholds | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/api/config" -and $request.HttpMethod -eq "POST") {
            try {
                $body = [System.IO.StreamReader]::new($request.InputStream).ReadToEnd()
                if ($body) {
                    $parsed = $body | ConvertFrom-Json
                    foreach ($key in $parsed.PSObject.Properties.Name) {
                        if ($script:AlertThresholds.ContainsKey($key)) {
                            $value = $parsed.$key
                            # Validate numeric type for threshold values
                            if ($value -is [double] -or $value -is [int] -or $value -is [float]) {
                                $script:AlertThresholds[$key] = $value
                            }
                        }
                    }
                    $script:AlertThresholds | ConvertTo-Json -Compress | Out-File -FilePath $configPath -Encoding UTF8
                    $json = @{ success = $true; thresholds = $script:AlertThresholds } | ConvertTo-Json -Compress
                } else {
                    $json = @{ success = $false; error = "Empty body" } | ConvertTo-Json -Compress
                }
            } catch {
                $json = @{ success = $false; error = "Invalid configuration" } | ConvertTo-Json -Compress
            }
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/" -or $path -eq "/index.html") {
            $sf = $script:StaticFiles['index.html']
            if ($sf) { $response.ContentType = $sf.type; $response.ContentLength64 = $sf.data.Length; $response.OutputStream.Write($sf.data, 0, $sf.data.Length) }
            else { $response.StatusCode = 404; $response.ContentLength64 = 0 }
        }
        elseif ($path -match '^/dashboard\.css$') {
            $sf = $script:StaticFiles['dashboard.css']
            if ($sf) { $response.ContentType = $sf.type; $response.ContentLength64 = $sf.data.Length; $response.OutputStream.Write($sf.data, 0, $sf.data.Length) }
            else { $response.StatusCode = 404; $response.ContentLength64 = 0 }
        }
        elseif ($path -match '^/dashboard\.js$') {
            $sf = $script:StaticFiles['dashboard.js']
            if ($sf) { $response.ContentType = $sf.type; $response.ContentLength64 = $sf.data.Length; $response.OutputStream.Write($sf.data, 0, $sf.data.Length) }
            else { $response.StatusCode = 404; $response.ContentLength64 = 0 }
        }
        else {
            $response.StatusCode = 404
            $response.ContentLength64 = 0
        }

        $response.Close()
    }
} catch {
    Write-Log "HTTP handler error: $_"
}

$shuttingDown = $false
Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
    $script:shuttingDown = $true
    $listener.Stop()
    Write-Host ""
    Write-Host "[pcmon] Stopped." -ForegroundColor Yellow
} | Out-Null
#endregion


