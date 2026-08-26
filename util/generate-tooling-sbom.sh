#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/.tooling-sbom}"
WAYBILL_VERSION="${WAYBILL_VERSION:-v0.2.0}"
REPO_URL="${REPO_URL:-https://github.com/cncf/sbom.git}"
ROOT_PACKAGE_NAME="${ROOT_PACKAGE_NAME:-cncf/sbom-tooling}"
SKIP_REPO_SBOM="false"
export WAYBILL_VERSION

usage() {
  cat <<'EOF'
Usage: ./util/generate-tooling-sbom.sh [--output-dir <dir>] [--skip-repo-sbom]

Generates:
  - tooling-repo.spdx.json: SBOM for this repository's tooling source
  - tooling-ci.spdx.json:   SBOM for the GitHub Actions/generation chain
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --skip-repo-sbom)
      SKIP_REPO_SBOM="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

WORKFLOW_DIR="$ROOT_DIR/.github/workflows"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REPO_COMMIT="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

spdx_id() {
  echo "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/-/g'
}

package_json() {
  local spdx_id_value="$1"
  local name="$2"
  local version="$3"
  local download_location="$4"
  local supplier="$5"
  local homepage="$6"
  local purpose="$7"

  jq -n \
    --arg spdx_id "$spdx_id_value" \
    --arg name "$name" \
    --arg version "$version" \
    --arg download_location "$download_location" \
    --arg supplier "$supplier" \
    --arg homepage "$homepage" \
    --arg purpose "$purpose" \
    '{
      SPDXID: $spdx_id,
      name: $name,
      versionInfo: $version,
      downloadLocation: $download_location,
      filesAnalyzed: false,
      supplier: $supplier,
      homepage: $homepage,
      primaryPackagePurpose: $purpose,
      licenseConcluded: "NOASSERTION",
      licenseDeclared: "NOASSERTION",
      copyrightText: "NOASSERTION"
    }'
}

generate_repo_sbom() {
  local output_file="$OUTPUT_DIR/tooling-repo.spdx.json"
  local temp_dir

  if [[ "$SKIP_REPO_SBOM" == "true" ]]; then
    echo "Skipping repository tooling SBOM generation"
    return
  fi

  require_cmd waybill
  require_cmd git

  temp_dir="$(mktemp -d)"
  git -C "$ROOT_DIR" archive HEAD | tar -x -C "$temp_dir"

  if ! waybill sbom scan \
    --path "$temp_dir" \
    --format spdx-2.3-json \
    --root-name "$ROOT_PACKAGE_NAME" \
    --root-version "$REPO_COMMIT" \
    --repo "$REPO_URL" \
    --git-ref "$REPO_COMMIT" \
    --output "$output_file"; then
    rm -rf "$temp_dir"
    return 1
  fi

  rm -rf "$temp_dir"
}

