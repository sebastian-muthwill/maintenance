#!/usr/bin/env bash
# migrate_pg_db.sh
# Dumps a PostgreSQL database from the old server and restores it on the new server.
#
# Configuration via environment variables or command-line arguments:
#
#   OLD_DB_HOST        Hostname / IP of the source PostgreSQL server  (default: from .pgpass or localhost)
#   OLD_DB_PORT        Port of the source server                       (default: from .pgpass or 5432)
#   OLD_DB_NAME        Database name on the source server              (required unless derivable from .pgpass)
#   OLD_DB_USER        Username for the source server                  (required unless derivable from .pgpass)
#   OLD_DB_PASSWORD    Password for the source server                  (optional, use .pgpass otherwise)
#   OLD_DB_PGPASSFILE  Path to .pgpass for source server               (optional)
#
#   NEW_DB_HOST        Hostname / IP of the target PostgreSQL server  (default: from .pgpass or localhost)
#   NEW_DB_PORT        Port of the target server                       (default: from .pgpass or 5432)
#   NEW_DB_NAME        Database name on the target server              (default: from .pgpass or OLD_DB_NAME)
#   NEW_DB_USER        Username for the target server                  (required unless derivable from .pgpass)
#   NEW_DB_PASSWORD    Password for the target server                  (optional, use .pgpass otherwise)
#   NEW_DB_PGPASSFILE  Path to .pgpass for target server               (optional)
#
#   DUMP_DIR           Local directory to store the dump file          (default: ./dumps)
#   DUMP_FILE          Explicit dump file path (overrides DUMP_DIR)    (optional)
#   DUMP_DATA_ONLY     Dump data only (no schema/constraints)           (default: false)
#
# Command-line arguments override environment variables:
#   -H  old host      -P  old port    -d  old db name   -U  old user   -p  old password
#   --old-pgpassfile  old .pgpass file path
#   -h  new host      -q  new port    -D  new db name   -u  new user   -w  new password
#   --new-pgpassfile  new .pgpass file path
#   -o  dump dir      -f  dump file
#   --data-only       Dump data only (for restoring into existing schema)
#   --dump-only       Only dump, do not restore
#   --restore-only    Only restore from an existing dump file (requires -f / DUMP_FILE)
#   --help            Show this help and exit

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
OLD_DB_HOST="${OLD_DB_HOST:-}"
OLD_DB_PORT="${OLD_DB_PORT:-}"
OLD_DB_NAME="${OLD_DB_NAME:-}"
OLD_DB_USER="${OLD_DB_USER:-}"
OLD_DB_PASSWORD="${OLD_DB_PASSWORD:-}"
OLD_DB_PGPASSFILE="${OLD_DB_PGPASSFILE:-}"

NEW_DB_HOST="${NEW_DB_HOST:-}"
NEW_DB_PORT="${NEW_DB_PORT:-}"
NEW_DB_NAME="${NEW_DB_NAME:-}"
NEW_DB_USER="${NEW_DB_USER:-}"
NEW_DB_PASSWORD="${NEW_DB_PASSWORD:-}"
NEW_DB_PGPASSFILE="${NEW_DB_PGPASSFILE:-}"

DUMP_DIR="${DUMP_DIR:-./dumps}"
DUMP_FILE="${DUMP_FILE:-}"
DUMP_DATA_ONLY="${DUMP_DATA_ONLY:-false}"

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

