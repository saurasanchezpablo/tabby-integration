#!/bin/bash
# Sandboxed tests for bin/omarchy-tabby: fake tabby/hyprctl/terminals on PATH,
# every directory under a throwaway HOME. Never touches the real desktop.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/omarchy-tabby"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-tabby-cli.XXXXXX")"
trap 'rm -rf -- "$SANDBOX"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf '  \e[31mFAIL\e[0m %s\n' "$*"
}
check() { # description command...
  local d="$1"
  shift
  if "$@"; then ok; else bad "$d"; fi
}
eq() { # description expected actual
  if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected [$2] got [$3]"; fi
}

export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_DIRS="$SANDBOX/usr/share"
export OMARCHY_TABBY_RUNTIME_DIR="$SANDBOX/run/omarchy-tabby"
export OMARCHY_TABBY_BIN="$HOME/.local/bin/omarchy-tabby"
export OMARCHY_TABBY_NO_RELOAD=1
unset OMARCHY_TABBY_TABBY_CMD OMARCHY_TABBY_ASSUME_COMPANION TABBY_CONFIG_DIRECTORY OMARCHY_TABBY_CONFIG_DIR OMARCHY_TABBY_STATE_DIR
mkdir -p "$HOME/.local/bin" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME/applications" "$SANDBOX/usr/share/applications" "$SANDBOX/fakebin" "$SANDBOX/run"
ln -s "$CLI" "$OMARCHY_TABBY_BIN"

# Fake binaries -----------------------------------------------------------------
FAKE="$SANDBOX/fakebin"
LOG="$SANDBOX/calls.log"
cat >"$FAKE/tabby" <<EOF
#!/bin/bash
printf 'tabby %s\n' "\$*" >>"$LOG"
EOF
cat >"$FAKE/foot" <<EOF
#!/bin/bash
printf 'foot' >>"$LOG"; printf ' [%s]' "\$@" >>"$LOG"; printf ' cwd=%s\n' "\$PWD" >>"$LOG"
EOF
# hyprctl answers from files so each test can set the scene.
cat >"$FAKE/hyprctl" <<EOF
#!/bin/bash
case "\$1" in
  version) echo "Hyprland fake" ;;
  clients) cat "$SANDBOX/clients.json" 2>/dev/null || echo '[]' ;;
  activewindow) cat "$SANDBOX/active.json" 2>/dev/null || echo '{}' ;;
  binds) cat "$SANDBOX/binds.json" 2>/dev/null || echo '[]' ;;
  dispatch) printf 'hyprctl dispatch %s\n' "\$2" >>"$LOG" ;;
  *) : ;;
esac
EOF
cat >"$FAKE/setsid" <<'EOF'
#!/bin/bash
[[ $1 == -f ]] && shift
exec "$@"
EOF
cat >"$FAKE/omarchy-notification-send" <<EOF
#!/bin/bash
printf 'notify %s\n' "\$*" >>"$LOG"
EOF
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"
# Hide uwsm-app so launches are direct and observable.
uwsm_shadow="$FAKE/uwsm-app"
printf '#!/bin/bash\nexit 127\n' >"$uwsm_shadow" && chmod +x "$uwsm_shadow"

cat >"$SANDBOX/usr/share/applications/foot.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Foot
Exec=foot
Categories=System;TerminalEmulator;
X-TerminalArgExec=-e
X-TerminalArgAppId=--app-id=
X-TerminalArgTitle=--title=
X-TerminalArgDir=--working-directory=
X-TerminalArgHold=--hold

[Desktop Action server]
Exec=foot --server
EOF

