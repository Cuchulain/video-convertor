# Zkontroluje FFmpeg (ffmpeg, ffprobe, potřebné kodeky a libass). Pokud chybí
# nebo nevyhovuje, stáhne ověřené sestavení z gyan.dev do složky ffmpeg
# v kořeni programu; skripty ho tam najdou samy (VideoTools.ps1).
# Volá ho instalátor a spouštěč ffmpeg-setup.cmd.
#
# Návratové kódy: 0 = FFmpeg vyhovuje / nainstalován, 1 = nevyhovuje (-CheckOnly),
# 2 = stažení nebo instalace selhaly.
[CmdletBinding()]
param(
    # Kam FFmpeg nainstalovat (výchozí: složka ffmpeg vedle složky tools).
    [string] $InstallDir,
    # Jen zkontrolovat, nic nestahovat.
    [switch] $CheckOnly,
    # Stáhnout, i když dostupný FFmpeg vyhovuje.
    [switch] $Force,
    # Použít předem stažený zip (instalace bez internetu); musí odpovídat
    # pevně zadané verzi a kontrolnímu součtu.
    [string] $ZipPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\windows\VideoTools.ps1"

# Pevně zadaná verze (reprodukovatelná a ověřená), při nedostupnosti záloha
# na aktuální release s kontrolním součtem ze serveru.
$PinnedVersion = '9.0.2'
$PinnedUrl = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-$PinnedVersion-essentials_build.zip"
$PinnedSha256 = '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba'
$LatestUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
$Marker = '.video-convertor'

if (-not $InstallDir) { $InstallDir = Join-Path $PSScriptRoot '..\ffmpeg' }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)

# Stáhne soubor a průběžně vypisuje průběh (instalátor ho zobrazuje v detailech).
function Save-Download([string] $Url, [string] $Destination) {
    Write-Host "Stahuji $Url"
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'video-convertor'
    $response = $request.GetResponse()
    try {
        $total = $response.ContentLength
        $stream = $response.GetResponseStream()
        $file = [IO.File]::Create($Destination)
        try {
            $buffer = New-Object byte[] 1048576
            $done = 0
            $reported = -10
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $file.Write($buffer, 0, $read)
                $done += $read
                if ($total -gt 0) {
                    $percent = [int][Math]::Floor($done * 100 / $total)
                    if ($percent -ge $reported + 10) {
                        Write-Host ("  {0} % ({1} / {2} MB)" -f $percent, [int]($done / 1MB), [int]($total / 1MB))
                        $reported = $percent
                    }
                }
            }
        } finally {
            $file.Close()
            $stream.Close()
        }
    } finally {
        $response.Close()
    }
}

function Assert-Sha256([string] $File, [string] $Expected) {
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    if ($actual -ne $Expected) {
        throw "Kontrolní součet nesouhlasí (očekáváno $Expected, staženo $actual)."
    }
    Write-Host 'Kontrolní součet SHA-256 souhlasí.'
}

# --- Kontrola ---------------------------------------------------------------

if (-not $Force) {
    $problems = @(Get-FfmpegProblems)
    if (-not $problems.Count) {
        Write-Host "FFmpeg vyhovuje: $((Get-Command ffmpeg).Source)"
        exit 0
    }
    Write-Host "FFmpeg nevyhovuje: $($problems -join ', ')"
}
if ($CheckOnly) { exit 1 }

# --- Stažení a instalace ----------------------------------------------------

$temporary = Join-Path ([IO.Path]::GetTempPath()) "video-convertor-ffmpeg-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $zip = Join-Path $temporary 'ffmpeg.zip'
    if ($ZipPath) {
        Copy-Item -LiteralPath $ZipPath -Destination $zip
        Assert-Sha256 $zip $PinnedSha256
    } else {
        # Windows PowerShell 5.1 má ve výchozím stavu vypnuté TLS 1.2.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            Save-Download $PinnedUrl $zip
            Assert-Sha256 $zip $PinnedSha256
        } catch {
            Write-Warning "Verze $PinnedVersion není dostupná ($($_.Exception.Message)), zkouším aktuální release."
            Save-Download "$LatestUrl.sha256" (Join-Path $temporary 'ffmpeg.zip.sha256')
            $expected = ((Get-Content -LiteralPath (Join-Path $temporary 'ffmpeg.zip.sha256') -Raw) -split '\s+')[0].Trim()
            Save-Download $LatestUrl $zip
            Assert-Sha256 $zip $expected
        }
    }

    Write-Host 'Rozbaluji…'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extracted = Join-Path $temporary 'x'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $extracted)
    $root = @(Get-ChildItem -LiteralPath $extracted -Directory)[0]
    if (-not $root) { throw 'Archiv nemá očekávanou strukturu.' }
    $bin = Join-Path $root.FullName 'bin'
    # ffplay skripty nepotřebují (ušetří ~100 MB)
    Remove-Item -LiteralPath (Join-Path $bin 'ffplay.exe') -ErrorAction SilentlyContinue

    $problems = @(Get-FfmpegProblems -Ffmpeg (Join-Path $bin 'ffmpeg.exe') -Ffprobe (Join-Path $bin 'ffprobe.exe'))
    if ($problems.Count) { throw "Stažený FFmpeg nevyhovuje: $($problems -join ', ')" }

    if (Test-Path -LiteralPath $InstallDir) {
        # Smazat jen složku, kterou vytvořil tento skript (značka), nikdy cizí.
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDir $Marker))) {
            throw "Složka $InstallDir už existuje a nevytvořil ji tento instalátor; přeskočeno."
        }
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($InstallDir)) -Force | Out-Null
    Move-Item -LiteralPath $root.FullName -Destination $InstallDir
    Set-Content -LiteralPath (Join-Path $InstallDir $Marker) -Value "FFmpeg $($root.Name) nainstalovaný video-convertorem" -Encoding UTF8
    Write-Host "FFmpeg nainstalován do $InstallDir"
    exit 0
} catch {
    Write-Host "CHYBA: $($_.Exception.Message)"
    exit 2
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
}
