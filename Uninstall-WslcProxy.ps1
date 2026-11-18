param(
    [string]$InstallDirectory = $(if ([IO.File]::Exists((Join-Path $PSScriptRoot 'install.json')) -or [IO.File]::Exists((Join-Path $PSScriptRoot 'wslc-local-proxy.exe'))) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'wslc-local-proxy' }),
    [string]$ProfileRoot,
    [switch]$SkipSessionCleanup
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallSupport.ps1')
$destination = [IO.Path]::GetFullPath($InstallDirectory)
$lock = Lock-WslcInstallation
$processes = @()
try {
    $profileRootPath = Get-WslcInstallProfileRoot $destination $ProfileRoot
    $changes = [Collections.ArrayList]::new(); $foreign = $false
    Add-WslcFileChange $changes (Join-Path $destination 'state\relay.json') $null
    foreach ($relative in @('PowerShell\profile.ps1','WindowsPowerShell\profile.ps1')) {
        $update = Get-WslcProfileUpdate (Join-Path $profileRootPath $relative) $destination -Remove
        if ($update.Changed) { Add-WslcFileChange $changes $update.Path $update.Bytes -Profile }
        $foreign = $foreign -or $update.Foreign
    }
    $processes = @(Get-WslcInstallRelay $destination)
    Invoke-WslcInstallChanges -Changes @($changes) -Destination $destination -Commit {
        if (-not $SkipSessionCleanup -and -not $foreign -and [IO.File]::Exists((Join-Path $destination 'profile.ps1'))) {
            . (Join-Path $destination 'profile.ps1') -DataDirectory $destination
            if ((Read-WslcConfiguration (Join-Path $destination 'config.json')).PSObject.Properties['registryMirrors']) { Sync-WslcRegistryMirrors -Mirrors @() }
            Disable-WslcProxy
            if ($LASTEXITCODE -ne 0) { throw 'Session cleanup failed. Close affected WSLC sessions before using -SkipSessionCleanup.' }
        }
        Stop-WslcInstallRelay $processes
    }
    if ($global:WslcLocalProxy -and $global:WslcLocalProxy.Root -eq $destination) { Remove-Item -LiteralPath 'Function:\wslc' -ErrorAction SilentlyContinue }
} finally {
    foreach ($process in $processes) { $process.Dispose() }
    $lock.Dispose()
}
Write-Output 'Autoload removed. Close old PowerShell windows. Files, configuration and profile backups are retained.'
