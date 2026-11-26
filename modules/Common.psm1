#Requires -Version 5.1
<#
.SYNOPSIS
    Common utilities for WinBackup: logging, admin checks, Robocopy wrapper, and manifest management.
#>

$script:LogFilePath = $null

function Initialize-LogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $script:LogFilePath = $Path
    $header = "=== WinBackup Log Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    Add-Content -LiteralPath $script:LogFilePath -Value $header -Encoding UTF8
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DRYRUN')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'OK'     { Write-Host $line -ForegroundColor Green }
        'WARN'   { Write-Host $line -ForegroundColor Yellow }
        'ERROR'  { Write-Host $line -ForegroundColor Red }
        'DRYRUN' { Write-Host $line -ForegroundColor Cyan }
        default  { Write-Host $line -ForegroundColor Gray }
    }

    if ($script:LogFilePath) {
        try {
            Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        catch {
            # Ignore logging I/O errors so main operation continues
        }
    }
}

function Test-IsAdmin {
    [CmdletBinding()]
    param()
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-CurrentUserContext {
    [CmdletBinding()]
    param()

    $sid = ''
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    catch {
        $sid = 'UNKNOWN'
    }

    $osCaption = 'Windows'
    $osBuild = ''
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $osCaption = $os.Caption
        $osBuild = "$($os.Version) (Build $($os.BuildNumber))"
    }
    catch {
        $osCaption = [System.Environment]::OSVersion.VersionString
    }

    return [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        UserName     = $env:USERNAME
        UserDomain   = $env:USERDOMAIN
        UserSID      = $sid
        UserProfile  = $env:USERPROFILE
        OSCaption    = $osCaption
        OSBuild      = $osBuild
        Timestamp    = (Get-Date -Format 'o')
    }
}

function Ensure-Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$DryRun
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($DryRun) {
            Write-Log "[DryRun] Would create directory: $Path" -Level DRYRUN
        }
        else {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

function Backup-ConflictingFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$PreRestoreDir,

        [switch]$DryRun
    )

    if (-not (Test-Path -LiteralPath $Source) -or -not (Test-Path -LiteralPath $Destination)) {
        return 0
    }

    $backedUpCount = 0
    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')

    $sourceFiles = Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -ErrorAction SilentlyContinue
    foreach ($file in $sourceFiles) {
        $relPath = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $targetFile = Join-Path -Path $Destination -ChildPath $relPath

        if (Test-Path -LiteralPath $targetFile) {
            $backupFile = Join-Path -Path $PreRestoreDir -ChildPath $relPath
            if ($DryRun) {
                $backedUpCount++
            }
            else {
                $backupParent = Split-Path -Path $backupFile -Parent
                if (-not (Test-Path -LiteralPath $backupParent)) {
                    New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
                }
                Copy-Item -LiteralPath $targetFile -Destination $backupFile -Force -ErrorAction SilentlyContinue
                $backedUpCount++
            }
        }
    }

    if ($backedUpCount -gt 0) {
        if ($DryRun) {
            Write-Log "[DryRun] Would back up $backedUpCount existing file(s) to $PreRestoreDir before overwriting." -Level DRYRUN
        }
        else {
            Write-Log "Backed up $backedUpCount existing file(s) to $PreRestoreDir before overwriting." -Level INFO
        }
    }

    return $backedUpCount
}

