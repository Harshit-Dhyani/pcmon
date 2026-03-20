#region --- CLI Parameters ---
param(
    [switch]$NoOpen,
    [switch]$ApiOnly,
    [switch]$Wallpaper,
    [int]$Port = 9876,
    [switch]$Help
)

if ($Help) {
    @"
pcmon - Local-first Windows system monitoring and diagnostics

Usage:
    .\pcmon.ps1 [-NoOpen] [-ApiOnly] [-Wallpaper] [-Port <int>] [-Help]

Options:
    -NoOpen      Start the server without opening the browser (API-only mode)
    -ApiOnly     Same as -NoOpen
    -Wallpaper   Start live wallpaper engine (full HUD wallpaper)
    -Port <int>  Port to listen on (default: 9876)
    -Help        Show this help message

Examples:
    .\pcmon.ps1                    Standard mode, opens browser automatically
    .\pcmon.ps1 -NoOpen            API-only, browser stays closed
    .\pcmon.ps1 -Wallpaper         Live wallpaper engine
    .\pcmon.ps1 -Wallpaper -NoOpen Start wallpaper without opening browser
    .\pcmon.ps1 -Port 8080         Custom port

Requirements:
    - Windows with PowerShell 5.1+ or PowerShell Core (pwsh)
    - Web browser for the dashboard

"@
    exit 0
}
#endregion

#region --- Setup ---
$ErrorActionPreference = "Continue"
$script:ErrorCount = 0
$HOSTNAME = "localhost"
$OPEN_BROWSER = -not ($NoOpen -or $ApiOnly)
$WALLPAPER_MODE = $Wallpaper
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$WEB_DIR = Join-Path $SCRIPT_DIR "web"
$LOG_FILE = Join-Path $env:TEMP "pcmon_errors.log"

