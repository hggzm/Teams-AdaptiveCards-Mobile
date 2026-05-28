# proxy-only — symbol-check smoke for the vendored swiftka kit on Windows MSVC.
# Builds the example, runs it, asserts the canonical PASS line on stdout.

# NOTE: do NOT set $ErrorActionPreference = 'Stop' — `swift build` writes
# progress to stderr (fetching, planning, etc) and PowerShell would
# treat those as terminating errors. We gate on $LASTEXITCODE instead.

# Reset PATH from the persistent registry so freshly-installed Swift
# DLLs are visible to the spawned binary (matches the win-build /
# win-smoke pattern used inside the swiftka kit's own repo).
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path", "User")
$sdk = [System.Environment]::GetEnvironmentVariable("SDKROOT", "User")
if ($sdk) { $env:SDKROOT = $sdk }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
    Write-Host "=== building adaptivecards-swiftka-demo ===" -ForegroundColor Cyan
    & swift build -c debug *>&1 | Tee-Object -FilePath build.log | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL adaptivecards-swiftka-build (swift build returned $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }

    Write-Host "`n=== running symbol-check ===" -ForegroundColor Cyan
    $output = & swift run -c debug adaptivecards-swiftka-demo *>&1 | Out-String
    $exit = $LASTEXITCODE
    Write-Host $output
    if ($exit -ne 0) {
        Write-Host "FAIL adaptivecards-swiftka-roundtrip (binary exit=$exit)" -ForegroundColor Red
        exit 1
    }
    if ($output -notmatch 'PASS adaptivecards-swiftka-roundtrip') {
        Write-Host "FAIL adaptivecards-swiftka-roundtrip (no PASS marker on stdout)" -ForegroundColor Red
        exit 1
    }
    Write-Host "`nPASS adaptivecards-swiftka-roundtrip" -ForegroundColor Green
    exit 0
}
finally {
    Pop-Location
}
