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

out="" url="" location=0 max_redirs="" proto="" proto_redir=""
while (( $# )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -L) location=1; shift ;;
        --max-redirs) max_redirs="$2"; shift 2 ;;
        --proto) proto="$2"; shift 2 ;;
        --proto-redir) proto_redir="$2"; shift 2 ;;
        -m|-r|-w) shift 2 ;;
        -s) shift ;;
        -*) exit 64 ;;
        *) url="$1"; shift ;;
    esac
done

printf '%s|%s|%s|%s|%s\n' "$url" "$location" "$max_redirs" "$proto" "$proto_redir" > "${ZF_CURL_ARGS:?}"
case "${ZF_CURL_MODE:-pass}" in
    pass)
        dd if=/dev/zero of="$out" bs=500001 count=1 status=none
        printf '206|409600'
        ;;
    stale) printf '410|0' ;;
    fail) printf '503|0' ;;
    *) exit 65 ;;
esac
EOF
chmod +x "$fake_bin/curl"

export PATH="$fake_bin:$PATH"
export ZF_CURL_ARGS="$TEST_DIR/curl-args"

# shellcheck source=../lib/health.sh
source "$PROJECT_DIR/lib/health.sh"

speed_spec="${ZF_HEALTH_MEDIA[2]}"
[[ "$speed_spec" == 'https://discord.com/api/download?platform=linux&format=tar.gz|500000||200' ]]

output=$(ZF_CURL_MODE=pass zf_check_media "$speed_spec")
[[ "$output" == *'тест скорости пройден'* ]]
IFS='|' read -r url location max_redirs proto proto_redir < "$ZF_CURL_ARGS"
[[ "$url" == 'https://discord.com/api/download?platform=linux&format=tar.gz' ]]
[[ "$location" == 1 && "$max_redirs" == 3 && "$proto" == '=https' && "$proto_redir" == '=https' ]]

set +e
output=$(ZF_CURL_MODE=stale zf_check_media "$speed_spec"); rc=$?
set -e
(( rc == 2 ))
[[ "$output" == *'SKIP'* && "$output" == *'HTTP 410'* ]]

set +e
output=$(ZF_CURL_MODE=fail zf_check_media "$speed_spec"); rc=$?
set -e
(( rc == 1 ))
[[ "$output" == *'FAIL'* && "$output" == *'HTTP 503'* ]]

printf 'PASS: Discord media target follows bounded HTTPS redirects and preserves PASS/FAIL/SKIP semantics\n'
