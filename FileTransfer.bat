@echo off
rem Starts FileTransfer. FileTransfer.exe (built by install.bat) starts it without a console window.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0FileTransfer.ps1"
