# PCMON Debug Guide

## Error Endpoints

When pcmon is running, access these URLs to debug issues:

### `/errors`
Get recent errors and system info:
```powershell
# View errors
Invoke-RestMethod http://localhost:9876/errors | ConvertTo-Json
```

### `/logs`
Get raw log output:
```powershell
Invoke-RestMethod http://localhost:9876/logs
```

### `/debug`
Get internal debug info:
```powershell
Invoke-RestMethod http://localhost:9876/debug | ConvertTo-Json
```

## Error Log File

Errors are also saved to:
```
$env:TEMP\pcmon_errors.log
```

View it with:
```powershell
Get-Content $env:TEMP\pcmon_errors.log
```

## Frontend Debugging (Wallpaper/Dashboard)

Open browser console (F12) and use:

```javascript
// View captured errors
window.pcmonDebug.errors

// View current config
window.pcmonDebug.config

// Force refresh data
window.pcmonDebug.fetch()

// Get all available debug methods
Object.keys(window.pcmonDebug)
```

## Common Issues & Fixes

### 1. "JSON truncated" Warning
**Cause:** Data depth exceeds limit
**Fix:** Already fixed in current version (depth=20)

### 2. API returns empty/slow data
**Check:**
```powershell
# Test API directly
Invoke-RestMethod http://localhost:9876/data | ConvertTo-Json -Depth 5

# Check if counters exist
Get-Counter -ListSet *Memory* | Select-Object CounterSetName
Get-Counter -ListSet *Processor* | Select-Object CounterSetName
```

### 3. GPU not detected
**Check:**
```powershell
# Verify GPU counters exist
Get-Counter -ListSet *GPU* 
# or
Get-Counter "\GPU*"

# Check video adapters
Get-CimInstance Win32_VideoController | Select-Object Name, Status
```

### 4. Browser can't connect
```powershell
# Check if server is running
Invoke-RestMethod http://localhost:9876/health

# Check firewall
netsh advfirewall firewall add rule --help

# Try different port
.\pcmon.ps1 -Port 8080
```

### 5. Wallpaper not displaying
- Make sure pcmon is running first
- Use Edge/Chrome for best compatibility
- Check browser console for JS errors

## Enable Verbose Logging

Edit pcmon.ps1 and add:
```powershell
$VerbosePreference = "Continue"
$DebugPreference = "Continue"
```

## Performance Issues

Check refresh rate:
```powershell
# In browser console
console.log(window.pcmonDebug.config.refreshRate)

// Slow? Increase interval in config
```

## Report Issues

When reporting issues, include:
1. Output of `http://localhost:9876/errors`
2. Output of `http://localhost:9876/debug`  
3. Browser console errors (F12)
4. OS and PowerShell version
