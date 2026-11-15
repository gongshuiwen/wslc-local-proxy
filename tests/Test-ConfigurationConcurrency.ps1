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
    $held = [IO.File]::Open($configPath + '.lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { [IO.File]::WriteAllText((Join-Path $ScratchDirectory 'held'), 'ready'); while ($true) { Start-Sleep -Milliseconds 100 } }
    finally { $held.Dispose() }
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
    Update-WslcConfiguration -Path $configPath -Values @{ recovered=$true }
    Assert (Read-WslcConfiguration $configPath).recovered 'Terminating the holder must release the OS lock'
    $failed = $false
    try { Update-WslcConfiguration -Path $configPath -Edit { param($config); $config.marker='discard'; Write-Error 'Abort this edit' } }
    catch { $failed = $true }
    Assert ($failed -and (Read-WslcConfiguration $configPath).marker -eq 'preserve') 'A failing edit must not commit'
    Read-WslcConfiguration $configPath | ForEach-Object { Update-WslcConfiguration -Path $configPath -Values @{ pipelineRead=$true } -LockTimeoutMilliseconds 150 }
    Assert (Read-WslcConfiguration $configPath).pipelineRead 'Readers must release the lock before passing a snapshot downstream'

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
    Write-Output ('Cross-process configuration checks passed: ' + $script:checks + '; 6 mixed PS5.1/PS7 writers, ' + (6 * $Iterations) + ' increments, mappings and removals; continuous reader; timeout, killed holder and failed edit recovery.')
} finally {
    foreach ($child in $script:children) { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit(5000) | Out-Null }; $child.Dispose() }
}
