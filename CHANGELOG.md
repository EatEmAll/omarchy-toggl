# Changelog

## Unreleased

- `install-local.sh` no longer uses `rsync --delete`. It installs only into a
  folder it created (tracked by `.omarchy-toggl-install`), refuses any other
  existing folder, and deletes only files it installed earlier. Reported in
  marketplace review.
- The install marker now records a SHA-256 per file. Reinstalling refuses, and
  changes nothing, if a plugin file was edited or added since. Stale files are
  deleted only if unchanged. Symlinks are never written through. The CLI
  wrapper is replaced or removed only if unchanged. Reported in marketplace review.
- The preflight also checks every parent folder. A symlinked folder, or a file
  where a folder should be, aborts the install. Stale files under such paths are
  kept. `uninstall.sh --purge` never deletes inside a symlinked cache or config
  folder. Reported in marketplace review.
- No-follow file handling everywhere (marketplace review):
  - the token, `state.json` and `ui.json` are written via a random
    `O_EXCL|O_NOFOLLOW` 0600 temp file and renamed through an owner-checked
    `O_NOFOLLOW` folder fd, so symlinks and hard links are never written through;
  - folders are `fchmod`ed, never `chmod`ed by path;
  - the lock is taken on the folder itself (no `state.lock`);
  - reads accept only regular files, so a FIFO can't hang them;
  - relative `XDG_*` values are ignored;
  - no `__pycache__` is written into the plugin folder.
- `install-local.sh`:
  - validates the source and the plugin ID before writing, and installs only
    tracked regular files;
  - journals the marker (old and new hashes, by temp + rename) so an interrupted
    run can be re-run;
  - hashes the wrapper only if it's a regular file;
  - treats shell rescan/enable failures as notes.
- `uninstall.sh` removes the plugin first and only then the wrapper, token and
  cache. A declined removal changes nothing.
- Tags are passed as `--tag=<name>`. The wrapper always runs the installed plugin.
- New test suites (`tests/test_installer.py`, `tests/test_safety.py`) run in CI.
- `uninstall.sh --purge` deletes only the files the plugin creates (no `rm -rf`)
  and no longer passes `--yes`, so Omarchy asks before removing the plugin.
- The cache folder is created 0700 and state files 0600; the token-file folder is 0700.
- CI actions are pinned to commit SHAs; tests no longer use a fixed `/tmp` path.
- Right-click on the pill cycles the timer while tracking:
  `0:30:05` → `0:30` → hidden (new `timerMode` setting; `showSeconds` still honoured).
- The open panel no longer shifts when the pill changes width.
- The "not tracking" reminder is skipped while the session is idle or locked.
- The bar dot no longer pulses.

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
