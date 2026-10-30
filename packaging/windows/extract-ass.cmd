@echo off
rem Video convertor pro TV - Jan Cejka, https://dev.jancejka.cz
rem https://github.com/Cuchulain/video-convertor (MIT)
rem Spousti extract-ass.ps1 bez nutnosti menit ExecutionPolicy
rem (funguje i pro soubory stazene z internetu, viz README).
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows\extract-ass.ps1" %*
exit /b %ERRORLEVEL%
