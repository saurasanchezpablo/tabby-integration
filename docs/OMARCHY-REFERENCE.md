# Omarchy reference for this plugin

Verified on Omarchy 4.0.4 (2026-10-09). Re-check against `/usr/share/omarchy`
after an Omarchy update — `omarchy version`.

## Plugin contract

Sources of truth: `/usr/share/omarchy/shell/README.md`,
`shell/plugins/README.md`, `shell/plugins/bar/README.md`,
`shell/services/PluginRegistry.qml`, `shell/shell.qml`,
`shell/services/Plugin*Api.qml`, `shell/Ui/*.qml`, `bin/omarchy-plugin-*`.

### manifest.json

- `schemaVersion` must be the **number** `1`. Required: `id`, `name`,
  `version`, `kinds`, `entryPoints`.
- `id` matches `^[A-Za-z0-9][A-Za-z0-9._-]*$`, must not start with `omarchy.`.
- Each kind needs its entry point: `bar-widget`→`entryPoints.barWidget`,
  `service`→`service`, `panel`/`overlay`/`menu`→same name, `bar`→`bar`.
- `omarchy plugin validate <dir>` also rejects **any symlink inside the plugin
  folder** and missing entry-point files.
- A plugin gets **one** panel-kind loader: `panel` > `overlay` > `menu`.
  Multiple views go inside one QML file.
- `keepLoaded: true`: loader stays mounted; a kept service survives hot reload,
  so changes to it need `omarchy restart shell`.
- `barWidget.defaults` / `schema` are informational — the host does not apply
  them. Always read settings with a fallback: `setting("key", default)`.
- No manifest field contributes menu entries or keybindings.

### Loading and enabled state

- Enabled ⇔ the id appears in `~/.config/omarchy/shell.json` (`bar.layout.*`
  for widgets, `plugins[]` for other kinds). A service+bar-widget plugin is
  enabled by its bar entry alone.
- Watcher: `inotifywait -r` on `~/.config/omarchy/plugins` → 150 ms → reload.
  **Does not follow symlinks**; reload may still serve cached QML. Reliable
  path: copy files, then `omarchy restart shell`.
- Hot reload destroys live objects. Guard every async callback / timer with an
  `alive` flag, or a write-after-destroy aborts the whole shell.
- Logs: `journalctl -t omarchy-shell` (console.log / warnings / load errors).

### Objects injected into QML (only if the property is declared)

- All kinds: `omarchyPath`, `shell` (PluginShellApi, scoped to own id),
  `manifest`, `pluginRegistry`, `barWidgetRegistry`. Panels also get `service`.
- Bar widgets: `bar` (PluginBarApi), `moduleName`, `settings`.
- PluginShellApi: `serviceFor(ownId)`, `summon/hide/toggle/isPluginOpen(ownId)`,
  `updateEntryInline(id, settings)` (persists own shell.json entry).
- PluginBarApi: `foreground`, `background`, `urgent`, `fontFamily`, `position`,
  `vertical`, `barSize`, `run(cmd)`, `showTooltip/hideTooltip`,
  `requestPopout/releasePopout`.
- `qs.Ui`: `Panel` (`open/close/toggle/setting`, `ipcTarget`, `manageIpc`),
  `BarWidget`, `WidgetButton`, `Toggle`, `Dropdown`, `TextField`,
  `PanelSectionHeader`, `ConfirmDialog`, …
- `qs.Commons`: `Color` (live theme: `foreground`, `background`, `accent`,
  `urgent`, `muted`, `Color.bar.*`, `Color.popups.*`), `Style`, `Util`.

### IPC

- `omarchy-shell shell ping|listPlugins|rescanPlugins|summon <id> <json>|toggle|hide`.
- `shell call` only reaches panel/overlay/menu loaders. Services and widgets
  declare their own `IpcHandler { target: "..." }` with typed functions.
- IPC args are visible in `ps` — never pass secrets through them.

### CLI

`omarchy plugin validate|add|enable|disable|list|update|remove`,
`omarchy restart shell`, `omarchy bar move|put|set`. **Never** run
`omarchy refresh shell` (resets shell.json) or `omarchy dev link` (Omarchy
source only, writes /etc).

## Terminal integration points (where Tabby is missing today)

