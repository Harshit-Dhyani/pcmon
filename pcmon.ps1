#region --- CLI Parameters ---
param(
    [switch]$NoOpen,
    [switch]$ApiOnly,
    [switch]$Wallpaper,
    [switch]$Tray,
    [switch]$Debug,
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
$script:CommandLines = @{}
$script:LiveCacheTime = [DateTime]::MinValue
$script:Errors = @()
$script:DebugMode = $Debug
$script:LiveDataCache = $null
$script:LiveDataCacheExpiry = [DateTime]::MinValue
$script:LiveDataCollectionStatus = "idle"
$script:ConnectionMethod = "polling"
$script:WSClients = [System.Collections.Generic.List[object]]::new()
$script:WSLastSend = [DateTime]::MinValue
$script:WSBroadcastInterval = 500
$SNAPSHOTS_DIR = Join-Path $SCRIPT_DIR "snapshots"
if (-not (Test-Path $SNAPSHOTS_DIR)) { New-Item -ItemType Directory -Path $SNAPSHOTS_DIR -Force | Out-Null }
$cacheFile = Join-Path $env:TEMP "pcmon_live_cache.json"

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
    if (Test-Path $cacheFile) {
        try { $data = Get-Content $cacheFile -Raw | ConvertFrom-Json } catch { $data = Get-LiveData }
    } else { $data = Get-LiveData }
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
    $snapshot | ConvertTo-Json -Depth 20 -Compress | Out-File -FilePath $filepath -Encoding UTF8
    return @{ id = $timestamp; ts = $snapshot.ts; label = $Label; filename = $filename }
}

function Compare-Snapshots {
    param([string]$SnapshotId)
    $files = Get-SnapshotFiles
    $snapshotFile = $files | Where-Object { $_.BaseName -eq "snapshot_$SnapshotId" } | Select-Object -First 1
    if (-not $snapshotFile) { return @{ error = "Snapshot not found" } }
    $snapshot = Get-Content $snapshotFile.FullName | ConvertFrom-Json
    if (Test-Path $cacheFile) {
        try { $current = Get-Content $cacheFile -Raw | ConvertFrom-Json } catch { $current = Get-LiveData }
    } else { $current = Get-LiveData }
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
    if ($Level -ne "DEBUG" -or $script:DebugMode) { $script:Errors += $entry }
    if ($script:Errors.Count -gt 100) { $script:Errors = @($script:Errors | Select-Object -Last 100) }
    $entry | Out-File -FilePath $LOG_FILE -Append -Encoding UTF8
}

function Send-Response {
    param([System.Net.HttpListenerResponse]$Response, [byte[]]$Buffer, [string]$ContentType = "application/json", [string]$ContentDisposition = "")
    try {
        $Response.ContentType = $ContentType
        if ($ContentDisposition) { $Response.Headers.Add("Content-Disposition", $ContentDisposition) }
        $Response.ContentLength64 = $Buffer.Length
        $Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
    } catch {
        if ($script:DebugMode) { Write-Log "Send failed (client disconnect?): $($_.Exception.Message)" "DEBUG" }
    }
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

function Broadcast-WebSocketData($data) {
    if ($script:WSClients.Count -eq 0) { return }
    $now = Get-Date
    if (($now - $script:WSLastSend).TotalMilliseconds -lt $script:WSBroadcastInterval) { return }
    $script:WSLastSend = $now
    try {
        $json = $data | ConvertTo-Json -Depth 20 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $dead = [System.Collections.Generic.List[object]]::new()
        foreach ($ws in $script:WSClients) {
            try {
                if ($ws.State -eq 'Open') {
                    $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None)
                } else { $dead.Add($ws) }
            } catch { $dead.Add($ws) }
        }
        foreach ($d in $dead) { try { $script:WSClients.Remove($d) } catch {} }
    } catch {}
}

function Send-Response($response, $data, $type = "application/json", $contentDisposition = $null) {
    try {
        if ($null -ne $contentDisposition -and $contentDisposition -ne "") {
            $response.Headers.Add("Content-Disposition", $contentDisposition)
        }
        if ($null -ne $data) {
            if ($data -is [byte[]]) {
                $response.ContentType = $type
                $response.ContentLength64 = $data.Length
                $response.OutputStream.Write($data, 0, $data.Length)
            } else {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($data)
                $response.ContentType = $type
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
        }
    } catch {}
    try { $response.Close() } catch {}
}
#endregion

#region --- Data Collection ---
function Get-CachedStaticData {
    $now = Get-Date
    if ($script:StaticCacheExpiry -gt $now) { return }
    $drives = @(Get-CimInstance Win32_LogicalDisk -Property DeviceID, VolumeName, FileSystem, Size, FreeSpace -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 3 })
    if ($drives.Count -eq 0) {
        try {
            $wmiDrives = @(Get-WmiObject Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 3 })
            if ($wmiDrives.Count -gt 0) { $drives = $wmiDrives }
        } catch {}
    }
    $script:CachedStatic = @{
        Drives = $drives
        Services = @(Get-CimInstance Win32_Service -Property Name, DisplayName, State, StartMode, ProcessId -ErrorAction SilentlyContinue)
        Startup = @(Get-CimInstance Win32_StartupCommand -Property Name, Command, Location, User -ErrorAction SilentlyContinue)
        OS = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        Video = @(Get-CimInstance Win32_VideoController -Property Name, AdapterRAM, Status -ErrorAction SilentlyContinue)
    }
    $script:StaticCacheExpiry = $now.AddSeconds(60)
}

function Get-CachedCommandLines {
    $now = Get-Date
    if ($script:ProcessCacheTime -gt $now.AddSeconds(-5)) { return }
    $script:ProcessCacheTime = $now
    $cmds = Get-CimInstance Win32_Process -Property ProcessId, CommandLine, ExecutablePath -ErrorAction SilentlyContinue
    foreach ($c in $cmds) {
        $script:CommandLines[$c.ProcessId] = @{ cmd = $c.CommandLine; exe_path = $c.ExecutablePath }
    }
}

function Get-LiveData {
    $now = Get-Date
    $cacheAge = ($now - $script:LiveCacheTime).TotalSeconds
    if ($cacheAge -lt 5 -and $null -ne $script:LiveDataCache) {
        return $script:LiveDataCache
    }
    if (Test-Path $cacheFile) {
        try {
            $fi = Get-Item $cacheFile -ErrorAction SilentlyContinue
            if ($fi -and ($now - $fi.LastWriteTime).TotalSeconds -lt 5) {
                $script:LiveDataCache = Get-Content $cacheFile -Raw | ConvertFrom-Json
                $script:LiveCacheTime = $now
                return $script:LiveDataCache
            }
        } catch {}
    }
    $script:LiveDataCache = _CollectLiveData
    $script:LiveCacheTime = $now
    return $script:LiveDataCache
}

