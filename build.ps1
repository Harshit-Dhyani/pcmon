# pcmon build script
# Bundles web/src/* into a single web/dist/index.html with CSS/JS inlined
# No external dependencies required

param(
    [switch]$Watch,
    [switch]$Embed,    # Also embed the generated HTML into pcmon.ps1
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"
$SCRIPT_DIR = $PSScriptRoot
$WEB_DIR = Join-Path $SCRIPT_DIR "web"
$SRC_DIR = Join-Path $WEB_DIR "src"
$DIST_DIR = Join-Path $WEB_DIR "dist"
$HTML_SOURCE = Join-Path $WEB_DIR "index.html"
$CSS_FILE = Join-Path $WEB_DIR "dashboard.css"
$MAIN_PS = Join-Path $SCRIPT_DIR "pcmon.ps1"

$MODULES = @(
    "1-config.js",
    "2-utils.js",
    "3-stream.js",
    "4-api.js",
    "5-render.js"
)

function Get-InlinedCSS {
    $css = Get-Content $CSS_FILE -Raw -Encoding UTF8
    # Remove @charset if present (set by HTML)
    $css = $css -replace '^@charset "[^"]+";?\r?\n?', ''
    $css
}

function Get-BundledJS {
    $parts = @()
    foreach ($mod in $MODULES) {
        $path = Join-Path $SRC_DIR $mod
        if (-not (Test-Path $path)) {
            Write-Error "Missing module: $path"
            exit 1
        }
        $content = Get-Content $path -Raw -Encoding UTF8
        $parts += $content
        Write-Host "  + $mod" -ForegroundColor DarkGray
    }
    $parts -join "`n`n"
}

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

    # Ensure dist dir
    if (-not (Test-Path $DIST_DIR)) {
        New-Item -ItemType Directory -Path $DIST_DIR -Force | Out-Null
    }

    # Read HTML template
    $html = Get-Content $HTML_SOURCE -Raw -Encoding UTF8

    # Read CSS
    Write-Host "  CSS:" -ForegroundColor Gray
    $css = Get-InlinedCSS
    Write-Host "    $(($css.Length / 1024).ToString('N1')) KB inlined" -ForegroundColor DarkGray

    # Bundle JS
    Write-Host "  JS modules:" -ForegroundColor Gray
    $js = Get-BundledJS
    Write-Host "    $(($js.Length / 1024).ToString('N1')) KB bundled" -ForegroundColor DarkGray

    # Replace stylesheet link (wrap replacement in parens to handle commas in CSS)
    $html = $html -replace '<link rel="stylesheet" href="dashboard\.css">', ("<style>`n" + $css + "`n</style>")

    # Replace script tags
    $html = $html -replace '<script src="dashboard\.js"></script>', ("<script>`n" + $js + "`n</script>")

    # Add build info comment (use single-quote concatenation to avoid PowerShell > redirect issue)
    $buildComment = '<!-- Built ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' v' + $Version + ' | Source: web/src/ -->'
    $html = $html -replace '(<meta charset)', ($buildComment + "`n" + '$1')

    # Write output
    $outPath = Join-Path $DIST_DIR "index.html"
    $html | Out-File -FilePath $outPath -Encoding UTF8 -NoNewline
    $sizeKB = [math]::Round((Get-Item $outPath).Length / 1024, 1)
    Write-Host "  Output: $outPath" -ForegroundColor Gray
    Write-Host "  Size: $sizeKB KB" -ForegroundColor Green

    # Also write bundled JS for pcmon.ps1 fallback (serves dashboard.js)
    $bundledJsPath = Join-Path $WEB_DIR "dashboard.js"
    $js | Out-File -FilePath $bundledJsPath -Encoding UTF8 -NoNewline
    $jsSizeKB = [math]::Round((Get-Item $bundledJsPath).Length / 1024, 1)
    Write-Host "  Bundled JS: $bundledJsPath ($jsSizeKB KB)" -ForegroundColor DarkGray

    Write-Host "Done." -ForegroundColor Green

    # Optionally embed into pcmon.ps1
    if ($Embed) {
        Write-Host "`nEmbedding into pcmon.ps1..." -ForegroundColor Cyan
        Embed-HTMLIntoPS1 -DistPath $outPath
    }

    return $outPath
}

function Embed-HTMLIntoPS1 {
    param([string]$DistPath)

    if (-not (Test-Path $MAIN_PS)) {
        Write-Error "pcmon.ps1 not found: $MAIN_PS"
        return
    }

    $content = Get-Content $MAIN_PS -Raw -Encoding UTF8

    # Find or create the embedded HTML section
    $embedMarker = '#region --- EMBEDDED FRONTEND ---'
    $embedEnd = '#endregion'

    # Generate Base64 representation
    $bytes = [System.IO.File]::ReadAllBytes($DistPath)
    $base64 = [Convert]::ToBase64String($bytes)

    # Check if section exists
    if ($content -match [regex]::Escape($embedMarker) + '[\s\S]*?' + [regex]::Escape($embedEnd)) {
        Write-Host "  Replacing existing embedded frontend section." -ForegroundColor Yellow
    } else {
        Write-Host "  Adding embedded frontend section." -ForegroundColor Gray
    }

    $embeddedSection = @"

$embedMarker
`$script:EmbeddedHTML = @'
$(Get-Content $DistPath -Raw)
'@
$embedEnd
"@

    # Remove existing embedded section if present
    $content = $content -replace [regex]::Escape($embedMarker) + '[\s\S]*?' + [regex]::Escape($embedEnd), ''

    # Find insertion point (after static files section or near end of setup)
    if ($content -match '(#region --- Static Files ---[\s\S]*?#endregion)') {
        $content = $content -replace '(#region --- Static Files ---[\s\S]*?#endregion)', "`$1`n$embeddedSection"
    } else {
        # Append at the end before the last closing brace or at the end
        $content = $content.TrimEnd() + "`n`n" + $embeddedSection + "`n"
    }

    $backupPath = $MAIN_PS + ".bak"
    Copy-Item $MAIN_PS $backupPath -Force
    $content | Out-File -FilePath $MAIN_PS -Encoding UTF8 -NoNewline
    Write-Host "  Backed up to: $backupPath" -ForegroundColor Yellow
    Write-Host "  Modified: $MAIN_PS" -ForegroundColor Green
    Write-Host "  Base64 size: $([math]::Round($base64.Length / 1024, 1)) KB" -ForegroundColor DarkGray
}

# ── Watch mode ────────────────────────────────────────────────────
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
