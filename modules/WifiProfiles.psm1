#Requires -Version 5.1
<#
.SYNOPSIS
    Backup and restore Windows Wi-Fi profiles (with optional AES-256 encryption at rest).
#>

function Test-WlanServiceAvailable {
    [CmdletBinding()]
    param()
    $svc = Get-Service -Name 'WlanSvc' -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

function Backup-WifiProfiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Security.SecureString]$EncryptionPassword = $null,
        [switch]$DryRun
    )

    Write-Log '=== Starting Wi-Fi Profiles Backup ===' -Level INFO
    $stats = [ordered]@{
        profileCount = 0
        encrypted    = ($null -ne $EncryptionPassword)
        warnings     = @()
    }

    if (-not (Test-WlanServiceAvailable)) {
        Write-Log 'WLAN AutoConfig service (WlanSvc) is not running or no Wi-Fi adapter is present. Skipping Wi-Fi backup.' -Level WARN
        $stats.warnings += 'WlanSvc not running'
        return $stats
    }

    $destRoot = Join-Path -Path $BackupDir -ChildPath 'wifi'
    if ($DryRun) {
        $listOut = & netsh.exe wlan show profiles 2>&1
        $count = ($listOut | Select-String -Pattern 'All User Profile\s*:').Count
        $stats.profileCount = $count
        Write-Log "[DryRun] Would export $count Wi-Fi profile(s) to '$destRoot' (Encrypted: $($stats.encrypted))." -Level DRYRUN
        return $stats
    }

    $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinBackup_Wifi_" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $null = & netsh.exe wlan export profile folder="$tempDir" key=clear 2>&1
        $xmlFiles = @(Get-ChildItem -LiteralPath $tempDir -Filter '*.xml' -File -ErrorAction SilentlyContinue)
        $stats.profileCount = $xmlFiles.Count

        if ($xmlFiles.Count -eq 0) {
            Write-Log 'No saved Wi-Fi profiles found to export.' -Level INFO
            return $stats
        }

        Ensure-Directory -Path $destRoot

        if ($EncryptionPassword) {
            $bundle = [ordered]@{
                exportedAt = (Get-Date -Format 'o')
                profiles   = @()
            }
            foreach ($file in $xmlFiles) {
                $bundle.profiles += [ordered]@{
                    fileName = $file.Name
                    xml      = (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8)
                }
            }
            $json = $bundle | ConvertTo-Json -Depth 5
            $encPath = Join-Path -Path $destRoot -ChildPath 'profiles.enc'
            Protect-StringToFile -PlainText $json -OutputPath $encPath -Password $EncryptionPassword
            Write-Log "Exported and encrypted $($xmlFiles.Count) Wi-Fi profile(s) to '$encPath'." -Level OK
        }
        else {
            foreach ($file in $xmlFiles) {
                Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destRoot $file.Name) -Force
            }
            Write-Log "Exported $($xmlFiles.Count) UNENCRYPTED Wi-Fi profile(s) (with plaintext keys!) to '$destRoot'." -Level WARN
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log '=== Finished Wi-Fi Profiles Backup ===' -Level OK
    return $stats
}

function Restore-WifiProfiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Security.SecureString]$EncryptionPassword = $null,
        [switch]$DryRun
    )

    Write-Log '=== Starting Wi-Fi Profiles Restore ===' -Level INFO

    if (-not (Test-WlanServiceAvailable)) {
        Write-Log 'WLAN AutoConfig service (WlanSvc) is not running on this machine. Skipping Wi-Fi restore.' -Level WARN
        return
    }

    $srcRoot = Join-Path -Path $BackupDir -ChildPath 'wifi'
    $encPath = Join-Path -Path $srcRoot -ChildPath 'profiles.enc'
    $tempDir = $null

    try {
        $xmlPaths = New-Object System.Collections.Generic.List[string]

        if (Test-Path -LiteralPath $encPath) {
            if (-not $EncryptionPassword) {
                throw 'Encryption password is required to restore encrypted Wi-Fi profiles.'
            }
            $json = Unprotect-StringFromFile -InputPath $encPath -Password $EncryptionPassword
            $bundle = $json | ConvertFrom-Json
            $profiles = @($bundle.profiles)

            if ($DryRun) {
                Write-Log "[DryRun] Would restore $($profiles.Count) encrypted Wi-Fi profile(s)." -Level DRYRUN
                foreach ($p in $profiles) {
                    Write-Log "[DryRun]   - $($p.fileName)" -Level DRYRUN
                }
                return
            }

            $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("WinBackup_WifiRestore_" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

            foreach ($p in $profiles) {
                $outFile = Join-Path -Path $tempDir -ChildPath $p.fileName
                Set-Content -LiteralPath $outFile -Value $p.xml -Encoding UTF8
                $xmlPaths.Add($outFile)
            }
        }
        elseif (Test-Path -LiteralPath $srcRoot) {
            $rawXmls = @(Get-ChildItem -LiteralPath $srcRoot -Filter '*.xml' -File -ErrorAction SilentlyContinue)
            foreach ($f in $rawXmls) { $xmlPaths.Add($f.FullName) }
        }
        else {
            Write-Log "No wifi folder found in backup '$BackupDir', skipping." -Level WARN
            return
        }

        if ($xmlPaths.Count -eq 0) {
            Write-Log 'No Wi-Fi profile XML files found to restore.' -Level WARN
            return
        }

        $restored = 0
        foreach ($xmlPath in $xmlPaths) {
            $name = Split-Path -Path $xmlPath -Leaf
            if ($DryRun) {
                Write-Log "[DryRun] Would import Wi-Fi profile: $name" -Level DRYRUN
                $restored++
                continue
            }

            $out = & netsh.exe wlan add profile filename="$xmlPath" user=all 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Imported Wi-Fi profile: $name" -Level OK
                $restored++
            }
            else {
                Write-Log "Failed to import Wi-Fi profile '$name': $($out -join ' ')" -Level WARN
            }
        }

        Write-Log "Wi-Fi restore complete: $restored profile(s) processed." -Level OK
    }
    finally {
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log '=== Finished Wi-Fi Profiles Restore ===' -Level OK
}

Export-ModuleMember -Function @(
    'Backup-WifiProfiles',
    'Restore-WifiProfiles'
)
