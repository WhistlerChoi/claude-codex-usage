param(
    [string]$Version = "1.5.0"
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

Write-Host "Building for Windows x64..."
$env:GOCACHE = Join-Path $env:TEMP "pulse-tray-go-build-cache"
$icon = Join-Path $PSScriptRoot "installer\Pulse.ico"
$savedGoOS = $env:GOOS
$savedGoARCH = $env:GOARCH
$savedCGO = $env:CGO_ENABLED
Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
$env:GOOS = "windows"
$env:GOARCH = "amd64"
$env:CGO_ENABLED = "0"

$goCommand = Get-Command go.exe -ErrorAction SilentlyContinue
$goPath = if ($goCommand) { $goCommand.Source } else { "C:\Program Files\Go\bin\go.exe" }
if (-not (Test-Path -LiteralPath $goPath)) {
    throw "Go was not found. Install Go or add go.exe to PATH."
}

# Keep the MSI Add/Remove Programs icon in sync with the tray icon.
$env:GOOS = $savedGoOS
$env:GOARCH = $savedGoARCH
$env:CGO_ENABLED = $savedCGO
& $goPath run . --render-ico $icon
if ($LASTEXITCODE -ne 0) {
    throw "Pulse.ico generation failed with exit code $LASTEXITCODE."
}
$env:GOOS = "windows"
$env:GOARCH = "amd64"
$env:CGO_ENABLED = "0"

& $goPath build -ldflags "-H windowsgui -s -w -X main.appVersion=$Version" -o Pulse.exe .
if ($LASTEXITCODE -ne 0) {
    throw "Go build failed with exit code $LASTEXITCODE."
}

$exe = Get-Item -LiteralPath .\Pulse.exe
Write-Host ("Done: {0} ({1:N0} bytes)" -f $exe.FullName, $exe.Length)
Write-Host "Copy Pulse.exe to the target Windows machine and double-click it."
