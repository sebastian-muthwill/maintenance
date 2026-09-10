#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gsutil" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_LOG"
EOF

cat > "$FAKE_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_LOG"
EOF

chmod +x "$FAKE_BIN/gsutil" "$FAKE_BIN/aws"

FAKE_LOG="$TEST_DIR/log.txt"
export FAKE_LOG
PATH="$FAKE_BIN:$PATH"

GCS_BUCKET=test-gcs-bucket S3_BUCKET=test-s3-bucket UPLOAD_ONLY=true bash \
  "$(dirname "$0")/migrate_gcs_to_s3.sh" >/dev/null 2>&1

if grep -q "rsync" "$FAKE_LOG"; then
  echo "FAIL: upload-only mode still triggered GCS download." >&2
  exit 1
fi

if ! grep -q "s3 sync" "$FAKE_LOG"; then
  echo "FAIL: upload-only mode did not invoke the S3 upload." >&2
  exit 1
fi

echo "PASS: upload-only mode behaves correctly."
