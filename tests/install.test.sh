#!/bin/bash
# install.sh in a sandbox HOME: install, update, uninstall, refusal cases.
# Omarchy/Hyprland are faked (calls are logged); the plugin validator and
# xdg-terminal-exec are the real ones when installed.
set -uo pipefail
exec </dev/null

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-tabby-install.XXXXXX")"
trap 'rm -rf -- "$SANDBOX"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf '  \e[31mFAIL\e[0m %s\n' "$*"
}
check() {
  local d="$1"
  shift
  if "$@"; then ok; else bad "$d"; fi
}
eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected [$2] got [$3]"; fi; }

export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_DIRS="$SANDBOX/usr/share"
export OMARCHY_TABBY_RUNTIME_DIR="$SANDBOX/run/omarchy-tabby" OMARCHY_TABBY_NO_RELOAD=1
export PATH="$SANDBOX/fakebin:$HOME/.local/bin:$PATH"
unset OMARCHY_TABBY_BIN OMARCHY_TABBY_TABBY_CMD OMARCHY_TABBY_ASSUME_COMPANION TABBY_CONFIG_DIRECTORY OMARCHY_TABBY_CONFIG_DIR OMARCHY_TABBY_STATE_DIR
LOG="$SANDBOX/calls.log"
mkdir -p "$SANDBOX/fakebin" "$XDG_CONFIG_HOME/hypr" "$XDG_CONFIG_HOME/omarchy/extensions" "$XDG_CONFIG_HOME/omarchy/plugins" "$SANDBOX/usr/share/applications"

for f in omarchy omarchy-shell; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >>%q\n' "$f" "$LOG" >"$SANDBOX/fakebin/$f"
done
cat >"$SANDBOX/fakebin/hyprctl" <<'EOF'
#!/bin/bash
case "$1" in version) echo fake ;; *) echo '[]' ;; esac
EOF
printf '#!/bin/bash\nexit 0\n' >"$SANDBOX/fakebin/tabby"
chmod +x "$SANDBOX/fakebin"/*
printf '[Desktop Entry]\nType=Application\nName=Foot\nExec=foot\nCategories=TerminalEmulator;\n' >"$SANDBOX/usr/share/applications/foot.desktop"

printf -- '-- user hyprland\nrequire("hypr.bindings")\n' >"$XDG_CONFIG_HOME/hypr/hyprland.lua"
printf '{\n  "personal": {"label":"P"}\n}\n' >"$XDG_CONFIG_HOME/omarchy/extensions/omarchy-menu.jsonc"
printf 'foot.desktop\n' >"$XDG_CONFIG_HOME/xdg-terminals.list"
mkdir -p "$XDG_CONFIG_HOME/tabby/plugins"
echo '{"dependencies":{"tabby-other":"1.0.0"}}' >"$XDG_CONFIG_HOME/tabby/plugins/package.json"
for f in hypr/hyprland.lua omarchy/extensions/omarchy-menu.jsonc xdg-terminals.list tabby/plugins/package.json; do
  cp "$XDG_CONFIG_HOME/$f" "$SANDBOX/orig.$(basename "$f")"
done

ID=io.github.saurasanchezpablo.tabby
DEST="$XDG_CONFIG_HOME/omarchy/plugins/$ID"
TP="$XDG_CONFIG_HOME/tabby/plugins"

echo "== install"
bash "$ROOT/install.sh" >"$SANDBOX/out" 2>&1
check "install exits 0" test $? -eq 0
check "plugin installed" test -f "$DEST/manifest.json"
check "install marker" test -f "$DEST/.omarchy-tabby-install"
check "cli executable" test -x "$DEST/bin/omarchy-tabby"
check "tests not shipped" bash -c '! find "$1" -name "*.test.*" | grep -q .' _ "$DEST"
check "no symlinks in plugin" bash -c '! find "$1" -type l | grep -q .' _ "$DEST"
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  check "omarchy validates the installed plugin" omarchy-plugin-validate "$DEST"
fi
check "wrapper works" bash -c '[[ $("$1" version) == $(jq -r .version "$2/manifest.json") ]]' _ "$HOME/.local/bin/omarchy-tabby" "$ROOT"
check "companion copied" test -f "$TP/omarchy/tabby-omarchy/index.js"
eq "companion link" ../omarchy/tabby-omarchy "$(readlink "$TP/node_modules/tabby-omarchy")"
check "link resolves" test -f "$TP/node_modules/tabby-omarchy/package.json"
eq "package.json keeps other deps" '{"tabby-other":"1.0.0","tabby-omarchy":"file:omarchy/tabby-omarchy"}' "$(jq -c .dependencies "$TP/package.json")"
check "hypr block" grep -q ">>> $ID" "$XDG_CONFIG_HOME/hypr/hyprland.lua"
check "menu block" grep -q ">>> $ID" "$XDG_CONFIG_HOME/omarchy/extensions/omarchy-menu.jsonc"
if command -v xdg-terminal-exec >/dev/null 2>&1; then
  real_xte="$(PATH="${PATH#"$SANDBOX/fakebin:"}" command -v xdg-terminal-exec)"
  eq "default terminal" tabby-omarchy.desktop "$("$real_xte" --print-id | cut -d: -f1)"
fi
check "widget enabled" grep -q "omarchy plugin enable $ID right" "$LOG"
check "install record" jq -e '.version and .default' "$XDG_STATE_HOME/omarchy-tabby/install.json" >/dev/null

echo "== update"
: >"$LOG"
bash "$ROOT/install.sh" >"$SANDBOX/out2" 2>&1
check "update exits 0" test $? -eq 0
eq "one hypr block" 1 "$(grep -c ">>> $ID" "$XDG_CONFIG_HOME/hypr/hyprland.lua")"
eq "one menu block" 1 "$(grep -c ">>> $ID" "$XDG_CONFIG_HOME/omarchy/extensions/omarchy-menu.jsonc")"
eq "one list entry" 1 "$(grep -cx tabby-omarchy.desktop "$XDG_CONFIG_HOME/xdg-terminals.list")"
check "shell restarted on update" grep -q "omarchy restart shell" "$LOG"

echo "== refusals"
mv "$HOME/.local/bin/omarchy-tabby" "$SANDBOX/wrapper"
printf '#!/bin/bash\necho mine\n' >"$HOME/.local/bin/omarchy-tabby"
check "won't overwrite a foreign command" bash -c '! bash "$1/install.sh" >/dev/null 2>&1' _ "$ROOT"
eq "foreign command untouched" mine "$(bash "$HOME/.local/bin/omarchy-tabby")"
mv "$SANDBOX/wrapper" "$HOME/.local/bin/omarchy-tabby"
rm -f "$DEST/.omarchy-tabby-install"
check "won't overwrite a foreign plugin dir" bash -c '! bash "$1/install.sh" >/dev/null 2>&1' _ "$ROOT"
echo 0.0.0 >"$DEST/.omarchy-tabby-install"

echo "== uninstall"
: >"$LOG"
bash "$ROOT/install.sh" --uninstall >"$SANDBOX/out3" 2>&1
check "uninstall exits 0" test $? -eq 0
check "plugin removed" test ! -e "$DEST"
check "wrapper removed" test ! -e "$HOME/.local/bin/omarchy-tabby"
check "companion removed" test ! -e "$TP/omarchy/tabby-omarchy"
check "link removed" test ! -L "$TP/node_modules/tabby-omarchy"
check "hyprland.lua restored" cmp -s "$XDG_CONFIG_HOME/hypr/hyprland.lua" "$SANDBOX/orig.hyprland.lua"
check "menu restored" cmp -s "$XDG_CONFIG_HOME/omarchy/extensions/omarchy-menu.jsonc" "$SANDBOX/orig.omarchy-menu.jsonc"
check "terminal list restored" cmp -s "$XDG_CONFIG_HOME/xdg-terminals.list" "$SANDBOX/orig.xdg-terminals.list"
eq "package.json back to the other plugin only" '{"dependencies":{"tabby-other":"1.0.0"}}' "$(jq -c . "$TP/package.json")"
check "desktop entry removed" test ! -e "$XDG_DATA_HOME/applications/tabby-omarchy.desktop"
check "settings removed" test ! -e "$XDG_CONFIG_HOME/omarchy-tabby"
check "widget disabled" grep -q "omarchy plugin disable $ID" "$LOG"

echo "== fresh Tabby plugin dir"
rm -rf "$TP"
bash "$ROOT/install.sh" --no-default --no-hypr --no-menu --no-widget >/dev/null 2>&1
eq "package.json created" '{"dependencies":{"tabby-omarchy":"file:omarchy/tabby-omarchy"}}' "$(jq -c . "$TP/package.json")"
bash "$ROOT/install.sh" --uninstall >/dev/null 2>&1
check "package.json we created is removed" test ! -e "$TP/package.json"

printf '\ninstall: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0)) || {
  echo "--- install output"
  cat "$SANDBOX/out"
}
((FAIL == 0))
