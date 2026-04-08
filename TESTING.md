# Blindfold Testing Results

**Date:** 2026-04-08
**Commit under test:** 12299fa (original, unmodified Blindfold from thesaadmirza/blindfold)
**Platform:** macOS (Darwin), Claude Code v2.1.69+, keychain backend

---

## Phase 1 — Baseline (No Blindfold)

Verified that Claude Code can interact with macOS Keychain without Blindfold hooks installed.

| Test | Description | Result | Notes |
|------|-------------|--------|-------|
| 1.1 | Read missing keychain item | **PASS** | Clean exit 44 (item not found) |
| 1.2 | Write to keychain from CC | **PASS** | Exit 0 |
| 1.4 | Read metadata (no `-w`) | **PASS** | Attributes returned |
| 1.5 | Read value (`-w` flag) | **PASS** | Value returned |
| 1.6 | Cleanup (delete item) | **PASS** | Item deleted |

**Conclusion:** Keychain fully functional inside Claude Code on macOS.

---

## Phase 2 — Original Blindfold Hooks Active

Hooks configured in `.claude/settings.json`:
- **PreToolUse** (Bash, Read): `secret-guard.sh` (5000ms timeout)
- **PostToolUse** (Bash): `secret-redact.sh` (10000ms timeout)

Test secret: `BLINDFOLD_TEST` = `test-value-12345` stored in login keychain.

| Test | Description | Result | Notes |
|------|-------------|--------|-------|
| 2.1 | Hook loads | **PASS** | `echo "hook test"` succeeds, no errors |
| 2.2 | Guard: block `-w` | **PASS** | `security find-generic-password -w` denied with message |
| 2.3 | Guard: block dump | **PASS** | `security dump-keychain` denied with message |
| 2.4 | Guard: allow safe cmd | **PASS** | `security list-keychains -d user` returned normal output |
| 2.5 | secret-list.sh | **PASS*** | Required adding missing `envProfiles` to registry — see Bug #1 |
| 2.6 | secret-exec.sh | **PASS** | `echo "val={{BLINDFOLD_TEST}}"` produced `val=[REDACTED:BLINDFOLD_TEST]` |
| 2.7 | Redact hook | **FAIL** | `echo "test-value-12345"` — no systemMessage warning produced. See Bug #2 |
| 2.8 | Guard: block `.env` cat | **FAIL** | `cat .env.test` not blocked (relative or absolute path). See Bug #3 |
| 2.9 | Guard: Read tool `.env` | **FAIL** | Read tool on registered `.env.test` not blocked. Same root cause as Bug #3 |

**Pass rate:** 6/9 (3 failures, all security-relevant)

**Summary:** The guard (blocking direct keychain reads) and secret-exec (placeholder substitution + redaction) work correctly. However, two of three defense-in-depth security features are broken out of the box: output leak detection never fires, and env file protection never blocks.

---

## Bugs Found

### Bug #1 — Registry crash on missing envProfiles ([#1](https://github.com/MatthewDruhl/blindfold/issues/1))

**Severity:** Low
**File:** `secret-list.sh` lines 17-25

`secret-list.sh` crashes with exit code 5 if the `secrets-registry.json` file is missing the `envProfiles` key in the `global` object. The jq filter uses `to_entries` on a null value, which errors. The `?` suffix suppresses the error output, but `set -e` still catches the non-zero exit code.

**Root cause:** The jq expression `.global.envProfiles | to_entries[]?` assumes `envProfiles` always exists. When a registry is created with secrets but without `envProfiles`, this field is null.

**Fix:** Use null-coalescing: `(.global.envProfiles // {}) | to_entries[]?`

### Bug #2 — Redact hook reads wrong field — secret leak detection never fires ([#2](https://github.com/MatthewDruhl/blindfold/issues/2))

**Severity:** High (security)
**File:** `secret-redact.sh` line 10

