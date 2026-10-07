#!/usr/bin/env bash
# GitDrip GitHub API (P13). Requires common, logger, auth sourced; jq for parsing.
# Token is read from $GITDRIP_HOME/credentials and handed to curl through `-K -` (stdin): never in argv, env, URL or logs.
# Env: GITDRIP_API (default https://api.github.com; tests point it at a local mock), GITDRIP_API_TIMEOUT (default 15 s).
# CLI: gitdrip github whoami | repos | branches <owner/repo> | check <owner/repo> | create <name> [--public] [--desc TEXT]
# Failures print `github: [class] message` on stderr (class: auth|ratelimit|notfound|transient|fatal) and return 1.

_GH_SLUG_RE='^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$'
_GH_REPO_SHAPE='{full_name, private, fork, archived, default_branch, html_url, push:(.permissions.push // false)}'

_gh_fail() { printf 'github: [%s] %s\n' "$1" "$2" >&2; return 1; }

# gh_slug_from_url <url> -> owner/repo (https or ssh github.com URL), else return 1
gh_slug_from_url() {
  local s
  s="$(printf '%s' "$1" | sed -n -E 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$#\2#p')"
  s="${s%.git}"
  _gh_slug_ok "$s" && printf '%s' "$s"
}

_gh_slug_ok() { # owner/repo, no "." / ".." segments (URL path safety)
  [[ "$1" =~ $_GH_SLUG_RE && "$1" != ./* && "$1" != ../* && "$1" != */. && "$1" != */.. ]]
}

# gh_api <METHOD> <path> [body-file]: body -> stdout; sets GH_STATUS. Returns 0 on 2xx, else prints classified error.
gh_api() {
  local m="$1" path="$2" body="${3:-}" tok hdr out code rc=0 cls msg rem
  tok="$(_cred_field token)"
  [[ -n "$tok" ]] || { GH_STATUS=0; _gh_fail auth "no token stored (run: echo TOKEN | gitdrip auth set --user NAME)"; return 1; }
  hdr="$(mktemp)"; out="$(mktemp)"
  local -a a=(-sS -L --max-redirs 3 -m "${GITDRIP_API_TIMEOUT:-15}" -X "$m" -o "$out" -D "$hdr" -w '%{http_code}'
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' -K -)
  [[ -z "$body" ]] || a+=(-H 'Content-Type: application/json' --data-binary "@$body")
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | curl "${a[@]}" "${GITDRIP_API:-https://api.github.com}$path" 2>/dev/null)" || rc=$?
  GH_STATUS="${code:-0}"
  if [[ $rc -ne 0 || ! "$GH_STATUS" =~ ^[0-9]{3}$ || "$GH_STATUS" == 000 ]]; then
    rm -f "$hdr" "$out"; GH_STATUS=0; _gh_fail transient "network error talking to GitHub"; return 1
  fi
  if [[ "$GH_STATUS" =~ ^2 ]]; then cat "$out"; rm -f "$hdr" "$out"; return 0; fi
  msg=""; have jq && msg="$(jq -r '.message // empty' "$out" 2>/dev/null | head -n1 | cut -c1-160 | _log_redact)"
  rem="$(tr -d '\r' < "$hdr" | sed -n -E 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]emaining:[[:space:]]*([0-9]+).*/\1/p' | head -n1)"
  rm -f "$hdr" "$out"
  case "$GH_STATUS" in
    401) cls=auth;      msg="bad or expired token${msg:+ ($msg)}" ;;
    403) if [[ "$rem" == 0 ]]; then cls=ratelimit; msg="API rate limit reached; try later"; else cls=auth; msg="token lacks permission${msg:+ ($msg)}"; fi ;;
    404) cls=notfound;  msg="not found, or the token has no access to it" ;;
    429) cls=ratelimit; msg="API rate limit reached; try later" ;;
    5??) cls=transient; msg="GitHub server error ($GH_STATUS)" ;;
    *)   cls=fatal;     msg="HTTP $GH_STATUS${msg:+: $msg}" ;;
  esac
  _gh_fail "$cls" "$msg"
}

