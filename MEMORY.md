# MEMORY.md

Projektová paměť: rozhodnutí, jejich důvody a poučení, která nejsou zřejmá z kódu. Nejnovější nahoře. Praktické pokyny pro práci s kódem jsou v [AGENTS.md](AGENTS.md).

## Rozhodnutí

### 2026-10-30 – FFmpeg pro Windows: vlastní stažené sestavení místo winget
- Instalátor ověří FFmpeg včetně kodeků a libass; když nevyhovuje, stáhne gyan.dev „essentials“ do `<instalace>\ffmpeg` a skripty ho preferují (VideoTools.ps1 ho dá na začátek PATH procesu).
- Proč ne winget: chybí na starších Windows 10 a LTSC, mění systémový PATH a výsledek není pod kontrolou.
- Pevná verze 9.0.2 s SHA-256 ve skriptu (stejná verze, se kterou se testuje na macOS); záloha na aktuální release se součtem ze serveru, pokud by gyan.dev starý balíček stáhl.
- Stažení přes HttpWebRequest s výpisem průběhu po 10 %, aby bylo v detailech instalátoru vidět, že se něco děje (115 MB). ffplay se maže (~100 MB navíc, nepotřebný).
- Mazat se smí jen složka se značkou `.video-convertor`, aby instalace do sdílené složky nesmazala cizí FFmpeg.

### 2026-10-30 – Vydávání přes tag a GitHub Actions
- Release vzniká automaticky po pushnutí tagu `vX.Y.Z` (ubuntu-latest + apt nsis; pwsh je na runneru předinstalovaný, takže proběhne i kontrola syntaxe). Tag musí odpovídat `VERSION`, poznámky jsou sekce z CHANGELOG.md.

### 2026-10-30 – Konverze nenechává extrahované titulky
- Uživatel chtěl, aby konverze po sobě smazala extrahované `.ass`. Protože se od 0.2.0 vypaluje z dočasné kopie vybrané stopy, extrakce vedle videa by vznikala jen proto, aby se smazala. Místo mazání se tedy ve výchozím stavu vůbec nespouští: stejný výsledek, rychlejší a bez rizika smazání titulků, které tam uživatel měl předem (stažené, ručně upravené).
- Původní chování zůstává přes `--keep-ass` / `-KeepAss`.

### 2026-10-30 – Windows instalátor v NSIS, spouštěče .cmd
- NSIS, protože `makensis` běží na macOS/Linuxu (brew/apt) a instalátor jde sestavit bez Windows; Inno Setup i WiX vyžadují Windows nebo Wine.
- Per-user instalace bez UAC: nástroj nepotřebuje nic systémového.
- Spouštěče `.cmd` s `-ExecutionPolicy Bypass` řeší dvě časté překážky: výchozí Restricted policy a Mark of the Web u souborů rozbalených ze staženého zipu (RemoteSigned je pak odmítne).
- PATH se mění přes registr jako REG_EXPAND_SZ (`user-path.ps1`), protože `[Environment]::SetEnvironmentVariable` rozvine `%USERPROFILE%` a uloží REG_SZ.
- Verzování zavedeno souborem `VERSION` (0.2.0), protože instalátor potřebuje číslo verze.

### 2026-10-30 – Výběr stop podle heuristiky, ne jen podle metadat
- Metadata v reálných souborech jsou nespolehlivá: chybí příznak forced, jazyk je `und` nebo špatně, správná informace bývá jen v názvu stopy („CZ“, „Čeština“, „forc“).
- Jazyk: název stopy (cs/sk) > jazykový tag > název (ostatní jazyky) > `und`. Název vyhrává, protože ho píše člověk; tag bývá výchozí hodnota z muxeru.
- Druh: název > příznak forced > počet titulků. Prahy: ≥ 6 titulků/min = plné, < 1,5/min = forced, stopa se 4× méně titulky než nejbohatší = forced. Příznak forced se ignoruje u stopy s ≥ 6/min, protože některé releasy označují plné české titulky jako forced, aby se zobrazily automaticky.
- PGS má 2 pakety na titulek (zobrazení + smazání), proto se počet dělí dvěma.
- Heuristika je sdílená v `scripts/lib/tracks.sh` (dříve duplikovaná v `convert-for-tv.sh` a `extract-ass.sh`).

