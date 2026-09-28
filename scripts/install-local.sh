#!/usr/bin/env bash
# Install this checkout as an Omarchy shell plugin (a from-source alternative to
# `omarchy plugin add`).
#
#   - copies the plugin's tracked, regular files to ~/.config/omarchy/plugins/<id>
#   - installs the optional `omarchy-toggl` CLI to ~/.local/bin
#   - enables the widget via `omarchy plugin enable` (skip with --no-enable);
#     that is its only change to ~/.config/omarchy/shell.json
#
# Ownership rules (nothing it did not write is ever changed):
#   - it only writes into a folder it created, recorded by the
#     .omarchy-toggl-install marker, which stores each written file's sha256;
#   - before writing anything it checks every file and every parent folder; a
#     file that was edited or added since, a symlinked file or folder, or a
#     non-folder in the path aborts the install with a list and no changes;
#   - files no longer shipped are deleted only if still unchanged;
#   - the marker is journaled (old and new hashes, written by temp + rename)
#     before any file is touched, so an interrupted run can simply be re-run.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wrapper="$HOME/.local/bin/omarchy-toggl"
marker_name=".omarchy-toggl-install"
enable=1
[[ "${1:-}" == "--no-enable" ]] && enable=0

for cmd in omarchy omarchy-shell rsync jq sha256sum; do
  command -v "$cmd" >/dev/null || { echo "missing dependency: $cmd" >&2; exit 1; }
done

# --- validate the source before writing anything ---------------------------
id=$(jq -er '.id | strings' "$root/manifest.json") || { echo "manifest.json has no string id" >&2; exit 1; }
if [[ ! "$id" =~ ^[a-z0-9][a-z0-9._-]*$ || "$id" == *..* || "$id" == omarchy.* ]]; then
  echo "refusing unexpected plugin id: $id" >&2
  exit 1
fi
omarchy plugin validate "$root" >/dev/null

target="$HOME/.config/omarchy/plugins/$id"
marker="$target/$marker_name"
marker_v1="# omarchy-toggl install manifest v1: $id"
marker_v2="# omarchy-toggl install manifest v2: $id"

# --- is the target ours? ----------------------------------------------------
if [[ -d "$target/.git" ]]; then
  echo "$target is managed by 'omarchy plugin add'." >&2
  echo "Update it with: omarchy plugin update $id  (or 'omarchy plugin remove $id' first to switch to this checkout)" >&2
  exit 1
fi
if [[ -L "$target" ]] || { [[ -e "$target" ]] && [[ ! -d "$target" || ! -r "$target" || ! -x "$target" ]]; }; then
  echo "$target is not a plain, readable folder; not touching it." >&2
  exit 1
fi
marker_version=""
if [[ -f "$marker" && ! -L "$marker" ]]; then
  case "$(head -n1 -- "$marker")" in
    "$marker_v2") marker_version=2 ;;
    "$marker_v1") marker_version=1 ;;
  esac
fi
if [[ -e "$target" ]] && [[ -n "$(ls -A -- "$target")" ]] && [[ -z "$marker_version" ]]; then
  echo "$target already exists and was not created by this installer; not touching it." >&2
  echo "Move or remove it yourself (e.g. 'omarchy plugin remove $id'), then run this again." >&2
  exit 1
fi

