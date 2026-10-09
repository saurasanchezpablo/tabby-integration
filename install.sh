#!/bin/bash
# Install / update / uninstall the Tabby integration for Omarchy.
#
#   ./install.sh                 install or update everything
#   ./install.sh --uninstall     remove everything and restore what we changed
#
# Options: --no-default --no-hypr --no-menu --no-widget --no-keys
#          --focus-key=COMBO --dropdown-key=COMBO --keep-settings --dev
#
# Never uses sudo, never edits Tabby's config.yaml, never kills Tabby.
set -uo pipefail
unset ELECTRON_RUN_AS_NODE

SRC="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
OT_ROOT="$SRC"
# shellcheck source=lib/common.sh
source "$SRC/lib/common.sh"

PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
DEST="$PLUGINS_DIR/$PLUGIN_ID"
MARKER=".omarchy-tabby-install"
TABBY_PLUGINS="$OT_TABBY_CONFIG_DIR/plugins"
COMPANION_DIR="$TABBY_PLUGINS/omarchy/tabby-omarchy"
COMPANION_LINK="$TABBY_PLUGINS/node_modules/tabby-omarchy"
WRAPPER_TAG="# omarchy-tabby wrapper ($PLUGIN_ID)"
PAYLOAD=(manifest.json Panel.qml Model.js bin lib tabby-omarchy LICENSE README.md CHANGELOG.md)

do_default=1 do_hypr=1 do_menu=1 do_widget=1 keep_settings=0 dev=0 uninstall=0
key_args=()

step() { printf '\e[1;34m::\e[0m %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
  --uninstall) uninstall=1 ;;
  --no-default) do_default=0 ;;
  --no-hypr) do_hypr=0 ;;
  --no-menu) do_menu=0 ;;
  --no-widget) do_widget=0 ;;
  --no-keys | --focus-key=* | --dropdown-key=*) key_args+=("$1") ;;
  --keep-settings) keep_settings=1 ;;
  --dev) dev=1 ;;
  --yes | -y) ;; # accepted for scripts; the installer never prompts
  -h | --help) usage; exit 0 ;;
  *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done

((EUID != 0)) || die "run as your user, not root"
command -v jq >/dev/null 2>&1 || die "jq is required (sudo pacman -S jq)"

is_git_install() { [[ -d $DEST/.git ]]; }

# The installed CLI (falls back to the source tree before the first copy).
ot() {
  if [[ -f $DEST/bin/omarchy-tabby ]]; then
    bash "$DEST/bin/omarchy-tabby" "$@"
  else
    bash "$SRC/bin/omarchy-tabby" "$@"
  fi
}

shell_ipc() {
  command -v omarchy-shell >/dev/null 2>&1 || return 1
  omarchy-shell -q shell "$@" >/dev/null 2>&1
}

widget_enabled() {
  local shell_json="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
  [[ -f $shell_json ]] && jq -e --arg id "$PLUGIN_ID" '[.. | objects | select(.id? == $id)] | length > 0' "$shell_json" >/dev/null 2>&1
}

validate_plugin() {
  if command -v omarchy-plugin-validate >/dev/null 2>&1; then
    omarchy-plugin-validate "$1" >/dev/null
  else
    jq -e '.schemaVersion == 1 and .id and .entryPoints.barWidget' "$1/manifest.json" >/dev/null
  fi
}

# --- Omarchy plugin files ---------------------------------------------------------

install_plugin_files() {
  if is_git_install && [[ $SRC != "$DEST" ]]; then
    note "$DEST is a git checkout (omarchy plugin add); leaving its files to 'omarchy plugin update'"
    return 0
  fi
  if [[ $SRC == "$DEST" ]]; then
    note "running from the installed plugin directory"
    return 0
  fi
  if [[ -e $DEST && ! -f $DEST/$MARKER ]]; then
    die "$DEST exists and was not installed by this script; remove it first"
  fi
  mkdir -p -- "$PLUGINS_DIR" || die "cannot create $PLUGINS_DIR"
  local stage="$PLUGINS_DIR/.$PLUGIN_ID.new.$$" item
  rm -rf -- "$stage"
  mkdir -p -- "$stage" || die "cannot create $stage"
  for item in "${PAYLOAD[@]}"; do
    [[ -e $SRC/$item ]] && cp -R --no-preserve=ownership -- "$SRC/$item" "$stage/"
  done
  # The source may live on a filesystem without exec bits (e.g. rclone).
  chmod 755 "$stage/bin/omarchy-tabby"
  find "$stage" -name '*.test.*' -delete
  printf '%s\n' "$OT_VERSION" >"$stage/$MARKER"
  if ! validate_plugin "$stage"; then
    rm -rf -- "$stage"
    die "the plugin failed validation"
  fi
  rm -rf -- "$DEST"
  mv -- "$stage" "$DEST" || die "cannot move the plugin into place"
}

