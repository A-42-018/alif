#!/usr/bin/env bash
# GitDrip common helpers. Source only; do not execute.

GITDRIP_VERSION="0.17.0"

# Runtime data dir (config, logs, projects, tasks). Override with GITDRIP_HOME.
: "${GITDRIP_HOME:=$HOME/.gitdrip}"
export GITDRIP_HOME
GITDRIP_CONFIG="$GITDRIP_HOME/config.json"
GITDRIP_LOG_DIR="$GITDRIP_HOME/logs"
GITDRIP_LOG_FILE="$GITDRIP_LOG_DIR/execution.log"
GITDRIP_DIRS=(logs projects tasks locks)

die() { printf 'gitdrip: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

ensure_dirs() {
  local d
  mkdir -p "$GITDRIP_HOME" || die "cannot create $GITDRIP_HOME"
  for d in "${GITDRIP_DIRS[@]}"; do mkdir -p "$GITDRIP_HOME/$d"; done
}

# config_get <key> [default]  -- flat top-level keys only
config_get() {
  local key="$1" def="${2:-}" val=""
  if [[ -f "$GITDRIP_CONFIG" ]]; then
    if have jq; then
      val="$(jq -r --arg k "$key" '.[$k] // empty' "$GITDRIP_CONFIG" 2>/dev/null)"
    else
      val="$(sed -n -E "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"?([^\",}]*)\"?,?[[:space:]]*$/\1/p" "$GITDRIP_CONFIG" | head -n1)"
    fi
  fi
  printf '%s' "${val:-$def}"
}

# config_set <key> <value>  -- requires jq; value auto-typed (number/bool else string)
config_set() {
  have jq || die "jq required for config set (pkg install jq)"
  [[ -f "$GITDRIP_CONFIG" ]] || die "config missing; run install.sh"
  local key="$1" val="$2" tmp
  tmp="$(mktemp "$GITDRIP_HOME/.cfg.XXXXXX")"
  if jq --arg k "$key" --arg v "$val" \
      '.[$k] = ($v | try fromjson catch $v)' "$GITDRIP_CONFIG" > "$tmp"; then
    mv "$tmp" "$GITDRIP_CONFIG"
  else
    rm -f "$tmp"; die "failed to update config"
  fi
}
