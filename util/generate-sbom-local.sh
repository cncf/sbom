#!/bin/bash
#
# Local SBOM Generation Script
# This script mimics the GitHub Actions workflow for local testing
#
# Prerequisites:
#   - git
#   - gh CLI (GitHub CLI) - for API access
#   - jq
#   - yq (https://github.com/mikefarah/yq)
#   - waybill (https://github.com/kusari-oss/waybill)
#
# Usage:
#   ./generate-sbom-local.sh                           # Process all projects
#   ./generate-sbom-local.sh kubernetes/kubernetes     # Process specific repo
#   ./generate-sbom-local.sh --force kubernetes/kubernetes  # Force regenerate
#
# Environment variables:
#   GH_TOKEN or GITHUB_TOKEN - GitHub token for API access
#   MAX_RELEASES - Maximum releases to process per repo (default: 3)
#   WAYBILL_VERSION - waybill release version (default: v0.1.0-alpha.69)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_FILE="$ROOT_DIR/util/data/repositories.yaml"
SBOM_BASE_DIR="$ROOT_DIR/sbom"
WAYBILL_VERSION="${WAYBILL_VERSION:-v0.1.0-alpha.69}"

# Parse arguments
FORCE_REGENERATE="false"
PROJECT_FILTER=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --force|-f)
      FORCE_REGENERATE="true"
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--force] [owner/repo]"
      echo ""
      echo "Options:"
      echo "  --force, -f    Force regenerate existing SBOMs"
      echo "  --help, -h     Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                           # Process all projects"
      echo "  $0 kubernetes/kubernetes     # Process specific repo"
      echo "  $0 --force coredns/coredns   # Force regenerate for coredns"
      exit 0
      ;;
    *)
      PROJECT_FILTER="$1"
      shift
      ;;
  esac
done

# Set token
GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
if [ -z "$GH_TOKEN" ]; then
  echo "Warning: No GitHub token found. API rate limits may apply."
  echo "Set GH_TOKEN or GITHUB_TOKEN environment variable for higher limits."
fi

MAX_RELEASES="${MAX_RELEASES:-3}"

# Check prerequisites
check_prerequisites() {
  local missing=()

  if ! command -v git &> /dev/null; then
    missing+=("git")
  fi

  if ! command -v gh &> /dev/null; then
    missing+=("gh (GitHub CLI)")
  fi

  if ! command -v jq &> /dev/null; then
    missing+=("jq")
  fi

  if ! command -v yq &> /dev/null; then
    missing+=("yq")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: Missing required tools: ${missing[*]}"
    echo ""
    echo "Installation:"
    echo "  gh:  https://cli.github.com/"
    echo "  jq:  https://stedolan.github.io/jq/"
    echo "  yq:  https://github.com/mikefarah/yq"
    exit 1
  fi
}

