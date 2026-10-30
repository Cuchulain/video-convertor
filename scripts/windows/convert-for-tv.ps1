[CmdletBinding()]
param(
    [ValidateSet('standard', 'akcni', 'serialy', 'hd10')]
    [string] $Profile = 'standard',
    [ValidateRange(0, 100)]
    [int] $Cq = 60,
    [ValidateSet('Auto', 'Nvidia', 'Cpu')]
    [string] $Hardware = 'Auto',
    [double] $Threshold = 0.050,
    [string] $OutDir,
    # Ponechat vedle videa CZ/SK titulky vytažené do .ass (pro jiné přehrávače).
    # Výchozí: nic se nevytváří, vypaluje se z dočasné kopie.
    [switch] $KeepAss,
    # Zastaralé, odpovídá výchozímu chování.
    [switch] $NoExtract,
    [switch] $NoFixOffset,
    [switch] $DryRun,
    # Ruční volba stop pro sporné případy (čísla viz výpis "Stopy ve zdroji"):
    # -Audio N (a:N), -AudioLang cs|sk|cizi, -Sub N (s:N) | soubor | none
    [string] $Audio,
    [string] $AudioLang,
    [string] $Sub,
    [Parameter(Position = 0, Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]] $Path
)

. "$PSScriptRoot\VideoTools.ps1"
Assert-VideoTools

# --- Výběr stop -------------------------------------------------------------
#
# Jazyk a druh stop určuje Get-TrackInfo (VideoTools.ps1), která kromě metadat
# bere v úvahu i název stopy a počet titulků. Logika odpovídá convert-for-tv.sh.

function Get-AudioCategory([string] $Language) {
    switch ($Language) { 'cs' { 'czech' } 'sk' { 'slovak' } default { 'foreign' } }
}

# Priorita: čeština -> slovenština -> angličtina -> neurčený jazyk -> ostatní,
# komentáře až nakonec. Neurčené stopy vedle necizího výběru se ponechají jako
# nevýchozí (mohou být český dabing).
function Select-Audio($Tracks) {
    $audioTracks = @($Tracks | Where-Object Type -eq 'audio')
    if (-not $audioTracks.Count) { return $null }
    $pick = $null
    if ($null -ne $script:AudioIndex) {
        $pick = @($audioTracks | Where-Object Relative -eq $script:AudioIndex)[0]
        if (-not $pick) { throw "Audio stopa a:$($script:AudioIndex) neexistuje." }
    } else {
        foreach ($want in @('cs', 'sk', 'en', 'und', 'other')) {
            $pick = @($audioTracks | Where-Object { -not $_.Skip -and $_.Language -eq $want })[0]
            if ($pick) { break }
        }
        if (-not $pick) { $pick = $audioTracks[0] }
    }

    $category = Get-AudioCategory $pick.Language
    $sure = ($pick.Language -ne 'und')
    if ($script:AudioCategory) { $category = $script:AudioCategory; $sure = $true }

    $extra = @()
    if ($null -eq $script:AudioIndex -and $category -ne 'czech') {
        $extra = @($audioTracks | Where-Object { $_ -ne $pick -and -not $_.Skip -and $_.Language -eq 'und' })
    }
    return @{ Track = $pick; Index = $pick.Relative; Category = $category; Sure = $sure; Extra = $extra }
}

# Najde ASS soubor vedle videa pro daný jazyk a druh.
function Find-ExternalSubtitle([string] $File, [string] $Code, [bool] $Forced) {
    $directory = [IO.Path]::GetDirectoryName($File)
    $name = [IO.Path]::GetFileNameWithoutExtension($File)
    foreach ($candidate in @(Get-ChildItem -LiteralPath $directory -Filter "$name.*.$Code.ass" -File -ErrorAction SilentlyContinue)) {
        $label = $candidate.Name.Substring($name.Length + 1)
        if (($label -match '(?i)forc') -eq $Forced) { return $candidate.FullName }
    }
    return $null
}

