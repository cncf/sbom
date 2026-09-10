#!/usr/bin/env bash

upload_sbom() {
  local file="$1"
  local bucket="$2"
  local key="$3"
  local output status

  if [[ -z "${S3_ENDPOINT:-}" || -z "${S3_REGION:-}" || -z "$bucket" || -z "$key" ]]; then
    echo "::error::S3 endpoint, region, bucket, and object key must be configured" >&2
    return 1
  fi
  if [[ ! -s "$file" ]]; then
    echo "::error::SBOM file is missing or empty: $file" >&2
    return 1
  fi

  echo "Uploading: s3://${bucket}/${key}"
  if output=$(AWS_PAGER="" aws s3api put-object \
    --endpoint-url "$S3_ENDPOINT" \
    --region "$S3_REGION" \
    --bucket "$bucket" \
    --key "$key" \
    --body "$file" 2>&1); then
    return 0
  else
    status=$?
    printf '::error::Upload failed for %s to s3://%s/%s (AWS CLI exit %s)\n' \
      "$file" "$bucket" "$key" "$status" >&2
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output" >&2
      if [[ "$output" == *"argument of type 'NoneType'"* ]]; then
        echo "AWS CLI may be masking an S3 service error with an empty Message. Check the S3 key's PutObject permissions and bucket policy; AccessDenied can trigger this CLI error." >&2
      fi
    else
      echo "AWS CLI returned no diagnostic output" >&2
    fi
    return "$status"
  fi
}
