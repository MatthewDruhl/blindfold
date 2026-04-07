"""Shared fixtures for Blindfold tests.

Tests call bash scripts via subprocess to validate the full pipeline.
Two tiers:
  - Unit tests: run anywhere, test argument parsing, registry logic, etc.
  - Integration tests: macOS only, test Keychain store/retrieve/delete cycle.
"""

import json
import os
import platform
import subprocess
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"

# Custom marker for macOS-only integration tests
macos_only = pytest.mark.skipif(
    platform.system() != "Darwin",
    reason="Requires macOS Keychain",
)


@pytest.fixture()
def scripts_dir():
    """Path to the blindfold scripts directory."""
    return SCRIPTS_DIR


@pytest.fixture()
def temp_registry(tmp_path):
    """Create a temporary secrets registry and set it via env var.

    Yields the path to the temp registry file. The file is cleaned up
    automatically by pytest's tmp_path fixture.
    """
    registry = tmp_path / "secrets-registry.json"
    registry.write_text('{"version":3,"global":{"secrets":[]},"projects":{}}')
    registry.chmod(0o600)
    yield registry


@pytest.fixture()
def env_with_registry(temp_registry):
    """Environment dict with BLINDFOLD_REGISTRY pointing to temp file.

    This keeps tests isolated from the user's real registry at
    ~/.claude/secrets-registry.json.
    """
    env = os.environ.copy()
    env["BLINDFOLD_REGISTRY"] = str(temp_registry)
    return env


@pytest.fixture()
def test_secret_name():
    """A unique secret name for test isolation."""
    return "BLINDFOLD_TEST_SECRET"


@pytest.fixture()
def test_secret_value():
    """A known value for test assertions."""
    return "test-value-s3cr3t-12345"


def run_script(script_name: str, args: list[str] | None = None,
               env: dict | None = None, input_text: str | None = None) -> subprocess.CompletedProcess:
    """Run a blindfold bash script and return the result.

    Args:
        script_name: Name of the script in scripts/ (e.g., "secret-store.sh")
        args: Command-line arguments to pass
        env: Environment variables (use env_with_registry fixture for isolation)
        input_text: Text to pipe to stdin
    """
    script_path = SCRIPTS_DIR / script_name
    cmd = ["bash", str(script_path)] + (args or [])
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        env=env,
        input=input_text,
        timeout=30,
    )