function _CollectLiveData {
    if ($null -eq $script:CachedStatic) { Get-CachedStaticData }
    $cs = $script:CachedStatic
    $t0 = [DateTime]::UtcNow.Ticks

    $samples = @()
    try {
        $systemCounters = Get-Counter '\Memory\Available MBytes','\Memory\Committed Bytes','\Memory\Commit Limit','\Memory\Pool Paged Bytes','\Memory\Pool Nonpaged Bytes','\Memory\Pages/sec','\Memory\Page Reads/sec','\Processor(_Total)\% Processor Time','\System\Processor Queue Length','\PhysicalDisk(_Total)\% Disk Time','\PhysicalDisk(_Total)\Avg. Disk Queue Length','\PhysicalDisk(_Total)\Disk Read Bytes/sec','\PhysicalDisk(_Total)\Disk Write Bytes/sec','\Network Interface(*)\Bytes Sent/sec','\Network Interface(*)\Bytes Received/sec' -ErrorAction SilentlyContinue

        $gpuCounters = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue
        $samples = @()
        if ($systemCounters) { $samples += $systemCounters.CounterSamples }
        if ($gpuCounters) { $samples += $gpuCounters.CounterSamples }
    } catch {}

    $t0 = [DateTime]::UtcNow.Ticks
    $os = if ($cs.OS) { $cs.OS } else { try { Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue } catch {} }
    $s = @{}
    foreach ($sm in $samples) {
        $idx = $sm.Path.IndexOf("\", 2)
        $clean = $sm.Path.Substring($idx).ToUpperInvariant()
        $s[$clean] = $sm.CookedValue
    }

    $totalRAMMB = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1024, 0) } else { 0 }
    $memAvailMB = [math]::Round([double]$s['\MEMORY\AVAILABLE MBYTES'], 2)
    $usedRAMMB = $totalRAMMB - $memAvailMB
    $ramPct = if ($totalRAMMB -gt 0) { [math]::Round(($usedRAMMB / $totalRAMMB) * 100, 1) } else { 0 }
    $commitBytes = [double]$s['\MEMORY\COMMITTED BYTES']
    $commitLimitBytes = [double]$s['\MEMORY\COMMIT LIMIT']
    $commitPct = if ($commitLimitBytes -gt 0) { [math]::Round(($commitBytes / $commitLimitBytes) * 100, 1) } else { 0 }
    $cpuPct = [math]::Round([double]$s['\PROCESSOR(_TOTAL)\% PROCESSOR TIME'], 1)

    $netSentKB = 0.0; $netRecvKB = 0.0
    foreach ($k in $s.Keys) {
        if ($k -like '*BYTES SENT*') { $netSentKB += $s[$k] }
        elseif ($k -like '*BYTES RECEIVED*') { $netRecvKB += $s[$k] }
    }

    Get-CachedCommandLines
    $processes = @()
    try {
        $processes = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            $extra = $script:CommandLines[$_.Id]
            [PSCustomObject]@{
                name = $_.ProcessName; pid = $_.Id
                ws_mb = [math]::Round($_.WorkingSet64 / 1MB, 1)
                private_mb = [math]::Round($_.PrivateMemorySize64 / 1MB, 1)
                cpu_s = [math]::Round($_.CPU, 1)
                threads = $_.Threads.Count; handles = $_.Handles
                path = if ($extra) { $extra.exe_path } else { $null }
                command_line = if ($extra) { $extra.cmd } else { $null }
            }
        })
    } catch { $processes = @() }

    $by_ram = @($processes | Sort-Object ws_mb -Descending | Select-Object -First 30)
    $by_private = @($processes | Sort-Object private_mb -Descending | Select-Object -First 30)
    $by_cpu = @($processes | Sort-Object cpu_s -Descending | Select-Object -First 20)

    $browserGroup = @{ ws_mb = 0.0; count = 0 }
    $devGroup = @{ ws_mb = 0.0; count = 0 }
    $secGroup = @{ ws_mb = 0.0; count = 0 }
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

    $adapters = if ($cs.Video) { $cs.Video } else { @() }
    $gpuResult = @{ available = $false; adapters = @(); eng_type_totals = @{ '3d' = 0; 'videodecode' = 0; 'videoprocessing' = 0; 'copy' = 0; 'videoencode' = 0; 'security' = 0; 'vr' = 0; 'other' = 0 }; dedicated_used_gb = 0; dedicated_total_gb = 0 }
    foreach ($adapter in $adapters) {
        $totalGB = if ($adapter.AdapterRAM -and $adapter.AdapterRAM -gt 0) { [math]::Round($adapter.AdapterRAM / 1GB, 1) } else { 0 }
        $gpuResult.adapters += @{ name = $adapter.Name; status = $adapter.Status; dedicated_gb = 0; total_gb = $totalGB; pct = 0 }
        $gpuResult.dedicated_total_gb += $totalGB
    }
    foreach ($sm in $samples) {
        $p = $sm.Path.ToUpperInvariant()
        if ($p -like '*GPU*ENG*3D*') { $gpuResult.eng_type_totals['3d'] += $sm.CookedValue }
        elseif ($p -like '*GPU*ENG*VIDEODECODE*') { $gpuResult.eng_type_totals['videodecode'] += $sm.CookedValue }
        elseif ($p -like '*GPU*ENG*VIDEOENCODE*') { $gpuResult.eng_type_totals['videoencode'] += $sm.CookedValue }
    }
    $gpuResult.available = $gpuResult.adapters.Count -gt 0

    $insights = @()
    $memAvailGB = [math]::Round($memAvailMB / 1024, 1)
    $pagedPoolBytes = [double]$s['\MEMORY\POOL PAGED BYTES']
    if ($pagedPoolBytes -le 0 -or [double]::IsNaN($pagedPoolBytes)) {
        try { $pagedPoolBytes = [double](Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue).PoolPagedBytes } catch { $pagedPoolBytes = 0 }
    }
    $nonPagedBytes = [double]$s['\MEMORY\POOL NONPAGED BYTES']
    if ($nonPagedBytes -le 0 -or [double]::IsNaN($nonPagedBytes)) {
        try { $nonPagedBytes = [double](Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue).PoolNonpagedBytes } catch { $nonPagedBytes = 0 }
    }
    $pagedPoolMB = [math]::Round($pagedPoolBytes / 1MB, 2)
    $pagedPoolPct = if ($totalRAMMB -gt 0) { [math]::Round($pagedPoolMB / $totalRAMMB * 100, 1) } else { 0 }
    $nonPagedMB = [math]::Round($nonPagedBytes / 1MB, 0)
    $nonPagedPct = if ($totalRAMMB -gt 0) { [math]::Round($nonPagedMB / $totalRAMMB * 100, 1) } else { 0 }
    if ($memAvailMB -lt 1024) { $insights += "CRITICAL: Less than 1GB RAM available ($memAvailGB GB)." }
    elseif ($memAvailMB -lt 2048) { $insights += "Low available RAM ($memAvailGB GB)." }
    if ($commitPct -ge 90) { $insights += "Commit charge > 90%." }
    if ([double]$s['\MEMORY\PAGES/SEC'] -ge 1000) { $insights += "Heavy paging." }
    if ($nonPagedMB -ge 1500) { $insights += "Non-paged pool high ($nonPagedMB MB)." }
    if ($cpuPct -ge 90) { $insights += "CPU at ${cpuPct}%." }
    if ($browserGroup.count -gt 0 -and $browserGroup.ws_mb -gt 2000) { $insights += "Browsers: $($browserGroup.count) procs, ~$($browserGroup.ws_mb) MB." }
    if ($devGroup.count -gt 0 -and $devGroup.ws_mb -gt 1000) { $insights += "Dev tools: $($devGroup.count) procs, ~$($devGroup.ws_mb) MB." }
    if ($secGroup.count -gt 0 -and $secGroup.ws_mb -gt 500) { $insights += "Security: $($secGroup.count) procs, ~$($secGroup.ws_mb) MB." }
    if (-not $insights) { $insights += 'System healthy.' }

    $disks = @()
    $drives = if ($cs.Drives) { $cs.Drives } else { @() }
    foreach ($d in $drives) {
        try {
            $used = $d.Size - $d.FreeSpace; $pct = if ($d.Size -gt 0) { [math]::Round(($used / $d.Size) * 100, 1) } else { 0 }
            $disks += [PSCustomObject]@{ drive = $d.DeviceID; label = $d.VolumeName; fs = $d.FileSystem; total_gb = [math]::Round($d.Size / 1GB, 1); used_gb = [math]::Round($used / 1GB, 1); free_gb = [math]::Round($d.FreeSpace / 1GB, 1); pct = $pct; state = if ($pct -ge 90) { 'bad' } elseif ($pct -ge 80) { 'warn' } else { 'ok' } }
        } catch {}
    }

    $pagefile = @()
    try { foreach ($pf in @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)) { $pagefile += [PSCustomObject]@{ name = $pf.Name; allocated_mb = $pf.AllocatedBaseSize; current_usage_mb = $pf.CurrentUsage; peak_usage_mb = $pf.PeakUsage } } } catch {}

    $psProfiles = @()
    try {
        $profilePaths = @($PROFILE.AllUsersAllHosts, $PROFILE.AllUsersCurrentHost, $PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)
        foreach ($pp in $profilePaths) { if ($pp) { $exists = Test-Path $pp -ErrorAction SilentlyContinue; $sizeKb = if ($exists) { try { [math]::Round((Get-Item $pp).Length / 1KB, 1) } catch { $null } } else { $null }; $psProfiles += [PSCustomObject]@{ path = $pp; exists = $exists; size_kb = $sizeKb } } }
    } catch {}

    $svcByPid = @{}
    $services = if ($cs.Services) { $cs.Services } else { @() }
    foreach ($svc in $services) { if ($svc.ProcessId -and $svc.ProcessId -gt 0) { $svcByPid[$svc.ProcessId] = $svc } }
    $heavyServices = @($by_ram | ForEach-Object { $svc = $svcByPid[$_.pid]; if ($svc) { [PSCustomObject]@{ name = $svc.Name; display_name = $svc.DisplayName; state = $svc.State; start_mode = $svc.StartMode; pid = $svc.ProcessId } } } | Select-Object -First 25)

    $allProcs = @($processes | Sort-Object ws_mb -Descending | Select-Object -First 300)
    $suspicious = @($processes | Where-Object { ($_.name -match 'powershell|pwsh|cmd|wscript|cscript|mshta|rundll32|regsvr32') -or ($_.command_line -match 'http://|https://|EncodedCommand|FromBase64String') } | Select-Object -First 50)

    $perfMs = [int](([DateTime]::UtcNow.Ticks - $t0) / 10000)

    $startupItems = if ($cs.Startup) { $cs.Startup } else { @() }
    $osCaption = if ($os) { $os.Caption } else { 'Unknown' }

    return @{
        ts = (Get-Date -Format 'HH:mm:ss'); hostname = $env:COMPUTERNAME; os_caption = $osCaption; total_procs = $processes.Count; ram_pct = $ramPct
        ram_used_gb = [math]::Round($usedRAMMB / 1024, 2); ram_total_gb = [math]::Round($totalRAMMB / 1024, 2); ram_avail_mb = $memAvailMB
        commit_pct = $commitPct; commit_gb = [math]::Round($commitBytes / 1GB, 2); limit_gb = [math]::Round($commitLimitBytes / 1GB, 2)
        paged_pool_mb = $pagedPoolMB; paged_pool_pct = $pagedPoolPct; non_paged_mb = $nonPagedMB; non_paged_pct = $nonPagedPct
        pages_sec = [math]::Round([double]$s['\MEMORY\PAGES/SEC'], 2); page_reads_sec = [math]::Round([double]$s['\MEMORY\PAGE READS/SEC'], 2)
        cpu_pct = $cpuPct; cpu_queue = [math]::Round([double]$s['\SYSTEM\PROCESSOR QUEUE LENGTH'], 2)
        disk_pct = [math]::Round([double]$s['\PHYSICALDISK(_TOTAL)\% DISK TIME'], 1); disk_queue = [math]::Round([double]$s['\PHYSICALDISK(_TOTAL)\AVG. DISK QUEUE LENGTH'], 2)
        disk_read_mb = [math]::Round([double]$s['\PHYSICALDISK(_TOTAL)\DISK READ BYTES/SEC'] / 1MB, 2)
        disk_write_mb = [math]::Round([double]$s['\PHYSICALDISK(_TOTAL)\DISK WRITE BYTES/SEC'] / 1MB, 2)
        net_sent_kb = [math]::Round($netSentKB / 1KB, 1); net_recv_kb = [math]::Round($netRecvKB / 1KB, 1)
        top_ram = $by_ram; top_private = $by_private; top_cpu = $by_cpu; all_processes = $allProcs; suspicious = $suspicious
        disks = $disks; startup = $startupItems; pagefile = $pagefile; heavy_services = $heavyServices; ps_profiles = $psProfiles
        insights = $insights; gpu = $gpuResult; groups = @{ browser = $browserGroup; dev_tools = $devGroup; security = $secGroup }
        _perf_ms = $perfMs; _loading = $false
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
Write-Host "   $([char]0x1B)[36m  Fast: 500ms | Tables: 4s | Static: 30s+$([char]0x1B)[0m"
Write-Host "  =========================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host ""
$base = "http://${HOSTNAME}:$Port"
Write-Host "  $([char]0x1B)[2mOpen in browser (Ctrl+Click):$([char]0x1B)[0m"
Write-Host "  $base/"
if (-not $ApiOnly) {
    Write-Host "  $base/dashboard.css"
}
Write-Host "  $base/data"
Write-Host "  $base/api/snapshots"
Write-Host "  $base/api/report"
Write-Host "  $base/api/report/download"
Write-Host "  $base/stream $([char]0x1B)[36m(WebSocket/SSE)$([char]0x1B)[0m"
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

$DIST_INDEX = Join-Path $WEB_DIR "dist\index.html"
if (Test-Path $DIST_INDEX) {
    $script:StaticFiles['index.html'] = @{ data = [System.IO.File]::ReadAllBytes($DIST_INDEX); type = 'text/html; charset=utf-8' }
} else {
    foreach ($f in @('index.html', 'dashboard.css')) {
        $fp = Join-Path $WEB_DIR $f
        if (Test-Path $fp) { $script:StaticFiles[$f] = @{ data = [System.IO.File]::ReadAllBytes($fp); type = if ($f -like '*.css') { 'text/css' } else { 'text/html; charset=utf-8' } } }
    }
}
$wallpaperFile = Join-Path $SCRIPT_DIR "wallpaper\index.html"
if (Test-Path $wallpaperFile) { $script:StaticFiles['wallpaper.html'] = @{ data = [System.IO.File]::ReadAllBytes($wallpaperFile); type = 'text/html; charset=utf-8' } }

$listener.Start()

$wsBroadcastTimer = New-Object System.Timers.Timer
$wsBroadcastTimer.Interval = $script:WSBroadcastInterval
$wsBroadcastTimer.AutoReset = $true
Register-ObjectEvent -InputObject $wsBroadcastTimer -EventName Elapsed -Action {
    if ($script:WSClients.Count -eq 0) { return }
    try {
        if (Test-Path $cacheFile) {
            $fi = Get-Item $cacheFile -ErrorAction SilentlyContinue
            if ($fi) {
                $data = Get-Content $cacheFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($data) {
                    Broadcast-WebSocketData $data
                }
            }
        }
    } catch {}
} | Out-Null
$wsBroadcastTimer.Start()

$script:LastFastUpdate = [DateTime]::MinValue
$script:FastUpdateInterval = 500

function Get-FastMetrics {
    try {
        $counters = Get-Counter '\Memory\Available MBytes','\Memory\Committed Bytes','\Memory\Commit Limit','\Processor(_Total)\% Processor Time','\PhysicalDisk(_Total)\% Disk Time' -ErrorAction SilentlyContinue
        $s = @{}
        if ($counters) { foreach ($sm in $counters.CounterSamples) { $idx = $sm.Path.IndexOf("\", 2); $clean = $sm.Path.Substring($idx).ToUpperInvariant(); $s[$clean] = $sm.CookedValue } }
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $totalMB = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1024, 0) } else { 0 }
        $availMB = if ($s['\MEMORY\AVAILABLE MBYTES']) { [math]::Round($s['\MEMORY\AVAILABLE MBYTES'], 0) } else { 0 }
        $usedMB = $totalMB - $availMB
        $ramPct = if ($totalMB -gt 0) { [math]::Round(($usedMB / $totalMB) * 100, 1) } else { 0 }
        $commitPct = 0
        if ($s['\MEMORY\COMMITTED BYTES'] -and $s['\MEMORY\COMMIT LIMIT']) {
            $commitPct = [math]::Round(($s['\MEMORY\COMMITTED BYTES'] / $s['\MEMORY\COMMIT LIMIT']) * 100, 1)
        }
        return @{
            ts = (Get-Date -Format 'HH:mm:ss')
            hostname = $env:COMPUTERNAME
            ram_pct = $ramPct
            ram_avail_mb = $availMB
            ram_total_gb = [math]::Round($totalMB / 1024, 1)
            commit_pct = $commitPct
            cpu_pct = if ($s['\PROCESSOR(_TOTAL)\% PROCESSOR TIME']) { [math]::Round($s['\PROCESSOR(_TOTAL)\% PROCESSOR TIME'], 1) } else { 0 }
            disk_pct = if ($s['\PHYSICALDISK(_TOTAL)\% DISK TIME']) { [math]::Round($s['\PHYSICALDISK(_TOTAL)\% DISK TIME'], 1) } else { 0 }
            _fast = $true
        }
    } catch { return $null }
}

$fastTimer = New-Object System.Timers.Timer
$fastTimer.Interval = $script:FastUpdateInterval
$fastTimer.AutoReset = $true
Register-ObjectEvent -InputObject $fastTimer -EventName Elapsed -Action {
    if ($script:WSClients.Count -eq 0) { return }
    $now = Get-Date
    if (($now - $script:LastFastUpdate).TotalMilliseconds -lt $script:FastUpdateInterval) { return }
    $script:LastFastUpdate = $now
    try {
        $data = Get-FastMetrics
        if ($data) { Broadcast-WebSocketData $data }
    } catch {}
} | Out-Null
$fastTimer.Start()

$cleanupTimer = New-Object System.Timers.Timer
$cleanupTimer.Interval = 30000
$cleanupTimer.AutoReset = $true
Register-ObjectEvent -InputObject $cleanupTimer -EventName Elapsed -Action {
    $dead = [System.Collections.Generic.List[object]]::new()
    foreach ($ws in $script:WSClients) {
        try { if ($ws.State -ne 'Open') { $dead.Add($ws) } } catch { $dead.Add($ws) }
    }
    foreach ($d in $dead) { try { $script:WSClients.Remove($d) } catch {} }
    $errCount = $script:Errors.Count
    if ($errCount -gt 100) { $script:Errors = @($script:Errors | Select-Object -Last 100) }
    if ($script:DebugMode -and $dead.Count -gt 0) { Write-Host "[DEBUG] Cleanup removed $($dead.Count) stale WS clients" -ForegroundColor DarkGray }
} | Out-Null
$cleanupTimer.Start()

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

$refreshRateFile = Join-Path $env:TEMP "pcmon_refresh_rate.txt"
$profilePathsFile = Join-Path $env:TEMP "pcmon_profile_paths.json"
"500" | Out-File -FilePath $refreshRateFile -Encoding UTF8 -Force
$profilePathsJson = @(
    $PROFILE.AllUsersAllHosts,
    $PROFILE.AllUsersCurrentHost,
    $PROFILE.CurrentUserAllHosts,
    $PROFILE.CurrentUserCurrentHost
) | Where-Object { $_ } | ConvertTo-Json -Compress
$profilePathsJson | Out-File -FilePath $profilePathsFile -Encoding UTF8 -Force

Write-Host "  Initializing..." -NoNewline
$sw2 = [Diagnostics.Stopwatch]::StartNew()
$sw2.Start()
if (Test-Path $cacheFile) {
    try {
        $script:LiveDataCache = Get-Content $cacheFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $script:LiveCacheTime = Get-Date
        $initMs = $sw2.ElapsedMilliseconds
        Write-Host " ${initMs}ms" -ForegroundColor Green -NoNewline
        Write-Host " | Streaming ready" -ForegroundColor Cyan
    } catch {
        Write-Host " no cache, starting..." -ForegroundColor Yellow
    }
} else {
    Write-Host " first run..." -ForegroundColor Yellow
}
Write-Host ""

$bgScriptContent = @'
$cacheFile = $args[0]
$refreshRateFile = $args[1]
$profilePathsFile = $args[2]
$bgDebug = if ($args[3] -eq "1") { $true } else { $false }
Import-Module CimCmdlets -ErrorAction SilentlyContinue
Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
$bgStart = [DateTime]::UtcNow.Ticks
try { $profilePathsJson = Get-Content $profilePathsFile -Raw -ErrorAction SilentlyContinue } catch { $profilePathsJson = '[]' }
try { $profilePaths = $profilePathsJson | ConvertFrom-Json } catch { $profilePaths = @() }
$os = Get-CimInstance Win32_OperatingSystem
$video = @(Get-CimInstance Win32_VideoController -Property Name, AdapterRAM, Status -ErrorAction SilentlyContinue)
$totalRAMMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
$firstRun = $true
$bgRefreshRate = 1000
$cycleCount = 0
$lastHeavyCollect = 0
$lastStaticCollect = 0
$heavyInterval = 4
$staticInterval = 30
if ($bgDebug) { Write-Host "[BG DEBUG] Started. Debug mode ON." -ForegroundColor Cyan }
while ($true) {
    $cycleCount++
    try { $bgRefreshRate = [int](Get-Content $refreshRateFile -Raw -ErrorAction SilentlyContinue) } catch {}
    if ($bgRefreshRate -lt 500) { $bgRefreshRate = 500 }
    if ($firstRun) { $firstRun = $false } else { Start-Sleep -Milliseconds $bgRefreshRate }
    if ($bgDebug) { Write-Host "[BG DEBUG] Cycle $cycleCount at ${bgRefreshRate}ms" -ForegroundColor Cyan }
    $t0 = [DateTime]::UtcNow.Ticks
    try {
        $counters = Get-Counter '\Memory\Available MBytes','\Memory\Committed Bytes','\Memory\Commit Limit','\Processor(_Total)\% Processor Time','\PhysicalDisk(_Total)\% Disk Time' -ErrorAction SilentlyContinue
        $s = @{}
        if ($counters) { foreach ($sm in $counters.CounterSamples) { $idx = $sm.Path.IndexOf("\", 2); $clean = $sm.Path.Substring($idx).ToUpperInvariant(); $s[$clean] = $sm.CookedValue } }
        $memAvailMB = [math]::Round([double]$s['\MEMORY\AVAILABLE MBYTES'], 2)
        $usedRAMMB = $totalRAMMB - $memAvailMB
        $ramPct = if ($totalRAMMB -gt 0) { [math]::Round(($usedRAMMB / $totalRAMMB) * 100, 1) } else { 0 }
        $commitBytes = [double]$s['\MEMORY\COMMITTED BYTES']
        $commitLimitBytes = [double]$s['\MEMORY\COMMIT LIMIT']
        $commitPct = if ($commitLimitBytes -gt 0) { [math]::Round(($commitBytes / $commitLimitBytes) * 100, 1) } else { 0 }
        $cpuPct = [math]::Round([double]$s['\PROCESSOR(_TOTAL)\% PROCESSOR TIME'], 1)
        $netSentKB = 0.0; $netRecvKB = 0.0
        $diskPct = [math]::Round([double]$s['\PHYSICALDISK(_TOTAL)\% DISK TIME'], 1)
        $doHeavy = ($cycleCount - $lastHeavyCollect) -ge $heavyInterval
        $doStatic = ($cycleCount - $lastStaticCollect) -ge $staticInterval
        if ($doHeavy) { $lastHeavyCollect = $cycleCount }
        if ($doStatic) { $lastStaticCollect = $cycleCount }
        $cmdLines = @{}
        if ($doHeavy) {
            foreach ($c in @(Get-CimInstance Win32_Process -Property ProcessId, CommandLine, ExecutablePath -ErrorAction SilentlyContinue)) { $cmdLines[[int]$c.ProcessId] = @{ cmd = $c.CommandLine; path = $c.ExecutablePath } }
            $procs = Get-Process -ErrorAction SilentlyContinue | Select-Object -First 300
            $processes = @($procs | ForEach-Object { $p = $_; $extra = $cmdLines[[int]$p.Id]; [PSCustomObject]@{ name = $p.ProcessName; pid = $p.Id; ws_mb = [math]::Round($p.WorkingSet64 / 1MB, 1); private_mb = [math]::Round($p.PrivateMemorySize64 / 1MB, 1); cpu_s = [math]::Round($p.CPU, 1); threads = $p.Threads.Count; handles = $p.Handles; path = if ($extra) { $extra.path } else { $null }; command_line = if ($extra) { $extra.cmd } else { $null } } })
            $all_processes = @($processes | Sort-Object ws_mb -Descending | Select-Object -First 300)
            $by_ram = @($processes | Sort-Object ws_mb -Descending | Select-Object -First 30)
            $by_private = @($processes | Sort-Object private_mb -Descending | Select-Object -First 30)
            $by_cpu = @($processes | Sort-Object cpu_s -Descending | Select-Object -First 20)
            $browserGroup = @{ ws_mb = 0.0; count = 0 }; $devGroup = @{ ws_mb = 0.0; count = 0 }; $secGroup = @{ ws_mb = 0.0; count = 0 }
            $browserPattern = 'msedge|arc|chrome|opera|brave|firefox|electron|librewolf'
            $devPattern = 'node|bun|python|java|code|webstorm|rider|idea|pycharm|goland|datagrip|phpstorm|ruby|rust|cargo|opencode|codex|chatgpt|pieces|os-server'
            $secPattern = 'msmpeng|malware|mbam|glasswire|portmaster|defender|avast|kaspersky|bitdefender|eset'
            foreach ($p in $processes) { $n = $p.name.ToLowerInvariant(); if ($n -match $browserPattern) { $browserGroup.ws_mb += $p.ws_mb; $browserGroup.count++ } elseif ($n -match $devPattern) { $devGroup.ws_mb += $p.ws_mb; $devGroup.count++ } elseif ($n -match $secPattern) { $secGroup.ws_mb += $p.ws_mb; $secGroup.count++ } }
            $browserGroup.ws_mb = [math]::Round($browserGroup.ws_mb, 1); $devGroup.ws_mb = [math]::Round($devGroup.ws_mb, 1); $secGroup.ws_mb = [math]::Round($secGroup.ws_mb, 1)
        }
        $gpuResult = @{ available = $false; adapters = @(); eng_type_totals = @{ '3d' = 0; 'videodecode' = 0; 'videoprocessing' = 0; 'copy' = 0; 'videoencode' = 0; 'security' = 0; 'vr' = 0; 'other' = 0 }; dedicated_used_gb = 0; dedicated_total_gb = 0 }
        foreach ($adapter in $video) { $totalGB = if ($adapter.AdapterRAM -and $adapter.AdapterRAM -gt 0) { [math]::Round($adapter.AdapterRAM / 1GB, 1) } else { 0 }; $gpuResult.adapters += @{ name = $adapter.Name; status = $adapter.Status; dedicated_gb = 0; total_gb = $totalGB; pct = 0 }; $gpuResult.dedicated_total_gb += $totalGB }
        $gpuResult.available = $gpuResult.adapters.Count -gt 0
        if ($doStatic) {
            $drives = @(Get-CimInstance Win32_LogicalDisk -Property DeviceID, VolumeName, FileSystem, Size, FreeSpace -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 3 })
            if ($drives.Count -eq 0) { try { $drives = @(Get-WmiObject Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 3 }) } catch {} }
            $disks = @()
            foreach ($d in $drives) { $used = $d.Size - $d.FreeSpace; $pct = if ($d.Size -gt 0) { [math]::Round(($used / $d.Size) * 100, 1) } else { 0 }; $disks += [PSCustomObject]@{ drive = $d.DeviceID; label = $d.VolumeName; fs = $d.FileSystem; total_gb = [math]::Round($d.Size / 1GB, 1); used_gb = [math]::Round($used / 1GB, 1); free_gb = [math]::Round($d.FreeSpace / 1GB, 1); pct = $pct; state = if ($pct -ge 90) { 'bad' } elseif ($pct -ge 80) { 'warn' } else { 'ok' } } }
            $services = @(Get-CimInstance Win32_Service -Property Name, DisplayName, State, StartMode, ProcessId -ErrorAction SilentlyContinue)
            $svcByPid = @{}
            foreach ($svc in $services) { if ($svc.ProcessId -and $svc.ProcessId -gt 0) { $svcByPid[[int]$svc.ProcessId] = $svc } }
            $heavyServices = @()
            if ($doHeavy -and $by_ram) { $heavyServices = @($by_ram | ForEach-Object { $svc = $svcByPid[[int]$_.pid]; if ($svc) { [PSCustomObject]@{ name = $svc.Name; display_name = $svc.DisplayName; state = $svc.State; start_mode = $svc.StartMode; pid = $svc.ProcessId } } } | Select-Object -First 25) }
        }
        $suspicious = @($all_processes | Where-Object { ($_.name -match 'powershell|pwsh|cmd|wscript|cscript|mshta|rundll32|regsvr32') -or ($_.command_line -match 'http://|https://|EncodedCommand|FromBase64String') } | Select-Object -First 50)
        $pagefile = @()
        try { foreach ($pf in @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)) { $pagefile += [PSCustomObject]@{ name = $pf.Name; allocated_mb = $pf.AllocatedBaseSize; current_usage_mb = $pf.CurrentUsage; peak_usage_mb = $pf.PeakUsage } } } catch {}
        $psProfiles = @()
        try { foreach ($pp in $profilePaths) { if ($pp) { $exists = Test-Path $pp -ErrorAction SilentlyContinue; $sizeKb = if ($exists) { [math]::Round((Get-Item $pp -ErrorAction SilentlyContinue).Length / 1KB, 1) } else { $null }; $psProfiles += [PSCustomObject]@{ path = $pp; exists = $exists; size_kb = $sizeKb } } } } catch {}
        $memAvailGB = [math]::Round($memAvailMB / 1024, 1)
        $pagedPoolBytes = [double]$s['\MEMORY\POOL PAGED BYTES']
        if ($pagedPoolBytes -le 0 -or [double]::IsNaN($pagedPoolBytes)) {
            try { $pagedPoolBytes = [double](Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue).PoolPagedBytes } catch { $pagedPoolBytes = 0 }
        }
        $nonPagedBytes = [double]$s['\MEMORY\POOL NONPAGED BYTES']
        if ($nonPagedBytes -le 0 -or [double]::IsNaN($nonPagedBytes)) {
            try { $nonPagedBytes = [double](Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue).PoolNonpagedBytes } catch { $nonPagedBytes = 0 }
        }
        $pagedPoolMB = [math]::Round($pagedPoolBytes / 1MB, 2)
        $pagedPoolPct = if ($totalRAMMB -gt 0) { [math]::Round($pagedPoolMB / $totalRAMMB * 100, 1) } else { 0 }
        $nonPagedMB = [math]::Round($nonPagedBytes / 1MB, 0)
        $nonPagedPct = if ($totalRAMMB -gt 0) { [math]::Round($nonPagedMB / $totalRAMMB * 100, 1) } else { 0 }
        $insights = @()
        if ($memAvailMB -lt 1024) { $insights += "CRITICAL: Less than 1GB RAM available ($memAvailGB GB)." }
        elseif ($memAvailMB -lt 2048) { $insights += "Low available RAM ($memAvailGB GB)." }
        if ($commitPct -ge 90) { $insights += "Commit charge > 90%." }
        if ([double]$s['\MEMORY\PAGES/SEC'] -ge 1000) { $insights += "Heavy paging." }
        if ($nonPagedMB -ge 1500) { $insights += "Non-paged pool high ($nonPagedMB MB)." }
        if ($cpuPct -ge 90) { $insights += "CPU at $cpuPct%." }
        if ($browserGroup.count -gt 0 -and $browserGroup.ws_mb -gt 2000) { $insights += "Browsers: $($browserGroup.count) procs, ~$($browserGroup.ws_mb) MB." }
        if ($devGroup.count -gt 0 -and $devGroup.ws_mb -gt 1000) { $insights += "Dev tools: $($devGroup.count) procs, ~$($devGroup.ws_mb) MB." }
        if ($secGroup.count -gt 0 -and $secGroup.ws_mb -gt 500) { $insights += "Security: $($secGroup.count) procs, ~$($secGroup.ws_mb) MB." }
        if (-not $insights) { $insights += 'System healthy.' }
        $collectMs = [int](([DateTime]::UtcNow.Ticks - $t0) / 10000)
        $startup = @(Get-CimInstance Win32_StartupCommand -Property Name, Command, Location, User -ErrorAction SilentlyContinue)
        $data = @{
            ts = (Get-Date -Format 'HH:mm:ss'); hostname = $env:COMPUTERNAME; os_caption = $os.Caption; total_procs = $procs.Count; ram_pct = $ramPct
            ram_used_gb = [math]::Round($usedRAMMB / 1024, 2); ram_total_gb = [math]::Round($totalRAMMB / 1024, 2); ram_avail_mb = $memAvailMB
            commit_pct = $commitPct; commit_gb = [math]::Round($commitBytes / 1GB, 2); limit_gb = [math]::Round($commitLimitBytes / 1GB, 2)
            paged_pool_mb = $pagedPoolMB; paged_pool_pct = $pagedPoolPct; non_paged_mb = $nonPagedMB; non_paged_pct = $nonPagedPct
            pages_sec = [math]::Round([double]$s['\MEMORY\PAGES/SEC'], 2); page_reads_sec = [math]::Round([double]$s['\MEMORY\PAGE READS/SEC'], 2)
            cpu_pct = $cpuPct; cpu_queue = [math]::Round([double]$s['\SYSTEM\PROCESSOR QUEUE LENGTH'], 2)
            disk_pct = [math]::Round([double]$s['\PHYSICALDISK(_TOTAL)\% DISK TIME'], 1); disk_queue = [math]::Round([double]$s['\PHYSICALDISK(_TOTAL)\AVG. DISK QUEUE LENGTH'], 2)
            disk_read_mb = [math]::Round([double]$s['\PHYSICALDISK(_TOTAL)\DISK READ BYTES/SEC'] / 1MB, 2)
            disk_write_mb = [math]::Round([double]$s['\PHYSICALDISK(_TOTAL)\DISK WRITE BYTES/SEC'] / 1MB, 2)
            net_sent_kb = [math]::Round($netSentKB / 1KB, 1); net_recv_kb = [math]::Round($netRecvKB / 1KB, 1)
            top_ram = $by_ram; top_private = $by_private; top_cpu = $by_cpu; all_processes = $all_processes; suspicious = $suspicious
            disks = $disks; startup = $startup; pagefile = $pagefile; heavy_services = $heavyServices; ps_profiles = $psProfiles
            insights = $insights; gpu = $gpuResult; groups = @{ browser = $browserGroup; dev_tools = $devGroup; security = $secGroup }
            _perf_ms = $collectMs; _loading = $false
        }
        $attempts = 0
        while ($attempts -lt 3) {
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Depth 20 -Compress))
                $fs = [System.IO.File]::Open($cacheFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Close()
                break
            } catch {
                $attempts++
                Start-Sleep -Milliseconds 100
            }
        }
        $totalMs = [int](([DateTime]::UtcNow.Ticks - $t0) / 10000)
        if ($bgDebug) {
            if ($attempts -ge 3) { Write-Host "[BG DEBUG] Write FAILED after 3 attempts, rate=${bgRefreshRate}ms" -ForegroundColor Red }
            else { Write-Host "[BG DEBUG] Cycle done. collect=${collectMs}ms write=$([int](([DateTime]::UtcNow.Ticks - $t0)/10000 - $collectMs))ms total=${totalMs}ms rate=${bgRefreshRate}ms" -ForegroundColor Cyan }
        }
    } catch {
        if ($bgDebug) { Write-Host "[BG DEBUG] Cycle error: $_" -ForegroundColor Red }
        else { Write-Host "[BG] cycle error: $_" }
    }
}
'@
$bgScriptFile = Join-Path $env:TEMP "pcmon_bg_$(Get-Random).ps1"
$bgScriptContent | Out-File -FilePath $bgScriptFile -Encoding UTF8 -Force
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } elseif (Get-Command powershell -ErrorAction SilentlyContinue) { "powershell" } else { "powershell" }
$bgDebugFlag = if ($script:DebugMode) { "1" } else { "0" }
try {
    $null = Start-Process -FilePath $psExe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bgScriptFile, $cacheFile, $refreshRateFile, $profilePathsFile, $bgDebugFlag -PassThru -NoNewWindow
} catch {
    Write-Host "[pcmon] Warning: Background process failed to start: $_" -ForegroundColor Yellow
}

