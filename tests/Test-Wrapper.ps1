param([string]$ScratchDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('wslc-wrapper-tests-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $ScratchDirectory -Force | Out-Null
. (Join-Path (Split-Path $PSScriptRoot) 'profile.ps1') -DataDirectory $ScratchDirectory
$fakeNative = Join-Path $ScratchDirectory 'fake-native.ps1'
[IO.File]::WriteAllText($fakeNative, '$global:WslcTestForwarded = @($args); $global:LASTEXITCODE = 0')
$global:WslcLocalProxy.Native = $fakeNative
function global:Initialize-WslcLocalProxy {
    param([string[]]$SessionArguments = @())
    $global:WslcTestInitCalls++
    $global:WslcTestSession = $SessionArguments -join '|'
}
function global:Initialize-WslcRegistryMirrors {
    param([string[]]$SessionArguments = @())
    $global:WslcTestMirrorCalls++
    $global:WslcTestMirrorSession = $SessionArguments -join '|'
}
$cases = @(
    @{ Arguments=@('pull','alpine:latest'); Calls=1; Session='' },
    @{ Arguments=@('--session','example','image','pull','alpine:latest'); Calls=1; Session='--session|example' },
    @{ Arguments=@('--session=example','container','run','alpine:latest','echo','--help'); Calls=1; Session='--session|example' },
    @{ Arguments=@('run','alpine:latest','echo','--session','application-session'); Calls=1; Session='' },
    @{ Arguments=@('images'); Calls=0; Session='' },
    @{ Arguments=@('pull','--help'); Calls=0; Session='' },
    @{ Arguments=@('image','pull','--help'); Calls=0; Session='' },
    @{ Arguments=@(); Calls=0; Session='' }
)
foreach ($case in $cases) {
    $global:WslcTestInitCalls=0; $global:WslcTestSession=''; $global:WslcTestForwarded=@()
    $global:WslcTestMirrorCalls=0; $global:WslcTestMirrorSession=''
    $argumentsToForward=$case.Arguments
    wslc @argumentsToForward
    if ($global:WslcTestInitCalls -ne $case.Calls -or $global:WslcTestSession -ne $case.Session) { throw ('Wrong routing dispatch: ' + ($argumentsToForward -join ' ')) }
    if ($global:WslcTestMirrorCalls -ne $case.Calls -or $global:WslcTestMirrorSession -ne $case.Session) { throw ('Wrong mirror dispatch: ' + ($argumentsToForward -join ' ')) }
    if ((ConvertTo-Json -InputObject @($global:WslcTestForwarded) -Compress) -ne (ConvertTo-Json -InputObject @($argumentsToForward) -Compress)) { throw 'Native arguments were changed.' }
}
$global:WslcLocalProxy.Enabled=$false; $global:WslcTestInitCalls=0; $global:WslcTestMirrorCalls=0
wslc pull alpine:latest
if ($global:WslcTestInitCalls -ne 0) { throw 'Disabled routing was initialized.' }
if ($global:WslcTestMirrorCalls -ne 1) { throw 'Mirrors were disabled together with proxy routing.' }
Write-Output 'Wrapper checks passed: native arguments, help, application flags, explicit sessions, mirrors without proxy.'
