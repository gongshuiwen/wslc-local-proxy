param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'wslc-local-proxy'),
    [string]$ProfileRoot = ([Environment]::GetFolderPath('MyDocuments')),
    [switch]$SkipSessionCleanup
)
$ErrorActionPreference = 'Stop'
$destination = [IO.Path]::GetFullPath($InstallDirectory)
$profileRootPath = [IO.Path]::GetFullPath($ProfileRoot)
if (-not $SkipSessionCleanup -and (Test-Path -LiteralPath (Join-Path $destination 'profile.ps1'))) {
    . (Join-Path $destination 'profile.ps1') -DataDirectory $destination
    Disable-WslcProxy
    if ($LASTEXITCODE -ne 0) { throw 'Session cleanup failed. Remove its routing before stopping the shared relay, or use -SkipSessionCleanup only after terminating affected sessions.' }
}
$pattern = '(?ms)^# BEGIN WSLC local proxy\r?\n.*?^# END WSLC local proxy\r?\n?'
$encoding = New-Object Text.UTF8Encoding($true)
foreach ($relative in @('PowerShell\profile.ps1','WindowsPowerShell\profile.ps1')) {
    $path = Join-Path $profileRootPath $relative
    if (Test-Path -LiteralPath $path) {
        $contents = [IO.File]::ReadAllText($path)
        $updated = [regex]::Replace($contents, $pattern, '')
        if ($updated -ne $contents) {
            $backupDirectory = Join-Path $destination 'backups'
            New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
            $backupName = (Split-Path (Split-Path $path) -Leaf) + '-uninstall-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.ps1'
            Copy-Item -LiteralPath $path -Destination (Join-Path $backupDirectory $backupName)
            [IO.File]::WriteAllText($path, $updated, $encoding)
        }
    }
}
$metadataPath = Join-Path $destination 'state\relay.json'
if (Test-Path -LiteralPath $metadataPath) {
    $metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
    $relay = Get-Process -Id ([int]$metadata.pid) -ErrorAction SilentlyContinue
    if ($relay -and $relay.Path -eq (Join-Path $destination 'wslc-local-proxy.exe')) { Stop-Process -Id $relay.Id -ErrorAction Stop }
}
if ($global:WslcLocalProxy -and $global:WslcLocalProxy.Root -eq $destination) { Remove-Item -LiteralPath 'Function:\wslc' -ErrorAction SilentlyContinue }
Write-Output 'Autoload removed. Close old PowerShell windows. Package files, configuration, logs, and profile backups are retained.'
