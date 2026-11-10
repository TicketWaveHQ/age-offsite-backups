# shellcheck shell=bash
# lib/common.sh: shared by backup-push and backup-verify. Sourced, not run.
#
# Written for bash 4 and later, and kept to the subset that the bash 3.2
# shipped with macOS also runs: no associative arrays, no mapfile, no
# ${var,,}. Works with GNU and BSD userlands alike.

AOB_VERSION="1.0.0"
AOB_DEFAULT_CONFIG="/etc/age-offsite-backups/backup.conf"

# Listing timestamps are compared as text, so pin them to UTC. Sorting and
# comparing keys must be byte-wise for comm and awk to agree.
export TZ=UTC LC_ALL=C

AOB_TAB="$(printf '\t')"

aob_err()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; }
aob_warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }

aob_usage_error() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    printf "Try '%s --help'.\n" "$PROG" >&2
    exit 2
}

# ---------------------------------------------------------------------------
# Configuration
#
# Settings come from the environment and from a KEY=VALUE file. The file is
# parsed, never sourced: nothing in it is executed or expanded. A setting
# already present in the environment wins over the file.

AOB_SETTINGS="BACKUP_BACKEND BACKUP_BUCKET BACKUP_S3_ENDPOINT BACKUP_RCLONE_REMOTE
BACKUP_LOCAL_DIR BACKUP_PREFIX BACKUP_SOURCES BACKUP_RECIPIENTS_FILE
BACKUP_MIN_RECIPIENTS BACKUP_ENCRYPTED_SINCE BACKUP_SETTLE_MINUTES
BACKUP_STAGING_DIR BACKUP_HEARTBEAT_FILE BACKUP_IDENTITY_FILE
BACKUP_VERIFY_JOBS BACKUP_AGE"

# Passed through to the AWS CLI or rclone, which read them themselves. The
# toolkit never reads a credential: those stay in the storage client's own
# configuration or environment.
AOB_PASSTHROUGH="AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_CONFIG_FILE
AWS_SHARED_CREDENTIALS_FILE RCLONE_CONFIG"

aob_is_word_in() { # WORD LIST
    case " $(printf '%s' "$2" | tr '\n' ' ') " in *" $1 "*) return 0 ;; esac
    return 1
}

aob_load_config() { # FILE
    local file="$1" line key val n=0
    if [ -d "$file" ] || [ ! -r "$file" ]; then
        aob_err "cannot read config file: $file"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in '' | '#'*) continue ;; esac
        case "$line" in
            'export '*) line="${line#export }"; line="${line#"${line%%[![:space:]]*}"}" ;;
        esac
        case "$line" in
            *=*) ;;
            *) aob_err "$file line $n: expected KEY=VALUE"; return 1 ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        if ! aob_is_word_in "$key" "$AOB_SETTINGS $AOB_PASSTHROUGH"; then
            aob_err "$file line $n: unknown setting '$key'"
            return 1
        fi
        case "$val" in
            \"*\") val="${val#\"}"; val="${val%\"}" ;;
            \'*\') val="${val#\'}"; val="${val%\'}" ;;
        esac
        if [ -z "${!key+set}" ]; then
            printf -v "$key" '%s' "$val"
        fi
        if aob_is_word_in "$key" "$AOB_PASSTHROUGH"; then
            export "${key?}"
        fi
    done < "$file"
}

# Load --config FILE, else $BACKUP_CONFIG, else the default file if it
# exists. Exits 2 on a configuration error.
aob_init_config() { # [FILE]
    local file="${1:-}"
    [ -n "$file" ] || file="${BACKUP_CONFIG:-}"
    if [ -n "$file" ]; then
        aob_load_config "$file" || exit 2
    elif [ -e "$AOB_DEFAULT_CONFIG" ]; then
        aob_load_config "$AOB_DEFAULT_CONFIG" || exit 2
    fi
    : "${BACKUP_BACKEND:=aws}"
    : "${BACKUP_AGE:=age}"
}

aob_is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; return 0; }

# A key prefix: no leading or trailing slash, no empty, "." or ".." part.
aob_valid_prefix() {
    case "$1" in '' | /* | */ | *//*) return 1 ;; esac
    case "/$1/" in */./* | */../*) return 1 ;; esac
    return 0
}

# ---------------------------------------------------------------------------
# Hashing: sha256sum (GNU), shasum (BSD, macOS) or openssl, whichever exists.

aob_find_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        AOB_SHA256="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        AOB_SHA256="shasum -a 256"
    elif command -v openssl >/dev/null 2>&1; then
        AOB_SHA256="openssl dgst -sha256 -r"
    else
        aob_err "no SHA-256 tool found (sha256sum, shasum or openssl)"
        return 1
    fi
}

# SHA-256 of standard input, as 64 lowercase hex digits.
aob_sha256() {
    # shellcheck disable=SC2086 # AOB_SHA256 is a command with arguments
    $AOB_SHA256 | awk '{ print tolower($1) }'
}

aob_is_sha256() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in *[!0-9a-f]*) return 1 ;; esac
    return 0
}

# ---------------------------------------------------------------------------
# Object layout
#
#   <prefix>/<path>/<name>.age            the file, encrypted
#   <prefix>/<path>/.<name>.sha256.age    its SHA-256, encrypted
#
# backup-push never uploads a dotfile or anything under a dot-directory, so
# a key whose last part starts with "." can only be a checksum. That keeps
# the two apart even when a backup directory holds a real "<name>.sha256".

aob_sum_rel() { # REL -> REL of its checksum object, without ".age"
    case "$1" in
        */*) printf '%s/.%s.sha256' "${1%/*}" "${1##*/}" ;;
        *) printf '.%s.sha256' "$1" ;;
    esac
}

# Print the first lines of a captured error, with anything that looks like
# a key or token masked. The storage client's messages can echo
# credentials or signed URLs; logs are not the place for them.
aob_show_err() { # FILE
    [ -s "$1" ] || return 0
    sed -E 's/[A-Za-z0-9/+=]{20,}/[REDACTED]/g' "$1" | head -3 | sed 's/^/    /' >&2
}
