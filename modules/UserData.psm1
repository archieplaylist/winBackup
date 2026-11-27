#Requires -Version 5.1
<#
.SYNOPSIS
    Backup and restore Windows User Data (Known Folders + user dotfiles).
#>

function Resolve-KnownFolderPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderName
    )

    $shellFolderMap = @{
        'Desktop'    = 'Desktop'
        'Documents'  = 'Personal'
        'Downloads'  = '{374DE290-123F-4565-9164-39C4925E467B}'
        'Pictures'   = 'My Pictures'
        'Videos'     = 'My Video'
        'Music'      = 'My Music'
        'Favorites'  = 'Favorites'
        'SavedGames' = '{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}'
        'Contacts'   = '{56784854-C6CB-462B-8169-88E350ACB882}'
        'Links'      = '{BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968}'
    }

    $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    if ($shellFolderMap.ContainsKey($FolderName)) {
        try {
            $regValName = $shellFolderMap[$FolderName]
            $props = Get-ItemProperty -Path $regPath -Name $regValName -ErrorAction Stop
            $rawPath = $props.$regValName
            if (-not [string]::IsNullOrWhiteSpace($rawPath)) {
                $expanded = [Environment]::ExpandEnvironmentVariables($rawPath)
                if (-not [string]::IsNullOrWhiteSpace($expanded)) {
                    return $expanded
                }
            }
        }
        catch {
            # Fall through to default path resolution
        }
    }

    $defaultName = if ($FolderName -eq 'SavedGames') { 'Saved Games' } else { $FolderName }
    return (Join-Path -Path $env:USERPROFILE -ChildPath $defaultName)
}

