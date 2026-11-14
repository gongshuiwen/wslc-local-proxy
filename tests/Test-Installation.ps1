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
if (Test-Path -LiteralPath (Join-Path $installation 'relay.go')) { throw 'Runtime installation contains unused Go source.' }
[IO.File]::WriteAllText((Join-Path $installation 'relay.go'), '// obsolete runtime copy')
Update-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath -Values @{ registryMirrors = @('https://mirror.example') }
& (Join-Path $repository 'Install-WslcProxy.ps1') -InstallDirectory $installation -ProfileRoot $documents
if ((Get-WslcProxyConfig).ProxyUrl -ne 'http://localhost:8765') { throw 'Upgrade reset the saved override.' }
if (Test-Path -LiteralPath (Join-Path $installation 'relay.go')) { throw 'Upgrade left unused Go source in the runtime directory.' }
if ((Read-WslcConfiguration $global:WslcLocalProxy.ConfigPath).registryMirrors[0] -ne 'https://mirror.example' -or -not (Test-Path -LiteralPath (Join-Path $installation 'RegistrySettings.ps1'))) { throw 'Upgrade did not preserve mirror settings or install mirror support.' }
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
function global:Get-WslcWindowsProxySettings { [pscustomobject]@{ Enabled=$true; Server='127.0.0.1:8767' } }
Set-WslcProxy -Auto | Out-Null
if ((Get-WslcProxyConfig).Source -ne 'windows-system') { throw 'Automatic mode did not return to Windows settings.' }
if ((Read-WslcConfiguration $global:WslcLocalProxy.ConfigPath).registryMirrors[0] -ne 'https://mirror.example') { throw 'Automatic proxy mode reset the mirror settings.' }
& (Join-Path $repository 'Uninstall-WslcProxy.ps1') -InstallDirectory $installation -ProfileRoot $documents -SkipSessionCleanup
foreach ($relative in @('PowerShell\profile.ps1','WindowsPowerShell\profile.ps1')) {
    if ([IO.File]::ReadAllText((Join-Path $documents $relative)).Contains('# BEGIN WSLC local proxy')) { throw 'Uninstaller left an autoload block.' }
}
if (-not [IO.File]::ReadAllText($existingProfile).Contains('# existing user profile content')) { throw 'Uninstaller removed unrelated profile content.' }
if (-not (Test-Path -LiteralPath (Join-Path $installation 'config.json'))) { throw 'Uninstaller removed the saved configuration.' }
Write-Output 'Installation checks passed: overrides, auto mode, relay restart, paths with spaces, repeat installation, profile preservation, uninstall.'