$script:StartTime = Get-Date
$script:CachedStatic = $null
$script:StaticCacheExpiry = [DateTime]::MinValue
$script:StaticFiles = @{}
$script:CachedVideo = $null
$script:CommandLines = @{}
$script:ProcessCache = @()
$script:ProcessCacheTime = [DateTime]::MinValue
$script:Errors = @()
$SNAPSHOTS_DIR = Join-Path $SCRIPT_DIR "snapshots"
if (-not (Test-Path $SNAPSHOTS_DIR)) { New-Item -ItemType Directory -Path $SNAPSHOTS_DIR -Force | Out-Null }
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

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Wallpaper {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@

$global:LAST_ERROR = $null
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

function Set-WallpaperImage {
    param([string]$HtmlPath)
    $wallpaperPath = Join-Path $env:TEMP "pcmon_wallpaper.html"
    Copy-Item $HtmlPath $wallpaperPath -Force
    [Wallpaper]::SystemParametersInfo(0x0014, 0, $wallpaperPath, 0x0001 -bor 0x0002)
}

function Get-LiveData {
    Get-CachedStaticData
    $cs = $script:CachedStatic

    $allCounterPaths = @(
        '\Memory\Available MBytes','\Memory\Committed Bytes','\Memory\Commit Limit',
        '\Memory\Pool Paged Bytes','\Memory\Pool Nonpaged Bytes','\Memory\Pages/sec',
        '\Memory\Page Reads/sec','\Processor(_Total)\% Processor Time',
        '\System\Processor Queue Length','\PhysicalDisk(_Total)\% Disk Time',
        '\PhysicalDisk(_Total)\Avg. Disk Queue Length','\PhysicalDisk(_Total)\Disk Read Bytes/sec',
        '\PhysicalDisk(_Total)\Disk Write Bytes/sec','\Network Interface(*)\Bytes Sent/sec',
        '\Network Interface(*)\Bytes Received/sec','\GPU Adapter Memory(*)\Dedicated Usage',
        '\GPU Engine(*)\Utilization Percentage'
    )

    $samples = @()
    try {
        $counters = Get-Counter $allCounterPaths -ErrorAction SilentlyContinue
        if ($counters) { $samples = $counters.CounterSamples }
    } catch { 
        $script:ErrorCount++
        Write-Err "Get-Counter failed: $_"
    }

    $os = $cs.OS
    $s = @{}
    foreach ($sample in $samples) { $s[$sample.Path] = $sample.CookedValue }

    $memAvailMB = [math]::Round($s['Available MBytes'], 2)
    $commitBytes = $s['Committed Bytes']
    $commitLimitBytes = $s['Commit Limit']
    $pagedPoolBytes = $s['Pool Paged Bytes']
    $nonPagedBytes = $s['Pool Nonpaged Bytes']
    $pagesSec = [math]::Round($s['Pages/sec'], 2)
    $pageReadsSec = [math]::Round($s['Page Reads/sec'], 2)
    $cpuPct = [math]::Round($s['% Processor Time'], 1)
    $cpuQueue = [math]::Round($s['Processor Queue Length'], 2)
    $diskPct = [math]::Round($s['% Disk Time'], 1)
    $diskQueue = [math]::Round($s['Avg. Disk Queue Length'], 2)
    $diskReadMB = [math]::Round($s['Disk Read Bytes/sec'] / 1MB, 2)
    $diskWriteMB = [math]::Round($s['Disk Write Bytes/sec'] / 1MB, 2)
    $netSentKB = 0; $netRecvKB = 0
    foreach ($k in $s.Keys) {
        if ($k -like '*Bytes Sent*') { $netSentKB += $s[$k] }
        if ($k -like '*Bytes Received*') { $netRecvKB += $s[$k] }
    }
    $netSentKB = [math]::Round($netSentKB / 1KB, 1)
    $netRecvKB = [math]::Round($netRecvKB / 1KB, 1)

    $totalRAMMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
    $usedRAMMB = $totalRAMMB - $memAvailMB
    $ramPct = if ($totalRAMMB -gt 0) { [math]::Round(($usedRAMMB / $totalRAMMB) * 100, 1) } else { 0 }
    $commitGB = [math]::Round($commitBytes / 1GB, 2)
    $commitLimitGB = [math]::Round($commitLimitBytes / 1GB, 2)
    $commitPct = if ($commitLimitBytes -gt 0) { [math]::Round(($commitBytes / $commitLimitBytes) * 100, 1) } else { 0 }

    $processes = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{ name = $_.ProcessName; pid = $_.Id; ws_mb = [math]::Round($_.WorkingSet64 / 1MB, 1); private_mb = [math]::Round($_.PrivateMemorySize64 / 1MB, 1); cpu_s = [math]::Round($_.CPU, 1); threads = $_.Threads.Count; handles = $_.Handles; path = try { $_.Path } catch {} }
    })

    $by_ram = @($processes | Sort-Object ws_mb -Descending | Select-Object -First 80)
    $by_private = @($processes | Sort-Object private_mb -Descending | Select-Object -First 80)
    $by_cpu = @($processes | Sort-Object cpu_s -Descending | Select-Object -First 50)

    $susPattern = 'node|bun|msedge|arc|chrome|webstorm|code|chatgpt|codex|opencode|java|python|electron|pieces|os-server|slack|discord|msmpeng|malware|mbam|glasswire|portmaster|vmware|nvidia'
    $browserPattern = 'msedge|arc|chrome|opera|brave|firefox|electron|librewolf'
    $devPattern = 'node|bun|python|java|code|webstorm|rider|idea|pycharm|goland|datagrip|phpstorm|ruby|rust|cargo|opencode|codex|chatgpt|pieces|os-server'
    $secPattern = 'msmpeng|malware|mbam|glasswire|portmaster|defender|avast|kaspersky|bitdefender|eset'

    $suspicious = @($processes | Where-Object { $_.name.ToLowerInvariant() -match $susPattern } | Sort-Object ws_mb -Descending)

    $browserGroup = @{ ws_mb = 0; count = 0 }
    $devGroup = @{ ws_mb = 0; count = 0 }
    $secGroup = @{ ws_mb = 0; count = 0 }
    foreach ($p in $processes) {
        $n = $p.name.ToLowerInvariant()
        if ($n -match $browserPattern) { $browserGroup.ws_mb += $p.ws_mb; $browserGroup.count++ }
        if ($n -match $devPattern) { $devGroup.ws_mb += $p.ws_mb; $devGroup.count++ }
        if ($n -match $secPattern) { $secGroup.ws_mb += $p.ws_mb; $secGroup.count++ }
    }
    $browserGroup.ws_mb = [math]::Round($browserGroup.ws_mb, 1)
    $devGroup.ws_mb = [math]::Round($devGroup.ws_mb, 1)
    $secGroup.ws_mb = [math]::Round($secGroup.ws_mb, 1)

    $topPids = @($by_ram | Select-Object -First 20 -ExpandProperty pid)
    $heavyServices = @($cs.Services | Where-Object { $topPids -contains $_.ProcessId })

    Get-CachedCommandLines -Pids $topPids
    $topPrivateWithCmd = @($by_private | Select-Object -First 20 | ForEach-Object {
        [PSCustomObject]@{ name = $_.name; pid = $_.pid; ws_mb = $_.ws_mb; private_mb = $_.private_mb; cpu_s = $_.cpu_s; commandLine = $script:CommandLines[$_.pid] }
    })

    $adapters = $cs.Video
    $gpuResult = @{ available = $false; adapters = @(); eng_type_totals = @{ '3d' = 0; 'videodecode' = 0; 'videoprocessing' = 0; 'copy' = 0; 'videoencode' = 0; 'security' = 0; 'vr' = 0; 'other' = 0 }; eng_type_count = @{ '3d' = 0; 'videodecode' = 0; 'videoprocessing' = 0; 'copy' = 0; 'videoencode' = 0; 'security' = 0; 'vr' = 0; 'other' = 0 }; dedicated_used_gb = 0; dedicated_total_gb = 0 }
    $memSamples = @($samples | Where-Object { $_.Path -like '*GPU*Adapter*Memory*Dedicated*Usage*' })
    $engSamples = @($samples | Where-Object { $_.Path -like '*GPU*Engine*Utilization*Percentage*' })
    foreach ($adapter in $adapters) {
        $escapedName = [regex]::Escape($adapter.Name)
        $dedBytes = 0
        foreach ($sm in $memSamples) { if ($sm.Path -match $escapedName -and $sm.CookedValue -gt $dedBytes) { $dedBytes = $sm.CookedValue } }
        $totalGB = if ($adapter.AdapterRAM -and $adapter.AdapterRAM -gt 0) { [math]::Round($adapter.AdapterRAM / 1GB, 1) } else { 0 }
        $dedGB = [math]::Round($dedBytes / 1GB, 2)
        $gpuResult.adapters += @{ name = $adapter.Name; status = $adapter.Status; dedicated_gb = $dedGB; total_gb = $totalGB; pct = if ($totalGB -gt 0) { [math]::Round(($dedGB / $totalGB) * 100, 1) } else { 0 } }
        $gpuResult.dedicated_used_gb += $dedGB
        $gpuResult.dedicated_total_gb += $totalGB
    }
    foreach ($sm in $engSamples) {
        $val = $sm.CookedValue
        if ($null -eq $val -or $val -eq 0) { continue }
        $type = 'other'
        switch -Regex ($sm.Path) { 'engtype_3d' { $type = '3d' } 'engtype_videodecode' { $type = 'videodecode' } 'engtype_videoprocessing' { $type = 'videoprocessing' } 'engtype_copy' { $type = 'copy' } 'engtype_videoencode' { $type = 'videoencode' } 'engtype_security' { $type = 'security' } 'engtype_vr' { $type = 'vr' } }
        $gpuResult.eng_type_totals[$type] += $val
        $gpuResult.eng_type_count[$type]++
    }
    $gpuResult.available = $gpuResult.adapters.Count -gt 0

    $insights = @()
    if ($ramPct -ge 85) { $insights += 'High physical RAM usage.' }
    if ($commitPct -ge 80) { $insights += 'Commit charge is high; system is overcommitted.' }
    if ($pagesSec -ge 100) { $insights += 'Heavy paging detected; disk thrash likely.' }
    if ($nonPagedBytes / 1MB -ge 1500) { $insights += 'Non-paged pool is abnormally high; possible driver or security tool leak.' }
    if ($diskPct -ge 90) { $insights += 'Disk is saturated.' }
    if ($cpuPct -ge 90) { $insights += 'CPU is near max; application may be CPU-bound.' }
    if ($diskQueue -gt 8) { $insights += "Disk queue is elevated ($([math]::Round($diskQueue, 1)))." }
    if ($gpuResult.available -and $gpuResult.dedicated_total_gb -gt 0) {
        $gpPct = [math]::Round(($gpuResult.dedicated_used_gb / $gpuResult.dedicated_total_gb) * 100, 0)
        if ($gpPct -ge 90) { $insights += "GPU memory is nearly full ($gpPct% of dedicated VRAM used)." }
        elseif ($gpPct -ge 75) { $insights += "GPU memory usage is high ($gpPct% of dedicated VRAM)." }
    }
    if ($browserGroup.count -gt 0 -and $browserGroup.ws_mb -gt 2000) { $insights += "Browser/Electron group is heavy: $($browserGroup.count) procs, ~$($browserGroup.ws_mb) MB WS." }
    if ($devGroup.count -gt 0 -and $devGroup.ws_mb -gt 1000) { $insights += "Dev tooling group is heavy: $($devGroup.count) procs, ~$($devGroup.ws_mb) MB WS." }
    if ($secGroup.count -gt 0 -and $secGroup.ws_mb -gt 500) { $insights += "Security tool group is present: $($secGroup.count) procs, ~$($secGroup.ws_mb) MB WS." }
    if (-not $insights) { $insights += 'No critical pressure right now.' }

    $disks = @($cs.Drives | ForEach-Object {
        $used = $_.Size - $_.FreeSpace
        $pct = if ($_.Size -gt 0) { [math]::Round(($used / $_.Size) * 100, 1) } else { 0 }
        [PSCustomObject]@{ drive = $_.DeviceID; label = $_.VolumeName; fs = $_.FileSystem; total_gb = [math]::Round($_.Size / 1GB, 1); used_gb = [math]::Round($used / 1GB, 1); free_gb = [math]::Round($_.FreeSpace / 1GB, 1); pct = $pct; state = if ($pct -ge 90) { 'bad' } elseif ($pct -ge 80) { 'warn' } else { 'ok' } }
    })

    $profiles = @()
    foreach ($p in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost, $PROFILE.AllUsersAllHosts, $PROFILE.AllUsersCurrentHost) | Select-Object -Unique) {
        $exists = Test-Path $p
        $sizeKb = 0
        if ($exists) { try { $sizeKb = [math]::Round((Get-Item $p).Length / 1KB, 2) } catch {} }
        $profiles += [PSCustomObject]@{ path = $p; exists = $exists; size_kb = $sizeKb }
    }

    $pageFile = @()
    try { $pageFile = @(Get-CimInstance Win32_PageFileUsage -Property Name, AllocatedBaseSize, CurrentUsage, PeakUsage, TempPageFile) } catch {}

    return @{
        ts = (Get-Date -Format 'HH:mm:ss'); hostname = $env:COMPUTERNAME; os_caption = $os.Caption; total_procs = $processes.Count; ram_pct = $ramPct
        ram_used_gb = [math]::Round($usedRAMMB / 1024, 2); ram_total_gb = [math]::Round($totalRAMMB / 1024, 2); ram_avail_mb = $memAvailMB
        commit_pct = $commitPct; commit_gb = $commitGB; limit_gb = $commitLimitGB
        paged_pool_mb = [math]::Round($pagedPoolBytes / 1MB, 2); non_paged_mb = [math]::Round($nonPagedBytes / 1MB, 2)
        pages_sec = $pagesSec; page_reads_sec = $pageReadsSec
        cpu_pct = $cpuPct; cpu_queue = $cpuQueue; disk_pct = $diskPct; disk_queue = $diskQueue
        disk_read_mb = $diskReadMB; disk_write_mb = $diskWriteMB; net_sent_kb = $netSentKB; net_recv_kb = $netRecvKB
        top_ram = $by_ram; top_private = $by_private; top_cpu = $by_cpu; suspicious = $suspicious
        disks = $disks; startup = $cs.Startup; pagefile = $pageFile; heavy_services = $heavyServices; ps_profiles = $profiles
        insights = $insights; gpu = $gpuResult; groups = @{ browser = $browserGroup; dev_tools = $devGroup; security = $secGroup }
    }
}
#endregion

