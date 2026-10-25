#!/usr/bin/env bash
# =============================================================================
# test_vendored_wheel.sh — Hermetic integrity suite for the vendored library
# wheel under sidecar/vendor/.
#
# Checks that the committed wheel bytes, the hash in sidecar/requirements.lock
# and the wheel_sha256 line in sidecar/vendor/SOURCE all agree, and that the
# provenance record names the pinned library commit. Tamper cases prove the
# agreement check fails when any one of them drifts.
#
# Usage:
#   bash tests/test_vendored_wheel.sh
#
# Never calls a package installer or the network: CI checks the committed
# wheel against its pins rather than rebuilding it, because a later rebuild
# can resolve a newer build backend and change the hash.
#
# SECURITY: the provenance record is parsed line by line and never executed.
#   Captured values are compared as fixed strings and are never evaluated or
#   interpolated into a command.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIDECAR_DIR="${REPO_ROOT}/sidecar"

EXPECTED_COMMIT_PREFIX="5c7fba3"
EXPECTED_CONFORMANCE="24 scenarios, 0 failing"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Cleanup: track all tmp dirs globally and clean up on exit.
# ---------------------------------------------------------------------------
declare -a TMP_HOMES=()

cleanup() {
  for d in "${TMP_HOMES[@]+"${TMP_HOMES[@]}"}"; do
    rm -rf "${d}" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# _wheel_sha <file> — print the file's sha256 hex digest.
# ---------------------------------------------------------------------------
_wheel_sha() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  else
    shasum -a 256 "${file}" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# _source_value <source_file> <key> — print the value of the first `key=` line.
# Prints nothing when the key is absent.
# ---------------------------------------------------------------------------
_source_value() {
  local file="$1" key="$2" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      "${key}="*)
        printf '%s\n' "${line#"${key}="}"
        return 0
        ;;
    esac
  done < "${file}"
  return 0
}

