# Changelog

All notable changes to pcmon will be documented in this file.

## [1.0.0] - 2026-03-21

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
- **CLI Parameters** - -NoOpen, -ApiOnly, -Debug, -Tray, -Wallpaper, -Help

### Fixed
- **JSON truncation** - Changed serialization depth from 5 to 20
- **Client disconnect crashes** - Added try-catch around OutputStream.Write
- **File lock conflicts** - Background process uses retry with exclusive file mode
- **Counter path case sensitivity** - All counter paths uppercased for consistency
- **Empty array errors** - /api/snapshots now handles empty directories gracefully
- **Cache-first architecture** - Snapshot/compare/report endpoints read from cache file first
- **Background process crashes** - Fixed param handling, profile paths via temp file

### Security
- XSS protection in dashboard (uses `esc()` function)
- Input validation on all API endpoints
- Protected process list
- No shell-string execution
- Confirmation header required for process actions

### Architecture
- PowerShell-first core
- Plain HTML/CSS/JS frontend
- Direct .ps1 mode as first-class path
- Background process for continuous data collection
- File-based cache for cross-process data sharing
- Debug mode with `-Debug` flag for verbose logging

## [0.0.0] - 2026-01-01

### Added
- Initial release (placeholder)
