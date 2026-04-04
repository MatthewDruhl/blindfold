#!/usr/bin/env bash
# PreToolUse hook: blocks commands that would expose secret values.
# Exit 0 = allow, Exit 2 = deny
set -uo pipefail

REGISTRY="$HOME/.claude/secrets-registry.json"

INPUT=$(cat)

# Extract tool name and input in one jq call
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

# Platform-specific secret store patterns
case "$(uname -s)" in
  Darwin)
    [[ "$COMMAND" =~ security[[:space:]]+find-generic-password.*-w ]] && deny "Direct Keychain password read blocked."
    [[ "$COMMAND" =~ security[[:space:]]+dump-keychain ]] && deny "Keychain dump blocked."
    [[ "$COMMAND" =~ security[[:space:]]+export ]] && deny "Keychain export blocked."
    ;;
  Linux)
    [[ "$COMMAND" =~ secret-tool[[:space:]]+lookup.*claude-secrets ]] && deny "Direct secret-tool lookup blocked."
    [[ "$COMMAND" =~ gpg[[:space:]]+(-d|--decrypt).*\.claude/vault/ ]] && deny "Direct GPG vault decrypt blocked."
    ;;
esac

# Block reading registered .env files
if [[ -f "$REGISTRY" ]]; then
  ENV_PATHS=$(jq -r '
    [.global.envProfiles | values // empty] +
    [.projects | to_entries[]? | .value.envProfiles | values // empty]
    | unique | .[]
  ' "$REGISTRY" 2>/dev/null)

  while IFS= read -r env_path; do
    [[ -n "$env_path" ]] || continue

    if [[ "$TOOL_NAME" == "Read" && "$COMMAND" == "$env_path" ]]; then
      deny "Direct reading of registered .env file blocked."
    fi

    if [[ "$TOOL_NAME" == "Bash" && "$COMMAND" == *"$env_path"* ]]; then
      [[ "$COMMAND" =~ (cat|head|tail|less|more|bat|view|grep|rg|awk|sed|source|\.)[[:space:]] ]] && \
        deny "Reading registered .env file blocked."
    fi
  done <<< "$ENV_PATHS"
fi

exit 0
