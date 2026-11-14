# Pure parsing/selection functions are also used by the configuration tests.
function global:Get-WslcUriAuthority {
    param([Uri]$Uri, [switch]$IncludePort)
    $hostName = $Uri.DnsSafeHost.Trim([char[]]'[]').ToLowerInvariant()
    $address = $null
    if ([Net.IPAddress]::TryParse($hostName, [ref]$address)) { $hostName = $address.ToString().ToLowerInvariant() }
    if ($hostName.Contains(':')) { $hostName = '[' + $hostName + ']' }
    if ($IncludePort -or -not $Uri.IsDefaultPort) { $hostName += ':' + $Uri.Port }
    $hostName
}

function global:ConvertTo-WslcProxyAddress {
    param([Parameter(Mandatory=$true)][string]$Value)
    $candidate = $Value.Trim()
    if (-not $candidate) { throw 'The proxy address must not be empty.' }
    if ($candidate -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $candidate = 'http://' + $candidate }
    $parsed = $null
    if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$parsed)) { throw 'Invalid proxy address. Use http://host:port.' }
    if ($parsed.Scheme -ne 'http') { throw 'Only HTTP CONNECT proxies are supported. Use an http:// proxy URL, not a SOCKS or HTTPS proxy URL.' }
    if ($parsed.UserInfo -or $parsed.Query -or $parsed.Fragment -or $parsed.AbsolutePath -ne '/') { throw 'Proxy credentials, paths, queries, and fragments are not supported.' }
    if (-not $parsed.Host -or $parsed.Port -lt 1 -or $parsed.Port -gt 65535) { throw 'The proxy must have a valid host and TCP port.' }
    $endpoint = Get-WslcUriAuthority -Uri $parsed -IncludePort
    [pscustomobject]@{ ProxyUrl = 'http://' + $endpoint; Endpoint = $endpoint }
}

function global:ConvertFrom-WslcWindowsProxyServer {
    param([Parameter(Mandatory=$true)][string]$Value)
    if ($Value -notmatch '=') { return (ConvertTo-WslcProxyAddress -Value $Value) }
    $servers = @{}
    foreach ($entry in ($Value -split ';')) {
        $pair = $entry.Trim() -split '=', 2
        if ($pair.Count -eq 2 -and $pair[1].Trim()) { $servers[$pair[0].Trim()] = $pair[1].Trim() }
    }
    foreach ($protocol in @('https','http')) {
        if ($servers.ContainsKey($protocol)) { return (ConvertTo-WslcProxyAddress -Value $servers[$protocol]) }
    }
    throw 'The Windows proxy has no HTTP/HTTPS entry. Specify an HTTP CONNECT proxy with -ProxyUrl.'
}

function global:Get-WslcWindowsProxySettings {
    $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Enabled = ($null -ne $settings -and $settings.ProxyEnable -eq 1)
        Server = [string]$settings.ProxyServer
    }
}

function global:Resolve-WslcProxySelection {
    param([string]$OverrideUrl, [string]$SavedProxyUrl, [object]$WindowsSettings, [hashtable]$Environment)
    $selection = $null; $source = ''
    if ($OverrideUrl) {
        $selection = ConvertTo-WslcProxyAddress -Value $OverrideUrl; $source = 'parameter'
    } elseif ($SavedProxyUrl) {
        $selection = ConvertTo-WslcProxyAddress -Value $SavedProxyUrl; $source = 'saved-config'
    } else {
        if ($null -eq $WindowsSettings) { $WindowsSettings = Get-WslcWindowsProxySettings }
        if ($WindowsSettings.Enabled -and $WindowsSettings.Server) {
            $selection = ConvertFrom-WslcWindowsProxyServer -Value $WindowsSettings.Server; $source = 'windows-system'
        } else {
            if ($null -eq $Environment) {
                $Environment = @{}
                foreach ($name in @('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY')) { $Environment[$name] = [Environment]::GetEnvironmentVariable($name) }
            }
            foreach ($name in @('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY')) {
                if ($Environment.ContainsKey($name) -and $Environment[$name]) {
                    $selection = ConvertTo-WslcProxyAddress -Value ([string]$Environment[$name]); $source = 'environment:' + $name; break
                }
            }
        }
    }
    if ($null -eq $selection) { throw 'No HTTP proxy was detected. Enable a Windows static proxy or use Set-WslcProxy -ProxyUrl http://host:port. PAC/WPAD is not evaluated.' }
    [pscustomobject]@{ ProxyUrl = $selection.ProxyUrl; Endpoint = $selection.Endpoint; Source = $source }
}

function global:Read-WslcConfiguration {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ mode = 'auto'; proxyUrl = $null } }
    $config = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($config -isnot [pscustomobject]) { throw 'Configuration must be a JSON object.' }
    $config
}

function global:Update-WslcConfiguration {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][hashtable]$Values)
    $config = Read-WslcConfiguration -Path $Path
    foreach ($key in $Values.Keys) { $config | Add-Member -NotePropertyName $key -NotePropertyValue $Values[$key] -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($config | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function global:Read-WslcProxyConfiguration {
    param([Parameter(Mandatory=$true)][string]$Path)
    $config = Read-WslcConfiguration -Path $Path
    if ($config.mode -notin @('auto','manual')) { throw 'Invalid proxy configuration mode; expected auto or manual.' }
    if ($config.mode -eq 'manual') {
        $address = ConvertTo-WslcProxyAddress -Value ([string]$config.proxyUrl)
        return [pscustomobject]@{ Mode = 'manual'; ProxyUrl = $address.ProxyUrl }
    }
    [pscustomobject]@{ Mode = 'auto'; ProxyUrl = $null }
}

function global:Write-WslcProxyConfiguration {
    param([Parameter(Mandatory=$true)][string]$Path, [string]$ProxyUrl, [switch]$Auto)
    $config = @{ mode = 'auto'; proxyUrl = $null }
    if (-not $Auto) { $config.mode = 'manual'; $config.proxyUrl = (ConvertTo-WslcProxyAddress -Value $ProxyUrl).ProxyUrl }
    Update-WslcConfiguration -Path $Path -Values $config
}

function global:ConvertTo-WslcRegistryMirrors {
    param([AllowEmptyCollection()][string[]]$Mirrors = @())
    $result = @()
    foreach ($mirror in $Mirrors) {
        $parsed = $null
        if (-not $mirror -or -not [Uri]::TryCreate($mirror.Trim(), [UriKind]::Absolute, [ref]$parsed) -or
            $parsed.Scheme -notin @('http','https') -or -not $parsed.Host -or $parsed.Port -lt 1 -or
            $parsed.UserInfo -or $parsed.Query -or $parsed.Fragment -or $parsed.AbsolutePath -ne '/') {
            throw 'Registry mirrors must be http(s)://host[:port] URLs without credentials, paths, queries, or fragments.'
        }
        $normalized = $parsed.Scheme + '://' + (Get-WslcUriAuthority -Uri $parsed)
        if ($result -notcontains $normalized) { $result += $normalized }
    }
    $result
}
