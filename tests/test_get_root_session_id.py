"""Unit tests for scripts/get-root-session-id.py

Tests cover the five behaviors specified in TRACE-01:
  1. no-parent sid -> returns itself
  2. one-hop: child from parent-with-spawn.jsonl -> returns parent uuid
  3. cycle (A declares B, B declares A) -> terminates at max_depth, returns deepest resolved
  4. missing/unreadable sessions_dir or malformed JSON -> returns input sid (fail-open)
  5. empty sid argument -> sys.exit(0) with no output

Fixtures:
  - tests/fixtures/sessions/parent-with-spawn.jsonl
      parent uuid: a1b2c3d4-0001-0001-0001-000000000001
      child uuid:  b1b2c3d4-0002-0002-0002-000000000002
  - tests/fixtures/sessions/plain-session.jsonl
      session uuid: c3d4e5f6-0003-0003-0003-000000000003 (no subagent linkage)
"""
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

# ---------------------------------------------------------------------------
# Import the module under test via importlib (non-package source file).
# ---------------------------------------------------------------------------
_REPO_ROOT = Path(__file__).resolve().parent.parent
_MODULE_PATH = _REPO_ROOT / "scripts" / "get-root-session-id.py"

spec = importlib.util.spec_from_file_location("get_root_session_id_module", _MODULE_PATH)
_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(_mod)

get_root_session_id = _mod.get_root_session_id

# ---------------------------------------------------------------------------
# Fixture UUIDs (must match the JSONL fixtures created in Task 1).
# ---------------------------------------------------------------------------
PARENT_UUID = "a1b2c3d4-0001-0001-0001-000000000001"
CHILD_UUID = "b1b2c3d4-0002-0002-0002-000000000002"
PLAIN_UUID = "c3d4e5f6-0003-0003-0003-000000000003"
FIXTURES_DIR = _REPO_ROOT / "tests" / "fixtures" / "sessions"


class TestGetRootSessionId(unittest.TestCase):

    def test_no_parent_returns_self(self):
        """A session that is not declared as anyone's child resolves to itself."""
        result = get_root_session_id(PLAIN_UUID, sessions_dir=str(FIXTURES_DIR))
        self.assertEqual(result, PLAIN_UUID)

    def test_one_hop_child_returns_parent(self):
        """Resolving the child uuid from parent-with-spawn.jsonl returns the parent uuid."""
        result = get_root_session_id(CHILD_UUID, sessions_dir=str(FIXTURES_DIR))
        self.assertEqual(result, PARENT_UUID)

    def test_cycle_terminates_at_max_depth(self):
        """A cycle (A declares B, B declares A) terminates and does not hang or raise."""
        with tempfile.TemporaryDirectory() as tmpdir:
            # Create A.jsonl declaring B as child
            a_uuid = "aaaa0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            b_uuid = "bbbb0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            a_path = os.path.join(tmpdir, f"{a_uuid}.jsonl")
            b_path = os.path.join(tmpdir, f"{b_uuid}.jsonl")

            # A declares B as child
            with open(a_path, "w") as f:
                f.write(json.dumps({"type": "session", "id": a_uuid}) + "\n")
                f.write(json.dumps({
                    "type": "message",
                    "message": {
                        "role": "toolResult",
                        "toolName": "sessions_spawn",
                        "details": {
                            "childSessionKey": f"agent:main:subagent:{b_uuid}",
                            "status": "accepted"
                        }
                    }
                }) + "\n")

            # B declares A as child (cycle)
            with open(b_path, "w") as f:
                f.write(json.dumps({"type": "session", "id": b_uuid}) + "\n")
                f.write(json.dumps({
                    "type": "message",
                    "message": {
                        "role": "toolResult",
                        "toolName": "sessions_spawn",
                        "details": {
                            "childSessionKey": f"agent:main:subagent:{a_uuid}",
                            "status": "accepted"
                        }
                    }
                }) + "\n")

            # Should not raise and should terminate
            try:
                result = get_root_session_id(a_uuid, sessions_dir=tmpdir, max_depth=10)
                # Must be a string (not an exception)
                self.assertIsInstance(result, str)
                self.assertTrue(len(result) > 0)
            except Exception as e:
                self.fail(f"get_root_session_id raised an exception on cycle: {e}")

    def test_missing_sessions_dir_fails_open(self):
        """Missing sessions directory returns the input sid (fail-open)."""
        nonexistent = "/tmp/nonexistent-sessions-dir-9999-xyz"
        result = get_root_session_id(PLAIN_UUID, sessions_dir=nonexistent)
        self.assertEqual(result, PLAIN_UUID)

    def test_malformed_jsonl_line_fails_open(self):
        """Malformed JSON lines are skipped; the function does not raise."""
        with tempfile.TemporaryDirectory() as tmpdir:
            a_uuid = "cccc0000-cccc-cccc-cccc-cccccccccccc"
            malformed_path = os.path.join(tmpdir, f"{a_uuid}.jsonl")
            with open(malformed_path, "w") as f:
                f.write("NOT VALID JSON\n")
                f.write("{\"also\": broken\n")
                f.write("\n")

            result = get_root_session_id(a_uuid, sessions_dir=tmpdir)
            self.assertEqual(result, a_uuid)

    def test_empty_sid_exits_zero(self):
        """Empty sid argument causes sys.exit(0) with no output."""
        import subprocess
        cmd = [sys.executable, str(_MODULE_PATH), ""]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")

    def test_empty_sid_function_returns_empty(self):
        """get_root_session_id('') returns the empty string (not None, not raising)."""
        result = get_root_session_id("")
        self.assertEqual(result, "")


if __name__ == "__main__":
    unittest.main()
