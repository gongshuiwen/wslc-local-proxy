param([string]$ScratchDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('wslc-install-tests-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$installation = Join-Path $ScratchDirectory 'installation with spaces'
$documents = Join-Path $ScratchDirectory 'documents with spaces'
$existingProfile = Join-Path $documents 'PowerShell\profile.ps1'
New-Item -ItemType Directory -Path (Split-Path $existingProfile) -Force | Out-Null
[IO.File]::WriteAllText($existingProfile, '# existing user profile content' + "`r`n")
& (Join-Path $repository 'Install-WslcProxy.ps1') -InstallDirectory $installation -ProfileRoot $documents -ProxyUrl 'localhost:8765'
if ((Get-WslcProxyConfig).ProxyUrl -ne 'http://localhost:8765') { throw 'Installer did not preserve the manual override.' }
& (Join-Path $repository 'Install-WslcProxy.ps1') -InstallDirectory $installation -ProfileRoot $documents
if ((Get-WslcProxyConfig).ProxyUrl -ne 'http://localhost:8765') { throw 'Upgrade reset the saved override.' }
foreach ($relative in @('PowerShell\profile.ps1','WindowsPowerShell\profile.ps1')) {
    $text = [IO.File]::ReadAllText((Join-Path $documents $relative))
    if ([regex]::Matches($text, '# BEGIN WSLC local proxy').Count -ne 1) { throw 'Repeated install duplicated the loader.' }
}
if (-not [IO.File]::ReadAllText($existingProfile).Contains('# existing user profile content')) { throw 'Installer changed unrelated profile content.' }
$selection = Get-WslcProxyConfig
$firstRelay = Start-WslcProxyRelay -ProxySelection $selection
if ($firstRelay.proxy -ne 'localhost:8765') { throw 'Relay did not receive the selected proxy.' }
Set-WslcProxy -ProxyUrl 'http://127.0.0.1:8766' | Out-Null
$secondRelay = Start-WslcProxyRelay -ProxySelection (Get-WslcProxyConfig)
if ($secondRelay.proxy -ne '127.0.0.1:8766' -or $secondRelay.pid -eq $firstRelay.pid) { throw 'Changing the proxy did not replace the auxiliary relay.' }
function global:Get-WslcWindowsProxySettings { [pscustomobject]@{ Enabled=$true; Server='127.0.0.1:8767'; PacUrl='' } }
Set-WslcProxy -Auto | Out-Null
if ((Get-WslcProxyConfig).Source -ne 'windows-system') { throw 'Automatic mode did not return to Windows settings.' }
& (Join-Path $repository 'Uninstall-WslcProxy.ps1') -InstallDirectory $installation -ProfileRoot $documents -SkipSessionCleanup
foreach ($relative in @('PowerShell\profile.ps1','WindowsPowerShell\profile.ps1')) {
    if ([IO.File]::ReadAllText((Join-Path $documents $relative)).Contains('# BEGIN WSLC local proxy')) { throw 'Uninstaller left an autoload block.' }
}
if (-not [IO.File]::ReadAllText($existingProfile).Contains('# existing user profile content')) { throw 'Uninstaller removed unrelated profile content.' }
if (-not (Test-Path -LiteralPath (Join-Path $installation 'config.json'))) { throw 'Uninstaller removed the saved configuration.' }
Write-Output 'Installation checks passed: overrides, auto mode, relay restart, paths with spaces, repeat installation, profile preservation, uninstall.'
