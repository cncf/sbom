#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${ROOT_DIR}/sbom"
DISCOVERED_FILE="${ROOT_DIR}/util/data/discovered-repos.yaml"

DOTENV_FILE=""
if [[ -f "${ROOT_DIR}/.env.sbom" ]]; then
  DOTENV_FILE="${ROOT_DIR}/.env.sbom"
elif [[ -f "${ROOT_DIR}/.env" ]]; then
  DOTENV_FILE="${ROOT_DIR}/.env"
fi

if [[ -n "$DOTENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$DOTENV_FILE"
  set +a
fi

PROJECT_BUCKET="${PROJECT_BUCKET:-cncf-project-sboms}"
SUBPROJECT_BUCKET="${SUBPROJECT_BUCKET:-cncf-subproject-sboms}"
OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
AUTH_MODE="${AUTH_MODE:-oci}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-${AWS_ACCESS_KEY_ID:-}}"
S3_SECRET_KEY="${S3_SECRET_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
S3_SESSION_TOKEN="${S3_SESSION_TOKEN:-${AWS_SESSION_TOKEN:-}}"
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Uploads existing local SBOM JSON files from the repository into OCI buckets.

Options:
  --source-dir <path>          Source SBOM directory (default: ${SOURCE_DIR})
  --project-bucket <name>      OCI bucket for project SBOMs (default: ${PROJECT_BUCKET})
  --subproject-bucket <name>   OCI bucket for subproject SBOMs (default: ${SUBPROJECT_BUCKET})
  --auth-mode <oci|s3>         Upload auth mode (default: ${AUTH_MODE})
  --oci-profile <name>         OCI CLI profile (default: ${OCI_PROFILE})
  --s3-endpoint <url>          S3-compatible endpoint URL (required with --auth-mode s3)
  --s3-region <region>         S3 region (default: ${S3_REGION})
  --s3-access-key <key>        S3 access key (or set AWS_ACCESS_KEY_ID)
  --s3-secret-key <key>        S3 secret key (or set AWS_SECRET_ACCESS_KEY)
  --s3-session-token <token>   Optional session token (or set AWS_SESSION_TOKEN)
  --force                      Overwrite existing objects in bucket
  --dry-run                    Print planned uploads without writing to OCI
  -h, --help                   Show this help

Dotenv auto-load (optional):
  - ${ROOT_DIR}/.env.sbom (preferred)
  - ${ROOT_DIR}/.env

Expected legacy source layouts:
  - Projects:    sbom/<project>/<repo>/<version>/<file>.json
  - Subprojects: sbom/subprojects/<owner>/<subproject>/<version>/<file>.json

Target object naming:
  - Projects:    <project>/<version>/<project>_<version>_spdx.json
  - Subprojects: <project>/<subproject>/<version>/<project>_<subproject>_<version>_spdx.json
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)
      SOURCE_DIR="$2"
      shift 2
      ;;
    --project-bucket)
      PROJECT_BUCKET="$2"
      shift 2
      ;;
    --subproject-bucket)
      SUBPROJECT_BUCKET="$2"
      shift 2
      ;;
    --oci-profile)
      OCI_PROFILE="$2"
      shift 2
      ;;
    --auth-mode)
      AUTH_MODE="$2"
      shift 2
      ;;
    --s3-endpoint)
      S3_ENDPOINT="$2"
      shift 2
      ;;
    --s3-region)
      S3_REGION="$2"
      shift 2
      ;;
    --s3-access-key)
      S3_ACCESS_KEY="$2"
      shift 2
      ;;
    --s3-secret-key)
      S3_SECRET_KEY="$2"
      shift 2
      ;;
    --s3-session-token)
      S3_SESSION_TOKEN="$2"
      shift 2
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$AUTH_MODE" != "oci" && "$AUTH_MODE" != "s3" ]]; then
  echo "Error: --auth-mode must be either 'oci' or 's3'" >&2
  exit 1
fi

if [[ "$AUTH_MODE" == "oci" ]]; then
  if ! command -v oci >/dev/null 2>&1; then
    echo "Error: oci CLI not found in PATH" >&2
    exit 1
  fi