The PostToolUse hook reads `tool_result.stdout` from the hook input JSON, but Claude Code actually sends the field as `tool_response.stdout`. The field mismatch means `TOOL_RESULT` is always empty, and the script exits early at line 14 without ever checking for leaked secrets in command output.

**Root cause:** The hook input JSON structure uses `tool_response` (not `tool_result`):
```json
{
  "tool_name": "Bash",
  "tool_input": { "command": "..." },
  "tool_response": {
    "stdout": "...",
    "stderr": "",
    "interrupted": false
  }
}
```

**Verified by:** Debug wrapper capturing actual hook input JSON. Confirmed field name is `tool_response` with `stdout`, `stderr`, `interrupted`, and `isImage` subfields.

**Fix:** Change `tool_result` to `tool_response` on line 10:
```bash
PARSED=$(echo "$INPUT" | jq -r '[.tool_name // "", .tool_response.stdout // .tool_response // ""] | @tsv' 2>/dev/null)
```

### Bug #3 — Env file protection completely bypassed ([#3](https://github.com/MatthewDruhl/blindfold/issues/3))

**Severity:** High (security)
**Files:** `secret-guard.sh` lines 39-43, `lib.sh` lines 73-78 (`get_all_env_paths()`)

Both the PreToolUse guard and the `get_all_env_paths()` utility use jq's `values` filter to extract registered env file paths from the registry. In jq, `values` is equivalent to `select(. != null)` — it filters nulls, it does **not** extract object values (unlike Python's `.values()`).

Given `{"test": "/path/to/.env"}`, piping through `| values` returns the entire object `{"test": "/path/to/.env"}`, not the path string `"/path/to/.env"`.

The guard then compares the command string against the JSON object text, which never matches actual file paths. Result: registered env files can be freely read via both `cat` and the Read tool.

**Secondary issues:**
- Even with the jq fix, the guard only matches absolute paths. Relative paths (e.g., `cat .env` vs `cat /full/path/.env`) bypass the substring check. The `cwd` field is available in the hook input but unused.
- The substring matching on full command strings causes false positives when heredoc bodies mention registered paths (e.g., `gh issue create` with a body referencing env files).

**Fix:** Replace `values` with `.[]` (object iteration) in both files:
```jq
[.global.envProfiles // {} | .[]] +
[.projects | to_entries[]? | (.value.envProfiles // {}) | .[]]
| unique | .[]
```

---

## Observations

- **Guard hook cancellation:** When a PreToolUse hook denies a command, all parallel tool calls in the same batch are cancelled. Tests had to be run sequentially after a denial.
- **Guard false positive on heredocs:** Filing GitHub issues with body text mentioning env paths triggered the guard, requiring temporary hook disablement. This is a design limitation of substring matching on the full command string.

---

## Test Environment Setup

```bash
# Hook configuration (.claude/settings.json)
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash scripts/secret-guard.sh", "timeout": 5000}]},
      {"matcher": "Read", "hooks": [{"type": "command", "command": "bash scripts/secret-guard.sh", "timeout": 5000}]}
    ],
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash scripts/secret-redact.sh", "timeout": 10000}]}
    ]
  }
}

# Test secret
security add-generic-password -a "claude-secret:global:BLINDFOLD_TEST" -s "claude-secrets" -w "test-value-12345"

# Registry (secrets-registry.json)
{"version":3,"global":{"secrets":["BLINDFOLD_TEST"],"envProfiles":{}},"projects":{}}

# Test env file (for tests 2.8-2.9)
echo 'TEST_KEY=secret-env-value-999' > .env.test
# Register: jq '.global.envProfiles.test = "/path/to/.env.test"' ~/.claude/secrets-registry.json
```

## Cleanup

```bash
security delete-generic-password -a "claude-secret:global:BLINDFOLD_TEST" -s "claude-secrets"
rm .env.test
echo '{"version":3,"global":{"secrets":[],"envProfiles":{}},"projects":{}}' > ~/.claude/secrets-registry.json
```
