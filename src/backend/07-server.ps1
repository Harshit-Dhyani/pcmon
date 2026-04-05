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
Write-Host "  $base/api/export"
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

$DIST_INDEX = Join-Path $DIST_DIR "index.html"
if (Test-Path $DIST_INDEX) {
    $script:StaticFiles['index.html'] = @{ data = [System.IO.File]::ReadAllBytes($DIST_INDEX); type = 'text/html; charset=utf-8' }
    $cssSrc = Join-Path $WEB_DIR "dashboard.css"
    if (Test-Path $cssSrc) { $script:StaticFiles['dashboard.css'] = @{ data = [System.IO.File]::ReadAllBytes($cssSrc); type = 'text/css' } }
} else {
    foreach ($f in @('index.html', 'dashboard.css')) {
        $fp = Join-Path $WEB_DIR $f
        if (Test-Path $fp) { $script:StaticFiles[$f] = @{ data = [System.IO.File]::ReadAllBytes($fp); type = if ($f -like '*.css') { 'text/css' } else { 'text/html; charset=utf-8' } } }
    }
}
$wallpaperFile = Join-Path $SCRIPT_DIR "wallpaper\index.html"
if (Test-Path $wallpaperFile) { $script:StaticFiles['wallpaper.html'] = @{ data = [System.IO.File]::ReadAllBytes($wallpaperFile); type = 'text/html; charset=utf-8' } }

$listener.Start()

$script:refreshRateFile = Join-Path $env:TEMP "pcmon_refresh_rate_$Port.txt"
$profilePathsFile = Join-Path $env:TEMP "pcmon_profile_paths_$Port.json"
"500" | Out-File -FilePath $script:refreshRateFile -Encoding UTF8 -Force

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
$script:LastFastRateCheck = [DateTime]::MinValue

