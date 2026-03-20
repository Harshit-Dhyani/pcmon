param(
    [switch]$NoOpen,
    [switch]$ApiOnly,
    [int]$Port = 9876,
    [switch]$Help
)

if ($Help) {
    @"
pcmon - Local-first Windows system monitoring and diagnostics

Usage:
    .\pcmon.ps1 [-NoOpen] [-ApiOnly] [-Port <int>] [-Help]

Options:
    -NoOpen      Start the server without opening the browser (API-only mode)
    -ApiOnly     Same as -NoOpen
    -Port <int>  Port to listen on (default: 9876)
    -Help        Show this help message

Examples:
    .\pcmon.ps1                    Standard mode, opens browser automatically
    .\pcmon.ps1 -NoOpen            API-only, browser stays closed
    .\pcmon.ps1 -Port 8080         Custom port
    .\pcmon.ps1 -NoOpen -Port 9000 API-only on port 9000

Requirements:
    - Windows with PowerShell 5.1+ or PowerShell Core (pwsh)
    - Web browser for the dashboard

"@
    exit 0
}

$ErrorActionPreference = "Continue"
$script:ErrorCount = 0
$HOSTNAME = "localhost"
$OPEN_BROWSER = -not ($NoOpen -or $ApiOnly)
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$WEB_DIR = Join-Path $SCRIPT_DIR "web"
$MAX_HISTORY = 90

function Convert-ToMB([double]$bytes) {
    return [math]::Round($bytes / 1MB, 2)
}

function Convert-ToGB([double]$bytes) {
    return [math]::Round($bytes / 1GB, 2)
}

function Get-SafeCounterValue {
    param(
        [Parameter(Mandatory=$true)]
        [array]$Samples,
        [Parameter(Mandatory=$true)]
        [string]$Pattern,
        [switch]$Sum
    )
    $matches = $Samples | Where-Object { $_.Path -like "*$Pattern*" }
    if (-not $matches) { return 0 }
    if ($Sum) {
        return [double](($matches | Measure-Object CookedValue -Sum).Sum)
    }
    return [double]($matches | Select-Object -First 1).CookedValue
}

function Get-ThresholdState {
    param([double]$Value, [double]$Warn, [double]$Bad)
    if ($Value -ge $Bad) { return "bad" }
    if ($Value -ge $Warn) { return "warn" }
    return "ok"
}

function Get-DriveSnapshot {
    Get-CimInstance Win32_LogicalDisk |
        Where-Object { $_.DriveType -eq 3 } |
        ForEach-Object {
            $used = $_.Size - $_.FreeSpace
            $pct = if ($_.Size -gt 0) { [math]::Round(($used / $_.Size) * 100, 1) } else { 0 }
            [PSCustomObject]@{
                drive     = $_.DeviceID
                label     = $_.VolumeName
                fs        = $_.FileSystem
                total_gb  = [math]::Round($_.Size / 1GB, 1)
                used_gb   = [math]::Round($used / 1GB, 1)
                free_gb   = [math]::Round($_.FreeSpace / 1GB, 1)
                pct       = $pct
                state     = Get-ThresholdState -Value $pct -Warn 80 -Bad 90
            }
        }
}

function Get-TopProcesses {
    $processes = Get-Process | ForEach-Object {
        $path = $null
        try { $path = $_.Path } catch { $script:ErrorCount++ }
        [PSCustomObject]@{
            name       = $_.ProcessName
            pid        = $_.Id
            ws_mb      = [math]::Round($_.WS / 1MB, 1)
            private_mb = [math]::Round($_.PrivateMemorySize64 / 1MB, 1)
            paged_mb   = [math]::Round($_.PagedMemorySize64 / 1MB, 1)
            virtual_mb = [math]::Round($_.VirtualMemorySize64 / 1MB, 1)
            cpu_s      = [math]::Round($_.CPU, 1)
            threads    = $_.Threads.Count
            handles    = $_.Handles
            path       = $path
        }
    }
    return @{
        all        = @($processes)
        by_ram     = @($processes | Sort-Object ws_mb -Descending | Select-Object -First 80)
        by_private = @($processes | Sort-Object private_mb -Descending | Select-Object -First 80)
        by_cpu     = @($processes | Sort-Object cpu_s -Descending | Select-Object -First 50)
        count      = $processes.Count
    }
}

