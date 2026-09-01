#!/usr/bin/env pwsh
# Runtime symbol-check smoke for the vendored SwiftSyncCore kit (flavor A —
# store / round-trip). Builds the demo, runs it, and gates on the PASS line.
# Exits non-zero on any failure so CI fails unless the PASS line prints.
#
# SwiftSyncCore is pure Foundation, so there are no zlib (-ZlibInc/-ZlibLib)
# parameters here, unlike the NIO-backed bridges.

param(
    # Optional unique SwiftPM scratch path, used locally to avoid build-DB lock
    # collisions when several bridge agents build in parallel. CI omits it.
    [string]$ScratchPath = ""
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PASS = 'PASS adaptivecards-swiftsync-roundtrip'

# Prime the Swift toolchain env from the registry (Windows DevBox); harmless in
# CI and elsewhere, where these scopes return nothing.
$machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
if ($machinePath) { $env:Path = "$machinePath;$userPath" }
$sdk = [System.Environment]::GetEnvironmentVariable('SDKROOT', 'User')
if ($sdk) { $env:SDKROOT = $sdk }

Push-Location $PSScriptRoot
try {
    $buildArgs = @('build', '-c', 'debug')
    $runArgs = @('run', '-c', 'debug', 'AdaptiveCardsDemo')
    if ($ScratchPath) {
        $buildArgs += @('--scratch-path', $ScratchPath)
        $runArgs += @('--scratch-path', $ScratchPath)
    }

    Write-Host "== build demo =="
    & swift @buildArgs
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: swift build failed" -ForegroundColor Red; exit 1 }

    Write-Host "== run demo =="
    $output = & swift @runArgs 2>&1
    $output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: demo exited $LASTEXITCODE" -ForegroundColor Red; exit 1 }

    if (($output -join "`n") -match [regex]::Escape($PASS)) {
        Write-Host "smoke OK: '$PASS' observed" -ForegroundColor Green
        exit 0
    }
    Write-Host "FAIL: '$PASS' not found in demo output" -ForegroundColor Red
    exit 1
}
finally {
    Pop-Location
}
