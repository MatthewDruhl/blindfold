#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_dependencies

usage() {
  echo "Usage: secret-store.sh [--scope global|project] [--register-only] <NAME>"
  exit 1
}

SCOPE_ARG="global"
REGISTER_ONLY=false
NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) [[ $# -ge 2 ]] || { echo "ERROR: --scope requires a value" >&2; exit 1; }
             SCOPE_ARG="$2"; shift 2 ;;
    --register-only) REGISTER_ONLY=true; shift ;;
    -h|--help) usage ;;
    *) NAME="$1"; shift ;;
  esac
done

[[ -n "$NAME" ]] || { echo "ERROR: Secret name is required." >&2; usage; }
[[ "$NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "ERROR: Name must be alphanumeric with underscores." >&2; exit 1; }

SCOPE=$(parse_scope_arg "$SCOPE_ARG")
ACCOUNT=$(make_account_key "$SCOPE" "$NAME")

if [[ "$REGISTER_ONLY" == true ]]; then
  add_to_registry "$SCOPE" "$NAME"
  echo "OK: ${NAME} registered (scope: ${SCOPE}). Store the value in your secret backend manually."
  exit 0
fi

VALUE=$(prompt_secret_dialog "$NAME")
[[ -n "$VALUE" ]] || { echo "ERROR: No value provided. Cancelled." >&2; exit 1; }

store_secret "$ACCOUNT" "$VALUE"
VALUE=""
add_to_registry "$SCOPE" "$NAME"
echo "OK: ${NAME} stored securely (scope: ${SCOPE})."