function Get-SuspiciousBuckets {
    param([array]$Processes)
    $patterns = @(
        'node', 'bun', 'msedge', 'arc', 'chrome', 'webstorm', 'code', 'chatgpt', 'codex',
        'opencode', 'java', 'python', 'electron', 'pieces', 'os-server', 'slack', 'discord',
        'msmpeng', 'malware', 'mbam', 'glasswire', 'portmaster', 'vmware', 'nvidia'
    )
    return @($Processes | Where-Object {
        $name = $_.name.ToLowerInvariant()
        $patterns | Where-Object { $name -like "*$_*" }
    } | Sort-Object ws_mb -Descending)
}

function Get-BrowserElectronGroup {
    param([array]$Processes)
    $browserPatterns = @('msedge', 'arc', 'chrome', 'opera', 'brave', 'firefox', 'electron', 'librewolf')
    $total = 0
    $count = 0
    $Processes | Where-Object {
        $n = $_.name.ToLowerInvariant()
        $browserPatterns | Where-Object { $n -like "*$_*" }
    } | ForEach-Object {
        $total += $_.ws_mb
        $count++
    }
    return @{ ws_mb = [math]::Round($total, 1); count = $count }
}

function Get-DevToolGroup {
    param([array]$Processes)
    $devPatterns = @('node', 'bun', 'python', 'java', 'code', 'webstorm', 'rider', 'idea', 'pycharm',
                      'goland', 'datagrip', 'phpstorm', 'ruby', 'rust', 'cargo', 'opencode', 'codex',
                      'chatgpt', 'pieces', 'os-server')
    $total = 0
    $count = 0
    $Processes | Where-Object {
        $n = $_.name.ToLowerInvariant()
        $devPatterns | Where-Object { $n -like "*$_*" }
    } | ForEach-Object {
        $total += $_.ws_mb
        $count++
    }
    return @{ ws_mb = [math]::Round($total, 1); count = $count }
}

function Get-SecurityGroup {
    param([array]$Processes)
    $secPatterns = @('msmpeng', 'malware', 'mbam', 'glasswire', 'portmaster', 'defender', 'avast', 'kaspersky', 'bitdefender', 'eset')
    $total = 0
    $count = 0
    $Processes | Where-Object {
        $n = $_.name.ToLowerInvariant()
        $secPatterns | Where-Object { $n -like "*$_*" }
    } | ForEach-Object {
        $total += $_.ws_mb
        $count++
    }
    return @{ ws_mb = [math]::Round($total, 1); count = $count }
}

function Get-ProcessCommandLines {
    Get-CimInstance Win32_Process | Select-Object Name, ProcessId, CommandLine
}

function Get-StartupItems {
    Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location, User
}

function Get-ServiceSnapshot {
    Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, ProcessId
}

function Get-PageFileSnapshot {
    Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage, TempPageFile
}

function Get-PowerShellProfileInfo {
    $paths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost, $PROFILE.AllUsersAllHosts, $PROFILE.AllUsersCurrentHost) | Select-Object -Unique
    $items = foreach ($p in $paths) {
        $exists = Test-Path $p
        $sizeKb = 0
        if ($exists) {
            try { $sizeKb = [math]::Round((Get-Item $p).Length / 1KB, 2) } catch { $script:ErrorCount++ }
        }
        [PSCustomObject]@{
            path    = $p
            exists  = $exists
            size_kb = $sizeKb
        }
    }
    return @($items)
}