### 2026-10-30 – Sporné situace: výpis, ruční volba, ponechání stop
- Skript vždy vypíše přehled stop s výsledkem heuristiky a ve sporu radí `--audio`, `--audio-lang`, `--sub`.
- Neurčený jazyk zvuku = „cizí“ (vypálí se plné titulky). Plné titulky přes český dabing jsou menší škoda než chybějící překlad cizích dialogů.
- Při sporu se ponechají další možné stopy jako nevýchozí: audio vždy, titulky jen u `hd10`. U vypalovacích profilů ne, protože MP4 muxer první titulkovou stopu vždy zapne a zobrazila by se přes vypálené titulky.

### 2026-10-30 – Titulky se vybírají ze stop zdroje, ne ze souborů z extrakce
- Dřív se vypalovalo z `*.cs.ass` vytvořených `extract-ass.sh` a výběr závisel na pojmenování souborů. Teď se vybírá ze stop zdroje (všechna metadata) a vybraná stopa se převede do dočasného ASS.
- `extract-ass.sh` dál vytváří soubory vedle videa pro jiné přehrávače; vedle videa se `.ass` použije jen jako poslední záloha.
- Ručně upravené ASS se vypálí přes `--sub soubor.ass` (styl se nemění).

### 2026-10-30 – Titulky vedle videa (`.srt`, `.sub`, `.vtt`, `.ssa`)
- Zařazují se jako další kandidátské stopy, prochází stejnou heuristikou.
- Jazyk z názvu souboru, jinak z obsahu: ř/ů/ě jsou jen v češtině, ľ/ĺ/ŕ/ô/ä jen ve slovenštině.
- Ne-UTF-8 soubory = Windows-1250 (staré české titulky); ISO-8859-2 se nerozlišuje.
- `.ass` se vedle videa nehledá, protože ho vytváří extrakce ze stop zdroje a vznikaly by duplicitní kandidáti.
- VobSub (`.idx` + `.sub`) zatím není podporovaný (vyžaduje overlay s přepočtem velikosti plátna).

### 2026-10-30 – Obrazové titulky ze zdroje se vypalují přes overlay bez ořezu
- PGS/VobSub nejdou převést do ASS (dřív se proto tiše vynechaly, typicky forced titulky z Blu-ray). Teď `overlay` na plné video před škálováním.
- Ořez černých pruhů se při tom vypíná, protože titulky v pruzích často bývají. Cesta zatím nebyla ověřena na reálném PGS (viz ROADMAP).

### 2026-10-30 – Podporované vstupy a kolize výstupů
- Přípony: mkv, mp4, m4v, mov, avi, wmv, asf, webm, ts, m2ts, mts, mpg, mpeg, flv. Ověřeno na mkv, avi (Xvid i H.264) a m4v; ostatní jen přidány do seznamu.
- `film.avi` a `film.mkv` ve stejné složce → stejný `tv/film.mp4`; druhý se v rámci běhu přeskočí s varováním.

### 2026-10-30 – macOS: `ffmpeg-full`
- Základní Homebrew formule `ffmpeg` neobsahuje libass → nelze vypalovat ASS. `ffmpeg-full` ji má, ale je keg-only, proto ho skripty hledají přímo v `/opt/homebrew/opt/ffmpeg-full/bin` (a `/usr/local/opt/...`).

## Poučení (chyby, na které jsme narazili)

- Windows `.ps1` bez BOM: PS 5.1 je čte jako ANSI, rozbité české hlášky a regulární výrazy s diakritikou. Platilo i pro distribuovaný zip.
- PowerShell nerozlišuje velikost písmen proměnných: smyčková `$audio` přepsala parametr `[string] $Audio`.
- `ffmpeg -filters | grep -q` pod `pipefail` hlásilo chybějící filtr kvůli SIGPIPE.
- Bez `-fflags +genpts` FFmpeg u kopie H.264 z AVI hlásí „Timestamps are unset in a packet“ (do budoucna chyba).
- Testovací MP4 s obalem jako první stopou nejde snadno vyrobit, muxer obal přesune na konec. Výběr `V:0` je ověřený jen sémanticky.
