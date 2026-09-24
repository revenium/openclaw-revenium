---
phase: 13-sandbox-provisioning-egress-cli-authenticated-metering
reviewed: 2026-06-08T00:00:00Z
depth: standard
files_reviewed: 5
files_reviewed_list:
  - scripts/post-install-nemoclaw.sh
  - scripts/revenium-policy.yaml
  - scripts/gh-release-policy.yaml
  - tests/stub-nemoclaw.sh
  - tests/test_nemoclaw_provisioning.sh
findings:
  critical: 1
  warning: 3
  info: 2
  total: 6
status: resolved
resolution: "CR-01, WR-01, WR-02, WR-03, IN-01 fixed in commit (egress exit-code detection, stub 000 exit, YAML-quoted creds, honest idempotent banner, anchored ledger asserts). IN-02 (stub tmpfile trap) accepted as test-only/low. Suite 18/18; dispatcher 10/10."
---

# Phase 13: Code Review Report

> **Resolution (2026-06-08):** CR-01 (proxy-block detection false-negative), WR-01
> (stub false-green for the 000 path), WR-02 (YAML-quote credential values), WR-03
> (idempotent-re-run banner), and IN-01 (anchored ledger-key asserts + cli-delivered
> value check) are fixed and regression-guarded. GROUP-A now genuinely exercises the
> egress exit-code path. IN-02 (stub `_payload_file` trap) accepted as test-only, low
> severity. Hermetic suite 18/18; dispatcher 10/10.

**Reviewed:** 2026-06-08
**Depth:** standard
**Files Reviewed:** 5
**Status:** issues_found

## Summary

Reviewed the full Phase 13 delivery: the `post-install-nemoclaw.sh` provisioning script,
two egress preset YAMLs, the argv-capturing nemoclaw stub, and the GROUP A–H hermetic test
harness. The credential-write base64 approach correctly addresses the live-smoke newline-argv
finding; the `api-key:` field name is used and regression-guarded by GROUP-H; the meter
success-shape classifier matches the live resource shape. These three already-fixed findings
are not re-raised.

One critical bug was found: the proxy-block detection logic in `provision_egress_policy` will
silently pass in production when the egress probe is actually blocked, because `curl` writes
`000` to stdout and then exits non-zero, causing the `|| echo "000"` fallback to append a
second `000`. The `[[ == "000" ]]` comparison against `"000000"` is false — the proxy block
goes undetected. The hermetic stub masks this because it exits 0 for all exec dispatches,
making GROUP-A a false-green against the production failure mode.

Three warnings cover: the stub's exit-0-on-proxy-block that creates the false-green, unvalidated
operator-supplied YAML values that could silently malform config.yaml, and a misleading success
banner on idempotent re-runs.

---

## Critical Issues

### CR-01: `provision_egress_policy` proxy-block detection fails in production due to double-"000" emission

**File:** `scripts/post-install-nemoclaw.sh:119-123`

**Issue:** When the in-sandbox `curl` probe fails with a CONNECT-tunnel error (proxy block), curl
writes `000` to stdout *and* exits non-zero (e.g., exit 7 for connection refused, exit 56 for
CONNECT tunnel failure). Because `nemoclaw exec` propagates the in-sandbox exit code, the outer
command substitution becomes:

```
http_code=$(nemoclaw ... exec -- sh -lc 'curl ... -w "%{http_code}" ...' 2>/dev/null || echo "000")
```

The `|| echo "000"` fallback fires after curl has already written `000` to the subshell stdout.
The result is `http_code="000000"` (or `"000\n000"` with an internal newline, depending on shell).
Either way `[[ "${http_code}" == "000" ]]` is false, the proxy block is not detected, and the
script incorrectly reports "Egress confirmed" and proceeds to ledger-write `revenium-policy-applied=1`,
permanently skipping the egress check on every subsequent run.

Verified locally:
```
$ http_code=$(curl -sS -o /dev/null -w "%{http_code}" http://localhost:19999/ 2>/dev/null || echo "000")
$ echo "[${http_code}]"
[000000]
```

The GROUP-A hermetic test does **not** catch this because the stub exits 0 even when
`STUB_NEMOCLAW_CURL_HTTP_CODE=000` (see WR-01), so GROUP-A is a false-green against the
production failure mode.

**Fix:** Separate the exit-code capture from the output capture so the `|| echo "000"` fallback
only fires when `nemoclaw` itself fails without producing any output:

