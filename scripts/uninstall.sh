#!/usr/bin/env bash
# Remove the plugin and what it created.
#
#   scripts/uninstall.sh           remove the plugin and the omarchy-toggl CLI
#   scripts/uninstall.sh --purge   also sign out (delete the API token from the
#                                  keyring / token file) and delete the cache
#
# Order matters: the plugin is removed first (Omarchy asks for confirmation).
# Only if that succeeds are the CLI wrapper, token and cache touched, so a
# declined removal changes nothing. Only files the plugin creates are deleted,
# never through a symlink. Keybindings or menu entries you added by hand are
# yours; the script only reminds you about them.
set -euo pipefail

id="io.github.eatemall.toggl"
plugin="$HOME/.config/omarchy/plugins/$id"
wrapper="$HOME/.local/bin/omarchy-toggl"
marker="$plugin/.omarchy-toggl-install"
purge=0
[[ "${1:-}" == "--purge" ]] && purge=1

xdg() {  # absolute $XDG_* value or the default (relative values are ignored)
  local value=$1 fallback=$2
  [[ "$value" == /* ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

# The wrapper is removed only if it is byte-for-byte what install-local.sh
# recorded. Read that before the plugin folder goes away, and only from a
# marker this installer wrote (a plain file in a non-git folder).
wrapper_hash=""
if [[ -f "$marker" && ! -L "$marker" && ! -e "$plugin/.git" && ! -L "$plugin" ]]; then
  wrapper_hash=$(grep -m1 -E '^[0-9a-f]{64}  @wrapper$' -- "$marker" | cut -c1-64 || true)
fi

# The plugin counts as installed if its folder exists or Omarchy lists it (a
# failing `plugin list` must not be mistaken for "not installed"). Removal
# counts as done only when the folder is really gone.
listed=0
omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" '.[] | select(.id == $id)' >/dev/null && listed=1
if (( listed )) || [[ -e "$plugin" || -L "$plugin" ]]; then
  # Omarchy shows its own confirmation; if it is declined or fails, stop here.
  if ! omarchy plugin remove "$id" || [[ -e "$plugin" || -L "$plugin" ]]; then
    echo "The plugin was not removed; nothing else was changed." >&2
    exit 1
  fi
fi

if [[ -f "$wrapper" && ! -L "$wrapper" ]]; then
  if [[ -n "$wrapper_hash" && "$(sha256sum -- "$wrapper" | cut -c1-64)" == "$wrapper_hash" ]]; then
    rm -f -- "$wrapper"
  else
    echo "note: left $wrapper in place (not installed by install-local.sh, or edited since)"
  fi
fi

# Delete only our own files inside a real (non-symlinked) folder, then the
# folder itself if it is now empty.
remove_ours() {  # dir name-pattern...
  local dir=$1; shift
  if [[ -L "$dir" ]]; then
    echo "note: $dir is a symlink; left it alone"
    return 0
  fi
  [[ -d "$dir" ]] || return 0
  local args=() name
  for name in "$@"; do args+=(-o -name "$name"); done
  find "$dir" -mindepth 1 -maxdepth 1 -type f \( "${args[@]:1}" \) -delete 2>/dev/null || true
  rmdir -- "$dir" 2>/dev/null || true
}

if (( purge )); then
  if command -v secret-tool >/dev/null; then
    secret-tool clear service omarchy-toggl account api-token 2>/dev/null || true
  fi
  cache="$(xdg "${XDG_CACHE_HOME:-}" "$HOME/.cache")/omarchy-toggl"
  config="$(xdg "${XDG_CONFIG_HOME:-}" "$HOME/.config")/omarchy-toggl"
  remove_ours "$cache" state.json ui.json state.lock '.state.json.*.tmp' '.ui.json.*.tmp'
  remove_ours "$config" token '.token.*.tmp'
fi

echo "Removed $id."
grep -qs "omarchy-toggl" "$HOME/.config/hypr/bindings.lua" \
  && echo "note: ~/.config/hypr/bindings.lua still has Toggl keybindings you added"
grep -qs "omarchy-toggl" "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc" \
  && echo "note: ~/.config/omarchy/extensions/omarchy-menu.jsonc still has Toggl menu entries you added"
exit 0
