#!/usr/bin/env bash
#
# Post-processes an SPDX 2.3 JSON document produced by `waybill sbom scan` so
# that it is self-describing. Every path that writes SBOMs to a bucket calls
# this script (workflows, generate-sbom-local.sh, ingest-sbom-oci.sh,
# generate-sandbox-sbom.sh).
#
# Usage:
#   postprocess-spdx.sh [--owner OWNER] [--repo REPO] [--tag TAG] [--project NAME] FILE [OUTPUT]
#
# Fields written (all other content is left exactly as waybill produced it):
#   name                    "<owner>/<repo> <tag>"
#   root downloadLocation   "git+https://github.com/<owner>/<repo>.git@<tag>"
#   root purl               "pkg:github/<owner>/<repo>@<tag>" (replaces pkg:generic/... and
#                           earlier pkg:github/... purls; added if the root has none)
#   root supplier           "Organization: <project>"; without --project an existing supplier
#                           is kept unless it is a document creator (the tool), else NOASSERTION
#
# --owner/--repo/--tag default to the root package ("owner/repo" name and
# versionInfo), so already published documents can be processed without
# additional metadata. --project is the CNCF landscape project name (for a
# subproject: its parent project). The script is idempotent; documentNamespace
# is never touched, so it stays unique per document.

set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") [--owner OWNER] [--repo REPO] [--tag TAG] [--project NAME] FILE [OUTPUT]" >&2
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
[[ ${#ARGS[@]} -ge 1 && ${#ARGS[@]} -le 2 ]] || usage

INPUT="${ARGS[0]}"
OUTPUT="${ARGS[1]:-$INPUT}"

if [[ ! -s "$INPUT" ]]; then
  echo "Error: SBOM file is missing or empty: $INPUT" >&2
  exit 1
fi

TMP_OUT="$(mktemp "$(dirname "$OUTPUT")/.postprocess.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

jq --arg owner "$OWNER" --arg repo "$REPO" --arg tag "$TAG" --arg project "$PROJECT" '
  def usable: type == "string" and test("\\S") and . != "NOASSERTION" and . != "NONE";
  def purl_segment: ascii_downcase | @uri;

  if (.spdxVersion | type == "string" and startswith("SPDX-2.")) | not then
    error("expected an SPDX 2.x JSON document")
  else . end

  | ((.documentDescribes // [] | map(select(type == "string")) | .[0])
     // ([.relationships[]? | select(.spdxElementId == "SPDXRef-DOCUMENT"
          and .relationshipType == "DESCRIBES") | .relatedSpdxElement][0])) as $root_id
  | if ($root_id | type) != "string" then error("document does not describe a root package") else . end
  | ([.packages[]? | select(.SPDXID == $root_id)][0]) as $root
  | if $root == null then error("root package \($root_id) not found in packages") else . end

  # Missing coordinates come from the root package, i.e. waybill --root-name/--root-version.
  | ($root.name // "" | capture("^(?<o>[^/\\s]+)/(?<r>[^/\\s]+)$") // {o: "", r: ""}) as $from_root
  | (if $owner | usable then $owner else $from_root.o end) as $owner
  | (if $repo | usable then $repo else $from_root.r end) as $repo
  | (if $tag | usable then $tag elif ($root.versionInfo | usable) then $root.versionInfo else "" end) as $tag
  | if ([$owner, $repo, $tag] | all(usable)) | not then
      error("owner, repo and tag are required (pass --owner/--repo/--tag or use an owner/repo root package with a version)")
    else . end

  | ("pkg:github/\($owner | purl_segment)/\($repo | purl_segment)@\($tag | @uri)") as $purl
  | ("git+https://github.com/\($owner)/\($repo).git@\($tag)") as $download
  | ($project | gsub("[\\r\\n\\t]+"; " ") | gsub("^\\s+|\\s+$"; "")) as $project
  # An actor "Organization: Name (x)" is read as name + email; an explicit empty
  # contact keeps parenthesised project names such as "Open Policy Agent (OPA)" intact.
  # Organizations listed as document creators are the tool authors (waybill adds
  # "Organization: waybill contributors"); they never supply the product.
  | ([.creationInfo.creators[]? | select(type == "string" and startswith("Organization:"))]) as $tool_orgs
  | (if $project != "" then
       (if ($project | test("[()]")) then "Organization: \($project) ()" else "Organization: \($project)" end)
     elif ($root.supplier | usable) and ([$root.supplier] | inside($tool_orgs) | not) then $root.supplier
     else "NOASSERTION" end) as $supplier

  | def replaceable_purl:
      .referenceType == "purl"
      and (.referenceLocator | type == "string")
      and (.referenceLocator | startswith("pkg:generic/") or startswith("pkg:github/"));
    def fix_refs:
      (. // []) as $refs
      | if any($refs[]; replaceable_purl) then
          reduce $refs[] as $ref ({out: [], done: false};
            if ($ref | replaceable_purl) then
              if .done then . else .out += [$ref | .referenceLocator = $purl] | .done = true end
            else .out += [$ref] end)
          | .out
        else
          $refs + [{referenceCategory: "PACKAGE-MANAGER", referenceType: "purl", referenceLocator: $purl}]
        end;

  .name = "\($owner)/\($repo) \($tag)"
  | .packages |= map(
      if .SPDXID == $root_id then
        .downloadLocation = $download
        | .supplier = $supplier
        | .externalRefs |= fix_refs
      else . end)
' "$INPUT" >"$TMP_OUT"

chmod "$(printf '%04o' $((0666 & ~$(umask))))" "$TMP_OUT"
mv "$TMP_OUT" "$OUTPUT"
trap - EXIT
