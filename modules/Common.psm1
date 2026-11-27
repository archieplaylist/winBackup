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

function Format-ByteSize {
    [CmdletBinding()]
    param([double]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Format-Duration {
    [CmdletBinding()]
    param([double]$Seconds)

    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) {
        return '--:--'
    }
    $span = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    if ($span.TotalDays -ge 1) {
        return ('{0}d {1:00}:{2:00}:{3:00}' -f [int][Math]::Floor($span.TotalDays), $span.Hours, $span.Minutes, $span.Seconds)
    }
    if ($span.TotalHours -ge 1) {
        return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
    }
    return ('{0:00}:{1:00}' -f $span.Minutes, $span.Seconds)
}

function Write-ProgressBar {
    [CmdletBinding()]
    param(
        [string]$Activity = '',
        [int]$Percent = 0,
        [double]$CurrentBytes = 0,
        [double]$TotalBytes = 0,
        [TimeSpan]$Elapsed = [TimeSpan]::Zero,
        [string]$Status = '',
        [switch]$Complete
    )

    if ($Complete) {
        Write-Host ''
        return
    }

    try { $consoleWidth = [Console]::WindowWidth } catch { $consoleWidth = 0 }
    if ($consoleWidth -le 0) { $consoleWidth = 100 }
    $maxWidth = [Math]::Max(30, $consoleWidth - 1)

    if ($Status) {
        $line = if ($Activity) { "$Activity  $Status" } else { $Status }
    }
    else {
        $pct = [Math]::Max(0, [Math]::Min(100, $Percent))
        $barWidth = 22
        $filled = [int][Math]::Round(($pct / 100.0) * $barWidth)
        $bar = ('#' * $filled) + ('-' * ($barWidth - $filled))

        $speedText = ''
        $etaText = ''
        if ($Elapsed.TotalSeconds -ge 1 -and $CurrentBytes -gt 0) {
            $speed = $CurrentBytes / $Elapsed.TotalSeconds
            $speedText = (Format-ByteSize -Bytes $speed) + '/s'
            if ($TotalBytes -gt $CurrentBytes) {
                $etaText = 'ETA ' + (Format-Duration -Seconds (($TotalBytes - $CurrentBytes) / $speed))
            }
        }

        $bytesText = if ($TotalBytes -gt 0) {
            '{0} / {1}' -f (Format-ByteSize -Bytes $CurrentBytes), (Format-ByteSize -Bytes $TotalBytes)
        }
        else {
            Format-ByteSize -Bytes $CurrentBytes
        }

        $line = '{0} [{1}] {2,3}%  {3}' -f $Activity, $bar, $pct, $bytesText
        if ($speedText) { $line += '  ' + $speedText }
        if ($etaText) { $line += '  ' + $etaText }
    }

    if ($line.Length -gt $maxWidth) { $line = $line.Substring(0, $maxWidth) }
    else { $line = $line.PadRight($maxWidth) }

    Write-Host ("`r" + $line) -NoNewline
}

function Get-RobocopyPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CoreArgs
    )

    $planArgs = New-Object System.Collections.Generic.List[string]
    foreach ($a in $CoreArgs) { $planArgs.Add($a) }
    $planArgs.Add('/L')
    $planArgs.Add('/BYTES')
    $planArgs.Add('/NJH')
    $planArgs.Add('/NFL')
    $planArgs.Add('/NDL')

    $out = & robocopy.exe @planArgs 2>&1

    # The summary prints Dirs, Files, and Bytes rows (in that order) with six
    # integers each. Labels are localized, so match by shape instead of text.
    $numericRows = New-Object System.Collections.Generic.List[object]
    foreach ($line in $out) {
        if ([string]$line -match '^\s*[^:]+:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$') {
            $numericRows.Add([PSCustomObject]@{
                Total  = [int64]$Matches[1]
                Copied = [int64]$Matches[2]
            })
        }
    }

    if ($numericRows.Count -ge 3) {
        return [PSCustomObject]@{
            TotalBytes = $numericRows[2].Copied
            TotalFiles = $numericRows[1].Copied
        }
    }
    return [PSCustomObject]@{ TotalBytes = [int64]0; TotalFiles = [int64]0 }
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
        [switch]$DryRun,

        [switch]$ShowProgress,
        [string]$Activity = 'Robocopy'
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

    # Core arguments are shared by the size pre-scan and the real copy so the
    # progress total reflects exclusions and the conflict policy exactly.
    $coreArgs = New-Object System.Collections.Generic.List[string]
    $coreArgs.Add($cleanSource)
    $coreArgs.Add($cleanDest)
    $coreArgs.Add('/E')
    $coreArgs.Add('/COPY:DAT')
    $coreArgs.Add('/DCOPY:DAT')
    $coreArgs.Add('/XJ')          # Exclude junction points to prevent infinite loops
    $coreArgs.Add("/R:$Retries")
    $coreArgs.Add("/W:$WaitSeconds")

    if ($ConflictPolicy -eq 'SkipExisting') {
        $coreArgs.Add('/XC')
        $coreArgs.Add('/XN')
        $coreArgs.Add('/XO')
    }

    if ($ExcludeDirs -and $ExcludeDirs.Count -gt 0) {
        $coreArgs.Add('/XD')
        foreach ($d in $ExcludeDirs) {
            if (-not [string]::IsNullOrWhiteSpace($d)) {
                $coreArgs.Add($d)
            }
        }
    }

    if ($ExcludeFiles -and $ExcludeFiles.Count -gt 0) {
        $coreArgs.Add('/XF')
        foreach ($f in $ExcludeFiles) {
            if (-not [string]::IsNullOrWhiteSpace($f)) {
                $coreArgs.Add($f)
            }
        }
    }

    $useProgress = [bool]$ShowProgress -and -not $DryRun

    $argsList = New-Object System.Collections.Generic.List[string]
    foreach ($a in $coreArgs) { $argsList.Add($a) }
    $argsList.Add("/MT:$Threads")
    $argsList.Add('/NP')
    $argsList.Add('/NJH')
    $argsList.Add('/NDL')
    if ($useProgress) {
        $argsList.Add('/BYTES')   # Plain-integer sizes make per-file progress parsing easy
    }
    else {
        $argsList.Add('/NFL')
    }

    if ($DryRun) {
        $argsList.Add('/L')
    }

    $actionLabel = if ($DryRun) { '[DryRun] Robocopy' } else { 'Robocopy' }
    Write-Log "$actionLabel`: '$cleanSource' -> '$cleanDest' (Policy: $ConflictPolicy)" -Level $(if ($DryRun) { 'DRYRUN' } else { 'INFO' })

    $totalBytes = [int64]0
    if ($useProgress) {
        Write-ProgressBar -Activity $Activity -Status 'Scanning source (calculating size)...'
        $plan = Get-RobocopyPlan -CoreArgs $coreArgs.ToArray()
        $totalBytes = [int64]$plan.TotalBytes
    }

    $copiedBytes = [int64]0
    $startTime = Get-Date
    $lastUpdate = [DateTime]::MinValue
    $tailLines = New-Object System.Collections.Generic.List[string]

    if ($useProgress) {
        $null = & robocopy.exe @argsList 2>&1 | ForEach-Object {
            $line = [string]$_
            $tailLines.Add($line)
            if ($tailLines.Count -gt 20) { $tailLines.RemoveAt(0) }

            # Per-file lines look like: <TAB>  New File <TAB><TAB>  12345<TAB>path
            $tokens = $line -split "`t"
            if ($tokens.Count -ge 5) {
                $size = [int64]0
                if ([int64]::TryParse($tokens[3].Trim(), [ref]$size)) {
                    $copiedBytes += $size
                    $now = Get-Date
                    if (($now - $lastUpdate).TotalMilliseconds -ge 250) {
                        $lastUpdate = $now
                        $pct = if ($totalBytes -gt 0) {
                            [int][Math]::Min(99, [Math]::Floor(($copiedBytes * 100.0) / $totalBytes))
                        }
                        else { 0 }
                        Write-ProgressBar -Activity $Activity -Percent $pct `
                            -CurrentBytes $copiedBytes -TotalBytes $totalBytes -Elapsed ($now - $startTime)
                    }
                }
            }
        }
        $exitCode = $LASTEXITCODE

        Write-ProgressBar -Activity $Activity -Percent 100 `
            -CurrentBytes ([Math]::Max($copiedBytes, $totalBytes)) -TotalBytes $totalBytes `
            -Elapsed ((Get-Date) - $startTime)
        Write-ProgressBar -Complete

        $output = $tailLines.ToArray()
    }
    else {
        $output = & robocopy.exe @argsList 2>&1
        $exitCode = $LASTEXITCODE
    }

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
    'Format-ByteSize',
    'Format-Duration',
    'Write-ProgressBar',
    'Backup-ConflictingFiles',
    'Invoke-SafeRobocopy',
    'Write-BackupManifest',
    'Read-BackupManifest',
    'Read-UserConfirmation'
)
