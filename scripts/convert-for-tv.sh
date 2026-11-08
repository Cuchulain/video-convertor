#!/usr/bin/env bash
set -euo pipefail

# Video convertor pro TV – Jan Čejka, https://dev.jancejka.cz
# https://github.com/Cuchulain/video-convertor (licence MIT)

# Asociativní pole vyžadují Bash 4+; systémový Bash 3.2 na macOS nestačí.
if (( BASH_VERSINFO[0] < 4 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" ${1+"$@"}
  done
  echo "Chyba: je potřeba Bash 4 nebo novější (brew install bash)." >&2
  exit 1
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  PATH="/opt/homebrew/bin:$PATH"
  # ffmpeg-full (s libass pro vypalování ASS titulků) je keg-only -> přednostně
  for d in /usr/local/opt/ffmpeg-full/bin /opt/homebrew/opt/ffmpeg-full/bin; do
    if [[ -d "$d" ]]; then PATH="$d:$PATH"; fi
  done
fi

# C.UTF-8 je běžné na Linuxu, en_US.UTF-8 na macOS. Pokud není dostupné ani
# jedno, ponecháme locale zděděné z prostředí.
if locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx 'c\.utf-8'; then
  export LC_ALL=C.UTF-8 LANG=C.UTF-8
elif locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -Eq '^en_us\.utf-?8$'; then
  export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
fi

# macOS používá VideoToolbox, Linux přenositelné softwarové enkodéry FFmpeg.
VIDEO_BACKEND="${VIDEO_BACKEND:-auto}"
if [[ "$VIDEO_BACKEND" == "auto" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then VIDEO_BACKEND="videotoolbox"; else VIDEO_BACKEND="software"; fi
fi

# convert-for-tv.sh
#
# ffmpeg/ffprobe konvertor videí pro TV (náhrada HandBrake) s HW akcelerací
# (VideoToolbox) na macOS. Orchestruje celý pipeline:
#   1. extract-ass.sh        -> jen s --keep-ass: vytáhne CZ/SK titulky do
#                              .cs.ass / .sk.ass vedle videa (pro jiné přehrávače;
#                              konverze sama vypaluje z dočasné kopie)
#                              (neprovádí se pro profil hd10)
#   2. ffmpeg konverze       -> výběr audia dle jazyka, titulky, škála
#   3. fix-audio-offsets.sh  -> srovná audio offset výsledku
#
# Výběr audia (priorita): čeština -> slovenština -> angličtina -> neurčený
# jazyk -> první stopa. Jazyk se bere z tagu i z názvu stopy (lib/tracks.sh).
# Výběr titulků (ze stop zdroje; když žádná nevyhovuje, z ASS vedle videa):
#   * český zvuk     -> české forced (fallback slovenské forced)
#   * slovenský zvuk -> slovenské forced (fallback české forced)
#   * cizí zvuk      -> české plné (fallback slovenské plné)
#   - standard/akcni/serialy -> vypálí titulky do obrazu (textové přes ASS,
#       obrazové PGS/VobSub přes overlay)
#   - hd10 -> nevypaluje, přidá vybranou stopu do MP4 (mov_text, default)
# Ve sporných případech se další možná správné stopy ponechají jako nevýchozí
# a skript poradí, jak volbu určit ručně (--audio, --audio-lang, --sub).
# Profil cílového zařízení (--device, devices.conf) určí kodek zvuku, co lze
# kopírovat, nejvyšší rozlišení a výstupní složku tv-<zařízení>.

# Skutečná složka skriptu i při spuštění přes symlink (např. ~/bin/convert-for-tv.sh);
# bez readlink -f, které starší macOS nemá.
SCRIPT_SRC="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SRC" ]]; do
  SCRIPT_LINK_DIR="$(cd -P "$(dirname "$SCRIPT_SRC")" && pwd)"
  SCRIPT_SRC="$(readlink "$SCRIPT_SRC")"
  [[ "$SCRIPT_SRC" == /* ]] || SCRIPT_SRC="$SCRIPT_LINK_DIR/$SCRIPT_SRC"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SRC")" && pwd)"

PROFILE="standard"
DRY_RUN="0"
DO_EXTRACT="0"   # --keep-ass
DO_FIX_OFFSET="1"
THRESHOLD="0.050"
OUTDIR=""
CQ="60"   # constant quality pro hd10 (VideoToolbox -q:v, 0-100, vyšší = lepší)
AUDIO_OPT=""       # --audio N (relativní index a:N)
AUDIO_LANG_OPT=""  # --audio-lang -> czech|slovak|foreign
SUB_OPT=""         # --sub N | none | soubor
DEVICE=""          # --device; prázdné = výchozí z konfigurace, jinak hyundai
LIST_DEVICES="0"   # --list-devices
SET_DEVICE=""      # --set-device
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/video-convertor"
declare -A DEV_CONF=()   # "zařízení.klíč" -> hodnota z devices.conf
DEV_NAMES=()             # zařízení v pořadí načtení
declare -A OUTPUTS_DONE=()   # výstup -> vstup, kvůli kolizím názvů v jednom běhu

# shellcheck source=lib/tracks.sh
source "$SCRIPT_DIR/lib/tracks.sh"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Chybí příkaz: $1"; exit 1; }
}

usage() {
  cat <<'EOF'
Použití:
  convert-for-tv.sh [přepínače] soubor1 [soubor2 ... | adresář ...]

Přepínače:
  --profile NAME     standard (výchozí) | akcni | serialy | hd10
  --device NAME      cílové zařízení (viz --list-devices), výchozí z konfigurace
  --list-devices     vypsat profily zařízení a výchozí zařízení
  --set-device NAME  uložit výchozí zařízení do konfigurace a skončit
  --cq N             constant quality pro hd10 (0-100, vyšší = lepší, výchozí 60)
  --threshold SEC    prah pro fix-audio-offsets.sh (výchozí 0.050)
  --outdir DIR       kam ukládat výstupy (výchozí: podadresář "tv-<zařízení>"
                     vedle vstupu)
  --keep-ass         ponechat vedle videa CZ/SK titulky vytažené do .ass
                     (výchozí: nic se nevytváří, vypaluje se z dočasné kopie)
  --no-extract       zastaralé, odpovídá výchozímu chování
  --no-fix-offset    nespouštět fix-audio-offsets.sh
  --dry-run          jen vypsat rozhodnutí, nic nekódovat
  -h, --help         nápověda

Ruční volba stop (pro sporné případy; čísla viz výpis "Stopy ve zdroji"):
  --audio N          použít audio stopu a:N
  --audio-lang L     jazyk vybraného zvuku: cs | sk | cizi
                     (určuje, zda se použijí forced, nebo plné titulky)
  --sub N            použít titulkovou stopu s:N
  --sub SOUBOR       použít titulky ze souboru (.ass, .srt, ...)
  --sub none         bez titulků

Video convertor pro TV – Jan Čejka, https://dev.jancejka.cz
https://github.com/Cuchulain/video-convertor (licence MIT)
EOF
}

# --- Profily zařízení a konfigurace -----------------------------------------
#
# Vestavěné profily jsou v devices.conf vedle skriptu, vlastní v $CONFIG_DIR/
# devices.conf (stejný název profilu přepíše jen uvedené klíče). Výchozí
# zařízení je v $CONFIG_DIR/config (device=nazev). Stejný formát čte VideoTools.ps1.

DEV_KEYS="description audio_codec audio_kbps audio_copy h264_max_level max_width max_height"

# Ořízne mezery na začátku a konci. $1=text, výsledek v _TRIM.
trim() {
  _TRIM="${1#"${1%%[![:space:]]*}"}"
  _TRIM="${_TRIM%"${_TRIM##*[![:space:]]}"}"
}

# Načte profily zařízení do DEV_CONF a DEV_NAMES. $1=soubor (nemusí existovat)
load_devices() {
  local file="$1" line key value section="" n=0
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    trim "${line%$'\r'}"
    line="$_TRIM"
    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    elif [[ "$line" =~ ^\[([a-z0-9][a-z0-9_-]*)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      if [[ -z "${DEV_CONF[$section.]+x}" ]]; then
        DEV_CONF[$section.]=1
        DEV_NAMES+=("$section")
      fi
    elif [[ -n "$section" && "$line" =~ ^([a-z0-9_]+)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      trim "${BASH_REMATCH[2]}"
      value="$_TRIM"
      if [[ " $DEV_KEYS " == *" $key "* ]]; then
        DEV_CONF[$section.$key]="$value"
      else
        warn "$file:$n: neznámý klíč '$key'"
      fi
    else
      warn "$file:$n: neplatný řádek: $line"
    fi
  done <"$file"
}

# Vypíše hodnotu klíče z uživatelské konfigurace. $1=klíč
config_get() {
  local line
  [[ -f "$CONFIG_DIR/config" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    trim "${line%$'\r'}"
    if [[ "$_TRIM" =~ ^$1[[:space:]]*=(.*)$ ]]; then
      trim "${BASH_REMATCH[1]}"
      printf '%s' "$_TRIM"
      return 0
    fi
  done <"$CONFIG_DIR/config"
}

# Uloží klíč do uživatelské konfigurace, ostatní řádky ponechá. $1=klíč $2=hodnota
config_set() {
  local line
  local -a lines=()
  if [[ -f "$CONFIG_DIR/config" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      trim "$line"
      [[ "$_TRIM" =~ ^$1[[:space:]]*= ]] || lines+=("$line")
    done <"$CONFIG_DIR/config"
  else
    lines+=("# Video convertor pro TV – uživatelská konfigurace")
  fi
  lines+=("$1=$2")
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "${lines[@]}" >"$CONFIG_DIR/config"
}

# Hodnota klíče profilu zařízení, chybějící klíč = výchozí (profil hyundai).
# $1=zařízení $2=klíč, výsledek v _DEV.
dev_get() {
  if [[ -n "${DEV_CONF[$1.$2]+x}" ]]; then
    _DEV="${DEV_CONF[$1.$2]}"
    return 0
  fi
  case "$2" in
    audio_codec) _DEV="ac3" ;;
    audio_kbps)  _DEV="384" ;;
    audio_copy)  _DEV="ac3 mp3" ;;
    max_width)   _DEV="1280" ;;
    max_height)  _DEV="720" ;;
    *)           _DEV="" ;;
  esac
}

# Výchozí zařízení: konfigurace, jinak hyundai. Výsledek v _DEV.
default_device() {
  _DEV="$(config_get device)"
  [[ -n "$_DEV" ]] || _DEV="hyundai"
}

# Vypíše profily zařízení (* = výchozí).
list_devices() {
  local d mark
  default_device
  local def="$_DEV"
  log "Profily zařízení (* výchozí):"
  for d in "${DEV_NAMES[@]}"; do
    mark=" "
    [[ "$d" != "$def" ]] || mark="*"
    dev_get "$d" description
    log "  $mark $d – $_DEV"
  done
  log "Konfigurace: $CONFIG_DIR/config (výchozí zařízení), $CONFIG_DIR/devices.conf (vlastní profily)"
}

# Ověří, že zařízení existuje a má platné hodnoty, a nastaví DEV_AUDIO_CODEC,
# DEV_AUDIO_KBPS, DEV_AUDIO_COPY, DEV_H264_MAX_LEVEL, DEV_MAX_W, DEV_MAX_H.
# $1=zařízení
use_device() {
  local d="$1"
  if [[ -z "${DEV_CONF[$d.]+x}" ]]; then
    err "Neznámé zařízení: $d (povolené: ${DEV_NAMES[*]})"
    exit 1
  fi
  dev_get "$d" audio_codec;    DEV_AUDIO_CODEC="$_DEV"
  dev_get "$d" audio_kbps;     DEV_AUDIO_KBPS="$_DEV"
  dev_get "$d" audio_copy;     DEV_AUDIO_COPY="$_DEV"
  dev_get "$d" h264_max_level; DEV_H264_MAX_LEVEL="$_DEV"
  dev_get "$d" max_width;      DEV_MAX_W="$_DEV"
  dev_get "$d" max_height;     DEV_MAX_H="$_DEV"
  case "$DEV_AUDIO_CODEC" in
    ac3|aac) ;;
    *) err "Zařízení $d: audio_codec musí být ac3 nebo aac"; exit 1 ;;
  esac
  local x
  for x in "$DEV_AUDIO_KBPS" "$DEV_MAX_W" "$DEV_MAX_H" "${DEV_H264_MAX_LEVEL:-0}"; do
    [[ "$x" =~ ^[0-9]+$ ]] || { err "Zařízení $d: neplatná číselná hodnota '$x'"; exit 1; }
  done
}

# Level H.264 pro kódování: 3.1 stačí do 1280x720, větší obraz potřebuje 4.1.
h264_level() {
  if (( DEV_MAX_W > 1280 || DEV_MAX_H > 720 )); then printf '41'; else printf '31'; fi
}

# --- Výběr stop -------------------------------------------------------------
#
# Jazyk a druh stop určuje heuristika v lib/tracks.sh (probe_tracks), která
# kromě metadat bere v úvahu i název stopy a počet titulků.

# Kategorie zvuku podle jazyka stopy. $1=cs|sk|en|other|und, výsledek v _CAT.
audio_cat_of() {
  case "$1" in
    cs) _CAT="czech" ;;
    sk) _CAT="slovak" ;;
    *)  _CAT="foreign" ;;
  esac
}

# Vybere audio stopu (priorita: čeština -> slovenština -> angličtina ->
# neurčený jazyk -> ostatní; komentáře až nakonec).
# Nastaví SEL_AIDX (a:N), SEL_CAT (czech|slovak|foreign), SEL_CAT_SURE
# (0 = jazyk zvuku není známý) a SEL_AUDIO_EXTRA (další a:N, které mohou být
# správné, např. neurčená stopa vedle anglické -> ponechají se jako nevýchozí).
select_audio() {
  SEL_AIDX=""
  SEL_CAT=""
  SEL_CAT_SURE=1
  SEL_AUDIO_EXTRA=()
  local i want pick=""

  if [[ -n "$AUDIO_OPT" ]]; then
    pick="$(trk_find audio "$AUDIO_OPT")"
    if [[ -z "$pick" ]]; then
      err "Audio stopa a:$AUDIO_OPT neexistuje"
      return 1
    fi
  else
    for want in cs sk en und other; do
      for ((i=0; i<TRK_N; i++)); do
        [[ "${TRK_TYPE[i]}" == "audio" && -z "${TRK_SKIP[i]}" && "${TRK_LANG[i]}" == "$want" ]] || continue
        pick="$i"
        break 2
      done
    done
    [[ -n "$pick" ]] || pick="$(trk_find audio 0)"
  fi
  [[ -n "$pick" ]] || return 0

  SEL_AIDX="${TRK_REL[pick]}"
  audio_cat_of "${TRK_LANG[pick]}"
  SEL_CAT="$_CAT"
  [[ "${TRK_LANG[pick]}" != "und" ]] || SEL_CAT_SURE=0
  if [[ -n "$AUDIO_LANG_OPT" ]]; then
    SEL_CAT="$AUDIO_LANG_OPT"
    SEL_CAT_SURE=1
  fi

  if [[ -z "$AUDIO_OPT" && "$SEL_CAT" != "czech" ]]; then
    for ((i=0; i<TRK_N; i++)); do
      [[ "${TRK_TYPE[i]}" == "audio" && "$i" != "$pick" && -z "${TRK_SKIP[i]}" && "${TRK_LANG[i]}" == "und" ]] || continue
      SEL_AUDIO_EXTRA+=("${TRK_REL[i]}")
    done
  fi
}

# Najde ASS soubor vedle videa pro daný jazyk a druh. $1=dir $2=name
# $3=langcode(cs|sk) $4=kind(forced|full). Vypíše cestu nebo nic.
find_sub() {
  local dir="$1" name="$2" langcode="$3" kind="$4"
  local f label label_lc is_forced
  shopt -s nullglob
  for f in "$dir/$name".*."$langcode".ass; do
    label="${f##*/}"
    label="${label#"$name".}"
    label="${label%."$langcode".ass}"
    label_lc="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
    if [[ "$label_lc" == *forc* ]]; then
      is_forced="forced"
    else
      is_forced="full"
    fi
    if [[ "$is_forced" == "$kind" ]]; then
      printf '%s' "$f"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
}

# Vypíše pozice (v polích TRK_*) použitelných titulkových stop daného jazyka
# a druhu, textové stopy první. $1=jazyk $2=druh
sub_candidates() {
  local lang="$1" kind="$2" i pass is_text
  for pass in text image; do
    for ((i=0; i<TRK_N; i++)); do
      [[ "${TRK_TYPE[i]}" == "subtitle" && -z "${TRK_SKIP[i]}" ]] || continue
      [[ "${TRK_LANG[i]}" == "$lang" && "${TRK_KIND[i]}" == "$kind" ]] || continue
      is_text="image"
      trk_is_text_codec "${TRK_CODEC[i]}" && is_text="text"
      [[ "$is_text" == "$pass" ]] || continue
      printf '%s\n' "$i"
    done
  done
}

# Vybere titulky podle SEL_CAT (nebo --sub). Nastaví:
#   SUB_SRC        track|"" (žádné)
#   SEL_SUB_POS    pozice vybrané stopy v polích TRK_* (stopa zdroje nebo
#                  titulky ze souboru vedle videa, viz TRK_FILE)
#   SEL_SUB_SURE   0 = výběr není jistý
#   SEL_SUB_ALT    pozice dalších možná správných stop (pro výpis)
#   SEL_SUB_EXTRA  z nich textové stopy, které se vloží jako nevýchozí (jen hd10;
#                  MP4 muxer by první titulkovou stopu vždy označil jako
#                  zapnutou, takže u vypalovacích profilů by se zobrazila
#                  přes vypálené titulky)
# $1=dir $2=name
select_subtitles() {
  local dir="$1" name="$2"
  SUB_SRC=""
  SEL_SUB_POS=""
  SEL_SUB_SURE=1
  SEL_SUB_ALT=()
  SEL_SUB_EXTRA=()

  case "$SUB_OPT" in
    none) return 0 ;;
    '') ;;
    *)
      if [[ "$SUB_OPT" =~ ^[0-9]+$ ]]; then
        SEL_SUB_POS="$(trk_find subtitle "$SUB_OPT")"
        if [[ -z "$SEL_SUB_POS" ]]; then
          warn "Titulková stopa s:$SUB_OPT neexistuje, titulky vynechávám"
          return 0
        fi
        SUB_SRC="track"
      else
        if ! trk_add_sidecar "$SUB_OPT" ""; then
          warn "Soubor titulků nelze načíst, titulky vynechávám: $SUB_OPT"
          return 0
        fi
        SEL_SUB_POS="$_TRK_POS"
        trk_classify
        SUB_SRC="track"
      fi
      return 0
      ;;
  esac

  # Úrovně v pořadí priority. Jistá je jen úroveň se známým jazykem i druhem.
  local -a tiers=()
  case "$SEL_CAT" in
    czech)   tiers=(cs:forced cs:unknown sk:forced sk:unknown und:forced und:unknown) ;;
    slovak)  tiers=(sk:forced cs:forced sk:unknown cs:unknown und:forced und:unknown) ;;
    foreign) tiers=(cs:full sk:full cs:unknown sk:unknown und:full und:unknown) ;;
  esac
  # Neznámý jazyk zvuku: může jít i o český dabing, takže forced stopy jsou
  # také kandidáti (ponechají se jako nevýchozí).
  [[ "$SEL_CAT_SURE" == "1" ]] || tiers+=(cs:forced sk:forced und:forced)

  local t c first_tier="" first_tier_count=0
  local -a all=()
  local -A seen=()
  for t in "${tiers[@]}"; do
    while IFS= read -r c; do
      [[ -n "$c" && -z "${seen[$c]+x}" ]] || continue
      seen[$c]=1
      all+=("$c")
      [[ -n "$first_tier" ]] || first_tier="$t"
      [[ "$t" != "$first_tier" ]] || first_tier_count=$((first_tier_count + 1))
    done < <(sub_candidates "${t%%:*}" "${t#*:}")
  done

  if [[ ${#all[@]} -eq 0 ]]; then
    # Nic vhodného -> ASS vedle videa (z extract-ass.sh nebo stažené .cs.ass)
    local ass=""
    case "$SEL_CAT" in
      czech)
        ass="$(find_sub "$dir" "$name" cs forced)"
        ;;
      slovak)
        ass="$(find_sub "$dir" "$name" sk forced)"
        [[ -n "$ass" ]] || ass="$(find_sub "$dir" "$name" cs forced)"
        ;;
      foreign)
        ass="$(find_sub "$dir" "$name" cs full)"
        [[ -n "$ass" ]] || ass="$(find_sub "$dir" "$name" sk full)"
        ;;
    esac
    if [[ -n "$ass" ]] && trk_add_sidecar "$ass" "${ass##*/}"; then
      SEL_SUB_POS="$_TRK_POS"
      trk_classify
      SUB_SRC="track"
    fi
    return 0
  fi

  SUB_SRC="track"
  SEL_SUB_POS="${all[0]}"
  if [[ "$first_tier" == und:* || "$first_tier" == *:unknown \
        || "$first_tier_count" -gt 1 || "$SEL_CAT_SURE" != "1" ]]; then
    SEL_SUB_SURE=0
    SEL_SUB_ALT=("${all[@]:1}")
    if [[ "$PROFILE" == "hd10" ]]; then
      for c in "${SEL_SUB_ALT[@]}"; do
        trk_is_text_codec "${TRK_CODEC[c]}" && SEL_SUB_EXTRA+=("$c")
      done
    fi
  fi
}

