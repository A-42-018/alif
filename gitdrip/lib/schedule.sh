#!/usr/bin/env bash
# GitDrip scheduler (P7, Termux side). Requires common, logger, manifest, runner, retry sourced. Needs jq.
# State: $GITDRIP_HOME/schedules.json {"schedules":[{id,time,project,policy,enabled,last_fire_day,carry}]}
# crond: managed block in the user crontab (# >>> gitdrip >>> ... # <<< gitdrip <<<):
#   MM HH * * * gitdrip schedule fire <id>      one line per schedule (system-local time)
#   */5 * * * * gitdrip schedule tick           retry-due + missed-slot catch-up
# Missed-slot policy (a slot is missed when now > slot+missed_grace_minutes and it has not fired today):
#   skip = drop it;  run-now = fire immediately;  next-slot = carry it to the project's next unfired slot today
#   (that slot runs 1+carry batches, still under the daily cap); no later slot today = dropped.
# Daily cap: config max_commits_per_day, counted across all projects (SUCCESS tasks with a commit finished today, local day).
# Exit codes: fire 0 ok / nothing to do, 8 daily cap reached, else the task's code.
# Env: GITDRIP_NOW=<epoch> fixes the clock (tests); GITDRIP_CRONTAB_CMD overrides `crontab` (tests).

_sched_file() { printf '%s/schedules.json' "$GITDRIP_HOME"; }
_sched_now() { printf '%s' "${GITDRIP_NOW:-$(date +%s)}"; }
_sched_day() { date -d "@$(_sched_now)" +%Y-%m-%d; }
_sched_init() { [[ -f "$(_sched_file)" ]] || echo '{"schedules":[]}' > "$(_sched_file)"; }
_sched_set() { # <jq-filter> [args]  atomic
  local f flt="$1"; f="$(_sched_file)"; shift; _sched_init
  jq "$@" "$flt" "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}
_sched_get() { jq -r --arg i "$1" ".schedules[]|select(.id==\$i)|$2" "$(_sched_file)"; }
_sched_slot_epoch() { date -d "$(_sched_day) $1" +%s; }   # HH:MM today (local)

# commits made today across all projects
sched_used_today() {
  local start now f; shopt -s nullglob
  start="$(date -d "$(_sched_day) 00:00" +%s)"; now="$(_sched_now)"
  for f in "$GITDRIP_HOME"/tasks/*.json; do
    jq -r --argjson s "$start" --argjson n "$now" \
      'select(.state=="SUCCESS" and (.commit//"")!="" and ((.finished_at//"")|fromdateiso8601? // 0) >= $s and ((.finished_at//"")|fromdateiso8601? // 0) <= ($n+86400))|1' "$f"
  done | wc -l | tr -d ' '
}

schedule_add() { # <HH:MM> <project> [--policy P]
  have jq || die "jq required"
  local t="${1:-}" p="${2:-}" pol="skip" id; shift 2 || die "usage: gitdrip schedule add \"HH:MM\" <project> [--policy skip|run-now|next-slot]"
  while [[ $# -gt 0 ]]; do case "$1" in --policy) pol="${2:-}"; shift 2 ;; *) die "unknown option: $1" ;; esac; done
  [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "time must be HH:MM (24h)"
  [[ "$pol" =~ ^(skip|run-now|next-slot)$ ]] || die "policy must be skip|run-now|next-slot"
  [[ -f "$(project_dir "$p")/batches.json" ]] || die "unknown project: $p"
  _sched_init
  jq -e --arg t "$t" --arg p "$p" '.schedules[]|select(.time==$t and .project==$p)' "$(_sched_file)" >/dev/null && die "schedule $t $p already exists"
  id="s$(date +%s)$(printf '%03x' $((RANDOM % 4096)))"
  _sched_set '.schedules += [{id:$i,time:$t,project:$p,policy:$o,enabled:true,last_fire_day:"",carry:0}]' \
    --arg i "$id" --arg t "$t" --arg p "$p" --arg o "$pol"
  log_info "schedule added $id $t $p ($pol)"; echo "$id"
  schedule_install >/dev/null 2>&1 || echo "note: crontab not updated (run: gitdrip schedule install)" >&2
}

schedule_remove() {
  [[ -n "${1:-}" && -n "$(_sched_get "$1" .id 2>/dev/null)" ]] || die "unknown schedule: ${1:-}"
  _sched_set '.schedules |= map(select(.id!=$i))' --arg i "$1"; log_info "schedule removed $1"
  schedule_install >/dev/null 2>&1 || true; echo "removed $1"
}

schedule_enable() { # <id> true|false
  [[ -n "${1:-}" && -n "$(_sched_get "$1" .id 2>/dev/null)" ]] || die "unknown schedule: ${1:-}"
  _sched_set '.schedules |= map(if .id==$i then .enabled=$e else . end)' --arg i "$1" --argjson e "$2"
  schedule_install >/dev/null 2>&1 || true
}

schedule_list() {
  _sched_init; printf '%-16s %-6s %-14s %-9s %-8s %s\n' ID TIME PROJECT POLICY ENABLED LAST_FIRE
  jq -r '.schedules|sort_by(.time)[]|[.id,.time,.project,.policy,(.enabled|tostring),(.last_fire_day//"")]|@tsv' "$(_sched_file)" \
    | awk -F'\t' '{printf "%-16s %-6s %-14s %-9s %-8s %s\n",$1,$2,$3,$4,$5,$6}'
}

# schedule_install  -- rewrite the managed crontab block from schedules.json (idempotent)
schedule_install() {
  local ct="${GITDRIP_CRONTAB_CMD:-crontab}" cur new bin
  have "${ct%% *}" || { echo "crontab not found (pkg install cronie)" >&2; return 1; }
  bin="$(command -v gitdrip || echo "$GITDRIP_APP/bin/gitdrip")"
  _sched_init
  cur="$($ct -l 2>/dev/null | sed '/^# >>> gitdrip >>>$/,/^# <<< gitdrip <<<$/d' || true)"
  new="$( { [[ -z "$cur" ]] || printf '%s\n' "$cur"
    echo '# >>> gitdrip >>>'
    echo "GITDRIP_HOME=$GITDRIP_HOME"
    jq -r --arg b "$bin" '.schedules[]|select(.enabled)|"\(.time[3:5]|ltrimstr("0")|if .=="" then "0" else . end) \(.time[0:2]|ltrimstr("0")|if .=="" then "0" else . end) * * * \($b) schedule fire \(.id) >/dev/null 2>&1"' "$(_sched_file)"
    echo "*/5 * * * * $bin schedule tick >/dev/null 2>&1"
    echo '# <<< gitdrip <<<'; } )"
  printf '%s\n' "$new" | $ct - || return 1
  log_info "crontab installed ($(jq '[.schedules[]|select(.enabled)]|length' "$(_sched_file)") slot(s))"
  echo "crontab updated"
}

