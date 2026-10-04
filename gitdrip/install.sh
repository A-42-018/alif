#!/usr/bin/env bash
# GitDrip installer (Termux or generic Linux). Idempotent.
set -euo pipefail

APP="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${GITDRIP_HOME:=$HOME/.gitdrip}"

if [[ -n "${PREFIX:-}" && -d "$PREFIX/bin" ]]; then
  BIN_DIR="$PREFIX/bin"
else
  BIN_DIR="${GITDRIP_BIN_DIR:-$HOME/.local/bin}"
fi

echo "==> deps"
if command -v pkg >/dev/null 2>&1; then
  pkg install -y git curl jq cronie termux-services >/dev/null 2>&1 || echo "warn: pkg install failed; install git curl jq manually"
else
  for t in git curl jq; do command -v "$t" >/dev/null 2>&1 || echo "warn: missing $t"; done
fi

echo "==> dirs: $GITDRIP_HOME"
mkdir -p "$GITDRIP_HOME"/{logs,projects,tasks,locks}
if [[ ! -f "$GITDRIP_HOME/config.json" ]]; then
  cp "$APP/config/config.json" "$GITDRIP_HOME/config.json"
  echo "created config.json"
else
  echo "config.json exists; kept"
fi
chmod 700 "$GITDRIP_HOME"

echo "==> link: $BIN_DIR/gitdrip"
mkdir -p "$BIN_DIR"
chmod +x "$APP/bin/gitdrip"
ln -sf "$APP/bin/gitdrip" "$BIN_DIR/gitdrip"

case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: add $BIN_DIR to PATH" ;; esac

"$BIN_DIR/gitdrip" log "installed v$("$BIN_DIR/gitdrip" version | cut -d' ' -f2)"
echo "done. try: gitdrip --help"
