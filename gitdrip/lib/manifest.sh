#!/usr/bin/env bash
# GitDrip manifest. Requires common.sh + logger.sh sourced. Needs jq.

project_dir() { printf '%s/projects/%s' "$GITDRIP_HOME" "$1"; }

slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+|-+$//g'; }

sha256_of() {
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Never imported / never batched (full secret scan arrives in P5).
manifest_excluded() {
  case "$1" in
    .git/*|*/.git/*|node_modules/*|*/node_modules/*|.DS_Store|*/.DS_Store) return 0 ;;
    .env|.env.*|*/.env|*/.env.*|*.pem|*.key|*.p12|*.jks|*.keystore|id_rsa*|*/id_rsa*) return 0 ;;
  esac
  return 1
}

# project_import <srcdir> <name>  -- copies allowed files into projects/<name>/source
project_import() {
  local src="$1" name="$2" pd rel n=0 x=0
  pd="$(project_dir "$name")"
  mkdir -p "$pd/source"; : > "$pd/excluded.txt"
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    if [[ "$rel" == *$'\t'* || "$rel" == *$'\n'* ]]; then log_warn "skip odd filename: $rel"; continue; fi
    if manifest_excluded "$rel"; then
      case "$rel" in .git/*|*/.git/*|node_modules/*|*/node_modules/*) ;; *) echo "$rel" >> "$pd/excluded.txt"; x=$((x+1)) ;; esac
      continue
    fi
    mkdir -p "$pd/source/$(dirname "$rel")"
    cp -p "$f" "$pd/source/$rel"; n=$((n+1))
  done < <(find "$src" -type f -print0 | sort -z)
  log_info "import $name: $n files copied, $x excluded"
  echo "imported $n files ($x excluded as sensitive)"
}

# manifest_generate <name>  -- writes projects/<name>/manifest.json
manifest_generate() {
  have jq || die "jq required (pkg install jq)"
  local name="$1" pd tsv rel
  pd="$(project_dir "$name")"; [[ -d "$pd/source" ]] || die "unknown project: $name"
  tsv="$(mktemp)"
  while IFS= read -r -d '' f; do
    rel="${f#"$pd/source/"}"
    printf '%s\t%s\t%s\n' "$rel" "$(wc -c < "$f" | tr -d ' ')" "$(sha256_of "$f")" >> "$tsv"
  done < <(find "$pd/source" -type f -print0 | sort -z)
  jq -R -n --arg p "$name" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --rawfile ex "$pd/excluded.txt" '
    [inputs | split("\t") | {path:.[0], size:(.[1]|tonumber), sha256:.[2]}] as $f
    | {project:$p, generated_at:$t, file_count:($f|length),
       total_bytes:($f|map(.size)|add // 0),
       excluded:($ex|split("\n")|map(select(length>0))), files:$f}' < "$tsv" > "$pd/manifest.json.tmp" \
    && mv "$pd/manifest.json.tmp" "$pd/manifest.json"
  rm -f "$tsv"
  log_info "manifest $name: $(jq .file_count "$pd/manifest.json") files"
}
