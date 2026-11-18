# Shared only by installation and removal; runtime configuration has its own transaction.
. (Join-Path $PSScriptRoot 'ProxySettings.ps1')

function Lock-WslcInstallation {
    Open-WslcFileLock -Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'wslc-local-proxy.install.lock')
}

function Get-WslcInstallProfileRoot {
    param([string]$Destination, [string]$ProfileRoot)
    if (-not $ProfileRoot) {
        $metadata = Join-Path $Destination 'install.json'
        if ([IO.File]::Exists($metadata)) { $ProfileRoot = ([IO.File]::ReadAllText($metadata) | ConvertFrom-Json).profileRoot }
        if (-not $ProfileRoot) { $ProfileRoot = [Environment]::GetFolderPath('MyDocuments') }
    }
    [IO.Path]::GetFullPath($ProfileRoot)
}

function Assert-WslcInstallBinary {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) { throw 'Invalid relay executable. Rebuild or download the complete Windows ZIP.' }
    $offset = [BitConverter]::ToInt32($bytes,60)
    if ($offset -lt 0 -or $offset -gt $bytes.Length - 6 -or [BitConverter]::ToUInt32($bytes,$offset) -ne 17744) { throw 'Invalid Windows executable header.' }
    $machine = [BitConverter]::ToUInt16($bytes,$offset + 4)
    $architecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE','Machine')
    if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    if (-not (($machine -eq 34404 -and $architecture -in @('AMD64','ARM64')) -or ($machine -eq 43620 -and $architecture -eq 'ARM64'))) { throw ('This executable is incompatible with Windows ' + $architecture + '. Download the correct architecture.') }
    $checksum = Join-Path (Split-Path -Parent $Path) 'sha256.txt'
    if (-not [IO.File]::Exists($checksum) -or [IO.File]::ReadAllText($checksum).Trim() -notmatch '^([a-fA-F0-9]{64})\s+\*?wslc-local-proxy\.exe$') { throw 'Missing or invalid dist\sha256.txt. Rebuild or download the complete Windows ZIP.' }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Matches[1]) { throw 'Relay checksum mismatch. Rebuild or download the complete Windows ZIP.' }
}

function Get-WslcProfileText {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return '' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes),[Text.UTF8Encoding]::new($false,$true),$true)
    try { $reader.ReadToEnd() }
    catch [Text.DecoderFallbackException] { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage).GetString($bytes) }
    finally { $reader.Dispose() }
}

function Add-WslcFileChange {
    param([Collections.IList]$Changes, [string]$Path, [AllowNull()][byte[]]$Bytes, [switch]$Profile)
    $exists = [IO.File]::Exists($Path)
    if ($exists -and $null -ne $Bytes -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -ceq [Convert]::ToBase64String($Bytes)) { return }
    if (-not $exists -and $null -eq $Bytes) { return }
    $id = [guid]::NewGuid().ToString('N')
    $null = $Changes.Add([pscustomobject]@{ Path=$Path; Bytes=$Bytes; Existed=$exists; Profile=[bool]$Profile; Temporary=$Path + '.' + $id + '.tmp'; Backup=$Path + '.' + $id + '.rollback'; Applied=$false })
}

function Get-WslcProfileUpdate {
    param([string]$Path, [string]$Destination, [switch]$Remove)
    $text = Get-WslcProfileText $Path
    $pattern = '(?ms)^# BEGIN WSLC local proxy\r?\n.*?^# END WSLC local proxy\r?\n?'
    $scriptPath = [IO.Path]::GetFullPath((Join-Path $Destination 'profile.ps1')).Replace("'", "''")
    $owner = "(?im)^\.\s+'" + [regex]::Escape($scriptPath) + "'(?:\s|$)"
    $block = '# BEGIN WSLC local proxy' + "`r`n. '" + $scriptPath + "' -DataDirectory '" + $Destination.Replace("'", "''") + "'`r`n# END WSLC local proxy`r`n"
    $state = @{ inserted=$false; own=$false; foreign=$false }
    $updated = [regex]::Replace($text,$pattern,[Text.RegularExpressions.MatchEvaluator]{ param($match)
        if ($match.Value -match $owner) { $state.own=$true } else { $state.foreign=$true }
        if ($Remove) { if ($match.Value -match $owner) { return '' }; return $match.Value }
        if (-not $state.inserted) { $state.inserted=$true; return $block }; return ''
    })
    if (-not $Remove -and -not $state.inserted) { $updated = $text + $(if ($text -and -not $text.EndsWith("`n")) { "`r`n" }) + $block }
    $bytes = $null
    if ($updated -cne $text) { $encoding = [Text.UTF8Encoding]::new($true); $bytes = [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($updated)) }
    [pscustomobject]@{ Path=$Path; Bytes=$bytes; Changed=($updated -cne $text); Own=$state.own; Foreign=$state.foreign }
}