# whoami -> {login,id,name,noreply_email,token_kind,user_matches}
gh_whoami() {
  have jq || { _gh_fail fatal "jq required (pkg install jq)"; return 1; }
  local r tok kind=classic; tok="$(_cred_field token)"
  [[ "$tok" == github_pat_* ]] && kind=fine-grained
  r="$(gh_api GET /user)" || return 1
  printf '%s' "$r" | jq -c --arg kind "$kind" --arg su "$(_cred_field user)" '
    {login, id, name:(.name // ""), noreply_email:"\(.id)+\(.login)@users.noreply.github.com", token_kind:$kind,
     user_matches:(($su|ascii_downcase) == (.login|ascii_downcase))}'
}

# gh_identity -> "login<TAB>noreply_email" (empty + return 1 when unavailable); used to fill a missing git identity
gh_identity() {
  GITDRIP_API_TIMEOUT=8 gh_whoami 2>/dev/null | jq -r '[.login,.noreply_email]|@tsv'
}

# repos -> [{full_name,private,fork,archived,default_branch,html_url,push}] (up to 300, most recently pushed first)
gh_repos() {
  have jq || { _gh_fail fatal "jq required (pkg install jq)"; return 1; }
  local pg r all='[]'
  for pg in 1 2 3; do
    r="$(gh_api GET "/user/repos?per_page=100&page=$pg&sort=pushed&affiliation=owner,collaborator,organization_member")" || return 1
    all="$(jq -c -n --argjson a "$all" --argjson b "$r" '$a + $b')"
    [[ "$(printf '%s' "$r" | jq 'length')" -ge 100 ]] || break
  done
  printf '%s' "$all" | jq -c "[.[] | $_GH_REPO_SHAPE]"
}

# branches <owner/repo> -> {default_branch, branches:[{name,default}]} (default first)
gh_branches() {
  have jq || { _gh_fail fatal "jq required (pkg install jq)"; return 1; }
  _gh_slug_ok "${1:-}" || { _gh_fail fatal "usage: owner/repo"; return 1; }
  local repo br def
  repo="$(gh_api GET "/repos/$1")" || return 1
  def="$(printf '%s' "$repo" | jq -r '.default_branch // ""')"
  br="$(gh_api GET "/repos/$1/branches?per_page=100")" || return 1
  printf '%s' "$br" | jq -c --arg d "$def" '{default_branch:$d, branches:([.[]|{name, default:(.name==$d)}] | sort_by(.default|not))}'
}

# check <owner/repo> -> repo shape + eligible (not fork, not archived, push access) + warnings[]
gh_repo_check() {
  have jq || { _gh_fail fatal "jq required (pkg install jq)"; return 1; }
  _gh_slug_ok "${1:-}" || { _gh_fail fatal "usage: owner/repo"; return 1; }
  local r; r="$(gh_api GET "/repos/$1")" || return 1
  printf '%s' "$r" | jq -c "$_GH_REPO_SHAPE | .eligible = ((.fork|not) and (.archived|not) and .push)
    | .warnings = [ (if .fork then \"fork: commits on forks do not count on your graph\" else empty end),
                    (if .archived then \"archived: repository is read-only\" else empty end),
                    (if (.push|not) then \"token has no push access\" else empty end) ]"
}

# create <name> [--public] [--desc TEXT]: OFF unless config allow_create_repo=true; private by default; never auto_init
gh_create_repo() {
  have jq || { _gh_fail fatal "jq required (pkg install jq)"; return 1; }
  local name="${1:-}" priv=true desc="" b r; shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in --public) priv=false; shift ;; --desc) desc="${2:-}"; shift 2 ;; *) _gh_fail fatal "unknown option: $1"; return 1 ;; esac
  done
  [[ "$(config_get allow_create_repo)" == true ]] || { _gh_fail fatal "repo creation is disabled (enable: gitdrip config set allow_create_repo true)"; return 1; }
  [[ "$name" =~ ^[A-Za-z0-9._-]{1,100}$ && "$name" != . && "$name" != .. ]] || { _gh_fail fatal "invalid repo name"; return 1; }
  b="$(mktemp)"; jq -nc --arg n "$name" --argjson p "$priv" --arg d "${desc:0:300}" '{name:$n, private:$p, description:$d, auto_init:false}' > "$b"
  r="$(gh_api POST /user/repos "$b")" || { rm -f "$b"; return 1; }
  rm -f "$b"; log_info "github: created repo $name (private=$priv)"
  printf '%s' "$r" | jq -c "$_GH_REPO_SHAPE | .eligible = true | .warnings = []"
}

# _gh_elig <remote-url> -> "LEVEL<TAB>message" lines for preflight; silent when no token / jq / unreachable / not a github URL
_gh_elig() {
  [[ -n "$(_cred_field token)" ]] && have jq || return 0
  local slug c cur; slug="$(gh_slug_from_url "$1")" || return 0
  c="$(GITDRIP_API_TIMEOUT=8 gh_repo_check "$slug" 2>/dev/null)" || return 0
  cur="$(_git symbolic-ref --short HEAD 2>/dev/null || true)"
  printf '%s' "$c" | jq -r --arg cur "$cur" '
    (if .archived then "BLOCK\t\(.full_name) is archived (read-only)" else empty end),
    (if (.push|not) then "WARN\ttoken has no push access to \(.full_name); push will likely fail" else empty end),
    (if .fork then "WARN\t\(.full_name) is a fork; commits on forks do not count on your graph" else empty end),
    (if ($cur != "" and $cur != .default_branch) then "WARN\tbranch \u0027\($cur)\u0027 is not the repo default \u0027\(.default_branch)\u0027; commits will not count" else empty end),
    (if .eligible and ($cur == "" or $cur == .default_branch) then "OK\t\(.full_name): not a fork, push access, default branch" else empty end)'
}
