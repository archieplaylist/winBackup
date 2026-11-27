#Requires -Version 5.1
<#
.SYNOPSIS
    WinBackup — Manual Windows 10/11 Backup & Restore Toolkit.

.DESCRIPTION
    Backs up and restores User Data, AppData, Browser Data, Windows Generic Credentials,
    Wi-Fi Profiles, and Installed Apps. Supports both an interactive menu and CLI flags.

.EXAMPLE
    .\WinBackup.ps1
    Launches the interactive menu.

.EXAMPLE
    .\WinBackup.ps1 -Mode Backup -BackupRoot D:\Backups -EncryptSensitive
    Runs a full backup to D:\Backups with AES-256 encryption for Wi-Fi keys and credentials.

.EXAMPLE
    .\WinBackup.ps1 -Mode Restore -BackupPath D:\Backups\WinBackup_MYPC_20261126_153000 -Categories UserData,WifiProfiles -ConflictPolicy BackupBeforeOverwrite -DryRun
    Previews restoring UserData and WifiProfiles without making any changes.
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Backup', 'Restore', 'Verify', 'List')]
    [string]$Mode = 'Menu',

    [string]$BackupRoot = '',
    [string]$BackupPath = '',

    [ValidateSet('All', 'UserData', 'AppData', 'BrowserData', 'Credentials', 'WifiProfiles', 'InstalledApps')]
    [string[]]$Categories = @('All'),

    [ValidateSet('Overwrite', 'SkipExisting', 'BackupBeforeOverwrite')]
    [string]$ConflictPolicy = '',

    [switch]$DryRun,
    [switch]$EncryptSensitive,
    [switch]$NoEncrypt,
    [switch]$NonInteractive,

    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulesDir = Join-Path -Path $ScriptRoot -ChildPath 'modules'

# Import modules
$moduleNames = @(
    'Common.psm1',
    'Crypto.psm1',
    'UserData.psm1',
    'AppData.psm1',
    'BrowserData.psm1',
    'Credentials.psm1',
    'WifiProfiles.psm1',
    'InstalledApps.psm1'
)
foreach ($mod in $moduleNames) {
    Import-Module -Name (Join-Path -Path $ModulesDir -ChildPath $mod) -Force
}

$AllCategories = @('UserData', 'AppData', 'BrowserData', 'Credentials', 'WifiProfiles', 'InstalledApps')

# Load config.json
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $ScriptRoot -ChildPath 'config.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}
$Config = (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($ConflictPolicy)) {
    $ConflictPolicy = if ($Config.defaultConflictPolicy) { [string]$Config.defaultConflictPolicy } else { 'BackupBeforeOverwrite' }
}

function Resolve-SelectedCategories {
    param([string[]]$InputCategories)
    if (-not $InputCategories -or $InputCategories -contains 'All') {
        return $AllCategories
    }
    return @($InputCategories | Select-Object -Unique)
}

function Prompt-SelectCategories {
    Write-Host ''
    Write-Host 'Select categories (comma-separated numbers, e.g. 1,3,5 or A for All):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $AllCategories.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $AllCategories[$i])
    }
    Write-Host '  [A] All categories'
    $raw = Read-Host 'Selection [A]'
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim().ToUpperInvariant() -eq 'A') {
        return $AllCategories
    }

    $chosen = @()
    foreach ($part in ($raw -split ',')) {
        $idx = 0
        if ([int]::TryParse($part.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $AllCategories.Count) {
            $chosen += $AllCategories[$idx - 1]
        }
    }
    if ($chosen.Count -eq 0) {
        Write-Host 'No valid categories selected; defaulting to All.' -ForegroundColor Yellow
        return $AllCategories
    }
    return @($chosen | Select-Object -Unique)
}

function Prompt-SelectConflictPolicy {
    Write-Host ''
    Write-Host 'Choose conflict policy for existing files on target:' -ForegroundColor Cyan
    Write-Host '  [1] BackupBeforeOverwrite (Recommended — saves conflicting files before overwriting)'
    Write-Host '  [2] SkipExisting          (Keep existing files untouched)'
    Write-Host '  [3] Overwrite             (Overwrite existing files directly)'
    $choice = Read-Host 'Policy [1]'
    switch ($choice.Trim()) {
        '2'     { return 'SkipExisting' }
        '3'     { return 'Overwrite' }
        default { return 'BackupBeforeOverwrite' }
    }
}

