<#
.SYNOPSIS
    Runtime symbol-check smoke for the vendored swiftharness bridge.

.DESCRIPTION
    Builds the demo SwiftPM package, runs it, and verifies that the
    canonical "PASS adaptivecards-swiftharness-roundtrip" line is
    written to stdout. Exits non-zero on any deviation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
Set-Location $here

Write-Host "=== adaptivecards-swiftharness-demo smoke ===" -ForegroundColor Cyan

Write-Host "--- swift build -c debug ---" -ForegroundColor Cyan
swift build -c debug
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: swift build exited $LASTEXITCODE" -ForegroundColor Red
    exit 1
}

Write-Host "--- swift run AdaptiveCardsDemo ---" -ForegroundColor Cyan
$output = swift run AdaptiveCardsDemo 2>&1
$exit = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }

if ($exit -ne 0) {
    Write-Host "FAIL: demo exited $exit" -ForegroundColor Red
    exit $exit
}

$needle = "PASS adaptivecards-swiftharness-roundtrip"
$hit = $output | Where-Object { $_ -match [regex]::Escape($needle) }
if (-not $hit) {
    Write-Host "FAIL: '$needle' not found on stdout" -ForegroundColor Red
    exit 2
}

Write-Host "=== smoke green ===" -ForegroundColor Green
exit 0
