#!/usr/bin/env bash
# Stop hook: if the working tree has uncommitted changes, ask Claude (once) to
# commit the finished feature before ending the turn. Never loops: when the
# stop was already blocked by this hook, it lets Claude stop.
set -u
input=$(cat)
if [[ "$(jq -r '.stop_hook_active // false' <<<"$input")" == "true" ]]; then
  exit 0
fi
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
changes=$(git status --porcelain 2>/dev/null)
[[ -z "$changes" ]] && exit 0
summary=$(head -n 15 <<<"$changes")
jq -n --arg files "$summary" '{
  decision: "block",
  reason: ("The working tree has uncommitted changes:\n" + $files + "\n\nProject rule (CLAUDE.md): every finished feature or fix is committed. If this work is complete and verified, run the checks and commit it now (one focused commit, imperative subject). If it is still in progress, or the user asked not to commit, say so in one line and stop.")
}'
