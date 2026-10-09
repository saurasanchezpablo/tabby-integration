# tabby-integration — Tabby for Omarchy

An Omarchy 4 plugin that makes the [Tabby](https://tabby.sh) terminal a
first-class Omarchy terminal: theme and font sync, correct launching
(cwd, commands, profiles), Hyprland integration and a bar widget.

Plugin id: **`io.github.saurasanchezpablo.tabby`** (same namespace as the
author's `io.github.saurasanchezpablo.moonraker-plus`, which is the house
style reference: `~/.config/omarchy/plugins/io.github.saurasanchezpablo.moonraker-plus`).

Global rules from `~/Work/ai-os/AGENTS.md` apply (safety levels, no secrets,
push only with permission, one worktree per parallel writer).

## Read before working

- [docs/OMARCHY-REFERENCE.md](docs/OMARCHY-REFERENCE.md) — plugin contract,
  injected APIs, IPC, theme/font hooks, Hyprland, where Tabby is missing.
- [docs/TABBY-REFERENCE.md](docs/TABBY-REFERENCE.md) — CLI (and its bug),
  config semantics, Tabby plugin API, Wayland behaviour.
- Upstream sources on this machine beat memory: `/usr/share/omarchy/` and
  `/usr/lib/tabby/builtin-plugins/*/src`. If a reference doc is wrong, fix it
  in the same commit.

## Architecture (target)

Two halves, because Omarchy cannot change Tabby's live config and Tabby cannot
see Omarchy's theme:

```
manifest.json            Omarchy shell plugin (kinds: service, bar-widget)
Service.qml              headless: watches current theme/font, exposes IpcHandler
Panel.qml                bar widget + popup (launch, profiles, sync status)
Model.js                 pure logic (palette mapping, URL building); node-tested
bin/                     omarchy-tabby-* scripts (launcher, cwd, theme export)
hooks/                   theme-set.d / font-set.d hook sources (installed by copy)
hypr/                    Lua snippets (window tag, bindings) installed as managed blocks
menu/                    omarchy-menu.jsonc extension entries
tabby-plugin/            Tabby-side plugin `tabby-omarchy` (Angular, CommonJS):
                         color-scheme provider + live apply via ConfigService
dev/install.sh           copy into ~/.config/omarchy/plugins/<id> + restart shell
tests/run.sh             all automated checks
```

Data flow for theming: `omarchy theme set` → Omarchy template / theme-set hook
writes `~/.local/state/omarchy/current/theme/tabby.json` (colours only) →
`tabby-omarchy` watches it and applies via `ConfigService.save()`.

## Hard constraints (each cost real time to find)

- **Never read or write `~/.config/tabby/config.yaml`** (vault + sync token;
  read is denied in settings). Tabby overwrites external edits on its next save
  and may encrypt the whole file. All Tabby setting changes go through the
  in-app `tabby-omarchy` plugin.
- **Tabby positional CLI is broken** on the Arch package. Launch with
  `tabby 'tabby://open?directory=…'` etc. (URL-encoded). Wrap in
  `env -u ELECTRON_RUN_AS_NODE` — this session's environment sets it.
- Current theme lives in `~/.local/state/omarchy/current/theme/`, not
  `~/.config/omarchy/current/`. The dir is replaced by rm+mv: watch the parent
  or poll.
- Use semantic palette keys (`red`, `bright_red`, `muted`…), not `colorN`.
- `omarchy plugin validate` rejects symlinks inside the plugin dir; the shell
  watcher doesn't follow symlinks → install by **copy**, then
  `omarchy restart shell`.
- QML: guard every async callback/timer with an `alive` flag (hot reload +
  late write = whole shell aborts); `textFormat: Text.PlainText` on every
  `Text`; Nerd Font glyphs as `\uXXXX`; never name properties `data`/`enabled`;
  read settings with `setting(key, fallback)` (manifest defaults are not
  applied); no secrets in IPC args.
- Edits to user config outside the repo (`~/.config/hypr/*`,
  `~/.config/omarchy/hooks`, `extensions/omarchy-menu.jsonc`) are done only by
  the installer, as **marked, idempotent, reversible blocks**
  (`-- >>> io.github.saurasanchezpablo.tabby … >>>`), with backup and an
  uninstall path. Never hand-edit them during development without asking.
- Theme input is colours only — never copy a theme's terminal config files
  (Omarchy treats those as code).
- **The repo is on an rclone FUSE mount** (`~/Cloud/Nextcloud`): exec bits are
  not stored. Run scripts as `bash script.sh`; record executables in git with
  `git update-index --chmod=+x <file>`. Avoid heavy `node_modules` here.

## Commands

```sh
bash tests/run.sh                         # all checks (add to it as features land)
node --test tests/                        # Model.js / tabby-plugin unit tests
omarchy plugin validate .                 # manifest + entry points + no symlinks
/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml -I <dir with qs -> /usr/share/omarchy/shell> *.qml
bash dev/install.sh                       # copy to plugin dir + restart shell (asks)
journalctl -t omarchy-shell -n 100        # shell/plugin logs
omarchy-shell shell listPlugins | jq '.[] | select(.id|test("tabby"))'
hyprctl clients -j | jq '.[] | select(.class=="tabby")'
```

No shellcheck/shfmt/bats installed; don't install tools without asking.

Actions that touch the live desktop (`omarchy restart shell`, enabling the
plugin, `omarchy theme set`, launching a real Tabby window, `hyprctl reload`)
are visible to the user — announce them and prefer isolated runs
(`TABBY_CONFIG_DIRECTORY=<scratch> tabby --user-data-dir=<scratch>`).

## Workflow — commit every feature

1. One feature (or fix) at a time; keep it small and reviewable.
2. Add/extend tests and `tests/run.sh`; update README/CHANGELOG/docs when
   behaviour changes.
3. Run `bash tests/run.sh` + `omarchy plugin validate .` (once a manifest
   exists). Report what ran and what couldn't.
4. **Commit as soon as the feature works** — one focused commit per feature.
   A Stop hook (`.claude/hooks/commit-reminder.sh`) reminds you if the tree is
   dirty when you finish.
5. Commit style (matches the author's repos): imperative, sentence case, no
   prefix, ≤ 72 chars, e.g. `Sync Tabby colours with the Omarchy theme`.
   Body explains *why* when not obvious. Releases: `Release 0.2.0` + CHANGELOG.
   No AI co-author trailer.
6. Never push without explicit permission. Parallel writers each get their own
   worktree (`~/Work/ai-os/scripts/worktree create`).

## Roadmap (each item = at least one commit)

1. Scaffold: manifest, minimal service + bar widget, `dev/install.sh`, tests, README.
2. Launcher `omarchy-tabby-launch`: `tabby://` URLs, cwd, run command, profile.
3. Correct cwd for SUPER+RETURN from a Tabby window (Tabby's children are
   Electron helpers; `omarchy-cmd-terminal-cwd` returns `$HOME`).
4. xdg-terminal-exec support: user `tabby.desktop` override with
   `X-TerminalArgExec` mapped to the launcher; "Set as default terminal".
5. Theme sync: palette export (template or hook) + `tabby-omarchy` plugin applying it live.
6. Font sync via `font-set` hook → `tabby-omarchy`.
7. Hyprland: tag `tabby` as `+terminal` (universal copy/paste), optional
   dropdown/quake via special workspace, opacity left to Hyprland.
8. Omarchy menu entries; bar widget popup (profiles, recent, new window).
9. Installer/uninstaller with managed blocks and backups; Release 0.1.0.