$script:LastBroadcast = [DateTime]::MinValue
$script:BroadcastInterval = 100

try {
    while ($listener.IsListening -and -not $script:shuttingDown) {
        try {
            $context = $listener.GetContext()
        } catch {
            if ($script:shuttingDown) { break }
            continue
        }
        $request = $context.Request
        $response = $context.Response
        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $path = $request.Url.LocalPath

        if ($path -eq "/health") {
            $ts = Get-Date -Format 'HH:mm:ss'
            $uptime = 0
            try { $uptime = [math]::Round((New-TimeSpan -Start $script:StartTime -End (Get-Date)).TotalSeconds) } catch {}
            $json = "{`"status`":`"ok`",`"ts`":`"$ts`",`"uptime_seconds`":$uptime}"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -eq "/errors") {
            $osCaption = if ($script:CachedStatic -and $script:CachedStatic.OS) { $script:CachedStatic.OS.Caption } else { 'Unknown' }
            $uptime = 0
            try { $uptime = [math]::Round((New-TimeSpan -Start $script:StartTime -End (Get-Date)).TotalSeconds) } catch {}
            $lastErrors = @()
            if ($script:Errors.Count -gt 0) { $lastErrors = @($script:Errors)[-20..-1] }
            $errList = ($lastErrors | Where-Object { $_ -is [string] -and $_ -ne "" } | ForEach-Object { '"' + $_.Replace('\','\\').Replace('"','\"') + '"' } | Join-String -Separator ',')
            if ($errList -eq "") { $errList = "[]" } else { $errList = "[$errList]" }
            $errJson = "{`"error_count`":$($script:Errors.Count),`"uptime`":$uptime,`"errors`":$errList,`"sysinfo`":{`"ps_version`":`"$($PSVersionTable.PSVersion.ToString())`",`"os`":`"$osCaption`",`"hostname`":`"$env:COMPUTERNAME`"}}"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($errJson)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -eq "/logs") {
            $buffer = [System.Text.Encoding]::UTF8.GetBytes(($script:Errors -join "`n"))
            Send-Response $response $buffer "text/plain"
        }
        elseif ($path -eq "/debug") {
            $staticFileCount = 0
            try { $staticFileCount = [int](@($script:StaticFiles.Keys).Count) } catch {}
            $wsClientCount = 0
            try { $wsClientCount = [int]$script:WSClients.Count } catch {}
            $connMethod = ""
            try { $connMethod = [string]$script:ConnectionMethod } catch {}
            $bcastMs = 0
            try { $bcastMs = [int]$script:WSBroadcastInterval } catch {}
            $cacheExpiry = ""
            try { $cacheExpiry = [string]$script:StaticCacheExpiry.ToString('o') } catch {}
            $startTime = [string](Get-Date).ToString('o')
            $json = "{`"start_time`":`"$startTime`",`"cache_expiry`":`"$cacheExpiry`",`"cached_services_count`":$(@($script:CachedStatic.Services).Count),`"cached_drives_count`":$(@($script:CachedStatic.Drives).Count),`"commandlines_cached`":$($script:CommandLines.Count),`"static_files`":$staticFileCount,`"ws_clients`":$wsClientCount,`"connection_method`":`"$connMethod`",`"broadcast_interval_ms`":$bcastMs}"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -eq "/data") {
            $data = Get-LiveData
            if ($null -eq $data) { $data = _CollectLiveData }
            $json = $data | ConvertTo-Json -Depth 20 -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -match '^/api/snapshots$' -and $request.HttpMethod -eq "GET") {
            $files = Get-SnapshotFiles
            $list = @($files | ForEach-Object {
                try {
                    $content = Get-Content $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    @{ id = $content.id; ts = $content.ts; label = $content.label; filename = $_.Name }
                } catch { $null }
            } | Where-Object { $_ })
            $json = if ($list) { $list | ConvertTo-Json -Compress } else { '[]' }
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
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
            Send-Response $response $buffer "application/json"
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
                Send-Response $response $buffer
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
            Send-Response $response $buffer "application/json"
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
                Send-Response $response $buffer
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
                Send-Response $response $buffer "text/csv" "attachment; filename=`"$filename`""
            } else {
                $response.StatusCode = 404
                $response.ContentLength64 = 0
            }
        }
        elseif ($path -match '^/api/snapshots/([^/]+)/delete$' -and $request.HttpMethod -eq "POST") {
            $snapId = $matches[1]
            $files = Get-SnapshotFiles
            $snapshotFile = $files | Where-Object { $_.BaseName -eq "snapshot_$snapId" } | Select-Object -First 1
            if ($snapshotFile) {
                try {
                    Remove-Item $snapshotFile.FullName -Force -ErrorAction Stop
                    $json = @{ success = $true } | ConvertTo-Json -Compress
                } catch {
                    $json = @{ success = $false; error = "Failed to delete" } | ConvertTo-Json -Compress
                }
            } else {
                $json = @{ success = $false; error = "Snapshot not found" } | ConvertTo-Json -Compress
            }
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -match '^/api/process/(\d+)/kill$' -and $request.HttpMethod -eq "POST") {
            if ($request.Headers.Get("X-PCMON-Confirm") -ne "1") {
                $response.StatusCode = 403
                $response.ContentLength64 = 0
                Send-Response $response $null "application/json"
                continue
            }
            $pid = [int]$matches[1]
            $result = Stop-ProcessById -ProcessId $pid -Force
            $json = $result | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -match '^/api/process/(\d+)/suspend$' -and $request.HttpMethod -eq "POST") {
            if ($request.Headers.Get("X-PCMON-Confirm") -ne "1") {
                $response.StatusCode = 403
                $response.ContentLength64 = 0
                Send-Response $response $null "application/json"
                continue
            }
            $pid = [int]$matches[1]
            $result = Suspend-ProcessById -ProcessId $pid
            $json = $result | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -match '^/api/process/(\d+)/resume$' -and $request.HttpMethod -eq "POST") {
            if ($request.Headers.Get("X-PCMON-Confirm") -ne "1") {
                $response.StatusCode = 403
                $response.ContentLength64 = 0
                Send-Response $response $null "application/json"
                continue
            }
            $pid = [int]$matches[1]
            $result = Resume-ProcessById -ProcessId $pid
            $json = $result | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -eq "/api/report") {
            if (Test-Path $cacheFile) {
                try { $data = Get-Content $cacheFile -Raw | ConvertFrom-Json } catch { $data = Get-LiveData }
            } else { $data = Get-LiveData }
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
            Send-Response $response $buffer "text/html; charset=utf-8"
        }
        elseif ($path -eq "/api/report/download") {
            if (Test-Path $cacheFile) {
                try { $data = Get-Content $cacheFile -Raw | ConvertFrom-Json } catch { $data = Get-LiveData }
            } else { $data = Get-LiveData }
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
            Send-Response $response $buffer "text/html; charset=utf-8" "attachment; filename=`"$filename`""
        }
        elseif ($path -eq "/api/config" -and $request.HttpMethod -eq "GET") {
            $json = $script:AlertThresholds | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
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
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -eq "/api/bootstrap") {
            $json = @{
                csrf_token = [guid]::NewGuid().ToString()
                thresholds = $script:AlertThresholds
            } | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -eq "/api/refresh-rate" -and $request.HttpMethod -eq "POST") {
            try {
                $body = [System.IO.StreamReader]::new($request.InputStream).ReadToEnd()
                if ($body) {
                    $parsed = $body | ConvertFrom-Json
                    if ($parsed.rate -and $parsed.rate -ge 500 -and $parsed.rate -le 10000) {
                        $parsed.rate | Out-File -FilePath $refreshRateFile -Encoding UTF8 -Force
                        $json = @{ success = $true; rate = $parsed.rate } | ConvertTo-Json -Compress
                    } else {
                        $json = @{ success = $false; error = "Rate must be between 500ms and 10000ms" } | ConvertTo-Json -Compress
                    }
                } else {
                    $json = @{ success = $false; error = "Empty body" } | ConvertTo-Json -Compress
                }
            } catch {
                $json = @{ success = $false; error = "Invalid request" } | ConvertTo-Json -Compress
            }
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -eq "/api/info" -and $request.HttpMethod -eq "GET") {
            $uptime = 0
            try { $uptime = [math]::Round((New-TimeSpan -Start $script:StartTime -End (Get-Date)).TotalSeconds) } catch {}
            $conn = ""
            try { $conn = [string]$script:ConnectionMethod } catch {}
            $wsCount = 0
            try { $wsCount = [int]$script:WSClients.Count } catch {}
            $info = "{`"method`":`"$conn`",`"uptime`":$uptime,`"ws_clients`":$wsCount,`"ps_version`":`"$($PSVersionTable.PSVersion.ToString())`",`"hostname`":`"$env:COMPUTERNAME`"}"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($info)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -eq "/stream" -and $request.HttpMethod -eq "GET") {
            $upgrade = $request.Headers.Get("Upgrade")
            $secWebSocketKey = $request.Headers.Get("Sec-WebSocket-Key")
            
            if ($secWebSocketKey) {
                try {
                    $wsContext = $context.AcceptWebSocketAsync($null)
                    if ($wsContext.Result) {
                        $script:ConnectionMethod = "websocket"
                        $script:WSClients.Add($wsContext.Result.WebSocket)
                        $buffer = [byte[]]::new(4096)
                        while ($wsContext.Result.WebSocket.State -eq 'Open' -and -not $script:shuttingDown) {
                            Start-Sleep -Milliseconds 50
                        }
                        $script:WSClients.Remove($wsContext.Result.WebSocket)
                    }
                } catch {
                    $script:ConnectionMethod = "sse"
                }
            } else {
                try {
                    $response.ContentType = "text/event-stream"
                    $response.Headers.Add("Cache-Control", "no-cache")
                    $response.Headers.Add("Connection", "keep-alive")
                    $response.Headers.Add("Access-Control-Allow-Origin", "*")
                    $script:ConnectionMethod = "sse"
                    while ($listener.IsListening -and -not $script:shuttingDown) {
                        try {
                            if (Test-Path $cacheFile) {
                                $fi = Get-Item $cacheFile -ErrorAction SilentlyContinue
                                if ($fi) {
                                    $data = Get-Content $cacheFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                                    if ($data) {
                                        $json = $data | ConvertTo-Json -Depth 20 -Compress
                                        $payload = [System.Text.Encoding]::UTF8.GetBytes("data: $json`n`n")
                                        try { $response.OutputStream.Write($payload, 0, $payload.Length); $response.OutputStream.Flush() } catch { break }
                                    }
                                }
                            }
                            Start-Sleep -Milliseconds 50
                        } catch { break }
                    }
                } catch { if ($script:DebugMode) { Write-Log "SSE error: $($_.Exception.Message)" "DEBUG" } }
                $response.StatusCode = 200
            }
            $response.Close()
        }
        elseif ($path -eq "/" -or $path -eq "/index.html") {
            $sf = $script:StaticFiles['index.html']
            if ($sf) { Send-Response $response $sf.data $sf.type } else { $response.StatusCode = 404; $response.ContentLength64 = 0 }
        }
        elseif ($path -match '^/dashboard\.css$') {
            $sf = $script:StaticFiles['dashboard.css']
            if ($sf) { Send-Response $response $sf.data $sf.type } else { $response.StatusCode = 404; $response.ContentLength64 = 0 }
        }
        elseif ($path -eq "/wallpaper.html") {
            $sf = $script:StaticFiles['wallpaper.html']
            if ($sf) { Send-Response $response $sf.data $sf.type } else { $response.StatusCode = 404; $response.ContentLength64 = 0 }
        }
        else {
            $response.StatusCode = 404
            $response.ContentLength64 = 0
        }

        $response.Close()
    }
} catch {
    Write-Host "[CRASH] $_" -ForegroundColor Red
    Write-Host "[CRASH] Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
}

$shuttingDown = $false
Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
    $script:shuttingDown = $true
    $listener.Stop()
    Write-Host ""
    Write-Host "[pcmon] Stopped." -ForegroundColor Yellow
} | Out-Null
#endregion


