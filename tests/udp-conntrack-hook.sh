#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export ZF_LIBRARY_MODE=1
export ZF_ZAPRET_BASE="$TEST_DIR/zapret"
export ZF_ZAPRET_CONFIG="$ZF_ZAPRET_BASE/config"
custom_dir="$ZF_ZAPRET_BASE/init.d/sysv/custom.d"
mkdir -p "$custom_dir"

# shellcheck source=../lib/zconfig.sh
source "$PROJECT_DIR/lib/zconfig.sh"

hook=$(zf_udp_conntrack_hook_path)
[[ "$hook" == "$custom_dir/50-sonar-udp-conntrack" ]]

zf_write_udp_conntrack_hook
[[ -f "$hook" && ! -L "$hook" ]]
[[ "$(stat -c %a "$hook")" == 644 ]]
bash -n "$hook"

# Правило обязано возвращать tracking только UDP, только IPv4 и только
# нефрагментированным пакетам: TCP/ipfrag зависят от notrack по другой причине.
grep -q 'zapret_custom_firewall_nft()' "$hook"
grep -q 'meta nfproto ipv4 meta l4proto udp' "$hook"
grep -q 'ip frag-off and 0x3fff == 0' "$hook"
grep -q 'sonar-udp-conntrack' "$hook"
grep -q 'DESYNC_MARK_POSTNAT' "$hook"
rule=$(sed -n '/nft insert rule/,/sonar-udp-conntrack/p' "$hook")
grep -q 'return' <<< "$rule"
if grep -q 'notrack' <<< "$rule"; then
    printf 'FAIL: hook rule must not touch notrack\n' >&2
    exit 1
fi
printf 'PASS: hook has the expected UDP-only rule\n'

# Идемпотентность: повторный вызов не меняет файл и не оставляет temp-файлов.
before=$(sha256sum "$hook")
zf_write_udp_conntrack_hook
[[ "$(sha256sum "$hook")" == "$before" ]]
[[ "$(find "$custom_dir" -maxdepth 1 -type f | wc -l)" == 1 ]]
printf 'PASS: hook rewrite is idempotent\n'

# Перегенерация конфига восстанавливает удалённый хук: иначе следующая смена
# стратегии молча оставила бы UDP без conntrack-совместимости.
rm -f "$hook"
printf '# zapret-sonar-strategy: old.bat\n' > "$ZF_ZAPRET_CONFIG"
# zf_write_config читает эти переменные из zf_translate.
# shellcheck disable=SC2034
ZF_OPT='--filter-tcp=443 --dpi-desync=fake'
# shellcheck disable=SC2034
ZF_PORTS_TCP=443
# shellcheck disable=SC2034
ZF_PORTS_UDP=""
zf_write_config 'general.bat' off none
[[ -f "$hook" ]]
printf 'PASS: config regeneration restores the hook\n'

# Симлинк на месте хука отклоняется: файл читается root-процессом zapret.
rm -f "$hook"
ln -s "$TEST_DIR/elsewhere" "$hook"
if zf_write_udp_conntrack_hook; then
    printf 'FAIL: symlinked hook must be rejected\n' >&2
    exit 1
fi
rm -f "$hook"
printf 'PASS: symlinked hook is rejected\n'

# Отсутствие custom.d не ломает запись конфига: предупреждение, а не откат.
rm -rf "$custom_dir"
if zf_write_config 'general.bat' off none; then :; else
    printf 'FAIL: config write must survive a missing custom.d\n' >&2
    exit 1
fi
[[ -f "$ZF_ZAPRET_CONFIG" ]]
printf 'PASS: missing custom.d does not break config generation\n'
