#!/usr/bin/env bash
# GitDrip batches. Requires manifest.sh sourced. Needs jq.

# batch_create <name> [max_files]  -- groups by directory (module), splits to <= max files
batch_create() {
  have jq || die "jq required (pkg install jq)"
  local name="$1" max="${2:-$(config_get batch_max_files 5)}" pd out
  pd="$(project_dir "$name")"; [[ -f "$pd/manifest.json" ]] || die "no manifest for $name"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || die "max must be a positive integer"
  if [[ -f "$pd/batches.json" ]] && jq -e '[.batches[]|select(.status!="PENDING")]|length>0' "$pd/batches.json" >/dev/null; then
    die "batches already in progress for $name; refusing to regenerate"
  fi
  out="$pd/batches.json"
  jq --argjson max "$max" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def grp: if (.path|contains("/")) then (.path|split("/")[:-1]|join("/")) else "(root)" end;
    def ext: (.path|split("/")|last|split(".")|if length>1 then last|ascii_downcase else "" end);
    def isdoc: (ext|IN("md","txt","rst"));
    def istest: (.path|test("(^|/)(tests?|__tests__|spec)(/|$)|\\.(test|spec)\\.|(^|/)test_"));
    def kind: if all(.[]; isdoc) then "docs" elif all(.[]; istest) then "test" else "feat" end;
    .project as $proj | (.files | group_by(grp) | map({g:(.[0]|grp), f:.})
      | sort_by(if .g=="(root)" then "" else .g end)) as $groups
    | [ $groups[] | .g as $g | .f as $f
        | [range(0; ($f|length); $max) as $i | $f[$i:$i+$max]] as $chunks
        | $chunks | to_entries[]
        | .key as $k | .value as $c
        | ($c|kind) as $kd
        | ( if $g=="(root)" then "project root files" else "\($g) module" end ) as $what
        | { name: (if ($chunks|length)>1 then "\($g) (part \($k+1)/\($chunks|length))" else $g end),
            message: ("\($kd): add \($what)" + (if ($chunks|length)>1 then " (part \($k+1)/\($chunks|length))" else "" end)),
            files: ($c|map(.path)), status: "PENDING" } ]
    | to_entries | map(.value + {id:(.key+1)}) as $b
    | {project:$proj, max_files:$max, created_at:$t, batches:$b}' "$pd/manifest.json" > "$out.tmp" && mv "$out.tmp" "$out"
  log_info "batch-create $name: $(jq '.batches|length' "$out") batches (max $max files)"
  echo "created $(jq '.batches|length' "$out") batches (commits available)"
}

batch_list() {
  have jq || die "jq required (pkg install jq)"
  local pd; pd="$(project_dir "$1")"; [[ -f "$pd/batches.json" ]] || die "no batches for $1 (run: gitdrip batch-create $1)"
  jq -r '.batches[] | "\(.id)\t\(.status)\t\(.files|length) files\t\(.message)"' "$pd/batches.json" | column -t -s $'\t' 2>/dev/null \
    || jq -r '.batches[] | "\(.id) \(.status) \(.files|length) files  \(.message)"' "$pd/batches.json"
  jq -r '"commits available: \([.batches[]|select(.status=="PENDING")]|length) of \(.batches|length)"' "$pd/batches.json"
}
