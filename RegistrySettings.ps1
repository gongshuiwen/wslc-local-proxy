# Docker Hub mirrors are configured in the engine, independently of proxy routing.
function global:Get-WslcRegistryState {
    param([string[]]$SessionArguments = @())
    $scriptText = @'
set -eu
printf '{"config":"'
base64 /etc/docker/daemon.json | tr -d '\n'
printf '","mirrors":'
/bin/docker info --format '{{json .RegistryConfig.Mirrors}}'
printf '}\n'
'@
    $output = @(Invoke-WslcSessionScript -ScriptText $scriptText -SessionArguments $SessionArguments)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the WSLC engine registry configuration.' }
    ($output -join "`n") | ConvertFrom-Json
}

function global:Sync-WslcRegistryMirrors {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Mirrors, [string[]]$SessionArguments = @())
    $desired = @(ConvertTo-WslcRegistryMirrors -Mirrors $Mirrors)
    $expected = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((($desired | ForEach-Object { $_ + '/' }) -join "`n")))
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $state = Get-WslcRegistryState -SessionArguments $SessionArguments
        $config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($state.config)) | ConvertFrom-Json
        $configured = @(foreach ($value in $config.'registry-mirrors') { ([string]$value).TrimEnd('/') })
        $effective = @(foreach ($value in $state.mirrors) { ([string]$value).TrimEnd('/') })
        if (($desired -join "`n") -ceq ($configured -join "`n") -and ($desired -join "`n") -ceq ($effective -join "`n")) { return }
        $config | Add-Member -NotePropertyName 'registry-mirrors' -NotePropertyValue $desired -Force
        $replacement = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($config | ConvertTo-Json -Depth 32 -Compress)))
        $scriptText = @'
set -eu
mkdir -p /run/wslc-local-proxy
exec 9>/run/wslc-local-proxy/setup.lock
flock -w 20 9
config=/etc/docker/daemon.json
if [ "$(base64 "$config" | tr -d '\n')" != '__ORIGINAL__' ]; then printf '%s\n' WSLC_REGISTRY_RETRY; exit 0; fi
temporary=$(mktemp /etc/docker/.wslc-mirrors.XXXXXX)
backup="$temporary.old"
restore=0
cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$restore" = 1 ]; then mv -f "$backup" "$config"; kill -HUP "$(cat /var/run/docker.pid)" || true; fi
  rm -f "$temporary" "$backup"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cp -p "$config" "$backup"
cp -p "$config" "$temporary"
printf %s '__REPLACEMENT__' | base64 -d >"$temporary"
if ! validation=$(/bin/dockerd --validate --config-file "$temporary" 2>&1); then printf '%s\n' "$validation" >&2; exit 1; fi
restore=1
mv -f "$temporary" "$config"
kill -HUP "$(cat /var/run/docker.pid)"
expected=$(printf %s '__EXPECTED__' | base64 -d)
for attempt in $(seq 1 50); do
  if actual=$(/bin/docker info --format '{{range .RegistryConfig.Mirrors}}{{println .}}{{end}}') && [ "$actual" = "$expected" ]; then restore=0; exit 0; fi
  sleep 0.1
done
printf '%s\n' 'Registry mirror reload timed out; restoring the previous engine configuration.' >&2
exit 1
'@
        $scriptText = $scriptText.Replace('__ORIGINAL__', $state.config).Replace('__REPLACEMENT__', $replacement).Replace('__EXPECTED__', $expected)
        $output = @(Invoke-WslcSessionScript -ScriptText $scriptText -SessionArguments $SessionArguments)
        if ($LASTEXITCODE -ne 0) { throw 'WSLC registry mirror configuration failed; the requested command was not run.' }
        if ($output -notcontains 'WSLC_REGISTRY_RETRY') { return }
    }
    throw 'The engine configuration changed concurrently. Retry the command.'
}

function global:Initialize-WslcRegistryMirrors {
    param([string[]]$SessionArguments = @())
    $saved = Read-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath
    if ($saved.PSObject.Properties['registryMirrors']) {
        Sync-WslcRegistryMirrors -Mirrors @(ConvertTo-WslcRegistryMirrors -Mirrors $saved.registryMirrors) -SessionArguments $SessionArguments
    }
}

function global:Get-WslcRegistryMirrors {
    param([string]$Session)
    $sessionArgs = @(); if ($Session) { $sessionArgs = @('--session', $Session) }
    $saved = Read-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath
    $configured = @(ConvertTo-WslcRegistryMirrors -Mirrors $saved.registryMirrors)
    $effective = @(foreach ($value in (Get-WslcRegistryState -SessionArguments $sessionArgs).mirrors) { ([string]$value).TrimEnd('/') })
    [pscustomobject]@{
        Session = $(if ($Session) { $Session } else { 'default' })
        Managed = [bool]$saved.PSObject.Properties['registryMirrors']
        Configured = $configured
        Effective = $effective
        Pending = ([bool]$saved.PSObject.Properties['registryMirrors'] -and ($configured -join "`n") -cne ($effective -join "`n"))
    }
}

function global:Set-WslcRegistryMirrors {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Mirrors, [string]$Session)
    $normalized = @(ConvertTo-WslcRegistryMirrors -Mirrors $Mirrors)
    $sessionArgs = @(); if ($Session) { $sessionArgs = @('--session', $Session) }
    Sync-WslcRegistryMirrors -Mirrors $normalized -SessionArguments $sessionArgs
    Update-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath -Values @{ registryMirrors = $normalized }
    Get-WslcRegistryMirrors -Session $Session
}

function global:Clear-WslcRegistryMirrors {
    param([string]$Session)
    Set-WslcRegistryMirrors -Mirrors @() -Session $Session
}
