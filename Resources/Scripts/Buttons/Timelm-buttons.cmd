@echo off
rem TimelmButtons trial. It starts the trial in the interactive session of the
rem logged on user, the trial itself installs the driver, records the button
rem state and shuts the phone down again.
rem The staging script replaces the button mode of the line below.
setlocal
set "TRIAL=%SystemDrive%\TimelmTools\TimelmButtonsTrial"
if not exist "%TRIAL%\Start-TimelmButtonsTrial.ps1" (
    echo TimelmButtons trial bundle is missing.
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TRIAL%\Start-TimelmButtonsTrial.ps1" -Seconds 120 -ButtonMode Agent -AssistAction LaunchTarget
exit /b %ERRORLEVEL%