function Get-BackupFolders {
    param([string]$RootDir)
    if ([string]::IsNullOrWhiteSpace($RootDir) -or -not (Test-Path -LiteralPath $RootDir)) {
        return @()
    }
    # If RootDir itself contains manifest.json, return it directly
    if (Test-Path -LiteralPath (Join-Path -Path $RootDir -ChildPath 'manifest.json')) {
        return @(Get-Item -LiteralPath $RootDir)
    }
    return @(Get-ChildItem -LiteralPath $RootDir -Directory -Filter 'WinBackup_*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'manifest.json') } |
        Sort-Object -Property Name -Descending)
}

function Invoke-BackupWorkflow {
    param(
        [string]$DestinationRoot,
        [string[]]$SelectedCategories,
        [bool]$UseEncryption,
        [switch]$IsDryRun,
        [switch]$IsNonInteractive
    )

    if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
        $DestinationRoot = Read-Host 'Enter backup destination folder (e.g. D:\WinBackups)'
    }
    if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
        throw 'Backup destination folder cannot be empty.'
    }

    $ctx = Get-CurrentUserContext
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupDir = Join-Path -Path $DestinationRoot -ChildPath ("WinBackup_{0}_{1}" -f $ctx.ComputerName, $stamp)

    if (-not $IsDryRun) {
        Ensure-Directory -Path $backupDir
        Initialize-LogFile -Path (Join-Path -Path $backupDir -ChildPath 'backup.log')
    }

    Write-Log "Starting WinBackup ($(if ($IsDryRun) { 'DRY-RUN' } else { 'LIVE' }))" -Level INFO
    Write-Log "Source: $($ctx.UserDomain)\$($ctx.UserName) on $($ctx.ComputerName) ($($ctx.OSCaption))" -Level INFO
    Write-Log "Target: $backupDir" -Level INFO
    Write-Log "Categories: $($SelectedCategories -join ', ')" -Level INFO

    if (-not (Test-IsAdmin)) {
        Write-Log 'Not running as Administrator. Wi-Fi key export and some system operations may fail.' -Level WARN
    }

    $needsSensitive = ($SelectedCategories -contains 'Credentials') -or ($SelectedCategories -contains 'WifiProfiles')
    $encPassword = $null
    if ($needsSensitive -and $UseEncryption) {
        $encPassword = Read-EncryptionPassword -Confirm
    }

    $results = [ordered]@{}

    # Show live progress on an interactive console; keep automation output clean.
    $isOutputRedirected = $false
    try { $isOutputRedirected = [Console]::IsOutputRedirected } catch { }
    $showProgress = (-not $IsNonInteractive) -and (-not $isOutputRedirected)

    $orderedCategories = @($AllCategories | Where-Object { $SelectedCategories -contains $_ })
    $totalCategories = $orderedCategories.Count
    $categoryIndex = 0
    $workflowStart = Get-Date

    foreach ($category in $orderedCategories) {
        $categoryIndex++
        $activity = "[$categoryIndex/$totalCategories] $category"
        Write-Log "--- Category $categoryIndex of ${totalCategories}: $category ---" -Level INFO
        $categoryStart = Get-Date

        switch ($category) {
            'UserData' {
                $results['UserData'] = Backup-UserData -BackupDir $backupDir -Config $Config `
                    -DryRun:$IsDryRun -ShowProgress:$showProgress -Activity $activity
            }
            'AppData' {
                $results['AppData'] = Backup-AppData -BackupDir $backupDir -Config $Config `
                    -DryRun:$IsDryRun -ShowProgress:$showProgress -Activity $activity
            }
            'BrowserData' {
                $results['BrowserData'] = Backup-BrowserData -BackupDir $backupDir -Config $Config `
                    -DryRun:$IsDryRun -NonInteractive:$IsNonInteractive `
                    -ShowProgress:$showProgress -Activity $activity
            }
            'Credentials' {
                $results['Credentials'] = Backup-WindowsCredentials -BackupDir $backupDir `
                    -EncryptionPassword $encPassword -DryRun:$IsDryRun
            }
            'WifiProfiles' {
                $results['WifiProfiles'] = Backup-WifiProfiles -BackupDir $backupDir `
                    -EncryptionPassword $encPassword -DryRun:$IsDryRun
            }
            'InstalledApps' {
                $results['InstalledApps'] = Backup-InstalledApps -BackupDir $backupDir -DryRun:$IsDryRun
            }
        }

        $categoryElapsed = (Get-Date) - $categoryStart
        Write-Log ("Category {0} finished in {1}." -f $category, (Format-Duration -Seconds $categoryElapsed.TotalSeconds)) -Level INFO
    }

    if (-not $IsDryRun) {
        $manifest = [ordered]@{
            schemaVersion     = 1
            createdAt         = (Get-Date -Format 'o')
            source            = $ctx
            categories        = $SelectedCategories
            encryptedSensitive = ($null -ne $encPassword)
            results           = $results
        }
        Write-BackupManifest -BackupDir $backupDir -ManifestData $manifest | Out-Null
        $totalElapsed = (Get-Date) - $workflowStart
        Write-Log ("Backup completed successfully in {0}: {1}" -f (Format-Duration -Seconds $totalElapsed.TotalSeconds), $backupDir) -Level OK
    }
    else {
        Write-Log '[DryRun] Dry-run backup complete. No files were written.' -Level DRYRUN
    }
}

