#!/usr/bin/env bash
# GitDrip auth (P5). Requires common.sh, logger.sh sourced.
# Token lives ONLY in $GITDRIP_HOME/credentials (chmod 600): lines "user=NAME" / "token=VALUE".
# Git gets it through a credential helper (`gitdrip credential-helper`): never in URL, argv, env or logs.

GITDRIP_CRED="$GITDRIP_HOME/credentials"

_cred_field() { # <key>  -- value of key from credentials file (empty if none)
  [[ -f "$GITDRIP_CRED" ]] || return 0
  sed -n -E "s/^$1=(.*)$/\1/p" "$GITDRIP_CRED" | head -n1
}

_cred_perm_fix() {
  [[ -f "$GITDRIP_CRED" ]] || return 0
  local m; m="$(stat -c %a "$GITDRIP_CRED" 2>/dev/null || stat -f %Lp "$GITDRIP_CRED" 2>/dev/null || echo 600)"
  [[ "$m" == 600 ]] && return 0
  chmod 600 "$GITDRIP_CRED"; log_warn "credentials file had mode $m; fixed to 600"
}

_token_valid() { [[ "$1" =~ ^(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})$ ]]; }

# auth_set --user NAME   (token read from stdin / hidden prompt; never from argv)
auth_set() {
  local user="" tok="" tmp
  while [[ $# -gt 0 ]]; do
    case "$1" in --user) user="${2:-}"; shift 2 ;; *) die "unknown option: $1 (token is read from stdin, never argv)" ;; esac
  done
  [[ "$user" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || die "usage: gitdrip auth set --user GITHUB_USER  (token on stdin)"
  if [[ -t 0 ]]; then read -rsp "GitHub token (hidden): " tok; echo >&2; else IFS= read -r tok || true; fi
  tok="${tok//[$'\r\n ']/}"
  _token_valid "$tok" || die "token format not recognised (expect ghp_/gho_/ghu_/ghs_/ghr_ or github_pat_ token)"
  ensure_dirs
  tmp="$(umask 077; mktemp "$GITDRIP_HOME/.cred.XXXXXX")"
  printf 'user=%s\ntoken=%s\n' "$user" "$tok" > "$tmp"; chmod 600 "$tmp"; mv "$tmp" "$GITDRIP_CRED"
  log_info "auth set for user $user"; echo "credentials saved for $user (chmod 600)"
}

# auth_handoff <user> <enc-file>   (P14) key = 64 hex chars on stdin (never argv of any child process).
# <enc-file> = openssl `enc -aes-256-cbc -pbkdf2 -md sha256 -iter 10000` blob ("Salted__"+salt+ciphertext) written by the Android app.
# The file is ONE-TIME: removed on every path (success, bad key, bad token). Plaintext goes only into `auth_set` via a pipe.
auth_handoff() {
  local user="${1:-}" f="${2:-}" key="" tok="" rc=0
  IFS= read -r key || true
  if [[ ! "$key" =~ ^[0-9a-f]{64}$ ]]; then [[ -L "$f" ]] || rm -f "$f"; die "handoff: bad key"; fi
  if [[ -L "$f" || ! -f "$f" ]]; then rm -f "$f"; die "handoff: file missing"; fi
  if [[ "$(wc -c < "$f" | tr -d ' ')" -gt 1024 ]]; then rm -f "$f"; die "handoff: file too large"; fi
  if ! have openssl; then rm -f "$f"; die "handoff: openssl missing (pkg install openssl-tool)"; fi
  tok="$(printf '%s\n' "$key" | openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 -iter 10000 -pass stdin -in "$f" 2>/dev/null)" || rc=$?
  rm -f "$f"
  [[ $rc -eq 0 && -n "$tok" ]] || die "handoff: could not decrypt (wrong key or corrupt file)"
  printf '%s\n' "$tok" | auth_set --user "$user"
}

auth_clear() { rm -f "$GITDRIP_CRED"; log_info "auth cleared"; echo "credentials removed"; }

auth_status() {
  local u t m
  [[ -f "$GITDRIP_CRED" ]] || { echo "no credentials (run: gitdrip auth set --user NAME)"; return 1; }
  _cred_perm_fix
  u="$(_cred_field user)"; t="$(_cred_field token)"
  m="$(stat -c %a "$GITDRIP_CRED" 2>/dev/null || echo '?')"
  echo "user: $u  token: ${t:0:4}…(${#t} chars)  mode: $m"
}

# git credential helper: only answers `get` for https://github.com; store/erase are no-ops (never writes).
auth_credential_helper() {
  local op="${1:-}" k v host="" proto="" u t
  [[ "$op" == get ]] || { cat >/dev/null; return 0; }
  while IFS='=' read -r k v; do
    [[ -n "$k" ]] || break
    case "$k" in host) host="$v" ;; protocol) proto="$v" ;; esac
  done
  [[ "$proto" == https && "$host" == github.com ]] || return 0
  _cred_perm_fix; u="$(_cred_field user)"; t="$(_cred_field token)"
  [[ -n "$u" && -n "$t" ]] || return 0
  printf 'username=%s\npassword=%s\n' "$u" "$t"
}

# auth_git_args  -> sets AUTH_ARGS (git -c options wiring the helper; contains no secret)
auth_git_args() {
  AUTH_ARGS=(-c credential.helper= -c "credential.helper=!'${GITDRIP_APP}/bin/gitdrip' credential-helper")
}

# classify_push_error  (stdin: git output) -> auth | conflict | transient | fatal | unknown
classify_push_error() {
  local t; t="$(tr '[:upper:]' '[:lower:]')"
  case "$t" in
    *"authentication failed"*|*"invalid username or password"*|*"could not read username"*|*"could not read password"*|*"terminal prompts disabled"*|*"bad credentials"*|*"returned error: 401"*|*"returned error: 403"*|*"permission to "*" denied"*|*"permission denied"*) echo auth ;;
    *"non-fast-forward"*|*"fetch first"*|*"updates were rejected"*) echo conflict ;;
    *"gh013"*|*"protected branch"*|*"gh006"*|*"repository not found"*|*"does not appear to be a git repository"*|*"not found"*) echo fatal ;;
    *"could not resolve host"*|*"failed to connect"*|*"couldn't connect"*|*"could not connect"*|*"no route to host"*|*"name or service not known"*|*"gnutls_handshake"*|*"timed out"*|*"timeout"*|*"connection reset"*|*"connection refused"*|*"connection closed"*|*"early eof"*|*"remote end hung up"*|*"rpc failed"*|*"network is unreachable"*|*"temporary failure"*|*"broken pipe"*|*"returned error: 5"*|*"ssl"*|*"tls"*) echo transient ;;
    *) echo unknown ;;
  esac
}
