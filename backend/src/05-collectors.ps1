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