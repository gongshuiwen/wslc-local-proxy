param([string]$ScratchDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('wslc-mirror-tests-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'profile.ps1') -DataDirectory $ScratchDirectory
$global:WslcMirrorTestConfig = '{"features":{"cdi":true},"labels":["preserve-me"],"registry-mirrors":["https://legacy.example/cache"]}'
$global:WslcMirrorTestEffective = @('https://legacy.example/cache/')
$global:WslcMirrorTestWrites = 0
$global:WslcMirrorTestFailure = $false
$global:WslcMirrorTestConflict = $false
function global:Invoke-WslcSessionScript {
    param([string]$ScriptText, [string[]]$SessionArguments = @())
    $global:LASTEXITCODE = 0
    $global:WslcMirrorTestSession = $SessionArguments -join '|'
    if ($ScriptText.Contains('WSLC_REGISTRY_RETRY')) {
        if ($global:WslcMirrorTestFailure) { $global:LASTEXITCODE = 1; return }
        if ($global:WslcMirrorTestConflict) { $global:WslcMirrorTestConflict = $false; return 'WSLC_REGISTRY_RETRY' }
        $encoded = [regex]::Match($ScriptText, "printf %s '([^']+)' \| base64 -d >").Groups[1].Value
        $global:WslcMirrorTestConfig = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        $global:WslcMirrorTestEffective = @(($global:WslcMirrorTestConfig | ConvertFrom-Json).'registry-mirrors' | ForEach-Object { $_ + '/' })
        $global:WslcMirrorTestWrites++
    } else {
        [pscustomobject]@{ config = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($global:WslcMirrorTestConfig)); mirrors = $global:WslcMirrorTestEffective } | ConvertTo-Json -Compress
    }
}
Write-WslcProxyConfiguration -Path $global:WslcLocalProxy.ConfigPath -Auto
Set-WslcRegistryMirrors -Mirrors @('https://ONE.example/','https://two.example') -Session example | Out-Null
if ($global:WslcMirrorTestSession -ne '--session|example') { throw 'Explicit session was lost.' }
$merged = $global:WslcMirrorTestConfig | ConvertFrom-Json
if (-not $merged.features.cdi -or $merged.labels[0] -ne 'preserve-me') { throw 'Unrelated engine settings were lost.' }
if ((Get-WslcRegistryMirrors).Pending) { throw 'Trailing slashes caused a false configuration difference.' }
Initialize-WslcRegistryMirrors
if ($global:WslcMirrorTestWrites -ne 1) { throw 'An unchanged configuration was reloaded.' }
$global:WslcMirrorTestConfig = '{"features":{"cdi":true}}'; $global:WslcMirrorTestEffective = @()
$global:WslcMirrorTestConflict = $true
Initialize-WslcRegistryMirrors
if ($global:WslcMirrorTestWrites -ne 2) { throw 'A new session did not recover the saved configuration after a concurrent edit.' }
$global:WslcMirrorTestFailure = $true
$caught = $false
try { Set-WslcRegistryMirrors -Mirrors @('https://failed.example') | Out-Null } catch { $caught = $true }
if (-not $caught -or (Read-WslcConfiguration $global:WslcLocalProxy.ConfigPath).registryMirrors[0] -ne 'https://one.example') { throw 'A failed application changed the saved configuration.' }
$global:WslcMirrorTestFailure = $false
Clear-WslcRegistryMirrors | Out-Null
$cleared = Get-WslcRegistryMirrors
if (-not $cleared.Managed -or $cleared.Configured.Count -or $cleared.Effective.Count -or $cleared.Pending) { throw 'Clear did not remove saved and effective mirrors.' }
if ((Read-WslcProxyConfiguration $global:WslcLocalProxy.ConfigPath).Mode -ne 'auto') { throw 'Mirror commands changed automatic proxy mode.' }
Write-Output 'Registry checks passed: merge preservation, explicit sessions, idempotence, session recovery, concurrent edit retry, failure persistence, clear, auto proxy.'
