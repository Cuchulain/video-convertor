# ROADMAP.md

Plánované a zvažované úpravy. Hotové věci se přesouvají do [CHANGELOG.md](CHANGELOG.md).

## Ověřit na reálných souborech

- [ ] Vypalování obrazových titulků PGS/VobSub ze zdroje přes overlay (zatím netestováno, syntetický PGS nejde vyrobit).
- [ ] MP4/MOV/M4V s obalem filmu jako první video stopou (výběr `V:0`).
- [ ] Formáty `.wmv`, `.asf`, `.webm`, `.ts`, `.m2ts`, `.mts`, `.mpg`, `.mpeg`, `.flv`.
- [ ] Windows verze na skutečném Windows (PS 5.1, cesty s diakritikou, NVENC na GTX 980M); zatím testováno jen přes `pwsh` na macOS.
- [ ] Prahy heuristiky forced/full (1,5 a 6 titulků/min) na větším vzorku filmů a seriálů, zvlášť u filmů s málo dialogy.

## Funkce

- [ ] Titulky VobSub vedle videa (`.idx` + `.sub`): vypálení přes overlay s přizpůsobením velikosti plátna videu.
- [ ] Titulky v podadresářích (`Subs/`, `Subtitles/`) a s jiným jménem než video (jeden `.srt` ve složce s jedním videem).
- [ ] Rozpoznání dalších kódování titulků (ISO-8859-2, UTF-16 bez BOM).
- [ ] Rekurzivní zpracování složek (volitelný přepínač).
- [ ] Při kolizi výstupů (`film.avi` + `film.mkv`) nabídnout odlišný název místo přeskočení.
- [ ] Volba druhu titulků bez výběru konkrétní stopy (např. plné titulky i k českému zvuku).

## Infrastruktura

- [ ] Automatické testy: generátor syntetických souborů + kontrola výběru stop v `--dry-run` (bats pro bash, Pester pro PowerShell), včetně porovnání shody obou verzí.
- [ ] ShellCheck a PSScriptAnalyzer v CI.
- [ ] Skript pro sestavení `video-convertor-windows.zip` (aktuální archiv je zastaralý: chybí změny od 2026-10-30 a BOM v `.ps1`).
- [ ] Číslované verze a tagy.
