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

function Test-SnapshotId {
    param([string]$Id)
    if ($Id -match '\.\.[/\\]' -or $Id -match '^[a-zA-Z]:' -or $Id -match '[/\\]') {
        return $false
    }
    return $true
}

function Compare-Snapshots {
    param([string]$SnapshotId)
    if (-not (Test-SnapshotId -Id $SnapshotId)) {
        return @{ error = "Invalid snapshot ID" }
    }
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
    foreach ($p in $snapshot.top_ram) { $snapProcs[$p.name] = $p }
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