#!/usr/bin/env bash
# =============================================================================
# test_provision_sidecar.sh — Hermetic suite for scripts/provision-sidecar.sh.
#
# Covers the failure matrix (every step records its reason and exits 0),
# manifest-gated reuse, the pinning flags uv is called with, model key
# handling and the runtime dir permission check. No network: stub `curl` and
# `uname` sit first on PATH, and a stub `uv` is pre-seeded at <runtime>/bin/uv.
# The stub uv logs its argv to <runtime>/uv-calls.log and reads a mode word
# from <runtime>/stub-uv-mode; its `venv` call plants a stub python that
# answers the conformance, platform and import checks.
#
# Groups PS-A..PS-O. Set TAP=1 to print TAP instead of PASS:/FAIL: lines.
#
# SECURITY: stub argv and outputs are compared as fixed strings, never
#   evaluated or interpolated into commands.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROV_SH="${REPO_ROOT}/scripts/provision-sidecar.sh"

PASS=0
FAIL=0
TAP_N=0

pass() {
  ((PASS++)) || true
  if [[ "${TAP:-}" == "1" ]]; then TAP_N=$((TAP_N + 1)); printf 'ok %s - %s\n' "${TAP_N}" "$1"; else printf 'PASS: %s\n' "$1"; fi
}
fail() {
  ((FAIL++)) || true
  if [[ "${TAP:-}" == "1" ]]; then TAP_N=$((TAP_N + 1)); printf 'not ok %s - %s\n' "${TAP_N}" "$1"; else printf 'FAIL: %s\n' "$1"; fi
}
group() {
  if [[ "${TAP:-}" == "1" ]]; then printf '# %s\n' "$1"; else printf '\n--- %s ---\n' "$1"; fi
}

[[ "${TAP:-}" == "1" ]] && printf 'TAP version 13\n'

# The suite controls these; an operator's exported values must not leak in.
unset REVENIUM_ECONOMICS_MODEL_KEY REVENIUM_SIDECAR_PYTHON_VERSION REVENIUM_ECON_STATE_DIR XDG_STATE_HOME

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

if [[ ! -f "${PROV_SH}" ]]; then
  fail "provision-script-exists: ${PROV_SH} not found"
  printf '\nResults: %s passed, %s failed\n' "${PASS}" "${FAIL}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Stubs shared by every group.
# ---------------------------------------------------------------------------
STUB_BIN="$(mktemp -d "${TMPDIR:-/tmp}/test-prov-bin.XXXXXX")"
TMP_HOMES+=("${STUB_BIN}")

# curl: never touches the network. fail (default) exits 22; random writes
# bytes that cannot match any pinned sha256. Every call is logged.
cat > "${STUB_BIN}/curl" <<'CURL_STUB'
#!/usr/bin/env bash
out=""
[ -n "${STUB_CURL_LOG:-}" ] && printf '%s\n' "$*" >> "${STUB_CURL_LOG}"
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
case "${STUB_CURL_MODE:-fail}" in
  random) [ -n "${out}" ] && head -c 4096 /dev/urandom > "${out}"; exit 0 ;;
  *) exit 22 ;;
esac
CURL_STUB

cat > "${STUB_BIN}/uname" <<'UNAME_STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf '%s\n' "${STUB_UNAME_M:-x86_64}" ;;
  *)  printf '%s\n' "${STUB_UNAME_S:-Linux}" ;;
esac
UNAME_STUB

chmod 755 "${STUB_BIN}/curl" "${STUB_BIN}/uname"

# uv: logs argv and the uv environment, then acts per <runtime>/stub-uv-mode.
STUB_UV_SRC="${STUB_BIN}/uv.src"
cat > "${STUB_UV_SRC}" <<'UV_STUB'
#!/usr/bin/env bash
rt="$(cd "$(dirname "$0")/.." && pwd -P)"
printf '%s\n' "$*" >> "${rt}/uv-calls.log"
if [ -n "${REVENIUM_ECONOMICS_MODEL_KEY:-}" ]; then echo "key_in_env=yes"; else echo "key_in_env=no"; fi >> "${rt}/uv-env.log"
printf 'UV_NO_CONFIG=%s\nUV_PYTHON_INSTALL_DIR=%s\nUV_CACHE_DIR=%s\n' \
  "${UV_NO_CONFIG:-}" "${UV_PYTHON_INSTALL_DIR:-}" "${UV_CACHE_DIR:-}" >> "${rt}/uv-env.log"
