#!/usr/bin/env bash
# Syntax and lint gate for the three scripts in this bundle.
#
# Worth having because update.sh rewrites lib.sh and the Containerfiles in
# place, and root sources lib.sh on the very next invocation, so a bad rewrite
# is otherwise not caught until it is already running with privilege.
#
# Nothing on a deployed host needs this; only whoever edits the bundle does.
set -Eeuo pipefail
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

scripts=(lib.sh setup.sh update.sh check.sh)

for f in "${scripts[@]}"; do
  bash -n "$f"
done
echo "bash -n: ok (${scripts[*]})"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${scripts[@]}"
  echo 'shellcheck: ok'
elif [[ ${ALLOW_NO_SHELLCHECK:-} == 1 ]]; then
  echo 'shellcheck not installed; syntax checked only (ALLOW_NO_SHELLCHECK=1).' >&2
else
  # Exiting non-zero rather than passing quietly: `bash -n` finds parse errors
  # and nothing else, while the constructs this bundle gets wrong are the ones
  # the linter catches.  Set ALLOW_NO_SHELLCHECK=1 for a syntax-only run.
  # (Do not open a comment with the linter's own name -- it reads that as a
  # directive and fails to parse it.)
  echo 'shellcheck is not installed, so this is not a lint gate.' >&2
  echo 'Install it, or set ALLOW_NO_SHELLCHECK=1 to check syntax only.' >&2
  exit 1
fi