# Vypíše přehled audio a titulkových stop s výsledkem heuristiky.
print_tracks() {
  local i mark spec desc x
  log "Stopy ve zdroji${TRK_DURATION:+ (délka $(( TRK_DURATION / 60 )) min)}:"
  for ((i=0; i<TRK_N; i++)); do
    mark=" "
    if [[ "${TRK_TYPE[i]}" == "audio" ]]; then
      spec="a:${TRK_REL[i]}"
      [[ "${TRK_REL[i]}" != "$SEL_AIDX" ]] || mark="*"
      for x in "${SEL_AUDIO_EXTRA[@]}"; do [[ "$x" != "${TRK_REL[i]}" ]] || mark="+"; done
      desc="${TRK_LANG[i]} (${TRK_LSRC[i]})"
    else
      spec="$(trk_spec "$i")"
      [[ "$SUB_SRC" != "track" || "$i" != "$SEL_SUB_POS" ]] || mark="*"
      for x in "${SEL_SUB_ALT[@]}"; do [[ "$x" != "$i" ]] || mark="?"; done
      for x in "${SEL_SUB_EXTRA[@]}"; do [[ "$x" != "$i" ]] || mark="+"; done
      desc="${TRK_LANG[i]} (${TRK_LSRC[i]}), ${TRK_KIND[i]} (${TRK_KSRC[i]}), ${TRK_EV[i]} tit."
    fi
    [[ -z "${TRK_SKIP[i]}" ]] || desc+=", vyřazeno: ${TRK_SKIP[i]}"
    if [[ -n "${TRK_FILE[i]}" ]]; then
      log "  $mark $spec ${TRK_CODEC[i]} kódování=${TRK_CHARENC[i]:-UTF-8} -> $desc"
    else
      log "  $mark $spec ${TRK_CODEC[i]} jazyk=${TRK_TAG[i]:--} název=\"${TRK_TITLE[i]}\" -> $desc"
    fi
  done
  log "  (* vybráno, + ponecháno jako další nevýchozí stopa, ? další možná správná stopa)"
}

