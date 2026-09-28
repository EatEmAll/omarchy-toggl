#!/usr/bin/env bash
# Install this checkout as an Omarchy shell plugin.
#
#   - copies the plugin to ~/.config/omarchy/plugins/<id> (validate rejects symlinks).
#     It only writes into a folder it created itself (tracked by the
#     .omarchy-toggl-install marker, which records each file's sha256). It
#     refuses to overwrite files changed or added since, and deletes only
#     stale files that are unchanged.
#   - installs the optional `omarchy-toggl` CLI to ~/.local/bin (never replaces a
#     different file of the same name)
#   - enables the widget and places it in the bar; this is the only change to
#     ~/.config/omarchy/shell.json and uses Omarchy's own `omarchy plugin enable`
#
# Pass --no-enable to skip the last step and place the widget yourself.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
id=$(jq -r .id "$root/manifest.json")
target="$HOME/.config/omarchy/plugins/$id"
wrapper="$HOME/.local/bin/omarchy-toggl"
enable=1
[[ "${1:-}" == "--no-enable" ]] && enable=0

for cmd in omarchy omarchy-shell python3 rsync jq; do
  command -v "$cmd" >/dev/null || { echo "missing dependency: $cmd" >&2; exit 1; }
done

marker="$target/.omarchy-toggl-install"
marker_v1="# omarchy-toggl install manifest v1: $id"
marker_v2="# omarchy-toggl install manifest v2: $id"

# Only ever write into a folder this installer created. A git-managed install
# (from `omarchy plugin add`) is updated with `omarchy plugin update`, and any
# other existing folder may hold files we did not put there.
if [[ -d "$target/.git" ]]; then
  echo "$target is managed by 'omarchy plugin add'." >&2
  echo "Update it with: omarchy plugin update $id  (or 'omarchy plugin remove $id' first to switch to this checkout)" >&2
  exit 1
fi
marker_version=""
if [[ -f "$marker" && ! -L "$marker" ]]; then
  case "$(head -n1 "$marker")" in
    "$marker_v2") marker_version=2 ;;
    "$marker_v1") marker_version=1 ;;
  esac
fi
if [[ -L "$target" ]] || { [[ -e "$target" ]] && [[ -n "$(ls -A "$target" 2>/dev/null)" ]] && [[ -z "$marker_version" ]]; }; then
  echo "$target already exists and was not created by this installer; not touching it." >&2
  echo "Move or remove it yourself (e.g. 'omarchy plugin remove $id'), then run this again." >&2
  exit 1
fi

# The files this checkout installs: tracked files when it is a git clone,
# minus development-only paths.
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  new_list=$(git -C "$root" ls-files --cached --others --exclude-standard)
else
  new_list=$(cd "$root" && find . -type f -not -path './.git/*' | sed 's|^\./||')
fi
new_list=$(printf '%s\n' "$new_list" | grep -Ev '^(\.github/|tests/|\.pytest_cache/)|(^|/)__pycache__/' | sort -u)

sha() { sha256sum -- "$1" | cut -c1-64; }

# v1 markers stored no hashes. For those files, accept content that this
# repository has shipped at some commit (proof the installer wrote it).
shipped_before() {  # path current_hash
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local commit
  for commit in $(git -C "$root" log --format=%H -- "$1" 2>/dev/null); do
    [[ "$(git -C "$root" show "$commit:$1" 2>/dev/null | sha256sum | cut -c1-64)" == "$2" ]] && return 0
  done
  return 1
}

