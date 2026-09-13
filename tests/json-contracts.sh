#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export ZF_LIBRARY_MODE=1
export ZF_ZAPRET_BASE="$TEST_DIR/zapret"
export ZF_ZAPRET_CONFIG="$ZF_ZAPRET_BASE/config"
export ZF_RUNTIME_DIR="$TEST_DIR/run"
export ZF_UPDATE_CACHE_DIR="$TEST_DIR/cache"
mkdir -p "$ZF_ZAPRET_BASE/nfq" "$ZF_ZAPRET_BASE/flowseal-current/strategies" \
    "$ZF_ZAPRET_BASE/flowseal-current/bin" "$ZF_ZAPRET_BASE/flowseal-current/lists" "$ZF_RUNTIME_DIR"
printf '#!/usr/bin/env bash\nprintf "github version v72.13 (test)\\n"\n' > "$ZF_ZAPRET_BASE/nfq/nfqws"
chmod +x "$ZF_ZAPRET_BASE/nfq/nfqws"
printf '1.10.2\n' > "$ZF_ZAPRET_BASE/.flowseal-version"
printf '# zapret-sonar-strategy: general.bat\n# zapret-sonar-gamefilter: off\n# zapret-sonar-ipset: none\n' > "$ZF_ZAPRET_CONFIG"
printf '203.0.113.113/32\n' > "$ZF_ZAPRET_BASE/flowseal-current/lists/ipset-all.txt"

# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"
systemctl() { [[ "$1" == is-active ]] && printf 'active\n'; }
status=$(cmd_status_json)
jq -e '.schema_version == 1 and .command == "status" and .sonar_version == "1.4.0" and .service_state == "active"' <<< "$status" >/dev/null

# shellcheck disable=SC2034
zf_health_check() {
    (( ZF_HEALTH_INCLUDE_QUIC == 0 ))
    ZF_HEALTH_PASSED=5; ZF_HEALTH_FAILED=1; ZF_HEALTH_SKIPPED=1
    return 1
}
set +e
check=$(cmd_check --json); rc=$?
set -e
(( rc == 1 ))
jq -e '.schema_version == 1 and .command == "check" and (.ok | not) and .passed == 5 and .failed == 1 and .skipped == 1 and .scope == "http-content"' <<< "$check" >/dev/null

# shellcheck disable=SC2034
zf_health_check() {
    (( ZF_HEALTH_INCLUDE_QUIC == 1 ))
    ZF_HEALTH_PASSED=2
    ZF_HEALTH_FAILED=1
    ZF_HEALTH_NOT_CHECKED=1
    ZF_HEALTH_RESULTS=(
        $'http\thttps://example.test/api\tPASS\thttp_response\t204\t-\t-\t-\t-\t-\t-'
        $'content\thttps://example.test/image.png\tNOT_CHECKED\tstale_target\t410\t-\t-\t-\t-\t-\t-'
        $'speed\thttps://example.test/file.tar.gz\tFAIL\tbelow_speed_threshold\t206\t500001\t120\t-\t-\t-\t-'
        $'quic\thttps://example.test/api\tPASS\thttp3_response\t200\t-\t-\t3\t0\t-\t-'
    )
    return 1
}
set +e
check_v2=$(cmd_check --json-v2); rc=$?
set -e
(( rc == 1 ))
jq -e '
    .schema_version == 2 and .command == "check" and (.ok | not) and
    .summary == {"passed":2,"failed":1,"not_checked":1} and
    .scope == ["http","content","speed","quic"] and
    (.checks | length) == 4 and
    .checks[0].status == "PASS" and .checks[0].http_code == 204 and
    .checks[1].status == "NOT_CHECKED" and .checks[1].bytes == null and
    .checks[2].category == "speed" and .checks[2].speed_kbps == 120 and
    .checks[3].category == "quic" and .checks[3].http_version == "3" and
    .checks[3].curl_exit_code == 0 and .checks[3].control_status == null and
    .checks[3].control_target == null and
    (.summary.passed + .summary.failed + .summary.not_checked) == (.checks | length)
' <<< "$check_v2" >/dev/null
printf 'PASS: status and check JSON v1/v2 contracts are versioned and valid\n'
