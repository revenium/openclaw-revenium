"""Read-path tests: session store to redacted turn cache through infer.

Every store here is a real SQLite file built by tests/lib/mk-session-store.sh
(the only fixture writer) at ``<openclaw_home>/agents/main/agent/
openclaw-agent.sqlite``, and every read goes through scripts/session-store.sh
exactly as a cron tick does. Values reach the fixture helper only as
positional arguments, never interpolated into the bash script text.

HOME is pointed at a temp dir for every test, so the known-value loader
reads fixture files only.

TestTracer drives two real ticks through run.main: the first baselines,
the second caches new user and assistant turns, drops the tool result and
the directive block, redacts a planted secret and starts a session created
after the baseline at its first turn.

TestToolCallMeta covers the meta-tool ``tool_call``: its wrapped
``arguments.id`` names the real tool when valid, the name ``tool_call`` is
kept otherwise, and the wrapped ``args`` never reach the cache.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SIDECAR_DIR = _REPO_ROOT / "sidecar"
if str(_SIDECAR_DIR) not in sys.path:
    sys.path.insert(0, str(_SIDECAR_DIR))

import run  # noqa: E402
from openclaw_economics import cache, turns  # noqa: E402

FIXTURE_LIB = str(_REPO_ROOT / "tests" / "lib" / "mk-session-store.sh")

SID_A = "aaaaaaaa-0000-4000-8000-000000000001"
SID_B = "bbbbbbbb-0000-4000-8000-000000000002"
SID_C = "cccccccc-0000-4000-8000-000000000003"

ANTHROPIC_SECRET = "sk-ant-" + "api03-" + "Qw7" * 14


def rmtree(path: str) -> None:
    for root, dirs, files in os.walk(path, topdown=False):
        for name in files:
            try:
                os.unlink(os.path.join(root, name))
            except OSError:
                pass
        for name in dirs:
            full = os.path.join(root, name)
            try:
                if os.path.islink(full):
                    os.unlink(full)
                else:
                    os.chmod(full, 0o700)
                    os.rmdir(full)
            except OSError:
                pass
    try:
        os.rmdir(path)
    except OSError:
        pass


def fixture(*steps: tuple) -> None:
    """Run mk-session-store.sh functions; each step is (function, *args).

    The script text is fixed; the function names and values are positional
    parameters, so no value is ever parsed as shell code.
    """
    script = (
        '. "$1"; shift\n'
        'while [ "$#" -gt 0 ]; do\n'
        '  n="$1"; shift\n'
        '  fn="$1"; shift\n'
        '  args=()\n'
        '  i=0\n'
        '  while [ "${i}" -lt "${n}" ]; do args+=("$1"); shift; i=$((i + 1)); done\n'
        '  "${fn}" ${args[@]+"${args[@]}"} || exit 1\n'
        'done\n'
    )
    argv = ["bash", "-c", script, "_", FIXTURE_LIB]
    for step in steps:
        fn, *args = step
        argv += [str(len(args)), fn, *[str(a) for a in args]]
    proc = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
    if proc.returncode != 0:
        raise AssertionError("fixture step failed: " + proc.stderr.decode("utf-8", "replace")[-500:])


def event(seq: int, role: str, content, **extra) -> str:
    message = {"role": role, "content": content}
    message.update(extra)
    return json.dumps({
        "type": "message",
        "id": f"evt-{seq}",
        "parentId": f"evt-{seq - 1}",
        "timestamp": "2026-10-26T12:00:00.000Z",
        "message": message,
    })


class Layout:
    """Temp HOME, OPENCLAW_HOME with one store, private state and runtime."""

    def __init__(self, test: unittest.TestCase) -> None:
        self.base = tempfile.mkdtemp(prefix="sidecar-read-")
        os.chmod(self.base, 0o700)
        test.addCleanup(rmtree, self.base)
        self.home = self._dir("home")
        self.oc_home = self._dir("openclaw")
        self.state = self._dir("state")
        self.runtime = self._dir("runtime")
        self.db = os.path.join(self.oc_home, "agents", "main", "agent", "openclaw-agent.sqlite")
        env = mock.patch.dict(os.environ, {"HOME": self.home})
        env.start()
        test.addCleanup(env.stop)
        os.environ.pop("REVENIUM_SESSION_STORE", None)

    def _dir(self, name: str) -> str:
        path = os.path.join(self.base, name)
        os.mkdir(path, 0o700)
        return path

    def argv(self, budget: int = 30) -> list:
        return [
            "infer",
            "--state-dir", self.state,
            "--openclaw-home", self.oc_home,
            "--skill-dir", str(_REPO_ROOT),
            "--runtime-dir", self.runtime,
            "--budget-seconds", str(budget),
        ]

    def infer(self, budget: int = 30) -> dict:
        rc = run.main(self.argv(budget), find_library=lambda: True)
        if rc != run.EXIT_OK:
            raise AssertionError(f"infer exited {rc}")
        return self.status()

    def status(self) -> dict:
        with open(os.path.join(self.state, "infer-status.json"), encoding="utf-8") as handle:
            return json.load(handle)

    def cursors_doc(self) -> dict:
        with open(os.path.join(self.state, cache.CURSORS_FILE), encoding="utf-8") as handle:
            return json.load(handle)

    def cached(self, sid: str) -> list:
        return cache.TurnCache(self.state).read(sid)

    def state_files(self) -> list:
        found = []
        for root, _dirs, files in os.walk(self.state):
            for name in files:
                found.append(os.path.join(root, name))
        return found

    def state_bytes(self) -> bytes:
        blob = b""
        for path in self.state_files():
            with open(path, "rb") as handle:
                blob += handle.read()
        return blob


class TestTracer(unittest.TestCase):
    def setUp(self) -> None:
        self.lay = Layout(self)

    def test_new_turns_reach_the_redacted_cache(self) -> None:
        lay = self.lay
        fixture(
            ("mk_store", lay.db),
            ("mk_session", lay.db, SID_A, "agent:main:main", "", 100),
            ("mk_event", lay.db, SID_A, 1, event(1, "user", "fixture hello before install")),
        )

        first = lay.infer()
        self.assertEqual(first["reason"], "ok")
        self.assertEqual(first["counters"]["baselined"], 1)
        self.assertEqual(first["counters"]["turnsCached"], 0)
        self.assertEqual(lay.cursors_doc()["sessions"][SID_A]["cursor"], 1)
        self.assertFalse(os.path.exists(os.path.join(lay.state, cache.TURNS_DIR)))

        user_text = (
            "<revenium-guard>\nfixture directive\n</revenium-guard>\n"
            f"please deploy with key {ANTHROPIC_SECRET} now"
        )
        tool_body = "fixture tool result body " + ANTHROPIC_SECRET
        fixture(
            ("mk_event", lay.db, SID_A, 2, event(2, "user", [{"type": "text", "text": user_text}])),
            ("mk_event", lay.db, SID_A, 3, event(3, "assistant", [
                {"type": "text", "text": "fixture deploying"},
                {"type": "toolCall", "id": "call-1", "name": "exec",
                 "arguments": {"command": "deploy --key " + ANTHROPIC_SECRET}},
            ])),
            ("mk_event", lay.db, SID_A, 4, event(4, "toolResult", [{"type": "text", "text": tool_body}],
                                               toolCallId="call-1", toolName="exec")),
            ("mk_session", lay.db, SID_B, "agent:main:subagent:x", "spawn", 201),
            ("mk_event", lay.db, SID_B, 0, event(0, "user", "fixture subagent task")),
        )

        second = lay.infer()
        self.assertEqual(second["reason"], "ok")
        self.assertEqual(second["counters"]["turnsCached"], 3)
        self.assertEqual(second["counters"]["sessionsRead"], 2)

        records = lay.cached(SID_A)
        self.assertEqual([r["seq"] for r in records], [2, 3])
        self.assertEqual(records[0]["role"], "user")
        self.assertIn("[REDACTED:anthropic]", records[0]["text"])
        self.assertEqual(records[1]["role"], "assistant")
        self.assertEqual(records[1]["tools"], ["exec"])
        self.assertEqual(lay.cursors_doc()["sessions"][SID_A]["cursor"], 4)

        sub = lay.cached(SID_B)
        self.assertEqual([(r["seq"], r["text"]) for r in sub], [(0, "fixture subagent task")])

        blob = lay.state_bytes()
        for needle in ("fixture directive", ANTHROPIC_SECRET, "fixture tool result body", "deploy --key"):
            self.assertNotIn(needle.encode("utf-8"), blob, needle)

        turns_dir = os.path.join(lay.state, cache.TURNS_DIR)
        self.assertEqual(stat.S_IMODE(os.stat(turns_dir).st_mode), 0o700)
        for name in os.listdir(turns_dir):
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(turns_dir, name)).st_mode), 0o600)


def meta_call(arguments) -> str:
    return event(5, "assistant", [
        {"type": "toolCall", "id": "call-9", "name": "tool_call", "arguments": arguments},
    ])


class TestToolCallMeta(unittest.TestCase):
    def test_wrapped_id_names_the_real_tool(self) -> None:
        msg = turns.extract(5, meta_call({"id": "openclaw:core:exec", "args": {"command": "ls"}}))
        self.assertEqual(msg.tools, ("exec",))
        self.assertEqual(turns.tool_markers(msg.tools), ["[tool: exec]"])

    def test_missing_or_invalid_id_keeps_the_meta_name(self) -> None:
        cases = (
            {},
            {"args": {}},
            {"id": 42},
            {"id": "openclaw:core:"},
            {"id": "openclaw:core:bad name"},
            {"id": "x" * 65},
            {"id": "openclaw:core:exec\n"},
            "not-an-object",
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                msg = turns.extract(5, meta_call(arguments))
                self.assertEqual(turns.tool_markers(msg.tools), ["[tool: tool_call]"])

    def test_other_tool_names_ignore_arguments(self) -> None:
        msg = turns.extract(5, event(5, "assistant", [
            {"type": "toolCall", "id": "c", "name": "exec", "arguments": {"id": "openclaw:core:rm"}},
            {"type": "toolCall", "id": "d", "name": "bad name!", "arguments": {}},
        ]))
        self.assertEqual(turns.tool_markers(msg.tools), ["[tool: exec]", "[tool]"])

    def test_wrapped_args_never_reach_the_cache(self) -> None:
        lay = Layout(self)
        fixture(
            ("mk_store", lay.db),
            ("mk_session", lay.db, SID_A, "agent:main:main", "", 100),
        )
        lay.infer()
        planted = "fixture-wrapped-arg-" + "7c1e"
        fixture(
            ("mk_session", lay.db, SID_C, "agent:main:other", "", 101),
            ("mk_event", lay.db, SID_C, 0, meta_call(
                {"id": "openclaw:core:exec", "args": {"command": planted, "id": planted}})),
        )
        lay.infer()
        self.assertEqual([r["tools"] for r in lay.cached(SID_C)], [["exec"]])
        self.assertNotIn(planted.encode("utf-8"), lay.state_bytes())


if __name__ == "__main__":
    unittest.main()
