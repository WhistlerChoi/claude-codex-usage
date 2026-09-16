param(
    [string]$Version = "1.4.1"
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

& .\build-win.ps1 -Version $Version
if ($LASTEXITCODE -ne 0) {
    throw "Pulse.exe build failed with exit code $LASTEXITCODE."
}

$wix = Get-Command wix.exe -ErrorAction SilentlyContinue
if (-not $wix) {
    throw "WiX was not found. Install it with: dotnet tool install --global wix"
}

$extension = "WixToolset.UI.wixext"
& $wix.Source extension add -g $extension
if ($LASTEXITCODE -ne 0) {
    throw "Unable to add the WiX UI extension (exit code $LASTEXITCODE)."
}

$source = Join-Path $PSScriptRoot "installer\Pulse.wxs"
$icon = Join-Path $PSScriptRoot "installer\Pulse.ico"
if (-not (Test-Path -LiteralPath $icon)) {
    throw "Pulse.ico was not found at $icon."
}
$output = Join-Path $PSScriptRoot "Pulse-$Version-x64.msi"
$exe = Join-Path $PSScriptRoot "Pulse.exe"
& $wix.Source build -arch x64 -ext $extension -d "PulseExe=$exe" -d "PulseIcon=$icon" -d "ProductVersion=$Version" -o $output $source
if ($LASTEXITCODE -ne 0) {
    throw "MSI build failed with exit code $LASTEXITCODE."
}

Write-Host "Done: $output"
