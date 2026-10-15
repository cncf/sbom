#!/usr/bin/env bash
#
# Post-processes a CycloneDX JSON document a project attached to its release so
# that it identifies the repository the same way our SPDX documents do.
# Counterpart of postprocess-spdx.sh; every path that uploads *_cdx.json calls it.
#
# Usage:
#   postprocess-cdx.sh --owner OWNER --repo REPO --tag TAG [--project NAME] FILE [OUTPUT]
#
# Fields written (everything else is left as the producing tool emitted it):
#   metadata.component.name / version   "<owner>/<repo>" / "<tag>"
#   metadata.component.externalReferences  + {type: vcs, url: https://github.com/<owner>/<repo>}
#   metadata.supplier.name              "<project>" (only with --project)
# The component purl is kept: CycloneDX allows one, and the tool's (e.g.
# pkg:golang/...) carries ecosystem information a pkg:github purl would lose.

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") --owner OWNER --repo REPO --tag TAG [--project NAME] FILE [OUTPUT]" >&2
  exit 2
}

OWNER="" REPO="" TAG="" PROJECT=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="${2-}"; shift 2 ;;
    --repo) REPO="${2-}"; shift 2 ;;
    --tag) TAG="${2-}"; shift 2 ;;
    --project) PROJECT="${2-}"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; ARGS+=("$@"); break ;;
    -*) echo "Error: unknown option: $1" >&2; usage ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ ${#ARGS[@]} -ge 1 && ${#ARGS[@]} -le 2 && -n "$OWNER" && -n "$REPO" && -n "$TAG" ]] || usage

INPUT="${ARGS[0]}"
OUTPUT="${ARGS[1]:-$INPUT}"
[[ -s "$INPUT" ]] || { echo "Error: SBOM file is missing or empty: $INPUT" >&2; exit 1; }

TMP_OUT="$(mktemp "$(dirname "$OUTPUT")/.postprocess.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

jq --arg owner "$OWNER" --arg repo "$REPO" --arg tag "$TAG" --arg project "$PROJECT" '
  if .bomFormat != "CycloneDX" then error("expected a CycloneDX JSON document") else . end
  | ("https://github.com/\($owner)/\($repo)") as $vcs
  | .metadata.component |= ((. // {type: "application"})
      | .name = "\($owner)/\($repo)"
      | .version = $tag
      | .externalReferences = ([.externalReferences[]? | select(.type != "vcs")] + [{type: "vcs", url: $vcs}]))
  | if $project != "" then .metadata.supplier = ((.metadata.supplier // {}) | .name = $project) else . end
' "$INPUT" >"$TMP_OUT"

chmod "$(printf '%04o' $((0666 & ~$(umask))))" "$TMP_OUT"
mv "$TMP_OUT" "$OUTPUT"
trap - EXIT
