#!/usr/bin/env bash
# PreToolUse hook: enforces kernel-level sandbox on Bash commands (macOS Seatbelt)
# and blocks direct reads of registered .env files.
# Exit 0 with JSON = allow (possibly with modified command)
# Exit 2 = deny
set -uo pipefail

REGISTRY="$HOME/.claude/secrets-registry.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_PROFILE="${SCRIPT_DIR}/sandbox.sb"
PLATFORM="$(uname -s)"

INPUT=$(</dev/stdin)

PARSED=$(echo "$INPUT" | jq -r '[.tool_name // "", .tool_input.command // .tool_input.file_path // ""] | @tsv' 2>/dev/null)
TOOL_NAME="${PARSED%%	*}"
COMMAND="${PARSED#*	}"

[[ "$TOOL_NAME" == "Bash" || "$TOOL_NAME" == "Read" ]] || exit 0
[[ -n "$COMMAND" ]] || exit 0

deny() {
  echo "DENIED by Blindfold: $1" >&2
  echo "Use secret-exec.sh to run commands that need secrets." >&2
  exit 2
}

# --- .env file blocking (applies to both Bash and Read) ---
if [[ -f "$REGISTRY" ]]; then
  # Only parse env paths if profiles actually exist
  HAS_PROFILES=$(jq '(.global.envProfiles | length) + ([.projects | to_entries[]? | .value.envProfiles | length] | add // 0) > 0' "$REGISTRY" 2>/dev/null)
  if [[ "$HAS_PROFILES" == "true" ]]; then
    ENV_PATHS=$(jq -r '
      [.global.envProfiles | values // empty] +
      [.projects | to_entries[]? | .value.envProfiles | values // empty]
      | unique | .[]
    ' "$REGISTRY" 2>/dev/null)

    while IFS= read -r env_path; do
      [[ -n "$env_path" ]] || continue
      [[ "$TOOL_NAME" == "Read" && "$COMMAND" == "$env_path" ]] && deny "Direct reading of registered .env file blocked."
      [[ "$TOOL_NAME" == "Bash" && "$COMMAND" == *"$env_path"* ]] && deny "Access to registered .env file blocked."
    done <<< "$ENV_PATHS"
  fi
fi

# --- Sandbox wrapping (Bash only) ---
[[ "$TOOL_NAME" == "Bash" ]] || exit 0

# Exempt Blindfold's own scripts -- must be the START of the command (not a substring)
# to prevent bypass via: echo secret-exec.sh && security dump-keychain
EXEC_PATH="${SCRIPT_DIR}/secret-exec.sh"
STORE_PATH="${SCRIPT_DIR}/secret-store.sh"
LIST_PATH="${SCRIPT_DIR}/secret-list.sh"
DELETE_PATH="${SCRIPT_DIR}/secret-delete.sh"
ENVR_PATH="${SCRIPT_DIR}/env-register.sh"
ENVK_PATH="${SCRIPT_DIR}/env-keys.sh"
ENVU_PATH="${SCRIPT_DIR}/env-unregister.sh"

for exempt in "$EXEC_PATH" "$STORE_PATH" "$LIST_PATH" "$DELETE_PATH" "$ENVR_PATH" "$ENVK_PATH" "$ENVU_PATH"; do
  # Match: "bash /full/path/to/script.sh" at the start of the command
  [[ "$COMMAND" == "bash ${exempt}"* ]] && exit 0
  [[ "$COMMAND" == "${exempt}"* ]] && exit 0
done

# On macOS with Seatbelt: wrap the command in sandbox-exec
if [[ "$PLATFORM" == "Darwin" && -f "$SANDBOX_PROFILE" ]] && command -v sandbox-exec &>/dev/null; then
  # Escape single quotes using bash native (no sed fork)
  ESCAPED_CMD="${COMMAND//\'/\'\\\'\'}"
  WRAPPED="sandbox-exec -f '${SANDBOX_PROFILE}' bash -c '${ESCAPED_CMD}'"

  jq -n --arg cmd "$WRAPPED" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: {
        command: $cmd
      }
    }
  }'
  exit 0
fi

# --- Fallback: string matching for platforms without sandbox ---
case "$PLATFORM" in
  Darwin)
    [[ "$COMMAND" == *"find-generic-password"*"-w"* ]] && deny "Keychain password read blocked."
    [[ "$COMMAND" == *"find-generic-password"*"claude-secret"* ]] && deny "Keychain read of managed secret blocked."
    [[ "$COMMAND" == *"dump-keychain"* ]] && deny "Keychain dump blocked."
    [[ "$COMMAND" == *"claude-secrets"*"-w"* ]] && deny "Keychain read blocked."
    ;;
  Linux)
    [[ "$COMMAND" == *"secret-tool"*"lookup"*"claude-secrets"* ]] && deny "secret-tool lookup blocked."
    [[ "$COMMAND" == *".claude/vault/"*".gpg"* ]] && deny "GPG vault access blocked."
    ;;
esac

exit 0
