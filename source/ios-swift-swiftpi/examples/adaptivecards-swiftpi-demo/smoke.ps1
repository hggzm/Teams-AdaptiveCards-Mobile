#!/usr/bin/env pwsh
# smoke.ps1 — Windows MSVC runtime symbol-check.
#
# Builds the adaptivecards-swiftpi-demo executable against the
# vendored swiftpi kit, runs it, and asserts the success line.
# Exit non-zero on any failure.

[CmdletBinding()]
param(
    # Path to the vcpkg-installed zlib include dir. Required on Windows
    # MSVC because hggz/swift-nio-extras's CNIOExtrasZlib C module
    # cannot otherwise find <zlib.h>. CI sets this; local callers may
    # leave it empty if their toolchain already exposes zlib.
    [string]$ZlibInc = '',
    [string]$ZlibLib = ''
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
Set-Location $here

$extra = @()
if ($ZlibInc) {
    $extra += @('-Xcc', "-I$ZlibInc", '-Xswiftc', "-I$ZlibInc")
}
if ($ZlibLib) {
    $extra += @('-Xlinker', "/LIBPATH:$ZlibLib")
}

Write-Host '=== swift build -c debug ===' -ForegroundColor Cyan
& swift build -c debug @extra
if ($LASTEXITCODE -ne 0) {
    Write-Host 'FAIL adaptivecards-swiftpi-build' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '=== swift run AdaptiveCardsDemo ===' -ForegroundColor Cyan
$output = & swift run -c debug @extra AdaptiveCardsDemo 2>&1 | Out-String
Write-Host $output

if ($LASTEXITCODE -ne 0) {
    Write-Host 'FAIL adaptivecards-swiftpi-run (non-zero exit)' -ForegroundColor Red
    exit 1
}

if ($output -notmatch 'PASS adaptivecards-swiftpi-agentloop') {
    Write-Host 'FAIL adaptivecards-swiftpi-assertion (PASS line not found)' -ForegroundColor Red
    exit 1
}

Write-Host 'smoke OK' -ForegroundColor Green
exit 0
