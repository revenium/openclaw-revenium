"""Tests for the fail-closed redaction and head/tail clamp.

Every planted secret is assembled from pieces at runtime, so no complete
key-shaped string is committed to the repository.

TestRegexPass plants one secret per kind inside prose and checks that it
becomes ``[REDACTED:<kind>]`` with no 8-character fragment left, and that an
assignment keeps its name and separator.

TestKnownValues covers load_known_values (revenium.env, config.yaml
``api-key:``, a model.key file, short values ignored, unreadable files
skipped, longest first) and the exact-value pass for a value no regex
matches.

TestSanitize covers the order (pre-cap, redact, clamp): a secret straddling
the 1,000-character clamp boundary, the empty and exact-length edge cases,
code-point safety next to CJK and emoji, the fail-closed ``[turn omitted]``
result, and that the module writes nothing to stdout or stderr.

TestAdversarialInputs times sanitize_turn on 1 MiB inputs built to make
regexes backtrack; each must finish in under 2 seconds.
"""
from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SIDECAR_DIR = _REPO_ROOT / "sidecar"
if str(_SIDECAR_DIR) not in sys.path:
    sys.path.insert(0, str(_SIDECAR_DIR))

from openclaw_economics import redact  # noqa: E402

KNOWN = "host-known-value-" + "9f8e7d6c"

# kind -> (planted text, the secret material that must not survive)
SECRETS = {
    "anthropic": ("sk-ant-" + "api03-" + "Ab1" * 14,) * 2,
    "openai": ("sk-" + "proj-" + "Zq9" * 10,) * 2,
    "revenium": ("rev_sk" + "_live_" + "x7Y" * 6,) * 2,
    "aws": ("AKIA" + "ABCDEFGH" + "IJKLMNOP",) * 2,
    "github": ("ghp_" + "a1" * 18,) * 2,
    "github-pat": ("github_pat_" + "11ABC" * 5,) * 2,
    "slack": ("xoxb-" + "1234567890" + "-abcdefghij",) * 2,
    "google": ("AIza" + "Sy" + "C3d" * 11,) * 2,
    "jwt": ("eyJ" + "hbGciOiJIUzI1NiJ9" + "." + "eyJzdWIiOiIxMjM0In0" + "." + "c2lnbmF0dXJlLXZhbHVl",) * 2,
    "bearer": ("Bearer " + "tok-" + "9f8e7d6c5b4a3210", "tok-" + "9f8e7d6c5b4a3210"),
    "pem": (
        "-----BEGIN RSA " + "PRIVATE KEY-----\nMIIBOgIBAAJBAK" + "q7" * 20 + "\n-----END RSA " + "PRIVATE KEY-----",
    ) * 2,
    "url-credentials": (
        "https://" + "alice" + ":" + "Pw-" + "s3cr3tval9" + "@db.example.com/x",
        "alice" + ":" + "Pw-" + "s3cr3tval9",
    ),
    "assignment": ("DB_PASSWORD = " + '"' + "hunter2-" + "hunter2" + '"', "hunter2-" + "hunter2"),
}


def fragments(secret: str, size: int = 8):
    return {secret[i:i + size] for i in range(max(1, len(secret) - size + 1))}


class TestRegexPass(unittest.TestCase):
    def assertNoFragment(self, secret: str, output: str) -> None:
        for frag in fragments(secret):
            self.assertNotIn(frag, output, f"fragment {frag!r} survived")

    def test_each_kind_is_redacted_inside_prose(self) -> None:
        for kind, (planted, material) in SECRETS.items():
            with self.subTest(kind=kind):
                text = f"Please review this config: {planted} before Friday."
                out = redact.redact(text, ())
                self.assertIn(f"[REDACTED:{kind}]", out)
                self.assertNoFragment(material, out)
                self.assertTrue(out.startswith("Please review this config: "))
                self.assertTrue(out.endswith(" before Friday."))

    def test_unterminated_pem_is_redacted_to_end_of_text(self) -> None:
        header = "-----BEGIN OPENSSH " + "PRIVATE KEY-----\n"
        body = "b3BlbnNzaC1rZXktdjEAAAAA" * 3
        out = redact.redact("Here is my key:\n" + header + body, ())
        self.assertEqual(out, "Here is my key:\n[REDACTED:pem-unterminated]")

    def test_assignment_keeps_name_and_separator(self) -> None:
        planted, _material = SECRETS["assignment"]
        out = redact.redact(f"set {planted} in the env", ())
        self.assertEqual(out, "set DB_PASSWORD = [REDACTED:assignment] in the env")
        out = redact.redact("api_key=" + "plainvalue123" + ";", ())
        self.assertEqual(out, "api_key=[REDACTED:assignment];")

    def test_plain_prose_is_unchanged(self) -> None:
        text = "The quick brown fox reviewed the quarterly report at https://example.com/a."
        self.assertEqual(redact.redact(text, ()), text)


