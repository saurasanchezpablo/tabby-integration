# shellcheck shell=bash
# Launching Tabby: one-shot requests, xdg-terminal-exec entry point, focus,
# scratchpad.

# Remove requests nobody consumed (Tabby closed, plugin missing, ...).
prune_requests() {
  [[ -d $OT_REQUESTS ]] || return 0
  find "$OT_REQUESTS" -maxdepth 1 -type f -name '*.json*' -mmin +2 -delete 2>/dev/null || true
}

# write_request JSON -> prints the request id
write_request() {
  local json="$1" id
  ensure_private_dir "$OT_RUNTIME" && ensure_private_dir "$OT_REQUESTS" || die "cannot create $OT_REQUESTS"
  prune_requests
  id="$(random_id)"
  [[ $id =~ ^[a-f0-9]{32}$ ]] || die "cannot generate a request id"
  (umask 077 && printf '%s\n' "$json" | write_atomic "$OT_REQUESTS/$id.json" 600) || die "cannot write request"
  printf '%s\n' "$id"
}

# Starts Tabby (detached, in its own systemd scope when uwsm is around) or
# forwards the URL to the running instance.
send_to_tabby() {
  local url="$1" cmd
  cmd="$(tabby_cmd)"
  if [[ -z ${OMARCHY_TABBY_TABBY_CMD:-} ]] && ! tabby_running && command -v uwsm-app >/dev/null 2>&1; then
    env -u ELECTRON_RUN_AS_NODE setsid -f uwsm-app -- "$cmd" "$url" >/dev/null 2>&1 </dev/null
  else
    env -u ELECTRON_RUN_AS_NODE setsid -f "$cmd" "$url" >/dev/null 2>&1 </dev/null
  fi
}

# Electron cannot take focus on Wayland without an activation token, so ask
# Hyprland to focus the most recently used Tabby window once one exists.
focus_tabby_soon() {
  [[ "$(setting focusOnOpen)" == true ]] || return 0
  have_hyprctl || return 0
  (
    for _ in $(seq 1 40); do
      address="$(tabby_windows_json | jq -r '.[0].address // empty')"
      if [[ -n $address ]]; then
        sleep 0.15
        focus_window "$address"
        exit 0
      fi
      sleep 0.25
    done
  ) >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
}

