#Requires -Version 5.1
<#
.SYNOPSIS
    Auto-detect, backup, and restore Chromium & Gecko browser profiles with DPAPI migration awareness.
#>

function Get-InstalledBrowserDefinitions {
    [CmdletBinding()]
    param()

    $defs = @(
        [PSCustomObject]@{ Name = 'Chrome';    Engine = 'Chromium'; Process = 'chrome';    Path = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') }
        [PSCustomObject]@{ Name = 'Edge';      Engine = 'Chromium'; Process = 'msedge';    Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') }
        [PSCustomObject]@{ Name = 'Brave';     Engine = 'Chromium'; Process = 'brave';     Path = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data') }
        [PSCustomObject]@{ Name = 'Vivaldi';   Engine = 'Chromium'; Process = 'vivaldi';   Path = (Join-Path $env:LOCALAPPDATA 'Vivaldi\User Data') }
        [PSCustomObject]@{ Name = 'Opera';     Engine = 'Chromium'; Process = 'opera';     Path = (Join-Path $env:APPDATA 'Opera Software\Opera Stable') }
        [PSCustomObject]@{ Name = 'OperaGX';   Engine = 'Chromium'; Process = 'opera';     Path = (Join-Path $env:APPDATA 'Opera Software\Opera GX Stable') }
        [PSCustomObject]@{ Name = 'Firefox';   Engine = 'Gecko';    Process = 'firefox';   Path = (Join-Path $env:APPDATA 'Mozilla\Firefox') }
        [PSCustomObject]@{ Name = 'LibreWolf'; Engine = 'Gecko';    Process = 'librewolf'; Path = (Join-Path $env:APPDATA 'LibreWolf') }
        [PSCustomObject]@{ Name = 'Zen';       Engine = 'Gecko';    Process = 'zen';       Path = (Join-Path $env:APPDATA 'zen') }
    )
    return $defs
}

function Stop-RunningBrowsersIfConfirmed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$Browsers,

        [switch]$DryRun,
        [switch]$NonInteractive
    )

    $procNames = $Browsers | Select-Object -ExpandProperty Process -Unique
    $running = @()
    foreach ($pName in $procNames) {
        $procs = Get-Process -Name $pName -ErrorAction SilentlyContinue
        if ($procs) {
            $running += $pName
        }
    }

    if ($running.Count -eq 0) {
        return
    }

    Write-Log "Running browser process(es) detected: $($running -join ', '). Open browsers lock SQLite databases (bookmarks/history/logins)." -Level WARN
    if ($DryRun) {
        Write-Log '[DryRun] Would prompt to close running browser processes.' -Level DRYRUN
        return
    }

    $shouldClose = $false
    if ($NonInteractive) {
        Write-Log 'Non-interactive mode: leaving browsers running; locked files may be skipped.' -Level WARN
    }
    else {
        $shouldClose = Read-UserConfirmation -Prompt "Close running browsers ($($running -join ', ')) now for a clean copy?" -DefaultYes $true
    }

    if ($shouldClose) {
        foreach ($pName in $running) {
            Write-Log "Closing browser process: $pName" -Level INFO
            Get-Process -Name $pName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
    }
}

function Backup-BrowserData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [switch]$DryRun,
        [switch]$NonInteractive
    )

    Write-Log '=== Starting Browser Data Backup ===' -Level INFO
    $destRoot = Join-Path -Path $BackupDir -ChildPath 'browsers'
    $allDefs = Get-InstalledBrowserDefinitions
    $detected = @($allDefs | Where-Object { Test-Path -LiteralPath $_.Path })

    $stats = [ordered]@{
        browsersBackedUp = @()
        chromiumDetected = $false
        warnings         = @()
    }

    if ($detected.Count -eq 0) {
        Write-Log 'No supported browser profile directories were detected.' -Level WARN
        return $stats
    }

    Write-Log "Detected browsers: $(($detected | Select-Object -ExpandProperty Name) -join ', ')" -Level INFO
    Stop-RunningBrowsersIfConfirmed -Browsers $detected -DryRun:$DryRun -NonInteractive:$NonInteractive

    foreach ($browser in $detected) {
        $targetDir = Join-Path -Path $destRoot -ChildPath $browser.Name
        if ($browser.Engine -eq 'Chromium') {
            $stats.chromiumDetected = $true
        }

        $res = Invoke-SafeRobocopy -Source $browser.Path -Destination $targetDir `
            -ExcludeDirs $Config.browserCacheExcludeDirs `
            -ExcludeFiles $Config.browserCacheExcludeFiles `
            -Threads $Config.robocopyThreads `
            -Retries $Config.robocopyRetries `
            -WaitSeconds $Config.robocopyWaitSeconds `
            -ConflictPolicy 'Overwrite' `
            -DryRun:$DryRun

        if ($res.Success) {
            $stats.browsersBackedUp += $browser.Name
        }
        else {
            $stats.warnings += "Robocopy exit $($res.ExitCode) for browser $($browser.Name)"
        }
    }

    if ($stats.chromiumDetected) {
        Write-Log 'NOTE (Chromium Browsers): Saved passwords & cookies are DPAPI-encrypted to this Windows user/PC. For a clean OS reinstall or new PC, also enable browser Sync or export passwords to CSV before wiping.' -Level WARN
    }

    Write-Log '=== Finished Browser Data Backup ===' -Level OK
    return $stats
}

function Restore-BrowserData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [PSCustomObject]$Manifest = $null,

        [ValidateSet('Overwrite', 'SkipExisting', 'BackupBeforeOverwrite')]
        [string]$ConflictPolicy = 'BackupBeforeOverwrite',

        [string]$PreRestoreRoot = '',
        [switch]$DryRun,
        [switch]$NonInteractive
    )

    Write-Log '=== Starting Browser Data Restore ===' -Level INFO
    $srcRoot = Join-Path -Path $BackupDir -ChildPath 'browsers'
    if (-not (Test-Path -LiteralPath $srcRoot)) {
        Write-Log "No browsers folder found in backup '$BackupDir', skipping." -Level WARN
        return
    }

    $allDefs = Get-InstalledBrowserDefinitions
    $defMap = @{}
    foreach ($d in $allDefs) { $defMap[$d.Name] = $d }

    $backedUpDirs = Get-ChildItem -LiteralPath $srcRoot -Directory -ErrorAction SilentlyContinue
    $toRestore = @()
    foreach ($dir in $backedUpDirs) {
        if ($defMap.ContainsKey($dir.Name)) {
            $toRestore += $defMap[$dir.Name]
        }
    }

    if ($toRestore.Count -eq 0) {
        Write-Log 'No recognized browser folders to restore.' -Level WARN
        return
    }

    # Check if migrating across different PC or Windows user SID
    if ($Manifest -and $Manifest.source) {
        $ctx = Get-CurrentUserContext
        $isDifferentMachine = ($Manifest.source.UserSID -ne $ctx.UserSID) -or ($Manifest.source.ComputerName -ne $ctx.ComputerName)
        $hasChromium = ($toRestore | Where-Object { $_.Engine -eq 'Chromium' }).Count -gt 0
        if ($isDifferentMachine -and $hasChromium) {
            Write-Log 'CROSS-PC / NEW OS DETECTED: Bookmarks, history, extensions, and settings will restore for Chromium browsers, but Windows DPAPI prevents decrypting saved passwords/cookies from a different OS install. Import your password CSV or sign into browser Sync after restore.' -Level WARN
        }
    }

    Stop-RunningBrowsersIfConfirmed -Browsers $toRestore -DryRun:$DryRun -NonInteractive:$NonInteractive

    foreach ($browser in $toRestore) {
        $srcDir = Join-Path -Path $srcRoot -ChildPath $browser.Name
        $preDir = if ($PreRestoreRoot) { Join-Path -Path $PreRestoreRoot -ChildPath "browsers\$($browser.Name)" } else { '' }

        Invoke-SafeRobocopy -Source $srcDir -Destination $browser.Path `
            -Threads $Config.robocopyThreads `
            -Retries $Config.robocopyRetries `
            -WaitSeconds $Config.robocopyWaitSeconds `
            -ConflictPolicy $ConflictPolicy `
            -PreRestoreBackupDir $preDir `
            -DryRun:$DryRun | Out-Null
    }

    Write-Log '=== Finished Browser Data Restore ===' -Level OK
}

Export-ModuleMember -Function @(
    'Get-InstalledBrowserDefinitions',
    'Backup-BrowserData',
    'Restore-BrowserData'
)
