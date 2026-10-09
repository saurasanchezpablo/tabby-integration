# Tabby reference for this plugin

Verified against Tabby 1.0.237 (Arch package `tabby`, Electron 43) on
2026-10-09, mostly from the TypeScript sources shipped in
`/usr/lib/tabby/builtin-plugins/*/src` and the source maps in
`/usr/lib/tabby/app.asar.unpacked/dist/*.js.map`. Re-check after upgrades:
`pacman -Q tabby`.

## Launching

- `/usr/bin/tabby` = `exec electron43 /usr/lib/tabby/app.asar --no-sandbox "$@"`.
- **Positional CLI commands are broken on this package**: yargs sees the asar
  path as the first positional, so `tabby open DIR`, `tabby profile X`,
  `tabby run …` are silently ignored (visible in `~/.config/tabby/log.txt` as
  `"_":["/usr/lib/tabby/app.asar","open",…]`).
- **Use `tabby://` URLs** — parsed from any argv position, bypassing yargs, and
  forwarded to the running instance:

  ```sh
  tabby 'tabby://open?directory=/tmp'
  tabby 'tabby://profile?profileName=bash'
  tabby 'tabby://run?command=htop%20-d%2010'      # Tabby asks for confirmation
  tabby 'tabby://recent?profileNumber=0'
  tabby 'tabby://quickConnect?providerId=ssh&query=user@host'
  ```

  URL-encode every value. `tabby.desktop` has no `x-scheme-handler/tabby`
  MimeType, so call `/usr/bin/tabby` directly, not `xdg-open`.
- Single instance (`requestSingleInstanceLock`, per `--user-data-dir`): a
  second invocation forwards argv+cwd to the running app and exits 0.
- Other CLI flags: `--hidden`, `--debug`, `--version`.
- **`ELECTRON_RUN_AS_NODE=1`** (inherited from VS Code / Claude Code) makes
  `tabby` crash with "Cannot find module 'electron'". Launch with
  `env -u ELECTRON_RUN_AS_NODE tabby …` in scripts and when testing here.
- Isolated test instance (never touches the real config):
  `env -u ELECTRON_RUN_AS_NODE TABBY_CONFIG_DIRECTORY=<scratch> tabby --user-data-dir=<scratch>`.
  It opens a real window on the user's screen — say so before doing it.

## Config (`~/.config/tabby/config.yaml`)

- **Do not read it** — it holds the vault and a config-sync token. Agents are
  denied read access in `.claude/settings.json`.
- No file watcher: external edits are not picked up, and Tabby's next save
  serializes the whole in-memory store, **overwriting external edits**. Saves
  are atomic (temp+rename) and also write `config.yaml.backup`.
- With `encrypted: true` the whole config lives inside the vault; external
  tools cannot read or edit it at all.
- ⇒ Change Tabby settings **from inside Tabby** (a Tabby plugin calling
  `config.store.… = …; await config.save()`), never by patching the YAML from
  outside while it may be running.
- Relevant keys:
  - `terminal.font`, `fontSize`, `fallbackFont`, `ligatures`
  - `terminal.colorScheme` / `terminal.lightColorScheme`: full objects
    `{name, foreground, background, cursor, colors[16], selection?, selectionForeground?, cursorAccent?}`;
    chosen by `appearance.colorSchemeMode` (`dark|light|auto`); a profile's
    `terminalColorScheme` overrides.
  - `terminal.customColorSchemes`: user schemes.
  - `appearance.theme: 'Follow the color scheme'` themes the whole UI from the
    terminal scheme (`colors[4]` = accent).
  - `appearance.opacity` ≠ 1 disables GPU acceleration on Linux → keep 1, let
    Hyprland do opacity/blur.
  - `appearance.frame`: `thin` (default, frameless) fits Hyprland; `dock*` is
    broken on Wayland (`setBounds` ignored, upstream #10814).
  - `hotkeys` (`copy: [Ctrl-Shift-C]`, `paste: [Ctrl-Shift-V, Shift-Insert]`,
    `toggle-window: [Ctrl-Space]`, …), `hacks.globalHotkey: true` disables
    global hotkeys (they don't work on Wayland anyway, #5207/#11781).
  - `profiles[]`, `electronFlags`.

## Tabby plugin system

- Search path: builtin-plugins → app.asar/node_modules →
  `~/.config/tabby/plugins/node_modules` → each dir in **`TABBY_PLUGINS`**
  (colon-separated; a package dir or a parent of `tabby-*` dirs).
- Package requirements: folder/name starts with `tabby-`; `package.json` has
  `keywords: ["tabby-plugin"]` **and `author`** (missing author ⇒ silently
  skipped); default export is an Angular NgModule. Can't reuse built-in names.
- Dev loop: `env -u ELECTRON_RUN_AS_NODE TABBY_PLUGINS=$PWD/tabby-plugin tabby --debug`.
- Plugin Manager (Arborist) may prune hand-placed folders in
  `plugins/node_modules` — prefer installing via `TABBY_PLUGINS` or re-check.
- Shared modules: `@angular/*` (v15), `rxjs`, `tabby-core`, `tabby-terminal`.
- Extension points: `TerminalColorSchemeProvider.getSchemes()`,
  `ConfigProvider`, `Theme`, `CLIHandler` (`{priority, firstMatchOnly, handle({argv,cwd,secondInstance})}`
  — can fix the asar-argv bug), `HotkeyProvider`, `ToolbarButtonProvider`,
  `ProfileProvider`, `TerminalDecorator`.
- `ConfigService`: `store`, `save()`, `load()`, `changed$`, `ready$`. Changes
  saved through it apply live (colours, fonts, theme).
- Templates: `tabby-community-color-schemes/src/*.ts`,
  github.com/Eugeny/tabby-clippy, HACKING.md in the Tabby repo.
- A no-build CommonJS plugin using Angular JIT + `inject()` is plausible but
  **unverified**; fallback is TS + webpack with Angular/tabby as externals.

## Wayland / Hyprland

- `class` = `initialClass` = `tabby`, `initialTitle` = `Tabby`, native Wayland
  (no XWayland). No app-id or title CLI flag.
- Ozone defaults to auto (Wayland) since Electron 38; flags via
  `~/.config/electron43-flags.conf` (affects every electron43 app) or
  `electronFlags`.
- Quake/dropdown: use a Hyprland special workspace + float/size rules, not
  Tabby's dock mode.
- No existing omarchy/pywal/base16 integration for Tabby was found (npm, GitHub).
