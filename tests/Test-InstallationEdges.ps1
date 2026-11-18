param(
    [string]$ScratchDirectory=(Join-Path ([IO.Path]::GetTempPath()) ('wslc-install-edges-'+[guid]::NewGuid().ToString('N'))),
    [string]$PackageDirectory=(Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference='Stop'
$PackageDirectory=[IO.Path]::GetFullPath($PackageDirectory)
New-Item -ItemType Directory -Path $ScratchDirectory -Force | Out-Null
. (Join-Path $PackageDirectory 'InstallSupport.ps1')
$script:checks=0
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Install-Test([string]$Destination,[string]$Profiles,[string]$Source=$PackageDirectory) { & (Join-Path $Source 'Install-WslcProxy.ps1') -InstallDirectory $Destination -ProfileRoot $Profiles | Out-Null }
function Profile-Path([string]$Root,[string]$Edition='PowerShell') { Join-Path $Root ($Edition+'\profile.ps1') }
function Invoke-X86Batch([string]$Command,[string]$Name) {
    $inputPath=Join-Path $ScratchDirectory 'empty-input.txt'; [IO.File]::WriteAllText($inputPath,'')
    $child=Start-Process -FilePath (Join-Path $env:WINDIR 'SysWOW64\cmd.exe') -ArgumentList ('/d /s /c "'+$Command+'"') -WindowStyle Hidden -PassThru -RedirectStandardInput $inputPath -RedirectStandardOutput (Join-Path $ScratchDirectory ($Name+'.out')) -RedirectStandardError (Join-Path $ScratchDirectory ($Name+'.err'))
    $null=$child.Handle
    try { if(-not $child.WaitForExit(30000)){throw '32-bit batch worker timed out'}; $child.ExitCode }
    finally { if(-not $child.HasExited){$child.Kill(); $child.WaitForExit(5000)|Out-Null}; $child.Dispose() }
}

$profile=Join-Path $ScratchDirectory 'ansi.ps1'
$acp=[int][Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Nls\CodePage','ACP',$null)
$culture=[Globalization.CultureInfo]::CurrentCulture
$text='$taskText = "caf'+[char]0xe9+'"'+"`r`n"
[IO.File]::WriteAllText($profile,$text,[Text.Encoding]::GetEncoding($acp))
try {
    [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('en-US')
    Assert ((Get-WslcProfileText $profile) -ceq $text) 'ANSI decoding must use Windows ACP independently of formatting culture'
} finally { [Threading.Thread]::CurrentThread.CurrentCulture=$culture }

$profile=Join-Path $ScratchDirectory 'edited-profile.ps1'
$other=Join-Path $ScratchDirectory 'earlier.txt'
[IO.File]::WriteAllText($profile,'# original'+"`r`n"); [IO.File]::WriteAllText($other,'original')
$update=Get-WslcProfileUpdate $profile (Join-Path $ScratchDirectory 'unused-install')
[IO.File]::AppendAllText($profile,'$taskConcurrentEdit = 42'+"`r`n")
$changes=[Collections.ArrayList]::new()
Add-WslcFileChange $changes $other ([Text.Encoding]::UTF8.GetBytes('updated'))
Add-WslcFileChange $changes $profile $update.Bytes -Profile -Original $update.Original
$failed=$false; try { Invoke-WslcInstallChanges -Changes @($changes) -Destination $ScratchDirectory -Commit {} } catch { $failed=$true }
Assert ($failed -and [IO.File]::ReadAllText($profile).Contains('$taskConcurrentEdit')) 'Edits made between profile reading and planning must not be overwritten'
Assert ([IO.File]::ReadAllText($other) -eq 'original') 'A conflict must roll back earlier changes'

$profile=Join-Path $ScratchDirectory 'late-profile.ps1'
[IO.File]::WriteAllText($profile,'original')
$changes=[Collections.ArrayList]::new(); Add-WslcFileChange $changes $profile ([Text.Encoding]::UTF8.GetBytes('installed')) -Profile
$originalOperation=(Get-Command Invoke-WslcInstallFileOperation).ScriptBlock
$script:injectOnce=$true
function Invoke-WslcInstallFileOperation {
    param([scriptblock]$Operation,[string]$BackupPath)
    if ($script:injectOnce -and $BackupPath) { $script:injectOnce=$false; [IO.File]::AppendAllText($profile,'; external edit') }
    & $originalOperation -Operation $Operation -BackupPath $BackupPath
}
$failed=$false
try { Invoke-WslcInstallChanges -Changes @($changes) -Destination $ScratchDirectory -Commit {} } catch { $failed=$true }
finally { Set-Item -LiteralPath 'Function:\Invoke-WslcInstallFileOperation' -Value $originalOperation }
Assert ($failed -and [IO.File]::ReadAllText($profile) -eq 'original; external edit') 'A concurrent edit immediately before replacement must be detected in the original backup and restored'

$location=Get-Location; $nativeDirectory=[Environment]::CurrentDirectory
$psRoot=Join-Path $ScratchDirectory 'powershell-location'; $nativeRoot=Join-Path $ScratchDirectory 'native-location'
New-Item -ItemType Directory -Path $psRoot,$nativeRoot -Force | Out-Null
try {
    Set-Location -LiteralPath $psRoot; [Environment]::CurrentDirectory=$nativeRoot
    Install-Test '.\relative-install' '.\relative-profiles'
    Assert ([IO.File]::Exists((Join-Path $psRoot 'relative-install\wslc-local-proxy.exe')) -and -not [IO.Directory]::Exists((Join-Path $nativeRoot 'relative-install'))) 'Relative installation paths must follow the PowerShell location'
    Assert ([IO.File]::Exists((Profile-Path (Join-Path $psRoot 'relative-profiles')))) 'Relative profile paths must follow the PowerShell location'
    $failed=$false; try { Resolve-WslcInstallPath 'HKCU:\Software' | Out-Null } catch { $failed=$true }
    Assert $failed 'Non-filesystem providers must be rejected'
} finally { Set-Location -LiteralPath $location.Path; [Environment]::CurrentDirectory=$nativeDirectory }

$destination=Join-Path $ScratchDirectory 'migration-install'; $a=Join-Path $ScratchDirectory 'profiles-a'; $b=Join-Path $ScratchDirectory 'profiles-b'
Install-Test $destination $a
[IO.File]::AppendAllText((Profile-Path $a),'$taskKeepThis = 1'+"`r`n")
foreach ($edition in @('PowerShell','WindowsPowerShell')) { New-Item -ItemType Directory -Path (Split-Path -Parent (Profile-Path $b $edition)) -Force | Out-Null; [IO.File]::WriteAllText((Profile-Path $b $edition),'# existing B'+"`r`n") }
$before=(Get-WslcFileSnapshot (Profile-Path $a)).Hash
$locked=[IO.File]::Open((Profile-Path $b 'WindowsPowerShell'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$failed=$false
try { Install-Test $destination $b } catch { $failed=$true } finally { $locked.Dispose() }
Assert ($failed -and (Get-WslcFileSnapshot (Profile-Path $a)).Hash -eq $before) 'Failed profile migration must restore old loaders'
Assert ((Get-WslcInstallProfileRoot $destination) -eq $a -and -not [IO.File]::ReadAllText((Profile-Path $b)).Contains('# BEGIN WSLC local proxy')) 'Failed migration must restore metadata and the new root'
Install-Test $destination $b
Assert (-not [IO.File]::ReadAllText((Profile-Path $a)).Contains('# BEGIN WSLC local proxy') -and [IO.File]::ReadAllText((Profile-Path $a)).Contains('$taskKeepThis')) 'Successful migration must remove only old owned loaders'
Assert ([IO.File]::ReadAllText((Profile-Path $b)).Contains('# BEGIN WSLC local proxy')) 'Successful migration must install new loaders'
& (Join-Path $PackageDirectory 'Uninstall-WslcProxy.ps1') -InstallDirectory $destination -SkipSessionCleanup | Out-Null
Assert (-not [IO.File]::ReadAllText((Profile-Path $a)).Contains('# BEGIN WSLC local proxy') -and -not [IO.File]::ReadAllText((Profile-Path $b)).Contains('# BEGIN WSLC local proxy')) 'Uninstall after migration must leave no old or new loaders'

$copy=Join-Path $ScratchDirectory 'mutable-package'; New-Item -ItemType Directory -Path (Join-Path $copy 'dist') -Force | Out-Null
foreach ($file in @(Get-WslcInstallFiles)+@('Install-WslcProxy.ps1','Install.cmd')) { Copy-Item -LiteralPath (Join-Path $PackageDirectory $file) -Destination (Join-Path $copy $file) }
foreach ($file in @('wslc-local-proxy.exe','sha256.txt')) { Copy-Item -LiteralPath (Join-Path $PackageDirectory ('dist\'+$file)) -Destination (Join-Path $copy ('dist\'+$file)) }
$marker=Join-Path $ScratchDirectory 'preflight-complete'; $support=Join-Path $copy 'InstallSupport.ps1'
$content=[IO.File]::ReadAllText($support).Replace("    Open-WslcFileLock -Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData'))",("    [IO.File]::WriteAllText('"+$marker.Replace("'","''")+"','ready')`r`n    Open-WslcFileLock -Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData'))"))
[IO.File]::WriteAllText($support,$content)
$expected=(Get-FileHash -LiteralPath (Join-Path $copy 'dist\wslc-local-proxy.exe')).Hash
$destination=Join-Path $ScratchDirectory 'snapshot-install'; $profiles=Join-Path $ScratchDirectory 'snapshot-profiles'
$lock=Lock-WslcInstallation; $child=$null
try {
    $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $copy 'Install-WslcProxy.ps1')+'" -InstallDirectory "'+$destination+'" -ProfileRoot "'+$profiles+'"'
    $child=Start-Process -FilePath (Get-Command pwsh.exe -CommandType Application | Select-Object -First 1).Source -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $ScratchDirectory 'snapshot.out') -RedirectStandardError (Join-Path $ScratchDirectory 'snapshot.err')
    $null=$child.Handle; $timer=[Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($marker)) { if ($timer.Elapsed.TotalSeconds -gt 10) { throw 'Snapshot worker did not finish preflight' }; Start-Sleep -Milliseconds 20 }
    [IO.File]::WriteAllBytes((Join-Path $copy 'dist\wslc-local-proxy.exe'),[byte[]]@(1,2,3))
    $lock.Dispose(); $lock=$null
    Assert ($child.WaitForExit(30000) -and $child.ExitCode -eq 0 -and (Get-FileHash -LiteralPath (Join-Path $destination 'wslc-local-proxy.exe')).Hash -eq $expected) 'Waiting for the lock must not replace the validated executable snapshot with changed source bytes'
} finally { if ($null -ne $lock) { $lock.Dispose() }; if ($null -ne $child) { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit(5000) | Out-Null }; $child.Dispose() } }

$x86=Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
if ([IO.File]::Exists($x86)) {
    $destination=Join-Path $ScratchDirectory 'x86-install'; $profiles=Join-Path $ScratchDirectory 'x86-profiles'
    & $x86 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PackageDirectory 'Install-WslcProxy.ps1') -InstallDirectory $destination -ProfileRoot $profiles -ProxyUrl '127.0.0.1:8765'
    Assert ($LASTEXITCODE -eq 0 -and [IO.File]::Exists((Join-Path $destination 'wslc-local-proxy.exe'))) 'Direct 32-bit PowerShell installation must reenter the native host'
    . (Join-Path $destination 'profile.ps1') -DataDirectory $destination
    $relay=Start-WslcProxyRelay -ProxySelection ([pscustomobject]@{ Endpoint='127.0.0.1:8765' })
    $owned=[Diagnostics.Process]::GetProcessById([int]$relay.pid); $null=$owned.Handle
    try {
        & $x86 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $destination 'Uninstall-WslcProxy.ps1') -SkipSessionCleanup
        Assert ($LASTEXITCODE -eq 0 -and $owned.HasExited -and -not [IO.File]::ReadAllText((Profile-Path $profiles)).Contains('# BEGIN WSLC local proxy')) 'Direct 32-bit PowerShell uninstall must stop the 64-bit relay'
    } finally { if (-not $owned.HasExited) { $owned.Kill(); $owned.WaitForExit(5000) | Out-Null }; $owned.Dispose() }
    $command='"'+(Join-Path $PackageDirectory 'Install.cmd')+'" -InstallDirectory "'+$destination+'" -ProfileRoot "'+$profiles+'"'
    Assert ((Invoke-X86Batch $command 'x86-install') -eq 0) 'Install.cmd must select the native host when called from 32-bit CMD'
    . (Join-Path $destination 'profile.ps1') -DataDirectory $destination
    $relay=Start-WslcProxyRelay -ProxySelection ([pscustomobject]@{ Endpoint='127.0.0.1:8765' })
    $owned=[Diagnostics.Process]::GetProcessById([int]$relay.pid); $null=$owned.Handle
    try {
        $command='"'+(Join-Path $destination 'Uninstall.cmd')+'" -SkipSessionCleanup'
        Assert ((Invoke-X86Batch $command 'x86-uninstall') -eq 0 -and $owned.HasExited) 'Uninstall.cmd from 32-bit CMD must stop the 64-bit relay'
    } finally { if (-not $owned.HasExited) { $owned.Kill(); $owned.WaitForExit(5000) | Out-Null }; $owned.Dispose() }
}
'Installation edge checks passed: '+$script:checks
