@echo off
setlocal

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

:: Launch PowerShell script with ExecutionPolicy bypassed
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinBackup.ps1" %*
set "EXIT_CODE=%errorlevel%"

echo.
if %EXIT_CODE% neq 0 (
    echo WinBackup exited with code %EXIT_CODE%.
)
pause
exit /b %EXIT_CODE%
