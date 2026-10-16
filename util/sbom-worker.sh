#!/usr/bin/env bash
#
# Processes the share of a plan (util/sbom-plan.sh) that belongs to one worker:
# for every (repository, tag) it imports the release SBOM or scans with Waybill,
# post-processes, and uploads straight away so one bad repository costs only
# its own item. Lines are dealt round-robin: worker w takes line n where n % workers == w.
#
# Usage: sbom-worker.sh PLAN_FILE WORKER WORKERS
#   WORKER is 0-based.
# Prints one "::error title=sbom-failed::owner/repo@tag" per failed item, writes
# {"uploaded": N, "failed": [...]} to SBOM_RESULT_FILE when set, and exits 1 when
# any item failed.
# Environment: S3_ENDPOINT, S3_REGION (+ AWS credentials), GH_TOKEN, SBOM_RESULT_FILE.
# Needs gh, jq, curl, git, waybill, aws.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=util/sbom-lib.sh
source "$SCRIPT_DIR/sbom-lib.sh"
# shellcheck source=util/s3-upload.sh
source "$SCRIPT_DIR/s3-upload.sh"

PLAN="${1:?usage: sbom-worker.sh PLAN_FILE WORKER WORKERS}"
WORKER="${2:?}" WORKERS="${3:?}"
WORK_DIR="${SBOM_WORK_DIR:-work}"
[[ "${S3_ENDPOINT:-}" != http://* && "${S3_ENDPOINT:-}" != https://* ]] && S3_ENDPOINT="https://${S3_ENDPOINT:-}"

# Imports or generates <base>_spdx.json (+ companions) for one tag. Returns 1 on failure.
build_sbom() {
  local owner="$1" repo="$2" tag="$3" supplier="$4" base="$5" sbom_file="${5}_spdx.json" f fmt src
  sbom_import_release_assets "$owner" "$repo" "$tag" "$base"
  # A per-binary release SBOM is uploaded next to our scan, never instead of it.
  # Imported documents that cannot be normalised are dropped.
  for f in "${base}_release_spdx.json" "${base}_cdx.json" "${base}_release_cdx.json" "${base}_spdx3.json" "${base}_release_spdx3.json"; do
    [ -f "$f" ] || continue
    fmt="${f##*_}"; fmt="${fmt%.json}"
    bash "$SCRIPT_DIR/postprocess-${fmt}.sh" --owner "$owner" --repo "$repo" --tag "$tag" --project "$supplier" "$f" || rm -f "$f"
  done
  if [ -f "$sbom_file" ]; then
    if bash "$SCRIPT_DIR/postprocess-spdx.sh" --owner "$owner" --repo "$repo" --tag "$tag" --project "$supplier" "$sbom_file"; then
      echo "Successfully imported SBOM: $sbom_file"
      return 0
    fi
    echo "Release SPDX asset unusable, generating instead"
    rm -f "$sbom_file"
  fi

  echo "Generating SBOM for $owner/$repo@$tag..."
  src="$(mktemp -d)"
  if git clone --depth 1 --branch "$tag" "https://github.com/${owner}/${repo}.git" "$src" 2>/dev/null &&
     sbom_waybill_scan "$owner" "$repo" "$tag" "$src" "$sbom_file" 2>&1 | tail -5 &&
     bash "$SCRIPT_DIR/postprocess-spdx.sh" --owner "$owner" --repo "$repo" --tag "$tag" --project "$supplier" "$sbom_file"; then
    echo "Successfully generated SBOM: $sbom_file"
    rm -rf "$src"
    return 0
  fi
  echo "Failed to generate SBOM for $owner/$repo@$tag"
  rm -rf "$src" "$sbom_file"
  return 1
}

UPLOADED=0 FAILED=0 FAILED_ITEMS=()
while IFS=$'\x1f' read -r OWNER REPO TAG BUCKET KEY_PREFIX SUPPLIER; do
  VERSION="$(sbom_version_of_tag "$TAG")"
  DIR="${WORK_DIR}/${OWNER}/${REPO}/${VERSION}"
  BASE="${DIR}/${REPO}_${VERSION//./_}"
  echo "::group::${OWNER}/${REPO}@${TAG}"
  mkdir -p "$DIR"
  if build_sbom "$OWNER" "$REPO" "$TAG" "$SUPPLIER" "$BASE" &&
     out="$(upload_sbom_dir "${WORK_DIR}/${OWNER}/${REPO}" "$BUCKET" "$KEY_PREFIX" "$REPO")"; then
    echo "$out"
    UPLOADED=$((UPLOADED + $(sed -n 's/^Uploaded \([0-9]*\) .*/\1/p' <<<"$out")))
  else
    FAILED=$((FAILED + 1)); FAILED_ITEMS+=("${OWNER}/${REPO}@${TAG}")
    echo "::error title=sbom-failed::${OWNER}/${REPO}@${TAG}"
  fi
  rm -rf "${WORK_DIR}/${OWNER}/${REPO}"
  echo "::endgroup::"
done < <(awk -v w="$WORKER" -v n="$WORKERS" 'NR % n == w' "$PLAN" |
         jq -r '[.owner, .repo, .tag, .bucket, .key_prefix, .supplier] | join("\u001f")')  # supplier may be empty

if [ -n "${SBOM_RESULT_FILE:-}" ]; then
  mkdir -p "$(dirname "$SBOM_RESULT_FILE")"
  printf '%s\n' "${FAILED_ITEMS[@]+"${FAILED_ITEMS[@]}"}" | jq -R . | jq -sc --argjson up "$UPLOADED" '{uploaded: $up, failed: map(select(. != ""))}' >"$SBOM_RESULT_FILE"
fi
echo "Worker ${WORKER}/${WORKERS}: uploaded ${UPLOADED}, failed ${FAILED}"
[ "$FAILED" -eq 0 ]