mode="ok"
[ -f "${rt}/stub-uv-mode" ] && mode="$(cat "${rt}/stub-uv-mode")"
case "${1:-}" in
  --version) echo "uv 0.12.19 (stub)"; exit 0 ;;
  python) [ "${mode}" = "python_fail" ] && exit 1; exit 0 ;;
  venv)
    target=""
    for a in "$@"; do target="${a}"; done
    mkdir -p "${target}/bin"
    [ "${mode}" = "venv_fail" ] && exit 1
    cp "${rt}/stub-python" "${target}/bin/python"
    chmod 755 "${target}/bin/python"
    exit 0
    ;;
  pip) [ "${mode}" = "pip_fail" ] && exit 1; exit 0 ;;
esac
exit 0
UV_STUB

# python: planted by the stub uv at <venv>/bin/python.
STUB_PY_SRC="${STUB_BIN}/python.src"
cat > "${STUB_PY_SRC}" <<'PY_STUB'
#!/usr/bin/env bash
rt="$(cd "$(dirname "$0")/../.." && pwd -P)"
mode="ok"
[ -f "${rt}/stub-uv-mode" ] && mode="$(cat "${rt}/stub-uv-mode")"
for a in "$@"; do
  case "${a}" in
    revenium_agent_economics.conformance)
      echo "scenario single-job ... ok"
      if [ "${mode}" = "conformance_fail" ]; then echo "23 scenarios, 1 failing"; else echo "24 scenarios, 0 failing"; fi
      exit 0
      ;;
    *platform.python_version*) echo "3.13.15"; exit 0 ;;
  esac
done
exit 0
PY_STUB

LOCK_SHA="$(sed -n 's/.*--hash=sha256:\([0-9a-f]\{64\}\).*/\1/p' "${REPO_ROOT}/sidecar/requirements.lock" | head -1)"
LIB_SHA="$(sed -n 's/^commit=//p' "${REPO_ROOT}/sidecar/vendor/SOURCE" | head -1)"

# ---------------------------------------------------------------------------
# new_env — fresh HOME (H) and runtime (RT, physical path) with the stub uv
# and stub python seeded. RT is created 0700, as the provisioner would.
# ---------------------------------------------------------------------------
new_env() {
  H="$(mktemp -d "${TMPDIR:-/tmp}/test-prov-home.XXXXXX")"
  TMP_HOMES+=("${H}")
  H="$(cd -P "${H}" && pwd -P)"
  RT="${H}/rt"
  mkdir -p "${RT}/bin"
  chmod 700 "${RT}"
  cp "${STUB_UV_SRC}" "${RT}/bin/uv"
  cp "${STUB_PY_SRC}" "${RT}/stub-python"
  chmod 755 "${RT}/bin/uv" "${RT}/stub-python"
  CURL_LOG="${H}/curl-calls.log"
}

# new_env_no_uv — as new_env, without a pre-seeded uv.
new_env_no_uv() {
  new_env
  rm -f "${RT}/bin/uv"
}

# run_prov [args...] — run the provisioner against H/RT with the stubs first
# on PATH. Sets OUT (stdout+stderr) and RC.
run_prov() {
  RC=0
  OUT="$(HOME="${H}" REVENIUM_SIDECAR_HOME="${RT}" STUB_CURL_LOG="${CURL_LOG}" \
    PATH="${STUB_BIN}:${PATH}" bash "${PROV_SH}" "$@" 2>&1)" || RC=$?
}

status_reason() {
  sed -n 's/^reason=//p' "${RT}/PROVISION_STATUS" 2>/dev/null | head -1
}

kv() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# assert_common <id> — every run exits 0 and leaves $HOME/.local/bin empty.
assert_common() {
  if [[ "${RC}" -eq 0 ]]; then
    pass "$1: provisioner exits 0"
  else
    fail "$1: provisioner exited ${RC}"
  fi
  if [[ -z "$(ls -A "${H}/.local/bin" 2>/dev/null)" ]]; then
    pass "$1: \$HOME/.local/bin gained no entries"
  else
    fail "$1: \$HOME/.local/bin gained entries"
  fi
}

assert_reason() {
  local id="$1" want="$2" got
  got="$(status_reason)"
  if [[ "${got}" == "${want}" ]]; then
    pass "${id}: PROVISION_STATUS reason=${want}"
  else
    fail "${id}: PROVISION_STATUS reason='${got}', expected '${want}'"
  fi
}

assert_out_has() {
  local id="$1" needle="$2" label="$3"
  if grep -qF -- "${needle}" <<<"${OUT}"; then
    pass "${id}: ${label}"
  else
    fail "${id}: ${label} (output lacked '${needle}')"
  fi
}

