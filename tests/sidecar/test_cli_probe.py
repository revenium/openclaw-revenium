"""Tests for the deliver stage's revenium CLI capability probe.

TestParsing covers strip_ansi, parse_version, the 1.7.0 floor comparison and
has_command against help fixtures copied from the real revenium 1.9.0 layout
(ANSI-coloured even when piped), including the false positives the probe
must not report: a command named only in Examples, in a wrapped description
line, or in the parent help an old CLI prints for an unknown verb.

TestProbe covers probe and load_or_probe through a fake runner that records
every argv list: a missing binary, an empty version line, the per-version
cache (one `revenium version` call when nothing changed, a full re-probe when
the version line changes) and the exact argv lists the runner may receive.

TestRunDeliver covers the wiring in run.run_deliver: phase pre records the
probe result, phase post skips it, and a probe exception is recorded as
capable false with its type name instead of failing the stage.
"""
from __future__ import annotations

import json
import os
import stat
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
from openclaw_economics import cli_probe  # noqa: E402
from openclaw_economics.paths import Context  # noqa: E402

ESC = "\x1b"


def _c(code: str, text: str) -> str:
    return f"{ESC}[{code}m{text}{ESC}[m"


def _cmd(name: str, desc: str, pad: int = 17) -> str:
    return "  " + _c("38;5;73", name.ljust(pad)) + "   " + _c("38;5;252", desc)


def _jobs_help(include_outcome_metrics: bool = True) -> str:
    commands = [
        ("create", "Create a new job"),
        ("get", "Get a job by agenticJobId"),
        ("list", "List all jobs"),
        ("outcome", "Report a job outcome (immutable)"),
        ("outcome-history", "List the outcome revision history for a job"),
    ]
    if include_outcome_metrics:
        commands.append(("outcome-metrics", "Append late per-job outcome metrics to an existing job"))
    commands += [("roi", "View ROI metrics for a job"), ("types", "List available job types")]
    lines = [
        _c("38;5;255", "Manage Agentic Jobs"),
        "",
        _c("1;38;5;99", "Usage:"),
        "  " + _c("38;5;220", "revenium jobs [command]"),
        "",
        _c("1;38;5;99", "Examples:"),
        _c("38;5;240", "  # Append metrics later"),
        _c("38;5;245", "  revenium jobs outcome-metrics loan-app-12345 --file m.json"),
        "",
        _c("1;38;5;99", "Available Commands:"),
    ]
    lines += [_cmd(n, d) for n, d in commands]
    lines += [
        "",
        _c("1;38;5;99", "Flags:"),
        "  " + _c("38;5;114", "-h, --help") + "   " + _c("38;5;252", "help for jobs"),
        "",
    ]
    return "\n".join(lines)


def _types_help(include_economics: bool = True) -> str:
    lines = [
        _c("38;5;255", "List available job types"),
        "",
        _c("1;38;5;99", "Usage:"),
        "  " + _c("38;5;220", "revenium jobs types [flags]"),
        "  " + _c("38;5;220", "revenium jobs types [command]"),
        "",
        _c("1;38;5;99", "Examples:"),
        _c("38;5;240", "  # Read a job type's declared economics contract"),
        _c("38;5;245", "  revenium jobs types economics get acme-review"),
        "",
        _c("1;38;5;99", "Available Commands:"),
        _cmd("baselines", "Read and append a job type's immutable pre-AI baseline versions", 9),
    ]
    if include_economics:
        lines.append(_cmd("economics", "Manage a job type's declared economics contract", 9))
    else:
        lines.append("              " + _c("38;5;252", "economics contract versions are listed elsewhere"))
    lines += [
        _cmd("facts", "Append a job type's declared period outcome facts", 9),
        "",
        _c("1;38;5;99", "Flags:"),
        "  " + _c("38;5;114", "-h, --help") + "   " + _c("38;5;252", "help for types"),
        "",
    ]
    return "\n".join(lines)


