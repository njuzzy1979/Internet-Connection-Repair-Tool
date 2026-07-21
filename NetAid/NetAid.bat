@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  NetAid.bat - Network First Aid Launcher
::  Encoding: ASCII (English only, no BOM)
::  Usage: NetAid.bat [options]
::         Double-click to run interactive mode with UAC prompt
:: ============================================================

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "PS1_SCRIPT=%SCRIPT_DIR%\NetAid.ps1"

:: Verify PS1 script exists
if not exist "%PS1_SCRIPT%" (
    echo [ERROR] NetAid.ps1 not found: %PS1_SCRIPT%
    echo Please ensure NetAid.ps1 is in the same directory as NetAid.bat
    pause
    exit /b 1
)

:: Check admin privileges
net session >nul 2>&1
if %errorlevel% equ 0 goto run_admin

:: ---- Not admin: VBS UAC elevation -> PowerShell directly ----
echo [INFO] Requesting administrator privileges...

set "VBS=%TEMP%\NetAid_Elevate.vbs"
(
    echo Set objShell = CreateObject^("Shell.Application"^)
    echo objShell.ShellExecute "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -NoExit -File ""%PS1_SCRIPT%"" %*", "%SCRIPT_DIR%", "runas", 1
) > "%VBS%"

cscript //nologo "%VBS%"
del "%VBS%" 2>nul
exit /b

:: ---- Already admin: launch PowerShell directly ----
:run_admin
title NetAid - Network First Aid
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_SCRIPT%" %*
exit /b %errorlevel%