# seed_old_runtime — a working runtime from an earlier build: INSTALLED with a
# stale wheel hash (so it is not reused) and venv/sentinel.
seed_old_runtime() {
  mkdir -p "${RT}/venv/bin"
  printf 'old\n' > "${RT}/venv/sentinel"
  cp "${RT}/stub-python" "${RT}/venv/bin/python"
  printf '%s\n' "uv_version=0.12.19" "python_request=3.13" "python_version=3.13.1" \
    "wheel_sha256=0000000000000000000000000000000000000000000000000000000000000000" \
    "library_sha=old" "conformance=24 scenarios, 0 failing" "installed_at=2026-01-01T00:00:00Z" \
    > "${RT}/INSTALLED"
}

# ===========================================================================
group "GROUP PS-A: unsupported platform"
new_env
STUB_UNAME_S="FreeBSD" STUB_UNAME_M="amd64" run_prov
assert_common "PS-A"
assert_reason "PS-A" "unsupported_platform"
assert_out_has "PS-A" "metering and budget enforcement are unaffected" "warning says metering is unaffected"

# ===========================================================================
group "GROUP PS-B: uv download fails"
new_env_no_uv
STUB_CURL_MODE="fail" run_prov
assert_common "PS-B"
assert_reason "PS-B" "download_failed"
if [[ ! -e "${RT}/bin/uv" ]]; then pass "PS-B: no uv installed"; else fail "PS-B: a uv binary was installed"; fi

# ===========================================================================
group "GROUP PS-C: uv tarball checksum mismatch"
new_env_no_uv
STUB_CURL_MODE="random" run_prov
assert_common "PS-C"
assert_reason "PS-C" "checksum_mismatch"
if [[ ! -e "${RT}/bin/uv" ]]; then pass "PS-C: nothing installed from an unverified tarball"; else fail "PS-C: uv installed from an unverified tarball"; fi
if grep -qF "uv-x86_64-unknown-linux-gnu.tar.gz" "${CURL_LOG}" 2>/dev/null; then
  pass "PS-C: fetched the pinned Linux-x86_64 asset"
else
  fail "PS-C: curl was not asked for the pinned Linux-x86_64 asset"
fi

# ===========================================================================
# PS-D..PS-G: each later step fails; venv.new is removed, the existing runtime
# is kept, and the reason is recorded.
# ---------------------------------------------------------------------------
fail_step_case() {
  local id="$1" mode="$2" want="$3"
  new_env
  seed_old_runtime
  mkdir -p "${RT}/venv.new/bin"
  printf '%s\n' "${mode}" > "${RT}/stub-uv-mode"
  run_prov
  assert_common "${id}"
  assert_reason "${id}" "${want}"
  if [[ ! -e "${RT}/venv.new" ]]; then pass "${id}: ${want} leaves no venv.new"; else fail "${id}: ${want} left venv.new behind"; fi
  if [[ -f "${RT}/venv/sentinel" ]]; then pass "${id}: existing venv kept"; else fail "${id}: existing venv was replaced"; fi
  if [[ "$(kv "${RT}/INSTALLED" library_sha)" == "old" ]]; then pass "${id}: existing INSTALLED kept"; else fail "${id}: existing INSTALLED was rewritten"; fi
  assert_out_has "${id}" "is kept" "warning says the existing runtime is kept"
}

group "GROUP PS-D: python install fails"
fail_step_case "PS-D" "python_fail" "python_install_failed"
group "GROUP PS-E: venv creation fails"
fail_step_case "PS-E" "venv_fail" "venv_failed"
group "GROUP PS-F: wheel install fails"
fail_step_case "PS-F" "pip_fail" "wheel_install_failed"
group "GROUP PS-G: conformance kit last line differs"
fail_step_case "PS-G" "conformance_fail" "conformance_failed"

# ===========================================================================
group "GROUP PS-H: successful build writes the manifest"
new_env
mkdir -p "${RT}/cache/wheels"
run_prov
assert_common "PS-H"
assert_reason "PS-H" "ok"
ps_h_ok=1
for key in uv_version python_request python_version wheel_sha256 library_sha conformance installed_at; do
  grep -q "^${key}=" "${RT}/INSTALLED" 2>/dev/null || ps_h_ok=0
