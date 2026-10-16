#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

export S3_ENDPOINT="https://storage.example"
export S3_REGION="us-east-1"
export PROJECT_BUCKET="cncf-project-sboms"
export SUBPROJECT_BUCKET="cncf-subproject-sboms"
export EXPECTED_BUCKET EXPECTED_KEY_PREFIX TEST_UPLOAD_MODE

aws() {
  local bucket="" key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bucket) bucket="$2"; shift ;;
      --key) key="$2"; shift ;;
    esac
    shift
  done
  if [[ "$bucket" != "$EXPECTED_BUCKET" || "$key" != "$EXPECTED_KEY_PREFIX"* ]]; then
    echo "Unexpected destination: s3://$bucket/$key" >&2
    return 99
  fi
  case "$TEST_UPLOAD_MODE" in
    success) echo '{"ETag":"example"}' ;;
    failure)
      printf '\naws: simulated stderr failure\n' >&2
      return 254
      ;;
    stdout-failure)
      echo 'simulated stdout failure'
      return 255
      ;;
    silent-failure) return 42 ;;
    masked-service-error)
      echo "aws: [ERROR]: argument of type 'NoneType' is not a container or iterable" >&2
      return 255
      ;;
    partial)
      if [[ "$key" == *"/2.19.2/"* ]]; then
        echo "simulated partial failure" >&2
        return 254
      fi
      ;;
  esac
}
export -f aws

source "$ROOT_DIR/util/s3-upload.sh"
for version in 2.19.1 2.19.2; do
  mkdir -p "$TEMP_DIR/work/$version"
  printf '{"name":"OmniTrust ILM %s"}\n' "$version" >"$TEMP_DIR/work/$version/core_${version//./_}_spdx.json"
done

for scenario in project subproject; do
  EXPECTED_BUCKET="$PROJECT_BUCKET" EXPECTED_KEY_PREFIX="omnitrust-ilm/"
  [[ "$scenario" == subproject ]] && EXPECTED_BUCKET="$SUBPROJECT_BUCKET" EXPECTED_KEY_PREFIX="project/core/"

  TEST_UPLOAD_MODE=success
  upload_sbom_dir "$TEMP_DIR/work" "$EXPECTED_BUCKET" "$EXPECTED_KEY_PREFIX" core >"$TEMP_DIR/log" 2>&1
  grep -q '^Uploaded 2 SBOMs' "$TEMP_DIR/log"
  for TEST_UPLOAD_MODE in failure stdout-failure silent-failure masked-service-error partial; do
    if upload_sbom_dir "$TEMP_DIR/work" "$EXPECTED_BUCKET" "$EXPECTED_KEY_PREFIX" core >"$TEMP_DIR/log" 2>&1; then
      echo "Expected upload failure: $scenario / $TEST_UPLOAD_MODE" >&2
      exit 1
    fi
    grep -q '::error::Upload failed' "$TEMP_DIR/log"
    grep -q 'SBOM uploads failed' "$TEMP_DIR/log"
    case "$TEST_UPLOAD_MODE" in
      failure) grep -q 'simulated stderr failure' "$TEMP_DIR/log" ;;
      stdout-failure) grep -q 'simulated stdout failure' "$TEMP_DIR/log" ;;
      silent-failure) grep -q 'AWS CLI returned no diagnostic output' "$TEMP_DIR/log" ;;
      masked-service-error) grep -q "PutObject permissions" "$TEMP_DIR/log" ;;
      partial) grep -q '^Uploaded 1 SBOMs' "$TEMP_DIR/log" ;;
    esac
  done
done

source "$ROOT_DIR/util/s3-upload.sh"
if upload_sbom "$TEMP_DIR/missing.json" "$PROJECT_BUCKET" key >"$TEMP_DIR/log" 2>&1; then
  echo "Expected a missing SBOM to fail" >&2
  exit 1
fi
grep -q 'missing or empty' "$TEMP_DIR/log"
if upload_sbom "$TEMP_DIR/missing.json" "" key >"$TEMP_DIR/log" 2>&1; then
  echo "Expected an empty bucket to fail" >&2
  exit 1
fi
grep -q 'must be configured' "$TEMP_DIR/log"

echo "S3 upload tests passed"
