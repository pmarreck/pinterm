# Shared Bash test helpers: pass/fail accounting and stdout/stderr/status capture.
# Source this file; do not execute it. Never use errexit in tests.
PASSES=0
FAILURES=0
SUITE="${SUITE:-tests}"

pass() { PASSES=$((PASSES + 1)); }
fail() {
	FAILURES=$((FAILURES + 1))
	printf '  \033[31mFAIL\033[0m %s: %s\n' "$SUITE" "$1" >&2
}
check() { # check "description" condition-command...
	local name="$1"; shift
	if "$@"; then pass; else fail "$name"; fi
}

# capture CMD... -> sets $out, $err, $rc (stderr via a RAM-backed temp file).
capture() {
	local errfile
	errfile="$(mktemp "${TMPDIR:-/tmp}/pinterm-err.XXXXXX")"
	out="$("$@" 2>"$errfile")"
	rc=$?
	err="$(cat "$errfile")"
	command rm -f -- "$errfile"
}

finish() {
	printf '%s: %d passed, %d failed\n' "$SUITE" "$PASSES" "$FAILURES"
	[ "$FAILURES" -eq 0 ]
}
