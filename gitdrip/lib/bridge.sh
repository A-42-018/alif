#!/usr/bin/env bash
# GitDrip app bridge (P10). Requires common, logger, manifest, batch, git, runner sourced. jq needed (doctor works without).
# Exchange dir (shared storage; Termux reads it through ~/storage/shared):
#   <ex>/<project>/source/    files written by the Android app
#   <ex>/<project>/plan.json  {"project","repo","branch","user"?,"email"?,"batches":[{"id","message","files":[..]}]}
#   <ex>/results/<req>.json   written here, polled by the app (state RUNNING -> final); no secrets, output redacted
# CLI: gitdrip bridge <req> doctor | sync <p> | run <p> [batch-id] [--sync] | status <p> | history <p>
#      gitdrip bridge <req> auth-handoff <user> <key64hex>   (P14: decrypts <ex>/handoff/<req>.enc -> credentials; file deleted; result has no secrets)
#      gitdrip bridge <req> backup [--full] | restore <backup-name> [--force] | cfg-export | cfg-import <name>   (P16b: files in <ex>/backups/, names validated, no secrets)
#      gitdrip bridge <req> gh-validate | gh-repos | gh-branches <o/r> | gh-check <o/r> | gh-create <name> [--public]   (P13: result in .data)
# Engine batch id = rank of the plan batch (sorted by plan id, 1..n). Once any batch != PENDING the plan is NOT re-applied.

_BR_PROJECT_RE='^[a-z0-9][a-z0-9._-]{0,39}$'
_BR_REQ_RE='^[A-Za-z0-9._-]{1,64}$'
_BR_REPO_RE='^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?$'

bridge_ex() {
  local d; d="$(config_get exchange_dir)"
  printf '%s' "${GITDRIP_EXCHANGE:-${d:-$HOME/storage/shared/GitDrip}}"
}

# exchange usable? (never create ~/storage/shared ourselves: that would be a plain dir, not the Android link)
_br_ex_ok() {
  [[ -n "${GITDRIP_EXCHANGE:-}" || -n "$(config_get exchange_dir)" || -d "$HOME/storage/shared" ]]
}

