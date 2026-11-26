#Requires -Version 5.1
<#
.SYNOPSIS
    Backup and restore Windows Generic Credentials via native Win32 advapi32.dll API
    (CredEnumerateW / CredWriteW) plus cmdkey & vaultcmd inventory.
#>

$script:CredManagerSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WinBackupNative
{
    public class GenericCredentialItem
    {
        public string TargetName { get; set; }
        public string UserName { get; set; }
        public string Comment { get; set; }
        public uint Persist { get; set; }
        public string BlobBase64 { get; set; }
    }

    public static class CredManager
    {
        private const uint CRED_TYPE_GENERIC = 1;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public uint Flags;
            public uint Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CredEnumerateW(string filter, uint flag, out uint count, out IntPtr pCredentials);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CredWriteW([In] ref CREDENTIAL userCredential, [In] uint flags);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CredReadW(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern void CredFree([In] IntPtr cred);

        public static List<GenericCredentialItem> EnumerateGenericCredentials()
        {
            var results = new List<GenericCredentialItem>();
            uint count = 0;
            IntPtr pCredentials = IntPtr.Zero;

            if (!CredEnumerateW(null, 0, out count, out pCredentials))
            {
                int err = Marshal.GetLastWin32Error();
                // 1168 = ERROR_NOT_FOUND (no credentials stored)
                if (err == 1168) return results;
                throw new System.ComponentModel.Win32Exception(err, "CredEnumerateW failed.");
            }

            try
            {
                int ptrSize = IntPtr.Size;
                for (int i = 0; i < count; i++)
                {
                    IntPtr credPtr = Marshal.ReadIntPtr(pCredentials, i * ptrSize);
                    CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(credPtr, typeof(CREDENTIAL));

                    if (cred.Type != CRED_TYPE_GENERIC)
                    {
                        continue;
                    }

                    string blobB64 = "";
                    if (cred.CredentialBlob != IntPtr.Zero && cred.CredentialBlobSize > 0)
                    {
                        byte[] blobBytes = new byte[cred.CredentialBlobSize];
                        Marshal.Copy(cred.CredentialBlob, blobBytes, 0, (int)cred.CredentialBlobSize);
                        blobB64 = Convert.ToBase64String(blobBytes);
                    }

                    results.Add(new GenericCredentialItem
                    {
                        TargetName = cred.TargetName ?? "",
                        UserName = cred.UserName ?? "",
                        Comment = cred.Comment ?? "",
                        Persist = cred.Persist,
                        BlobBase64 = blobB64
                    });
                }
            }
            finally
            {
                if (pCredentials != IntPtr.Zero)
                {
                    CredFree(pCredentials);
                }
            }

            return results;
        }

        public static bool CredentialExists(string targetName)
        {
            IntPtr pCred = IntPtr.Zero;
            if (CredReadW(targetName, CRED_TYPE_GENERIC, 0, out pCred))
            {
                if (pCred != IntPtr.Zero) CredFree(pCred);
                return true;
            }
            return false;
        }

        public static void WriteGenericCredential(string targetName, string userName, string comment, uint persist, string blobBase64)
        {
            byte[] blobBytes = string.IsNullOrEmpty(blobBase64) ? new byte[0] : Convert.FromBase64String(blobBase64);
            IntPtr blobPtr = IntPtr.Zero;

            try
            {
                if (blobBytes.Length > 0)
                {
                    blobPtr = Marshal.AllocCoTaskMem(blobBytes.Length);
                    Marshal.Copy(blobBytes, 0, blobPtr, blobBytes.Length);
                }

                CREDENTIAL cred = new CREDENTIAL
                {
                    Flags = 0,
                    Type = CRED_TYPE_GENERIC,
                    TargetName = targetName,
                    Comment = string.IsNullOrEmpty(comment) ? null : comment,
                    CredentialBlobSize = (uint)blobBytes.Length,
                    CredentialBlob = blobPtr,
                    Persist = persist == 0 ? 2u : persist, // default CRED_PERSIST_LOCAL_MACHINE (2)
                    AttributeCount = 0,
                    Attributes = IntPtr.Zero,
                    TargetAlias = null,
                    UserName = string.IsNullOrEmpty(userName) ? null : userName
                };

                if (!CredWriteW(ref cred, 0))
                {
                    int err = Marshal.GetLastWin32Error();
                    throw new System.ComponentModel.Win32Exception(err, "CredWriteW failed for target: " + targetName);
                }
            }
            finally
            {
                if (blobPtr != IntPtr.Zero)
                {
                    Marshal.FreeCoTaskMem(blobPtr);
                }
            }
        }
    }
}
'@

function Initialize-CredManagerType {
    [CmdletBinding()]
    param()
    if (-not ([System.Management.Automation.PSTypeName]'WinBackupNative.CredManager').Type) {
        Add-Type -TypeDefinition $script:CredManagerSource -Language CSharp
    }
}

function Backup-WindowsCredentials {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Security.SecureString]$EncryptionPassword = $null,
        [switch]$DryRun
    )

    Write-Log '=== Starting Windows Credentials Backup ===' -Level INFO
    Initialize-CredManagerType

    $destRoot = Join-Path -Path $BackupDir -ChildPath 'credentials'
    $stats = [ordered]@{
        genericCount = 0
        encrypted    = ($null -ne $EncryptionPassword)
        warnings     = @()
    }

    try {
        $items = [WinBackupNative.CredManager]::EnumerateGenericCredentials()
        $stats.genericCount = $items.Count
        Write-Log "Found $($items.Count) Generic Windows Credential(s)." -Level INFO

        if ($DryRun) {
            Write-Log "[DryRun] Would export $($items.Count) Generic Credential(s) and cmdkey/vaultcmd inventory to '$destRoot'." -Level DRYRUN
            return $stats
        }

        Ensure-Directory -Path $destRoot

        $payloadObj = [ordered]@{
            exportedAt  = (Get-Date -Format 'o')
            sourceUser  = $env:USERNAME
            sourceHost  = $env:COMPUTERNAME
            credentials = @($items | ForEach-Object {
                [ordered]@{
                    TargetName = $_.TargetName
                    UserName   = $_.UserName
                    Comment    = $_.Comment
                    Persist    = $_.Persist
                    BlobBase64 = $_.BlobBase64
                }
            })
        }
        $jsonPayload = $payloadObj | ConvertTo-Json -Depth 6

        if ($EncryptionPassword) {
            $encPath = Join-Path -Path $destRoot -ChildPath 'generic-credentials.enc'
            Protect-StringToFile -PlainText $jsonPayload -OutputPath $encPath -Password $EncryptionPassword
            Write-Log "Saved encrypted Generic Credentials: $encPath" -Level OK
        }
        else {
            $plainPath = Join-Path -Path $destRoot -ChildPath 'generic-credentials.json'
            Set-Content -LiteralPath $plainPath -Value $jsonPayload -Encoding UTF8
            Write-Log "Saved UNENCRYPTED Generic Credentials (keep this backup secure!): $plainPath" -Level WARN
        }

        # Capture human-readable inventory from cmdkey and vaultcmd
        $invLines = New-Object System.Collections.Generic.List[string]
        $invLines.Add("=== Windows Credentials Inventory ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) ===")
        $invLines.Add('')
        $invLines.Add('--- cmdkey /list ---')
        try {
            $cmdkeyOut = & cmdkey.exe /list 2>&1
            foreach ($line in $cmdkeyOut) { $invLines.Add([string]$line) }
        }
        catch {
            $invLines.Add("cmdkey failed: $($_.Exception.Message)")
        }

        $invLines.Add('')
        $invLines.Add('--- vaultcmd /listcreds:"Windows Credentials" ---')
        try {
            $vaultWin = & vaultcmd.exe /listcreds:"Windows Credentials" 2>&1
            foreach ($line in $vaultWin) { $invLines.Add([string]$line) }
        }
        catch {
            $invLines.Add("vaultcmd (Windows Credentials) failed: $($_.Exception.Message)")
        }

        $invLines.Add('')
        $invLines.Add('--- vaultcmd /listcreds:"Web Credentials" ---')
        try {
            $vaultWeb = & vaultcmd.exe /listcreds:"Web Credentials" 2>&1
            foreach ($line in $vaultWeb) { $invLines.Add([string]$line) }
        }
        catch {
            $invLines.Add("vaultcmd (Web Credentials) failed: $($_.Exception.Message)")
        }

        $invPath = Join-Path -Path $destRoot -ChildPath 'inventory.txt'
        Set-Content -LiteralPath $invPath -Value $invLines -Encoding UTF8
        Write-Log "Saved credential inventory: $invPath" -Level OK
    }
    catch {
        Write-Log "Windows Credentials backup failed: $($_.Exception.Message)" -Level ERROR
        $stats.warnings += $_.Exception.Message
    }

    Write-Log '=== Finished Windows Credentials Backup ===' -Level OK
    return $stats
}

