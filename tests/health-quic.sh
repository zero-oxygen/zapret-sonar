#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fake_bin="$TEST_DIR/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    *'--version'*)
        [[ "${ZF_CURL_HTTP3:-1}" == 1 ]] && printf 'curl 8.0.0\nFeatures: HTTP2 HTTP3 SSL\n' \
            || printf 'curl 8.0.0\nFeatures: HTTP2 SSL\n'
        exit 0
        ;;
    *'--help all'*) printf '     --http3-only  Use HTTP/3 only\n'; exit 0 ;;
esac

[[ "$*" == *'--http3-only'* && "$*" == *"--noproxy *"* ]] || exit 64
case "$*" in
    *discord.com*)
        case "${ZF_CURL_TARGET:-pass}" in
            pass) printf '200|3'; exit 0 ;;
            unsupported) printf '000|0'; exit 4 ;;
            fail) printf '000|0'; exit 28 ;;
        esac
        ;;
    *cloudflare-quic.com*)
        [[ "${ZF_CURL_CONTROL:-pass}" == pass ]] && { printf '200|3'; exit 0; }
        printf '000|0'; exit 28
        ;;
esac
exit 65
EOF
chmod +x "$fake_bin/curl"
export PATH="$fake_bin:$PATH"

# shellcheck source=../lib/health.sh
source "$PROJECT_DIR/lib/health.sh"

output=$(ZF_CURL_TARGET=pass zf_check_quic "$TEST_DIR/result")
[[ "$output" == *'HTTP/3 200'* ]]
IFS=$'\t' read -r category _target status reason http_code _bytes _speed_kbps \
    http_version curl_exit_code control_status control_target < "$TEST_DIR/result"
[[ "$category" == quic && "$status" == PASS && "$reason" == http3_response ]]
[[ "$http_code" == 200 && "$http_version" == 3 && "$curl_exit_code" == 0 && "$control_status" == - && "$control_target" == - ]]

set +e
output=$(ZF_CURL_HTTP3=0 zf_check_quic "$TEST_DIR/result"); rc=$?
set -e
(( rc == 2 ))
[[ "$output" == *'NOT CHECKED'* && "$output" == *'curl без HTTP/3'* ]]

set +e
output=$(ZF_CURL_TARGET=unsupported zf_check_quic "$TEST_DIR/result"); rc=$?
set -e
(( rc == 2 ))
[[ "$output" == *'NOT CHECKED'* && "$output" == *'не поддерживается curl'* ]]

set +e
output=$(ZF_CURL_TARGET=fail ZF_CURL_CONTROL=pass zf_check_quic "$TEST_DIR/result"); rc=$?
set -e
(( rc == 1 ))
[[ "$output" == *'FAIL'* && "$output" == *'контрольная цель работает'* ]]
IFS=$'\t' read -r category _target status reason http_code _bytes _speed_kbps \
    http_version curl_exit_code control_status control_target < "$TEST_DIR/result"
[[ "$status" == FAIL && "$reason" == target_http3_failed && "$curl_exit_code" == 28 && "$control_status" == PASS ]]
[[ "$http_code" == 000 && "$http_version" == 0 ]]
[[ "$control_target" == 'https://cloudflare-quic.com/' ]]

set +e
output=$(ZF_CURL_TARGET=fail ZF_CURL_CONTROL=fail zf_check_quic "$TEST_DIR/result"); rc=$?
set -e
(( rc == 2 ))
[[ "$output" == *'NOT CHECKED'* && "$output" == *'контрольной цели'* ]]
IFS=$'\t' read -r category _target status reason http_code _bytes _speed_kbps \
    http_version curl_exit_code control_status control_target < "$TEST_DIR/result"
[[ "$status" == NOT_CHECKED && "$reason" == control_http3_failed && "$control_status" == FAIL ]]
[[ "$control_target" == 'https://cloudflare-quic.com/' ]]

printf 'PASS: QUIC probe requires HTTP/3-only and distinguishes target failure from unavailable control\n'
