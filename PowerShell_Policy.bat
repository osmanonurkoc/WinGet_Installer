@echo off
Title Winget Installer Launcher

:: --- 1. ADMINISTRATOR PRIVILEGE CHECK ---
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrative privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c %~dpnx0' -Verb RunAs"
    exit
)

:: --- 2. REGISTRY SETTINGS (Running as Admin) ---
echo Configuring system settings...

:: PowerShell ExecutionPolicy Setting (Machine-wide)
reg add "HKLM\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v ExecutionPolicy /t REG_SZ /d RemoteSigned /f >nul

:: Winget EnableHashOverride Setting
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller" /v EnableHashOverride /t REG_DWORD /d 1 /f >nul

exit
