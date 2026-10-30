; Instalátor Video convertor pro TV (NSIS 3). Sestavuje build/build-windows.sh:
;   makensis -DVERSION=X.Y.Z -DSTAGEDIR=<připravená distribuce> -DOUTFILE=<exe> installer.nsi
; Instaluje pro aktuálního uživatele do %LOCALAPPDATA%\Programs, bez práv správce.

Unicode true
SetCompressor /SOLID lzma

!ifndef VERSION
  !error "Chybí -DVERSION=X.Y.Z"
!endif
!ifndef STAGEDIR
  !error "Chybí -DSTAGEDIR=... (adresář s připravenou distribucí)"
!endif
!ifndef OUTFILE
  !define OUTFILE "video-convertor-${VERSION}-setup.exe"
!endif

!define APPNAME "Video convertor pro TV"
!define APPKEY "video-convertor"
!define PUBLISHER "Jan Čejka"
!define REGKEY "Software\${APPKEY}"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}"
!define SMDIR "$SMPROGRAMS\${APPNAME}"
!define DESKTOPLNK "$DESKTOP\Převést pro TV.lnk"
!define POWERSHELL "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"

Name "${APPNAME} ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\${APPKEY}"
InstallDirRegKey HKCU "${REGKEY}" "InstallDir"
RequestExecutionLevel user
ManifestDPIAware true
BrandingText "${APPNAME} ${VERSION}"
; podrobnosti ukazují průběh stahování FFmpeg
ShowInstDetails show
ShowUninstDetails show

!include "MUI2.nsh"
!include "LogicLib.nsh"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_TEXT "Video convertor je nainstalovaný.$\r$\n$\r$\nVideo převedete přetažením na zástupce „Převést pro TV“ (nabídka Start, případně plocha), nebo v terminálu příkazem:$\r$\n$\r$\nconvert-for-tv -Profile standard -Path D:\Video\film.mkv$\r$\n$\r$\nStav FFmpeg lze kdykoli ověřit zástupcem „Zkontrolovat FFmpeg“."
!define MUI_FINISHPAGE_SHOWREADME "$WINDIR\notepad.exe"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Zobrazit návod (README)"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION ShowReadme
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Czech"

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=${LANG_CZECH} "ProductName" "${APPNAME}"
VIAddVersionKey /LANG=${LANG_CZECH} "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=${LANG_CZECH} "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=${LANG_CZECH} "FileDescription" "Instalátor ${APPNAME}"
VIAddVersionKey /LANG=${LANG_CZECH} "CompanyName" "${PUBLISHER}"
VIAddVersionKey /LANG=${LANG_CZECH} "LegalCopyright" "© ${PUBLISHER}"

Function ShowReadme
  Exec '"$WINDIR\notepad.exe" "$INSTDIR\README.md"'
FunctionEnd

Section "Video convertor (povinné)" SecMain
  SectionIn RO

  ; Skripty odebrané v nové verzi nesmí zůstat po předchozí instalaci.
  Delete "$INSTDIR\scripts\windows\*.ps1"

  SetOutPath "$INSTDIR"
  File /r "${STAGEDIR}/*"

  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "${REGKEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UNINSTKEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1

  CreateDirectory "${SMDIR}"
  CreateShortcut "${SMDIR}\Převést pro TV (přetáhněte video).lnk" "$INSTDIR\prevest-pro-tv.cmd"
  CreateShortcut "${SMDIR}\Terminál Video convertor.lnk" "${POWERSHELL}" \
    `-NoExit -NoProfile -ExecutionPolicy Bypass -Command "Set-Location -LiteralPath '$INSTDIR'; Write-Host 'Příklad: .\convert-for-tv.cmd -Profile standard -Path D:\Video\film.mkv'"`
  CreateShortcut "${SMDIR}\Návod (README).lnk" "$WINDIR\notepad.exe" '"$INSTDIR\README.md"'
  CreateShortcut "${SMDIR}\Zkontrolovat FFmpeg.lnk" "$INSTDIR\ffmpeg-setup.cmd"
  CreateShortcut "${SMDIR}\Odinstalovat.lnk" "$INSTDIR\uninstall.exe"
SectionEnd

