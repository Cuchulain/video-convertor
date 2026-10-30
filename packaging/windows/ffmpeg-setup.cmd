@echo off
rem Video convertor pro TV - Jan Cejka, https://dev.jancejka.cz
rem https://github.com/Cuchulain/video-convertor (MIT)
rem Zkontroluje FFmpeg (kodeky, libass) a pokud chybi nebo nevyhovuje,
rem stahne overene sestaveni do slozky ffmpeg. Parametry: -CheckOnly, -Force, -ZipPath.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\ffmpeg-setup.ps1" %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%
