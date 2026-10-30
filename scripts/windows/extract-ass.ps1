# Video convertor pro TV – Jan Čejka, https://dev.jancejka.cz
# https://github.com/Cuchulain/video-convertor (licence MIT)

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Path = @((Get-Location).Path)
)

. "$PSScriptRoot\VideoTools.ps1"
Assert-VideoTools

function Get-SafeLabel([string] $Title, [string] $Fallback) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $Fallback }
    $label = ((ConvertTo-NormalizedText $Title).Trim() -replace ' +', '-')
    if ($label) { return $label }
    return $Fallback
}

# Jazyk i druh (forced/full) určuje heuristika Get-TrackInfo, takže se vytáhnou
# i stopy se špatným tagem, ale s "CZ"/"čeština" v názvu, a forced stopy bez
# příznaku dostanou "force" v labelu.
foreach ($file in (Get-MediaFiles $Path)) {
    $tracks = Get-TrackInfo (Get-Probe $file -CountPackets)
    foreach ($language in @(
        @{ Code = 'cs'; Name = 'české' },
        @{ Code = 'sk'; Name = 'slovenské' }
    )) {
        $used = @{}
        $found = $false
        foreach ($track in @($tracks | Where-Object { $_.Type -eq 'subtitle' -and $_.Language -eq $language.Code -and -not $_.Skip })) {
            $found = $true
            if (-not $track.IsText) {
                Write-Host "[$file] Titulky #$($track.Index) jsou obrazové ($($track.Codec)), do ASS je nelze převést."
                continue
            }
            $forced = ($track.Kind -eq 'forced')
            $fallback = if ($forced) { 'force' } else { 'full' }
            $label = Get-SafeLabel $track.Title $fallback
            if ($forced -and $label -notmatch 'forc') { $label = "force-$label" }
            $baseLabel = $label
            $counter = 2
            while ($used.ContainsKey($label)) { $label = "$baseLabel-$counter"; $counter++ }
            $used[$label] = $true

            $directory = [IO.Path]::GetDirectoryName($file)
            $name = [IO.Path]::GetFileNameWithoutExtension($file)
            $output = Join-Path $directory "$name.$label.$($language.Code).ass"
            Write-Host "[$file] Titulky #$($track.Index) ($($track.Kind)) -> $output"
            Invoke-Native ffmpeg @('-y', '-v', 'error', '-i', $file, '-map', "0:$($track.Index)", '-c:s', 'ass', $output)
            Set-AssDefaultStyle $output
        }
        if (-not $found) { Write-Host "[$file] Nenalezeny $($language.Name) titulky." }
    }
}