_br_put() { # <req> <json>
  _br_ex_ok || return 1
  local ex f; ex="$(bridge_ex)"; mkdir -p "$ex/results" 2>/dev/null || return 1
  f="$ex/results/$1.json"
  printf '%s\n' "$2" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

# minimal ERROR json without jq (reason sanitized)
_br_json_min() { # req action project reason
  local r; r="$(printf '%s' "$4" | tr -c 'A-Za-z0-9 ._:/-' ' ' | cut -c1-200)"
  printf '{"req":"%s","action":"%s","project":"%s","state":"ERROR","reason":"%s","exit_code":1}' "$1" "$2" "$3" "$r"
}

# _br_final <req> <action> <project> <state> <reason> <exit_code> <output> [task_id]
_br_final() {
  have jq || { _br_json_min "$1" "$2" "$3" "${5:-jq missing (pkg install jq)}"; return; }
  local pd bj='[]' tj='{}' tf
  pd="$(project_dir "$3")"
  [[ -f "$pd/batches.json" ]] && bj="$(jq -c '[.batches[]|{id,status,commit:(.commit // "")}]' "$pd/batches.json" 2>/dev/null || echo '[]')"
  if [[ -n "${8:-}" ]]; then tf="$(_task_file "$8")"; [[ -f "$tf" ]] && tj="$(cat "$tf")"; fi
  jq -n --arg req "$1" --arg a "$2" --arg p "$3" --arg s "$4" --arg r "$5" --argjson c "$6" --arg o "$7" \
        --arg t "$(_now)" --argjson bj "$bj" --argjson task "$tj" '
    {req:$req, action:$a, project:$p, state:$s, reason:$r, exit_code:$c, output:$o, updated_at:$t,
     task_id:($task.id // ""), batch_id:($task.batch_id // null), commit:($task.commit // ""),
     files_changed:($task.files_changed // 0), attempt:($task.attempt // 0),
     next_retry_at:($task.next_retry_at // ""), batches:$bj}'
}

bridge_doctor() {
  local req="$1" w=false s=false a=false g=false c=false j=false cr=false o=false ex
  ex="$(bridge_ex)"
  [[ -d "$HOME/storage/shared" ]] && s=true
  if _br_ex_ok && mkdir -p "$ex/results" 2>/dev/null && : > "$ex/results/.w.$$" 2>/dev/null; then w=true; rm -f "$ex/results/.w.$$"; fi
  [[ -s "$GITDRIP_HOME/credentials" ]] && a=true
  have git && g=true; have curl && c=true; have jq && j=true; have crond && cr=true; have openssl && o=true
  [[ -d "$ex/handoff" ]] && find "$ex/handoff" -maxdepth 1 -name '*.enc' -mmin +10 -delete 2>/dev/null
  _br_put "$req" "$(printf '{"req":"%s","action":"doctor","state":"OK","version":"%s","tools":{"git":%s,"curl":%s,"jq":%s,"crond":%s,"openssl":%s},"storage_link":%s,"exchange_writable":%s,"auth":%s}' \
      "$req" "$GITDRIP_VERSION" "$g" "$c" "$j" "$cr" "$o" "$s" "$w" "$a")" \
    || { echo "cannot write results to $ex/results (run: termux-setup-storage)" >&2; return 1; }
}

# _bridge_sync_core <p>  -- ALWAYS call in a subshell (uses die/trap). Applies plan.json: import source, write batches.json, repo-init.
_bridge_sync_core() {
  have jq || die "jq required (pkg install jq)"
  local p="$1" ex plan src pd f n m repo branch user email; local -a args=()
  ex="$(bridge_ex)"; plan="$ex/$p/plan.json"; src="$ex/$p/source"; pd="$(project_dir "$p")"
  [[ -f "$plan" && -d "$src" ]] || die "missing plan.json or source/ in $ex/$p (import in the app first)"
  jq -e --arg p "$p" '
      .project == $p and (.batches|type=="array" and length>0)
      and all(.batches[]; (.id|type=="number") and (.message|type=="string" and length>0 and length<=200 and (test("[\n\r]")|not))
          and (.files|type=="array" and length>0 and all(.[]; type=="string" and length>0 and (startswith("/")|not) and ((split("/")|index("..")) == null))))
      and ([.batches[].files[]]|length) == ([.batches[].files[]]|unique|length)' "$plan" >/dev/null \
    || die "invalid plan.json (bad batch, absolute/.. path, or a file in two batches)"
  while IFS= read -r f; do
    [[ -f "$src/$f" ]] || die "planned file missing from source: $f"
    if manifest_excluded "$f"; then die "planned file is sensitive/excluded: $f"; fi
  done < <(jq -r '.batches[].files[]' "$plan")

  if [[ -f "$pd/batches.json" ]] && jq -e '[.batches[]|select(.status!="PENDING")]|length>0' "$pd/batches.json" >/dev/null; then
    echo "batches already in progress; plan not applied"; return 0
  fi
  lock_acquire "$p" || die "project '$p' is locked; try again later"
  trap 'lock_release "$p"' EXIT
  rm -rf "$pd/source" "$pd/manifest.json" "$pd/batches.json"
  project_import "$src" "$p" >/dev/null
  manifest_generate "$p"
  jq --arg p "$p" --arg t "$(_now)" '
    {project:$p, max_files:([.batches[].files|length]|max), created_at:$t,
     batches:(.batches|sort_by(.id)|to_entries|map({id:(.key+1), name:.value.message, message:.value.message, files:.value.files, status:"PENDING"}))}' \
    "$plan" > "$pd/batches.json.tmp" && mv "$pd/batches.json.tmp" "$pd/batches.json"

  repo="$(jq -r '.repo // ""' "$plan")"; branch="$(jq -r '.branch // ""' "$plan")"
  user="$(jq -r '.user // ""' "$plan")"; email="$(jq -r '.email // ""' "$plan")"
  if [[ -z "$user" && -z "$email" && -s "$GITDRIP_HOME/credentials" && -z "$(git -C "$(repo_dir "$p")" config user.email 2>/dev/null || true)" ]]; then
    local gid; gid="$(gh_identity 2>/dev/null || true)"   # no identity yet: use the token owner's login + noreply email
    if [[ -n "$gid" ]]; then user="${gid%%$'\t'*}"; email="${gid#*$'\t'}"; fi
  fi
  if [[ -n "$repo" ]]; then [[ "$repo" =~ $_BR_REPO_RE ]] || die "invalid repo URL (https://github.com/owner/repo, no credentials)"; args+=(--remote "$repo"); fi
  if [[ -n "$branch" ]]; then [[ "$branch" =~ ^[A-Za-z0-9._/-]{1,60}$ ]] || die "invalid branch"; args+=(--branch "$branch"); fi
  if [[ -n "$user" ]]; then [[ "$user" =~ ^[A-Za-z0-9\ ._-]{1,60}$ ]] || die "invalid git user"; args+=(--user "$user"); fi
  if [[ -n "$email" ]]; then [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || die "invalid git email"; args+=(--email "$email"); fi
  if [[ ${#args[@]} -gt 0 || ! -d "$(repo_dir "$p")/.git" ]]; then git_repo_init "$p" ${args[@]+"${args[@]}"} >/dev/null; fi
  n="$(jq '.batches|length' "$pd/batches.json")"; m="$(jq '[.batches[].files|length]|add' "$pd/batches.json")"
  log_info "bridge sync $p: $n batches, $m files"
  echo "synced $n batches ($m files)"
}

bridge_sync() {
  local req="$1" p="$2" out rc=0
  _br_put "$req" "$(_br_final "$req" sync "$p" RUNNING "" 0 "")" || { echo "cannot write results" >&2; return 1; }
  out="$( (_bridge_sync_core "$p") 2>&1 )" || rc=$?
  out="$(printf '%s\n' "$out" | _log_redact | tail -n 5)"
  if [[ $rc -eq 0 ]]; then _br_put "$req" "$(_br_final "$req" sync "$p" OK "" 0 "$out")"
  else _br_put "$req" "$(_br_final "$req" sync "$p" ERROR "$(printf '%s\n' "$out" | tail -n1)" 1 "$out")"; return 1; fi
}

bridge_status() { _br_put "$1" "$(_br_final "$1" status "$2" OK "" 0 "")"; }

# auth-handoff <req> <user> <key>: one-time encrypted token from the app -> credentials (works without jq)
bridge_auth_handoff() {
  local req="$1" user="$2" key="$3" f out rc=0
  f="$(bridge_ex)/handoff/$req.enc"
  out="$( (printf '%s\n' "$key" | auth_handoff "$user" "$f") 2>&1 )" || rc=$?
  out="$(printf '%s\n' "$out" | _log_redact | tail -n 1)"
  if [[ $rc -eq 0 ]]; then
    log_info "bridge auth-handoff $req ok for $user"
    _br_put "$req" "$(printf '{"req":"%s","action":"auth-handoff","state":"OK","reason":"","exit_code":0}' "$req")"
  else
    log_warn "bridge auth-handoff $req failed"
    _br_put "$req" "$(_br_json_min "$req" auth-handoff "" "${out:-handoff failed}")" || true; return 1
  fi
}

# history <req> <p>: last 30 tasks of the project (newest first) as results/<req>.json .tasks[] -> app sync (P12)
bridge_history() {
  have jq || { _br_put "$1" "$(_br_json_min "$1" history "$2" "jq missing (pkg install jq)")"; return 1; }
  local tj f
  tj="$( (shopt -s nullglob; for f in "$GITDRIP_HOME"/tasks/*.json; do
      jq -c --arg p "$2" 'select(.project==$p)|{id,batch_id:(.batch_id//null),state,commit:(.commit//""),files_changed:(.files_changed//0),
        attempt:(.attempt//0),reason:(.reason//""),output:(.output//""),error_class:(.error_class//""),next_retry_at:(.next_retry_at//""),
        created_at:(.created_at//""),started_at:(.started_at//""),finished_at:(.finished_at//"")}' "$f" 2>/dev/null
    done) | jq -s 'sort_by(.created_at)|reverse|.[0:30]' 2>/dev/null || echo '[]')"
  [[ -n "$tj" ]] || tj='[]'
  _br_put "$1" "$(_br_final "$1" history "$2" OK "" 0 "" | jq -c --argjson t "$tj" '.tasks=$t')"
}

bridge_run() {
  local req="$1" p="$2"; shift 2
  local bid="" sync=0 tid="" out="" rc=0 st reason=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --sync ]]; then sync=1
    elif [[ "$1" =~ ^[0-9]+$ ]]; then bid="$1"
    else _br_put "$req" "$(_br_json_min "$req" run "$p" "unknown option")"; return 1; fi
    shift
  done
  _br_put "$req" "$(_br_final "$req" run "$p" RUNNING "" 0 "")" || { echo "cannot write results" >&2; return 1; }
  have jq || { _br_put "$req" "$(_br_json_min "$req" run "$p" "jq missing (pkg install jq)")"; return 1; }
  if [[ $sync -eq 1 ]]; then
    out="$( (_bridge_sync_core "$p") 2>&1 )" || rc=$?
    if [[ $rc -ne 0 ]]; then
      out="$(printf '%s\n' "$out" | _log_redact | tail -n 5)"
      _br_put "$req" "$(_br_final "$req" run "$p" ERROR "sync failed: $(printf '%s\n' "$out" | tail -n1)" 1 "$out")"; return 1
    fi
  fi
  rc=0
  tid="$( (task_create "$p" ${bid:+"$bid"}) 2>/dev/null )" || rc=$?
  if [[ $rc -eq 5 ]]; then
    _br_put "$req" "$(_br_final "$req" run "$p" SKIPPED "no pending batches" 0 "")"; return 0
  elif [[ $rc -ne 0 || -z "$tid" ]]; then
    _br_put "$req" "$(_br_final "$req" run "$p" ERROR "could not create task (unknown project or batch?)" 1 "")"; return 1
  fi
  tid="$(printf '%s\n' "$tid" | tail -n1)"
  _br_put "$req" "$(_br_final "$req" run "$p" RUNNING "" 0 "" "$tid")"
  rc=0
  out="$( (task_run "$tid") 2>&1 )" || rc=$?
  out="$(printf '%s\n' "$out" | _log_redact | tail -n 10)"
  st="$(jq -r '.state // "FAILED"' "$(_task_file "$tid")" 2>/dev/null || echo FAILED)"
  reason="$(jq -r '.reason // ""' "$(_task_file "$tid")" 2>/dev/null || true)"
  [[ $rc -ne 4 ]] || reason="project locked by another run; try again later"
  _br_put "$req" "$(_br_final "$req" run "$p" "$st" "$reason" "$rc" "$out" "$tid")"
  log_info "bridge run $req $p -> $st (exit $rc)"
  return "$rc"
}

# _br_gh <req> <action> <gh function> [args]: runs a GitHub API call, writes results/<req>.json {state, reason, error_class, data}
_br_gh() {
  local req="$1" act="$2" data rc=0 ef msg cls; shift 2
  have jq || { _br_put "$req" "$(_br_json_min "$req" "$act" "" "jq missing (pkg install jq)")"; return 1; }
  ef="$(mktemp)"; data="$("$@" 2>"$ef")" || rc=$?
  if [[ $rc -eq 0 && -n "$data" ]]; then
    _br_put "$req" "$(jq -nc --arg r "$req" --arg a "$act" --arg t "$(_now)" --argjson d "$data" \
      '{req:$r, action:$a, state:"OK", reason:"", error_class:"", exit_code:0, updated_at:$t, data:$d}')"
  else
    msg="$(tail -n1 "$ef" | _log_redact | sed -E 's/^github: \[[a-z]+\] //')"; cls="$(sed -n -E 's/^github: \[([a-z]+)\].*/\1/p' "$ef" | tail -n1)"
    _br_put "$req" "$(jq -nc --arg r "$req" --arg a "$act" --arg t "$(_now)" --arg m "${msg:-GitHub request failed}" --arg c "${cls:-fatal}" \
      '{req:$r, action:$a, state:"ERROR", reason:$m, error_class:$c, exit_code:1, updated_at:$t}')"
    rm -f "$ef"; return 1
  fi
  rm -f "$ef"
}

# ---- P16b: backup / restore / config via the exchange folder (<ex>/backups/, no secrets inside) ----
_BR_BK_RE='^gitdrip-(backup|config)-[0-9]{8}-[0-9]{6}\.(tar\.gz|json)$'

_br_ok_min() { # req action reason
  local r; r="$(printf '%s' "$3" | tr -c 'A-Za-z0-9 ._:/(),;-' ' ' | cut -c1-300)"
  printf '{"req":"%s","action":"%s","project":"","state":"OK","reason":"%s","exit_code":0}' "$1" "$2" "$r"
}
_br_err() { _br_put "$1" "$(_br_json_min "$1" "$2" "" "$3")" || true; return 1; }

# _br_bk_run <req> <action> <cmd...>: runs in a subshell (die = exit), reports last output line
_br_bk_run() {
  local req="$1" act="$2" out rc=0; shift 2
  out="$( ( "$@" ) 2>&1 )" || rc=$?
  out="$(printf '%s' "$out" | _log_redact 2>/dev/null | tail -n 1)"
  if [[ $rc -eq 0 ]]; then _br_put "$req" "$(_br_ok_min "$req" "$act" "$out")" || true
  else _br_err "$req" "$act" "${out:-failed}"; fi
}

bridge_backup() { # req [--full]
  local req="$1"; shift; local -a a=()
  [[ "${1:-}" == "--full" ]] && a=(--full)
  _br_ex_ok || return 1
  local d; d="$(bridge_ex)/backups"; mkdir -p "$d" 2>/dev/null || { _br_err "$req" backup "cannot create backups folder"; return 1; }
  local f="$d/gitdrip-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  _br_bk_run "$req" backup backup_create "$f" "${a[@]}"
  # keep the newest 10 backups
  local n=0 x; while IFS= read -r x; do n=$((n+1)); [[ $n -gt 10 ]] && rm -f "$d/$x"; done \
    < <(ls -1t "$d" 2>/dev/null | grep -E '^gitdrip-backup-[0-9]{8}-[0-9]{6}\.tar\.gz$')
  return 0
}

bridge_restore() { # req <name> [--force]
  local req="$1" name="${2:-}" a=(); [[ "${3:-}" == "--force" ]] && a=(--force)
  _br_ex_ok || return 1
  [[ "$name" =~ $_BR_BK_RE && "$name" == *.tar.gz ]] || { _br_err "$req" restore "invalid backup name"; return 1; }
  local f; f="$(bridge_ex)/backups/$name"
  [[ -f "$f" && ! -L "$f" ]] || { _br_err "$req" restore "backup not found"; return 1; }
  _br_bk_run "$req" restore backup_restore "$f" "${a[@]}"
}

bridge_cfg_export() { # req
  local req="$1"; _br_ex_ok || return 1
  local d; d="$(bridge_ex)/backups"; mkdir -p "$d" 2>/dev/null || { _br_err "$req" cfg-export "cannot create backups folder"; return 1; }
  _br_bk_run "$req" cfg-export config_export "$d/gitdrip-config-$(date +%Y%m%d-%H%M%S).json"
}

bridge_cfg_import() { # req <name>
  local req="$1" name="${2:-}"; _br_ex_ok || return 1
  [[ "$name" =~ $_BR_BK_RE && "$name" == *.json ]] || { _br_err "$req" cfg-import "invalid config name"; return 1; }
  local f; f="$(bridge_ex)/backups/$name"
  [[ -f "$f" && ! -L "$f" ]] || { _br_err "$req" cfg-import "config file not found"; return 1; }
  _br_bk_run "$req" cfg-import config_import "$f"
}

bridge_main() {
  local req="${1:-}" act="${2:-}" p
  [[ "$req" =~ $_BR_REQ_RE ]] || die "usage: gitdrip bridge <req-id> {doctor|sync <p>|run <p> [batch-id] [--sync]|status <p>|history <p>}"
  shift 2 || true
  case "$act" in
    doctor) bridge_doctor "$req" ;;
    auth-handoff)
      if [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ && "${2:-}" =~ ^[0-9a-f]{64}$ ]]; then bridge_auth_handoff "$req" "$1" "$2"
      else rm -f "$(bridge_ex)/handoff/$req.enc"; _br_put "$req" "$(_br_json_min "$req" auth-handoff "" "invalid user or key")" || true; return 1; fi ;;
    backup)     bridge_backup "$req" "$@" ;;
    restore)    bridge_restore "$req" "$@" ;;
    cfg-export) bridge_cfg_export "$req" ;;
    cfg-import) bridge_cfg_import "$req" "$@" ;;
    gh-validate) _br_gh "$req" "$act" gh_whoami ;;
    gh-repos)    _br_gh "$req" "$act" gh_repos ;;
    gh-branches|gh-check|gh-create)
      [[ -n "${1:-}" ]] || { _br_put "$req" "$(_br_json_min "$req" "$act" "" "missing argument")" || true; return 1; }
      case "$act" in
        gh-branches) _br_gh "$req" "$act" gh_branches "$1" ;;
        gh-check)    _br_gh "$req" "$act" gh_repo_check "$1" ;;
        gh-create)   _br_gh "$req" "$act" gh_create_repo "$@" ;;
      esac ;;
    sync|run|status|history)
      p="${1:-}"; shift || true
      if ! [[ "$p" =~ $_BR_PROJECT_RE ]]; then _br_put "$req" "$(_br_json_min "$req" "$act" "" "invalid project name")" || true; return 1; fi
      "bridge_$act" "$req" "$p" "$@" ;;
    *) die "unknown bridge action: $act" ;;
  esac
}
