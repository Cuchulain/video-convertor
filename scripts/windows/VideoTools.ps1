Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-VideoTools {
    foreach ($command in @('ffmpeg', 'ffprobe')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Chybí příkaz '$command'. Nainstalujte FFmpeg a přidejte jeho složku bin do PATH."
        }
    }
}

# Podporované vstupní formáty.
$script:MediaExtensions = @('.mkv', '.mp4', '.m4v', '.mov', '.avi', '.wmv', '.asf', '.webm', '.ts', '.m2ts', '.mts', '.mpg', '.mpeg', '.flv')

function Get-MediaFiles([string[]] $InputPaths) {
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $InputPaths) {
        if ($item -match '[*?]') {
            Get-ChildItem -Path $item -File -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Extension -in $script:MediaExtensions) { $result.Add($_.FullName) }
            }
        } elseif (Test-Path -LiteralPath $item -PathType Container) {
            Get-ChildItem -LiteralPath $item -File | Where-Object Extension -in $script:MediaExtensions |
                ForEach-Object { $result.Add($_.FullName) }
        } elseif (Test-Path -LiteralPath $item -PathType Leaf) {
            $file = Get-Item -LiteralPath $item
            if ($file.Extension -in $script:MediaExtensions) { $result.Add($file.FullName) }
        } else {
            Write-Warning "Cesta neexistuje: $item"
        }
    }
    return @($result)
}

function Get-Probe([string] $File, [switch] $CountPackets) {
    $args = @('-v', 'error')
    if ($CountPackets) { $args += '-count_packets' }
    $args += @('-show_streams', '-show_format', '-of', 'json', $File)
    $json = & ffprobe @args
    if ($LASTEXITCODE -ne 0) { throw "ffprobe selhal pro: $File" }
    return ($json | ConvertFrom-Json)
}

function Get-Tag($Stream, [string] $Name) {
    $tags = $Stream.PSObject.Properties['tags']
    if ($tags -and $tags.Value) {
        $property = $tags.Value.PSObject.Properties[$Name]
        if ($property -and $property.Value) { return [string]$property.Value }
    }
    return ''
}

function Get-Title($Stream) { return (Get-Tag $Stream 'title') }

function Get-Disposition($Stream, [string] $Name) {
    $disposition = $Stream.PSObject.Properties['disposition']
    if ($disposition -and $disposition.Value) {
        $property = $disposition.Value.PSObject.Properties[$Name]
        if ($property) { return ([int]$property.Value -eq 1) }
    }
    return $false
}

# --- Heuristika jazyka a druhu stop (shodná se scripts/lib/tracks.sh) --------
#
# Metadata stop bývají nespolehlivá: chybí příznak forced, jazyk je "und" nebo
# špatně, a správná informace je jen v názvu stopy ("CZ", "Čeština", "forc"...).
#   jazyk: název stopy (cs/sk) > jazykový tag > název stopy (ostatní) > und
#   druh:  název stopy > příznak forced (pokud mu neodporuje počet titulků)
#          > počet titulků vůči délce filmu a ostatním stopám

$script:ReCs = ' (cz|cze|ces|cs|czech[a-z]*|cesk[a-z]*|cestin[a-z]*) '
$script:ReSk = ' (sk|slk|svk|slovak[a-z]*|slovencin[a-z]*|slovensk(y|e|a|ych|ym|ou|om|eho)?) '
$script:ReEn = ' (en|eng|english|angl|anglick[a-z]*|anglictin[a-z]*) '
$script:ReOther = ' (ger|deu|german|deutsch|nemeck[a-z]*|nemcin[a-z]*|pol|polish|polski|polsk[a-z]*|hun|hungarian|magyar|madarsk[a-z]*|rus|russian|rusk[a-z]*|fre|fra|french|francais|francouzsk[a-z]*|spa|spanish|espanol|spanelsk[a-z]*|ita|italian|italiano|italsk[a-z]*|ukr|ukrainian|ukrajinsk[a-z]*|jpn|japanese|japonsk[a-z]*) '
$script:ReForced = 'forc|vynucen| nucen| cizi | cizich | cizojazyc|foreign| napis| signs '
$script:ReFull = ' (full|plne|plna|plny|uplne|uplna|kompletni|complete) '
$script:ReSdh = ' sdh |hearing| cc | hoh |neslysic|nedoslych'
$script:ReComment = 'comment|komentar'
$script:TextSubtitleCodecs = @('subrip', 'srt', 'ass', 'ssa', 'mov_text', 'webvtt', 'text',
    'microdvd', 'subviewer', 'subviewer1', 'mpl2', 'vplayer', 'sami', 'realtext', 'pjs', 'jacosub', 'stl')
