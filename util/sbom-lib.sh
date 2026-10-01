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