function Get-WslcInstallRelay {
    param([string]$Destination)
    $path = Join-Path $Destination 'wslc-local-proxy.exe'
    Get-Process -Name 'wslc-local-proxy' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $path } | ForEach-Object { $null = $_.Handle; $_ }
}

function Stop-WslcInstallRelay {
    param([object[]]$Processes, [switch]$Warn)
    foreach ($process in $Processes) {
        try { if (-not $process.HasExited) { $process.Kill(); if (-not $process.WaitForExit(5000)) { throw 'Relay did not exit.' } } }
        catch { if (-not $Warn) { throw }; Write-Warning ('Close the previous relay process: ' + $process.Id + '. ' + $_.Exception.Message) -WarningAction Continue }
    }
}

function Invoke-WslcInstallFileOperation {
    param([scriptblock]$Operation, [string]$BackupPath)
    for ($attempt=0; ; $attempt++) {
        try { & $Operation; return }
        catch [IO.IOException] {
            # Retry only untouched operations. Never overwrite a backup from a partial replacement.
            if ($attempt -ge 20 -or ($_.Exception.HResult -band 65535) -notin @(32,33) -or ($BackupPath -and [IO.File]::Exists($BackupPath))) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Invoke-WslcInstallChanges {
    param([object[]]$Changes, [string]$Destination, [scriptblock]$Commit)
    $clean = $false
    try {
        # Stage all writes before touching live files. Keep original file objects for rollback.
        foreach ($change in $Changes) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $change.Path) -Force | Out-Null
            if ($null -ne $change.Bytes) { [IO.File]::WriteAllBytes($change.Temporary,$change.Bytes) }
            if ($change.Profile -and $change.Existed) {
                $backups = Join-Path $Destination 'backups'
                New-Item -ItemType Directory -Path $backups -Force | Out-Null
                Copy-Item -LiteralPath $change.Path -Destination (Join-Path $backups ((Split-Path (Split-Path $change.Path) -Leaf) + '-profile-' + [guid]::NewGuid().ToString('N') + '.ps1'))
            }
        }
        foreach ($change in $Changes) {
            try {
                Invoke-WslcInstallFileOperation -BackupPath $change.Backup -Operation {
                    if ($null -eq $change.Bytes) { [IO.File]::Move($change.Path,$change.Backup) }
                    elseif ($change.Existed) { [IO.File]::Replace($change.Temporary,$change.Path,$change.Backup) }
                    else { [IO.File]::Move($change.Temporary,$change.Path) }
                }
            } catch { throw [IO.IOException]::new(('Cannot update ' + $change.Path + ': ' + $_.Exception.Message),$_.Exception) }
            $change.Applied = $true
        }
        & $Commit | Out-Null
        $clean = $true
    } catch {
        $failure = $_; $errors = @()
        for ($index=$Changes.Count-1; $index -ge 0; $index--) {
            $change = $Changes[$index]
            try {
                if ([IO.File]::Exists($change.Backup)) {
                    # A running image can be renamed, but cannot be the source of ReplaceFile.
                    if ([IO.File]::Exists($change.Path)) { Invoke-WslcInstallFileOperation { [IO.File]::Move($change.Path,$change.Backup + '.discard') } }
                    Invoke-WslcInstallFileOperation { [IO.File]::Move($change.Backup,$change.Path) }
                } elseif ($change.Applied -and -not $change.Existed) { [IO.File]::Delete($change.Path) }
            } catch { $errors += $_.Exception.Message }
        }
        $clean = $errors.Count -eq 0
        if (-not $clean) { throw ($failure.Exception.Message + ' Rollback incomplete; retain the .rollback files. ' + ($errors -join '; ')) }
        throw $failure
    } finally {
        if ($clean) { foreach ($change in $Changes) { foreach ($path in @($change.Temporary,$change.Backup,($change.Backup + '.discard'))) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue } } }
    }
}