function Invoke-RestoreWorkflow {
    param(
        [string]$TargetBackupDir,
        [string[]]$SelectedCategories,
        [string]$Policy,
        [switch]$IsDryRun,
        [switch]$IsNonInteractive
    )

    if (-not (Test-Path -LiteralPath $TargetBackupDir)) {
        throw "Backup folder not found: $TargetBackupDir"
    }

    $manifest = Read-BackupManifest -BackupDir $TargetBackupDir
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    $preRestoreRoot = ''
    if ($Policy -eq 'BackupBeforeOverwrite') {
        $preRestoreRoot = Join-Path -Path $env:USERPROFILE -ChildPath ("WinBackup_PreRestore_$stamp")
    }

    if (-not $IsDryRun) {
        $logPath = Join-Path -Path $TargetBackupDir -ChildPath ("restore_$stamp.log")
        Initialize-LogFile -Path $logPath
    }

    Write-Log "Starting WinBackup Restore ($(if ($IsDryRun) { 'DRY-RUN' } else { 'LIVE' }))" -Level INFO
    Write-Log "Backup Source: $TargetBackupDir (from $($manifest.source.ComputerName) / $($manifest.source.UserName) at $($manifest.createdAt))" -Level INFO
    Write-Log "Categories: $($SelectedCategories -join ', ') | Conflict Policy: $Policy" -Level INFO

    if (-not (Test-IsAdmin)) {
        Write-Log 'Not running as Administrator. Wi-Fi profile import and winget installs may require elevation.' -Level WARN
    }

    $needsDecrypt = $false
    if (($SelectedCategories -contains 'Credentials') -and (Test-Path -LiteralPath (Join-Path $TargetBackupDir 'credentials\generic-credentials.enc'))) {
        $needsDecrypt = $true
    }
    if (($SelectedCategories -contains 'WifiProfiles') -and (Test-Path -LiteralPath (Join-Path $TargetBackupDir 'wifi\profiles.enc'))) {
        $needsDecrypt = $true
    }

    $encPassword = $null
    if ($needsDecrypt) {
        $encPassword = Read-EncryptionPassword
    }

    if ($SelectedCategories -contains 'UserData') {
        Restore-UserData -BackupDir $TargetBackupDir -Config $Config -ConflictPolicy $Policy -PreRestoreRoot $preRestoreRoot -DryRun:$IsDryRun
    }
    if ($SelectedCategories -contains 'AppData') {
        Restore-AppData -BackupDir $TargetBackupDir -Config $Config -ConflictPolicy $Policy -PreRestoreRoot $preRestoreRoot -DryRun:$IsDryRun
    }
    if ($SelectedCategories -contains 'BrowserData') {
        Restore-BrowserData -BackupDir $TargetBackupDir -Config $Config -Manifest $manifest -ConflictPolicy $Policy -PreRestoreRoot $preRestoreRoot -DryRun:$IsDryRun -NonInteractive:$IsNonInteractive
    }
    if ($SelectedCategories -contains 'Credentials') {
        Restore-WindowsCredentials -BackupDir $TargetBackupDir -EncryptionPassword $encPassword -ConflictPolicy $Policy -DryRun:$IsDryRun
    }
    if ($SelectedCategories -contains 'WifiProfiles') {
        Restore-WifiProfiles -BackupDir $TargetBackupDir -EncryptionPassword $encPassword -DryRun:$IsDryRun
    }
    if ($SelectedCategories -contains 'InstalledApps') {
        Restore-InstalledApps -BackupDir $TargetBackupDir -DryRun:$IsDryRun -NonInteractive:$IsNonInteractive
    }

    if ($preRestoreRoot -and (Test-Path -LiteralPath $preRestoreRoot)) {
        Write-Log "Pre-restore backups of overwritten files were saved to: $preRestoreRoot" -Level INFO
    }

    Write-Log "Restore workflow finished ($(if ($IsDryRun) { 'DRY-RUN' } else { 'LIVE' }))." -Level OK
}

