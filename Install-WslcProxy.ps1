[CmdletBinding(DefaultParameterSetName='Auto')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Manual')][string]$ProxyUrl,
    [Parameter(ParameterSetName='Auto')][switch]$Auto,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'wslc-local-proxy'),
    [string]$ProfileRoot = ([Environment]::GetFolderPath('MyDocuments'))
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProxySettings.ps1')
if ($PSBoundParameters.ContainsKey('ProxyUrl')) { $ProxyUrl = (ConvertTo-WslcProxyAddress -Value $ProxyUrl).ProxyUrl }
$destination = [IO.Path]::GetFullPath($InstallDirectory)
$profileRootPath = [IO.Path]::GetFullPath($ProfileRoot)
$binarySource = Join-Path $PSScriptRoot 'dist\wslc-local-proxy.exe'
if (-not (Test-Path -LiteralPath $binarySource)) { throw 'Build the relay first: .\Build.ps1' }
$files = @('profile.ps1','ProxySettings.ps1','RegistrySettings.ps1','relay.go','README.md')
foreach ($file in $files) { if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) { throw ('Missing package file: ' + $file) } }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$binaryTarget = Join-Path $destination 'wslc-local-proxy.exe'
$copyBinary = -not (Test-Path -LiteralPath $binaryTarget)
if (-not $copyBinary) { $copyBinary = (Get-FileHash -LiteralPath $binarySource).Hash -ne (Get-FileHash -LiteralPath $binaryTarget).Hash }
if ($copyBinary) {
    $metadataPath = Join-Path $destination 'state\relay.json'
    if (Test-Path -LiteralPath $metadataPath) {
        $metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
        $runningRelay = Get-Process -Id ([int]$metadata.pid) -ErrorAction SilentlyContinue
        if ($runningRelay -and $runningRelay.Path -eq $binaryTarget) {
            Stop-Process -Id $runningRelay.Id -ErrorAction Stop
            if (-not $runningRelay.WaitForExit(5000)) { throw 'The old relay did not exit.' }
        }
    }
    Copy-Item -LiteralPath $binarySource -Destination $binaryTarget -Force
}
foreach ($file in $files) {
    $source = Join-Path $PSScriptRoot $file; $target = Join-Path $destination $file
    if ((Test-Path -LiteralPath $target) -and (Get-FileHash -LiteralPath $source).Hash -eq (Get-FileHash -LiteralPath $target).Hash) { continue }
    Copy-Item -LiteralPath $source -Destination $target -Force
}
foreach ($obsolete in @('README.txt','state\redirect.pid')) {
    $obsoletePath = Join-Path $destination $obsolete
    if (Test-Path -LiteralPath $obsoletePath) { Remove-Item -LiteralPath $obsoletePath }
}
$configPath = Join-Path $destination 'config.json'
if ($PSBoundParameters.ContainsKey('ProxyUrl')) {
    Write-WslcProxyConfiguration -Path $configPath -ProxyUrl $ProxyUrl
} elseif ($Auto -or -not (Test-Path -LiteralPath $configPath)) {
    Write-WslcProxyConfiguration -Path $configPath -Auto
}
$profilePaths = @((Join-Path $profileRootPath 'PowerShell\profile.ps1'), (Join-Path $profileRootPath 'WindowsPowerShell\profile.ps1'))
$loader = ". '" + (Join-Path $destination 'profile.ps1').Replace("'", "''") + "' -DataDirectory '" + $destination.Replace("'", "''") + "'"
$block = '# BEGIN WSLC local proxy' + "`r`n" + $loader + "`r`n" + '# END WSLC local proxy'
$encoding = New-Object Text.UTF8Encoding($true)
foreach ($profilePath in $profilePaths) {
    $contents = ''
    if (Test-Path -LiteralPath $profilePath) {
        $contents = [IO.File]::ReadAllText($profilePath)
        $backupDirectory = Join-Path $destination 'backups'
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        $backupName = (Split-Path (Split-Path $profilePath) -Leaf) + '-profile-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.ps1'
        Copy-Item -LiteralPath $profilePath -Destination (Join-Path $backupDirectory $backupName)
    }
    $pattern = '(?ms)^# BEGIN WSLC local proxy\r?\n.*?^# END WSLC local proxy\r?\n?'
    $contents = [regex]::Replace($contents, $pattern, '')
    $contents = $contents.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
    New-Item -ItemType Directory -Path (Split-Path $profilePath) -Force | Out-Null
    [IO.File]::WriteAllText($profilePath, $contents, $encoding)
    Write-Output ('Configured profile: ' + $profilePath)
}
. (Join-Path $destination 'profile.ps1') -DataDirectory $destination
Write-Output 'Installed. Proxy and registry mirror settings are applied before the next pull/run/create/build/push.'
