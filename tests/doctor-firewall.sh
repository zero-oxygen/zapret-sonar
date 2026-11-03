#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    exec sudo -n -- env HOME=/root bash "$0"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export ZF_LIBRARY_MODE=1
export ZF_ZAPRET_BASE="$TEST_DIR/zapret"
export ZF_ZAPRET_CONFIG="$ZF_ZAPRET_BASE/config"
export ZF_RUNTIME_DIR="$TEST_DIR/run"
export ZF_UPDATE_CACHE_DIR="$TEST_DIR/cache"
tree="$ZF_ZAPRET_BASE/flowseal-current"
mkdir -p "$tree/strategies" "$tree/bin" "$tree/lists" "$ZF_ZAPRET_BASE/nfq" "$ZF_RUNTIME_DIR"
printf '@echo off\n"%%BIN%%winws.exe" --wf-tcp=443 --dpi-desync=fake\n' > "$tree/strategies/general.bat"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ZF_ZAPRET_BASE/nfq/nfqws"
chmod +x "$ZF_ZAPRET_BASE/nfq/nfqws"
printf '# zapret-sonar-strategy: general.bat\n# zapret-sonar-gamefilter: off\n# zapret-sonar-ipset: none\nFWTYPE=nftables\n' > "$ZF_ZAPRET_CONFIG"

# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"
systemctl() { [[ "$1" == is-active ]] && printf 'active\n'; }
nft() { return 1; }
iptables-save() { return 1; }
_zf_nfqws_uses_queue() { return 0; }

set +e
output=$(cmd_doctor 2>&1)
rc=$?
set -e
if (( EUID == 0 )); then
    (( rc == 1 ))
    [[ "$output" == *'FAIL (не удалось прочитать nftables rules)'* ]]
else
    (( rc == 0 ))
    [[ "$output" == *'Перехват трафика: SKIP (firewall rules требуют root)'* ]]
fi
printf 'PASS: doctor handles unavailable nftables interception correctly\n'

