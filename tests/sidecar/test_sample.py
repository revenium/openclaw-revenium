"""Transcript samples and planted-secret proofs on both arms' event shapes.

Every planted secret is assembled from pieces at runtime (the table comes
from test_redaction), so no complete key-shaped string is committed.

TestBuild covers build_messages (text first, then one marker per tool) and
build_sample, which must return exactly the library's sample_transcript
excerpt over the cached turns, with the library's default budgets.

TestPlantedSecrets inserts the recorded NemoClaw event shapes
(tests/sidecar/fixtures/nemoclaw-events.jsonl) and standalone-shaped events
(mk_toolcall_pair plus user, assistant and toolResult rows) into a real
fixture store, with a secret of every regex kind and a host-known value
appended to their text and directive blocks prepended to the user text.
After a real infer tick, no secret, directive text, tool-result body or
custom-row body may appear in the built sample or in any file under the
state dir. The host-known value is loaded from each of its sources in turn,
and a forced redaction failure must cache ``[turn omitted]`` for every turn.
"""
from __future__ import annotations

import importlib
import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

_TESTS_DIR = Path(__file__).resolve().parent
_REPO_ROOT = _TESTS_DIR.parent.parent
_SIDECAR_DIR = _REPO_ROOT / "sidecar"
for _path in (str(_SIDECAR_DIR), str(_TESTS_DIR)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

from openclaw_economics import cache, redact  # noqa: E402
from revenium_agent_economics import sample_transcript  # noqa: E402
from test_read_path import SID_A, SID_B, Layout, event, fixture  # noqa: E402
from test_redaction import KNOWN, SECRETS  # noqa: E402

NEMOCLAW_FIXTURE = _TESTS_DIR / "fixtures" / "nemoclaw-events.jsonl"

DIRECTIVES = (
    "<revenium-guard>\nfixture directive guard\n</revenium-guard>\n"
    "<revenium-metering>\nfixture directive metering\n</revenium-metering>\n"
    "<!-- BEGIN revenium-metering-directives -->\nfixture directive agents\n"
    "<!-- END revenium-metering-directives -->\n"
)

FORBIDDEN_TEXT = (
    "fixture directive",
    "fixture tool result body",
    "fixture nested tool record",
    "tool output",
    "tool error text",
)


def sample_module():
    return importlib.import_module("openclaw_economics.sample")


def planted_suffix() -> str:
    parts = [planted for planted, _material in SECRETS.values()]
    parts.append(KNOWN)
    return "\n" + " ; ".join(parts)


def secret_materials() -> list:
    return [material for _planted, material in SECRETS.values()] + [KNOWN]


def with_secrets(line: dict) -> dict:
    """Append every planted secret to each text part of one event."""
    doc = json.loads(json.dumps(line))
    message = doc["message"]
    content = message.get("content")
    if isinstance(content, str):
        message["content"] = content + planted_suffix()
        if message.get("role") == "user":
            message["content"] = DIRECTIVES + message["content"]
    elif isinstance(content, list):
        for item in content:
            if item.get("type") == "text":
                item["text"] += planted_suffix()
                if message.get("role") == "user":
                    item["text"] = DIRECTIVES + item["text"]
    return doc


def nemoclaw_rows() -> list:
    with open(NEMOCLAW_FIXTURE, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


class PlantedLayout(Layout):
    """A Layout baselined on an empty session, ready for a new session."""

    def __init__(self, test: unittest.TestCase) -> None:
        super().__init__(test)
        fixture(
            ("mk_store", self.db),
            ("mk_session", self.db, SID_A, "agent:main:main", "", 100),
        )
        self.infer()

    def insert_nemoclaw(self, transform=with_secrets) -> int:
        steps = [("mk_session", self.db, SID_B, "agent:main:subagent:x", "spawn", 200)]
        for seq, row in enumerate(nemoclaw_rows()):
            steps.append(("mk_event", self.db, SID_B, seq, json.dumps(transform(row))))
        fixture(*steps)
        return len(steps) - 1


class TestBuild(unittest.TestCase):
    def test_build_messages_renders_text_then_markers(self) -> None:
        records = [
            {"role": "assistant", "text": "hello", "tools": ["exec", ""]},
            {"role": "assistant", "text": "", "tools": ["exec"]},
            {"role": "user", "text": "plain", "tools": []},
        ]
        self.assertEqual(sample_module().build_messages(records), [
            ("assistant", "hello\n[tool: exec]\n[tool]"),
            ("assistant", "[tool: exec]"),
            ("user", "plain"),
        ])

    def test_build_sample_is_the_library_excerpt(self) -> None:
        lay = Layout(self)
        turn_cache = cache.TurnCache(lay.state)
        turn_cache.append(SID_B, [
            {"seq": 0, "role": "user", "text": "fixture please list files", "tools": []},
            {"seq": 1, "role": "assistant", "text": "fixture listing", "tools": ["exec"]},
            {"seq": 2, "role": "assistant", "text": "fixture done", "tools": []},
        ])
        mod = sample_module()
        text = mod.build_sample(turn_cache, SID_B)
        self.assertIn("user: ", text)
        self.assertIn("assistant: ", text)
        self.assertIn("[tool: exec]", text)
        expected = sample_transcript(mod.build_messages(turn_cache.read(SID_B))).text
        self.assertEqual(text, expected)


class TestPlantedSecrets(unittest.TestCase):
    def assertClean(self, lay: Layout, sid: str) -> str:
        sample = sample_module().build_sample(cache.TurnCache(lay.state), sid)
        blob = lay.state_bytes().decode("utf-8", errors="replace")
        for where, text in (("sample", sample), ("state dir", blob)):
            for material in secret_materials():
                self.assertNotIn(material, text, f"secret survived in {where}")
            for needle in FORBIDDEN_TEXT:
                self.assertNotIn(needle, text, f"{needle!r} survived in {where}")
        return sample

    def test_nemoclaw_shapes_leak_nothing(self) -> None:
        lay = PlantedLayout(self)
        with open(os.path.join(lay.oc_home, "revenium.env"), "w", encoding="utf-8") as handle:
            handle.write(f"REVENIUM_API_KEY={KNOWN}\n")
        lay.insert_nemoclaw()
        doc = lay.infer()
        self.assertEqual(doc["counters"]["turnsCached"], 4)
        sample = self.assertClean(lay, SID_B)
        self.assertIn("[tool: exec]", sample)
        self.assertNotIn("[tool: tool_call]", sample)
        self.assertIn("[REDACTED:known]", sample)
        self.assertIn("fixture assistant final reply", sample)

    def test_standalone_shapes_leak_nothing(self) -> None:
        lay = PlantedLayout(self)
        with open(os.path.join(lay.oc_home, "revenium.env"), "w", encoding="utf-8") as handle:
            handle.write(f"export REVENIUM_API_KEY='{KNOWN}'\n")
        suffix = planted_suffix()
        fixture(
            ("mk_session", lay.db, SID_B, "agent:main:main2", "", 200),
            ("mk_event", lay.db, SID_B, 0, event(0, "user", [{"type": "text", "text": DIRECTIVES + "fixture ask" + suffix}])),
            ("mk_event", lay.db, SID_B, 1, event(1, "assistant", [
                {"type": "thinking", "thinking": "fixture directive thinking" + suffix},
                {"type": "text", "text": "fixture answer" + suffix},
                {"type": "toolCall", "id": "c-1", "name": "exec", "arguments": {"command": suffix}},
            ])),
            ("mk_event", lay.db, SID_B, 2, event(2, "toolResult", [
                {"type": "text", "text": "fixture tool result body" + suffix}],
                toolCallId="c-1", toolName="exec")),
            ("mk_toolcall_pair", lay.db, SID_B, 3, "c-2", "exec", 12, 0),
            ("mk_toolcall_pair", lay.db, SID_B, 5, "c-3", "read", 3, 1),
        )
        doc = lay.infer()
        self.assertEqual(doc["counters"]["turnsCached"], 4)
        sample = self.assertClean(lay, SID_B)
        self.assertIn("[tool: exec]", sample)
        self.assertIn("[tool: read]", sample)
        self.assertNotIn("thinking", sample)

    def _known_value_from(self, place) -> None:
        lay = PlantedLayout(self)
        place(lay)
        fixture(
            ("mk_session", lay.db, SID_B, "agent:main:main2", "", 200),
            ("mk_event", lay.db, SID_B, 0, event(0, "user", f"fixture value {KNOWN} here")),
        )
        lay.infer()
        records = lay.cached(SID_B)
        self.assertEqual([r["text"] for r in records], ["fixture value [REDACTED:known] here"])
        self.assertClean(lay, SID_B)

    def test_known_value_from_nemoclaw_host_env(self) -> None:
        def place(lay):
            os.mkdir(os.path.join(lay.home, ".nemoclaw"), 0o700)
            with open(os.path.join(lay.home, ".nemoclaw", "revenium-host.env"), "w", encoding="utf-8") as handle:
                handle.write(f'REVENIUM_API_KEY="{KNOWN}"\n')

        self._known_value_from(place)

    def test_known_value_from_openclaw_revenium_env(self) -> None:
        def place(lay):
            with open(os.path.join(lay.oc_home, "revenium.env"), "w", encoding="utf-8") as handle:
                handle.write(f"REVENIUM_API_KEY={KNOWN}\n")

        self._known_value_from(place)

    def test_known_value_from_model_key_file(self) -> None:
        def place(lay):
            fd = os.open(os.path.join(lay.state, "model.key"), os.O_WRONLY | os.O_CREAT, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(KNOWN + "\n")

        self._known_value_from(place)

    def test_known_value_from_revenium_config_yaml(self) -> None:
        def place(lay):
            os.makedirs(os.path.join(lay.home, ".config", "revenium"), 0o700)
            with open(os.path.join(lay.home, ".config", "revenium", "config.yaml"), "w", encoding="utf-8") as handle:
                handle.write(f"api-key: {KNOWN}\n")

        self._known_value_from(place)

    def test_forced_redaction_failure_omits_every_turn(self) -> None:
        lay = PlantedLayout(self)
        lay.insert_nemoclaw()
        with mock.patch.object(redact, "redact", side_effect=RuntimeError("boom")):
            doc = lay.infer()
        records = lay.cached(SID_B)
        self.assertEqual(len(records), 4)
        self.assertEqual({r["text"] for r in records}, {redact.OMITTED})
        self.assertEqual(doc["counters"]["redactionOmitted"], len(records))
        self.assertClean(lay, SID_B)


if __name__ == "__main__":
    unittest.main()
