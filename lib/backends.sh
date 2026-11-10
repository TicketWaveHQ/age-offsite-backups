# shellcheck shell=bash
# lib/backends.sh: the storage backends. Sourced after lib/common.sh.
#
# Each backend provides four operations:
#
#   check              settings and tools present
#   list PREFIX        one line per object under PREFIX/ (PREFIX "" = all):
#                      "YYYY-MM-DD HH:MM:SS<TAB>SIZE<TAB>KEY", time in UTC.
#                      Returns non-zero if the listing could not be made:
#                      "could not list" must never be read as "nothing there".
#   upload DIR PREFIX  copy every file under DIR to PREFIX/<path>
#   cat KEY            write one object to standard output
#
# Errors from list and upload go to $AOB_WORK/backend.err.
#
#   aws     the AWS CLI, against AWS S3 or any S3-compatible endpoint (primary)
#   rclone  any rclone remote
#   local   a directory: a mounted disk, or the offline tests

aob_backend_check() {
    case "$BACKUP_BACKEND" in
        aws)
            command -v aws >/dev/null 2>&1 || { aob_err "the AWS CLI (aws) is not installed"; return 1; }
            [ -n "${BACKUP_BUCKET:-}" ] || { aob_err "BACKUP_BUCKET is not set"; return 1; }
            case "$BACKUP_BUCKET" in
                s3://* | */*)
                    aob_err "BACKUP_BUCKET is a bucket name only, without s3:// or a path (paths go in BACKUP_PREFIX)"
                    return 1 ;;
            esac ;;
        rclone)
            command -v rclone >/dev/null 2>&1 || { aob_err "rclone is not installed"; return 1; }
            [ -n "${BACKUP_RCLONE_REMOTE:-}" ] || { aob_err "BACKUP_RCLONE_REMOTE is not set"; return 1; } ;;
        local)
            [ -n "${BACKUP_LOCAL_DIR:-}" ] || { aob_err "BACKUP_LOCAL_DIR is not set"; return 1; }
            [ -d "$BACKUP_LOCAL_DIR" ] || { aob_err "BACKUP_LOCAL_DIR does not exist: $BACKUP_LOCAL_DIR"; return 1; } ;;
        *)
            aob_err "unknown BACKUP_BACKEND '$BACKUP_BACKEND' (use aws, rclone or local)"
            return 1 ;;
    esac
}

aob_list()   { "aob_${BACKUP_BACKEND}_list" "$@"; }
aob_upload() { "aob_${BACKUP_BACKEND}_upload" "$@"; }
aob_cat()    { "aob_${BACKUP_BACKEND}_cat" "$@"; }

# ---------------------------------------------------------------------------
# aws

aob_aws() {
    if [ -n "${BACKUP_S3_ENDPOINT:-}" ]; then
        aws --endpoint-url "$BACKUP_S3_ENDPOINT" "$@"
    else
        aws "$@"
    fi
}

aob_aws_list() { # PREFIX
    local url="s3://$BACKUP_BUCKET/" out rc
    [ -z "$1" ] || url="s3://$BACKUP_BUCKET/$1/"
    out=$(aob_aws s3 ls "$url" --recursive 2>"$AOB_WORK/backend.err")
    rc=$?
    # An empty prefix makes "aws s3 ls" exit 1 with nothing on stderr.
    # Anything on stderr with a non-zero exit is a real failure.
    if [ "$rc" -ne 0 ] && [ -s "$AOB_WORK/backend.err" ]; then
        return 1
    fi
    [ -n "$out" ] || return 0
    printf '%s\n' "$out" | awk -v OFS='\t' 'NF >= 4 {
        k = $0; sub(/^[^ ]+ +[^ ]+ +[0-9]+ /, "", k)
        print $1 " " $2, $3, k
    }'
}

aob_aws_upload() { # DIR PREFIX
    aob_aws s3 cp "$1" "s3://$BACKUP_BUCKET/$2" --recursive \
        --no-progress --only-show-errors 2>"$AOB_WORK/backend.err"
}