resolve_connection_from_pgpass() {
    local label="$1"
    local pgpassfile="$2"
    local -n host_ref="$3"
    local -n port_ref="$4"
    local -n db_ref="$5"
    local -n user_ref="$6"

    local line
    local entry_host
    local entry_port
    local entry_db
    local entry_user
    local found_match=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        IFS=':' read -r entry_host entry_port entry_db entry_user _ <<< "$line"
        [[ -n "$entry_user" ]] || continue

        if [[ -n "$host_ref" && "$entry_host" != "*" && "$entry_host" != "$host_ref" ]]; then
            continue
        fi
        if [[ -n "$port_ref" && "$entry_port" != "*" && "$entry_port" != "$port_ref" ]]; then
            continue
        fi
        if [[ -n "$db_ref" && "$entry_db" != "*" && "$entry_db" != "$db_ref" ]]; then
            continue
        fi
        if [[ -n "$user_ref" && "$entry_user" != "*" && "$entry_user" != "$user_ref" ]]; then
            continue
        fi

        found_match=true

        if [[ -z "$host_ref" && "$entry_host" != "*" ]]; then
            host_ref="$entry_host"
        fi
        if [[ -z "$port_ref" && "$entry_port" != "*" ]]; then
            port_ref="$entry_port"
        fi
        if [[ -z "$db_ref" && "$entry_db" != "*" ]]; then
            db_ref="$entry_db"
        fi
        if [[ -z "$user_ref" && "$entry_user" != "*" ]]; then
            user_ref="$entry_user"
        fi

        break
    done < "$pgpassfile"

    if [[ "$found_match" == false ]]; then
        err "${label} .pgpass file has no entry matching the provided connection parameters."
    fi
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
        --data-only) DUMP_DATA_ONLY=true ;;
        *) err "Unknown argument: $1. Use --help for usage." ;;
    esac
    shift
done

if [[ "$DUMP_DATA_ONLY" != "true" && "$DUMP_DATA_ONLY" != "false" ]]; then
    err "DUMP_DATA_ONLY must be 'true' or 'false'."
fi

if [[ -n "$OLD_DB_PGPASSFILE" ]]; then
    validate_pgpassfile "$OLD_DB_PGPASSFILE" "Source"
fi

if [[ -n "$NEW_DB_PGPASSFILE" ]]; then
    validate_pgpassfile "$NEW_DB_PGPASSFILE" "Target"
fi

if [[ "$RESTORE_ONLY" == false && -n "$OLD_DB_PGPASSFILE" ]]; then
    resolve_connection_from_pgpass "Source" "$OLD_DB_PGPASSFILE" OLD_DB_HOST OLD_DB_PORT OLD_DB_NAME OLD_DB_USER
fi

if [[ "$DUMP_ONLY" == false && -n "$NEW_DB_PGPASSFILE" ]]; then
    resolve_connection_from_pgpass "Target" "$NEW_DB_PGPASSFILE" NEW_DB_HOST NEW_DB_PORT NEW_DB_NAME NEW_DB_USER
fi

# Fall back to traditional defaults when host/port were not specified or derived.
OLD_DB_HOST="${OLD_DB_HOST:-localhost}"
OLD_DB_PORT="${OLD_DB_PORT:-5432}"
NEW_DB_HOST="${NEW_DB_HOST:-localhost}"
NEW_DB_PORT="${NEW_DB_PORT:-5432}"

# Target DB name defaults to source DB name when not provided/derived.
NEW_DB_NAME="${NEW_DB_NAME:-$OLD_DB_NAME}"

# ─── Validation ───────────────────────────────────────────────────────────────
if [[ "$RESTORE_ONLY" == false ]]; then
    [[ -n "$OLD_DB_NAME" ]] || err "Source database name is required (OLD_DB_NAME / -d, or derivable from --old-pgpassfile)."
    [[ -n "$OLD_DB_USER" ]] || err "Source database user is required (OLD_DB_USER / -U, or derivable from --old-pgpassfile)."
fi

if [[ "$DUMP_ONLY" == false ]]; then
    [[ -n "$NEW_DB_NAME" ]] || err "Target database name is required (NEW_DB_NAME / -D, derivable from --new-pgpassfile, or inherited from OLD_DB_NAME)."
    [[ -n "$NEW_DB_USER" ]] || err "Target database user is required (NEW_DB_USER / -u, or derivable from --new-pgpassfile)."
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
        --no-owner
        --no-privileges
        --blobs
        --verbose
        --file="$DUMP_FILE"
        "$OLD_DB_NAME"
    )

    if [[ "$DUMP_DATA_ONLY" == "true" ]]; then
        pg_dump_cmd+=(--data-only)
    fi

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
    if [[ "$DUMP_DATA_ONLY" == "true" ]]; then
        log "Starting data-only dump of '${OLD_DB_NAME}' from ${OLD_DB_HOST}:${OLD_DB_PORT} ..."
    else
        log "Starting dump of '${OLD_DB_NAME}' from ${OLD_DB_HOST}:${OLD_DB_PORT} ..."
    fi
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
