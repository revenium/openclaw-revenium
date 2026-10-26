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

TestEdges covers change detection, the compacted-row count, idempotency,
crash safety between the cache append and the cursor save, 64-bit seqs,
invalid UTF-8, empty and failing stores, age and size retention, the soft
deadline between sessions and dropping cursors of sessions gone from the
store. A failing store is a real unreadable SQLite file read through the
real session-store.sh, never a faked exit code: the lenient verbs exit 0 on
a SQLite error, so only the real failure shape tests the real contract.

TestRecheck covers the periodic max-seq recheck: change detection trusts
the store to move ``updated_at`` with every new row, so every
MAX_SEQ_RECHECK_SECONDS one grouped ``max-seq-all-strict`` call finds any
session whose rows outran its ``updated_at``. ``maxSeqCheckedAt`` in
cursors.json records the last complete recheck; a failed or deadline-cut
recheck leaves it alone so the next tick tries again.
"""
from __future__ import annotations

import json
import os
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SIDECAR_DIR = _REPO_ROOT / "sidecar"
if str(_SIDECAR_DIR) not in sys.path:
    sys.path.insert(0, str(_SIDECAR_DIR))

import run  # noqa: E402
from openclaw_economics import cache, paths, redact, store, turns  # noqa: E402

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

    def context(self, budget: int = 30) -> paths.Context:
        return paths.build_context(SimpleNamespace(
            state_dir=self.state, openclaw_home=self.oc_home, skill_dir=str(_REPO_ROOT),
            runtime_dir=self.runtime, budget_seconds=budget,
        ))

    def snapshot(self) -> dict:
        found = {}
        for path in self.state_files():
            if path.endswith("-status.json"):
                continue
            with open(path, "rb") as handle:
                found[os.path.relpath(path, self.state)] = handle.read()
        return found

    def state_bytes(self, exclude: tuple = ()) -> bytes:
        blob = b""
        for path in self.state_files():
            if os.path.basename(path) in exclude:
                continue
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
            ("mk_touch_session", lay.db, SID_A, 200),
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


def write_garbage(path: str) -> None:
    """Make path an unreadable store: SQLite answers "file is not a database"."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(b"not a sqlite database " * 64)


class CountingRunner:
    """subprocess.run stand-in that records each verb.

    ``broken`` maps a verb to the path of an unreadable store: that verb runs
    the real session-store.sh with REVENIUM_SESSION_STORE pointed there, so
    it fails exactly the way a busy, corrupt or drifted store does.
    """

    def __init__(self, broken: dict | None = None) -> None:
        self.verbs: list = []
        self.broken = broken or {}

    def __call__(self, argv, **kwargs):
        self.verbs.append(argv[2])
        bad = self.broken.get(argv[2])
        if bad is not None:
            kwargs["env"] = dict(kwargs.get("env") or os.environ, REVENIUM_SESSION_STORE=bad)
        return subprocess.run(argv, **kwargs)


class BrokenStore:
    """Context manager: the layout's store is unreadable while inside."""

    def __init__(self, db: str) -> None:
        self.db = db
        self.saved = db + ".saved"

    def __enter__(self):
        os.replace(self.db, self.saved)
        write_garbage(self.db)
        return self

    def __exit__(self, *exc) -> None:
        os.replace(self.saved, self.db)


def patch_runner(test: unittest.TestCase, runner: CountingRunner) -> None:
    real = store.StoreClient

    def factory(*args, **kwargs):
        kwargs["runner"] = runner
        return real(*args, **kwargs)

    patcher = mock.patch.object(run, "StoreClient", factory)
    patcher.start()
    test.addCleanup(patcher.stop)


def fake_clock(*readings: float):
    values = list(readings)

    def clock() -> float:
        return values.pop(0) if len(values) > 1 else values[0]

    return clock