class TestKnownValues(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.mkdtemp(prefix="sidecar-redact-")
        self.addCleanup(self._cleanup)

    def _cleanup(self) -> None:
        for name in os.listdir(self.dir):
            path = os.path.join(self.dir, name)
            if os.path.isdir(path):
                os.rmdir(path)
            else:
                os.unlink(path)
        os.rmdir(self.dir)

    def _write(self, name: str, content: str) -> str:
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        return path

    def _check_redacts_known(self, values) -> None:
        self.assertIn(KNOWN, values)
        text = f"the value {KNOWN} appears here"
        self.assertEqual(redact.redact(text, values), "the value [REDACTED:known] appears here")

    def test_value_from_env_file(self) -> None:
        env = self._write("revenium.env", f'# comment\nexport REVENIUM_X="{KNOWN}"\nSHORT=abc\n\n')
        values = redact.load_known_values(env_files=(env,))
        self._check_redacts_known(values)
        self.assertNotIn("abc", values)

    def test_value_from_config_yaml_api_key(self) -> None:
        cfg = self._write("config.yaml", f"team-id: t1\napi-key: '{KNOWN}'\n")
        values = redact.load_known_values(config_yaml=cfg)
        self._check_redacts_known(values)
        self.assertNotIn("t1", values)

    def test_value_from_key_file(self) -> None:
        key = self._write("model.key", f"{KNOWN}\n")
        self._check_redacts_known(redact.load_known_values(key_files=(key,)))

    def test_short_values_are_ignored(self) -> None:
        env = self._write("revenium.env", "A=1234567\nB=12345678\n")
        self.assertEqual(redact.load_known_values(env_files=(env,)), ("12345678",))

    def test_unreadable_files_are_skipped(self) -> None:
        missing = os.path.join(self.dir, "missing.env")
        a_dir = os.path.join(self.dir, "subdir")
        os.mkdir(a_dir)
        key = self._write("model.key", KNOWN)
        values = redact.load_known_values(
            config_yaml=missing, env_files=(missing, a_dir), key_files=(a_dir, key)
        )
        self.assertEqual(values, (KNOWN,))

    def test_longest_value_is_replaced_first(self) -> None:
        inner = "known-value-" + "9f8e"
        env = self._write("revenium.env", f"INNER={inner}\nOUTER={KNOWN}\nDUP={KNOWN}\n")
        values = redact.load_known_values(env_files=(env,))
        self.assertEqual(values, (KNOWN, inner))
        self.assertEqual(redact.redact(f"x {KNOWN} y {inner} z", values),
                         "x [REDACTED:known] y [REDACTED:known] z")

    def test_regex_pass_runs_before_exact_value_pass(self) -> None:
        planted, _ = SECRETS["revenium"]
        out = redact.redact(f"key {planted} end", (planted,))
        self.assertEqual(out, "key [REDACTED:revenium] end")


class TestSanitize(unittest.TestCase):
    def test_secret_straddling_clamp_boundary_leaves_no_fragment(self) -> None:
        planted, material = SECRETS["anthropic"]
        start = 990
        text = "a" * start + planted
        text += "b" * (5000 - len(text))
        self.assertEqual(len(text), 5000)
        out, omitted = redact.sanitize_turn(text, ())
        self.assertFalse(omitted)
        for frag in fragments(material):
            self.assertNotIn(frag, out)

    def test_known_value_straddling_clamp_boundary_leaves_no_fragment(self) -> None:
        text = "c" * 995 + KNOWN + "d" * 4000
        out, _ = redact.sanitize_turn(text, (KNOWN,))
        for frag in fragments(KNOWN):
            self.assertNotIn(frag, out)

    def test_empty_text(self) -> None:
        self.assertEqual(redact.sanitize_turn("", ()), ("", False))

    def test_exact_limit_is_unchanged(self) -> None:
        text = "x" * 2100
        self.assertEqual(redact.sanitize_turn(text, ()), (text, False))

    def test_one_over_limit_is_clamped(self) -> None:
        text = "h" * 1000 + "m" * 101 + "t" * 1000
        out, omitted = redact.sanitize_turn(text, ())
        self.assertFalse(omitted)
        self.assertEqual(out, "h" * 1000 + "\n[… 101 chars elided …]\n" + "t" * 1000)

    def test_secret_next_to_cjk_and_emoji_is_redacted(self) -> None:
        planted, material = SECRETS["github"]
        out, _ = redact.sanitize_turn("密钥是" + planted + "🔑🙂", ())
        self.assertEqual(out, "密钥是[REDACTED:github]🔑🙂")
        planted, material = SECRETS["openai"]
        out, _ = redact.sanitize_turn("鍵🔑 " + planted + " 終わり", ())
        self.assertNotIn(material, out)
        self.assertIn("[REDACTED:openai]", out)

    def test_clamping_emoji_keeps_whole_code_points(self) -> None:
        out, omitted = redact.sanitize_turn("😀" * 3000, ())
        self.assertFalse(omitted)
        self.assertIsInstance(out, str)
        out.encode("utf-8")
        self.assertTrue(out.startswith("😀" * 1000 + "\n[… 1000 chars elided …]\n"))
        self.assertTrue(out.endswith("😀" * 1000))

    def test_lone_surrogate_output_still_encodes(self) -> None:
        out, _ = redact.sanitize_turn("broken \ud800 text", ())
        out.encode("utf-8")

    def test_precap_drops_middle_before_redaction(self) -> None:
        text = "p" * 30000 + "MIDDLE-MARKER" + "q" * 40000
        capped = redact.precap(text)
        self.assertNotIn("MIDDLE-MARKER", capped)
        self.assertTrue(capped.startswith("p" * 16384 + "\n[… "))
        self.assertIn(" chars elided before redaction …]\n", capped)
        self.assertTrue(capped.endswith("q" * 16384))
        exact = "z" * 65536
        self.assertEqual(redact.precap(exact), exact)

    def test_raising_pattern_omits_the_turn(self) -> None:
        class Boom:
            def sub(self, *args, **kwargs):
                raise RuntimeError("would leak " + KNOWN)

        with mock.patch.object(redact, "PATTERNS", (("boom", Boom()),)):
            self.assertEqual(redact.sanitize_turn("hello " + KNOWN, ()), ("[turn omitted]", True))

    def test_non_string_input_omits_the_turn(self) -> None:
        self.assertEqual(redact.sanitize_turn(None, ()), (redact.OMITTED, True))

    def test_module_is_silent(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            redact.sanitize_turn("x " + SECRETS["aws"][0] + " " * 3000, (KNOWN,))
            redact.sanitize_turn(None, ())
            redact.load_known_values(config_yaml="/nonexistent/config.yaml",
                                     env_files=("/nonexistent/revenium.env",))
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(err.getvalue(), "")


class TestAdversarialInputs(unittest.TestCase):
    MIB = 1 << 20

    def assertFast(self, text: str) -> None:
        began = time.monotonic()
        out, omitted = redact.sanitize_turn(text, (KNOWN,))
        elapsed = time.monotonic() - began
        self.assertLess(elapsed, 2.0)
        self.assertFalse(omitted)
        self.assertLessEqual(len(out), 2200)

    def test_sk_prefix_followed_by_dashes(self) -> None:
        self.assertFast("sk-" + "-" * self.MIB)

    def test_unterminated_pem_with_base64_body(self) -> None:
        self.assertFast("-----BEGIN RSA " + "PRIVATE KEY-----\n" + "QUJD" * (self.MIB // 4))

    def test_repeated_bearer(self) -> None:
        self.assertFast("bearer " * (self.MIB // 7))

    def test_repeated_assignment_separator(self) -> None:
        self.assertFast("a=" * (self.MIB // 2))

    def test_repeated_jwt_prefix(self) -> None:
        self.assertFast("eyJ" * (self.MIB // 3))

    def test_hyphenated_name_run(self) -> None:
        self.assertFast("a-" * (self.MIB // 2))

    def test_many_pem_headers(self) -> None:
        self.assertFast(("-----BEGIN RSA " + "PRIVATE KEY-----\n") * (self.MIB // 32))


if __name__ == "__main__":
    unittest.main()
