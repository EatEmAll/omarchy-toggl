#!/usr/bin/env bash
# Copy this checkout into the Omarchy plugin folder (validate rejects symlinks),
# install the CLI wrapper, and enable + place the widget on first install.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target="$HOME/.config/omarchy/plugins/omarchy-toggl"

mkdir -p "$target"
rsync -a --delete --delete-excluded \
  --exclude '.git/' --exclude '__pycache__/' --exclude 'tests/' --exclude '.pytest_cache/' \
  "$root/" "$target/"
install -Dm755 "$root/scripts/omarchy-toggl" "$HOME/.local/bin/omarchy-toggl"
omarchy plugin validate "$target"
omarchy-shell shell rescanPlugins >/dev/null

if ! omarchy plugin list --json | jq -e '.. | objects | select(.id? == "omarchy-toggl") | select(.enabled == true)' >/dev/null 2>&1; then
  omarchy plugin enable omarchy-toggl --section center --after omarchy.weather
fi
echo "omarchy-toggl installed to $target"
