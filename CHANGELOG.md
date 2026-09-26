# Changelog

## 0.2.0

- **Breaking:** the plugin ID is now `io.github.eatemall.toggl`, the namespaced
  format the Omarchy marketplace recommends. The old ID was `omarchy-toggl`.
  - Reinstall with `omarchy plugin add`.
  - Update any keybindings or menu entries that call `omarchy-shell shell toggle omarchy-toggl`.
  - The CLI (`omarchy-toggl`), the IPC target (`omarchy-shell omarchy-toggl …`),
    the stored token and the cache are unchanged.
- Added `scripts/uninstall.sh` and uninstall instructions.
- `install-local.sh` checks its dependencies, never replaces a foreign
  `~/.local/bin/omarchy-toggl`, and accepts `--no-enable`.
- Added CI: Python tests, Model.js tests and a manifest check.
- Round start/stop button: the play triangle is drawn and optically centred.

## 0.1.0

- Initial release.