function Restore-WindowsCredentials {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Security.SecureString]$EncryptionPassword = $null,

        [ValidateSet('Overwrite', 'SkipExisting', 'BackupBeforeOverwrite')]
        [string]$ConflictPolicy = 'BackupBeforeOverwrite',

        [switch]$DryRun
    )

    Write-Log '=== Starting Windows Credentials Restore ===' -Level INFO
    Initialize-CredManagerType

    $srcRoot = Join-Path -Path $BackupDir -ChildPath 'credentials'
    $encPath = Join-Path -Path $srcRoot -ChildPath 'generic-credentials.enc'
    $plainPath = Join-Path -Path $srcRoot -ChildPath 'generic-credentials.json'

    $jsonText = $null
    if (Test-Path -LiteralPath $encPath) {
        if (-not $EncryptionPassword) {
            throw 'Encryption password is required to restore encrypted Windows Credentials.'
        }
        $jsonText = Unprotect-StringFromFile -InputPath $encPath -Password $EncryptionPassword
    }
    elseif (Test-Path -LiteralPath $plainPath) {
        $jsonText = Get-Content -LiteralPath $plainPath -Raw -Encoding UTF8
    }
    else {
        Write-Log "No backed-up credentials file found in '$srcRoot', skipping." -Level WARN
        return
    }

    $data = $jsonText | ConvertFrom-Json
    $creds = @($data.credentials)
    Write-Log "Loaded $($creds.Count) Generic Credential(s) from backup." -Level INFO

    $restored = 0
    $skipped = 0
    foreach ($cred in $creds) {
        if ([string]::IsNullOrWhiteSpace($cred.TargetName)) { continue }

        $exists = [WinBackupNative.CredManager]::CredentialExists($cred.TargetName)
        if ($exists -and $ConflictPolicy -eq 'SkipExisting') {
            Write-Log "Skipping existing credential: $($cred.TargetName)" -Level INFO
            $skipped++
            continue
        }

        if ($DryRun) {
            $action = if ($exists) { 'overwrite' } else { 'create' }
            Write-Log "[DryRun] Would $action credential: $($cred.TargetName) (User: $($cred.UserName))" -Level DRYRUN
            $restored++
            continue
        }

        try {
            [WinBackupNative.CredManager]::WriteGenericCredential(
                [string]$cred.TargetName,
                [string]$cred.UserName,
                [string]$cred.Comment,
                [uint32]$cred.Persist,
                [string]$cred.BlobBase64
            )
            $restored++
        }
        catch {
            Write-Log "Failed to restore credential '$($cred.TargetName)': $($_.Exception.Message)" -Level WARN
        }
    }

    Write-Log "Credentials restore complete: $restored restored, $skipped skipped." -Level OK
    Write-Log 'Note: Windows Vault / Web Credentials cannot be imported automatically; see credentials\inventory.txt for reference.' -Level INFO
    Write-Log '=== Finished Windows Credentials Restore ===' -Level OK
}

Export-ModuleMember -Function @(
    'Backup-WindowsCredentials',
    'Restore-WindowsCredentials'
)
