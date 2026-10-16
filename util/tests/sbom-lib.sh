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

# 3. Keys written by the worker: the plan decides bucket and folder, upload_sbom_dir the file name.
ln -s "$ROOT_DIR/util" "$TEMP_DIR/util"
export S3_ENDPOINT="https://storage.example" S3_REGION="us-east-1"
export PROJECT_BUCKET="cncf-project-sboms" SUBPROJECT_BUCKET="cncf-subproject-sboms"
export GITHUB_OUTPUT="$TEMP_DIR/output" UPLOAD_LOG="$TEMP_DIR/uploads"
# shellcheck source=util/s3-upload.sh
source "$ROOT_DIR/util/s3-upload.sh"
# shellcheck disable=SC2317 # stub, invoked by the upload helper
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

# Arguments: bucket key_prefix repo
upload_keys() {
  : >"$UPLOAD_LOG"
  rm -rf "$TEMP_DIR/work"
  mkdir -p "$TEMP_DIR/work/1.0.0"
  echo '{}' >"$TEMP_DIR/work/1.0.0/${3}_1_0_0_spdx.json"
  echo '{}' >"$TEMP_DIR/work/1.0.0/${3}_1_0_0_release_cdx.json"
  upload_sbom_dir "$TEMP_DIR/work" "$1" "$2" "$3" >/dev/null
  cat "$UPLOAD_LOG"
}
# The format suffix (spdx / spdx3 / cdx) of the local file carries over to the key.
[[ "$(upload_keys cncf-project-sboms argo/ argo-cd)" == \
  "cncf-project-sboms/argo/1.0.0/argo_1_0_0_release_cdx.json
cncf-project-sboms/argo/1.0.0/argo_1_0_0_spdx.json" ]]
[[ "$(upload_keys cncf-subproject-sboms argo/argo-workflows/ argo-workflows)" == \
  "cncf-subproject-sboms/argo/argo-workflows/1.0.0/argo_argo-workflows_1_0_0_release_cdx.json
cncf-subproject-sboms/argo/argo-workflows/1.0.0/argo_argo-workflows_1_0_0_spdx.json" ]]

# Plan: folder per bucket from the checked-in data (parent_project, discovered_by lookup, legacy).
mkdir -p "$TEMP_DIR/data"
cp "$ROOT_DIR/util/data/cncf-projects.yaml" "$TEMP_DIR/data/"
printf 'repositories:\n  - owner: Example\n    repo: Tool\n    name: Example Tool\n' >"$TEMP_DIR/data/repositories.yaml"
cat >"$TEMP_DIR/data/discovered-repos.yaml" <<'YAML'
repositories:
  - owner: argoproj
    repo: argo-workflows
    name: argo-workflows
    parent_project: Argo
    parent_repo: argoproj/argo-cd
    discovered_by: org-scan from argoproj/argo-cd
  - owner: aeraki-mesh
    repo: meta-protocol-proxy
    name: meta-protocol-proxy
    discovered_by: org-scan from aeraki-mesh/aeraki
  - owner: example
    repo: tool
    name: tool
    discovered_by: org-scan from example/not-a-project
YAML
# shellcheck disable=SC2317 # stubs for the plan: every repo has one release, buckets are empty
gh() { jq -n '{data: {r0: {releases: {nodes: [{tagName: "v1.0.0", isDraft: false, isPrerelease: false, publishedAt: "2099-01-01T00:00:00Z"}]}, refs: {nodes: []}},
                      r1: {releases: {nodes: [{tagName: "v1.0.0", isDraft: false, isPrerelease: false, publishedAt: "2099-01-01T00:00:00Z"}]}, refs: {nodes: []}},
                      r2: {releases: {nodes: [{tagName: "v1.0.0", isDraft: false, isPrerelease: false, publishedAt: "2099-01-01T00:00:00Z"}]}, refs: {nodes: []}}}}'; }
# shellcheck disable=SC2317
aws() { echo None; }
export -f gh aws
SBOM_DATA_DIR="$TEMP_DIR/data" PROJECT_SOURCE=discovered bash "$ROOT_DIR/util/sbom-plan.sh" "$TEMP_DIR/plan.jsonl" >/dev/null 2>&1
[[ "$(jq -r '"\(.bucket)/\(.key_prefix) \(.supplier)"' "$TEMP_DIR/plan.jsonl" | tr '\n' ';')" == \
  "cncf-subproject-sboms/argo/argo-workflows/ Argo;cncf-subproject-sboms/aeraki-mesh/meta-protocol-proxy/ Aeraki Mesh;cncf-subproject-sboms/not-a-project/tool/ ;" ]]
SBOM_DATA_DIR="$TEMP_DIR/data" PROJECT_SOURCE=manual bash "$ROOT_DIR/util/sbom-plan.sh" "$TEMP_DIR/plan.jsonl" >/dev/null 2>&1
[[ "$(jq -r '"\(.bucket)/\(.key_prefix) \(.supplier) \(.owner)/\(.repo)@\(.tag)"' "$TEMP_DIR/plan.jsonl")" == \
  "cncf-project-sboms/example-tool/ Example Tool Example/Tool@v1.0.0" ]]

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
  elif [[ "$2" == */releases/tags/v4.0.3 ]]; then
    echo "gh: API rate limit exceeded (HTTP 403)" >&2; return 1
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
# Any other API error (rate limit) fails the import so the item is retried, not silently scanned.
if sbom_import_release_assets example tool v4.0.3 "$TEMP_DIR/out/limited" 2>"$TEMP_DIR/import.err"; then echo "expected failure at line $LINENO" >&2; exit 1; fi
grep -q '::warning::Release lookup for example/tool@v4.0.3 failed' "$TEMP_DIR/import.err"

# 6. Tag selection and versions.
[[ "$(sbom_version_of_tag v5.8.3)" == 5.8.3 ]]
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
      {"tag_name":"pkg/app/plugin/kubernetes/v0.1.0","draft":false,"prerelease":false,"published_at":"2026-09-05T00:00:00Z"},
      {"tag_name":"opentelemetry-util-genai==1.2.0","draft":false,"prerelease":false,"published_at":"2026-09-04T00:00:00Z"},
      {"tag_name":"v1.9.0b1","draft":false,"prerelease":false,"published_at":"2026-09-03T00:00:00Z"},
      {"tag_name":"v1.9.0-rc2+k3s1","draft":false,"prerelease":false,"published_at":"2026-09-02T00:00:00Z"},
      {"tag_name":"v1.8.0","draft":false,"prerelease":false,"published_at":"2026-01-01T00:00:00Z"}]' ;;
    repos/example/tagsonly/releases*) echo '[]' ;;
    repos/example/tagsonly/tags*) echo '[{"name":"kustomize/v5.8.3"},{"name":"v5.7.0-beta.1"},{"name":"latest"},{"name":"v5.7.0"},{"name":"v5.6.0"},{"name":"v5.5.0"}]' ;;
    repos/example/gone/*) echo '{"message":"Not Found","status":"404"}'; return 1 ;;
    *) echo '{"message":"boom","status":"500"}'; return 1 ;;
  esac
}
export -f gh
[[ "$(sbom_stable_tags example tool recent "$SINCE" 3 | tr '\n' ' ')" == "v2.0.0 chart-test-tools-1.0.0 " ]]
[[ "$(sbom_stable_tags example tool all "" 3 | tr '\n' ' ')" == "v2.0.0 chart-test-tools-1.0.0 v1.8.0 " ]]
[[ "$(sbom_stable_tags example tagsonly recent "$SINCE" 2 | tr '\n' ' ')" == "v5.7.0 v5.6.0 " ]]
[[ -z "$(sbom_stable_tags example gone recent "$SINCE" 3 2>/dev/null)" ]]
! sbom_stable_tags example broken recent "$SINCE" 3 2>/dev/null

# 7. Plan + worker end to end: the plan skips what the bucket has and nested tags,
#    the worker imports or generates its share, normalises and uploads.
# shellcheck disable=SC2317
gh_graphql() { jq -n '{data: {
  r0: null,
  r2: {releases: {nodes: [
        {tagName: "v2.0.0-rc1", isDraft: false, isPrerelease: false, publishedAt: "2026-10-10T00:00:00Z"},
        {tagName: "v2.0.0", isDraft: false, isPrerelease: false, publishedAt: "2099-10-01T00:00:00Z"},
        {tagName: "v1.9.1", isDraft: true, isPrerelease: false, publishedAt: "2099-09-20T00:00:00Z"},
        {tagName: "chart-test-tools-1.0.0", isDraft: false, isPrerelease: false, publishedAt: "2099-09-10T00:00:00Z"},
        {tagName: "pkg/app/plugin/kubernetes/v0.1.0", isDraft: false, isPrerelease: false, publishedAt: "2099-09-05T00:00:00Z"},
        {tagName: "opentelemetry-util-genai==1.2.0", isDraft: false, isPrerelease: false, publishedAt: "2099-09-04T00:00:00Z"},
        {tagName: "v1.9.0b1", isDraft: false, isPrerelease: false, publishedAt: "2099-09-03T00:00:00Z"},
        {tagName: "v1.9.0-rc2+k3s1", isDraft: false, isPrerelease: false, publishedAt: "2099-09-02T00:00:00Z"},
        {tagName: "v1.8.0", isDraft: false, isPrerelease: false, publishedAt: "2026-01-01T00:00:00Z"}]}, refs: {nodes: []}},
  r1: {releases: {nodes: []}, refs: {nodes: [{name: "kustomize/v5.8.3"}, {name: "v5.7.0-beta.1"}, {name: "latest"}, {name: "v5.7.0"}, {name: "v5.6.0"}, {name: "v5.5.0"}]}}},
  errors: [{path: ["r0"], message: "Could not resolve to a Repository"}]}'; return 1; }  # real gh exits 1 on partial errors; repos come sorted: gone, tagsonly, tool
# gh serves GraphQL for the plan and REST release assets for the worker.
# shellcheck disable=SC2317
gh_rest() {
  case "$2" in
    repos/example/tool/releases/tags/chart-test-tools-1.0.0) jq -r "$4" <<<"{\"assets\":[$(asset bom.json 20)]}" ;;
    *) echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
  esac
}
# shellcheck disable=SC2317
gh() { if [[ "$2" == graphql ]]; then gh_graphql; else gh_rest "$@"; fi; }
# shellcheck disable=SC2317
aws_stub() {
  case "$*" in
    *list-objects-v2*) printf 'example/2.0.0/example_2_0_0_spdx.json\texample/0.1.0/example_0_1_0_spdx.json\n' ;;
    *) local bucket="" key=""; while [[ $# -gt 0 ]]; do case "$1" in --bucket) bucket="$2"; shift ;; --key) key="$2"; shift ;; esac; shift; done
       printf '%s/%s\n' "$bucket" "$key" >>"$UPLOAD_LOG" ;;
  esac
}
# shellcheck disable=SC2317
git() { mkdir -p "${@: -1}"; }
# shellcheck disable=SC2317
waybill() {
  while [[ $# -gt 0 ]]; do [[ "$1" == --output ]] && cp "$ROOT_DIR/util/tests/data/kagent-v0.10.0-waybill.spdx.json" "$2"; shift; done
}
aws() { aws_stub "$@"; }
export -f gh gh_graphql gh_rest aws aws_stub git waybill asset
export TEMP_DIR ROOT_DIR
printf 'repositories:\n  - {owner: example, repo: tool, name: Example}\n  - {owner: example, repo: tagsonly, name: Example}\n  - {owner: example, repo: gone, name: Example}\n' >"$TEMP_DIR/data/repositories.yaml"
rm -f "$TEMP_DIR/data/discovered-repos.yaml"
SBOM_DATA_DIR="$TEMP_DIR/data" PROJECT_SOURCE=manual bash "$ROOT_DIR/util/sbom-plan.sh" "$TEMP_DIR/plan.jsonl" >"$TEMP_DIR/plan.out" 2>"$TEMP_DIR/plan.err"
grep -q '^items=4$' "$TEMP_DIR/plan.out"
grep -q '::warning::r0: Could not resolve' "$TEMP_DIR/plan.err"
# v2.0.0 is in the bucket, rc/draft/nested/old tags are out; tags-only repos get their newest 3 semver tags.
[[ "$(jq -r '"\(.repo)@\(.tag)"' "$TEMP_DIR/plan.jsonl" | tr '\n' ' ')" == \
  "tagsonly@v5.7.0 tagsonly@v5.6.0 tagsonly@v5.5.0 tool@chart-test-tools-1.0.0 " ]]
SBOM_DATA_DIR="$TEMP_DIR/data" PROJECT_SOURCE=manual RELEASES_MODE=latest MAX_RELEASES=2 bash "$ROOT_DIR/util/sbom-plan.sh" "$TEMP_DIR/latest.jsonl" >/dev/null 2>&1
[[ "$(jq -r '"\(.repo)@\(.tag)"' "$TEMP_DIR/latest.jsonl" | tr '\n' ' ')" == "tagsonly@v5.7.0 tagsonly@v5.6.0 tool@chart-test-tools-1.0.0 " ]]
SBOM_DATA_DIR="$TEMP_DIR/data" PROJECT_SOURCE=manual FORCE_REGENERATE=true bash "$ROOT_DIR/util/sbom-plan.sh" "$TEMP_DIR/force.jsonl" >/dev/null 2>&1
grep -q '"tag":"v2.0.0"' "$TEMP_DIR/force.jsonl"
# A failed bucket listing must stop the plan, or every SBOM would be re-planned.
aws() { [[ "$2" == list-objects-v2 ]] && return 1; aws_stub "$@"; }; export -f aws
if SBOM_DATA_DIR="$TEMP_DIR/data" PROJECT_SOURCE=manual bash "$ROOT_DIR/util/sbom-plan.sh" "$TEMP_DIR/nolist.jsonl" >/dev/null 2>&1; then echo "expected failure at line $LINENO" >&2; exit 1; fi
aws() { aws_stub "$@"; }; export -f aws

# Two workers share the four items round-robin; the release of chart-test-tools-1.0.0 ships only a
# CycloneDX asset, so Waybill scans and the normalised CDX is uploaded next to it.
: >"$UPLOAD_LOG"
(cd "$TEMP_DIR" && SBOM_WORK_DIR="$TEMP_DIR/work" SBOM_RESULT_FILE="$TEMP_DIR/results/0.json" bash "$ROOT_DIR/util/sbom-worker.sh" plan.jsonl 0 2 >"$TEMP_DIR/worker0.log" 2>&1)
(cd "$TEMP_DIR" && SBOM_WORK_DIR="$TEMP_DIR/work" SBOM_RESULT_FILE="$TEMP_DIR/results/1.json" bash "$ROOT_DIR/util/sbom-worker.sh" plan.jsonl 1 2 >"$TEMP_DIR/worker1.log" 2>&1)
[[ "$(LC_ALL=C sort "$UPLOAD_LOG" | tr '\n' ' ')" == \
  "cncf-project-sboms/example/5.5.0/example_5_5_0_spdx.json cncf-project-sboms/example/5.6.0/example_5_6_0_spdx.json cncf-project-sboms/example/5.7.0/example_5_7_0_spdx.json cncf-project-sboms/example/chart-test-tools-1.0.0/example_chart-test-tools-1_0_0_cdx.json cncf-project-sboms/example/chart-test-tools-1.0.0/example_chart-test-tools-1_0_0_spdx.json " ]]
grep -q 'metadata.component' "$ROOT_DIR/util/postprocess-cdx.sh"
grep -q 'Using release asset bom.json' "$TEMP_DIR/worker0.log" "$TEMP_DIR/worker1.log"
[[ "$(jq -s 'map(.uploaded) | add' "$TEMP_DIR"/results/*.json)" == 5 ]]
[[ "$(jq -s '[.[].failed[]] | length' "$TEMP_DIR"/results/*.json)" == 0 ]]
[[ -z "$(ls -A "$TEMP_DIR/work/example")" ]]  # scratch per repo is removed
# A failing item is reported and does not stop the worker.
# shellcheck disable=SC2317
git() { [[ "$*" == *tagsonly* ]] && return 1; mkdir -p "${@: -1}"; }
export -f git
: >"$UPLOAD_LOG"
! (cd "$TEMP_DIR" && SBOM_WORK_DIR="$TEMP_DIR/work" SBOM_RESULT_FILE="$TEMP_DIR/results/all.json" bash "$ROOT_DIR/util/sbom-worker.sh" plan.jsonl 0 1 >"$TEMP_DIR/worker.log" 2>&1)
[[ "$(jq -c '.failed' "$TEMP_DIR/results/all.json")" == '["example/tagsonly@v5.7.0","example/tagsonly@v5.6.0","example/tagsonly@v5.5.0"]' ]]
[[ "$(jq '.uploaded' "$TEMP_DIR/results/all.json")" == 2 ]]
grep -q '::error title=sbom-failed::example/tagsonly@v5.7.0' "$TEMP_DIR/worker.log"

echo "SBOM naming tests passed"
