#!/usr/bin/env bash
set -euo pipefail

# fix-audio-offsets.sh
#
# Použití:
#   ./fix-audio-offsets.sh soubor.mp4
#   ./fix-audio-offsets.sh soubor1.mp4 soubor2.mp4
#   ./fix-audio-offsets.sh --dry-run *.mp4
#   ./fix-audio-offsets.sh --threshold 0.100 *.mp4
#
# Co dělá:
# - zjistí start_time všech audio stop
# - pokud má některá audio stopa |start_time| > threshold, soubor opraví
# - video kopíruje bez rekomprese
# - titulky/data kopíruje
# - audio stopy s offsetem znovu vyrenderuje s fyzicky přidaným tichem
# - audio stopy bez offsetu jen zkopíruje
# - původní soubor přejmenuje na .original.ext
# - výsledek uloží pod původním názvem
# - po úspěchu smaže zálohu
#
# Omezení:
# - záporný audio offset zatím jen přeskočí s varováním
# - zaměřeno hlavně na MP4/MOV s edit listem

THRESHOLD="0.050"
DRY_RUN="0"

usage() {
  cat <<'EOF'
Použití:
  fix-audio-offsets.sh [--dry-run] [--threshold SEC] soubor1 [soubor2 ...]

Přepínače:
  --dry-run          Jen vypíše, co by se opravovalo
  --threshold SEC    Prah v sekundách, výchozí 0.050
  -h, --help         Nápověda
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Chybí příkaz: $1"; exit 1; }
}

abs_float_gt() {
  awk -v x="$1" -v t="$2" 'BEGIN { if (x < 0) x = -x; exit !(x > t) }'
}

float_abs() {
  awk -v x="$1" 'BEGIN { if (x < 0) x = -x; printf "%.6f", x }'
}

to_ms_round() {
  awk -v x="$1" 'BEGIN { printf "%.0f", x * 1000 }'
}

norm_float() {
  awk -v x="${1:-0}" 'BEGIN { printf "%.6f", x + 0 }'
}

# Vrátí počet audio streamů
get_audio_count() {
  local file="$1"
  ffprobe -v error \
    -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 \
    "$file" | wc -l | awk '{print $1}'
}

# Vrátí start_time pro audio stopu a:N při normálním čtení
get_audio_start() {
  local file="$1"
  local aidx="$2"
  ffprobe -v error \
    -select_streams "a:${aidx}" \
    -show_entries stream=start_time \
    -of default=nw=1:nk=1 \
    "$file" | head -n1
}

# Vrátí codec_name pro audio stopu a:N
get_audio_codec() {
  local file="$1"
  local aidx="$2"
  ffprobe -v error \
    -select_streams "a:${aidx}" \
    -show_entries stream=codec_name \
    -of default=nw=1:nk=1 \
    "$file" | head -n1
}

# Vrátí bit_rate pro audio stopu a:N, nebo prázdno
get_audio_bitrate() {
  local file="$1"
  local aidx="$2"
  ffprobe -v error \
    -select_streams "a:${aidx}" \
    -show_entries stream=bit_rate \
    -of default=nw=1:nk=1 \
    "$file" | head -n1
}

# Zachová audio codec pokud je AC-3, jinak AC-3 fallback
# Výstup: "<codec> <bitrate>"
choose_audio_output() {
  local codec="$1"
  local bitrate="${2:-}"

  case "$codec" in
    ac3)
      if [[ -n "$bitrate" && "$bitrate" != "N/A" ]]; then
        printf 'ac3 %s' "$bitrate"
      else
        printf 'ac3 384000'
      fi
      ;;
    *)
      # Pro TV kompatibilitu raději AC-3
      printf 'ac3 384000'
      ;;
  esac
}

