#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
ln -s "$ROOT_DIR/util" "$TEMP_DIR/util"

export S3_ENDPOINT="https://storage.example"
export S3_REGION="us-east-1"
export PROJECT_BUCKET="cncf-project-sboms"
export SUBPROJECT_BUCKET="cncf-subproject-sboms"
export GITHUB_OUTPUT="$TEMP_DIR/output"
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

run_upload_step() {
  local workflow="$1"
  : >"$GITHUB_OUTPUT"
  yq -r '.jobs[].steps[]? | select(.id == "upload") | .run' "$workflow" |
    sed \
      -e 's/${{ matrix.owner }}/OmniTrustILM/g' \
      -e 's/${{ matrix.repo }}/core/g' \
      -e 's/${{ matrix.name }}/OmniTrust ILM/g' \
      -e 's/${{ matrix.discovered_by }}/from parent\/project/g' |
    (cd "$TEMP_DIR" && bash -e)
}

for version in 2.19.1 2.19.2; do
  for base in sbom/omnitrust-ilm/core sbom/subprojects/OmniTrustILM/core; do
    mkdir -p "$TEMP_DIR/$base/$version"
    printf '{"name":"OmniTrust ILM %s"}\n' "$version" >"$TEMP_DIR/$base/$version/sbom.json"
  done
done

for scenario in project reusable-project subproject; do
  export SBOM_PATH_PREFIX=""
  EXPECTED_BUCKET="$PROJECT_BUCKET"
  EXPECTED_KEY_PREFIX="omnitrust-ilm/"
  WORKFLOW="$ROOT_DIR/.github/workflows/generate-sbom.yml"
  if [[ "$scenario" != project ]]; then
    WORKFLOW="$ROOT_DIR/.github/workflows/reusable-generate-sbom.yml"
  fi
  if [[ "$scenario" == subproject ]]; then
    SBOM_PATH_PREFIX="subprojects"
    EXPECTED_BUCKET="$SUBPROJECT_BUCKET"
    EXPECTED_KEY_PREFIX="project/core/"
  fi

  TEST_UPLOAD_MODE=success
  run_upload_step "$WORKFLOW" >"$TEMP_DIR/log" 2>&1
  grep -q '^uploaded=2$' "$GITHUB_OUTPUT"
  for TEST_UPLOAD_MODE in failure stdout-failure silent-failure masked-service-error partial; do
    if run_upload_step "$WORKFLOW" >"$TEMP_DIR/log" 2>&1; then
      echo "Expected workflow failure: $scenario / $TEST_UPLOAD_MODE" >&2
      exit 1
    fi
    grep -q '::error::Upload failed' "$TEMP_DIR/log"
    grep -q 'SBOM uploads failed' "$TEMP_DIR/log"
    case "$TEST_UPLOAD_MODE" in
      failure) grep -q 'simulated stderr failure' "$TEMP_DIR/log" ;;
      stdout-failure) grep -q 'simulated stdout failure' "$TEMP_DIR/log" ;;
      silent-failure) grep -q 'AWS CLI returned no diagnostic output' "$TEMP_DIR/log" ;;
      masked-service-error) grep -q "PutObject permissions" "$TEMP_DIR/log" ;;
      partial) grep -q '^uploaded=1$' "$GITHUB_OUTPUT" ;;
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
