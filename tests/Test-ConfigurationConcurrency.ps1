param(
    [string]$ScratchDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('wslc-lock-tests-' + [guid]::NewGuid().ToString('N'))),
    [string]$PackageDirectory = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('Parent','Write','Read','Hold')][string]$Mode = 'Parent',
    [int]$WorkerId = 0,
    [int]$Iterations = 12
)
$ErrorActionPreference = 'Stop'
$ScratchDirectory = [IO.Path]::GetFullPath($ScratchDirectory)
$PackageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
New-Item -ItemType Directory -Path $ScratchDirectory -Force | Out-Null
. (Join-Path $PackageDirectory 'profile.ps1') -DataDirectory $ScratchDirectory
$configPath = $global:WslcLocalProxy.ConfigPath
$gate = Join-Path $ScratchDirectory 'start'
$stop = Join-Path $ScratchDirectory 'stop'

if ($Mode -eq 'Hold') {
    Update-WslcConfiguration -Path $configPath -Edit {
        param($config)
        $config.marker = 'never commit this interrupted edit'
        [IO.File]::WriteAllText((Join-Path $ScratchDirectory 'held'), 'ready')
        while ($true) { Start-Sleep -Milliseconds 100 }
    }
    return
}
if ($Mode -in @('Write','Read')) {
    [IO.File]::WriteAllText((Join-Path $ScratchDirectory ('ready-' + $Mode + '-' + $WorkerId)), 'ready')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($gate)) { if ($timer.Elapsed.TotalSeconds -gt 30) { throw 'Start gate timed out' }; Start-Sleep -Milliseconds 10 }
    if ($Mode -eq 'Read') {
        $reads = 0; $previous = 0
        while (-not [IO.File]::Exists($stop)) {
            $config = Read-WslcConfiguration $configPath
            if ($config.marker -ne 'preserve' -or $config.counter -lt $previous) { throw 'Reader observed an incomplete or regressed configuration' }
            $previous = $config.counter; $reads++
            Start-Sleep -Milliseconds 1
        }
        [IO.File]::WriteAllText((Join-Path $ScratchDirectory 'reads'), [string]$reads)
    } else {
        for ($round = 0; $round -lt $Iterations; $round++) {
            Update-WslcConfiguration -Path $configPath -Edit {
                param($config)
                $config.counter = [int]$config.counter + 1
                Start-Sleep -Milliseconds 3
            }
            Set-WslcRegistryMapping -Registry ('worker-' + $WorkerId + '-' + $round + '.example') -Mirrors ('mirror.example/worker-' + $WorkerId) | Out-Null
            Clear-WslcRegistryMapping -Registry ('remove-' + $WorkerId + '-' + $round + '.example') | Out-Null
            Write-WslcProxyConfiguration -Path $configPath -Auto
            if ($WorkerId -eq 0) { Update-WslcConfiguration -Path $configPath -Values @{ registryMirrors = @('https://hub-' + $round + '.example') } }
            Update-WslcConfiguration -Path $configPath -Values @{ ('root' + $WorkerId) = $round }
        }
    }
    return
}

$script:checks = 0
function Assert($Condition, [string]$Label) { if (-not $Condition) { throw $Label }; $script:checks++ }
$ps7 = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:children = @()
function Start-Child([string]$Edition, [string]$ChildMode, [int]$Id) {
    if (-not (Test-Path -LiteralPath $Edition -PathType Leaf)) { throw ('Child executable is missing: [' + $Edition + ']') }
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -ScratchDirectory "' + $ScratchDirectory + '" -PackageDirectory "' + $PackageDirectory + '" -Mode ' + $ChildMode + ' -WorkerId ' + $Id + ' -Iterations ' + $Iterations
    $process = Start-Process -FilePath $Edition -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $ScratchDirectory ($ChildMode + '-' + $Id + '.out')) -RedirectStandardError (Join-Path $ScratchDirectory ($ChildMode + '-' + $Id + '.err'))
    $null = $process.Handle # Cache the handle before a fast child exits (Windows PowerShell 5.1).
    $script:children += $process
    $process
}
function Wait-File([string]$Path) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($Path)) { if ($timer.Elapsed.TotalSeconds -gt 20) { throw ('Child process did not become ready: ' + $Path) }; Start-Sleep -Milliseconds 20 }
}
function Wait-Child([object]$Process) {
    if (-not $Process.WaitForExit(30000)) { throw ('Child timed out: ' + $Process.Id) }
    Assert ($Process.ExitCode -eq 0) ('Child failed: ' + $Process.Id + ', exit=[' + $Process.ExitCode + ']; inspect ' + $ScratchDirectory)
}

