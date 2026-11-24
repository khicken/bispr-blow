# Builds BisprBlow for Windows, installs it to %LOCALAPPDATA%\Programs\BisprBlow, and relaunches it.
# -SkipWeights for a build meant to have no models; -NoInstall for CI and
# package.ps1, which only want the publish folder.
param([switch]$SkipWeights, [switch]$NoInstall)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue) -or -not (dotnet --list-sdks | Select-String '^10\.')) {
    throw 'The .NET 10 SDK is missing. Install it from https://dotnet.microsoft.com/download/dotnet/10.0 and run this again.'
}

# The same word list macOS reads from /usr/share/dict/words (LLMCleaner.EnglishWords). It is not in
# the repo, so a fresh clone fetches it once; without it the app still runs, it just trusts every word.
$words = 'Resources\words.txt'
if (-not (Test-Path $words)) {
    Write-Host 'Fetching the English word list (once, 2.5 MB).'
    Invoke-WebRequest 'https://raw.githubusercontent.com/freebsd/freebsd-src/main/share/dict/web2' -OutFile $words
}

# Self-contained, so nobody needs a .NET runtime to run it.
# Unlike build.sh this does not take the newest tag: on a branch that is the *previous* release and
# would stamp the wrong version. Only a build sitting exactly on a tag (CI) is stamped with it;
# anything else keeps the csproj's own <Version>.
$version = @()
# cmd swallows git's "no tag" stderr, which Windows PowerShell would otherwise raise under Stop.
$tag = cmd /c 'git describe --tags --exact-match 2>nul'
if ($tag -match '^v(.+)$') { $version = @("-p:Version=$($Matches[1])"); Write-Host "Version $($Matches[1])." }
dotnet publish -c Release -r win-x64 --self-contained -o bin\publish @version
if ($LASTEXITCODE) { throw 'dotnet publish failed.' }

$publish = Join-Path $PSScriptRoot 'bin\publish'
$exe = Join-Path $publish 'BisprBlow.exe'

# A fresh machine has no weights, and an app with none falls back to rule-based cleanup without
# saying so. Ask the binary rather than test a path, so this cannot drift from where it looks.
# Piped to Out-Host because BisprBlow.exe is a GUI-subsystem program: PowerShell only waits for it,
# and only sets $LASTEXITCODE, when its output is piped.
if (-not $SkipWeights) {
    if (-not (& $exe --list-models | Out-String).Trim()) {
        Write-Host 'No cleanup model on this machine - fetching Fast (once, 335 MB).'
        & $exe --download-fast | Out-Host
        if ($LASTEXITCODE) { throw 'Fast model download failed.' }
    }
    & $exe --download-speech | Out-Host
    if ($LASTEXITCODE) { throw 'Speech model download failed.' }
}

if ($NoInstall) { Write-Host "Built $publish (-NoInstall, so not installed)."; return }

Get-Process BisprBlow -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process BisprBlow -ErrorAction SilentlyContinue | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue

# One installed copy, on purpose: two copies means two keyboard hooks fighting over one shortcut.
# /MIR also removes files a previous version had and this one does not. Exit codes below 8 are success.
$dest = Join-Path $env:LOCALAPPDATA 'Programs\BisprBlow'
robocopy $publish $dest /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Copy to $dest failed." }

$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\BisprBlow.lnk'
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$shortcut.TargetPath = Join-Path $dest 'BisprBlow.exe'
$shortcut.WorkingDirectory = $dest
$shortcut.Save()

Start-Process (Join-Path $dest 'BisprBlow.exe')
Write-Host "Installed $dest and relaunched."
