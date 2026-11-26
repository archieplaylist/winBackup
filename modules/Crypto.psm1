#Requires -Version 5.1
<#
.SYNOPSIS
    Zero-dependency native .NET AES-256-CBC + HMAC-SHA256 encryption/decryption for sensitive backup files.
    Compatible with Windows PowerShell 5.1 (.NET Framework 4.7.2+) and PowerShell 7+.
#>

function ConvertFrom-SecureStringToPlainText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$SecureString
    )
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-EncryptionPassword {
    [CmdletBinding()]
    param(
        [switch]$Confirm
    )

    while ($true) {
        $sec1 = Read-Host -Prompt 'Enter encryption password for sensitive data (Wi-Fi & Credentials)' -AsSecureString
        $plain1 = ConvertFrom-SecureStringToPlainText -SecureString $sec1

        if ([string]::IsNullOrEmpty($plain1)) {
            Write-Host 'Password cannot be empty. Please try again.' -ForegroundColor Yellow
            continue
        }

        if (-not $Confirm) {
            return $sec1
        }

        $sec2 = Read-Host -Prompt 'Confirm encryption password' -AsSecureString
        $plain2 = ConvertFrom-SecureStringToPlainText -SecureString $sec2

        if ($plain1 -ceq $plain2) {
            return $sec1
        }
        Write-Host 'Passwords do not match. Please try again.' -ForegroundColor Red
    }
}

function Get-DerivedKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Password,

        [Parameter(Mandatory = $true)]
        [byte[]]$Salt,

        [int]$Iterations = 100000,

        [string]$Kdf = 'PBKDF2-SHA256'
    )

    $passwordBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $kdfUsed = $Kdf
    $pbkdf2 = $null

    try {
        if ($Kdf -eq 'PBKDF2-SHA256') {
            try {
                $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
                    $passwordBytes,
                    $Salt,
                    $Iterations,
                    [System.Security.Cryptography.HashAlgorithmName]::SHA256
                )
            }
            catch {
                # Fallback for older .NET Framework < 4.7.2
                $kdfUsed = 'PBKDF2-SHA1'
                $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($passwordBytes, $Salt, $Iterations)
            }
        }
        else {
            $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($passwordBytes, $Salt, $Iterations)
        }

        $keyMaterial = $pbkdf2.GetBytes(64)
        $encKey = New-Object byte[] 32
        $macKey = New-Object byte[] 32
        [Array]::Copy($keyMaterial, 0, $encKey, 0, 32)
        [Array]::Copy($keyMaterial, 32, $macKey, 0, 32)

        return [PSCustomObject]@{
            EncKey = $encKey
            MacKey = $macKey
            Kdf    = $kdfUsed
        }
    }
    finally {
        if ($pbkdf2) { $pbkdf2.Dispose() }
        [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
    }
}

function Compare-ByteArraysConstantTime {
    [CmdletBinding()]
    param(
        [byte[]]$A,
        [byte[]]$B
    )
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) {
        return $false
    }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) {
        $diff = $diff -bor ($A[$i] -bxor $B[$i])
    }
    return ($diff -eq 0)
}

function Protect-StringToFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlainText,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Password
    )

    $plainPassword = ConvertFrom-SecureStringToPlainText -SecureString $Password
    $iterations = 100000

    $salt = New-Object byte[] 16
    $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($salt)
        $rng.GetBytes($iv)
    }
    finally {
        $rng.Dispose()
    }

    $keys = Get-DerivedKeys -Password $plainPassword -Salt $salt -Iterations $iterations -Kdf 'PBKDF2-SHA256'
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $keys.EncKey
    $aes.IV = $iv

    $cipherBytes = $null
    try {
        $encryptor = $aes.CreateEncryptor()
        try {
            $cipherBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
        }
        finally {
            $encryptor.Dispose()
        }
    }
    finally {
        $aes.Dispose()
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }

    # Encrypt-then-MAC: HMAC-SHA256 over (salt || iv || ciphertext)
    $macInput = New-Object byte[] ($salt.Length + $iv.Length + $cipherBytes.Length)
    [Array]::Copy($salt, 0, $macInput, 0, $salt.Length)
    [Array]::Copy($iv, 0, $macInput, $salt.Length, $iv.Length)
    [Array]::Copy($cipherBytes, 0, $macInput, $salt.Length + $iv.Length, $cipherBytes.Length)

    $hmac = New-Object System.Security.Cryptography.HMACSHA256(,$keys.MacKey)
    try {
        $tag = $hmac.ComputeHash($macInput)
    }
    finally {
        $hmac.Dispose()
    }

    $envelope = [ordered]@{
        version    = 1
        cipher     = 'AES-256-CBC'
        mac        = 'HMAC-SHA256'
        kdf        = $keys.Kdf
        iterations = $iterations
        salt       = [Convert]::ToBase64String($salt)
        iv         = [Convert]::ToBase64String($iv)
        hmac       = [Convert]::ToBase64String($tag)
        ciphertext = [Convert]::ToBase64String($cipherBytes)
    }

    $parent = Split-Path -Path $OutputPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    ($envelope | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

function Unprotect-StringFromFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Password
    )

    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw "Encrypted file not found: $InputPath"
    }

    $envelope = (Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8) | ConvertFrom-Json
    $salt = [Convert]::FromBase64String($envelope.salt)
    $iv = [Convert]::FromBase64String($envelope.iv)
    $expectedTag = [Convert]::FromBase64String($envelope.hmac)
    $cipherBytes = [Convert]::FromBase64String($envelope.ciphertext)
    $iterations = [int]$envelope.iterations
    $kdf = [string]$envelope.kdf

    $plainPassword = ConvertFrom-SecureStringToPlainText -SecureString $Password
    $keys = Get-DerivedKeys -Password $plainPassword -Salt $salt -Iterations $iterations -Kdf $kdf

    # Verify HMAC before decrypting
    $macInput = New-Object byte[] ($salt.Length + $iv.Length + $cipherBytes.Length)
    [Array]::Copy($salt, 0, $macInput, 0, $salt.Length)
    [Array]::Copy($iv, 0, $macInput, $salt.Length, $iv.Length)
    [Array]::Copy($cipherBytes, 0, $macInput, $salt.Length + $iv.Length, $cipherBytes.Length)

    $hmac = New-Object System.Security.Cryptography.HMACSHA256(,$keys.MacKey)
    try {
        $actualTag = $hmac.ComputeHash($macInput)
    }
    finally {
        $hmac.Dispose()
    }

    if (-not (Compare-ByteArraysConstantTime -A $expectedTag -B $actualTag)) {
        throw "Decryption failed for '$InputPath': incorrect password or corrupted file."
    }

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $keys.EncKey
    $aes.IV = $iv

    try {
        $decryptor = $aes.CreateDecryptor()
        try {
            $plainBytes = $decryptor.TransformFinalBlock($cipherBytes, 0, $cipherBytes.Length)
            return [System.Text.Encoding]::UTF8.GetString($plainBytes)
        }
        finally {
            $decryptor.Dispose()
        }
    }
    finally {
        $aes.Dispose()
    }
}

Export-ModuleMember -Function @(
    'Read-EncryptionPassword',
    'Protect-StringToFile',
    'Unprotect-StringFromFile'
)
