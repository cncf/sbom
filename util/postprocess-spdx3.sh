#!/usr/bin/env bash
#
# Post-processes an SPDX 3 JSON-LD document a project attached to its release so
# that it identifies the repository the same way our SPDX 2.x documents do.
# Counterpart of postprocess-spdx.sh; every path that uploads *_spdx3.json calls it.
# BOMHort reads SPDX 3 through protobom: document name from SpdxDocument.name,
# roots from rootElement, version from software_packageVersion, supplier from
# suppliedBy -> Agent element.
#
# Usage:
#   postprocess-spdx3.sh --owner OWNER --repo REPO --tag TAG [--project NAME] FILE [OUTPUT]
#
# Fields written (everything else is left as the producing tool emitted it):
#   SpdxDocument.name                       "<owner>/<repo> <tag>"
#   root package name / software_packageVersion / software_downloadLocation
#   root package suppliedBy -> new Organization agent "<project>" (only with --project)
# Roots are the SpdxDocument.rootElement targets, else the targets of a
# "describes" relationship from the document. Without a root the script fails
# so the caller falls back to a Waybill scan.

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
  if (.["@graph"] | type) != "array" or ([.["@graph"][] | select(.type == "SpdxDocument")] | length) != 1
    then error("expected an SPDX 3 JSON-LD document with one SpdxDocument") else . end
  | (.["@graph"] | map(select(.type == "SpdxDocument"))[0]) as $doc
  | ((($doc.rootElement // []) | if type == "array" then . else [.] end)
      + [.["@graph"][] | select(.type == "Relationship" and .relationshipType == "describes" and .from == $doc.spdxId) | .to[]?]
     | unique) as $roots
  | if ($roots | length) == 0 then error("SPDX 3 document has no root element") else . end
  | "\($doc.spdxId)/agent/supplier" as $agent
  | .["@graph"] |= map(
      if .type == "SpdxDocument" then .name = "\($owner)/\($repo) \($tag)"
      elif (.spdxId as $id | $roots | index($id)) != null then
        .name = "\($owner)/\($repo)"
        | .software_packageVersion = $tag
        | .software_downloadLocation = "git+https://github.com/\($owner)/\($repo).git@\($tag)"
        | if $project != "" then .suppliedBy = $agent else . end
      else . end)
  | if $project != "" then
      .["@graph"] = [.["@graph"][] | select(.spdxId != $agent)]
        + [{type: "Organization", spdxId: $agent, name: $project, creationInfo: $doc.creationInfo}]
    else . end
' "$INPUT" >"$TMP_OUT"

chmod "$(printf '%04o' $((0666 & ~$(umask))))" "$TMP_OUT"
mv "$TMP_OUT" "$OUTPUT"
trap - EXIT
