# shellcheck shell=bash
# Tabby as the default terminal (xdg-terminal-exec), the way Omarchy selects
# terminals: SUPER+RETURN, omarchy-launch-tui, menu installers, ...

OT_XDG_LIST="${OMARCHY_TABBY_XDG_LIST:-${XDG_CONFIG_HOME:-$HOME/.config}/xdg-terminals.list}"
OT_DESKTOP_FILE="$OT_APPS_DIR/$OT_DESKTOP_ID"

# Desktop Exec quoting: double-quote args, escape " ` $ \ (Desktop Entry spec).
desktop_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\`/\\\`}"
  s="${s//\$/\\\$}"
  s="${s//%/%%}" # field codes
  printf '"%s"' "$s"
}

desktop_entry() {
  cat <<EOF
[Desktop Entry]
Type=Application
Name=Tabby
GenericName=Terminal
Comment=Tabby, integrated with Omarchy
Exec=$(desktop_quote "$OT_BIN_LINK") xdg
TryExec=$OT_BIN_LINK
Icon=tabby
Terminal=false
NoDisplay=true
StartupWMClass=tabby
Categories=System;TerminalEmulator;
X-TerminalArgExec=--
X-TerminalArgAppId=--app-id=
X-TerminalArgTitle=--title=
X-TerminalArgDir=--dir=
X-TerminalArgHold=--hold
EOF
}

default_is_tabby() {
  command -v xdg-terminal-exec >/dev/null 2>&1 || return 1
  local id
  id="$(xdg-terminal-exec --print-id 2>/dev/null)" || return 1
  [[ ${id%%:*} == "$OT_DESKTOP_ID" ]]
}

write_desktop_entry() {
  mkdir -p -- "$OT_APPS_DIR" || die "cannot create $OT_APPS_DIR"
  desktop_entry | write_atomic "$OT_DESKTOP_FILE" 644 || die "cannot write $OT_DESKTOP_FILE"
}

default_on() {
  [[ -x $OT_BIN_LINK ]] || die "$OT_BIN_LINK is missing; run the installer first"
  write_desktop_entry
  ensure_private_dir "$OT_STATE_DIR" || die "cannot create $OT_STATE_DIR"
  local orig="$OT_STATE_DIR/xdg-terminals.list.orig"
  if [[ ! -e $orig && ! -e $orig.absent ]]; then
    if [[ -f $OT_XDG_LIST ]]; then
      cp -p -- "$OT_XDG_LIST" "$orig"
    else
      : >"$orig.absent"
    fi
  fi
  # Keep the previous choices after ours, so xdg-terminal-exec still has a
  # fallback if Tabby is ever uninstalled without `default off`.
  {
    echo "# Terminal emulator preference order for xdg-terminal-exec"
    echo "# The first found and valid terminal will be used"
    echo "# $OT_DESKTOP_ID was added by omarchy-tabby (undo: omarchy-tabby default off)"
    echo "$OT_DESKTOP_ID"
    if [[ -f $OT_XDG_LIST ]]; then
      grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' -e "^$OT_DESKTOP_ID\$" -- "$OT_XDG_LIST" || true
    fi
  } | replace_file "$OT_XDG_LIST" || die "cannot write $OT_XDG_LIST"
  [[ ${1:-} == --quiet ]] || notify "Tabby is now the default terminal" $'\xef\x92\x89'
}

default_off() {
  local orig="$OT_STATE_DIR/xdg-terminals.list.orig"
  if [[ -f $orig ]]; then
    replace_file "$OT_XDG_LIST" <"$orig" && rm -f -- "$orig"
  elif [[ -e $orig.absent ]]; then
    rm -f -- "$OT_XDG_LIST" "$orig.absent"
  elif [[ -f $OT_XDG_LIST ]]; then
    grep -v -e "^$OT_DESKTOP_ID\$" -e "added by omarchy-tabby" -- "$OT_XDG_LIST" | replace_file "$OT_XDG_LIST"
  fi
  rm -f -- "$OT_DESKTOP_FILE"
  [[ ${1:-} == --quiet ]] || notify "Tabby is no longer the default terminal" $'\xef\x92\x89'
}

cmd_default() {
  case "${1:-status}" in
  on) default_on "${2:-}" ;;
  off) default_off "${2:-}" ;;
  toggle) if default_is_tabby; then default_off; else default_on; fi ;;
  status)
    if [[ ${2:-} == -q ]]; then
      default_is_tabby
    elif default_is_tabby; then
      echo "Tabby is the default terminal"
    else
      echo "Default terminal: $(xdg-terminal-exec --print-id 2>/dev/null || echo unknown)"
      return 1
    fi
    ;;
  *) die "usage: omarchy-tabby default [on | off | toggle | status [-q]]" ;;
  esac
}
