#!/usr/bin/env bash
# GitDrip PR flow (P7.5). Requires common, logger, auth, github, git, runner (lock) sourced; needs git + jq + token.
# CLI: gitdrip issue create <o/r> --title T [--body B]
#      gitdrip pr open <o/r> --head BR --title T [--base BR] [--body B]
#      gitdrip pr merge <o/r> <number> [--method squash|merge|rebase]
#      gitdrip pr-flow <project> <batch-id> [--issue] [--merge] [--method M] [--dry]
# pr-flow = real batch commit on branch gitdrip/<project>-batch-<id> (cut from the repo default branch) -> push -> [issue] -> PR -> [merge].
# Rules: no empty PRs (no change = STOP, branch dropped), never force-push, merge only with --merge, one PR per batch (rerun resumes).

_GH_BRANCH_RE='^[A-Za-z0-9._/-]{1,100}$'

_gh_body() { # _gh_body <jq-args...> -> temp file path with JSON (caller removes)
  local f; f="$(mktemp)"; jq -nc "$@" > "$f" && printf '%s' "$f"
}

# gh_issue_create <o/r> <title> [body] -> {number,html_url}
gh_issue_create() {
  have jq || { _gh_fail fatal "jq required"; return 1; }
  _gh_slug_ok "${1:-}" || { _gh_fail fatal "usage: owner/repo"; return 1; }
  [[ -n "${2:-}" ]] || { _gh_fail fatal "title required"; return 1; }
  local b r; b="$(_gh_body --arg t "${2:0:200}" --arg b "${3:0:4000}" '{title:$t, body:$b}')"
  r="$(gh_api POST "/repos/$1/issues" "$b")" || { rm -f "$b"; return 1; }
  rm -f "$b"; printf '%s' "$r" | jq -c '{number, html_url}'
}

