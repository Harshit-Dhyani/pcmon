# Changelog

All notable changes to pcmon will be documented in this file.

## [1.0.0] - 2026-03-20

### Added
- **Dashboard** - 11 tabs (Overview, RAM, CPU, Disk, GPU, Groups, Suspicious, Services, System, All Processes, Settings)
- **Process Actions** - Kill, Suspend, Resume processes from UI
- **Protected Processes** - System processes cannot be terminated
- **Snapshots** - Save labeled system snapshots
- **Compare** - Compare snapshots to see changes
- **Export** - JSON and CSV export for snapshots
- **Clipboard** - Copy process tables to clipboard
- **Alert Thresholds** - Configurable via Settings tab
- **PDF Reports** - Generate printable HTML reports
- **System Tray** - Run in background with -Tray flag
- **Live Wallpaper** - Live system stats as desktop wallpaper
- **GPU Metrics** - Adapter info, utilization, memory
- **Process Groups** - Browser/Electron, Dev Tools, Security tools tracking
- **Sparklines** - Historical trending visualization
- **Delta Indicators** - Show metric changes (up/down)
- **Diagnostic Insights** - Actionable system health explanations
- **CLI Parameters** - -Port, -NoOpen, -ApiOnly, -Tray, -Wallpaper, -Help

### Security
- XSS protection in dashboard
- Input validation on all API endpoints
- Protected process list
- No shell-string execution

### Architecture
- PowerShell-first core
- Plain HTML/CSS/JS frontend
- Direct .ps1 mode as first-class path
- Package-ready structure with regions

## [0.0.0] - 2026-01-01

### Added
- Initial release (placeholder)
