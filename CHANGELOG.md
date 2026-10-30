# Changelog

Formát vychází z [Keep a Changelog](https://keepachangelog.com/cs/1.1.0/). Projekt zatím nemá číslované verze.

## [Nevydáno] – 2026-10-30

### Přidáno
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

## Původní stav (před 2026-10-30)

- Konverze MKV/MP4 do MP4 pro TV s profily `standard`, `akcni`, `serialy`, `hd10`; macOS (VideoToolbox), Linux (libx264/libx265), Windows (NVENC s návratem na CPU).
- Výběr zvuku podle jazykového tagu, titulky z extrahovaných CZ/SK ASS souborů, cropdetect, oprava kladného audio offsetu.