function Invoke-VerifyWorkflow {
    param([string]$TargetBackupDir)

    Write-Host ''
    Write-Host "Verifying backup: $TargetBackupDir" -ForegroundColor Cyan
    $manifest = Read-BackupManifest -BackupDir $TargetBackupDir

    Write-Host "  Created At  : $($manifest.createdAt)"
    Write-Host "  Source PC   : $($manifest.source.ComputerName) ($($manifest.source.OSCaption))"
    Write-Host "  Source User : $($manifest.source.UserDomain)\$($manifest.source.UserName)"
    Write-Host "  Categories  : $(($manifest.categories) -join ', ')"
    Write-Host "  Encrypted   : $($manifest.encryptedSensitive)"

    $checks = @(
        @{ Cat = 'UserData';      Rel = 'user-data' }
        @{ Cat = 'AppData';       Rel = 'appdata' }
        @{ Cat = 'BrowserData';   Rel = 'browsers' }
        @{ Cat = 'Credentials';   Rel = 'credentials' }
        @{ Cat = 'WifiProfiles';  Rel = 'wifi' }
        @{ Cat = 'InstalledApps'; Rel = 'apps' }
    )

    foreach ($chk in $checks) {
        if ($manifest.categories -contains $chk.Cat) {
            $full = Join-Path -Path $TargetBackupDir -ChildPath $chk.Rel
            if (Test-Path -LiteralPath $full) {
                Write-Host ("  [OK]   {0,-14} -> {1}" -f $chk.Cat, $chk.Rel) -ForegroundColor Green
            }
            else {
                Write-Host ("  [WARN] {0,-14} -> folder '{1}' not found (may have been empty)" -f $chk.Cat, $chk.Rel) -ForegroundColor Yellow
            }
        }
    }

    $encCreds = Join-Path -Path $TargetBackupDir -ChildPath 'credentials\generic-credentials.enc'
    $encWifi  = Join-Path -Path $TargetBackupDir -ChildPath 'wifi\profiles.enc'

    if ((Test-Path -LiteralPath $encCreds) -or (Test-Path -LiteralPath $encWifi)) {
        $testDecrypt = Read-UserConfirmation -Prompt 'Encrypted sensitive files detected. Test decryption password now?' -DefaultYes $true
        if ($testDecrypt) {
            $pw = Read-EncryptionPassword
            if (Test-Path -LiteralPath $encCreds) {
                try {
                    $null = Unprotect-StringFromFile -InputPath $encCreds -Password $pw
                    Write-Host '  [OK]   Credentials decryption verified.' -ForegroundColor Green
                }
                catch {
                    Write-Host "  [FAIL] Credentials decryption failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            if (Test-Path -LiteralPath $encWifi) {
                try {
                    $null = Unprotect-StringFromFile -InputPath $encWifi -Password $pw
                    Write-Host '  [OK]   Wi-Fi profiles decryption verified.' -ForegroundColor Green
                }
                catch {
                    Write-Host "  [FAIL] Wi-Fi profiles decryption failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
}

function Prompt-SelectBackupFolder {
    param([string]$RootHint = '')

    $root = $RootHint
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Read-Host 'Enter path to a backup folder OR parent directory containing WinBackup_* folders'
    }
    $folders = @(Get-BackupFolders -RootDir $root)
    if ($folders.Count -eq 0) {
        throw "No valid WinBackup folders (with manifest.json) found in '$root'."
    }
    if ($folders.Count -eq 1) {
        Write-Host "Selected backup: $($folders[0].FullName)" -ForegroundColor Green
        return $folders[0].FullName
    }

    Write-Host ''
    Write-Host 'Available backups:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $folders.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $folders[$i].Name)
    }
    $idxRaw = Read-Host 'Choose backup number [1]'
    $idx = 1
    if (-not [string]::IsNullOrWhiteSpace($idxRaw)) {
        [void][int]::TryParse($idxRaw.Trim(), [ref]$idx)
    }
    if ($idx -lt 1 -or $idx -gt $folders.Count) { $idx = 1 }
    return $folders[$idx - 1].FullName
}

function Show-InteractiveMenu {
    while ($true) {
        Write-Host ''
        Write-Host '======================================================' -ForegroundColor Cyan
        Write-Host '       WinBackup — Windows Backup & Restore Tool      ' -ForegroundColor Cyan
        Write-Host '======================================================' -ForegroundColor Cyan
        $adminText = if (Test-IsAdmin) { 'Administrator' } else { 'Standard User (some features limited)' }
        Write-Host "  User: $env:USERDOMAIN\$env:USERNAME | PC: $env:COMPUTERNAME | Role: $adminText" -ForegroundColor Gray
        Write-Host ''
        Write-Host '  [1] Full Backup        (All 6 categories)'
        Write-Host '  [2] Selective Backup   (Choose categories)'
        Write-Host '  [3] Restore from Backup'
        Write-Host '  [4] Verify a Backup'
        Write-Host '  [5] Exit'
        Write-Host ''

        $choice = Read-Host 'Select an option [1-5]'
        try {
            switch ($choice.Trim()) {
                '1' {
                    $dest = if ($BackupRoot) { $BackupRoot } else { Read-Host 'Backup destination root folder (e.g. D:\WinBackups)' }
                    $useEnc = Read-UserConfirmation -Prompt 'Encrypt sensitive data (Wi-Fi keys & Windows Credentials) with a password?' -DefaultYes $true
                    $dry = Read-UserConfirmation -Prompt 'Run in Dry-Run (preview only) mode?' -DefaultYes $false
                    Invoke-BackupWorkflow -DestinationRoot $dest -SelectedCategories $AllCategories -UseEncryption $useEnc -IsDryRun:$dry
                }
                '2' {
                    $dest = if ($BackupRoot) { $BackupRoot } else { Read-Host 'Backup destination root folder (e.g. D:\WinBackups)' }
                    $cats = Prompt-SelectCategories
                    $useEnc = $false
                    if (($cats -contains 'Credentials') -or ($cats -contains 'WifiProfiles')) {
                        $useEnc = Read-UserConfirmation -Prompt 'Encrypt sensitive data (Wi-Fi keys & Windows Credentials) with a password?' -DefaultYes $true
                    }
                    $dry = Read-UserConfirmation -Prompt 'Run in Dry-Run (preview only) mode?' -DefaultYes $false
                    Invoke-BackupWorkflow -DestinationRoot $dest -SelectedCategories $cats -UseEncryption $useEnc -IsDryRun:$dry
                }
                '3' {
                    $targetDir = Prompt-SelectBackupFolder -RootHint $(if ($BackupPath) { $BackupPath } else { $BackupRoot })
                    $cats = Prompt-SelectCategories
                    $pol = Prompt-SelectConflictPolicy
                    $dry = Read-UserConfirmation -Prompt 'Run in Dry-Run (preview only) mode first?' -DefaultYes $true
                    Invoke-RestoreWorkflow -TargetBackupDir $targetDir -SelectedCategories $cats -Policy $pol -IsDryRun:$dry
                }
                '4' {
                    $targetDir = Prompt-SelectBackupFolder -RootHint $(if ($BackupPath) { $BackupPath } else { $BackupRoot })
                    Invoke-VerifyWorkflow -TargetBackupDir $targetDir
                }
                '5' {
                    Write-Host 'Goodbye!' -ForegroundColor Cyan
                    return
                }
                default {
                    Write-Host 'Invalid choice. Please enter 1-5.' -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# Main execution dispatch
switch ($Mode) {
    'Menu' {
        Show-InteractiveMenu
    }
    'Backup' {
        $cats = Resolve-SelectedCategories -InputCategories $Categories
        $useEnc = if ($NoEncrypt) { $false } elseif ($EncryptSensitive) { $true } else { $true }
        Invoke-BackupWorkflow -DestinationRoot $BackupRoot -SelectedCategories $cats -UseEncryption $useEnc -IsDryRun:$DryRun -IsNonInteractive:$NonInteractive
    }
    'Restore' {
        $target = if (-not [string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath } else { Prompt-SelectBackupFolder -RootHint $BackupRoot }
        $cats = Resolve-SelectedCategories -InputCategories $Categories
        Invoke-RestoreWorkflow -TargetBackupDir $target -SelectedCategories $cats -Policy $ConflictPolicy -IsDryRun:$DryRun -IsNonInteractive:$NonInteractive
    }
    'Verify' {
        $target = if (-not [string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath } else { Prompt-SelectBackupFolder -RootHint $BackupRoot }
        Invoke-VerifyWorkflow -TargetBackupDir $target
    }
    'List' {
        $folders = @(Get-BackupFolders -RootDir $BackupRoot)
        if ($folders.Count -eq 0) {
            Write-Host "No WinBackup folders found in '$BackupRoot'." -ForegroundColor Yellow
        }
        else {
            foreach ($f in $folders) {
                $m = Read-BackupManifest -BackupDir $f.FullName
                Write-Host ("{0} | PC: {1} | User: {2} | Categories: {3} | Encrypted: {4}" -f $f.Name, $m.source.ComputerName, $m.source.UserName, ($m.categories -join ','), $m.encryptedSensitive)
            }
        }
    }
}