# What the previous install wrote: path -> sha256 (v2 markers). v1 markers
# only list paths, so their files have no recorded content.
declare -A installed=()
if [[ "$marker_version" == 2 ]]; then
  while IFS= read -r line; do
    [[ ${#line} -gt 66 ]] && installed["${line:66}"]="${line:0:64}"
  done < <(tail -n +2 "$marker")
elif [[ "$marker_version" == 1 ]]; then
  while IFS= read -r path; do [[ -n "$path" ]] && installed["$path"]=""; done < <(tail -n +2 "$marker")
fi
declare -A shipping=()
while IFS= read -r path; do [[ -n "$path" ]] && shipping["$path"]=1; done <<< "$new_list"

# Preflight, before anything is written. An existing file may be replaced
# only if it is exactly what this installer last wrote, or already identical
# to the new version. Anything else (edited by the user, created by the user,
# a symlink) is a conflict and nothing is changed.
conflicts=()
for path in "${!shipping[@]}"; do
  dest="$target/$path"
  if [[ -L "$dest" ]]; then conflicts+=("$path (symlink)"); continue; fi
  [[ -e "$dest" ]] || continue
  current=$(sha "$dest")
  [[ "$current" == "$(sha "$root/$path")" ]] && continue
  [[ -n "${installed[$path]:-}" && "$current" == "${installed[$path]}" ]] && continue
  [[ "$marker_version" == 1 && -n "${installed[$path]+set}" ]] && shipped_before "$path" "$current" && continue
  conflicts+=("$path")
done
if (( ${#conflicts[@]} )); then
  echo "Not updating $target: these files were changed or added outside this installer:" >&2
  printf '  %s\n' "${conflicts[@]}" | sort >&2
  echo "Save your changes elsewhere and remove those files (or the whole folder), then run this again." >&2
  exit 1
fi

# Stale files (installed before, no longer shipped) are deleted only when
# they are unchanged since this installer wrote them; edited ones are kept.
stale_delete=()
stale_kept=()
for path in "${!installed[@]}"; do
  [[ -n "${shipping[$path]:-}" || "$path" == "@wrapper" ]] && continue
  [[ -z "$path" || "$path" == /* || "$path" == *..* ]] && continue
  dest="$target/$path"
  [[ -e "$dest" || -L "$dest" ]] || continue
  if [[ ! -L "$dest" && -n "${installed[$path]}" && "$(sha "$dest")" == "${installed[$path]}" ]]; then
    stale_delete+=("$path")
  elif [[ ! -L "$dest" && "$marker_version" == 1 ]] && shipped_before "$path" "$(sha "$dest")"; then
    stale_delete+=("$path")
  else
    stale_kept+=("$path")
  fi
done

mkdir -p "$target"
printf '%s\n' "$new_list" | rsync -a --files-from=- "$root/" "$target/"

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

# The optional CLI wrapper follows the same rule: install it when absent,
# replace it only if it is exactly what we installed before (hash recorded in
# the marker as "@wrapper") or already identical, otherwise leave it alone.
wrapper_hash=""
new_wrapper_hash=$(sha "$root/scripts/omarchy-toggl")
if [[ -L "$wrapper" ]]; then
  echo "note: $wrapper is a symlink; leaving it alone" >&2
elif [[ ! -e "$wrapper" ]] || [[ "$(sha "$wrapper")" == "$new_wrapper_hash" ]] \
     || [[ -n "${installed[@wrapper]:-}" && "$(sha "$wrapper")" == "${installed[@wrapper]}" ]]; then
  install -Dm755 "$root/scripts/omarchy-toggl" "$wrapper"
  wrapper_hash=$new_wrapper_hash
else
  echo "note: $wrapper exists and was not installed by this script (or was edited); leaving it alone" >&2
fi

# Record exactly what was written, with content hashes.
{
  printf '%s\n' "$marker_v2"
  while IFS= read -r path; do
    [[ -n "$path" ]] && printf '%s  %s\n' "$(sha "$target/$path")" "$path"
  done <<< "$new_list"
  [[ -n "$wrapper_hash" ]] && printf '%s  %s\n' "$wrapper_hash" "@wrapper"
} > "$marker"

omarchy plugin validate "$target"


omarchy-shell shell rescanPlugins >/dev/null
if (( enable )) && ! omarchy plugin list --json | jq -e --arg id "$id" '.[] | select(.id == $id and .enabled)' >/dev/null; then
  omarchy plugin enable "$id" --section center --after omarchy.weather
fi
echo "Installed $id to $target"
