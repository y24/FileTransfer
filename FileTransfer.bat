@echo off
rem FileTransfer
rem   FileTransfer.bat                       show the window (FileTransfer.exe does the same without a console)
rem   FileTransfer.bat -Destination ... ...  transfer from the command line (see README.md)
if "%~1"=="" (
  start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0FileTransfer.ps1"
  exit /b 0
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0FileTransfer.ps1" %*
exit /b %ERRORLEVEL%
