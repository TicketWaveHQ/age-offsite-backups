# shellcheck shell=bash
# Tests for bin/backup-push. Sourced by tests/run.sh with tests/helpers.sh.

# --- encryption ------------------------------------------------------------

test_push_encrypts_every_file_so_either_key_restores_it() {
    push "$SRC"
    assert_rc 0
    assert_out "backup-push: 1 ok, 0 failed"
    assert_out "3 encrypted and uploaded"
    local p; p="$STORE/$(src_prefix)"
    for f in one.txt db/two.sql db/two.sql.sha256; do
        assert_file "$p/$f.age"
        assert_eq "$(decrypt "$p/$f.age" "$T/keys/a.txt" | sha256_of)" "$(sha256_of "$SRC/$f")" "key A restores $f"
        assert_eq "$(decrypt "$p/$f.age" "$T/keys/b.txt" | sha256_of)" "$(sha256_of "$SRC/$f")" "key B restores $f"
    done
}

test_push_stores_no_plaintext_at_all() {
    push "$SRC"
    assert_rc 0
    if grep -rqF MARKER-plaintext "$STORE"; then fail "plaintext found in storage"; fi
    local other
    other="$(find "$STORE" -type f ! -name '*.age' ! -path '*/.age-offsite-incoming/*')"
    assert_eq "$other" "" "objects not ending in .age"
}

test_push_stores_each_checksum_encrypted_and_correct() {
    push "$SRC"
    assert_rc 0
    local p sum; p="$STORE/$(src_prefix)"
    sum="$(sha256_of "$SRC/db/two.sql")"
    assert_file "$p/db/.two.sql.sha256.age"
    if grep -qF "$sum" "$p/db/.two.sql.sha256.age"; then fail "checksum stored in the clear"; fi
    assert_eq "$(decrypt "$p/db/.two.sql.sha256.age")" "$sum  two.sql" "decrypted checksum"
}

test_push_keeps_a_real_sha256_file_apart_from_its_own_checksums() {
    # db/two.sql.sha256 is a file in its own right; its encrypted copy must
    # not collide with the checksum of db/two.sql.
    push "$SRC"
    assert_rc 0
    local p; p="$STORE/$(src_prefix)/db"
    assert_eq "$(decrypt "$p/two.sql.sha256.age")" "MARKER-plaintext-three" "the file two.sql.sha256"
    assert_file "$p/.two.sql.sha256.sha256.age"
}

# --- skip what exists ------------------------------------------------------

test_push_uploads_each_file_once_and_skips_what_is_stored() {
    push "$SRC"
    assert_rc 0
    local before; before="$(store_fingerprint)"
    push "$SRC"
    assert_rc 0
    assert_out "0 encrypted and uploaded"
    # age output is randomised, so re-encrypting would change every object.
    assert_eq "$(store_fingerprint)" "$before" "storage after a second run"

    printf 'MARKER-plaintext-four\n' > "$SRC/four.txt"
    make_old "$SRC/four.txt"
    push "$SRC"
    assert_rc 0
    assert_out "1 encrypted and uploaded"
    assert_file "$STORE/$(src_prefix)/four.txt.age"
    assert_eq "$(store_fingerprint | grep -v four.txt)" "$before" "objects already stored"
}

test_push_adds_a_missing_checksum_without_uploading_the_file_again() {
    push "$SRC"
    local p data; p="$STORE/$(src_prefix)"
    data="$(sha256_of "$p/one.txt.age")"
    rm "$p/.one.txt.sha256.age"
    push "$SRC"
    assert_rc 0
    assert_out "0 encrypted and uploaded, 1 missing checksum(s) added"
    assert_eq "$(decrypt "$p/.one.txt.sha256.age")" "$(sha256_of "$SRC/one.txt")  one.txt" "restored checksum"
    assert_eq "$(sha256_of "$p/one.txt.age")" "$data" "the encrypted file"
}

# --- what is left alone ----------------------------------------------------

test_push_leaves_recently_changed_files_for_the_next_run() {
    printf 'still being written\n' > "$SRC/growing.dump"
    push "$SRC"
    assert_rc 0
    assert_out "3 encrypted and uploaded, 1 left for the next run"
    refute_file "$STORE/$(src_prefix)/growing.dump.age"

    BACKUP_SETTLE_MINUTES=0 push "$SRC"
    assert_rc 0
    assert_file "$STORE/$(src_prefix)/growing.dump.age"
}

test_push_never_uploads_dotfiles_or_dot_directories() {
    mkdir -p "$SRC/.partial"
    printf 'x\n' > "$SRC/.one.txt.tmp"
    printf 'y\n' > "$SRC/.partial/chunk"
    make_old "$SRC/.one.txt.tmp" "$SRC/.partial/chunk"
    push "$SRC"
    assert_rc 0
    assert_out "2 hidden skipped"
    refute_file "$STORE/$(src_prefix)/.one.txt.tmp.age"
    refute_file "$STORE/$(src_prefix)/.partial"
}

