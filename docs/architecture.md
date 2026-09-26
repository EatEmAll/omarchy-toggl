# Architecture

```
omarchy-shell (Quickshell)
 ├─ src/Service.qml      one instance: state FileView, Backend queue, sync timer,
 │                       1 s clock + suspend-gap detection, IdleMonitor, reminders,
 │                       IpcHandler "omarchy-toggl" (plugin id: io.github.eatemall.toggl)
 ├─ src/BarWidget.qml    one per monitor: the pill; finds the service through
 │                       bar.shell.serviceFor() and pushes its settings to it
 └─ src/ui/Panel.qml     KeyboardPanel popout (sections/, views/, dialogs/, components/)
            │ argv (token via stdin only)
            ▼
 src/toggl.py → omarchy_toggl/
   cli.py     one JSON line per command, exit codes 0/2 usage/3 auth/4 quota/5 net
   sync.py    Engine: quota-aware sync, mutations, offline queue, idle resolution
   api.py     urllib client, Basic token auth, quota headers → state.quota
   store.py   ~/.cache/omarchy-toggl/state.json (atomic write + flock), ui.json
   stats.py   today/week totals for the CLI (the panel computes live stats in Model.js)
   parse.py   quick-entry grammar  (@project #tag $)
   token.py   secret-tool → 0600 file → $TOGGL_API_TOKEN
   timeutil.py  "14:02", "-15m", "yesterday 17:30" (mirrors Model.parseWhen)
```

Every writer (panel, keybindings, menu, terminal) goes through the CLI, which
updates `state.json`. The service watches that file, so every UI updates
immediately without another API call.

`src/ui/Model.js` is a pure `.pragma library`: grouping, ranges, stats,
suggestions, timelines and time parsing. `tests/model_test.js` runs it under
deno, and `tests/time_cases.json` is shared with the Python tests so the two
time parsers stay in sync.

Lessons from the Omarchy shell host:

- Services survive plugin hot-reload, so a change to `Service.qml` needs
  `omarchy restart shell`.
- A QML type that failed to load stays cached until the shell restarts.
- Root items must not declare a `state` property, because it would shadow `Item.state`.
