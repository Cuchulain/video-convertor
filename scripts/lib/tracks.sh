# shellcheck shell=bash
# Video convertor pro TV – Jan Čejka, https://dev.jancejka.cz
# https://github.com/Cuchulain/video-convertor (licence MIT)
#
# tracks.sh — sdílená heuristika pro rozpoznání jazyka a druhu (forced/full)
# audio a titulkových stop. Načítá se přes `source` z convert-for-tv.sh
# a extract-ass.sh.
#
# Metadata stop bývají nespolehlivá: chybí příznak forced, jazyk je "und" nebo
# špatně, a správná informace je jen v názvu stopy ("CZ", "Čeština", "forc"...).
# Proto se kombinuje:
#   jazyk: název stopy (cs/sk) > jazykový tag > název stopy (ostatní) > und
#   druh:  název stopy > příznak forced (pokud mu neodporuje počet titulků)
#          > počet titulků vůči délce filmu a ostatním stopám
#
# Po probe_tracks jsou k dispozici pole indexovaná pořadím stopy (jen audio
# a titulky, video a přílohy se přeskakují):
#   TRK_TYPE   audio|subtitle
#   TRK_REL    relativní index v rámci typu (specifikátor a:N / s:N)
#   TRK_IDX    absolutní index streamu (specifikátor 0:N)
#   TRK_CODEC, TRK_TAG (jazykový tag), TRK_TITLE, TRK_PKTS, TRK_FORCED, TRK_HI
#   TRK_LANG   cs|sk|en|other|und
#   TRK_LSRC   odkud jazyk pochází (popis pro výpis)
#   TRK_KIND   forced|full|unknown (jen titulky)
#   TRK_KSRC   odkud druh pochází (popis pro výpis)
#   TRK_EV     odhad počtu titulků (PGS má 2 pakety na titulek)
#   TRK_SKIP   důvod vyřazení (sdh, komentář, prázdná) nebo prázdné
#   TRK_FILE   cesta k titulkům vedle videa (prázdné = stopa ve zdroji);
#              takové stopy mají prázdné TRK_REL/TRK_IDX a TRK_TITLE je část
#              názvu souboru mezi jménem videa a příponou ("cs", "forced.cz"...)
#   TRK_CHARENC kódování textových titulků ze souboru: "" (UTF-8), UTF-16, CP1250
# TRK_N je počet stop, TRK_DURATION délka souboru v sekundách (nebo prázdné).

# Podporované vstupní formáty (přípony malými písmeny).
MEDIA_EXTS=(mkv mp4 m4v mov avi wmv asf webm ts m2ts mts mpg mpeg flv)

# Je soubor podporovaný vstup? Porovnává příponu bez ohledu na velikost písmen.
is_media_file() {
  local ext e
  ext="$(printf '%s' "${1##*.}" | LC_ALL=C tr 'A-Z' 'a-z')"
  for e in "${MEDIA_EXTS[@]}"; do
    [[ "$ext" != "$e" ]] || return 0
  done
  return 1
}

TRK_RE_CS=' (cz|cze|ces|cs|czech[a-z]*|cesk[a-z]*|cestin[a-z]*) '
TRK_RE_SK=' (sk|slk|svk|slovak[a-z]*|slovencin[a-z]*|slovensk(y|e|a|ych|ym|ou|om|eho)?) '
TRK_RE_EN=' (en|eng|english|angl|anglick[a-z]*|anglictin[a-z]*) '
TRK_RE_OTHER=' (ger|deu|german|deutsch|nemeck[a-z]*|nemcin[a-z]*|pol|polish|polski|polsk[a-z]*|hun|hungarian|magyar|madarsk[a-z]*|rus|russian|rusk[a-z]*|fre|fra|french|francais|francouzsk[a-z]*|spa|spanish|espanol|spanelsk[a-z]*|ita|italian|italiano|italsk[a-z]*|ukr|ukrainian|ukrajinsk[a-z]*|jpn|japanese|japonsk[a-z]*) '
TRK_RE_FORCED='forc|vynucen| nucen| cizi | cizich | cizojazyc|foreign| napis| signs '
TRK_RE_FULL=' (full|plne|plna|plny|uplne|uplna|kompletni|complete) '
TRK_RE_SDH=' sdh |hearing| cc | hoh |neslysic|nedoslych'
TRK_RE_COMMENT='comment|komentar'

# Přípony titulků hledaných vedle videa. ASS se nehledá, protože ho vytváří
# extract-ass.sh ze stop zdroje (používá se jen jako záloha, viz find_sub).
SIDECAR_EXTS=(srt sub vtt ssa)

# Textové kodeky titulků (lze převést do ASS / mov_text).
trk_is_text_codec() {
  case "$1" in
    subrip|srt|ass|ssa|mov_text|webvtt|text) return 0 ;;
    microdvd|subviewer|subviewer1|mpl2|vplayer|sami|realtext|pjs|jacosub|stl) return 0 ;;
    *) return 1 ;;
  esac
}

