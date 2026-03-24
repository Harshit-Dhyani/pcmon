$bgScriptContent = @'
$cacheFile = $args[0]
$refreshRateFile = $args[1]
$profilePathsFile = $args[2]
$bgDebug = if ($args[3] -eq "1") { $true } else { $false }
Import-Module CimCmdlets -ErrorAction SilentlyContinue
Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
function Get-CounterSampleValue {
    param(
        [array]$Samples,
        [string]$Pattern,
        [switch]$Sum
    )
    $matches = @($Samples | Where-Object { $_.Path -like "*$Pattern*" })
    if ($matches.Count -eq 0) { return 0 }
    if ($Sum) {
        return [double](($matches | Measure-Object CookedValue -Sum).Sum)
    }
    return [double]$matches[0].CookedValue
}
function Get-LinkSpeedBps {
    param([string]$LinkSpeed)
    if ([string]::IsNullOrWhiteSpace($LinkSpeed)) { return 0 }
    if ($LinkSpeed -match '([\d\.]+)\s*(Kbps|Mbps|Gbps|Tbps|bps)') {
        $value = [double]$matches[1]
        switch ($matches[2].ToLowerInvariant()) {
            'tbps' { return [double]($value * 1TB) }
            'gbps' { return [double]($value * 1GB) }
            'mbps' { return [double]($value * 1MB) }
            'kbps' { return [double]($value * 1KB) }
            default { return $value }
        }
    }
    return 0
}
function Get-AdapterKind {
    param($Adapter)
    $joined = @(
        [string]$Adapter.Name,
        [string]$Adapter.InterfaceDescription,
        [string]$Adapter.MediaType,
        [string]$Adapter.PhysicalMediaType
    ) -join ' '
    if ($joined -match 'wi-?fi|wireless|802\.11') { return 'Wi-Fi' }
    if ($joined -match 'ethernet|802\.3') { return 'Ethernet' }
    return 'Other'
}
$bgStart = [DateTime]::UtcNow.Ticks
try { $profilePathsJson = Get-Content $profilePathsFile -Raw -ErrorAction SilentlyContinue } catch { $profilePathsJson = '[]' }
try { $profilePaths = $profilePathsJson | ConvertFrom-Json } catch { $profilePaths = @() }
$os = Get-CimInstance Win32_OperatingSystem
$video = @(Get-CimInstance Win32_VideoController -Property Name, AdapterRAM, Status -ErrorAction SilentlyContinue)
$cpuMeta = @(Get-CimInstance Win32_Processor -Property Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, CurrentClockSpeed, SocketDesignation, Status -ErrorAction SilentlyContinue)
$netAdapters = @(try { Get-NetAdapter -Physical -ErrorAction Stop | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MediaType, PhysicalMediaType, MacAddress } catch { @() })
$totalRAMMB = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
$firstRun = $true
$bgRefreshRate = 1000
$cycleCount = 0
$lastHeavyCollect = 0
$lastStaticCollect = 0
$heavyInterval = 4
$staticInterval = 30
$cmdLines = @{}
$processes = @()
$all_processes = @()
$by_ram = @()
$by_private = @()
$by_cpu = @()
$suspicious = @()
$browserGroup = @{ ws_mb = 0.0; count = 0 }
$devGroup = @{ ws_mb = 0.0; count = 0 }
$secGroup = @{ ws_mb = 0.0; count = 0 }
$disks = @()
$heavyServices = @()
$startup = @()
$pagefile = @()
$psProfiles = @()
$maxObservedCpuMhz = 0
if ($bgDebug) { Write-Host "[BG DEBUG] Started. Debug mode ON." -ForegroundColor Cyan }
while ($true) {
    $cycleCount++
    try { $bgRefreshRate = [int](Get-Content $refreshRateFile -Raw -ErrorAction SilentlyContinue) } catch {}
    if ($bgRefreshRate -lt 500) { $bgRefreshRate = 500 }
    $heavyInterval = [math]::Max([int][math]::Ceiling(4000 / $bgRefreshRate), 1)
    $staticInterval = [math]::Max([int][math]::Ceiling(30000 / $bgRefreshRate), 1)
    $isInitialCycle = $firstRun
    if ($firstRun) { $firstRun = $false } else { Start-Sleep -Milliseconds $bgRefreshRate }
    if ($bgDebug) { Write-Host "[BG DEBUG] Cycle $cycleCount at ${bgRefreshRate}ms" -ForegroundColor Cyan }
    $t0 = [DateTime]::UtcNow.Ticks
    try {
        $counters = Get-Counter '\Memory\Available MBytes','\Memory\Committed Bytes','\Memory\Commit Limit','\Memory\Pool Paged Bytes','\Memory\Pool Nonpaged Bytes','\Memory\Pages/sec','\Memory\Page Reads/sec','\Processor(_Total)\% Processor Time','\Processor Information(_Total)\Processor Frequency','\Processor Information(_Total)\% Processor Performance','\System\Processor Queue Length','\PhysicalDisk(_Total)\% Disk Time','\PhysicalDisk(_Total)\Avg. Disk Queue Length','\PhysicalDisk(_Total)\Disk Read Bytes/sec','\PhysicalDisk(_Total)\Disk Write Bytes/sec','\Network Interface(*)\Bytes Sent/sec','\Network Interface(*)\Bytes Received/sec' -ErrorAction SilentlyContinue
        $samples = if ($counters) { @($counters.CounterSamples) } else { @() }
        $memAvailMB = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\memory\available mbytes'), 2)
        $usedRAMMB = $totalRAMMB - $memAvailMB
        $ramPct = if ($totalRAMMB -gt 0) { [math]::Round(($usedRAMMB / $totalRAMMB) * 100, 1) } else { 0 }
        $commitBytes = Get-CounterSampleValue -Samples $samples -Pattern '\memory\committed bytes'
        $commitLimitBytes = Get-CounterSampleValue -Samples $samples -Pattern '\memory\commit limit'
        $commitPct = if ($commitLimitBytes -gt 0) { [math]::Round(($commitBytes / $commitLimitBytes) * 100, 1) } else { 0 }
        $cpuPct = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\processor(_total)\% processor time'), 1)
        $netSentKB = Get-CounterSampleValue -Samples $samples -Pattern 'bytes sent/sec' -Sum
        $netRecvKB = Get-CounterSampleValue -Samples $samples -Pattern 'bytes received/sec' -Sum
        $diskPct = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\% disk time'), 1)
        $doHeavy = $isInitialCycle -or (($cycleCount - $lastHeavyCollect) -ge $heavyInterval)
        $doStatic = $isInitialCycle -or (($cycleCount - $lastStaticCollect) -ge $staticInterval)
        if ($doHeavy) { $lastHeavyCollect = $cycleCount }
        if ($doStatic) { $lastStaticCollect = $cycleCount }
        if ($doHeavy) {
            if ($doStatic -or $cmdLines.Count -eq 0) {
                $cmdLines = @{}
                foreach ($c in @(Get-CimInstance Win32_Process -Property ProcessId, CommandLine, ExecutablePath -ErrorAction SilentlyContinue)) { $cmdLines[[int]$c.ProcessId] = @{ cmd = $c.CommandLine; path = $c.ExecutablePath } }
            }
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
        $gpuResult = @{ available = $false; adapters = @(); eng_type_totals = @{ '3d' = 0; 'videodecode' = 0; 'videoprocessing' = 0; 'copy' = 0; 'videoencode' = 0; 'security' = 0; 'vr' = 0; 'other' = 0 }; dedicated_used_gb = 0; dedicated_total_gb = 0; engines_supported = $false; status_text = 'No GPU adapters detected' }
        foreach ($adapter in $video) { $totalGB = if ($adapter.AdapterRAM -and $adapter.AdapterRAM -gt 0) { [math]::Round($adapter.AdapterRAM / 1GB, 1) } else { 0 }; $gpuResult.adapters += @{ name = $adapter.Name; status = $adapter.Status; dedicated_gb = 0; total_gb = $totalGB; pct = 0; telemetry_supported = $false }; $gpuResult.dedicated_total_gb += $totalGB }
        $gpuResult.available = $gpuResult.adapters.Count -gt 0
        if ($doHeavy) {
            try {
                $gpuCounters = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue
                if ($gpuCounters) { foreach ($sm in $gpuCounters.CounterSamples) { $p = $sm.Path.ToUpperInvariant(); if ($p -like '*GPU*ENGINE*UTILIZATION*') { $gpuResult.engines_supported = $true }; if ($p -like '*GPU*ENG*3D*') { $gpuResult.eng_type_totals['3d'] += $sm.CookedValue } elseif ($p -like '*GPU*ENG*VIDEODECODE*') { $gpuResult.eng_type_totals['videodecode'] += $sm.CookedValue } elseif ($p -like '*GPU*ENG*VIDEOENCODE*') { $gpuResult.eng_type_totals['videoencode'] += $sm.CookedValue } } }
            } catch {}
        }
        if ($gpuResult.available) {
            $gpuResult.status_text = if ($gpuResult.engines_supported) { 'Collector active' } else { 'Adapters detected, engine counters unavailable' }
            foreach ($adapter in $gpuResult.adapters) { $adapter.telemetry_supported = $gpuResult.engines_supported }
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
            $startup = @(Get-CimInstance Win32_StartupCommand -Property Name, Command, Location, User -ErrorAction SilentlyContinue)
            $pagefile = @()
            try { foreach ($pf in @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)) { $pagefile += [PSCustomObject]@{ name = $pf.Name; allocated_mb = $pf.AllocatedBaseSize; current_usage_mb = $pf.CurrentUsage; peak_usage_mb = $pf.PeakUsage } } } catch {}
            $psProfiles = @()
            try { foreach ($pp in $profilePaths) { if ($pp) { $exists = Test-Path $pp -ErrorAction SilentlyContinue; $sizeKb = if ($exists) { [math]::Round((Get-Item $pp -ErrorAction SilentlyContinue).Length / 1KB, 1) } else { $null }; $psProfiles += [PSCustomObject]@{ path = $pp; exists = $exists; size_kb = $sizeKb } } } } catch {}
            $netAdapters = @(try { Get-NetAdapter -Physical -ErrorAction Stop | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MediaType, PhysicalMediaType, MacAddress } catch { @() })
        }
        $suspicious = @($all_processes | Where-Object { ($_.name -match 'powershell|pwsh|cmd|wscript|cscript|mshta|rundll32|regsvr32') -or ($_.command_line -match 'http://|https://|EncodedCommand|FromBase64String') } | Select-Object -First 50)
        $memAvailGB = [math]::Round($memAvailMB / 1024, 1)
        $pagedPoolBytes = Get-CounterSampleValue -Samples $samples -Pattern '\memory\pool paged bytes'
        if ($pagedPoolBytes -le 0 -or [double]::IsNaN($pagedPoolBytes)) {
            try { $pagedPoolBytes = [double](Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue).PoolPagedBytes } catch { $pagedPoolBytes = 0 }
        }
        $nonPagedBytes = Get-CounterSampleValue -Samples $samples -Pattern '\memory\pool nonpaged bytes'
        if ($nonPagedBytes -le 0 -or [double]::IsNaN($nonPagedBytes)) {
            try { $nonPagedBytes = [double](Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue).PoolNonpagedBytes } catch { $nonPagedBytes = 0 }
        }
        $pagedPoolMB = [math]::Round($pagedPoolBytes / 1MB, 2)
        $pagedPoolPct = if ($totalRAMMB -gt 0) { [math]::Round($pagedPoolMB / $totalRAMMB * 100, 1) } else { 0 }
        $nonPagedMB = [math]::Round($nonPagedBytes / 1MB, 0)
        $nonPagedPct = if ($totalRAMMB -gt 0) { [math]::Round($nonPagedMB / $totalRAMMB * 100, 1) } else { 0 }
        $cpuName = 'Unknown CPU'
        $cpuSockets = @($cpuMeta).Count
        $cpuCores = 0
        $cpuLogical = 0
        $cpuBaseMhz = 0
        $cpuCurrentMhz = 0
        $cpuPerfPct = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\processor information(_total)\% processor performance'), 1)
        $cpuFreqCounterMhz = [int][math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\processor information(_total)\processor frequency'), 0)
        if ($cpuMeta.Count -gt 0) {
            $cpuName = $cpuMeta[0].Name
            $cpuBaseMhz = [int]($cpuMeta[0].MaxClockSpeed)
            $cpuCurrentMhz = [int]($cpuMeta[0].CurrentClockSpeed)
            foreach ($cpu in $cpuMeta) {
                $cpuCores += [int]($cpu.NumberOfCores)
                $cpuLogical += [int]($cpu.NumberOfLogicalProcessors)
            }
        }
        if ($cpuFreqCounterMhz -gt 0) { $cpuCurrentMhz = $cpuFreqCounterMhz }
        elseif ($cpuBaseMhz -gt 0 -and $cpuPerfPct -gt 0) { $cpuCurrentMhz = [int][math]::Round(($cpuBaseMhz * $cpuPerfPct) / 100, 0) }
        if ($cpuCurrentMhz -gt $maxObservedCpuMhz) { $maxObservedCpuMhz = $cpuCurrentMhz }
        $netAdapterRows = @()
        foreach ($adapter in $netAdapters) {
            $kind = Get-AdapterKind -Adapter $adapter
            $linkSpeedBps = Get-LinkSpeedBps -LinkSpeed ([string]$adapter.LinkSpeed)
            $netAdapterRows += [PSCustomObject]@{ name = $adapter.Name; description = $adapter.InterfaceDescription; status = $adapter.Status; link_speed = [string]$adapter.LinkSpeed; kind = $kind; media_type = if ($adapter.PhysicalMediaType) { [string]$adapter.PhysicalMediaType } else { [string]$adapter.MediaType }; link_speed_bps = $linkSpeedBps }
        }
        $activeNetAdapters = @($netAdapterRows | Where-Object { $_.status -eq 'Up' })
        $primaryNetAdapter = if ($activeNetAdapters.Count -gt 0) { @($activeNetAdapters | Sort-Object link_speed_bps -Descending | Select-Object -First 1)[0] } elseif ($netAdapterRows.Count -gt 0) { @($netAdapterRows | Sort-Object link_speed_bps -Descending | Select-Object -First 1)[0] } else { $null }
        $network = @{ status_text = if ($netAdapterRows.Count -eq 0) { 'No physical adapters detected' } elseif ($activeNetAdapters.Count -eq 0) { 'No active physical adapter' } else { 'Collector active' }; busiest_adapter = if ($primaryNetAdapter) { $primaryNetAdapter.name } else { $null }; primary_type = if ($primaryNetAdapter) { $primaryNetAdapter.kind } else { 'Unknown' }; adapter_count = $netAdapterRows.Count; adapters = $netAdapterRows }
        $insights = @()
        if ($memAvailMB -lt 1024) { $insights += "CRITICAL: Less than 1GB RAM available ($memAvailGB GB)." }
        elseif ($memAvailMB -lt 2048) { $insights += "Low available RAM ($memAvailGB GB)." }
        if ($commitPct -ge 90) { $insights += "Commit charge > 90%." }
        if ((Get-CounterSampleValue -Samples $samples -Pattern '\memory\pages/sec') -ge 1000) { $insights += "Heavy paging." }
        if ($nonPagedMB -ge 1500) { $insights += "Non-paged pool high ($nonPagedMB MB)." }
        if ($cpuPct -ge 90) { $insights += "CPU at $cpuPct%." }
        if ($cpuPct -ge 80 -and $commitPct -lt 80 -and $diskPct -lt 70) { $insights += "CPU pressure is likely the current bottleneck." }
        if ($commitPct -ge 85 -and (Get-CounterSampleValue -Samples $samples -Pattern '\memory\pages/sec') -ge 500) { $insights += "High memory pressure with active paging." }
        if ($diskPct -ge 85 -or (Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\avg. disk queue length') -ge 2) { $insights += "Storage bottleneck likely." }
        if ($browserGroup.count -gt 0 -and $browserGroup.ws_mb -gt 2000) { $insights += "Browsers: $($browserGroup.count) procs, ~$($browserGroup.ws_mb) MB." }
        if ($devGroup.count -gt 0 -and $devGroup.ws_mb -gt 1000) { $insights += "Dev tools: $($devGroup.count) procs, ~$($devGroup.ws_mb) MB." }
        if ($secGroup.count -gt 0 -and $secGroup.ws_mb -gt 500) { $insights += "Security: $($secGroup.count) procs, ~$($secGroup.ws_mb) MB." }
        if ($gpuResult.available -and -not $gpuResult.engines_supported) { $insights += "GPU telemetry partially unsupported on this device." }
        if ($netAdapterRows.Count -eq 0) { $insights += "No physical network adapters detected." }
        if (-not $insights) { $insights += 'System healthy.' }
        $collectMs = [int](([DateTime]::UtcNow.Ticks - $t0) / 10000)
        $data = @{
            ts = (Get-Date -Format 'HH:mm:ss'); hostname = $env:COMPUTERNAME; os_caption = $os.Caption; total_procs = $processes.Count; ram_pct = $ramPct
            ram_used_gb = [math]::Round($usedRAMMB / 1024, 2); ram_total_gb = [math]::Round($totalRAMMB / 1024, 2); ram_avail_mb = $memAvailMB
            commit_pct = $commitPct; commit_gb = [math]::Round($commitBytes / 1GB, 2); limit_gb = [math]::Round($commitLimitBytes / 1GB, 2)
            paged_pool_mb = $pagedPoolMB; paged_pool_pct = $pagedPoolPct; non_paged_mb = $nonPagedMB; non_paged_pct = $nonPagedPct
            pages_sec = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\memory\pages/sec'), 2); page_reads_sec = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\memory\page reads/sec'), 2)
            cpu_pct = $cpuPct; cpu_queue = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\system\processor queue length'), 2)
            disk_pct = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\% disk time'), 1); disk_queue = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\avg. disk queue length'), 2)
            disk_read_mb = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\disk read bytes/sec') / 1MB, 2)
            disk_write_mb = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\disk write bytes/sec') / 1MB, 2)
            net_sent_kb = [math]::Round($netSentKB / 1KB, 1); net_recv_kb = [math]::Round($netRecvKB / 1KB, 1)
            top_ram = $by_ram; top_private = $by_private; top_cpu = $by_cpu; all_processes = $all_processes; suspicious = $suspicious
            disks = $disks; startup = $startup; pagefile = $pagefile; heavy_services = $heavyServices; ps_profiles = $psProfiles
            cpu = @{
                name = $cpuName
                sockets = $cpuSockets
                cores = $cpuCores
                logical = $cpuLogical
                base_mhz = $cpuBaseMhz
                current_mhz = $cpuCurrentMhz
                max_seen_mhz = $maxObservedCpuMhz
                performance_pct = $cpuPerfPct
                temp_c = $null
                max_temp_c = $null
                temp_supported = $false
                power_w = $null
                max_power_w = $null
                power_supported = $false
            }
            insights = $insights; gpu = $gpuResult; network = $network; groups = @{ browser = $browserGroup; dev_tools = $devGroup; security = $secGroup }
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
