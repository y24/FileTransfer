@echo off
rem Installs FileTransfer for the current user (no administrator rights needed).
rem   install.bat              install or update
rem   install.bat -Uninstall   remove the program and shortcuts
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Install.ps1" %*
if errorlevel 1 pause
