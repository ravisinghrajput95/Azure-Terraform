#!/usr/bin/env bash
#
# Invariant tests for the scripts in scripts/.
#
# These scripts answer the questions `terraform plan` cannot, which means a
# defect in one of them is a defect in the verification itself. The failure
# that matters is not a crash — a crash is visible. It is a script that exits 0
# without having checked anything, because that reports success it did not
# earn, and reporting unearned success is the one thing this repository treats
# as worse than having no check at all.
#
# So these are not unit tests of the Azure logic; that needs a subscription and
# is what the scripts themselves are for. They assert the properties that keep
# a silent no-op from passing for a pass:
#
#   - the script parses at all
#   - `set -euo pipefail`, so a failed command stops the script rather than
#     letting the next one run against empty output and report nothing wrong
#   - a shebang and the executable bit, which is what decides whether the
#     pre-commit hook lints the file or silently skips it (CONTRIBUTING.md)
#   - the one behaviour reachable with no credentials: preflight.sh rejects a
#     missing region with a usage message rather than proceeding
#
# No Azure, no credentials, no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

passed=0
failed=0

pass() {
  printf '  ok    %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf '  FAIL  %s\n' "$1" >&2
  printf '        %s\n' "$2" >&2
  failed=$((failed + 1))
}

# ---------------------------------------------------------------------------
# Every script, every invariant
# ---------------------------------------------------------------------------

shopt -s nullglob
scripts=("${SCRIPTS}"/*.sh)
shopt -u nullglob

if [ ${#scripts[@]} -eq 0 ]; then
  echo "no scripts found in ${SCRIPTS} — refusing to report success over an empty set" >&2
  exit 1
fi

for script in "${scripts[@]}"; do
  name="$(basename "$script")"

  if bash -n "$script" 2>/dev/null; then
    pass "${name}: parses"
  else
    fail "${name}: parses" "bash -n reported a syntax error"
  fi

  if grep -qE '^set -euo pipefail$' "$script"; then
    pass "${name}: set -euo pipefail"
  else
    fail "${name}: set -euo pipefail" \
      "without it a failed command is ignored and the script continues, reporting nothing wrong"
  fi

  if head -n 1 "$script" | grep -qE '^#!'; then
    pass "${name}: shebang"
  else
    fail "${name}: shebang" "pre-commit's shell file type needs a shebang or a .sh suffix"
  fi

  if [ -x "$script" ]; then
    pass "${name}: executable"
  else
    fail "${name}: executable" \
      "a shebang alone does not satisfy pre-commit; the hook would skip this file while CI lints it"
  fi
done

# ---------------------------------------------------------------------------
# The one behaviour testable with no subscription
#
# preflight.sh takes a region and refuses without one. Everything past that
# point calls Azure, so this is the boundary between what can be tested here
# and what cannot.
# ---------------------------------------------------------------------------

if [ -x "${SCRIPTS}/preflight.sh" ]; then
  set +e
  output="$("${SCRIPTS}/preflight.sh" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 2 ]; then
    pass "preflight.sh: exits 2 with no region"
  else
    fail "preflight.sh: exits 2 with no region" "exited ${status}"
  fi

  if printf '%s' "$output" | grep -q "usage:"; then
    pass "preflight.sh: prints usage with no region"
  else
    fail "preflight.sh: prints usage with no region" "no usage line in output"
  fi
fi

# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
