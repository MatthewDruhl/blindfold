#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_dependencies

[[ $# -ge 1 && "$1" != "-h" && "$1" != "--help" ]] || { echo "Usage: env-keys.sh <PROFILE_NAME>"; exit 1; }

PROFILE="$1"
[[ -f "$REGISTRY" ]] || { echo "ERROR: No registry found." >&2; exit 1; }

ENV_PATH=$(resolve_env_profile "$PROFILE")
[[ -n "$ENV_PATH" ]] || { echo "ERROR: Profile '${PROFILE}' not found." >&2; exit 1; }
[[ -f "$ENV_PATH" ]] || { echo "ERROR: File missing: ${ENV_PATH}" >&2; exit 1; }

echo "Env Profile: ${PROFILE}"
echo "File: ${ENV_PATH}"
echo "Variables (keys only):"
env_key_names "$ENV_PATH" | while IFS= read -r key; do
  echo "  - ${key}"
done
