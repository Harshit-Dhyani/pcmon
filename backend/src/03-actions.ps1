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