# Přípony titulků hledaných vedle videa. ASS se nehledá, protože ho vytváří
# extract-ass.ps1 ze stop zdroje (používá se jen jako záloha).
$script:SidecarExtensions = @('.srt', '.sub', '.vtt', '.ssa')

# Malá písmena, bez diakritiky, vše kromě [a-z0-9] -> mezera, obaleno mezerami.
function ConvertTo-NormalizedText([string] $Text) {
    $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = [Text.StringBuilder]::new()
    foreach ($char in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }
    $plain = ($builder.ToString().ToLowerInvariant() -replace '[^a-z0-9]', ' ')
    return " $plain "
}

function Get-TagLanguage([string] $Tag) {
    switch -regex ($Tag.ToLowerInvariant()) {
        '^(cs|cz|cze|ces|czech)$' { return 'cs' }
        '^(sk|slk|slo|slovak)$' { return 'sk' }
        '^(en|eng|english)$' { return 'en' }
        '^(|und|unk|unknown|undefined|undetermined|mis|mul|zxx|none)$' { return 'und' }
        default { return 'other' }
    }
}

function Get-TitleLanguage([string] $Normalized) {
    if ($Normalized -match $script:ReCs) { return 'cs' }
    if ($Normalized -match $script:ReSk) { return 'sk' }
    if ($Normalized -match $script:ReEn) { return 'en' }
    if ($Normalized -match $script:ReOther) { return 'other' }
    return ''
}

# Jazyk z kódu v názvu souboru titulků ("cs", "cz", "en", "de"...).
function Get-CodeTokenLanguage([string] $Token) {
    switch -regex ($Token) {
        '^(cs|cz|cze|ces|czech)$' { return 'cs' }
        '^(sk|slk|slo|slovak)$' { return 'sk' }
        '^(en|eng|english)$' { return 'en' }
        '^(de|ger|deu|fr|fre|fra|es|spa|it|ita|pl|pol|hu|hun|ru|rus|uk|ukr|nl|dut|nld|pt|por)$' { return 'other' }
        default { return '' }
    }
}

function Get-Windows1250 {
    try { return [Text.Encoding]::GetEncoding(1250) } catch {
        # PowerShell 7 (.NET Core) má kódové stránky Windows v samostatném providerovi
        [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
        return [Text.Encoding]::GetEncoding(1250)
    }
}

# Kódování textových titulků: '' (UTF-8), 'UTF-16' (s BOM, FFmpeg ho pozná sám)
# nebo 'CP1250' (vše ostatní, typické pro české .srt/.sub).
function Get-SubtitleCharset([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return '' }
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { return 'UTF-16' }
    try {
        [void][Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        return ''
    } catch { return 'CP1250' }
}

# Jazyk podle obsahu titulků (pro soubory bez jazyka v názvu): cs|sk|en|''.
function Get-ContentLanguage([string] $Path, [string] $Charset) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 300000) { $bytes = $bytes[0..299999] }
    $text = switch ($Charset) {
        'CP1250' { (Get-Windows1250).GetString($bytes) }
        'UTF-16' { [Text.Encoding]::Unicode.GetString($bytes) }
        default  { [Text.Encoding]::UTF8.GetString($bytes) }
    }
    # ř/ů/ě má jen čeština, ľ/ĺ/ŕ/ô/ä jen slovenština
    $cs = [regex]::Matches($text, '[řŘůŮěĚ]').Count
    $sk = [regex]::Matches($text, '[ľĽĺĹŕŔôÔäÄ]').Count
    $en = [regex]::Matches($text, '(?i)\b(the|you|and|what|this|that)\b').Count
    if ($cs -ge 10 -and $sk * 4 -lt $cs) { return 'cs' }
    if ($sk -ge 10 -and $cs * 4 -lt $sk) { return 'sk' }
    if ($en -ge 30) { return 'en' }
    return ''
}

