param(
    [ValidateSet('amd64','arm64')][string]$Architecture = 'amd64',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference = 'Stop'
$previous = @{}
foreach ($name in @('GOOS','GOARCH','CGO_ENABLED')) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:GOOS = 'windows'; $env:GOARCH = $Architecture; $env:CGO_ENABLED = '0'
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $binaryPath = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) 'wslc-local-proxy.exe'
    Push-Location $PSScriptRoot
    try { & go build -trimpath -ldflags '-s -w -H=windowsgui' -o $binaryPath .; if ($LASTEXITCODE -ne 0) { throw 'Go build failed.' } }
    finally { Pop-Location }
    $hash = (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path (Split-Path $binaryPath) 'sha256.txt') -Value ($hash + '  wslc-local-proxy.exe') -Encoding ascii
    Write-Output ('Built: ' + $binaryPath)
} finally {
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
