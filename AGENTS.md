# AGENTS.md

Pokyny pro AI agenty (Claude Code, Codex, Cursor…) i lidi, kteří v projektu pracují. Uživatelská dokumentace je v [README.md](README.md), požadavky v [REQUIREMENTS.md](REQUIREMENTS.md), rozhodnutí a poučení v [MEMORY.md](MEMORY.md), plány v [ROADMAP.md](ROADMAP.md), změny v [CHANGELOG.md](CHANGELOG.md).

## O projektu

Sada skriptů nad FFmpeg, která převádí videa (MKV, MP4, AVI…) do MP4 pro televizor: vybere zvuk a titulky (čeština → slovenština → angličtina), titulky vypálí nebo vloží, zmenší obraz na max. 1280 × 720 a opraví audio offset. Náhrada za dříve používaný HandBrake (profily v `HandBrake-profiles/` jsou jen historická reference, skripty je nenačítají).

## Struktura

| Cesta | Účel |
|---|---|
| `scripts/convert-for-tv.sh` | hlavní skript (macOS/Linux): výběr stop, rozhodnutí kopie/překódování, konverze |
| `scripts/extract-ass.sh` | extrakce CZ/SK textových titulků ze stop zdroje do `*.label.cs.ass` vedle videa |
| `scripts/fix-audio-offsets.sh` | dorovnání kladného audio offsetu ve výsledném MP4 |
| `scripts/lib/tracks.sh` | **sdílená heuristika**: načtení stop (`probe_tracks`), jazyk, forced/full, titulky ze souborů vedle videa, seznam podporovaných přípon |
| `scripts/linux/*.sh` | tenké wrappery, které spustí skripty o úroveň výš s `VIDEO_BACKEND=software` |
| `scripts/windows/*.ps1` | samostatný port pro Windows PowerShell 5.1 / PowerShell 7 |
| `scripts/windows/VideoTools.ps1` | sdílené funkce pro Windows včetně stejné heuristiky jako `lib/tracks.sh` |
| `packaging/windows/*.cmd` | spouštěče pro Windows (`-ExecutionPolicy Bypass`), musí mít CRLF a jen ASCII text |
| `packaging/windows/user-path.ps1` | přidání/odebrání instalační složky v uživatelském `PATH` (volá instalátor) |
| `packaging/windows/ffmpeg-setup.ps1` | kontrola FFmpeg (kodeky, libass) a stažení ověřeného sestavení gyan.dev do `ffmpeg/` (instalátor, `ffmpeg-setup.cmd`) |
| `packaging/windows/installer.nsi` | instalátor NSIS |
| `.github/workflows/release.yml` | po pushnutí tagu `vX.Y.Z` sestaví balíčky a založí GitHub Release |
| `build/build-windows.sh` | sestaví `dist/video-convertor-windows-<verze>.zip` a `dist/video-convertor-<verze>-setup.exe` |
| `VERSION` | verze projektu (X.Y.Z), používá ji build i instalátor |

## Zásadní pravidla

- **Parita platforem.** Každá změna chování v bash verzi musí být i ve Windows verzi (`scripts/windows/`) a naopak. Heuristika v `lib/tracks.sh` a `VideoTools.ps1` musí dávat stejné výsledky (stejné regulární výrazy, prahy, pořadí priorit, texty hlášek).
- **Čeština.** Komentáře, hlášky, nápověda i dokumentace jsou česky. Identifikátory v kódu anglicky/zkratkami jako dosud (`SEL_AIDX`, `TRK_LANG`, `Select-Audio`).
- **Styl kódu.** Drž se okolního kódu: bash s `set -euo pipefail`, funkce vracejí výsledek přes globální proměnné (`SEL_*`, `TRK_*`, `_TRK_R`), komentář nad každou funkcí s popisem parametrů (`$1=...`).
- **Verze.** Při vydání zvyš `VERSION`, přejmenuj sekci v CHANGELOG.md (`## [X.Y.Z] – datum`, workflow z ní bere poznámky), commitni a pushni tag `vX.Y.Z`; release vytvoří GitHub Actions. Výstupy v `dist/` se necommitují.
- **Dokumentace.** Změnu chování nebo parametrů zapiš do README.md (a REQUIREMENTS.md u závislostí), přidej záznam do CHANGELOG.md, nová poučení do MEMORY.md a hotové/nové body do ROADMAP.md.
- **Nemazat uživatelská data.** Skripty nesmí přepsat vstup; výstupy jdou do `tv/` nebo `--outdir`.

## Bash: na co si dát pozor

- Vyžaduje Bash 4+ (asociativní pole). `convert-for-tv.sh` a `extract-ass.sh` se pod Bashem 3.2 samy znovu spustí přes Homebrew Bash.
- Na macOS se do `PATH` přidává `/opt/homebrew/bin` a před něj keg-only `ffmpeg-full` (obsahuje libass).
- `set -o pipefail` + `cmd | grep -q`: `grep -q` skončí dřív, `cmd` dostane SIGPIPE a pipeline selže. Výstup nejdřív ulož do proměnné.
- `[[ podmínka ]] && příkaz` jako poslední příkaz smyčky/funkce vrací 1 a se `set -e` může ukončit skript. Používej `if`.
- `grep` bez shody vrací 1: v `$(...)` použij `{ grep ... || true; }`.
- Prázdná pole v `"${pole[@]}"` jsou v pořádku jen v Bash 4.4+ (Homebrew bash 5 to splňuje).
- Video stopa se adresuje `V:0` (velké V), ne `v:0`: ignoruje obal filmu (`attached_pic`).