VERSION_ARGV = ["revenium", "version"]
JOBS_ARGV = ["revenium", "jobs", "--help"]
TYPES_ARGV = ["revenium", "jobs", "types", "--help"]
ALLOWED_ARGV = [VERSION_ARGV, JOBS_ARGV, TYPES_ARGV]


class FakeRunner:
    """Record every argv list and answer from a fixed table."""

    def __init__(self, version: str = "revenium 1.9.0 (8cf0e69)\n", jobs: str | None = None,
                 types: str | None = None) -> None:
        self.calls: list = []
        self.answers = {
            tuple(VERSION_ARGV): (0, version),
            tuple(JOBS_ARGV): (0, _jobs_help() if jobs is None else jobs),
            tuple(TYPES_ARGV): (0, _types_help() if types is None else types),
        }

    def __call__(self, argv, timeout: float = 10.0):
        self.calls.append(list(argv))
        return self.answers.get(tuple(argv), (0, ""))


class TestParsing(unittest.TestCase):
    def test_strip_ansi_removes_colour_sequences_only(self) -> None:
        text = f"{ESC}[38;5;255mManage{ESC}[0m jobs {ESC}[m(today) 50% [ok]"
        self.assertEqual(cli_probe.strip_ansi(text), "Manage jobs (today) 50% [ok]")

    def test_parse_version_reads_first_triple(self) -> None:
        self.assertEqual(cli_probe.parse_version("revenium 1.9.0 (8cf0e69)"), (1, 9, 0))

    def test_parse_version_empty_is_none(self) -> None:
        self.assertIsNone(cli_probe.parse_version(""))
        self.assertIsNone(cli_probe.parse_version("revenium dev"))

    def test_floor_compares_integer_tuples(self) -> None:
        self.assertEqual(cli_probe.FLOOR, (1, 7, 0))
        self.assertTrue(cli_probe.version_meets_floor((1, 10, 0)))
        self.assertTrue(cli_probe.version_meets_floor((1, 7, 0)))
        self.assertFalse(cli_probe.version_meets_floor((1, 6, 9)))
        self.assertFalse(cli_probe.version_meets_floor(None))

    def test_has_command_finds_listed_command(self) -> None:
        self.assertTrue(cli_probe.has_command(_jobs_help(), "outcome-metrics"))
        self.assertTrue(cli_probe.has_command(_types_help(), "economics"))

    def test_has_command_requires_exact_token(self) -> None:
        self.assertFalse(cli_probe.has_command(_jobs_help(), "outcome-metric"))
        self.assertFalse(cli_probe.has_command(_jobs_help(), "metrics"))

    def test_examples_mention_is_not_a_command(self) -> None:
        self.assertFalse(cli_probe.has_command(_jobs_help(include_outcome_metrics=False), "outcome-metrics"))
        self.assertFalse(cli_probe.has_command(_types_help(include_economics=False), "economics"))

    def test_wrapped_description_line_is_not_a_command(self) -> None:
        help_text = _types_help(include_economics=False)
        self.assertIn("economics contract versions", cli_probe.strip_ansi(help_text))
        self.assertNotIn("economics", cli_probe.available_commands(help_text))

    def test_available_commands_stops_at_blank_line(self) -> None:
        names = cli_probe.available_commands(_jobs_help())
        self.assertIn("create", names)
        self.assertIn("types", names)
        self.assertNotIn("-h,", names)

    def test_no_available_commands_block(self) -> None:
        self.assertEqual(set(cli_probe.available_commands("Usage:\n  revenium jobs\n")), set())