test_push_handles_spaces_in_names() {
    mkdir -p "$SRC/with space"
    printf 'MARKER-plaintext-space\n' > "$SRC/with space/a file.txt"
    make_old "$SRC/with space/a file.txt"
    push "$SRC"
    assert_rc 0
    assert_eq "$(decrypt "$STORE/$(src_prefix)/with space/a file.txt.age")" "MARKER-plaintext-space" "decrypted"
    assert_file "$STORE/$(src_prefix)/with space/.a file.txt.sha256.age"
}

# --- fail closed -----------------------------------------------------------

test_push_fails_closed_without_age() {
    BACKUP_AGE="$T/no-such-dir/age" push "$SRC"
    assert_rc 1
    assert_out "refusing to upload anything unencrypted"
    assert_out "backup-push: 0 ok, 1 failed"
    refute_out "encrypted and uploaded"
    assert_eq "$(count_objects)" 0 "objects stored"
}

test_push_fails_closed_without_a_recipients_file() {
    BACKUP_RECIPIENTS_FILE="$T/missing.txt" push "$SRC"
    assert_rc 1
    assert_out "is missing or unreadable: refusing to upload anything unencrypted"
    refute_out "encrypted and uploaded"
    assert_eq "$(count_objects)" 0 "objects stored"
}

test_push_fails_closed_on_a_recipients_file_age_cannot_use() {
    printf 'not-a-key\n' > "$T/bad.txt"
    BACKUP_RECIPIENTS_FILE="$T/bad.txt" push "$SRC"
    assert_rc 1
    assert_out "age cannot use recipients file"
    refute_out "encrypted and uploaded"
    assert_eq "$(count_objects)" 0 "objects stored"

    : > "$T/empty.txt"
    BACKUP_RECIPIENTS_FILE="$T/empty.txt" push "$SRC"
    assert_rc 1
    assert_eq "$(count_objects)" 0 "objects stored"
}

test_push_refuses_a_private_key_in_the_recipients_file_and_never_prints_it() {
    cat "$T/recipients.txt" "$T/keys/a.txt" > "$T/mixed.txt"
    BACKUP_RECIPIENTS_FILE="$T/mixed.txt" push "$SRC"
    assert_rc 1
    assert_out "contains a private key"
    refute_out "encrypted and uploaded"
    refute_out "AGE-SECRET-KEY-1"
    assert_eq "$(count_objects)" 0 "objects stored"
}

test_push_requires_two_recipients_unless_told_otherwise() {
    echo "$PUB_A" > "$T/one.txt"
    BACKUP_RECIPIENTS_FILE="$T/one.txt" push "$SRC"
    assert_rc 1
    assert_out "lists 1 recipient(s); at least 2 are required"
    assert_eq "$(count_objects)" 0 "objects stored"

    printf '%s\n%s\n' "$PUB_A" "$PUB_A" > "$T/twice.txt"
    BACKUP_RECIPIENTS_FILE="$T/twice.txt" push "$SRC"
    assert_rc 1
    assert_out "lists 1 recipient(s)"

    BACKUP_RECIPIENTS_FILE="$T/one.txt" BACKUP_MIN_RECIPIENTS=1 push "$SRC"
    assert_rc 0
}

# --- plaintext detection ---------------------------------------------------

test_push_fails_when_plaintext_appears_under_its_prefix() {
    push "$SRC"
    mkdir -p "$STORE/testhost/manual"
    printf 'MARKER-plaintext-manual\n' > "$STORE/testhost/manual/dump.sql"
    push "$SRC"
    assert_rc 1
    assert_out "1 UNENCRYPTED object(s) under testhost/"
    assert_out "testhost/manual/dump.sql"
    assert_out "backup-push: 1 ok, 1 failed"
}

test_push_only_notes_plaintext_from_before_encrypted_since() {
    mkdir -p "$STORE/testhost/legacy"
    printf 'old\n' > "$STORE/testhost/legacy/old.sql"
    make_old "$STORE/testhost/legacy/old.sql"
    BACKUP_ENCRYPTED_SINCE="2021-06-01" push "$SRC"
    assert_rc 0
    assert_out "note: 1 unencrypted object(s) from before 2021-06-01 00:00:00 UTC"

    printf 'new\n' > "$STORE/testhost/legacy/new.sql"
    BACKUP_ENCRYPTED_SINCE="2021-06-01 00:00:00" push "$SRC"
    assert_rc 1
    assert_out "UNENCRYPTED object(s) under testhost/ uploaded since 2021-06-01 00:00:00 UTC"
    assert_out "testhost/legacy/new.sql"
}

test_push_ignores_plaintext_outside_its_own_prefix() {
    mkdir -p "$STORE/otherhost" "$STORE/testhost2"
    printf 'theirs\n' > "$STORE/otherhost/x.sql"
    printf 'theirs\n' > "$STORE/testhost2/y.sql"
    push "$SRC"
    assert_rc 0
}

# --- failures are counted, never hidden -----------------------------------

test_push_counts_a_missing_source_directory_as_a_failure() {
    push "$SRC" "$T/not-there"
    assert_rc 1
    assert_out "source directory not found"
    assert_out "backup-push: 1 ok, 1 failed"
}

