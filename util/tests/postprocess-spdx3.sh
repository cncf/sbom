#!/usr/bin/env bash
# Imported SPDX 3 documents must identify the repository like our SPDX 2.x ones.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
PP="$ROOT_DIR/util/postprocess-spdx3.sh"

cat >"$TEMP_DIR/bom.json" <<'JSON'
{"@context":"https://spdx.org/rdf/3.0.1/spdx-context.jsonld","@graph":[
 {"type":"CreationInfo","@id":"_:ci","specVersion":"3.0.1","created":"2026-01-01T00:00:00Z","createdBy":["https://x/agent/syft"]},
 {"type":"Tool","spdxId":"https://x/agent/syft","name":"syft","creationInfo":"_:ci"},
 {"type":"SpdxDocument","spdxId":"https://x/doc","name":"flux_2.9.6.spdx.json","rootElement":["https://x/pkg/root"],"creationInfo":"_:ci"},
 {"type":"software_Package","spdxId":"https://x/pkg/root","name":"flux_2.9.6_source.tar.gz","software_packageVersion":"sha256:abc","software_downloadLocation":"NOASSERTION","creationInfo":"_:ci"},
 {"type":"software_Package","spdxId":"https://x/pkg/dep","name":"golang.org/x/net","software_packageVersion":"v0.1.0","creationInfo":"_:ci"}]}
JSON
bash "$PP" --owner fluxcd --repo flux2 --tag v2.9.6 --project Flux "$TEMP_DIR/bom.json"
g() { jq -r ".[\"@graph\"][] | select(.spdxId == \"$1\") | $2" "$TEMP_DIR/bom.json"; }
[[ "$(g https://x/doc .name)" == "fluxcd/flux2 v2.9.6" ]]
[[ "$(g https://x/pkg/root '"\(.name) \(.software_packageVersion) \(.software_downloadLocation) \(.suppliedBy)"')" == \
  "fluxcd/flux2 v2.9.6 git+https://github.com/fluxcd/flux2.git@v2.9.6 https://x/doc/agent/supplier" ]]
[[ "$(g https://x/doc/agent/supplier '"\(.type) \(.name) \(.creationInfo)"')" == "Organization Flux _:ci" ]]
[[ "$(g https://x/pkg/dep '"\(.name) \(.software_packageVersion)"')" == "golang.org/x/net v0.1.0" ]]
[[ "$(jq -r '.["@context"]' "$TEMP_DIR/bom.json")" == "https://spdx.org/rdf/3.0.1/spdx-context.jsonld" ]]
# Idempotent (agent not duplicated).
cp "$TEMP_DIR/bom.json" "$TEMP_DIR/again.json"
bash "$PP" --owner fluxcd --repo flux2 --tag v2.9.6 --project Flux "$TEMP_DIR/again.json"
cmp -s "$TEMP_DIR/bom.json" "$TEMP_DIR/again.json"
# Root via describes relationship, no project: no agent added.
cat >"$TEMP_DIR/rel.json" <<'JSON'
{"@context":"https://spdx.org/rdf/3.0.1/spdx-context.jsonld","@graph":[
 {"type":"SpdxDocument","spdxId":"https://x/doc","name":"d"},
 {"type":"Relationship","spdxId":"https://x/rel","from":"https://x/doc","relationshipType":"describes","to":["https://x/pkg/root"]},
 {"type":"software_Package","spdxId":"https://x/pkg/root","name":"foo"}]}
JSON
bash "$PP" --owner o --repo r --tag v1 "$TEMP_DIR/rel.json"
[[ "$(jq -r '[.["@graph"][] | select(.type == "software_Package") | .name, .software_packageVersion, (.suppliedBy // "none")] | join(" ")' "$TEMP_DIR/rel.json")" == "o/r v1 none" ]]
[[ "$(jq -r '[.["@graph"][] | select(.type == "Organization")] | length' "$TEMP_DIR/rel.json")" == 0 ]]
# No root, or not SPDX 3: fails, input untouched.
echo '{"@context":"https://spdx.org/rdf/3.0.1/spdx-context.jsonld","@graph":[{"type":"SpdxDocument","spdxId":"https://x/doc","name":"d"}]}' >"$TEMP_DIR/noroot.json"
! bash "$PP" --owner o --repo r --tag v1 "$TEMP_DIR/noroot.json" 2>/dev/null
echo '{"spdxVersion":"SPDX-2.3"}' >"$TEMP_DIR/spdx.json"
! bash "$PP" --owner o --repo r --tag v1 "$TEMP_DIR/spdx.json" 2>/dev/null
[[ "$(cat "$TEMP_DIR/spdx.json")" == '{"spdxVersion":"SPDX-2.3"}' ]]
echo "SPDX 3 post-processing tests passed"
