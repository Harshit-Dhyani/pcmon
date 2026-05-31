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
        CPU = @(Get-CimInstance Win32_Processor -Property Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, CurrentClockSpeed, SocketDesignation, Status -ErrorAction SilentlyContinue)
        NetAdapters = @(try { Get-NetAdapter -Physical -ErrorAction Stop | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MediaType, PhysicalMediaType, MacAddress } catch { @() })
        PageFile = @()
        PSProfiles = @()
    }
    try {
        foreach ($pf in @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)) {
            $script:CachedStatic.PageFile += [PSCustomObject]@{ name = $pf.Name; allocated_mb = $pf.AllocatedBaseSize; current_usage_mb = $pf.CurrentUsage; peak_usage_mb = $pf.PeakUsage }
        }
    } catch {}
    try {
        $profilePaths = @($PROFILE.AllUsersAllHosts, $PROFILE.AllUsersCurrentHost, $PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)
        foreach ($pp in $profilePaths) {
            if ($pp) {
                $exists = Test-Path $pp -ErrorAction SilentlyContinue
                $sizeKb = if ($exists) { try { [math]::Round((Get-Item $pp).Length / 1KB, 1) } catch { $null } } else { $null }
                $script:CachedStatic.PSProfiles += [PSCustomObject]@{ path = $pp; exists = $exists; size_kb = $sizeKb }
            }
        }
    } catch {}
    $script:StaticCacheExpiry = $now.AddSeconds(60)
}

function Get-CachedCommandLines {
    $now = Get-Date
    if ($script:ProcessCacheTime -gt $now.AddSeconds(-5)) { return }
    $script:ProcessCacheTime = $now
    $script:CommandLines = @{}
    $cmds = Get-CimInstance Win32_Process -Property ProcessId, CommandLine, ExecutablePath -ErrorAction SilentlyContinue
    foreach ($c in $cmds) {
        $script:CommandLines[$c.ProcessId] = @{ cmd = $c.CommandLine; exe_path = $c.ExecutablePath }
    }
}

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

# Convert Windows link-speed strings such as "260 Mbps" into a sortable numeric
# value so the UI can pick a stable primary adapter.
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

# Normalize adapter families into coarse types that are easy to read in the UI.
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

function Get-LiveData {
    $now = Get-Date
    $cacheAge = ($now - $script:LiveCacheTime).TotalSeconds
    # Keep HTTP polling responsive by returning very recent in-memory samples
    # instead of re-collecting on every request.
    if ($cacheAge -lt 0.9 -and $null -ne $script:LiveDataCache) {
        return $script:LiveDataCache
    }
    if (Test-Path $cacheFile) {
        try {
            $fi = Get-Item $cacheFile -ErrorAction SilentlyContinue
            if ($fi) {
                $script:LiveDataCache = Get-Content $cacheFile -Raw | ConvertFrom-Json
                $script:LiveCacheTime = $now
                if (($now - $fi.LastWriteTime).TotalSeconds -lt 15) {
                    return $script:LiveDataCache
                }
            }
        } catch {}
    }
    if ($script:LiveDataCollectionStatus -eq "busy" -and $null -ne $script:LiveDataCache) {
        return $script:LiveDataCache
    }
    $script:LiveDataCollectionStatus = "busy"
    try {
        $script:LiveDataCache = _CollectLiveData
        $script:LiveCacheTime = $now
        return $script:LiveDataCache
    } finally {
        $script:LiveDataCollectionStatus = "idle"
    }
}

