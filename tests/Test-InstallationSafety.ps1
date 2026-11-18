param(
    [string]$ScratchDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('wslc-install-safety-' + [guid]::NewGuid().ToString('N'))),
    [string]$PackageDirectory = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('Parent','Install','Uninstall','FileLock')][string]$Mode = 'Parent'
)
$ErrorActionPreference = 'Stop'
$PackageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
New-Item -ItemType Directory -Path $ScratchDirectory -Force | Out-Null
. (Join-Path $PackageDirectory 'InstallSupport.ps1')
if ($Mode -eq 'FileLock') {
    $handle=[IO.File]::Open((Join-Path $ScratchDirectory 'retry.txt'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { [IO.File]::WriteAllText((Join-Path $ScratchDirectory 'file-lock.ready'),'ready'); Start-Sleep -Milliseconds 500 } finally { $handle.Dispose() }
    return
}
if ($Mode -ne 'Parent') {
    [IO.File]::WriteAllText((Join-Path $ScratchDirectory ($Mode + '.ready')), 'ready')
    $arguments = @{ InstallDirectory=(Join-Path $ScratchDirectory 'concurrent-install'); ProfileRoot=(Join-Path $ScratchDirectory 'concurrent-profiles') }
    if ($Mode -eq 'Install') { & (Join-Path $PackageDirectory 'Install-WslcProxy.ps1') @arguments }
    else { & (Join-Path $PackageDirectory 'Uninstall-WslcProxy.ps1') @arguments -SkipSessionCleanup }
    [IO.File]::WriteAllText((Join-Path $ScratchDirectory ($Mode + '.done')), 'done')
    return
}
$script:checks = 0
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Install-Test([string]$Name,[string]$Source=$PackageDirectory) {
    & (Join-Path $Source 'Install-WslcProxy.ps1') -InstallDirectory (Join-Path $ScratchDirectory ($Name + '-install')) -ProfileRoot (Join-Path $ScratchDirectory ($Name + '-profiles')) | Out-Null
}
function Profile-Path([string]$Name,[string]$Edition='PowerShell') { Join-Path $ScratchDirectory ($Name + '-profiles\' + $Edition + '\profile.ps1') }
function Fingerprint([string]$Path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }

$savedPath = $env:Path; $failed = $false
try { $env:Path=''; Install-Test 'missing-wslc' } catch { $failed=$true } finally { $env:Path=$savedPath }
Assert ($failed -and -not [IO.Directory]::Exists((Join-Path $ScratchDirectory 'missing-wslc-install')) -and -not [IO.Directory]::Exists((Join-Path $ScratchDirectory 'missing-wslc-profiles'))) 'Missing WSLC must fail before writing files or profiles'

$copy = Join-Path $ScratchDirectory 'upgrade-package'
New-Item -ItemType Directory -Path (Join-Path $copy 'dist') -Force | Out-Null
foreach ($file in @('Install.cmd','Install-WslcProxy.ps1','Uninstall.cmd','Uninstall-WslcProxy.ps1','InstallSupport.ps1','ProxySettings.ps1','RegistrySettings.ps1','RegistryMapping.ps1','profile.ps1','README.md')) { Copy-Item -LiteralPath (Join-Path $PackageDirectory $file) -Destination (Join-Path $copy $file) }
$sourceBinary = Join-Path $copy 'dist\wslc-local-proxy.exe'
$sourceChecksum = Join-Path $copy 'dist\sha256.txt'
Copy-Item -LiteralPath (Join-Path $PackageDirectory 'dist\wslc-local-proxy.exe') -Destination $sourceBinary
Set-Content -LiteralPath $sourceChecksum -Value (('0' * 64) + '  wslc-local-proxy.exe') -Encoding ASCII
$failed=$false; try { Install-Test 'bad-checksum' $copy } catch { $failed=$true }
Assert ($failed -and -not [IO.Directory]::Exists((Join-Path $ScratchDirectory 'bad-checksum-install'))) 'Checksum mismatch must fail before installation'
$originalBinary = [IO.File]::ReadAllBytes($sourceBinary)
if ([Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE','Machine') -eq 'AMD64') {
    $wrong = [byte[]]$originalBinary.Clone(); $offset = [BitConverter]::ToInt32($wrong,60)
    $wrong[$offset+4]=0x64; $wrong[$offset+5]=0xaa
    [IO.File]::WriteAllBytes($sourceBinary,$wrong)
    Set-Content -LiteralPath $sourceChecksum -Value ((Get-FileHash -LiteralPath $sourceBinary).Hash + '  wslc-local-proxy.exe') -Encoding ASCII
    $failed=$false; try { Install-Test 'wrong-architecture' $copy } catch { $failed=$true }
    Assert ($failed -and -not [IO.Directory]::Exists((Join-Path $ScratchDirectory 'wrong-architecture-install'))) 'Wrong architecture must fail before installation'
}
[IO.File]::WriteAllBytes($sourceBinary,$originalBinary)

$ansiText = '$taskValue = "caf' + [char]0xe9 + '"' + "`r`n"
$utf16Text = '# ' + [char]0x4e2d + [char]0x6587 + "`r`n"
foreach ($edition in @('PowerShell','WindowsPowerShell')) { New-Item -ItemType Directory -Path (Split-Path -Parent (Profile-Path 'encoding' $edition)) -Force | Out-Null }
[IO.File]::WriteAllText((Profile-Path 'encoding'),$ansiText,[Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage))
[IO.File]::WriteAllText((Profile-Path 'encoding' 'WindowsPowerShell'),$utf16Text,[Text.Encoding]::Unicode)
$ansiBefore = Fingerprint (Profile-Path 'encoding')
Install-Test 'encoding'
Assert ([IO.File]::ReadAllText((Profile-Path 'encoding')).Contains($ansiText)) 'ANSI profile text must survive installation'
Assert ([IO.File]::ReadAllText((Profile-Path 'encoding' 'WindowsPowerShell')).Contains($utf16Text)) 'UTF-16 profile text must survive installation'
$installation = Join-Path $ScratchDirectory 'encoding-install'
$backups = @(Get-ChildItem -LiteralPath (Join-Path $installation 'backups') -File)
Assert (@($backups | Where-Object { (Fingerprint $_.FullName) -eq $ansiBefore }).Count -eq 1) 'Profile backup must retain original raw bytes'
$before = Fingerprint (Profile-Path 'encoding'); $time = [IO.File]::GetLastWriteTimeUtc((Profile-Path 'encoding'))
& (Join-Path $PackageDirectory 'Install-WslcProxy.ps1') -InstallDirectory $installation | Out-Null
Assert ((Fingerprint (Profile-Path 'encoding')) -eq $before -and [IO.File]::GetLastWriteTimeUtc((Profile-Path 'encoding')) -eq $time) 'No-op upgrade must not rewrite profiles'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $installation 'backups') -File).Count -eq $backups.Count) 'No-op upgrade must not create profile backups'
Assert ([IO.File]::Exists((Join-Path $installation 'Uninstall.cmd')) -and [IO.File]::Exists((Join-Path $installation 'InstallSupport.ps1'))) 'Uninstaller must remain available in the installation'
Set-Content -LiteralPath (Join-Path $installation 'Uninstall-WslcProxy.ps1') -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ASCII
'' | & (Join-Path $installation 'Uninstall.cmd') -SkipSessionCleanup | Out-Null
Assert ($LASTEXITCODE -eq 0 -and -not [IO.File]::ReadAllText((Profile-Path 'encoding')).Contains('# BEGIN WSLC local proxy')) 'Installed uninstall launcher must handle download marks and remember custom paths'
Assert ([IO.File]::ReadAllText((Profile-Path 'encoding')).Contains($ansiText)) 'Uninstall must preserve unrelated profile content'

Install-Test 'missing-binary'
$installation=Join-Path $ScratchDirectory 'missing-binary-install'
[IO.File]::Move((Join-Path $installation 'wslc-local-proxy.exe'),(Join-Path $installation 'held.exe'))
$savedLocalAppData=$env:LOCALAPPDATA
try { $env:LOCALAPPDATA=Join-Path $ScratchDirectory 'unused-default'; '' | & (Join-Path $installation 'Uninstall.cmd') -SkipSessionCleanup | Out-Null }
finally { $env:LOCALAPPDATA=$savedLocalAppData }
Assert ($LASTEXITCODE -eq 0 -and -not [IO.File]::ReadAllText((Profile-Path 'missing-binary')).Contains('# BEGIN WSLC local proxy')) 'Installed uninstaller must still find its directory when the executable is missing'

$sharedProfiles = Join-Path $ScratchDirectory 'shared-profiles'; $old = Join-Path $ScratchDirectory 'old-install'; $new = Join-Path $ScratchDirectory 'new-install'
& (Join-Path $PackageDirectory 'Install-WslcProxy.ps1') -InstallDirectory $old -ProfileRoot $sharedProfiles | Out-Null
& (Join-Path $PackageDirectory 'Install-WslcProxy.ps1') -InstallDirectory $new -ProfileRoot $sharedProfiles | Out-Null
$profile = Join-Path $sharedProfiles 'PowerShell\profile.ps1'; $before = Fingerprint $profile
$cleanupFlag = Join-Path $ScratchDirectory 'wrong-session-cleanup'
$stub = 'function global:Read-WslcConfiguration { [pscustomobject]@{} }; function global:Disable-WslcProxy { [IO.File]::WriteAllText(''' + $cleanupFlag.Replace("'","''") + ''',''bad''); $global:LASTEXITCODE=0 }'
[IO.File]::WriteAllText((Join-Path $old 'profile.ps1'),$stub)
& (Join-Path $PackageDirectory 'Uninstall-WslcProxy.ps1') -InstallDirectory $old -ProfileRoot $sharedProfiles | Out-Null
Assert ((Fingerprint $profile) -eq $before -and -not [IO.File]::Exists($cleanupFlag)) 'Uninstalling an old directory must preserve a newer loader and its session'

Install-Test 'running'
$installation = Join-Path $ScratchDirectory 'running-install'; $documents = Join-Path $ScratchDirectory 'running-profiles'
$owned = @(); $locked = $null
try {
    . (Join-Path $installation 'profile.ps1') -DataDirectory $installation
    Update-WslcConfiguration -Path (Join-Path $installation 'config.json') -Values @{ extension='keep'; registryMirrors=@('https://mirror.example') }
    $relay = Start-WslcProxyRelay -ProxySelection ([pscustomobject]@{ Endpoint='127.0.0.1:8765' })
    $process = [Diagnostics.Process]::GetProcessById([int]$relay.pid); $null=$process.Handle; $owned += $process
    $stream = [IO.File]::Open($sourceBinary,[IO.FileMode]::Append,[IO.FileAccess]::Write)
    try { $stream.WriteByte(0) } finally { $stream.Dispose() }
    Set-Content -LiteralPath $sourceChecksum -Value ((Get-FileHash -LiteralPath $sourceBinary).Hash + '  wslc-local-proxy.exe') -Encoding ASCII
    $target = Join-Path $installation 'wslc-local-proxy.exe'; $oldHash=(Get-FileHash -LiteralPath $target).Hash
    $configPath=Join-Path $installation 'config.json'; $configBefore=Fingerprint $configPath
    $locked=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $failed=$false; try { Install-Test 'running' $copy } catch { $failed=$true } finally { $locked.Dispose(); $locked=$null }
    Assert ($failed -and -not $process.HasExited -and (Get-FileHash -LiteralPath $target).Hash -eq $oldHash) 'Blocked executable replacement must preserve the old binary and running relay'
    foreach ($edition in @('PowerShell','WindowsPowerShell')) {
        $path=Profile-Path 'running' $edition
        [IO.File]::WriteAllText($path,[IO.File]::ReadAllText($path).Replace('# END WSLC local proxy',"# stale block`r`n# END WSLC local proxy"),[Text.UTF8Encoding]::new($true))
    }
    $profile7Before=Fingerprint (Profile-Path 'running'); $profile51Before=Fingerprint (Profile-Path 'running' 'WindowsPowerShell')
    $locked=[IO.File]::Open((Profile-Path 'running' 'WindowsPowerShell'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $failed=$false; try { Install-Test 'running' $copy } catch { $failed=$true } finally { $locked.Dispose(); $locked=$null }
    Assert ($failed -and -not $process.HasExited -and (Get-FileHash -LiteralPath $target).Hash -eq $oldHash) 'Later write failure must restore an already replaced executable without stopping its old process'
    Assert ((Fingerprint (Profile-Path 'running')) -eq $profile7Before -and (Fingerprint (Profile-Path 'running' 'WindowsPowerShell')) -eq $profile51Before) 'Later profile failure must restore every original profile byte'
    Assert ((Fingerprint $configPath) -eq $configBefore) 'Failed upgrade must preserve configuration bytes'
    $client=[Net.Sockets.TcpClient]::new(); try { $client.Connect('127.0.0.1',[int]$relay.httpPort); Assert $client.Connected 'Old relay listener must remain usable after rollback' } finally { $client.Dispose() }
    $locked=[IO.File]::Open((Profile-Path 'running' 'WindowsPowerShell'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $failed=$false; try { & (Join-Path $PackageDirectory 'Uninstall-WslcProxy.ps1') -InstallDirectory $installation -SkipSessionCleanup | Out-Null } catch { $failed=$true } finally { $locked.Dispose(); $locked=$null }
    Assert ($failed -and -not $process.HasExited -and (Fingerprint (Profile-Path 'running')) -eq $profile7Before) 'Failed uninstall must roll back loaders and leave the relay running'
    Install-Test 'running' $copy
    Assert ($process.HasExited -and (Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $sourceBinary).Hash) 'Successful upgrade must commit the new executable before stopping the old relay'
    . (Join-Path $installation 'profile.ps1') -DataDirectory $installation
    Assert ((Read-WslcConfiguration $configPath).extension -eq 'keep') 'Successful upgrade must preserve unknown settings'
    $relay=Start-WslcProxyRelay -ProxySelection ([pscustomobject]@{ Endpoint='127.0.0.1:8765' })
    $process=[Diagnostics.Process]::GetProcessById([int]$relay.pid); $null=$process.Handle; $owned += $process
    [IO.File]::WriteAllText((Join-Path $installation 'state\relay.json'), '{bad metadata')
    Install-Test 'running' $copy
    Assert ($process.HasExited -and -not [IO.File]::Exists((Join-Path $installation 'state\relay.json'))) 'Reinstall must repair corrupt relay state without waiting for an executable update'
    [IO.File]::WriteAllText((Join-Path $installation 'state\relay.json'), '')
    Install-Test 'running' $copy
    Assert (-not [IO.File]::Exists((Join-Path $installation 'state\relay.json'))) 'Reinstall must also repair empty relay state'
    . (Join-Path $installation 'profile.ps1') -DataDirectory $installation
    $relay=Start-WslcProxyRelay -ProxySelection ([pscustomobject]@{ Endpoint='127.0.0.1:8765' })
    $process=[Diagnostics.Process]::GetProcessById([int]$relay.pid); $null=$process.Handle; $owned += $process
    [IO.File]::WriteAllText((Join-Path $installation 'state\relay.json'), '{bad metadata')
    & (Join-Path $PackageDirectory 'Uninstall-WslcProxy.ps1') -InstallDirectory $installation -SkipSessionCleanup | Out-Null
    Assert ($process.HasExited -and -not [IO.File]::ReadAllText((Profile-Path 'running')).Contains('# BEGIN WSLC local proxy')) 'Malformed relay metadata must not prevent complete uninstall'
    Assert (-not [IO.File]::Exists((Join-Path $installation 'state\relay.json'))) 'Uninstall must clear runtime metadata so a later install starts cleanly'
} finally {
    if ($null -ne $locked) { $locked.Dispose() }
    foreach ($process in $owned) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }; $process.Dispose() }
}

$retryPath=Join-Path $ScratchDirectory 'retry.txt'
[IO.File]::WriteAllText($retryPath,'original')
$changes=[Collections.ArrayList]::new()
Add-WslcFileChange $changes $retryPath ([Text.Encoding]::UTF8.GetBytes('updated'))
$arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -PackageDirectory "' + $PackageDirectory + '" -ScratchDirectory "' + $ScratchDirectory + '" -Mode FileLock'
$child=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
$null=$child.Handle
try {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists((Join-Path $ScratchDirectory 'file-lock.ready'))) { if ($timer.Elapsed.TotalSeconds -gt 10) { throw 'File lock worker did not become ready' }; Start-Sleep -Milliseconds 10 }
    Invoke-WslcInstallChanges -Changes @($changes) -Destination $ScratchDirectory -Commit {}
    Assert ($child.WaitForExit(5000) -and $child.ExitCode -eq 0 -and [IO.File]::ReadAllText($retryPath) -eq 'updated') 'Short-lived file sharing conflicts must be retried successfully'
} finally { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit(5000) | Out-Null }; $child.Dispose() }

$lock=Lock-WslcInstallation; $children=@()
try {
    $editions=@((Get-Command pwsh.exe -CommandType Application | Select-Object -First 1).Source,(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $index=0
    foreach ($worker in @('Install','Uninstall')) {
        $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -PackageDirectory "' + $PackageDirectory + '" -ScratchDirectory "' + $ScratchDirectory + '" -Mode ' + $worker
        $child=Start-Process -FilePath $editions[$index] -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $ScratchDirectory ($worker+'.out')) -RedirectStandardError (Join-Path $ScratchDirectory ($worker+'.err'))
        $null=$child.Handle; $children += $child; $index++
    }
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while (-not ([IO.File]::Exists((Join-Path $ScratchDirectory 'Install.ready')) -and [IO.File]::Exists((Join-Path $ScratchDirectory 'Uninstall.ready')))) { if ($timer.Elapsed.TotalSeconds -gt 10) { throw 'Installation workers did not become ready' }; Start-Sleep -Milliseconds 20 }
    Start-Sleep -Milliseconds 300
    Assert (-not [IO.File]::Exists((Join-Path $ScratchDirectory 'Install.done')) -and -not [IO.File]::Exists((Join-Path $ScratchDirectory 'Uninstall.done'))) 'Both installation entry points must wait for the same cross-process lock'
    $lock.Dispose(); $lock=$null
    foreach ($child in $children) { Assert ($child.WaitForExit(30000) -and $child.ExitCode -eq 0) 'Concurrent installation worker failed; inspect worker stderr' }
    $first=[IO.File]::ReadAllText((Join-Path $ScratchDirectory 'concurrent-profiles\PowerShell\profile.ps1')).Contains('# BEGIN WSLC local proxy')
    $second=[IO.File]::ReadAllText((Join-Path $ScratchDirectory 'concurrent-profiles\WindowsPowerShell\profile.ps1')).Contains('# BEGIN WSLC local proxy')
    Assert ($first -eq $second) 'Concurrent install and uninstall must leave both profiles consistent'
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    foreach ($child in $children) { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit(5000) | Out-Null }; $child.Dispose() }
}
'Installation safety checks passed: ' + $script:checks
