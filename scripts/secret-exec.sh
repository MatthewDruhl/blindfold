#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
check_dependencies

ENV_PROFILE=""
COMMAND=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) [[ $# -ge 2 ]] || { echo "ERROR: --env requires a profile name" >&2; exit 1; }
           ENV_PROFILE="$2"; shift 2 ;;
    -h|--help) echo "Usage: secret-exec.sh [--env <profile>] '<command>'"; exit 1 ;;
    *) COMMAND="$1"; shift ;;
  esac
done

[[ -n "$COMMAND" ]] || { echo "ERROR: Command is required." >&2; exit 1; }
[[ -f "$REGISTRY" ]] || { echo "ERROR: Registry not found." >&2; exit 1; }

PROJECT_PATH=$(get_project_path)

# Secure temp files (600 permissions, cleaned up on exit)
OLD_UMASK=$(umask)
umask 077
REDACT_FILE=$(mktemp)
EXEC_SCRIPT=$(mktemp)
STDOUT_TMP=$(mktemp)
STDERR_TMP=$(mktemp)
umask "$OLD_UMASK"
trap 'rm -f "$REDACT_FILE" "$EXEC_SCRIPT" "$STDOUT_TMP" "$STDERR_TMP" 2>/dev/null' EXIT

echo '#!/usr/bin/env bash' > "$EXEC_SCRIPT"

# Resolve {{PLACEHOLDER}} secrets
PLACEHOLDERS=$(echo "$COMMAND" | grep -oE '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' | sort -u || true)
RESOLVED_CMD="$COMMAND"

while IFS= read -r placeholder; do
  [[ -n "$placeholder" ]] || continue
  name="${placeholder#\{\{}"
  name="${name%\}\}}"

  value=$(get_secret "$(make_account_key "$PROJECT_PATH" "$name")")
  [[ -n "$value" ]] || value=$(get_secret "$(make_account_key global "$name")")
  [[ -n "$value" ]] || { echo "ERROR: Secret '${name}' not found." >&2; exit 1; }

  printf '%s\t%s\n' "$name" "$value" >> "$REDACT_FILE"
  printf 'export __SV_%s=%q\n' "$name" "$value" >> "$EXEC_SCRIPT"
  RESOLVED_CMD="${RESOLVED_CMD//"{{${name}}}"/"\${__SV_${name}}"}"
done <<< "$PLACEHOLDERS"

# Load env profile
if [[ -n "$ENV_PROFILE" ]]; then
  ENV_PATH=$(resolve_env_profile "$ENV_PROFILE")
  [[ -n "$ENV_PATH" ]] || { echo "ERROR: Env profile '${ENV_PROFILE}' not found." >&2; exit 1; }
  [[ -f "$ENV_PATH" ]] || { echo "ERROR: Env file missing: ${ENV_PATH}" >&2; exit 1; }

  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_PATH" 2>/dev/null | while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    val="${val#\"}" ; val="${val%\"}"
    val="${val#\'}" ; val="${val%\'}"
    printf 'ENV:%s\t%s\n' "$key" "$val" >> "$REDACT_FILE"
    printf 'export %s=%q\n' "$key" "$val" >> "$EXEC_SCRIPT"
  done
fi

echo "$RESOLVED_CMD" >> "$EXEC_SCRIPT"

# Execute
bash "$EXEC_SCRIPT" > "$STDOUT_TMP" 2> "$STDERR_TMP"
CMD_EXIT=$?
rm -f "$EXEC_SCRIPT"

# Redact secret values from output using awk -v (safe from injection)
while IFS=$'\t' read -r label value; do
  [[ -n "$value" && ${#value} -ge $MIN_REDACT_LENGTH ]] || continue
  for f in "$STDOUT_TMP" "$STDERR_TMP"; do
    awk -v find="$value" -v repl="[REDACTED:${label}]" '{
      while (idx = index($0, find)) {
        $0 = substr($0, 1, idx-1) repl substr($0, idx + length(find))
      }
      print
    }' "$f" > "${f}.redacted" && mv "${f}.redacted" "$f"
  done
done < "$REDACT_FILE"

STDOUT_CONTENT=$(cat "$STDOUT_TMP")
STDERR_CONTENT=$(cat "$STDERR_TMP")

[[ -z "$STDOUT_CONTENT" ]] || echo "$STDOUT_CONTENT"
[[ -z "$STDERR_CONTENT" ]] || echo "$STDERR_CONTENT" >&2

exit "$CMD_EXIT"
