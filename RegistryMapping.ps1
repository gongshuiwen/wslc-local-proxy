# Mapping is one hop through native WSLC pulls; credentials and TLS stay with the engine.
function global:ConvertTo-WslcRegistryPrefix {
    param([Parameter(Mandatory=$true)][string]$Value, [switch]$RegistryOnly)
    $parts = $Value.Trim().TrimEnd('/') -split '/', 2
    $parsed = $null
    if (-not [Uri]::TryCreate(('https://' + $parts[0]), [UriKind]::Absolute, [ref]$parsed) -or
        -not $parsed.Host -or $parsed.Port -lt 1 -or $parsed.UserInfo -or $parsed.Query -or $parsed.Fragment -or
        $parsed.AbsolutePath -ne '/' -or ($parts[0] -notmatch '[.:]' -and $parts[0] -ne 'localhost')) {
        throw 'Use a registry host[:port] or mirror host[:port]/namespace prefix, without a URL scheme or credentials.'
    }
    $hostName = Get-WslcUriAuthority -Uri $parsed -IncludePort:($parts[0] -match ':\d+$')
    if ($parts.Count -eq 2) {
        if ($RegistryOnly -or $parts[1] -cnotmatch '^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*$') { throw 'Registry keys cannot contain paths; mirror namespace components must be valid lowercase image names.' }
        return $hostName + '/' + $parts[1]
    }
    $hostName
}

function global:Read-WslcRegistryMappings {
    $mappings = (Read-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath).registryMappings
    if ($null -eq $mappings) { return [pscustomobject]@{} }
    if ($mappings -isnot [pscustomobject]) { throw 'registryMappings must be a JSON object of registry-to-prefix-array entries.' }
    $mappings
}

function global:ConvertTo-WslcRegistryPrefixes {
    param([string[]]$Prefixes)
    $Prefixes | ForEach-Object { ConvertTo-WslcRegistryPrefix -Value $_ } | Select-Object -Unique
}

function global:Get-WslcRegistryMapping {
    param([string]$Registry)
    if ($Registry) { $Registry = ConvertTo-WslcRegistryPrefix -Value $Registry -RegistryOnly }
    foreach ($entry in (Read-WslcRegistryMappings).PSObject.Properties) {
        if ($Registry -and $entry.Name -ne $Registry) { continue }
        [pscustomobject]@{ Registry = (ConvertTo-WslcRegistryPrefix -Value $entry.Name -RegistryOnly); Mirrors = @(ConvertTo-WslcRegistryPrefixes -Prefixes $entry.Value); Fallback = 'original' }
    }
}

function global:Set-WslcRegistryMapping {
    param([Parameter(Mandatory=$true)][string]$Registry, [Parameter(Mandatory=$true)][string[]]$Mirrors)
    $source = ConvertTo-WslcRegistryPrefix -Value $Registry -RegistryOnly
    $normalized = @(ConvertTo-WslcRegistryPrefixes -Prefixes $Mirrors)
    if (-not $normalized.Count) { throw 'Specify at least one mirror prefix, or use Clear-WslcRegistryMapping.' }
    $mappings = Read-WslcRegistryMappings
    $mappings | Add-Member -NotePropertyName $source -NotePropertyValue $normalized -Force
    Update-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath -Values @{ registryMappings = $mappings }
    Get-WslcRegistryMapping -Registry $source
}

function global:Clear-WslcRegistryMapping {
    param([ValidateNotNullOrEmpty()][string]$Registry)
    $mappings = [pscustomobject]@{}
    if ($Registry) {
        $source = ConvertTo-WslcRegistryPrefix -Value $Registry -RegistryOnly
        $mappings = Read-WslcRegistryMappings
        $mappings.PSObject.Properties.Remove($source)
    }
    Update-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath -Values @{ registryMappings = $mappings }
    Get-WslcRegistryMapping
}

function global:Get-WslcMappedPullRequest {
    param([string[]]$Arguments, [object]$Context)
    $start = $Context.Start; $command = $Context.Command
    if ($command -notin @('pull','run','create')) { return }
    $imageIndex = -1; $policy = 'missing'; $policyIndices = @(); $allTags = $false; $quiet = $false
    $flags = @('--help','-?'); $values = @()
    if ($command -eq 'pull') { $flags += @('--all-tags','--quiet','-a','-q') }
    else {
        $flags += @('--interactive','--tty','--publish-all','--rm','--no-healthcheck','-i','-t','-P')
        if ($command -eq 'run') { $flags += @('--detach','-d') }
        $values = @('cap-add cap-drop cidfile cpus dns dns-option dns-search domainname entrypoint env env-file gpus health-cmd health-interval health-retries health-start-period health-timeout hostname ip label memory mount name network network-alias pull restart shm-size stop-signal stop-timeout tmpfs ulimit user volume workdir' -split ' ' | ForEach-Object { '--' + $_ }) + @('-e','-h','-l','-m','-p','-u','-v','-w')
    }
    for ($i = $start; $i -lt $Arguments.Count; $i++) {
        $token = $Arguments[$i]
        if (-not $token.StartsWith('-') -or $token -in @('-','--')) {
            if ($imageIndex -ge 0) { return }
            $imageIndex = $i
            if ($command -ne 'pull') { break }
            continue
        }
        if ($token -cmatch '^--+([^=]+)(?:=(.*))?$') { $names = @('--' + $Matches[1]) }
        elseif ($token -cmatch '^-([^=]+)(?:=(.*))?$') { $names = @($Matches[1].ToCharArray() | ForEach-Object { '-' + $_ }) }
        else { return }
        $inline = $token.Contains('='); $value = $Matches[2]; $indices = @($i)
        for ($n = 0; $n -lt $names.Count; $n++) {
            $name = $names[$n]; $last = $n -eq $names.Count - 1
            if ($name -cin $flags) {
                $enabled = $true
                if ($inline -and $last) {
                    if ($value -cmatch '^"(.*)"$') { $value = $Matches[1] }
                    if ($value -notin @('true','false','1','0','t','f')) { return }
                    $enabled = $value -in @('true','1','t')
                }
                if ($name -in @('--help','-?') -and $enabled) { return [pscustomobject]@{ Help = $true } }
                if ($name -in @('--all-tags','-a')) { $allTags = $enabled }
                if ($name -in @('--quiet','-q')) { $quiet = $enabled }
            } elseif ($name -cin $values) {
                if (-not $last) { return }
                if (-not $inline) { $i++; if ($i -ge $Arguments.Count) { return }; $value = $Arguments[$i]; $indices += $i }
                if ($name -eq '--pull') { $policy = $value; $policyIndices += $indices }
            } else { return [pscustomobject]@{ Unsupported = $token } }
        }
    }
    if ($imageIndex -lt 0 -or $imageIndex -ge $Arguments.Count -or $policy -cnotin @('missing','always','never')) { return }
    [pscustomobject]@{ Command = $command; Start = $start; ImageIndex = $imageIndex; Image = $Arguments[$imageIndex]; Policy = $policy; PolicyIndices = $policyIndices; AllTags = $allTags; Quiet = $quiet }
}

