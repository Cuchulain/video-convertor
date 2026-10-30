#!/usr/bin/env bash
set -euo pipefail

# Video convertor pro TV – Jan Čejka, https://dev.jancejka.cz
# https://github.com/Cuchulain/video-convertor (licence MIT)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/../extract-ass.sh" "$@"
