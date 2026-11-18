param(
    [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [ValidateSet('amd64','arm64')][string[]]$Architecture = @('amd64','arm64'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist\releases')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$files=@('Install.cmd','Install-WslcProxy.ps1','Uninstall.cmd','Uninstall-WslcProxy.ps1','InstallSupport.ps1','ProxySettings.ps1','RegistrySettings.ps1','RegistryMapping.ps1','profile.ps1','README.md')
$hashes=@()
foreach ($arch in $Architecture) {
    $build=Join-Path $OutputDirectory ('windows-'+$arch)
    & (Join-Path $PSScriptRoot 'Build.ps1') -Architecture $arch -OutputDirectory $build
    $name='wslc-local-proxy-v'+$Version+'-windows-'+$arch+'.zip'
    $archive=Join-Path $OutputDirectory $name
    $zip=[IO.Compression.ZipArchive]::new([IO.File]::Open($archive,[IO.FileMode]::Create),[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $files + @('dist/wslc-local-proxy.exe','dist/sha256.txt')) {
            $source=Join-Path $PSScriptRoot $file
            if ($file.StartsWith('dist/')) { $source=Join-Path $build (Split-Path $file -Leaf) }
            $bytes=[IO.File]::ReadAllBytes($source)
            if ($file.EndsWith('.cmd')) { $bytes=[Text.Encoding]::ASCII.GetBytes([Text.Encoding]::ASCII.GetString($bytes).Replace("`r`n","`n").Replace("`n","`r`n")) }
            $stream=$zip.CreateEntry($file,[IO.Compression.CompressionLevel]::Optimal).Open()
            try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    $hashes += (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() + '  ' + $name
    Write-Output ('Packaged: '+$archive)
}
Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Value $hashes -Encoding ASCII