# Malá písmena, bez české/slovenské diakritiky, vše kromě [a-z0-9] -> mezera.
# Výsledek je obalen mezerami, aby šlo hledat celá slova přes ' slovo '.
trk_normalize() {
  local s
  s="$(printf '%s' "$1" | sed \
    -e 's/á/a/g;s/Á/a/g;s/ä/a/g;s/Ä/a/g;s/č/c/g;s/Č/c/g;s/ď/d/g;s/Ď/d/g' \
    -e 's/é/e/g;s/É/e/g;s/ě/e/g;s/Ě/e/g;s/í/i/g;s/Í/i/g;s/ĺ/l/g;s/Ĺ/l/g;s/ľ/l/g;s/Ľ/l/g' \
    -e 's/ň/n/g;s/Ň/n/g;s/ó/o/g;s/Ó/o/g;s/ô/o/g;s/Ô/o/g;s/ŕ/r/g;s/Ŕ/r/g;s/ř/r/g;s/Ř/r/g' \
    -e 's/š/s/g;s/Š/s/g;s/ť/t/g;s/Ť/t/g;s/ú/u/g;s/Ú/u/g;s/ů/u/g;s/Ů/u/g' \
    -e 's/ý/y/g;s/Ý/y/g;s/ž/z/g;s/Ž/z/g' \
    | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9' ' ')"
  printf ' %s ' "$s"
}

# Jazyk z jazykového tagu. Výsledek v _TRK_R (cs|sk|en|other|und).
trk_lang_from_tag() {
  case "$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')" in
    cs|cz|cze|ces|czech)  _TRK_R="cs" ;;
    sk|slk|slo|slovak)    _TRK_R="sk" ;;
    en|eng|english)       _TRK_R="en" ;;
    ''|und|unk|unknown|undefined|undetermined|mis|mul|zxx|none) _TRK_R="und" ;;
    *)                    _TRK_R="other" ;;
  esac
}

# Jazyk z normalizovaného názvu stopy. Výsledek v _TRK_R (cs|sk|en|other|"").
trk_lang_from_title() {
  local t="$1"
  _TRK_R=""
  if   [[ "$t" =~ $TRK_RE_CS ]];    then _TRK_R="cs"
  elif [[ "$t" =~ $TRK_RE_SK ]];    then _TRK_R="sk"
  elif [[ "$t" =~ $TRK_RE_EN ]];    then _TRK_R="en"
  elif [[ "$t" =~ $TRK_RE_OTHER ]]; then _TRK_R="other"
  fi
}

# Jazyk z kódu v názvu souboru titulků ("cs", "cz", "en", "de"...).
# Výsledek v _TRK_R (cs|sk|en|other|"").
trk_lang_from_code_token() {
  case "$1" in
    cs|cz|cze|ces|czech) _TRK_R="cs" ;;
    sk|slk|slo|slovak)   _TRK_R="sk" ;;
    en|eng|english)      _TRK_R="en" ;;
    de|ger|deu|fr|fre|fra|es|spa|it|ita|pl|pol|hu|hun|ru|rus|uk|ukr|nl|dut|nld|pt|por) _TRK_R="other" ;;
    *) _TRK_R="" ;;
  esac
}

# Kódování textových titulků. Výsledek v _TRK_R: "" (UTF-8), UTF-16 (s BOM,
# FFmpeg ho pozná sám) nebo CP1250 (vše ostatní, typické pro české .srt/.sub).
trk_detect_charenc() {
  local bom
  bom="$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')"
  case "$bom" in
    efbbbf)      _TRK_R="" ; return 0 ;;
    fffe*|feff*) _TRK_R="UTF-16" ; return 0 ;;
  esac
  if iconv -f UTF-8 -t UTF-8 "$1" >/dev/null 2>&1; then
    _TRK_R=""
  else
    _TRK_R="CP1250"
  fi
}

