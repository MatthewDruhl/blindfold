#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_dependencies

SCOPE_ARG="project"
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) [[ $# -ge 2 ]] || { echo "ERROR: --scope requires a value" >&2; exit 1; }
             SCOPE_ARG="$2"; shift 2 ;;
    -h|--help) echo "Usage: env-unregister.sh [--scope global|project] <PROFILE>"; exit 1 ;;
    *) PROFILE="$1"; shift ;;
  esac
done

[[ -n "$PROFILE" ]] || { echo "ERROR: Profile name required." >&2; exit 1; }
[[ -f "$REGISTRY" ]] || { echo "ERROR: No registry found." >&2; exit 1; }

SCOPE_KEY=$(parse_scope_arg "$SCOPE_ARG")

if [[ "$SCOPE_KEY" == "global" ]]; then
  update_registry "$(printf '.global.envProfiles |= del(.["%s"])' "$PROFILE")"
else
  update_registry "$(printf 'if .projects["%s"] then .projects["%s"].envProfiles |= del(.["%s"]) else . end' "$SCOPE_KEY" "$SCOPE_KEY" "$PROFILE")"
fi

echo "OK: Env profile '${PROFILE}' unregistered."