function Get-FastMetrics {
    try {
        $counters = Get-Counter '\Memory\Available MBytes','\Memory\Committed Bytes','\Memory\Commit Limit','\Processor(_Total)\% Processor Time','\PhysicalDisk(_Total)\% Disk Time' -ErrorAction SilentlyContinue
        $samples = if ($counters) { @($counters.CounterSamples) } else { @() }
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $totalMB = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1024, 0) } else { 0 }
        $availMB = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\memory\available mbytes'), 0)
        $usedMB = $totalMB - $availMB
        $ramPct = if ($totalMB -gt 0) { [math]::Round(($usedMB / $totalMB) * 100, 1) } else { 0 }
        $commitPct = 0
        $commitBytes = Get-CounterSampleValue -Samples $samples -Pattern '\memory\committed bytes'
        $commitLimit = Get-CounterSampleValue -Samples $samples -Pattern '\memory\commit limit'
        if ($commitBytes -and $commitLimit) {
            $commitPct = [math]::Round(($commitBytes / $commitLimit) * 100, 1)
        }
        return @{
            ts = (Get-Date -Format 'HH:mm:ss')
            hostname = $env:COMPUTERNAME
            ram_pct = $ramPct
            ram_avail_mb = $availMB
            ram_total_gb = [math]::Round($totalMB / 1024, 1)
            commit_pct = $commitPct
            cpu_pct = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\processor(_total)\% processor time'), 1)
            disk_pct = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\% disk time'), 1)
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

$profilePathsFile = Join-Path $env:TEMP "pcmon_profile_paths_$Port.json"
$profilePathsJson = @(
    $PROFILE.AllUsersAllHosts,
    $PROFILE.AllUsersCurrentHost,
    $PROFILE.CurrentUserAllHosts,
    $PROFILE.CurrentUserCurrentHost
) | Where-Object { $_ } | ConvertTo-Json -Compress
$profilePathsJson | Out-File -FilePath $profilePathsFile -Encoding UTF8 -Force

$rateCheckTimer = New-Object System.Timers.Timer
$rateCheckTimer.Interval = 2000
$rateCheckTimer.AutoReset = $true
Register-ObjectEvent -InputObject $rateCheckTimer -EventName Elapsed -Action {
    try {
        $rateContent = Get-Content $script:refreshRateFile -Raw -ErrorAction SilentlyContinue
        if ($rateContent) {
            $newRate = [int]($rateContent.Trim())
            if ($newRate -ge 500 -and $newRate -le 10000 -and $newRate -ne $script:FastUpdateInterval) {
                $script:FastUpdateInterval = $newRate
            }
        }
    } catch {}
} | Out-Null
$rateCheckTimer.Start()

$cleanupTimer = New-Object System.Timers.Timer
$cleanupTimer.Interval = 30000
$cleanupTimer.AutoReset = $true
Register-ObjectEvent -InputObject $cleanupTimer -EventName Elapsed -Action {
    $dead = [System.Collections.Generic.List[object]]::new()
    foreach ($ws in @($script:WSClients)) {
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

Write-Host "  Initializing..." -NoNewline
$sw2 = [Diagnostics.Stopwatch]::StartNew()
$sw2.Start()

$script:shuttingDown = $false
Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
    $script:shuttingDown = $true
    $listener.Stop()
    Write-Host ""
    Write-Host "[pcmon] Stopped." -ForegroundColor Yellow
} | Out-Null

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
        $origin = $request.Headers.Get("Origin")
        if ($origin -and $origin -match '^http://(localhost|127\.0\.0\.1):\d+$') {
            $response.Headers.Add("Access-Control-Allow-Origin", $origin)
        }
        $path = $request.Url.LocalPath

        if ($path -eq "/health") {
            # Keep /health cheap and always available, even if the cache is still warming.
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
                    $procId = if ($p.pid) { $p.pid } else { 0 }
                    $ws = if ($p.ws_mb) { $p.ws_mb } else { 0 }
                    $cpu = if ($p.cpu_s) { $p.cpu_s } else { 0 }
                    $threads = if ($p.threads) { $p.threads } else { 0 }
                    $handles = if ($p.handles) { $p.handles } else { 0 }
                    $csvLines += "$name,$procId,$ws,$cpu,$threads,$handles"
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
            $procId = [int]$matches[1]
            $result = Stop-ProcessById -ProcessId $procId -Force
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
            $procId = [int]$matches[1]
            $result = Suspend-ProcessById -ProcessId $procId
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
            $procId = [int]$matches[1]
            $result = Resume-ProcessById -ProcessId $procId
            $json = $result | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -eq "/api/report") {
            if ($request.HttpMethod -ne "GET") {
                $response.StatusCode = 405
                $response.ContentLength64 = 0
                Send-Response $response $null "application/json"
                continue
            }
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
            if ($request.HttpMethod -ne "GET") {
                $response.StatusCode = 405
                $response.ContentLength64 = 0
                Send-Response $response $null "application/json"
                continue
            }
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
        elseif ($path -eq "/api/thresholds" -and $request.HttpMethod -ne "GET") {
            $response.StatusCode = 405
            $response.ContentLength64 = 0
            Send-Response $response $null "application/json"
            continue
        }
        elseif ($path -eq "/api/thresholds" -and $request.HttpMethod -eq "GET") {
            $json = $script:AlertThresholds | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
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
            if ($request.HttpMethod -ne "GET") {
                $response.StatusCode = 405
                $response.ContentLength64 = 0
                Send-Response $response $null "application/json"
                continue
            }
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
                    if ($parsed.refreshRate -and $parsed.refreshRate -ge 500 -and $parsed.refreshRate -le 10000) {
                        $parsed.refreshRate | Out-File -FilePath $script:refreshRateFile -Encoding UTF8 -Force
                        $json = @{ success = $true; rate = $parsed.refreshRate } | ConvertTo-Json -Compress
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
        elseif ($path -eq "/api/info") {
            if ($request.HttpMethod -ne "GET") {
                $response.StatusCode = 405
                $response.ContentLength64 = 0
                Send-Response $response $null "application/json"
                continue
            }
            $uptime = 0
            try { $uptime = [math]::Round((New-TimeSpan -Start $script:StartTime -End (Get-Date)).TotalSeconds) } catch {}
            $conn = ""
            try { $conn = [string]$script:ConnectionMethod } catch {}
            $wsCount = 0
            try { $wsCount = [int]$script:WSClients.Count } catch {}
            $info = @{
                method = $conn
                uptime = $uptime
                ws_clients = $wsCount
                ps_version = $PSVersionTable.PSVersion.ToString()
                hostname = $env:COMPUTERNAME
            } | ConvertTo-Json -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($info)
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buffer.Length
            Send-Response $response $buffer "application/json"
        }
        elseif ($path -eq "/api/export" -and $request.HttpMethod -eq "GET") {
            $cacheFile = Join-Path $TEMP_DIR "pcmon_cache_$Port.json"
            $data = $null
            if (Test-Path $cacheFile) {
                try {
                    $json = [System.IO.File]::ReadAllText($cacheFile)
                    $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue
                } catch { }
            }
            if (-not $data) {
                $data = Get-LiveData -Force
            }
            $exportObj = @{
                exported_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                hostname = $env:COMPUTERNAME
                data = $data
                thresholds = $script:AlertThresholds
                version = "1.0"
            }
            $json = $exportObj | ConvertTo-Json -Depth 20 -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
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
#endregion