install_wrapper() {
  local dir
  dir="$(dirname "$OT_BIN_LINK")"
  mkdir -p -- "$dir" || die "cannot create $dir"
  if [[ -e $OT_BIN_LINK ]] && ! grep -qF "$WRAPPER_TAG" "$OT_BIN_LINK" 2>/dev/null; then
    die "$OT_BIN_LINK exists and is not ours; remove it first"
  fi
  printf '#!/bin/bash\n%s\nexec bash %q "$@"\n' "$WRAPPER_TAG" "$DEST/bin/omarchy-tabby" | write_atomic "$OT_BIN_LINK" 755 ||
    die "cannot write $OT_BIN_LINK"
  case ":$PATH:" in
  *":$dir:"*) ;;
  *) note "warning: $dir is not on PATH; Omarchy calls $OT_BIN_LINK by full path, but your shell won't find omarchy-tabby" ;;
  esac
}

# --- Tabby companion plugin --------------------------------------------------------

install_companion() {
  mkdir -p -- "$TABBY_PLUGINS/omarchy" "$TABBY_PLUGINS/node_modules" || die "cannot create $TABBY_PLUGINS"
  local stage="$TABBY_PLUGINS/omarchy/.tabby-omarchy.new.$$"
  rm -rf -- "$stage"
  cp -R --no-preserve=ownership -- "$SRC/tabby-omarchy" "$stage" || die "cannot copy the Tabby plugin"
  rm -rf -- "$COMPANION_DIR"
  mv -- "$stage" "$COMPANION_DIR" || die "cannot move the Tabby plugin into place"

  # node_modules/tabby-omarchy -> ../omarchy/tabby-omarchy, declared in
  # plugins/package.json so Tabby's plugin manager (npm Arborist) keeps it.
  if [[ -L $COMPANION_LINK || ! -e $COMPANION_LINK ]]; then
    ln -sfn ../omarchy/tabby-omarchy "$COMPANION_LINK"
  elif [[ -f $COMPANION_LINK/package.json ]] && jq -e '.name == "tabby-omarchy"' "$COMPANION_LINK/package.json" >/dev/null 2>&1; then
    rm -rf -- "$COMPANION_LINK"
    ln -sfn ../omarchy/tabby-omarchy "$COMPANION_LINK"
  else
    die "$COMPANION_LINK exists and is not ours"
  fi

  local pkg="$TABBY_PLUGINS/package.json" current='{}'
  if [[ -f $pkg ]]; then
    current="$(jq -c 'if type == "object" then . else error("not an object") end' "$pkg")" ||
      die "$pkg is not valid JSON; fix it and rerun"
  fi
  jq '.dependencies = ((.dependencies // {}) + {"tabby-omarchy": "file:omarchy/tabby-omarchy"})' <<<"$current" |
    write_atomic "$pkg" 644 || die "cannot update $pkg"
}

remove_companion() {
  local pkg="$TABBY_PLUGINS/package.json"
  [[ -L $COMPANION_LINK ]] && rm -f -- "$COMPANION_LINK"
  rm -rf -- "$COMPANION_DIR"
  rmdir -- "$TABBY_PLUGINS/omarchy" 2>/dev/null || true
  if [[ -f $pkg ]] && jq -e '.dependencies["tabby-omarchy"]' "$pkg" >/dev/null 2>&1; then
    local next
    next="$(jq 'del(.dependencies["tabby-omarchy"]) | if .dependencies == {} then del(.dependencies) else . end' "$pkg")"
    if [[ $next == "{}" ]]; then
      rm -f -- "$pkg"
    else
      write_atomic "$pkg" 644 <<<"$next"
    fi
  fi
}

# Turn the syncs off and give a running Tabby time to restore its own scheme,
# font and hotkeys (only the companion plugin can edit Tabby's config).
# Sets RESTORED=1 when Tabby confirmed it.
RESTORED=0
restore_tabby() {
  ot settings set syncColors false >/dev/null 2>&1
  ot settings set syncFont false >/dev/null 2>&1
  ot settings set clipboardKeys false >/dev/null 2>&1
  if ot status --json --fast 2>/dev/null | jq -e '.companion.loaded' >/dev/null 2>&1; then
    local _
    for _ in $(seq 1 40); do
      if ot status --json --fast 2>/dev/null | jq -e '.colors == "off" and .font == "off" and .clipboard == false' >/dev/null 2>&1; then
        note "Tabby's own colour scheme, font and copy keys are restored"
        RESTORED=1
        return 0
      fi
      sleep 0.25
    done
    note "warning: Tabby did not confirm the restore in time"
  elif [[ -f $OT_STATE_DIR/tabby-backup.json ]]; then
    note "Tabby is not running: it keeps the Omarchy scheme/font until you pick others in its settings"
    note "(your previous values are saved in $OT_STATE_DIR/tabby-backup.json)"
  fi
}

# --- Bar widget ------------------------------------------------------------------------

