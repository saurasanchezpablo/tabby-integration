#!/bin/bash
# Run every check. Usage: bash tests/run.sh [--e2e]
#   --e2e  also drive a real, isolated Tabby (opens a window for ~30 s)
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

failed=0
section() { printf '\n\e[1m== %s\e[0m\n' "$*"; }
run() { # name command...
  local name="$1"
  shift
  if "$@"; then
    printf '\e[32mok\e[0m   %s\n' "$name"
  else
    printf '\e[31mFAIL\e[0m %s\n' "$name"
    failed=1
  fi
}

for tool in bash jq node; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing required tool: $tool"
    exit 1
  }
done

section "syntax"
run "bash -n" bash -c 'for f in bin/omarchy-tabby lib/*.sh install.sh dev/*.sh tests/*.sh; do bash -n "$f" || exit 1; done'
run "node --check" bash -c 'for f in tabby-omarchy/index.js tabby-omarchy/lib/*.js Model.js; do node --check "$f" || exit 1; done'
run "JSON files" bash -c 'for f in manifest.json tabby-omarchy/package.json tabby-omarchy/lib/*.json; do jq empty "$f" || exit 1; done'
run "no raw private-use glyphs in sources" bash -c '! grep -rnP "[\x{E000}-\x{F8FF}]" bin lib tabby-omarchy Model.js Panel.qml install.sh'
if command -v shellcheck >/dev/null 2>&1; then
  run "shellcheck" shellcheck -x -S warning bin/omarchy-tabby lib/*.sh install.sh tests/*.sh dev/*.sh
fi

section "manifest"
run "manifest shape" jq -e '.schemaVersion == 1 and .id == "io.github.saurasanchezpablo.tabby" and .entryPoints.barWidget == "Panel.qml"' manifest.json >/dev/null
run "versions agree" bash -c '[[ $(jq -r .version manifest.json) == $(jq -r .version tabby-omarchy/package.json) ]]'
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  run "omarchy plugin validate" omarchy-plugin-validate .
fi

section "qml"
QMLLINT=/usr/lib/qt6/bin/qmllint
if [[ -x $QMLLINT && -d /usr/share/omarchy/shell ]]; then
  qs="$(mktemp -d)"
  ln -s /usr/share/omarchy/shell "$qs/qs"
  # Dynamic host objects make missing-property/unqualified noise; anything else fails.
  run "qmllint" bash -c '! "$1" -I /usr/lib/qt6/qml -I "$2" Panel.qml 2>&1 | grep -E "^(Warning|Error)" | grep -vE "missing-property|unqualified"' _ "$QMLLINT" "$qs"
  rm -rf "$qs"
fi

section "unit"
run "node tests" node --test tests/

section "sandbox"
run "cli" bash tests/cli.test.sh
run "integrate" bash tests/integrate.test.sh
run "install" bash tests/install.test.sh

if [[ ${1:-} == --e2e ]]; then
  section "e2e (isolated Tabby)"
  run "e2e" bash tests/e2e.test.sh
fi

echo
if ((failed)); then
  echo "Some checks failed."
  exit 1
fi
echo "All checks passed."
