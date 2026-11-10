# shellcheck shell=bash
# Tests for bin/backup-verify. Sourced by tests/run.sh with tests/helpers.sh.

# Push the sample files first; every verify test starts from there.
pushed() {
    push "$SRC"
    [ "$RC" -eq 0 ] || fail "set-up push failed"
}

test_verify_passes_with_either_private_key() {
    pushed
    verify --identity "$T/keys/a.txt"
    assert_rc 0
    assert_out "OK testhost$SRC/one.txt.age"
    assert_out "OK testhost$SRC/db/two.sql.age"
    assert_out "OK testhost$SRC/db/two.sql.sha256.age"
    assert_out "backup-verify: 3 ok, 0 failed"
    verify --identity "$T/keys/b.txt"
    assert_rc 0
    assert_out "backup-verify: 3 ok, 0 failed"
}

test_verify_reads_the_identity_from_stdin_and_never_prints_it() {
    pushed
    RC=0
    "$ROOT/bin/backup-verify" --identity-stdin < "$T/keys/b.txt" > "$T/out" 2>&1 || RC=$?
    assert_rc 0
    assert_out "backup-verify: 3 ok, 0 failed"
    refute_out "AGE-SECRET-KEY"
}

test_verify_takes_the_identity_file_from_the_config() {
    pushed
    printf 'BACKUP_IDENTITY_FILE=%s\n' "$T/keys/a.txt" > "$T/verify.conf"
    verify --config "$T/verify.conf"
    assert_rc 0
}

test_verify_limits_itself_to_the_prefixes_given() {
    pushed
    mkdir -p "$STORE/elsewhere"
    printf 'not encrypted at all\n' > "$STORE/elsewhere/broken.age"
    verify --identity "$T/keys/a.txt" "testhost$SRC/db"
    assert_rc 0
    assert_out "backup-verify: 2 ok, 0 failed"
    verify --identity "$T/keys/a.txt"
    assert_rc 1
    assert_out "ERROR elsewhere/broken.age (could not decrypt)"
}

test_verify_detects_a_damaged_object() {
    pushed
    local f; f="$STORE/$(src_prefix)/db/two.sql.age"
    printf 'X' | dd of="$f" bs=1 seek=4000 conv=notrunc 2>/dev/null
    verify --identity "$T/keys/a.txt"
    assert_rc 1
    assert_out "ERROR testhost$SRC/db/two.sql.age (could not decrypt)"
    assert_out "backup-verify: 2 ok, 1 failed"
}

test_verify_detects_an_object_replaced_with_other_content() {
    pushed
    printf 'something else\n' | age -R "$T/recipients.txt" -o "$STORE/$(src_prefix)/one.txt.age"
    verify --identity "$T/keys/a.txt"
    assert_rc 1
    assert_out "MISMATCH testhost$SRC/one.txt.age"
}

test_verify_fails_an_object_with_no_checksum() {
    pushed
    rm "$STORE/$(src_prefix)/.one.txt.sha256.age"
    verify --identity "$T/keys/a.txt"
    assert_rc 1
    assert_out "NOSUM testhost$SRC/one.txt.age"
}

test_verify_fails_when_the_encrypted_file_is_missing() {
    pushed
    rm "$STORE/$(src_prefix)/one.txt.age"
    verify --identity "$T/keys/a.txt"
    assert_rc 1
    assert_out "MISSING testhost$SRC/one.txt.age"
}

test_verify_compares_with_a_plaintext_original_where_one_is_stored() {
    # An archive from before encryption: plaintext objects with .age copies
    # made later, and no checksum objects.
    mkdir -p "$STORE/legacy"
    printf 'MARKER-plaintext-legacy\n' > "$STORE/legacy/dump.sql"
    age -R "$T/recipients.txt" -o "$STORE/legacy/dump.sql.age" "$STORE/legacy/dump.sql"
    printf 'MARKER-plaintext-other\n' > "$STORE/legacy/other.sql"
    printf 'different\n' | age -R "$T/recipients.txt" -o "$STORE/legacy/other.sql.age"
    verify --identity "$T/keys/b.txt" legacy
    assert_rc 1
    assert_out "OK legacy/dump.sql.age (compared with its plaintext original)"
    assert_out "MISMATCH legacy/other.sql.age (differs from its plaintext original)"
    assert_out "plaintext: 2, of which 0 have no encrypted copy"
}

test_verify_fails_with_a_key_that_is_not_a_recipient() {
    pushed
    age-keygen -o "$T/keys/c.txt" 2>/dev/null
    verify --identity "$T/keys/c.txt"
    assert_rc 1
    assert_out "backup-verify: 0 ok, 3 failed"
}

test_verify_fails_when_there_is_nothing_to_verify() {
    verify --identity "$T/keys/a.txt"
    assert_rc 1
    assert_out "nothing to verify"
}

test_verify_needs_a_valid_identity() {
    pushed
    verify
    assert_rc 2
    assert_out "an identity is needed"
    printf 'hello\n' > "$T/notakey.txt"
    verify --identity "$T/notakey.txt"
    assert_rc 2
    RC=0
    "$ROOT/bin/backup-verify" --identity-stdin < "$T/notakey.txt" > "$T/out" 2>&1 || RC=$?
    assert_rc 2
    assert_out "no age identity on standard input"
}

test_verify_through_the_aws_cli_in_parallel_reports_in_key_order() {
    use_aws_stub
    local i
    for i in 01 02 03 04 05 06 07; do
        printf 'file %s\n' "$i" > "$SRC/n$i.txt"
    done
    make_old "$SRC"/n*.txt
    pushed
    verify --identity "$T/keys/a.txt" --jobs 3
    assert_rc 0
    assert_out "backup-verify: 10 ok, 0 failed"
    grep '^OK ' "$T/out" > "$T/ok"
    assert_eq "$(LC_ALL=C sort "$T/ok")" "$(cat "$T/ok")" "report order"
}

test_verify_never_changes_storage() {
    use_aws_stub
    pushed
    local before; before="$(store_fingerprint)"
    : > "$STUB_S3_ROOT/calls.log"
    verify --identity "$T/keys/a.txt"
    assert_rc 0
    assert_eq "$(store_fingerprint)" "$before" "storage after verify"
    # Only listings and downloads to standard output.
    if grep -v -E ' s3 ls s3://my-backups-bucket/ --recursive$| s3 cp s3://[^ ]+ - --no-progress --only-show-errors$' \
        "$STUB_S3_ROOT/calls.log" | grep -q .; then
        fail "verify made a call other than list or download"
    fi
}

test_verify_reports_a_listing_failure() {
    use_aws_stub
    pushed
    STUB_AWS_FAIL=ls verify --identity "$T/keys/a.txt"
    assert_rc 1
    assert_out "could not list the storage"
}