# --- Sondování proudů + rozhodnutí kopie/překódování ------------------------

# Vrátí jednu hodnotu z ffprobe. $1=file $2=stream_spec(V:0|a:N) $3=entry(stream=...)
# V:0 = první video bez obalu/miniatury (attached_pic), které mají MP4/MOV/M4V.
probe1() {
  ffprobe -v error -select_streams "$2" -show_entries "$3" \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -n1
}

# Bitrate proudu v bps, nebo prázdné (neznámé). $1=file $2=stream_spec
stream_bitrate() {
  local file="$1" spec="$2" v
  v="$(probe1 "$file" "$spec" stream=bit_rate)"
  [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  # MKV (mkvmerge) ukládá bitrate jako tag BPS
  v="$(ffprobe -v error -select_streams "$spec" \
        -show_entries stream_tags=BPS,BPS-eng,BPS-ENG \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -n1)"
  [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  return 0
}

# Cílový video bitrate profilu v kbps (prázdné pro hd10).
profile_video_kbps() {
  case "$PROFILE" in
    standard) printf '2000' ;;
    akcni)    printf '2500' ;;
    serialy)  printf '1600' ;;
    hd10)     printf '' ;;
  esac
}

# Rozhodne, zda lze video kopírovat. Nastaví VIDEO_COPY=0|1. $1=file $2=crop
decide_video() {
  local file="$1" crop="$2"
  VIDEO_COPY=0

  # vypálení titulků -> vždy překódovat (uživatelská výjimka)
  [[ -z "$BURN" ]] || return 0

  local w h codec pf
  w="$(probe1 "$file" V:0 stream=width)"
  h="$(probe1 "$file" V:0 stream=height)"
  codec="$(probe1 "$file" V:0 stream=codec_name)"
  pf="$(probe1 "$file" V:0 stream=pix_fmt)"

  # reálný ořez -> překódovat
  if [[ -n "$crop" ]]; then
    local rest cw ch cx cy
    rest="${crop#crop=}"
    IFS=: read -r cw ch cx cy <<<"$rest"
    if [[ "$cw" != "$w" || "$ch" != "$h" || "$cx" != "0" || "$cy" != "0" ]]; then
      return 0
    fi
  fi

  # nutná škála?
  if [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]]; then
    (( w > DEV_MAX_W || h > DEV_MAX_H )) && return 0
  else
    return 0
  fi

  # kodek dle profilu
  case "$PROFILE" in
    hd10)
      [[ "$codec" == "hevc" ]] || return 0
      case "$pf" in *10le|*10be) ;; *) return 0 ;; esac
      # hd10: bitrate se neřeší (kopie HEVC10 je bezeztrátová a nemůže překročit zdroj)
      ;;
    *)
      [[ "$codec" == "h264" ]] || return 0
      # level nad možnosti zařízení (nebo neznámý) -> překódovat
      if [[ -n "$DEV_H264_MAX_LEVEL" ]]; then
        local lvl
        lvl="$(probe1 "$file" V:0 stream=level)"
        [[ "$lvl" =~ ^[0-9]+$ ]] || return 0
        (( lvl > DEV_H264_MAX_LEVEL )) && return 0
      fi
      local sbr tgt
      sbr="$(stream_bitrate "$file" V:0)"
      tgt="$(profile_video_kbps)"
      if [[ "$sbr" =~ ^[0-9]+$ ]]; then
        (( sbr > tgt * 1000 )) && return 0
      else
        return 0  # neznámý bitrate -> překódovat
      fi
      ;;
  esac

  VIDEO_COPY=1
}

