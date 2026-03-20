#!/usr/bin/env pwsh
# pcmon CLI wrapper shim
# Future package-manager entry point (npm/pnpm/bun)
# Resolves the script directory relative to this file, then launches pcmon.ps1

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

$rootDir = $SCRIPT_DIR
while ($rootDir -and (Test-Path "$rootDir/pcmon.ps1") -eq $false) {
    $parent = Split-Path -Parent $rootDir
    if ($parent -eq $rootDir) {
        Write-Host "[pcmon] Error: Could not locate pcmon.ps1" -ForegroundColor Red
        exit 1
    }
    $rootDir = $parent
}

$scriptPath = Join-Path $rootDir "pcmon.ps1"

$argsToForward = $args

& $scriptPath @argsToForward
