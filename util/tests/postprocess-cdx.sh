#!/usr/bin/env bash
# Imported CycloneDX documents must identify the repository like our SPDX ones.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat >"$TEMP_DIR/bom.json" <<'JSON'
{"bomFormat":"CycloneDX","specVersion":"1.6","metadata":{"component":{"type":"application","name":"github.com/aquasecurity/trivy","version":"v0.76.0","purl":"pkg:golang/github.com/aquasecurity/trivy@v0.76.0?goos=linux","externalReferences":[{"type":"vcs","url":"https://old"},{"type":"website","url":"https://trivy.dev"}]}},"components":[{"name":"x"}]}
JSON
bash "$ROOT_DIR/util/postprocess-cdx.sh" --owner aquasecurity --repo trivy --tag v0.76.0 --project Trivy "$TEMP_DIR/bom.json"
[[ "$(jq -r '.metadata.component | "\(.name) \(.version) \(.purl) \(.type)"' "$TEMP_DIR/bom.json")" == \
  "aquasecurity/trivy v0.76.0 pkg:golang/github.com/aquasecurity/trivy@v0.76.0?goos=linux application" ]]
[[ "$(jq -c '[.metadata.component.externalReferences[] | .url]' "$TEMP_DIR/bom.json")" == '["https://trivy.dev","https://github.com/aquasecurity/trivy"]' ]]
[[ "$(jq -r '.metadata.supplier.name' "$TEMP_DIR/bom.json")" == Trivy ]]
[[ "$(jq -c '.components' "$TEMP_DIR/bom.json")" == '[{"name":"x"}]' ]]
# Idempotent; a document without metadata.component gets one.
cp "$TEMP_DIR/bom.json" "$TEMP_DIR/again.json"
bash "$ROOT_DIR/util/postprocess-cdx.sh" --owner aquasecurity --repo trivy --tag v0.76.0 --project Trivy "$TEMP_DIR/again.json"
cmp -s "$TEMP_DIR/bom.json" "$TEMP_DIR/again.json"
echo '{"bomFormat":"CycloneDX","specVersion":"1.5","components":[]}' >"$TEMP_DIR/bare.json"
bash "$ROOT_DIR/util/postprocess-cdx.sh" --owner o --repo r --tag v1 "$TEMP_DIR/bare.json"
[[ "$(jq -r '.metadata.component.name + " " + .metadata.component.version + " " + (.metadata.supplier // "none" | tostring)' "$TEMP_DIR/bare.json")" == "o/r v1 none" ]]
# Not CycloneDX: fails, input untouched.
echo '{"spdxVersion":"SPDX-2.3"}' >"$TEMP_DIR/spdx.json"
! bash "$ROOT_DIR/util/postprocess-cdx.sh" --owner o --repo r --tag v1 "$TEMP_DIR/spdx.json" 2>/dev/null
[[ "$(cat "$TEMP_DIR/spdx.json")" == '{"spdxVersion":"SPDX-2.3"}' ]]
echo "CycloneDX post-processing tests passed"
