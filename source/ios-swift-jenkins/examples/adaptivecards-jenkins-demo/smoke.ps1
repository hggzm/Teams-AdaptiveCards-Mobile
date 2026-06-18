#!/usr/bin/env pwsh
# examples/adaptivecards-jenkins-demo/smoke.ps1
#
# Build and run the symbol-check demo on Windows MSVC. Threads the same
# vcpkg zlib include / libpath the parent kit needs (the Vapor/NIO
# substrate pulls NIOHTTPCompression, whose CNIOExtrasZlib C module wants
# <zlib.h>). Asserts the PASS marker line in stdout.

[CmdletBinding()]
param(
    [string]$ZlibInc = "",
    [string]$ZlibLib = "",
    [string]$VcpkgInstalled = ""
)

$ErrorActionPreference = 'Stop'

# If caller passed -ZlibInc + -ZlibLib (CI path), use those directly.
# Otherwise derive from -VcpkgInstalled or local fallbacks.
if (-not $ZlibInc -or -not $ZlibLib) {
    if (-not $VcpkgInstalled) {
        $tryRel = Resolve-Path ..\..\..\..\..\vcpkg_installed\x64-windows-static-md -ErrorAction SilentlyContinue
        if ($tryRel) { $VcpkgInstalled = $tryRel.Path }
    }
    if (-not $VcpkgInstalled -or -not (Test-Path $VcpkgInstalled)) {
        $fallback = 'C:\Users\hugogonzalez\code\swiftci\vcpkg_installed\x64-windows-static-md'
        if (Test-Path $fallback) { $VcpkgInstalled = $fallback }
    }
    if (-not $VcpkgInstalled -or -not (Test-Path $VcpkgInstalled)) {
        Write-Host "FAIL adaptivecards-jenkins-roundtrip: vcpkg_installed not found (pass -ZlibInc/-ZlibLib or -VcpkgInstalled)" -ForegroundColor Red
        exit 2
    }
    $ZlibInc = Join-Path $VcpkgInstalled 'include'
    $ZlibLib = Join-Path $VcpkgInstalled 'lib'
}

if (-not (Test-Path $ZlibInc)) {
    Write-Host "FAIL adaptivecards-jenkins-roundtrip: ZlibInc '$ZlibInc' does not exist" -ForegroundColor Red
    exit 2
}
if (-not (Test-Path $ZlibLib)) {
    Write-Host "FAIL adaptivecards-jenkins-roundtrip: ZlibLib '$ZlibLib' does not exist" -ForegroundColor Red
    exit 2
}

Push-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
try {
    Write-Host "=== swift build (demo) ==="
    & swift build -c debug `
        -Xcc      "-I$ZlibInc" `
        -Xswiftc  "-I$ZlibInc" `
        -Xlinker  "/LIBPATH:$ZlibLib"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL adaptivecards-jenkins-roundtrip: build exit=$LASTEXITCODE" -ForegroundColor Red
        exit $LASTEXITCODE
    }

    # SwiftPM placed the executable somewhere under .build/. We don't use
    # `swift run` because its linker invocation drops `-Xlinker /LIBPATH:`,
    # which makes zlib.lib unresolvable for NIOHTTPCompression on Windows.
    $exe = $null
    foreach ($c in @(
        '.\.build\debug\AdaptiveCardsDemo.exe',
        '.\.build\x86_64-unknown-windows-msvc\debug\AdaptiveCardsDemo.exe',
        '.\.build\arm64-unknown-windows-msvc\debug\AdaptiveCardsDemo.exe'
    )) {
        if (Test-Path $c) { $exe = (Resolve-Path $c).Path; break }
    }
    if (-not $exe) {
        $exe = Get-ChildItem -Recurse -Filter AdaptiveCardsDemo.exe -Path .\.build -ErrorAction SilentlyContinue |
               Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $exe) {
        Write-Host "FAIL adaptivecards-jenkins-roundtrip: built exe not found anywhere under .build" -ForegroundColor Red
        exit 3
    }
    Write-Host "exe: $exe"

    Write-Host "=== run demo ==="
    $out = & $exe 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { $_ }
    if ($rc -ne 0) {
        Write-Host "FAIL adaptivecards-jenkins-roundtrip: demo exit=$rc" -ForegroundColor Red
        exit $rc
    }
    if (-not ($out -match 'PASS adaptivecards-jenkins-roundtrip')) {
        Write-Host "FAIL adaptivecards-jenkins-roundtrip: PASS marker not found in output" -ForegroundColor Red
        exit 4
    }
    Write-Host ""
    Write-Host "PASS adaptivecards-jenkins-roundtrip" -ForegroundColor Green
}
finally {
    Pop-Location
}
