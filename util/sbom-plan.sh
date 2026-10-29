#!/usr/bin/env bash
#
# Plans one SBOM run: which (repository, tag) pairs are missing from the buckets.
# The workflow splits the resulting list over a few worker jobs (util/sbom-worker.sh)
# instead of starting one job per repository.
#
# Usage: sbom-plan.sh OUT_FILE
#   OUT_FILE gets one JSON object per line:
#     {owner, repo, name, tag, bucket, key_prefix, supplier}
#   key_prefix is the bucket folder ("argo/" or "argo/argo-workflows/"); the key
#   layout below must match util/s3-upload.sh:upload_sbom_dir.
#   Prints "repos=N" and "items=N" (GITHUB_OUTPUT format) on stdout.
#
# Environment:
#   PROJECT_SOURCE   all | cncf | manual | discovered   (default all)
#   PROJECT_FILTER   owner/repo, empty for all
#   RELEASES_MODE    recent (releases of the last 60 days) | latest (newest MAX_RELEASES)
#   MAX_RELEASES     default 3
#   FORCE_REGENERATE true: ignore what the bucket has
#   S3_ENDPOINT, S3_REGION, PROJECT_BUCKET, SUBPROJECT_BUCKET
#   SBOM_DATA_DIR    default util/data
# Needs gh (GraphQL), jq, yq, aws.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=util/sbom-lib.sh
source "$SCRIPT_DIR/sbom-lib.sh"

