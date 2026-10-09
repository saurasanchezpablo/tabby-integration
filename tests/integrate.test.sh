#!/bin/bash
# Hyprland + Omarchy menu integration, in a sandbox. Uses Omarchy's own menu
# parser (MenuModel.js) and executes the generated Lua with a stubbed `o` API.
set -uo pipefail
exec </dev/null

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/omarchy-tabby"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-tabby-int.XXXXXX")"
trap 'rm -rf -- "$SANDBOX"' EXIT
MENU_MODEL="${OMARCHY_PATH:-/usr/share/omarchy}/shell/plugins/menu/MenuModel.js"

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
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state" XDG_DATA_HOME="$HOME/.local/share"
export OMARCHY_TABBY_RUNTIME_DIR="$SANDBOX/run/omarchy-tabby" OMARCHY_TABBY_NO_RELOAD=1
export OMARCHY_TABBY_BIN="$HOME/.local/bin/omarchy-tabby"
unset OMARCHY_TABBY_CONFIG_DIR OMARCHY_TABBY_STATE_DIR OMARCHY_TABBY_HYPR_DIR OMARCHY_TABBY_MENU_FILE
mkdir -p "$XDG_CONFIG_HOME/hypr" "$XDG_CONFIG_HOME/omarchy/extensions" "$HOME/.local/bin" "$SANDBOX/fakebin"
printf '#!/bin/bash\nexec bash %q "$@"\n' "$CLI" >"$OMARCHY_TABBY_BIN"
chmod +x "$OMARCHY_TABBY_BIN"

cat >"$SANDBOX/fakebin/hyprctl" <<EOF
#!/bin/bash
case "\$1" in
  version) echo fake ;;
  binds) cat "$SANDBOX/binds.json" 2>/dev/null || echo '[]' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$SANDBOX/fakebin/hyprctl"
export PATH="$SANDBOX/fakebin:$PATH"

HYPR="$XDG_CONFIG_HOME/hypr/hyprland.lua"
MENU="$XDG_CONFIG_HOME/omarchy/extensions/omarchy-menu.jsonc"
cat >"$HYPR" <<'EOF'
-- user config
require("hypr.bindings")
EOF
cat >"$MENU" <<'EOF'
{
  // Extend the Quickshell Omarchy menu with JSONC.
  // "personal": {"icon":"","label":"Personal"},
  "personal": {"icon":"x","label":"Personal"},
  "personal.notes": {"icon":"y","label":"Notes","action":"echo notes"}
}
EOF
cp "$HYPR" "$SANDBOX/hypr.orig"
cp "$MENU" "$SANDBOX/menu.orig"

ot() { bash "$CLI" "$@"; }

# Runs the generated Lua with a stub `o` and prints what it registered.
run_lua() {
  lua -e '
    o = {
      window = function(match, rules) print("window", match, rules.tag) end,
      bind = function(keys, desc, cmd) print("bind", keys, desc, cmd) end,
    }
    dofile(arg[1])' "$1"
}

echo "== hyprland"
echo '[{"modmask":64,"key":"RETURN"}]' >"$SANDBOX/binds.json"
check "install" ot integrate install
check "block added" grep -q '>>> io.github.saurasanchezpablo.tabby' "$HYPR"
check "generated file" test -f "$XDG_CONFIG_HOME/hypr/omarchy-tabby.lua"
if command -v lua >/dev/null 2>&1; then
  out="$(run_lua "$XDG_CONFIG_HOME/hypr/omarchy-tabby.lua")"
  check "terminal tag rule" grep -qx $'window\t^(tabby)$\t+terminal' <<<"$out"
  check "focus binding" grep -qx $'bind\tSUPER + ALT + T\tTabby\t'"$OMARCHY_TABBY_BIN focus" <<<"$out"
  check "dropdown binding" grep -qx $'bind\tSUPER + grave\tTabby dropdown\t'"$OMARCHY_TABBY_BIN scratchpad" <<<"$out"
  # The loader line in hyprland.lua must load our file, and survive it being broken.
  loader="$(sed -n '/>>> io.github.saurasanchezpablo.tabby/,/<<< io.github.saurasanchezpablo.tabby/p' "$HYPR" | sed '1d;$d')"
  printf 'o = { window = function() print("loaded") end, bind = function() end }\n%s\n' "$loader" >"$SANDBOX/loader.lua"
  eq "loader runs our file" loaded "$(lua "$SANDBOX/loader.lua" | head -1)"
  cp "$XDG_CONFIG_HOME/hypr/omarchy-tabby.lua" "$SANDBOX/good.lua"
  echo 'this is not lua' >"$XDG_CONFIG_HOME/hypr/omarchy-tabby.lua"
  check "broken file does not break the config" bash -c 'lua "$1" >/dev/null 2>&1' _ "$SANDBOX/loader.lua"
  cp "$SANDBOX/good.lua" "$XDG_CONFIG_HOME/hypr/omarchy-tabby.lua"
  check "lua syntax of hyprland.lua" luac -p "$HYPR"
