#!/usr/bin/env bash

set -euo pipefail

UTIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

matrix() {
  bash "$UTIL_DIR/prepare-project-matrix.sh" "$1" "${2:-}" "$TEMP_DIR"
}

expect_failure() {
  if matrix "$@" >"$TEMP_DIR/output" 2>"$TEMP_DIR/error"; then
    echo "Expected matrix preparation to fail: $*" >&2
    exit 1
  fi
  test -s "$TEMP_DIR/error"
}

jq -n '{repositories: [
  {owner: "cncf", repo: "example", name: "CNCF Example"},
  {owner: "shared", repo: "repo", name: "Official Name"}
]}' >"$TEMP_DIR/cncf-projects.yaml"
jq -n '{repositories: [
  {owner: "OmniTrustILM", repo: "core", name: "OmniTrust ILM"},
  {owner: "SHARED", repo: "REPO", name: "Manual Name"}
]}' >"$TEMP_DIR/repositories.yaml"

matrix all | jq -e '
  (.include | length) == 3
  and any(.include[]; .owner == "OmniTrustILM" and .repo == "core")
  and any(.include[]; .name == "Official Name")
  and all(.include[]; .name != "Manual Name")
' >/dev/null
matrix cncf | jq -e '
  (.include | length) == 2
  and all(.include[]; .owner != "OmniTrustILM")
' >/dev/null
matrix manual | jq -e '
  (.include | length) == 2
  and any(.include[]; .name == "Manual Name")
' >/dev/null
matrix all omnitrustilm/CORE | jq -e '
  .include == [{owner: "OmniTrustILM", repo: "core", name: "OmniTrust ILM"}]
' >/dev/null
matrix manual 'missing/"repo' | jq -e '.include == []' >/dev/null
expect_failure unsupported

jq -n '{repositories: []}' >"$TEMP_DIR/repositories.yaml"
matrix manual | jq -e '.include == []' >/dev/null
matrix all | jq -e '(.include | length) == 2' >/dev/null

jq -n '{repositories: [{owner: "example", repo: "repo"}]}' >"$TEMP_DIR/repositories.yaml"
expect_failure manual
jq -n '{repositories: null}' >"$TEMP_DIR/repositories.yaml"
expect_failure all
printf 'repositories: [\n' >"$TEMP_DIR/repositories.yaml"
expect_failure all
rm "$TEMP_DIR/repositories.yaml"
expect_failure all
matrix cncf | jq -e '(.include | length) == 2' >/dev/null

# Exercise the checked-in entry, not just synthetic fixtures.
bash "$UTIL_DIR/prepare-project-matrix.sh" all OmniTrustILM/core |
  jq -e '.include == [{owner: "OmniTrustILM", repo: "core", name: "OmniTrust ILM"}]' >/dev/null

echo "Project matrix tests passed"