function _CollectLiveData {
    if ($null -eq $script:CachedStatic) { Get-CachedStaticData }
    $cs = $script:CachedStatic
    $t0 = [DateTime]::UtcNow.Ticks

    $samples = @()
    try {
        $systemCounters = Get-Counter '\Memory\Available MBytes','\Memory\Committed Bytes','\Memory\Commit Limit','\Memory\Pool Paged Bytes','\Memory\Pool Nonpaged Bytes','\Memory\Pages/sec','\Memory\Page Reads/sec','\Processor(_Total)\% Processor Time','\Processor Information(_Total)\Processor Frequency','\Processor Information(_Total)\% Processor Performance','\System\Processor Queue Length','\PhysicalDisk(_Total)\% Disk Time','\PhysicalDisk(_Total)\Avg. Disk Queue Length','\PhysicalDisk(_Total)\Disk Read Bytes/sec','\PhysicalDisk(_Total)\Disk Write Bytes/sec','\Network Interface(*)\Bytes Sent/sec','\Network Interface(*)\Bytes Received/sec' -ErrorAction SilentlyContinue

        $gpuCounters = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue
        $samples = @()
        if ($systemCounters) { $samples += $systemCounters.CounterSamples }
        if ($gpuCounters) { $samples += $gpuCounters.CounterSamples }
    } catch {}

    $os = if ($cs.OS) { $cs.OS } else { try { Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue } catch {} }
    $cpuMeta = if ($cs.CPU) { @($cs.CPU) } else { @() }

    $totalRAMMB = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1024, 0) } else { 0 }
    $memAvailMB = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\memory\available mbytes'), 2)
    $usedRAMMB = $totalRAMMB - $memAvailMB
    $ramPct = if ($totalRAMMB -gt 0) { [math]::Round(($usedRAMMB / $totalRAMMB) * 100, 1) } else { 0 }
    $commitBytes = Get-CounterSampleValue -Samples $samples -Pattern '\memory\committed bytes'
    $commitLimitBytes = Get-CounterSampleValue -Samples $samples -Pattern '\memory\commit limit'
    $commitPct = if ($commitLimitBytes -gt 0) { [math]::Round(($commitBytes / $commitLimitBytes) * 100, 1) } else { 0 }
    $cpuPct = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\processor(_total)\% processor time'), 1)
    $diskPct = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\% disk time'), 1)

    $netSentKB = Get-CounterSampleValue -Samples $samples -Pattern 'bytes sent/sec' -Sum
    $netRecvKB = Get-CounterSampleValue -Samples $samples -Pattern 'bytes received/sec' -Sum

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
    # "available" means an adapter exists. Engine telemetry is tracked separately
    # so we can distinguish unsupported counters from a real 0% workload.
    $gpuResult = @{ available = $false; adapters = @(); eng_type_totals = @{ '3d' = 0; 'videodecode' = 0; 'videoprocessing' = 0; 'copy' = 0; 'videoencode' = 0; 'security' = 0; 'vr' = 0; 'other' = 0 }; dedicated_used_gb = 0; dedicated_total_gb = 0; engines_supported = $false; status_text = 'No GPU adapters detected' }
    foreach ($adapter in $adapters) {
        $totalGB = if ($adapter.AdapterRAM -and $adapter.AdapterRAM -gt 0) { [math]::Round($adapter.AdapterRAM / 1GB, 1) } else { 0 }
        $gpuResult.adapters += @{ name = $adapter.Name; status = $adapter.Status; dedicated_gb = 0; total_gb = $totalGB; pct = 0; telemetry_supported = $false }
        $gpuResult.dedicated_total_gb += $totalGB
    }
    foreach ($sm in $samples) {
        $p = $sm.Path.ToUpperInvariant()
        if ($p -like '*GPU*ENGINE*UTILIZATION*') { $gpuResult.engines_supported = $true }
        if ($p -like '*GPU*ENG*3D*') { $gpuResult.eng_type_totals['3d'] += $sm.CookedValue }
        elseif ($p -like '*GPU*ENG*VIDEODECODE*') { $gpuResult.eng_type_totals['videodecode'] += $sm.CookedValue }
        elseif ($p -like '*GPU*ENG*VIDEOENCODE*') { $gpuResult.eng_type_totals['videoencode'] += $sm.CookedValue }
    }
    $gpuResult.available = $gpuResult.adapters.Count -gt 0
    if ($gpuResult.available) {
        $gpuResult.status_text = if ($gpuResult.engines_supported) { 'Collector active' } else { 'Adapters detected, engine counters unavailable' }
        foreach ($adapter in $gpuResult.adapters) { $adapter.telemetry_supported = $gpuResult.engines_supported }
    }

    $netAdapterRows = @()
    $netAdapters = if ($cs.NetAdapters) { @($cs.NetAdapters) } else { @() }
    foreach ($adapter in $netAdapters) {
        $kind = Get-AdapterKind -Adapter $adapter
        $linkSpeedBps = Get-LinkSpeedBps -LinkSpeed ([string]$adapter.LinkSpeed)
        $netAdapterRows += [PSCustomObject]@{
            name = $adapter.Name
            description = $adapter.InterfaceDescription
            status = $adapter.Status
            link_speed = [string]$adapter.LinkSpeed
            kind = $kind
            media_type = if ($adapter.PhysicalMediaType) { [string]$adapter.PhysicalMediaType } else { [string]$adapter.MediaType }
            link_speed_bps = $linkSpeedBps
        }
    }
    $activeNetAdapters = @($netAdapterRows | Where-Object { $_.status -eq 'Up' })
    # Prefer an active adapter, then fall back to the fastest known physical
    # adapter so the summary panel stays populated even while disconnected.
    $primaryNetAdapter = if ($activeNetAdapters.Count -gt 0) {
        @($activeNetAdapters | Sort-Object link_speed_bps -Descending | Select-Object -First 1)[0]
    } elseif ($netAdapterRows.Count -gt 0) {
        @($netAdapterRows | Sort-Object link_speed_bps -Descending | Select-Object -First 1)[0]
    } else { $null }
    $network = @{
        status_text = if ($netAdapterRows.Count -eq 0) { 'No physical adapters detected' } elseif ($activeNetAdapters.Count -eq 0) { 'No active physical adapter' } else { 'Collector active' }
        busiest_adapter = if ($primaryNetAdapter) { $primaryNetAdapter.name } else { $null }
        primary_type = if ($primaryNetAdapter) { $primaryNetAdapter.kind } else { 'Unknown' }
        adapter_count = $netAdapterRows.Count
        adapters = $netAdapterRows
    }

    $insights = @()
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
    $cpuCurrentMhz = 0
    $cpuBaseMhz = 0
    $cpuPerfPct = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\processor information(_total)\% processor performance'), 1)
    $cpuFreqCounterMhz = [int][math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\processor information(_total)\processor frequency'), 0)
    $cpuName = 'Unknown CPU'
    $cpuSockets = @($cpuMeta).Count
    $cpuCores = 0
    $cpuLogical = 0
    if ($cpuMeta.Count -gt 0) {
        $cpuName = $cpuMeta[0].Name
        $cpuBaseMhz = [int]($cpuMeta[0].MaxClockSpeed)
        $cpuCurrentMhz = [int]($cpuMeta[0].CurrentClockSpeed)
        foreach ($cpu in $cpuMeta) {
            $cpuCores += [int]($cpu.NumberOfCores)
            $cpuLogical += [int]($cpu.NumberOfLogicalProcessors)
        }
    }
    if ($cpuFreqCounterMhz -gt 0) {
        # The Processor Information counter is more truthful than the static CIM
        # CurrentClockSpeed field, so use it when Windows exposes it.
        $cpuCurrentMhz = $cpuFreqCounterMhz
    } elseif ($cpuBaseMhz -gt 0 -and $cpuPerfPct -gt 0) {
        $cpuCurrentMhz = [int][math]::Round(($cpuBaseMhz * $cpuPerfPct) / 100, 0)
    }
    if ($cpuCurrentMhz -gt $script:SessionMaxCpuMhz) { $script:SessionMaxCpuMhz = $cpuCurrentMhz }
    if ($memAvailMB -lt 1024) { $insights += "CRITICAL: Less than 1GB RAM available ($memAvailGB GB)." }
    elseif ($memAvailMB -lt 2048) { $insights += "Low available RAM ($memAvailGB GB)." }
    if ($commitPct -ge 90) { $insights += "Commit charge > 90%." }
    if ((Get-CounterSampleValue -Samples $samples -Pattern '\memory\pages/sec') -ge 1000) { $insights += "Heavy paging." }
    if ($nonPagedMB -ge 1500) { $insights += "Non-paged pool high ($nonPagedMB MB)." }
    if ($cpuPct -ge 90) { $insights += "CPU at ${cpuPct}%." }
    if ($cpuPct -ge 80 -and $commitPct -lt 80 -and ($diskPct -lt 70)) { $insights += "CPU pressure is likely the current bottleneck." }
    if ($commitPct -ge 85 -and (Get-CounterSampleValue -Samples $samples -Pattern '\memory\pages/sec') -ge 500) { $insights += "High memory pressure with active paging." }
    if ($diskPct -ge 85 -or (Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\avg. disk queue length') -ge 2) { $insights += "Storage bottleneck likely." }
    if ($browserGroup.count -gt 0 -and $browserGroup.ws_mb -gt 2000) { $insights += "Browsers: $($browserGroup.count) procs, ~$($browserGroup.ws_mb) MB." }
    if ($devGroup.count -gt 0 -and $devGroup.ws_mb -gt 1000) { $insights += "Dev tools: $($devGroup.count) procs, ~$($devGroup.ws_mb) MB." }
    if ($secGroup.count -gt 0 -and $secGroup.ws_mb -gt 500) { $insights += "Security: $($secGroup.count) procs, ~$($secGroup.ws_mb) MB." }
    if ($gpuResult.available -and -not $gpuResult.engines_supported) { $insights += "GPU telemetry partially unsupported on this device." }
    if ($netAdapterRows.Count -eq 0) { $insights += "No physical network adapters detected." }
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
    if ($cs.PageFile) { $pagefile = $cs.PageFile }
    
    $psProfiles = @()
    if ($cs.PSProfiles) { $psProfiles = $cs.PSProfiles }

    $svcByPid = @{}
    $services = if ($cs.Services) { $cs.Services } else { @() }
    foreach ($svc in $services) { if ($svc.ProcessId -and $svc.ProcessId -gt 0) { $svcByPid[$svc.ProcessId] = $svc } }
    $heavyServices = @($by_ram | ForEach-Object { $svc = $svcByPid[$_.pid]; if ($svc) { [PSCustomObject]@{ name = $svc.Name; display_name = $svc.DisplayName; state = $svc.State; start_mode = $svc.StartMode; pid = $svc.ProcessId } } } | Select-Object -First 25)

    $allProcs = @($processes | Sort-Object ws_mb -Descending | Select-Object -First 300)
    $suspicious = @($processes | Where-Object { ($_.name -match 'powershell|pwsh|cmd|wscript|cscript|mshta|rundll32|regsvr32') -or ($_.command_line -match 'http://|https://|EncodedCommand|FromBase64String') } | Select-Object -First 50)

    $perfMs = [int](([DateTime]::UtcNow.Ticks - $t0) / 10000)

    $startupItems = if ($cs.Startup) { $cs.Startup } else { @() }
    $osCaption = if ($os) { $os.Caption } else { 'Unknown' }

    $script:cpuTempC = $null
    $script:cpuTempSupported = $false
    try {
        $thermal = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*TZ*' } | Select-Object -First 1
        if ($null -ne $thermal -and $thermal.Temperature -gt 0) {
            $script:cpuTempC = [math]::Round($thermal.Temperature / 10.0, 1)
            $script:cpuTempSupported = $true
            if ($null -eq $script:SessionMaxCpuTempC -or $script:cpuTempC -gt $script:SessionMaxCpuTempC) { $script:SessionMaxCpuTempC = $script:cpuTempC }
        }
        } catch {}

    $script:cpuTempC = $null
    $script:cpuTempSupported = $false
    try {
        $thermal = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*TZ*' } | Select-Object -First 1
        if ($null -ne $thermal -and $thermal.Temperature -gt 0) {
            $script:cpuTempC = [math]::Round($thermal.Temperature / 10.0, 1)
            $script:cpuTempSupported = $true
            if ($null -eq $script:SessionMaxCpuTempC -or $script:cpuTempC -gt $script:SessionMaxCpuTempC) { $script:SessionMaxCpuTempC = $script:cpuTempC }
        }
    } catch {}

    return @{
        ts = (Get-Date -Format 'HH:mm:ss'); hostname = $env:COMPUTERNAME; os_caption = $osCaption; total_procs = $processes.Count; ram_pct = $ramPct
        ram_used_gb = [math]::Round($usedRAMMB / 1024, 2); ram_total_gb = [math]::Round($totalRAMMB / 1024, 2); ram_avail_mb = $memAvailMB
        commit_pct = $commitPct; commit_gb = [math]::Round($commitBytes / 1GB, 2); limit_gb = [math]::Round($commitLimitBytes / 1GB, 2)
        paged_pool_mb = $pagedPoolMB; paged_pool_pct = $pagedPoolPct; non_paged_mb = $nonPagedMB; non_paged_pct = $nonPagedPct
        pages_sec = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\memory\pages/sec'), 2); page_reads_sec = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\memory\page reads/sec'), 2)
        cpu_pct = $cpuPct; cpu_queue = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\system\processor queue length'), 2)
        disk_pct = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\% disk time'), 1); disk_queue = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\avg. disk queue length'), 2)
        disk_read_mb = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\disk read bytes/sec') / 1MB, 2)
        disk_write_mb = [math]::Round((Get-CounterSampleValue -Samples $samples -Pattern '\physicaldisk(_total)\disk write bytes/sec') / 1MB, 2)
        net_sent_kb = [math]::Round($netSentKB / 1KB, 1); net_recv_kb = [math]::Round($netRecvKB / 1KB, 1)
        top_ram = $by_ram; top_private = $by_private; top_cpu = $by_cpu; all_processes = $allProcs; suspicious = $suspicious
        disks = $disks; startup = $startupItems; pagefile = $pagefile; heavy_services = $heavyServices; ps_profiles = $psProfiles
        cpu = @{
            name = $cpuName
            sockets = $cpuSockets
            cores = $cpuCores
            logical = $cpuLogical
            base_mhz = $cpuBaseMhz
            current_mhz = $cpuCurrentMhz
            max_seen_mhz = $script:SessionMaxCpuMhz
            performance_pct = $cpuPerfPct
            temp_c = $script:cpuTempC
            max_temp_c = $script:SessionMaxCpuTempC
            temp_supported = $script:cpuTempSupported
            power_w = $null
            max_power_w = $script:SessionMaxCpuPowerW
            power_supported = $false
        }
        insights = $insights; gpu = $gpuResult; network = $network; groups = @{ browser = $browserGroup; dev_tools = $devGroup; security = $secGroup }
        _perf_ms = $perfMs; _loading = $false
    }
}
#endregion
