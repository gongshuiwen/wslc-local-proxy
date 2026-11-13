param([string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'wslc-local-proxy'))
# WSLC 3.0.3 local-proxy workaround. Keep the original managed engine running.
. (Join-Path $PSScriptRoot 'ProxySettings.ps1')
$global:WslcLocalProxy = [pscustomobject]@{
    Root = $PSScriptRoot
    State = (Join-Path $DataDirectory 'state')
    ConfigPath = (Join-Path $DataDirectory 'config.json')
    ProxyOverride = $null
    Native = (Get-Command wslc.exe -CommandType Application -ErrorAction Stop).Source
    Enabled = $true
}

function global:Invoke-WslcProxyShell {
    param([string]$ScriptText, [string[]]$SessionArguments = @())
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ScriptText.Replace("`r`n", "`n")))
    & $global:WslcLocalProxy.Native @SessionArguments system session run /bin/sh -c "printf %s $encoded | base64 -d | /bin/sh"
}

function global:Start-WslcProxyRelay {
    param([Parameter(Mandatory=$true)][object]$ProxySelection)
    $binary = Join-Path $global:WslcLocalProxy.Root 'wslc-local-proxy.exe'
    $builtBinary = Join-Path $global:WslcLocalProxy.Root 'dist\wslc-local-proxy.exe'
    if ((Test-Path -LiteralPath $builtBinary) -or (Test-Path -LiteralPath (Join-Path $global:WslcLocalProxy.Root 'go.mod'))) { $binary = $builtBinary }
    if (-not (Test-Path -LiteralPath $binary)) { throw 'Relay executable not found. Run Build.ps1 first.' }
    $pidPath = Join-Path $global:WslcLocalProxy.State 'relay.json'
    if (Test-Path -LiteralPath $pidPath) {
        $relayState = [IO.File]::ReadAllText($pidPath) | ConvertFrom-Json
        if ($relayState.pid) {
            $existing = Get-Process -Id ([int]$relayState.pid) -ErrorAction SilentlyContinue
            if ($existing -and $existing.Path -eq $binary) {
                if ($relayState.proxy -eq $ProxySelection.Endpoint) { return $relayState }
                Stop-Process -Id $existing.Id -ErrorAction Stop
                if (-not $existing.WaitForExit(5000)) { throw 'The previous relay did not exit.' }
            }
        }
    }
    New-Item -ItemType Directory -Path $global:WslcLocalProxy.State -Force | Out-Null
    if (Test-Path -LiteralPath $pidPath) { Remove-Item -LiteralPath $pidPath }
    $relayArguments = '-proxy "' + $ProxySelection.Endpoint + '" -state "' + $global:WslcLocalProxy.State + '"'
    $process = Start-Process -FilePath $binary -ArgumentList $relayArguments -WindowStyle Hidden -PassThru
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $process.Refresh()
        if ($process.HasExited) { throw ('Local relay exited. Check ' + (Join-Path $global:WslcLocalProxy.State 'redirect.log')) }
        if (Test-Path -LiteralPath $pidPath) {
            $relayState = [IO.File]::ReadAllText($pidPath) | ConvertFrom-Json
            if ([int]$relayState.pid -eq $process.Id) { return $relayState }
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Local relay startup timed out.'
}

function global:Initialize-WslcLocalProxy {
    param([string[]]$SessionArguments = @())
    $selection = Get-WslcProxyConfig
    $relayState = Start-WslcProxyRelay -ProxySelection $selection
    $bootstrap = @'
set -eu
state=/run/wslc-local-proxy
mkdir -p "$state"
exec 9>"$state/setup.lock"
flock -w 20 9
ports='__TLS__:__HTTP__'
if [ -r "$state/ready-v4" ] && [ "$(cat "$state/ready-v4")" = "$ports" ] && iptables -t nat -C OUTPUT -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY 2>/dev/null; then exit 0; fi
cleanup() {
  for tool in iptables ip6tables; do
    while "$tool" -t nat -D OUTPUT -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY 2>/dev/null; do :; done
    "$tool" -t nat -F WSLC_LOCAL_PROXY 2>/dev/null || true
    "$tool" -t nat -X WSLC_LOCAL_PROXY 2>/dev/null || true
  done
  while ip6tables -t filter -D OUTPUT -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY 2>/dev/null; do :; done
  ip6tables -t filter -F WSLC_LOCAL_PROXY 2>/dev/null || true
  ip6tables -t filter -X WSLC_LOCAL_PROXY 2>/dev/null || true
  rm -f "$state/ready-v2" "$state/ready-v3" "$state/ready-v4"
}
cleanup
trap cleanup EXIT HUP INT TERM
iptables -t nat -N WSLC_LOCAL_PROXY
for network in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4; do
  iptables -t nat -A WSLC_LOCAL_PROXY -d "$network" -j RETURN
done
iptables -t nat -A WSLC_LOCAL_PROXY -p tcp --dport 443 -j REDIRECT --to-ports __TLS__
iptables -t nat -A WSLC_LOCAL_PROXY -p tcp --dport 80 -j REDIRECT --to-ports __HTTP__
iptables -t nat -I OUTPUT 1 -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY
# WSLC's IPv6 loopback path cannot reach this Windows relay. Reject public
# IPv6 HTTP(S) immediately so the engine's ordinary dual-stack dialer uses IPv4.
if [ -s /proc/net/if_inet6 ]; then
  ip6tables -t filter -N WSLC_LOCAL_PROXY
  for network in ::1/128 fc00::/7 fe80::/10 ff00::/8; do ip6tables -t filter -A WSLC_LOCAL_PROXY -d "$network" -j RETURN; done
  ip6tables -t filter -A WSLC_LOCAL_PROXY -p tcp -j REJECT --reject-with tcp-reset
  ip6tables -t filter -I OUTPUT 1 -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY
fi
printf '%s' "$ports" >"$state/ready-v4"
trap - EXIT HUP INT TERM
'@
    $bootstrap = $bootstrap.Replace('__TLS__', [string][int]$relayState.tlsPort).Replace('__HTTP__', [string][int]$relayState.httpPort)
    Invoke-WslcProxyShell -ScriptText $bootstrap -SessionArguments $SessionArguments
    if ($LASTEXITCODE -ne 0) { throw 'WSLC routing initialization failed. The requested command was not run.' }
}

function global:Invoke-WslcWithLocalProxy {
    param([string[]]$WslcArguments)
    if ($null -eq $WslcArguments) { $WslcArguments = @() }
    $sessionArgs = @(); $positional = @()
    for ($i = 0; $i -lt $WslcArguments.Count; $i++) {
        if ($WslcArguments[$i] -eq '--session' -and $i + 1 -lt $WslcArguments.Count) {
            $sessionArgs = @('--session', $WslcArguments[$i + 1]); $i++; continue
        }
        if ($WslcArguments[$i] -like '--session=*') {
            $sessionArgs = @('--session', $WslcArguments[$i].Substring(10)); continue
        }
        $positional += $WslcArguments[$i]
    }
    $networkCommand = $positional.Count -gt 0 -and $positional[0] -in @('pull','push','build','run','create')
    if ($positional.Count -gt 1) {
        $networkCommand = $networkCommand -or ($positional[0] -eq 'image' -and $positional[1] -in @('pull','push','build')) -or ($positional[0] -eq 'container' -and $positional[1] -in @('run','create'))
    }
    if ($global:WslcLocalProxy.Enabled -and $networkCommand -and -not ($WslcArguments -contains '--help') -and -not ($WslcArguments -contains '-?')) {
        Initialize-WslcLocalProxy -SessionArguments $sessionArgs
    }
    & $global:WslcLocalProxy.Native @WslcArguments
    $global:LASTEXITCODE = $LASTEXITCODE
}
function global:wslc { Invoke-WslcWithLocalProxy -WslcArguments @($args) }
function global:Get-WslcProxyConfig {
    $saved = Read-WslcProxyConfiguration -Path $global:WslcLocalProxy.ConfigPath
    $selection = Resolve-WslcProxySelection -OverrideUrl $global:WslcLocalProxy.ProxyOverride -SavedProxyUrl $saved.ProxyUrl
    [pscustomobject]@{ Mode = $saved.Mode; ProxyUrl = $selection.ProxyUrl; Endpoint = $selection.Endpoint; Source = $selection.Source; ConfigPath = $global:WslcLocalProxy.ConfigPath }
}
function global:Set-WslcProxy {
    [CmdletBinding(DefaultParameterSetName='Manual')]
    param(
        [Parameter(Mandatory=$true,ParameterSetName='Manual')][string]$ProxyUrl,
        [Parameter(Mandatory=$true,ParameterSetName='Auto')][switch]$Auto
    )
    Write-WslcProxyConfiguration -Path $global:WslcLocalProxy.ConfigPath -ProxyUrl $ProxyUrl -Auto:$Auto
    $global:WslcLocalProxy.ProxyOverride = $null
    Get-WslcProxyConfig
}
function global:Enable-WslcProxy {
    param([string]$ProxyUrl)
    if ($PSBoundParameters.ContainsKey('ProxyUrl')) { $global:WslcLocalProxy.ProxyOverride = (ConvertTo-WslcProxyAddress -Value $ProxyUrl).ProxyUrl }
    $global:WslcLocalProxy.Enabled = $true
    Initialize-WslcLocalProxy
}
function global:Disable-WslcProxy {
    $global:WslcLocalProxy.Enabled = $false
    Invoke-WslcProxyShell -ScriptText @'
for tool in iptables ip6tables; do
  while "$tool" -t nat -D OUTPUT -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY 2>/dev/null; do :; done
  "$tool" -t nat -F WSLC_LOCAL_PROXY 2>/dev/null || true
  "$tool" -t nat -X WSLC_LOCAL_PROXY 2>/dev/null || true
done
while ip6tables -t filter -D OUTPUT -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY 2>/dev/null; do :; done
ip6tables -t filter -F WSLC_LOCAL_PROXY 2>/dev/null || true
ip6tables -t filter -X WSLC_LOCAL_PROXY 2>/dev/null || true
rm -f /run/wslc-local-proxy/ready-v2 /run/wslc-local-proxy/ready-v3 /run/wslc-local-proxy/ready-v4
'@
}
function global:Get-WslcProxyStatus {
    $selection = Get-WslcProxyConfig
    Write-Output ('Selected proxy: ' + $selection.ProxyUrl + '; source: ' + $selection.Source + '; hook enabled: ' + $global:WslcLocalProxy.Enabled)
    Invoke-WslcProxyShell -ScriptText @'
if [ -r /run/wslc-local-proxy/ready-v4 ]; then
  iptables -t nat -L WSLC_LOCAL_PROXY -n -v
else
  printf '%s\n' 'Routing will be initialized before the next pull/run/create/build/push.'
fi
'@
    $logPath = Join-Path $global:WslcLocalProxy.State 'redirect.log'
    if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 8 }
}
