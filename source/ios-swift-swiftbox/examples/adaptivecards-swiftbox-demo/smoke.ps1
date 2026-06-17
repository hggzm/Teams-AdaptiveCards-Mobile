# examples/adaptivecards-swiftbox-demo/smoke.ps1
#
# Build and run the symbol-check demo on Windows MSVC, then assert the PASS
# marker line in stdout. swiftbox is pure Foundation — no vcpkg / zlib needed.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$marker = 'PASS adaptivecards-swiftbox-roundtrip'

Push-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
try {
    Write-Host "=== swift build (demo) ==="
    & swift build -c debug
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL adaptivecards-swiftbox-roundtrip: build exit=$LASTEXITCODE" -ForegroundColor Red
        exit $LASTEXITCODE
    }

    # SwiftPM places the exe under .build/<triple>/debug or .build/debug.
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
        Write-Host "FAIL adaptivecards-swiftbox-roundtrip: built exe not found under .build" -ForegroundColor Red
        exit 3
    }
    Write-Host "exe: $exe"

    Write-Host "=== run demo ==="
    $out = & $exe 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { $_ }
    if ($rc -ne 0) {
        Write-Host "FAIL adaptivecards-swiftbox-roundtrip: demo exit=$rc" -ForegroundColor Red
        exit $rc
    }
    if (-not ($out -match [regex]::Escape($marker))) {
        Write-Host "FAIL adaptivecards-swiftbox-roundtrip: PASS marker not found in output" -ForegroundColor Red
        exit 4
    }
    Write-Host ""
    Write-Host $marker -ForegroundColor Green
}
finally {
    Pop-Location
}