class TestEdges(unittest.TestCase):
    def setUp(self) -> None:
        self.lay = Layout(self)
        fixture(
            ("mk_store", self.lay.db),
            ("mk_session", self.lay.db, SID_A, "agent:main:main", "", 100),
            ("mk_event", self.lay.db, SID_A, 0, event(0, "user", "fixture before install")),
        )
        self.lay.infer()

    def add_turns(self, sid: str, first_seq: int, count: int, updated_at: int, text: str = "fixture turn") -> None:
        steps = [("mk_event", self.lay.db, sid, seq, event(seq, "user", f"{text} {seq}"))
                 for seq in range(first_seq, first_seq + count)]
        steps.append(("mk_touch_session", self.lay.db, sid, updated_at))
        fixture(*steps)

    def cursors_bytes(self) -> bytes:
        with open(os.path.join(self.lay.state, cache.CURSORS_FILE), "rb") as handle:
            return handle.read()

    def test_unchanged_session_is_not_read(self) -> None:
        runner = CountingRunner()
        patch_runner(self, runner)
        fixture(("mk_event", self.lay.db, SID_A, 1, event(1, "user", "fixture unseen")))
        doc = self.lay.infer()
        self.assertNotIn("session-events-seq", runner.verbs)
        self.assertEqual(doc["counters"]["sessionsSkippedUnchanged"], 1)
        self.assertEqual(doc["counters"]["sessionsRead"], 0)

    def test_compacted_rows_are_counted(self) -> None:
        fixture(
            ("mk_compacted_event", self.lay.db, SID_A, 1),
            ("mk_compacted_event", self.lay.db, SID_A, 2),
            ("mk_touch_session", self.lay.db, SID_A, 150),
        )
        doc = self.lay.infer()
        self.assertEqual(doc["counters"]["compactedUnread"], 2)
        self.assertEqual(doc["counters"]["turnsCached"], 0)

    def test_second_run_on_unchanged_store_changes_nothing(self) -> None:
        self.add_turns(SID_A, 1, 3, 150)
        self.lay.infer()
        before = self.lay.snapshot()
        self.assertIn(os.path.join(cache.TURNS_DIR, SID_A + ".jsonl"), before)
        doc = self.lay.infer()
        self.assertEqual(self.lay.snapshot(), before)
        self.assertEqual(doc["counters"]["turnsCached"], 0)

    def test_crash_before_cursor_save_is_absorbed_by_seq_dedupe(self) -> None:
        self.add_turns(SID_A, 1, 3, 150)
        with mock.patch.object(cache.Cursors, "save", side_effect=OSError("disk full")):
            rc = run.main(self.lay.argv(), find_library=lambda: True)
        self.assertEqual(rc, run.EXIT_CRASH)
        self.assertEqual([r["seq"] for r in self.lay.cached(SID_A)], [1, 2, 3])
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_A]["cursor"], 0)

        doc = self.lay.infer()
        self.assertEqual(doc["counters"]["turnsCached"], 0)
        self.assertEqual([r["seq"] for r in self.lay.cached(SID_A)], [1, 2, 3])
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_A]["cursor"], 3)

    def test_large_seq_round_trips_exactly(self) -> None:
        big = 9007199254740993
        fixture(
            ("mk_session", self.lay.db, SID_B, "agent:main:big", "", 160),
            ("mk_event", self.lay.db, SID_B, big, event(1, "user", "fixture big seq")),
        )
        self.lay.infer()
        self.assertIn(b'"cursor": 9007199254740993', self.cursors_bytes())
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_B]["cursor"], big)
        self.assertEqual([r["seq"] for r in self.lay.cached(SID_B)], [big])
        path = cache.TurnCache(self.lay.state).path(SID_B)
        with open(path, "rb") as handle:
            self.assertIn(b'"seq": 9007199254740993', handle.read())
        self.assertEqual(cache.TurnCache(self.lay.state).last_seq(SID_B), big)

    def test_invalid_utf8_and_cjk_are_cached_as_valid_utf8(self) -> None:
        raw = event(1, "user", "fixture 你好 PLACEHOLDER end").encode("utf-8")
        raw = raw.replace(b"PLACEHOLDER", b"\xff\xfe\xc3")
        fixture(
            ("mk_event_hex", self.lay.db, SID_A, 1, raw.hex()),
            ("mk_event", self.lay.db, SID_A, 2, event(2, "assistant", [{"type": "text", "text": "fixture こんにちは"}])),
            ("mk_touch_session", self.lay.db, SID_A, 150),
        )
        doc = self.lay.infer()
        self.assertEqual(doc["counters"]["turnsCached"], 2)
        with open(cache.TurnCache(self.lay.state).path(SID_A), "rb") as handle:
            data = handle.read()
        text = data.decode("utf-8")  # strict: raises on invalid bytes
        self.assertIn("你好", text)
        self.assertIn("�", text)
        self.assertIn("こんにちは", text)
        self.assertEqual([r["seq"] for r in self.lay.cached(SID_A)], [1, 2])

    def test_empty_quiet_and_failing_stores_change_nothing(self) -> None:
        with self.subTest("session with no new rows"):
            before = self.cursors_bytes()
            fixture(("mk_touch_session", self.lay.db, SID_A, 150))
            doc = self.lay.infer()
            self.assertEqual(doc["reason"], "ok")
            self.assertEqual(self.lay.cursors_doc()["sessions"][SID_A]["cursor"], 0)
            self.assertEqual(json.loads(before)["sessions"][SID_A]["cursor"], 0)
            self.assertFalse(os.path.exists(os.path.join(self.lay.state, cache.TURNS_DIR)))

        with self.subTest("store cannot be read"):
            self.add_turns(SID_A, 1, 2, 170)
            before = self.cursors_bytes()
            with BrokenStore(self.lay.db):
                doc = self.lay.infer()
            self.assertEqual(doc["reason"], "ok")
            self.assertGreater(doc["counters"]["storeFailures"], 0)
            self.assertEqual(self.cursors_bytes(), before)
            self.assertFalse(os.path.exists(os.path.join(self.lay.state, cache.TURNS_DIR)))

    def test_empty_store_finishes_ok_without_writes(self) -> None:
        lay = Layout(self)
        fixture(("mk_store", lay.db))
        doc = lay.infer()
        self.assertEqual(doc["reason"], "ok")
        before = lay.snapshot()
        doc = lay.infer()
        self.assertEqual(doc["reason"], "ok")
        self.assertEqual(lay.snapshot(), before)
        self.assertFalse(os.path.exists(os.path.join(lay.state, cache.TURNS_DIR)))

    def test_failing_store_on_first_run_does_not_baseline(self) -> None:
        lay = Layout(self)
        fixture(
            ("mk_store", lay.db),
            ("mk_session", lay.db, SID_B, "agent:main:main", "", 100),
            ("mk_event", lay.db, SID_B, 0, event(0, "user", "fixture history before install")),
        )
        with BrokenStore(lay.db):
            doc = lay.infer()
        self.assertEqual(doc["reason"], "ok")
        self.assertGreater(doc["counters"]["storeFailures"], 0)
        self.assertFalse(os.path.exists(os.path.join(lay.state, cache.CURSORS_FILE)))

        # Once the store answers, the baseline covers the existing history.
        lay.infer()
        self.assertEqual(lay.cursors_doc()["sessions"][SID_B]["cursor"], 0)
        lay.infer()
        self.assertEqual(lay.cached(SID_B), [])

    def test_one_unreadable_agent_store_blocks_the_baseline(self) -> None:
        lay = Layout(self)
        other = os.path.join(lay.oc_home, "agents", "dev", "agent", "openclaw-agent.sqlite")
        fixture(
            ("mk_store", lay.db),
            ("mk_session", lay.db, SID_B, "agent:main:main", "", 100),
            ("mk_event", lay.db, SID_B, 0, event(0, "user", "fixture main history")),
            ("mk_store", other),
            ("mk_session", other, SID_C, "agent:dev:main", "", 100),
            ("mk_event", other, SID_C, 0, event(0, "user", "fixture dev history")),
        )
        with BrokenStore(other):
            doc = lay.infer()
        self.assertEqual(doc["counters"]["baselined"], 0)
        self.assertFalse(os.path.exists(os.path.join(lay.state, cache.CURSORS_FILE)))

        lay.infer()
        self.assertEqual(set(lay.cursors_doc()["sessions"]), {SID_B, SID_C})
        lay.infer()
        self.assertNotIn(b"history", lay.state_bytes())

    def test_failed_max_seq_during_baseline_does_not_baseline(self) -> None:
        lay = Layout(self)
        fixture(
            ("mk_store", lay.db),
            ("mk_session", lay.db, SID_B, "agent:main:main", "", 100),
            ("mk_event", lay.db, SID_B, 3, event(3, "user", "fixture history before install")),
        )
        bad = os.path.join(lay.base, "bad", "openclaw-agent.sqlite")
        write_garbage(bad)
        patch_runner(self, CountingRunner(broken={"max-seq-all-strict": bad}))
        doc = lay.infer()
        self.assertEqual(doc["counters"]["baselined"], 0)
        self.assertFalse(os.path.exists(os.path.join(lay.state, cache.CURSORS_FILE)))

    def test_baseline_is_one_store_call_for_many_sessions(self) -> None:
        lay = Layout(self)
        steps = [("mk_store", lay.db)]
        sids = [f"dddddddd-0000-4000-8000-{i:012d}" for i in range(40)]
        for i, sid in enumerate(sids):
            steps.append(("mk_session", lay.db, sid, f"agent:main:s{i}", "", 100 + i))
            steps.append(("mk_event", lay.db, sid, i, event(i, "user", "fixture history")))
        fixture(*steps)
        runner = CountingRunner()
        patch_runner(self, runner)
        doc = lay.infer()
        self.assertEqual(doc["counters"]["baselined"], 40)
        self.assertEqual(runner.verbs, ["list-sessions-strict", "max-seq-all-strict"])
        got = lay.cursors_doc()["sessions"]
        self.assertEqual({sid: got[sid]["cursor"] for sid in sids}, {sid: i for i, sid in enumerate(sids)})

    def test_max_seq_all_merges_stores_and_skips_empty_sessions(self) -> None:
        lay = Layout(self)
        other = os.path.join(lay.oc_home, "agents", "dev", "agent", "openclaw-agent.sqlite")
        fixture(
            ("mk_store", lay.db),
            ("mk_session", lay.db, SID_A, "agent:main:main", "", 100),
            ("mk_event", lay.db, SID_A, 7, event(7, "user", "fixture")),
            ("mk_session", lay.db, SID_B, "agent:main:empty", "", 100),
            ("mk_store", other),
            ("mk_session", other, SID_C, "agent:dev:main", "", 100),
            ("mk_event", other, SID_C, 2, event(2, "user", "fixture")),
        )
        client = store.StoreClient(os.path.join(str(_REPO_ROOT), "scripts", "session-store.sh"), lay.oc_home)
        self.assertEqual(client.max_seq_all(), {SID_A: (7, 7), SID_C: (2, 2)})
        lay.infer()
        self.assertEqual(lay.cursors_doc()["sessions"][SID_B]["cursor"], -1)

    def test_failed_event_read_keeps_cursor_and_updated_at(self) -> None:
        self.add_turns(SID_A, 1, 2, 170)
        before = self.cursors_bytes()
        bad = os.path.join(self.lay.base, "bad", "openclaw-agent.sqlite")
        write_garbage(bad)
        runner = CountingRunner(broken={"session-events-seq-strict": bad})
        with mock.patch.object(run, "StoreClient",
                               lambda *a, **k: store.StoreClient(*a, **dict(k, runner=runner))):
            doc = self.lay.infer()
        self.assertIn("session-events-seq-strict", runner.verbs)
        self.assertGreater(doc["counters"]["storeFailures"], 0)
        self.assertEqual(self.cursors_bytes(), before)
        doc = self.lay.infer()
        self.assertEqual([r["seq"] for r in self.lay.cached(SID_A)], [1, 2])

    def test_short_read_keeps_the_old_updated_at(self) -> None:
        self.add_turns(SID_A, 1, 3, 170)

        def short(argv, **kwargs):
            proc = subprocess.run(argv, **kwargs)
            if argv[2] == "session-events-seq-strict":
                lines = proc.stdout.splitlines(keepends=True)
                proc = subprocess.CompletedProcess(argv, 0, b"".join(lines[:-1]), b"")
            return proc

        with mock.patch.object(run, "StoreClient",
                               lambda *a, **k: store.StoreClient(*a, **dict(k, runner=short))):
            self.lay.infer()
        entry = self.lay.cursors_doc()["sessions"][SID_A]
        self.assertEqual(entry["cursor"], 2)
        self.assertEqual(entry["updatedAt"], "100")
        doc = self.lay.infer()
        self.assertEqual(doc["counters"]["sessionsRead"], 1)
        self.assertEqual([r["seq"] for r in self.lay.cached(SID_A)], [1, 2, 3])
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_A]["updatedAt"], "170")

    def test_compacted_head_row_does_not_force_rereads(self) -> None:
        fixture(
            ("mk_event", self.lay.db, SID_A, 1, event(1, "user", "fixture turn")),
            ("mk_compacted_event", self.lay.db, SID_A, 2),
            ("mk_touch_session", self.lay.db, SID_A, 170),
        )
        self.lay.infer()
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_A]["updatedAt"], "170")
        doc = self.lay.infer()
        self.assertEqual(doc["counters"]["sessionsSkippedUnchanged"], 1)

    def test_store_client_keeps_failed_distinct_from_empty(self) -> None:
        lay = Layout(self)
        fixture(("mk_store", lay.db))
        client = store.StoreClient(os.path.join(str(_REPO_ROOT), "scripts", "session-store.sh"), lay.oc_home)
        self.assertEqual(client.list_sessions(), [])
        self.assertEqual(client.max_seq(SID_A), -1)
        self.assertEqual(client.events_since(SID_A, -1), [])
        self.assertEqual(client.failures, 0)
        self.assertEqual(client.max_seq_all(), {})
        with BrokenStore(lay.db):
            self.assertIsNone(client.list_sessions())
            self.assertIsNone(client.max_seq(SID_A))
            self.assertIsNone(client.events_since(SID_A, -1))
            self.assertIsNone(client.max_seq_all())
        self.assertEqual(client.failures, 4)

    def test_prune_deletes_files_older_than_seven_days(self) -> None:
        turn_cache = cache.TurnCache(self.lay.state)
        for sid in (SID_B, SID_C):
            turn_cache.append(sid, [{"seq": 0, "role": "user", "text": "fixture", "tools": []}])
        now = time.time()
        os.utime(turn_cache.path(SID_B), (now - 8 * 86400, now - 8 * 86400))
        os.utime(turn_cache.path(SID_C), (now - 6 * 86400, now - 6 * 86400))
        turn_cache.prune(now)
        self.assertFalse(os.path.exists(turn_cache.path(SID_B)))
        self.assertTrue(os.path.exists(turn_cache.path(SID_C)))

    def test_prune_drops_expired_records_from_an_active_session(self) -> None:
        turn_cache = cache.TurnCache(self.lay.state)
        now = time.time()
        turn_cache.append(SID_B, [{"seq": i, "role": "user", "text": f"fixture old {i}", "tools": []}
                                  for i in range(3)], now=now - 8 * 86400)
        turn_cache.append(SID_B, [{"seq": 3, "role": "user", "text": "fixture new", "tools": []}], now=now)
        turn_cache.prune(now)
        self.assertEqual([r["seq"] for r in turn_cache.read(SID_B)], [3])
        self.assertEqual(stat.S_IMODE(os.stat(turn_cache.path(SID_B)).st_mode), 0o600)
        self.assertEqual(turn_cache.last_seq(SID_B), 3)

    def test_prune_deletes_a_fresh_file_whose_records_all_expired(self) -> None:
        turn_cache = cache.TurnCache(self.lay.state)
        now = time.time()
        turn_cache.append(SID_B, [{"seq": 0, "role": "user", "text": "fixture", "tools": []}],
                          now=now - 8 * 86400)
        turn_cache.prune(now)
        self.assertFalse(os.path.exists(turn_cache.path(SID_B)))

    def test_prune_ages_records_without_cached_at_by_their_ts(self) -> None:
        turn_cache = cache.TurnCache(self.lay.state)
        os.makedirs(turn_cache.dir, 0o700, exist_ok=True)
        now = time.time()
        old_ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now - 9 * 86400))
        new_ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now - 3600))
        lines = [
            {"seq": 0, "role": "user", "ts": old_ts, "text": "fixture old", "tools": []},
            {"seq": 1, "role": "user", "ts": "not a time", "text": "fixture bad", "tools": []},
            {"seq": 2, "role": "user", "ts": new_ts, "text": "fixture new", "tools": []},
        ]
        fd = os.open(turn_cache.path(SID_B), os.O_WRONLY | os.O_CREAT, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write("".join(json.dumps(r) + "\n" for r in lines))
        turn_cache.prune(now)
        self.assertEqual([r["seq"] for r in turn_cache.read(SID_B)], [2])

    def test_appended_records_carry_cached_at(self) -> None:
        turn_cache = cache.TurnCache(self.lay.state)
        turn_cache.append(SID_B, [{"seq": 0, "role": "user", "text": "fixture", "tools": []}], now=1234.9)
        self.assertEqual(turn_cache.read(SID_B)[0]["cachedAt"], 1234)

    def test_prune_cuts_an_oversized_file_to_its_newest_records(self) -> None:
        turn_cache = cache.TurnCache(self.lay.state)
        filler = "fixture é" * 250
        records = [{"seq": i, "role": "user", "text": filler, "tools": []} for i in range(400)]
        turn_cache.append(SID_B, records)
        path = turn_cache.path(SID_B)
        self.assertGreater(os.path.getsize(path), cache.SESSION_CAP_BYTES)
        turn_cache.prune(time.time())
        self.assertLessEqual(os.path.getsize(path), cache.SESSION_CAP_BYTES)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(turn_cache.last_seq(SID_B), 399)
        kept = [r["seq"] for r in turn_cache.read(SID_B)]
        self.assertEqual(kept, list(range(400 - len(kept), 400)))
        self.assertGreater(len(kept), 0)
        self.assertEqual([n for n in os.listdir(turn_cache.dir) if n.endswith(".tmp")], [])

    def test_soft_deadline_stops_between_sessions(self) -> None:
        fixture(
            ("mk_session", self.lay.db, SID_B, "agent:main:b", "", 300),
            ("mk_event", self.lay.db, SID_B, 0, event(0, "user", "fixture b")),
            ("mk_session", self.lay.db, SID_C, "agent:main:c", "", 200),
            ("mk_event", self.lay.db, SID_C, 0, event(0, "user", "fixture c")),
        )
        ctx = self.lay.context(budget=30)
        counters = run.run_infer(ctx, clock=fake_clock(0.0, 0.0, 1e9))
        self.assertEqual(counters["sessionsRead"], 1)
        doc = self.lay.cursors_doc()["sessions"]
        self.assertIn(SID_B, doc)
        self.assertNotIn(SID_C, doc)
        self.assertEqual(len(self.lay.cached(SID_B)), 1)
        self.assertEqual(self.lay.cached(SID_C), [])

        counters = run.run_infer(ctx)
        self.assertEqual(counters["sessionsRead"], 1)
        self.assertEqual(len(self.lay.cached(SID_C)), 1)
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_C]["cursor"], 0)

    def test_cursors_of_vanished_sessions_drop_once_their_cache_is_gone(self) -> None:
        fixture(
            ("mk_session", self.lay.db, SID_B, "agent:main:b", "", 300),
            ("mk_session", self.lay.db, SID_C, "agent:main:c", "", 301),
            ("mk_event", self.lay.db, SID_C, 0, event(0, "user", "fixture c")),
        )
        self.lay.infer()
        self.assertEqual(set(self.lay.cursors_doc()["sessions"]), {SID_A, SID_B, SID_C})

        fixture(
            ("mk_store", self.lay.db),
            ("mk_session", self.lay.db, SID_A, "agent:main:main", "", 100),
            ("mk_event", self.lay.db, SID_A, 0, event(0, "user", "fixture before install")),
        )
        for _ in range(cache.MISSES_BEFORE_DROP - 1):
            self.lay.infer()
            self.assertEqual(set(self.lay.cursors_doc()["sessions"]), {SID_A, SID_B, SID_C})
        self.lay.infer()
        self.assertEqual(set(self.lay.cursors_doc()["sessions"]), {SID_A, SID_C})

        path = cache.TurnCache(self.lay.state).path(SID_C)
        old = time.time() - 8 * 86400
        os.utime(path, (old, old))
        self.lay.infer()
        self.assertFalse(os.path.exists(path))
        self.assertEqual(set(self.lay.cursors_doc()["sessions"]), {SID_A})

    def set_created_via(self, sid: str, value: str | None) -> None:
        # The listing leaves out cron sessions, so this hides or shows one.
        conn = sqlite3.connect(self.lay.db)
        try:
            conn.execute("UPDATE session_nodes SET created_via = ? WHERE current_session_id = ?", (value, sid))
            conn.commit()
        finally:
            conn.close()

    def test_a_session_listed_again_resets_its_misses(self) -> None:
        fixture(("mk_session", self.lay.db, SID_B, "agent:main:b", "", 300))
        self.lay.infer()
        self.set_created_via(SID_B, "cron")
        for _ in range(cache.MISSES_BEFORE_DROP - 1):
            self.lay.infer()
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_B]["misses"], cache.MISSES_BEFORE_DROP - 1)
        self.set_created_via(SID_B, None)
        self.lay.infer()
        self.assertNotIn("misses", self.lay.cursors_doc()["sessions"][SID_B])

    def test_partial_listing_keeps_cursors_of_the_unread_store(self) -> None:
        lay = Layout(self)
        other = os.path.join(lay.oc_home, "agents", "dev", "agent", "openclaw-agent.sqlite")
        fixture(
            ("mk_store", lay.db),
            ("mk_session", lay.db, SID_B, "agent:main:main", "", 100),
            ("mk_store", other),
            ("mk_session", other, SID_C, "agent:dev:main", "", 100),
            ("mk_event", other, SID_C, 0, event(0, "user", "fixture dev history")),
        )
        lay.infer()
        fixture(("mk_touch_session", lay.db, SID_B, 150))
        for _ in range(cache.MISSES_BEFORE_DROP + 1):
            with BrokenStore(other):
                doc = lay.infer()
            self.assertGreater(doc["counters"]["storeFailures"], 0)
            self.assertIn(SID_C, lay.cursors_doc()["sessions"])
        lay.infer()
        self.assertEqual(lay.cursors_doc()["sessions"][SID_C]["cursor"], 0)
        self.assertNotIn(b"dev history", lay.state_bytes())


