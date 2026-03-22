#region --- Logging ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    if ($Level -ne "DEBUG" -or $script:DebugMode) { $script:Errors += $entry }
    if ($script:Errors.Count -gt 100) { $script:Errors = @($script:Errors | Select-Object -Last 100) }
    $entry | Out-File -FilePath $LOG_FILE -Append -Encoding UTF8
}

function Write-Err {
    param([string]$Message)
    Write-Log -Message $Message -Level "ERROR"
}
#endregion
