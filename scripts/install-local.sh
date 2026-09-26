#!/usr/bin/env bash
# Install this checkout as an Omarchy shell plugin.
#
#   - copies the plugin to ~/.config/omarchy/plugins/<id> (validate rejects symlinks)
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

# A git-managed install (from `omarchy plugin add`) must be updated with
# `omarchy plugin update`; syncing over it would delete its .git metadata.
if [[ -d "$target/.git" ]]; then
  echo "$target is managed by 'omarchy plugin add'." >&2
  echo "Update it with: omarchy plugin update $id  (or 'omarchy plugin remove $id' first to switch to this checkout)" >&2
  exit 1
fi

mkdir -p "$target"
rsync -a --delete --delete-excluded \
  --exclude '.git/' --exclude '.github/' --exclude '__pycache__/' --exclude 'tests/' --exclude '.pytest_cache/' \
  "$root/" "$target/"
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