class TestRecheck(unittest.TestCase):
    def setUp(self) -> None:
        self.lay = Layout(self)
        fixture(
            ("mk_store", self.lay.db),
            ("mk_session", self.lay.db, SID_A, "agent:main:main", "", 100),
            ("mk_event", self.lay.db, SID_A, 0, event(0, "user", "fixture before install")),
            ("mk_session", self.lay.db, SID_B, "agent:main:b", "", 100),
            ("mk_event", self.lay.db, SID_B, 0, event(0, "user", "fixture b before install")),
        )
        self.lay.infer()

    def cursors_path(self) -> str:
        return os.path.join(self.lay.state, cache.CURSORS_FILE)

    def cursors_bytes(self) -> bytes:
        with open(self.cursors_path(), "rb") as handle:
            return handle.read()

    def age_check_time(self) -> int:
        doc = self.lay.cursors_doc()
        aged = int(time.time()) - run.MAX_SEQ_RECHECK_SECONDS - 1
        doc["maxSeqCheckedAt"] = aged
        with open(self.cursors_path(), "w", encoding="utf-8") as handle:
            json.dump(doc, handle)
        return aged

    def add_silent_turn(self, sid: str, seq: int, text: str) -> None:
        """A new row with no updated_at change, as a store that breaks the rule writes it."""
        fixture(("mk_event", self.lay.db, sid, seq, event(seq, "user", text)))

    def test_turn_added_without_an_updated_at_change_is_read_on_recheck(self) -> None:
        self.add_silent_turn(SID_A, 1, "fixture silent turn")
        doc = self.lay.infer()
        self.assertEqual(self.lay.cached(SID_A), [])
        self.assertEqual(doc["counters"]["sessionsReadOnRecheck"], 0)

        self.age_check_time()
        started = int(time.time())
        doc = self.lay.infer()
        self.assertEqual([r["text"] for r in self.lay.cached(SID_A)], ["fixture silent turn"])
        self.assertEqual(doc["counters"]["sessionsReadOnRecheck"], 1)
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_A]["cursor"], 1)
        self.assertGreaterEqual(self.lay.cursors_doc()["maxSeqCheckedAt"], started)

    def test_recheck_of_a_quiet_store_reads_no_events_and_then_waits(self) -> None:
        aged = self.age_check_time()
        runner = CountingRunner()
        patch_runner(self, runner)
        doc = self.lay.infer()
        self.assertEqual(runner.verbs, ["list-sessions-strict", "max-seq-all-strict"])
        self.assertEqual(doc["counters"]["sessionsRead"], 0)
        self.assertEqual(doc["counters"]["sessionsReadOnRecheck"], 0)
        self.assertGreater(self.lay.cursors_doc()["maxSeqCheckedAt"], aged)

        before = self.cursors_bytes()
        runner.verbs.clear()
        self.lay.infer()
        self.assertEqual(runner.verbs, ["list-sessions-strict"])
        self.assertEqual(self.cursors_bytes(), before)

    def test_recheck_tick_with_a_changed_session_calls_max_seq_all_once(self) -> None:
        self.add_silent_turn(SID_A, 1, "fixture silent a")
        fixture(
            ("mk_event", self.lay.db, SID_B, 1, event(1, "user", "fixture touched b")),
            ("mk_touch_session", self.lay.db, SID_B, 150),
        )
        self.age_check_time()
        runner = CountingRunner()
        patch_runner(self, runner)
        doc = self.lay.infer()
        self.assertEqual(runner.verbs.count("max-seq-all-strict"), 1)
        self.assertEqual(doc["counters"]["sessionsRead"], 2)
        self.assertEqual(doc["counters"]["sessionsReadOnRecheck"], 1)
        self.assertEqual([r["text"] for r in self.lay.cached(SID_A)], ["fixture silent a"])
        self.assertEqual([r["text"] for r in self.lay.cached(SID_B)], ["fixture touched b"])

    def test_failed_recheck_keeps_the_old_check_time(self) -> None:
        self.add_silent_turn(SID_A, 1, "fixture silent turn")
        aged = self.age_check_time()
        bad = os.path.join(self.lay.base, "bad", "openclaw-agent.sqlite")
        write_garbage(bad)
        runner = CountingRunner(broken={"max-seq-all-strict": bad})
        patch_runner(self, runner)
        doc = self.lay.infer()
        self.assertIn("max-seq-all-strict", runner.verbs)
        self.assertNotIn("session-events-seq-strict", runner.verbs)
        self.assertGreater(doc["counters"]["storeFailures"], 0)
        self.assertEqual(self.lay.cursors_doc()["maxSeqCheckedAt"], aged)
        self.assertEqual(self.lay.cached(SID_A), [])

        runner.broken.clear()
        doc = self.lay.infer()
        self.assertEqual(doc["counters"]["sessionsReadOnRecheck"], 1)
        self.assertEqual([r["text"] for r in self.lay.cached(SID_A)], ["fixture silent turn"])
        self.assertGreater(self.lay.cursors_doc()["maxSeqCheckedAt"], aged)

    def test_deadline_cut_recheck_keeps_the_old_check_time(self) -> None:
        self.add_silent_turn(SID_A, 1, "fixture silent a")
        self.add_silent_turn(SID_B, 1, "fixture silent b")
        aged = self.age_check_time()
        counters = run.run_infer(self.lay.context(budget=30), clock=fake_clock(0.0, 0.0, 1e9))
        self.assertGreater(counters["sessionsDeferred"], 0)
        self.assertEqual(counters["sessionsReadOnRecheck"], 1)
        self.assertEqual(self.lay.cursors_doc()["maxSeqCheckedAt"], aged)

        counters = run.run_infer(self.lay.context(budget=30))
        self.assertEqual(counters["sessionsDeferred"], 0)
        self.assertEqual(counters["sessionsReadOnRecheck"], 1)
        self.assertGreater(self.lay.cursors_doc()["maxSeqCheckedAt"], aged)
        self.assertEqual(len(self.lay.cached(SID_A)) + len(self.lay.cached(SID_B)), 2)

    def test_compacted_head_row_does_not_trigger_a_recheck_read(self) -> None:
        fixture(
            ("mk_event", self.lay.db, SID_A, 1, event(1, "user", "fixture turn")),
            ("mk_compacted_event", self.lay.db, SID_A, 2),
            ("mk_touch_session", self.lay.db, SID_A, 170),
        )
        self.lay.infer()
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_A]["cursor"], 1)
        self.age_check_time()
        runner = CountingRunner()
        patch_runner(self, runner)
        doc = self.lay.infer()
        self.assertIn("max-seq-all-strict", runner.verbs)
        self.assertNotIn("session-events-seq-strict", runner.verbs)
        self.assertEqual(doc["counters"]["sessionsReadOnRecheck"], 0)
        self.assertEqual(doc["counters"]["sessionsSkippedUnchanged"], 2)

    def test_baseline_records_the_check_time(self) -> None:
        lay = Layout(self)
        fixture(
            ("mk_store", lay.db),
            ("mk_session", lay.db, SID_C, "agent:main:c", "", 100),
            ("mk_event", lay.db, SID_C, 4, event(4, "user", "fixture history")),
        )
        runner = CountingRunner()
        patch_runner(self, runner)
        started = int(time.time())
        lay.infer()
        self.assertEqual(runner.verbs, ["list-sessions-strict", "max-seq-all-strict"])
        checked = lay.cursors_doc().get("maxSeqCheckedAt")
        self.assertIsInstance(checked, int)
        self.assertGreaterEqual(checked, started)

        runner.verbs.clear()
        doc = lay.infer()
        self.assertEqual(runner.verbs, ["list-sessions-strict"])
        self.assertEqual(doc["counters"]["sessionsReadOnRecheck"], 0)
        self.assertEqual(lay.cursors_doc()["maxSeqCheckedAt"], checked)

    def test_check_time_parsing_falls_back_to_due(self) -> None:
        now = time.time()
        interval = run.MAX_SEQ_RECHECK_SECONDS
        base = {
            "version": 1,
            "baselinedAt": "2026-10-26T12:00:00Z",
            "sessions": {
                SID_A: {"cursor": 7, "updatedAt": "170"},
                SID_B: {"cursor": -1, "updatedAt": ""},
            },
        }
        missing = object()
        cases = (
            ("missing", missing, True),
            ("boolean", True, True),
            ("negative", -5, True),
            ("string", str(int(now)), True),
            ("float", float(int(now)), True),
            ("far future", int(now) + interval + 100, True),
            ("recent", int(now) - 5, False),
        )
        for label, value, due in cases:
            with self.subTest(label):
                doc = dict(base)
                if value is not missing:
                    doc["maxSeqCheckedAt"] = value
                with open(self.cursors_path(), "w", encoding="utf-8") as handle:
                    json.dump(doc, handle)
                cursors = cache.Cursors.load(self.lay.state)
                self.assertFalse(cursors.baseline_needed)
                self.assertEqual(cursors.recheck_due(now, interval), due)
                self.assertEqual(cursors.get(SID_A), {"cursor": 7, "updatedAt": "170"})
                self.assertEqual(cursors.get(SID_B), {"cursor": -1, "updatedAt": ""})