# Vrátí @{ Source = 'track'|$null; Track; Sure; Alt; Extra }. Track je stopa
# zdroje, nebo titulky ze souboru vedle videa (Track.File).
# Alt = další možná správné stopy (pro výpis), Extra = z nich textové, které se
# vloží jako nevýchozí (jen hd10; MP4 muxer by první titulkovou stopu vždy
# označil jako zapnutou, takže u vypalovacích profilů by se zobrazila přes
# vypálené titulky).
function Select-Subtitle($Tracks, $AudioChoice, [string] $File, $Duration) {
    $result = @{ Source = $null; Track = $null; Sure = $true; Alt = @(); Extra = @() }
    $subtitles = @($Tracks | Where-Object Type -eq 'subtitle')

    if ($Sub) {
        if ($Sub -eq 'none') { return $result }
        if ($Sub -match '^\d+$') {
            $track = @($subtitles | Where-Object Relative -eq ([int]$Sub))[0]
            if (-not $track) { Write-Warning "Titulková stopa s:$Sub neexistuje, titulky vynechávám."; return $result }
            $result.Source = 'track'; $result.Track = $track
        } else {
            $track = Add-SidecarTrack $Tracks $script:SubFile ''
            if (-not $track) { Write-Warning "Soubor titulků nelze načíst, titulky vynechávám: $($script:SubFile)"; return $result }
            Update-TrackClassification $Tracks $Duration
            $result.Source = 'track'; $result.Track = $track
        }
        return $result
    }

    # Úrovně v pořadí priority. Jistá je jen úroveň se známým jazykem i druhem.
    $tiers = switch ($AudioChoice.Category) {
        'czech'  { @('cs:forced', 'cs:unknown', 'sk:forced', 'sk:unknown', 'und:forced', 'und:unknown') }
        'slovak' { @('sk:forced', 'cs:forced', 'sk:unknown', 'cs:unknown', 'und:forced', 'und:unknown') }
        default  { @('cs:full', 'sk:full', 'cs:unknown', 'sk:unknown', 'und:full', 'und:unknown') }
    }
    # Neznámý jazyk zvuku: může jít i o český dabing -> i forced stopy jsou kandidáti.
    if (-not $AudioChoice.Sure) { $tiers += @('cs:forced', 'sk:forced', 'und:forced') }

    $all = [System.Collections.Generic.List[object]]::new()
    $firstTier = $null
    $firstTierCount = 0
    foreach ($tier in $tiers) {
        $language, $kind = $tier -split ':'
        $matching = @($subtitles | Where-Object { -not $_.Skip -and $_.Language -eq $language -and $_.Kind -eq $kind })
        # textové stopy první
        foreach ($track in @(@($matching | Where-Object IsText) + @($matching | Where-Object { -not $_.IsText }))) {
            if ($all.Contains($track)) { continue }
            $all.Add($track)
            if (-not $firstTier) { $firstTier = $tier }
            if ($tier -eq $firstTier) { $firstTierCount++ }
        }
    }

    if ($all.Count -eq 0) {
        # Nic vhodného -> ASS vedle videa (z extract-ass.ps1 nebo stažené .cs.ass)
        $found = switch ($AudioChoice.Category) {
            'czech'  { Find-ExternalSubtitle $File 'cs' $true }
            'slovak' { $f = Find-ExternalSubtitle $File 'sk' $true; if (-not $f) { $f = Find-ExternalSubtitle $File 'cs' $true }; $f }
            default  { $f = Find-ExternalSubtitle $File 'cs' $false; if (-not $f) { $f = Find-ExternalSubtitle $File 'sk' $false }; $f }
        }
        if ($found) {
            $track = Add-SidecarTrack $Tracks $found ([IO.Path]::GetFileName($found))
            if ($track) {
                Update-TrackClassification $Tracks $Duration
                $result.Source = 'track'; $result.Track = $track
            }
        }
        return $result
    }

    $result.Source = 'track'
    $result.Track = $all[0]
    if ($firstTier -like 'und:*' -or $firstTier -like '*:unknown' -or $firstTierCount -gt 1 -or -not $AudioChoice.Sure) {
        $result.Sure = $false
        $result.Alt = @($all | Select-Object -Skip 1)
        if ($Profile -eq 'hd10') { $result.Extra = @($result.Alt | Where-Object IsText) }
    }
    return $result
}

function Format-Subtitle($Track) {
    return "$(Get-TrackSpec $Track) ($($Track.Codec), $($Track.Language) $($Track.Kind))"
}