# ---------------------------------------------------------------------------
# _check_wheel_agreement <sidecar_dir> — return 0 only when the vendored wheel,
# the lock line and the provenance record agree. Prints the reason on failure.
# ---------------------------------------------------------------------------
_check_wheel_agreement() {
  local dir="$1"
  local lock="${dir}/requirements.lock"
  local src="${dir}/vendor/SOURCE"
  local wheel_count=0 wheel_path="" f

  for f in "${dir}"/vendor/*.whl; do
    [[ -f "${f}" ]] || continue
    wheel_count=$((wheel_count + 1))
    wheel_path="${f}"
  done
  if [[ "${wheel_count}" -ne 1 ]]; then
    echo "  expected exactly one wheel in ${dir}/vendor, found ${wheel_count}"
    return 1
  fi
  local wheel_name
  wheel_name="$(basename "${wheel_path}")"

  if [[ ! -f "${lock}" ]]; then
    echo "  lock file missing"
    return 1
  fi
  local lock_lines=0 lock_line="" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lock_lines=$((lock_lines + 1))
    lock_line="${line}"
  done < "${lock}"
  if [[ "${lock_lines}" -ne 1 ]]; then
    echo "  lock file must hold exactly one line, found ${lock_lines}"
    return 1
  fi
  if ! printf '%s\n' "${lock_line}" \
      | grep -Eq '^\./vendor/[A-Za-z0-9_.-]+\.whl --hash=sha256:[0-9a-f]{64}$'; then
    echo "  lock line has the wrong shape"
    return 1
  fi
  local lock_path="${lock_line%% *}"
  local lock_name="${lock_path#./vendor/}"
  local lock_hash="${lock_line##*--hash=sha256:}"

  if [[ "${lock_name}" != "${wheel_name}" ]]; then
    echo "  lock names ${lock_name}, vendor holds ${wheel_name}"
    return 1
  fi

  local digest
  digest="$(_wheel_sha "${wheel_path}")"
  if [[ "${digest}" != "${lock_hash}" ]]; then
    echo "  wheel digest ${digest} does not match lock hash ${lock_hash}"
    return 1
  fi

  if [[ ! -f "${src}" ]]; then
    echo "  provenance record missing"
    return 1
  fi
  local src_sha src_wheel
  src_sha="$(_source_value "${src}" wheel_sha256)"
  src_wheel="$(_source_value "${src}" wheel)"
  if [[ "${src_sha}" != "${digest}" ]]; then
    echo "  provenance wheel_sha256 ${src_sha} does not match wheel digest ${digest}"
    return 1
  fi
  if [[ "${src_wheel}" != "${wheel_name}" ]]; then
    echo "  provenance wheel ${src_wheel} does not match ${wheel_name}"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _copy_sidecar — copy the committed sidecar/ into a fresh temp dir and print
# the copy's path.
# ---------------------------------------------------------------------------
_copy_sidecar() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/vw-test.XXXXXX")"
  cp -R "${SIDECAR_DIR}" "${tmp}/sidecar"
  printf '%s\n' "${tmp}"
}

SOURCE_FILE="${SIDECAR_DIR}/vendor/SOURCE"

if [[ ! -f "${SOURCE_FILE}" || ! -f "${SIDECAR_DIR}/requirements.lock" ]]; then
  echo ""
  echo "=== VENDORED WHEEL PINS MISSING ==="
  fail "vendored-wheel-pins-exist: ${SIDECAR_DIR}/requirements.lock or vendor/SOURCE not found"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

# ===========================================================================
# GROUP VW-A: committed wheel, lock and provenance record agree.
# ===========================================================================
echo ""
echo "--- GROUP VW-A: committed wheel/lock/SOURCE agreement ---"
if _check_wheel_agreement "${SIDECAR_DIR}"; then
  pass "VW-A: committed wheel digest matches the lock hash and SOURCE wheel_sha256"
else
  fail "VW-A: committed wheel, lock and SOURCE disagree"
fi

# ===========================================================================
# GROUP VW-B: provenance names the pinned library commit.
# ===========================================================================
echo ""
echo "--- GROUP VW-B: pinned library commit ---"
commit_b="$(_source_value "${SOURCE_FILE}" commit)"
if printf '%s\n' "${commit_b}" | grep -Eqx '[0-9a-f]{40}' \
    && [[ "${commit_b:0:${#EXPECTED_COMMIT_PREFIX}}" == "${EXPECTED_COMMIT_PREFIX}" ]]; then
  pass "VW-B: SOURCE commit is a full SHA starting ${EXPECTED_COMMIT_PREFIX}"
else
  fail "VW-B: SOURCE commit is not a full SHA starting ${EXPECTED_COMMIT_PREFIX} (got '${commit_b:0:64}')"
fi

# ===========================================================================
# GROUP VW-C: conformance line the provisioner expects.
# ===========================================================================
echo ""
echo "--- GROUP VW-C: conformance line ---"
conf_c="$(_source_value "${SOURCE_FILE}" conformance)"
if [[ "${conf_c}" == "${EXPECTED_CONFORMANCE}" ]]; then
  pass "VW-C: SOURCE conformance is '${EXPECTED_CONFORMANCE}'"
else
  fail "VW-C: SOURCE conformance mismatch (got '${conf_c:0:64}')"
fi

# ===========================================================================
# GROUP VW-D: one extra byte in the wheel breaks agreement.
# ===========================================================================
echo ""
echo "--- GROUP VW-D: tampered wheel bytes ---"
tmp_d="$(_copy_sidecar)"
TMP_HOMES+=("${tmp_d}")
for whl_d in "${tmp_d}"/sidecar/vendor/*.whl; do
  printf 'x' >> "${whl_d}"
done
if _check_wheel_agreement "${tmp_d}/sidecar" >/dev/null; then
  fail "VW-D: agreement check passed on a wheel with an appended byte"
else
  pass "VW-D: agreement check fails on a tampered wheel"
fi

# ===========================================================================
# GROUP VW-E: a different lock hash breaks agreement.
# ===========================================================================
echo ""
echo "--- GROUP VW-E: tampered lock hash ---"
tmp_e="$(_copy_sidecar)"
TMP_HOMES+=("${tmp_e}")
lock_e="${tmp_e}/sidecar/requirements.lock"
line_e=""
IFS= read -r line_e < "${lock_e}" || true
printf '%s--hash=sha256:%s\n' "${line_e%%--hash=sha256:*}" \
  "0000000000000000000000000000000000000000000000000000000000000000" > "${lock_e}"
if _check_wheel_agreement "${tmp_e}/sidecar" >/dev/null; then
  fail "VW-E: agreement check passed with an all-zero lock hash"
else
  pass "VW-E: agreement check fails on a tampered lock hash"
fi

# ===========================================================================
# GROUP VW-F: PyPI name claim status is recorded.
# ===========================================================================
echo ""
echo "--- GROUP VW-F: PyPI name claim status ---"
pypi_f="$(_source_value "${SOURCE_FILE}" pypi_name_claimed)"
if [[ "${pypi_f}" == "no" ]]; then
  pass "VW-F: SOURCE records pypi_name_claimed=no"
else
  fail "VW-F: SOURCE pypi_name_claimed is '${pypi_f:0:16}', expected 'no'"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