try {
    foreach ($file in @($gate,$stop,(Join-Path $ScratchDirectory 'held'))) { if ([IO.File]::Exists($file)) { Remove-Item -LiteralPath $file } }
    foreach ($file in @(Get-ChildItem -LiteralPath $ScratchDirectory -Filter 'ready-*')) { Remove-Item -LiteralPath $file.FullName }
    $initial = [pscustomobject]@{ mode='auto'; proxyUrl=$null; marker='preserve'; counter=0; registryMirrors=@('https://hub.example'); registryMappings=[pscustomobject]@{} }
    for ($id = 0; $id -lt 6; $id++) {
        for ($round = 0; $round -lt $Iterations; $round++) { $initial.registryMappings | Add-Member -NotePropertyName ('remove-' + $id + '-' + $round + '.example') -NotePropertyValue @('remove.example') }
    }
    Update-WslcConfiguration -Path $configPath -Edit {
        param($config)
        foreach ($property in @($config.PSObject.Properties)) { $config.PSObject.Properties.Remove($property.Name) }
        foreach ($property in $initial.PSObject.Properties) { $config | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
    }

    $holder = Start-Child $ps51 Hold 0
    Wait-File (Join-Path $ScratchDirectory 'held')
    $before = [IO.File]::ReadAllBytes($configPath)
    $timedOut = $false
    try { Update-WslcConfiguration -Path $configPath -Values @{ unexpected=$true } -LockTimeoutMilliseconds 150 }
    catch [TimeoutException] { $timedOut = $true }
    Assert $timedOut 'A competing process must trigger a bounded lock timeout'
    $readTimedOut = $false
    try { Update-WslcConfiguration -Path $configPath -ReadOnly -LockTimeoutMilliseconds 150 | Out-Null }
    catch [TimeoutException] { $readTimedOut = $true }
    Assert $readTimedOut 'Readers must use the same lock as writers'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($before)) 'Lock timeout must leave file bytes unchanged'
    $holder.Kill(); Assert ($holder.WaitForExit(5000)) 'Lock holder did not stop'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($before)) 'Killing an actual edit must preserve the original file'
    Update-WslcConfiguration -Path $configPath -Values @{ recovered=$true }
    Assert (Read-WslcConfiguration $configPath).recovered 'Terminating the holder must release the OS lock'
    $failed = $false
    try { Update-WslcConfiguration -Path $configPath -Edit { param($config); $config.marker='discard'; Write-Error 'Abort this edit' } }
    catch { $failed = $true }
    Assert ($failed -and (Read-WslcConfiguration $configPath).marker -eq 'preserve') 'A failing edit must not commit'
    Read-WslcConfiguration $configPath | ForEach-Object { Update-WslcConfiguration -Path $configPath -Values @{ pipelineRead=$true } -LockTimeoutMilliseconds 150 }
    Assert (Read-WslcConfiguration $configPath).pipelineRead 'Readers must release the lock before passing a snapshot downstream'
    Update-WslcConfiguration -Path $configPath -ReadOnly | ForEach-Object { Update-WslcConfiguration -Path $configPath -Values @{ directPipelineRead=$true } -LockTimeoutMilliseconds 150 }
    Assert (Read-WslcConfiguration $configPath).directPipelineRead 'The common read transaction must also release the lock before pipeline output'
    $nested = $false
    try { Update-WslcConfiguration -Path $configPath -Edit { param($config); Read-WslcConfiguration $configPath | Out-Null } }
    catch [InvalidOperationException] { $nested = $true }
    Assert $nested 'A nested transaction must fail immediately instead of waiting for its own lock'
    Update-WslcConfiguration -Path $configPath -Values @{ afterNested=$true }
    Assert (Read-WslcConfiguration $configPath).afterNested 'A rejected nested transaction must not poison future transactions'
    $before = [IO.File]::ReadAllBytes($configPath)
    $blocked = [IO.File]::Open($configPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $failed = $false
    try { Update-WslcConfiguration -Path $configPath -Values @{ blockedReplacement=$true } }
    catch [IO.IOException] { $failed = $true }
    finally { $blocked.Dispose() }
    Assert ($failed -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($before)) 'A blocked file replacement must preserve the original file'

    $reader = Start-Child $ps7 Read 0
    $writers = @()
    for ($id = 0; $id -lt 6; $id++) {
        $edition = $ps7; if ($id % 2) { $edition = $ps51 }
        $writers += Start-Child $edition Write $id
    }
    Wait-File (Join-Path $ScratchDirectory 'ready-Read-0')
    for ($id = 0; $id -lt 6; $id++) { Wait-File (Join-Path $ScratchDirectory ('ready-Write-' + $id)) }
    [IO.File]::WriteAllText($gate, 'go')
    foreach ($writer in $writers) { Wait-Child $writer }
    [IO.File]::WriteAllText($stop, 'stop')
    Wait-Child $reader

    $final = Read-WslcConfiguration $configPath
    Assert ($final.counter -eq 6 * $Iterations) 'Concurrent read-modify-write increments lost an update'
    Assert (@($final.registryMappings.PSObject.Properties).Count -eq 6 * $Iterations) 'Concurrent mapping add/remove lost an entry'
    for ($id = 0; $id -lt 6; $id++) {
        Assert ($final.('root' + $id) -eq $Iterations - 1) ('Root field lost for writer ' + $id)
        for ($round = 0; $round -lt $Iterations; $round++) {
            Assert ($final.registryMappings.('worker-' + $id + '-' + $round + '.example')[0] -eq ('mirror.example/worker-' + $id)) 'A mapping was overwritten'
            Assert ($null -eq $final.registryMappings.PSObject.Properties[('remove-' + $id + '-' + $round + '.example')]) 'A removed mapping reappeared'
        }
    }
    Assert ($final.mode -eq 'auto' -and $null -eq $final.proxyUrl -and $final.marker -eq 'preserve' -and $final.registryMirrors[0] -eq ('https://hub-' + ($Iterations - 1) + '.example')) 'Proxy, mirror or unrelated settings were overwritten'
    Assert ([int][IO.File]::ReadAllText((Join-Path $ScratchDirectory 'reads')) -gt 0) 'The concurrent reader did not run'
    Assert (@(Get-ChildItem -LiteralPath $ScratchDirectory -Filter '*.tmp').Count -eq 0) 'Temporary files were not cleaned up'
    $deep = [pscustomobject]@{ sentinel='preserve nested data' }
    for ($level = 0; $level -lt 99; $level++) { $deep = [pscustomobject]@{ child=$deep } }
    Update-WslcConfiguration -Path $configPath -Values @{ extension=$deep }
    Assert ([IO.File]::ReadAllText($configPath).Contains('preserve nested data')) 'Nested fields must not be silently truncated'
    $before = [IO.File]::ReadAllBytes($configPath)
    for ($level = 0; $level -lt 70; $level++) { $deep = [pscustomobject]@{ child=$deep } }
    $failed = $false
    try { Update-WslcConfiguration -Path $configPath -Values @{ extension=$deep } } catch { $failed=$true }
    Assert ($failed -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($before)) 'Excessive JSON depth must fail before committing'
    [IO.File]::WriteAllText($configPath, '[{"mode":"auto","proxyUrl":null}]')
    $invalid = [IO.File]::ReadAllBytes($configPath); $failed = $false
    try { Update-WslcConfiguration -Path $configPath -Values @{ unexpected=$true } } catch { $failed=$true }
    Assert ($failed -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($invalid)) 'An array root must be rejected without rewriting it'
    [IO.File]::WriteAllBytes($configPath, $before)
    [IO.File]::Copy($configPath, $configPath + '.bak', $true)
    [IO.File]::Delete($configPath)
    $recovered = Read-WslcConfiguration $configPath
    Assert ($recovered.marker -eq 'preserve' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($before)) 'A missing primary file must recover the backup under the lock'
    Assert (-not [IO.File]::Exists($configPath + '.bak')) 'Recovery must rename the backup atomically instead of copying into a visible partial file'
    Assert ($null -eq $recovered.unexpected) 'Invalid-root edits must never be committed'
    Write-Output ('Cross-process configuration checks passed: ' + $script:checks + '; 6 mixed PS5.1/PS7 writers, ' + (6 * $Iterations) + ' increments, mappings and removals; continuous reader; timeout, killed holder and failed edit recovery.')
} finally {
    foreach ($child in $script:children) { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit(5000) | Out-Null }; $child.Dispose() }
}
