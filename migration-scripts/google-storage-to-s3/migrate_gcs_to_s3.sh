#!/usr/bin/env bash
# migrate_gcs_to_s3.sh
# Downloads objects from a Google Cloud Storage bucket and uploads them to an S3 bucket.
#
# Configuration via environment variables or command-line arguments:
#
#   GCS_BUCKET        Google Cloud Storage bucket name (required)
#   GCS_PREFIX        Optional object prefix inside the bucket (e.g. "folder/subfolder")
#   S3_BUCKET         Amazon S3 bucket name (required)
#   S3_PREFIX         Optional object prefix inside the S3 bucket (e.g. "folder/subfolder")
#   LOCAL_DIR         Local directory for the downloaded files (default: ./gcs-download)
#   DOWNLOAD_ONLY     Set to "true" to skip the upload step
#   UPLOAD_ONLY       Set to "true" to skip the download step
#   DELTA_MODE        Set to "true" to only sync changed files (download: gsutil/gcloud rsync --delete; upload: aws s3 sync --delete)
#   AWS_PROFILE       Optional AWS profile name to use for AWS CLI commands
#   AWS_REGION        Optional AWS region for AWS CLI commands
#
# Command-line arguments override environment variables:
#   --gcs-bucket       Google bucket name
#   --gcs-prefix       GCS prefix
#   --s3-bucket        S3 bucket name
#   --s3-prefix        S3 prefix
#   --local-dir        Local download directory
#   --download-only    Skip the S3 upload step
#   --upload-only      Skip the GCS download step
#   --delta            Use delta / incremental sync semantics for both copy steps
#   --full             Disable delta / incremental sync semantics
#   --aws-profile      AWS profile name
#   --aws-region       AWS region
#   --help             Show this help and exit

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
GCS_BUCKET="${GCS_BUCKET:-}"
GCS_PREFIX="${GCS_PREFIX:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-}"
LOCAL_DIR="${LOCAL_DIR:-./gcs-download}"
DOWNLOAD_ONLY="${DOWNLOAD_ONLY:-false}"
UPLOAD_ONLY="${UPLOAD_ONLY:-false}"
DELTA_MODE="${DELTA_MODE:-false}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-}"

# ─── Helpers ─────────────────────────────────────────────────────────────────
usage() {
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] || break
        echo "${line#\# }" | sed 's/^#$//'
    done < "$0" | tail -n +2
    exit 0
}

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "Required command '$1' is not installed or not on PATH."
}

aws_cli_args() {
    local -a args=()
    if [[ -n "$AWS_PROFILE" ]]; then
        args+=(--profile "$AWS_PROFILE")
    fi
    if [[ -n "$AWS_REGION" ]]; then
        args+=(--region "$AWS_REGION")
    fi
    printf '%s\n' "${args[@]}"
}

resolve_gcs_tool() {
    if command -v gsutil >/dev/null 2>&1; then
        GCS_TOOL="gsutil"
    elif command -v gcloud >/dev/null 2>&1; then
        GCS_TOOL="gcloud"
    else
        err "Neither 'gsutil' nor 'gcloud' is available. Install Google Cloud SDK first."
    fi
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --gcs-bucket) GCS_BUCKET="$2"; shift ;;
        --gcs-prefix) GCS_PREFIX="$2"; shift ;;
        --s3-bucket) S3_BUCKET="$2"; shift ;;
        --s3-prefix) S3_PREFIX="$2"; shift ;;
        --local-dir) LOCAL_DIR="$2"; shift ;;
        --download-only) DOWNLOAD_ONLY=true ;;
        --upload-only) UPLOAD_ONLY=true ;;
        --delta) DELTA_MODE=true ;;
        --full) DELTA_MODE=false ;;
        --aws-profile) AWS_PROFILE="$2"; shift ;;
        --aws-region) AWS_REGION="$2"; shift ;;
        *) err "Unknown argument: $1. Use --help for usage." ;;
    esac
    shift
