#!/usr/bin/env bash
# =============================================================================
# provision-sidecar.sh — Provision the agent-economics sidecar runtime.
#
# EXECUTED by post-install.sh and post-install-nemoclaw.sh, never sourced, so
# nothing in here can trip an installer's `set -e`. Installs a pinned uv, a
# uv-managed CPython and a venv holding only the vendored library wheel, runs
# the library's conformance kit, then records the result. A re-run reuses a
# runtime whose manifest matches the pins; otherwise it builds a new venv
# beside the old one and swaps it in only after the conformance kit passes.
#
# Usage:
#   bash scripts/provision-sidecar.sh [--openclaw-home DIR | --sandbox NAME | --state-dir DIR]
#
#   The option selects the per-install state dir that receives model.key and
#   whose infer lock is held during the venv swap. With no option only the
#   shared runtime is provisioned.
#
# Environment:
#   REVENIUM_SIDECAR_HOME            runtime dir (default ~/.local/share/revenium-sidecar)
#   REVENIUM_SIDECAR_PYTHON_VERSION  CPython request, 3.11 to 3.19 (default 3.13)
#   REVENIUM_ECONOMICS_MODEL_KEY     optional model-provider key, stored as
#                                    <state>/model.key (0600)
#
# Files:
#   <runtime>/bin/uv, <runtime>/python/, <runtime>/venv/
#   <runtime>/INSTALLED         uv_version, python_request, python_version,
#                               wheel_sha256, library_sha, conformance, installed_at
#   <runtime>/PROVISION_STATUS  reason, at, uv_version, python_request
#   <runtime>/provision.log     uv and conformance output from the last run
#   <runtime>/.revenium-sidecar-runtime  ownership marker (see economics-paths.sh)
#   <state>/model.key
#
# Exit codes: always 0. Every failure becomes a reason in PROVISION_STATUS
#   (see ECON_PROVISION_REASONS in economics-paths.sh) and a warning.
#
# SECURITY: the uv tarball is compared against a per-platform sha256 pin before
#   it is extracted. `uv python install --no-bin` never touches ~/.local/bin or
#   PATH. The library is installed with `--no-index --require-hashes` from the
#   vendored wheel, and UV_NO_CONFIG=1 keeps uv.toml / pyproject settings from
#   injecting an index. The model key is written with the printf builtin into a
#   mktemp file under umask 077, so it never reaches argv, output or a log.
#
# BASH 3.x COMPATIBILITY (mandatory): runs under macOS /bin/bash 3.2. No
#   associative arrays, case-changing expansions, the job-select wait flag or
#   the array-from-stdin builtins.
# =============================================================================
# NOTE: `set -uo pipefail` without `-e`: every failure has to be turned into a
# recorded reason before exiting 0, and -e would exit early instead.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

# shellcheck source=economics-paths.sh
. "${SCRIPT_DIR}/economics-paths.sh"

info() { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Pins. uv 0.12.19 release tarballs hold uv-<triple>/uv. Pinning uv also pins
# the CPython patch release it downloads from releases.astral.sh.
# ---------------------------------------------------------------------------
UV_VERSION="0.12.19"
UV_RELEASE_BASE="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
UV_SHA_DARWIN_ARM64="a9a8df1eedeb192f2e47e40e2faabfb387db4b850209118786d42f89dde3e0ba"
UV_SHA_DARWIN_X86_64="cb5fa57bafe68fc0fb94b17f06bee0b0b9a7feb94ccbd110445afa0696e39273"
UV_SHA_LINUX_X86_64="23bf5552d220e0842b65c862097b2ebaeba0064b74eda5e565e77fd25969d8c8"
UV_SHA_LINUX_AARCH64="0804e9b164c64b6914182d5920c08551958a095986f10a3731056df701126436"
PY_DEFAULT="3.13"
# Seconds to wait for a running infer to finish before swapping the venv.
SWAP_LOCK_WAIT_SECONDS=60

RT=""
STATE_DIR=""
OC_HOME_ARG=""
PY_REQUEST="${PY_DEFAULT}"
UV_TRIPLE=""
UV_SHA=""
LOCK_SHA=""
LIB_SHA=""
CONFORMANCE_EXPECTED=""
PROV_LOG=""

# ---------------------------------------------------------------------------
# record_reason <reason> — write PROVISION_STATUS and, for any failure, tell
# the operator the install carries on without the sidecar.
# ---------------------------------------------------------------------------
record_reason() {
  local reason="$1"
  econ_write_kv "${RT}/PROVISION_STATUS" "reason=${reason}" "at=$(econ_now_iso)" \
    "uv_version=${UV_VERSION}" "python_request=${PY_REQUEST}" \
    || warn "could not write ${RT}/PROVISION_STATUS"
  [[ "${reason}" == "ok" ]] && return 0
  warn "Economics sidecar not provisioned (${reason}) — install continues; metering and budget enforcement are unaffected. Re-run post-install to retry."
  if [[ -f "${RT}/INSTALLED" ]]; then
    warn "The existing sidecar runtime in ${RT} is kept."
  fi
  if [[ -s "${PROV_LOG}" ]]; then
    warn "Details: ${PROV_LOG}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# resolve_state_dir — set STATE_DIR from the option, or leave it empty when
# the dir cannot be used safely (owned by us, 0700, outside OPENCLAW_HOME).
# ---------------------------------------------------------------------------
resolve_state_dir() {
  local candidate="$1"
  [[ -n "${candidate}" ]] || return 0
  if ! econ_real_dir "${candidate}" >/dev/null; then
    warn "Ignoring sidecar state dir ${candidate:0:200}: it must be an absolute path without . or .. components"
    return 0
  fi
  if [[ -n "${OC_HOME_ARG}" ]] && econ_is_under "${candidate}" "${OC_HOME_ARG}"; then
    warn "Ignoring sidecar state dir ${candidate}: it is inside OPENCLAW_HOME, which the agent can read"
    return 0
  fi
  if ! econ_ensure_private_dir "${candidate}" || ! econ_dir_is_private "${candidate}"; then
    warn "Ignoring sidecar state dir ${candidate}: it must be owned by you, mode 0700 and not a symlink"
    return 0
  fi
  if [[ -n "${OC_HOME_ARG}" ]] && ! econ_state_dir_is_safe "${candidate}" "${OC_HOME_ARG}"; then
    warn "Ignoring sidecar state dir ${candidate}: it resolves inside OPENCLAW_HOME"
    return 0
  fi
  STATE_DIR="$(econ_real_dir "${candidate}")" || STATE_DIR=""
}

# ---------------------------------------------------------------------------
# store_model_key — D-18. The printf builtin spawns no process, so the key
# never appears in any argv; it is never echoed or logged.
# ---------------------------------------------------------------------------
store_model_key() {
  local tmp
  [[ -n "${REVENIUM_ECONOMICS_MODEL_KEY:-}" ]] || return 0
  if [[ -z "${STATE_DIR}" ]]; then
    warn "REVENIUM_ECONOMICS_MODEL_KEY is set but there is no usable sidecar state dir; the key was not stored"
    return 0
  fi
  tmp="$(mktemp "${STATE_DIR}/.model.key.XXXXXX" 2>/dev/null)" || {
    warn "Could not store the model key in ${STATE_DIR}"
    return 0
  }
  if printf '%s' "${REVENIUM_ECONOMICS_MODEL_KEY}" > "${tmp}" \
    && chmod 600 "${tmp}" \
    && mv -f "${tmp}" "${STATE_DIR}/model.key"; then
    info "Model key stored at ${STATE_DIR}/model.key (mode 0600)"
  else
    rm -f "${tmp}" 2>/dev/null
    warn "Could not store the model key in ${STATE_DIR}"
  fi
}

# ---------------------------------------------------------------------------
# select_platform — set UV_TRIPLE and UV_SHA; 1 when unsupported.
# ---------------------------------------------------------------------------
select_platform() {
  case "$(uname -s 2>/dev/null)-$(uname -m 2>/dev/null)" in
    Darwin-arm64)  UV_TRIPLE="aarch64-apple-darwin";      UV_SHA="${UV_SHA_DARWIN_ARM64}" ;;
    Darwin-x86_64) UV_TRIPLE="x86_64-apple-darwin";       UV_SHA="${UV_SHA_DARWIN_X86_64}" ;;
    Linux-x86_64)  UV_TRIPLE="x86_64-unknown-linux-gnu";  UV_SHA="${UV_SHA_LINUX_X86_64}" ;;
    Linux-aarch64) UV_TRIPLE="aarch64-unknown-linux-gnu"; UV_SHA="${UV_SHA_LINUX_AARCH64}" ;;
    *) return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# read_pins — LOCK_SHA from requirements.lock, LIB_SHA and the expected
