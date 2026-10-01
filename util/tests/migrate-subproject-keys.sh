#!/usr/bin/env bash
#
# util/migrate-subproject-keys.sh against the checked-in util/data files with a
# stubbed aws CLI. Nothing here talks to a bucket.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
MIGRATE="$ROOT_DIR/util/migrate-subproject-keys.sh"

export AWS_CALLS="$TEMP_DIR/aws-calls" LISTING_JSON="$TEMP_DIR/listing.json"
export AWS_ACCESS_KEY_ID="test" S3_ENDPOINT="https://storage.example" S3_REGION="us-east-1" SUBPROJECT_BUCKET="cncf-subproject-sboms"
# shellcheck disable=SC2317 # stub, invoked by the migration script
aws() {
  printf '%s\n' "$*" >>"$AWS_CALLS"
  case "$2" in
    list-objects-v2) cat "$LISTING_JSON" ;;
    head-object) echo '[1024, "\"etag\""]' ;;
    copy-object|delete-object) echo '{}' ;;
    *) return 1 ;;
  esac
}
export -f aws

cat >"$TEMP_DIR/keys" <<'EOF'
argo-cd/argo-workflows/4.1.4/argo-cd_argo-workflows_4_1_4_spdx.json
argo-cd/argo-rollouts/1.8.3/argo-cd_argo-rollouts_1_8_3_spdx.json
argo-cd/pkg/0.7.0/argo-cd_pkg_0_7_0_spdx.json
argo/pkg/0.7.0/argo_pkg_0_7_0_spdx.json
argo/argo-events/1.9.6/argo_argo-events_1_9_6_spdx.json
aeraki/meta-protocol-proxy/1.4.2/aeraki_meta-protocol-proxy_1_4_2_spdx.json
cdk8s/cdk8s-plus/cdk8s-plus-32/v2.5.100/cdk8s-plus_cdk8s-plus-32/cdk8s_cdk8s-plus_cdk8s-plus-32/v2_5_100/cdk8s-plus_cdk8s-plus-32_spdx.json
higress/alink/1.5.2/higress_alink_1_5_2_spdx.json
not-a-project/tool/1.0.0/not-a-project_tool_1_0_0_spdx.json
EOF
jq -R . "$TEMP_DIR/keys" | jq -s . >"$LISTING_JSON"

expected_moves() {
  cat <<'EOF'
MOVE      aeraki/meta-protocol-proxy/1.4.2/aeraki_meta-protocol-proxy_1_4_2_spdx.json -> aeraki-mesh/meta-protocol-proxy/1.4.2/aeraki-mesh_meta-protocol-proxy_1_4_2_spdx.json
MOVE      argo-cd/argo-rollouts/1.8.3/argo-cd_argo-rollouts_1_8_3_spdx.json -> argo/argo-rollouts/1.8.3/argo_argo-rollouts_1_8_3_spdx.json
MOVE      argo-cd/argo-workflows/4.1.4/argo-cd_argo-workflows_4_1_4_spdx.json -> argo/argo-workflows/4.1.4/argo_argo-workflows_4_1_4_spdx.json
MOVE      cdk8s/cdk8s-plus/cdk8s-plus-32/v2.5.100/cdk8s-plus_cdk8s-plus-32/cdk8s_cdk8s-plus_cdk8s-plus-32/v2_5_100/cdk8s-plus_cdk8s-plus-32_spdx.json -> cdk-for-kubernetes-cdk8s/cdk8s-plus/cdk8s-plus-32/v2.5.100/cdk8s-plus_cdk8s-plus-32/cdk8s_cdk8s-plus_cdk8s-plus-32/v2_5_100/cdk8s-plus_cdk8s-plus-32_spdx.json
EOF
}

