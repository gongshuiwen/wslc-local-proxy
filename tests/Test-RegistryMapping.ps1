param([string]$ScratchDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('wslc-mapping-tests-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $ScratchDirectory -Force | Out-Null
. (Join-Path (Split-Path $PSScriptRoot) 'profile.ps1') -DataDirectory $ScratchDirectory
$script:checks = 0
function Assert($Condition, [string]$Label) { if (-not $Condition) { throw $Label }; $script:checks++ }
function Assert-Throws([scriptblock]$Action, [string]$Label) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Assert $failed $Label }
function global:Initialize-WslcRegistryMirrors {}
function global:Initialize-WslcLocalProxy {}
$fake = Join-Path $ScratchDirectory 'native.ps1'
$fakeSource = @'
$argv = @($args)
$global:MappingCalls += ,$argv
$offset = 0; if ($argv[0] -eq '--session') { $offset = 2 }
$command = $argv[$offset]; $last = $argv[-1]
$global:LASTEXITCODE = 0
if ($command -eq 'image' -and $argv[$offset + 1] -eq 'inspect') {
    if ($global:MappingCached -cnotcontains $last) { $global:LASTEXITCODE = 1; if ($global:MappingInspectErrors) { Write-Error 'Expected missing image' } }
} elseif ($command -eq 'pull') {
    if ($global:MappingFailed -ccontains $last) { $global:LASTEXITCODE = 23; if ($global:MappingPullErrors) { Write-Error 'Expected mirror failure' } }
    else { $global:MappingCached += $last; Write-Output ('PULLED:' + $last) }
} elseif ($command -eq 'tag') {
    $global:MappingCached += $last
} elseif ($command -eq 'system') {
    $filter = @($argv | Where-Object { $_ -like 'reference=*' })[0]
    $repository = $filter.Substring(10).TrimEnd(':*')
    Write-Output ($repository + ':one'); Write-Output ($repository + ':two')
} elseif ($command -in @('run','container','create')) {
    $global:LASTEXITCODE = $global:MappingContainerExit
}
'@
[IO.File]::WriteAllText($fake, $fakeSource)
$global:WslcLocalProxy.Native = $fake
function Reset-Native {
    $global:MappingCalls=@(); $global:MappingCached=@(); $global:MappingFailed=@(); $global:MappingContainerExit=0; $global:MappingInspectErrors=$false; $global:MappingPullErrors=$false
}
function Pulls { @($global:MappingCalls | Where-Object { $_ -contains 'pull' -and $_ -notcontains 'run' }) }

Assert ((ConvertTo-WslcRegistryPrefix 'MIRROR.EXAMPLE:5000/ghcr/cache/') -ceq 'mirror.example:5000/ghcr/cache') 'prefix normalization'
Assert ((ConvertTo-WslcRegistryPrefix '[::1]:5000/cache') -ceq '[::1]:5000/cache') 'IPv6 prefix normalization'
foreach ($invalid in @('https://mirror.example','http://mirror.example','user:pass@mirror.example','mirror.example/ns:tag','mirror.example/ns@sha256:abc','mirror.example/../cache','mirror.example/UPPER','mirror.example/a//b','mirror.example/a?x=1','mirror.example/a#fragment','mirror.example:0','mirror.example:70000','namespace-only')) {
    $value = $invalid
    Assert-Throws { ConvertTo-WslcRegistryPrefix $value } ('invalid prefix: ' + $invalid)
}
Assert-Throws { Set-WslcRegistryMapping -Registry ghcr.io/path -Mirrors mirror.example } 'registry key cannot have a path'
Write-WslcProxyConfiguration -Path $global:WslcLocalProxy.ConfigPath -Auto
Update-WslcConfiguration -Path $global:WslcLocalProxy.ConfigPath -Values @{ registryMirrors = @('https://hub.example'); extra = 'keep' }
Set-WslcRegistryMapping -Registry GHCR.IO -Mirrors mirror.one/ghcr,mirror.two/cache,mirror.one/ghcr | Out-Null
Set-WslcRegistryMapping -Registry lscr.io -Mirrors lscr-mirror.example | Out-Null
Assert (@(Get-WslcRegistryMapping).Count -eq 2) 'independent registry entries'
Assert ((Get-WslcRegistryMapping -Registry ghcr.io).Mirrors.Count -eq 2) 'duplicate prefixes removed'
$before = [IO.File]::ReadAllText($global:WslcLocalProxy.ConfigPath)
Assert-Throws { Set-WslcRegistryMapping -Registry ghcr.io -Mirrors 'bad://mirror' } 'invalid setting fails'
Assert ([IO.File]::ReadAllText($global:WslcLocalProxy.ConfigPath) -ceq $before) 'invalid setting leaves configuration untouched'
Assert-Throws { Clear-WslcRegistryMapping -Registry '' } 'empty explicit registry must not clear all mappings'

Reset-Native
$global:MappingFailed=@('mirror.one/ghcr/org/image:tag')
$output = @(wslc --session example image pull -q ghcr.io/org/image:tag)
$pulls = @(Pulls)
Assert ($pulls.Count -eq 2 -and $pulls[0][-1] -eq 'mirror.one/ghcr/org/image:tag' -and $pulls[1][-1] -eq 'mirror.two/cache/org/image:tag') 'mirror ordering and namespace paths'
Assert (($global:MappingCalls[-1] -join '|') -eq '--session|example|tag|mirror.two/cache/org/image:tag|ghcr.io/org/image:tag') 'retag original reference in the selected session'
Assert ($output.Count -eq 1 -and $output[0] -like 'PULLED:*') 'native pull stdout stays available to pipelines'
Reset-Native
$global:MappingFailed=@('mirror.one/ghcr/org/image:tag'); $global:MappingPullErrors=$true
$output = @(wslc pull -q ghcr.io/org/image:tag 2>&1)
Assert ((@(Pulls)).Count -eq 2 -and $LASTEXITCODE -eq 0) 'redirected mirror errors still allow fallback under Stop preference'
Reset-Native
$global:MappingFailed=@('mirror.one/ghcr/org/image:tag','mirror.two/cache/org/image:tag')
wslc pull ghcr.io/org/image:tag | Out-Null
Assert ((@(Pulls))[-1][-1] -eq 'ghcr.io/org/image:tag' -and $LASTEXITCODE -eq 0) 'fallback to origin uses native pull'
Reset-Native
$global:MappingFailed=@('mirror.one/ghcr/org/image:tag','mirror.two/cache/org/image:tag','ghcr.io/org/image:tag')
wslc run --rm ghcr.io/org/image:tag echo ok | Out-Null
Assert ($LASTEXITCODE -eq 23 -and @($global:MappingCalls | Where-Object { $_[0] -eq 'run' }).Count -eq 0) 'failed pulls preserve exit code and never execute containers'

Reset-Native
wslc run -it -P -p 3001:3001 -e 'KEY=ghcr.io/not/the/image' --shm-size=1gb --pull always ghcr.io/org/image:tag echo --pull never --help | Out-Null
$run = $global:MappingCalls[-1]
Assert (($run -join '|') -eq 'run|--pull|never|-it|-P|-p|3001:3001|-e|KEY=ghcr.io/not/the/image|--shm-size=1gb|ghcr.io/org/image:tag|echo|--pull|never|--help') 'container flags, pull policy and application arguments remain distinct'
Reset-Native
$global:MappingCached=@('ghcr.io/org/image:tag')
wslc create --name example ghcr.io/org/image:tag | Out-Null
Assert ((@(Pulls)).Count -eq 0 -and $global:MappingCalls[-1][0] -eq 'create') 'missing policy uses an existing original tag'
Reset-Native
$global:MappingInspectErrors=$true
wslc run --rm ghcr.io/org/image:tag echo ok | Out-Null
Assert ((@(Pulls)).Count -eq 1 -and $global:MappingCalls[-1][0] -eq 'run') 'expected cache-miss stderr does not stop a mapped pull'
Reset-Native
wslc container create --pull=never ghcr.io/org/image:tag | Out-Null
Assert ((@(Pulls)).Count -eq 0) 'never policy does not contact mirrors'
Reset-Native
$global:MappingContainerExit=42
wslc run --rm ghcr.io/org/image:tag false | Out-Null
Assert ($LASTEXITCODE -eq 42 -and @($global:MappingCalls | Where-Object { $_[0] -eq 'run' }).Count -eq 1) 'application failure never triggers fallback or a second execution'

$digest = '@sha256:' + ('a' * 64)
Reset-Native
wslc pull ('ghcr.io/org/image' + $digest) | Out-Null
Assert (@($global:MappingCalls | Where-Object { $_[0] -eq 'tag' }).Count -eq 0) 'digest references are never forged by tagging'
wslc run --rm --pull never ('ghcr.io/org/image' + $digest) echo ok | Out-Null
Assert (($global:MappingCalls[-1] -join '|').Contains('mirror.one/ghcr/org/image' + $digest)) 'never policy can use a cached mapped digest'
Reset-Native
wslc pull --all-tags ghcr.io/org/image | Out-Null
$tags = @($global:MappingCalls | Where-Object { $_[0] -eq 'tag' })
Assert ($tags.Count -eq 2 -and $tags[0][-1] -eq 'ghcr.io/org/image:one' -and $tags[1][-1] -eq 'ghcr.io/org/image:two') 'all-tags restores every original tag'
Reset-Native
wslc pull quay.io/org/image:tag | Out-Null
Assert ($global:MappingCalls.Count -eq 1 -and $global:MappingCalls[0][-1] -eq 'quay.io/org/image:tag') 'unmapped registries pass through'
wslc push ghcr.io/org/image:tag | Out-Null
Assert ($global:MappingCalls[-1][0] -eq 'push') 'push is never remapped'
Reset-Native
wslc run --pull always --pull never ghcr.io/org/image:tag | Out-Null
Assert ((@(Pulls)).Count -eq 0) 'duplicate pull-policy options are left to native validation before downloads'
Clear-WslcRegistryMapping -Registry ghcr.io | Out-Null
Assert (@(Get-WslcRegistryMapping).Count -eq 1 -and (Get-WslcRegistryMapping).Registry -eq 'lscr.io') 'clear one mapping preserves others'
Write-WslcProxyConfiguration -Path $global:WslcLocalProxy.ConfigPath -Auto
Assert (@(Get-WslcRegistryMapping).Count -eq 1) 'proxy settings preserve mappings'
Clear-WslcRegistryMapping | Out-Null
Reset-Native
wslc pull ghcr.io/org/image:tag | Out-Null
Assert ($global:MappingCalls.Count -eq 1) 'empty mapping configuration has no interception'
$saved = Read-WslcConfiguration $global:WslcLocalProxy.ConfigPath
Assert ($saved.mode -eq 'auto' -and $saved.registryMirrors[0] -eq 'https://hub.example' -and $saved.extra -eq 'keep') 'mapping commands preserve auto proxy, Hub mirrors and unrelated settings'
Write-Output ('Registry mapping checks passed: ' + $script:checks)
