#!/usr/bin/env bash
# =============================================================================
# test_common_paths.sh — verify scripts/common.sh OPENCLAW_HOME resolution.
#
# Focus: the NemoClaw/OpenShell sandbox normalization. Inside an OpenShell
# sandbox OpenClaw sets OPENCLAW_HOME to the parent (e.g. /sandbox) with the real
# data dir at $OPENCLAW_HOME/.openclaw, whereas standalone OpenClaw points
# OPENCLAW_HOME at the .openclaw dir itself. common.sh must descend into
# .openclaw in the sandbox case so STATE_DIR / TAXONOMY_FILE / SESSIONS_DIR /
# ledgers resolve correctly, and must be a no-op for standalone.
#
# SECURITY: sources common.sh in an isolated subshell with controlled HOME /
# OPENCLAW_HOME; never evals captured output.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_SH="${REPO_ROOT}/scripts/common.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

declare -a TMP=()
cleanup() { for d in "${TMP[@]+"${TMP[@]}"}"; do rm -rf "${d}" 2>/dev/null || true; done; }
trap cleanup EXIT

if [[ ! -f "${COMMON_SH}" ]]; then
  fail "common.sh-exists: ${COMMON_SH} not found"
  echo ""; echo "Results: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Case 1: sandbox layout — OPENCLAW_HOME=<sandbox>, real data at .openclaw/
#   No <sandbox>/agents dir; <sandbox>/.openclaw/agents exists.
# ---------------------------------------------------------------------------
echo "--- Case 1: sandbox layout (OPENCLAW_HOME=parent, data in .openclaw) ---"
SBX=$(mktemp -d "${TMPDIR:-/tmp}/test-common-sbx.XXXXXX"); TMP+=("${SBX}")
mkdir -p "${SBX}/.openclaw/agents/main/sessions" "${SBX}/.openclaw/skills/revenium"

out1=$(OPENCLAW_HOME="${SBX}" HOME="${SBX}" bash -c "source '${COMMON_SH}'
echo \"OCH=\${OPENCLAW_HOME}\"
echo \"STATE=\${STATE_DIR}\"
echo \"TAX=\${TAXONOMY_FILE}\"
echo \"SESS=\${SESSIONS_DIR}\"" 2>/dev/null)

if echo "${out1}" | grep -qx "OCH=${SBX}/.openclaw"; then
  pass "Case1: OPENCLAW_HOME descends into .openclaw in sandbox"
else
  fail "Case1: OPENCLAW_HOME not normalized ($(echo "${out1}" | grep '^OCH='))"
fi
if echo "${out1}" | grep -qx "STATE=${SBX}/.openclaw/skills/revenium"; then
  pass "Case1: STATE_DIR resolves under .openclaw"
else
  fail "Case1: STATE_DIR wrong ($(echo "${out1}" | grep '^STATE='))"
fi
if echo "${out1}" | grep -qx "TAX=${SBX}/.openclaw/skills/revenium/task-taxonomy.json"; then
  pass "Case1: TAXONOMY_FILE resolves under .openclaw (the Gate D bug)"
else
  fail "Case1: TAXONOMY_FILE wrong ($(echo "${out1}" | grep '^TAX='))"
fi
if echo "${out1}" | grep -qx "SESS=${SBX}/.openclaw/agents/main/sessions"; then
  pass "Case1: SESSIONS_DIR resolves under .openclaw"
else
  fail "Case1: SESSIONS_DIR wrong ($(echo "${out1}" | grep '^SESS='))"
fi

# ---------------------------------------------------------------------------
# Case 2: standalone layout — OPENCLAW_HOME IS the .openclaw dir (has agents/).
#   Normalization must be a no-op.
# ---------------------------------------------------------------------------
echo ""
echo "--- Case 2: standalone layout (OPENCLAW_HOME is the .openclaw dir) ---"
STD=$(mktemp -d "${TMPDIR:-/tmp}/test-common-std.XXXXXX"); TMP+=("${STD}")
mkdir -p "${STD}/agents/main/sessions" "${STD}/skills/revenium"

out2=$(OPENCLAW_HOME="${STD}" HOME="${STD}" bash -c "source '${COMMON_SH}'
echo \"OCH=\${OPENCLAW_HOME}\"" 2>/dev/null)

if echo "${out2}" | grep -qx "OCH=${STD}"; then
  pass "Case2: OPENCLAW_HOME unchanged for standalone (no-op normalization)"
else
  fail "Case2: OPENCLAW_HOME wrongly modified for standalone ($(echo "${out2}" | grep '^OCH='))"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
