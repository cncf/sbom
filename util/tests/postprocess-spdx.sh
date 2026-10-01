#!/usr/bin/env bash

set -euo pipefail

UTIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$UTIL_DIR/tests/data/kagent-v0.10.0-waybill.spdx.json"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
ROOT="SPDXRef-DocumentRoot-BK5M3V7SPYVEE75K"

postprocess() {
  bash "$UTIL_DIR/postprocess-spdx.sh" "$@"
}

expect_failure() {
  if postprocess "$@" >"$TEMP_DIR/out" 2>"$TEMP_DIR/error"; then
    echo "Expected post-processing to fail: $*" >&2
    exit 1
  fi
  test -s "$TEMP_DIR/error"
}

# The fixture has the defects of the published kagent document.
jq -e --arg root "$ROOT" '
  (.name | startswith("tmp."))
  and (.packages[] | select(.SPDXID == $root)
    | .downloadLocation == "NOASSERTION"
      and .supplier == "Organization: waybill contributors"
      and any(.externalRefs[]; .referenceLocator == "pkg:generic/kagent-dev%2Fkagent@v0.10.0"))
' "$FIXTURE" >/dev/null

# 1. Explicit coordinates, as the workflows call it. Input file is left untouched.
postprocess --owner kagent-dev --repo kagent --tag v0.10.0 --project kagent "$FIXTURE" "$TEMP_DIR/out.json"
jq -e '.name | startswith("tmp.")' "$FIXTURE" >/dev/null
jq -e --arg root "$ROOT" '
  .name == "kagent-dev/kagent v0.10.0"
  and (.packages[] | select(.SPDXID == $root)
    | .downloadLocation == "git+https://github.com/kagent-dev/kagent.git@v0.10.0"
      and .supplier == "Organization: kagent"
      and ([.externalRefs[] | select(.referenceType == "purl") | .referenceLocator]
        == ["pkg:github/kagent-dev/kagent@v0.10.0"])
      and any(.externalRefs[]; .referenceType == "cpe23Type"))
' "$TEMP_DIR/out.json" >/dev/null

# Everything else is unchanged: namespace, creators, relationships, annotations,
# all non-root packages and every other root field.
strip() {
  jq -S --arg root "$ROOT" '
    del(.name)
    | .packages |= map(if .SPDXID == $root
        then del(.downloadLocation, .supplier) | .externalRefs |= map(select(.referenceType != "purl"))
        else . end)' "$1"
}
cmp <(strip "$FIXTURE") <(strip "$TEMP_DIR/out.json")
for field in documentNamespace creationInfo relationships annotations documentDescribes; do
  cmp <(jq -S ".$field" "$FIXTURE") <(jq -S ".$field" "$TEMP_DIR/out.json")
done

# 2. Idempotent, with the same arguments and with coordinates inferred from the root.
cp "$TEMP_DIR/out.json" "$TEMP_DIR/again.json"
postprocess --owner kagent-dev --repo kagent --tag v0.10.0 --project kagent "$TEMP_DIR/again.json"
cmp "$TEMP_DIR/out.json" "$TEMP_DIR/again.json"
postprocess "$TEMP_DIR/again.json"
cmp "$TEMP_DIR/out.json" "$TEMP_DIR/again.json"

# 3. Coordinates inferred from the root package give the same result in place.
cp "$FIXTURE" "$TEMP_DIR/inferred.json"
postprocess --project kagent "$TEMP_DIR/inferred.json"
cmp "$TEMP_DIR/out.json" "$TEMP_DIR/inferred.json"

# 4. Supplier: never the tool; parenthesised project names stay unambiguous.
postprocess "$FIXTURE" "$TEMP_DIR/no-project.json"
jq -e --arg root "$ROOT" '.packages[] | select(.SPDXID == $root) | .supplier == "NOASSERTION"' \
  "$TEMP_DIR/no-project.json" >/dev/null
postprocess --project "Open Policy Agent (OPA)" "$FIXTURE" "$TEMP_DIR/opa.json"
jq -e --arg root "$ROOT" '.packages[] | select(.SPDXID == $root)
  | .supplier == "Organization: Open Policy Agent (OPA) ()"' "$TEMP_DIR/opa.json" >/dev/null
postprocess "$TEMP_DIR/opa.json"
jq -e --arg root "$ROOT" '.packages[] | select(.SPDXID == $root)
  | .supplier == "Organization: Open Policy Agent (OPA) ()"' "$TEMP_DIR/opa.json" >/dev/null

# 5. purl rules: lowercase owner/repo, encoded version, added when the root has none.
jq --arg root "$ROOT" '.packages |= map(if .SPDXID == $root then del(.externalRefs) else . end)' \
  "$FIXTURE" >"$TEMP_DIR/no-refs.json"
postprocess --owner OmniTrustILM --repo Core --tag "release/2.19+1" "$TEMP_DIR/no-refs.json"
jq -e --arg root "$ROOT" '
  .name == "OmniTrustILM/Core release/2.19+1"
  and (.packages[] | select(.SPDXID == $root)
    | .externalRefs == [{referenceCategory: "PACKAGE-MANAGER", referenceType: "purl",
        referenceLocator: "pkg:github/omnitrustilm/core@release%2F2.19%2B1"}]
      and .downloadLocation == "git+https://github.com/OmniTrustILM/Core.git@release/2.19+1")
' "$TEMP_DIR/no-refs.json" >/dev/null

# 6. Root found through the DESCRIBES relationship when documentDescribes is absent.
jq 'del(.documentDescribes)' "$FIXTURE" >"$TEMP_DIR/relationship-only.json"
postprocess --project kagent "$TEMP_DIR/relationship-only.json"
cmp <(jq 'del(.documentDescribes)' "$TEMP_DIR/out.json") "$TEMP_DIR/relationship-only.json"

# 7. Invalid input fails and leaves the file alone.
jq 'del(.documentDescribes) | .relationships = []' "$FIXTURE" >"$TEMP_DIR/no-root.json"
cp "$TEMP_DIR/no-root.json" "$TEMP_DIR/no-root.orig"
expect_failure "$TEMP_DIR/no-root.json"
cmp "$TEMP_DIR/no-root.json" "$TEMP_DIR/no-root.orig"
jq '.spdxVersion = "SPDX-3.0"' "$FIXTURE" >"$TEMP_DIR/spdx3.json"
expect_failure "$TEMP_DIR/spdx3.json"
jq --arg root "$ROOT" '.packages |= map(if .SPDXID == $root then .name = "kagent" | .versionInfo = "NOASSERTION" else . end)' \
  "$FIXTURE" >"$TEMP_DIR/no-coordinates.json"
expect_failure "$TEMP_DIR/no-coordinates.json"
expect_failure "$TEMP_DIR/missing.json"
expect_failure --bogus "$FIXTURE"
[[ -z "$(find "$TEMP_DIR" -name '.postprocess.*')" ]]

echo "SPDX post-processing tests passed"
