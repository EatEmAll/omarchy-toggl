#!/usr/bin/env bash
# Remove the plugin and everything it created.
#
#   scripts/uninstall.sh           remove the plugin and the omarchy-toggl CLI
#   scripts/uninstall.sh --purge   also sign out (delete the API token from the
#                                  keyring / token file) and delete the cache
#
# Keybindings or menu entries you added by hand are yours; the script only
# reminds you about them.
set -euo pipefail

id="io.github.eatemall.toggl"
wrapper="$HOME/.local/bin/omarchy-toggl"
cli="$HOME/.config/omarchy/plugins/$id/src/toggl.py"
purge=0
[[ "${1:-}" == "--purge" ]] && purge=1

if (( purge )); then
  # Sign out through the plugin when it is still installed; otherwise (or if
  # that fails) clear the keyring entry directly so the token never lingers.
  if [[ -f "$cli" ]]; then python3 "$cli" --text auth logout || true; fi
  if command -v secret-tool >/dev/null; then
    secret-tool clear service omarchy-toggl account api-token 2>/dev/null || true
  fi
fi

if omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" '.[] | select(.id == $id)' >/dev/null; then
  omarchy plugin remove "$id" --yes
fi

if [[ -f "$wrapper" ]] && grep -q "omarchy-toggl plugin backend" "$wrapper"; then
  rm -f "$wrapper"
fi

if (( purge )); then
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-toggl"
  rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-toggl"
fi

echo "Removed $id."
grep -qs "omarchy-toggl" "$HOME/.config/hypr/bindings.lua" \
  && echo "note: ~/.config/hypr/bindings.lua still has Toggl keybindings you added"
grep -qs "omarchy-toggl" "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc" \
  && echo "note: ~/.config/omarchy/extensions/omarchy-menu.jsonc still has Toggl menu entries you added"
exit 0
