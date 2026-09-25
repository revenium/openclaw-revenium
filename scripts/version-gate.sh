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

# Same defensive fallback for warn() (Rule 2 — this file's own STUB-override
# notices, e.g. sqlite3_detected's STUB_SQLITE3_VERSION_OUTPUT warning below,
# call warn() unconditionally; without a fallback, hermetic direct-sourcing
# of this file hits an undefined-command error instead of exercising the
# STUB-override code path). Mirrors post-install.sh/post-install-nemoclaw.sh's
# own `warn()  { echo "  ⚠ $*"; }` definition exactly.
declare -F warn >/dev/null 2>&1 || warn() { echo "  ⚠ $*"; }

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

# ---------------------------------------------------------------------------
# node_version_ok VERSION — true if VERSION satisfies
# >=24.16.0 <25.0.0, or >=26.1.0 (NODE_VERSION_FLOOR_TEXT). Ported verbatim
# from spike 007 (provision-2-0-host.sh:47-63). Major 25 is EXCLUDED
# unconditionally via an explicit case arm — this is the shape a generic
# semver-range parser gets wrong (25.x is numerically above 24.16.0 but is
# not a supported major), so do not replace this with a hand-rolled range
# parser or a generic comparator.
# ---------------------------------------------------------------------------
node_version_ok() {
  local v="${1#v}"
  local major="${v%%.*}"
  case "$major" in
    24) version_ge "$v" "24.16.0" ;;
    25) return 1 ;;
    *)
      if [ "$major" -ge 26 ] 2>/dev/null; then
        version_ge "$v" "26.1.0"
      else
        return 1
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# require_node_version — fail()s (non-zero exit) unless the detected Node
# version satisfies NODE_VERSION_FLOOR_TEXT. Message always names both the
# detected and required values — never a silent no-op (GATE-04).
# ---------------------------------------------------------------------------
require_node_version() {
  local _detected

  # See openclaw_version_detected's NOTE above: warn() must go to stderr
  # here too, since this function's stdout is captured as its return value.
  if [[ -n "${STUB_NODE_VERSION:-}" ]]; then
    warn "STUB_NODE_VERSION is set — using a test override instead of the real 'node --version' output. (T-18-03)" >&2
  fi

  _detected="${STUB_NODE_VERSION:-$(node --version 2>/dev/null)}"

  if [[ -z "${_detected}" ]]; then
    fail "Could not determine the installed Node.js version.

  This skill requires Node ${NODE_VERSION_FLOOR_TEXT}, and no version was
  returned by 'node --version'. Install Node, then re-run this installer.

  See: https://nodejs.org"
  fi

  if ! node_version_ok "${_detected}"; then
    fail "Node.js version is outside the supported range.

  Detected: ${_detected}
  Required: ${NODE_VERSION_FLOOR_TEXT}

  Upgrade Node before continuing with OpenClaw — an unsupported Node version
  risks the SQLite TEXT truncation OpenClaw's own installer warns about."
  fi
}

# ---------------------------------------------------------------------------
# sqlite3_detected — echoes the dotted numeric version reported by
# `sqlite3 --version` (e.g. "3.46.1"), or from STUB_SQLITE3_VERSION_OUTPUT
# when set (hermetic test override). Echoes nothing (empty string) when
# sqlite3 is absent from PATH, exits non-zero, or produces no parseable
# leading version number.
#
# There is deliberately no version-floor check paired with this detector
# (contrast openclaw_version_detected/require_openclaw_version, which check a
# floor) — READ-04 gates on PRESENCE only. The JSON1 and json_each() functions
# scripts/session-store.sh relies on have shipped compiled-in by default
# since sqlite3 3.38, which predates every platform package this project
# supports; a version floor here would be an unverified guess (19-02-PLAN.md
# Task 2).
# ---------------------------------------------------------------------------
sqlite3_detected() {
  local _raw

  # NOTE: warn() is redirected to stderr here for the same reason it is in
  # openclaw_version_detected/require_node_version above — this function's
  # stdout IS its return value (captured via command substitution by
  # callers), so any warn() text on stdout would silently corrupt the
  # detected version string (T-19-09).
  if [[ -n "${STUB_SQLITE3_VERSION_OUTPUT:-}" ]]; then
    warn "STUB_SQLITE3_VERSION_OUTPUT is set — using a test override instead of the real 'sqlite3 --version' output. (T-19-09)" >&2
  fi

  _raw="${STUB_SQLITE3_VERSION_OUTPUT:-$(sqlite3 --version 2>/dev/null)}"
  # `sqlite3 --version` output shape is "3.46.1 2024-08-13 09:16:08 <sha> ..."
  # — the dotted numeric triple is the leading token. `|| true` guards
  # against `set -e` in the caller exactly as openclaw_version_detected's
  # equivalent line does: when extraction finds no match, grep exits
  # non-zero and (under pipefail) so does this pipeline, which would
  # otherwise trip the caller's `set -e` before require_sqlite3's own
  # `[[ -z "${_detected}" ]]` check (and its fail() call) ever runs.
  echo "${_raw}" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
}

# ---------------------------------------------------------------------------
# require_sqlite3 — fail()s (non-zero exit) unless the sqlite3 CLI is present
# on PATH. Presence is the gate; there is no minimum version (see
# sqlite3_detected's note above). The failure message always names the
# binary, the reason it is needed, and a concrete per-platform install
# command — never a silent no-op (READ-04, D-03).
# ---------------------------------------------------------------------------
require_sqlite3() {
  local _detected
  _detected="$(sqlite3_detected)"

  if [[ -z "${_detected}" ]]; then
    fail "sqlite3 (the SQLite command-line client) was not found.

  Detected: not found
  Required: sqlite3 installed and on PATH (no minimum version)

  From OpenClaw 2.0, the metering read path queries the OpenClaw agent
  session store directly via the sqlite3 CLI — without it, every metering
  tick classifies the store unreadable and meters nothing. Install it, then
  re-run this installer:

    Debian/Ubuntu: sudo apt-get install -y sqlite3
    macOS (Homebrew): brew install sqlite3"
  fi
}
