# Changelog

## 0.1.0 (2026-10-09)

First release.

- **Theme sync**: Tabby uses the current Omarchy theme and follows
  `omarchy theme set` live (whole UI via *Follow the color scheme*). Palette
  resolved exactly like `omarchy-theme-color`, mapped like Omarchy's terminal
  templates. Pauses instead of overriding a scheme picked in Tabby.
- **Font sync** with `omarchy font set`.
- **Universal clipboard**: SUPER+C/V copy and paste in Tabby.
- **Default terminal**: `omarchy-tabby default on` makes SUPER+RETURN and
  every xdg-terminal-exec launch open Tabby tabs; Omarchy TUIs and floating
  installers keep their own window in foot/alacritty/ghostty/kitty.
- **Smart cwd**: new terminals from a focused Tabby start in the active
  tab's directory.
- **Dropdown** (SUPER+\`) and **focus** (SUPER+ALT+T) via Hyprland.
- **Bar widget**: tab count, quick actions, profiles, sync status, settings.
- **Omarchy menu**: Setup → Tabby, Setup → Defaults → Terminal → Tabby.
- **Secure launching**: one-shot private request files; `tabby://` URLs from
  web pages cannot run anything. Works around the Arch package's broken
  positional CLI.
- **Installer** with a restoring uninstall; safe with symlinked dotfiles.
