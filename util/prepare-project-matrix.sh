#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${1:-all}"
FILTER="${2:-}"
DATA_DIR="${3:-$SCRIPT_DIR/data}"

case "$SOURCE" in
  all) FILES=("$DATA_DIR/cncf-projects.yaml" "$DATA_DIR/repositories.yaml") ;;
  cncf) FILES=("$DATA_DIR/cncf-projects.yaml") ;;
  manual) FILES=("$DATA_DIR/repositories.yaml") ;;
  *)
    echo "Error: unsupported project source: $SOURCE" >&2
    exit 1
    ;;
esac

yq -o=json '.repositories' "${FILES[@]}" |
  jq -sc --arg filter "$FILTER" '
    def nonempty: type == "string" and test("\\S");
    if all(.[]; type == "array") then add
    else error("Each repository file must contain a repositories array") end
    | if all(.[]; type == "object"
        and (.owner | nonempty)
        and (.repo | nonempty)
        and (.name | nonempty)) then .
      else error("Each repository requires nonempty owner, repo, and name fields") end
    | unique_by((.owner + "/" + .repo) | ascii_downcase)
    | map(select($filter == "" or
        ((.owner + "/" + .repo | ascii_downcase) == ($filter | ascii_downcase))))
    | {include: .}
  '