# Počet výskytů některého z řetězců $2.. v textu $1.
trk_count() {
  local text="$1"; shift
  local -a pats=()
  local p
  for p in "$@"; do pats+=(-e "$p"); done
  printf '%s' "$text" | { grep -o -i -w "${pats[@]}" || true; } | wc -l | tr -d ' '
}

# Jazyk podle obsahu titulků (pro soubory bez jazyka v názvu).
# $1=soubor $2=kódování. Výsledek v _TRK_R (cs|sk|en|"").
trk_sniff_lang() {
  local text cs sk en
  if [[ -n "$2" ]]; then
    text="$(head -c 300000 "$1" | iconv -f "$2" -t UTF-8 2>/dev/null || true)"
  else
    text="$(head -c 300000 "$1")"
  fi
  # ř/ů/ě má jen čeština, ľ/ĺ/ŕ/ô/ä jen slovenština
  cs="$(printf '%s' "$text" | { grep -o -e 'ř' -e 'Ř' -e 'ů' -e 'Ů' -e 'ě' -e 'Ě' || true; } | wc -l | tr -d ' ')"
  sk="$(printf '%s' "$text" | { grep -o -e 'ľ' -e 'Ľ' -e 'ĺ' -e 'Ĺ' -e 'ŕ' -e 'Ŕ' -e 'ô' -e 'Ô' -e 'ä' -e 'Ä' || true; } | wc -l | tr -d ' ')"
  en="$(trk_count "$text" the you and what this that)"
  _TRK_R=""
  if (( cs >= 10 && sk * 4 < cs )); then _TRK_R="cs"
  elif (( sk >= 10 && cs * 4 < sk )); then _TRK_R="sk"
  elif (( en >= 30 )); then _TRK_R="en"
  fi
}

# Přidá titulky ze souboru jako další titulkovou stopu (bez klasifikace druhu,
# tu doplní trk_classify). Jazyk určí z názvu, jinak z obsahu.
# $1=cesta $2=label (část názvu mezi jménem videa a příponou)
# Pozici stopy vrací v _TRK_POS; návratová hodnota 1 = soubor nelze načíst.
trk_add_sidecar() {
  local path="$1" label="$2" i out line codec="" pkts=0 norm tok lang="" lsrc="" charenc=""
  for ((i=0; i<TRK_N; i++)); do
    if [[ "${TRK_FILE[i]}" == "$path" ]]; then _TRK_POS="$i"; return 0; fi
  done

  out="$(ffprobe -v error -count_packets -select_streams s:0 \
    -show_entries stream=codec_name,nb_read_packets -of default=noprint_wrappers=1 "$path" 2>/dev/null)" || return 1
  while IFS= read -r line; do
    case "$line" in
      codec_name=*)      codec="${line#codec_name=}" ;;
      nb_read_packets=*) pkts="${line#nb_read_packets=}" ;;
    esac
  done <<<"$out"
  [[ -n "$codec" ]] || return 1

  if trk_is_text_codec "$codec"; then
    trk_detect_charenc "$path"; charenc="$_TRK_R"
  fi

  norm="$(trk_normalize "$label")"
  trk_lang_from_title "$norm"; lang="$_TRK_R"
  if [[ -z "$lang" ]]; then
    for tok in $norm; do
      trk_lang_from_code_token "$tok"
      if [[ -n "$_TRK_R" ]]; then lang="$_TRK_R"; break; fi
    done
  fi
  if [[ -n "$lang" ]]; then
    lsrc="název souboru"
  elif trk_is_text_codec "$codec"; then
    trk_sniff_lang "$path" "$charenc"
    lang="$_TRK_R"
    [[ -z "$lang" ]] || lsrc="obsah souboru"
  fi
  if [[ -z "$lang" ]]; then lang="und"; lsrc="neurčen"; fi

  i="$TRK_N"
  TRK_TYPE[i]="subtitle"; TRK_REL[i]=""; TRK_IDX[i]=""; TRK_CODEC[i]="$codec"
  TRK_TAG[i]=""; TRK_TITLE[i]="$label"; TRK_PKTS[i]="$pkts"; TRK_FORCED[i]="0"; TRK_HI[i]="0"
  TRK_FILE[i]="$path"; TRK_CHARENC[i]="$charenc"; TRK_LANG[i]="$lang"; TRK_LSRC[i]="$lsrc"
  TRK_N=$((TRK_N + 1))
  _TRK_POS="$i"
}

