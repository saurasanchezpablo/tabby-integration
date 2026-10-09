# shellcheck shell=bash
# status / profiles / apply / doctor

status_json() {
  local windows states tabby_version="" running=false default=false installed=false companion=false
  tabby_installed && installed=true
  if [[ $installed == true && ${1:-} != --fast ]]; then
    tabby_version="$(pacman -Q tabby 2>/dev/null | awk '{print $2}')"
  fi
  windows="$(tabby_windows_json)"
  states="$(window_states_json)"
  tabby_running && running=true
  fn default_is_tabby && default=true
  companion_installed && companion=true
  local cli=false hypr=false widget=false
  [[ -x $OT_BIN_LINK ]] && cli=true
  fn has_block "${OT_HYPR_MAIN:-}" -- && hypr=true
  [[ -f ${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID/manifest.json ]] && widget=true
  jq -cn \
    --argjson cli "$cli" --argjson hypr "$hypr" --argjson widget "$widget" \
    --argjson installed "$installed" --arg version "$tabby_version" --argjson running "$running" \
    --argjson windows "$windows" --argjson states "$states" --argjson default "$default" \
    --argjson companion "$companion" --argjson settings "$(settings_json)" \
    --arg pluginVersion "$OT_VERSION" --arg dropdown "special:$OT_SPECIAL" '
    ($states | sort_by(.focused | not) | .[0]) as $main |
    {
      plugin: $pluginVersion,
      tabby: { installed: $installed, version: $version, running: $running,
               windows: ($windows | length),
               dropdown: ($windows | any(.workspace.name == $dropdown)) },
      companion: { installed: $companion, loaded: ($states | length > 0),
                   version: ($main.plugin // null),
                   needsRestart: ($companion and $running and ($states | length == 0)) },
      tabs: ([$states[].tabs] | add // 0),
      colors: ($main.status.colors // null),
      font: ($main.status.font // null),
      fontFamily: ($main.status.fontFamily // null),
      theme: ($main.status.theme // null),
      clipboard: ($main.status.clipboard // null),
      default: $default,
      setup: { cli: $cli, hyprland: $hypr, companion: $companion, widget: $widget,
               complete: ($cli and $companion) },
      settings: $settings,
      profiles: ($main.profiles // [])
    }'
}

cmd_status() {
  local json
  case "${1:-}" in
  --json) status_json "${2:-}" ;;
  "")
    json="$(status_json)"
    jq -r '
      def yn: if . then "yes" else "no" end;
      "Tabby          \(if .tabby.installed then .tabby.version else "not installed" end)\(if .tabby.running then " (running, \(.tabby.windows) window(s), \(.tabs) tab(s))" else "" end)",
      "Companion      \(if .companion.loaded then "loaded \(.companion.version)" elif .companion.needsRestart then "installed, restart Tabby to load it" elif .companion.installed then "installed" else "not installed" end)",
      "Colours        \(.colors // "-")\(if .theme then " (theme \(.theme))" else "" end)",
      "Font           \(.font // "-")\(if .fontFamily then " (\(.fontFamily))" else "" end)",
      "Clipboard      \(.clipboard // "-")",
      "Default term   \(.default | yn)",
      "Dropdown       \(.tabby.dropdown | yn)"' <<<"$json"
    ;;
  *) die "usage: omarchy-tabby status [--json [--fast]]" ;;
  esac
}

cmd_profiles() {
  local json
  json="$(window_states_json | jq -c 'sort_by(.focused | not) | .[0].profiles // []')"
  if [[ ${1:-} == --json ]]; then
    printf '%s\n' "$json"
  else
    jq -r '.[] | "\(.id)\t\(.name)\t\(.type)"' <<<"$json"
  fi
}

# Re-apply Omarchy colours and font even if the sync is paused because a
# different scheme/font was picked in Tabby.
cmd_apply() {
  ensure_private_dir "$OT_RUNTIME" || die "cannot create $OT_RUNTIME"
  jq -cn --argjson t "$(now_ms)" '{apply: $t}' | write_atomic "$OT_CONTROL" 600 || die "cannot write $OT_CONTROL"
  local s
  s="$(settings_json)"
  if [[ "$(jq -r '.syncColors and .syncFont' <<<"$s")" != true ]]; then
    warn "colour or font sync is off; enable it with: omarchy-tabby settings set syncColors true"
  fi
  if ! companion_loaded; then
    warn "Tabby is not running with the companion plugin; it will apply on next start"
  fi
}

cmd_doctor() {
  local ok=0
  check() { # label command...
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
      printf '  \e[32m✓\e[0m %s\n' "$label"
    else
      printf '  \e[31m✗\e[0m %s\n' "$label"
      ok=1
      return 1
    fi
  }
  echo "omarchy-tabby $OT_VERSION ($OT_ROOT)"
  check "tabby installed" tabby_installed
  check "jq installed" command -v jq
  check "Hyprland reachable" have_hyprctl
  check "xdg-terminal-exec installed" command -v xdg-terminal-exec
  check "omarchy-tabby on PATH ($OT_BIN_LINK)" test -x "$OT_BIN_LINK"
  if ! check "Omarchy bar widget installed" test -f "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID/manifest.json"; then
    printf '    (removed with omarchy plugin remove? put it back with: omarchy-tabby setup)\n'
  fi
  check "companion Tabby plugin installed" companion_installed
  check "companion survives Tabby's plugin manager" jq -e '.dependencies["tabby-omarchy"]' "$OT_TABBY_CONFIG_DIR/plugins/package.json"
  if tabby_running; then
    check "companion loaded in the running Tabby" companion_loaded
  fi
  check "current Omarchy theme readable" test -r "$HOME/.local/state/omarchy/current/theme/colors.toml"
  check "Hyprland integration" fn has_block "${OT_HYPR_MAIN:-}" --
  check "Omarchy menu entries" fn has_block "${OT_MENU_FILE:-}" '  //'
  check "runtime dir private" bash -c '[[ ! -e $1 ]] || [[ -O $1 && $(stat -c %a "$1") == 700 ]]' _ "$OT_RUNTIME"
  if fn default_is_tabby; then
    printf '  • Tabby is the default terminal; TUIs open in: %s\n' "$(tui_terminal)"
  else
    printf '  • default terminal: %s (omarchy-tabby default on)\n' "$(xdg-terminal-exec --print-id 2>/dev/null || echo unknown)"
  fi
  return $ok
}