class TestDeadline(unittest.TestCase):
    """The SIGALRM deadline must stop the stage, never be swallowed."""

    def setUp(self) -> None:
        self.lay = Layout(self)
        fixture(
            ("mk_store", self.lay.db),
            ("mk_session", self.lay.db, SID_A, "agent:main:main", "", 100),
            ("mk_event", self.lay.db, SID_A, 0, event(0, "user", "fixture before install")),
        )
        self.lay.infer()

    def test_deadline_is_not_an_exception(self) -> None:
        self.assertFalse(issubclass(run.DeadlineExceeded, Exception))

    def test_sanitize_turn_lets_the_deadline_through(self) -> None:
        with mock.patch.object(redact, "redact", side_effect=run.DeadlineExceeded()):
            with self.assertRaises(run.DeadlineExceeded):
                redact.sanitize_turn("fixture text", ())

    def test_store_call_lets_the_deadline_through(self) -> None:
        def runner(argv, **kwargs):
            raise run.DeadlineExceeded()

        client = store.StoreClient("/nonexistent/session-store.sh", self.lay.oc_home, runner=runner)
        with self.assertRaises(run.DeadlineExceeded):
            client.list_sessions()
        self.assertEqual(client.failures, 0)

    def test_turn_interrupted_mid_redaction_is_cached_later_not_omitted(self) -> None:
        fixture(
            ("mk_event", self.lay.db, SID_A, 1, event(1, "user", "fixture first turn")),
            ("mk_event", self.lay.db, SID_A, 2, event(2, "user", "fixture second turn")),
            ("mk_touch_session", self.lay.db, SID_A, 150),
        )
        real = redact.redact
        calls = []

        def interrupted(text, known):
            calls.append(text)
            if len(calls) == 2:
                raise run.DeadlineExceeded()
            return real(text, known)

        with mock.patch.object(redact, "redact", side_effect=interrupted):
            rc = run.main(self.lay.argv(), find_library=lambda: True)
        self.assertEqual(rc, run.EXIT_DEADLINE)
        self.assertEqual(self.lay.status()["reason"], "timeout")
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_A]["cursor"], 0)
        self.assertNotIn(redact.OMITTED.encode("utf-8"), self.lay.state_bytes())

        doc = self.lay.infer()
        self.assertEqual(doc["counters"]["redactionOmitted"], 0)
        self.assertEqual([r["text"] for r in self.lay.cached(SID_A)],
                         ["fixture first turn", "fixture second turn"])
        self.assertEqual(self.lay.cursors_doc()["sessions"][SID_A]["cursor"], 2)

    def test_deadline_during_the_baseline_reports_timeout(self) -> None:
        lay = Layout(self)
        fixture(("mk_store", lay.db), ("mk_session", lay.db, SID_B, "agent:main:main", "", 100))

        def runner(argv, **kwargs):
            if argv[2] != "list-sessions-strict":
                raise run.DeadlineExceeded()
            return subprocess.run(argv, **kwargs)

        patch_runner(self, runner)
        rc = run.main(lay.argv(), find_library=lambda: True)
        self.assertEqual(rc, run.EXIT_DEADLINE)
        self.assertFalse(os.path.exists(os.path.join(lay.state, cache.CURSORS_FILE)))

    def test_stale_temp_files_are_swept_and_fresh_ones_kept(self) -> None:
        state = self.lay.state
        stale = os.path.join(state, ".cursors.json.abc123.tmp")
        fresh = os.path.join(state, ".deliver-status.json.def456.tmp")
        for path in (stale, fresh):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
            os.close(fd)
        old = time.time() - run.STALE_TMP_SECONDS - 60
        os.utime(stale, (old, old))
        self.lay.infer()
        self.assertFalse(os.path.exists(stale))
        self.assertTrue(os.path.exists(fresh))


if __name__ == "__main__":
    unittest.main()
