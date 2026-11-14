param([string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'wslc-local-proxy'))
. (Join-Path $PSScriptRoot 'ProxySettings.ps1')
$global:WslcLocalProxy = [pscustomobject]@{
    Root = $PSScriptRoot
    State = (Join-Path $DataDirectory 'state')
    ConfigPath = (Join-Path $DataDirectory 'config.json')
    ProxyOverride = $null
    Native = (Get-Command wslc.exe -CommandType Application -ErrorAction Stop).Source
    Enabled = $true
}
. (Join-Path $PSScriptRoot 'RegistrySettings.ps1')
. (Join-Path $PSScriptRoot 'RegistryMapping.ps1')

function global:Invoke-WslcSessionScript {
    param([Parameter(Mandatory=$true)][string]$ScriptText, [string[]]$SessionArguments = @())
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ScriptText.Replace("`r`n", "`n")))
    & $global:WslcLocalProxy.Native @SessionArguments system session run /bin/sh -c "printf %s $encoded | base64 -d | /bin/sh"
}

function global:Start-WslcProxyRelay {
    param([Parameter(Mandatory=$true)][object]$ProxySelection)
    $binary = Join-Path $global:WslcLocalProxy.Root 'wslc-local-proxy.exe'
    if (Test-Path -LiteralPath (Join-Path $global:WslcLocalProxy.Root 'go.mod')) { $binary = Join-Path $global:WslcLocalProxy.Root 'dist\wslc-local-proxy.exe' }
    if (-not (Test-Path -LiteralPath $binary)) { throw 'Relay executable not found. Run Build.ps1 first.' }
    $pidPath = Join-Path $global:WslcLocalProxy.State 'relay.json'
    if (Test-Path -LiteralPath $pidPath) {
        $relayState = [IO.File]::ReadAllText($pidPath) | ConvertFrom-Json
        $existing = Get-Process -Id ([int]$relayState.pid) -ErrorAction SilentlyContinue
        if ($existing -and $existing.Path -eq $binary) {
            if ($relayState.proxy -eq $ProxySelection.Endpoint) { return $relayState }
            Stop-Process -Id $existing.Id -ErrorAction Stop
            if (-not $existing.WaitForExit(5000)) { throw 'The previous relay did not exit.' }
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

function global:Invoke-WslcSessionRouting {
    param([ValidateSet('enable','disable','status')][string]$Action, [int]$TlsPort, [int]$HttpPort, [string[]]$SessionArguments = @())
    if ($Action -eq 'enable' -and ($TlsPort -lt 1 -or $HttpPort -lt 1 -or $TlsPort -gt 65535 -or $HttpPort -gt 65535)) { throw 'Invalid relay ports.' }
    $scriptText = @'
set -eu
state=/run/wslc-local-proxy
mkdir -p "$state"
exec 9>"$state/setup.lock"
flock -w 20 9
cleanup() {
  for spec in 'iptables nat' 'ip6tables filter'; do
    set -- $spec
    while "$1" -t "$2" -D OUTPUT -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY 2>/dev/null; do :; done
    "$1" -t "$2" -F WSLC_LOCAL_PROXY 2>/dev/null || true
    "$1" -t "$2" -X WSLC_LOCAL_PROXY 2>/dev/null || true
  done
  rm -f "$state/ready-v4"
}
case '__ACTION__' in
  disable) cleanup; exit 0 ;;
  status)
    if [ -r "$state/ready-v4" ]; then iptables -t nat -L WSLC_LOCAL_PROXY -n -v
    else printf '%s\n' 'Routing will be initialized before the next pull/run/create/build/push.'; fi
    exit 0 ;;
esac
ports='__TLS__:__HTTP__'
if [ -r "$state/ready-v4" ] && [ "$(cat "$state/ready-v4")" = "$ports" ] && iptables -t nat -C OUTPUT -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY 2>/dev/null; then exit 0; fi
cleanup
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
iptables -t nat -N WSLC_LOCAL_PROXY
for network in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4; do iptables -t nat -A WSLC_LOCAL_PROXY -d "$network" -j RETURN; done
iptables -t nat -A WSLC_LOCAL_PROXY -p tcp --dport 443 -j REDIRECT --to-ports __TLS__
iptables -t nat -A WSLC_LOCAL_PROXY -p tcp --dport 80 -j REDIRECT --to-ports __HTTP__
iptables -t nat -I OUTPUT 1 -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY
# Make the engine fall back to IPv4; WSLC's IPv6 loopback forwarding failed validation.
if [ -s /proc/net/if_inet6 ]; then
  ip6tables -t filter -N WSLC_LOCAL_PROXY
  for network in ::1/128 fc00::/7 fe80::/10 ff00::/8; do ip6tables -t filter -A WSLC_LOCAL_PROXY -d "$network" -j RETURN; done
  ip6tables -t filter -A WSLC_LOCAL_PROXY -p tcp -j REJECT --reject-with tcp-reset
  ip6tables -t filter -I OUTPUT 1 -p tcp -m multiport --dports 80,443 -j WSLC_LOCAL_PROXY
fi
printf '%s' "$ports" >"$state/ready-v4"
trap - EXIT HUP INT TERM
'@
    $scriptText = $scriptText.Replace('__ACTION__', $Action).Replace('__TLS__', [string]$TlsPort).Replace('__HTTP__', [string]$HttpPort)
    Invoke-WslcSessionScript -ScriptText $scriptText -SessionArguments $SessionArguments
}

function global:Initialize-WslcLocalProxy {
    param([string[]]$SessionArguments = @())
    $relay = Start-WslcProxyRelay -ProxySelection (Get-WslcProxyConfig)
    Invoke-WslcSessionRouting -Action enable -TlsPort $relay.tlsPort -HttpPort $relay.httpPort -SessionArguments $SessionArguments
    if ($LASTEXITCODE -ne 0) { throw 'WSLC routing initialization failed. The requested command was not run.' }
}

function global:wslc {
    $nativeArguments = @($args)
    $sessionArgs = @(); $offset = 0
    while ($offset -lt $nativeArguments.Count) {
        if ($nativeArguments[$offset] -eq '--session' -and $offset + 1 -lt $nativeArguments.Count) {
            $sessionArgs = @('--session', $nativeArguments[$offset + 1]); $offset += 2
        } elseif ($nativeArguments[$offset] -like '--session=*') {
            $sessionArgs = @('--session', $nativeArguments[$offset].Substring(10)); $offset++
        } else { break }
    }
    $command = ''; $next = ''
    if ($offset -lt $nativeArguments.Count) { $command = $nativeArguments[$offset] }
    if ($offset + 1 -lt $nativeArguments.Count) { $next = $nativeArguments[$offset + 1] }
    $networkCommand = $command -in @('pull','push','build','run','create') -or ($command -eq 'image' -and $next -in @('pull','push','build')) -or ($command -eq 'container' -and $next -in @('run','create'))
    if ($command -in @('image','container') -and $offset + 2 -lt $nativeArguments.Count) { $next = $nativeArguments[$offset + 2] }
    if ($networkCommand -and $next -notin @('--help','-?')) {
        Initialize-WslcRegistryMirrors -SessionArguments $sessionArgs
        if ($global:WslcLocalProxy.Enabled) { Initialize-WslcLocalProxy -SessionArguments $sessionArgs }
        Invoke-WslcRegistryMapping -Arguments ([ref]$nativeArguments) -CommandOffset $offset -SessionArguments $sessionArgs
        if ($null -eq $nativeArguments) { return }
    }
    & $global:WslcLocalProxy.Native @nativeArguments
    $global:LASTEXITCODE = $LASTEXITCODE
}

function global:Get-WslcProxyConfig {
    $saved = Read-WslcProxyConfiguration -Path $global:WslcLocalProxy.ConfigPath
    $selection = Resolve-WslcProxySelection -OverrideUrl $global:WslcLocalProxy.ProxyOverride -SavedProxyUrl $saved.ProxyUrl
    [pscustomobject]@{ Mode = $saved.Mode; ProxyUrl = $selection.ProxyUrl; Endpoint = $selection.Endpoint; Source = $selection.Source; ConfigPath = $global:WslcLocalProxy.ConfigPath }
}
function global:Set-WslcProxy {
    [CmdletBinding(DefaultParameterSetName='Manual')]
    param([Parameter(Mandatory=$true,ParameterSetName='Manual')][string]$ProxyUrl, [Parameter(Mandatory=$true,ParameterSetName='Auto')][switch]$Auto)
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
    Invoke-WslcSessionRouting -Action disable
}
function global:Get-WslcProxyStatus {
    $selection = Get-WslcProxyConfig
    Write-Output ('Selected proxy: ' + $selection.ProxyUrl + '; source: ' + $selection.Source + '; hook enabled: ' + $global:WslcLocalProxy.Enabled)
    Invoke-WslcSessionRouting -Action status
    $logPath = Join-Path $global:WslcLocalProxy.State 'redirect.log'
    if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 8 }
}