# Install waybill if not present
install_waybill() {
  if command -v waybill &> /dev/null; then
    echo "Using waybill: $(which waybill)"
    return
  fi

  # Check in local bin directory
  local LOCAL_BIN="$ROOT_DIR/.local/bin"
  if [ -x "$LOCAL_BIN/waybill" ]; then
    export PATH="$LOCAL_BIN:$PATH"
    echo "Using waybill: $LOCAL_BIN/waybill"
    return
  fi

  echo "Installing waybill ${WAYBILL_VERSION}..."
  mkdir -p "$LOCAL_BIN"

  local ARCH
  ARCH=$(uname -m)
  local OS
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')

  local PLATFORM=""
  case "${ARCH}-${OS}" in
    x86_64-linux)
      PLATFORM="x86_64-unknown-linux-gnu"
      ;;
    aarch64-linux)
      PLATFORM="aarch64-unknown-linux-gnu"
      ;;
    arm64-darwin|aarch64-darwin)
      PLATFORM="aarch64-apple-darwin"
      ;;
    *)
      echo "Error: Unsupported platform: ${ARCH}-${OS}"
      echo "Download waybill manually from https://github.com/kusari-oss/waybill/releases"
      exit 1
      ;;
  esac

  local DOWNLOAD_URL="https://github.com/kusari-oss/waybill/releases/download/${WAYBILL_VERSION}/waybill-${WAYBILL_VERSION}-${PLATFORM}.tar.gz"
  local TMP_TAR
  TMP_TAR=$(mktemp)

  echo "Downloading from: $DOWNLOAD_URL"
  if ! curl -sL "$DOWNLOAD_URL" -o "$TMP_TAR"; then
    echo "Error: Failed to download waybill"
    rm -f "$TMP_TAR"
    exit 1
  fi

  local TMP_EXTRACT
  TMP_EXTRACT=$(mktemp -d)
  tar xzf "$TMP_TAR" -C "$TMP_EXTRACT"
  cp "$TMP_EXTRACT"/*/waybill "$LOCAL_BIN/waybill"
  chmod +x "$LOCAL_BIN/waybill"
  rm -rf "$TMP_TAR" "$TMP_EXTRACT"

  export PATH="$LOCAL_BIN:$PATH"
  echo "Installed waybill to: $LOCAL_BIN/waybill"
}

# Generate SBOM for a specific tag
generate_sbom() {
  local OWNER="$1"
  local REPO="$2"
  local PROJECT_NAME="$3"
  local TAG="$4"

  local SANITIZED_PROJECT=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')
  local VERSION=$(echo "$TAG" | sed 's/^v//')
  local SBOM_DIR="${SBOM_BASE_DIR}/${SANITIZED_PROJECT}/${REPO}/${VERSION}"
  local FILENAME_VERSION=$(echo "$VERSION" | tr '.' '_')
  local SBOM_FILE="${SBOM_DIR}/${SANITIZED_PROJECT}_${FILENAME_VERSION}_spdx.json"

  # Check if SBOM already exists
  if [ -f "$SBOM_FILE" ] && [ "$FORCE_REGENERATE" != "true" ]; then
    echo "  SBOM already exists: $SBOM_FILE, skipping..."
    return 1
  fi

  echo "  Generating SBOM for $OWNER/$REPO@$TAG..."

  # Clone the repository at specific tag
  local TEMP_DIR=$(mktemp -d)
  trap "rm -rf '$TEMP_DIR'" EXIT

  if ! git clone --depth 1 --branch "$TAG" "https://github.com/${OWNER}/${REPO}.git" "$TEMP_DIR" 2>/dev/null; then
    echo "  Failed to clone $OWNER/$REPO@$TAG, skipping..."
    rm -rf "$TEMP_DIR"
    return 1
  fi

  # Create output directory
  mkdir -p "$SBOM_DIR"

  # Generate SBOM with waybill (SPDX 2.3 + deps.dev enrichment)
  if waybill sbom scan \
    --path "$TEMP_DIR" \
    --format spdx-2.3-json \
    --scan-target-name "${OWNER}/${REPO}" \
    --root-name "${OWNER}/${REPO}" \
    --root-version "$TAG" \
    --repo "https://github.com/${OWNER}/${REPO}.git" \
    --git-ref "$TAG" \
    --output "$SBOM_FILE" \
    2>/dev/null; then
    echo "  Successfully generated SBOM: $SBOM_FILE"
    rm -rf "$TEMP_DIR"
    return 0
  else
    echo "  Failed to generate SBOM for $OWNER/$REPO@$TAG"
    rm -rf "$TEMP_DIR"
    return 1
  fi
}

# Process a single repository
process_repository() {
  local OWNER="$1"
  local REPO="$2"
  local PROJECT_NAME="$3"
  local PROCESSED=0

  echo ""
  echo "=========================================="
  echo "Processing: $PROJECT_NAME ($OWNER/$REPO)"
  echo "=========================================="

  # Get releases from GitHub API
  local RELEASES
  RELEASES=$(gh api "repos/${OWNER}/${REPO}/releases" --paginate -q '.[0:50]' 2>/dev/null || echo "[]")

  if [ "$RELEASES" == "[]" ] || [ -z "$RELEASES" ]; then
    echo "No releases found, trying tags..."
    local TAGS
    TAGS=$(gh api "repos/${OWNER}/${REPO}/tags" --paginate -q '.[0:20] | .[].name' 2>/dev/null || echo "")

    if [ -z "$TAGS" ]; then
      echo "No tags found, skipping..."
      return 0
    fi

    # Process tags as releases
    for TAG in $TAGS; do
      # Filter out pre-releases
      if echo "$TAG" | grep -qiE '[-\.](alpha|beta|rc|pre|dev|snapshot|nightly|canary|test|draft|wip)[0-9]*'; then
        echo "  Skipping pre-release tag: $TAG"
        continue
      fi

      # Only process semver-like tags
      if ! echo "$TAG" | grep -qE '^v?[0-9]+\.[0-9]+'; then
        echo "  Skipping non-semver tag: $TAG"
        continue
      fi

      if generate_sbom "$OWNER" "$REPO" "$PROJECT_NAME" "$TAG"; then
        PROCESSED=$((PROCESSED + 1))
      fi

      if [ "$PROCESSED" -ge "$MAX_RELEASES" ]; then
        echo "  Processed $MAX_RELEASES releases, stopping..."
        break
      fi
    done
  else
    # Process releases - filter stable releases
    readarray -t RELEASE_TAGS < <(echo "$RELEASES" | jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name')

    for TAG in "${RELEASE_TAGS[@]}"; do
      # Additional filter for pre-release patterns
      if echo "$TAG" | grep -qiE '[-\.](alpha|beta|rc|pre|dev|snapshot|nightly|canary|test|draft|wip)[0-9]*'; then
        echo "  Skipping pre-release tag: $TAG"
        continue
      fi

      if generate_sbom "$OWNER" "$REPO" "$PROJECT_NAME" "$TAG"; then
        PROCESSED=$((PROCESSED + 1))
      fi

      if [ "$PROCESSED" -ge "$MAX_RELEASES" ]; then
        echo "  Processed $MAX_RELEASES releases, stopping..."
        break
      fi
    done
  fi

  echo "Processed $PROCESSED releases for $OWNER/$REPO"
}

# Generate index of all SBOMs
generate_index() {
  echo ""
  echo "=========================================="
  echo "Generating SBOM index"
  echo "=========================================="

  local INDEX_FILE="$SBOM_BASE_DIR/index.json"

  # Check if there are any SBOMs
  local SBOM_COUNT
  SBOM_COUNT=$(find "$SBOM_BASE_DIR" -name "*.json" -type f ! -name "index.json" 2>/dev/null | wc -l)

  if [ "$SBOM_COUNT" -eq 0 ]; then
    echo "No SBOMs found, creating empty index..."
    echo '{"generated_at": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'", "sboms": []}' > "$INDEX_FILE"
    return 0
  fi

  # Generate index using jq
  find "$SBOM_BASE_DIR" -name "*.json" -type f ! -name "index.json" | sort | while read -r SBOM; do
    REL_PATH="${SBOM#$SBOM_BASE_DIR/}"
    PROJECT=$(echo "$REL_PATH" | cut -d'/' -f1)
    REPO=$(echo "$REL_PATH" | cut -d'/' -f2)
    VERSION=$(echo "$REL_PATH" | cut -d'/' -f3)
    echo "{\"project\": \"$PROJECT\", \"repo\": \"$REPO\", \"version\": \"$VERSION\", \"path\": \"$REL_PATH\"}"
  done | jq -s '{"generated_at": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'", "sboms": .}' > "$INDEX_FILE"

  echo "Index generated: $INDEX_FILE"
  echo "Total SBOMs: $SBOM_COUNT"
}

# Main execution
main() {
  echo "SBOM Generator for CNCF Projects (powered by waybill)"
  echo "======================================================"
  echo ""
  echo "Settings:"
  echo "  Force regenerate: $FORCE_REGENERATE"
  echo "  Project filter: ${PROJECT_FILTER:-all}"
  echo "  Max releases per repo: $MAX_RELEASES"
  echo "  Output directory: $SBOM_BASE_DIR"
  echo "  waybill version: $WAYBILL_VERSION"
  echo ""

  check_prerequisites
  install_waybill

  # Ensure data file exists
  if [ ! -f "$DATA_FILE" ]; then
    echo "Error: Repository data file not found: $DATA_FILE"
    exit 1
  fi

  # Get repositories to process
  if [ -n "$PROJECT_FILTER" ]; then
    OWNER=$(echo "$PROJECT_FILTER" | cut -d'/' -f1)
    REPO=$(echo "$PROJECT_FILTER" | cut -d'/' -f2)
    REPOS=$(yq -o=json '.repositories | map(select(.owner == "'"$OWNER"'" and .repo == "'"$REPO"'"))' "$DATA_FILE")
  else
    REPOS=$(yq -o=json '.repositories' "$DATA_FILE")
  fi

  # Process each repository
  local REPO_COUNT
  REPO_COUNT=$(echo "$REPOS" | jq 'length')

  if [ "$REPO_COUNT" -eq 0 ]; then
    echo "No repositories found matching filter: $PROJECT_FILTER"
    exit 1
  fi

  echo "Found $REPO_COUNT repositories to process"

  echo "$REPOS" | jq -c '.[]' | while read -r REPO_JSON; do
    OWNER=$(echo "$REPO_JSON" | jq -r '.owner')
    REPO=$(echo "$REPO_JSON" | jq -r '.repo')
    NAME=$(echo "$REPO_JSON" | jq -r '.name')

    process_repository "$OWNER" "$REPO" "$NAME"
  done

  generate_index

  echo ""
  echo "=========================================="
  echo "SBOM generation complete!"
  echo "=========================================="
}

main "$@"