test_push_without_sources_is_a_usage_error() {
    push
    assert_rc 2
    BACKUP_SOURCES="$SRC" push
    assert_rc 0
}

test_push_reports_an_upload_failure_and_redacts_the_error() {
    use_aws_stub
    STUB_AWS_FAIL=cp push "$SRC"
    assert_rc 1
    assert_out "upload failed for $SRC"
    assert_out "[REDACTED]"
    refute_out "STUBEXAMPLEKEYID0123456789abcdef"
    assert_out "not found in storage at full size"
    assert_out "backup-push: 0 ok, 1 failed"
}

test_push_detects_a_truncated_upload() {
    use_aws_stub
    STUB_AWS_TRUNCATE=1 push "$SRC"
    assert_rc 1
    assert_out "not found in storage at full size"
}

test_push_treats_a_listing_failure_as_a_failure_not_as_empty() {
    use_aws_stub
    STUB_AWS_FAIL=ls push "$SRC"
    assert_rc 1
    assert_out "could not list"
    if grep -q ' s3 cp ' "$STUB_S3_ROOT/calls.log"; then
        fail "an upload was attempted after a failed listing"
    fi
}

# --- backends and configuration --------------------------------------------

test_push_through_the_aws_cli_uses_the_endpoint_and_round_trips() {
    use_aws_stub
    push "$SRC"
    assert_rc 0
    grep -qF -- "--endpoint-url https://s3.example.com s3 cp" "$STUB_S3_ROOT/calls.log" ||
        fail "endpoint not passed to the AWS CLI"
    assert_eq "$(decrypt "$STORE/$(src_prefix)/one.txt.age" "$T/keys/b.txt")" "MARKER-plaintext-one" "decrypted"
    push "$SRC"
    assert_rc 0
    assert_out "0 encrypted and uploaded"
}

test_push_through_rclone_round_trips() {
    command -v rclone >/dev/null 2>&1 || { echo "rclone not installed"; return 77; }
    mkdir -p "$T/rclone-store"
    : > "$T/rclone.conf"
    export RCLONE_CONFIG="$T/rclone.conf"
    export BACKUP_BACKEND=rclone BACKUP_RCLONE_REMOTE="$T/rclone-store"
    push "$SRC"
    assert_rc 0
    STORE="$T/rclone-store"
    assert_eq "$(decrypt "$STORE/$(src_prefix)/db/two.sql.age" | sha256_of)" "$(sha256_of "$SRC/db/two.sql")" "decrypted"
    local before; before="$(store_fingerprint)"
    push "$SRC"
    assert_rc 0
    assert_eq "$(store_fingerprint)" "$before" "storage after a second run"
    printf 'plain\n' > "$STORE/testhost/stray.txt"
    push "$SRC"
    assert_rc 1
    assert_out "UNENCRYPTED"
}

test_push_reads_a_config_file_without_executing_it() {
    unset BACKUP_LOCAL_DIR BACKUP_PREFIX
    cat > "$T/backup.conf" <<EOF
# a comment
BACKUP_BACKEND=local
export BACKUP_LOCAL_DIR="$STORE"
BACKUP_PREFIX='fromfile'
BACKUP_HEARTBEAT_FILE=$T/beat\$(touch $T/pwned)
EOF
    push --config "$T/backup.conf" "$SRC"
    assert_rc 0
    assert_file "$STORE/fromfile$SRC/one.txt.age"
    refute_file "$T/pwned"

    BACKUP_PREFIX=fromenv push --config "$T/backup.conf" "$SRC"
    assert_rc 0
    assert_file "$STORE/fromenv$SRC/one.txt.age"

    printf 'BACKUP_BUCKKET=typo\n' > "$T/typo.conf"
    push --config "$T/typo.conf" "$SRC"
    assert_rc 2
    assert_out "unknown setting 'BACKUP_BUCKKET'"
}

test_push_writes_the_heartbeat_only_after_a_clean_run() {
    BACKUP_HEARTBEAT_FILE="$T/beat" BACKUP_AGE="$T/no-such-dir/age" push "$SRC"
    refute_file "$T/beat"
    BACKUP_HEARTBEAT_FILE="$T/beat" push "$SRC"
    assert_rc 0
    assert_file "$T/beat"
}

test_the_example_config_files_parse() {
    # The environment wins over the file, so the examples can be loaded
    # against the local backend without touching any real storage.
    BACKUP_HEARTBEAT_FILE="$T/beat" BACKUP_STAGING_DIR="$T/tmp" BACKUP_SOURCES="$SRC" \
        push --config "$ROOT/examples/backup.conf.example"
    assert_rc 0
    assert_out "backup-push: 1 ok, 0 failed"
    verify --config "$ROOT/examples/verify.conf.example" --identity "$T/keys/a.txt"
    assert_rc 0
}

test_push_follows_a_source_directory_that_is_a_symlink() {
    ln -s "$SRC" "$T/link"
    push "$T/link"
    assert_rc 0
    assert_out "3 encrypted and uploaded"
    assert_file "$STORE/testhost$T/link/one.txt.age"
}
