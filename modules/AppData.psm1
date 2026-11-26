#Requires -Version 5.1
<#
.SYNOPSIS
    Backup and restore Windows AppData (Roaming, Local, LocalLow) with smart cache/temp exclusions.
#>

function Get-AppDataScopePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Roaming', 'Local', 'LocalLow')]
        [string]$Scope
    )

    switch ($Scope) {
        'Roaming'  { return $env:APPDATA }
        'Local'    { return $env:LOCALAPPDATA }
        'LocalLow' { return (Join-Path -Path $env:USERPROFILE -ChildPath 'AppData\LocalLow') }
    }
}

function Expand-ScopeExclusions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScopeRoot,

        [string[]]$ExcludeDirs
    )

    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $ExcludeDirs) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry.Contains('\')) {
            $resolved.Add((Join-Path -Path $ScopeRoot -ChildPath $entry))
        }
        else {
            $resolved.Add($entry)
        }
    }
    return $resolved.ToArray()
}

function Backup-AppData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [switch]$DryRun
    )

    Write-Log '=== Starting AppData Backup ===' -Level INFO
    $destRoot = Join-Path -Path $BackupDir -ChildPath 'appdata'

    $stats = [ordered]@{
        scopesBackedUp = @()
        warnings       = @()
    }

    foreach ($scope in $Config.appDataScopes) {
        $srcPath = Get-AppDataScopePath -Scope $scope
        if (-not (Test-Path -LiteralPath $srcPath)) {
            Write-Log "AppData scope '$scope' not found at '$srcPath', skipping." -Level WARN
            continue
        }

        $targetDir = Join-Path -Path $destRoot -ChildPath $scope
        $excludeDirs = Expand-ScopeExclusions -ScopeRoot $srcPath -ExcludeDirs $Config.appDataExcludeDirs

        $res = Invoke-SafeRobocopy -Source $srcPath -Destination $targetDir `
            -ExcludeDirs $excludeDirs `
            -ExcludeFiles $Config.appDataExcludeFiles `
            -Threads $Config.robocopyThreads `
            -Retries $Config.robocopyRetries `
            -WaitSeconds $Config.robocopyWaitSeconds `
            -ConflictPolicy 'Overwrite' `
            -DryRun:$DryRun

        if ($res.Success) {
            $stats.scopesBackedUp += $scope
        }
        else {
            $stats.warnings += "Robocopy exit $($res.ExitCode) for AppData\$scope (locked files are common in AppData)"
        }
    }

    Write-Log '=== Finished AppData Backup ===' -Level OK
    return $stats
}

function Restore-AppData {
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

    Write-Log '=== Starting AppData Restore ===' -Level INFO
    $srcRoot = Join-Path -Path $BackupDir -ChildPath 'appdata'
    if (-not (Test-Path -LiteralPath $srcRoot)) {
        Write-Log "No appdata folder found in backup '$BackupDir', skipping." -Level WARN
        return
    }

    foreach ($scope in @('Roaming', 'Local', 'LocalLow')) {
        $srcScope = Join-Path -Path $srcRoot -ChildPath $scope
        if (-not (Test-Path -LiteralPath $srcScope)) { continue }

        $targetScope = Get-AppDataScopePath -Scope $scope
        $preDir = if ($PreRestoreRoot) { Join-Path -Path $PreRestoreRoot -ChildPath "appdata\$scope" } else { '' }

        Invoke-SafeRobocopy -Source $srcScope -Destination $targetScope `
            -Threads $Config.robocopyThreads `
            -Retries $Config.robocopyRetries `
            -WaitSeconds $Config.robocopyWaitSeconds `
            -ConflictPolicy $ConflictPolicy `
            -PreRestoreBackupDir $preDir `
            -DryRun:$DryRun | Out-Null
    }

    Write-Log '=== Finished AppData Restore ===' -Level OK
}

Export-ModuleMember -Function @(
    'Backup-AppData',
    'Restore-AppData'
)