function Show-Tracks($Tracks, $AudioChoice, $SubtitleChoice, $Duration) {
    $header = 'Stopy ve zdroji'
    if ($Duration) { $header += " (délka $([Math]::Floor($Duration / 60)) min)" }
    Write-Host "${header}:"
    foreach ($track in $Tracks) {
        $mark = ' '
        if ($track.Type -eq 'audio') {
            $spec = "a:$($track.Relative)"
            if ($track -eq $AudioChoice.Track) { $mark = '*' }
            if ($AudioChoice.Extra -contains $track) { $mark = '+' }
            $description = "$($track.Language) ($($track.LanguageSource))"
        } else {
            $spec = Get-TrackSpec $track
            if ($SubtitleChoice.Source -eq 'track' -and $track -eq $SubtitleChoice.Track) { $mark = '*' }
            if ($SubtitleChoice.Alt -contains $track) { $mark = '?' }
            if ($SubtitleChoice.Extra -contains $track) { $mark = '+' }
            $description = "$($track.Language) ($($track.LanguageSource)), $($track.Kind) ($($track.KindSource)), $($track.Events) tit."
        }
        if ($track.Skip) { $description += ", vyřazeno: $($track.Skip)" }
        if ($track.File) {
            $charset = if ($track.Charset) { $track.Charset } else { 'UTF-8' }
            Write-Host "  $mark $spec $($track.Codec) kódování=$charset -> $description"
        } else {
            $tag = if ($track.Tag) { $track.Tag } else { '-' }
            Write-Host "  $mark $spec $($track.Codec) jazyk=$tag název=`"$($track.Title)`" -> $description"
        }
    }
    Write-Host '  (* vybráno, + ponecháno jako další nevýchozí stopa, ? další možná správná stopa)'
}

# Rozhodne kopii/parametry audia. Vrací @{ Copy; Kbps; SampleRate }.
function Get-AudioPlan($Stream) {
    $bitrate = Get-StreamBitrate $Stream
    $channels = 0; $sampleRate = 0
    $property = $Stream.PSObject.Properties['channels']
    if ($property -and $property.Value) { $channels = [int]$property.Value }
    $property = $Stream.PSObject.Properties['sample_rate']
    if ($property -and $property.Value) { $sampleRate = [int]$property.Value }

    $copy = $Stream.codec_name -in @('ac3', 'mp3') -and $channels -gt 0 -and $channels -le 2 -and
        $sampleRate -gt 0 -and $sampleRate -le 48000 -and $bitrate -and $bitrate -le 384000
    $target = if ($Profile -eq 'hd10') { 160 } else { 384 }
    if ($bitrate -and [Math]::Floor($bitrate / 1000) -lt $target) { $target = [Math]::Floor($bitrate / 1000) }
    $rate = if ($sampleRate -gt 0 -and $sampleRate -lt 48000) { $sampleRate } else { 48000 }
    return @{ Copy = $copy; Kbps = $target; SampleRate = $rate }
}

# Jazyk do metadat výstupní stopy, pokud byl zjištěn z názvu a tag zdroje je jiný.
function Get-LanguageFixArguments([string] $Spec, $Track) {
    if (-not $Track -or ($Track.LanguageSource -notlike 'název*' -and -not $Track.File)) { return @() }
    $iso = Get-Iso3 $Track.Language
    if (-not $iso) { return @() }
    return @("-metadata:s:$Spec", "language=$iso")
}

function Get-Crop([string] $File, $Probe) {
    $duration = 0.0
    $durationProperty = $Probe.format.PSObject.Properties['duration']
    if ($durationProperty -and $durationProperty.Value) { $duration = [double]$durationProperty.Value }
    $start = if ($duration -gt 0) { [Math]::Round($duration * 0.35) } else { 60 }
    $output = & ffmpeg -hide_banner -ss $start -i $File -vf 'cropdetect=round=2' -frames:v 300 -an -f null - 2>&1
    $matches = [regex]::Matches(($output -join "`n"), 'crop=\d+:\d+:\d+:\d+')
    if ($matches.Count) { return $matches[$matches.Count - 1].Value }
    return $null
}

function Get-TargetVideoKbps([string] $Name) {
    switch ($Name) { 'standard' { 2000 } 'akcni' { 2500 } 'serialy' { 1600 } default { $null } }
}

# Nestačí ověřit, že sestavení FFmpeg enkodér uvádí. Krátký jednookénkový
# encode současně prověří ovladač a skutečné schopnosti instalované GPU.
$script:NvencTests = @{}
function Test-NvencEncoder([string] $Encoder, [bool] $Main10) {
    $key = "$Encoder/$Main10"
    if ($script:NvencTests.ContainsKey($key)) { return $script:NvencTests[$key] }

    $arguments = @(
        '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=c=black:s=128x128:r=1',
        '-frames:v', '1', '-an'
    )
    if ($Main10) { $arguments += @('-vf', 'format=p010le') }
    $arguments += @('-c:v', $Encoder, '-preset', 'p5')
    if ($Main10) { $arguments += @('-profile:v', 'main10', '-pix_fmt', 'p010le') }
    $arguments += @('-f', 'null', '-')

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & ffmpeg @arguments 2>&1
        $supported = ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $script:NvencTests[$key] = $supported
    return $supported
}

function Resolve-VideoBackend([string] $Requested, [string] $SelectedProfile) {
    if ($Requested -eq 'Cpu') { return 'Cpu' }

    $main10 = ($SelectedProfile -eq 'hd10')
    $encoder = if ($main10) { 'hevc_nvenc' } else { 'h264_nvenc' }
    if (Test-NvencEncoder $encoder $main10) { return 'Nvidia' }

    if ($Requested -eq 'Nvidia') {
        if ($main10) {
            throw "NVENC pro HEVC Main10 není dostupný. GTX 980M jej nepodporuje; použijte -Hardware Cpu nebo Auto."
        }
        throw "Enkodér $encoder není funkční. Zkontrolujte NVIDIA ovladač a sestavení FFmpeg."
    }

    if ($main10) {
        Write-Warning 'NVENC pro HEVC Main10 není dostupný; profil hd10 použije CPU (libx265).'
    } else {
        Write-Warning 'NVENC pro H.264 není dostupný; konverze použije CPU (libx264).'
    }
    return 'Cpu'
}

# --- Kontrola parametrů ruční volby ------------------------------------------
$script:AudioIndex = $null
if ($Audio) {
    if ($Audio -notmatch '^\d+$') { throw "-Audio očekává číslo stopy (a:N), např. -Audio 1." }
    $script:AudioIndex = [int]$Audio
}
$script:AudioCategory = $null
if ($AudioLang) {
    switch -regex ($AudioLang.ToLowerInvariant()) {
        '^(cs|cz|cze|ces|cesky|czech)$' { $script:AudioCategory = 'czech' }
        '^(sk|slk|slo|slovensky|slovak)$' { $script:AudioCategory = 'slovak' }
        '^(cizi|foreign|en|eng|other|jiny)$' { $script:AudioCategory = 'foreign' }
        default { throw "Neznámá hodnota -AudioLang: $AudioLang (povolené: cs sk cizi)." }
    }
}
$script:SubFile = $null
if ($Sub -and $Sub -ne 'none' -and $Sub -notmatch '^\d+$') {
    if (-not (Test-Path -LiteralPath $Sub -PathType Leaf)) { throw "Soubor titulků neexistuje: $Sub" }
    $script:SubFile = (Resolve-Path -LiteralPath $Sub).ProviderPath
}

# Potřebné kodeky; vypalování titulků navíc libass (hd10 titulky nevypaluje).
$ffmpegProblems = if ($Profile -eq 'hd10') { @(Get-FfmpegProblems -Filters @()) } else { @(Get-FfmpegProblems) }
if ($ffmpegProblems.Count) {
    throw "FFmpeg nevyhovuje, chybí: $($ffmpegProblems -join ', '). $($script:FfmpegHint)"
}

$videoBackend = Resolve-VideoBackend $Hardware $Profile
Write-Host "Kódování videa: $videoBackend (požadováno: $Hardware)"

$outputsDone = @{}
foreach ($file in (Get-MediaFiles $Path)) {
    Write-Host "`n=== $file ==="
    if (-not $DryRun -and $KeepAss -and $Profile -ne 'hd10') {
        & "$PSScriptRoot\extract-ass.ps1" -Path $file
        if (-not $?) { Write-Warning "Extrakce titulků selhala pro: $file" }
    }

    $probe = Get-Probe $file -CountPackets
    # první video bez obalu/miniatury (attached_pic), které mají MP4/MOV/M4V
    $video = @($probe.streams | Where-Object { $_.codec_type -eq 'video' -and -not (Get-Disposition $_ 'attached_pic') })[0]
    if (-not $video) { Write-Warning 'Soubor nemá video stopu; přeskakuji.'; continue }
    $tracks = Get-TrackInfo $probe $file
    $duration = Get-ProbeDuration $probe
    $audioChoice = Select-Audio $tracks
    if (-not $audioChoice) { Write-Warning 'Soubor nemá audio stopu; přeskakuji.'; continue }
    $subtitle = Select-Subtitle $tracks $audioChoice $file $duration

    # Obrazové titulky ze souboru (VobSub .idx/.sub) zatím neumíme použít.
    if ($subtitle.Source -eq 'track' -and $subtitle.Track.File -and -not $subtitle.Track.IsText) {
        Write-Warning "Obrazové titulky ze souboru ($($subtitle.Track.Codec)) nejsou podporované: $($subtitle.Track.File)"
        $subtitle.Source = $null
    }

    # Vypalování: ass = textové titulky přes filtr ass,
    # image = obrazové titulky zdroje (PGS/VobSub) přes overlay.
    $burn = $null
    if ($Profile -ne 'hd10' -and $subtitle.Source -eq 'track') {
        $burn = if ($subtitle.Track.IsText) { 'ass' } else { 'image' }
    }

    Show-Tracks $tracks $audioChoice $subtitle $duration
    $audioTracks = @($audioChoice.Track) + @($audioChoice.Extra)

    Write-Host "Audio: a:$($audioChoice.Index) (kategorie: $($audioChoice.Category))"
    if (-not $audioChoice.Sure) {
        Write-Warning "Jazyk zvuku a:$($audioChoice.Index) není určen, beru ho jako cizí (plné titulky). Pro český zvuk použijte -AudioLang cs, pro jinou stopu -Audio N."
    }
    if ($audioChoice.Extra.Count) {
        Write-Warning "Ponechávám i audio stopy s neurčeným jazykem (nevýchozí): $((@($audioChoice.Extra) | ForEach-Object { "a:$($_.Relative)" }) -join ' ')"
    }
    switch ($subtitle.Source) {
        'track' {
            $description = Format-Subtitle $subtitle.Track
            if ($Profile -eq 'hd10') { Write-Host "Titulky (vložit jako výchozí): $description" }
            elseif ($burn -eq 'image') { Write-Host "Titulky (vypálit obrazové, bez ořezu černých pruhů): $description" }
            else { Write-Host "Titulky (vypálit): $description" }
        }
        default { Write-Host 'Titulky: žádné' }
    }
    if (-not $subtitle.Sure) {
        Write-Warning 'Výběr titulků není jistý. Ruční volba: -Sub N | -Sub soubor | -Sub none (případně -AudioLang cs|sk|cizi).'
    }
    $alternatives = (@($subtitle.Alt) | ForEach-Object { Format-Subtitle $_ }) -join ', '
    if ($subtitle.Extra.Count) { Write-Host "Další možné titulky ponechány jako nevýchozí stopy: $alternatives" }
    elseif ($alternatives) { Write-Host "Další možné titulky (vybrat přes -Sub N nebo -Sub soubor): $alternatives" }

    $directory = [IO.Path]::GetDirectoryName($file)
    $targetDirectory = if ($OutDir) { [IO.Path]::GetFullPath($OutDir) } else { Join-Path $directory 'tv' }
    $output = Join-Path $targetDirectory "$([IO.Path]::GetFileNameWithoutExtension($file)).mp4"
    if ([IO.Path]::GetFullPath($output) -eq [IO.Path]::GetFullPath($file)) { throw "Výstup by přepsal vstup: $output" }
    # např. film.avi a film.mkv ve stejné složce -> stejný tv\film.mp4
    $outputKey = [IO.Path]::GetFullPath($output).ToLowerInvariant()
    if ($outputsDone.ContainsKey($outputKey)) {
        Write-Warning "Výstup $output už v tomto běhu vznikl z $($outputsDone[$outputKey]), přeskakuji: $file"
        continue
    }
    $outputsDone[$outputKey] = $file
    Write-Host "Profil: $Profile -> $output"
    if ($DryRun) { Write-Host "Hardware: $videoBackend`n(dry-run: extrakce, cropdetect a konverze přeskočeny)"; continue }

    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    $temporaryDirectory = $null
    try {
        # ASCII-safe ASS v dočasném adresáři kvůli escapování v ass filtru
        $safeSubtitle = $null
        if ($burn -eq 'ass') {
            $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "video-convertor-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
            $safeSubtitle = Join-Path $temporaryDirectory 'sub.ass'
            try {
                if ($subtitle.Track.File -and $subtitle.Track.Codec -in @('ass', 'ssa')) {
                    # vlastní ASS/SSA (stažené, ručně upravené) se použije beze změny stylu
                    Copy-Item -LiteralPath $subtitle.Track.File -Destination $safeSubtitle
                } else {
                    $source = if ($subtitle.Track.File) {
                        @(Get-SidecarInputArguments $subtitle.Track $video) + @('-i', $subtitle.Track.File)
                    } else { @('-i', $file, '-map', "0:$($subtitle.Track.Index)") }
                    Invoke-Native ffmpeg (@('-y', '-v', 'error') + $source + @('-c:s', 'ass', $safeSubtitle))
                    Set-AssDefaultStyle $safeSubtitle
                }
            } catch {
                Write-Warning "Titulky se nepodařilo připravit k vypálení, pokračuji bez nich: $_"
                $burn = $null
                $safeSubtitle = $null
            }
        }

        # Obrazové titulky bývají v černých pruzích -> neořezávat.
        $crop = $null
        if ($burn -ne 'image') {
            $crop = Get-Crop $file $probe
            if ($crop) { Write-Host "Cropdetect: $crop" }
        }
        $videoBitrate = Get-StreamBitrate $video
        $targetKbps = Get-TargetVideoKbps $Profile
        $tenBit = "$($video.pix_fmt)" -match '10(le|be)'
        $realCrop = $false
        if ($crop -and $crop -match '^crop=(\d+):(\d+):(\d+):(\d+)$') {
            $realCrop = ([int]$Matches[1] -ne [int]$video.width -or [int]$Matches[2] -ne [int]$video.height -or [int]$Matches[3] -ne 0 -or [int]$Matches[4] -ne 0)
        }
        $videoCopy = -not $burn -and -not $realCrop -and [int]$video.width -le 1280 -and [int]$video.height -le 720
        if ($Profile -eq 'hd10') {
            $videoCopy = $videoCopy -and $video.codec_name -eq 'hevc' -and $tenBit
        } else {
            $videoCopy = $videoCopy -and $video.codec_name -eq 'h264' -and $videoBitrate -and $videoBitrate -le ($targetKbps * 1000)
        }

        $args = @('-hide_banner', '-y')
        # AVI často nemá časové značky pro kopírování videa do MP4 -> dopočítat
        if ([IO.Path]::GetExtension($file) -eq '.avi') { $args += @('-fflags', '+genpts') }
        $args += @('-i', $file)

        # Titulkové stopy do MP4 (mov_text): v hd10 vybraná stopa jako výchozí,
        # dále případné další možné stopy jako nevýchozí. Obrazové titulky MP4
        # nepodporuje. Titulky ze souborů jsou další vstupy FFmpeg.
        $subtitleOutputs = @()
        $subtitleDefault = $false
        if ($Profile -eq 'hd10' -and $subtitle.Source -eq 'track') {
            if ($subtitle.Track.IsText) { $subtitleOutputs += $subtitle.Track; $subtitleDefault = $true }
            else { Write-Warning "Obrázkové titulky '$($subtitle.Track.Codec)' nelze vložit do MP4." }
        }
        $subtitleOutputs += @($subtitle.Extra)
        $subtitleMaps = @()
        $inputIndex = 1
        foreach ($track in $subtitleOutputs) {
            if ($track.File) {
                $args += @(Get-SidecarInputArguments $track $video) + @('-i', $track.File)
                $subtitleMaps += "${inputIndex}:0"
                $inputIndex++
            } else {
                $subtitleMaps += "0:s:$($track.Relative)"
            }
        }

        $filters = @()
        if (-not $videoCopy) {
            if ($crop) { $filters += $crop }
            $filters += "scale='min(1280,iw)':'min(720,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
            if ($safeSubtitle) {
                $escaped = $safeSubtitle.Replace('\', '/').Replace(':', '\:').Replace("'", "\'")
                $filters += "ass=filename='$escaped'"
            }
            if ($videoBackend -eq 'Nvidia') {
                if ($Profile -eq 'hd10') { $filters += 'format=p010le' } else { $filters += 'format=yuv420p' }
            }
        }
        if ($burn -eq 'image') {
            $args += @('-filter_complex', "[0:V:0][0:s:$($subtitle.Track.Relative)]overlay=eof_action=pass,$($filters -join ',')[vout]", '-map', '[vout]')
        } else {
            $args += @('-map', '0:V:0')
        }
        foreach ($track in $audioTracks) { $args += @('-map', "0:a:$($track.Relative)") }

        foreach ($map in $subtitleMaps) { $args += @('-map', $map) }

        if ($videoCopy) {
            $args += @('-c:v', 'copy')
            if ($Profile -eq 'hd10') { $args += @('-tag:v', 'hvc1') }
            Write-Host 'Video: kopie'
        } else {
            if ($burn -ne 'image') { $args += @('-vf', ($filters -join ',')) }
            if ($Profile -eq 'hd10') {
                $crf = [Math]::Max(0, [Math]::Min(51, 51 - [Math]::Floor($Cq * 31 / 100)))
                if ($videoBackend -eq 'Nvidia') {
                    $args += @('-c:v', 'hevc_nvenc', '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr', '-cq', "$crf", '-b:v', '0', '-profile:v', 'main10', '-pix_fmt', 'p010le', '-tag:v', 'hvc1')
                } else {
                    $args += @('-c:v', 'libx265', '-preset', 'medium', '-crf', "$crf", '-profile:v', 'main10', '-pix_fmt', 'yuv420p10le', '-tag:v', 'hvc1')
                }
                if ($videoBitrate) { $kbps = [Math]::Floor($videoBitrate / 1000); $args += @('-maxrate', "${kbps}k", '-bufsize', "$($kbps * 2)k") }
            } else {
                $effective = $targetKbps
                if ($videoBitrate -and [Math]::Floor($videoBitrate / 1000) -lt $effective) { $effective = [Math]::Floor($videoBitrate / 1000) }
                if ($videoBackend -eq 'Nvidia') {
                    $args += @('-c:v', 'h264_nvenc', '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr', '-b:v', "${effective}k", '-maxrate', "${effective}k", '-bufsize', "$($effective * 2)k", '-profile:v', 'high', '-level', '3.1')
                } else {
                    $args += @('-c:v', 'libx264', '-preset', 'medium', '-b:v', "${effective}k", '-profile:v', 'high', '-level', '31')
                }
            }
            Write-Host "Video: překódovat ($videoBackend)"
        }

        $k = 0
        foreach ($track in $audioTracks) {
            $plan = Get-AudioPlan $track.Stream
            if ($plan.Copy) {
                $args += @("-c:a:$k", 'copy')
                Write-Host "Audio a:$($track.Relative): kopie"
            } else {
                $codec = if ($Profile -eq 'hd10') { 'aac' } else { 'ac3' }
                $args += @("-c:a:$k", $codec, "-b:a:$k", "$($plan.Kbps)k", "-ac:a:$k", '2', "-ar:a:$k", "$($plan.SampleRate)")
                Write-Host "Audio a:$($track.Relative): překódovat -> $($plan.Kbps)k @ $($plan.SampleRate) Hz"
            }
            $disposition = if ($k -eq 0) { 'default' } else { '0' }
            $args += @("-disposition:a:$k", $disposition)
            $args += Get-LanguageFixArguments "a:$k" $track
            $k++
        }

        if ($subtitleOutputs.Count) {
            $args += @('-c:s', 'mov_text')
            $k = 0
            foreach ($track in $subtitleOutputs) {
                $disposition = if ($k -eq 0 -and $subtitleDefault) { 'default' } else { '0' }
                $args += @("-disposition:s:$k", $disposition)
                $args += Get-LanguageFixArguments "s:$k" $track
                $k++
            }
        }
        $args += @('-map_chapters', '-1', '-map_metadata', '0', '-movflags', '+faststart', $output)
        Invoke-Native ffmpeg $args
        Write-Host "Konverze hotová: $output"
    } finally {
        if ($temporaryDirectory -and (Test-Path -LiteralPath $temporaryDirectory)) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }

    if (-not $NoFixOffset) {
        & "$PSScriptRoot\fix-audio-offsets.ps1" -Threshold $Threshold -Path $output
        if (-not $?) { Write-Warning "Oprava audio offsetu selhala pro: $output" }
    }
}
