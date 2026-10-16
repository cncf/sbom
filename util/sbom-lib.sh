#!/usr/bin/env bash
#
# Shared naming helpers for SBOM object keys. Source this file; do not execute it.
#
# Every path that writes to the buckets (workflows, ingest, migration) must
# derive folder names through these functions so that a project and its
# subprojects always share one folder slug:
#   cncf-project-sboms:    <project-slug>/<version>/...
#   cncf-subproject-sboms: <project-slug>/<subproject>/<version>/...

SBOM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBOM_PROJECTS_FILE="${SBOM_PROJECTS_FILE:-$SBOM_LIB_DIR/data/cncf-projects.yaml}"

# Folder slug for a project or repository name: lowercase ASCII, spaces become
# '-', every other character outside [a-z0-9-] is dropped.
# "Argo" -> "argo", "Aeraki Mesh" -> "aeraki-mesh", "Open Policy Agent (OPA)" -> "open-policy-agent-opa".
sbom_slugify() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr ' ' '-' | LC_ALL=C tr -cd 'a-z0-9-'
}

# Prints "owner/repo" from a discovered_by value such as "org-scan from argoproj/argo-cd".
sbom_discovered_by_repo() {
  local discovered_by="$1"
  if [[ "$discovered_by" =~ from[[:space:]]+([^/[:space:]]+/[^[:space:]]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Prints the landscape name of the CNCF project that owns a subproject, or
# nothing when it cannot be determined. Resolution order:
#   1. the explicit parent_project recorded by util/discover-repos
#   2. parent_repo (or discovered_by's owner/repo) looked up in cncf-projects.yaml
# There is deliberately no guess from the GitHub owner alone (see
# resolveParentProject in util/discover-repos/main.go).
# Usage: sbom_resolve_parent_project <parent_project> <parent_repo> <discovered_by> <owner>
sbom_resolve_parent_project() {
  local parent_project="$1" parent_repo="$2" discovered_by="$3"

  if [[ -n "${parent_project//[[:space:]]/}" ]]; then
    printf '%s' "$parent_project"
    return 0
  fi

  [[ -n "$parent_repo" ]] || parent_repo="$(sbom_discovered_by_repo "$discovered_by")"
  if [[ -z "$parent_repo" || ! -f "$SBOM_PROJECTS_FILE" ]] || ! command -v yq >/dev/null 2>&1; then
    return 0
  fi

  yq -r '.repositories[] | [.owner, .repo, .name] | @tsv' "$SBOM_PROJECTS_FILE" |
    awk -F'\t' -v want="$(printf '%s' "$parent_repo" | LC_ALL=C tr '[:upper:]' '[:lower:]')" '
      found == "" && tolower($1 "/" $2) == want { found = $3 }
      END { printf "%s", found }'
}

# Pre-2026-10 parent folder: the parent's *repository* name (or the owner).
# Kept as the last fallback and to plan migrations away from it.
# Usage: sbom_legacy_parent_slug <discovered_by> <owner>
sbom_legacy_parent_slug() {
  local discovered_by="$1" owner="$2" parent_repo
  parent_repo="$(sbom_discovered_by_repo "$discovered_by")"
  if [[ -n "$parent_repo" ]]; then
    sbom_slugify "${parent_repo#*/}"
  else
    sbom_slugify "$owner"
  fi
}

# Parent folder slug for a subproject; equals the parent project's folder in
# the project bucket whenever the parent project is known.
# Usage: sbom_parent_slug <parent_project> <parent_repo> <discovered_by> <owner>
sbom_parent_slug() {
  local name
  name="$(sbom_resolve_parent_project "$@")"
  if [[ -n "$name" ]]; then
    sbom_slugify "$name"
  else
    sbom_legacy_parent_slug "$3" "$4"
  fi
}

# Prints "spdx" (SPDX 2.x), "spdx3" or "cdx" (CycloneDX) for a JSON SBOM file,
# nothing when the file is none of these.
sbom_format_of() {
  jq -r 'if (.spdxVersion // "" | tostring | startswith("SPDX-2.")) then "spdx"
         elif (.bomFormat // "") == "CycloneDX" then "cdx"
         elif (.["@context"] // "" | tostring | test("spdx.org/rdf/3")) then "spdx3"
         else empty end' "$1" 2>/dev/null
}

# Pattern of a release asset built for one OS/arch (a binary or image SBOM).
SBOM_PER_ARCH_RE='linux|darwin|windows|amd64|arm64|aarch64|x86_64|ppc64|s390x|riscv|386'

# Downloads the SBOMs a project attached to a GitHub release. Per format the
# largest JSON asset (max 100 MB) wins, project-wide ones (name without OS/arch)
# before per-binary ones. A project-wide asset lands in <base>_{spdx,spdx3,cdx}.json
# and replaces our own scan; a per-binary one in <base>_release_{spdx,spdx3,cdx}.json
# next to it. The format is detected by content. A tag without a release is not an
# error. Needs gh, curl, jq.
# shortcut: tag-value SPDX (istio), tarballs (argo-cd) and XML CycloneDX are ignored,
# and only the first 12 candidates are downloaded (otel ships 800+ per-arch SBOMs);
# add a converter / smarter pick when a project publishes only those.
# Usage: sbom_import_release_assets <owner> <repo> <tag> <base>
sbom_import_release_assets() {
  local owner="$1" repo="$2" tag="$3" base="$4" url file fmt tmp urls name out
  tmp="$(mktemp -d)"
  if ! urls="$(gh api "repos/${owner}/${repo}/releases/tags/${tag}" --jq \
      '.assets | map(select(.size <= 104857600 and (.name | ascii_downcase | test("(spdx|cdx|cyclonedx|bom).*\\.json$"))))
       | sort_by((.name | ascii_downcase | test("'"$SBOM_PER_ARCH_RE"'")), -.size)
       | limit(12; .[]) | .browser_download_url' \
      2>"$tmp/err")"; then
    grep -q 'HTTP 404' "$tmp/err" || cat "$tmp/err" >&2
    urls=""
  fi
  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    name="${url##*/}"
    file="$tmp/$name"
    curl -fsSL --show-error --max-filesize 104857600 "$url" -o "$file" || continue
    fmt="$(sbom_format_of "$file")"
    [[ -n "$fmt" ]] || continue
    out="${base}_${fmt}.json"
    [[ "${name,,}" =~ $SBOM_PER_ARCH_RE ]] && out="${base}_release_${fmt}.json"
    # assets come project-wide first, then largest, so the first usable one per format wins
    [[ -e "${base}_${fmt}.json" || -e "${base}_release_${fmt}.json" ]] && continue
    mv "$file" "$out" && echo "Using release asset $name as ${out##*/}"
  done <<<"$urls"
  rm -rf "$tmp"
}

# Version of a tag as used in paths and keys: "v5.8.3" -> "5.8.3".
sbom_version_of_tag() {
  local v="${1##*/}"
  printf '%s\n' "${v#v}"
}

# Prints the stable tags of a repo, newest first, one per line. Uses GitHub
# releases (draft/prerelease excluded; mode "recent" only those published after
# <since>). Repos without releases fall back to the newest <tag_limit> semver tags.
# A 404 prints a warning and nothing else; any other API error returns 1.
# Usage: sbom_stable_tags <owner> <repo> <mode> <since> <tag_limit>
# Shared by sbom_stable_tags and sbom-plan.sh (jq test()).
SBOM_PRERELEASE_RE='[-.](alpha|beta|rc|pre|preview|dev|devel|snapshot|nightly|canary|test|draft|wip)([-.]?[0-9]+)?$'
# Tags with a path segment (kustomize: api/v0.21.3 + kyaml/v0.21.3, pipecd: pkg/.../v0.1.0)
# version a sub-component; the key uses only the version, so they would collide. Skip them.
SBOM_NESTED_TAG_RE='/'
SBOM_VERSION_TAG_RE='^v?[0-9]+\.[0-9]+'

sbom_stable_tags() {
  local owner="$1" repo="$2" mode="$3" since="$4" limit="$5" out
  local pre="$SBOM_PRERELEASE_RE"
  if ! out="$(gh api "repos/${owner}/${repo}/releases?per_page=100" 2>&1)"; then
    if grep -q '404' <<<"$out"; then
      echo "::warning::Repository ${owner}/${repo} not found or releases not accessible (404), skipping" >&2
      return 0
    fi
    echo "::error::Failed to fetch releases for ${owner}/${repo}: ${out}" >&2
    return 1
  fi
  if ! jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    echo "::error::Unexpected releases response for ${owner}/${repo}: ${out}" >&2
    return 1
  fi
  if [ "$(jq 'length' <<<"$out")" -gt 0 ]; then
    jq -r --arg since "$since" --arg mode "$mode" \
      '.[] | select(.draft == false and .prerelease == false and ($mode != "recent" or .published_at >= $since)) | .tag_name' <<<"$out" |
      grep -viE "$pre" | grep -vE "$SBOM_NESTED_TAG_RE" || true
    return 0
  fi
  if ! out="$(gh api "repos/${owner}/${repo}/tags?per_page=100" 2>&1)"; then
    grep -q '404' <<<"$out" && return 0
    echo "::error::Failed to fetch tags for ${owner}/${repo}: ${out}" >&2
    return 1
  fi
  jq -r '.[].name' <<<"$out" | grep -E "$SBOM_VERSION_TAG_RE" | grep -viE "$pre" | grep -vE "$SBOM_NESTED_TAG_RE" | head -n "$limit" || true
}

# Waybill scan with the flags all repo SBOMs use.
# ClearlyDefined is opt-in since waybill 0.10 (fills licenseConcluded). go-mod-why is
# off because with a Go toolchain on the runner it misclassifies multi-workspace repos
# (flux2: 4 runtime deps left); build/test deps are still typed via *_DEPENDENCY_OF
# relationships and waybill:lifecycle-scope annotations.
# Usage: sbom_waybill_scan <owner> <repo> <tag> <src_dir> <out_file>
sbom_waybill_scan() {
  waybill sbom scan \
    --path "$4" \
    --format spdx-2.3-json \
    --clearly-defined --no-go-mod-why \
    --root-name "$1/$2" \
    --root-version "$3" \
    --repo "https://github.com/$1/$2.git" \
    --git-ref "$3" \
    --output "$5"
}
