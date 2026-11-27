# WinBackup — Windows Manual Backup & Restore Toolkit

A zero-dependency, modular PowerShell 5.1 / 7+ toolkit for backing up and restoring a Windows 10/11 user environment—designed for both **clean Windows reinstalls / new PC migrations** and **same-PC recovery**.

## What It Backs Up & Restores

| Category | Backup Details | Restore Details |
| :--- | :--- | :--- |
| **UserData** | Known Folders (`Desktop`, `Documents`, `Downloads`, `Pictures`, `Videos`, `Music`, `Favorites`, `SavedGames`, `Contacts`, `Links` — resolves OneDrive/drive redirection) + dotfiles (`.ssh`, `.gitconfig`, `.aws`, `.kube`, `.wslconfig`, etc.) | Copies back to resolved Known Folders & `%USERPROFILE%` respecting conflict policy |
| **AppData** | `Roaming`, `Local`, and `LocalLow` with smart exclusions for caches, temp files, crash dumps, and browser profiles (editable in `config.json`) | Restores to `%APPDATA%`, `%LOCALAPPDATA%`, and `AppData\LocalLow` |
| **BrowserData** | Auto-detects Chrome, Edge, Brave, Vivaldi, Opera, Opera GX, Firefox, LibreWolf, and Zen; prompts to close running browsers; excludes heavy caches | Restores profiles and warns about Chromium DPAPI limits on cross-PC restores |
| **Credentials** | Exports Generic Windows Credentials via native Win32 API (`CredEnumerateW`) + `cmdkey /list` and `vaultcmd` inventory | Restores Generic Credentials cross-PC via `CredWriteW` |
| **WifiProfiles** | Exports saved Wi-Fi profiles & keys (`netsh wlan export profile key=clear`) | Imports saved profiles via `netsh wlan add profile` |
| **InstalledApps** | `winget export` JSON + Win32 Registry CSV + Microsoft Store AppX CSV + Scoop/Chocolatey lists + Markdown summary | Offers automated `winget import` + links to `installed-apps-summary.md` |

## Security & Encryption

Wi-Fi keys and Generic Windows Credentials are sensitive. By default, WinBackup encrypts both into `.enc` files using native .NET **AES-256-CBC + HMAC-SHA256** (Encrypt-then-MAC with PBKDF2-SHA256 key derivation, 100,000 iterations)—requiring **no third-party tools** like 7-Zip. Plaintext temporary files are deleted immediately.

## Quick Start

### Interactive Mode (Recommended)
1. Double-click **`WinBackup.bat`** (it automatically requests Administrator privileges and bypasses PowerShell `ExecutionPolicy`).
2. Pick from the menu:
   - `[1]` **Full Backup** (all 6 categories)
   - `[2]` **Selective Backup**
   - `[3]` **Restore from Backup** (includes Dry-Run preview and conflict policy selection)
   - `[4]` **Verify a Backup** (validates `manifest.json`, folders, and encryption password)

### Live Progress
While backing up, WinBackup shows a live progress bar for the current category and folder, including bytes copied, percentage, transfer speed, and ETA:

```text
[2/6] AppData - Local [##########------------]  48%  4.2 GB / 8.7 GB  62 MB/s  ETA 01:12
```

Each category also logs its name, position (`Category 2 of 6`), and elapsed time when it finishes. Progress is shown automatically in an interactive console and is disabled with `-NonInteractive` or when output is redirected, so automated logs stay clean.

### CLI Mode (PowerShell)

```powershell
# Full backup with encryption (default)
.\WinBackup.ps1 -Mode Backup -BackupRoot D:\WinBackups -EncryptSensitive

# Dry-run selective backup (preview only, writes nothing)
.\WinBackup.ps1 -Mode Backup -BackupRoot D:\WinBackups -Categories UserData,BrowserData,WifiProfiles -DryRun

# Verify a backup before wiping your PC
.\WinBackup.ps1 -Mode Verify -BackupPath D:\WinBackups\WinBackup_MYPC_20261126_153000

# Preview a restore (Dry-Run) with safe conflict handling
.\WinBackup.ps1 -Mode Restore -BackupPath D:\WinBackups\WinBackup_MYPC_20261126_153000 -ConflictPolicy BackupBeforeOverwrite -DryRun

# Live selective restore
.\WinBackup.ps1 -Mode Restore -BackupPath D:\WinBackups\WinBackup_MYPC_20261126_153000 -Categories UserData,Credentials,WifiProfiles,InstalledApps -ConflictPolicy BackupBeforeOverwrite

# List available backups in a folder
.\WinBackup.ps1 -Mode List -BackupRoot D:\WinBackups
```

### Conflict Policies (Restore)
- `BackupBeforeOverwrite` *(default)*: Saves any conflicting target files to `%USERPROFILE%\WinBackup_PreRestore_<timestamp>\` before overwriting.
- `SkipExisting`: Leaves existing files and credentials untouched.
- `Overwrite`: Overwrites conflicting files (never deletes unrelated files on the target PC).

## Customizing `config.json`

Edit [`config.json`](config.json) to customize:
- `userFolders` & `userDotfiles`
- `appDataScopes`, `appDataExcludeDirs`, `appDataExcludeFiles`
- `browserCacheExcludeDirs`, `browserCacheExcludeFiles`
- `robocopyThreads`, `robocopyRetries`, `robocopyWaitSeconds`
- `defaultConflictPolicy`

## Pre-Wipe Checklist & DPAPI Caveats

Before wiping Windows or migrating to a new PC:
1. **Run Verify Mode** (`[4]` in menu or `-Mode Verify`) and test your encryption password.
2. **Chromium Browsers (Chrome, Edge, Brave, Opera, Vivaldi)**: Bookmarks, history, extensions, and settings transfer cross-PC cleanly, but Windows **DPAPI** prevents Chromium from decrypting saved passwords and cookies on a different Windows install/SID. Enable browser **Sync** or export your passwords to CSV before wiping. *(Firefox / Gecko `logins.json` + `key4.db` transfer cross-PC cleanly.)*
3. **Windows Vault / Web Credentials**: Generic Credentials restore automatically across PCs, while Windows Web Vault entries are recorded in `credentials\inventory.txt` for reference.
4. **BitLocker / Recovery Keys**: Make sure your BitLocker recovery key is saved in your Microsoft account or printed before reinstalling Windows.
