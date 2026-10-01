#!/usr/bin/env bash
#
# Moves subproject SBOMs from the legacy parent folder (the parent's repository
# name, e.g. "argo-cd") to the parent's project slug (e.g. "argo"), which is
# the folder the project's own SBOMs use in the project bucket:
#
#   argo-cd/argo-workflows/4.1.4/argo-cd_argo-workflows_4_1_4_spdx.json
#     -> argo/argo-workflows/4.1.4/argo_argo-workflows_4_1_4_spdx.json
#
# DRY-RUN BY DEFAULT: prints the plan and changes nothing. With --apply each
# object is copied server-side, the copy is verified (size and ETag) and only
# then the old key is deleted. Keys whose target already exists are reported
# as conflicts and left untouched.
#
# The mapping is derived from util/data/discovered-repos.yaml with the same
# functions the upload step uses (util/sbom-lib.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
APPLY="false"
LISTING=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--apply] [--listing FILE] [--bucket NAME] [--data-dir DIR]

  --apply          perform the moves (default: dry-run, print the plan only)
  --listing FILE   read object keys (one per line) from FILE instead of listing the bucket
  --bucket NAME    subproject bucket (default: \$SUBPROJECT_BUCKET or cncf-subproject-sboms)
  --data-dir DIR   directory with cncf-projects.yaml and discovered-repos.yaml (default: util/data)

Credentials and endpoint come from the environment, or from ${ROOT_DIR}/.env.sbom
if AWS_ACCESS_KEY_ID is not set:
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_ENDPOINT, S3_REGION, SUBPROJECT_BUCKET
EOF
}