ot() { bash "$CLI" "$@"; }
last_request() {
  local f
  f="$(ls -t "$OMARCHY_TABBY_RUNTIME_DIR/requests"/*.json 2>/dev/null | head -1)"
  [[ -n $f ]] && cat "$f"
}
reset_log() { : >"$LOG"; rm -f "$OMARCHY_TABBY_RUNTIME_DIR/requests"/*.json; }
companion() {
  mkdir -p "$HOME/.config/tabby/plugins/node_modules/tabby-omarchy"
  echo '{}' >"$HOME/.config/tabby/plugins/node_modules/tabby-omarchy/package.json"
}
no_companion() { rm -rf "$HOME/.config/tabby/plugins"; }
# A live window state, as tabby-omarchy writes it (pid of this shell = alive).
loaded() {
  mkdir -p "$OMARCHY_TABBY_RUNTIME_DIR/windows"
  chmod 700 "$OMARCHY_TABBY_RUNTIME_DIR" "$OMARCHY_TABBY_RUNTIME_DIR/windows"
  echo '{"v":1,"pid":'$$',"plugin":"0.1.0","focused":true,"tabs":3,"status":{"colors":"synced","font":"synced","clipboard":true,"theme":"tokyo-night","fontFamily":"JetBrainsMono Nerd Font"},"profiles":[{"id":"local:bash","name":"bash","type":"local","group":"","builtin":true}]}' \
    >"$OMARCHY_TABBY_RUNTIME_DIR/windows/$$.json"
}
focused_tabby() {
  echo '[{"address":"0xabc","class":"tabby","focusHistoryID":0,"workspace":{"name":"1"}}]' >"$SANDBOX/clients.json"
  echo '{"class":"tabby"}' >"$SANDBOX/active.json"
}
focused_other() {
  echo '[]' >"$SANDBOX/clients.json"
  echo '{"class":"firefox"}' >"$SANDBOX/active.json"
}

echo "== settings"
eq "default syncColors" true "$(ot settings get syncColors)"
check "set false" ot settings set syncColors false
eq "stored" false "$(ot settings get syncColors)"
check "toggle" ot settings toggle syncColors
eq "toggled" true "$(ot settings get syncColors)"
check "enum set" ot settings set tuiTerminal foot
check "reject unknown key" bash -c '! bash "$1" settings set nope 1 2>/dev/null' _ "$CLI"
check "reject bad bool" bash -c '! bash "$1" settings set syncFont maybe 2>/dev/null' _ "$CLI"
check "reject bad enum" bash -c '! bash "$1" settings set tuiTerminal xterm 2>/dev/null' _ "$CLI"
check "reject toggling an enum" bash -c '! bash "$1" settings toggle tuiTerminal 2>/dev/null' _ "$CLI"
echo '{"syncFont": "garbage", "smartCwd": false, "x": 1}' >"$XDG_CONFIG_HOME/omarchy-tabby/settings.json"
eq "garbage falls back to default" true "$(ot settings get syncFont)"
eq "valid stored value kept" false "$(ot settings get smartCwd)"
echo 'not json' >"$XDG_CONFIG_HOME/omarchy-tabby/settings.json"
eq "corrupt file falls back" true "$(ot settings get smartCwd)"
check "list --json" bash -c 'bash "$1" settings list --json | jq -e "length == 6 and all(has(\"label\"))" >/dev/null' _ "$CLI"
ot settings reset

echo "== open (companion installed)"
companion
focused_other
reset_log
check "open --dir" ot open --dir /tmp
req="$(last_request)"
eq "action" open "$(jq -r .action <<<"$req")"
eq "cwd" /tmp "$(jq -r .cwd <<<"$req")"
id="$(ls "$OMARCHY_TABBY_RUNTIME_DIR/requests" | head -1)"
id="${id%.json}"
check "id is 128-bit hex" bash -c '[[ $1 =~ ^[a-f0-9]{32}$ ]]' _ "$id"
check "url carries the id" grep -q "tabby tabby://open?directory=%2Ftmp&omarchyRequest=$id" "$LOG"
eq "request file mode" 600 "$(stat -c %a "$OMARCHY_TABBY_RUNTIME_DIR/requests/$id.json")"
eq "request dir mode" 700 "$(stat -c %a "$OMARCHY_TABBY_RUNTIME_DIR/requests")"
eq "runtime dir mode" 700 "$(stat -c %a "$OMARCHY_TABBY_RUNTIME_DIR")"

reset_log
check "run command" ot open --title 'my "tab"' --hold -- printf '%s\n' 'a b' '$(id)'
req="$(last_request)"
eq "run action" run "$(jq -r .action <<<"$req")"
eq "argv kept verbatim" '["printf","%s\\n","a b","$(id)"]' "$(jq -c .argv <<<"$req")"
eq "title" 'my "tab"' "$(jq -r .title <<<"$req")"
eq "hold" true "$(jq -r .hold <<<"$req")"
check "no shell in url" bash -c '! grep -q "printf" "$1"' _ "$LOG"

reset_log
check "profile" ot open --profile 'SSH prod'
eq "profile action" 'profile:SSH prod' "$(jq -r '"\(.action):\(.profile)"' <<<"$(last_request)")"
check "window" ot open --window
eq "window action" window "$(jq -r .action <<<"$(last_request)")"
check "reject missing dir" bash -c '! bash "$1" open --dir /does/not/exist 2>/dev/null' _ "$CLI"
check "reject profile+command" bash -c '! bash "$1" open --profile x -- ls 2>/dev/null' _ "$CLI"

echo "== smart cwd"
focused_tabby
loaded
eq "cwd follows tabby" "@active (the focused Tabby tab's directory)" "$(ot cwd)"
reset_log
ot xdg --dir="$HOME"
req="$(last_request)"
eq "xdg uses @active" "@active" "$(jq -r .cwd <<<"$req")"
eq "xdg fallback" "$HOME" "$(jq -r .fallbackCwd <<<"$req")"
reset_log
ot xdg --dir=/tmp
eq "explicit dir wins" /tmp "$(jq -r .cwd <<<"$(last_request)")"
ot settings set smartCwd false
reset_log
ot xdg --dir="$HOME"
eq "smartCwd off" "$HOME" "$(jq -r .cwd <<<"$(last_request)")"
ot settings reset
focused_other
eq "not focused" "$HOME" "$(ot cwd)"

echo "== xdg entry point"
reset_log
ot xdg --title=T -- htop -d 10
req="$(last_request)"
eq "xdg run argv" '["htop","-d","10"]' "$(jq -c .argv <<<"$req")"
eq "xdg title" T "$(jq -r .title <<<"$req")"
reset_log
ot xdg --app-id=org.omarchy.btop --title=btop --dir=/tmp --hold -- btop
eq "app-id goes to foot" "foot [--app-id=org.omarchy.btop] [--title=btop] [--working-directory=/tmp] [--hold] [-e] [btop] cwd=$PWD" "$(grep '^foot' "$LOG")"
check "no tabby request for TUIs" bash -c '! grep -q "^tabby" "$1"' _ "$LOG"
ot settings set tuiTerminal tabby
reset_log
ot xdg --app-id=org.omarchy.btop -- btop
check "tuiTerminal=tabby keeps it in Tabby" grep -q "^tabby tabby://open" "$LOG"
ot settings reset

echo "== fallback without companion"
no_companion
rm -rf "$OMARCHY_TABBY_RUNTIME_DIR/windows"
focused_other
reset_log
ot open --dir /tmp
check "plain open url" grep -qx "tabby tabby://open?directory=%2Ftmp" "$LOG"
reset_log
ot open -- echo 'hi there'
check "run url (confirmed by Tabby)" grep -q "^tabby tabby://run?command=echo%20hi%5C%20there" "$LOG"
check "no request files without companion" bash -c '! ls "$1"/requests/*.json 2>/dev/null' _ "$OMARCHY_TABBY_RUNTIME_DIR"

echo "== status / profiles"
companion
loaded
focused_tabby
check "status json" bash -c 'bash "$1" status --json --fast | jq -e ".companion.loaded and .tabs == 3 and .colors == \"synced\" and (.profiles | length) == 1" >/dev/null' _ "$CLI"
eq "profiles" "local:bash	bash	local" "$(ot profiles)"
check "stale window state pruned" bash -c '
  echo "{\"v\":1}" > "$2/windows/999999.json"
  bash "$1" status --json --fast >/dev/null
  [[ ! -e $2/windows/999999.json ]]' _ "$CLI" "$OMARCHY_TABBY_RUNTIME_DIR"
check "apply writes control" bash -c 'bash "$1" apply 2>/dev/null; jq -e ".apply > 0" "$2/control.json" >/dev/null' _ "$CLI" "$OMARCHY_TABBY_RUNTIME_DIR"

echo "== scratchpad"
reset_log
echo '[{"address":"0xabc","class":"tabby","focusHistoryID":0,"workspace":{"name":"1"}}]' >"$SANDBOX/clients.json"
ot scratchpad
check "moves to special" grep -q 'hl.dsp.window.move({ workspace = "special:tabby", follow = false, window = "address:0xabc" })' "$LOG"
check "toggles special" grep -q 'toggle_special("tabby")' "$LOG"
reset_log
echo '[{"address":"0xabc","class":"tabby","focusHistoryID":0,"workspace":{"name":"special:tabby"}}]' >"$SANDBOX/clients.json"
ot scratchpad
check "already there: only toggles" bash -c '! grep -q window.move "$1" && grep -q toggle_special "$1"' _ "$LOG"
echo '[{"address":"0xabc; os.execute(1)","class":"tabby","focusHistoryID":0,"workspace":{"name":"1"}}]' >"$SANDBOX/clients.json"
reset_log
check "rejects a weird address" bash -c '! bash "$1" scratchpad 2>/dev/null' _ "$CLI"
check "nothing dispatched for weird address" bash -c '! grep -q dispatch "$1"' _ "$LOG"

printf '\ncli: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
