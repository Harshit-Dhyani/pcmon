# pcmon

Local-first Windows diagnostics in one PowerShell script and a lightweight browser dashboard.

pcmon helps you understand what is consuming CPU, memory, disk, GPU, network, services, startup items, and process groups on a Windows machine. It is built for truthful diagnostics: unsupported, stale, warming, or missing collectors are surfaced clearly instead of being hidden behind fake zeroes.

> Status: active development. Public interfaces are intended to remain compatible, but internals and diagnostics may continue to evolve.

## Highlights

- **Local-first by design**: no cloud service, telemetry, account, or external runtime.
- **PowerShell-native collection**: uses Windows and PowerShell APIs directly.
- **Plain web dashboard**: HTML, CSS, and JavaScript only; no React, Vue, Angular, Electron, or Tauri.
- **Stable live data**: fast metric packets update cards and trends without wiping full process tables or static sections.
- **Truthful collector state**: `/data` includes `collection_state`, `cache_age_ms`, and per-subsystem states.
- **Safe process actions**: kill, suspend, and resume require explicit confirmation and block protected system processes.
- **Snapshots and reports**: save, compare, export, and print system state locally.

## Quick Start

Run from the repository root:

```powershell
.\pcmon.ps1
```

Or with PowerShell Core:

```powershell
pwsh -File .\pcmon.ps1
```

Then open the printed local URL, usually:

```text
http://localhost:9876/
```

## Requirements

- Windows
- Windows PowerShell 5.1+ or PowerShell 7+
- A modern browser
- Optional administrator rights for the most complete process and counter visibility

## Usage

```powershell
.\pcmon.ps1              # Start server and open the dashboard
.\pcmon.ps1 -NoOpen      # Start API/dashboard server without opening a browser
.\pcmon.ps1 -ApiOnly     # Alias-style API-only mode
.\pcmon.ps1 -Debug       # Enable verbose runtime logging
.\pcmon.ps1 -Port 8080   # Use a specific local port
.\pcmon.ps1 -Tray        # Run with tray integration when supported
.\pcmon.ps1 -Wallpaper   # Serve the live wallpaper view
.\pcmon.ps1 -Help        # Show all options
```

## Dashboard

pcmon includes 11 diagnostic views:

| Tab | Focus |
| --- | --- |
| Overview | RAM, commit, CPU, disk, current issues, and sparklines |
| RAM | Availability, commit pressure, private memory, paged/non-paged pool |
| CPU | Utilization, paging activity, queue signals, CPU identity |
| Disk | Activity, queue, read/write throughput, drive usage |
| GPU | Adapter identity, engine utilization, VRAM where Windows exposes it |
| Groups | Browser/Electron, developer tools, and security tool memory groups |
| Suspicious | High-resource or unusual process candidates |
| Services | Heavy services and startup items |
| System | Drives, pagefile, PowerShell profiles, network adapters |
| All Processes | Full process inventory with filtering and actions |
| Settings | Thresholds, refresh cadence, connection/debug information |

## Data Freshness Model

pcmon intentionally separates fast metrics from heavier inventory data.

- Fast metrics run at the configured cadence, default `500ms`.
- Tables and static sections refresh more slowly to avoid constant full rerenders.
- `_fast` stream packets update only summary cards, timestamps, trends, and sparklines.
- Full payloads preserve `top_ram`, `top_private`, `top_cpu`, `all_processes`, `startup`, `heavy_services`, `groups`, `disks`, `pagefile`, GPU adapters, and network adapters until a fresh full replacement is available.
- Section skeletons remain visible until that section's owning subsystem has settled.

The refresh selector supports `500ms` through `10000ms`.

## Collector State

The `/data` payload includes non-breaking metadata for diagnostics and UI honesty:

```json
{
  "collection_state": "valid",
  "cache_age_ms": 120,
  "subsystems": {
    "counters": "valid",
    "processes": "valid",
    "gpu": "unsupported",
    "network": "valid",
    "static": "valid"
  }
}
```

Subsystem states may include `valid`, `unsupported`, `missing`, `stale`, `warming`, `transiently_unavailable`, or `error`.

## API Reference

All endpoints are local to the running pcmon instance.

