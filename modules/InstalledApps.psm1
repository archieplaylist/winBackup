#Requires -Version 5.1
<#
.SYNOPSIS
    Backup and restore Installed Apps (winget export/import + Win32 Registry + Store AppX + Scoop/Chocolatey).
#>

function Test-IsSteamGameEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$RegistryItem
    )

    if ($RegistryItem.PSChildName -like 'Steam App *') {
        return $true
    }

    $uninstallStr = if ($RegistryItem.UninstallString) { [string]$RegistryItem.UninstallString } else { '' }
    if ($uninstallStr -match '(?i)steam://uninstall/') {
        return $true
    }

    $installLoc = if ($RegistryItem.InstallLocation) { [string]$RegistryItem.InstallLocation } else { '' }
    if ($installLoc -match '(?i)\\steamapps\\') {
        return $true
    }

    return $false
}

function Get-Win32InstalledApps {
    [CmdletBinding()]
    param(
        [switch]$ExcludeSteamGames
    )

    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $apps = @()
    $excludedSteamCount = 0
    foreach ($path in $regPaths) {
        $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            if ([string]::IsNullOrWhiteSpace($item.DisplayName)) { continue }
            if ($item.SystemComponent -eq 1) { continue }
            if ($ExcludeSteamGames -and (Test-IsSteamGameEntry -RegistryItem $item)) {
                $excludedSteamCount++
                continue
            }

            $apps += [PSCustomObject]@{
                Name            = $item.DisplayName.Trim()
                Version         = if ($item.DisplayVersion) { $item.DisplayVersion.Trim() } else { '' }
                Publisher       = if ($item.Publisher) { $item.Publisher.Trim() } else { '' }
                InstallDate     = if ($item.InstallDate) { $item.InstallDate } else { '' }
                InstallLocation = if ($item.InstallLocation) { $item.InstallLocation } else { '' }
                Scope           = if ($path -like 'HKCU:*') { 'User' } else { 'Machine' }
            }
        }
    }

    if ($ExcludeSteamGames -and $excludedSteamCount -gt 0) {
        Write-Log "Excluded $excludedSteamCount Steam game(s) from Win32 installed apps list." -Level INFO
    }

    return ($apps | Sort-Object -Property Name, Version -Unique)
}

function Backup-InstalledApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [PSCustomObject]$Config = $null,

        [switch]$DryRun
    )

    Write-Log '=== Starting Installed Apps Backup ===' -Level INFO
    $destRoot = Join-Path -Path $BackupDir -ChildPath 'apps'

    $excludeSteamGames = $false
    if ($Config -and $Config.PSObject.Properties['excludeSteamGames']) {
        $excludeSteamGames = [bool]$Config.excludeSteamGames
    }

    $stats = [ordered]@{
        wingetExported = $false
        win32Count     = 0
        storeCount     = 0
        scoopExported  = $false
        chocoExported  = $false
        warnings       = @()
    }

    if ($DryRun) {
        $win32 = @(Get-Win32InstalledApps -ExcludeSteamGames:$excludeSteamGames)
        $stats.win32Count = $win32.Count
        Write-Log "[DryRun] Would export winget JSON, $($win32.Count) Win32 apps, Store apps, and summary Markdown to '$destRoot'." -Level DRYRUN
        return $stats
    }

    Ensure-Directory -Path $destRoot

    # 1. Winget export (machine-restorable)
    $wingetCmd = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
    if ($wingetCmd) {
        $wingetFile = Join-Path -Path $destRoot -ChildPath 'winget-apps.json'
        Write-Log 'Running winget export...' -Level INFO
        $null = & winget.exe export -o $wingetFile --include-versions --accept-source-agreements 2>&1
        if (Test-Path -LiteralPath $wingetFile) {
            $stats.wingetExported = $true
            Write-Log "Saved winget export: $wingetFile" -Level OK
        }
        else {
            Write-Log 'winget export did not produce a file.' -Level WARN
            $stats.warnings += 'winget export failed'
        }
    }
    else {
        Write-Log 'winget.exe not found; skipping winget export.' -Level WARN
        $stats.warnings += 'winget not installed'
    }

    # 2. Win32 Registry Uninstall list
    $win32Apps = @(Get-Win32InstalledApps -ExcludeSteamGames:$excludeSteamGames)
    $stats.win32Count = $win32Apps.Count
    $win32Csv = Join-Path -Path $destRoot -ChildPath 'installed-apps-win32.csv'
    $win32Apps | Export-Csv -LiteralPath $win32Csv -NoTypeInformation -Encoding UTF8
    Write-Log "Saved $($win32Apps.Count) Win32 app(s) to $win32Csv" -Level OK

    # 3. Microsoft Store (AppX) packages
    $storeApps = @()
    try {
        $storeApps = @(Get-AppxPackage -ErrorAction Stop |
            Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' } |
            Select-Object Name, Version, Publisher, PackageFamilyName |
            Sort-Object -Property Name)
        $stats.storeCount = $storeApps.Count
        $storeCsv = Join-Path -Path $destRoot -ChildPath 'installed-apps-store.csv'
        $storeApps | Export-Csv -LiteralPath $storeCsv -NoTypeInformation -Encoding UTF8
        Write-Log "Saved $($storeApps.Count) Store AppX package(s) to $storeCsv" -Level OK
    }
    catch {
        Write-Log "Could not enumerate AppX packages: $($_.Exception.Message)" -Level WARN
        $stats.warnings += 'Get-AppxPackage failed'
    }

    # 4. Scoop (if installed)
    $scoopCmd = Get-Command -Name 'scoop' -ErrorAction SilentlyContinue
    if ($scoopCmd) {
        try {
            $scoopOut = & scoop export 2>&1
            $scoopFile = Join-Path -Path $destRoot -ChildPath 'scoop-apps.json'
            Set-Content -LiteralPath $scoopFile -Value ($scoopOut -join [Environment]::NewLine) -Encoding UTF8
            $stats.scoopExported = $true
            Write-Log "Saved Scoop export: $scoopFile" -Level OK
        }
        catch {
            $stats.warnings += 'scoop export failed'
        }
    }

    # 5. Chocolatey (if installed)
    $chocoCmd = Get-Command -Name 'choco.exe' -ErrorAction SilentlyContinue
    if ($chocoCmd) {
        try {
            $chocoOut = & choco.exe list --local-only 2>&1
            $chocoFile = Join-Path -Path $destRoot -ChildPath 'choco-apps.txt'
            Set-Content -LiteralPath $chocoFile -Value ($chocoOut -join [Environment]::NewLine) -Encoding UTF8
            $stats.chocoExported = $true
            Write-Log "Saved Chocolatey list: $chocoFile" -Level OK
        }
        catch {
            $stats.warnings += 'choco export failed'
        }
    }

    # 6. Human-readable Markdown summary
    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# Installed Apps Inventory ($($env:COMPUTERNAME))")
    $md.Add('')
    $md.Add("- **Exported**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $md.Add("- **Winget Export**: $(if ($stats.wingetExported) { 'Yes (`winget-apps.json`)' } else { 'No' })")
    $md.Add("- **Win32 Apps**: $($stats.win32Count)")
    $md.Add("- **Microsoft Store Apps**: $($stats.storeCount)")
    $md.Add("- **Scoop**: $(if ($stats.scoopExported) { 'Exported (`scoop-apps.json`)' } else { 'Not installed' })")
    $md.Add("- **Chocolatey**: $(if ($stats.chocoExported) { 'Exported (`choco-apps.txt`)' } else { 'Not installed' })")
    $md.Add('')
    $md.Add('## Win32 Installed Applications')
    $md.Add('')
    $md.Add('| Name | Version | Publisher | Scope |')
    $md.Add('| --- | --- | --- | --- |')
    foreach ($app in $win32Apps) {
        $n = ($app.Name -replace '\|', '\|')
        $v = ($app.Version -replace '\|', '\|')
        $p = ($app.Publisher -replace '\|', '\|')
        $md.Add("| $n | $v | $p | $($app.Scope) |")
    }

    $mdPath = Join-Path -Path $destRoot -ChildPath 'installed-apps-summary.md'
    Set-Content -LiteralPath $mdPath -Value $md -Encoding UTF8
    Write-Log "Saved human-readable app summary: $mdPath" -Level OK

    Write-Log '=== Finished Installed Apps Backup ===' -Level OK
    return $stats
}