done
if [[ "${ps_h_ok}" -eq 1 ]]; then pass "PS-H: INSTALLED has all seven keys"; else fail "PS-H: INSTALLED is missing keys"; fi
if [[ "$(kv "${RT}/INSTALLED" uv_version)" == "0.12.19" && "$(kv "${RT}/INSTALLED" python_request)" == "3.13" \
  && "$(kv "${RT}/INSTALLED" python_version)" == "3.13.15" && "$(kv "${RT}/INSTALLED" wheel_sha256)" == "${LOCK_SHA}" \
  && "$(kv "${RT}/INSTALLED" library_sha)" == "${LIB_SHA}" \
  && "$(kv "${RT}/INSTALLED" conformance)" == "24 scenarios, 0 failing" ]]; then
  pass "PS-H: INSTALLED values match the pins"
else
  fail "PS-H: INSTALLED values do not match the pins"
fi
if [[ ! -e "${RT}/cache" ]]; then pass "PS-H: uv cache removed"; else fail "PS-H: uv cache left behind"; fi
if [[ -x "${RT}/venv/bin/python" && ! -e "${RT}/venv.new" ]]; then pass "PS-H: venv.new swapped into venv"; else fail "PS-H: venv not swapped into place"; fi
if [[ ! -s "${CURL_LOG}" ]]; then pass "PS-H: a pinned uv already present means no download"; else fail "PS-H: curl was called although uv 0.12.19 was present"; fi
assert_out_has "PS-H" "${LIB_SHA:0:7}" "info line names the library SHA"

# ===========================================================================
group "GROUP PS-I: manifest-gated reuse"
: > "${RT}/uv-calls.log"
run_prov
assert_common "PS-I"
assert_out_has "PS-I" "reused" "second run reports reuse"
if ! grep -q '^venv ' "${RT}/uv-calls.log"; then pass "PS-I: reuse makes no venv call"; else fail "PS-I: reuse rebuilt the venv"; fi
sed 's/^wheel_sha256=.*/wheel_sha256=1111111111111111111111111111111111111111111111111111111111111111/' \
  "${RT}/INSTALLED" > "${RT}/INSTALLED.edit" && mv "${RT}/INSTALLED.edit" "${RT}/INSTALLED"
: > "${RT}/uv-calls.log"
run_prov
if grep -q '^venv ' "${RT}/uv-calls.log"; then pass "PS-I: changed wheel_sha256 forces a rebuild"; else fail "PS-I: changed wheel_sha256 did not rebuild"; fi
if [[ "$(kv "${RT}/INSTALLED" wheel_sha256)" == "${LOCK_SHA}" ]]; then pass "PS-I: rebuild rewrites wheel_sha256"; else fail "PS-I: rebuild left the stale wheel_sha256"; fi

# ===========================================================================
group "GROUP PS-J: uv is called with the pinning flags"
new_env
run_prov
if grep -qE '^python install --no-bin 3\.13$' "${RT}/uv-calls.log"; then
  pass "PS-J: uv python install --no-bin"
else
  fail "PS-J: uv python install was not called with --no-bin"
fi
pip_line="$(grep '^pip install' "${RT}/uv-calls.log" | head -1)"
if [[ "${pip_line}" == *"--no-index"* && "${pip_line}" == *"--require-hashes"* && "${pip_line}" == *"-r requirements.lock"* ]]; then
  pass "PS-J: pip install uses --no-index --require-hashes -r requirements.lock"
else
  fail "PS-J: pip install line lacks the pinning flags: ${pip_line}"
fi
if grep -q '^venv .*--managed-python' "${RT}/uv-calls.log"; then pass "PS-J: venv uses --managed-python"; else fail "PS-J: venv call lacks --managed-python"; fi
if grep -qx 'UV_NO_CONFIG=1' "${RT}/uv-env.log" && grep -qxF "UV_PYTHON_INSTALL_DIR=${RT}/python" "${RT}/uv-env.log"; then
  pass "PS-J: uv runs with UV_NO_CONFIG=1 and the runtime's python dir"
else
  fail "PS-J: uv environment not pinned (UV_NO_CONFIG / UV_PYTHON_INSTALL_DIR)"
fi

