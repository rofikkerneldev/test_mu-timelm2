@echo off
if /i not "%PROCESSOR_ARCHITECTURE%"=="ARM64" exit /b 90
if /i not "%COMPUTERNAME%"=="TIMELM-V60" exit /b 91
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SystemDrive%\TimelmTools\TouchEnumerationProbe\Run-EnumerationProbe.ps1"
