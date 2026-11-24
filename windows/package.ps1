# Builds .build\BisprBlow-Windows.zip: the self-contained app, ready to unzip anywhere.
# The models are NOT in it. They are 1.3 GB, and the app fetches them on first run, so the
# download stays small and a machine that already has them never gets a second copy.
# Calls build.ps1 so the bundle is assembled in exactly one place.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

& .\build.ps1 -NoInstall -SkipWeights

$zip = Join-Path $PSScriptRoot '..\.build\BisprBlow-Windows.zip'
New-Item -ItemType Directory -Force (Split-Path $zip) | Out-Null
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path 'bin\publish\*' -DestinationPath $zip
Write-Host "Built $(Resolve-Path $zip) ($([math]::Round((Get-Item $zip).Length / 1MB)) MB)"
