#!/bin/bash
# End-to-end test against a real, isolated Tabby (own --user-data-dir and
# config, own runtime/settings dirs). It opens a Tabby window on the current
# screen for ~30 seconds and closes it. Run through: tests/run.sh --e2e
set -uo pipefail
exec </dev/null
unset ELECTRON_RUN_AS_NODE

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/omarchy-tabby"
command -v tabby >/dev/null 2>&1 || {
  echo "e2e: tabby not installed, skipped"
  exit 0
}
[[ -n ${WAYLAND_DISPLAY:-} ]] || {
  echo "e2e: no Wayland session, skipped"
  exit 0
}

W="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-tabby-e2e.XXXXXX")"
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

UD="$W/ud"
mkdir -p "$UD/plugins/omarchy" "$UD/plugins/node_modules" "$W/rt" "$W/conf" "$W/state"
chmod 700 "$W/rt"
# Same layout install.sh creates.
cp -R "$ROOT/tabby-omarchy" "$UD/plugins/omarchy/tabby-omarchy"
ln -s ../omarchy/tabby-omarchy "$UD/plugins/node_modules/tabby-omarchy"
echo '{"dependencies":{"tabby-omarchy":"file:omarchy/tabby-omarchy"}}' >"$UD/plugins/package.json"

export OMARCHY_TABBY_RUNTIME_DIR="$W/rt" OMARCHY_TABBY_CONFIG_DIR="$W/conf" OMARCHY_TABBY_STATE_DIR="$W/state"
export TABBY_CONFIG_DIRECTORY="$UD" OMARCHY_TABBY_ASSUME_COMPANION=1
printf '#!/bin/bash\nexec tabby --user-data-dir=%q "$@"\n' "$UD" >"$W/tabby"
chmod +x "$W/tabby"
export OMARCHY_TABBY_TABBY_CMD="$W/tabby"

tabby_pids() {
  # [-] keeps the pattern from matching this script's own command line.
  pgrep -u "$UID" -f -- "[-]-user-data-dir=$UD" 2>/dev/null
}
cleanup() {
  local pids
  pids="$(tabby_pids)"
  # shellcheck disable=SC2086
  [[ -n $pids ]] && kill $pids 2>/dev/null
  for _ in $(seq 1 20); do
    [[ -z $(tabby_pids) ]] && break
    sleep 0.25
  done
  pids="$(tabby_pids)"
  # shellcheck disable=SC2086
  [[ -n $pids ]] && kill -9 $pids 2>/dev/null
  rm -rf -- "$W"
}
trap cleanup EXIT

ot() { bash "$CLI" "$@"; }
state() { cat "$W"/rt/windows/*.json 2>/dev/null | head -1; }
wait_for() { # seconds command...
  local t="$1"
  shift
  for _ in $(seq 1 $((t * 4))); do
    "$@" && return 0
    sleep 0.25
  done
  return 1
}
loaded() { [[ -n $(state) ]]; }
tabs() { state | jq -r '.tabs // 0'; }

ot settings set focusOnOpen false >/dev/null
echo "== start"
setsid -f "$W/tabby" >"$W/tabby.log" 2>&1
check "companion loads from node_modules symlink" wait_for 25 loaded
check "colours synced" wait_for 10 bash -c '[[ $(cat "$1"/rt/windows/*.json | jq -r .status.colors) == synced ]]' _ "$W"
check "config holds the Omarchy scheme" wait_for 5 grep -q "name: Omarchy" "$UD/config.yaml"
if [[ -f $HOME/.local/state/omarchy/current/theme/colors.toml ]]; then
  bg="$(node -e '
    const P = require(process.argv[1]); const fs = require("fs")
    console.log(P.schemeFromToml(fs.readFileSync(process.argv[2], "utf8")).background)' \
    "$ROOT/tabby-omarchy/lib/palette.js" "$HOME/.local/state/omarchy/current/theme/colors.toml")"
  check "background matches the current theme" grep -qi "background: '$bg'" "$UD/config.yaml"
fi
check "Ctrl-Insert copy added" grep -q "Ctrl-Insert" "$UD/config.yaml"
check "backup is private" bash -c '[[ $(stat -c %a "$1/state/tabby-backup.json") == 600 ]]' _ "$W"
eq "state dir private" 700 "$(stat -c %a "$W/rt/windows")"

echo "== requests"
before="$(tabs)"
ot open --dir /etc
check "open adds a tab" wait_for 10 bash -c '(( $(cat "$1"/rt/windows/*.json | jq -r .tabs) > $2 ))' _ "$W" "$before"
before="$(tabs)"
ot open --title e2e -- bash -c "touch '$W/ran'; sleep 5"
check "command ran without a confirmation dialog" wait_for 10 test -e "$W/ran"
check "requests consumed" bash -c '! ls "$1"/rt/requests/*.json 2>/dev/null' _ "$W"

echo "== hostile URLs"
sleep 6 # let the command tab above exit, so the count is stable
before="$(tabs)"
"$W/tabby" 'tabby://open?directory=/&omarchyRequest=0123456789abcdef0123456789abcdef'
"$W/tabby" 'tabby://open?directory=/&omarchyRequest=../../../../etc/passwd'
id="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
(umask 077 && echo "{\"v\":1,\"action\":\"run\",\"argv\":[\"touch\",\"$W/pwned\"],\"created\":1}" >"$W/rt/requests/$id.json")
"$W/tabby" "tabby://open?directory=/&omarchyRequest=$id"
id2="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
echo "{\"v\":1,\"action\":\"run\",\"argv\":[\"touch\",\"$W/pwned2\"],\"created\":$(date +%s%3N)}" >"$W/rt/requests/$id2.json"
chmod 644 "$W/rt/requests/$id2.json"
"$W/tabby" "tabby://open?directory=/&omarchyRequest=$id2"
sleep 3
check "expired request did not run" test ! -e "$W/pwned"
check "world-readable request did not run" test ! -e "$W/pwned2"
check "no tabs opened by hostile URLs" bash -c '(( $(cat "$1"/rt/windows/*.json | jq -r .tabs) <= $2 ))' _ "$W" "$before"

echo "== restore"
ot settings set syncColors false >/dev/null
ot settings set syncFont false >/dev/null
ot settings set clipboardKeys false >/dev/null
check "status off" wait_for 15 bash -c '[[ $(cat "$1"/rt/windows/*.json | jq -r "[.status.colors, .status.font, .status.clipboard] | join(\",\")") == off,off,false ]]' _ "$W"
check "scheme restored" bash -c '! grep -q "name: Omarchy" "$1/config.yaml"' _ "$UD"
check "Ctrl-Insert removed" bash -c '! grep -q "Ctrl-Insert" "$1/config.yaml"' _ "$UD"
ot settings reset >/dev/null
check "re-enabled" wait_for 15 grep -q "name: Omarchy" "$UD/config.yaml"

echo "== uninstall while running (same order as install.sh --uninstall)"
ot settings set syncColors false >/dev/null
check "restored before removal" wait_for 15 bash -c '! grep -q "name: Omarchy" "$1/config.yaml"' _ "$UD"
rm -rf "$UD/plugins/omarchy/tabby-omarchy"
rm -rf "$W/conf" # settings gone -> defaults would say syncColors=true
sleep 12         # longer than the poll interval
check "removed plugin stops instead of re-syncing" bash -c '! grep -q "name: Omarchy" "$1/config.yaml"' _ "$UD"

printf '\ne2e: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
