#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=../lib/health.sh
source "$PROJECT_DIR/lib/health.sh"

# shellcheck disable=SC2034
ZF_HEALTH_HOSTS=("https://example.test/failing-worker")
# shellcheck disable=SC2034
ZF_HEALTH_MEDIA=()
# shellcheck disable=SC2034
ZF_HEALTH_INCLUDE_QUIC=0
zf_check_host() { return 1; }

set +e
zf_health_check > "$TEST_DIR/output"; rc=$?
set -e
output=$(cat "$TEST_DIR/output")
(( rc == 1 ))
[[ "$output" == *'внутренняя ошибка проверки'* ]]
(( ZF_HEALTH_PASSED == 0 && ZF_HEALTH_FAILED == 1 && ZF_HEALTH_NOT_CHECKED == 0 ))
(( ${#ZF_HEALTH_RESULTS[@]} == 1 ))
IFS=$'\t' read -r category target status reason _ <<< "${ZF_HEALTH_RESULTS[0]}"
[[ "$category" == http && "$target" == 'https://example.test/failing-worker' ]]
[[ "$status" == FAIL && "$reason" == probe_execution_failed ]]

printf 'PASS: failed workers produce a structured result consistent with the summary\n'
