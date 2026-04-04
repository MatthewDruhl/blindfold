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

# Extract everything in one jq pass
REGISTRY_DATA=$(jq '{
  global_secrets: [.global.secrets[]?],
  global_profiles: [.global.envProfiles | to_entries[]? | {name: .key, path: .value}],
  projects: [.projects | to_entries[]? | {
    path: .key,
    secrets: [.value.secrets[]?],
    profiles: [.value.envProfiles | to_entries[]? | {name: .key, path: .value}]
  }]
}' "$REGISTRY" 2>/dev/null)

# Global secrets
GLOBAL_SECRETS=$(echo "$REGISTRY_DATA" | jq -r '.global_secrets[]?')
GLOBAL_PROFILES=$(echo "$REGISTRY_DATA" | jq -r '.global_profiles[]? | "\(.name)\t\(.path)"')

if [[ -n "$GLOBAL_SECRETS" || -n "$GLOBAL_PROFILES" ]]; then
  echo "GLOBAL:"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if secret_exists "$(make_account_key global "$name")"; then
      echo "  [ok] ${name}"
    else
      echo "  [!]  ${name} (not found in ${BACKEND})"
    fi
  done <<< "$GLOBAL_SECRETS"

  if [[ -n "$GLOBAL_PROFILES" ]]; then
    echo "  Env Profiles:"
    while IFS=$'\t' read -r profile path; do
      [[ -n "$profile" ]] || continue
      if [[ -f "$path" ]]; then
        echo "    [ok] ${profile} ($(env_key_count "$path") vars)"
      else
        echo "    [!]  ${profile} (file missing)"
      fi
    done <<< "$GLOBAL_PROFILES"
  fi
  echo ""
fi

# Project secrets
echo "$REGISTRY_DATA" | jq -r '.projects[]? | "\(.path)"' | while IFS= read -r project; do
  [[ -n "$project" ]] || continue
  P_SECRETS=$(echo "$REGISTRY_DATA" | jq -r --arg p "$project" '.projects[]? | select(.path == $p) | .secrets[]?')
  P_PROFILES=$(echo "$REGISTRY_DATA" | jq -r --arg p "$project" '.projects[]? | select(.path == $p) | .profiles[]? | "\(.name)\t\(.path)"')

  if [[ -n "$P_SECRETS" || -n "$P_PROFILES" ]]; then
    echo "PROJECT: ${project}"
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      if secret_exists "$(make_account_key "$project" "$name")"; then
        echo "  [ok] ${name}"
      else
        echo "  [!]  ${name} (not found in ${BACKEND})"
      fi
    done <<< "$P_SECRETS"

    if [[ -n "$P_PROFILES" ]]; then
      echo "  Env Profiles:"
      while IFS=$'\t' read -r profile path; do
        [[ -n "$profile" ]] || continue
        if [[ -f "$path" ]]; then
          echo "    [ok] ${profile} ($(env_key_count "$path") vars)"
        else
          echo "    [!]  ${profile} (file missing)"
        fi
      done <<< "$P_PROFILES"
    fi
    echo ""
  fi
done

TOTAL_SECRETS=$(echo "$REGISTRY_DATA" | jq '(.global_secrets | length) + ([.projects[]?.secrets | length] | add // 0)')
TOTAL_PROFILES=$(echo "$REGISTRY_DATA" | jq '(.global_profiles | length) + ([.projects[]?.profiles | length] | add // 0)')
echo "Total: ${TOTAL_SECRETS} secrets, ${TOTAL_PROFILES} env profiles"
