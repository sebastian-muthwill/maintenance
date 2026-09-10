# Google Cloud Storage to S3 Migration

This folder contains a Bash script for copying object data from a Google Cloud Storage bucket into an Amazon S3 bucket.

## `migrate_gcs_to_s3.sh`

The script can run in one of three modes:

- Full copy: download from GCS to a local directory and then sync to S3.
- Download-only: fetch the GCS objects without uploading them to S3.
- Upload-only: upload a pre-downloaded local directory to S3.

Delta / incremental copies are supported via `--delta` or `DELTA_MODE=true`. In that mode the underlying tools perform a timestamp-aware sync:

- GCS download: `gsutil rsync -r -d` or `gcloud storage rsync --recursive --delete`
- S3 upload: `aws s3 sync ... --delete`

This lets the job skip unchanged files and remove stale files from the destination when a full reconciliation is desired.

## Prerequisites

- `gsutil` or `gcloud` installed and authenticated for the source Google Cloud Storage bucket
- `aws` CLI installed and configured for the destination S3 bucket
- Network access to both storage systems

## Configuration

Set any of these as environment variables, or pass the equivalent command-line arguments. Command-line flags take precedence.

| Variable | Flag | Description | Default |
|---|---|---|---|
| `GCS_BUCKET` | `--gcs-bucket` | Source Google bucket | required |
| `GCS_PREFIX` | `--gcs-prefix` | Optional GCS prefix / folder | empty |
| `S3_BUCKET` | `--s3-bucket` | Destination S3 bucket | required |
| `S3_PREFIX` | `--s3-prefix` | Optional S3 prefix / folder | empty |
| `LOCAL_DIR` | `--local-dir` | Local directory for staging | `./gcs-download` |
| `DOWNLOAD_ONLY` | `--download-only` | Skip the S3 upload step | `false` |
| `UPLOAD_ONLY` | `--upload-only` | Skip the GCS download step | `false` |
| `DELTA_MODE` | `--delta` | Use incremental sync semantics | `false` |
| `AWS_PROFILE` | `--aws-profile` | AWS profile for CLI auth | empty |
| `AWS_REGION` | `--aws-region` | AWS CLI region | empty |

## Usage examples

### Full migration with delta sync

```bash
export GCS_BUCKET=my-gcs-bucket
export GCS_PREFIX=archive/2025
export S3_BUCKET=my-s3-bucket
export S3_PREFIX=archive/2025
export LOCAL_DIR=/var/tmp/gcs-export
export DELTA_MODE=true

bash migration-scripts/google-storage-to-s3/migrate_gcs_to_s3.sh
```

### Download only

```bash
bash migration-scripts/google-storage-to-s3/migrate_gcs_to_s3.sh \
  --gcs-bucket my-gcs-bucket \
  --gcs-prefix archive/2025 \
  --local-dir /var/tmp/gcs-export \
  --download-only
```

### Upload only

```bash
bash migration-scripts/google-storage-to-s3/migrate_gcs_to_s3.sh \
  --s3-bucket my-s3-bucket \
  --s3-prefix archive/2025 \
  --local-dir /var/tmp/gcs-export \
  --upload-only \
  --delta
```

### Full migration without delta logic

```bash
bash migration-scripts/google-storage-to-s3/migrate_gcs_to_s3.sh \
  --gcs-bucket my-gcs-bucket \
  --s3-bucket my-s3-bucket \
  --local-dir /var/tmp/gcs-export \
  --full
```

## Notes

- The script uses timestamp-aware sync semantics when `--delta` or `DELTA_MODE=true` is enabled. This is the practical incremental pattern for Google Cloud Storage and S3.
- If you need a strict historical delta window (for example, only files changed since a specific point in time), you can combine the script with a custom prefix or a pre-filtered GCS object set before invoking it.
- The local staging directory is kept in a predictable location, which makes it easy to rerun the upload step without re-downloading the GCS data.
- Ensure both Google and AWS credentials are valid before running the script in production.
