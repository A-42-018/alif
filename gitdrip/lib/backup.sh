#!/usr/bin/env bash
# GitDrip backup / restore / config import-export (P16). Source only.
# Never includes: credentials, locks, logs. repo/ and source/ only with --full.

_BK_TOP='config.json schedules.json projects tasks'

# backup_create [file] [--full] -> prints archive path
backup_create() {
  local out="" full=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --full) full=1; shift ;; *) out="$1"; shift ;; esac
  done
  [[ -d "$GITDRIP_HOME" ]] || die "nothing to back up ($GITDRIP_HOME missing)"
  [[ -n "$out" ]] || out="$PWD/gitdrip-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  local -a items=() ex=()
  local t; for t in $_BK_TOP; do [[ -e "$GITDRIP_HOME/$t" ]] && items+=("$t"); done
  [[ ${#items[@]} -gt 0 ]] || die "nothing to back up"
  if [[ $full -eq 0 ]]; then ex=(--exclude='projects/*/repo' --exclude='projects/*/source'); fi
  local tmp; tmp="$(mktemp "${out}.XXXXXX")" || die "cannot write $out"
  if tar -C "$GITDRIP_HOME" "${ex[@]}" -czf "$tmp" "${items[@]}" 2>/dev/null; then
    chmod 600 "$tmp"; mv "$tmp" "$out"; log_info "backup created (full=$full)"; echo "$out"
  else
    rm -f "$tmp"; die "backup failed"
  fi
}

# _bk_validate <archive>: only allowed top-level names, no abs/.. paths, no links/devices
_bk_validate() {
  local f="$1" line name type top ok
  tar -tzf "$f" >/dev/null 2>&1 || return 1
  while IFS= read -r line; do
    type="${line:0:1}"
    [[ "$type" == "-" || "$type" == "d" ]] || return 2
  done < <(tar -tvzf "$f" 2>/dev/null)
  while IFS= read -r name; do
    [[ -n "$name" && "$name" != /* && "$name" != *..* ]] || return 3
    top="${name%%/*}"; ok=0
    local t; for t in $_BK_TOP; do [[ "$top" == "$t" ]] && ok=1; done
    [[ $ok -eq 1 ]] || return 4
    case "$name" in credentials*|locks*|logs*) return 4 ;; esac
  done < <(tar -tzf "$f" 2>/dev/null)
  return 0
}

backup_restore() {
  local f="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in --force) force=1; shift ;; *) f="$1"; shift ;; esac
  done
  [[ -n "$f" && -f "$f" ]] || die "usage: gitdrip restore <backup.tar.gz> [--force]"
  local rc=0; _bk_validate "$f" || rc=$?
  case "$rc" in
    0) ;; 1) die "not a valid archive" ;; 2) die "archive contains links/special files; refusing" ;;
    3) die "archive contains unsafe paths; refusing" ;; *) die "archive contains unexpected entries; refusing" ;;
  esac
  ensure_dirs
  local stage; stage="$(mktemp -d "$GITDRIP_HOME/.restore.XXXXXX")" || die "cannot stage"
  if ! tar -C "$stage" -xzf "$f" 2>/dev/null; then rm -rf "$stage"; die "extract failed"; fi
  local p n clash=""
  if [[ -d "$stage/projects" ]]; then
    for p in "$stage/projects"/*/; do
      [[ -d "$p" ]] || continue; n="$(basename "$p")"
      [[ -e "$GITDRIP_HOME/projects/$n" ]] && clash="$clash $n"
    done
  fi
  if [[ -n "$clash" && $force -eq 0 ]]; then
    rm -rf "$stage"; die "projects already exist:$clash (use --force to overwrite)"
  fi
  local restored=0
  if [[ -d "$stage/projects" ]]; then
    for p in "$stage/projects"/*/; do
      [[ -d "$p" ]] || continue; n="$(basename "$p")"
      if [[ -e "$GITDRIP_HOME/projects/$n" ]]; then
        # keep local repo/ + source/ when the backup is lean
        for k in repo source; do
          [[ -e "$p$k" || ! -e "$GITDRIP_HOME/projects/$n/$k" ]] || mv "$GITDRIP_HOME/projects/$n/$k" "$p$k"
        done
        rm -rf "$GITDRIP_HOME/projects/$n"
      fi
      mv "$p" "$GITDRIP_HOME/projects/$n"; restored=$((restored+1))
    done
  fi
  if [[ -d "$stage/tasks" ]]; then
    for p in "$stage/tasks"/*; do
      [[ -e "$p" ]] || continue
      [[ -e "$GITDRIP_HOME/tasks/$(basename "$p")" && $force -eq 0 ]] || cp -f "$p" "$GITDRIP_HOME/tasks/"
    done
  fi
  [[ -f "$stage/schedules.json" && ( $force -eq 1 || ! -f "$GITDRIP_HOME/schedules.json" ) ]] \
    && cp -f "$stage/schedules.json" "$GITDRIP_HOME/schedules.json"
  [[ -f "$stage/config.json" && ( $force -eq 1 || ! -f "$GITDRIP_CONFIG" ) ]] \
    && cp -f "$stage/config.json" "$GITDRIP_CONFIG"
  rm -rf "$stage"
  log_info "restore done ($restored projects)"
  echo "restored $restored project(s); token not included: run 'gitdrip auth set' again; cron: 'gitdrip schedule install'"
}

config_export() {
  local out="${1:-}"; [[ -n "$out" ]] || die "usage: gitdrip config export <file>"
  [[ -f "$GITDRIP_CONFIG" ]] || die "config missing; run install.sh"
  cp "$GITDRIP_CONFIG" "$out" && chmod 600 "$out" && echo "$out"
}

# config_import <file>: only known keys with matching JSON types are applied
config_import() {
  local f="${1:-}"; [[ -f "$f" ]] || die "usage: gitdrip config import <file>"
  have jq || die "jq required for config import (pkg install jq)"
  jq -e 'type=="object"' "$f" >/dev/null 2>&1 || die "not a JSON object"
  [[ -f "$GITDRIP_CONFIG" ]] || die "config missing; run install.sh"
  local tmp; tmp="$(mktemp "$GITDRIP_HOME/.cfg.XXXXXX")"
  if jq --slurpfile n "$f" '
      . as $cur | ($n[0]) as $new
      | reduce ($cur | keys[]) as $k ($cur;
          if ($new | has($k)) and (($new[$k] | type) == ($cur[$k] | type)) and $k != "version"
          then .[$k] = $new[$k] else . end)' "$GITDRIP_CONFIG" > "$tmp"; then
    mv "$tmp" "$GITDRIP_CONFIG"; log_info "config imported"; echo "config imported (unknown/mistyped keys ignored)"
  else
    rm -f "$tmp"; die "import failed"
  fi
}