# Při kopii videa zjistí, zda má stálou snímkovou frekvenci, jen s rozkolísanými
# časovými značkami (typicky H.264 z MKV, kde jsou časy v ms: snímky 23,976 fps
# pak mají střídavě 41 a 42 ms). V MP4 takové video nepřehraje např. LG webOS
# 3.0 (tabulka délek snímků nejde zhustit a index celého filmu je pro TV moc
# velký), krátké úseky ano. Časy se pak srovnají na mřížku snímků filtrem setts
# bez překódování. Skutečně proměnná frekvence (každý čas musí ležet do 1/4
# snímku od mřížky a dva snímky nesmí padnout na stejný čas) se nechá být.
# Nastaví VIDEO_TS_SCALE (časová základna 1/N) a VIDEO_TS_STEP (délka snímku
# v ní), nebo prázdné. $1=file
decide_timestamps() {
  local file="$1" rate tb num den tbn tbd verdict k
  VIDEO_TS_SCALE=""
  VIDEO_TS_STEP=""
  rate="$(probe1 "$file" V:0 stream=r_frame_rate)"
  tb="$(probe1 "$file" V:0 stream=time_base)"
  [[ "$rate" =~ ^([0-9]+)/([0-9]+)$ ]] || return 0
  num="${BASH_REMATCH[1]}"
  den="${BASH_REMATCH[2]}"
  [[ "$tb" =~ ^([0-9]+)/([0-9]+)$ ]] || return 0
  tbn="${BASH_REMATCH[1]}"
  tbd="${BASH_REMATCH[2]}"
  (( num > 0 && den > 0 && tbn > 0 && tbd > 0 )) || return 0

  # PTS, protože MKV DTS neukládá
  verdict="$(ffprobe -v error -select_streams V:0 -show_entries packet=pts -of csv=p=0 "$file" 2>/dev/null \
    | awk -F, -v n="$num" -v d="$den" -v a="$tbn" -v b="$tbd" '
        BEGIN { f = d / n }
        $1 ~ /^-?[0-9]+$/ && !bad {
          t = $1 * a / b
          q = t / f
          r = (q >= 0) ? int(q + 0.5) : -int(-q + 0.5)
          dev = t - r * f
          if (dev < 0) dev = -dev
          if (dev > f / 4 || (r in seen)) bad = 1
          seen[r] = 1
          if (dev > 0.0001) jit = 1
        }
        END { if (bad) print "vfr"; else if (jit) print "jitter"; else print "ok" }' || true)"
  [[ "$verdict" == "jitter" ]] || return 0

  # časová základna aspoň 1/10000 s (24000/1001 -> 1/24000, 25 -> 1/10000)
  k=$(( (10000 + num - 1) / num ))
  VIDEO_TS_SCALE=$(( num * k ))
  VIDEO_TS_STEP=$(( den * k ))
}