OUT="${1:?usage: sbom-plan.sh OUT_FILE}"
PROJECT_SOURCE="${PROJECT_SOURCE:-all}"
PROJECT_FILTER="${PROJECT_FILTER:-}"
RELEASES_MODE="${RELEASES_MODE:-recent}"
MAX_RELEASES="${MAX_RELEASES:-3}"
FORCE_REGENERATE="${FORCE_REGENERATE:-false}"
DATA_DIR="${SBOM_DATA_DIR:-$SCRIPT_DIR/data}"
: "${PROJECT_BUCKET:?}" "${SUBPROJECT_BUCKET:?}" "${S3_ENDPOINT:?}" "${S3_REGION:?}"
[[ "$S3_ENDPOINT" != http://* && "$S3_ENDPOINT" != https://* ]] && S3_ENDPOINT="https://${S3_ENDPOINT}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Repositories with their bucket, folder and supplier (the CNCF project).
{
  if [[ "$PROJECT_SOURCE" != discovered ]]; then
    bash "$SCRIPT_DIR/prepare-project-matrix.sh" "$PROJECT_SOURCE" "$PROJECT_FILTER" "$DATA_DIR" |
      jq -c --arg bucket "$PROJECT_BUCKET" '.include[] | {owner, repo, name, bucket: $bucket, supplier: .name}' |
      while IFS= read -r r; do
        jq -c --arg p "$(sbom_slugify "$(jq -r .name <<<"$r")")/" '.key_prefix = $p' <<<"$r"
      done
  fi
  if [[ "$PROJECT_SOURCE" == all || "$PROJECT_SOURCE" == discovered ]] && [[ -f "$DATA_DIR/discovered-repos.yaml" ]]; then
    yq -o=json '.repositories' "$DATA_DIR/discovered-repos.yaml" |
      jq -c --arg f "$PROJECT_FILTER" '.[] | select($f == "" or ((.owner + "/" + .repo) | ascii_downcase) == ($f | ascii_downcase))
        | {owner, repo, name, parent_project: (.parent_project // ""), parent_repo: (.parent_repo // ""), discovered_by: (.discovered_by // "")}' |
      while IFS= read -r r; do
        # \x1f instead of tab: empty fields must not collapse
        IFS=$'\x1f' read -r owner repo pp pr db < <(jq -r '[.owner, .repo, .parent_project, .parent_repo, .discovered_by] | join("\u001f")' <<<"$r")
        supplier="$(sbom_resolve_parent_project "$pp" "$pr" "$db" "$owner")"
        parent="$(sbom_parent_slug "$pp" "$pr" "$db" "$owner")"
        jq -c --arg bucket "$SUBPROJECT_BUCKET" --arg s "$supplier" --arg p "${parent}/$(sbom_slugify "$repo")/" \
          '{owner, repo, name, bucket: $bucket, supplier: $s, key_prefix: $p}' <<<"$r"
      done
  fi
} >"$TMP/repos.jsonl"
REPOS=$(wc -l <"$TMP/repos.jsonl")
echo "Planning $REPOS repositories (source=$PROJECT_SOURCE mode=$RELEASES_MODE)" >&2

# 2. Releases and tags, 50 repositories per GraphQL query (REST would need one call
#    per repository and GITHUB_TOKEN allows 1000/h).
: >"$TMP/tags.jsonl"
split -l 50 -d -a 4 "$TMP/repos.jsonl" "$TMP/chunk."
for chunk in "$TMP"/chunk.*; do
  [[ -s "$chunk" ]] || continue
  QUERY="query {$(jq -r '"r\(input_line_number - 1): repository(owner: \(.owner | @json), name: \(.repo | @json)) { releases(first: 100, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { tagName isDraft isPrerelease publishedAt } } refs(refPrefix: \"refs/tags/\", first: 30, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) { nodes { name } } }"' "$chunk" | tr '\n' ' ') }"
  # Responses are ~200 KB; a dropped connection truncates the JSON, so retry.
  # gh exits 1 on partial errors (one unknown repo) although .data is complete: ignore its status.
  # GitHub answers these heavy queries with 504 at times: 6 tries, 15s..150s backoff.
  for attempt in 1 2 3 4 5 6; do
    gh api graphql -f query="$QUERY" >"$TMP/resp.json" 2>"$TMP/resp.err" || true
    jq -e '.data' "$TMP/resp.json" >/dev/null 2>&1 && break
    if [[ $attempt == 6 ]]; then
      echo "::error::GraphQL query failed: $(cat "$TMP/resp.err"; head -c 2000 "$TMP/resp.json")" >&2
      exit 1
    fi
    echo "::warning::GraphQL attempt $attempt failed, retrying: $(head -c 200 "$TMP/resp.err")" >&2
    sleep $((attempt * attempt * 10))
  done
  jq -r '.errors[]? | "::warning::\(.path[0] // "?"): \(.message)"' "$TMP/resp.json" >&2
  # Pair every repository with its answer; a missing repo yields null and no items.
  jq -c --slurpfile resp "$TMP/resp.json" '. as $repo | $resp[0].data["r\(input_line_number - 1)"] as $d
    | $repo + {releases: ($d.releases.nodes // []), tags: [$d.refs.nodes[]?.name]}' "$chunk" >>"$TMP/tags.jsonl"
done

# 3. What the buckets already have (one listing per bucket).
#    A listing error must stop the plan: an empty list would re-plan every SBOM.
list_keys() {
  local out
  out=$(AWS_PAGER="" aws s3api list-objects-v2 --endpoint-url "$S3_ENDPOINT" --region "$S3_REGION" \
    --bucket "$1" --query 'Contents[].Key' --output text)
  tr '\t' '\n' <<<"$out" | grep -v '^None$' || true
}
if [[ "$FORCE_REGENERATE" == true ]]; then
  : >"$TMP/keys.txt"
else
  { list_keys "$PROJECT_BUCKET"; list_keys "$SUBPROJECT_BUCKET"; } >"$TMP/keys.txt"
fi

# 4. Stable tags per repository (same rules as sbom_stable_tags), minus existing keys.
SINCE=$(date -u -d '60 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-60d +%Y-%m-%dT%H:%M:%SZ)
jq -nc --arg mode "$RELEASES_MODE" --arg since "$SINCE" --argjson limit "$MAX_RELEASES" \
   --arg pre "$SBOM_PRERELEASE_RE" --arg nested "$SBOM_NESTED_TAG_RE" --arg vtag "$SBOM_VERSION_TAG_RE" \
   --rawfile keys "$TMP/keys.txt" '
  ($keys | split("\n") | map(select(. != "")) | map({(.): true}) | add // {}) as $have
  | def stable: select((test($pre; "i") or test($nested)) | not);
    def version: sub("^v"; "");
    inputs
  | (if (.releases | length) > 0 then
       [.releases[] | select(.isDraft == false and .isPrerelease == false and ($mode != "recent" or .publishedAt >= $since)) | .tagName | stable]
     else
       [.tags[] | select(test($vtag)) | stable] | .[:$limit]
     end
     | if $mode == "latest" then .[:$limit] else . end) as $tags
  | . as $r
  | $tags[] | . as $tag | ($tag | version) as $v
  | ($r.key_prefix + $v + "/" + ($r.key_prefix | rtrimstr("/") | gsub("/"; "_")) + "_" + ($v | gsub("\\."; "_")) + "_spdx.json") as $key
  | select($have[$key] | not)
  | {owner: $r.owner, repo: $r.repo, name: $r.name, tag: $tag, bucket: $r.bucket, key_prefix: $r.key_prefix, supplier: $r.supplier}
' "$TMP/tags.jsonl" >"$OUT"

echo "repos=$REPOS"
echo "items=$(wc -l <"$OUT")"
