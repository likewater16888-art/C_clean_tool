@echo off
rem ---------------------------------------------------------------------------
rem  CDriveGuard launcher.  Double-click this file.
rem  Keep this file ASCII-only: it is executed by cmd.exe before any codepage
rem  setup, so non-ASCII characters here would be mojibake on some machines.
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"

if not exist "%~dp0CDriveGuard.ps1" (
    echo.
    echo [ERROR] CDriveGuard.ps1 is missing next to this launcher.
    echo         Extract the whole folder again, do not copy Start.cmd alone.
    echo.
    pause
    exit /b 1
)

"%PSEXE%" -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0CDriveGuard.ps1"
if errorlevel 1 (
    echo.
    echo [ERROR] CDriveGuard closed with an error code.
    echo         Details: %LOCALAPPDATA%\CDriveGuard\logs
    echo.
    pause
)
endlocal
