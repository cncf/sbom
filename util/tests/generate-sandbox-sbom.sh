#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
export TEST_REPOSITORY="$TEMP_DIR/repository"
export TEST_SCAN_PATH="$TEMP_DIR/scan-path"
export TEST_SCANNER_MODE=success

mkdir "$TEST_REPOSITORY"
git -C "$TEST_REPOSITORY" init --quiet
printf 'test repository\n' >"$TEST_REPOSITORY/README"
git -C "$TEST_REPOSITORY" add README
git -C "$TEST_REPOSITORY" -c user.name=Test -c user.email=test@example.invalid \
  commit --quiet -m fixture
COMMIT="$(git -C "$TEST_REPOSITORY" rev-parse HEAD)"
jq -n --arg commit "$COMMIT" \
  '{repository:"ray-project/kuberay", commit:$commit, version:"v1.2.3"}' >"$TEMP_DIR/revision.json"

git() {
  if [[ "$*" == *"remote add origin https://github.com/ray-project/kuberay.git" ]]; then
    command git -C "$2" remote add origin "$TEST_REPOSITORY"
  else
    command git "$@"
  fi
}
waybill() {
  local output="" path="" name="" version="" ref=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output) output="$2"; shift ;;
      --path) path="$2"; shift ;;
      --root-name) name="$2"; shift ;;
      --root-version) version="$2"; shift ;;
      --git-ref) ref="$2"; shift ;;
    esac
    shift
  done
  [[ "$(command git -C "$path" rev-parse HEAD)" == "$ref" ]]
  [[ "$name" == "ray-project/kuberay" && "$version" == "v1.2.3" ]]
  printf '%s\n' "$path" >"$TEST_SCAN_PATH"
  if [[ "$TEST_SCANNER_MODE" == failure ]]; then
    echo "simulated scanner failure" >&2
    return 1
  fi
  jq -n --arg name "$(basename "$(dirname "$path")")" \
    '{
      spdxVersion:"SPDX-2.3", name:$name,
      packages:[{SPDXID:"SPDXRef-root",name:"ray-project/kuberay",versionInfo:"v1.2.3"}],
      documentDescribes:["SPDXRef-root"],
      relationships:[{spdxElementId:"SPDXRef-DOCUMENT",relationshipType:"DESCRIBES",relatedSpdxElement:"SPDXRef-root"}]
    }' >"$output"
}
export -f git waybill

for run in first second; do
  bash "$ROOT_DIR/util/generate-sandbox-sbom.sh" "$TEMP_DIR/revision.json" "$TEMP_DIR/$run.json"
  jq -e '.name == "ray-project/kuberay v1.2.3"
    and .packages[0].versionInfo == "v1.2.3"
    and .documentDescribes == ["SPDXRef-root"]
    and .relationships[0].relationshipType == "DESCRIBES"' "$TEMP_DIR/$run.json" >/dev/null
  if [[ "$run" == first ]]; then
    first_path="$(<"$TEST_SCAN_PATH")"
  else
    [[ "$first_path" != "$(<"$TEST_SCAN_PATH")" ]]
  fi
  [[ ! -d "$(<"$TEST_SCAN_PATH")" ]]
done
cmp "$TEMP_DIR/first.json" "$TEMP_DIR/second.json"

TEST_SCANNER_MODE=failure
if bash "$ROOT_DIR/util/generate-sandbox-sbom.sh" "$TEMP_DIR/revision.json" "$TEMP_DIR/failed.json" >"$TEMP_DIR/error" 2>&1; then
  echo "Expected scanner failure" >&2
  exit 1
fi
[[ ! -e "$TEMP_DIR/failed.json" ]]
grep -q 'simulated scanner failure' "$TEMP_DIR/error"
[[ ! -d "$(<"$TEST_SCAN_PATH")" ]]

jq '.commit = "--upload-pack=invalid"' "$TEMP_DIR/revision.json" >"$TEMP_DIR/invalid.json"
if bash "$ROOT_DIR/util/generate-sandbox-sbom.sh" "$TEMP_DIR/invalid.json" "$TEMP_DIR/invalid-output.json" >"$TEMP_DIR/error" 2>&1; then
  echo "Expected invalid revision failure" >&2
  exit 1
fi
[[ ! -e "$TEMP_DIR/invalid-output.json" ]]
echo "Sandbox scan tests passed"