# Rozhodne kopii/parametry audia. Nastaví AUDIO_COPY=0|1, AUDIO_CODEC,
# AUDIO_BR, AUDIO_AR. $1=file $2=idx
decide_audio() {
  local file="$1" idx="$2"
  AUDIO_COPY=0
  AUDIO_CODEC=""
  AUDIO_BR=""
  AUDIO_AR=""

  local codec ch sr abr
  codec="$(probe1 "$file" "a:$idx" stream=codec_name)"
  ch="$(probe1 "$file" "a:$idx" stream=channels)"
  sr="$(probe1 "$file" "a:$idx" stream=sample_rate)"
  abr="$(stream_bitrate "$file" "a:$idx")"

  # kopie jen kodeků podporovaných zařízením (audio_copy) splňujících
  # stereo/<=48k/<=384k (známý bitrate)
  if [[ -n "$codec" && " $DEV_AUDIO_COPY " == *" $codec "* ]] \
     && [[ "$ch" =~ ^[0-9]+$ && "$ch" -le 2 ]] \
     && [[ "$sr" =~ ^[0-9]+$ && "$sr" -le 48000 ]] \
     && [[ "$abr" =~ ^[0-9]+$ && "$abr" -le 384000 ]]; then
    AUDIO_COPY=1
    return 0
  fi

  # re-enkód: cíl dle profilu, capnutý na zdroj
  local tgt
  if [[ "$PROFILE" == "hd10" ]]; then
    AUDIO_CODEC="aac"
    tgt=160
  else
    AUDIO_CODEC="$DEV_AUDIO_CODEC"
    tgt="$DEV_AUDIO_KBPS"
  fi
  if [[ "$abr" =~ ^[0-9]+$ ]]; then
    local src_kbps=$(( abr / 1000 ))
    (( src_kbps < tgt )) && tgt="$src_kbps"
  fi
  AUDIO_BR="${tgt}k"

  if [[ "$sr" =~ ^[0-9]+$ && "$sr" -lt 48000 ]]; then
    AUDIO_AR="$sr"
  else
    AUDIO_AR="48000"
  fi
}

# --- Cropdetect pre-pass ----------------------------------------------------

# Vypíše "crop=W:H:X:Y" nebo nic. $1=soubor
detect_crop() {
  local file="$1" dur start
  dur="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$file" 2>/dev/null || true)"
  if [[ "$dur" =~ ^[0-9.]+$ ]]; then
    start="$(awk -v d="$dur" 'BEGIN { printf "%.0f", d * 0.35 }')"
  else
    start="60"
  fi
  ffmpeg -hide_banner -ss "$start" -i "$file" \
    -vf cropdetect=round=2 -frames:v 300 -an -f null - 2>&1 \
    | awk '/crop=/ { for (i=1;i<=NF;i++) if ($i ~ /^crop=/) c=$i } END { if (c!="") print c }'
}

# --- Konverze ---------------------------------------------------------------

# Sestaví video filtr (crop -> scale -> ass). Nastaví globální VF.
# $1=crop (může být prázdné) $2=sub_path (může být prázdné, ASCII-safe temp)
build_vf() {
  local crop="$1" sub="$2"
  local -a parts=()
  [[ -n "$crop" ]] && parts+=("$crop")
  parts+=("scale='min($DEV_MAX_W,iw)':'min($DEV_MAX_H,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2")
  [[ -n "$sub" ]] && parts+=("ass=f=$sub")
  local IFS=,
  VF="${parts[*]}"
}

# Přidá video kodek/kvalitu dle profilu (a VIDEO_COPY) do pole CMD. $1=file
append_video_opts() {
  local file="$1"

  if [[ "$VIDEO_COPY" == "1" ]]; then
    CMD+=(-c:v copy)
    if [[ -n "$VIDEO_TS_SCALE" ]]; then
      local st="$VIDEO_TS_STEP"
      CMD+=(-bsf:v "setts=time_base=1/$VIDEO_TS_SCALE:prescale=1:pts=round(PTS/$st)*$st:dts=round(DTS/$st)*$st:duration=$st"
            -video_track_timescale "$VIDEO_TS_SCALE")
    fi
    [[ "$PROFILE" == "hd10" ]] && CMD+=(-tag:v hvc1)
    return 0
  fi

  case "$PROFILE" in
    standard|akcni|serialy)
      local tgt eff sbr
      tgt="$(profile_video_kbps)"
      eff="$tgt"
      sbr="$(stream_bitrate "$file" V:0)"
      if [[ "$sbr" =~ ^[0-9]+$ ]]; then
        local skbps=$(( sbr / 1000 ))
        (( skbps < tgt )) && eff="$skbps"
      fi
      if [[ "$VIDEO_BACKEND" == "videotoolbox" ]]; then
        CMD+=(-c:v h264_videotoolbox -b:v "${eff}k" -profile:v high -level "$(h264_level)")
      else
        CMD+=(-c:v libx264 -preset medium -b:v "${eff}k" -profile:v high -level "$(h264_level)")
      fi
      ;;
    hd10)
      if [[ "$VIDEO_BACKEND" == "videotoolbox" ]]; then
        CMD+=(-c:v hevc_videotoolbox -q:v "$CQ" -profile:v main10 -pix_fmt p010le -tag:v hvc1)
      else
        # CQ VideoToolbox 0..100 převedeme na rozumný rozsah CRF libx265.
        local crf=$(( 51 - (CQ * 31 / 100) ))
        (( crf < 0 )) && crf=0
        (( crf > 51 )) && crf=51
        CMD+=(-c:v libx265 -preset medium -crf "$crf" -profile:v main10 -pix_fmt yuv420p10le -tag:v hvc1)
      fi
      local sbr
      sbr="$(stream_bitrate "$file" V:0)"
      if [[ "$sbr" =~ ^[0-9]+$ ]]; then
        local skbps=$(( sbr / 1000 ))
        CMD+=(-maxrate "${skbps}k" -bufsize "$(( skbps * 2 ))k")
      fi
      ;;
    *) err "Neznámý profil: $PROFILE"; exit 1 ;;
  esac
}

