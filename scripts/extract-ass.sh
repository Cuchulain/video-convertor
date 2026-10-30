#!/usr/bin/env bash
set -euo pipefail

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

if locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx 'c\.utf-8'; then
  export LC_ALL=C.UTF-8 LANG=C.UTF-8
elif locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -Eq '^en_us\.utf-?8$'; then
  export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tracks.sh
source "$SCRIPT_DIR/lib/tracks.sh"

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Chyba: ffprobe není dostupný v PATH." >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Chyba: ffmpeg není dostupný v PATH." >&2
  exit 1
fi

# Sanitizuje title streamu na bezpečný řetězec pro název souboru.
# $1 = raw title, $2 = fallback (použije se, pokud je title prázdný nebo nevýsledný)
sanitize_title() {
  local raw="$1"
  local fallback="$2"
  if [[ -z "$raw" ]]; then
    printf '%s' "$fallback"
    return
  fi
  local result
  result="$(trk_normalize "$raw" \
    | tr -s ' ' '-' \
    | sed 's/^-*//;s/-*$//')"
  if [[ -z "$result" ]]; then
    printf '%s' "$fallback"
  else
    printf '%s' "$result"
  fi
}

# Vytáhne titulky jedné jazykové sady a uloží je jako .<label>.<langcode>.ass.
# Jazyk i druh (forced/full) určuje heuristika z lib/tracks.sh, takže se
# vytáhnou i stopy se špatným tagem, ale s "CZ"/"čeština" v názvu, a forced
# stopy bez příznaku dostanou "force" v labelu. Očekává naplněná pole TRK_*.
# $1 = media_file, $2 = langcode (cs/sk), $3 = langname (lidský název)
extract_lang_streams() {
  local media_file="$1"
  local langcode="$2"
  local langname="$3"

  declare -A used_labels=()
  local found=0
  local i fallback label output_file counter

  for ((i=0; i<TRK_N; i++)); do
    [[ "${TRK_TYPE[i]}" == "subtitle" && "${TRK_LANG[i]}" == "$langcode" ]] || continue
    [[ -z "${TRK_SKIP[i]}" ]] || continue
    found=1

    if ! trk_is_text_codec "${TRK_CODEC[i]}"; then
      echo "[$media_file] Stream titulků #${TRK_IDX[i]} je obrazový (${TRK_CODEC[i]}), do ASS ho nelze převést"
      continue
    fi

    if [[ "${TRK_KIND[i]}" == "forced" ]]; then
      fallback="force"
    else
      fallback="full"
    fi

    label="$(sanitize_title "${TRK_TITLE[i]}" "$fallback")"

    # Forced stopa musí mít "force" v labelu (podle něj se soubor klasifikuje,
    # viz find_sub v convert-for-tv.sh); plná naopak nesmí obsahovat "forc".
    if [[ "${TRK_KIND[i]}" == "forced" && "$label" != *forc* ]]; then
      label="force-${label}"
    fi

    # Ošetření kolizí stejného labelu
    if [[ -n "${used_labels[$label]+x}" ]]; then
      counter=2
      while [[ -n "${used_labels[${label}-${counter}]+x}" ]]; do
        (( counter++ ))
      done
      label="${label}-${counter}"
    fi
    used_labels[$label]=1

    output_file="${media_file%.*}.${label}.${langcode}.ass"
    echo "[$media_file] Nalezen stream titulků #${TRK_IDX[i]} (${TRK_KIND[i]}) -> $output_file"

    if ffmpeg -y -v error -i "$media_file" -map "0:${TRK_IDX[i]}" -c:s ass "$output_file"; then
      if replace_default_style "$output_file"; then
        echo "[$media_file] OK (styl upraven)"
      else
        echo "[$media_file] OK (varování: styl nebyl upraven)"
      fi
    else
      echo "[$media_file] Chyba při extrakci streamu #${TRK_IDX[i]}" >&2
    fi
  done

  if [[ "$found" == "0" ]]; then
    echo "[$media_file] Nenalezeny ${langname} titulky (forced ani full)"
  fi

  unset used_labels
}

process_media_file() {
  local media_file="$1"

  [[ -f "$media_file" ]] || return 0

  is_media_file "$media_file" || return 0

  if ! probe_tracks "$media_file"; then
    echo "[$media_file] ffprobe selhal" >&2
    return 0
  fi
  extract_lang_streams "$media_file" "cs" "české"
  extract_lang_streams "$media_file" "sk" "slovenské"
}

process_path() {
  local input_path="$1"

  if [[ -d "$input_path" ]]; then
    shopt -s nullglob
    local media_file
    for media_file in "$input_path"/*; do
      [[ -f "$media_file" ]] || continue
      process_media_file "$media_file"
    done
    shopt -u nullglob
  elif [[ -f "$input_path" ]]; then
    process_media_file "$input_path"
  else
    echo "Přeskakuji: '$input_path' neexistuje." >&2
  fi
}

main() {
  if [[ "$#" -eq 0 ]]; then
    process_path "$PWD"
    exit 0
  fi

  local arg
  for arg in "$@"; do
    process_path "$arg"
  done
}

main "$@"
