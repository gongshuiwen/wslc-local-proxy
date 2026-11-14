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
    $hostName = $parsed.DnsSafeHost.Trim([char[]]'[]').ToLowerInvariant()
    $address = $null
    if ([Net.IPAddress]::TryParse($hostName, [ref]$address)) { $hostName = $address.ToString() }
    if ($hostName.Contains(':')) { $hostName = '[' + $hostName + ']' }
    if (-not $parsed.IsDefaultPort) { $hostName += ':' + $parsed.Port }
    if ($parts.Count -eq 2) {
        if ($RegistryOnly -or $parts[1] -cnotmatch '^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*$') { throw 'Registry keys cannot contain paths; mirror namespace components must be valid lowercase image names.' }
        return $hostName + '/' + $parts[1]
    }
    $hostName
}

function global:Get-WslcRegistryMapping {
    param([string]$Registry)
    if ($Registry) { $Registry = ConvertTo-WslcRegistryPrefix -Value $Registry -RegistryOnly }
    $mappings = (Read-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath).registryMappings
    if ($null -eq $mappings) { return }
    if ($mappings -isnot [pscustomobject]) { throw 'registryMappings must be a JSON object of registry-to-prefix-array entries.' }
    foreach ($entry in $mappings.PSObject.Properties) {
        $source = ConvertTo-WslcRegistryPrefix -Value $entry.Name -RegistryOnly
        if ($Registry -and $source -ne $Registry) { continue }
        $mirrors = @()
        foreach ($value in $entry.Value) {
            $prefix = ConvertTo-WslcRegistryPrefix -Value $value
            if ($mirrors -cnotcontains $prefix) { $mirrors += $prefix }
        }
        [pscustomobject]@{ Registry = $source; Mirrors = $mirrors; Fallback = 'original' }
    }
}

function global:Set-WslcRegistryMapping {
    param([Parameter(Mandatory=$true)][string]$Registry, [Parameter(Mandatory=$true)][string[]]$Mirrors)
    $source = ConvertTo-WslcRegistryPrefix -Value $Registry -RegistryOnly
    $normalized = @($Mirrors | ForEach-Object { ConvertTo-WslcRegistryPrefix -Value $_ } | Select-Object -Unique)
    if (-not $normalized.Count) { throw 'Specify at least one mirror prefix, or use Clear-WslcRegistryMapping.' }
    $mappings = (Read-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath).registryMappings
    if ($null -eq $mappings) { $mappings = [pscustomobject]@{} }
    if ($mappings -isnot [pscustomobject]) { throw 'registryMappings must be a JSON object.' }
    $mappings | Add-Member -NotePropertyName $source -NotePropertyValue $normalized -Force
    Update-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath -Values @{ registryMappings = $mappings }
    Get-WslcRegistryMapping -Registry $source
}

function global:Clear-WslcRegistryMapping {
    param([ValidateNotNullOrEmpty()][string]$Registry)
    $mappings = [pscustomobject]@{}
    if ($Registry) {
        $source = ConvertTo-WslcRegistryPrefix -Value $Registry -RegistryOnly
        $saved = (Read-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath).registryMappings
        if ($null -ne $saved) {
            if ($saved -isnot [pscustomobject]) { throw 'registryMappings must be a JSON object.' }
            $mappings = $saved; $mappings.PSObject.Properties.Remove($source)
        }
    }
    Update-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath -Values @{ registryMappings = $mappings }
    Get-WslcRegistryMapping
}

