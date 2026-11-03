#!/usr/bin/env bash
set -euo pipefail

# Video convertor pro TV – Jan Čejka, https://dev.jancejka.cz
# https://github.com/Cuchulain/video-convertor (licence MIT)
# Skutečná složka skriptu i při spuštění přes symlink (např. ~/bin/convert-for-tv.sh);
# bez readlink -f, které starší macOS nemá.
SCRIPT_SRC="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SRC" ]]; do
  SCRIPT_LINK_DIR="$(cd -P "$(dirname "$SCRIPT_SRC")" && pwd)"
  SCRIPT_SRC="$(readlink "$SCRIPT_SRC")"
  [[ "$SCRIPT_SRC" == /* ]] || SCRIPT_SRC="$SCRIPT_LINK_DIR/$SCRIPT_SRC"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SRC")" && pwd)"
exec "$SCRIPT_DIR/../extract-ass.sh" "$@"
