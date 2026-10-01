#!/usr/bin/env bash
#
# Project and subproject SBOMs of the same CNCF project must share one folder
# slug, whichever path writes them: both workflow upload steps and the ingest
# script. Uses the checked-in util/data files.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# shellcheck source=util/sbom-lib.sh
source "$ROOT_DIR/util/sbom-lib.sh"

# 1. Slug function, cases shared with util/generate-index (Go).
while IFS=$'\t' read -r name slug; do
  if [[ "$(sbom_slugify "$name")" != "$slug" ]]; then
    echo "sbom_slugify '$name' = '$(sbom_slugify "$name")', want '$slug'" >&2
    exit 1
  fi
done <"$ROOT_DIR/util/tests/data/slug-cases.tsv"

# 2. Parent resolution order: parent_project, parent_repo/discovered_by lookup, legacy.
[[ "$(sbom_parent_slug "Argo" "" "org-scan from argoproj/argo-cd" argoproj)" == argo ]]
[[ "$(sbom_parent_slug "" "argoproj/argo-cd" "" argoproj)" == argo ]]
[[ "$(sbom_parent_slug "" "" "org-scan from argoproj/argo-cd" argoproj)" == argo ]]
[[ "$(sbom_parent_slug "" "" "org-scan from Aeraki-Mesh/Aeraki" aeraki-mesh)" == aeraki-mesh ]]
[[ "$(sbom_resolve_parent_project "" "" "org-scan from aeraki-mesh/aeraki" aeraki-mesh)" == "Aeraki Mesh" ]]
[[ "$(sbom_parent_slug "" "" "org-scan from example/not-a-project" example)" == not-a-project ]]
[[ "$(sbom_parent_slug "" "" "" Some-Owner)" == some-owner ]]
[[ -z "$(sbom_resolve_parent_project "" "" "org-scan from example/not-a-project" example)" ]]
[[ "$(sbom_legacy_parent_slug "org-scan from argoproj/argo-cd" argoproj)" == argo-cd ]]
[[ "$(sbom_legacy_parent_slug "org-scan from aeraki-mesh/aeraki" aeraki-mesh)" == aeraki ]]
# The checked-in discovery data records the parents.
[[ "$(yq -r '.repositories[] | select(.owner == "argoproj" and .repo == "argo-workflows") | .parent_project' \
  "$ROOT_DIR/util/data/discovered-repos.yaml")" == Argo ]]
[[ "$(yq -r '.repositories[] | select(.owner == "aeraki-mesh" and .repo == "meta-protocol-proxy") | .parent_project' \
  "$ROOT_DIR/util/data/discovered-repos.yaml")" == "Aeraki Mesh" ]]

# 3. Keys written by the workflow upload steps.
ln -s "$ROOT_DIR/util" "$TEMP_DIR/util"
export S3_ENDPOINT="https://storage.example" S3_REGION="us-east-1"
export PROJECT_BUCKET="cncf-project-sboms" SUBPROJECT_BUCKET="cncf-subproject-sboms"
export GITHUB_OUTPUT="$TEMP_DIR/output" UPLOAD_LOG="$TEMP_DIR/uploads"
# shellcheck disable=SC2317 # stub, invoked by the workflow steps
aws() {
  local bucket="" key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bucket) bucket="$2"; shift ;;
      --key) key="$2"; shift ;;
    esac
    shift
  done
  printf '%s/%s\n' "$bucket" "$key" >>"$UPLOAD_LOG"
}
export -f aws

# Arguments: workflow owner repo name prefix [env assignments...]
upload_keys() {
  local workflow="$1" owner="$2" repo="$3" name="$4" prefix="$5"
  shift 5
  : >"$UPLOAD_LOG"
  rm -rf "$TEMP_DIR/sbom"
  local base
  base="sbom/$(sbom_slugify "$name")/$repo"
  [[ -n "$prefix" ]] && base="sbom/$prefix/$owner/$repo"
  mkdir -p "$TEMP_DIR/$base/1.0.0"
  echo '{}' >"$TEMP_DIR/$base/1.0.0/sbom.json"
  yq -r '.jobs[].steps[]? | select(.id == "upload") | .run' "$ROOT_DIR/.github/workflows/$workflow" |
    sed -e "s/\${{ matrix.owner }}/$owner/g" -e "s/\${{ matrix.repo }}/$repo/g" -e "s/\${{ matrix.name }}/$name/g" |
    (cd "$TEMP_DIR" && env SBOM_PATH_PREFIX="$prefix" MATRIX_PARENT_PROJECT="" MATRIX_PARENT_REPO="" \
      MATRIX_DISCOVERED_BY="" "$@" bash -e) >/dev/null
  cat "$UPLOAD_LOG"
}

