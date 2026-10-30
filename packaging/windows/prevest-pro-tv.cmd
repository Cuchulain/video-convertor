@echo off
rem Video convertor pro TV - Jan Cejka, https://dev.jancejka.cz
rem https://github.com/Cuchulain/video-convertor (MIT)
rem Pro pretazeni videi mysi na tento soubor nebo jeho zastupce:
rem prevede je profilem standard a pocka na klavesu, aby slo precist vysledek.
if "%~1"=="" (
    echo Pretahnete na tento soubor jedno nebo vice videi, nebo pouzijte
    echo convert-for-tv.cmd -Profile standard -Path "D:\Video\film.mkv"
    echo.
    pause
    exit /b 1
)
rem Soubory se predavaji pozicne; "-Path a b" PowerShell u -File odmitne.
call "%~dp0convert-for-tv.cmd" -Profile standard %*
echo.
pause
