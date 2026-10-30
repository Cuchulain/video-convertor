@echo off
rem Spousti fix-audio-offsets.ps1 bez nutnosti menit ExecutionPolicy
rem (funguje i pro soubory stazene z internetu, viz README).
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows\fix-audio-offsets.ps1" %*
exit /b %ERRORLEVEL%