| Area | Omarchy mechanism | Tabby status |
|---|---|---|
| Default terminal | `xdg-terminal-exec`; `~/.config/xdg-terminals.list`; `omarchy default terminal` accepts only alacritty/foot/ghostty/kitty | `tabby.desktop` lacks `X-TerminalArg*`, so `-e cmd` → `tabby -e cmd` (wrong; should be `tabby run cmd`) |
| SUPER+RETURN | `omarchy-launch-terminal` → `xdg-terminal-exec --dir="$(omarchy-cmd-terminal-cwd)"` | cwd detection reads `pgrep -P <pid>`; Tabby's children are Electron helpers → always `$HOME` |
| Floating/presentation terminals | `--app-id=org.omarchy.terminal` | Tabby has no app-id flag → menu installers don't float |
| Window tag | `apps/terminals.lua` tags classes with `+terminal` | class `tabby` not tagged → SUPER+C/V universal copy/paste sends CTRL+C/V |
| Theme | `omarchy theme set` → templates `~/.config/omarchy/themed/*.tpl` → `~/.local/state/omarchy/current/theme/<name>`; then `omarchy-hook theme-set <slug>` | no Tabby template/hook |
| Font | `omarchy font set` → per-terminal sed → `omarchy-hook font-set "<Font>"` | not updated |
| Screensaver | `omarchy-launch-screensaver` only supports 4 terminals | unsupported |
| Menu | `~/.config/omarchy/extensions/omarchy-menu.jsonc` (watched, dotted ids, `when`/`checked`/`action`) | no entries |

### Theme data

- Current theme dir: **`~/.local/state/omarchy/current/theme/`** (the
  `~/.config/omarchy/current/` one is stale legacy). Slug in `current/theme.name`.
- Directory is replaced via rm+mv: FileView watchers must also poll/reload.
- Template placeholders: `{{ key }}`, `{{ key_strip }}`, `{{ key_rgb }}`,
  `{{ mix A B 30% }}`. Keys: `omarchy-theme-color --all`.
- Templates are written only if the theme doesn't already ship the file.
- Security precedent: Omarchy refuses terminal config files from git-installed
  themes (they can run programs). Take **only colours** from themes.

Terminal palette mapping Omarchy uses (mirror it for Tabby):

| Tabby | colors.toml |
|---|---|
| foreground / background | `foreground` / `background` |
| cursor | `bright_foreground` |
| selection | `selection_background` / `selection_foreground` |
| ANSI 0, 7, 8, 15 | `background`, `foreground`, `muted`, `bright_foreground` |
| ANSI 1–6 | `red green yellow blue magenta cyan` |
| ANSI 9–14 | `bright_red … bright_cyan` |

Use semantic keys, not `colorN` (they differ from generated terminal configs).

### Hooks

`omarchy-hook <name> args…` runs `~/.config/omarchy/hooks/<name>` and
`<name>.d/*` (not `*.sample`) with `bash`; no exec bit needed; failures are
logged and skipped. `theme-set` gets the slug, `font-set` the font name.
`theme-set.d/` already holds ~30 THPM hooks (`NN-name.sh`) — pick a free prefix.

### Hyprland (Lua config)

- User overrides: `~/.config/hypr/bindings.lua`, `~/.config/hypr/hyprland.lua`.
- `o.bind(keys, desc, dispatcher)`, `hl.unbind(keys)`,
  `o.window(classPattern, rules)`.
- Managed-block idiom (system-stats plugin): write one marked block
  `-- >>> <id> ... >>>` / `-- <<< <id> <<<`, check conflicts with
  `hyprctl binds -j`, `hyprctl reload`, roll back if error count rises.
- Tabby window class: `tabby`.

## Idioms from installed plugins worth copying

- `Model.js` pure functions + `if (typeof module !== "undefined") module.exports = {…}`
  → testable with node; QML: `import "Model.js" as Model`.
- Subprocess: `Process { command: [...] }` without a shell; bound with
  `/usr/bin/timeout`; secrets via stdin.
- `Text { textFormat: Text.PlainText }` everywhere; Nerd Font glyphs as
  `\uXXXX` escapes (heredocs strip private-use codepoints).
- Plugin dir in QML:
  `decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//,"").replace(/\/$/,""))`.
- Lint: `/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml -I <dir with qs -> /usr/share/omarchy/shell>`.
  qmllint does not catch a missing JS import.