```bash
local http_code exec_rc=0
http_code=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    'curl -sS -o /dev/null -w "%{http_code}" https://api.revenium.ai/ 2>/dev/null' \
    2>/dev/null) || exec_rc=$?

# Treat a non-zero exec exit code OR an empty/000 http_code as a proxy block.
if [[ "${exec_rc}" -ne 0 ]] || [[ "${http_code}" == "000" ]] || [[ -z "${http_code}" ]]; then
    fail "sandbox cannot reach api.revenium.ai — policy gap detected. Apply the revenium egress preset: nemoclaw ${SANDBOX_NAME} policy-list"
fi
```

The companion fix in the stub (WR-01) is also required to make GROUP-A test the correct failure
mode.

---

## Warnings

### WR-01: Stub exits 0 for proxy-block dispatch — GROUP-A is a false-green

**File:** `tests/stub-nemoclaw.sh:102-106`

**Issue:** The http-code dispatch branch always exits 0 regardless of the value of
`STUB_NEMOCLAW_CURL_HTTP_CODE`:

```bash
if grep -qF "http_code" "${_payload_file}" && grep -qF "api.revenium.ai" "${_payload_file}"; then
  rm -f "${_payload_file}"
  echo "${STUB_NEMOCLAW_CURL_HTTP_CODE:-403}"
  exit 0          # <-- always 0, even when CURL_HTTP_CODE=000
fi
```

In production, when the proxy blocks the egress, `nemoclaw exec` exits non-zero. GROUP-A sets
`STUB_NEMOCLAW_CURL_HTTP_CODE=000` to simulate this, but the stub still exits 0. The provisioning
script therefore receives `http_code="000"` cleanly and the `[[ == "000" ]]` check passes — but
only because the stub is unrealistically cooperative. Once CR-01 is fixed with the separate
exit-code capture, the stub will also need to exit non-zero when simulating a proxy block:

```bash
if grep -qF "http_code" "${_payload_file}" && grep -qF "api.revenium.ai" "${_payload_file}"; then
  rm -f "${_payload_file}"
  local code="${STUB_NEMOCLAW_CURL_HTTP_CODE:-403}"
  echo "${code}"
  # Proxy block: curl exits non-zero and nemoclaw propagates that exit code.
  if [[ "${code}" == "000" ]]; then
    exit 7    # simulate curl "connection refused" (or exit 56 for CONNECT tunnel failure)
  fi
  exit 0
fi
```

Without this companion fix, GROUP-A will remain a false-green even after CR-01 is applied.

### WR-02: Operator-supplied credential values not validated for YAML-breaking characters

**File:** `scripts/post-install-nemoclaw.sh:211-217`

**Issue:** `config_content` is assembled by direct string interpolation of operator-supplied env
vars into bare YAML values:

```bash
config_content="api-key: ${REVENIUM_API_KEY}"
[[ -n "${REVENIUM_TEAM_ID:-}" ]] && config_content="${config_content}
team-id: ${REVENIUM_TEAM_ID}"
```

If any of `REVENIUM_API_KEY`, `REVENIUM_TEAM_ID`, `REVENIUM_TENANT_ID`, or `REVENIUM_OWNER_ID`
contains a YAML-breaking sequence — specifically colon-space (`: `) or space-hash (` #`) —
the resulting `config.yaml` will be silently malformed:

- A value like `abc: xyz` produces `api-key: abc: xyz` which YAML parses as a nested mapping,
  not a scalar. The CLI would fail to read the API key with no clear error.
- A value like `abc #xyz` produces `api-key: abc #xyz` which YAML parses as `api-key: abc`
  (the `#xyz` is treated as a comment). The CLI silently receives a truncated key.

The base64 encoding fully prevents shell injection and in-sandbox expansion (T-13-INJ correctly
mitigated), but YAML-layer integrity of the values is unguarded. The values never pass through an
in-sandbox shell, but they DO land in a YAML file that the CLI parses.

**Fix:** Validate each credential value before building `config_content`:

