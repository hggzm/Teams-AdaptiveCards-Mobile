# adaptivecards-swiftag-demo runtime symbol-check (Windows MSVC)
# Builds and runs the demo, asserts both required PASS lines are
# present, exits non-zero on any failure.

$ErrorActionPreference = 'Stop'

$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path','User')
$env:SDKROOT = [System.Environment]::GetEnvironmentVariable('SDKROOT','User')

Push-Location $PSScriptRoot
try {
    Write-Host '=== swift build -c debug ===' -ForegroundColor Cyan
    swift build -c debug
    if ($LASTEXITCODE -ne 0) {
        throw "swift build failed (exit $LASTEXITCODE)"
    }

    Write-Host '=== swift run adaptivecards-swiftag-demo ===' -ForegroundColor Cyan
    # Swift writes "Building for debugging..." to stderr; under
    # $ErrorActionPreference=Stop PowerShell would otherwise treat
    # that as a terminating error. Drop down to Continue for the
    # native-command call and arbitrate via $LASTEXITCODE.
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $logPath = Join-Path $env:TEMP ("acm-swiftag-demo-{0}.log" -f ([guid]::NewGuid()))
    & swift run adaptivecards-swiftag-demo 2>&1 |
        Tee-Object -FilePath $logPath |
        ForEach-Object { Write-Host $_ }
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    $output = Get-Content $logPath -Raw
    Remove-Item $logPath -ErrorAction SilentlyContinue

    if ($exit -ne 0) {
        throw "demo binary failed (exit $exit)"
    }

    $required = @(
        'PASS adaptivecards-swiftag-roundtrip',
        'PASS adaptivecards-swiftag-tool'
    )
    foreach ($line in $required) {
        if ($output -notmatch [regex]::Escape($line)) {
            throw "missing required line: '$line'"
        }
    }

    Write-Host '=== adaptivecards-swiftag-demo: SMOKE PASS ===' -ForegroundColor Green
} finally {
    Pop-Location
}