function Get-ProbeDuration($Probe) {
    $durationProperty = $Probe.format.PSObject.Properties['duration']
    if ($durationProperty -and $durationProperty.Value) {
        $seconds = [Math]::Floor([double]$durationProperty.Value)
        if ($seconds -ge 60) { return $seconds }
    }
    return $null
}

# Přidá titulky ze souboru jako další titulkovou stopu; jazyk určí z názvu,
# jinak z obsahu. Vrátí stopu (i už dříve přidanou), nebo $null, pokud soubor
# nejde načíst. Druh doplní Update-TrackClassification.
# $Label = část názvu mezi jménem videa a příponou ("cs", "forced.cz"...).
function Add-SidecarTrack($Tracks, [string] $Path, [string] $Label) {
    $existing = @($Tracks | Where-Object { $_.File -eq $Path })[0]
    if ($existing) { return $existing }

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $json = & ffprobe -v error -count_packets -select_streams s:0 -show_entries stream=codec_name,nb_read_packets -of json $Path 2>$null
        $ok = ($LASTEXITCODE -eq 0)
    } finally { $ErrorActionPreference = $oldPreference }
    if (-not $ok) { return $null }
    $stream = @(($json | ConvertFrom-Json).streams)[0]
    if (-not $stream) { return $null }
    $codecProperty = $stream.PSObject.Properties['codec_name']
    $codec = if ($codecProperty) { [string]$codecProperty.Value } else { '' }
    $packets = 0
    $packetProperty = $stream.PSObject.Properties['nb_read_packets']
    if ($packetProperty -and "$($packetProperty.Value)" -match '^\d+$') { $packets = [long]$packetProperty.Value }

    $isText = ($codec -in $script:TextSubtitleCodecs)
    $charset = if ($isText) { Get-SubtitleCharset $Path } else { '' }
    $normalized = ConvertTo-NormalizedText $Label
    $language = Get-TitleLanguage $normalized
    if (-not $language) {
        foreach ($token in ($normalized.Trim() -split ' +')) {
            $language = Get-CodeTokenLanguage $token
            if ($language) { break }
        }
    }
    $languageSource = 'název souboru'
    if (-not $language -and $isText) {
        $language = Get-ContentLanguage $Path $charset
        $languageSource = 'obsah souboru'
    }
    if (-not $language) { $language = 'und'; $languageSource = 'neurčen' }

    $track = [pscustomobject]@{
        Type = 'subtitle'; Relative = $null; Index = $null; Codec = $codec
        Tag = ''; Title = $Label; Normalized = $normalized; Language = $language
        LanguageSource = $languageSource; Kind = ''; KindSource = ''; Packets = $packets; Events = 0
        Skip = ''; IsText = $isText; Forced = $false; HearingImpaired = $false
        File = $Path; Charset = $charset; Stream = $null
    }
    $Tracks.Add($track)
    return $track
}