#region --- HTTP Server ---
$modeLabel = if ($ApiOnly) { "API-Only" } elseif ($WALLPAPER_MODE) { "Wallpaper" } else { "Dashboard" }
$browserLabel = if ($OPEN_BROWSER) { "Auto-open" } else { "No browser" }

Write-Host ""
Write-Host "  =========================================" -ForegroundColor DarkGray
Write-Host "   $([char]0x1B)[92mPCMON v1.0$([char]0x1B)[0m  $([char]0x1B)[96m$modeLabel$([char]0x1B)[0m" -NoNewline; Write-Host ""
Write-Host "   $([char]0x1B)[2m  Local-first Windows system monitor$([char]0x1B)[0m"
Write-Host "  =========================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Port      : $([char]0x1B)[93m$Port$([char]0x1B)[0m" -NoNewline; Write-Host "    Browser : $browserLabel"
Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
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
Write-Host "  $base/health"
Write-Host "  $base/errors"
Write-Host "  $base/debug"
Write-Host "  $base/logs"
if ($WALLPAPER_MODE) {
    Write-Host "  $base/wallpaper"
}
Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
Write-Host "  Stop      : $([char]0x1B)[93mCtrl+C$([char]0x1B)[0m" -NoNewline; Write-Host ""
Write-Host ""

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://${HOSTNAME}:$Port/")
$listener.TimeoutManager.RequestQueue = New-Object System.TimeSpan(0, 2, 0)

