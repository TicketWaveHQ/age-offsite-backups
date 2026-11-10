#!/usr/bin/env bash
# Run the test suite. Offline: no cloud account, no network, nothing
# outside a temporary directory per test.
#
#   tests/run.sh              all tests
#   tests/run.sh verify       only tests whose name contains "verify"
#
# Each test_* function in tests/test_*.sh runs in its own subshell with a
# fresh temporary directory and freshly generated throwaway age keys, which
# are deleted with it. A test passes by returning 0 and is skipped by
# returning 77. Output is TAP-like.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export ROOT HERE
filter="${1:-}"

command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1 || {
    echo "the tests need age and age-keygen on PATH" >&2
    exit 2
}

echo "# bash $BASH_VERSION; $(age --version 2>/dev/null | head -1 | sed 's/^/age /')"
n=0 pass=0 fail=0 skip=0
for file in "$HERE"/test_*.sh; do
    for t in $(grep -E '^test_[A-Za-z0-9_]+\(\)' "$file" | sed 's/().*//'); do
        case "$t" in *"$filter"*) ;; *) continue ;; esac
        n=$((n + 1))
        name="$(printf '%s' "${t#test_}" | tr '_' ' ')"
        log="$(mktemp "${TMPDIR:-/tmp}/aob-test-log.XXXXXX")"
        (
            # shellcheck source=helpers.sh
            . "$HERE/helpers.sh"
            # shellcheck disable=SC1090
            . "$file"
            setup
            trap teardown EXIT
            # A failed assertion (or any other failing command) ends the test.
            set -e
            "$t"
        ) > "$log" 2>&1
        rc=$?
        if [ "$rc" -eq 0 ]; then
            pass=$((pass + 1)); echo "ok $n - $name"
        elif [ "$rc" -eq 77 ]; then
            skip=$((skip + 1)); echo "ok $n - $name # SKIP $(tail -1 "$log")"
        else
            fail=$((fail + 1)); echo "not ok $n - $name"
            sed 's/^/#   /' "$log"
        fi
        rm -f "$log"
    done
done
echo "1..$n"
echo "# $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ] && [ "$n" -gt 0 ]
