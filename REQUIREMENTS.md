# Potřebné aplikace

## Linux amd64

Povinné:

- 64bitová distribuce Linuxu a Bash 4 nebo novější
- FFmpeg s programy `ffmpeg` a `ffprobe` a enkodéry `libx264`, `libx265`, `aac`, `ac3`
- podpora ASS titulků: FFmpeg sestavený s `libass` (filtry `ass` a `subtitles`), bez ní nelze titulky vypálit; balík `ffmpeg` v Ubuntu/Debianu ji obsahuje
- běžné nástroje `awk`, `sed`, `grep`, `tr`, `head`, `wc`, `cp`, `mv`, `rm` a `mktemp`
- font Arial pro vzhled titulků; bez něj libass zvolí náhradní font

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install ffmpeg gawk coreutils grep sed fonts-liberation2
```

Balík `fonts-liberation2` dodá metricky kompatibilní náhradu Arialu. Skutečný Arial lze doinstalovat podle pravidel konkrétní distribuce. Ověření kodeků:

```bash
ffmpeg -hide_banner -encoders | grep -E 'libx264|libx265| ac3 | aac '
ffmpeg -hide_banner -filters | grep -E ' (ass|subtitles) '
```

## Windows 10/11 x64

Povinné:

- Windows PowerShell 5.1 (součást Windows 10/11) nebo PowerShell 7+
- 64bitový FFmpeg s `ffmpeg.exe`, `ffprobe.exe`, `libx264`, `libx265`, `aac` a `ac3`; oba programy musí být dostupné v `PATH`
- podpora ASS titulků: FFmpeg s `libass` (filtry `ass` a `subtitles`) pro vypalování titulků; sestavení Gyan.FFmpeg ji obsahuje
- Arial (standardní součást Windows)

Instalátor (nebo `ffmpeg-setup.cmd` v rozbaleném zipu) FFmpeg zkontroluje a pokud chybí nebo nevyhovuje, stáhne sestavení gyan.dev „essentials“ do složky programu. Ruční instalace níže je potřeba jen tehdy, když chcete systémový FFmpeg.

Pro volitelnou NVIDIA akceleraci:

- NVIDIA ovladač kompatibilní s instalovanou grafickou kartou
- FFmpeg s enkodérem `h264_nvenc`; pro HW profil `hd10` také `hevc_nvenc` s podporou Main10
- GTX 980M podporuje hardwarové H.264, ale nepodporuje HEVC Main10; `-Hardware Auto` proto u `hd10` použije CPU

Instalace FFmpeg přes WinGet:

```powershell
winget install --id Gyan.FFmpeg -e
```

Po instalaci zavřete a znovu otevřete terminál a ověřte:

```powershell
ffmpeg -version
ffprobe -version
ffmpeg -hide_banner -encoders | Select-String 'libx264|libx265|h264_nvenc|hevc_nvenc| ac3 | aac '
ffmpeg -hide_banner -filters | Select-String ' (ass|subtitles) '
```

Samotná přítomnost názvu enkodéru ve výpisu nezaručuje podporu GPU. Skript v režimu `-Hardware Auto` provede před konverzí krátký funkční test.

Nejsou potřeba WSL, Git Bash, HandBrake ani Python.

## macOS

Původní skripty vyžadují Bash 4+ a FFmpeg s VideoToolbox a podporou ASS titulků (`libass`, filtry `ass` a `subtitles`). Základní formule `ffmpeg` v Homebrew `libass` neobsahuje, proto je potřeba `ffmpeg-full`:

```bash
brew install bash ffmpeg-full
```

`ffmpeg-full` je keg-only (nelinkuje se do `/opt/homebrew/bin`). Skripty ho najdou samy v `/opt/homebrew/opt/ffmpeg-full/bin` (případně `/usr/local/opt/ffmpeg-full/bin` na Intel Macu) a použijí ho přednostně, i když je současně nainstalovaný základní `ffmpeg`. Ověření:

```bash
/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg -hide_banner -filters | grep -E ' (ass|subtitles) '
```

Bez `libass` skript `convert-for-tv.sh` u profilů s vypalováním titulků (`standard`, `akcni`, `serialy`) skončí s chybou; profil `hd10` titulky nevypaluje a `libass` nepotřebuje.

Profily v `HandBrake-profiles/` jsou volitelné a skripty je přímo nenačítají.

## Sestavení balíčků pro Windows

Jen pro vývojáře, kteří sestavují zip a instalátor (`build/build-windows.sh`). Běží na macOS i Linuxu:

- Bash 4+, `zip`
- NSIS 3 (`makensis`) pro instalátor; bez něj vznikne jen zip
- volitelně PowerShell 7 (`pwsh`) pro kontrolu syntaxe `.ps1`

```bash
brew install makensis              # macOS (zip je součástí systému; pwsh: brew install --cask powershell)
sudo apt install nsis zip          # Debian/Ubuntu
```