aob_aws_cat() { # KEY
    aob_aws s3 cp "s3://$BACKUP_BUCKET/$1" - --no-progress --only-show-errors
}

# ---------------------------------------------------------------------------
# rclone
#
# --use-server-modtime makes the listing show when an object was uploaded,
# not the source file's modification time that rclone stores with it; the
# plaintext check compares upload times.

aob_rclone_path() { # [PREFIX]
    if [ -n "${1:-}" ]; then
        printf '%s/%s' "${BACKUP_RCLONE_REMOTE%/}" "$1"
    else
        printf '%s' "$BACKUP_RCLONE_REMOTE"
    fi
}

aob_rclone_list() { # PREFIX
    local out rc
    out=$(rclone lsf -R --files-only --use-server-modtime --format tsp \
        --separator "$AOB_TAB" "$(aob_rclone_path "$1")" 2>"$AOB_WORK/backend.err")
    rc=$?
    # Exit status 3 is rclone's "directory not found": nothing stored yet.
    [ "$rc" -eq 3 ] && return 0
    [ "$rc" -eq 0 ] || return 1
    [ -n "$out" ] || return 0
    printf '%s\n' "$out" | AOB_P="$1" awk -F'\t' -v OFS='\t' '{
        k = $3; for (i = 4; i <= NF; i++) k = k "\t" $i
        if (ENVIRON["AOB_P"] != "") k = ENVIRON["AOB_P"] "/" k
        print $1, $2, k
    }'
}

aob_rclone_upload() { # DIR PREFIX
    # --immutable: never replace an object that is already there.
    rclone copy --immutable -q "$1" "$(aob_rclone_path "$2")" 2>"$AOB_WORK/backend.err"
}

aob_rclone_cat() { # KEY
    rclone cat "$(aob_rclone_path "$1")"
}

# ---------------------------------------------------------------------------
# local
#
# Files are copied into a holding directory on the same file system and
# renamed into place, so an interrupted copy never leaves a short object
# under its final name. The holding directory sits outside every prefix.

AOB_LOCAL_INCOMING=".age-offsite-incoming"

aob_local_list() { # PREFIX
    local base="$BACKUP_LOCAL_DIR" f
    [ -z "$1" ] || base="$BACKUP_LOCAL_DIR/$1"
    [ -e "$base" ] || return 0
    (
        set -o pipefail
        find "$base" -type f ! -path "$BACKUP_LOCAL_DIR/$AOB_LOCAL_INCOMING/*" -print0 |
            while IFS= read -r -d '' f; do
                printf '%s\t%s\t%s\n' "$(date -u -r "$f" '+%Y-%m-%d %H:%M:%S')" \
                    "$(wc -c < "$f" | tr -d ' ')" "${f#"$BACKUP_LOCAL_DIR"/}" || exit 1
            done
    ) 2>"$AOB_WORK/backend.err"
}

aob_local_upload() { # DIR PREFIX
    (
        set -o pipefail
        inc="$BACKUP_LOCAL_DIR/$AOB_LOCAL_INCOMING"
        mkdir -p "$inc" || exit 1
        cd "$1" || exit 1
        find . -type f -print0 | while IFS= read -r -d '' f; do
            rel="${f#./}"
            dest="$BACKUP_LOCAL_DIR/$2/$rel"
            if [ -e "$dest" ]; then
                echo "refusing to replace $2/$rel" >&2
                exit 1
            fi
            mkdir -p "$(dirname "$dest")" || exit 1
            tmp=$(mktemp "$inc/part.XXXXXX") || exit 1
            if ! { cp "$rel" "$tmp" && mv "$tmp" "$dest"; }; then
                rm -f "$tmp"
                exit 1
            fi
        done
    ) 2>"$AOB_WORK/backend.err"
}

aob_local_cat() { # KEY
    cat "$BACKUP_LOCAL_DIR/$1"
}