# The environment takes precedence; .env.sbom is only read when no credentials are set.
if [[ -z "${AWS_ACCESS_KEY_ID:-}" && -f "${ROOT_DIR}/.env.sbom" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${ROOT_DIR}/.env.sbom"
  set +a
fi
BUCKET="${SUBPROJECT_BUCKET:-cncf-subproject-sboms}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="true"; shift ;;
    --listing) LISTING="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

export SBOM_PROJECTS_FILE="${DATA_DIR}/cncf-projects.yaml"
# shellcheck source=util/sbom-lib.sh
source "${SCRIPT_DIR}/sbom-lib.sh"
DISCOVERED_FILE="${DATA_DIR}/discovered-repos.yaml"

for tool in jq yq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Error: $tool is required" >&2; exit 1; }
done
[[ -f "$DISCOVERED_FILE" ]] || { echo "Error: not found: $DISCOVERED_FILE" >&2; exit 1; }

s3() {
  local endpoint="${S3_ENDPOINT:-}"
  [[ -z "$endpoint" || "$endpoint" == http://* || "$endpoint" == https://* ]] || endpoint="https://${endpoint}"
  AWS_PAGER="" AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    aws s3api "$@" ${endpoint:+--endpoint-url "$endpoint"} ${S3_REGION:+--region "$S3_REGION"}
}

# "<legacy-parent>/<repo-slug>" -> "<project-slug>" for every discovered repository.
declare -A NEW_PARENT TARGET_PAIR AMBIGUOUS
while IFS=$'\x1f' read -r owner repo parent_project parent_repo discovered_by; do
  [[ -n "$owner" && -n "$repo" ]] || continue
  repo_slug="$(sbom_slugify "$repo")"
  old="$(sbom_legacy_parent_slug "$discovered_by" "$owner")/${repo_slug}"
  new_parent="$(sbom_parent_slug "$parent_project" "$parent_repo" "$discovered_by" "$owner")"
  TARGET_PAIR["${new_parent}/${repo_slug}"]=1
  if [[ -n "${NEW_PARENT[$old]:-}" && "${NEW_PARENT[$old]}" != "$new_parent" ]]; then
    AMBIGUOUS["$old"]=1
  fi
  NEW_PARENT["$old"]="$new_parent"
done < <(yq -o=json '.repositories // []' "$DISCOVERED_FILE" |
    jq -r '.[] | [.owner, .repo, .parent_project // "", .parent_repo // "", .discovered_by // ""] | map(tostring) | join("\u001f")')

KEYS_FILE="$(mktemp)"
trap 'rm -f "$KEYS_FILE"' EXIT
if [[ -n "$LISTING" ]]; then
  grep -v '^[[:space:]]*$' "$LISTING" >"$KEYS_FILE" || true
else
  s3 list-objects-v2 --bucket "$BUCKET" --query 'Contents[].Key' --output json | jq -r '.[]?' >"$KEYS_FILE"
fi
declare -A EXISTS
while IFS= read -r key; do EXISTS["$key"]=1; done <"$KEYS_FILE"

encode_key() { jq -rn --arg k "$1" '$k | split("/") | map(@uri) | join("/")'; }

move_object() {
  local src="$1" dst="$2" src_meta dst_meta
  src_meta="$(s3 head-object --bucket "$BUCKET" --key "$src" --query '[ContentLength,ETag]' --output json)"
  s3 copy-object --bucket "$BUCKET" --key "$dst" --copy-source "${BUCKET}/$(encode_key "$src")" >/dev/null
  dst_meta="$(s3 head-object --bucket "$BUCKET" --key "$dst" --query '[ContentLength,ETag]' --output json)"
  if [[ "$(jq -c . <<<"$src_meta")" != "$(jq -c . <<<"$dst_meta")" ]]; then
    echo "Error: copy of ${src} does not match the source (${src_meta} vs ${dst_meta}); old key kept" >&2
    return 1
  fi
  s3 delete-object --bucket "$BUCKET" --key "$src" >/dev/null
}

moves=0 unchanged=0 conflicts=0 unknown=0 ambiguous=0 failed=0
declare -A PARENT_MOVES
while IFS= read -r key; do
  IFS='/' read -r p1 p2 rest <<<"$key"
  pair="${p1}/${p2}"
  if [[ -z "$p2" || -z "$rest" || -z "${NEW_PARENT[$pair]:-}" ]]; then
    if [[ -z "${TARGET_PAIR[$pair]:-}" ]]; then
      echo "UNKNOWN   ${key} (not a discovered repository; left in place)"
      unknown=$((unknown + 1))
    else
      unchanged=$((unchanged + 1))
    fi
    continue
  fi
  new_parent="${NEW_PARENT[$pair]}"
  if [[ "$new_parent" == "$p1" ]]; then
    unchanged=$((unchanged + 1))
    continue
  fi
  if [[ -n "${AMBIGUOUS[$pair]:-}" || -n "${TARGET_PAIR[$pair]:-}" ]]; then
    echo "AMBIGUOUS ${key} (${pair} maps to more than one project; left in place)"
    ambiguous=$((ambiguous + 1))
    continue
  fi

  file="${rest##*/}"
  dir="${rest%"$file"}"
  [[ "$file" == "${p1}_"* ]] && file="${new_parent}_${file#"${p1}_"}"
  target="${new_parent}/${p2}/${dir}${file}"

  if [[ -n "${EXISTS[$target]:-}" ]]; then
    echo "CONFLICT  ${key} -> ${target} (target exists; both left in place)"
    conflicts=$((conflicts + 1))
    continue
  fi

  echo "MOVE      ${key} -> ${target}"
  PARENT_MOVES["${p1} -> ${new_parent}"]=$(( ${PARENT_MOVES["${p1} -> ${new_parent}"]:-0} + 1 ))
  moves=$((moves + 1))
  if [[ "$APPLY" == "true" ]]; then
    if ! move_object "$key" "$target"; then
      failed=$((failed + 1))
    fi
  fi
done < <(sort "$KEYS_FILE")

echo
echo "Parent folder changes:"
for change in "${!PARENT_MOVES[@]}"; do
  printf '  %-60s %5d objects\n' "$change" "${PARENT_MOVES[$change]}"
done | sort
echo
echo "Summary for s3://${BUCKET}/ ($([[ "$APPLY" == "true" ]] && echo applied || echo "dry-run, nothing changed")):"
echo "  move:      ${moves}"
echo "  unchanged: ${unchanged}"
echo "  conflict:  ${conflicts}"
echo "  ambiguous: ${ambiguous}"
echo "  unknown:   ${unknown}"
[[ "$APPLY" == "true" ]] && echo "  failed:    ${failed}"
[[ "$failed" -eq 0 ]]
