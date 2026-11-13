param([string]$ScratchDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('wslc-proxy-tests-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $repository 'ProxySettings.ps1')
$script:configurationChecks = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) { throw ($Label + ': expected [' + $Expected + '], got [' + $Actual + ']') }
    $script:configurationChecks++
}
function Assert-Throws([scriptblock]$Action, [string]$Label) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw ($Label + ': expected an error') }
    $script:configurationChecks++
}
$disabledWindows = [pscustomobject]@{ Enabled=$false; Server=''; PacUrl='' }
$enabledWindows = [pscustomobject]@{ Enabled=$true; Server='http=127.0.0.1:7890;https=127.0.0.1:7891;socks=127.0.0.1:1080'; PacUrl='' }
Assert-Equal (ConvertTo-WslcProxyAddress '127.0.0.1:10808').ProxyUrl 'http://127.0.0.1:10808' 'bare address'
Assert-Equal (ConvertTo-WslcProxyAddress 'http://LOCALHOST:7890/').Endpoint 'localhost:7890' 'normalized hostname'
Assert-Equal (ConvertTo-WslcProxyAddress 'http://proxy.example').Endpoint 'proxy.example:80' 'default HTTP port'
Assert-Equal (ConvertTo-WslcProxyAddress 'http://[::1]:7890').Endpoint '[::1]:7890' 'bracketed IPv6 proxy address'
Assert-Equal (ConvertFrom-WslcWindowsProxyServer 'https=127.0.0.1:7891;http=127.0.0.1:7890').Endpoint '127.0.0.1:7891' 'Windows per-protocol selection'
Assert-Equal (ConvertFrom-WslcWindowsProxyServer 'http=127.0.0.1:7890').Endpoint '127.0.0.1:7890' 'Windows HTTP fallback'
Assert-Equal (Resolve-WslcProxySelection -OverrideUrl 'localhost:9001' -SavedProxyUrl 'localhost:9002' -WindowsSettings $enabledWindows -Environment @{HTTPS_PROXY='http://localhost:9003'}).Endpoint 'localhost:9001' 'parameter overrides everything'
Assert-Equal (Resolve-WslcProxySelection -SavedProxyUrl 'localhost:9002' -WindowsSettings $enabledWindows -Environment @{HTTPS_PROXY='http://localhost:9003'}).Source 'saved-config' 'saved override'
Assert-Equal (Resolve-WslcProxySelection -WindowsSettings $enabledWindows -Environment @{HTTPS_PROXY='http://localhost:9003'}).Endpoint '127.0.0.1:7891' 'Windows beats stale environment'
Assert-Equal (Resolve-WslcProxySelection -WindowsSettings $disabledWindows -Environment @{HTTPS_PROXY='http://localhost:9003';HTTP_PROXY='http://localhost:9004'}).Endpoint 'localhost:9003' 'HTTPS environment priority'
Assert-Equal (Resolve-WslcProxySelection -WindowsSettings $disabledWindows -Environment @{HTTP_PROXY='http://localhost:9004'}).Source 'environment:HTTP_PROXY' 'HTTP environment fallback'
Assert-Equal (Resolve-WslcProxySelection -WindowsSettings $disabledWindows -Environment @{ALL_PROXY='http://localhost:9005'}).Source 'environment:ALL_PROXY' 'HTTP-compatible ALL_PROXY'
foreach ($invalid in @('socks5://127.0.0.1:1080','https://proxy.example:443','http://user:pass@proxy.example:80','http://proxy.example:0','http://proxy.example:70000','http://proxy.example/path','http://proxy.example?x=1','http://proxy.example#fragment')) {
    $invalidValue = $invalid
    Assert-Throws { ConvertTo-WslcProxyAddress $invalidValue } ('reject ' + $invalidValue)
}
Assert-Throws { Resolve-WslcProxySelection -WindowsSettings $disabledWindows -Environment @{} } 'no proxy must fail clearly'
Assert-Throws { ConvertFrom-WslcWindowsProxyServer 'socks=127.0.0.1:1080' } 'SOCKS-only Windows setting'
New-Item -ItemType Directory -Path $ScratchDirectory -Force | Out-Null
$configPath = Join-Path $ScratchDirectory 'config.json'
Write-WslcProxyConfiguration -Path $configPath -ProxyUrl 'localhost:8765'
Assert-Equal (Read-WslcProxyConfiguration $configPath).Mode 'manual' 'persist manual mode'
Assert-Equal (Read-WslcProxyConfiguration $configPath).ProxyUrl 'http://localhost:8765' 'persist normalized address'
Write-WslcProxyConfiguration -Path $configPath -Auto
Assert-Equal (Read-WslcProxyConfiguration $configPath).Mode 'auto' 'switch back to automatic mode'
Assert-Equal (Read-WslcProxyConfiguration (Join-Path $ScratchDirectory 'absent.json')).Mode 'auto' 'fresh installation defaults to auto'
Write-Output ('Configuration checks passed: ' + $script:configurationChecks)
