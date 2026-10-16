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

# Uploads every <repo>_<version_slug>_<suffix>.json under <dir>/<version>/ to
# <key_prefix><version>/<flat prefix>_<version_slug>_<suffix>; e.g. argo/argo-workflows/
# gives argo/argo-workflows/1.0.0/argo_argo-workflows_1_0_0_spdx.json. The suffix
# ([release_]{spdx,spdx3,cdx}.json) carries over from the local file name.
# Prints "Uploaded N SBOMs"; returns 1 when any upload failed.
# Usage: upload_sbom_dir <dir> <bucket> <key_prefix> <repo>
upload_sbom_dir() {
  local dir="$1" bucket="$2" prefix="$3" repo="$4" flat uploaded=0 failed=0
  local file version slug suffix
  flat="${prefix%/}"; flat="${flat//\//_}"
  while IFS= read -r file; do
    version="$(basename "$(dirname "$file")")"
    slug="${version//./_}"
    suffix="$(basename "$file")"; suffix="${suffix#${repo}_${slug}_}"
    if upload_sbom "$file" "$bucket" "${prefix}${version}/${flat}_${slug}_${suffix}"; then
      uploaded=$((uploaded + 1))
    else
      failed=$((failed + 1))
    fi
  done < <(find "$dir" -type f -name '*.json' | sort)
  echo "Uploaded ${uploaded} SBOMs to s3://${bucket}/${prefix}"
  if [ "$failed" -gt 0 ]; then
    echo "::error::${failed} SBOM uploads failed" >&2
    return 1
  fi
}