enable_widget() {
  shell_ipc rescanPlugins || {
    note "the Omarchy shell is not running; enable the widget later with: omarchy plugin enable $PLUGIN_ID right"
    return 0
  }
  if widget_enabled; then
    return 0
  fi
  if command -v omarchy >/dev/null 2>&1; then
    omarchy plugin enable "$PLUGIN_ID" right >/dev/null 2>&1 ||
      shell_ipc enablePlugin "$PLUGIN_ID" '{"section":"right"}' ||
      note "could not enable the bar widget; run: omarchy plugin enable $PLUGIN_ID right"
  fi
}

# --- main ---------------------------------------------------------------------------------

do_install() {
  local updating=0
  [[ -d $DEST ]] && updating=1
  tabby_installed || note "warning: Tabby is not installed yet (sudo pacman -S tabby); installing the integration anyway"

  step "Omarchy plugin → $DEST"
  install_plugin_files
  step "Command → $OT_BIN_LINK"
  install_wrapper
  step "Tabby plugin → $COMPANION_DIR"
  install_companion

  if ((do_hypr || do_menu)); then
    step "Hyprland rules and Omarchy menu"
    if ((do_hypr)); then
      ot integrate install "${key_args[@]}" || note "warning: Hyprland integration failed"
    fi
    if ((!do_menu)); then
      # integrate install does both; undo the menu part when it was not wanted.
      OT_ROOT="$DEST" bash -c 'source "$OT_ROOT/lib/common.sh"; source "$OT_ROOT/lib/integrate.sh"; menu_remove' || true
    elif ((!do_hypr)); then
      OT_ROOT="$DEST" bash -c 'source "$OT_ROOT/lib/common.sh"; source "$OT_ROOT/lib/integrate.sh"; menu_install' || true
    fi
  fi

  if ((do_default)); then
    step "Default terminal"
    if command -v xdg-terminal-exec >/dev/null 2>&1; then
      ot default on --quiet && note "SUPER+RETURN now opens Tabby (undo: omarchy-tabby default off)"
    else
      note "xdg-terminal-exec is missing; skipping"
    fi
  fi

  if ((do_widget)); then
    step "Bar widget"
    enable_widget
    if ((updating || dev)) && command -v omarchy >/dev/null 2>&1; then
      # Hot reload can keep serving the old compiled QML.
      omarchy restart shell >/dev/null 2>&1 || true
    fi
  fi

  ensure_private_dir "$OT_STATE_DIR" >/dev/null 2>&1 &&
    jq -n --arg v "$OT_VERSION" --arg at "$(date -Iseconds)" --argjson d "$do_default" --argjson h "$do_hypr" \
      --argjson m "$do_menu" --argjson w "$do_widget" \
      '{version: $v, installedAt: $at, default: ($d == 1), hyprland: ($h == 1), menu: ($m == 1), widget: ($w == 1)}' |
    write_atomic "$OT_STATE_DIR/install.json" 600

  if tabby_running && ! ot status --json --fast 2>/dev/null | jq -e '.companion.loaded' >/dev/null 2>&1; then
    step "Restart Tabby to load the integration (it is running without it)"
    notify "Restart Tabby to finish the Omarchy integration" $'\xef\x92\x89'
  fi
  step "Done: omarchy-tabby $OT_VERSION"
  ot doctor || true
}

do_uninstall() {
  step "Restoring Tabby's own settings"
  restore_tabby
  step "Default terminal"
  if ot default status -q 2>/dev/null || [[ -e $OT_STATE_DIR/xdg-terminals.list.orig || -e $OT_STATE_DIR/xdg-terminals.list.orig.absent ]]; then
    ot default off --quiet
  fi
  rm -f -- "$OT_APPS_DIR/$OT_DESKTOP_ID"
  step "Hyprland rules and Omarchy menu"
  ot integrate remove || note "warning: could not remove the Hyprland/menu integration"
  step "Bar widget"
  if command -v omarchy >/dev/null 2>&1; then
    omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || shell_ipc setPluginEnabled "$PLUGIN_ID" false || true
  fi
  step "Tabby plugin"
  remove_companion
  step "Files"
  if [[ -f $OT_BIN_LINK ]] && grep -qF "$WRAPPER_TAG" "$OT_BIN_LINK"; then
    rm -f -- "$OT_BIN_LINK"
  fi
  if is_git_install; then
    note "$DEST is a git checkout; remove it with: omarchy plugin remove $PLUGIN_ID"
  elif [[ -f $DEST/$MARKER ]]; then
    rm -rf -- "$DEST"
  fi
  shell_ipc rescanPlugins || true
  rm -rf -- "$OT_RUNTIME"
  if ((!keep_settings)); then
    rm -rf -- "$OT_CONFIG_DIR"
  fi
  rm -f -- "$OT_STATE_DIR/install.json"
  ((RESTORED)) && rm -f -- "$OT_STATE_DIR/tabby-backup.json"
  if [[ -d $OT_STATE_DIR/backups || -f $OT_STATE_DIR/tabby-backup.json ]]; then
    note "backups are kept in $OT_STATE_DIR"
  else
    rmdir -- "$OT_STATE_DIR" 2>/dev/null || true
  fi
  step "Uninstalled"
}

if ((uninstall)); then
  do_uninstall
else
  do_install
fi