Section "Přidat do PATH (příkaz convert-for-tv v terminálu)" SecPath
  nsExec::ExecToLog '"${POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\tools\user-path.ps1" -Directory "$INSTDIR"'
  Pop $0
  ${If} $0 == 0
    WriteRegDWORD HKCU "${REGKEY}" "AddedToPath" 1
  ${Else}
    DetailPrint "Přidání do PATH selhalo (kód $0)."
  ${EndIf}
SectionEnd

Section /o "Zástupce na ploše pro přetažení videa" SecDesktop
  CreateShortcut "${DESKTOPLNK}" "$INSTDIR\prevest-pro-tv.cmd"
SectionEnd

Section "FFmpeg (stáhnout, pokud chybí nebo nevyhovuje)" SecFfmpeg
  ; Ověří ffmpeg/ffprobe, kodeky libx264, libx265, aac, ac3 a libass; jinak
  ; stáhne ověřené sestavení (SHA-256) do $INSTDIR\ffmpeg.
  DetailPrint "Kontrola FFmpeg…"
  nsExec::ExecToLog '"${POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\tools\ffmpeg-setup.ps1" -InstallDir "$INSTDIR\ffmpeg"'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "FFmpeg se nepodařilo zkontrolovat ani stáhnout (kód $0), podrobnosti jsou v průběhu instalace.$\r$\n$\r$\nZopakovat to lze později zástupcem „Zkontrolovat FFmpeg“ v nabídce Start, případně FFmpeg nainstalovat ručně podle REQUIREMENTS.md." /SD IDOK
  ${EndIf}
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "Skripty pro převod videa, spouštěče a dokumentace."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecPath} "Umožní spouštět convert-for-tv, extract-ass a fix-audio-offsets z libovolného terminálu."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecFfmpeg} "Ověří, že je k dispozici FFmpeg se všemi potřebnými kodeky a libass. Pokud ne, stáhne ověřené sestavení z gyan.dev (asi 115 MB) do složky programu."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "Zástupce „Převést pro TV“ na ploše: přetáhněte na něj videa a převedou se profilem standard."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  ReadRegDWORD $0 HKCU "${REGKEY}" "AddedToPath"
  ${If} $0 == 1
    nsExec::ExecToLog '"${POWERSHELL}" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\tools\user-path.ps1" -Directory "$INSTDIR" -Remove'
    Pop $0
  ${EndIf}

  ; Mažou se jen vlastní soubory, aby nevadila instalace do sdílené složky.
  Delete "$INSTDIR\convert-for-tv.cmd"
  Delete "$INSTDIR\extract-ass.cmd"
  Delete "$INSTDIR\fix-audio-offsets.cmd"
  Delete "$INSTDIR\prevest-pro-tv.cmd"
  Delete "$INSTDIR\ffmpeg-setup.cmd"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\REQUIREMENTS.md"
  Delete "$INSTDIR\CHANGELOG.md"
  Delete "$INSTDIR\VERSION"
  Delete "$INSTDIR\scripts\windows\*.ps1"
  RMDir "$INSTDIR\scripts\windows"
  RMDir "$INSTDIR\scripts"
  Delete "$INSTDIR\tools\user-path.ps1"
  Delete "$INSTDIR\tools\ffmpeg-setup.ps1"
  ; FFmpeg stažený instalátorem (značka), nikdy cizí složku ffmpeg
  ${If} ${FileExists} "$INSTDIR\ffmpeg\.video-convertor"
    RMDir /r "$INSTDIR\ffmpeg"
  ${EndIf}
  RMDir "$INSTDIR\tools"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  Delete "${SMDIR}\Převést pro TV (přetáhněte video).lnk"
  Delete "${SMDIR}\Terminál Video convertor.lnk"
  Delete "${SMDIR}\Návod (README).lnk"
  Delete "${SMDIR}\Zkontrolovat FFmpeg.lnk"
  Delete "${SMDIR}\Odinstalovat.lnk"
  RMDir "${SMDIR}"
  Delete "${DESKTOPLNK}"

  DeleteRegKey HKCU "${UNINSTKEY}"
  DeleteRegKey HKCU "${REGKEY}"
SectionEnd