# conformance line from vendor/SOURCE; 1 when any file or value is missing.
# The lock is parsed, never passed to a shell.
# ---------------------------------------------------------------------------
read_pins() {
  local lock="${SKILL_DIR}/sidecar/requirements.lock"
  local source="${SKILL_DIR}/sidecar/vendor/SOURCE"
  local line wheel_rel="" hash=""
  [[ -f "${lock}" && -f "${source}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      ''|'#'*) continue ;;
    esac
    wheel_rel="${line%% *}"
    case "${line}" in
      *"--hash=sha256:"*) hash="${line##*--hash=sha256:}"; hash="${hash%% *}" ;;
    esac
    break
  done < "${lock}"
  [[ "${wheel_rel}" =~ ^\./vendor/[A-Za-z0-9._+-]+\.whl$ ]] || return 1
  [[ "${hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ -f "${SKILL_DIR}/sidecar/${wheel_rel#./}" ]] || return 1
  LOCK_SHA="${hash}"
  LIB_SHA="$(econ_read_kv "${source}" commit)"
  CONFORMANCE_EXPECTED="$(econ_read_kv "${source}" conformance)"
  [[ -n "${CONFORMANCE_EXPECTED}" ]] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# runtime_matches_pins — D-05: reuse only when uv, the Python request and the
# wheel all match INSTALLED and the library imports.
# ---------------------------------------------------------------------------
runtime_matches_pins() {
  local manifest="${RT}/INSTALLED"
  [[ -f "${manifest}" ]] || return 1
  [[ "$(econ_read_kv "${manifest}" uv_version)" == "${UV_VERSION}" ]] || return 1
  [[ "$(econ_read_kv "${manifest}" python_request)" == "${PY_REQUEST}" ]] || return 1
  [[ "$(econ_read_kv "${manifest}" wheel_sha256)" == "${LOCK_SHA}" ]] || return 1
  [[ -x "${RT}/venv/bin/python" ]] || return 1
  "${RT}/venv/bin/python" -E -s -c 'import revenium_agent_economics' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# ensure_uv — reuse <runtime>/bin/uv at the pinned version, else download,
# verify and install it. Prints nothing on success; on failure prints the
# reason (download_failed or checksum_mismatch) and returns 1.
# ---------------------------------------------------------------------------
ensure_uv() {
  local uv_bin="${RT}/bin/uv" have tmpd actual rc=0
  if [[ -x "${uv_bin}" ]]; then
    have="$("${uv_bin}" --version 2>/dev/null)"
    if [[ "${have}" == "uv ${UV_VERSION}" || "${have}" == "uv ${UV_VERSION} "* ]]; then
      return 0
    fi
  fi
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/revenium-uv.XXXXXX" 2>/dev/null)" || {
    printf 'download_failed\n'
    return 1
  }
  if ! curl -fsSL --retry 2 --max-time 300 -o "${tmpd}/uv.tar.gz" \
      "${UV_RELEASE_BASE}/uv-${UV_TRIPLE}.tar.gz" >>"${PROV_LOG}" 2>&1; then
    printf 'download_failed\n'
    rc=1
  else
    # Verify the tarball, not the extracted binary: nothing is unpacked from
    # an unverified archive.
    actual="$(_econ_sha256_stdin < "${tmpd}/uv.tar.gz")"
    if [[ "${actual}" != "${UV_SHA}" ]]; then
      printf 'checksum_mismatch\n'
      rc=1
    elif ! tar -xzf "${tmpd}/uv.tar.gz" -C "${tmpd}" >>"${PROV_LOG}" 2>&1 \
      || [[ ! -f "${tmpd}/uv-${UV_TRIPLE}/uv" ]] \
      || ! mkdir -p "${RT}/bin" \
      || ! install -m 755 "${tmpd}/uv-${UV_TRIPLE}/uv" "${uv_bin}"; then
      printf 'download_failed\n'
      rc=1
    fi
  fi
  rm -rf "${tmpd}"
  return "${rc}"
}

# ---------------------------------------------------------------------------
# build_venv — install CPython, build <runtime>/venv.new with the wheel and
# run the conformance kit. On failure prints the reason, removes venv.new and
# returns 1.
# ---------------------------------------------------------------------------
build_venv() {
  local uv_bin="${RT}/bin/uv" new="${RT}/venv.new" out rc last
  export UV_NO_CONFIG=1 UV_PYTHON_INSTALL_DIR="${RT}/python" UV_CACHE_DIR="${RT}/cache"

  # A venv.new left by an interrupted run is never trusted or reused.
  rm -rf "${new}"
  if ! "${uv_bin}" python install --no-bin "${PY_REQUEST}" >>"${PROV_LOG}" 2>&1; then
    printf 'python_install_failed\n'
    return 1
  fi
  if ! "${uv_bin}" venv --no-project --managed-python --python "${PY_REQUEST}" --clear "${new}" >>"${PROV_LOG}" 2>&1; then
    rm -rf "${new}"
    printf 'venv_failed\n'
    return 1
  fi
  # Run from sidecar/ so the lock's ./vendor/<wheel> path resolves.
  if ! ( cd "${SKILL_DIR}/sidecar" \
      && "${uv_bin}" pip install --python "${new}/bin/python" --no-index --require-hashes -r requirements.lock ) \
      >>"${PROV_LOG}" 2>&1; then
    rm -rf "${new}"
    printf 'wheel_install_failed\n'
    return 1
  fi
  out="$("${new}/bin/python" -I -m revenium_agent_economics.conformance 2>>"${PROV_LOG}")"
  rc=$?
  printf '%s\n' "${out}" >>"${PROV_LOG}"
  last="$(printf '%s\n' "${out}" | tail -n 1)"
  if [[ "${rc}" -ne 0 || "${last}" != "${CONFORMANCE_EXPECTED}" ]]; then
    rm -rf "${new}"
    printf 'conformance_failed\n'
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# swap_venv — move venv.new into place while holding the infer lock, so a
# detached infer never starts against a half-swapped venv. The old venv stays
# until the new one is in place.
# ---------------------------------------------------------------------------
swap_venv() {
  local held=0 waited=0 rc=0
  if [[ -n "${STATE_DIR}" ]]; then
    while (( waited < SWAP_LOCK_WAIT_SECONDS )); do
      if econ_lock_acquire "${STATE_DIR}" "${ECON_INFER_BUDGET_DEFAULT}"; then
        held=1
        break
      fi
      sleep 1
      waited=$(( waited + 1 ))
    done
    (( held == 1 )) || warn "The sidecar infer lock stayed busy for ${SWAP_LOCK_WAIT_SECONDS}s; swapping the runtime anyway"
  fi
  rm -rf "${RT}/venv.old"
  if [[ -d "${RT}/venv" ]] && ! mv -f "${RT}/venv" "${RT}/venv.old"; then
    rc=1
  elif ! mv -f "${RT}/venv.new" "${RT}/venv"; then
    [[ -d "${RT}/venv.old" ]] && mv -f "${RT}/venv.old" "${RT}/venv"
    rc=1
  fi
  rm -rf "${RT}/venv.old" "${RT}/venv.new"
  (( held == 1 )) && econ_lock_release "${STATE_DIR}"
  return "${rc}"
}

# ---------------------------------------------------------------------------
# claim_runtime_dir — 0 when RT may be built into: it already carries the
# ownership marker, or it is empty and the marker was just written. A
# non-empty dir without the marker is refused untouched, because uv, venv/,
# python/ and the manifests would overwrite whatever it holds and the
# uninstaller would later remove it.
# ---------------------------------------------------------------------------
claim_runtime_dir() {
  econ_runtime_owned "${RT}" && return 0
  if [[ -n "$(ls -A "${RT}" 2>/dev/null)" ]]; then
    warn "Economics sidecar not provisioned: ${RT} is not empty and has no ${ECON_RUNTIME_MARKER} marker, so it was left untouched."
    if [[ -f "${RT}/INSTALLED" || -f "${RT}/PROVISION_STATUS" ]]; then
      warn "It looks like a sidecar runtime from an earlier version, which wrote no marker. Check that it holds only bin/uv, python/, venv/, cache/ and the INSTALLED, PROVISION_STATUS and provision.log files, remove it, then re-run post-install."
    else
      warn "Point REVENIUM_SIDECAR_HOME at a new or empty directory, then re-run post-install. Metering and budget enforcement are unaffected."
    fi
    return 1
  fi
  if ! econ_write_kv "${RT}/${ECON_RUNTIME_MARKER}" "owner=${ECON_RUNTIME_OWNER}" "created_at=$(econ_now_iso)"; then
    warn "Economics sidecar not provisioned: could not write the ownership marker in ${RT}"
    return 1
  fi
  return 0
}

prov_main() {
  local candidate="" reason python_version
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --openclaw-home)
        OC_HOME_ARG="${2:-}"
        [[ -n "${OC_HOME_ARG}" ]] && candidate="$(econ_standalone_state_dir "${OC_HOME_ARG}")"
        shift 2 || shift
        ;;
      --sandbox)
        candidate="$(econ_nemoclaw_state_dir "${2:-}")" \
          || warn "Ignoring invalid sandbox name ${2:0:64}"
        shift 2 || shift
        ;;
      --state-dir)
        candidate="${2:-}"
        shift 2 || shift
        ;;
      *)
        warn "provision-sidecar.sh: ignoring unknown argument ${1:0:64}"
        shift
        ;;
    esac
  done

  resolve_state_dir "${candidate}"

  RT="$(econ_runtime_dir)"
  if ! econ_real_dir "${RT}" >/dev/null; then
    warn "Economics sidecar not provisioned: runtime dir ${RT:0:200} must be an absolute path without . or .. components"
    return 0
  fi
  if [[ -n "${OC_HOME_ARG}" ]] && econ_is_under "${RT}" "${OC_HOME_ARG}"; then
    warn "Economics sidecar not provisioned: runtime dir ${RT} is inside OPENCLAW_HOME"
    return 0
  fi
  if ! econ_ensure_private_dir "${RT}" || ! econ_dir_not_shared_writable "${RT}"; then
    warn "Economics sidecar not provisioned: runtime dir ${RT} must be owned by you and not group- or world-writable"
    return 0
  fi
  RT="$(econ_real_dir "${RT}")" || return 0
  if ! claim_runtime_dir; then
    return 0
  fi
  PROV_LOG="${RT}/provision.log"
  : > "${PROV_LOG}" 2>/dev/null || PROV_LOG="/dev/null"

  store_model_key
  # The key is stored; keep it out of every child process's environment.
  unset REVENIUM_ECONOMICS_MODEL_KEY

  if [[ -n "${REVENIUM_SIDECAR_PYTHON_VERSION:-}" ]]; then
    if [[ "${REVENIUM_SIDECAR_PYTHON_VERSION}" =~ ^3\.1[1-9]$ ]]; then
      PY_REQUEST="${REVENIUM_SIDECAR_PYTHON_VERSION}"
    else
      warn "Ignoring REVENIUM_SIDECAR_PYTHON_VERSION=${REVENIUM_SIDECAR_PYTHON_VERSION:0:16} (expected 3.11 or later, like 3.13); using ${PY_DEFAULT}"
    fi
  fi

  if ! select_platform; then
    record_reason unsupported_platform
    return 0
  fi
  if ! read_pins; then
    record_reason wheel_missing
    return 0
  fi

  if runtime_matches_pins; then
    info "Economics sidecar runtime reused (uv ${UV_VERSION}, Python $(econ_read_kv "${RT}/INSTALLED" python_version), library ${LIB_SHA:0:7})"
    record_reason ok
    return 0
  fi

  reason="$(ensure_uv)" || { record_reason "${reason:-download_failed}"; return 0; }
  reason="$(build_venv)" || { record_reason "${reason:-venv_failed}"; return 0; }
  if ! swap_venv; then
    record_reason venv_failed
    return 0
  fi

  python_version="$("${RT}/venv/bin/python" -E -s -c 'import platform; print(platform.python_version())' 2>/dev/null)"
  [[ "${python_version}" =~ ^3\.[0-9]{1,2}\.[0-9]{1,3}$ ]] || python_version=""
  econ_write_kv "${RT}/INSTALLED" \
    "uv_version=${UV_VERSION}" \
    "python_request=${PY_REQUEST}" \
    "python_version=${python_version}" \
    "wheel_sha256=${LOCK_SHA}" \
    "library_sha=${LIB_SHA}" \
    "conformance=${CONFORMANCE_EXPECTED}" \
    "installed_at=$(econ_now_iso)" \
    || { record_reason venv_failed; return 0; }
  record_reason ok
  rm -rf "${RT}/cache"
  info "Economics sidecar provisioned: Python ${python_version:-unknown}, library ${LIB_SHA:0:7}"
  return 0
}

# Run in a subshell so that even an unexpected `set -u` abort inside it still
# leaves this script exiting 0.
( prov_main "$@" )
exit 0
