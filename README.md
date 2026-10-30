# Video convertor pro TV

Sada skriptů převede videosoubory (MKV, MP4, AVI a další, viz [Podporované vstupy](#podporované-vstupy)) do MP4 vhodného pro televizor. Automaticky vybere zvuk v pořadí čeština → slovenština → angličtina → neurčený jazyk → ostatní, pracuje s českými a slovenskými titulky ve videu i vedle něj (podrobně v části [Výběr stop a titulků](#výběr-stop-a-titulků)), zmenší obraz nejvýše na 1280 × 720 a podle potřeby opraví kladný audio offset.

## Podporované platformy

- macOS: původní skripty v `scripts/`, hardwarové kódování VideoToolbox
- Linux amd64: skripty v `scripts/linux/`, softwarové kódování `libx264`/`libx265`
- Windows 10/11 x64: nativní PowerShell skripty v `scripts/windows/`, automatická NVIDIA NVENC akcelerace s návratem na `libx264`/`libx265`

Podrobný seznam programů a instalační příkazy jsou v [REQUIREMENTS.md](REQUIREMENTS.md).

## Profily

| Profil | Video | Zvuk | Titulky |
|---|---|---|---|
| `standard` | H.264, max. 2 000 kb/s | AC-3, max. 384 kb/s | vypálené do obrazu |
| `akcni` | H.264, max. 2 500 kb/s | AC-3, max. 384 kb/s | vypálené do obrazu |
| `serialy` | H.264, max. 1 600 kb/s | AC-3, max. 384 kb/s | vypálené do obrazu |
| `hd10` | HEVC Main 10 | AAC, max. 160 kb/s | vložené jako `mov_text` |

Skript kompatibilní stopu zkopíruje bez ztráty kvality. Překódování spustí jen tehdy, když je nutné kvůli kodeku, rozlišení, datovému toku, ořezu nebo vypálení titulků. Výstup vzniká standardně v podadresáři `tv` vedle vstupu.

## Linux amd64

Po instalaci závislostí nastavte spustitelné oprávnění (v repozitáři už je nastavené):

```bash
chmod +x scripts/*.sh scripts/linux/*.sh
```

Konverze jednoho souboru nebo celé složky:

```bash
./scripts/linux/convert-for-tv.sh --profile standard film.mkv
./scripts/linux/convert-for-tv.sh --profile serialy "/data/Seriál"
./scripts/linux/convert-for-tv.sh --profile hd10 --cq 60 video.mkv
```

Kontrola rozhodnutí bez změny souborů:

```bash
./scripts/linux/convert-for-tv.sh --dry-run film.mkv
```

Samostatná extrakce titulků a oprava audio offsetu:

```bash
./scripts/linux/extract-ass.sh film.mkv
./scripts/linux/fix-audio-offsets.sh --threshold 0.050 film.mp4
```

## Windows 10/11

Spusťte PowerShell nebo Windows Terminal v kořeni projektu. Při prvním spuštění může být potřeba povolit lokální skripty pro aktuální účet:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Konverze souboru nebo složky:

```powershell
.\scripts\windows\convert-for-tv.ps1 -Profile standard -Path "D:\Video\film.mkv"
.\scripts\windows\convert-for-tv.ps1 -Profile serialy -Path "D:\Video\Seriál"
.\scripts\windows\convert-for-tv.ps1 -Profile hd10 -Cq 60 -Path "D:\Video\film.mkv"
```

Výchozí `-Hardware Auto` provede krátký test skutečného enkódování a použije NVENC, pouze pokud jej podporují FFmpeg, ovladač i grafická karta. Volbu lze změnit:

```powershell
# Automatická volba NVENC/CPU (výchozí)
.\scripts\windows\convert-for-tv.ps1 -Hardware Auto -Profile standard -Path "D:\Video\film.mkv"

# Vynutit NVIDIA; při nedostupném NVENC skončí s vysvětlením
.\scripts\windows\convert-for-tv.ps1 -Hardware Nvidia -Profile standard -Path "D:\Video\film.mkv"

# Vždy použít CPU
.\scripts\windows\convert-for-tv.ps1 -Hardware Cpu -Profile standard -Path "D:\Video\film.mkv"
```

Na NVIDIA GeForce GTX 980M režim `Auto` používá `h264_nvenc` pro profily `standard`, `akcni` a `serialy`. Profil `hd10` automaticky použije `libx265`, protože GTX 980M nepodporuje hardwarové HEVC Main10.

Další příklady:

```powershell
# Pouze kontrola; nic se nevytvoří ani nezmění
.\scripts\windows\convert-for-tv.ps1 -DryRun -Path "D:\Video\film.mkv"

# Vlastní výstupní složka a vypnutí dílčích kroků
.\scripts\windows\convert-for-tv.ps1 -OutDir "E:\Hotovo" -NoExtract -NoFixOffset -Path "D:\Video"

# Samostatné pomocné skripty
.\scripts\windows\extract-ass.ps1 -Path "D:\Video\film.mkv"
.\scripts\windows\fix-audio-offsets.ps1 -Threshold 0.050 -Path "D:\Video\film.mp4"
```

Více vstupů lze předat za `-Path` oddělených čárkou. Kromě souborů jsou podporované adresáře a zástupné cesty jako `D:\Video\*.mkv`.

## Podporované vstupy

`.mkv`, `.mp4`, `.m4v`, `.mov`, `.avi`, `.wmv`, `.asf`, `.webm`, `.ts`, `.m2ts`, `.mts`, `.mpg`, `.mpeg`, `.flv` (bez ohledu na velikost písmen). Při zadání adresáře se zpracují všechny takové soubory v něm (bez podadresářů).

- U AVI se dopočítají chybějící časové značky (`-fflags +genpts`), aby šlo H.264 video zkopírovat do MP4 bez překódování.
- Obal filmu uložený jako obrázková stopa (MP4/MOV/M4V) se ignoruje a použije se skutečné video.
- Pokud ve stejné složce leží např. `film.avi` i `film.mkv`, oba by vedly na `tv/film.mp4`; zpracuje se jen první a druhý se s varováním přeskočí.

## Výběr stop a titulků

Metadata stop bývají nespolehlivá (chybí příznak forced, jazyk je `und` nebo špatně), proto skript kromě jazykového tagu a příznaků bere v úvahu i název stopy a počet titulků:

- **Jazyk**: název stopy s „CZ“, „čeština“, „česky“, „Czech“ apod. (případně „SK“, „slovenčina“…) má přednost před tagem. Jinak platí tag, a když chybí nebo je `und`, zkusí se v názvu najít jiný jazyk.
- **Forced/plné titulky**: rozhoduje název stopy („forced“, „forc“, „vynucené“, „cizí“, „nápisy“, „signs“ / „full“, „plné“), potom příznak forced a nakonec počet titulků vůči délce filmu (forced obvykle méně než 1,5 za minutu, plné 6 a více) a vůči ostatním stopám. Příznak forced u stopy s počtem titulků plné stopy se ignoruje.
- SDH a stopy pro neslyšící se ignorují, komentáře se použijí jen tehdy, když nic jiného není.

Zvuk se vybírá v pořadí čeština → slovenština → angličtina → neurčený jazyk → ostatní. Podle zvuku se volí titulky:

| Zvuk | Titulky |
|---|---|
| český | české forced (fallback slovenské forced) |
| slovenský | slovenské forced (fallback české forced) |
| cizí | české plné (fallback slovenské plné) |

Kandidáty jsou i titulky uložené vedle videa se stejným jménem: `film.srt`, `film.cs.srt`, `film.forced.cz.srt`, `film.sub`, `film.vtt`, `film.ssa`. Procházejí stejnou heuristikou:

- jazyk podle názvu souboru (`cs`, `cz`, `czech`, `sk`, `en`…); bez jazyka v názvu (`film.srt`) podle obsahu (ř/ů/ě → čeština, ľ/ô/ä → slovenština, časté anglické výrazy → angličtina),
- forced podle názvu souboru (`forced`, `forc`…), jinak podle počtu titulků,
- kódování: soubory, které nejsou v UTF-8, se čtou jako Windows-1250,
- `.sub` ve formátu MicroDVD (časy ve snímcích) dostane snímkovou frekvenci videa, pokud ji soubor sám neuvádí; obrazové VobSub (`.idx` + `.sub`) zatím podporované nejsou.

Když nic vhodného není ani tak, použije se ASS soubor vedle videa (z extrakce nebo stažené `film.cokoli.cs.ass`).

Na začátku zpracování skript vypíše přehled stop s výsledkem heuristiky (`*` vybráno, `+` ponecháno jako nevýchozí stopa, `?` další možná správná stopa). Ve sporných situacích (neurčený jazyk, nejasný druh titulků, více kandidátů) vypíše varování a:

- u zvuku ponechá i stopy s neurčeným jazykem jako další, nevýchozí audio stopy,
- u profilu `hd10` vloží i ostatní možná správné textové titulky jako nevýchozí stopy,
- u vypalovacích profilů vypálí nejpravděpodobnější stopu a vypíše alternativy (MP4 by jinak zobrazil přidanou titulkovou stopu přes vypálené titulky).

Volbu lze určit ručně (čísla stop odpovídají výpisu):

| macOS/Linux | Windows | Význam |
|---|---|---|
| `--audio N` | `-Audio N` | použít audio stopu `a:N` |
| `--audio-lang cs\|sk\|cizi` | `-AudioLang cs\|sk\|cizi` | jazyk zvuku (určuje forced, nebo plné titulky) |
| `--sub N` | `-Sub N` | použít titulkovou stopu `s:N` |
| `--sub soubor` | `-Sub soubor` | použít titulky ze souboru (`.srt`, `.sub`, `.ass`…, kódování se pozná samo) |
| `--sub none` | `-Sub none` | bez titulků |

```bash
./scripts/convert-for-tv.sh --dry-run film.mkv                     # nejdřív zkontrolovat výběr
./scripts/convert-for-tv.sh --audio-lang cs film.mkv               # neurčený zvuk je český dabing
./scripts/convert-for-tv.sh --sub 2 film.mkv                       # vypálit titulky s:2
```

```powershell
.\scripts\windows\convert-for-tv.ps1 -DryRun -Path "D:\Video\film.mkv"
.\scripts\windows\convert-for-tv.ps1 -AudioLang cs -Sub 2 -Path "D:\Video\film.mkv"
```

Při zpracování celé složky platí ruční volba pro všechny soubory, hodí se tedy hlavně pro jeden soubor nebo sérii se stejným rozložením stop.

## Titulky

Pro profily `standard`, `akcni` a `serialy` se titulky vypalují do obrazu. Textové titulky se převedou do ASS (žluté Arial), obrazové PGS/VobSub se vypálí přes overlay. U obrazových titulků se neořezávají černé pruhy, protože v nich titulky často bývají. Skript navíc vyextrahuje textové CZ/SK titulky do souborů ASS vedle videa (forced stopy mají v názvu `force`).

Profil `hd10` titulky nevypaluje. Vybranou textovou stopu vloží do MP4 jako výchozí `mov_text`. Obrazové titulky PGS/VobSub nelze do MP4 tímto způsobem vložit a skript je s varováním přeskočí.

Pokud byl jazyk stopy určen z názvu a tag zdroje je jiný, výstupní stopa dostane opravený jazykový tag.

## Důležité chování

- Konverze může podle délky videa a výkonu CPU trvat dlouho, zejména HEVC Main10 na Linuxu a na Windows s GTX 980M.
- `fix-audio-offsets` dočasně přejmenuje vstup na `*.original.*`; po úspěchu zálohu odstraní, při chybě ji obnoví.
- Záporné audio offsety se pouze ohlásí a neupravují.
- Existující cílový MP4 přepíše FFmpeg bez dotazu. Nejdřív lze použít `--dry-run` na Linuxu/macOS nebo `-DryRun` na Windows.
- `--cq`/`-Cq` má rozsah 0–100; vyšší číslo znamená vyšší kvalitu. Hodnota se interně převádí na CRF/CQ použitého HEVC enkodéru.

## macOS

Původní rozhraní zůstává beze změny:

```bash
./scripts/convert-for-tv.sh --profile standard film.mkv
./scripts/extract-ass.sh film.mkv
./scripts/fix-audio-offsets.sh film.mp4
```

## Dokumentace

- [REQUIREMENTS.md](REQUIREMENTS.md) – potřebné programy a instalace
- [CHANGELOG.md](CHANGELOG.md) – přehled změn
- [ROADMAP.md](ROADMAP.md) – plánované úpravy a co je potřeba ověřit
- [AGENTS.md](AGENTS.md) – pokyny pro vývoj (struktura, konvence, testování), i pro AI agenty
- [MEMORY.md](MEMORY.md) – rozhodnutí a jejich důvody, poučení z chyb