[[ "$(upload_keys generate-sbom.yml argoproj argo-cd Argo "")" == \
  "cncf-project-sboms/argo/1.0.0/argo_1_0_0_spdx.json" ]]
[[ "$(upload_keys generate-sbom.yml aeraki-mesh aeraki "Aeraki Mesh" "")" == \
  "cncf-project-sboms/aeraki-mesh/1.0.0/aeraki-mesh_1_0_0_spdx.json" ]]
[[ "$(upload_keys reusable-generate-sbom.yml argoproj argo-workflows argo-workflows subprojects \
  MATRIX_PARENT_PROJECT=Argo MATRIX_PARENT_REPO=argoproj/argo-cd \
  "MATRIX_DISCOVERED_BY=org-scan from argoproj/argo-cd")" == \
  "cncf-subproject-sboms/argo/argo-workflows/1.0.0/argo_argo-workflows_1_0_0_spdx.json" ]]
# Without parent_project the parent comes from discovered_by + cncf-projects.yaml.
[[ "$(upload_keys reusable-generate-sbom.yml aeraki-mesh meta-protocol-proxy meta-protocol-proxy subprojects \
  "MATRIX_DISCOVERED_BY=org-scan from aeraki-mesh/aeraki")" == \
  "cncf-subproject-sboms/aeraki-mesh/meta-protocol-proxy/1.0.0/aeraki-mesh_meta-protocol-proxy_1_0_0_spdx.json" ]]
# Unknown parent: previous behaviour (parent repository name).
[[ "$(upload_keys reusable-generate-sbom.yml example tool tool subprojects \
  "MATRIX_DISCOVERED_BY=org-scan from example/not-a-project")" == \
  "cncf-subproject-sboms/not-a-project/tool/1.0.0/not-a-project_tool_1_0_0_spdx.json" ]]

# 4. Keys written by util/ingest-sbom-oci.sh (dry-run; post-processes a copy).
mkdir -p "$TEMP_DIR/ingest/argo/argo-cd/3.3.14" "$TEMP_DIR/ingest/subprojects/argoproj/argo-workflows/4.1.4" \
  "$TEMP_DIR/ingest/subprojects/alibaba/Alink/1.6.2"
fixture="$ROOT_DIR/util/tests/data/kagent-v0.10.0-waybill.spdx.json"
cp "$fixture" "$TEMP_DIR/ingest/argo/argo-cd/3.3.14/argo_3_3_14_spdx.json"
cp "$fixture" "$TEMP_DIR/ingest/subprojects/argoproj/argo-workflows/4.1.4/argo-workflows_4_1_4_spdx.json"
cp "$fixture" "$TEMP_DIR/ingest/subprojects/alibaba/Alink/1.6.2/Alink_1_6_2_spdx.json"
aws() { return 1; } # head-object: nothing exists yet
export -f aws
bash "$ROOT_DIR/util/ingest-sbom-oci.sh" --source-dir "$TEMP_DIR/ingest" --auth-mode s3 \
  --s3-endpoint https://storage.example --s3-access-key x --s3-secret-key y \
  --project-bucket cncf-project-sboms --subproject-bucket cncf-subproject-sboms --dry-run >"$TEMP_DIR/ingest.log"
grep -q '^DRY-RUN: oci://cncf-project-sboms/argo/3.3.14/argo_3_3_14_spdx.json <- ' "$TEMP_DIR/ingest.log"
grep -q '^DRY-RUN: oci://cncf-subproject-sboms/argo/argo-workflows/4.1.4/argo_argo-workflows_4_1_4_spdx.json <- ' \
  "$TEMP_DIR/ingest.log"
# Parent no longer in the landscape (empty parent_project): legacy folder.
grep -q '^DRY-RUN: oci://cncf-subproject-sboms/higress/alink/1.6.2/higress_alink_1_6_2_spdx.json <- ' "$TEMP_DIR/ingest.log"
grep -q 'Failed: 0' "$TEMP_DIR/ingest.log"
cmp "$fixture" "$TEMP_DIR/ingest/argo/argo-cd/3.3.14/argo_3_3_14_spdx.json"

echo "SBOM naming tests passed"
