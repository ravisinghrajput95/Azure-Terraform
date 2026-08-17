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
# The Python checks
#
# ShellCheck does not read these and neither did anything else, so until now
# the two scripts that run with no credentials — the ones CI can actually
# execute — were the least checked files in this directory.
#
# The executable bit is asserted for the same reason it is asserted on the
# shell scripts, and for one more: `make conformance` and the mutation campaign
# both invoke these through python3, so a lost bit is invisible until someone
# runs the file directly.
# ---------------------------------------------------------------------------

shopt -s nullglob
py_scripts=("${SCRIPTS}"/*.py)
shopt -u nullglob

if [ ${#py_scripts[@]} -eq 0 ]; then
  echo "no Python scripts found in ${SCRIPTS} — refusing to report success over an empty set" >&2
  exit 1
fi

for script in "${py_scripts[@]}"; do
  name="$(basename "$script")"

  if python3 -m py_compile "$script" 2>/dev/null; then
    pass "${name}: compiles"
  else
    fail "${name}: compiles" "python3 -m py_compile reported a syntax error"
  fi

  if head -n 1 "$script" | grep -qE '^#!'; then
    pass "${name}: shebang"
  else
    fail "${name}: shebang" "no shebang, so the file cannot be run directly"
  fi

  if [ -x "$script" ]; then
    pass "${name}: executable"
  else
    fail "${name}: executable" "chmod +x, or it can only be run via python3"
  fi
done

find "${SCRIPTS}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

# The mutation catalogue names a run block per mutation, and a renamed run
# block would make that mutation permanently uncatchable — reported as a weak
# assertion in the suite rather than as a stale entry in the catalogue. This is
# the check that keeps the campaign honest about its own rot. It reads files
# only: no terraform, no edits, safe on a dirty tree.
if [ -x "${SCRIPTS}/mutation-test.py" ]; then
  if "${SCRIPTS}/mutation-test.py" --check-catalogue >/dev/null 2>&1; then
    pass "mutation-test.py: every mutation names a run block that exists"
  else
    fail "mutation-test.py: every mutation names a run block that exists" \
      "run ./scripts/mutation-test.py --check-catalogue for the list"
  fi
fi

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
