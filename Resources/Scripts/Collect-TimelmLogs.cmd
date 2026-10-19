@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Collect-TimelmDiagnostics.ps1"
set "COLLECT_EXIT=%errorlevel%"
echo.
echo Output: %SystemDrive%\TimelmLogs
pause
exit /b %COLLECT_EXIT%
