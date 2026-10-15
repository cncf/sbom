#!/usr/bin/env bash
#
# Project and subproject SBOMs of the same CNCF project must share one folder
# slug, whichever path writes them: both workflow upload steps and the ingest
# script. Uses the checked-in util/data files.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
trap 'echo "FAILED line $LINENO: $BASH_COMMAND" >&2' ERR

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
  echo '{}' >"$TEMP_DIR/$base/1.0.0/${repo}_1_0_0_spdx.json"
  echo '{}' >"$TEMP_DIR/$base/1.0.0/${repo}_1_0_0_release_cdx.json"
  yq -r '.jobs[].steps[]? | select(.id == "upload") | .run' "$ROOT_DIR/.github/workflows/$workflow" |
    sed -e "s/\${{ matrix.owner }}/$owner/g" -e "s/\${{ matrix.repo }}/$repo/g" -e "s/\${{ matrix.name }}/$name/g" |
    (cd "$TEMP_DIR" && env SBOM_PATH_PREFIX="$prefix" MATRIX_PARENT_PROJECT="" MATRIX_PARENT_REPO="" \
      MATRIX_DISCOVERED_BY="" "$@" bash -e) >/dev/null
  cat "$UPLOAD_LOG"
}

# The format suffix (spdx / spdx3 / cdx) of the local file carries over to the key.
[[ "$(upload_keys reusable-generate-sbom.yml argoproj argo-cd Argo "")" == \
  "cncf-project-sboms/argo/1.0.0/argo_1_0_0_release_cdx.json
cncf-project-sboms/argo/1.0.0/argo_1_0_0_spdx.json" ]]
[[ "$(upload_keys reusable-generate-sbom.yml aeraki-mesh aeraki "Aeraki Mesh" "")" == \
  "cncf-project-sboms/aeraki-mesh/1.0.0/aeraki-mesh_1_0_0_release_cdx.json
cncf-project-sboms/aeraki-mesh/1.0.0/aeraki-mesh_1_0_0_spdx.json" ]]
[[ "$(upload_keys reusable-generate-sbom.yml argoproj argo-workflows argo-workflows subprojects \
  MATRIX_PARENT_PROJECT=Argo MATRIX_PARENT_REPO=argoproj/argo-cd \
  "MATRIX_DISCOVERED_BY=org-scan from argoproj/argo-cd")" == \
  "cncf-subproject-sboms/argo/argo-workflows/1.0.0/argo_argo-workflows_1_0_0_release_cdx.json
cncf-subproject-sboms/argo/argo-workflows/1.0.0/argo_argo-workflows_1_0_0_spdx.json" ]]
# Without parent_project the parent comes from discovered_by + cncf-projects.yaml.
[[ "$(upload_keys reusable-generate-sbom.yml aeraki-mesh meta-protocol-proxy meta-protocol-proxy subprojects \
  "MATRIX_DISCOVERED_BY=org-scan from aeraki-mesh/aeraki")" == \
  "cncf-subproject-sboms/aeraki-mesh/meta-protocol-proxy/1.0.0/aeraki-mesh_meta-protocol-proxy_1_0_0_release_cdx.json
cncf-subproject-sboms/aeraki-mesh/meta-protocol-proxy/1.0.0/aeraki-mesh_meta-protocol-proxy_1_0_0_spdx.json" ]]
# Unknown parent: previous behaviour (parent repository name).
[[ "$(upload_keys reusable-generate-sbom.yml example tool tool subprojects \
  "MATRIX_DISCOVERED_BY=org-scan from example/not-a-project")" == \
  "cncf-subproject-sboms/not-a-project/tool/1.0.0/not-a-project_tool_1_0_0_release_cdx.json
cncf-subproject-sboms/not-a-project/tool/1.0.0/not-a-project_tool_1_0_0_spdx.json" ]]

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

# 5. Release assets: format by content, project-wide beats per-arch, largest per format wins,
#    oversize assets are skipped, 404 (tag without release) is quiet.
mkdir -p "$TEMP_DIR/assets"
echo '{"spdxVersion":"SPDX-2.3","packages":[]}' >"$TEMP_DIR/assets/big.spdx.json"
echo '{"spdxVersion":"SPDX-2.2"}' >"$TEMP_DIR/assets/small.spdx.json"
echo '{"spdxVersion":"SPDX-2.3","packages":[{},{}]}' >"$TEMP_DIR/assets/tool-linux-amd64.spdx.json"
echo '{"bomFormat":"CycloneDX","specVersion":"1.5"}' >"$TEMP_DIR/assets/bom.json"
echo '{"bomFormat":"CycloneDX","specVersion":"1.6","components":[{}]}' >"$TEMP_DIR/assets/tool_linux_amd64.cdx.json"
echo '{"@context":"https://spdx.org/rdf/3.0.1/spdx-context.jsonld","@graph":[]}' >"$TEMP_DIR/assets/x.spdx3.json"
echo '{"checksums":{}}' >"$TEMP_DIR/assets/notes-sbom.json"
[[ "$(sbom_format_of "$TEMP_DIR/assets/big.spdx.json")" == spdx ]]
[[ "$(sbom_format_of "$TEMP_DIR/assets/bom.json")" == cdx ]]
[[ "$(sbom_format_of "$TEMP_DIR/assets/x.spdx3.json")" == spdx3 ]]
[[ -z "$(sbom_format_of "$TEMP_DIR/assets/notes-sbom.json")" ]]
[[ -z "$(sbom_format_of "$ROOT_DIR/util/tests/data/slug-cases.tsv")" ]]
# shellcheck disable=SC2317
asset() { printf '{"name":"%s","size":%s,"browser_download_url":"file://%s/assets/%s"}' "$1" "$2" "$TEMP_DIR" "$1"; }
RELEASE_JSON="{\"assets\":[$(asset tool-linux-amd64.spdx.json 900),$(asset big.spdx.json 100),$(asset huge.spdx.json 200000000),
  $(asset notes-sbom.json 500),$(asset x.spdx3.json 50),$(asset small.spdx.json 10),$(asset bom.json 20),$(asset tool_linux_amd64.cdx.json 2000),$(asset tool.tar.gz 999999)]}"
# shellcheck disable=SC2317
gh() {
  if [[ "$2" == */releases/tags/v1.0.0 ]]; then
    jq -r "$4" <<<"$RELEASE_JSON"
  else
    echo "gh: Not Found (HTTP 404)" >&2; return 1
  fi
}
export -f gh
mkdir -p "$TEMP_DIR/out"
sbom_import_release_assets example tool v1.0.0 "$TEMP_DIR/out/tool_1_0_0" >/dev/null
[[ "$(ls "$TEMP_DIR/out" | LC_ALL=C sort | tr '\n' ' ')" == "tool_1_0_0_cdx.json tool_1_0_0_spdx.json tool_1_0_0_spdx3.json " ]]
# Only per-arch SPDX assets: kept as *_release_spdx.json so our own scan still runs.
RELEASE_JSON="{\"assets\":[$(asset tool-linux-amd64.spdx.json 900)]}"
sbom_import_release_assets example tool v1.0.0 "$TEMP_DIR/out/arch_1_0_0" >/dev/null
[[ "$(ls "$TEMP_DIR/out" | grep arch_ | tr '\n' ' ')" == "arch_1_0_0_release_spdx.json " ]]
cmp -s "$TEMP_DIR/assets/big.spdx.json" "$TEMP_DIR/out/tool_1_0_0_spdx.json"
sbom_import_release_assets example tool v9.9.9 "$TEMP_DIR/out/none" 2>"$TEMP_DIR/import.err"
[[ ! -s "$TEMP_DIR/import.err" ]]
[[ ! -e "$TEMP_DIR/out/none_spdx.json" ]]

# 6. Tag selection and versions.
[[ "$(sbom_version_of_tag kustomize/v5.8.3)" == 5.8.3 ]]
[[ "$(sbom_version_of_tag v1.2.3)" == 1.2.3 ]]
[[ "$(sbom_version_of_tag 1.2.3)" == 1.2.3 ]]
SINCE="2026-09-01T00:00:00Z"
# shellcheck disable=SC2317
gh() {
  case "$2" in
    repos/example/tool/releases/tags/chart-test-tools-1.0.0)
      jq -r "$4" <<<"{\"assets\":[$(asset bom.json 20)]}" ;;
    */releases/tags/*) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
    repos/example/tool/releases*) echo '[
      {"tag_name":"v2.0.0-rc1","draft":false,"prerelease":false,"published_at":"2026-10-10T00:00:00Z"},
      {"tag_name":"v2.0.0","draft":false,"prerelease":false,"published_at":"2026-10-01T00:00:00Z"},
      {"tag_name":"v1.9.1","draft":true,"prerelease":false,"published_at":"2026-09-20T00:00:00Z"},
      {"tag_name":"chart-test-tools-1.0.0","draft":false,"prerelease":false,"published_at":"2026-09-10T00:00:00Z"},
      {"tag_name":"v1.8.0","draft":false,"prerelease":false,"published_at":"2026-01-01T00:00:00Z"}]' ;;
    repos/example/tagsonly/releases*) echo '[]' ;;
    repos/example/tagsonly/tags*) echo '[{"name":"kustomize/v5.8.3"},{"name":"v5.7.0-beta.1"},{"name":"latest"},{"name":"v5.7.0"},{"name":"v5.6.0"}]' ;;
    repos/example/gone/*) echo '{"message":"Not Found","status":"404"}'; return 1 ;;
    *) echo '{"message":"boom","status":"500"}'; return 1 ;;
  esac
}
export -f gh
[[ "$(sbom_stable_tags example tool recent "$SINCE" 3 | tr '\n' ' ')" == "v2.0.0 chart-test-tools-1.0.0 " ]]
[[ "$(sbom_stable_tags example tool all "" 3 | tr '\n' ' ')" == "v2.0.0 chart-test-tools-1.0.0 v1.8.0 " ]]
[[ "$(sbom_stable_tags example tagsonly recent "$SINCE" 2 | tr '\n' ' ')" == "kustomize/v5.8.3 v5.7.0 " ]]
[[ -z "$(sbom_stable_tags example gone recent "$SINCE" 3 2>/dev/null)" ]]
! sbom_stable_tags example broken recent "$SINCE" 3 2>/dev/null

# 7. Generate step: skips what the bucket has, imports or generates the rest, slash tags get a flat version.
# shellcheck disable=SC2317
aws() { printf 'example/2.0.0/example_2_0_0_spdx.json\texample/0.1.0/example_0_1_0_spdx.json\n'; }
# shellcheck disable=SC2317
git() { mkdir -p "${@: -1}"; }
# shellcheck disable=SC2317
waybill() {
  while [[ $# -gt 0 ]]; do [[ "$1" == --output ]] && cp "$ROOT_DIR/util/tests/data/kagent-v0.10.0-waybill.spdx.json" "$2"; shift; done
}
export -f aws git waybill asset
export TEMP_DIR
export ROOT_DIR
run_generate() {
  rm -rf "$TEMP_DIR/sbom"
  yq -r '.jobs[].steps[]? | select(.id == "generate") | .run' "$ROOT_DIR/.github/workflows/reusable-generate-sbom.yml" |
    sed -e "s/\${{ matrix.owner }}/example/g" -e "s/\${{ matrix.repo }}/$1/g" -e "s/\${{ matrix.name }}/Example/g" |
    (cd "$TEMP_DIR" && env SBOM_PATH_PREFIX="" MATRIX_PARENT_PROJECT="" MATRIX_PARENT_REPO="" MATRIX_DISCOVERED_BY="" \
      FORCE_REGENERATE=false RELEASES_MODE=recent MAX_RELEASES=3 bash) >"$TEMP_DIR/generate.log" 2>&1
  (cd "$TEMP_DIR/sbom" && find . -type f | LC_ALL=C sort | tr '\n' ' ')
}
# v2.0.0 is in the bucket; the release ships only a CycloneDX asset, so Waybill scans and the CDX is normalised next to it.
[[ "$(run_generate tool)" == "./example/tool/chart-test-tools-1.0.0/tool_chart-test-tools-1_0_0_cdx.json ./example/tool/chart-test-tools-1.0.0/tool_chart-test-tools-1_0_0_spdx.json " ]]
[[ "$(jq -r '.metadata.component.name + " " + .metadata.component.version + " " + .metadata.supplier.name' \
  "$TEMP_DIR/sbom/example/tool/chart-test-tools-1.0.0/tool_chart-test-tools-1_0_0_cdx.json")" == "example/tool chart-test-tools-1.0.0 Example" ]]
grep -q 'example/tool@v2.0.0 already in bucket' "$TEMP_DIR/generate.log"
grep -q '^processed=1$' "$GITHUB_OUTPUT"
[[ "$(run_generate tagsonly)" == "./example/tagsonly/5.6.0/tagsonly_5_6_0_spdx.json ./example/tagsonly/5.7.0/tagsonly_5_7_0_spdx.json ./example/tagsonly/5.8.3/tagsonly_5_8_3_spdx.json " ]]
jq -e '.packages[0].externalRefs[] | select(.referenceType == "purl" and .referenceLocator == "pkg:github/example/tagsonly@kustomize%2Fv5.8.3")' \
  "$TEMP_DIR/sbom/example/tagsonly/5.8.3/tagsonly_5_8_3_spdx.json" >/dev/null

echo "SBOM naming tests passed"