schedule_uninstall() {
  local ct="${GITDRIP_CRONTAB_CMD:-crontab}" cur
  cur="$($ct -l 2>/dev/null | sed '/^# >>> gitdrip >>>$/,/^# <<< gitdrip <<<$/d' || true)"
  if [[ -n "$cur" ]]; then printf '%s\n' "$cur" | $ct -; else $ct -r 2>/dev/null || true; fi
  echo "gitdrip crontab block removed"
}

# schedule_fire <id>  -- run 1+carry batches for the slot, honoring the daily cap
schedule_fire() {
  have jq || die "jq required"
  local id="${1:-}" p carry n used cap tid rc=0 ran=0 first=0
  [[ -n "$id" && -n "$(_sched_get "$id" .id 2>/dev/null)" ]] || die "unknown schedule: $id"
  [[ "$(_sched_get "$id" .enabled)" == true ]] || { echo "schedule $id disabled"; return 0; }
  p="$(_sched_get "$id" .project)"; carry="$(_sched_get "$id" '.carry // 0')"
  _sched_set '.schedules |= map(if .id==$i then .last_fire_day=$d|.carry=0 else . end)' --arg i "$id" --arg d "$(_sched_day)"
  cap="$(config_get max_commits_per_day 3)"; n=$((1 + carry))
  while (( n > 0 )); do
    used="$(sched_used_today)"
    if (( used >= cap )); then log_warn "schedule $id: daily cap reached ($used/$cap); not running"; echo "daily cap reached ($used/$cap)"; (( ran > 0 )) || first=8; break; fi
    tid="$(task_create "$p")" || { echo "no pending batches for $p"; break; }
    echo "slot $id: task $tid"; rc=0; (task_run "$tid") || rc=$?
    ran=$((ran + 1)); n=$((n - 1))
    (( rc == 0 )) || { first=$rc; break; }     # failure/retry/lock/skip: stop; later slots try again
  done
  log_info "schedule $id fired project=$p ran=$ran exit=$first"
  retry_due >/dev/null 2>&1 || true
  return "$first"
}

# schedule_tick  -- cron every 5 min: due retries + missed-slot policy
schedule_tick() {
  have jq || die "jq required"
  _sched_init
  local now day grace id t p pol last ep nxt; now="$(_sched_now)"; day="$(_sched_day)"; grace="$(config_get missed_grace_minutes 10)"
  retry_due >/dev/null 2>&1 || true
  while IFS=$'\t' read -r id t p pol last; do
    [[ "$last" != "$day" ]] || continue
    ep="$(_sched_slot_epoch "$t")"
    (( now > ep + grace * 60 )) || continue
    log_warn "schedule $id ($t $p) missed; policy=$pol"
    case "$pol" in
      run-now) schedule_fire "$id" >/dev/null 2>&1 || true ;;
      next-slot)
        nxt="$(jq -r --arg p "$p" --arg d "$day" --arg t "$t" --arg i "$id" \
          '[.schedules[]|select(.enabled and .project==$p and .id!=$i and .time>$t and .last_fire_day!=$d)]|sort_by(.time)[0].id // empty' "$(_sched_file)")"
        _sched_set '.schedules |= map(if .id==$i then .last_fire_day=$d else . end)' --arg i "$id" --arg d "$day"
        if [[ -n "$nxt" ]]; then
          _sched_set '.schedules |= map(if .id==$n then .carry+=1 else . end)' --arg n "$nxt"
          log_info "schedule $id carried to $nxt"
        else log_info "schedule $id dropped (no later slot today)"; fi ;;
      *) _sched_set '.schedules |= map(if .id==$i then .last_fire_day=$d else . end)' --arg i "$id" --arg d "$day"; log_info "schedule $id skipped" ;;
    esac
  done < <(jq -r '.schedules[]|select(.enabled)|[.id,.time,.project,.policy,(.last_fire_day//"")]|@tsv' "$(_sched_file)")
  return 0
}

# schedule_next  -- show the next batch each project would run
schedule_next() {
  local d n p; shopt -s nullglob
  for d in "$GITDRIP_HOME"/projects/*/; do
    p="$(basename "$d")"; [[ -f "$d/batches.json" ]] || continue; n="$(_next_batch "$p")"
    printf '%s\t%s\n' "$p" "${n:+batch $n: $(_batch_get "$p" "$n" .message)}"
  done
  echo "used today: $(sched_used_today)/$(config_get max_commits_per_day 3)"
}