function Get-GpuData {
    $adapters = Get-CimInstance Win32_VideoController | Select-Object Name, AdapterRAM, Status
    $gpuResult = @{
        available = $false
        adapters  = @()
        eng_type_totals = @{
            '3d'            = 0
            'videodecode'   = 0
            'videoprocessing' = 0
            'copy'          = 0
            'videoencode'   = 0
            'security'      = 0
            'vr'            = 0
            'other'         = 0
        }
        eng_type_count = @{
            '3d'            = 0
            'videodecode'   = 0
            'videoprocessing' = 0
            'copy'          = 0
            'videoencode'   = 0
            'security'      = 0
            'vr'            = 0
            'other'         = 0
        }
        dedicated_used_gb = 0
        dedicated_total_gb = 0
    }

    try {
        $memSamples = @()
        try { $memSamples = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction SilentlyContinue).CounterSamples } catch { $script:ErrorCount++ }

        foreach ($adapter in $adapters) {
            $dedBytes = 0
            foreach ($s in $memSamples) {
                if ($s.Path -match [regex]::Escape($adapter.Name) -and $s.CookedValue -gt 0) {
                    $dedBytes = [math]::Max($dedBytes, $s.CookedValue)
                }
            }
            $totalGB = if ($adapter.AdapterRAM -and $adapter.AdapterRAM -gt 0) { [math]::Round($adapter.AdapterRAM / 1GB, 1) } else { 0 }
            $dedGB = [math]::Round($dedBytes / 1GB, 2)
            $gpuResult.adapters += @{
                name         = $adapter.Name
                status       = $adapter.Status
                dedicated_gb = $dedGB
                total_gb     = $totalGB
                pct          = if ($totalGB -gt 0) { [math]::Round(($dedGB / $totalGB) * 100, 1) } else { 0 }
            }
            $gpuResult.dedicated_used_gb += $dedGB
            $gpuResult.dedicated_total_gb += $totalGB
        }

        try {
            $engSamples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue).CounterSamples
            foreach ($s in $engSamples) {
                $val = $s.CookedValue
                if ($null -eq $val -or $val -eq 0) { continue }
                $type = 'other'
                if ($s.Path -match 'engtype_3d')              { $type = '3d' }
                elseif ($s.Path -match 'engtype_videodecode')  { $type = 'videodecode' }
                elseif ($s.Path -match 'engtype_videoprocessing') { $type = 'videoprocessing' }
                elseif ($s.Path -match 'engtype_copy')          { $type = 'copy' }
                elseif ($s.Path -match 'engtype_videoencode')   { $type = 'videoencode' }
                elseif ($s.Path -match 'engtype_security')      { $type = 'security' }
                elseif ($s.Path -match 'engtype_vr')             { $type = 'vr' }
                $gpuResult.eng_type_totals[$type] += $val
                $gpuResult.eng_type_count[$type]++
            }
        } catch {}

        $gpuResult.available = $gpuResult.adapters.Count -gt 0
    } catch {}

    return $gpuResult
}

