#!/usr/bin/env bash
# GitDrip logger. Requires lib/common.sh sourced first.
# Format: 2026-10-03T12:00:00Z [LEVEL] message

_log_level_num() {
  case "${1^^}" in
    DEBUG) echo 10 ;; INFO) echo 20 ;; WARN) echo 30 ;; ERROR) echo 40 ;; *) echo 20 ;;
  esac
}

# Strip secrets before anything touches disk. Also masks the stored token literally.
_log_redact() {
  local tok="" esc=""
  if declare -F _cred_field >/dev/null; then tok="$(_cred_field token)"; fi
  [[ -z "$tok" ]] || esc="$(printf '%s' "$tok" | sed -e 's/[][\.*^$/|&]/\\&/g')"
  sed -E \
    -e 's/(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/[REDACTED]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED]/g' \
    -e 's/(AKIA|ASIA)[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/xox[abprs]-[A-Za-z0-9-]{10,}/[REDACTED]/g' \
    -e 's/AIza[0-9A-Za-z_-]{35}/[REDACTED]/g' \
    -e 's/sk_live_[0-9A-Za-z]{16,}/[REDACTED]/g' \
    -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----).*/\1 [REDACTED]/' \
    -e 's/([Aa]uthorization:[[:space:]]*([Bb]earer|[Tt]oken|[Bb]asic)[[:space:]]+)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/((password|passwd|token|secret|api[_-]?key)[=:][[:space:]]*)[^[:space:]&"'"'"']{8,}/\1[REDACTED]/Ig' \
    -e 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's/(auth-handoff[[:space:]]+[A-Za-z0-9-]+[[:space:]]+)[0-9a-f]{64}/\1[REDACTED]/g' \
  | { if [[ -n "$esc" ]]; then sed -e "s/$esc/[REDACTED]/g"; else cat; fi; }
}

_log_rotate() {
  local max size
  max="$(config_get log_max_bytes 1048576)"
  [[ -f "$GITDRIP_LOG_FILE" ]] || return 0
  size="$(wc -c < "$GITDRIP_LOG_FILE" | tr -d ' ')"
  if (( size > max )); then
    mv -f "$GITDRIP_LOG_FILE" "$GITDRIP_LOG_FILE.1"
  fi
}

# log_msg <LEVEL> <message...>
log_msg() {
  local level="${1^^}"; shift
  local min cur ts line
  min="$(_log_level_num "$(config_get log_level INFO)")"
  cur="$(_log_level_num "$level")"
  (( cur >= min )) || return 0
  mkdir -p "$GITDRIP_LOG_DIR"
  _log_rotate
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="$(printf '%s [%s] %s' "$ts" "$level" "$*" | _log_redact)"
  printf '%s\n' "$line" >> "$GITDRIP_LOG_FILE"
  [[ "$level" == "ERROR" || "$level" == "WARN" ]] && printf '%s\n' "$line" >&2
  return 0
}

log_debug() { log_msg DEBUG "$@"; }
log_info()  { log_msg INFO  "$@"; }
log_warn()  { log_msg WARN  "$@"; }
log_error() { log_msg ERROR "$@"; }
