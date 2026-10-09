# Tabby for Omarchy

Makes [Tabby](https://tabby.sh) a first-class Omarchy terminal instead of
"an app that happens to be a terminal".

| | Without | With this plugin |
|---|---|---|
| Theme | Tabby keeps its own scheme | Follows `omarchy theme set` live, whole UI included |
| Font | Tabby default | Follows `omarchy font set` |
| SUPER+RETURN | foot/alacritty | Tabby (optional), as a tab in the running window |
| New terminal from Tabby | always `$HOME` | the active tab's directory |
| SUPER+C / SUPER+V | sends Ctrl+C/V into the shell | copy/paste, like every Omarchy terminal |
| Omarchy TUIs & installers | would land in Tabby tabs | still get their own floating window (foot/alacritty/…) |
| Dropdown | Tabby's dock mode is broken on Wayland | SUPER+\` toggles Tabby in a special workspace |
| Bar | — | tab count, profiles (SSH, serial…), sync status, every setting |
| `tabby open DIR` | silently ignored on Arch | `omarchy-tabby open --dir DIR` works |

## Install

```bash
git clone https://github.com/saurasanchezpablo/omarchy-tabby.git
cd omarchy-tabby
bash install.sh         # works even where exec bits are lost (rclone, some mounts)
```

Then **restart Tabby** once so it loads its half of the integration.

Options: `--no-default` (keep your current default terminal), `--no-hypr`,
`--no-menu`, `--no-widget`, `--no-keys`, `--focus-key="SUPER + ALT + T"`,
`--dropdown-key="SUPER + grave"`. The installer never uses sudo, never edits
Tabby's `config.yaml` and never kills Tabby. Keys that are already bound are
left alone.

Uninstall with `bash install.sh --uninstall`: Tabby gets its own colour scheme,
font and copy keys back (live, if it's running), and every file that was
edited is restored. Backups stay in `~/.local/state/omarchy-tabby/backups`.

`omarchy plugin add <repo>` also works for the bar widget; run `install.sh`
from the checkout afterwards for the rest.

## Use

| | |
|---|---|
| SUPER+RETURN | Tabby, when it is the default terminal (`omarchy-tabby default on`) |
| SUPER+ALT+T | focus Tabby, starting it if needed |
| SUPER+\` | Tabby dropdown |
| Bar: left / middle / right click | panel / new tab / dropdown |
| Omarchy menu | *Setup → Tabby*, *Setup → Defaults → Terminal → Tabby* |

```bash
omarchy-tabby open --dir ~/src --title api -- npm run dev   # a tab running a command
omarchy-tabby open --profile "prod"                         # a Tabby profile (SSH, serial…)
omarchy-tabby scratchpad                                    # dropdown
omarchy-tabby settings set tuiTerminal alacritty            # where Omarchy TUIs open
omarchy-tabby apply                                         # Omarchy theme again after picking another in Tabby
omarchy-tabby status                                        # what is synced
omarchy-tabby doctor                                        # check the installation
```

Settings (`omarchy-tabby settings list`, also in the bar panel and the menu):

| Key | Default | |
|---|---|---|
| `syncColors` | `true` | Tabby uses and follows the Omarchy theme |
| `syncFont` | `true` | Tabby uses the Omarchy font (size untouched) |
| `clipboardKeys` | `true` | SUPER+C/V work in Tabby |
| `smartCwd` | `true` | new terminals start in the active Tabby tab's directory |
| `tuiTerminal` | `auto` | terminal for Omarchy TUIs: `auto`, `tabby`, `foot`, `alacritty`, `ghostty`, `kitty` |
| `focusOnOpen` | `true` | bring Tabby forward after opening a tab |

Picking a different colour scheme or font inside Tabby pauses that sync
(the panel shows *Paused*) instead of fighting you; *Use the Omarchy theme
again* or `omarchy-tabby apply` resumes it.

## How it works

Two halves, because neither side can do it alone:

- **Omarchy side** (`bin/omarchy-tabby`, `lib/`, `Panel.qml`): the CLI that
  Omarchy, Hyprland, the menu and the bar call; the xdg-terminal-exec entry
  point; Hyprland rules and bindings; the bar widget.
- **Tabby side** (`tabby-omarchy/`): a Tabby plugin. Tabby rewrites its whole
  config file on every save and may encrypt it, so changing it from outside
  is unsafe. The plugin applies the theme, font and keys from inside, through
  Tabby's own config service, and opens the tabs the CLI asks for.

The CLI talks to the plugin with one-shot request files in
`$XDG_RUNTIME_DIR/omarchy-tabby/requests` (0700 directory, 0600 files,
128-bit random names, consumed on read, expire after 60 s) referenced from a
`tabby://open?…&omarchyRequest=<id>` URL. Because `tabby://` is a registered
URL handler, a web page can send Tabby such URLs, but it cannot create the
file the id must point to, so it cannot run anything.

The palette comes from the current theme's `colors.toml` through a port of
`omarchy-theme-color`, tested for identical output on every installed theme,
and mapped to ANSI colours exactly like Omarchy's alacritty/kitty/ghostty
templates.

See [docs/OMARCHY-REFERENCE.md](docs/OMARCHY-REFERENCE.md) and
[docs/TABBY-REFERENCE.md](docs/TABBY-REFERENCE.md) for the details behind
each decision.

## Known limitations

- Tabby is one process with many windows and opens requests in its newest
  window. With several windows, a new tab can appear in a different window
  than the focused one (it still starts in the focused tab's directory).
- After the first install Tabby has to be restarted once; until then
  launches fall back to Tabby's own `tabby://` commands (`run` asks for
  confirmation) and the panel says so.
- If Tabby's config is encrypted, the sync waits until the vault is unlocked.
- Omarchy's screensaver only supports alacritty, foot, ghostty and kitty.

## Development

```bash
bash tests/run.sh          # syntax, manifest, qmllint, unit + sandboxed suites
bash tests/run.sh --e2e    # + a real, isolated Tabby (opens a window ~30 s)
bash dev/install.sh        # checks, then install the working tree
```

Requirements: Omarchy 4, Tabby (Arch package `tabby`), `jq`. Optional:
`xdg-terminal-exec` (default terminal), `python3` (menu validation), `perl`.

MIT licensed.
