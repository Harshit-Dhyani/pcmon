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
        $counters = Get-Counter '\Memory\Available MBytes','\Memory\Committed Bytes','\Memory\Commit Limit','\Memory\Pool Paged Bytes','\Memory\Pool Nonpaged Bytes','\Memory\Pages/sec','\Memory\Page Reads/sec','\Processor(_Total)\% Processor Time','\System\Processor Queue Length','\PhysicalDisk(_Total)\% Disk Time','\PhysicalDisk(_Total)\Avg. Disk Queue Length','\PhysicalDisk(_Total)\Disk Read Bytes/sec','\PhysicalDisk(_Total)\Disk Write Bytes/sec','\Network Interface(*)\Bytes Sent/sec','\Network Interface(*)\Bytes Received/sec' -ErrorAction SilentlyContinue
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
        foreach ($k in $s.Keys) { if ($k -like '*BYTES SENT*') { $netSentKB += $s[$k] } elseif ($k -like '*BYTES RECEIVED*') { $netRecvKB += $s[$k] } }
        $diskPct = [math]::Round([double]$s['\PHYSICALDISK(_TOTAL)\% DISK TIME'], 1)
        $doHeavy = ($cycleCount - $lastHeavyCollect) -ge $heavyInterval
        $doStatic = ($cycleCount - $lastStaticCollect) -ge $staticInterval
        if ($doHeavy) { $lastHeavyCollect = $cycleCount }
        if ($doStatic) { $lastStaticCollect = $cycleCount }
        $cmdLines = @{}
        $procs = @(); $all_processes = @(); $by_ram = @(); $by_private = @(); $by_cpu = @(); $suspicious = @()
        $browserGroup = @{ ws_mb = 0.0; count = 0 }; $devGroup = @{ ws_mb = 0.0; count = 0 }; $secGroup = @{ ws_mb = 0.0; count = 0 }
        $heavyServices = @()
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
        if ($doHeavy) {
            try {
                $gpuCounters = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue
                if ($gpuCounters) { foreach ($sm in $gpuCounters.CounterSamples) { $p = $sm.Path.ToUpperInvariant(); if ($p -like '*GPU*ENG*3D*') { $gpuResult.eng_type_totals['3d'] += $sm.CookedValue } elseif ($p -like '*GPU*ENG*VIDEODECODE*') { $gpuResult.eng_type_totals['videodecode'] += $sm.CookedValue } elseif ($p -like '*GPU*ENG*VIDEOENCODE*') { $gpuResult.eng_type_totals['videoencode'] += $sm.CookedValue } } }
            } catch {}
        }
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
