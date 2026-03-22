# pcmon build script
# Bundles web/src/* into a single web/dist/index.html with CSS/JS inlined
# No external dependencies required

param(
    [switch]$Watch,
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"
$SCRIPT_DIR = $PSScriptRoot
$WEB_DIR = Join-Path $SCRIPT_DIR "web"
$SRC_DIR = Join-Path $WEB_DIR "src"
$DIST_DIR = Join-Path $WEB_DIR "dist"
$HTML_SOURCE = Join-Path $WEB_DIR "index.html"
$CSS_FILE = Join-Path $WEB_DIR "dashboard.css"

$MODULES = @(
    "1-config.js",
    "2-utils.js",
    "3-stream.js",
    "4-api.js",
    "5-render.js"
)

function Build {
    Write-Host "Building pcmon..." -ForegroundColor Cyan
    Write-Host "  Version: $Version"

    if (-not (Test-Path $SRC_DIR)) {
        Write-Error "Source directory not found: $SRC_DIR"
        exit 1
    }
    if (-not (Test-Path $HTML_SOURCE)) {
        Write-Error "HTML source not found: $HTML_SOURCE"
        exit 1
    }
    if (-not (Test-Path $CSS_FILE)) {
        Write-Error "CSS file not found: $CSS_FILE"
        exit 1
    }

    if (-not (Test-Path $DIST_DIR)) {
        New-Item -ItemType Directory -Path $DIST_DIR -Force | Out-Null
    }

    $html = Get-Content $HTML_SOURCE -Raw -Encoding UTF8

    Write-Host "  CSS:" -ForegroundColor Gray
    $css = Get-Content $CSS_FILE -Raw -Encoding UTF8
    $css = $css -replace '^@charset "[^"]+";?\r?\n?', ''
    Write-Host "    $(($css.Length / 1024).ToString('N1')) KB inlined" -ForegroundColor DarkGray

    Write-Host "  JS modules:" -ForegroundColor Gray
    $jsParts = @()
    foreach ($mod in $MODULES) {
        $path = Join-Path $SRC_DIR $mod
        if (-not (Test-Path $path)) {
            Write-Error "Missing module: $path"
            exit 1
        }
        $jsParts += Get-Content $path -Raw -Encoding UTF8
        Write-Host "    + $mod" -ForegroundColor DarkGray
    }
    $js = $jsParts -join "`n`n"
    Write-Host "    $(($js.Length / 1024).ToString('N1')) KB bundled" -ForegroundColor DarkGray

    $html = $html -replace '<link rel="stylesheet" href="dashboard\.css">', ("<style>`n" + $css + "`n</style>")

    $html = $html -replace '<script src="src/1-config\.js"></script>\s*', ''
    $html = $html -replace '<script src="src/2-utils\.js"></script>\s*', ''
    $html = $html -replace '<script src="src/3-stream\.js"></script>\s*', ''
    $html = $html -replace '<script src="src/4-api\.js"></script>\s*', ''
    $html = $html -replace '<script src="src/5-render\.js"></script>\s*', ''
    $html = $html -replace '<script src="dashboard\.js"></script>\s*', ''
    $html = $html -replace '</body>', ("<script>`n" + $js + "`n</script>`n</body>")

    $buildComment = '<!-- Built ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' v' + $Version + ' | Source: web/src/ -->'
    $html = $html -replace '(<meta charset)', ($buildComment + "`n" + '$1')

    $outPath = Join-Path $DIST_DIR "index.html"
    $html | Out-File -FilePath $outPath -Encoding UTF8 -NoNewline
    $sizeKB = [math]::Round((Get-Item $outPath).Length / 1024, 1)
    Write-Host "  Output: $outPath" -ForegroundColor Gray
    Write-Host "  Size: $sizeKB KB" -ForegroundColor Green

    $distHtml = Get-Content $outPath -Raw -Encoding UTF8
    $errors = @()
    if ($distHtml -match '<script src="src/') { $errors += "dead src/ script tags found" }
    if ($distHtml -match '<script src="dashboard\.js"') { $errors += "dead dashboard.js tag found" }
    if (-not ($distHtml -match '<!-- Built ')) { $errors += "build comment missing (not bundled?)" }
    if ($distHtml.Length -lt 10000) { $errors += "output suspiciously small" }
    if ($errors.Count -eq 0) {
        Write-Host "  Verified: no dead code, CSS+JS inlined." -ForegroundColor DarkGray
    } else {
        Write-Host "  VERIFY FAILED: $($errors -join '; ')" -ForegroundColor Red
        exit 1
    }

    Write-Host "Done." -ForegroundColor Green
    Write-Host "  Run '$SCRIPT_DIR\pcmon.ps1' to start." -ForegroundColor Gray

    return $outPath
}

if ($Watch) {
    Write-Host "Watch mode: building on file changes..." -ForegroundColor Cyan
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $SRC_DIR
    $watcher.Filter = "*.js"
    $watcher.IncludeSubdirectories = $false
    $watcher.EnableRaisingEvents = $true
    $action = {
        Start-Sleep -Milliseconds 200
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Change detected, rebuilding..." -ForegroundColor Yellow
        Build
    }
    $job = Register-ObjectEvent $watcher "Changed" -Action $action
    Write-Host "Watching $SRC_DIR for changes... (Ctrl+C to stop)"
    while ($true) { Start-Sleep -Seconds 1 }
} else {
    Build
}
