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
marker="$HOME/.config/omarchy/plugins/$id/.omarchy-toggl-install"
# The wrapper is removed only if it is byte-for-byte what install-local.sh
# recorded; read that before the plugin folder (and its marker) goes away.
wrapper_hash=$(grep -m1 '  @wrapper$' "$marker" 2>/dev/null | cut -c1-64 || true)
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
  # Let Omarchy show its own confirmation before it deletes the plugin folder.
  omarchy plugin remove "$id"
fi

if [[ -f "$wrapper" && ! -L "$wrapper" ]]; then
  if [[ -n "$wrapper_hash" && "$(sha256sum -- "$wrapper" | cut -c1-64)" == "$wrapper_hash" ]]; then
    rm -f -- "$wrapper"
  else
    echo "note: left $wrapper in place (not installed by install-local.sh, or edited since)"
  fi
fi

if (( purge )); then
  # Remove only the files this plugin creates, then the folders if now empty.
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-toggl"
  config="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-toggl"
  # Never follow a symlinked folder: only delete inside real directories.
  if [[ -d "$cache" && ! -L "$cache" ]]; then
    rm -f -- "$cache/state.json" "$cache/ui.json" "$cache/state.lock"
    find "$cache" -maxdepth 1 \( -name '.state.json.*.tmp' -o -name '.ui.json.*.tmp' \) -type f -delete 2>/dev/null || true
    rmdir -- "$cache" 2>/dev/null || true
  elif [[ -L "$cache" ]]; then
    echo "note: $cache is a symlink; left it alone"
  fi
  if [[ -d "$config" && ! -L "$config" ]]; then
    rm -f -- "$config/token"
    rmdir -- "$config" 2>/dev/null || true
  elif [[ -L "$config" ]]; then
    echo "note: $config is a symlink; left it alone"
  fi
fi

echo "Removed $id."
grep -qs "omarchy-toggl" "$HOME/.config/hypr/bindings.lua" \
  && echo "note: ~/.config/hypr/bindings.lua still has Toggl keybindings you added"
grep -qs "omarchy-toggl" "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc" \
  && echo "note: ~/.config/omarchy/extensions/omarchy-menu.jsonc still has Toggl menu entries you added"
exit 0
