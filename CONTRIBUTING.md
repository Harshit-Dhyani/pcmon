# Contributing to pcmon

Thank you for your interest in contributing to pcmon!

## Development Philosophy

pcmon is a **local-first Windows diagnostics tool** with these principles:

- **PowerShell-first** - Core logic in PowerShell
- **Plain frontend** - HTML/CSS/JS without frameworks
- **Local-only** - No cloud, no external services
- **Diagnostic-focused** - Metrics with actionable insights

## Getting Started

1. Clone the repository
2. Run `.\pcmon.ps1` to test
3. Make your changes
4. Rebuild with `.\src\build.ps1`
5. Test thoroughly
6. Submit a pull request

## Code Structure

```
pcmon/
  pcmon.ps1          # Generated runnable script; rebuild instead of editing by hand
  dist/
    index.html       # Generated dashboard with CSS+JS inlined
  src/
    build.ps1        # Builds backend and frontend outputs
    backend/
      00-config.ps1
      01-logging.ps1
      02-http-helpers.ps1
      03-actions.ps1
      04-snapshots.ps1
      05-collectors.ps1
      06-background.ps1
      07-server.ps1
      main.ps1
    web/
      index.html
      dashboard.css
      src/
        1-config.js
        2-utils.js
        3-stream.js
        4-api.js
        5-render.js
  wallpaper/
    index.html       # Live wallpaper HTML
```

Source of truth:
- Backend changes go in `src/backend/*.ps1`
- Frontend changes go in `src/web/*`
- Build outputs are `pcmon.ps1` and `dist/index.html`
- Do not edit generated outputs as the source fix

## Adding Features

### Process Actions
- Add API route in `src/backend/07-server.ps1`
- Add process implementation in `src/backend/03-actions.ps1` when needed
- Add JS API/rendering behavior in `src/web/src/4-api.js` or `src/web/src/5-render.js`
- Require `X-PCMON-Confirm: 1` for kill, suspend, and resume
- Test with protected processes; protected process guards must cover all actions

### Real-Time Stream
- `/stream` endpoint handles both WebSocket (via AcceptWebSocketAsync) and SSE
- `Broadcast-WebSocketData` function sends to all connected clients
- Fast packets are marked `_fast` and may update only summary metrics, timestamps, trends, and sparklines
- Full table/static sections must keep the last full payload until a replacement full payload arrives
- SSE must keep localhost-only CORS behavior

### Insights
- Modify insight generation in `Get-LiveData` and the background collector script content
- Keep explanations actionable
- Do not represent unsupported or missing counters as valid zeroes

### Dashboard UI
- Add tab in `src/web/index.html` with `data-page` attribute
- Add page section with `id="pg-{name}"`
- Add rendering logic in the matching `src/web/src/*.js` module
- Use `esc()` for all user data in innerHTML
- Gate skeleton removal on real section readiness, not just the first partial packet
- Avoid inline event handlers for dynamic IDs; use data attributes and event listeners

## Testing

Test your changes:
```powershell
.\pcmon.ps1 -NoOpen
# Then visit http://localhost:9876
```

Test with debug mode:
```powershell
.\pcmon.ps1 -Debug
# Shows detailed background collection timing
# Shows client disconnect errors gracefully
```

Test specific features:
- Process actions - try killing a notepad process
- Snapshots - save and compare
- Config - change thresholds in Settings tab
- Refresh rate - change to 1s and verify fast metric updates without clearing tables
- `/health` - should answer quickly during startup
- `/data` - should return valid JSON with `collection_state`, `cache_age_ms`, and `subsystems`

Static validation:
```powershell
.\src\build.ps1

$paths = @(
  'src\backend\00-config.ps1',
  'src\backend\01-logging.ps1',
  'src\backend\02-http-helpers.ps1',
  'src\backend\03-actions.ps1',
  'src\backend\04-snapshots.ps1',
  'src\backend\05-collectors.ps1',
  'src\backend\06-background.ps1',
  'src\backend\07-server.ps1',
  'pcmon.ps1'
)
foreach ($path in $paths) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path), [ref]$tokens, [ref]$errors) > $null
  if ($errors.Count -gt 0) { throw "$path parse failed" }
}

node --check src\web\src\1-config.js
node --check src\web\src\2-utils.js
node --check src\web\src\3-stream.js
node --check src\web\src\4-api.js
node --check src\web\src\5-render.js
```

## Guidelines

- Keep changes minimal and focused
- Preserve existing behavior
- Add XSS protection for user data
- Validate all inputs
- Don't expose internal errors to users
- Keep `/health` cheap and independent from collector warmup
- Preserve last known good entity data during transient collector misses
- Rebuild generated artifacts before committing source changes

## Questions

Open an issue for questions about contributing.
