#!/usr/bin/env bash
# migrate_pg_db.sh
# Dumps a PostgreSQL database from the old server and restores it on the new server.
#
# Configuration via environment variables or command-line arguments:
#
#   OLD_DB_HOST        Hostname / IP of the source PostgreSQL server  (default: localhost)
#   OLD_DB_PORT        Port of the source server                       (default: 5432)
#   OLD_DB_NAME        Database name on the source server              (required)
#   OLD_DB_USER        Username for the source server                  (required)
#   OLD_DB_PASSWORD    Password for the source server                  (optional, use .pgpass otherwise)
#   OLD_DB_PGPASSFILE  Path to .pgpass for source server               (optional)
#
#   NEW_DB_HOST        Hostname / IP of the target PostgreSQL server  (default: localhost)
#   NEW_DB_PORT        Port of the target server                       (default: 5432)
#   NEW_DB_NAME        Database name on the target server              (defaults to OLD_DB_NAME)
#   NEW_DB_USER        Username for the target server                  (required)
#   NEW_DB_PASSWORD    Password for the target server                  (optional, use .pgpass otherwise)
#   NEW_DB_PGPASSFILE  Path to .pgpass for target server               (optional)
#
#   DUMP_DIR           Local directory to store the dump file          (default: ./dumps)
#   DUMP_FILE          Explicit dump file path (overrides DUMP_DIR)    (optional)
#
# Command-line arguments override environment variables:
#   -H  old host      -P  old port    -d  old db name   -U  old user   -p  old password
#   --old-pgpassfile  old .pgpass file path
#   -h  new host      -q  new port    -D  new db name   -u  new user   -w  new password
#   --new-pgpassfile  new .pgpass file path
#   -o  dump dir      -f  dump file
#   --dump-only       Only dump, do not restore
#   --restore-only    Only restore from an existing dump file (requires -f / DUMP_FILE)
#   --help            Show this help and exit

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
OLD_DB_HOST="${OLD_DB_HOST:-localhost}"
OLD_DB_PORT="${OLD_DB_PORT:-5432}"
OLD_DB_NAME="${OLD_DB_NAME:-}"
OLD_DB_USER="${OLD_DB_USER:-}"
OLD_DB_PASSWORD="${OLD_DB_PASSWORD:-}"
OLD_DB_PGPASSFILE="${OLD_DB_PGPASSFILE:-}"

NEW_DB_HOST="${NEW_DB_HOST:-localhost}"
NEW_DB_PORT="${NEW_DB_PORT:-5432}"
NEW_DB_NAME="${NEW_DB_NAME:-}"
NEW_DB_USER="${NEW_DB_USER:-}"
NEW_DB_PASSWORD="${NEW_DB_PASSWORD:-}"
NEW_DB_PGPASSFILE="${NEW_DB_PGPASSFILE:-}"

DUMP_DIR="${DUMP_DIR:-./dumps}"
DUMP_FILE="${DUMP_FILE:-}"

DUMP_ONLY=false
RESTORE_ONLY=false

# ─── Helpers ─────────────────────────────────────────────────────────────────
usage() {
    # Print lines from the top of the file until the first non-comment line
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] || break
        echo "${line#\# }" | sed 's/^#$//'
    done < "$0" | tail -n +2   # skip the shebang line
    exit 0
}

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "'$1' is required but not installed."
}

validate_pgpassfile() {
    local pgpassfile="$1"
    local label="$2"

    [[ -f "$pgpassfile" ]] || err "${label} .pgpass file not found: ${pgpassfile}"
    [[ -r "$pgpassfile" ]] || err "${label} .pgpass file is not readable: ${pgpassfile}"
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)       usage ;;
        --dump-only)  DUMP_ONLY=true ;;
        --restore-only) RESTORE_ONLY=true ;;
        -H) OLD_DB_HOST="$2";     shift ;;
        -P) OLD_DB_PORT="$2";     shift ;;
        -d) OLD_DB_NAME="$2";     shift ;;
        -U) OLD_DB_USER="$2";     shift ;;
        -p) OLD_DB_PASSWORD="$2"; shift ;;
        --old-pgpassfile) OLD_DB_PGPASSFILE="$2"; shift ;;
        -h) NEW_DB_HOST="$2";     shift ;;
        -q) NEW_DB_PORT="$2";     shift ;;
        -D) NEW_DB_NAME="$2";     shift ;;
        -u) NEW_DB_USER="$2";     shift ;;
        -w) NEW_DB_PASSWORD="$2"; shift ;;
        --new-pgpassfile) NEW_DB_PGPASSFILE="$2"; shift ;;
        -o) DUMP_DIR="$2";        shift ;;
        -f) DUMP_FILE="$2";       shift ;;
        *) err "Unknown argument: $1. Use --help for usage." ;;
    esac
    shift
