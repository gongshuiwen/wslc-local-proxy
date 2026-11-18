[CmdletBinding(DefaultParameterSetName='Auto')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Manual')][string]$ProxyUrl,
    [Parameter(ParameterSetName='Auto')][switch]$Auto,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'wslc-local-proxy'),
    [string]$ProfileRoot
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallSupport.ps1')
$null = Get-Command wslc.exe -CommandType Application -ErrorAction Stop
$manual = $PSBoundParameters.ContainsKey('ProxyUrl')
if ($manual) { $ProxyUrl = (ConvertTo-WslcProxyAddress $ProxyUrl).ProxyUrl }
$destination = [IO.Path]::GetFullPath($InstallDirectory)
$binarySource = Join-Path $PSScriptRoot 'dist\wslc-local-proxy.exe'
$files = @('ProxySettings.ps1','RegistrySettings.ps1','RegistryMapping.ps1','InstallSupport.ps1','Uninstall-WslcProxy.ps1','Uninstall.cmd','README.md','profile.ps1')
foreach ($file in @($binarySource) + @($files | ForEach-Object { Join-Path $PSScriptRoot $_ })) { if (-not [IO.File]::Exists($file)) { throw ('Missing package file: ' + $file) } }
Assert-WslcInstallBinary $binarySource
$lock = Lock-WslcInstallation
$processes = @()
try {
    $profileRootPath = Get-WslcInstallProfileRoot $destination $ProfileRoot
    $changes = [Collections.ArrayList]::new()
    $binaryTarget = Join-Path $destination 'wslc-local-proxy.exe'
    Add-WslcFileChange $changes $binaryTarget ([IO.File]::ReadAllBytes($binarySource))
    $restartRelay = $changes.Count -gt 0
    $statePath = Join-Path $destination 'state\relay.json'
    if ([IO.File]::Exists($statePath)) {
        try {
            $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
            if ($state -isnot [pscustomobject] -or [long]$state.pid -lt 1 -or [int]$state.tlsPort -lt 1 -or [int]$state.tlsPort -gt 65535 -or [int]$state.httpPort -lt 1 -or [int]$state.httpPort -gt 65535) { $restartRelay = $true }
        } catch { $restartRelay = $true }
    }
    if ($restartRelay) { $processes = @(Get-WslcInstallRelay $destination); Add-WslcFileChange $changes $statePath $null }
    foreach ($file in $files) { Add-WslcFileChange $changes (Join-Path $destination $file) ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $file))) }
    foreach ($file in @('README.txt','state\redirect.pid','relay.go')) { Add-WslcFileChange $changes (Join-Path $destination $file) $null }
    $metadata = [Text.UTF8Encoding]::new($false).GetBytes((@{ profileRoot=$profileRootPath } | ConvertTo-Json -Compress))
    Add-WslcFileChange $changes (Join-Path $destination 'install.json') $metadata
    foreach ($relative in @('PowerShell\profile.ps1','WindowsPowerShell\profile.ps1')) {
        $update = Get-WslcProfileUpdate (Join-Path $profileRootPath $relative) $destination
        if ($update.Changed) { Add-WslcFileChange $changes $update.Path $update.Bytes -Profile }
    }
    $configPath = Join-Path $destination 'config.json'
    if ([IO.File]::Exists($configPath)) { Read-WslcProxyConfiguration $configPath | Out-Null }
    Invoke-WslcInstallChanges -Changes @($changes) -Destination $destination -Commit {
        foreach ($file in @('wslc-local-proxy.exe') + $files) { Unblock-File -LiteralPath (Join-Path $destination $file) }
        . (Join-Path $destination 'profile.ps1') -DataDirectory $destination
        if ($manual) { Write-WslcProxyConfiguration $configPath -ProxyUrl $ProxyUrl }
        elseif ($Auto -or -not [IO.File]::Exists($configPath)) { Write-WslcProxyConfiguration $configPath -Auto }
        if ($restartRelay) { Stop-WslcInstallRelay $processes -Warn }
    }
} finally {
    foreach ($process in $processes) { $process.Dispose() }
    $lock.Dispose()
}
Write-Output 'Installed. Open a new PowerShell window. Existing proxy and mirror settings are preserved unless explicitly changed.'
