#!/usr/bin/env bash
# GitDrip task runner (P4). Requires common, logger, manifest, batch, git sourced. Needs jq.
# Task file: tasks/<task_id>.json   state: PENDING -> RUNNING -> SUCCESS | FAILED | SKIPPED
# Idempotency key = "<project>:<batch_id>". Final tasks (SUCCESS/SKIPPED) are no-ops when rerun.
# Lock: locks/<project>.lock = "<pid> <epoch>"; stale = pid dead, unparsable, or older than lock_stale_minutes.
# Failed tasks carry error_class (secret|auth|conflict|transient|fatal|unknown) for the P6 retry logic.
# P6: transient failures / offline -> PENDING_RETRY (see lib/retry.sh); `task-run <id> [--now]` ignores the retry timer.
# Exit codes (task-run/run): 0 success or already done, 1 failed, 3 skipped (no change), 4 project locked, 7 retry scheduled / not due.

_task_file() { printf '%s/tasks/%s.json' "$GITDRIP_HOME" "$1"; }
_lock_file() { printf '%s/locks/%s.lock' "$GITDRIP_HOME" "$1"; }
_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _task_set <id> <jq-filter> [jq args...]  -- atomic update, stamps updated_at
_task_set() {
  local f flt="$2"; f="$(_task_file "$1")"; shift 2
  jq "$@" --arg _t "$(_now)" "$flt | .updated_at=\$_t" "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}
_task_get() { jq -r "$2" "$(_task_file "$1")"; }

_lock_stale() {
  local pid="" ts="" max; max="$(config_get lock_stale_minutes 30)"
  read -r pid ts < "$1" 2>/dev/null || true
  [[ "$pid" =~ ^[0-9]+$ && "$ts" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  (( $(date +%s) - ts > max * 60 ))
}

# lock_acquire <project>  -> 0 acquired, 1 held by a live process
lock_acquire() {
  local lf tmp before; lf="$(_lock_file "$1")"; tmp="$lf.$$"
  printf '%s %s\n' "$$" "$(date +%s)" > "$tmp"
  if ln "$tmp" "$lf" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  if _lock_stale "$lf"; then
    before="$(cat "$lf" 2>/dev/null || true)"
    log_warn "stale lock for $1 ($before); taking over"
    [[ "$(cat "$lf" 2>/dev/null || true)" == "$before" ]] && rm -f "$lf"
    if ln "$tmp" "$lf" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  fi
  rm -f "$tmp"; return 1
}

lock_release() {
  local lf pid=""; lf="$(_lock_file "$1")"
  read -r pid _ < "$lf" 2>/dev/null || true
  [[ "$pid" == "$$" ]] && rm -f "$lf"
  return 0
}

# _next_batch <project>  -- COMMITTED (resume push) first, else first PENDING; empty if none
_next_batch() {
  jq -r '([.batches[]|select(.status=="COMMITTED")][0] // [.batches[]|select(.status=="PENDING")][0]) | .id // empty' \
    "$(project_dir "$1")/batches.json"
}

# task_create <project> [batch_id]  -> prints task_id (reuses an open task for the same batch)
task_create() {
  have jq || die "jq required"
  local p="$1" bid="${2:-}" pd id key existing f
  pd="$(project_dir "$p")"; [[ -f "$pd/batches.json" ]] || die "unknown project or no batches: $p"
  [[ -n "$bid" ]] || bid="$(_next_batch "$p")"
  [[ -n "$bid" ]] || return 5
  [[ "$bid" =~ ^[0-9]+$ ]] || die "batch id must be a number"
  [[ -n "$(_batch_get "$p" "$bid" .id)" ]] || die "batch $bid not found in $p"
  key="$p:$bid"
  existing="$(shopt -s nullglob; for f in "$GITDRIP_HOME"/tasks/*.json; do
      jq -r --arg k "$key" 'select(.key==$k and (.state=="PENDING" or .state=="RUNNING" or .state=="PENDING_RETRY"))|.id' "$f"; done | head -n1)"
  if [[ -n "$existing" ]]; then echo "$existing"; return 0; fi
  id="$(date -u +%Y%m%dT%H%M%SZ)-$p-b$bid-$(printf '%04x' $((RANDOM)))"
  jq -n --arg id "$id" --arg p "$p" --argjson b "$bid" --arg k "$key" --arg t "$(_now)" \
    '{id:$id,project:$p,batch_id:$b,key:$k,state:"PENDING",attempt:0,created_at:$t,updated_at:$t}' \
    > "$(_task_file "$id")"
  log_info "task created $id"; echo "$id"
}

_task_finish() { # <id> <state> <reason> <output>
  _task_set "$1" '.state=$s|.reason=$r|.output=$o|.finished_at=$t2' \
    --arg s "$2" --arg r "$3" --arg o "$4" --arg t2 "$(_now)"
}

# task_run <task_id>  (wrapper clears traps/lock on every exit path)
task_run() {
  local rc=0; _RUN_NOW=0; [[ "${2:-}" != --now ]] || _RUN_NOW=1
  _task_run_inner "$1" || rc=$?
  trap - EXIT INT TERM; [[ -z "${_RUN_P:-}" ]] || lock_release "$_RUN_P"; _RUN_P=""
  return "$rc"
}

_task_run_inner() {
  have jq || die "jq required"
  local id="$1" tf p bid st bst out rc=0 commit files reason ecls=""
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid task id"
  tf="$(_task_file "$id")"; [[ -f "$tf" ]] || die "unknown task: $id"
  jq -e '.project and .batch_id' "$tf" >/dev/null 2>&1 || die "malformed task file: $id"
  p="$(_task_get "$id" .project)"; bid="$(_task_get "$id" .batch_id)"
  [[ -f "$(project_dir "$p")/batches.json" ]] || die "task $id: project '$p' missing"
  [[ "$(config_get dry_run false)" != "true" ]] || die "config dry_run=true; tasks would record false results (use: gitdrip run-batch $p $bid --dry)"

  st="$(_task_get "$id" .state)"
  case "$st" in SUCCESS|SKIPPED) echo "task $id already $st; nothing to do"; return 0 ;; esac

  if [[ "$st" == PENDING_RETRY && "$_RUN_NOW" != 1 && $(date +%s) -lt $(_task_get "$id" '.next_retry_epoch // 0') ]]; then
    echo "task $id not due until $(_task_get "$id" .next_retry_at)"; return 7
  fi
  if ! lock_acquire "$p"; then
    log_warn "task $id: project $p locked by another run; left $st"
    echo "project '$p' is locked; try again later"; return 4
  fi
  _RUN_P="$p"; _RUN_ID="$id"
  trap 'lock_release "$_RUN_P"' EXIT
  trap '_task_finish "$_RUN_ID" FAILED interrupted ""; exit 130' INT TERM

  # re-read under lock: another runner may have finished this task meanwhile
  st="$(_task_get "$id" .state)"
  case "$st" in SUCCESS|SKIPPED) echo "task $id already $st; nothing to do"; return 0 ;; esac
  [[ "$st" != RUNNING ]] || log_warn "task $id was RUNNING with no live owner; recovering"

  bst="$(_batch_get "$p" "$bid" .status)"
  case "$bst" in
    SUCCESS|NOCHANGE)
      _task_set "$id" '.attempt+=1|.started_at=$t2' --arg t2 "$(_now)"
      _task_finish "$id" SKIPPED "batch already $bst" ""
      log_info "task $id skipped (batch $bid $bst)"; echo "skipped: batch $bid already $bst"; return 0 ;;
  esac

  [[ "$st" != FAILED ]] || _task_set "$id" '.retries=0'   # manual re-run of a failed task restarts the retry budget
  if ! net_online "$p"; then
    log_warn "task $id: offline; nothing attempted"
    retry_schedule "$id" offline 0
    echo "offline; will retry at $(_task_get "$id" .next_retry_at)"; return 7
  fi
  _task_set "$id" '.state="RUNNING"|.attempt+=1|.started_at=$t2|del(.finished_at,.reason,.output,.error_class,.next_retry_at,.next_retry_epoch)' --arg t2 "$(_now)"
  out="$( (git_run_batch "$p" "$bid") 2>&1 )" || rc=$?
  out="$(printf '%s\n' "$out" | _log_redact | tail -n 10)"
  commit="$(_batch_get "$p" "$bid" '.commit // ""')"
  files="$(_batch_get "$p" "$bid" '.files|length')"
  case "$rc" in
    0) _task_finish "$id" SUCCESS "" "$out" ;;
    3) _task_finish "$id" SKIPPED "no changes" "$out" ;;
    6) _task_finish "$id" FAILED secret_blocked "$out"; ecls=secret; rc=1 ;;
    *) reason="$(printf '%s\n' "$out" | tail -n1)"; _task_finish "$id" FAILED "$reason" "$out"; rc=1
       ecls="$(printf '%s\n' "$out" | sed -n -E 's/.*push failed \[([a-z]+)\].*/\1/p' | tail -n1)" ;;
  esac
  [[ -z "$ecls" ]] || _task_set "$id" '.error_class=$e' --arg e "$ecls"
  if [[ "$ecls" == transient ]] && retry_schedule "$id" "transient: $(printf '%s\n' "$out" | tail -n1)"; then rc=7
  elif [[ "$ecls" == transient ]]; then _task_set "$id" '.reason="retries exhausted: "+.reason'; fi
  _task_set "$id" '.exit_code=$c|.commit=$h|.files_changed=$n' --argjson c "$rc" --arg h "$commit" --argjson n "$files"
  log_info "task $id -> $(_task_get "$id" .state) (exit $rc)"
  printf '%s\n' "$out"
  return "$rc"
}

# task_run_next <project> [batch_id]  -- create + run
task_run_next() {
  local id rc=0
  id="$(task_create "$@")" || rc=$?
  if [[ $rc -eq 5 ]]; then echo "no pending batches for $1"; return 0; fi
  [[ $rc -eq 0 ]] || return "$rc"
  echo "task: $id"; task_run "$id"
}

task_list() { # [project]
  local f; shopt -s nullglob
  printf '%-44s %-13s %-6s %s\n' TASK STATE BATCH REASON
  for f in "$GITDRIP_HOME"/tasks/*.json; do
    jq -r --arg p "${1:-}" 'select($p=="" or .project==$p)|[.id,.state,(.batch_id|tostring),(.reason//"")]|@tsv' "$f"
  done | awk -F'\t' '{printf "%-44s %-13s %-6s %s\n",$1,$2,$3,$4}'
}

task_show() { local f; f="$(_task_file "$1")"; [[ -f "$f" ]] || die "unknown task: $1"; cat "$f"; }
