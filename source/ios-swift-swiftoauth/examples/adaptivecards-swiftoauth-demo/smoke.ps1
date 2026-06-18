#!/usr/bin/env pwsh
# smoke.ps1 — Windows MSVC runtime symbol-check.
#
# Builds the adaptivecards-swiftoauth-demo executable against the
# vendored swiftoauth kit, runs it, and asserts the success line.
# Exit non-zero on any failure.
#
# This drop (SwiftOAuthCore + SwiftOAuthServer, loopback callback server
# only) does NOT need zlib: Hummingbird's HTTP/1 runtime pulls swift-nio
# + swift-nio-extras but not nio-ssl/compression. The optional
# -ZlibInc/-ZlibLib parameters are accepted for template compatibility
# and threaded through only if a caller supplies them.
#
# On Windows the demo builds into a SHORT scratch path. Hummingbird
# pulls swift-async-algorithms, whose deeply-nested file names (e.g.
# MultiProducerSingleConsumerAsyncChannel+Internal.swift) overflow the
# 260-char MAX_PATH limit when combined with this example's already-deep
# location, breaking llbuild. A short -ScratchPath keeps every input
# path under the limit.

[CmdletBinding()]
param(
    [string]$ZlibInc = '',
    [string]$ZlibLib = '',
    [string]$ScratchPath = ''
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

# Default to a short scratch path on Windows to dodge MAX_PATH. It MUST live on
# the same drive as this package: `swift run` computes the executable's path
# relative to the package dir, and a cross-drive relative path (e.g. package on
# D:, scratch on C:) cannot be formed — it mangles into a bogus
# `..\..\C:\...` and fails with "No such file or directory". So derive the
# drive from this script's own location.
if (-not $ScratchPath -and $IsWindows) {
    $drive = (Get-Item $here).PSDrive.Name
    $ScratchPath = "${drive}:\b\sao"
}
if ($ScratchPath) {
    $extra += @('--scratch-path', $ScratchPath)
    New-Item -ItemType Directory -Force -Path $ScratchPath | Out-Null
    Write-Host "scratch-path: $ScratchPath"
}

Write-Host '=== swift build -c debug ===' -ForegroundColor Cyan
& swift build -c debug @extra
if ($LASTEXITCODE -ne 0) {
    Write-Host 'FAIL adaptivecards-swiftoauth-build' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '=== run AdaptiveCardsDemo ===' -ForegroundColor Cyan
# Execute the built binary DIRECTLY rather than via `swift run`. `swift run`
# re-derives a (possibly cross-drive) relative path to the executable and can
# fail to launch it on the runner; running the produced .exe avoids that
# entirely. Locate it under the scratch/build dir.
$buildDir = if ($ScratchPath) { $ScratchPath } else { Join-Path $here '.build' }
$exe = Get-ChildItem -Path $buildDir -Recurse -Filter 'AdaptiveCardsDemo.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $exe) {
    # POSIX / non-.exe fallback.
    $exe = Get-ChildItem -Path $buildDir -Recurse -Filter 'AdaptiveCardsDemo' -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer } | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $exe) {
    Write-Host 'FAIL adaptivecards-swiftoauth-run (executable not found)' -ForegroundColor Red
    exit 1
}
Write-Host "exe: $exe"
$output = & $exe 2>&1 | Out-String
Write-Host $output

if ($LASTEXITCODE -ne 0) {
    Write-Host 'FAIL adaptivecards-swiftoauth-run (non-zero exit)' -ForegroundColor Red
    exit 1
}

if ($output -notmatch 'PASS adaptivecards-swiftoauth-http') {
    Write-Host 'FAIL adaptivecards-swiftoauth-assertion (PASS line not found)' -ForegroundColor Red
    exit 1
}

Write-Host 'smoke OK' -ForegroundColor Green
exit 0
