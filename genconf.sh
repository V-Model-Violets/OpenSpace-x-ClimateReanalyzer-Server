#!/usr/bin/env bash
# genconf: scan ./webconf, verify data files exist under $DATA_FOLDER, fix paths in .webconf,
#          and emit ahtse.conf for AHTSE + MRF.
# Compatible with .ppg (PNG) / .pjg (JPEG) data files and .idx index files.

set -euo pipefail
IFS=$'\n\t'

# --- Config -------------------------------------------------------------------
# Root data folder where you keep MRF triplets (…/{rel_dir}/{basename}/ files)
DATA_FOLDER="${DATA_FOLDER:-/workspaces/OpenSpace-x-ClimateReanalyzer-Server/data}"

# Resolve script path and webconf root
SCRIPT="$(realpath "$0" 2>/dev/null || readlink -f "$0")"
SCRIPTPATH="$(dirname "$SCRIPT")"
WEBCONF_ROOT="$SCRIPTPATH/webconf"
OUT_CONF="$SCRIPTPATH/ahtse.conf"

# --- Helpers ------------------------------------------------------------------
log() { printf '%s\n' "$*" >&2; }

# Sed in-place portable helper (GNU/BSD)
_sedi() {
  # usage: _sedi 's|^DataFile .*|DataFile /abs/path|' file
  if sed --version >/dev/null 2>&1; then
    sed -i "$1" "$2"
  else
    # macOS/BSD sed
    sed -i '' "$1" "$2"
  fi
}

# Trim leading/trailing spaces
trim() { awk '{$1=$1;print}'; }

# Extract 2nd token from a line like "DataFile something"
extract_value() {
  awk 'NF>=2 {print $2; exit}'
}

# Validate extensions and auto-swap common mistakes
check_swap_extensions() {
  local data_name="$1" index_name="$2"
  local data_ext="${data_name##*.}"
  local index_ext="${index_name##*.}"

  # Expected: data_ext in {ppg,pjg}, index_ext == idx
  if [[ "$data_ext" == "idx" ]] && [[ "$index_ext" =~ ^(ppg|pjg)$ ]]; then
    # Swapped; return "swap"
    echo "swap"
    return 0
  fi
  echo "ok"
}

# Make a directory block once per path (avoid duplicate blocks)
declare -A EMITTED_DIRS
emit_directory_block() {
  local dir="$1" webconf_path="$2"
  [[ -n "${EMITTED_DIRS["$dir"]+yes}" ]] && return 0
  EMITTED_DIRS["$dir"]=1

  {
    echo "<Directory $dir>"
    echo "  Options -Indexes -FollowSymLinks -ExecCGI"
    echo "  MRF_RegExp */tile/.*"
    echo "  MRF_ConfigurationFile $webconf_path"
    echo "</Directory>"
    echo
  } >> "$OUT_CONF"
}

# --- Start fresh --------------------------------------------------------------
echo "# ahtse.conf (generated $(date -u +'%Y-%m-%dT%H:%M:%SZ'))" > "$OUT_CONF"

log "search : $WEBCONF_ROOT"
[[ -d "$WEBCONF_ROOT" ]] || { log "No webconf directory at: $WEBCONF_ROOT"; exit 1; }

# --- Walk all .webconf files --------------------------------------------------
while IFS= read -r -d '' webconf; do
  log "check: $webconf"

  webconf_dir="$(dirname "$webconf")"
  webconf_base="$(basename -- "$webconf")"
  base_noext="${webconf_base%.*}"

  # Compute relative dir under webconf root to mirror under DATA_FOLDER
  rel_dir="${webconf_dir#"$WEBCONF_ROOT"/}"

  # Read DataFile/IndexFile tokens as written in the .webconf
  df_line="$(grep -m1 '^DataFile[[:space:]]' "$webconf" || true)"
  ix_line="$(grep -m1 '^IndexFile[[:space:]]' "$webconf" || true)"

  if [[ -z "$df_line" || -z "$ix_line" ]]; then
    log "  WARN: Missing DataFile or IndexFile line in $webconf; skipping"
    continue
  fi

  data_name="$(echo "$df_line" | extract_value | trim)"
  index_name="$(echo "$ix_line" | extract_value | trim)"

  # If absolute paths were written in the webconf, keep only the basenames
  data_name_base="$(basename -- "$data_name")"
  index_name_base="$(basename -- "$index_name")"

  # Target directory follows convention: $DATA_FOLDER/$rel_dir/$base_noext
  target_dir="$DATA_FOLDER/$rel_dir/$base_noext"
  data_path="$target_dir/$data_name_base"
  index_path="$target_dir/$index_name_base"

  # Detect common swap (.idx put in DataFile and .ppg/.pjg in IndexFile)
  swap_status="$(check_swap_extensions "$data_name_base" "$index_name_base")"
  if [[ "$swap_status" == "swap" ]]; then
    log "  NOTE: Detected swapped DataFile/IndexFile in $webconf — fixing"
    # Swap variables locally
    tmp="$data_name_base"; data_name_base="$index_name_base"; index_name_base="$tmp"
    data_path="$target_dir/$data_name_base"
    index_path="$target_dir/$index_name_base"
  fi

  # Verify existence
  missing=0
  if [[ ! -f "$data_path" ]]; then
    log "  No data file found for: $data_path"
    missing=1
  fi
  if [[ ! -f "$index_path" ]]; then
    log "  No index file found for: $index_path"
    missing=1
  fi

  if [[ $missing -eq 1 ]]; then
    # Try a fallback: maybe user put files directly under $DATA_FOLDER/$rel_dir (without /$base_noext)
    alt_dir="$DATA_FOLDER/$rel_dir"
    alt_data="$alt_dir/$data_name_base"
    alt_index="$alt_dir/$index_name_base"
    if [[ -f "$alt_data" && -f "$alt_index" ]]; then
      log "  Using fallback location: $alt_dir"
      target_dir="$alt_dir"
      data_path="$alt_data"
      index_path="$alt_index"
      missing=0
    fi
  fi

  if [[ $missing -eq 1 ]]; then
    # Give the user a hint if extensions look wrong
    data_ext="${data_name_base##*.}"
    index_ext="${index_name_base##*.}"
    if [[ "$data_ext" == "idx" || "$index_ext" =~ ^(ppg|pjg)$ ]]; then
      log "  HINT: DataFile should be .ppg (PNG) or .pjg (JPEG); IndexFile should be .idx"
    fi
    continue
  fi

  # Update the .webconf to point to absolute paths we just validated
  _sedi "s|^DataFile .*|DataFile $data_path|" "$webconf"
  _sedi "s|^IndexFile .*|IndexFile $index_path|" "$webconf"

  # Emit Directory block for Apache/AHTSE
  emit_directory_block "$target_dir" "$webconf"

  log "  Data file found: $data_path"
  log "  Index file found: $index_path"

done < <(find "$WEBCONF_ROOT" -type f -name '*.webconf' -print0)

log "Wrote: $OUT_CONF"
