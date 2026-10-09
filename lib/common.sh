# shellcheck shell=bash
# Shared helpers for omarchy-tabby. Sourced, never executed.
#
# Directory layout must match tabby-omarchy/lib/paths.js.

PLUGIN_ID="io.github.saurasanchezpablo.tabby"
OT_VERSION="$(jq -r .version "$OT_ROOT/manifest.json" 2>/dev/null || echo 0.0.0)"

OT_RUNTIME="${OMARCHY_TABBY_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$UID}/omarchy-tabby}"
OT_REQUESTS="$OT_RUNTIME/requests"
OT_WINDOWS="$OT_RUNTIME/windows"
OT_CONTROL="$OT_RUNTIME/control.json"
OT_CONFIG_DIR="${OMARCHY_TABBY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-tabby}"
OT_SETTINGS="$OT_CONFIG_DIR/settings.json"
OT_STATE_DIR="${OMARCHY_TABBY_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-tabby}"
OT_SCHEMA="$OT_ROOT/tabby-omarchy/lib/settings-schema.json"
OT_TABBY_CONFIG_DIR="${TABBY_CONFIG_DIRECTORY:-${XDG_CONFIG_HOME:-$HOME/.config}/tabby}"
OT_APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
OT_DESKTOP_ID="tabby-omarchy.desktop"
OT_SPECIAL="tabby"
OT_BIN_LINK="${OMARCHY_TABBY_BIN:-$HOME/.local/bin/omarchy-tabby}"

die() {
  printf 'omarchy-tabby: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'omarchy-tabby: %s\n' "$*" >&2
}

# Desktop notification through Omarchy when available. Never fails.
notify() {
  local msg="$1" glyph="${2:-}"
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    if [[ -n $glyph ]]; then
      omarchy-notification-send -g "$glyph" "$msg" >/dev/null 2>&1 || true
    else
      omarchy-notification-send "$msg" >/dev/null 2>&1 || true
    fi
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name=Tabby -- "Tabby" "$msg" >/dev/null 2>&1 || true
  fi
}

now_ms() {
  date +%s%3N
}

# mkdir -p with 0700; tightens a directory we own, refuses anything else.
ensure_private_dir() {
  local dir="$1"
  (umask 077 && mkdir -p -- "$dir") || return 1
  [[ -d $dir && ! -L $dir && -O $dir ]] || {
    warn "$dir is not a directory owned by $USER"
    return 1
  }
  chmod 700 -- "$dir"
}

# 128 random bits as 32 lowercase hex chars.
random_id() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

uri_encode() {
  jq -rn --arg v "$1" '$v|@uri'
}

# Write stdin to $1 atomically (same directory, then rename).
write_atomic() {
  local file="$1" mode="${2:-600}" tmp
  tmp="$(mktemp "${file}.XXXXXX.tmp")" || return 1
  if cat >"$tmp" && chmod "$mode" "$tmp" && mv -f -- "$tmp" "$file"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Replace FILE's content with stdin, atomically, keeping its mode. A symlink
# (dotfile managers) is followed: the target is rewritten and the link kept,
# instead of being replaced by a copy with the link's 0777 mode.
replace_file() {
  local file="$1" default_mode="${2:-644}" target mode
  target="$(readlink -f -- "$file" 2>/dev/null)"
  [[ -n $target ]] || target="$file"
  if [[ -e $target ]]; then
    mode="$(stat -L -c %a -- "$target")" || return 1
  else
    mode="$default_mode"
  fi
  write_atomic "$target" "$mode"
}

tabby_installed() {
  [[ -n ${OMARCHY_TABBY_TABBY_CMD:-} ]] || command -v tabby >/dev/null 2>&1
}

# Command that launches/forwards to Tabby. OMARCHY_TABBY_TABBY_CMD (one
# executable) lets tests point at an isolated instance.
tabby_cmd() {
  printf '%s\n' "${OMARCHY_TABBY_TABBY_CMD:-tabby}"
}

tabby_running() {
  if [[ -n ${OMARCHY_TABBY_TABBY_CMD:-} ]]; then
    tabby_windows_json | jq -e 'length > 0' >/dev/null 2>&1
  else
    pgrep -u "$UID" -f -- '/usr/lib/tabby/app.asar' >/dev/null 2>&1
  fi
}

have_hyprctl() {
  command -v hyprctl >/dev/null 2>&1 && hyprctl version >/dev/null 2>&1
}

# JSON array of Tabby windows, most recently focused first.
tabby_windows_json() {
  have_hyprctl || {
    echo '[]'
    return
  }
  hyprctl clients -j 2>/dev/null |
    jq -c '[.[] | select(.class == "tabby")] | sort_by(.focusHistoryID)' 2>/dev/null || echo '[]'
}

active_window_class() {
  have_hyprctl || return 0
  hyprctl activewindow -j 2>/dev/null | jq -r '.class // empty' 2>/dev/null || true
}

hypr_dispatch() {
  have_hyprctl || return 1
  hyprctl dispatch "$1" >/dev/null 2>&1
}

focus_window() {
  local address="$1"
  [[ $address =~ ^0x[0-9a-f]+$ ]] || return 1
  hypr_dispatch "hl.dsp.focus({ window = \"address:$address\" })" ||
    hyprctl dispatch focuswindow "address:$address" >/dev/null 2>&1
}

# Companion plugin state ------------------------------------------------------

companion_installed() {
  [[ -f $OT_TABBY_CONFIG_DIR/plugins/node_modules/tabby-omarchy/package.json ]] ||
    [[ -n ${OMARCHY_TABBY_ASSUME_COMPANION:-} ]]
}

# Live window states written by tabby-omarchy, as one JSON array. Files whose
# renderer process is gone are skipped (and removed when owned by us).
window_states_json() {
  local f pid out=()
  [[ -d $OT_WINDOWS ]] || {
    echo '[]'
    return
  }
  for f in "$OT_WINDOWS"/*.json; do
    [[ -f $f && ! -L $f && -O $f ]] || continue
    pid="${f##*/}"
    pid="${pid%.json}"
    [[ $pid =~ ^[0-9]+$ ]] || continue
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f -- "$f"
      continue
    fi
    out+=("$f")
  done
  if ((${#out[@]} == 0)); then
    echo '[]'
  else
    jq -cs '[.[] | select(type == "object" and .v == 1)]' "${out[@]}" 2>/dev/null || echo '[]'
  fi
}

companion_loaded() {
  window_states_json | jq -e 'length > 0' >/dev/null 2>&1
}
