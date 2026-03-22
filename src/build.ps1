# pcmon build script
# Bundles src/web/src/* into web/dist/index.html with CSS+JS inlined
# Bundles src/backend/* into pcmon.ps1
# Run from project root: .\src\build.ps1

param(
    [switch]$Watch,
    [string]$Version = "1.0.0",
    [switch]$BackendOnly,
    [switch]$FrontendOnly
)

$ErrorActionPreference = "Stop"
$SRC_DIR = $PSScriptRoot
$WEB_SRC = Join-Path $SRC_DIR "web"
$JS_DIR = Join-Path $WEB_SRC "src"
$HTML_SOURCE = Join-Path $WEB_SRC "index.html"
$CSS_FILE = Join-Path $WEB_SRC "dashboard.css"
$BACKEND_SRC = Join-Path $SRC_DIR "backend"
$OUT_DIR = Split-Path $SRC_DIR -Parent
$OUT_BACKEND = Join-Path $OUT_DIR "pcmon.ps1"
$OUT_FRONTEND = Join-Path $OUT_DIR "web"

$FRONTEND_MODULES = @("1-config.js","2-utils.js","3-stream.js","4-api.js","5-render.js")
$DIST_OUT = Join-Path $OUT_FRONTEND "dist"
$BACKEND_MODULES = @("00-config.ps1","01-logging.ps1","02-http-helpers.ps1","03-actions.ps1","04-snapshots.ps1","05-collectors.ps1","06-background.ps1","07-server.ps1","main.ps1")