else
  if ! command -v aws >/dev/null 2>&1; then
    echo "Error: aws CLI not found in PATH (required for --auth-mode s3)" >&2
    exit 1
  fi

  if [[ -z "$S3_ENDPOINT" ]]; then
    echo "Error: --s3-endpoint is required when --auth-mode s3" >&2
    exit 1
  fi

  if [[ -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" ]]; then
    echo "Error: S3 credentials missing. Use --s3-access-key/--s3-secret-key or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY" >&2
    exit 1
  fi
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Error: source dir does not exist: $SOURCE_DIR" >&2
  exit 1
fi

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-'
}

sanitize_version() {
  local v
  v="${1#v}"
  # Remove CR/LF first, then normalize separators/spaces to '-', then trim.
  v="${v//$'\r'/}"
  v="${v//$'\n'/}"
  v="$(printf '%s' "$v" | sed -E 's/[[:space:]\/]+/-/g; s/^-+//; s/-+$//')"
  v="$(printf '%s' "$v" | tr -cd '[:alnum:]._-')"
  if [[ -z "$v" ]]; then
    echo "unknown"
  else
    echo "$v"
  fi
}

declare -A PARENT_PROJECT_BY_REPO
load_subproject_mapping() {
  if [[ ! -f "$DISCOVERED_FILE" ]]; then
    return 0
  fi

  if ! command -v yq >/dev/null 2>&1; then
    echo "Info: yq not found; subproject parent mapping falls back to owner name." >&2
    return 0
  fi

  while IFS=$'\t' read -r owner repo parent; do
    [[ -z "$owner" || -z "$repo" ]] && continue
    PARENT_PROJECT_BY_REPO["${owner}/${repo}"]="$parent"
  done < <(
    yq -r '.repositories[] | [
      .owner,
      .repo,
      ((.discovered_by // "") | capture("from [^/]+/(?<repo>[^ ]+)")?.repo // .owner)
    ] | @tsv' "$DISCOVERED_FILE"
  )
}

object_exists() {
  local bucket="$1"
  local key="$2"

  if [[ "$AUTH_MODE" == "oci" ]]; then
    oci os object head --profile "$OCI_PROFILE" -bn "$bucket" --name "$key" >/dev/null 2>&1
    return 0
  fi

  AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
  AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
  AWS_SESSION_TOKEN="$S3_SESSION_TOKEN" \
  AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
  AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
  aws s3api head-object \
    --endpoint-url "$S3_ENDPOINT" \
    --region "$S3_REGION" \
    --bucket "$bucket" \
    --key "$key" >/dev/null 2>&1
}

upload_object() {
  local bucket="$1"
  local key="$2"
  local file="$3"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY-RUN: oci://${bucket}/${key} <- ${file}"
    return 0
  fi

  if [[ "$AUTH_MODE" == "oci" ]]; then
    if ! oci os object put \
      --profile "$OCI_PROFILE" \
      -bn "$bucket" \
      --name "$key" \
      --file "$file" \
      --force \
      --no-progress >/dev/null; then
      return 1
    fi
  else
    if ! AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
      AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
      AWS_SESSION_TOKEN="$S3_SESSION_TOKEN" \
      AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
      AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
      aws s3api put-object \
        --endpoint-url "$S3_ENDPOINT" \
        --region "$S3_REGION" \
        --bucket "$bucket" \
        --key "$key" \
        --body "$file" >/dev/null; then
      return 1
    fi
  fi

  echo "Uploaded: oci://${bucket}/${key}"
}

load_subproject_mapping

total=0
uploaded=0
skipped=0
failed=0

while IFS= read -r file; do
  total=$((total + 1))

  rel="${file#${SOURCE_DIR}/}"
  IFS='/' read -r p1 p2 p3 p4 _ <<<"$rel"

  bucket=""
  key=""

  if [[ "$p1" == "subprojects" ]]; then
    owner="$p2"
    subproject="$p3"
    version="$p4"

    if [[ -z "$owner" || -z "$subproject" || -z "$version" ]]; then
      echo "Skip malformed subproject path: ${rel}" >&2
      skipped=$((skipped + 1))
      continue
    fi

    parent_project="${PARENT_PROJECT_BY_REPO["${owner}/${subproject}"]:-$owner}"
    project_slug="$(slugify "$parent_project")"
    subproject_slug="$(slugify "$subproject")"
    version_slug="$(sanitize_version "$version")"
    filename_version="$(echo "$version_slug" | tr '.' '_')"

    file_name="${project_slug}_${subproject_slug}_${filename_version}_spdx.json"
    key="${project_slug}/${subproject_slug}/${version_slug}/${file_name}"
    bucket="$SUBPROJECT_BUCKET"
  else
    project="$p1"
    repo="$p2"
    version="$p3"

    if [[ -z "$project" || -z "$repo" || -z "$version" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    project_slug="$(slugify "$project")"
    version_slug="$(sanitize_version "$version")"
    filename_version="$(echo "$version_slug" | tr '.' '_')"

    file_name="${project_slug}_${filename_version}_spdx.json"
    key="${project_slug}/${version_slug}/${file_name}"
    bucket="$PROJECT_BUCKET"
  fi

  if [[ "$FORCE" != "true" ]] && object_exists "$bucket" "$key"; then
    echo "Skip existing: oci://${bucket}/${key}"
    skipped=$((skipped + 1))
    continue
  fi

  if upload_object "$bucket" "$key" "$file"; then
    uploaded=$((uploaded + 1))
  else
    echo "Upload failed for ${file}" >&2
    failed=$((failed + 1))
  fi
done < <(find "$SOURCE_DIR" -type f -name '*.json' ! -name 'index.json' | sort)

echo
echo "Ingest finished"
echo "- Total files scanned: ${total}"
echo "- Uploaded: ${uploaded}"
echo "- Skipped: ${skipped}"
echo "- Failed: ${failed}"

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi







