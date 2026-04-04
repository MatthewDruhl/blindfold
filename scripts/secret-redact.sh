#!/usr/bin/env bash
# PostToolUse hook: scans Bash output for leaked secret values.
set -uo pipefail

REGISTRY="$HOME/.claude/secrets-registry.json"

INPUT=$(cat)

# Extract tool name and result in one jq call
PARSED=$(echo "$INPUT" | jq -r '[.tool_name // "", .tool_result.stdout // .tool_result // ""] | @tsv' 2>/dev/null)
TOOL_NAME="${PARSED%%	*}"
TOOL_RESULT="${PARSED#*	}"

[[ "$TOOL_NAME" == "Bash" && -n "$TOOL_RESULT" && -f "$REGISTRY" ]] || exit 0

SCRIPT_DIR="$(dirname "$0")"
[[ -f "$SCRIPT_DIR/lib.sh" ]] && source "$SCRIPT_DIR/lib.sh" || exit 0

LEAKED_NAMES=()
PROJECT_PATH=$(get_project_path)

# Check individual secrets
ALL_SECRETS=$(jq -r '
  [.global.secrets[]?] + [.projects | to_entries[]? | .value.secrets[]?]
  | unique | .[]
' "$REGISTRY" 2>/dev/null)

while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  for scope in "$PROJECT_PATH" "global"; do
    value=$(get_secret "$(make_account_key "$scope" "$name")")
    if [[ -n "$value" && ${#value} -ge $MIN_REDACT_LENGTH ]]; then
      [[ "$TOOL_RESULT" == *"$value"* ]] && LEAKED_NAMES+=("$name")
      break
    fi
  done
done <<< "$ALL_SECRETS"

# Check env profile values (use process substitution to avoid subshell)
ALL_ENV_PATHS=$(get_all_env_paths)
while IFS= read -r env_path; do
  [[ -n "$env_path" && -f "$env_path" ]] || continue
  while IFS='=' read -r key val; do
    [[ -n "$key" && -n "$val" ]] || continue
    val="${val#\"}" ; val="${val%\"}"
    val="${val#\'}" ; val="${val%\'}"
    [[ ${#val} -ge $MIN_REDACT_LENGTH && "$TOOL_RESULT" == *"$val"* ]] && LEAKED_NAMES+=("ENV:${key}")
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_path" 2>/dev/null)
done <<< "$ALL_ENV_PATHS"

if [[ ${#LEAKED_NAMES[@]} -gt 0 ]]; then
  NAMES_STR=$(IFS=', '; echo "${LEAKED_NAMES[*]}")
  jq -n --arg msg "WARNING: Secret values detected in output for: ${NAMES_STR}. DO NOT reference or repeat these values." \
    '{"systemMessage": $msg}' >&2
fi

exit 0
