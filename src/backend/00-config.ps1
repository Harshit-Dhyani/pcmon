#region --- CLI Parameters ---
param(
    [switch]$NoOpen,
    [switch]$ApiOnly,
    [switch]$Wallpaper,
    [switch]$Tray,
    [switch]$Debug,
    [switch]$Help,
    [ValidateRange(1, 65535)]
    [int]$Port = 9876
)

if ($Help) {
    @"
pcmon - Local-first Windows system monitoring and diagnostics

Usage:
    .\pcmon.ps1 [-NoOpen] [-ApiOnly] [-Tray] [-Help]

Options:
    -NoOpen      Start the server without opening the browser (API-only mode)
    -ApiOnly     Same as -NoOpen
    -Tray        Run in system tray mode
    -Help        Show this help message

Examples:
    .\pcmon.ps1            Standard mode, opens browser automatically
    .\pcmon.ps1 -NoOpen    API-only, browser stays closed
    .\pcmon.ps1 -Tray      Run with system tray icon

Requirements:
    - Windows with PowerShell 5.1+ or PowerShell Core (pwsh)
    - Web browser for the dashboard

"@
    exit 0
}

if ($Wallpaper -and -not $Tray) {
    Write-Host "[pcmon] -Wallpaper requires -Tray to be enabled." -ForegroundColor Red
    exit 1
}
#endregion

#region --- Setup ---
$ErrorActionPreference = "Continue"
$script:ErrorCount = 0
$HOSTNAME = "localhost"
$OPEN_BROWSER = -not ($NoOpen -or $ApiOnly)
for ($i = 0; $i -lt 20; $i++) {
    $test = New-Object System.Net.HttpListener
    $test.Prefixes.Add("http://${HOSTNAME}:$Port/")
    try { $test.Start(); $test.Stop(); break } catch { $Port++; $test.Abort() }
}
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$WEB_DIR = Join-Path $SCRIPT_DIR "web"
$DIST_DIR = Join-Path $SCRIPT_DIR "dist"
$LOG_FILE = Join-Path $env:TEMP "pcmon_errors_$Port.log"

$script:StartTime = Get-Date
$script:CachedStatic = $null
$script:StaticCacheExpiry = [DateTime]::MinValue
$script:StaticFiles = @{}
$script:CommandLines = @{}
$script:LiveCacheTime = [DateTime]::MinValue
$script:Errors = @()
$script:DebugMode = $Debug
$script:LiveDataCache = $null
$script:LiveDataCacheExpiry = [DateTime]::MinValue
$script:LiveDataCollectionStatus = "idle"
$script:ConnectionMethod = "polling"
$script:WSClients = [System.Collections.Generic.List[object]]::new()
$script:WSLastSend = [DateTime]::MinValue
$script:WSBroadcastInterval = 500
$script:SessionMaxCpuMhz = 0
$script:SessionMaxCpuTempC = $null
$script:SessionMaxCpuPowerW = $null
$SNAPSHOTS_DIR = Join-Path $SCRIPT_DIR "snapshots"
if (-not (Test-Path $SNAPSHOTS_DIR)) { New-Item -ItemType Directory -Path $SNAPSHOTS_DIR -Force | Out-Null }
$cacheFile = Join-Path $env:TEMP "pcmon_live_cache_$Port.json"

$PROTECTED_PROCESSES = @('System', 'Idle', 'csrss', 'smss', 'wininit', 'services', 'lsass', 'svchost', 'winlogon', 'dwm', 'explorer', 'taskhostw', 'sihost', 'ctfmon', 'fontdrvhost', 'Memory Compression')

$script:AlertThresholds = @{
    ram_pct = 85
    commit_pct = 80
    pages_sec = 1000
    non_paged_mb = 1500
    disk_pct = 90
    cpu_pct = 90
}

$configPath = Join-Path $SCRIPT_DIR "config.json"
if (Test-Path $configPath) {
    try {
        $saved = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($key in $saved.PSObject.Properties.Name) {
            $script:AlertThresholds[$key] = $saved.$key
        }
    } catch { }
}
#endregion
