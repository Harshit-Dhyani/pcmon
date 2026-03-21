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
4. Test thoroughly
5. Submit a pull request

## Code Structure

```
pcmon/
  pcmon.ps1          # Main entry - data collection, HTTP server (~1450 lines)
  web/
    index.html       # Dashboard HTML (~650 lines)
    dashboard.js    # Dashboard JavaScript (~1440 lines)
    dashboard.css   # Dashboard styles (~880 lines)
  wallpaper/
    index.html       # Live wallpaper HTML
```

## Adding Features

### Process Actions
- Add API route in pcmon.ps1 HTTP handler
- Add JS handler in dashboard.js
- Add button in index.html
- Test with protected processes

### Real-Time Stream
- `/stream` endpoint handles both WebSocket (via AcceptWebSocketAsync) and SSE
- `Broadcast-WebSocketData` function sends to all connected clients
- Fast metrics timer (50ms) sends lightweight updates
- Check connection method via `$script:ConnectionMethod`

### Insights
- Modify insight generation in `_CollectLiveData` function
- Keep explanations actionable

### Dashboard UI
- Add tab in index.html with `data-page` attribute
- Add page section with `id="pg-{name}"`
- Add rendering logic in dashboard.js
- Use `esc()` for all user data in innerHTML

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
- Refresh rate - change to 1s and verify fast updates

## Guidelines

- Keep changes minimal and focused
- Preserve existing behavior
- Add XSS protection for user data
- Validate all inputs
- Don't expose internal errors to users

## Questions

Open an issue for questions about contributing.