function Backup-UserData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [string[]]$ExtraExcludeDirs = @(),
        [string[]]$ExtraExcludeFiles = @(),
        [switch]$DryRun,
        [switch]$ShowProgress,
        [string]$Activity = 'UserData'
    )

    Write-Log '=== Starting User Data Backup ===' -Level INFO
    $destRoot = Join-Path -Path $BackupDir -ChildPath 'user-data'
    $foldersDest = Join-Path -Path $destRoot -ChildPath 'folders'
    $dotfilesDest = Join-Path -Path $destRoot -ChildPath 'dotfiles'

    $stats = [ordered]@{
        foldersBackedUp  = @()
        dotfilesBackedUp = @()
        warnings         = @()
    }

    $configuredExcludeDirs = @()
    if ($Config.PSObject.Properties['userDataExcludeDirs'] -and $Config.userDataExcludeDirs) {
        $configuredExcludeDirs = @($Config.userDataExcludeDirs)
    }

    $allExcludeFiles = @()
    if ($Config.PSObject.Properties['userDataExcludeFiles'] -and $Config.userDataExcludeFiles) {
        $allExcludeFiles += @($Config.userDataExcludeFiles)
    }
    if ($ExtraExcludeFiles) {
        $allExcludeFiles += @($ExtraExcludeFiles)
    }

    $rawExcludeDirs = @()
    if ($configuredExcludeDirs) { $rawExcludeDirs += $configuredExcludeDirs }
    if ($ExtraExcludeDirs) { $rawExcludeDirs += @($ExtraExcludeDirs) }

    foreach ($folderName in $Config.userFolders) {
        $srcPath = Resolve-KnownFolderPath -FolderName $folderName
        if (-not (Test-Path -LiteralPath $srcPath)) {
            Write-Log "Known folder '$folderName' not found at '$srcPath', skipping." -Level WARN
            $stats.warnings += "Missing folder: $folderName ($srcPath)"
            continue
        }

        $cleanSrcPath = $srcPath.TrimEnd('\')
        $skipFolder = $false
        foreach ($ex in $rawExcludeDirs) {
            if ([string]::IsNullOrWhiteSpace($ex)) { continue }
            $trimmedEx = $ex.Trim().TrimEnd('\')
            if ($trimmedEx.Equals($folderName, [System.StringComparison]::OrdinalIgnoreCase) -or
                $trimmedEx.Equals($cleanSrcPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $skipFolder = $true
                break
            }
        }
        if ($skipFolder) {
            Write-Log "Skipping excluded known folder: $folderName ($srcPath)" -Level INFO
            continue
        }

        $targetDir = Join-Path -Path $foldersDest -ChildPath $folderName
        $excludeDirs = Resolve-ExcludeDirs -BaseRoot $srcPath `
            -ExcludeDirs $configuredExcludeDirs `
            -ExtraExcludeDirs $ExtraExcludeDirs `
            -ScopePrefix $folderName

        $res = Invoke-SafeRobocopy -Source $srcPath -Destination $targetDir `
            -ExcludeDirs $excludeDirs `
            -ExcludeFiles $allExcludeFiles `
            -Threads $Config.robocopyThreads `
            -Retries $Config.robocopyRetries `
            -WaitSeconds $Config.robocopyWaitSeconds `
            -ConflictPolicy 'Overwrite' `
            -DryRun:$DryRun `
            -ShowProgress:$ShowProgress `
            -Activity ("$Activity - $folderName")

        if ($res.Success) {
            $stats.foldersBackedUp += $folderName
        }
        else {
            $stats.warnings += "Robocopy exit $($res.ExitCode) for folder $folderName"
        }
    }

    foreach ($dotItem in $Config.userDotfiles) {
        $srcItem = Join-Path -Path $env:USERPROFILE -ChildPath $dotItem
        if (-not (Test-Path -LiteralPath $srcItem)) {
            continue
        }

        $destItem = Join-Path -Path $dotfilesDest -ChildPath $dotItem
        if (Test-Path -LiteralPath $srcItem -PathType Container) {
            $res = Invoke-SafeRobocopy -Source $srcItem -Destination $destItem `
                -Threads $Config.robocopyThreads `
                -Retries $Config.robocopyRetries `
                -WaitSeconds $Config.robocopyWaitSeconds `
                -ConflictPolicy 'Overwrite' `
                -DryRun:$DryRun `
                -ShowProgress:$ShowProgress `
                -Activity ("$Activity - $dotItem")
            if ($res.Success) {
                $stats.dotfilesBackedUp += $dotItem
            }
            else {
                $stats.warnings += "Robocopy exit $($res.ExitCode) for dotfolder $dotItem"
            }
        }
        else {
            if ($DryRun) {
                Write-Log "[DryRun] Would copy dotfile '$srcItem' -> '$destItem'" -Level DRYRUN
                $stats.dotfilesBackedUp += $dotItem
            }
            else {
                $parent = Split-Path -Path $destItem -Parent
                Ensure-Directory -Path $parent
                Copy-Item -LiteralPath $srcItem -Destination $destItem -Force
                Write-Log "Copied dotfile: $dotItem" -Level OK
                $stats.dotfilesBackedUp += $dotItem
            }
        }
    }

    Write-Log '=== Finished User Data Backup ===' -Level OK
    return $stats
}

function Restore-UserData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [ValidateSet('Overwrite', 'SkipExisting', 'BackupBeforeOverwrite')]
        [string]$ConflictPolicy = 'BackupBeforeOverwrite',

        [string]$PreRestoreRoot = '',
        [switch]$DryRun
    )

    Write-Log '=== Starting User Data Restore ===' -Level INFO
    $srcRoot = Join-Path -Path $BackupDir -ChildPath 'user-data'
    if (-not (Test-Path -LiteralPath $srcRoot)) {
        Write-Log "No user-data folder found in backup '$BackupDir', skipping." -Level WARN
        return
    }

    $foldersSrc = Join-Path -Path $srcRoot -ChildPath 'folders'
    if (Test-Path -LiteralPath $foldersSrc) {
        $dirs = Get-ChildItem -LiteralPath $foldersSrc -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $dirs) {
            $targetPath = Resolve-KnownFolderPath -FolderName $dir.Name
            $preDir = if ($PreRestoreRoot) { Join-Path -Path $PreRestoreRoot -ChildPath "user-data\folders\$($dir.Name)" } else { '' }
            Invoke-SafeRobocopy -Source $dir.FullName -Destination $targetPath `
                -Threads $Config.robocopyThreads `
                -Retries $Config.robocopyRetries `
                -WaitSeconds $Config.robocopyWaitSeconds `
                -ConflictPolicy $ConflictPolicy `
                -PreRestoreBackupDir $preDir `
                -DryRun:$DryRun | Out-Null
        }
    }

    $dotfilesSrc = Join-Path -Path $srcRoot -ChildPath 'dotfiles'
    if (Test-Path -LiteralPath $dotfilesSrc) {
        $rootLen = (Resolve-Path -LiteralPath $dotfilesSrc).Path.TrimEnd('\').Length
        $files = Get-ChildItem -LiteralPath $dotfilesSrc -File -Recurse -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $relPath = $file.FullName.Substring($rootLen).TrimStart('\')
            $targetFile = Join-Path -Path $env:USERPROFILE -ChildPath $relPath
            $exists = Test-Path -LiteralPath $targetFile

            if ($exists -and $ConflictPolicy -eq 'SkipExisting') {
                Write-Log "Skipping existing dotfile: $relPath" -Level INFO
                continue
            }

            if ($exists -and $ConflictPolicy -eq 'BackupBeforeOverwrite' -and $PreRestoreRoot) {
                $backupFile = Join-Path -Path $PreRestoreRoot -ChildPath "user-data\dotfiles\$relPath"
                if ($DryRun) {
                    Write-Log "[DryRun] Would back up existing dotfile '$targetFile' -> '$backupFile'" -Level DRYRUN
                }
                else {
                    Ensure-Directory -Path (Split-Path -Path $backupFile -Parent)
                    Copy-Item -LiteralPath $targetFile -Destination $backupFile -Force
                }
            }

            if ($DryRun) {
                Write-Log "[DryRun] Would restore dotfile '$relPath' -> '$targetFile'" -Level DRYRUN
            }
            else {
                Ensure-Directory -Path (Split-Path -Path $targetFile -Parent)
                Copy-Item -LiteralPath $file.FullName -Destination $targetFile -Force
                Write-Log "Restored dotfile: $relPath" -Level OK
            }
        }
    }

    Write-Log '=== Finished User Data Restore ===' -Level OK
}

Export-ModuleMember -Function @(
    'Resolve-KnownFolderPath',
    'Backup-UserData',
    'Restore-UserData'
)