# Přidá titulky vedle videa: <jméno>.srt, <jméno>.cs.srt, <jméno>.forced.cz.sub...
# $1=adresář $2=jméno videa bez přípony
trk_scan_sidecars() {
  local dir="$1" name="$2" f base rest label ext e ok
  local restore_nullglob=0
  shopt -q nullglob || restore_nullglob=1
  shopt -s nullglob
  for f in "$dir/$name".*; do
    [[ -f "$f" ]] || continue
    base="${f##*/}"
    ext="$(printf '%s' "${base##*.}" | LC_ALL=C tr 'A-Z' 'a-z')"
    ok=0
    for e in "${SIDECAR_EXTS[@]}"; do [[ "$ext" != "$e" ]] || ok=1; done
    [[ "$ok" == "1" ]] || continue
    rest="${base#"$name".}"
    label=""
    [[ "$rest" != *.* ]] || label="${rest%.*}"
    trk_add_sidecar "$f" "$label" || true
  done
  [[ "$restore_nullglob" == "0" ]] || shopt -u nullglob
}

# Načte stopy souboru do polí TRK_*. $1=soubor; volitelně $2=adresář $3=jméno
# videa bez přípony -> přidá i titulky ze souborů vedle videa.
# Používá -count_packets, takže ffprobe přečte celý soubor.
probe_tracks() {
  local file="$1" line section="" cur=-1 na=0 ns=0
  TRK_N=0
  TRK_DURATION=""
  TRK_TYPE=(); TRK_REL=(); TRK_IDX=(); TRK_CODEC=(); TRK_TAG=(); TRK_TITLE=()
  TRK_PKTS=(); TRK_FORCED=(); TRK_HI=(); TRK_LANG=(); TRK_LSRC=()
  TRK_KIND=(); TRK_KSRC=(); TRK_EV=(); TRK_SKIP=(); TRK_FILE=(); TRK_CHARENC=()

  local probe_out
  probe_out="$(ffprobe -v error -count_packets \
    -show_entries stream=index,codec_type,codec_name,nb_read_packets:stream_tags=language,title:stream_disposition=forced,hearing_impaired:format=duration \
    -of default "$file")" || return 1

  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in
      '[STREAM]')
        section="stream"
        cur="$TRK_N"
        TRK_TYPE[cur]=""; TRK_REL[cur]="-1"; TRK_IDX[cur]=""; TRK_CODEC[cur]=""
        TRK_TAG[cur]=""; TRK_TITLE[cur]=""; TRK_PKTS[cur]="0"; TRK_FORCED[cur]="0"; TRK_HI[cur]="0"
        TRK_FILE[cur]=""; TRK_CHARENC[cur]=""
        ;;
      '[/STREAM]')
        section=""
        case "${TRK_TYPE[cur]}" in
          audio)    TRK_REL[cur]="$na"; na=$((na + 1)); TRK_N=$((TRK_N + 1)) ;;
          subtitle) TRK_REL[cur]="$ns"; ns=$((ns + 1)); TRK_N=$((TRK_N + 1)) ;;
          *) ;;  # video/přílohy/data: slot se přepíše další stopou
        esac
        ;;
      '[FORMAT]')  section="format" ;;
      '[/FORMAT]') section="" ;;
      *)
        if [[ "$section" == "stream" ]]; then
          case "$line" in
            index=*)                        TRK_IDX[cur]="${line#index=}" ;;
            codec_type=*)                   TRK_TYPE[cur]="${line#codec_type=}" ;;
            codec_name=*)                   TRK_CODEC[cur]="${line#codec_name=}" ;;
            nb_read_packets=*)              TRK_PKTS[cur]="${line#nb_read_packets=}" ;;
            DISPOSITION:forced=*)           TRK_FORCED[cur]="${line#DISPOSITION:forced=}" ;;
            DISPOSITION:hearing_impaired=*) TRK_HI[cur]="${line#DISPOSITION:hearing_impaired=}" ;;
            TAG:language=*)                 TRK_TAG[cur]="${line#TAG:language=}" ;;
            TAG:title=*)                    TRK_TITLE[cur]="${line#TAG:title=}" ;;
          esac
        elif [[ "$section" == "format" && "$line" == duration=* ]]; then
          local d="${line#duration=}"
          [[ "$d" =~ ^[0-9]+ ]] && TRK_DURATION="${BASH_REMATCH[0]}"
        fi
        ;;
    esac
  done <<<"$probe_out"

  [[ "$TRK_DURATION" =~ ^[0-9]+$ && "$TRK_DURATION" -ge 60 ]] || TRK_DURATION=""
  [[ $# -lt 3 ]] || trk_scan_sidecars "$2" "$3"
  trk_classify
}

# Doplní TRK_LANG/LSRC/KIND/KSRC/EV/SKIP. Volá se z probe_tracks a znovu po
# přidání titulků ze souboru (jazyk těchto stop určuje už trk_add_sidecar).
trk_classify() {
  local i norm tag_lang title_lang
  local -a norms=()

  # 1) jazyk, vyřazené stopy, odhad počtu titulků
  for ((i=0; i<TRK_N; i++)); do
    norm="$(trk_normalize "${TRK_TITLE[i]}")"
    norms[i]="$norm"
    trk_lang_from_tag "${TRK_TAG[i]}"; tag_lang="$_TRK_R"
    trk_lang_from_title "$norm";       title_lang="$_TRK_R"

    if [[ -n "${TRK_FILE[i]}" ]]; then
      :  # jazyk už určil trk_add_sidecar
    elif [[ "$title_lang" == "cs" || "$title_lang" == "sk" ]]; then
      TRK_LANG[i]="$title_lang"
      if [[ "$tag_lang" == "$title_lang" ]]; then
        TRK_LSRC[i]="tag+název"
      else
        TRK_LSRC[i]="název (tag '${TRK_TAG[i]:-žádný}')"
      fi
    elif [[ "$tag_lang" != "und" ]]; then
      TRK_LANG[i]="$tag_lang"; TRK_LSRC[i]="tag"
    elif [[ -n "$title_lang" ]]; then
      TRK_LANG[i]="$title_lang"; TRK_LSRC[i]="název"
    else
      TRK_LANG[i]="und"; TRK_LSRC[i]="neurčen"
    fi

    TRK_SKIP[i]=""
    if [[ "$norm" =~ $TRK_RE_COMMENT ]]; then
      TRK_SKIP[i]="komentář"
    fi
    TRK_EV[i]=0
    TRK_KIND[i]=""
    TRK_KSRC[i]=""
    if [[ "${TRK_TYPE[i]}" == "subtitle" ]]; then
      if [[ "${TRK_HI[i]}" == "1" || "$norm" =~ $TRK_RE_SDH ]]; then
        TRK_SKIP[i]="sdh"
      fi
      if [[ "${TRK_PKTS[i]}" =~ ^[0-9]+$ ]]; then
        TRK_EV[i]="${TRK_PKTS[i]}"
        [[ "${TRK_CODEC[i]}" == "hdmv_pgs_subtitle" ]] && TRK_EV[i]=$(( TRK_PKTS[i] / 2 ))
      fi
      if [[ -z "${TRK_SKIP[i]}" && "${TRK_EV[i]}" -le 0 ]]; then
        TRK_SKIP[i]="prázdná"
      fi
      if [[ -n "${TRK_FILE[i]}" ]] && ! trk_is_text_codec "${TRK_CODEC[i]}"; then
        TRK_SKIP[i]="obrazové titulky ze souboru (VobSub) nejsou podporované"
      fi
    fi
  done

  # 2) největší počet titulků mezi běžnými stopami (bez SDH/komentářů)
  local maxev=0
  for ((i=0; i<TRK_N; i++)); do
    [[ "${TRK_TYPE[i]}" == "subtitle" && -z "${TRK_SKIP[i]}" ]] || continue
    (( TRK_EV[i] > maxev )) && maxev="${TRK_EV[i]}"
  done

  # 3) druh titulků
  local ev rate count_kind
  for ((i=0; i<TRK_N; i++)); do
    [[ "${TRK_TYPE[i]}" == "subtitle" ]] || continue
    norm="${norms[i]}"
    ev="${TRK_EV[i]}"
    # titulků za minutu * 100 (celá čísla), prázdné = délka neznámá
    rate=""
    [[ -n "$TRK_DURATION" ]] && rate=$(( ev * 6000 / TRK_DURATION ))

    # Typický film: plné titulky 6–15/min, forced do 1/min.
    count_kind="unknown"
    if   [[ -n "$rate" ]] && (( rate >= 600 )); then count_kind="full"
    elif [[ -n "$rate" ]] && (( rate < 150 )); then count_kind="forced"
    elif (( maxev > 0 && ev * 4 <= maxev )); then count_kind="forced"
    elif [[ -n "$rate" ]] && (( rate >= 300 )); then count_kind="full"
    elif [[ -z "$rate" ]] && (( ev >= 300 )); then count_kind="full"
    fi

    if [[ "$norm" =~ $TRK_RE_FORCED ]]; then
      TRK_KIND[i]="forced"; TRK_KSRC[i]="název"
    elif [[ "$norm" =~ $TRK_RE_FULL ]]; then
      TRK_KIND[i]="full"; TRK_KSRC[i]="název"
    elif [[ "${TRK_FORCED[i]}" == "1" ]]; then
      # Některé releasy označí jako forced i plné titulky, aby se zobrazily.
      if [[ -n "$rate" ]] && (( rate >= 600 )); then
        TRK_KIND[i]="full"; TRK_KSRC[i]="počet titulků (příznak forced ignorován)"
      else
        TRK_KIND[i]="forced"; TRK_KSRC[i]="příznak"
      fi
    else
      TRK_KIND[i]="$count_kind"
      if [[ "$count_kind" == "unknown" ]]; then
        TRK_KSRC[i]="nelze určit"
      else
        TRK_KSRC[i]="počet titulků"
      fi
    fi
  done
}

# Najde pozici v polích TRK_* podle typu a relativního indexu. $1=typ $2=rel
# Vypíše pozici nebo nic.
trk_find() {
  local i
  for ((i=0; i<TRK_N; i++)); do
    if [[ "${TRK_TYPE[i]}" == "$1" && "${TRK_REL[i]}" == "$2" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
}

# Označení stopy pro výpis: s:N, nebo název souboru. $1=pozice v TRK_*
trk_spec() {
  if [[ -n "${TRK_FILE[$1]}" ]]; then
    printf 'soubor %s' "${TRK_FILE[$1]##*/}"
  else
    printf 's:%s' "${TRK_REL[$1]}"
  fi
}

# Vstupní volby FFmpeg pro titulky ze souboru (kódování, snímková frekvence
# pro MicroDVD). Výsledek v poli _TRK_OPTS. $1=pozice v TRK_* $2=video
trk_sidecar_input_opts() {
  local fps
  _TRK_OPTS=()
  [[ "${TRK_CHARENC[$1]}" != "CP1250" ]] || _TRK_OPTS+=(-sub_charenc CP1250)
  if [[ "${TRK_CODEC[$1]}" == "microdvd" ]]; then
    # MicroDVD má časy ve snímcích; použije se, jen když soubor neuvádí vlastní fps
    fps="$(ffprobe -v error -select_streams V:0 -show_entries stream=r_frame_rate \
      -of default=noprint_wrappers=1:nokey=1 "$2" 2>/dev/null | head -n1)"
    [[ ! "$fps" =~ ^[0-9]+/[1-9][0-9]*$ ]] || _TRK_OPTS+=(-subfps "$fps")
  fi
}

# ISO 639-2/T kód pro MP4 metadata. $1=cs|sk|en
trk_iso3() {
  case "$1" in
    cs) printf 'ces' ;;
    sk) printf 'slk' ;;
    en) printf 'eng' ;;
  esac
}

# Přepíše styl Default v ASS souboru (žluté Arial 30 se stínem). $1=soubor
replace_default_style() {
  local file="$1"
  local style='Style: Default,Arial,30,\&H0000FFFF,\&H000000FF,\&H00000000,\&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1'
  local tmp="${file}.style.$$"
  awk -v style="$style" '/^Style: Default,/ { print style; next } { print }' "$file" > "$tmp" && mv "$tmp" "$file"
}
