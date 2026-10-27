#!/usr/bin/env bash
# =============================================================================
# run-sidecar-tests.sh — Run every tests/sidecar suite under an interpreter
# that has the vendored revenium-agent-economics library installed.
#
# The sidecar suites need the real library (the end-to-end shim test is
# skipped without it), so they cannot run under the system python3 that
# tests/run-all.sh uses. This script is deliberately named outside run-all's
# `test_*.sh` glob: it needs either uv or a provisioned runtime.
#
# Usage:
#   bash tests/run-sidecar-tests.sh
#
# Environment:
#   SIDECAR_TEST_RUNTIME         Use this runtime (its venv/bin/python) as is.
#   SIDECAR_TEST_PYTHON_VERSION  Python for the cached runtime (default 3.11).
#
# Without SIDECAR_TEST_RUNTIME, a runtime is cached at
#   ${TMPDIR:-/tmp}/revenium-sidecar-test-rt-py<version>
# and rebuilt whenever its INSTALLED wheel_sha256 differs from the hash pinned
# in sidecar/requirements.lock.
#
# Exit codes:
#   0  every suite passed and nothing was skipped
#   1  a test failed, a test was skipped, or no runtime could be prepared
#
# SECURITY: the only package installed is the vendored wheel, with
#   --no-index --require-hashes, so nothing is fetched from an index. The
#   cached runtime is created under umask 077. uv runs with UV_NO_CONFIG=1 so
#   a project or user uv.toml cannot redirect the install.
# =============================================================================
# NOTE: `set -uo pipefail` without `-e`: the unittest exit status and its
# output are both inspected after the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
SIDECAR_DIR="${REPO_ROOT}/sidecar"
LOCK_FILE="${SIDECAR_DIR}/requirements.lock"
SOURCE_FILE="${SIDECAR_DIR}/vendor/SOURCE"

die() {
  printf '%s\n' "run-sidecar-tests: $*" >&2
  exit 1
}

# kv_value <file> <key> — value of the first `key=` line; never sources the file.
kv_value() {
  local file="$1" key="$2" line
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      "${key}="*) printf '%s\n' "${line#"${key}="}"; return 0 ;;
    esac
  done < "${file}"
  return 0
}

lock_wheel_sha() {
  local line
  line="$(head -n 1 "${LOCK_FILE}" 2>/dev/null)"
  line="${line##*--hash=sha256:}"
  printf '%s\n' "${line%%[[:space:]]*}"
}

prepare_cached_runtime() {
  local version="${SIDECAR_TEST_PYTHON_VERSION:-3.11}" want have commit
  if ! [[ "${version}" =~ ^3\.[0-9]{1,2}$ ]]; then
    die "SIDECAR_TEST_PYTHON_VERSION must look like 3.11"
  fi
  command -v uv >/dev/null 2>&1 \
    || die "uv is not on PATH; install uv or set SIDECAR_TEST_RUNTIME to a provisioned runtime"
  RT="${TMPDIR:-/tmp}"
  RT="${RT%/}/revenium-sidecar-test-rt-py${version}"
  want="$(lock_wheel_sha)"
  [[ "${want}" =~ ^[0-9a-f]{64}$ ]] || die "could not read the wheel hash from ${LOCK_FILE}"
  have="$(kv_value "${RT}/INSTALLED" wheel_sha256)"
  if [[ "${have}" == "${want}" && -x "${RT}/venv/bin/python" ]]; then
    return 0
  fi

  printf '%s\n' "run-sidecar-tests: building test runtime at ${RT} (Python ${version})"
  rm -rf "${RT}"
  (
    umask 077
    mkdir -p "${RT}" \
      && UV_NO_CONFIG=1 uv venv --quiet --python "${version}" "${RT}/venv" \
      && cd "${SIDECAR_DIR}" \
      && UV_NO_CONFIG=1 uv pip install --quiet --python "${RT}/venv/bin/python" \
           --no-index --require-hashes -r requirements.lock
  ) || die "could not build the test runtime at ${RT}"
  commit="$(kv_value "${SOURCE_FILE}" commit)"
  (
    umask 077
    printf 'wheel_sha256=%s\nlibrary_sha=%s\n' "${want}" "${commit}" > "${RT}/INSTALLED"
  ) || die "could not write ${RT}/INSTALLED"
  return 0
}

if [[ -n "${SIDECAR_TEST_RUNTIME:-}" && -x "${SIDECAR_TEST_RUNTIME}/venv/bin/python" ]]; then
  RT="${SIDECAR_TEST_RUNTIME}"
else
  prepare_cached_runtime
fi
export SIDECAR_TEST_RUNTIME="${RT}"

OUT="$(mktemp "${TMPDIR:-/tmp}/revenium-sidecar-tests.XXXXXX")" || die "mktemp failed"
trap 'rm -f "${OUT}"' EXIT

cd "${REPO_ROOT}" || die "cannot cd to ${REPO_ROOT}"
"${RT}/venv/bin/python" -E -s -B -X utf8 -m unittest discover -s tests/sidecar -p 'test_*.py' -v \
  > "${OUT}" 2>&1
rc=$?
cat "${OUT}"

if [[ "${rc}" -ne 0 ]]; then
  printf '%s\n' "run-sidecar-tests: unittest failed (rc=${rc})" >&2
  exit 1
fi
if grep -qE '^Ran 0 tests' "${OUT}"; then
  printf '%s\n' "run-sidecar-tests: no tests ran" >&2
  exit 1
fi
if grep -q 'skipped' "${OUT}"; then
  printf '%s\n' "run-sidecar-tests: a test was skipped; every sidecar test must run" >&2
  exit 1
fi
exit 0