function Build-Frontend {
    Write-Host "Building frontend..." -ForegroundColor Cyan
    Write-Host "  Version: $Version"
    if (-not (Test-Path $JS_DIR)) { Write-Error "JS source not found: $JS_DIR"; exit 1 }
    if (-not (Test-Path $HTML_SOURCE)) { Write-Error "HTML source not found: $HTML_SOURCE"; exit 1 }
    if (-not (Test-Path $CSS_FILE)) { Write-Error "CSS not found: $CSS_FILE"; exit 1 }
    if (-not (Test-Path $DIST_OUT)) { New-Item -ItemType Directory -Path $DIST_OUT -Force | Out-Null }
    $html = Get-Content $HTML_SOURCE -Raw -Encoding UTF8
    $css = Get-Content $CSS_FILE -Raw -Encoding UTF8
    if ($css -match "^@charset") { $css = $css -replace "^@charset .+[

]+", "" }
    Write-Host ("    " + [math]::Round($css.Length / 1KB, 1) + " KB inlined") -ForegroundColor DarkGray
    Write-Host "  JS modules:" -ForegroundColor Gray
    $jsParts = @()
    foreach ($mod in $FRONTEND_MODULES) {
        $path = Join-Path $JS_DIR $mod
        if (-not (Test-Path $path)) { Write-Error "Missing: $path"; exit 1 }
        $jsParts += Get-Content $path -Raw -Encoding UTF8
        Write-Host ("    + " + $mod) -ForegroundColor DarkGray
    }
    $js = $jsParts -join "`n`n"
    Write-Host ("    " + [math]::Round($js.Length / 1KB, 1) + " KB bundled") -ForegroundColor DarkGray
    $html = $html -Replace "<link rel=`"stylesheet`" href=`"dashboard.css`">", ("<style>`n" + $css + "`n</style>")
    $html = $html -Replace "<script src=`"src/1-config.js`"></script>\s*", ""
    $html = $html -Replace "<script src=`"src/2-utils.js`"></script>\s*", ""
    $html = $html -Replace "<script src=`"src/3-stream.js`"></script>\s*", ""
    $html = $html -Replace "<script src=`"src/4-api.js`"></script>\s*", ""
    $html = $html -Replace "<script src=`"src/5-render.js`"></script>\s*", ""
    $html = $html -Replace "<script src=`"dashboard.js`"></script>\s*", ""
    $html = $html -Replace "</body>", ("<script>`n" + $js + "`n</script>`n</body>")
    $bc = "<!-- Built " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " v" + $Version + " | Source: src/web/src/ -->"
    $html = $html -Replace "(<meta charset)", ($bc + "`n" + "$1")
    $outPath = Join-Path $DIST_OUT "index.html"
    $html | Out-File -FilePath $outPath -Encoding UTF8 -NoNewline
    Write-Host ("  Output: " + $outPath) -ForegroundColor Gray
    Write-Host ("  Size: " + [math]::Round((Get-Item $outPath).Length / 1KB, 1) + " KB") -ForegroundColor Green
    $distHtml = Get-Content $outPath -Raw -Encoding UTF8
    $errors = @()
    if ($distHtml -match "<script src=`"src/") { $errors += "dead src/ refs" }
    if ($distHtml -match "<script src=`"dashboard.js`"") { $errors += "dead dashboard.js" }
    if ($distHtml.Length -lt 10000) { $errors += "too small" }
    if ($errors.Count -eq 0) { Write-Host "  Verified." -ForegroundColor DarkGray }
    else { Write-Host "  FAILED: $($errors -join ";")" -ForegroundColor Red; exit 1 }
}

function Build-Backend {
    Write-Host "Building backend..." -ForegroundColor Cyan
    Write-Host "  Version: $Version"
    if (-not (Test-Path $BACKEND_SRC)) { Write-Error "Backend source not found"; exit 1 }
    $parts = @()
    $parts += "# pcmon - Built from src/backend/"
    $parts += "# DO NOT EDIT - edit src/backend/"
    $parts += ""
    foreach ($mod in $BACKEND_MODULES) {
        $path = Join-Path $BACKEND_SRC $mod
        if (-not (Test-Path $path)) { Write-Error "Missing: $path"; exit 1 }
        $raw = [System.IO.File]::ReadAllText($path)
        $raw = $raw.TrimEnd([char]10, [char]13)
        $raw = $raw -Replace ([char]65279), ""
        $raw = $raw -replace '(?m)^\s*#\s*endregion\s*(\r?\n)', '$1'
        $raw = $raw -replace '(?m)^\s*#\s*region[^\r\n]*\r?\n', ''
        $modName = [System.IO.Path]::GetFileNameWithoutExtension($mod)
        $parts += "# -- $modName --"
        $parts += $raw.TrimEnd()
        $parts += ""
        Write-Host ("    + " + $mod) -ForegroundColor DarkGray
    }
    $outPath = $OUT_BACKEND
    $outContent = $parts -Join "`n"
    [System.IO.File]::WriteAllText($outPath, $outContent, [System.Text.Encoding]::UTF8)
    Write-Host ("  Output: " + $outPath) -ForegroundColor Gray
    Write-Host ("  Size: " + [math]::Round((Get-Item $outPath).Length / 1KB, 1) + " KB") -ForegroundColor Green
    $check = [System.IO.File]::ReadAllText($outPath)
    $dupErrors = @()
    $fnames = @("Send-Response","Get-SnapshotFiles","Save-Snapshot","Compare-Snapshots","Write-Log","Write-Err","Stop-ProcessById","Suspend-ProcessById","Resume-ProcessById","Get-CachedStaticData","Get-CachedCommandLines","Get-LiveData","_CollectLiveData")
    foreach ($fn in $fnames) {
        $cnt = [regex]::Matches($check, "^function " + [regex]::Escape($fn), [System.Text.RegularExpressions.RegexOptions]::Multiline).Count
        if ($cnt -gt 1) { $dupErrors += "duplicate: $fn ($cnt)" }
    }
    if ($dupErrors.Count -eq 0) { Write-Host "  Verified: no duplicate functions." -ForegroundColor DarkGray }
    else { Write-Host "  FAILED: $($dupErrors -join ";")" -ForegroundColor Red; exit 1 }
    Write-Host "  Backend built." -ForegroundColor Green
}

function Build {
    if ($BackendOnly) { Build-Backend; return }
    if ($FrontendOnly) { Build-Frontend; return }
    Build-Frontend; Write-Host ""; Build-Backend; Write-Host ""; Write-Host "Build complete." -ForegroundColor Green
}

if ($Watch) {
    Write-Host "Watch mode..." -ForegroundColor Cyan
    $w = New-Object System.IO.FileSystemWatcher; $w.Path = $JS_DIR; $w.Filter = "*.js"; $w.EnableRaisingEvents = $true
    $null = Register-ObjectEvent $w Changed -Action { Start-Sleep 200; Build-Frontend }
    while ($true) { Start-Sleep 1 }
} else {
    Build
}
