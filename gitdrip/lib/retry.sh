#!/usr/bin/env bash
# GitDrip retry + offline handling (P6). Requires common, logger, git, runner (task helpers) sourced. Needs jq.
# Only error_class=transient is retried. auth|fatal|conflict|secret|unknown stay FAILED (notify, user fixes, "Retry").
# Backoff minutes come from config `retry_backoff_minutes` (default "0,2,5,15"): entry 0 = first attempt,
# entries 1.. = delay before each retry. Task states add PENDING_RETRY (+ retries, next_retry_at, next_retry_epoch).
# Env GITDRIP_NET=online|offline overrides the connectivity probe (tests / airplane-mode simulation).

retry_backoff() { config_get retry_backoff_minutes "0,2,5,15"; }

# net_online <project> -> 0 reachable (or nothing to reach), 1 offline
net_online() {
  case "${GITDRIP_NET:-auto}" in online) return 0 ;; offline) return 1 ;; esac
  have curl || return 0
  local url target; REPO="$(repo_dir "$1")"
  url="$(_git remote get-url origin 2>/dev/null || true)"
  case "$url" in
    https://*|http://*) target="$(printf '%s' "$url" | sed -E 's#^(https?://)([^/@]*@)?([^/]+).*#\1\3#')" ;;
    git@*|ssh://*)      target="https://github.com" ;;
    *) return 0 ;;   # no remote / local path: nothing to probe
  esac
  curl -sI -m 5 -o /dev/null "$target"
}

# retry_verify_commit <project> <batch_id>  (REPO set)
# 0 = commit is local and not on remote yet -> push;  10 = remote already has it;  11 = commit missing locally
retry_verify_commit() {
  local c br rs; c="$(_batch_get "$1" "$2" '.commit // ""')"
  [[ -n "$c" ]] || return 0
  _git merge-base --is-ancestor "$c" HEAD 2>/dev/null || return 11
  _git remote get-url origin >/dev/null 2>&1 || return 0
  br="$(_git symbolic-ref --short HEAD)"; auth_git_args
  rs="$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true $(have timeout && echo "timeout 30") git -C "$REPO" "${AUTH_ARGS[@]}" \
        ls-remote origin "refs/heads/$br" 2>/dev/null | awk 'NR==1{print $1}')" || true
  [[ -n "$rs" ]] || return 0   # unreachable/empty remote: let push decide and classify
  if [[ "$rs" == "$c" ]] || _git merge-base --is-ancestor "$c" "$rs" 2>/dev/null; then return 10; fi
  return 0
}

# retry_schedule <task_id> <reason> [consume=1]
# -> 0 task is PENDING_RETRY;  1 retries exhausted (caller keeps FAILED)
retry_schedule() {
  local id="$1" why="$2" consume="${3:-1}" n d at ep list=() len
  IFS=',' read -r -a list <<< "$(retry_backoff)"; len=${#list[@]}
  n="$(_task_get "$id" '.retries // 0')"
  if [[ "$consume" == 1 ]]; then
    (( n + 1 < len )) || return 1
    n=$((n + 1)); d="${list[$n]}"
  else
    d="${list[1]:-2}"   # offline waits do not consume a retry
  fi
  [[ "$d" =~ ^[0-9]+$ ]] || d=2
  ep=$(( $(date +%s) + d * 60 )); at="$(date -u -d "@$ep" +%Y-%m-%dT%H:%M:%SZ)"
  _task_set "$id" '.state="PENDING_RETRY"|.retries=$n|.reason=$r|.next_retry_at=$a|.next_retry_epoch=$e|.error_class="transient"|del(.finished_at)' \
    --argjson n "$n" --arg r "$why" --arg a "$at" --argjson e "$ep"
  log_warn "task $id: retry $n scheduled at $at ($why)"
  return 0
}

# retry_due [--list]  -- run every PENDING_RETRY task whose time has come
retry_due() {
  have jq || die "jq required"
  local f id now ran=0 rc; now="$(date +%s)"; shopt -s nullglob
  for f in "$GITDRIP_HOME"/tasks/*.json; do
    id="$(jq -r --argjson n "$now" 'select(.state=="PENDING_RETRY" and (.next_retry_epoch//0) <= $n)|.id' "$f")"
    [[ -n "$id" ]] || continue
    if [[ "${1:-}" == "--list" ]]; then echo "$id"; continue; fi
    echo "== retry $id"; rc=0; (task_run "$id") || rc=$?; echo "-> exit $rc"; ran=$((ran + 1))
  done
  [[ "${1:-}" == "--list" ]] || echo "retry-due: $ran task(s) run"
  return 0
}