function Invoke-SafeRobocopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeFiles = @(),
        [int]$Threads = 8,
        [int]$Retries = 2,
        [int]$WaitSeconds = 2,

        [ValidateSet('Overwrite', 'SkipExisting', 'BackupBeforeOverwrite')]
        [string]$ConflictPolicy = 'Overwrite',

        [string]$PreRestoreBackupDir = '',
        [switch]$DryRun
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Log "Source path does not exist, skipping: $Source" -Level WARN
        return [PSCustomObject]@{ Success = $true; ExitCode = 0; Skipped = $true }
    }

    if ($ConflictPolicy -eq 'BackupBeforeOverwrite' -and $PreRestoreBackupDir) {
        Backup-ConflictingFiles -Source $Source -Destination $Destination -PreRestoreDir $PreRestoreBackupDir -DryRun:$DryRun | Out-Null
    }

    if (-not $DryRun) {
        Ensure-Directory -Path $Destination
    }

    # Trim trailing backslashes to avoid Robocopy quote escaping bugs (e.g., "C:\Foo\")
    $cleanSource = $Source.TrimEnd('\')
    if ($cleanSource -match '^[A-Za-z]:$') { $cleanSource += '\' }
    $cleanDest = $Destination.TrimEnd('\')
    if ($cleanDest -match '^[A-Za-z]:$') { $cleanDest += '\' }

    $argsList = New-Object System.Collections.Generic.List[string]
    $argsList.Add($cleanSource)
    $argsList.Add($cleanDest)
    $argsList.Add('/E')
    $argsList.Add('/COPY:DAT')
    $argsList.Add('/DCOPY:DAT')
    $argsList.Add('/XJ')          # Exclude junction points to prevent infinite loops
    $argsList.Add("/R:$Retries")
    $argsList.Add("/W:$WaitSeconds")
    $argsList.Add("/MT:$Threads")
    $argsList.Add('/NP')
    $argsList.Add('/NJH')
    $argsList.Add('/NFL')
    $argsList.Add('/NDL')

    if ($ConflictPolicy -eq 'SkipExisting') {
        $argsList.Add('/XC')
        $argsList.Add('/XN')
        $argsList.Add('/XO')
    }

    if ($DryRun) {
        $argsList.Add('/L')
    }

    if ($ExcludeDirs -and $ExcludeDirs.Count -gt 0) {
        $argsList.Add('/XD')
        foreach ($d in $ExcludeDirs) {
            if (-not [string]::IsNullOrWhiteSpace($d)) {
                $argsList.Add($d)
            }
        }
    }

    if ($ExcludeFiles -and $ExcludeFiles.Count -gt 0) {
        $argsList.Add('/XF')
        foreach ($f in $ExcludeFiles) {
            if (-not [string]::IsNullOrWhiteSpace($f)) {
                $argsList.Add($f)
            }
        }
    }

    $actionLabel = if ($DryRun) { '[DryRun] Robocopy' } else { 'Robocopy' }
    Write-Log "$actionLabel`: '$cleanSource' -> '$cleanDest' (Policy: $ConflictPolicy)" -Level $(if ($DryRun) { 'DRYRUN' } else { 'INFO' })

    $output = & robocopy.exe @argsList 2>&1
    $exitCode = $LASTEXITCODE

    # Robocopy exit codes 0-7 indicate success / informational conditions; >= 8 indicates failure
    if ($exitCode -ge 8) {
        Write-Log "Robocopy completed with errors (exit code $exitCode) for '$cleanSource'." -Level WARN
        if ($script:LogFilePath -and $output) {
            $summaryLines = $output | Select-Object -Last 12
            Add-Content -LiteralPath $script:LogFilePath -Value ($summaryLines -join [Environment]::NewLine) -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        return [PSCustomObject]@{ Success = $false; ExitCode = $exitCode; Skipped = $false }
    }

    Write-Log "Robocopy finished (exit code $exitCode): '$cleanSource'" -Level OK
    return [PSCustomObject]@{ Success = $true; ExitCode = $exitCode; Skipped = $false }
}

function Write-BackupManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Parameter(Mandatory = $true)]
        [hashtable]$ManifestData
    )

    $manifestPath = Join-Path -Path $BackupDir -ChildPath 'manifest.json'
    $json = $ManifestData | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $manifestPath -Value $json -Encoding UTF8
    Write-Log "Saved backup manifest: $manifestPath" -Level OK
    return $manifestPath
}

function Read-BackupManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir
    )

    $manifestPath = Join-Path -Path $BackupDir -ChildPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found at '$manifestPath'. Is this a valid WinBackup folder?"
    }

    $raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Read-UserConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $reply = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($reply)) {
        return $DefaultYes
    }
    return ($reply.Trim().ToLowerInvariant() -in @('y', 'yes'))
}

Export-ModuleMember -Function @(
    'Initialize-LogFile',
    'Write-Log',
    'Test-IsAdmin',
    'Get-CurrentUserContext',
    'Ensure-Directory',
    'Backup-ConflictingFiles',
    'Invoke-SafeRobocopy',
    'Write-BackupManifest',
    'Read-BackupManifest',
    'Read-UserConfirmation'
)