function global:Test-WslcCachedImage {
    param([string]$Image, [string[]]$SessionArguments)
    # Windows PowerShell 5.1 turns redirected stderr into errors, including expected cache misses.
    $ErrorActionPreference = 'Continue'
    Invoke-WslcNative -Arguments (@($SessionArguments) + @('image','inspect',$Image)) *> $null
    $LASTEXITCODE -eq 0
}

function global:Invoke-WslcMappedPull {
    param([string]$Image, [string[]]$Candidates, [object]$Request, [string[]]$SessionArguments, [ref]$Resolved)
    $ErrorActionPreference = 'Continue' # Expected native failures must reach the next mirror, even with 2>&1 on PS5.1.
    $options = @(); if ($Request.Quiet) { $options += '--quiet' }
    foreach ($candidate in $Candidates) {
        if (-not $Request.Quiet) { Write-Host ('Registry pull: ' + $Image + ' -> ' + $candidate) }
        Invoke-WslcNative -Arguments (@($SessionArguments) + @('pull') + $options + @($candidate))
        if ($LASTEXITCODE -ne 0) { continue }
        $Resolved.Value = $Image
        if ($candidate -cne $Image) {
            if ($Image.Contains('@')) { $Resolved.Value = $candidate }
            else { Invoke-WslcNative -Arguments (@($SessionArguments) + @('tag',$candidate,$Image)); if ($LASTEXITCODE -ne 0) { $Resolved.Value = $null; return } }
        }
        $global:LASTEXITCODE = 0
        return
    }
}

function global:Invoke-WslcRegistryMapping {
    param([ref]$Arguments, [object]$Request, [string[]]$SessionArguments = @())
    if ($null -eq $Request -or $Request.Help -or $Request.AllTags) { return }
    $mappings = Read-WslcRegistryMappings
    if (-not @($mappings.PSObject.Properties).Count) { return }
    if ($Request.Unsupported) { throw ('Unsupported option for registry mapping: ' + $Request.Unsupported) }
    if ($Request.Image -notmatch '^([^/]+)/(.+)$') { return }
    $source = $Matches[1]; $suffix = $Matches[2]
    if ($source -notmatch '[.:]' -and $source -ne 'localhost') { return }
    $entry = $mappings.PSObject.Properties[(ConvertTo-WslcRegistryPrefix -Value $source -RegistryOnly)]
    if ($null -eq $entry) { return }
    $prefixes = @(ConvertTo-WslcRegistryPrefixes -Prefixes $entry.Value)
    if (-not $prefixes.Count) { return }
    $candidates = @($prefixes | ForEach-Object { $_ + '/' + $suffix })
    if ($candidates -cnotcontains $request.Image) { $candidates += $request.Image }
    if ($request.Command -ne 'pull' -and $request.Policy -ne 'always') {
        if (Test-WslcCachedImage -Image $request.Image -SessionArguments $SessionArguments) { return }
        if ($request.Policy -eq 'never') {
            if ($request.Image.Contains('@')) {
                foreach ($candidate in $candidates) {
                    if (Test-WslcCachedImage -Image $candidate -SessionArguments $SessionArguments) { $Arguments.Value[$request.ImageIndex] = $candidate; break }
                }
            }
            return
        }
    }
    $resolved = $null
    Invoke-WslcMappedPull -Image $request.Image -Candidates $candidates -Request $request -SessionArguments $SessionArguments -Resolved ([ref]$resolved)
    if ($request.Command -eq 'pull' -or $null -eq $resolved) { $Arguments.Value = $null; return }
    $forwarded = New-Object 'Collections.Generic.List[string]'
    for ($i = 0; $i -lt $Arguments.Value.Count; $i++) {
        if ($i -eq $request.Start) { $forwarded.Add('--pull'); $forwarded.Add('never') }
        if ($request.PolicyIndices -contains $i) { continue }
        if ($i -eq $request.ImageIndex) { $forwarded.Add($resolved) } else { $forwarded.Add($Arguments.Value[$i]) }
    }
    $Arguments.Value = $forwarded.ToArray()
}
