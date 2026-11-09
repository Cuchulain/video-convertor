# Changelog

Formát vychází z [Keep a Changelog](https://keepachangelog.com/cs/1.1.0/), verze podle souboru `VERSION`.

## [Nevydáno]

### Přidáno
- Klíč `video_kbps_percent` v profilech zařízení: datové toky profilů kvality (dělané pro 720p) se pro zařízení s vyšším rozlišením navýší.

### Změněno
- Profil `lg` převádí ve Full HD (max. 1920 × 1080) s datovým tokem 180 % (`standard` 3 600 kb/s); zdroj 1080p s nižším datovým tokem se zkopíruje místo zmenšení na 720p.

### Opraveno
- Převod přeskočí výstupní složky `tv` a `tv-…` zadané jako adresář; `convert-for-tv.sh *` po předchozím běhu už nevytvoří zanořenou `tv-lg/tv-lg`.

## [0.3.0] – 2026-11-08

### Přidáno
- Profily cílových zařízení (`--device`, `--list-devices`, `--set-device`; Windows `-Device`, `-ListDevices`, `-SetDevice`): kodek zvuku, kopírovatelné zvukové kodeky, nejvyšší level H.264 pro kopii a nejvyšší rozlišení. Vestavěné `hyundai` (dosavadní chování) a `lg` (LG 49LH6047, kopie H.264 do levelu 4.2, kopie i AAC) ve sdíleném `scripts/devices.conf`, vlastní profily a výchozí zařízení v uživatelské konfiguraci.

### Změněno
- Výstup jde do podadresáře `tv-<zařízení>` místo `tv` (např. `tv-hyundai`, `tv-lg`).
- `fix-audio-offsets` při posunu zvuku zachová AAC (dříve vždy převedl na AC-3).

### Opraveno
- Video zkopírované z MKV mělo v MP4 rozkolísané časové značky (snímky 23,976 fps střídavě 41 a 42 ms) a LG 49LH6047 takový film odmítla („Tento soubor nelze rozpoznat“). Při kopii videa se stálou frekvencí se časy nově srovnají na mřížku snímků (filtr `setts`, bez překódování); skutečně proměnná frekvence zůstává beze změny.
- `fix-audio-offsets.sh` spuštěný samostatně s českým locale neopravil offset (awk četl `0,48` jako 0).

## [0.2.1] – 2026-11-03

### Opraveno
- Spuštění přes symlink (např. `~/bin/convert-for-tv.sh`) končilo chybou `lib/tracks.sh: No such file or directory`; skripty i linuxové wrappery nyní dohledají svou skutečnou složku.

## [0.2.0] – 2026-10-30

### Přidáno
- Instalátor pro Windows (NSIS, per-user bez práv správce): zástupci v nabídce Start, volitelně přidání do `PATH` a zástupce na ploše pro přetažení videa, odinstalace.
- Kontrola FFmpeg včetně potřebných kodeků (`libx264`, `libx265`, `aac`, `ac3`) a libass; pokud nevyhovuje, instalátor nebo `ffmpeg-setup.cmd` stáhne ověřené sestavení gyan.dev (pevná verze 9.0.2 se SHA-256) do složky programu. Možná i instalace offline (`-ZipPath`).
- Skripty před konverzí ověří potřebné kodeky a libass a srozumitelně nahlásí, co chybí (macOS/Linux i Windows).
- Automatické vydání: po pushnutí tagu `vX.Y.Z` GitHub Actions sestaví zip a instalátor a založí release s poznámkami z CHANGELOG.md a `SHA256SUMS.txt`.
- Spouštěče `convert-for-tv.cmd`, `extract-ass.cmd`, `fix-audio-offsets.cmd` (bez nutnosti měnit ExecutionPolicy) a `prevest-pro-tv.cmd` pro přetažení videí myší.
- `build/build-windows.sh`: sestavení zipu a instalátoru z repozitáře včetně kontrol (BOM, CRLF, syntaxe `.ps1`); soubor `VERSION`.
- Přepínač `--keep-ass` / `-KeepAss` pro uložení extrahovaných titulků vedle videa.
- Licence MIT; autor a odkazy (https://dev.jancejka.cz, repozitář) v hlavičkách skriptů, nápovědě, README a instalátoru (stránka s licencí, odkazy v Nastavení → Aplikace, zástupce „Web projektu“).
- Sdílená heuristika výběru stop (`scripts/lib/tracks.sh`, ve Windows `VideoTools.ps1`): jazyk i z názvu stopy („CZ“, „čeština“, „Czech“…), forced podle názvu („forced“, „forc“, „vynucené“, „cizí“, „nápisy“…), příznaku a počtu titulků.
- Přehled stop s výsledkem heuristiky na začátku zpracování a varování ve sporných situacích.
- Ruční volba stop: `--audio N`, `--audio-lang cs|sk|cizi`, `--sub N|soubor|none` (Windows: `-Audio`, `-AudioLang`, `-Sub`).
- Ve sporných situacích se ponechají další možné stopy jako nevýchozí (audio s neurčeným jazykem; titulky u profilu `hd10`).
- Titulky vedle videa (`film.srt`, `film.cs.srt`, `film.forced.cz.srt`, `.sub`, `.vtt`, `.ssa`) jako kandidáti výběru; jazyk z názvu souboru nebo z obsahu, automatické Windows-1250, MicroDVD s frekvencí snímků videa.
- Vypalování obrazových titulků (PGS/VobSub) ze zdroje přes overlay.
- Podpora vstupů `.m4v`, `.mov`, `.avi`, `.wmv`, `.asf`, `.webm`, `.ts`, `.m2ts`, `.mts`, `.mpg`, `.mpeg`, `.flv`.
- Oprava jazykového tagu výstupní stopy, pokud byl jazyk zjištěn z názvu nebo obsahu.
- Kontrola filtru `ass` (libass) před vypalováním se srozumitelnou chybou.
- Dokumentace: AGENTS.md, MEMORY.md, ROADMAP.md, CHANGELOG.md, `.gitignore`; README sekce „Podporované vstupy“ a „Výběr stop a titulků“.

### Změněno
- Konverze po sobě nenechává extrahované titulky: `extract-ass` se při konverzi ve výchozím stavu nespouští, vypaluje se z dočasné kopie. `--no-extract` / `-NoExtract` je zastaralé (odpovídá výchozímu chování).
- Zip pro Windows má kořenovou složku `video-convertor/` a obsahuje spouštěče, CHANGELOG a VERSION.
- Titulky se vybírají ze stop zdroje (dříve z ASS souborů vytvořených extrakcí); ASS vedle videa slouží jen jako záloha nebo přes `--sub`.
- Pořadí výběru zvuku: čeština → slovenština → angličtina → neurčený jazyk → ostatní; komentáře až nakonec.
- Pro český zvuk se jako záloha použijí i slovenské forced titulky.
- Příznak forced se ignoruje u stopy s počtem titulků odpovídajícím plným titulkům.
- `extract-ass` používá stejnou heuristiku: vytáhne i stopy se špatným tagem a „CZ“ v názvu, forced stopy mají v názvu souboru `force`, diakritika v názvu se převádí (`cestina` místo `e-tina`).
- macOS: skripty přednostně používají keg-only `ffmpeg-full`; REQUIREMENTS doporučuje `brew install bash ffmpeg-full` a uvádí požadavek na libass pro všechny platformy.
- Video se vybírá jako `V:0` (ignoruje obal filmu uložený jako obrázková stopa).

### Opraveno
- CS forced titulky se nevybraly, když měl český zvuk neurčený/špatný tag, titulky špatný jazyk nebo chyběl příznak forced.
- Obrazové forced titulky (PGS) se tiše vynechaly.
- AVI s H.264: chybějící časové značky při kopii videa (`-fflags +genpts`).
- `film.avi` a `film.mkv` ve stejné složce se navzájem přepisovaly v `tv/film.mp4`.
- Windows: `.ps1` soubory nyní mají UTF-8 BOM, takže Windows PowerShell 5.1 správně zobrazí češtinu.
- Spuštění systémovým Bashem 3.2 na macOS končilo nesrozumitelnou chybou; skript se nyní sám spustí přes Homebrew Bash.

## [0.1.0] – původní stav (před 2026-10-30)

- Konverze MKV/MP4 do MP4 pro TV s profily `standard`, `akcni`, `serialy`, `hd10`; macOS (VideoToolbox), Linux (libx264/libx265), Windows (NVENC s návratem na CPU).
- Výběr zvuku podle jazykového tagu, titulky z extrahovaných CZ/SK ASS souborů, cropdetect, oprava kladného audio offsetu.