| Route | Method | Description |
| --- | --- | --- |
| `/` | GET | Dashboard HTML |
| `/health` | GET | Cheap server health check |
| `/data` | GET | Live system data JSON |
| `/stream` | GET | WebSocket or SSE live stream |
| `/api/export` | GET | Export current live data as JSON |
| `/api/report` | GET | Printable HTML report |
| `/api/report/download` | GET | Download report HTML |
| `/api/config` | GET/POST | Read or save alert thresholds |
| `/api/refresh-rate` | POST | Save refresh rate in milliseconds |
| `/api/process/{pid}/kill` | POST | Kill process, requires confirmation header |
| `/api/process/{pid}/suspend` | POST | Suspend process, requires confirmation header |
| `/api/process/{pid}/resume` | POST | Resume process, requires confirmation header |
| `/api/snapshots` | GET | List saved snapshots |
| `/api/snapshots` | POST | Save a snapshot |
| `/api/snapshots/{id}/compare` | POST | Compare current data to a snapshot |
| `/api/snapshots/{id}/export` | GET | Export snapshot JSON |
| `/api/snapshots/{id}/export.csv` | GET | Export snapshot CSV |
| `/api/snapshots/{id}` | DELETE | Delete snapshot |
| `/errors` | GET | Recent runtime errors |
| `/debug` | GET | Debug state |
| `/logs` | GET | Plain text runtime logs |
| `/wallpaper.html` | GET | Live wallpaper page |

Process action endpoints require:

```text
X-PCMON-Confirm: 1
```

## Architecture

```text
pcmon/
├── pcmon.ps1              # Generated runnable script
├── dist/
│   └── index.html         # Generated dashboard with CSS and JS inlined
├── src/
│   ├── build.ps1          # Build script
│   ├── backend/           # PowerShell source modules
│   └── web/               # Dashboard source
├── wallpaper/             # Live wallpaper assets and notes
├── snapshots/             # Local snapshots, created on use
└── config.json            # Local threshold config, created on use
```

Source of truth:

- Backend: `src/backend/*.ps1`
- Frontend: `src/web/*`
- Generated outputs: `pcmon.ps1`, `dist/index.html`

Rebuild after source changes:

```powershell
.\src\build.ps1
```

The build strips backend region markers, removes BOMs, inlines frontend CSS/JS, and validates duplicate PowerShell function definitions.

## Runtime Files

pcmon stores local runtime state in port-scoped files so multiple instances do not collide:

```text
$env:TEMP\pcmon_live_cache_<port>.json
$env:TEMP\pcmon_refresh_rate_<port>.txt
$env:TEMP\pcmon_errors_<port>.log
```

Snapshots and configuration stay in the repository working directory unless the user moves the project.

## Security Model

- Localhost-only diagnostics server.
- No telemetry or outbound cloud dependency.
- No shell-string execution for process actions.
- Method and input validation at API boundaries.
- Snapshot IDs are validated before lookup, compare, export, or delete.
- Process IDs are parsed as numeric values.
- Kill, suspend, and resume require `X-PCMON-Confirm: 1`.
- Protected system processes are blocked from kill, suspend, and resume actions.
- Dashboard and report values are HTML-escaped before rendering.
- SSE uses localhost-only CORS rules, not wildcard `*`.

See [SECURITY.md](SECURITY.md) for more detail.

## Development

Recommended validation before committing:

```powershell
.\src\build.ps1
node --check src\web\src\1-config.js
node --check src\web\src\2-utils.js
node --check src\web\src\3-stream.js
node --check src\web\src\4-api.js
node --check src\web\src\5-render.js
```

For runtime smoke testing:

```powershell
.\pcmon.ps1 -NoOpen -Debug -Port 9876
Invoke-RestMethod http://localhost:9876/health
Invoke-RestMethod http://localhost:9876/data | ConvertTo-Json -Depth 20
```

## Documentation

- [CHANGELOG.md](CHANGELOG.md) - notable changes
- [CONTRIBUTING.md](CONTRIBUTING.md) - contribution workflow
- [SECURITY.md](SECURITY.md) - security policy and local API boundary
- [docs/tree.md](docs/tree.md) - source tree and generated artifacts
- [wallpaper/DEBUG.md](wallpaper/DEBUG.md) - debug endpoints and troubleshooting

## License

MIT
