# pcmon

Local-first Windows system monitoring and diagnostics tool.

## Quick Start

```powershell
.\pcmon.ps1
```

Or with PowerShell Core:

```powershell
pwsh -File .\pcmon.ps1
```

## Usage

```powershell
.\pcmon.ps1              # defaults: opens browser, 4s refresh
.\pcmon.ps1 -NoOpen      # API-only mode, no browser auto-open
.\pcmon.ps1 -ApiOnly     # same as -NoOpen
.\pcmon.ps1 -Debug       # enable verbose debug logging
.\pcmon.ps1 -Tray        # system tray mode (runs in background)
.\pcmon.ps1 -Wallpaper   # live wallpaper mode
.\pcmon.ps1 -Help        # show all options
```

## Features

### Dashboard Tabs
- **Overview** — RAM, commit, CPU, disk at a glance with sparklines
- **RAM** — paged/non-paged pool, private memory breakdown
- **CPU** — CPU utilization, queue, paging activity
- **Disk** — disk activity, drives with usage bars
- **GPU** — adapter info, utilization, memory (if available)
- **Groups** — Browser/Electron, Dev Tools, Security tools memory
- **Suspicious** — high-resource processes detection
- **Services** — heavy services and startup items
- **System** — drives, page file, PowerShell profiles
- **All Processes** — full process list with filtering
- **Settings** — configurable alert thresholds

### Process Actions
- **Kill** — terminate a process (with confirmation)
- **Suspend** — pause a process
- **Resume** — resume a suspended process

Protected system processes cannot be terminated.

### Snapshots
- Save labeled snapshots of system state
- Compare snapshots to see what changed
- Export to JSON or CSV

### Reports
- Generate printable HTML reports
- Save as PDF via browser print dialog

### Insights
Real-time diagnostic insights:
- High RAM vs commit pressure distinction
- Paging / disk thrashing detection
- Non-paged pool (driver leak detection)
- Browser/Electron/Dev tool overhead
- Disk bottlenecks

### Alert Thresholds
Customizable thresholds for:
- RAM usage %
- CPU usage %
- Commit charge %
- Pages/sec
- Non-paged pool MB
- Disk usage %

## API Routes

| Route | Method | Description |
|-------|--------|-------------|
| `/` | GET | Dashboard HTML |
| `/data` | GET | Live system data JSON |
| `/dashboard.js` | GET | JavaScript |
| `/dashboard.css` | GET | Styles |
| `/api/process/{pid}/kill` | POST | Kill process |
| `/api/process/{pid}/suspend` | POST | Suspend process |
| `/api/process/{pid}/resume` | POST | Resume process |
| `/api/snapshots` | GET | List snapshots |
| `/api/snapshots` | POST | Save snapshot |
| `/api/snapshots/{id}/compare` | POST | Compare snapshot |
| `/api/snapshots/{id}/export` | GET | Export JSON |
| `/api/snapshots/{id}/export.csv` | GET | Export CSV |
| `/api/config` | GET/POST | Alert thresholds |
| `/api/refresh-rate` | POST | Set refresh rate (ms) |
| `/api/report` | GET | Printable report |
| `/api/report/download` | GET | Download report |
| `/health` | GET | Server health status |
| `/errors` | GET | Error log |
| `/debug` | GET | Debug info |
| `/logs` | GET | Plain text logs |
| `/wallpaper.html` | GET | Live wallpaper |

## File Layout

```
pcmon/
  pcmon.ps1          # main entry point
  config.json        # saved alert thresholds (created on first use)
  snapshots/         # saved snapshots (created on first use)
  web/
    index.html      # dashboard
    dashboard.js    # UI logic
    dashboard.css   # styles
```

## Architecture

### Background Data Collection
- Separate PowerShell process collects data continuously
- Writes to temp JSON cache file every ~3.5s
- Main server reads from cache for fast response
- Falls back to synchronous collection if background fails

### Refresh Rate
- Configurable from Settings tab (1s - 30s)
- Default: 4 seconds
- Minimum: 1 second (500ms minimum enforced server-side)

## Requirements

- Windows with PowerShell 5.1+ or PowerShell Core (pwsh)
- Web browser for the dashboard
- Admin privileges for full accuracy (optional)

## Design Principles

- **Local-first**: all data stays on your machine
- **Diagnostic-focused**: raw metrics with actionable interpretation
- **PowerShell-first**: native Windows access without external dependencies
- **Lightweight**: plain HTML/CSS/JS, no React
- **One core, multiple entry modes**: direct PS1, CLI package, optional desktop shell

## Security

- Process actions require confirmation header (`X-PCMON-Confirm: 1`)
- Protected system processes cannot be terminated
- Input validation on all API endpoints
- No shell-string execution
- XSS protection in dashboard (uses `esc()` function)

## License

MIT
