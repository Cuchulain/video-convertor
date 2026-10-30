[CmdletBinding()]
param(
    [switch] $DryRun,
    [double] $Threshold = 0.050,
    [Parameter(Position = 0, Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]] $Path
)

. "$PSScriptRoot\VideoTools.ps1"
Assert-VideoTools

foreach ($file in (Get-MediaFiles $Path)) {
    Write-Host "`n=== $file ==="
    $probe = Get-Probe $file
    $audio = @($probe.streams | Where-Object codec_type -eq 'audio')
    if ($audio.Count -eq 0) { Write-Host 'Soubor nemá audio stopy.'; continue }

    $fix = @()
    for ($i = 0; $i -lt $audio.Count; $i++) {
        $startProperty = $audio[$i].PSObject.Properties['start_time']
        $start = if ($startProperty -and $null -ne $startProperty.Value) { [double]$startProperty.Value } else { 0.0 }
        $bitrate = Get-StreamBitrate $audio[$i]
        Write-Host ("Audio a:{0} codec={1} start_time={2:F6}" -f $i, $audio[$i].codec_name, $start)
        if ([Math]::Abs($start) -gt $Threshold -and $start -ge 0) {
            $fix += @{ Index = $i; Delay = [Math]::Round($start * 1000); Codec = $audio[$i].codec_name; Bitrate = $bitrate }
        } elseif ($start -lt -$Threshold) {
            Write-Warning "Audio a:$i má záporný offset; stopa nebude upravena."
        }
    }
    if ($fix.Count -eq 0) { Write-Host 'Není co opravovat.'; continue }
    if ($DryRun) {
        $fix | ForEach-Object { Write-Host "a:$($_.Index) -> přidat $($_.Delay) ms ticha" }
        continue
    }

    $directory = [IO.Path]::GetDirectoryName($file)
    $name = [IO.Path]::GetFileNameWithoutExtension($file)
    $extension = [IO.Path]::GetExtension($file)
    $backup = Join-Path $directory "$name.original$extension"
    $temporary = Join-Path $directory "$name.fixed.$PID$extension"
    if (Test-Path -LiteralPath $backup) { Write-Warning "Záloha už existuje: $backup"; continue }

    Move-Item -LiteralPath $file -Destination $backup
    try {
        $args = @('-hide_banner', '-y', '-i', $backup)
        for ($i = 0; $i -lt $audio.Count; $i++) { $args += @('-ignore_editlist', '1', '-i', $backup) }
        $args += @('-map', '0:v?')
        for ($i = 0; $i -lt $audio.Count; $i++) { $args += @('-map', "$(($i + 1)):a:0") }
        $args += @('-map', '0:s?', '-map', '0:d?', '-map_metadata', '0', '-map_chapters', '0', '-c:v', 'copy', '-c:s', 'copy', '-c:d', 'copy')
        for ($i = 0; $i -lt $audio.Count; $i++) {
            $item = $fix | Where-Object Index -eq $i | Select-Object -First 1
            if ($item) {
                $rate = if ($item.Codec -eq 'ac3' -and $item.Bitrate) { $item.Bitrate } else { 384000 }
                $args += @("-filter:a:$i", "adelay=$($item.Delay):all=1,asetpts=PTS-STARTPTS", "-c:a:$i", 'ac3', "-b:a:$i", "$rate")
            } else { $args += @("-c:a:$i", 'copy') }
        }
        $args += @('-avoid_negative_ts', 'make_zero', '-movflags', '+faststart', $temporary)
        Invoke-Native ffmpeg $args
        Move-Item -LiteralPath $temporary -Destination $file
        Remove-Item -LiteralPath $backup
        Write-Host "Hotovo: $file"
    } catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (-not (Test-Path -LiteralPath $file) -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $file
        }
        throw
    }
}
