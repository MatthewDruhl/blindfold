#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_dependencies

SCOPE_ARG="project"
PROFILE=""
ENV_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) [[ $# -ge 2 ]] || { echo "ERROR: --scope requires a value" >&2; exit 1; }
             SCOPE_ARG="$2"; shift 2 ;;
    -h|--help) echo "Usage: env-register.sh [--scope global|project] <PROFILE> <PATH>"; exit 1 ;;
    *)
      if [[ -z "$PROFILE" ]]; then PROFILE="$1"
      elif [[ -z "$ENV_PATH" ]]; then ENV_PATH="$1"
      fi
      shift ;;
  esac
done

[[ -n "$PROFILE" && -n "$ENV_PATH" ]] || { echo "ERROR: Profile name and .env file path required." >&2; exit 1; }
[[ "$PROFILE" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || { echo "ERROR: Invalid profile name." >&2; exit 1; }

# Resolve to absolute path
[[ "$ENV_PATH" = /* ]] || ENV_PATH="$(cd "$(dirname "$ENV_PATH")" && pwd)/$(basename "$ENV_PATH")"
[[ -f "$ENV_PATH" ]] || { echo "ERROR: File not found: ${ENV_PATH}" >&2; exit 1; }

ensure_registry
SCOPE_KEY=$(parse_scope_arg "$SCOPE_ARG")

if [[ "$SCOPE_KEY" == "global" ]]; then
  update_registry "$(printf '.global.envProfiles["%s"] = "%s"' "$PROFILE" "$ENV_PATH")"
else
  update_registry "$(printf 'if .projects["%s"] == null then .projects["%s"] = {"secrets": [], "envProfiles": {("%s"): "%s"}} else .projects["%s"].envProfiles["%s"] = "%s" end' "$SCOPE_KEY" "$SCOPE_KEY" "$PROFILE" "$ENV_PATH" "$SCOPE_KEY" "$PROFILE" "$ENV_PATH")"
fi

echo "OK: Env profile '${PROFILE}' registered (scope: ${SCOPE_KEY})."
echo "  File: ${ENV_PATH}"
echo "  Variables ($(env_key_count "$ENV_PATH")):"
env_key_names "$ENV_PATH" | while IFS= read -r key; do
  echo "    - ${key}"
done