## PowerShell: na co si dát pozor

- Kompatibilita s **Windows PowerShell 5.1**: žádné `??`, ternární operátor ani jiné novinky PS 7. `Set-StrictMode -Version 2.0`, k volitelným vlastnostem přistupuj přes `$obj.PSObject.Properties['x']`.
- Soubory `.ps1` musí být **UTF-8 s BOM**, jinak je PS 5.1 čte jako ANSI a rozbije češtinu i regulární výrazy s diakritikou.
- Proměnné nerozlišují velikost písmen: `$audio` přepíše parametr `$Audio` (který je navíc typu `[string]`). Lokální proměnné pojmenovávej odlišně od parametrů skriptu.
- `$args` je automatická proměnná; v `convert-for-tv.ps1` se historicky používá pro argumenty FFmpeg, nepřidávej další použití jinde.
- Kódová stránka 1250 je v PS 7 (.NET Core) dostupná až po `RegisterProvider` (viz `Get-Windows1250`).
- `powershell -File skript.ps1 -Path a b` selže: parametr s `ValueFromRemainingArguments` přebírá více hodnot jen pozičně (`skript.ps1 a b`) nebo oddělené čárkou.
- Nový `.ps1` soubor: zapiš s BOM (Python `encoding='utf-8-sig'`); build to kontroluje.

## Spouštěče a instalátor (Windows)

- `.cmd` musí mít CRLF (vynucuje `.gitattributes`) a jen ASCII: cmd.exe čte dávky v OEM kódové stránce.
- Instalátor je per-user (`RequestExecutionLevel user`, `HKCU`, `%LOCALAPPDATA%\Programs`). Odinstalace maže jen vyjmenované soubory, nikdy `RMDir /r $INSTDIR`. Přidáš-li do distribuce soubor, doplň ho do sekce `Uninstall` v `installer.nsi`.
- Seznam souborů distribuce je jen v `build/build-windows.sh` (adresář `STAGE`); instalátor bere celý připravený adresář.
- Požadované kodeky a filtry jsou ve `VideoTools.ps1` (`$RequiredEncoders`, `$RequiredFilters`) a v bash `main()`; drž je v souladu. Na macOS se místo `libx264`/`libx265` vyžadují VideoToolbox enkodéry.
- Aktualizace FFmpeg pro Windows: v `ffmpeg-setup.ps1` změň `$PinnedVersion` a `$PinnedSha256` (součet z `https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-<verze>-essentials_build.zip.sha256`). Stažený FFmpeg je ve složce se značkou `.video-convertor`; jen takovou smí skript i odinstalace smazat.
- Na macOS lze instalátor jen sestavit, ne spustit (chybí Windows/Wine). Spouštěče, PATH a instalátor je potřeba ověřit na Windows.

## FFmpeg: na co si dát pozor

- MP4 muxer vždy označí první titulkovou stopu jako zapnutou (default), i když dostane `-disposition 0`. Proto se u vypalovacích profilů nevkládají žádné další titulkové stopy (zobrazily by se přes vypálené).
- Vypalování textových titulků potřebuje filtr `ass` (libass). Základní Homebrew `ffmpeg` ho nemá → `ffmpeg-full`.
- AVI: pro kopii videa do MP4 je nutné `-fflags +genpts`.
- Titulky ze souborů: `-sub_charenc CP1250` pro ne-UTF-8, `-subfps <fps videa>` pro MicroDVD.
- `-count_packets` čte celý soubor (u velkých filmů to trvá); je potřeba pro heuristiku forced/full.

## Testování

Před sestavením balíčků: `build/build-windows.sh --no-installer` zkontroluje BOM, CRLF a syntaxi `.ps1`.

Automatické testy zatím nejsou (viz ROADMAP). Ověřuje se ručně na syntetických souborech, nikdy ne v repozitáři, ale v dočasném adresáři:

```bash
# kontrola syntaxe
for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$f"; done

# syntetické video 10 min (délka je důležitá pro heuristiku počtu titulků)
ffmpeg -f lavfi -i color=c=gray:s=320x240:r=5:d=600 -f lavfi -i sine=d=600 \
  -c:v libx264 -preset ultrafast -c:a ac3 base.mkv
# titulky: SRT se 100 řádky (plné) a 5 řádky (forced), metadata přes
#   -metadata:s:s:0 language=eng -metadata:s:s:0 title="CZ forced" -disposition:s:0 forced

# rozhodnutí bez konverze
scripts/convert-for-tv.sh --dry-run base.mkv
pwsh -NoProfile -File scripts/windows/convert-for-tv.ps1 -Hardware Cpu -DryRun -Path base.mkv
```

Výstup `--dry-run` z bash a Windows verze musí vybrat stejné stopy. U vypálených titulků zkontroluj snímek (`ffmpeg -ss 1.5 -i tv/x.mp4 -frames:v 1 x.png`), u vložených `ffprobe -show_entries stream_disposition=default:stream_tags=language`.

Scénáře, které je dobré po změně heuristiky projít: forced bez příznaku jen s „forc“ v názvu, špatný jazykový tag s „CZ“ v názvu, plné titulky s chybným příznakem forced, neurčený jazyk zvuku i titulků, český zvuk jen podle názvu stopy, titulky vedle videa v CP1250 bez jazyka v názvu, MicroDVD `.sub`, AVI s H.264 (kopie videa).
