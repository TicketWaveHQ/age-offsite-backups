# shellcheck shell=bash
# Shared set-up and assertions for the tests. Sourced by tests/run.sh.
#
# setup gives every test:
#   $T              a temporary directory, removed afterwards
#   $T/keys/a.txt   throwaway age identity A   (public key in $PUB_A)
#   $T/keys/b.txt   throwaway age identity B   (public key in $PUB_B)
#   $T/recipients.txt  PUB_A and PUB_B
#   $SRC            a source directory with three finished files
#   $STORE          the storage root for the local backend
# and the environment for backup-push and backup-verify with the local
# backend. The private keys are generated here, never printed, and deleted
# with $T.

setup() {
    T="$(mktemp -d "${TMPDIR:-/tmp}/aob-test.XXXXXX")"
    T="$(cd "$T" && pwd -P)"
    mkdir -p "$T/keys" "$T/src/db" "$T/store" "$T/tmp"
    age-keygen -o "$T/keys/a.txt" 2>/dev/null
    age-keygen -o "$T/keys/b.txt" 2>/dev/null
    PUB_A="$(age-keygen -y "$T/keys/a.txt")"
    PUB_B="$(age-keygen -y "$T/keys/b.txt")"
    {
        echo "# restore key 1"
        echo "$PUB_A"
        echo "# restore key 2"
        echo "$PUB_B"
    } > "$T/recipients.txt"

    SRC="$T/src"
    STORE="$T/store"
    printf 'MARKER-plaintext-one\n' > "$SRC/one.txt"
    printf 'MARKER-plaintext-two\n%.0s' $(seq 1 2000) > "$SRC/db/two.sql"
    printf 'MARKER-plaintext-three\n' > "$SRC/db/two.sql.sha256"
    make_old "$SRC/one.txt" "$SRC/db/two.sql" "$SRC/db/two.sql.sha256"

    : > "$T/empty.conf"
    unset BACKUP_BUCKET BACKUP_S3_ENDPOINT BACKUP_RCLONE_REMOTE BACKUP_SOURCES \
        BACKUP_ENCRYPTED_SINCE BACKUP_HEARTBEAT_FILE BACKUP_IDENTITY_FILE \
        BACKUP_VERIFY_JOBS BACKUP_AGE BACKUP_MIN_RECIPIENTS \
        STUB_AWS_FAIL STUB_AWS_TRUNCATE 2>/dev/null || true
    export BACKUP_CONFIG="$T/empty.conf"
    export BACKUP_BACKEND=local
    export BACKUP_LOCAL_DIR="$STORE"
    export BACKUP_PREFIX=testhost
    export BACKUP_RECIPIENTS_FILE="$T/recipients.txt"
    export BACKUP_SETTLE_MINUTES=15
    export BACKUP_STAGING_DIR="$T/tmp"
    export TMPDIR="$T/tmp"
}

teardown() {
    [ -n "${T:-}" ] && rm -rf "$T"
}

# Give files a modification time well in the past, so they count as finished.
make_old() { touch -t 202001010000 "$@"; }

# The key prefix backup-push uses for $SRC.
src_prefix() { printf 'testhost%s' "$SRC"; }

# Run backup-push or backup-verify; output in $T/out, exit status in $RC.
push() {
    RC=0
    "$ROOT/bin/backup-push" "$@" > "$T/out" 2>&1 || RC=$?
}
verify() {
    RC=0
    "$ROOT/bin/backup-verify" "$@" > "$T/out" 2>&1 || RC=$?
}

# Use the AWS CLI stub instead of the local backend.
use_aws_stub() {
    export PATH="$ROOT/tests/stub:$PATH"
    export BACKUP_BACKEND=aws
    export BACKUP_BUCKET=my-backups-bucket
    export BACKUP_S3_ENDPOINT=https://s3.example.com
    export STUB_S3_ROOT="$T/s3"
    mkdir -p "$STUB_S3_ROOT/my-backups-bucket"
    : > "$STUB_S3_ROOT/calls.log"
    STORE="$STUB_S3_ROOT/my-backups-bucket"
}

# Decrypt a stored object with identity A (default) or another key file.
decrypt() { # FILE [IDENTITY_FILE]
    age -d -i "${2:-$T/keys/a.txt}" "$1"
}

# SHA-256 of FILE, or of standard input with no argument.
sha256_of() {
    if [ $# -gt 0 ]; then sha256_raw < "$1"; else sha256_raw; fi | awk '{ print $1 }'
}
sha256_raw() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

# A fingerprint of every stored object, to prove a run changed nothing.
store_fingerprint() {
    (cd "$STORE" && find . -type f ! -path './.age-offsite-incoming/*' -print | LC_ALL=C sort |
        while IFS= read -r f; do printf '%s %s\n' "$(sha256_of "$f")" "$f"; done)
}

count_objects() { find "$STORE" -type f ! -path '*/.age-offsite-incoming/*' | wc -l | tr -d ' '; }

# ---------------------------------------------------------------------------
# Assertions. Each prints what it expected and returns 1 on failure.

fail() { echo "FAIL: $*"; echo "--- output:"; cat "$T/out" 2>/dev/null; return 1; }

assert_rc() { # EXPECTED
    [ "$RC" -eq "$1" ] || fail "exit status $RC, expected $1"
}
assert_out() { # TEXT
    grep -qF -- "$1" "$T/out" || fail "output does not contain: $1"
}
refute_out() { # TEXT
    ! grep -qF -- "$1" "$T/out" || fail "output contains: $1"
}
assert_file() { [ -f "$1" ] || fail "missing file: $1"; }
refute_file() { [ ! -e "$1" ] || fail "file should not exist: $1"; }
assert_eq() { # ACTUAL EXPECTED [WHAT]
    [ "$1" = "$2" ] || fail "${3:-value}: got '$1', expected '$2'"
}