done

# ─── Validation ───────────────────────────────────────────────────────────────
if [[ "$RESTORE_ONLY" == false ]]; then
    [[ -n "$OLD_DB_NAME" ]] || err "Source database name is required (OLD_DB_NAME or -d)."
    [[ -n "$OLD_DB_USER" ]] || err "Source database user is required (OLD_DB_USER or -U)."
fi

if [[ "$DUMP_ONLY" == false ]]; then
    [[ -n "$NEW_DB_USER" ]] || err "Target database user is required (NEW_DB_USER or -u)."
fi

# Target DB name defaults to source DB name
NEW_DB_NAME="${NEW_DB_NAME:-$OLD_DB_NAME}"

if [[ -n "$OLD_DB_PGPASSFILE" ]]; then
    validate_pgpassfile "$OLD_DB_PGPASSFILE" "Source"
fi

if [[ -n "$NEW_DB_PGPASSFILE" ]]; then
    validate_pgpassfile "$NEW_DB_PGPASSFILE" "Target"
fi

# ─── Tool checks ──────────────────────────────────────────────────────────────
require_cmd pg_dump
require_cmd pg_restore || true   # pg_restore may be absent if psql is used for plain-text dumps
require_cmd psql

# ─── Build dump file path ─────────────────────────────────────────────────────
if [[ -z "$DUMP_FILE" ]]; then
    mkdir -p "$DUMP_DIR"
    TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
    DUMP_FILE="${DUMP_DIR}/${OLD_DB_NAME}_${TIMESTAMP}.dump"
fi

# ─── PGPASSWORD helpers ───────────────────────────────────────────────────────
run_pg_dump() {
    local -a pg_dump_cmd=(
        pg_dump
        --host="$OLD_DB_HOST"
        --port="$OLD_DB_PORT"
        --username="$OLD_DB_USER"
        --format=custom
        --blobs
        --verbose
        --file="$DUMP_FILE"
        "$OLD_DB_NAME"
    )

    if [[ -n "$OLD_DB_PASSWORD" ]]; then
        PGPASSWORD="$OLD_DB_PASSWORD" "${pg_dump_cmd[@]}"
    elif [[ -n "$OLD_DB_PGPASSFILE" ]]; then
        PGPASSFILE="$OLD_DB_PGPASSFILE" "${pg_dump_cmd[@]}"
    else
        "${pg_dump_cmd[@]}"
    fi
}

run_pg_restore() {
    local -a pg_restore_cmd=(
        pg_restore
        --host="$NEW_DB_HOST"
        --port="$NEW_DB_PORT"
        --username="$NEW_DB_USER"
        --dbname="$NEW_DB_NAME"
        --no-owner
        --no-privileges
        --verbose
        "$DUMP_FILE"
    )

    if [[ -n "$NEW_DB_PASSWORD" ]]; then
        PGPASSWORD="$NEW_DB_PASSWORD" "${pg_restore_cmd[@]}"
    elif [[ -n "$NEW_DB_PGPASSFILE" ]]; then
        PGPASSFILE="$NEW_DB_PGPASSFILE" "${pg_restore_cmd[@]}"
    else
        "${pg_restore_cmd[@]}"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
if [[ "$RESTORE_ONLY" == false ]]; then
    log "Starting dump of '${OLD_DB_NAME}' from ${OLD_DB_HOST}:${OLD_DB_PORT} ..."
    run_pg_dump
    DUMP_SIZE="$(du -sh "$DUMP_FILE" | cut -f1)"
    log "Dump complete: ${DUMP_FILE} (${DUMP_SIZE})"
else
    [[ -f "$DUMP_FILE" ]] || err "Dump file not found: ${DUMP_FILE}"
    log "Using existing dump file: ${DUMP_FILE}"
fi

if [[ "$DUMP_ONLY" == false ]]; then
    log "Restoring '${NEW_DB_NAME}' on ${NEW_DB_HOST}:${NEW_DB_PORT} ..."
    run_pg_restore
    log "Restore complete."
fi

log "Migration finished successfully."