foreach ($f in @('index.html', 'dashboard.css', 'dashboard.js')) {
    $fp = Join-Path $WEB_DIR $f
    if (Test-Path $fp) { $script:StaticFiles[$f] = @{ data = [System.IO.File]::ReadAllBytes($fp); type = if ($f -like '*.css') { 'text/css' } elseif ($f -like '*.js') { 'application/javascript' } else { 'text/html; charset=utf-8' } } }
}

try {
    $listener.Start()
} catch {
    Write-Host "[pcmon] Failed to start on port $Port. Is something already using it?" -ForegroundColor Red
    exit 1
}

if ($OPEN_BROWSER -or $WALLPAPER_MODE) { 
    if ($WALLPAPER_MODE) {
        $url = "http://${HOSTNAME}:$Port/wallpaper"
        $script = "var win=window.open('$url','pcmon_wallpaper','width=320,height=600,alwaysRaised=1,toolbar=0,menubar=0,location=0,status=0,resizable=0');win.moveTo(screen.width-340,20);win.focus();"
        Start-Process "msedge.exe","--app=$url --window-size=320,600 --window-position=$(1920-340),20"
    } else {
        Start-Process "http://${HOSTNAME}:$Port"
    }
}

Get-CachedStaticData

try {
    while ($listener.IsListening) {
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
        elseif ($path -eq "/wallpaper") {
            $data = Get-LiveData
            $ramPct = [math]::Round($data.ram_pct)
            $cpuPct = [math]::Round($data.cpu_pct)
            $ramUsed = [math]::Round($data.ram_used_gb, 1)
            $ramTotal = [math]::Round($data.ram_total_gb, 1)
            $ts = $data.ts
            $hostname = $data.hostname
            $totalProcs = $data.total_procs
            $gpu3d = 0
            $gpuSection = ""
            if ($data.gpu.available) {
                $gpu3d = [math]::Round($data.gpu.eng_type_totals.'3d')
                $gpuSection = "<div class=stat><span class=stat-label>GPU</span><span class=stat-value>" + $gpu3d + "%</span></div><div class=bar><div style=width:" + $gpu3d + "%></div></div>"
            }
            $procs = ($data.top_ram | Select-Object -First 5 | ForEach-Object { "<div class=process><span>" + $_.name + "</span><span>" + [math]::Round($_.ws_mb) + " MB</span></div>" }) -join ""
            $diskR = [math]::Round($data.disk_read_mb, 1)
            $diskW = [math]::Round($data.disk_write_mb, 1)
            $netS = [math]::Round($data.net_sent_kb)
            $netR = [math]::Round($data.net_recv_kb)
            $html = "<!DOCTYPE html><html><head><meta http-equiv=""refresh"" content=""2""><style>*{margin:0;padding:0}body{background:#000;color:#0f0;font-family:monospace;font-size:12px;padding:10px}.h{background:#111;padding:8px;margin:-10px -10px 10px}.logo{color:#0f0;font-weight:bold}.t{color:#888;font-size:10px}.s{padding:4px 0;border-bottom:1px solid #222;display:flex;justify-content:space-between}.l{color:#888;font-size:10px}.v{font-size:16px;font-weight:bold;color:#0f0}.b{height:3px;background:#222;margin:2px 0 8px}.b div{height:100%;background:#0f0}.p{font-size:10px;padding:2px 0;display:flex;justify-content:space-between}.p span:first-child{max-width:100px;overflow:hidden}.p span:last-child{color:#888}.f{margin-top:10px;font-size:9px;color:#555}</style></head><body><div class=h><span class=logo>PCMON</span> <span class=t>" + $ts + "</span></div><div class=s><span class=l>CPU</span><span class=v>" + $cpuPct + "%</span></div><div class=b><div style=width:" + $cpuPct + "%></div></div><div class=s><span class=l>RAM</span><span class=v>" + $ramUsed + " / " + $ramTotal + " GB</span></div><div class=b><div style=width:" + $ramPct + "%></div></div>" + $gpuSection + "<div class=t>Top</div>" + $procs + "<div class=t>I/O: " + $diskR + "/" + $diskW + " MB/s | " + $netS + "/" + $netR + " KB/s</div><div class=f>" + $hostname + " | " + $totalProcs + " procs</div></body></html>"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
            $response.ContentType = "text/html"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        else {
            $response.StatusCode = 404
            $response.ContentLength64 = 0
        }

        $response.Close()
    }
} catch {
    Write-Log "HTTP handler error: $_"
} finally {
    $listener.Stop()
    Write-Host ""
    Write-Host "[pcmon] Stopped." -ForegroundColor Yellow
}
#endregion