function Get-InsightText {
    param(
        [double]$RamPct,
        [double]$CommitPct,
        [double]$PagesSec,
        [double]$NonPagedMB,
        [double]$DiskPct,
        [double]$DiskQueue,
        [double]$CpuPct,
        $BrowserGroup,
        $DevGroup,
        $SecGroup,
        $GpuData
    )

    $insights = @()

    if ($RamPct -ge 85) { $insights += 'High physical RAM usage.' }
    if ($CommitPct -ge 80) { $insights += 'Commit charge is high; system is overcommitted.' }
    if ($PagesSec -ge 100) { $insights += 'Heavy paging detected; disk thrash likely.' }
    if ($NonPagedMB -ge 1500) { $insights += 'Non-paged pool is abnormally high; possible driver or security tool leak.' }
    if ($DiskPct -ge 90) { $insights += 'Disk is saturated.' }
    if ($CpuPct -ge 90) { $insights += 'CPU is near max; application may be CPU-bound.' }
    if ($DiskQueue -gt 8) { $insights += "Disk queue is elevated (${DiskQueue})." }

    if ($GpuData.available) {
        $topEngType = ($GpuData.eng_type_totals.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
        if ($topEngType.Value -gt 50) {
            $engLabel = $topEngType.Key
            if ($engLabel -eq '3d') { $insights += "GPU 3D engine is heavily used ($([math]::Round($topEngType.Value, 0))% aggregate)." }
            elseif ($engLabel -eq 'videodecode') { $insights += "GPU video decode is active (aggregate ~$([math]::Round($topEngType.Value, 0))%)." }
            elseif ($engLabel -eq 'videoprocessing') { $insights += "GPU video processing is active (aggregate ~$([math]::Round($topEngType.Value, 0))%)." }
            elseif ($engLabel -eq 'copy') { $insights += "GPU memory copy engine is active." }
            elseif ($engLabel -eq 'videoencode') { $insights += "GPU video encode is active (aggregate ~$([math]::Round($topEngType.Value, 0))%)." }
            elseif ($engLabel -eq 'security') { $insights += "GPU security engine is active." }
            elseif ($engLabel -eq 'vr') { $insights += "GPU VR workload is active." }
        }
        if ($GpuData.dedicated_total_gb -gt 0) {
            $pct = if ($GpuData.dedicated_total_gb -gt 0) { [math]::Round(($GpuData.dedicated_used_gb / $GpuData.dedicated_total_gb) * 100, 0) } else { 0 }
            if ($pct -ge 90) { $insights += "GPU memory is nearly full ($pct% of dedicated VRAM used)." }
            elseif ($pct -ge 75) { $insights += "GPU memory usage is high ($pct% of dedicated VRAM)." }
        }
    }

    if ($BrowserGroup.count -gt 0) {
        if ($BrowserGroup.ws_mb -gt 2000) {
            $insights += "Browser/Electron group is heavy: $($BrowserGroup.count) procs, ~$($BrowserGroup.ws_mb) MB WS."
        }
    }
    if ($DevGroup.count -gt 0) {
        if ($DevGroup.ws_mb -gt 1000) {
            $insights += "Dev tooling group is heavy: $($DevGroup.count) procs, ~$($DevGroup.ws_mb) MB WS."
        }
    }
    if ($SecGroup.count -gt 0) {
        if ($SecGroup.ws_mb -gt 500) {
            $insights += "Security tool group is present: $($SecGroup.count) procs, ~$($SecGroup.ws_mb) MB WS."
        }
    }

    if (-not $insights) { $insights += 'No critical pressure right now.' }

    return @($insights)
}

function Get-LiveData {
    $counterPaths = @(
        '\Memory\Available MBytes',
        '\Memory\Committed Bytes',
        '\Memory\Commit Limit',
        '\Memory\Pool Paged Bytes',
        '\Memory\Pool Nonpaged Bytes',
        '\Memory\Pages/sec',
        '\Memory\Page Reads/sec',
        '\Memory\Page Writes/sec',
        '\Processor(_Total)\% Processor Time',
        '\System\Processor Queue Length',
        '\PhysicalDisk(_Total)\% Disk Time',
        '\PhysicalDisk(_Total)\Avg. Disk Queue Length',
        '\PhysicalDisk(_Total)\Disk Read Bytes/sec',
        '\PhysicalDisk(_Total)\Disk Write Bytes/sec',
        '\Network Interface(*)\Bytes Sent/sec',
        '\Network Interface(*)\Bytes Received/sec'
    )

    $allCounterPaths = $counterPaths
    $gpuCounterPaths = @('\GPU Adapter Memory(*)\Dedicated Usage', '\GPU Engine(*)\Utilization Percentage')
    $allCounterPaths = @($counterPaths) + @($gpuCounterPaths)

    $samples = $null
    try {
        $counters = Get-Counter $allCounterPaths -ErrorAction SilentlyContinue
        if ($counters) { $samples = $counters.CounterSamples }
    } catch {}

    if (-not $samples) { $samples = @() }

    $os = Get-CimInstance Win32_OperatingSystem

    $memAvailMB = [math]::Round((Get-SafeCounterValue -Samples $samples -Pattern 'Available MBytes'), 2)
    $commitBytes = Get-SafeCounterValue -Samples $samples -Pattern 'Committed Bytes'
    $commitLimitBytes = Get-SafeCounterValue -Samples $samples -Pattern 'Commit Limit'
    $pagedPoolBytes = Get-SafeCounterValue -Samples $samples -Pattern 'Pool Paged Bytes'
    $nonPagedBytes = Get-SafeCounterValue -Samples $samples -Pattern 'Pool Nonpaged Bytes'
    $pagesSec = [math]::Round((Get-SafeCounterValue -Samples $samples -Pattern 'Pages/sec'), 2)
    $pageReadsSec = [math]::Round((Get-SafeCounterValue -Samples $samples -Pattern 'Page Reads/sec'), 2)
    $pageWritesSec = [math]::Round((Get-SafeCounterValue -Samples $samples -Pattern 'Page Writes/sec'), 2)
    $cpuPct = [math]::Round((Get-SafeCounterValue -Samples $samples -Pattern '% Processor Time'), 1)
    $cpuQueue = [math]::Round((Get-SafeCounterValue -Samples $samples -Pattern 'Processor Queue Length'), 2)
    $diskPct = [math]::Round((Get-SafeCounterValue -Samples $samples -Pattern '% Disk Time'), 1)
    $diskQueue = [math]::Round((Get-SafeCounterValue -Samples $samples -Pattern 'Avg. Disk Queue Length'), 2)
    $diskReadMB = Convert-ToMB (Get-SafeCounterValue -Samples $samples -Pattern 'Disk Read Bytes/sec')
    $diskWriteMB = Convert-ToMB (Get-SafeCounterValue -Samples $samples -Pattern 'Disk Write Bytes/sec')
    $netSentKB = [math]::Round((Get-SafeCounterValue -Samples $samples -Pattern 'Bytes Sent/sec' -Sum) / 1KB, 1)
    $netRecvKB = [math]::Round((Get-SafeCounterValue -Samples $samples -Pattern 'Bytes Received/sec' -Sum) / 1KB, 1)

    $totalRAMMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
    $usedRAMMB = $totalRAMMB - $memAvailMB
    $ramPct = if ($totalRAMMB -gt 0) { [math]::Round(($usedRAMMB / $totalRAMMB) * 100, 1) } else { 0 }

    $commitGB = Convert-ToGB $commitBytes
    $commitLimitGB = Convert-ToGB $commitLimitBytes
    $commitPct = if ($commitLimitBytes -gt 0) { [math]::Round(($commitBytes / $commitLimitBytes) * 100, 1) } else { 0 }

    $procs = Get-TopProcesses
    $suspicious = Get-SuspiciousBuckets -Processes $procs.all
    $services = Get-ServiceSnapshot
    $startup = Get-StartupItems
    $pageFile = Get-PageFileSnapshot
    $profiles = Get-PowerShellProfileInfo
    $browserGroup = Get-BrowserElectronGroup -Processes $procs.all
    $devGroup = Get-DevToolGroup -Processes $procs.all
    $secGroup = Get-SecurityGroup -Processes $procs.all

    $topServicePids = @($procs.by_ram | Select-Object -First 20 -ExpandProperty pid)
    $heavyServices = @($services | Where-Object { $topServicePids -contains $_.ProcessId })

    $topPrivateWithCmd = foreach ($p in ($procs.by_private | Select-Object -First 20)) {
        $cmd = $null
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.pid)" | Select-Object -ExpandProperty CommandLine)
        } catch {}
        [PSCustomObject]@{
            name        = $p.name
            pid         = $p.pid
            ws_mb       = $p.ws_mb
            private_mb  = $p.private_mb
            cpu_s       = $p.cpu_s
            commandLine = $cmd
        }
    }

    $gpuData = Get-GpuData
    $insights = Get-InsightText -RamPct $ramPct -CommitPct $commitPct -PagesSec $pagesSec `
        -NonPagedMB (Convert-ToMB $nonPagedBytes) -DiskPct $diskPct -DiskQueue $diskQueue `
        -CpuPct $cpuPct -BrowserGroup $browserGroup -DevGroup $devGroup -SecGroup $secGroup `
        -GpuData $gpuData

    return @{
        ts                = (Get-Date -Format 'HH:mm:ss')
        hostname          = $env:COMPUTERNAME
        os_caption        = $os.Caption
        total_procs       = $procs.count
        ram_pct           = $ramPct
        ram_used_gb       = [math]::Round($usedRAMMB / 1024, 2)
        ram_total_gb      = [math]::Round($totalRAMMB / 1024, 2)
        ram_avail_mb      = $memAvailMB
        commit_pct        = $commitPct
        commit_gb         = $commitGB
        limit_gb          = $commitLimitGB
        paged_pool_mb     = Convert-ToMB $pagedPoolBytes
        non_paged_mb      = Convert-ToMB $nonPagedBytes
        pages_sec         = $pagesSec
        page_reads_sec    = $pageReadsSec
        page_writes_sec   = $pageWritesSec
        cpu_pct           = $cpuPct
        cpu_queue         = $cpuQueue
        disk_pct          = $diskPct
        disk_queue        = $diskQueue
        disk_read_mb      = $diskReadMB
        disk_write_mb     = $diskWriteMB
        net_sent_kb       = $netSentKB
        net_recv_kb       = $netRecvKB
        top_ram           = @($procs.by_ram)
        top_private       = @($procs.by_private)
        top_cpu           = @($procs.by_cpu)
        suspicious        = @($suspicious)
        top_private_cmd   = @($topPrivateWithCmd)
        disks             = @(Get-DriveSnapshot)
        startup           = @($startup)
        pagefile          = @($pageFile)
        heavy_services    = @($heavyServices)
        ps_profiles       = @($profiles)
        insights          = @($insights)
        gpu               = $gpuData
        groups            = @{
            browser       = $browserGroup
            dev_tools     = $devGroup
            security      = $secGroup
        }
    }
}

function Write-Banner {
    param([string]$Mode, [int]$Port)
    $green  = "`e[92m"
    $yellow = "`e[93m"
    $dim    = "`e[2m"
    $reset  = "`e[0m"

    Write-Host ""
    Write-Host "  =========================================" -ForegroundColor DarkGray
    Write-Host "   ${green}PCMON v1.0${reset}"
    Write-Host "   ${dim}  Local-first Windows system monitor${reset}"
    Write-Host "  =========================================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Dashboard : ${yellow}http://${HOSTNAME}:$Port${reset}"
    Write-Host "  API data  : ${yellow}http://${HOSTNAME}:$Port/data${reset}"
    Write-Host "  Stop      : ${yellow}Ctrl+C${reset}"
    Write-Host ""
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://${HOSTNAME}:$Port/")

try {
    $listener.Start()
} catch {
    Write-Host "[pcmon] Failed to start on port $Port. Is something already using it?" -ForegroundColor Red
    exit 1
}

$modeLabel = if ($OPEN_BROWSER) { "dashboard" } else { "api-only" }
Write-Banner -Mode $modeLabel -Port $Port

if ($OPEN_BROWSER) {
    Start-Process "http://${HOSTNAME}:$Port"
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $response.Headers.Add("Access-Control-Allow-Origin", "*")

        $path = $request.Url.LocalPath

        if ($path -eq "/data") {
            $data = Get-LiveData
            $json = $data | ConvertTo-Json -Depth 10 -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/" -or $path -eq "/index.html") {
            $filePath = Join-Path $WEB_DIR "index.html"
            if (Test-Path $filePath) {
                $buffer = [System.IO.File]::ReadAllBytes($filePath)
                $response.ContentType = "text/html; charset=utf-8"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } else {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes("[pcmon] web/index.html not found")
                $response.StatusCode = 404
                $response.ContentType = "text/plain"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
        }
        elseif ($path -match '^/dashboard\.css$') {
            $filePath = Join-Path $WEB_DIR "dashboard.css"
            if (Test-Path $filePath) {
                $buffer = [System.IO.File]::ReadAllBytes($filePath)
                $response.ContentType = "text/css"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } else {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes("[pcmon] web/dashboard\.css not found")
                $response.StatusCode = 404
                $response.ContentType = "text/plain"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
        }

        elseif ($path -match '^/dashboard\.js$') {
            $filePath = Join-Path $WEB_DIR "dashboard.js"
            if (Test-Path $filePath) {
                $buffer = [System.IO.File]::ReadAllBytes($filePath)
                $response.ContentType = "application/javascript"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            } else {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes("[pcmon] web/dashboard.js not found")
                $response.StatusCode = 404
                $response.ContentType = "text/plain"
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
        }
        else {
            $buffer = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
            $response.StatusCode = 404
            $response.ContentType = "text/plain"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }

        $response.OutputStream.Close()
    }
} finally {
    $listener.Stop()
    Write-Host ""
    Write-Host "[pcmon] Stopped." -ForegroundColor Yellow
}


