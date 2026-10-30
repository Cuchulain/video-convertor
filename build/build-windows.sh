#!/usr/bin/env bash
set -euo pipefail

# build-windows.sh
#
# Sestaví distribuci pro Windows do dist/:
#   video-convertor-windows-<verze>.zip  přenosná verze (rozbalit a spustit .cmd)
#   video-convertor-<verze>-setup.exe    instalátor NSIS (potřebuje makensis)
#   SHA256SUMS.txt                       kontrolní součty
#
# Verze se bere ze souboru VERSION. Před sestavením se ověří, že .ps1 mají
# UTF-8 BOM (jinak je Windows PowerShell 5.1 čte jako ANSI), .cmd mají CRLF
# a (pokud je k dispozici pwsh) že .ps1 jdou naparsovat.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="video-convertor"

INSTALLER="auto"   # auto | yes | no

log()  { printf '%s\n' "$*"; }
err()  { printf 'ERROR: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Použití:
  build/build-windows.sh [přepínače]

Přepínače:
  --no-installer       sestavit jen zip
  --require-installer  skončit chybou, pokud chybí makensis
  -h, --help           nápověda

makensis: macOS "brew install makensis", Debian/Ubuntu "apt install nsis".
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-installer)      INSTALLER="no"; shift ;;
    --require-installer) INSTALLER="yes"; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) err "Neznámý přepínač: $1"; usage; exit 1 ;;
  esac
done

VERSION="$(tr -d ' \r\n' < "$ROOT/VERSION")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  err "VERSION musí mít tvar X.Y.Z, je: '$VERSION'"
  exit 1
fi

# --- Kontroly ---------------------------------------------------------------

fail=0
for f in "$ROOT"/scripts/windows/*.ps1 "$ROOT"/packaging/windows/*.ps1; do
  if [[ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" != "efbbbf" ]]; then
    err "Chybí UTF-8 BOM: ${f#"$ROOT"/}"
    fail=1
  fi
done
for f in "$ROOT"/packaging/windows/*.cmd; do
  # každý řádek musí končit CR LF
  if [[ "$(grep -c $'\r$' "$f" || true)" != "$(wc -l < "$f" | tr -d ' ')" ]]; then
    err "Soubor nemá konce řádků CRLF: ${f#"$ROOT"/}"
    fail=1
  fi
done
if command -v pwsh >/dev/null 2>&1; then
  # argumenty za -Command se do $args nepředají -> seznam přes proměnnou prostředí
  if ! PS_FILES="$(printf '%s\n' "$ROOT"/scripts/windows/*.ps1 "$ROOT"/packaging/windows/*.ps1)" \
       pwsh -NoProfile -Command '
         $failed = $false
         foreach ($file in ($env:PS_FILES -split "`n" | Where-Object { $_ })) {
           $errors = $null
           [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
           foreach ($e in @($errors)) { Write-Host "ERROR: ${file}: $($e.Extent.StartLineNumber): $($e.Message)"; $failed = $true }
         }
         if ($failed) { exit 1 }'; then
    fail=1
  fi
else
  log "pwsh není k dispozici, kontrola syntaxe .ps1 přeskočena"
fi
[[ "$fail" == "0" ]] || exit 1

# --- Příprava distribuce ----------------------------------------------------

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/$APP"
mkdir -p "$PKG/scripts/windows" "$PKG/tools" "$DIST"

cp "$ROOT"/packaging/windows/*.cmd "$PKG/"
cp "$ROOT"/scripts/windows/*.ps1 "$PKG/scripts/windows/"
cp "$ROOT"/packaging/windows/user-path.ps1 "$ROOT"/packaging/windows/ffmpeg-setup.ps1 "$PKG/tools/"
cp "$ROOT"/README.md "$ROOT"/REQUIREMENTS.md "$ROOT"/CHANGELOG.md "$ROOT"/VERSION "$PKG/"

# --- Zip --------------------------------------------------------------------

# kontrolní součty všech sestavených balíčků
write_checksums() {
  local sum=(sha256sum)
  command -v sha256sum >/dev/null 2>&1 || sum=(shasum -a 256)
  (cd "$DIST" && "${sum[@]}" "$APP"-*"$VERSION"* > SHA256SUMS.txt)
  log "Kontrolní součty: ${DIST#"$ROOT"/}/SHA256SUMS.txt"
}

ZIP="$DIST/$APP-windows-$VERSION.zip"
rm -f "$DIST"/*"$VERSION"* "$DIST/SHA256SUMS.txt"
(cd "$STAGE" && zip -X -q -r "$ZIP" "$APP")
log "Zip: ${ZIP#"$ROOT"/}"

# --- Instalátor -------------------------------------------------------------

if [[ "$INSTALLER" == "no" ]]; then
  write_checksums
  exit 0
fi
if ! command -v makensis >/dev/null 2>&1; then
  if [[ "$INSTALLER" == "yes" ]]; then
    err "Chybí makensis (macOS: brew install makensis, Debian/Ubuntu: apt install nsis)"
    exit 1
  fi
  log "makensis není k dispozici, instalátor přeskočen (brew install makensis / apt install nsis)"
  write_checksums
  exit 0
fi

SETUP="$DIST/$APP-$VERSION-setup.exe"
makensis -V2 -INPUTCHARSET UTF8 \
  "-DVERSION=$VERSION" "-DSTAGEDIR=$PKG" "-DOUTFILE=$SETUP" \
  "$ROOT/packaging/windows/installer.nsi"
log "Instalátor: ${SETUP#"$ROOT"/}"
write_checksums