generate_ci_sbom() {
  local output_file="$OUTPUT_DIR/tooling-ci.spdx.json"
  local temp_dir
  temp_dir="$(mktemp -d)"

  local packages_file="$temp_dir/packages.jsonl"
  local relationships_file="$temp_dir/relationships.jsonl"

  local root_spdx="SPDXRef-Package-Tooling-CI"
  package_json \
    "$root_spdx" \
    "cncf/sbom-ci-generation-chain" \
    "$REPO_COMMIT" \
    "$REPO_URL" \
    "Organization: CNCF" \
    "${REPO_URL%.git}" \
    "APPLICATION" >> "$packages_file"

  jq -n --arg source "SPDXRef-DOCUMENT" --arg target "$root_spdx" \
    '{spdxElementId:$source, relationshipType:"DESCRIBES", relatedSpdxElement:$target}' >> "$relationships_file"

  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue

    local spdx_ref
    local name
    local version
    local download_location
    local homepage
    local supplier
    local purpose="FRAMEWORK"

    if [[ "$ref" == ./* ]]; then
      spdx_ref="SPDXRef-$(spdx_id "$ref")"
      name="Local workflow ${ref}"
      version="$REPO_COMMIT"
      download_location="$REPO_URL"
      homepage="${REPO_URL%.git}/blob/${REPO_COMMIT}/${ref#./}"
      supplier="Organization: CNCF"
      purpose="SOURCE"
    else
      local action_name="${ref%@*}"
      local action_version="${ref##*@}"
      spdx_ref="SPDXRef-$(spdx_id "$action_name-$action_version")"
      name="GitHub Action ${action_name}"
      version="$action_version"
      download_location="https://github.com/${action_name}"
      homepage="https://github.com/${action_name}"
      supplier="Organization: GitHub"
    fi

    package_json \
      "$spdx_ref" \
      "$name" \
      "$version" \
      "$download_location" \
      "$supplier" \
      "$homepage" \
      "$purpose" >> "$packages_file"

    jq -n --arg source "$root_spdx" --arg target "$spdx_ref" \
      '{spdxElementId:$source, relationshipType:"DEPENDS_ON", relatedSpdxElement:$target}' >> "$relationships_file"
  done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^[:space:]]+).*$/\1/p' "$WORKFLOW_DIR"/*.yml | sort -u)

  package_json \
    "SPDXRef-Package-ToolingWorkflow" \
    "Local workflow .github/workflows/generate-tooling-sbom.yml" \
    "$REPO_COMMIT" \
    "$REPO_URL" \
    "Organization: CNCF" \
    "${REPO_URL%.git}/blob/${REPO_COMMIT}/.github/workflows/generate-tooling-sbom.yml" \
    "SOURCE" >> "$packages_file"
  jq -n --arg source "$root_spdx" --arg target "SPDXRef-Package-ToolingWorkflow" \
    '{spdxElementId:$source, relationshipType:"DEPENDS_ON", relatedSpdxElement:$target}' >> "$relationships_file"

  package_json \
    "SPDXRef-Package-ToolingScript" \
    "Local script util/generate-tooling-sbom.sh" \
    "$REPO_COMMIT" \
    "$REPO_URL" \
    "Organization: CNCF" \
    "${REPO_URL%.git}/blob/${REPO_COMMIT}/util/generate-tooling-sbom.sh" \
    "SOURCE" >> "$packages_file"
  jq -n --arg source "$root_spdx" --arg target "SPDXRef-Package-ToolingScript" \
    '{spdxElementId:$source, relationshipType:"DEPENDS_ON", relatedSpdxElement:$target}' >> "$relationships_file"

  package_json \
    "SPDXRef-Package-Waybill" \
    "Waybill" \
    "$WAYBILL_VERSION" \
    "https://github.com/kusari-oss/waybill/releases/download/${WAYBILL_VERSION}/waybill-${WAYBILL_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    "Organization: Kusari" \
    "https://github.com/kusari-oss/waybill" \
    "APPLICATION" >> "$packages_file"
  jq -n --arg source "$root_spdx" --arg target "SPDXRef-Package-Waybill" \
    '{spdxElementId:$source, relationshipType:"DEPENDS_ON", relatedSpdxElement:$target}' >> "$relationships_file"

  package_json \
    "SPDXRef-Package-AWSCLI" \
    "AWS CLI" \
    "latest" \
    "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    "Organization: Amazon Web Services" \
    "https://aws.amazon.com/cli/" \
    "APPLICATION" >> "$packages_file"
  jq -n --arg source "$root_spdx" --arg target "SPDXRef-Package-AWSCLI" \
    '{spdxElementId:$source, relationshipType:"DEPENDS_ON", relatedSpdxElement:$target}' >> "$relationships_file"

  package_json \
    "SPDXRef-Package-GitHubCLI" \
    "GitHub CLI" \
    "latest" \
    "https://cli.github.com/packages" \
    "Organization: GitHub" \
    "https://cli.github.com/" \
    "APPLICATION" >> "$packages_file"
  jq -n --arg source "$root_spdx" --arg target "SPDXRef-Package-GitHubCLI" \
    '{spdxElementId:$source, relationshipType:"DEPENDS_ON", relatedSpdxElement:$target}' >> "$relationships_file"

  package_json \
    "SPDXRef-Package-YQ" \
    "yq" \
    "latest" \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" \
    "Person: Mike Farah" \
    "https://github.com/mikefarah/yq" \
    "APPLICATION" >> "$packages_file"
  jq -n --arg source "$root_spdx" --arg target "SPDXRef-Package-YQ" \
    '{spdxElementId:$source, relationshipType:"DEPENDS_ON", relatedSpdxElement:$target}' >> "$relationships_file"

  package_json \
    "SPDXRef-Package-GoToolchain" \
    "Go toolchain" \
    "1.24" \
    "https://go.dev/dl/" \
    "Organization: Go team" \
    "https://go.dev/" \
    "APPLICATION" >> "$packages_file"
  jq -n --arg source "$root_spdx" --arg target "SPDXRef-Package-GoToolchain" \
    '{spdxElementId:$source, relationshipType:"DEPENDS_ON", relatedSpdxElement:$target}' >> "$relationships_file"

  jq -s \
    --arg timestamp "$TIMESTAMP" \
    --arg namespace "https://github.com/cncf/sbom/tooling-ci/${REPO_COMMIT}" \
    --slurpfile packages "$packages_file" \
    --slurpfile relationships "$relationships_file" \
    '{
      spdxVersion: "SPDX-2.3",
      dataLicense: "CC0-1.0",
      SPDXID: "SPDXRef-DOCUMENT",
      name: "cncf/sbom CI generation chain",
      documentNamespace: $namespace,
      creationInfo: {
        created: $timestamp,
        creators: [
          "Tool: util/generate-tooling-sbom.sh",
          ("Tool: Waybill " + env.WAYBILL_VERSION)
        ]
      },
      packages: $packages,
      relationships: $relationships
    }' > "$output_file"

  rm -rf "$temp_dir"
}

main() {
  require_cmd jq
  mkdir -p "$OUTPUT_DIR"

  generate_repo_sbom
  generate_ci_sbom

  echo "Generated tooling SBOM artifacts in: $OUTPUT_DIR"
  ls -1 "$OUTPUT_DIR"
}

main "$@"
