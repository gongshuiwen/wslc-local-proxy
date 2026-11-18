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
    Update-WslcConfiguration -Path $Path -ReadOnly
}

function global:Assert-WslcConfigurationDepth {
    param([object]$Value, [int]$Depth = 0)
    if ($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary] -and $Value -isnot [Array]) { return }
    if ($Depth -gt 100) { throw 'Configuration nesting exceeds 100 levels; no changes were saved.' }
    if ($Value -is [Collections.IDictionary]) { $children = $Value.Values }
    elseif ($Value -is [Array]) { $children = $Value }
    else { $children = @($Value.PSObject.Properties | ForEach-Object { ,$_.Value }) }
    foreach ($child in $children) { Assert-WslcConfigurationDepth -Value $child -Depth ($Depth + 1) }
}

function global:Open-WslcFileLock {
    param([string]$Path, [ValidateRange(1,60000)][int]$TimeoutMilliseconds = 10000)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force -ErrorAction Stop | Out-Null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try { return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if (($_.Exception.HResult -band 65535) -notin @(32,33)) { throw }
            if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) { throw [TimeoutException]::new('Timed out waiting for lock: ' + $Path) }
            Start-Sleep -Milliseconds 50
        }
    }
}

function global:Update-WslcConfiguration {
    [CmdletBinding(DefaultParameterSetName='Values')]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true,ParameterSetName='Values')][hashtable]$Values,
        [Parameter(Mandatory=$true,ParameterSetName='Edit')][scriptblock]$Edit,
        [Parameter(Mandatory=$true,ParameterSetName='Read')][switch]$ReadOnly,
        [ValidateRange(1,60000)][int]$LockTimeoutMilliseconds = 10000
    )
    $ErrorActionPreference = 'Stop'
    $Path = [IO.Path]::GetFullPath($Path)
    if (Get-Variable -Name WslcConfigurationActive -Scope Script -ValueOnly -ErrorAction SilentlyContinue) {
        throw [InvalidOperationException]::new('Nested configuration transactions are not supported; edit the supplied configuration snapshot instead.')
    }
    $lock = $null
    $temporary = $null
    $backup = $Path + '.bak'
    $script:WslcConfigurationActive = $true
    try {
        $lock = Open-WslcFileLock -Path ($Path + '.lock') -TimeoutMilliseconds $LockTimeoutMilliseconds
        if (-not [IO.File]::Exists($Path) -and [IO.File]::Exists($backup)) { [IO.File]::Move($backup, $Path) }
        $config = [pscustomobject]@{ mode = 'auto'; proxyUrl = $null }
        if ([IO.File]::Exists($Path)) {
            $json = [IO.File]::ReadAllText($Path)
            if (-not $json.TrimStart().StartsWith('{')) { throw 'Configuration must be a JSON object.' }
            $config = $json | ConvertFrom-Json
        }
        if ($config -isnot [pscustomobject]) { throw 'Configuration must be a JSON object.' }
        if ($PSCmdlet.ParameterSetName -ne 'Read') {
            if ($null -ne $Edit) { & $Edit $config | Out-Null }
            else { foreach ($key in $Values.Keys) { $config | Add-Member -NotePropertyName $key -NotePropertyValue $Values[$key] -Force } }
            Assert-WslcConfigurationDepth -Value $config
            $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            [IO.File]::WriteAllText($temporary, ($config | ConvertTo-Json -Depth 100 -WarningAction Stop), (New-Object Text.UTF8Encoding($true)))
            # Keep the old file: ReplaceFile can fail after moving the destination aside.
            if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $backup) }
            else { [IO.File]::Move($temporary, $Path) }
        }
    } catch {
        if ($temporary -and -not [IO.File]::Exists($Path) -and [IO.File]::Exists($backup)) { [IO.File]::Move($backup, $Path) }
        throw
    } finally {
        # The open handle is the lock. Keep the sidecar so waiters always open the same file.
        try { if ($null -ne $lock) { $lock.Dispose() } } finally { $script:WslcConfigurationActive = $false }
        if ($temporary -and [IO.File]::Exists($Path)) { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue }
    }
    if ($PSCmdlet.ParameterSetName -eq 'Read') { $config }
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