class TestProbe(unittest.TestCase):
    def setUp(self) -> None:
        self.state = tempfile.mkdtemp(prefix="sidecar-probe-")
        os.chmod(self.state, 0o700)
        self.bin_dir = tempfile.mkdtemp(prefix="sidecar-probe-bin-")
        self.cli = os.path.join(self.bin_dir, "revenium")
        with open(self.cli, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\nexit 0\n")
        self.addCleanup(self._cleanup)

    def _cleanup(self) -> None:
        for d in (self.state, self.bin_dir):
            for name in os.listdir(d):
                os.unlink(os.path.join(d, name))
            os.rmdir(d)

    def which(self, name: str):
        return self.cli if name == "revenium" else None

    def test_capable_cli(self) -> None:
        runner = FakeRunner()
        result = cli_probe.probe(runner=runner, which=self.which)
        self.assertEqual(result["version"], "1.9.0")
        self.assertEqual(result["versionLine"], "revenium 1.9.0 (8cf0e69)")
        self.assertEqual(result["cliPath"], os.path.realpath(self.cli))
        self.assertTrue(result["floorOk"])
        self.assertTrue(result["outcomeMetrics"])
        self.assertTrue(result["typesEconomics"])
        self.assertTrue(result["capable"])
        self.assertRegex(result["probedAt"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertEqual(
            set(result),
            {"cliPath", "versionLine", "version", "floorOk", "outcomeMetrics",
             "typesEconomics", "capable", "probedAt"},
        )

    def test_version_above_floor_with_two_digit_minor(self) -> None:
        result = cli_probe.probe(runner=FakeRunner(version="revenium 1.10.0 (abc)\n"), which=self.which)
        self.assertTrue(result["floorOk"])
        self.assertTrue(result["capable"])

    def test_version_below_floor_is_not_capable(self) -> None:
        result = cli_probe.probe(runner=FakeRunner(version="revenium 1.6.9 (abc)\n"), which=self.which)
        self.assertFalse(result["floorOk"])
        self.assertFalse(result["capable"])

    def test_old_cli_printing_parent_help_reports_false(self) -> None:
        old_jobs = _jobs_help(include_outcome_metrics=False)
        runner = FakeRunner(version="revenium 1.2.0 (aaa)\n", jobs=old_jobs, types=old_jobs)
        result = cli_probe.probe(runner=runner, which=self.which)
        self.assertFalse(result["outcomeMetrics"])
        self.assertFalse(result["typesEconomics"])
        self.assertFalse(result["capable"])

    def test_examples_only_types_help_reports_false(self) -> None:
        runner = FakeRunner(types=_types_help(include_economics=False))
        result = cli_probe.probe(runner=runner, which=self.which)
        self.assertTrue(result["outcomeMetrics"])
        self.assertFalse(result["typesEconomics"])
        self.assertFalse(result["capable"])

    def test_missing_binary_is_not_capable(self) -> None:
        runner = FakeRunner()
        result = cli_probe.probe(runner=runner, which=lambda name: None)
        self.assertFalse(result["capable"])
        self.assertEqual(result["version"], "")
        self.assertEqual(result["cliPath"], "")
        self.assertEqual(runner.calls, [])
        result = cli_probe.load_or_probe(self.state, runner=runner, which=lambda name: None)
        self.assertFalse(result["capable"])
        self.assertEqual(result["version"], "")
        self.assertEqual(runner.calls, [])

    def test_empty_version_output_is_not_capable(self) -> None:
        runner = FakeRunner(version="")
        result = cli_probe.load_or_probe(self.state, runner=runner, which=self.which)
        self.assertFalse(result["capable"])
        self.assertEqual(result["version"], "")
        self.assertEqual(result["versionLine"], "")

    def test_ansi_in_version_output_is_stripped(self) -> None:
        runner = FakeRunner(version=_c("1", "revenium 1.9.0 (8cf0e69)") + "\n")
        result = cli_probe.probe(runner=runner, which=self.which)
        self.assertEqual(result["versionLine"], "revenium 1.9.0 (8cf0e69)")
        self.assertTrue(result["capable"])

    def test_cache_is_reused_for_same_path_and_version(self) -> None:
        first = FakeRunner()
        cached = cli_probe.load_or_probe(self.state, runner=first, which=self.which)
        self.assertEqual(first.calls, ALLOWED_ARGV)
        cache_path = os.path.join(self.state, "cli-capability.json")
        self.assertEqual(stat.S_IMODE(os.stat(cache_path).st_mode), 0o600)
        with open(cache_path, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle), cached)

        second = FakeRunner()
        again = cli_probe.load_or_probe(self.state, runner=second, which=self.which)
        self.assertEqual(second.calls, [VERSION_ARGV])
        self.assertEqual(again, cached)

    def test_changed_version_line_reprobes(self) -> None:
        cli_probe.load_or_probe(self.state, runner=FakeRunner(), which=self.which)
        upgraded = FakeRunner(version="revenium 1.9.1 (1234567)\n")
        result = cli_probe.load_or_probe(self.state, runner=upgraded, which=self.which)
        self.assertEqual(upgraded.calls, ALLOWED_ARGV)
        self.assertEqual(result["version"], "1.9.1")

    def test_changed_cli_path_reprobes(self) -> None:
        cli_probe.load_or_probe(self.state, runner=FakeRunner(), which=self.which)
        other = os.path.join(self.bin_dir, "revenium-other")
        with open(other, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\n")
        runner = FakeRunner()
        result = cli_probe.load_or_probe(self.state, runner=runner, which=lambda name: other)
        self.assertEqual(runner.calls, ALLOWED_ARGV)
        self.assertEqual(result["cliPath"], os.path.realpath(other))

    def test_corrupt_cache_reprobes(self) -> None:
        with open(os.path.join(self.state, "cli-capability.json"), "w", encoding="utf-8") as handle:
            handle.write("{not json")
        runner = FakeRunner()
        result = cli_probe.load_or_probe(self.state, runner=runner, which=self.which)
        self.assertEqual(runner.calls, ALLOWED_ARGV)
        self.assertTrue(result["capable"])

    def test_runner_only_receives_allowed_argv(self) -> None:
        runners = [FakeRunner(), FakeRunner(version=""), FakeRunner(version="revenium 1.6.0 (x)\n")]
        for runner in runners:
            cli_probe.probe(runner=runner, which=self.which)
            cli_probe.load_or_probe(self.state, runner=runner, which=self.which)
            for argv in runner.calls:
                self.assertIn(argv, ALLOWED_ARGV)

    def test_exit_status_never_decides_capability(self) -> None:
        runner = FakeRunner()
        runner.answers[tuple(JOBS_ARGV)] = (1, _jobs_help())
        runner.answers[tuple(TYPES_ARGV)] = (2, _types_help())
        self.assertTrue(cli_probe.probe(runner=runner, which=self.which)["capable"])
        quiet = FakeRunner(jobs=_jobs_help(include_outcome_metrics=False))
        self.assertFalse(cli_probe.probe(runner=quiet, which=self.which)["capable"])


class TestRunDeliver(unittest.TestCase):
    def setUp(self) -> None:
        self.state = tempfile.mkdtemp(prefix="sidecar-deliver-")
        self.addCleanup(lambda: os.rmdir(self.state))
        self.ctx = Context(self.state, "/nonexistent", str(_REPO_ROOT), "/nonexistent",
                           str(_REPO_ROOT / "scripts" / "session-store.sh"), 10)

    def test_pre_records_probe_result(self) -> None:
        fake = {"capable": True, "version": "1.9.0"}
        with mock.patch.object(cli_probe, "load_or_probe", return_value=fake) as probe:
            counters, extra = run.run_deliver(self.ctx, "pre")
        probe.assert_called_once_with(self.state)
        self.assertEqual(counters, {})
        self.assertEqual(extra, {"cli": fake})

    def test_post_skips_probe(self) -> None:
        with mock.patch.object(cli_probe, "load_or_probe") as probe:
            self.assertEqual(run.run_deliver(self.ctx, "post"), ({}, {}))
        probe.assert_not_called()

    def test_probe_error_is_recorded_not_raised(self) -> None:
        with mock.patch.object(cli_probe, "load_or_probe", side_effect=PermissionError("secret")):
            counters, extra = run.run_deliver(self.ctx, "pre")
        self.assertEqual(extra, {"cli": {"capable": False, "error": "PermissionError"}})


if __name__ == "__main__":
    unittest.main()
