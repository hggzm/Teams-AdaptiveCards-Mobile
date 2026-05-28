# examples/adaptivecards-giteax-demo/smoke.ps1
#
# Build and run the symbol-check demo on Windows MSVC. Threads the same
# vcpkg zlib include / libpath the parent kit needs (libgit2 + Csqlite3
# both want zlib's headers). Asserts the PASS marker line in stdout.

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
        $fallback = 'C:\Users\hugogonzalez\code\giteax\vcpkg_installed\x64-windows-static-md'
        if (Test-Path $fallback) { $VcpkgInstalled = $fallback }
    }
    if (-not $VcpkgInstalled -or -not (Test-Path $VcpkgInstalled)) {
        Write-Host "FAIL adaptivecards-giteax-roundtrip: vcpkg_installed not found (pass -ZlibInc/-ZlibLib or -VcpkgInstalled)" -ForegroundColor Red
        exit 2
    }
    $ZlibInc = Join-Path $VcpkgInstalled 'include'
    $ZlibLib = Join-Path $VcpkgInstalled 'lib'
}

if (-not (Test-Path $ZlibInc)) {
    Write-Host "FAIL adaptivecards-giteax-roundtrip: ZlibInc '$ZlibInc' does not exist" -ForegroundColor Red
    exit 2
}
if (-not (Test-Path $ZlibLib)) {
    Write-Host "FAIL adaptivecards-giteax-roundtrip: ZlibLib '$ZlibLib' does not exist" -ForegroundColor Red
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
        Write-Host "FAIL adaptivecards-giteax-roundtrip: build exit=$LASTEXITCODE" -ForegroundColor Red
        exit $LASTEXITCODE
    }

    # SwiftPM placed the executable somewhere under .build/. Locations
    # we know about on Windows MSVC:
    #   .build/debug/AdaptiveCardsDemo.exe                            (with local dev junction)
    #   .build/x86_64-unknown-windows-msvc/debug/AdaptiveCardsDemo.exe (fresh CI)
    #   .build/arm64-unknown-windows-msvc/debug/AdaptiveCardsDemo.exe  (arm64 host)
    # We don't use `swift run` because its linker invocation drops
    # `-Xlinker /LIBPATH:`, which makes zlib.lib unresolvable when
    # NIOHTTPCompression's vendored fallback (and the hggz fork's
    # actual `empty.c` shim aren't selected together cleanly).
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
        Write-Host "FAIL adaptivecards-giteax-roundtrip: built exe not found anywhere under .build" -ForegroundColor Red
        exit 3
    }
    Write-Host "exe: $exe"

    Write-Host "=== run demo ==="
    $out = & $exe 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { $_ }
    if ($rc -ne 0) {
        Write-Host "FAIL adaptivecards-giteax-roundtrip: demo exit=$rc" -ForegroundColor Red
        exit $rc
    }
    if (-not ($out -match 'PASS adaptivecards-giteax-roundtrip')) {
        Write-Host "FAIL adaptivecards-giteax-roundtrip: PASS marker not found in output" -ForegroundColor Red
        exit 4
    }
    Write-Host ""
    Write-Host "PASS adaptivecards-giteax-roundtrip" -ForegroundColor Green
}
finally {
    Pop-Location
}