# open_request ACTION DIR TITLE HOLD PROFILE FALLBACK -- ARGV...
open_request() {
  local action="$1" dir="$2" title="$3" hold="$4" profile="$5" fallback="$6"
  shift 6
  [[ ${1:-} == -- ]] && shift
  local url_dir="${fallback:-$dir}"
  [[ $url_dir == /* && -d $url_dir ]] || url_dir="$HOME"

  tabby_installed || die "Tabby is not installed (sudo pacman -S tabby)"
  # The plugin caps titles; a long one must not make the whole launch fail.
  title="${title:0:256}"

  # Installed but not loaded yet (Tabby running since before the install):
  # Tabby would treat the request URL as a plain `open` and drop the command.
  local use_requests=0
  if companion_installed; then
    if ! tabby_running || companion_loaded; then
      use_requests=1
    else
      notify "Restart Tabby to finish the Omarchy integration" $'\xef\x92\x89'
    fi
  fi

  if ((use_requests)); then
    local json id
    json="$(jq -cn \
      --arg action "$action" --arg dir "$dir" --arg title "$title" --arg profile "$profile" \
      --arg fallback "$fallback" --argjson hold "$hold" --argjson created "$(now_ms)" \
      '{v: 1, action: $action, created: $created}
       + (if $dir != "" then {cwd: $dir} else {} end)
       + (if $fallback != "" then {fallbackCwd: $fallback} else {} end)
       + (if $title != "" then {title: $title} else {} end)
       + (if $hold then {hold: true} else {} end)
       + (if $action == "profile" then {profile: $profile} else {} end)
       + (if $action == "run" then {argv: $ARGS.positional} else {} end)' \
      --args -- "$@")" || die "cannot encode request"
    ((${#json} <= 262144)) || die "command line too long for Tabby (max 256 KiB)"
    id="$(write_request "$json")"
    send_to_tabby "tabby://open?directory=$(uri_encode "$url_dir")&omarchyRequest=$id"
  else
    # Without the companion plugin only Tabby's own URL commands are left:
    # `run` shows a confirmation dialog, nothing else can be expressed.
    case "$action" in
    open | window) send_to_tabby "tabby://open?directory=$(uri_encode "$url_dir")" ;;
    run) send_to_tabby "tabby://run?command=$(uri_encode "$(printf '%q ' "$@")")" ;;
    profile) send_to_tabby "tabby://profile?profileName=$(uri_encode "$profile")" ;;
    esac
  fi
  focus_tabby_soon
}

# The directory a new terminal should start in.
#   explicit dir -> that dir
#   Tabby focused + smartCwd -> the focused Tabby window's active tab, as
#     published by tabby-omarchy; "@active" (resolved by whichever window
#     receives the request) when no window has published one.
smart_dir() {
  local dir="$1" states published
  if [[ -z $dir || $dir == "$HOME" || $dir == "$HOME/" ]] &&
    [[ "$(setting smartCwd)" == true && "$(active_window_class)" == tabby ]]; then
    states="$(window_states_json)"
    if jq -e 'length > 0' >/dev/null 2>&1 <<<"$states"; then
      published="$(jq -r '[.[] | select(.focused == true and (.cwd | type) == "string")][0].cwd // empty' <<<"$states")"
      if [[ $published == /* && -d $published ]]; then
        printf '%s\n' "$published"
      else
        printf '@active\n'
      fi
      return
    fi
  fi
  printf '%s\n' "$dir"
}

usage_open() {
  cat <<'EOF'
Usage: omarchy-tabby open [options] [-- command [args...]]

  --dir DIR        start in DIR (default: the active Tabby tab's directory when
                   Tabby is focused, otherwise $HOME)
  --title TITLE    tab title
  --hold           keep the tab open after the command exits
  --profile NAME   open a Tabby profile (name or id)
  --window         open a new Tabby window
EOF
}

cmd_open() {
  local dir="" title="" hold=false profile="" action=open
  while (($#)); do
    case "$1" in
    --dir) dir="${2:-}"; shift 2 || die "--dir needs a value" ;;
    --dir=*) dir="${1#*=}"; shift ;;
    --title) title="${2:-}"; shift 2 || die "--title needs a value" ;;
    --title=*) title="${1#*=}"; shift ;;
    --hold) hold=true; shift ;;
    --profile) profile="${2:-}"; action=profile; shift 2 || die "--profile needs a value" ;;
    --profile=*) profile="${1#*=}"; action=profile; shift ;;
    --window) action=window; shift ;;
    -h | --help) usage_open; return 0 ;;
    --) shift; break ;;
    -*) die "unknown option $1" ;;
    *) break ;;
    esac
  done
  if (($#)); then
    [[ $action == open ]] || die "a command cannot be combined with --profile or --window"
    action=run
  fi
  if [[ -n $dir ]]; then
    [[ -d $dir ]] || die "not a directory: $dir"
    dir="$(CDPATH='' cd -P -- "$dir" && pwd -P)"
  fi
  local fallback=""
  dir="$(smart_dir "$dir")"
  [[ $dir == @active ]] && fallback="$HOME"
  open_request "$action" "$dir" "$title" "$hold" "$profile" "$fallback" -- "$@"
}

# Terminal used for launches that need their own window (--app-id).
tui_terminal() {
  local choice candidate
  choice="$(setting tuiTerminal)"
  if [[ $choice == auto ]]; then
    for candidate in foot alacritty ghostty kitty; do
      if command -v "$candidate" >/dev/null 2>&1 && desktop_file_for "$candidate" >/dev/null; then
        printf '%s\n' "$candidate"
        return
      fi
    done
    printf 'tabby\n'
  else
    printf '%s\n' "$choice"
  fi
}

desktop_file_for() {
  local id dir
  case "$1" in
  foot) id=foot.desktop ;;
  alacritty) id=Alacritty.desktop ;;
  ghostty) id=com.mitchellh.ghostty.desktop ;;
  kitty) id=kitty.desktop ;;
  *) return 1 ;;
  esac
  local IFS=:
  for dir in "${XDG_DATA_HOME:-$HOME/.local/share}" ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
    if [[ -f $dir/applications/$id ]]; then
      printf '%s\n' "$dir/applications/$id"
      return 0
    fi
  done
  return 1
}

# desktop_key FILE KEY -> value from the [Desktop Entry] group
desktop_key() {
  awk -v key="$2" '
    /^\[/ { group = $0; next }
    group == "[Desktop Entry]" && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  ' "$1"
}

# Runs a command in another terminal using the same X-TerminalArg* contract
# xdg-terminal-exec uses. Never returns.
exec_other_terminal() {
  local name="$1" app_id="$2" title="$3" dir="$4" hold="$5"
  shift 5
  local file exec_line arg_exec arg_app arg_title arg_dir arg_hold
  file="$(desktop_file_for "$name")" || die "no desktop entry for $name"
  exec_line="$(desktop_key "$file" Exec)"
  [[ -n $exec_line && $exec_line != *[\"\'\\\`\$]* ]] || die "unsupported Exec line in $file"
  local -a argv
  read -r -a argv <<<"${exec_line//%[a-zA-Z]/}"
  [[ ${#argv[@]} -gt 0 ]] || die "empty Exec in $file"
  arg_exec="$(desktop_key "$file" X-TerminalArgExec)"
  arg_app="$(desktop_key "$file" X-TerminalArgAppId)"
  arg_title="$(desktop_key "$file" X-TerminalArgTitle)"
  arg_dir="$(desktop_key "$file" X-TerminalArgDir)"
  arg_hold="$(desktop_key "$file" X-TerminalArgHold)"

  add_opt() { # flag value
    [[ -n $1 && -n $2 ]] || return 0
    if [[ $1 == *= ]]; then argv+=("$1$2"); else argv+=("$1" "$2"); fi
  }
  add_opt "$arg_app" "$app_id"
  add_opt "$arg_title" "$title"
  if [[ -n $dir ]]; then
    if [[ -n $arg_dir ]]; then add_opt "$arg_dir" "$dir"; else cd -- "$dir" 2>/dev/null || true; fi
  fi
  [[ $hold == true && -n $arg_hold ]] && argv+=("$arg_hold")
  if (($#)); then
    argv+=("${arg_exec:--e}" "$@")
  fi
  exec "${argv[@]}"
}

# Entry point of tabby-omarchy.desktop, called by xdg-terminal-exec with the
# X-TerminalArg* flags declared there:
#   --app-id=ID --title=T --dir=D --hold -- command args...
cmd_xdg() {
  local app_id="" title="" dir="" hold=false
  while (($#)); do
    case "$1" in
    --app-id=*) app_id="${1#*=}"; shift ;;
    --title=*) title="${1#*=}"; shift ;;
    --dir=*) dir="${1#*=}"; shift ;;
    --hold) hold=true; shift ;;
    --) shift; break ;;
    -e) shift; break ;;
    *) break ;;
    esac
  done
  [[ -n $dir && ! -d $dir ]] && dir=""

  # Omarchy TUIs and floating installers identify their windows by app-id,
  # which Tabby (one window, many tabs) cannot provide.
  if [[ -n $app_id ]]; then
    local other
    other="$(tui_terminal)"
    if [[ $other != tabby ]]; then
      exec_other_terminal "$other" "$app_id" "$title" "$dir" "$hold" "$@"
    fi
  fi

  local fallback="" action=open
  [[ -n $dir ]] && dir="$(CDPATH='' cd -P -- "$dir" && pwd -P)"
  dir="$(smart_dir "$dir")"
  [[ $dir == @active ]] && fallback="$HOME"
  (($#)) && action=run
  open_request "$action" "$dir" "$title" "$hold" "" "$fallback" -- "$@"
}

# Focus Tabby, starting it when needed.
cmd_focus() {
  local address
  address="$(tabby_windows_json | jq -r '.[0].address // empty')"
  if [[ -n $address ]]; then
    focus_window "$address"
  else
    open_request open "" "" false "" "" --
  fi
}

# Toggle Tabby as a dropdown in the special workspace "tabby".
cmd_scratchpad() {
  have_hyprctl || die "Hyprland is not running"
  local windows address
  windows="$(tabby_windows_json)"
  address="$(jq -r --arg ws "special:$OT_SPECIAL" '[.[] | select(.workspace.name == $ws)][0].address // empty' <<<"$windows")"
  if [[ -z $address ]]; then
    address="$(jq -r '.[0].address // empty' <<<"$windows")"
    if [[ -z $address ]]; then
      open_request open "" "" false "" "" --
      for _ in $(seq 1 60); do
        sleep 0.25
        address="$(tabby_windows_json | jq -r '.[0].address // empty')"
        [[ -n $address ]] && break
      done
      [[ -n $address ]] || die "Tabby did not open a window"
    fi
    [[ $address =~ ^0x[0-9a-f]+$ ]] || die "unexpected window address"
    hypr_dispatch "hl.dsp.window.move({ workspace = \"special:$OT_SPECIAL\", follow = false, window = \"address:$address\" })" ||
      die "cannot move Tabby to the scratchpad"
  fi
  hypr_dispatch "hl.dsp.workspace.toggle_special(\"$OT_SPECIAL\")"
}

# Print the directory a new terminal would start in.
cmd_cwd() {
  local dir
  dir="$(smart_dir "")"
  if [[ $dir == @active ]]; then
    echo "@active (the focused Tabby tab's directory)"
  else
    echo "${dir:-$HOME}"
  fi
}