function global:Get-WslcMappedPullRequest {
    param([string[]]$Arguments, [int]$CommandOffset)
    $start = $CommandOffset + 1; $command = $Arguments[$CommandOffset]
    if ($command -in @('image','container')) { $command = $Arguments[$start]; $start++ }
    if ($command -notin @('pull','run','create')) { return }
    $imageIndex = -1; $policy = 'missing'; $policyIndices = @(); $allTags = $false; $quiet = $false
    $flags = @('--interactive','--tty','--publish-all','--rm','--no-healthcheck')
    if ($command -eq 'run') { $flags += '--detach' }
    $values = 'cap-add cap-drop cidfile cpus dns dns-option dns-search domainname entrypoint env env-file gpus health-cmd health-interval health-retries health-start-period health-timeout hostname ip label memory mount name network network-alias pull restart shm-size stop-signal stop-timeout tmpfs ulimit user volume workdir' -split ' '
    for ($i = $start; $i -lt $Arguments.Count; $i++) {
        $token = $Arguments[$i]
        if ($token -in @('--help','-?')) { return }
        if ($token -eq '--') { if ($command -eq 'pull' -and $i + 2 -ne $Arguments.Count) { return }; $imageIndex = $i + 1; break }
        if (-not $token.StartsWith('-') -or $token -eq '-') {
            if ($imageIndex -ge 0) { return }
            $imageIndex = $i
            if ($command -ne 'pull') { break }
        } elseif ($command -eq 'pull') {
            if ($token -cmatch '^-[aq]+$') { $allTags = $allTags -or $token.Contains('a'); $quiet = $quiet -or $token.Contains('q') }
            elseif ($token -eq '--all-tags') { $allTags = $true }
            elseif ($token -eq '--quiet') { $quiet = $true }
            else { throw ('Unsupported pull option for registry mapping: ' + $token) }
        } elseif ($token -cin $flags -or $token -cmatch '^-[itP]+$' -or ($command -eq 'run' -and $token -cmatch '^-[ditP]+$')) { continue }
        elseif ($token -cmatch '^--([^=]+)(?:=(.*))?$') {
            $name = $Matches[1]; $inline = $token.Contains('='); $value = $Matches[2]; $indices = @($i)
            if ($name -cnotin $values) { throw ('Unsupported container option for registry mapping: ' + $token) }
            if (-not $inline) { $i++; if ($i -ge $Arguments.Count) { return }; $value = $Arguments[$i]; $indices += $i }
            if ($name -eq 'pull') { if ($policyIndices.Count) { return }; $policy = $value; $policyIndices += $indices }
        } elseif ($token -cmatch '^-[ehlmpuvw](.*)$') { if (-not $Matches[1]) { $i++ } }
        else { throw ('Unsupported container option for registry mapping: ' + $token) }
    }
    if ($imageIndex -lt 0 -or $imageIndex -ge $Arguments.Count -or $policy -cnotin @('missing','always','never')) { return }
    [pscustomobject]@{ Command = $command; Start = $start; ImageIndex = $imageIndex; Image = $Arguments[$imageIndex]; Policy = $policy; PolicyIndices = $policyIndices; AllTags = $allTags; Quiet = $quiet }
}

function global:Test-WslcCachedImage {
    param([string]$Image, [string[]]$SessionArguments)
    # Windows PowerShell 5.1 turns redirected stderr into errors, including expected cache misses.
    $ErrorActionPreference = 'Continue'
    & $global:WslcLocalProxy.Native @SessionArguments image inspect $Image *> $null
    $LASTEXITCODE -eq 0
}

function global:Invoke-WslcMappedPull {
    param([string]$Image, [string[]]$Candidates, [object]$Request, [string[]]$SessionArguments, [ref]$Resolved)
    $ErrorActionPreference = 'Continue' # Expected native failures must reach the next mirror, even with 2>&1 on PS5.1.
    $options = @(); if ($Request.AllTags) { $options += '--all-tags' }; if ($Request.Quiet) { $options += '--quiet' }
    foreach ($candidate in $Candidates) {
        if (-not $Request.Quiet) { Write-Host ('Registry pull: ' + $Image + ' -> ' + $candidate) }
        & $global:WslcLocalProxy.Native @SessionArguments pull @options $candidate
        if ($LASTEXITCODE -ne 0) { continue }
        $Resolved.Value = $Image
        if ($candidate -cne $Image) {
            if ($Image.Contains('@')) { $Resolved.Value = $candidate }
            else {
                $tags = @($candidate)
                if ($Request.AllTags) {
                    $tags = @(& $global:WslcLocalProxy.Native @SessionArguments system session run /bin/docker image ls --filter ('reference=' + $candidate + ':*') --format '{{.Repository}}:{{.Tag}}')
                    if ($LASTEXITCODE -ne 0) { $Resolved.Value = $null; return }
                }
                foreach ($tag in $tags) {
                    $target = $Image + $tag.Substring($candidate.Length)
                    & $global:WslcLocalProxy.Native @SessionArguments tag $tag $target
                    if ($LASTEXITCODE -ne 0) { $Resolved.Value = $null; return }
                }
            }
        }
        $global:LASTEXITCODE = 0
        return
    }
}

function global:Invoke-WslcRegistryMapping {
    param([ref]$Arguments, [int]$CommandOffset, [string[]]$SessionArguments = @())
    $mappings = (Read-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath).registryMappings
    if ($null -eq $mappings -or -not @($mappings.PSObject.Properties).Count) { return }
    $request = Get-WslcMappedPullRequest -Arguments $Arguments.Value -CommandOffset $CommandOffset
    if ($null -eq $request -or $request.Image -notmatch '^([^/]+)/(.+)$') { return }
    $source = $Matches[1]; $suffix = $Matches[2]
    if ($source -notmatch '[.:]' -and $source -ne 'localhost') { return }
    $mapping = @(Get-WslcRegistryMapping -Registry $source)
    if (-not $mapping.Count -or -not $mapping[0].Mirrors.Count) { return }
    $candidates = @($mapping[0].Mirrors | ForEach-Object { $_ + '/' + $suffix })
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
