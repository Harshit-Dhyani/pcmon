# pcmon Tree

Generated from the live workspace on 2026-06-01. This file documents the source-of-truth layout and the generated runtime artifacts that are currently committed.

```text
pcmon/
├── AGENTS.md
├── CHANGELOG.md
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── LICENSE
├── README.md
├── SECURITY.md
├── config.json
├── dist/
│   └── index.html                  # generated dashboard, CSS+JS inlined
├── docs/
│   └── tree.md
├── package.json                    # package version: 1.0.0
├── pcmon.ps1                       # generated runnable PowerShell script
├── snapshots/                      # local saved snapshots
├── src/
│   ├── build.ps1                   # builds frontend and backend artifacts
│   ├── backend/
│   │   ├── 00-config.ps1           # parameters, paths, thresholds, protected names
│   │   ├── 01-logging.ps1          # Write-Log / Write-Err
│   │   ├── 02-http-helpers.ps1     # JSON/binary responses, HTML escape, WS send
│   │   ├── 03-actions.ps1          # kill/suspend/resume process actions
│   │   ├── 04-snapshots.ps1        # snapshot save/list/compare/export helpers
│   │   ├── 05-collectors.ps1       # live data, static caches, process groups
│   │   ├── 06-background.ps1       # background collector process script
│   │   ├── 07-server.ps1           # HttpListener routes, reports, stream, startup
│   │   └── main.ps1                # thin source entry point
│   └── web/
│       ├── dashboard.css           # dashboard styles
│       ├── index.html              # dashboard template
│       └── src/
│           ├── 1-config.js         # PCM state and constants
│           ├── 2-utils.js          # formatting, skeletons, sparklines, fast updates
│           ├── 3-stream.js         # WebSocket/SSE stream handling
│           ├── 4-api.js            # REST API client and loading payload handling
│           └── 5-render.js         # render engine, settings, snapshots, debug panel
├── wallpaper/
│   ├── DEBUG.md
│   ├── index.html
│   └── project.json
└── web/                            # legacy/static public folder, currently empty
```

## Build Outputs

- `pcmon.ps1` is built from `src/backend/*.ps1`.
- `dist/index.html` is built from `src/web/index.html`, `src/web/dashboard.css`, and `src/web/src/*.js`.
- Rebuild with `.\src\build.ps1` after source edits.
- Do not edit generated files as the source of truth.

## Runtime Temp Files

pcmon uses port-scoped temp files so multiple local instances do not collide:

```text
$env:TEMP\pcmon_live_cache_<port>.json
$env:TEMP\pcmon_refresh_rate_<port>.txt
$env:TEMP\pcmon_errors_<port>.log
```
