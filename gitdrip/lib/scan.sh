#!/usr/bin/env bash
# GitDrip secret scanner (P5). Requires common.sh sourced. Prints "file:line: rule" — NEVER the secret itself.
# Suppress a known-safe line with an inline marker: gitdrip:allow

_SCAN_RULES=(
  'github_token|(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})'
  'aws_access_key|(AKIA|ASIA)[0-9A-Z]{16}'
  'private_key|-----BEGIN ([A-Z]+ )?PRIVATE KEY( BLOCK)?-----'
  'slack_token|xox[abprs]-[A-Za-z0-9-]{10,}'
  'google_api_key|AIza[0-9A-Za-z_-]{35}'
  'stripe_live_key|sk_live_[0-9A-Za-z]{16,}'
  'generic_secret|(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\''[:space:]$<{}]{16,}["'\'']'
)

# secret filename check (basename)
_scan_bad_name() {
  case "$(basename "$1")" in
    .env.example|.env.sample|.env.template) return 1 ;;
    .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|id_rsa*|id_ed25519*|id_ecdsa*|credentials|.netrc|.npmrc|.pypirc) return 0 ;;
  esac
  return 1
}

# scan_file <abs path> [display name]  -> hits on stdout, return 1 if any
scan_file() {
  local f="$1" disp="${2:-$1}" hit=0 r name re out l
  if _scan_bad_name "$disp"; then echo "$disp:0: secret_filename"; hit=1; fi
  [[ -f "$f" ]] || return "$hit"
  for r in "${_SCAN_RULES[@]}"; do
    name="${r%%|*}"; re="${r#*|}"
    out="$(grep -I -n -i -E -e "$re" -- "$f" 2>/dev/null | grep -v 'gitdrip:allow' | cut -d: -f1 || true)"
    [[ -n "$out" ]] || continue
    while IFS= read -r l; do echo "$disp:$l: $name"; done <<< "$out"; hit=1
  done
  return "$hit"
}

# scan_dir <dir> -> scan every regular file (skips .git, node_modules)
scan_dir() {
  local d="$1" f rc=0
  while IFS= read -r -d '' f; do
    scan_file "$f" "${f#"$d"/}" || rc=1
  done < <(find "$d" \( -name .git -o -name node_modules \) -prune -o -type f -print0)
  return "$rc"
}