```bash
_validate_yaml_scalar() {
    local name="$1" val="$2"
    # Reject colon-space (YAML mapping ambiguity) and space-hash (YAML comment start)
    if [[ "${val}" =~ :[[:space:]] ]] || [[ "${val}" =~ [[:space:]]'#' ]]; then
        fail "${name} contains YAML-unsafe characters (': ' or ' #') — cannot write config.yaml safely"
    fi
}
_validate_yaml_scalar "REVENIUM_API_KEY"    "${REVENIUM_API_KEY}"
[[ -n "${REVENIUM_TEAM_ID:-}" ]]   && _validate_yaml_scalar "REVENIUM_TEAM_ID"   "${REVENIUM_TEAM_ID}"
[[ -n "${REVENIUM_TENANT_ID:-}" ]] && _validate_yaml_scalar "REVENIUM_TENANT_ID" "${REVENIUM_TENANT_ID}"
[[ -n "${REVENIUM_OWNER_ID:-}" ]]  && _validate_yaml_scalar "REVENIUM_OWNER_ID"  "${REVENIUM_OWNER_ID}"
```

Alternatively, quote all values in the YAML (`api-key: "..."`) and escape inner `"` characters.

### WR-03: Success banner always reports "Delivered" and "Probe" even when both steps were skipped

**File:** `scripts/post-install-nemoclaw.sh:331-343`

**Issue:** The final banner unconditionally prints:

```
  Delivered: revenium CLI v1.2.0
  Config:    /sandbox/.config/revenium/config.yaml
  Probe:     meter-probe-passed
```

On a re-run where the ledger already contains all five keys, every provisioning function skips
immediately and logs "skipping" — but the banner still claims `Delivered` and `Probe` as if those
actions just completed. An operator re-running after a failure might misread the banner and assume
the config was freshly written with the current `REVENIUM_API_KEY`, when in fact `write_revenium_creds`
was skipped and the old credentials remain.

**Fix:** Track whether each phase-13 step actually ran (versus was skipped) and adjust the banner
text, or add a "(idempotent re-run — all steps already complete)" note to the banner when the
ledger already contained all five keys at start-of-run:

```bash
# Before provisioning, snapshot whether all keys were already present
_already_provisioned=0
if ledger_has "revenium-policy-applied" && ledger_has "gh-release-policy-applied" && \
   ledger_has "cli-delivered" && ledger_has "creds-written" && ledger_has "meter-probe-passed"; then
    _already_provisioned=1
fi
```

Then in the banner:
```bash
if [[ "${_already_provisioned}" -eq 1 ]]; then
    echo "  (All steps already complete — ledger verified, no actions taken)"
fi
```

---

## Info

### IN-01: GROUP-G asserts ledger key presence but not key value correctness

**File:** `tests/test_nemoclaw_provisioning.sh:328-334`

**Issue:** The GROUP-G assertion iterates the five expected ledger keys and checks only that each
key string appears in the ledger file:

```bash
for key in revenium-policy-applied gh-release-policy-applied cli-delivered creds-written meter-probe-passed; do
  if [[ -f "${LEDGER_G}" ]] && grep -qF "${key}" "${LEDGER_G}" 2>/dev/null; then
```

`grep -qF "${key}"` matches even if the ledger contains `old-cli-delivered=wrong-value` (because
`cli-delivered` is a substring). More importantly, the `cli-delivered` value encodes both version
and tarball sha256 (`v1.2.0:cc4b07...`), and a version bump that writes the wrong sha256 to the
ledger would pass this test. A tighter assertion would verify the exact `key=value` format:

```bash
grep -qF "^${key}=" "${LEDGER_G}"   # anchored to start of line, exact key match
```

And for `cli-delivered` specifically, also assert the version:sha256 format is present:

```bash
grep -qF "cli-delivered=v1.2.0:" "${LEDGER_G}"
```

### IN-02: Stub's `_payload_file` tmpfile can leak if the process is sent SIGKILL or `set -uo pipefail` exits unexpectedly inside the exec block

**File:** `tests/stub-nemoclaw.sh:95-143`

**Issue:** The `_payload_file=$(mktemp)` temporary file is created inside the `exec` dispatch
block and cleaned up explicitly before each `exit 0/2`. There is no `trap` to handle unexpected
exits (signal or unhandled error under `set -uo pipefail`). In a long-running CI run where the
stub is invoked hundreds of times, leaked tmpfiles accumulate in `/tmp`. In practice the harness
cleanup trap removes the whole `TMP_HOME` tree, but `_payload_file` is created in the system
`/tmp`, not under `TMP_HOME`.

**Fix:** Add a local cleanup trap at the top of the `exec` dispatch block:

```bash
if [[ "${2:-}" == "exec" ]]; then
  _payload_file=$(mktemp)
  trap 'rm -f "${_payload_file}"' EXIT   # clean up on any exit path
  ...
fi
```

This is test-only code with low production impact but is a clean-code improvement.

---

_Reviewed: 2026-06-08_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