# Přidá audio kodek (podle decide_audio) pro výstupní stopu a:K do pole CMD.
# $1=K
append_audio_opts() {
  local k="$1"
  if [[ "$AUDIO_COPY" == "1" ]]; then
    CMD+=("-c:a:$k" copy)
    return 0
  fi
  CMD+=("-c:a:$k" "$AUDIO_CODEC" "-b:a:$k" "$AUDIO_BR" "-ac:a:$k" 2 "-ar:a:$k" "$AUDIO_AR")
}

# Přidá jazyk do metadat výstupní stopy, pokud byl zjištěn z názvu a tag zdroje
# je jiný (TV pak ukáže správný jazyk). $1=a|s $2=K $3=pozice v TRK_*
append_lang_fix() {
  local iso
  [[ "${TRK_LSRC[$3]}" == název* || -n "${TRK_FILE[$3]}" ]] || return 0
  iso="$(trk_iso3 "${TRK_LANG[$3]}")"
  [[ -z "$iso" ]] || CMD+=("-metadata:s:$1:$2" "language=$iso")
}

# Popis titulkové stopy pro log. $1=pozice v TRK_*
sub_desc() {
  printf '%s (%s, %s %s)' "$(trk_spec "$1")" "${TRK_CODEC[$1]}" "${TRK_LANG[$1]}" "${TRK_KIND[$1]}"
}