# ===========================================================================
group "GROUP PS-K: wheel missing"
new_env
KCOPY="${H}/skill"
mkdir -p "${KCOPY}"
cp -R "${REPO_ROOT}/scripts" "${REPO_ROOT}/sidecar" "${KCOPY}/"
rm -f "${KCOPY}"/sidecar/vendor/*.whl
RC=0
OUT="$(HOME="${H}" REVENIUM_SIDECAR_HOME="${RT}" PATH="${STUB_BIN}:${PATH}" \
  bash "${KCOPY}/scripts/provision-sidecar.sh" 2>&1)" || RC=$?
assert_common "PS-K"
assert_reason "PS-K" "wheel_missing"

# ===========================================================================
group "GROUP PS-L: pinning flags stay on non-comment lines"
for flag in --no-bin --no-index --require-hashes --managed-python; do
  if grep -v '^[[:space:]]*#' "${PROV_SH}" | grep -q -e "${flag}"; then
    pass "PS-L: ${flag} present on a non-comment line"
  else
    fail "PS-L: ${flag} missing from scripts/provision-sidecar.sh"
  fi
done

# ===========================================================================
group "GROUP PS-M: model key handling"
new_env
MKEY="sk-test-model-key-7f3a9c2e1b5d4f60"
STATE="${H}/state"
RC=0
OUT="$(HOME="${H}" REVENIUM_SIDECAR_HOME="${RT}" REVENIUM_ECONOMICS_MODEL_KEY="${MKEY}" \
  PATH="${STUB_BIN}:${PATH}" bash "${PROV_SH}" --state-dir "${STATE}" 2>&1)" || RC=$?
assert_common "PS-M"
if [[ -f "${STATE}/model.key" && "$(cat "${STATE}/model.key")" == "${MKEY}" \
  && "$(wc -c < "${STATE}/model.key" | tr -d ' ')" == "${#MKEY}" ]]; then
  pass "PS-M: model.key holds exactly the key"
else
  fail "PS-M: model.key missing or not exactly the key"
fi
mkey_perms="$(ls -l "${STATE}/model.key" 2>/dev/null)"
if [[ "${mkey_perms:0:10}" == "-rw-------" ]]; then pass "PS-M: model.key is -rw-------"; else fail "PS-M: model.key perms '${mkey_perms:0:10}'"; fi
if ! grep -qF -- "${MKEY}" <<<"${OUT}"; then pass "PS-M: key absent from output"; else fail "PS-M: key printed to output"; fi
if ! grep -rqF -- "${MKEY}" "${RT}" 2>/dev/null; then pass "PS-M: key absent from every runtime file"; else fail "PS-M: key written into the runtime dir"; fi
if grep -qx 'key_in_env=no' "${RT}/uv-env.log" && ! grep -qx 'key_in_env=yes' "${RT}/uv-env.log"; then
  pass "PS-M: key kept out of uv's environment"
else
  fail "PS-M: uv inherited the model key"
fi
if [[ -z "$(ls -A "${STATE}" | grep '^\.model\.key\.' || true)" ]]; then pass "PS-M: no temp key file left"; else fail "PS-M: temp key file left in the state dir"; fi
before="$(cat "${STATE}/model.key" 2>/dev/null)"
run_prov --state-dir "${STATE}"
if [[ "$(cat "${STATE}/model.key" 2>/dev/null)" == "${before}" && -n "${before}" ]]; then
  pass "PS-M: a run without the variable leaves model.key unchanged"
else
  fail "PS-M: a run without the variable changed model.key"
fi

# ===========================================================================
group "GROUP PS-N: shared-writable runtime dir is refused"
new_env
chmod 777 "${RT}"
run_prov
assert_common "PS-N"
if [[ ! -e "${RT}/PROVISION_STATUS" ]]; then pass "PS-N: no PROVISION_STATUS written"; else fail "PS-N: PROVISION_STATUS written into a 0777 runtime dir"; fi
assert_out_has "PS-N" "not group- or world-writable" "warns about the runtime dir mode"
chmod 700 "${RT}"

# ===========================================================================
group "GROUP PS-O: Python version request"
new_env
REVENIUM_SIDECAR_PYTHON_VERSION="3.11" run_prov
if grep -qE '^python install --no-bin 3\.11$' "${RT}/uv-calls.log" && [[ "$(kv "${RT}/INSTALLED" python_request)" == "3.11" ]]; then
  pass "PS-O: a valid request (3.11) is used and recorded"
else
  fail "PS-O: a valid 3.11 request was not used"
fi
new_env
REVENIUM_SIDECAR_PYTHON_VERSION="3.9; rm -rf /" run_prov
assert_common "PS-O"
if grep -qE '^python install --no-bin 3\.13$' "${RT}/uv-calls.log" && [[ "$(kv "${RT}/PROVISION_STATUS" python_request)" == "3.13" ]]; then
  pass "PS-O: an invalid request falls back to 3.13"
else
  fail "PS-O: an invalid request was not replaced by 3.13"
fi
assert_out_has "PS-O" "Ignoring REVENIUM_SIDECAR_PYTHON_VERSION" "warns about the invalid request"

# ===========================================================================
# Summary
# ===========================================================================
if [[ "${TAP:-}" == "1" ]]; then
  printf '1..%s\n' "${TAP_N}"
else
  printf '\nResults: %s passed, %s failed\n' "${PASS}" "${FAIL}"
fi
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