# gh_pr_find <o/r> <head-branch> -> {number,html_url} of the open PR for that head, or empty
gh_pr_find() {
  _gh_slug_ok "${1:-}" && [[ "${2:-}" =~ $_GH_BRANCH_RE ]] || { _gh_fail fatal "bad repo or branch"; return 1; }
  local r; r="$(gh_api GET "/repos/$1/pulls?state=open&per_page=1&head=${1%%/*}:$2")" || return 1
  printf '%s' "$r" | jq -c '.[0] // empty | {number, html_url}'
}

# gh_pr_open <o/r> <head> <base> <title> [body] -> {number,html_url}
gh_pr_open() {
  have jq || { _gh_fail fatal "jq required"; return 1; }
  _gh_slug_ok "${1:-}" && [[ "${2:-}" =~ $_GH_BRANCH_RE && "${3:-}" =~ $_GH_BRANCH_RE ]] || { _gh_fail fatal "bad repo or branch"; return 1; }
  [[ -n "${4:-}" ]] || { _gh_fail fatal "title required"; return 1; }
  local b r; b="$(_gh_body --arg t "${4:0:200}" --arg h "$2" --arg base "$3" --arg d "${5:0:4000}" '{title:$t, head:$h, base:$base, body:$d}')"
  r="$(gh_api POST "/repos/$1/pulls" "$b")" || { rm -f "$b"; return 1; }
  rm -f "$b"; printf '%s' "$r" | jq -c '{number, html_url}'
}

# gh_pr_merge <o/r> <number> [method] -> {merged,sha}
gh_pr_merge() {
  have jq || { _gh_fail fatal "jq required"; return 1; }
  local m="${3:-squash}" b r
  _gh_slug_ok "${1:-}" && [[ "${2:-}" =~ ^[0-9]+$ && "$m" =~ ^(squash|merge|rebase)$ ]] || { _gh_fail fatal "usage: owner/repo number [squash|merge|rebase]"; return 1; }
  b="$(_gh_body --arg m "$m" '{merge_method:$m}')"
  r="$(gh_api PUT "/repos/$1/pulls/$2/merge" "$b")" || { rm -f "$b"; return 1; }
  rm -f "$b"; printf '%s' "$r" | jq -c '{merged:(.merged // false), sha:(.sha // "")}'
}

# _opt_parse: sets O_title O_body O_head O_base O_method from "--k v" pairs; leftovers in O_rest
_opt_parse() {
  O_title=""; O_body=""; O_head=""; O_base=""; O_method=""; O_rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) O_title="${2:-}"; shift 2 ;; --body) O_body="${2:-}"; shift 2 ;; --head) O_head="${2:-}"; shift 2 ;;
      --base) O_base="${2:-}"; shift 2 ;; --method) O_method="${2:-}"; shift 2 ;;
      *) O_rest+=("$1"); shift ;;
    esac
  done
}

cmd_issue() {
  [[ "${1:-}" == create ]] || die "usage: gitdrip issue create <owner/repo> --title T [--body B]"; shift
  _opt_parse "$@"; [[ ${#O_rest[@]} -eq 1 ]] || die "usage: gitdrip issue create <owner/repo> --title T [--body B]"
  gh_issue_create "${O_rest[0]}" "$O_title" "$O_body"
}

cmd_pr() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    open)
      _opt_parse "$@"; [[ ${#O_rest[@]} -eq 1 && -n "$O_head" && -n "$O_title" ]] || die "usage: gitdrip pr open <owner/repo> --head BR --title T [--base BR] [--body B]"
      _gh_slug_ok "${O_rest[0]}" && [[ "$O_head" =~ $_GH_BRANCH_RE ]] || die "bad repo or branch name"
      if [[ -z "$O_base" ]]; then O_base="$(gh_api GET "/repos/${O_rest[0]}" | jq -r '.default_branch // empty')" || exit 1; fi
      gh_pr_open "${O_rest[0]}" "$O_head" "${O_base:-main}" "$O_title" "$O_body" ;;
    merge)
      _opt_parse "$@"; [[ ${#O_rest[@]} -eq 2 ]] || die "usage: gitdrip pr merge <owner/repo> <number> [--method squash|merge|rebase]"
      gh_pr_merge "${O_rest[0]}" "${O_rest[1]}" "${O_method:-squash}" ;;
    *) die "usage: gitdrip pr {open|merge} ..." ;;
  esac
}

# _batch_meta <project> <id> <key> <value>  (key: pr|pr_url|issue; stored in batches.json)
_batch_meta() {
  local f; f="$(project_dir "$1")/batches.json"
  jq --argjson id "$2" --arg k "$3" --arg v "$4" '.batches |= map(if .id==$id then .[$k] = ($v | try tonumber catch $v) else . end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

_pr_fetch_base() { # fetch + fast-forward local <base>; warns on failure (offline is not fatal), dies if local base diverged
  local base="$1" out rc=0
  auth_git_args
  out="$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git -C "$REPO" "${AUTH_ARGS[@]}" fetch -q origin "$base" 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then log_warn "pr-flow: fetch $base failed; continuing with local copy"; return 0; fi
  _git rev-parse --verify -q "refs/remotes/origin/$base" >/dev/null || return 0
  _git merge -q --ff-only "origin/$base" >/dev/null 2>&1 || die "local $base diverged from origin/$base; resolve manually"
}

# prflow_run <project> <batch-id> [--issue] [--merge] [--method M] [--dry]
prflow_run() {
  have git || die "git required"; have jq || die "jq required"
  local p="${1:-}" id="${2:-}" issue=0 merge=0 method=squash dry=0 rc=0
  [[ -n "$p" && "$id" =~ ^[0-9]+$ ]] || die "usage: gitdrip pr-flow <project> <batch-id> [--issue] [--merge] [--method squash|merge|rebase] [--dry]"
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in --issue) issue=1; shift ;; --merge) merge=1; shift ;; --dry) dry=1; shift ;; --method) method="${2:-}"; shift 2 ;; *) die "unknown option: $1" ;; esac
  done
  [[ "$method" =~ ^(squash|merge|rebase)$ ]] || die "--method must be squash, merge or rebase"
  [[ "$(config_get dry_run false)" == true ]] && dry=1
  local pd; pd="$(project_dir "$p")"; [[ -f "$pd/batches.json" ]] || die "no batches for $p"
  REPO="$(repo_dir "$p")"; [[ -d "$REPO/.git" ]] || die "no repo; run: gitdrip repo-init $p --remote URL --user N --email E"
  if [[ $dry -eq 1 ]]; then
    echo "[dry] would branch gitdrip/$p-batch-$id, commit + push it, open a PR$([[ $issue -eq 1 ]] && echo ' (with issue)')$([[ $merge -eq 1 ]] && echo " and $method-merge it")"
    ( git_run_batch "$p" "$id" --dry ) || true; return 0
  fi
  lock_acquire "$p" || { echo "project '$p' is locked; try again later"; return 4; }
  trap 'lock_release "$p"' EXIT
  _prflow_body "$p" "$id" "$issue" "$merge" "$method" || rc=$?
  trap - EXIT; lock_release "$p"; return "$rc"
}

_prflow_body() {
  local p="$1" id="$2" issue="$3" merge="$4" method="$5" pd url slug chk base st msg branch rc=0 pr="" prn pru inum body mr files
  pd="$(project_dir "$p")"
  url="$(_git config --get remote.origin.url 2>/dev/null)" || die "no origin remote"
  slug="$(gh_slug_from_url "$url")" || die "pr-flow needs a github.com remote"
  [[ -n "$(_cred_field token)" ]] || die "no token stored (run: echo TOKEN | gitdrip auth set --user NAME)"
  chk="$(gh_repo_check "$slug")" || die "cannot check $slug"
  [[ "$(jq -r .eligible <<<"$chk")" == true ]] || die "$slug is not eligible: $(jq -r '.warnings|join("; ")' <<<"$chk")"
  base="$(jq -r .default_branch <<<"$chk")"; [[ "$base" =~ $_GH_BRANCH_RE ]] || die "unusable default branch: $base"
  st="$(_batch_get "$p" "$id" .status)"; [[ -n "$st" ]] || die "batch $id not found"
  msg="$(_batch_get "$p" "$id" .message)"; branch="gitdrip/$p-batch-$id"
  case "$st" in SUCCESS|NOCHANGE) echo "batch $id already $st; nothing to do"; return 0 ;; esac
  [[ -z "$(_git status --porcelain --untracked-files=no)" ]] || die "repo has uncommitted changes; refusing to switch branches"

  if _git show-ref --verify --quiet "refs/heads/$branch"; then
    _git checkout -q "$branch" || die "cannot switch to $branch"
  else
    [[ "$st" != COMMITTED ]] || die "batch $id was committed outside pr-flow; push it with: gitdrip run $p $id"
    _git rev-parse --verify -q "refs/heads/$base" >/dev/null || die "local $base has no commits; push the first batch normally (gitdrip run $p)"
    _git checkout -q "$base" || die "cannot switch to $base"
    _pr_fetch_base "$base"
    _git checkout -q -b "$branch" || die "cannot create $branch"
  fi

  ( git_run_batch "$p" "$id" ) || rc=$?
  if [[ $rc -eq 3 ]]; then _git checkout -q "$base"; _git branch -q -D "$branch" 2>/dev/null || true; return 3; fi
  if [[ $rc -ne 0 ]]; then
    _git checkout -q "$base"
    if [[ "$(_git rev-list --count "$base..$branch" 2>/dev/null || echo 1)" == 0 ]]; then _git branch -q -D "$branch" 2>/dev/null || true
    else echo "batch $id failed (rc=$rc); branch $branch kept, rerun pr-flow to resume" >&2; fi
    return "$rc"
  fi

  pr="$(gh_pr_find "$slug" "$branch")" || { _git checkout -q "$base"; echo "pushed $branch but PR lookup failed; rerun pr-flow" >&2; return 1; }
  if [[ -z "$pr" ]]; then
    inum="$(_batch_get "$p" "$id" '.issue // empty')"
    if [[ $issue -eq 1 && -z "$inum" ]]; then
      files="$(jq -r --argjson id "$id" '.batches[]|select(.id==$id)|.files[]|"- "+.' "$pd/batches.json")"
      inum="$(gh_issue_create "$slug" "$msg" "Planned change (batch $id):"$'\n\n'"$files" | jq -r .number)" || { _git checkout -q "$base"; return 1; }
      _batch_meta "$p" "$id" issue "$inum"; log_info "pr-flow: issue #$inum for batch $id"
    fi
    body="Batch $id of project $p."; [[ -z "$inum" ]] || body+=$'\n\n'"Closes #$inum"
    pr="$(gh_pr_open "$slug" "$branch" "$base" "$msg" "$body")" || { _git checkout -q "$base"; echo "pushed $branch but PR failed; rerun pr-flow" >&2; return 1; }
    log_info "pr-flow: opened PR for batch $id"
  fi
  prn="$(jq -r .number <<<"$pr")"; pru="$(jq -r .html_url <<<"$pr")"
  _batch_meta "$p" "$id" pr "$prn"; _batch_meta "$p" "$id" pr_url "$pru"
  echo "pr: #$prn $pru"

  rc=0
  if [[ $merge -eq 1 ]]; then
    mr="$(gh_pr_merge "$slug" "$prn" "$method")" || rc=1
    if [[ $rc -eq 0 && "$(jq -r .merged <<<"$mr")" == true ]]; then
      echo "merged: $(jq -r '.sha[0:7]' <<<"$mr") ($method)"; log_info "pr-flow: merged PR #$prn ($method)"
      gh_api DELETE "/repos/$slug/git/refs/heads/$branch" >/dev/null 2>&1 || log_warn "pr-flow: could not delete remote $branch"
      _git checkout -q "$base"; _pr_fetch_base "$base"; _git branch -q -D "$branch" 2>/dev/null || true
    else
      rc=1; echo "PR #$prn is open but was not merged" >&2
    fi
  fi
  _git checkout -q "$base" 2>/dev/null || true
  return "$rc"
}
