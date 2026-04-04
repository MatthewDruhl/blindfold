#!/usr/bin/env bash
set -euo pipefail

# Blindfold installer
# Usage: curl -fsSL https://raw.githubusercontent.com/thesaadmirza/blindfold/main/install.sh | bash

REPO="thesaadmirza/blindfold"
SKILL_DIR="$HOME/.claude/skills/blindfold"
REGISTRY="$HOME/.claude/secrets-registry.json"
SETTINGS="$HOME/.claude/settings.json"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

info()  { echo -e "${GREEN}[blindfold]${NC} $1"; }
warn()  { echo -e "${YELLOW}[blindfold]${NC} $1"; }
error() { echo -e "${RED}[blindfold]${NC} $1" >&2; }

# Check dependencies
check_deps() {
  local missing=()
  command -v jq &>/dev/null || missing+=("jq")
  command -v git &>/dev/null || missing+=("git")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
    echo ""
    echo "Install them first:"
    case "$(uname -s)" in
      Darwin) echo "  brew install ${missing[*]}" ;;
      Linux)  echo "  sudo apt install ${missing[*]}  # or: sudo yum install ${missing[*]}" ;;
    esac
    exit 1
  fi
}

# Detect secret backend
detect_backend() {
  case "$(uname -s)" in
    Darwin) echo "macOS Keychain" ;;
    Linux)
      if command -v secret-tool &>/dev/null; then echo "secret-tool (GNOME Keyring)"
      elif command -v gpg &>/dev/null; then echo "GPG (encrypted files)"
      else echo "none"; fi ;;
    MINGW*|MSYS*|CYGWIN*) echo "Windows Credential Manager" ;;
    *) echo "none" ;;
  esac
}

install_skill() {
  info "Installing Blindfold skill..."

  mkdir -p "$HOME/.claude/skills"

  if [[ -d "$SKILL_DIR" ]]; then
    warn "Existing installation found. Updating..."
    rm -rf "$SKILL_DIR"
  fi

  # Try git clone first, fall back to tarball
  if git clone --depth 1 "https://github.com/${REPO}.git" "$SKILL_DIR" 2>/dev/null; then
    rm -rf "$SKILL_DIR/.git"
    info "Downloaded from GitHub."
  elif command -v curl &>/dev/null; then
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" | tar xz -C "$tmp"
    mv "$tmp/blindfold-main" "$SKILL_DIR"
    rm -rf "$tmp"
    info "Downloaded from GitHub (tarball)."
  else
    error "Cannot download. Install git or curl, or clone manually:"
    echo "  git clone https://github.com/${REPO}.git $SKILL_DIR"
    exit 1
  fi

  chmod 700 "$SKILL_DIR/scripts/"*.sh
  info "Scripts permissions set."
}

init_registry() {
  if [[ ! -f "$REGISTRY" ]]; then
    echo '{"version":2,"global":{"secrets":[],"envProfiles":{}},"projects":{}}' > "$REGISTRY"
    chmod 600 "$REGISTRY"
    info "Registry created at $REGISTRY"
  else
    info "Registry already exists. Skipping."
  fi
}

configure_hooks() {
  if [[ ! -f "$SETTINGS" ]]; then
    # No settings file exists -- create one with just hooks
    cat > "$SETTINGS" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ~/.claude/skills/blindfold/scripts/secret-guard.sh", "timeout": 5000}]
      },
      {
        "matcher": "Read",
        "hooks": [{"type": "command", "command": "bash ~/.claude/skills/blindfold/scripts/secret-guard.sh", "timeout": 5000}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ~/.claude/skills/blindfold/scripts/secret-redact.sh", "timeout": 10000}]
      }
    ]
  }
}
EOF
    info "Created settings.json with hooks."
    return
  fi

  # Settings file exists -- check if hooks are already configured
  if jq -e '.hooks.PreToolUse' "$SETTINGS" &>/dev/null; then
    if grep -q "blindfold" "$SETTINGS"; then
      info "Hooks already configured. Skipping."
      return
    fi
    warn "Existing hooks found in settings.json."
    warn "You need to manually add Blindfold hooks. See README.md for the config."
    return
  fi

  # No hooks key -- merge it in
  local tmp
  tmp=$(mktemp)
  jq '. + {
    "hooks": {
      "PreToolUse": [
        {
          "matcher": "Bash",
          "hooks": [{"type": "command", "command": "bash ~/.claude/skills/blindfold/scripts/secret-guard.sh", "timeout": 5000}]
        },
        {
          "matcher": "Read",
          "hooks": [{"type": "command", "command": "bash ~/.claude/skills/blindfold/scripts/secret-guard.sh", "timeout": 5000}]
        }
      ],
      "PostToolUse": [
        {
          "matcher": "Bash",
          "hooks": [{"type": "command", "command": "bash ~/.claude/skills/blindfold/scripts/secret-redact.sh", "timeout": 10000}]
        }
      ]
    }
  }' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  info "Hooks added to settings.json."
}

# --- Main ---
echo ""
echo -e "${BOLD}  Blindfold${NC} — secret management for Claude Code"
echo -e "  Keeps your secrets out of the LLM's context window."
echo ""

check_deps

BACKEND=$(detect_backend)
if [[ "$BACKEND" == "none" ]]; then
  error "No supported secret backend found."
  echo "  Install one of: secret-tool (Linux), gpg"
  exit 1
fi
info "Detected secret backend: ${BACKEND}"

install_skill
init_registry
configure_hooks

echo ""
echo -e "${GREEN}${BOLD}  Done!${NC} Blindfold is installed."
echo ""
echo "  Restart Claude Code to load the hooks, then try:"
echo ""
echo -e "    ${BOLD}/blindfold${NC}                    — activate the skill"
echo -e "    ${BOLD}\"store my API key\"${NC}            — store a secret"
echo -e "    ${BOLD}\"register my staging env\"${NC}     — register a .env file"
echo -e "    ${BOLD}\"list my secrets\"${NC}             — see what's stored"
echo ""
echo "  Docs: https://github.com/${REPO}"
echo ""