process_file() {
  local input="$1"

  [[ -f "$input" ]] || { warn "Soubor neexistuje: $input"; return 1; }
  is_media_file "$input" || return 0

  local dir base name out_dir output
  dir="$(cd "$(dirname "$input")" && pwd)"
  base="$(basename "$input")"
  name="${base%.*}"
  out_dir="${OUTDIR:-$dir/tv-$DEVICE}"

  log
  log "=== $input ==="

  # 1) extrakce titulků (přeskočí se pro hd10, kde se titulky nevypalují)
  if [[ "$DO_EXTRACT" == "1" && "$DRY_RUN" != "1" && "$PROFILE" != "hd10" ]]; then
    "$SCRIPT_DIR/extract-ass.sh" "$input" || warn "extract-ass.sh selhal pro $input"
  fi

  # 2) výběr audia + titulků
  if ! probe_tracks "$input" "$dir" "$name"; then
    warn "ffprobe selhal, přeskakuji: $input"
    return 1
  fi
  select_audio || return 1
  if [[ -z "$SEL_AIDX" ]]; then
    warn "Soubor nemá audio stopy, přeskakuji: $input"
    return 1
  fi
  select_subtitles "$dir" "$name"

  # Obrazové titulky ze souboru (VobSub .idx/.sub) zatím neumíme použít.
  if [[ "$SUB_SRC" == "track" && -n "${TRK_FILE[SEL_SUB_POS]}" ]] \
     && ! trk_is_text_codec "${TRK_CODEC[SEL_SUB_POS]}"; then
    warn "Obrazové titulky ze souboru (${TRK_CODEC[SEL_SUB_POS]}) nejsou podporované: ${TRK_FILE[SEL_SUB_POS]}"
    SUB_SRC=""
  fi

  # Vypalování: ass = textové titulky přes filtr ass,
  # image = obrazové titulky zdroje (PGS/VobSub) přes overlay.
  BURN=""
  if [[ "$PROFILE" != "hd10" && "$SUB_SRC" == "track" ]]; then
    BURN="image"
    trk_is_text_codec "${TRK_CODEC[SEL_SUB_POS]}" && BURN="ass"
  fi

  print_tracks
  local -a audio_list=("$SEL_AIDX" "${SEL_AUDIO_EXTRA[@]}")
  log "Audio: a:$SEL_AIDX (kategorie: $SEL_CAT)"
  if [[ "$SEL_CAT_SURE" != "1" ]]; then
    warn "Jazyk zvuku a:$SEL_AIDX není určen, beru ho jako cizí (plné titulky)." \
         "Pro český zvuk použij --audio-lang cs, pro jinou stopu --audio N."
  fi
  if [[ ${#SEL_AUDIO_EXTRA[@]} -gt 0 ]]; then
    warn "Ponechávám i audio stopy s neurčeným jazykem (nevýchozí): ${SEL_AUDIO_EXTRA[*]/#/a:}"
  fi

  case "$SUB_SRC" in
    "")
      log "Titulky: žádné"
      ;;
    track)
      if [[ "$PROFILE" == "hd10" ]]; then
        log "Titulky (vložit jako výchozí): $(sub_desc "$SEL_SUB_POS")"
      elif [[ "$BURN" == "image" ]]; then
        log "Titulky (vypálit obrazové, bez ořezu černých pruhů): $(sub_desc "$SEL_SUB_POS")"
      else
        log "Titulky (vypálit): $(sub_desc "$SEL_SUB_POS")"
      fi
      ;;
  esac
  if [[ "$SEL_SUB_SURE" != "1" ]]; then
    warn "Výběr titulků není jistý. Ruční volba: --sub N | --sub soubor | --sub none" \
         "(případně --audio-lang cs|sk|cizi)."
  fi
  local x
  local -a sub_alt_desc=()
  for x in "${SEL_SUB_ALT[@]}"; do sub_alt_desc+=("$(sub_desc "$x")"); done
  if [[ ${#SEL_SUB_EXTRA[@]} -gt 0 ]]; then
    log "Další možné titulky ponechány jako nevýchozí stopy: ${sub_alt_desc[*]}"
  elif [[ ${#sub_alt_desc[@]} -gt 0 ]]; then
    log "Další možné titulky (vybrat přes --sub N nebo --sub soubor): ${sub_alt_desc[*]}"
  fi

  output="$out_dir/$name.mp4"
  if [[ -e "$output" && "$output" -ef "$input" ]]; then
    err "Výstup by přepsal vstup: $output"
    return 1
  fi
  # např. film.avi a film.mkv ve stejné složce -> stejný tv-<zařízení>/film.mp4
  if [[ -n "${OUTPUTS_DONE[$output]+x}" ]]; then
    warn "Výstup $output už v tomto běhu vznikl z ${OUTPUTS_DONE[$output]}, přeskakuji: $input"
    return 1
  fi
  OUTPUTS_DONE[$output]="$input"
  log "Profil: $PROFILE, zařízení: $DEVICE  ->  výstup: $output"

  if [[ "$DRY_RUN" == "1" ]]; then
    # rozhodnutí bez znalosti ořezu (ten se zjistí až při konverzi)
    decide_video "$input" ""
    local vcodec vw vh vbr acodec ach abr2 aidx
    vcodec="$(probe1 "$input" V:0 stream=codec_name)"
    vw="$(probe1 "$input" V:0 stream=width)"
    vh="$(probe1 "$input" V:0 stream=height)"
    vbr="$(stream_bitrate "$input" V:0)"
    if [[ "$VIDEO_COPY" == "1" ]]; then
      log "Video: kopie (${vcodec} ${vw}x${vh}${vbr:+ $(( vbr / 1000 ))k}) (ořez se zjistí až při konverzi)"
      decide_timestamps "$input"
      [[ -z "$VIDEO_TS_SCALE" ]] || log "Video: srovnat rozkolísané časové značky (časová základna 1/$VIDEO_TS_SCALE)"
    else
      log "Video: překódovat (zdroj ${vcodec} ${vw}x${vh}${vbr:+ $(( vbr / 1000 ))k})"
    fi
    for aidx in "${audio_list[@]}"; do
      decide_audio "$input" "$aidx"
      acodec="$(probe1 "$input" "a:$aidx" stream=codec_name)"
      ach="$(probe1 "$input" "a:$aidx" stream=channels)"
      abr2="$(stream_bitrate "$input" "a:$aidx")"
      if [[ "$AUDIO_COPY" == "1" ]]; then
        log "Audio a:$aidx: kopie (${acodec} ${ach}ch${abr2:+ $(( abr2 / 1000 ))k})"
      else
        log "Audio a:$aidx: překódovat -> ${AUDIO_CODEC} ${AUDIO_BR} @ ${AUDIO_AR} Hz (zdroj ${acodec} ${ach}ch${abr2:+ $(( abr2 / 1000 ))k})"
      fi
    done
    log "(dry-run: cropdetect a konverze přeskočeny)"
    return 0
  fi

  mkdir -p "$out_dir"

  # ASCII-safe ASS v dočasném adresáři kvůli escapování v ass filtru
  local tmpdir="" sub_safe=""
  cleanup() { [[ -n "$tmpdir" && -d "$tmpdir" ]] && rm -rf "$tmpdir"; }
  trap cleanup RETURN
  if [[ "$BURN" == "ass" ]]; then
    tmpdir="$(mktemp -d)"
    sub_safe="$tmpdir/sub.ass"
    if [[ -n "${TRK_FILE[SEL_SUB_POS]}" ]]; then
      case "${TRK_CODEC[SEL_SUB_POS]}" in
        # vlastní ASS/SSA (stažené, ručně upravené) se použije beze změny stylu
        ass|ssa) cp "${TRK_FILE[SEL_SUB_POS]}" "$sub_safe" ;;
        *)
          trk_sidecar_input_opts "$SEL_SUB_POS" "$input"
          ffmpeg -v error -y "${_TRK_OPTS[@]}" -i "${TRK_FILE[SEL_SUB_POS]}" -c:s ass "$sub_safe" \
            && replace_default_style "$sub_safe"
          ;;
      esac
    else
      ffmpeg -v error -y -i "$input" -map "0:${TRK_IDX[SEL_SUB_POS]}" -c:s ass "$sub_safe" \
        && replace_default_style "$sub_safe"
    fi
    if [[ ! -s "$sub_safe" ]]; then
      warn "Titulky se nepodařilo připravit k vypálení, pokračuji bez nich"
      BURN=""
      sub_safe=""
    fi
  fi

  # 3) cropdetect (obrazové titulky bývají v černých pruzích -> neořezávat)
  local crop=""
  if [[ "$BURN" != "image" ]]; then
    crop="$(detect_crop "$input" || true)"
    [[ -n "$crop" ]] && log "Cropdetect: $crop"
  fi

  # 4) rozhodnutí kopie vs překódování
  decide_video "$input" "$crop"
  VIDEO_TS_SCALE=""
  if [[ "$VIDEO_COPY" == "1" ]]; then
    log "Video: kopie (-c:v copy)"
    decide_timestamps "$input"
    [[ -z "$VIDEO_TS_SCALE" ]] || log "Video: srovnat rozkolísané časové značky (časová základna 1/$VIDEO_TS_SCALE)"
  else
    log "Video: překódovat"
  fi

  CMD=(ffmpeg -hide_banner -y)
  # AVI často nemá časové značky pro kopírování videa do MP4 -> dopočítat
  case "$(printf '%s' "${input##*.}" | tr '[:upper:]' '[:lower:]')" in
    avi) CMD+=(-fflags +genpts) ;;
  esac
  CMD+=(-i "$input")

  # Titulkové stopy do MP4 (mov_text): v hd10 vybraná stopa jako výchozí,
  # dále případné další možné stopy jako nevýchozí. Obrazové titulky MP4
  # nepodporuje. Titulky ze souborů jsou další vstupy FFmpeg.
  local -a sub_out_pos=() sub_maps=()
  local sub_default=0 x n=1
  if [[ "$PROFILE" == "hd10" && "$SUB_SRC" == "track" ]]; then
    if trk_is_text_codec "${TRK_CODEC[SEL_SUB_POS]}"; then
      sub_out_pos+=("$SEL_SUB_POS")
      sub_default=1
    else
      warn "Stopa titulků má kodek '${TRK_CODEC[SEL_SUB_POS]}' (obrázkové), MP4 ji nepodporuje — přeskočeno"
    fi
  fi
  sub_out_pos+=("${SEL_SUB_EXTRA[@]}")
  for x in "${sub_out_pos[@]}"; do
    if [[ -n "${TRK_FILE[x]}" ]]; then
      trk_sidecar_input_opts "$x" "$input"
      CMD+=("${_TRK_OPTS[@]}" -i "${TRK_FILE[x]}")
      sub_maps+=("$n:0")
      n=$((n + 1))
    else
      sub_maps+=("0:s:${TRK_REL[x]}")
    fi
  done

  if [[ "$BURN" == "image" ]]; then
    build_vf "" ""
    CMD+=(-filter_complex "[0:V:0][0:s:${TRK_REL[SEL_SUB_POS]}]overlay=eof_action=pass,${VF}[vout]" -map "[vout]")
  else
    CMD+=(-map 0:V:0)
  fi

  local aidx
  for aidx in "${audio_list[@]}"; do
    CMD+=(-map "0:a:$aidx")
  done

  for x in "${sub_maps[@]}"; do
    CMD+=(-map "$x")
  done

  if [[ "$VIDEO_COPY" != "1" && "$BURN" != "image" ]]; then
    build_vf "$crop" "$sub_safe"
    CMD+=(-vf "$VF")
  fi
  append_video_opts "$input"

  local k=0 pos
  for aidx in "${audio_list[@]}"; do
    decide_audio "$input" "$aidx"
    if [[ "$AUDIO_COPY" == "1" ]]; then
      log "Audio a:$aidx: kopie (-c:a copy)"
    else
      log "Audio a:$aidx: překódovat -> ${AUDIO_CODEC} ${AUDIO_BR} @ ${AUDIO_AR} Hz"
    fi
    append_audio_opts "$k"
    if [[ "$k" == "0" ]]; then
      CMD+=("-disposition:a:$k" default)
    else
      CMD+=("-disposition:a:$k" 0)
    fi
    pos="$(trk_find audio "$aidx")"
    append_lang_fix a "$k" "$pos"
    k=$((k + 1))
  done

  if [[ ${#sub_out_pos[@]} -gt 0 ]]; then
    CMD+=(-c:s mov_text)
    k=0
    for pos in "${sub_out_pos[@]}"; do
      if [[ "$k" == "0" && "$sub_default" == "1" ]]; then
        CMD+=("-disposition:s:$k" default)
      else
        CMD+=("-disposition:s:$k" 0)
      fi
      append_lang_fix s "$k" "$pos"
      k=$((k + 1))
    done
  fi
  CMD+=(-map_chapters -1 -map_metadata 0 -movflags +faststart "$output")

  log "Spouštím konverzi..."
  "${CMD[@]}"
  log "Konverze hotová: $output"

  cleanup
  trap - RETURN

  # 4) srovnání offsetu
  if [[ "$DO_FIX_OFFSET" == "1" ]]; then
    "$SCRIPT_DIR/fix-audio-offsets.sh" --threshold "$THRESHOLD" "$output" \
      || warn "fix-audio-offsets.sh selhal pro $output"
  fi
}

process_path() {
  local p="$1"
  if [[ -d "$p" ]]; then
    shopt -s nullglob
    local f
    for f in "$p"/*; do
      [[ -f "$f" ]] && is_media_file "$f" || continue
      process_file "$f" || true
    done
    shopt -u nullglob
  else
    process_file "$p" || true
  fi
}

main() {
  local -a inputs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) [[ $# -ge 2 ]] || { err "Chybí hodnota za --profile"; exit 1; }; PROFILE="$2"; shift 2 ;;
      --device)  [[ $# -ge 2 ]] || { err "Chybí hodnota za --device"; exit 1; }; DEVICE="$2"; shift 2 ;;
      --set-device) [[ $# -ge 2 ]] || { err "Chybí hodnota za --set-device"; exit 1; }; SET_DEVICE="$2"; shift 2 ;;
      --list-devices)  LIST_DEVICES="1"; shift ;;
      --cq)      [[ $# -ge 2 ]] || { err "Chybí hodnota za --cq"; exit 1; }; CQ="$2"; shift 2 ;;
      --threshold) [[ $# -ge 2 ]] || { err "Chybí hodnota za --threshold"; exit 1; }; THRESHOLD="$2"; shift 2 ;;
      --outdir)  [[ $# -ge 2 ]] || { err "Chybí hodnota za --outdir"; exit 1; }; OUTDIR="$2"; shift 2 ;;
      --audio)   [[ $# -ge 2 ]] || { err "Chybí hodnota za --audio"; exit 1; }; AUDIO_OPT="$2"; shift 2 ;;
      --audio-lang) [[ $# -ge 2 ]] || { err "Chybí hodnota za --audio-lang"; exit 1; }; AUDIO_LANG_OPT="$2"; shift 2 ;;
      --sub)     [[ $# -ge 2 ]] || { err "Chybí hodnota za --sub"; exit 1; }; SUB_OPT="$2"; shift 2 ;;
      --keep-ass)      DO_EXTRACT="1"; shift ;;
      --no-extract)    DO_EXTRACT="0"; shift ;;  # zastaralé, výchozí chování
      --no-fix-offset) DO_FIX_OFFSET="0"; shift ;;
      --dry-run)       DRY_RUN="1"; shift ;;
      -h|--help)       usage; exit 0 ;;
      --) shift; while [[ $# -gt 0 ]]; do inputs+=("$1"); shift; done ;;
      -*) err "Neznámý přepínač: $1"; usage; exit 1 ;;
      *)  inputs+=("$1"); shift ;;
    esac
  done

  load_devices "$SCRIPT_DIR/devices.conf"
  load_devices "$CONFIG_DIR/devices.conf"
  if [[ "$LIST_DEVICES" == "1" ]]; then
    list_devices
    exit 0
  fi
  if [[ -n "$SET_DEVICE" ]]; then
    use_device "$SET_DEVICE"
    config_set device "$SET_DEVICE"
    log "Výchozí zařízení: $SET_DEVICE (uloženo do $CONFIG_DIR/config)"
    exit 0
  fi
  if [[ -z "$DEVICE" ]]; then
    default_device
    DEVICE="$_DEV"
  fi
  use_device "$DEVICE"

  require_cmd ffmpeg
  require_cmd ffprobe
  require_cmd awk

  case "$PROFILE" in
    standard|akcni|serialy|hd10) ;;
    *) err "Neznámý profil: $PROFILE (povolené: standard akcni serialy hd10)"; exit 1 ;;
  esac

  if [[ -n "$AUDIO_OPT" && ! "$AUDIO_OPT" =~ ^[0-9]+$ ]]; then
    err "--audio očekává číslo stopy (a:N), např. --audio 1"; exit 1
  fi
  case "$(printf '%s' "$AUDIO_LANG_OPT" | tr '[:upper:]' '[:lower:]')" in
    '') ;;
    cs|cz|cze|ces|cesky|czech)                 AUDIO_LANG_OPT="czech" ;;
    sk|slk|slo|slovensky|slovak)               AUDIO_LANG_OPT="slovak" ;;
    cizi|foreign|en|eng|other|jiny)            AUDIO_LANG_OPT="foreign" ;;
    *) err "Neznámá hodnota --audio-lang: $AUDIO_LANG_OPT (povolené: cs sk cizi)"; exit 1 ;;
  esac
  if [[ -n "$SUB_OPT" && "$SUB_OPT" != "none" && ! "$SUB_OPT" =~ ^[0-9]+$ ]]; then
    [[ -f "$SUB_OPT" ]] || { err "Soubor titulků neexistuje: $SUB_OPT"; exit 1; }
    SUB_OPT="$(cd "$(dirname "$SUB_OPT")" && pwd)/$(basename "$SUB_OPT")"
  fi

  # Potřebné kodeky; vypalování titulků navíc libass (hd10 titulky nevypaluje).
  # Výstup se ukládá do proměnné: "ffmpeg | grep -q" by pod pipefail selhal na SIGPIPE.
  local encoders filters missing="" x
  encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
  filters="$(ffmpeg -hide_banner -filters 2>/dev/null || true)"
  local -a need_enc=(aac ac3)
  if [[ "$VIDEO_BACKEND" == "videotoolbox" ]]; then
    need_enc+=(h264_videotoolbox hevc_videotoolbox)
  else
    need_enc+=(libx264 libx265)
  fi
  for x in "${need_enc[@]}"; do
    [[ "$encoders" == *" $x "* ]] || missing+=" enkodér $x,"
  done
  if [[ "$PROFILE" != "hd10" ]]; then
    for x in ass subtitles; do
      [[ "$filters" == *" $x "* ]] || missing+=" filtr $x (libass),"
    done
  fi
  if [[ -n "$missing" ]]; then
    err "FFmpeg nevyhovuje, chybí:${missing%,}"
    err "macOS: brew install ffmpeg-full; Linux: balík ffmpeg s libass, libx264 a libx265 (viz REQUIREMENTS.md)."
    exit 1
  fi

  [[ ${#inputs[@]} -gt 0 ]] || { usage; exit 1; }

  local p
  for p in "${inputs[@]}"; do
    process_path "$p"
  done
}

main "$@"
