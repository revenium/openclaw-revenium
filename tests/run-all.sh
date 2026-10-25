#!/usr/bin/env bash
# Runs every hermetic suite under tests/ and exits non-zero if any fails.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()

for suite in "${TESTS_DIR}"/test_*.sh "${TESTS_DIR}"/test_*.py; do
  name="$(basename "${suite}")"
  echo "=== ${name}"
  case "${suite}" in
    *.py) python3 "${suite}" ;;
    *)    bash "${suite}" ;;
  esac || failed+=("${name}")
done

echo ""
if (( ${#failed[@]} )); then
  echo "FAILED suites (${#failed[@]}): ${failed[*]}"
  exit 1
fi
echo "All suites passed."
