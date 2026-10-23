@echo off
rem The button trial runs next to the GPIO touch trial, so the Volume, Power
rem and Assist keys stay usable while the touch trial is on the screen. The
rem mapping is the one the button trial proved on this phone: the short press
rem of a key sends its key, the long press sends the second action.
rem The trial is started from the Startup folder of the logged on user, so it
rem runs in the interactive session and needs no separate launcher.
rem The phone is switched off by the touch trial at the end of the run, long
rem before this trial reaches its own end.
setlocal
set "TRIAL=%SystemDrive%\TimelmTools\TimelmButtonsTrial"
if not exist "%TRIAL%\Start-TimelmButtonsTrial.ps1" (
    echo TimelmButtons trial bundle is missing.
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TRIAL%\Start-TimelmButtonsTrial.ps1" -Seconds 3600 -ButtonMode Agent -PowerAction Tab -PowerLongAction AltTab -PowerLongPressMillis 1500 -VolumeUpAction Up -VolumeUpLongAction Right -VolumeUpLongPressMillis 800 -VolumeDownAction Down -VolumeDownLongAction Left -VolumeDownLongPressMillis 800 -AssistAction Enter -AssistLongAction Tab -AssistLongPressMillis 800 -AssistTarget "notepad.exe"
exit /b %ERRORLEVEL%