process_file() {
  local input="$1"

  if [[ ! -f "$input" ]]; then
    warn "Soubor neexistuje: $input"
    return 1
  fi

  local dir base name ext backup tmp_out
  dir="$(cd "$(dirname "$input")" && pwd)"
  base="$(basename "$input")"
  name="${base%.*}"
  ext="${base##*.}"
  backup="$dir/${name}.original.${ext}"
  tmp_out="$dir/${name}.fixed.$$.$ext"

  if [[ -e "$backup" ]]; then
    warn "Přeskakuji, už existuje záloha: $backup"
    return 1
  fi

  if [[ -e "$tmp_out" ]]; then
    warn "Přeskakuji, už existuje dočasný soubor: $tmp_out"
    return 1
  fi

  local audio_count
  audio_count="$(get_audio_count "$input")"

  if [[ "$audio_count" -eq 0 ]]; then
    log "Soubor nemá audio stopy, přeskakuji: $input"
    return 0
  fi

  log
  log "=== $input ==="

  local needs_fix="0"
  local -a starts codecs bitrates fix_flags delay_ms_list out_codecs out_bitrates

  local i
  for ((i=0; i<audio_count; i++)); do
    local raw_start codec bitrate start_norm abs_start
    raw_start="$(get_audio_start "$input" "$i" || true)"
    codec="$(get_audio_codec "$input" "$i" || true)"
    bitrate="$(get_audio_bitrate "$input" "$i" || true)"

    start_norm="$(norm_float "${raw_start:-0}")"
    abs_start="$(float_abs "$start_norm")"

    starts[$i]="$start_norm"
    codecs[$i]="${codec:-unknown}"
    bitrates[$i]="${bitrate:-}"
    fix_flags[$i]="0"
    delay_ms_list[$i]="0"

    local chosen
    chosen="$(choose_audio_output "${codecs[$i]}" "${bitrates[$i]}")"
    out_codecs[$i]="$(awk '{print $1}' <<<"$chosen")"
    out_bitrates[$i]="$(awk '{print $2}' <<<"$chosen")"

    log "Audio a:$i codec=${codecs[$i]} start_time=${starts[$i]}"

    if abs_float_gt "$start_norm" "$THRESHOLD"; then
      if awk -v x="$start_norm" 'BEGIN { exit !(x >= 0) }'; then
        fix_flags[$i]="1"
        delay_ms_list[$i]="$(to_ms_round "$start_norm")"
        needs_fix="1"
      else
        warn "Audio a:$i má záporný offset (${start_norm}s). Tuto stopu zatím neupravuji."
      fi
    fi
  done

  if [[ "$needs_fix" != "1" ]]; then
    log "Není co opravovat."
    return 0
  fi

  log "Soubor vyžaduje opravu."

  if [[ "$DRY_RUN" == "1" ]]; then
    for ((i=0; i<audio_count; i++)); do
      if [[ "${fix_flags[$i]}" == "1" ]]; then
        log "  a:$i -> opravit, přidat ${delay_ms_list[$i]} ms ticha, výstup ${out_codecs[$i]} ${out_bitrates[$i]}"
      else
        log "  a:$i -> ponechat beze změny"
      fi
    done
    return 0
  fi

  local cleanup_needed="0"
  cleanup_on_error() {
    local exit_code=$?
    if [[ "$cleanup_needed" == "1" ]]; then
      [[ -f "$tmp_out" ]] && rm -f "$tmp_out"
      if [[ -f "$backup" && ! -f "$input" ]]; then
        mv -f "$backup" "$input" || true
      fi
    fi
    exit "$exit_code"
  }
  trap cleanup_on_error ERR INT TERM

  mv "$input" "$backup"
  cleanup_needed="1"

  local -a cmd
  cmd=(ffmpeg -hide_banner -y)

  # Vstup 0 = běžný soubor kvůli videu/titulkům/datům/mapování metadata
  cmd+=(-i "$backup")

  # Pro každou audio stopu vlastní vstup bez edit listu
  for ((i=0; i<audio_count; i++)); do
    cmd+=(-ignore_editlist 1 -i "$backup")
  done

  # Mapování: video, audio, titulky, data
  cmd+=(-map 0:v?)
  for ((i=0; i<audio_count; i++)); do
    cmd+=(-map "$((i+1)):a:0")
  done
  cmd+=(-map 0:s? -map 0:d? -map_metadata 0 -map_chapters 0)

  # Video a ostatní věci kopírovat
  cmd+=(-c:v copy -c:s copy -c:d copy)

  # Nastavení pro jednotlivé audio stopy
  for ((i=0; i<audio_count; i++)); do
    if [[ "${fix_flags[$i]}" == "1" ]]; then
      cmd+=(-filter:a:$i "adelay=${delay_ms_list[$i]}:all=1,asetpts=PTS-STARTPTS")
      cmd+=(-c:a:$i "${out_codecs[$i]}")
      cmd+=(-b:a:$i "${out_bitrates[$i]}")
    else
      cmd+=(-c:a:$i copy)
    fi
  done

  cmd+=(-avoid_negative_ts make_zero -movflags +faststart "$tmp_out")

  "${cmd[@]}"

  # Ověření výsledku
  for ((i=0; i<audio_count; i++)); do
    local new_start
    new_start="$(get_audio_start "$tmp_out" "$i" || true)"
    log "Výstup a:$i start_time=$(norm_float "${new_start:-0}")"
  done

  mv "$tmp_out" "$input"
  rm -f "$backup"

  cleanup_needed="0"
  trap - ERR INT TERM

  log "Hotovo: $input"
}

main() {
  require_cmd ffmpeg
  require_cmd ffprobe
  require_cmd awk

  local -a files=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN="1"
        shift
        ;;
      --threshold)
        [[ $# -ge 2 ]] || { err "Chybí hodnota za --threshold"; exit 1; }
        THRESHOLD="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          files+=("$1")
          shift
        done
        ;;
      -*)
        err "Neznámý přepínač: $1"
        usage
        exit 1
        ;;
      *)
        files+=("$1")
        shift
        ;;
    esac
  done

  [[ ${#files[@]} -gt 0 ]] || { usage; exit 1; }

  local rc=0
  local f
  for f in "${files[@]}"; do
    process_file "$f" || rc=1
  done

  exit "$rc"
}

main "$@"