# --- what this checkout ships: tracked, regular files only -----------------
excluded() { [[ "$1" =~ ^(\.github/|tests/|\.pytest_cache/) || "$1" == */__pycache__/* || "$1" == "$marker_name" ]]; }
files=()
add_file() {
  local path=$1
  excluded "$path" && return 0
  if [[ ! "$path" =~ ^[A-Za-z0-9._/-]+$ || "$path" == *..* || "$path" == /* ]]; then
    echo "refusing to install unexpected file name: $path" >&2
    exit 1
  fi
  [[ -f "$root/$path" && ! -L "$root/$path" ]] || { echo "not a regular file in the checkout: $path" >&2; exit 1; }
  files+=("$path")
}
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r -d '' entry; do
    mode=${entry%% *}
    path=${entry#*$'\t'}
    [[ "$mode" == 100644 || "$mode" == 100755 ]] || { excluded "$path" || { echo "refusing non-regular tracked entry: $path" >&2; exit 1; }; continue; }
    add_file "$path"
  done < <(git -C "$root" ls-files -z -s)
else
  while IFS= read -r -d '' path; do
    add_file "${path#./}"
  done < <(cd "$root" && find . -path ./.git -prune -o -type f -print0)
fi
(( ${#files[@]} )) || { echo "nothing to install" >&2; exit 1; }
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  untracked=$(git -C "$root" ls-files --others --exclude-standard -- src scripts manifest.json)
  if [[ -n "$untracked" ]]; then
    echo "note: not installing untracked files (git add them to include them):" >&2
    printf '  %s\n' $untracked >&2
  fi
fi

sha() { sha256sum -- "$1" | cut -c1-64; }

# v1 markers stored no hashes; accept content this repository has shipped.
shipped_before() {  # path current_hash
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local commit
  while IFS= read -r commit; do
    [[ "$(git -C "$root" show "$commit:$1" 2>/dev/null | sha256sum | cut -c1-64)" == "$2" ]] && return 0
  done < <(git -C "$root" log --format=%H -- "$1" 2>/dev/null)
  return 1
}

# --- what we wrote before: path -> space-separated set of hashes ------------
declare -A installed=()
if [[ "$marker_version" == 2 ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^([0-9a-f]{64})\ \ (.+)$ ]] && installed["${BASH_REMATCH[2]}"]+=" ${BASH_REMATCH[1]}"
  done < <(tail -n +2 -- "$marker")
elif [[ "$marker_version" == 1 ]]; then
  while IFS= read -r path; do [[ -n "$path" ]] && installed["$path"]+=""; done < <(tail -n +2 -- "$marker")
fi
ours() {  # path hash -> was this content written by us?
  [[ " ${installed[$1]:-} " == *" $2 "* ]] && return 0
  [[ "$marker_version" == 1 && -n "${installed[$1]+set}" ]] && shipped_before "$1" "$2"
}

# First existing parent folder that is a symlink or not a folder, if any.
bad_parent() {
  local dir parts=()
  dir=$(dirname -- "$1")
  while [[ "$dir" != "." ]]; do parts=("$dir" "${parts[@]}"); dir=$(dirname -- "$dir"); done
  for dir in "${parts[@]}"; do
    if [[ -L "$target/$dir" ]]; then echo "$dir (symlinked folder)"; return 0; fi
    if [[ -e "$target/$dir" && ! -d "$target/$dir" ]]; then echo "$dir (not a folder)"; return 0; fi
    [[ -e "$target/$dir" ]] || return 0
  done
  return 0
}

# --- preflight: decide everything before writing anything -------------------
declare -A shipping=() new_hash=() conflict_set=()
for path in "${files[@]}"; do
  shipping["$path"]=1
  new_hash["$path"]=$(sha "$root/$path")
  dest="$target/$path"
  parent=$(bad_parent "$path")
  if [[ -n "$parent" ]]; then conflict_set["$parent"]=1; continue; fi
  if [[ -L "$dest" ]]; then conflict_set["$path (symlink)"]=1; continue; fi
  [[ -e "$dest" ]] || continue
  if [[ ! -f "$dest" ]]; then conflict_set["$path (not a regular file)"]=1; continue; fi
  current=$(sha "$dest")
  [[ "$current" == "${new_hash[$path]}" ]] && continue
  ours "$path" "$current" && continue
  conflict_set["$path"]=1
done
if (( ${#conflict_set[@]} )); then
  echo "Not updating $target: these were changed or added outside this installer:" >&2
  printf '  %s\n' "${!conflict_set[@]}" | sort >&2
  echo "Save your changes elsewhere and remove those files (or the whole folder), then run this again." >&2
  exit 1
fi

stale_delete=() stale_kept=()
for path in "${!installed[@]}"; do
  [[ -n "${shipping[$path]:-}" || "$path" == "@wrapper" ]] && continue
  [[ -z "$path" || "$path" == /* || "$path" == *..* ]] && continue
  dest="$target/$path"
  if [[ -n "$(bad_parent "$path")" ]]; then
    [[ -e "$dest" || -L "$dest" ]] && stale_kept+=("$path")
    continue
  fi
  [[ -e "$dest" || -L "$dest" ]] || continue
  if [[ -f "$dest" && ! -L "$dest" ]] && ours "$path" "$(sha "$dest")"; then
    stale_delete+=("$path")
  else
    stale_kept+=("$path")
  fi
done

new_wrapper_hash=$(sha "$root/scripts/omarchy-toggl")
install_wrapper=0
if [[ -L "$wrapper" ]]; then
  echo "note: $wrapper is a symlink; leaving it alone" >&2
elif [[ ! -e "$wrapper" ]]; then
  install_wrapper=1
elif [[ -f "$wrapper" ]] && { [[ "$(sha "$wrapper")" == "$new_wrapper_hash" ]] || ours "@wrapper" "$(sha "$wrapper")"; }; then
  install_wrapper=1
else
  echo "note: $wrapper exists and was not installed by this script (or was edited); leaving it alone" >&2
fi

# --- write: journal first, then files, then the final marker ----------------
tmp_marker=""
cleanup() { [[ -n "$tmp_marker" ]] && rm -f -- "$tmp_marker"; return 0; }
trap cleanup EXIT
write_marker() {  # lines on stdin -> marker, via temp file + rename (never writes through)
  tmp_marker=$(mktemp -- "$target/$marker_name.XXXXXX")
  { printf '%s\n' "$marker_v2"; cat; } > "$tmp_marker"
  mv -f -T -- "$tmp_marker" "$marker"
  tmp_marker=""
}

mkdir -p -- "$target"
{
  # Journal: everything we may leave behind if interrupted is recognisable.
  for path in "${!installed[@]}"; do
    for h in ${installed[$path]}; do printf '%s  %s\n' "$h" "$path"; done
  done
  for path in "${files[@]}"; do printf '%s  %s\n' "${new_hash[$path]}" "$path"; done
  (( install_wrapper )) && printf '%s  %s\n' "$new_wrapper_hash" "@wrapper"
  true
} | sort -u | write_marker

printf '%s\0' "${files[@]}" | rsync -a --from0 --files-from=- -- "$root/" "$target/"

for path in "${stale_delete[@]}"; do
  rm -f -- "$target/$path"
  dir=$(dirname -- "$path")
  while [[ "$dir" != "." ]]; do
    rmdir -- "$target/$dir" 2>/dev/null || break
    dir=$(dirname -- "$dir")
  done
done
if (( ${#stale_kept[@]} )); then
  echo "note: kept files no longer shipped because they were changed (or could not be verified):" >&2
  printf '  %s\n' "${stale_kept[@]}" | sort >&2
fi

(( install_wrapper )) && install -Dm755 -- "$root/scripts/omarchy-toggl" "$wrapper"

{
  for path in "${files[@]}"; do printf '%s  %s\n' "${new_hash[$path]}" "$path"; done
  (( install_wrapper )) && printf '%s  %s\n' "$new_wrapper_hash" "@wrapper"
  if (( ! install_wrapper )) && [[ -n "${installed[@wrapper]:-}" ]]; then
    for h in ${installed[@wrapper]}; do printf '%s  %s\n' "$h" "@wrapper"; done
  fi
  true
} | sort -u | write_marker

omarchy plugin validate "$target" >/dev/null

if ! omarchy-shell shell rescanPlugins >/dev/null 2>&1; then
  echo "note: could not ask omarchy-shell to rescan plugins (is it running?)" >&2
fi
if (( enable )) && ! omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" '.[] | select(.id == $id and .enabled)' >/dev/null; then
  omarchy plugin enable "$id" --section center --after omarchy.weather \
    || echo "note: could not enable the widget; run: omarchy plugin enable $id" >&2
fi
echo "Installed $id to $target"