function Restore-InstalledApps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [switch]$DryRun,
        [switch]$NonInteractive
    )

    Write-Log '=== Starting Installed Apps Restore ===' -Level INFO
    $srcRoot = Join-Path -Path $BackupDir -ChildPath 'apps'
    if (-not (Test-Path -LiteralPath $srcRoot)) {
        Write-Log "No apps folder found in backup '$BackupDir', skipping." -Level WARN
        return
    }

    $summaryPath = Join-Path -Path $srcRoot -ChildPath 'installed-apps-summary.md'
    if (Test-Path -LiteralPath $summaryPath) {
        Write-Log "Full installed apps reference list: $summaryPath" -Level INFO
    }

    $wingetFile = Join-Path -Path $srcRoot -ChildPath 'winget-apps.json'
    if (-not (Test-Path -LiteralPath $wingetFile)) {
        Write-Log 'No winget-apps.json found in backup. Please use the CSV/Markdown inventory to reinstall apps manually.' -Level WARN
        return
    }

    $wingetCmd = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-Log 'winget.exe is not available on this system. Install App Installer from Microsoft Store or reinstall manually using installed-apps-summary.md.' -Level WARN
        return
    }

    if ($DryRun) {
        Write-Log "[DryRun] Would run: winget import -i `"$wingetFile`" --accept-package-agreements --accept-source-agreements --ignore-unavailable" -Level DRYRUN
        return
    }

    $proceed = $true
    if (-not $NonInteractive) {
        $proceed = Read-UserConfirmation -Prompt 'Run winget import now to automatically reinstall backed-up applications?' -DefaultYes $false
    }

    if ($proceed) {
        Write-Log 'Running winget import (this may take several minutes)...' -Level INFO
        & winget.exe import -i $wingetFile --accept-package-agreements --accept-source-agreements --ignore-unavailable
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'winget import completed successfully.' -Level OK
        }
        else {
            Write-Log "winget import exited with code $LASTEXITCODE (some packages may already be installed or unavailable)." -Level WARN
        }
    }
    else {
        Write-Log "Skipped automatic winget import. You can run it later with: winget import -i `"$wingetFile`"" -Level INFO
    }

    Write-Log '=== Finished Installed Apps Restore ===' -Level OK
}

Export-ModuleMember -Function @(
    'Backup-InstalledApps',
    'Restore-InstalledApps'
)