else
  echo "  (lua not installed, Lua checks skipped)"
fi
check "reinstall is idempotent" ot integrate install
eq "one block" 1 "$(grep -c '>>> io.github.saurasanchezpablo.tabby' "$HYPR")"
check "backup kept" bash -c 'ls "$1"/omarchy-tabby/backups/hyprland.lua.*.bak >/dev/null 2>&1' _ "$XDG_STATE_HOME"

echo '[{"modmask":72,"key":"t"},{"modmask":64,"key":"grave"}]' >"$SANDBOX/binds.json"
ot integrate remove
ot integrate install 2>"$SANDBOX/err"
check "conflict warned" grep -q "already bound" "$SANDBOX/err"
check "conflicting keys skipped" bash -c '! grep -q "o.bind" "$1"' _ "$XDG_CONFIG_HOME/hypr/omarchy-tabby.lua"
check "rule still installed" grep -q 'tag = "+terminal"' "$XDG_CONFIG_HOME/hypr/omarchy-tabby.lua"
echo '[]' >"$SANDBOX/binds.json"
check "custom keys" ot integrate install --focus-key="SUPER + CTRL + ALT + T" --no-keys
check "--no-keys wins" bash -c '! grep -q "o.bind" "$1"' _ "$XDG_CONFIG_HOME/hypr/omarchy-tabby.lua"
check "rejects injection in key combos" bash -c '! bash "$1" integrate install --focus-key="SUPER + T\") os.execute(\"x" 2>/dev/null' _ "$CLI"

echo "== menu"
check "menu block" grep -q '>>> io.github.saurasanchezpablo.tabby' "$MENU"
check "glyphs stay escaped" grep -qF "$(printf '\\u%s' f489)" "$MENU"
check "user entries untouched" grep -qF '"personal.notes": {"icon":"y","label":"Notes","action":"echo notes"}' "$MENU"
if command -v node >/dev/null 2>&1 && [[ -f $MENU_MODEL ]]; then
  ids="$(node -e '
    const M = require(process.argv[1]); const fs = require("fs")
    const items = M.parseMenuJsonc(fs.readFileSync(process.argv[2], "utf8"))
    console.log(items.map(i => i.id + ":" + i.parent).sort().join(" "))' "$MENU_MODEL" "$MENU")"
  check "Omarchy parses our entries" grep -q "setup.tabby.colors:setup.tabby" <<<"$ids"
  check "default terminal entry under Terminal" grep -q "setup.default.terminal.tabby:setup.default.terminal" <<<"$ids"
  check "user entries still parse" grep -q "personal.notes:personal" <<<"$ids"
  # Run the shell guards exactly as the menu does (when/checked).
  guard="$(node -e '
    const M = require(process.argv[1]); const fs = require("fs")
    const items = {}
    for (const i of M.parseMenuJsonc(fs.readFileSync(process.argv[2], "utf8"))) items[i.id] = i
    process.stdout.write(M.guardScript(items, Object.keys(items)))' "$MENU_MODEL" "$MENU")"
  check "guard script runs" bash -c "$guard" >/dev/null 2>&1
else
  echo "  (node or MenuModel.js missing, parser checks skipped)"
fi
ot integrate install --no-keys
eq "menu block once" 1 "$(grep -c '>>> io.github.saurasanchezpablo.tabby' "$MENU")"

echo "== remove restores files"
check "remove" ot integrate remove
check "hyprland.lua restored byte for byte" cmp -s "$HYPR" "$SANDBOX/hypr.orig"
check "menu restored byte for byte" cmp -s "$MENU" "$SANDBOX/menu.orig"
check "generated lua removed" test ! -e "$XDG_CONFIG_HOME/hypr/omarchy-tabby.lua"
eq "status absent" $'hyprland\tabsent\nmenu\tabsent' "$(ot integrate status)"

echo "== menu edge cases"
rm -f "$MENU"
check "creates a missing menu file" ot integrate install --no-keys
check "valid JSON when created" python3 -c '
import json, re, sys
t = open(sys.argv[1]).read()
t = re.sub(r"(?m)^\s*//[^\n]*(\n|$)", "", t); t = re.sub(r",(\s*[}\]])", r"\1", t)
json.loads(t)' "$MENU"
printf '{"a": {"label":"A"}}\n' >"$MENU"
cp "$MENU" "$SANDBOX/compact"
ot integrate install --no-keys 2>/dev/null
check "compact file left untouched" cmp -s "$MENU" "$SANDBOX/compact"

printf '\nintegrate: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