done

# Allow environment names for booleans to be case-insensitive.
DOWNLOAD_ONLY="${DOWNLOAD_ONLY,,}"
UPLOAD_ONLY="${UPLOAD_ONLY,,}"
DELTA_MODE="${DELTA_MODE,,}"

if [[ "$DOWNLOAD_ONLY" == "true" && "$UPLOAD_ONLY" == "true" ]]; then
    err "Use either --download-only or --upload-only, not both."
fi

resolve_gcs_tool
require_cmd aws

# ─── Validation ───────────────────────────────────────────────────────────────
[[ -n "$GCS_BUCKET" ]] || err "GCS_BUCKET is required (environment variable or --gcs-bucket)."
[[ -n "$S3_BUCKET" ]] || err "S3_BUCKET is required (environment variable or --s3-bucket)."

# Clean and normalize prefix values to avoid double slashes.
GCS_PREFIX="${GCS_PREFIX#/}"
GCS_PREFIX="${GCS_PREFIX%/}"
S3_PREFIX="${S3_PREFIX#/}"
S3_PREFIX="${S3_PREFIX%/}"

# Convert boolean to flag-friendly variables for the later commands.
download_delta=false
upload_delta=false
if [[ "$DELTA_MODE" == "true" ]]; then
    download_delta=true
    upload_delta=true
fi

# ─── Helper functions for download/upload ─────────────────────────────────────
normalize_gcs_source() {
    if [[ -n "$GCS_PREFIX" ]]; then
        printf '%s' "gs://${GCS_BUCKET}/${GCS_PREFIX}"
    else
        printf '%s' "gs://${GCS_BUCKET}"
    fi
}

normalize_s3_target() {
    if [[ -n "$S3_PREFIX" ]]; then
        printf '%s' "s3://${S3_BUCKET}/${S3_PREFIX}"
    else
        printf '%s' "s3://${S3_BUCKET}"
    fi
}

download_from_gcs() {
    local gcs_url
    gcs_url="$(normalize_gcs_source)"

    mkdir -p "$LOCAL_DIR"
    log "Downloading from ${gcs_url} into ${LOCAL_DIR}"

    if [[ "$GCS_TOOL" == "gsutil" ]]; then
        if [[ "$download_delta" == "true" ]]; then
            gsutil -m rsync -r -d "$gcs_url" "$LOCAL_DIR"
        else
            gsutil -m rsync -r "$gcs_url" "$LOCAL_DIR"
        fi
    else
        if [[ "$download_delta" == "true" ]]; then
            gcloud storage rsync --recursive --delete "$gcs_url" "$LOCAL_DIR"
        else
            gcloud storage rsync --recursive "$gcs_url" "$LOCAL_DIR"
        fi
    fi

    log "Download complete."
}

upload_to_s3() {
    local s3_url
    s3_url="$(normalize_s3_target)"

    mkdir -p "$LOCAL_DIR"
    log "Uploading from ${LOCAL_DIR} to ${s3_url}"

    local -a aws_args=()
    if [[ -n "$AWS_PROFILE" ]]; then
        aws_args+=(--profile "$AWS_PROFILE")
    fi
    if [[ -n "$AWS_REGION" ]]; then
        aws_args+=(--region "$AWS_REGION")
    fi

    if [[ "$upload_delta" == "true" ]]; then
        aws "${aws_args[@]}" s3 sync "$LOCAL_DIR" "$s3_url" --delete
    else
        aws "${aws_args[@]}" s3 sync "$LOCAL_DIR" "$s3_url"
    fi

    log "Upload complete."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
if [[ "$UPLOAD_ONLY" != "true" ]]; then
    download_from_gcs
fi

if [[ "$DOWNLOAD_ONLY" != "true" ]]; then
    upload_to_s3
fi

log "Migration finished successfully."