check_plan() {
  local log="$1"
  diff <(grep '^MOVE' "$log") <(expected_moves)
  grep -qx 'CONFLICT  argo-cd/pkg/0.7.0/argo-cd_pkg_0_7_0_spdx.json -> argo/pkg/0.7.0/argo_pkg_0_7_0_spdx.json (target exists; both left in place)' "$log"
  grep -qx 'UNKNOWN   not-a-project/tool/1.0.0/not-a-project_tool_1_0_0_spdx.json (not a discovered repository; left in place)' "$log"
  grep -q 'argo-cd -> argo .* 2 objects' "$log"
  grep -q 'aeraki -> aeraki-mesh .* 1 objects' "$log"
  grep -qx '  move:      4' "$log"
  grep -qx '  unchanged: 3' "$log" # argo/pkg, argo/argo-events (already migrated), higress/alink (parent unknown)
  grep -qx '  conflict:  1' "$log"
  grep -qx '  unknown:   1' "$log"
}

# 1. Dry-run is the default: with a listing file no aws call is made at all.
: >"$AWS_CALLS"
bash "$MIGRATE" --listing "$TEMP_DIR/keys" >"$TEMP_DIR/dry-run.log"
check_plan "$TEMP_DIR/dry-run.log"
grep -q 'dry-run, nothing changed' "$TEMP_DIR/dry-run.log"
[[ ! -s "$AWS_CALLS" ]]

# 2. Dry-run against the bucket only lists it (read-only).
bash "$MIGRATE" --bucket cncf-subproject-sboms >"$TEMP_DIR/dry-run-bucket.log"
check_plan "$TEMP_DIR/dry-run-bucket.log"
[[ "$(cut -d' ' -f2 "$AWS_CALLS" | sort -u)" == list-objects-v2 ]]
grep -q -- '--bucket cncf-subproject-sboms' "$AWS_CALLS"

# 3. --apply copies, verifies and only then deletes, once per planned move (stubbed aws).
: >"$AWS_CALLS"
bash "$MIGRATE" --apply --listing "$TEMP_DIR/keys" >"$TEMP_DIR/apply.log"
check_plan "$TEMP_DIR/apply.log"
[[ "$(cut -d' ' -f2 "$AWS_CALLS" | uniq -c | awk '{print $2}' | paste -sd' ')" == \
  "head-object copy-object head-object delete-object head-object copy-object head-object delete-object head-object copy-object head-object delete-object head-object copy-object head-object delete-object" ]]
grep -q -- '--copy-source cncf-subproject-sboms/argo-cd/argo-workflows/4.1.4/argo-cd_argo-workflows_4_1_4_spdx.json' "$AWS_CALLS"
grep -q -- 'delete-object --bucket cncf-subproject-sboms --key aeraki/meta-protocol-proxy/1.4.2/' "$AWS_CALLS"
if grep -q 'argo-cd/pkg' "$AWS_CALLS"; then echo "Conflicting key was touched" >&2; exit 1; fi

# 4. A copy that does not match the source keeps the old key and fails the run.
aws() {
  printf '%s\n' "$*" >>"$AWS_CALLS"
  case "$2" in
    head-object) [[ "$*" == *"--key argo/"* ]] && echo '[1, "\"other\""]' || echo '[1024, "\"etag\""]' ;;
    copy-object|delete-object) echo '{}' ;;
    *) return 1 ;;
  esac
}
export -f aws
: >"$AWS_CALLS"
if bash "$MIGRATE" --apply --listing "$TEMP_DIR/keys" >"$TEMP_DIR/mismatch.log" 2>&1; then
  echo "Expected a failed verification to fail the migration" >&2
  exit 1
fi
grep -q 'does not match the source' "$TEMP_DIR/mismatch.log"
if grep -q 'delete-object .*--key argo-cd/' "$AWS_CALLS"; then echo "Source deleted after a failed copy" >&2; exit 1; fi
grep -q 'delete-object .*--key aeraki/' "$AWS_CALLS" # verified copies are still completed

echo "Subproject key migration tests passed"
