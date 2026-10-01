#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <resolved-revision.json> <output.spdx.json>" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
metadata="$1"
output="$2"
jq -e '
  (.repository | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$"))
  and (.commit | type == "string" and test("^[0-9a-f]{40}$"))
  and (.version | type == "string" and test("\\S"))
' "$metadata" >/dev/null
repository="$(jq -r '.repository' "$metadata")"
commit="$(jq -r '.commit' "$metadata")"
version="$(jq -r '.version' "$metadata")"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
mkdir "$work_dir/checkout"
git -C "$work_dir/checkout" init --quiet
git -C "$work_dir/checkout" remote add origin "https://github.com/${repository}.git"
git -C "$work_dir/checkout" fetch --quiet --depth 1 --no-tags origin "$commit"
git -C "$work_dir/checkout" checkout --quiet --detach FETCH_HEAD
if [[ "$(git -C "$work_dir/checkout" rev-parse HEAD)" != "$commit" ]]; then
  echo "Error: checkout does not match the resolved commit" >&2
  exit 1
fi

waybill sbom scan \
  --path "$work_dir/checkout" \
  --format spdx-2.3-json \
  --root-name "$repository" \
  --root-version "$version" \
  --repo "https://github.com/${repository}.git" \
  --git-ref "$commit" \
  --output "$work_dir/raw.spdx.json"

jq -e '.spdxVersion == "SPDX-2.3"' "$work_dir/raw.spdx.json" >/dev/null ||
  { echo "Error: Expected an SPDX 2.3 document" >&2; exit 1; }
# Same post-processing as the project buckets; sandbox applications have no
# CNCF project yet, so the root supplier is NOASSERTION.
bash "$script_dir/postprocess-spdx.sh" --owner "${repository%%/*}" --repo "${repository#*/}" \
  --tag "$version" "$work_dir/raw.spdx.json" "$work_dir/named.spdx.json"
mkdir -p "$(dirname "$output")"
mv "$work_dir/named.spdx.json" "$output"
