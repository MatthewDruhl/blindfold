#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
check_dependencies

if [[ ! -f "$REGISTRY" ]]; then
  echo "No secrets registered yet."
  exit 0
fi

BACKEND=$(detect_backend)
echo "Blindfold (backend: ${BACKEND})"
echo "=================================="
echo ""

REGISTRY_DATA=$(jq '{
  global_secrets: [.global.secrets[]?],
  projects: [.projects | to_entries[]? | {
    path: .key,
    secrets: [.value.secrets[]?]
  }]
}' "$REGISTRY" 2>/dev/null)

# Global secrets
GLOBAL_SECRETS=$(echo "$REGISTRY_DATA" | jq -r '.global_secrets[]?')

if [[ -n "$GLOBAL_SECRETS" ]]; then
  echo "GLOBAL:"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if secret_exists "$(make_account_key global "$name")"; then
      echo "  [ok] ${name}"
    else
      echo "  [!]  ${name} (not found in ${BACKEND})"
    fi
  done <<< "$GLOBAL_SECRETS"
  echo ""
fi

# Project secrets
echo "$REGISTRY_DATA" | jq -r '.projects[]? | "\(.path)"' | while IFS= read -r project; do
  [[ -n "$project" ]] || continue
  P_SECRETS=$(echo "$REGISTRY_DATA" | jq -r --arg p "$project" '.projects[]? | select(.path == $p) | .secrets[]?')

  if [[ -n "$P_SECRETS" ]]; then
    echo "PROJECT: ${project}"
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      if secret_exists "$(make_account_key "$project" "$name")"; then
        echo "  [ok] ${name}"
      else
        echo "  [!]  ${name} (not found in ${BACKEND})"
      fi
    done <<< "$P_SECRETS"
    echo ""
  fi
done

TOTAL=$(echo "$REGISTRY_DATA" | jq '(.global_secrets | length) + ([.projects[]?.secrets | length] | add // 0)')
echo "Total: ${TOTAL} secrets"
