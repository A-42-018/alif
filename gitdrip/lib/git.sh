#!/usr/bin/env bash
# GitDrip git engine (P3, P5 safety). Requires common, logger, manifest, batch, auth, scan sourced. Needs git + jq.
# Batch status flow: PENDING -> COMMITTED (local commit, push pending) -> SUCCESS | NOCHANGE (nothing to commit).
# Rules: only batch files are ever staged; never empty commits; never backdated; never force-push.

repo_dir() { printf '%s/repo' "$(project_dir "$1")"; }

_git() { git -C "$REPO" "$@"; }

_url_has_creds() { [[ "$1" =~ ://[^/@]+(:[^/@]*)?@ ]] || [[ "$1" =~ (ghp_|gho_|github_pat_) ]]; }

# batch_field <project> <id> <jq-expr>
_batch_get() { jq -r --argjson id "$2" ".batches[]|select(.id==\$id)|$3" "$(project_dir "$1")/batches.json"; }

# _batch_set <project> <id> <status> [commit]
_batch_set() {
  local f; f="$(project_dir "$1")/batches.json"
  jq --argjson id "$2" --arg s "$3" --arg c "${4:-}" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.batches |= map(if .id==$id then .status=$s | (if $c!="" then .commit=$c else . end) | .updated_at=$t else . end)' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# git_repo_init <project> [--remote URL] [--branch B] [--user N] [--email E]
git_repo_init() {
  have git || die "git required (pkg install git)"
  local p="$1"; shift
  local remote="" branch="" user="" email=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) remote="${2:-}"; shift 2 ;; --branch) branch="${2:-}"; shift 2 ;;
      --user) user="${2:-}"; shift 2 ;; --email) email="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -d "$(project_dir "$p")" ]] || die "unknown project: $p"
  [[ -z "$remote" ]] || { _url_has_creds "$remote" && die "remote URL must not contain credentials (use: gitdrip auth set)"; }
  branch="${branch:-$(config_get default_branch main)}"
  REPO="$(repo_dir "$p")"
  if [[ ! -d "$REPO/.git" ]]; then
    mkdir -p "$REPO"; git -C "$REPO" init -q
    git -C "$REPO" symbolic-ref HEAD "refs/heads/$branch"
  fi
  [[ -z "$user" ]] || _git config user.name "$user"
  [[ -z "$email" ]] || _git config user.email "$email"
  if [[ -n "$remote" ]]; then
    if _git remote get-url origin >/dev/null 2>&1; then _git remote set-url origin "$remote"; else _git remote add origin "$remote"; fi
  fi
  gitignore_merge "$REPO"
  log_info "repo-init $p branch=$branch remote=$([[ -n "$remote" ]] && echo set || echo none)"
  echo "repo ready: $REPO (branch $branch)"
}

# .gitignore merge: append missing secret/junk patterns, keep user lines (idempotent)
gitignore_merge() {
  local gi="$1/.gitignore" pat
  [[ -f "$gi" ]] || : > "$gi"
  for pat in .env '.env.*' '!.env.example' '*.pem' '*.key' '*.p12' '*.pfx' '*.jks' '*.keystore' 'id_rsa*' 'id_ed25519*' .netrc node_modules/ .DS_Store '*.log'; do
    grep -qxF -- "$pat" "$gi" || printf '%s\n' "$pat" >> "$gi"
  done
}