# Přidá titulky vedle videa: <jméno>.srt, <jméno>.cs.srt, <jméno>.forced.cz.sub...
function Add-SidecarTracks($Tracks, [string] $File) {
    $directory = [IO.Path]::GetDirectoryName($File)
    $name = [IO.Path]::GetFileNameWithoutExtension($File)
    foreach ($candidate in @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue)) {
        if (-not $candidate.Name.StartsWith("$name.", [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($candidate.Extension -notin $script:SidecarExtensions) { continue }
        $rest = $candidate.Name.Substring($name.Length + 1)
        $label = if ($rest.Contains('.')) { $rest.Substring(0, $rest.LastIndexOf('.')) } else { '' }
        [void](Add-SidecarTrack $Tracks $candidate.FullName $label)
    }
}

# Doplní Events/Skip/Kind/KindSource všech stop. Volá se z Get-TrackInfo
# a znovu po přidání titulků ze souboru.
function Update-TrackClassification($Tracks, $Duration) {
    foreach ($track in $Tracks) {
        $track.Skip = ''
        if ($track.Normalized -match $script:ReComment) { $track.Skip = 'komentář' }
        if ($track.Type -ne 'subtitle') { continue }
        $track.Events = if ($track.Codec -eq 'hdmv_pgs_subtitle') { [Math]::Floor($track.Packets / 2) } else { $track.Packets }
        if ($track.HearingImpaired -or $track.Normalized -match $script:ReSdh) { $track.Skip = 'sdh' }
        if (-not $track.Skip -and $track.Events -le 0) { $track.Skip = 'prázdná' }
        if ($track.File -and -not $track.IsText) { $track.Skip = 'obrazové titulky ze souboru (VobSub) nejsou podporované' }
    }

    $maxEvents = 0
    foreach ($track in $Tracks) {
        if ($track.Type -eq 'subtitle' -and -not $track.Skip -and $track.Events -gt $maxEvents) { $maxEvents = $track.Events }
    }

    # Typický film: plné titulky 6–15/min, forced do 1/min.
    foreach ($track in $Tracks) {
        if ($track.Type -ne 'subtitle') { continue }
        $events = $track.Events
        $rate = $null
        if ($Duration) { $rate = $events * 60.0 / $Duration }

        $countKind = 'unknown'
        if ($null -ne $rate -and $rate -ge 6) { $countKind = 'full' }
        elseif ($null -ne $rate -and $rate -lt 1.5) { $countKind = 'forced' }
        elseif ($maxEvents -gt 0 -and $events * 4 -le $maxEvents) { $countKind = 'forced' }
        elseif ($null -ne $rate -and $rate -ge 3) { $countKind = 'full' }
        elseif ($null -eq $rate -and $events -ge 300) { $countKind = 'full' }

        if ($track.Normalized -match $script:ReForced) {
            $track.Kind = 'forced'; $track.KindSource = 'název'
        } elseif ($track.Normalized -match $script:ReFull) {
            $track.Kind = 'full'; $track.KindSource = 'název'
        } elseif ($track.Forced) {
            # Některé releasy označí jako forced i plné titulky, aby se zobrazily.
            if ($null -ne $rate -and $rate -ge 6) {
                $track.Kind = 'full'; $track.KindSource = 'počet titulků (příznak forced ignorován)'
            } else {
                $track.Kind = 'forced'; $track.KindSource = 'příznak'
            }
        } else {
            $track.Kind = $countKind
            $track.KindSource = if ($countKind -eq 'unknown') { 'nelze určit' } else { 'počet titulků' }
        }
    }
}

# Vrátí audio a titulkové stopy s výsledkem heuristiky (jako List, aby šly
# přidávat titulky ze souborů). Probe musí být pořízen s -CountPackets, aby
# šel odhadnout druh titulků podle počtu. S -File se přidají i titulky vedle videa.
function Get-TrackInfo($Probe, [string] $File) {
    $tracks = [System.Collections.Generic.List[object]]::new()
    $audioCount = 0
    $subtitleCount = 0
    foreach ($stream in @($Probe.streams)) {
        $type = [string]$stream.codec_type
        if ($type -eq 'audio') { $relative = $audioCount; $audioCount++ }
        elseif ($type -eq 'subtitle') { $relative = $subtitleCount; $subtitleCount++ }
        else { continue }

        $tag = Get-Tag $stream 'language'
        $title = Get-Title $stream
        $normalized = ConvertTo-NormalizedText $title
        $tagLanguage = Get-TagLanguage $tag
        $titleLanguage = Get-TitleLanguage $normalized
        if ($titleLanguage -in @('cs', 'sk')) {
            $language = $titleLanguage
            $languageSource = if ($tagLanguage -eq $titleLanguage) { 'tag+název' } else { "název (tag '$(if ($tag) { $tag } else { 'žádný' })')" }
        } elseif ($tagLanguage -ne 'und') {
            $language = $tagLanguage; $languageSource = 'tag'
        } elseif ($titleLanguage) {
            $language = $titleLanguage; $languageSource = 'název'
        } else {
            $language = 'und'; $languageSource = 'neurčen'
        }

        $packets = 0
        $packetProperty = $stream.PSObject.Properties['nb_read_packets']
        if ($packetProperty -and "$($packetProperty.Value)" -match '^\d+$') { $packets = [long]$packetProperty.Value }
        $codecProperty = $stream.PSObject.Properties['codec_name']
        $codec = if ($codecProperty) { [string]$codecProperty.Value } else { '' }

        $tracks.Add([pscustomobject]@{
            Type = $type; Relative = $relative; Index = [int]$stream.index; Codec = $codec
            Tag = $tag; Title = $title; Normalized = $normalized; Language = $language
            LanguageSource = $languageSource; Kind = ''; KindSource = ''; Packets = $packets; Events = 0
            Skip = ''; IsText = ($codec -in $script:TextSubtitleCodecs)
            Forced = (Get-Disposition $stream 'forced'); HearingImpaired = (Get-Disposition $stream 'hearing_impaired')
            File = $null; Charset = ''; Stream = $stream
        })
    }
    if ($File) { Add-SidecarTracks $tracks $File }
    Update-TrackClassification $tracks (Get-ProbeDuration $Probe)
    return , $tracks
}

# Označení stopy pro výpis: s:N, nebo název souboru.
function Get-TrackSpec($Track) {
    if ($Track.File) { return "soubor $([IO.Path]::GetFileName($Track.File))" }
    return "s:$($Track.Relative)"
}

# Vstupní volby FFmpeg pro titulky ze souboru (kódování, snímková frekvence
# pro MicroDVD, použije se jen když soubor neuvádí vlastní).
function Get-SidecarInputArguments($Track, $VideoStream) {
    $arguments = @()
    if ($Track.Charset -eq 'CP1250') { $arguments += @('-sub_charenc', 'CP1250') }
    if ($Track.Codec -eq 'microdvd' -and $VideoStream) {
        $rate = $VideoStream.PSObject.Properties['r_frame_rate']
        if ($rate -and "$($rate.Value)" -match '^\d+/[1-9]\d*$') { $arguments += @('-subfps', $rate.Value) }
    }
    return $arguments
}

# ISO 639-2/T kód pro MP4 metadata.
function Get-Iso3([string] $Language) {
    switch ($Language) { 'cs' { 'ces' } 'sk' { 'slk' } 'en' { 'eng' } default { '' } }
}

# Přepíše styl Default v ASS souboru (žluté Arial 30 se stínem).
function Set-AssDefaultStyle([string] $File) {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $text = [IO.File]::ReadAllText($File)
    $style = 'Style: Default,Arial,30,&H0000FFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1'
    $text = [regex]::Replace($text, '(?m)^Style: Default,.*$', $style)
    [IO.File]::WriteAllText($File, $text, $utf8)
}

function Get-StreamBitrate($Stream) {
    $bitRate = $Stream.PSObject.Properties['bit_rate']
    if ($bitRate -and "$($bitRate.Value)" -match '^\d+$') { return [long]$bitRate.Value }
    $tags = $Stream.PSObject.Properties['tags']
    if ($tags -and $tags.Value) {
        foreach ($name in @('BPS', 'BPS-eng', 'BPS-ENG')) {
            $property = $tags.Value.PSObject.Properties[$name]
            if ($property -and "$($property.Value)" -match '^\d+$') { return [long]$property.Value }
        }
    }
    return $null
}

function Invoke-Native([string] $Command, [object[]] $Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command skončil s kódem $LASTEXITCODE." }
}
