#!/usr/bin/env bash
# =============================================================================
# version-gate.sh — Runtime version floor checks (GATE-01/GATE-02/GATE-04).
#
# SOURCED (not executed). Sourced by scripts/install.sh, scripts/post-install.sh,
# and scripts/post-install-nemoclaw.sh. Callers MUST define fail() (the
# one-line `fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }` convention used
# throughout the install-family scripts) BEFORE sourcing this file. A
# defensive fallback is provided below for direct/hermetic sourcing (e.g. this
# file's own unit tests), but production callers should rely on their own
# fail() definition, not this fallback.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/version-gate.sh"
#   require_openclaw_version
#   require_node_version
# =============================================================================
# NOTE: No `set -e` here — this is a sourced library. Callers that set -e will
# keep it. Adding -e here would cause unexpected exits in the caller's context
# on any sub-expression that evaluates to non-zero (mirrors scripts/common.sh).
set -uo pipefail

# Defensive fallback: only used when sourced without a caller-defined fail()
# (e.g. this file's own hermetic unit tests). Production callers (install.sh,
# post-install.sh, post-install-nemoclaw.sh) already define fail() before the
# source line, so this never overrides their behavior.
declare -F fail >/dev/null 2>&1 || fail() { echo ""; echo "  ✗ $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Version floors
# ---------------------------------------------------------------------------
OPENCLAW_VERSION_FLOOR="2026.8.1"
NODE_VERSION_FLOOR_TEXT=">=24.16.0 <25.0.0, or >=26.1.0"

# ---------------------------------------------------------------------------
# version_ge DETECTED REQUIRED — returns 0 if DETECTED >= REQUIRED.
#
# Numeric CalVer-aware comparison via `sort -C -V` — NEVER a string-prefix
# test (see 18-RESEARCH.md Pitfall 1: "2026.8.9" vs "2026.8.10" sorts
# backwards under ASCII-lexical/prefix comparison since '9' > '1').
#
# CRITICAL: the argument order fed into `sort -C -V` is (required, detected)
# — REQUIRED emitted FIRST, DETECTED emitted SECOND. `sort -C` verifies the
# input is already sorted ascending, so this is true exactly when
# required <= detected. Inverting this order (detected first, as in
# .planning/research/ARCHITECTURE.md §7's snippet) silently passes the gate
# when the version is OLDER than required — the exact opposite of the
# intended check. Ported verbatim from spike 007
# (.planning/spikes/007-live-2-0-host-provisioning/provision-2-0-host.sh:40-45),
# which is live-tested against this exact adversarial case.
# ---------------------------------------------------------------------------
version_ge() {
  local detected="$1" required="$2"
  [ "$detected" = "$required" ] && return 0
  printf '%s\n%s\n' "$required" "$detected" | sort -C -V
}

# ---------------------------------------------------------------------------
# openclaw_version_detected — echoes the numeric dotted triple (e.g.
# "2026.9.6") detected from `openclaw --version`, or from
# STUB_OPENCLAW_VERSION_OUTPUT when set (hermetic test override). The live
# output shape is "OpenClaw 2026.9.6 (eb377ac)" — extraction with
# grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' stops at the numeric triple and ignores
# the trailing git-sha parenthetical. Echoes nothing (empty string) when
# extraction yields nothing (absent binary, non-zero exit, or empty output).
# ---------------------------------------------------------------------------
openclaw_version_detected() {
  local _raw

  # NOTE: the warn() call is explicitly redirected to stderr (>&2) here even
  # though warn() itself writes to stdout by convention — this function's
  # stdout IS its return value (captured via command substitution by
  # callers), so any warn() text on stdout would silently corrupt the
  # detected version string. Without this redirect, the warning text gets
  # captured alongside (or instead of) the real version, which is exactly
  # the "override bypasses the gate silently" failure mode T-18-03 exists to
  # prevent.
  if [[ -n "${STUB_OPENCLAW_VERSION_OUTPUT:-}" ]]; then
    warn "STUB_OPENCLAW_VERSION_OUTPUT is set — using a test override instead of the real 'openclaw --version' output. (T-18-03)" >&2
  fi

  _raw="${STUB_OPENCLAW_VERSION_OUTPUT:-$(openclaw --version 2>/dev/null | head -1)}"
  # `|| true` guards against `set -e` in the caller: when extraction finds no
  # match, grep exits non-zero and (under pipefail) so does this pipeline —
  # which, as the last command of a function whose result is captured via
  # `x="$(openclaw_version_detected)"`, would otherwise trip the caller's
  # `set -e` and exit the whole script BEFORE require_openclaw_version's own
  # `[[ -z "${_detected}" ]]` check (and its fail() call) ever runs. Echoing
  # nothing and forcing exit 0 here is correct — the empty-string case IS the
  # documented behavior; require_openclaw_version is what actually fails it.
  echo "${_raw}" | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1 || true
}

# ---------------------------------------------------------------------------
# require_openclaw_version — fail()s (non-zero exit) unless the detected
# OpenClaw version is >= OPENCLAW_VERSION_FLOOR. The failure message always
# names both the detected and required values — never a silent no-op
# (GATE-01).
# ---------------------------------------------------------------------------
require_openclaw_version() {
  local _detected
  _detected="$(openclaw_version_detected)"

  if [[ -z "${_detected}" ]]; then
    fail "Could not determine the installed OpenClaw version.

  This skill requires OpenClaw ${OPENCLAW_VERSION_FLOOR} or later, and no
  parseable version was returned by 'openclaw --version'. Install or upgrade
  OpenClaw, then re-run this installer.

  See: https://docs.openclaw.ai"
  fi

  if ! version_ge "${_detected}" "${OPENCLAW_VERSION_FLOOR}"; then
    fail "OpenClaw version is below the required floor.

  Detected: ${_detected}
  Required: ${OPENCLAW_VERSION_FLOOR} or later

  Upgrade OpenClaw before continuing. See: https://docs.openclaw.ai/releases"
  fi
}