# _elig_checks <project> -> lines "LEVEL<TAB>message" (OK|WARN|BLOCK). Fork/archived/default-branch checks come from the GitHub API (_gh_elig, P13).
_elig_checks() {
  local p="$1" email user cur def verified url cu today n cap tabs=$'\t'
  email="$(_git config user.email || true)"; user="$(_git config user.name || true)"
  if [[ -z "$email" || -z "$user" ]]; then
    printf 'BLOCK\tgit identity missing; run: gitdrip repo-init %s --user NAME --email EMAIL\n' "$p"
  else
    verified="$(config_get verified_emails)"
    if [[ "$email" =~ @users\.noreply\.github\.com$ ]] || [[ ",$verified," == *",$email,"* ]]; then
      printf 'OK\tauthor email %s is noreply/verified\n' "$email"
    else
      printf 'WARN\temail '"'%s'"' is not a noreply address or in config verified_emails; commits may not count on your graph\n' "$email"
    fi
    cu="$(_cred_field user)"
    if [[ -n "$cu" && "$email" =~ ^([0-9]+\+)?([A-Za-z0-9-]+)@users\.noreply\.github\.com$ && "${BASH_REMATCH[2],,}" != "${cu,,}" ]]; then
      printf 'WARN\tnoreply email user '"'%s'"' differs from authenticated user '"'%s'"'; commits may not count\n' "${BASH_REMATCH[2]}" "$cu"
    fi
  fi
  def="$(config_get default_branch main)"
  cur="$(_git symbolic-ref --short HEAD 2>/dev/null || echo "")"
  if [[ "$cur" == "$def" ]]; then printf 'OK\tbranch %s is default\n' "$cur"
  else printf 'WARN\tbranch '"'%s'"' is not default '"'%s'"'; commits on it will not count\n' "$cur" "$def"; fi
  if url="$(_git remote get-url origin 2>/dev/null)"; then
    if _url_has_creds "$url"; then printf 'BLOCK\tremote URL contains credentials; fix with: gitdrip repo-init %s --remote CLEAN_URL\n' "$p"
    elif [[ "$url" =~ ^(https://|git@|ssh://)github\.com[/:] ]]; then
      printf 'OK\tremote is github.com\n'
      _gh_elig "$url"
      [[ ! "$url" =~ ^https:// || -n "$(_cred_field token)" ]] || printf 'WARN\tno credentials stored for https push; run: gitdrip auth set --user NAME\n'
    elif [[ "$url" =~ ^(https?://|git@|ssh://) ]]; then printf 'WARN\tremote is not github.com; commits will not count on your GitHub graph\n'
    else printf 'OK\tremote is local path (test/mirror)\n'; fi
  else printf 'WARN\tno remote '"'origin'"'; commit will stay local\n'; fi
  today="$(date -u +%Y-%m-%d)"; cap="$(config_get max_commits_per_day 3)"
  n="$(jq -r --arg d "$today" '[.batches[]|select((.status=="SUCCESS" or .status=="COMMITTED") and ((.updated_at//"")|startswith($d)))]|length' "$(project_dir "$p")/batches.json" 2>/dev/null || echo 0)"
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= cap )); then printf 'WARN\t%s commit(s) already today (max_commits_per_day=%s)\n' "$n" "$cap"
  else printf 'OK\t%s/%s commits today\n' "${n:-0}" "$cap"; fi
}

# git_preflight <project>: BLOCK = die, WARN = log. Requires REPO.
git_preflight() {
  local lv msg
  while IFS=$'\t' read -r lv msg; do
    case "$lv" in BLOCK) die "preflight: $msg" ;; WARN) log_warn "preflight: $msg" ;; esac
  done < <(_elig_checks "$1")
}

# git_preflight_report <project> -> prints all checks; exit 1 if any BLOCK
git_preflight_report() {
  REPO="$(repo_dir "$1")"; [[ -d "$REPO/.git" ]] || die "no repo for $1"
  local lv msg rc=0
  while IFS=$'\t' read -r lv msg; do printf '[%s] %s\n' "$lv" "$msg"; [[ "$lv" != BLOCK ]] || rc=1; done < <(_elig_checks "$1")
  echo "[INFO] private repos: enable Profile > Contribution settings > Private contributions to show them"
  return "$rc"
}

# _push: uses credential helper; sets PUSH_CLASS (auth|conflict|transient|fatal|unknown) on failure
_push() {
  local br out rc=0 l; PUSH_CLASS=""
  br="$(_git symbolic-ref --short HEAD)"
  _git remote get-url origin >/dev/null 2>&1 || { log_warn "no origin remote; not pushed"; return 2; }
  auth_git_args
  out="$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git -C "$REPO" "${AUTH_ARGS[@]}" push -q origin "HEAD:refs/heads/$br" 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    PUSH_CLASS="$(printf '%s' "$out" | classify_push_error)"
    while IFS= read -r l; do log_warn "push: $l"; done < <(printf '%s\n' "$out" | _log_redact)
  fi
  return "$rc"
}

# git_run_batch <project> <id> [--dry] [--no-push]  -> exit 0 ok/skip, 3 no change, 1 error
git_run_batch() {
  have git || die "git required"; have jq || die "jq required"
  local p="$1" id="$2"; shift 2
  local dry=0 nopush=0 pd st msg f src rel n changed=() staged hits
  [[ "$(config_get dry_run false)" == "true" ]] && dry=1
  while [[ $# -gt 0 ]]; do case "$1" in --dry) dry=1 ;; --no-push) nopush=1 ;; *) die "unknown option: $1" ;; esac; shift; done
  [[ "$id" =~ ^[0-9]+$ ]] || die "batch id must be a number"
  pd="$(project_dir "$p")"; [[ -f "$pd/batches.json" ]] || die "no batches for $p"
  REPO="$(repo_dir "$p")"; [[ -d "$REPO/.git" ]] || die "no repo; run: gitdrip repo-init $p --remote URL --user N --email E"
  st="$(_batch_get "$p" "$id" .status)"; [[ -n "$st" ]] || die "batch $id not found"
  msg="$(_batch_get "$p" "$id" .message)"

  case "$st" in
    SUCCESS)  echo "batch $id already SUCCESS; nothing to do"; return 0 ;;
    NOCHANGE) echo "batch $id already NOCHANGE; nothing to do"; return 0 ;;
    COMMITTED)
      [[ $dry -eq 0 ]] || { echo "[dry] batch $id committed locally; would push"; return 0; }
      git_preflight "$p"
      if [[ $nopush -eq 1 ]]; then echo "batch $id committed; push skipped"; return 0; fi
      local vrc=0; retry_verify_commit "$p" "$id" || vrc=$?
      case "$vrc" in
        10) _batch_set "$p" "$id" SUCCESS; log_info "batch $id already on remote; marked SUCCESS"; echo "batch $id already on remote; no push needed"; return 0 ;;
        11) log_error "push failed [fatal] commit for batch $id is missing from local history; not pushing"; return 1 ;;
      esac
      if _push; then _batch_set "$p" "$id" SUCCESS; log_info "batch $id pushed (resume)"; echo "pushed batch $id"; return 0; fi
      log_error "push failed [${PUSH_CLASS:-unknown}] for batch $id (commit kept locally)"; return 1 ;;
  esac

  # PENDING: compare source vs repo, only for this batch's files
  while IFS= read -r rel; do
    src="$pd/source/$rel"; [[ -f "$src" ]] || die "missing source file: $rel"
    if [[ ! -f "$REPO/$rel" ]] || ! cmp -s "$src" "$REPO/$rel"; then changed+=("$rel"); fi
  done < <(jq -r --argjson id "$id" '.batches[]|select(.id==$id)|.files[]' "$pd/batches.json")

  if [[ ${#changed[@]} -eq 0 ]]; then
    [[ $dry -eq 1 ]] && { echo "[dry] no changes; would STOP (no empty commit)"; return 3; }
    _batch_set "$p" "$id" NOCHANGE; log_info "batch $id: no changes, stopped"; echo "no changes; nothing committed"; return 3
  fi
  hits="$(for rel in "${changed[@]}"; do scan_file "$pd/source/$rel" "$rel" || true; done)"
  if [[ -n "$hits" ]]; then
    log_error "secret_blocked: batch $id: $(printf '%s' "$hits" | head -n3 | tr '\n' ';')"
    printf 'secret_blocked: batch %s has potential secrets (batch stays PENDING):\n%s\n' "$id" "$hits" >&2
    return 6
  fi
  if [[ $dry -eq 1 ]]; then
    echo "[dry] would commit \"$msg\" with ${#changed[@]} file(s):"; printf '  %s\n' "${changed[@]}"; return 0
  fi

  git_preflight "$p"
  staged="$(_git diff --cached --name-only)"
  [[ -z "$staged" ]] || die "repo has unrelated staged files; refusing to commit: $(echo "$staged" | head -n3 | tr '\n' ' ')"
  for rel in "${changed[@]}"; do
    mkdir -p "$REPO/$(dirname "$rel")"; cp -p "$pd/source/$rel" "$REPO/$rel"
  done
  _git add -- "${changed[@]}"
  staged="$(_git diff --cached --name-only)"
  if [[ -z "$staged" ]]; then
    _batch_set "$p" "$id" NOCHANGE; log_info "batch $id: nothing staged, stopped"; echo "no changes; nothing committed"; return 3
  fi
  _git commit -q -m "$msg" || { _git reset -q; die "commit failed"; }
  n="$(_git rev-parse HEAD)"
  _batch_set "$p" "$id" COMMITTED "$n"
  log_info "batch $id committed ${n:0:7} (${#changed[@]} files)"
  echo "committed ${n:0:7}: $msg"
  [[ $nopush -eq 0 ]] || { echo "push skipped (--no-push)"; return 0; }
  if _push; then _batch_set "$p" "$id" SUCCESS; log_info "batch $id pushed"; echo "pushed"; return 0; fi
  log_error "push failed [${PUSH_CLASS:-unknown}] for batch $id; commit ${n:0:7} kept locally (rerun to retry push)"; return 1
}

git_status() {
  local p="$1"; REPO="$(repo_dir "$p")"; [[ -d "$REPO/.git" ]] || die "no repo for $p"
  echo "branch: $(_git symbolic-ref --short HEAD)  commits: $(_git rev-list --count HEAD 2>/dev/null || echo 0)"
  echo "remote: $(_git remote get-url origin 2>/dev/null | _log_redact || echo none)"
  echo "identity: $(_git config user.name || echo '?') <$(_git config user.email || echo '?')>"
  _git status --short
}
