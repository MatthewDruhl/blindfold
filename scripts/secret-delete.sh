#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_dependencies

SCOPE_ARG="global"
NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) [[ $# -ge 2 ]] || { echo "ERROR: --scope requires a value" >&2; exit 1; }
             SCOPE_ARG="$2"; shift 2 ;;
    -h|--help) echo "Usage: secret-delete.sh [--scope global|project] <NAME>"; exit 1 ;;
    *) NAME="$1"; shift ;;
  esac
done

[[ -n "$NAME" ]] || { echo "ERROR: Secret name is required." >&2; exit 1; }

SCOPE=$(parse_scope_arg "$SCOPE_ARG")
ACCOUNT=$(make_account_key "$SCOPE" "$NAME")

delete_secret "$ACCOUNT"

if [[ -f "$REGISTRY" ]]; then
  if [[ "$SCOPE" == "global" ]]; then
    update_registry "$(printf '.global.secrets = [.global.secrets[] | select(. != "%s")]' "$NAME")"
  else
    update_registry "$(printf 'if .projects["%s"] then .projects["%s"].secrets = [.projects["%s"].secrets[] | select(. != "%s")] else . end' "$SCOPE" "$SCOPE" "$SCOPE" "$NAME")"
  fi
fi

echo "OK: ${NAME} deleted (scope: ${SCOPE})."
