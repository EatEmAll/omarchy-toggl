#!/usr/bin/env bash
# Install this checkout as an Omarchy shell plugin.
#
#   - copies the plugin to ~/.config/omarchy/plugins/<id> (validate rejects symlinks).
#     It only writes into a folder it created itself (tracked by the
#     .omarchy-toggl-install marker) and only deletes files listed there.
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
marker_header="# omarchy-toggl install manifest v1: $id"

# Only ever write into a folder this installer created. A git-managed install
# (from `omarchy plugin add`) is updated with `omarchy plugin update`, and any
# other existing folder may hold files we did not put there.
if [[ -d "$target/.git" ]]; then
  echo "$target is managed by 'omarchy plugin add'." >&2
  echo "Update it with: omarchy plugin update $id  (or 'omarchy plugin remove $id' first to switch to this checkout)" >&2
  exit 1
fi
if [[ -e "$target" ]] && [[ -n "$(ls -A "$target" 2>/dev/null)" ]] \
   && ! { [[ -f "$marker" ]] && [[ "$(head -n1 "$marker")" == "$marker_header" ]]; }; then
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

mkdir -p "$target"
printf '%s\n' "$new_list" | rsync -a --files-from=- "$root/" "$target/"

# Remove files a previous install of ours put there that this version no
# longer ships. Only paths listed in our own marker are ever deleted.
if [[ -f "$marker" ]]; then
  old_list=$(tail -n +2 "$marker" | sort -u)
  comm -23 <(printf '%s\n' "$old_list") <(printf '%s\n' "$new_list") | while IFS= read -r stale; do
    [[ -z "$stale" || "$stale" == /* || "$stale" == *..* ]] && continue
    rm -f -- "$target/$stale"
    dir=$(dirname -- "$stale")
    while [[ "$dir" != "." ]]; do
      rmdir -- "$target/$dir" 2>/dev/null || break
      dir=$(dirname -- "$dir")
    done
  done
fi
{ printf '%s\n' "$marker_header"; printf '%s\n' "$new_list"; } > "$marker"

omarchy plugin validate "$target"

if [[ -e "$wrapper" ]] && ! grep -q "omarchy-toggl plugin backend" "$wrapper" 2>/dev/null; then
  echo "note: $wrapper exists and is not ours; leaving it alone" >&2
else
  install -Dm755 "$root/scripts/omarchy-toggl" "$wrapper"
fi

omarchy-shell shell rescanPlugins >/dev/null
if (( enable )) && ! omarchy plugin list --json | jq -e --arg id "$id" '.[] | select(.id == $id and .enabled)' >/dev/null; then
  omarchy plugin enable "$id" --section center --after omarchy.weather
fi
echo "Installed $id to $target"
