#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export ZF_LIBRARY_MODE=1
export ZF_ZAPRET_BASE="$TEST_DIR/zapret"
export ZF_RUNTIME_DIR="$TEST_DIR/run"
export ZF_UPDATE_CACHE_DIR="$TEST_DIR/cache"
mkdir -p "$ZF_ZAPRET_BASE/nfq" "$ZF_RUNTIME_DIR"
printf '#!/usr/bin/env bash\nprintf "github version v72.13 (test)\\n"\n' > "$ZF_ZAPRET_BASE/nfq/nfqws"
chmod +x "$ZF_ZAPRET_BASE/nfq/nfqws"
printf '1.10.2\n' > "$ZF_ZAPRET_BASE/.flowseal-version"

# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"

victim="$TEST_DIR/victim"
printf 'keep-me\n' > "$victim"
ln -s "$victim" "$ZF_RUNTIME_DIR/operations.lock"
if ( _zf_lock ) 2>/dev/null; then
    printf 'FAIL: symlink lock was accepted\n' >&2
    exit 1
fi
[[ "$(cat "$victim")" == "keep-me" ]]
rm "$ZF_RUNTIME_DIR/operations.lock"
printf 'PASS: lock rejects symlinks without truncating the target\n'

mkdir -p "$ZF_UPDATE_CACHE_DIR"
marker="$TEST_DIR/executed"
cat > "$ZF_UPDATE_CACHE_DIR/update-check" <<EOF
check_state=ok
flowseal_local=1.10.2
flowseal_remote=1.10.2
zapret_local=v72.13
zapret_remote=v72.13
sonar_remote=1.2.2
last_check=slot[\$(touch $marker)]
EOF
chmod 600 "$ZF_UPDATE_CACHE_DIR/update-check"
_zf_do_update_check() { :; }
[[ "$(_zf_update_status)" == "актуально" ]]
[[ ! -e "$marker" ]]
printf 'PASS: malicious cache timestamp is not evaluated\n'

printf '1.10.3\n' > "$ZF_ZAPRET_BASE/.flowseal-version"
[[ "$(_zf_update_status)" == 'актуально' ]]
printf '1.10.2\n' > "$ZF_ZAPRET_BASE/.flowseal-version"
printf 'PASS: cached remote versions do not downgrade newer local state\n'

[[ "$(_zf_version_is_newer 1.10.3 main && printf yes || printf no)" == yes ]]
[[ "$(_zf_version_is_newer 1.10.3 1.10.2 && printf yes || printf no)" == yes ]]
[[ "$(_zf_version_is_newer 1.10.2 1.10.3 && printf yes || printf no)" == no ]]
[[ "$(_zf_version_is_newer 1.10.3 1.10.3-beta && printf yes || printf no)" == yes ]]
[[ "$(_zf_version_is_newer 1.10.3-beta 1.10.3 && printf yes || printf no)" == no ]]
[[ "$(_zf_version_is_newer 1.10.3-rc1 1.10.3-beta2 && printf yes || printf no)" == no ]]
printf 'PASS: release versions supersede fallback state without downgrades\n'

escaped=$(_zf_json_escape $'a\tb\rc\001d')
[[ "$escaped" == 'a\tb\rc\u0001d' ]]
printf '"%s"\n' "$escaped" | jq -e . >/dev/null
printf 'PASS: JSON control characters are escaped\n'

curl() { printf '451|0'; }
set +e
zf_check_media 'https://example.test/file|1||0' >/dev/null
media_rc=$?
set -e
if (( media_rc != 1 )); then
    printf 'FAIL: HTTP 451 was not treated as failure\n' >&2
    exit 1
fi
unset -f curl
printf 'PASS: HTTP 451 is treated as a failed check\n'

rm -f "$ZF_UPDATE_CACHE_DIR/update-check"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
sleep 1
case "$*" in
    *Flowseal*) printf '{"tag_name":"1.10.2"}\n' ;;
    *zapret-sonar*) printf '{"tag_name":"v1.4.0"}\n' ;;
    *) printf '{"tag_name":"v72.13"}\n' ;;
esac
EOF
chmod +x "$TEST_DIR/bin/curl"
export PATH="$TEST_DIR/bin:$PATH"
start=$(date +%s%N)
[[ "$(_zf_update_status)" == "проверка…" ]]
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
(( elapsed < 500 ))
for _ in {1..30}; do
    [[ -f "$ZF_UPDATE_CACHE_DIR/update-check" ]] && break
    sleep 0.2
done
[[ "$(_zf_update_status)" == "актуально" ]]
printf 'PASS: cold-cache update check is asynchronous\n'