test_root_firewall() {
    if (( EUID != 0 )); then
        printf 'SKIP: root doctor firewall checks need root (run with sudo)\n'
        return 0
    fi
    printf '# zapret-sonar-strategy: general.bat\n# zapret-sonar-gamefilter: off\n# zapret-sonar-ipset: none\nFWTYPE="nftables"\nQNUM=200\nZAPRET_NFT_TABLE="zapret"\n' > "$ZF_ZAPRET_CONFIG"
    mkdir -p "$ZF_ZAPRET_BASE/init.d/sysv/custom.d"
    zf_write_udp_conntrack_hook
    nft() {
        case "$*" in
            *postnat_hook) printf 'type filter hook postrouting priority srcnat + 1; jump postnat\n' ;;
            *postnat) printf 'udp queue flags bypass to 200\ntcp queue flags bypass to 200\n' ;;
            *prenat) printf 'type filter hook prerouting priority dstnat - 1; udp queue flags bypass to 200\ntcp queue flags bypass to 200\n' ;;
            *predefrag_nfqws) printf 'udp return comment "sonar-udp-conntrack"\nmark notrack comment "postnat traffic"\n' ;;
        esac
    }
    output=$(cmd_doctor 2>&1)
    [[ "$output" == *'OK (nftables, NFQUEUE 200'* ]]
    [[ "$output" == *'UDP conntrack'* ]]

    # Файл хука на месте, но правило не применилось: это отдельный диагноз,
    # иначе потеря workaround выглядела бы как исправная установка.
    nft() {
        case "$*" in
            *postnat_hook) printf 'type filter hook postrouting priority srcnat + 1; jump postnat\n' ;;
            *postnat) printf 'udp queue flags bypass to 200\ntcp queue flags bypass to 200\n' ;;
            *prenat) printf 'type filter hook prerouting priority dstnat - 1; udp queue flags bypass to 200\ntcp queue flags bypass to 200\n' ;;
            *predefrag_nfqws) printf 'mark notrack comment "postnat traffic"\n' ;;
        esac
    }
    set +e
    output=$(cmd_doctor 2>&1); rc=$?
    set -e
    (( rc == 1 ))
    [[ "$output" == *'FAIL (UDP conntrack hook есть, но не применён'* ]]

    # Ни файла, ни правила: конфиг управляется sonar, значит хук просто не
    # создан (старая установка или ручное удаление).
    rm -f "$(zf_udp_conntrack_hook_path)"
    set +e
    output=$(cmd_doctor 2>&1); rc=$?
    set -e
    (( rc == 1 ))
    [[ "$output" == *'FAIL (нет UDP conntrack hook'* ]]

    # Правило есть, но стоит после notrack: оно бесполезно, и doctor обязан
    # отличать это от исправной установки.
    zf_write_udp_conntrack_hook
    nft() {
        case "$*" in
            *postnat_hook) printf 'type filter hook postrouting priority srcnat + 1; jump postnat\n' ;;
            *postnat) printf 'udp queue flags bypass to 200\ntcp queue flags bypass to 200\n' ;;
            *prenat) printf 'type filter hook prerouting priority dstnat - 1; udp queue flags bypass to 200\ntcp queue flags bypass to 200\n' ;;
            *predefrag_nfqws) printf 'mark notrack comment "postnat traffic"\nudp return comment "sonar-udp-conntrack"\n' ;;
        esac
    }
    set +e
    output=$(cmd_doctor 2>&1); rc=$?
    set -e
    (( rc == 1 ))
    [[ "$output" == *'FAIL (UDP conntrack hook стоит после notrack'* ]]

    # POSTNAT не используется (нет notrack): правило не требуется, это SKIP,
    # а не ложная ошибка вечного «перезапустите сервис».
    nft() {
        case "$*" in
            *postnat_hook) printf 'type filter hook postrouting priority srcnat + 1; jump postnat\n' ;;
            *postnat) printf 'udp queue flags bypass to 200\ntcp queue flags bypass to 200\n' ;;
            *prenat) printf 'type filter hook prerouting priority dstnat - 1; udp queue flags bypass to 200\ntcp queue flags bypass to 200\n' ;;
            *predefrag_nfqws) printf '\n' ;;
        esac
    }
    output=$(cmd_doctor 2>&1)
    [[ "$output" == *'SKIP (POSTNAT не используется)'* ]]

    nft() {
        case "$*" in
            *postnat_hook) printf 'type filter hook postrouting priority srcnat + 1; jump postnat\n' ;;
            *postnat) printf 'udp queue flags bypass to 200\ntcp queue flags bypass to 200\n' ;;
            *prenat) printf 'type filter hook prerouting priority dstnat - 1; udp queue flags bypass to 200\ntcp queue flags bypass to 200\n' ;;
            *predefrag_nfqws) printf 'udp return comment "sonar-udp-conntrack"\nmark notrack comment "postnat traffic"\n' ;;
        esac
    }
    zf_write_udp_conntrack_hook

    nft() {
        case "$*" in
            *postnat_hook) printf 'type filter hook postrouting priority srcnat + 1; jump postnat\n' ;;
            *postnat) printf 'udp queue flags bypass to 2000\ntcp queue flags bypass to 2000\n' ;;
            *prenat) printf 'type filter hook prerouting priority dstnat - 1; udp queue flags bypass to 2000\ntcp queue flags bypass to 2000\n' ;;
        esac
    }
    set +e
    output=$(cmd_doctor 2>&1); rc=$?
    set -e
    (( rc == 1 ))
    [[ "$output" == *'FAIL (неполный nftables NFQUEUE 200:'* ]]

    printf '# zapret-sonar-strategy: general.bat\n# zapret-sonar-gamefilter: off\n# zapret-sonar-ipset: none\nFWTYPE=iptables\nQNUM=200\n' > "$ZF_ZAPRET_CONFIG"
    iptables-save() { return 1; }
    set +e
    output=$(cmd_doctor 2>&1); rc=$?
    set -e
    (( rc == 1 ))
    [[ "$output" == *'FAIL (не удалось прочитать iptables rules)'* ]]

    iptables-save() {
        printf '%s\n' \
            '-A POSTROUTING -p tcp -j NFQUEUE --queue-num 200 --queue-bypass' \
            '-A POSTROUTING -p udp -j NFQUEUE --queue-num 200 --queue-bypass' \
            '-A INPUT -p tcp -j NFQUEUE --queue-num 200 --queue-bypass' \
            '-A INPUT -p udp -j NFQUEUE --queue-num 200 --queue-bypass' \
            '-A FORWARD -p tcp -j NFQUEUE --queue-num 200 --queue-bypass' \
            '-A FORWARD -p udp -j NFQUEUE --queue-num 200 --queue-bypass'
    }
    output=$(cmd_doctor 2>&1)
    [[ "$output" == *'OK (iptables, NFQUEUE 200)'* ]]

    iptables-save() {
        printf '%s\n' \
            '-A POSTROUTING -p tcp -j NFQUEUE --queue-num 2000 --queue-bypass' \
            '-A POSTROUTING -p udp -j NFQUEUE --queue-num 2000 --queue-bypass' \
            '-A INPUT -p tcp -j NFQUEUE --queue-num 2000 --queue-bypass' \
            '-A INPUT -p udp -j NFQUEUE --queue-num 2000 --queue-bypass' \
            '-A FORWARD -p tcp -j NFQUEUE --queue-num 2000 --queue-bypass' \
            '-A FORWARD -p udp -j NFQUEUE --queue-num 2000 --queue-bypass'
    }
    set +e
    output=$(cmd_doctor 2>&1); rc=$?
    set -e
    (( rc == 1 ))
    [[ "$output" == *'FAIL (неполный iptables NFQUEUE 200)'* ]]
    printf 'PASS: root doctor validates exact nftables and iptables queue numbers\n'
}
test_root_firewall
