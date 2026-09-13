#!/usr/bin/env bash
set -euo pipefail

PROFILE="${ZF_VM_PROFILE:?}"
RUN_DIR="${ZF_VM_RUN_DIR:?}"
SOURCE_DIR="$RUN_DIR/source"
ARTIFACT_DIR="$RUN_DIR/artifacts"
FIXTURE_BIN="$RUN_DIR/fixture-bin"
NO_NFT_BIN="$RUN_DIR/no-nft-bin"
COMMAND_PATH=""
FAILURE_CAPTURED=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

capture_failure() {
    (( FAILURE_CAPTURED == 0 )) || return 0
    FAILURE_CAPTURED=1
    set +e
    install -d -m 0700 "$ARTIFACT_DIR"
    uname -a > "$ARTIFACT_DIR/uname.txt" 2>&1
    cp /etc/os-release "$ARTIFACT_DIR/os-release.txt" 2>/dev/null
    systemctl status zapret --no-pager > "$ARTIFACT_DIR/systemctl-status.txt" 2>&1
    systemctl is-enabled zapret > "$ARTIFACT_DIR/systemctl-enabled.txt" 2>&1
    journalctl -u zapret --no-pager > "$ARTIFACT_DIR/journal.txt" 2>&1
    ls -ldZ /opt/zapret /opt/zapret/init.d /opt/zapret/init.d/sysv /opt/zapret/init.d/sysv/zapret \
        > "$ARTIFACT_DIR/selinux-contexts.txt" 2>&1
    ps -ef > "$ARTIFACT_DIR/processes.txt" 2>&1
    for proc in /proc/[0-9]*; do
        [[ "$(readlink "$proc/exe" 2>/dev/null)" == /opt/zapret/nfq/nfqws ]] || continue
        tr '\0' ' ' < "$proc/cmdline"
        printf '\n'
    done > "$ARTIFACT_DIR/nfqws-argv.txt" 2>&1
    nft list ruleset > "$ARTIFACT_DIR/nft-ruleset.txt" 2>&1
    iptables-save > "$ARTIFACT_DIR/iptables-save.txt" 2>&1
    ip6tables-save > "$ARTIFACT_DIR/ip6tables-save.txt" 2>&1
    cp /proc/net/netfilter/nfnetlink_queue "$ARTIFACT_DIR/nfnetlink-queue.txt" 2>/dev/null
    cp "$RUN_DIR/doctor.txt" "$ARTIFACT_DIR/doctor.txt" 2>/dev/null
}

cleanup_guest() {
    systemctl stop zapret >/dev/null 2>&1 || true
    systemctl disable zapret >/dev/null 2>&1 || true
    if command -v nft >/dev/null 2>&1 && nft list table inet zapret >/dev/null 2>&1; then
        nft delete table inet zapret >/dev/null 2>&1 || true
    fi
    if [[ -f /opt/zapret/nfq/nfqws ]]; then
        printf 'y\n' | env PATH="${COMMAND_PATH:-$PATH}" /usr/local/bin/sonar uninstall >/dev/null 2>&1 || true
    fi
}

on_exit() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 )); then
        capture_failure
        cleanup_guest
    fi
    exit "$rc"
}
trap on_exit EXIT

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] || fail "$message (expected=$expected actual=$actual)"
}

assert_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "path must be absent: $1"
}

prepare_curl_fixture() {
    install -d -m 0755 "$FIXTURE_BIN"
    install -m 0755 "$SOURCE_DIR/tests/vm/curl-fixture.sh" "$FIXTURE_BIN/curl"
    COMMAND_PATH="$FIXTURE_BIN:$PATH"
}

prepare_iptables_legacy() {
    update-alternatives --set iptables /usr/sbin/iptables-legacy
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
    iptables --version | grep -q legacy
    install -d -m 0755 "$NO_NFT_BIN"
    local directory executable name
    for directory in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
        [[ -d "$directory" ]] || continue
        for executable in "$directory"/*; do
            [[ -x "$executable" && ! -d "$executable" ]] || continue
            name=${executable##*/}
            [[ "$name" != nft && "$name" != ipset && "$name" != curl ]] || continue
            [[ -e "$NO_NFT_BIN/$name" ]] || ln -s "$executable" "$NO_NFT_BIN/$name"
        done
    done
    ln -s "$FIXTURE_BIN/curl" "$NO_NFT_BIN/curl"
    COMMAND_PATH="$NO_NFT_BIN"

    local output rc
    set +e
    output=$(env PATH="$COMMAND_PATH" bash "$SOURCE_DIR/install.sh" --dry-run 2>&1)
    rc=$?
    set -e
    (( rc != 0 )) || fail 'iptables preflight accepted missing ipset'
    [[ "$output" == *'для iptables backend нужна утилита ipset'* ]] || fail 'iptables preflight failed for an unexpected reason'
    ln -s "$(command -v ipset)" "$NO_NFT_BIN/ipset"
}

run_command() {
    local command="$1"
    shift
    [[ "$command" != sonar ]] || command=/usr/local/bin/sonar
    env PATH="$COMMAND_PATH" "$command" "$@"
}

install_project() {
    (cd "$SOURCE_DIR" && \
        ZF_VM_INPUT_DIR="$ZF_VM_INPUT_DIR" \
        ZF_VM_UPSTREAM_MANIFEST="$SOURCE_DIR/tests/vm/upstream.tsv" \
        run_command bash ./install.sh --non-interactive)
}

nfqws_pids() {
    local proc exe comm
    for proc in /proc/[0-9]*; do
        exe=$(readlink "$proc/exe" 2>/dev/null || true)
        comm=$(cat "$proc/comm" 2>/dev/null || true)
        [[ "$exe" == /opt/zapret/nfq/nfqws || "$exe" == '/opt/zapret/nfq/nfqws (deleted)' || "$comm" == nfqws ]] || continue
        printf '%s\n' "${proc##*/}"
    done
}

assert_layout() {
    [[ -x /opt/zapret/nfq/nfqws ]] || fail 'nfqws is not installed'
    [[ -L /opt/zapret/zapret-sonar/current ]] || fail 'versioned current link is missing'
    assert_eq releases/1.4.0 "$(readlink /opt/zapret/zapret-sonar/current)" 'unexpected current release target'
    [[ -f /etc/systemd/system/zapret.service ]] || fail 'systemd unit is missing'
    local link
    for link in zapret-sonar sonar zapret-sonar-tui sonar-tui; do
        [[ -L "/usr/local/bin/$link" ]] || fail "command link is missing: $link"
    done
    [[ -z "$(find /opt/zapret ! -user root -print -quit)" ]] || fail '/opt/zapret contains non-root-owned paths'
}

assert_validate() {
    local result
    result=$(run_command sonar validate --json)
    jq -e '.ok == true and .summary == {total: 22, passed: 22, failed: 0}' <<< "$result" >/dev/null \
        || fail 'validate JSON summary is not 22/22'
}

assert_running() {
    assert_eq active "$(systemctl is-active zapret)" 'zapret service is not active'
    local pids
    pids=$(nfqws_pids)
    assert_eq 1 "$(wc -w <<< "$pids")" 'expected exactly one installed nfqws process'
    grep -Eq '(^|/)system\.slice/zapret\.service$' "/proc/$pids/cgroup" \
        || fail 'nfqws process is not tracked in the zapret service cgroup'
    tr '\0' ' ' < "/proc/$pids/cmdline" | grep -Eq -- '(^| )--qnum(=| )200( |$)' \
        || fail 'nfqws does not use queue 200'
    run_command sonar doctor | tee "$RUN_DIR/doctor.txt" || {
        nft list tables >&2 || true
        nft list table inet zapret >&2 || true
        nft list chain inet zapret postnat >&2 || true
        nft list chain inet zapret postnat_hook >&2 || true
        nft list chain inet zapret prenat >&2 || true
        fail 'doctor rejected the active firewall state'
    }
    if [[ "$PROFILE" == ubuntu-iptables-legacy ]]; then
        local chain protocol
        for chain in POSTROUTING INPUT FORWARD; do
            for protocol in tcp udp; do
                assert_eq 1 "$(iptables-save | awk -v chain="$chain" -v protocol="$protocol" '$1 == "-A" && $2 == chain && $3 == "-p" && $4 == protocol && $0 ~ /-j NFQUEUE/ && $0 ~ /--queue-num 200([[:space:]]|$)/ { count++ } END { print count+0 }')" \
                    "unexpected iptables NFQUEUE rule count for $chain/$protocol"
            done
        done
    else
        local chain protocol
        for chain in postnat prenat; do
            for protocol in tcp udp; do
                assert_eq 1 "$(nft list chain inet zapret "$chain" | awk -v protocol="$protocol" '$1 == protocol && $0 ~ /queue/ && $0 ~ /to 200([[:space:]]|$)/ { count++ } END { print count+0 }')" \
                    "unexpected nftables NFQUEUE rule count for $chain/$protocol"
            done
        done
    fi
}

user_lists_hash() {
    local list_file
    list_file=$(find /opt/zapret/flowseal-current/lists -type f -name '*-user.txt' -print -quit)
    [[ -n "$list_file" ]] || fail 'no user list exists'
    find /opt/zapret/flowseal-current/lists -type f -name '*-user.txt' -print0 \
        | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
}

assert_state_preserved() {
    local strategy="$1" lists_hash="$2" expected_active="$3" expected_enabled="$4"
    assert_eq "$strategy" "$(sed -n 's/^# zapret-sonar-strategy: //p' /opt/zapret/config | head -1)" 'strategy changed after reinstall'
    assert_eq "$lists_hash" "$(user_lists_hash)" 'user lists changed after reinstall'
    assert_eq "$expected_active" "$(systemctl is-active zapret 2>/dev/null || true)" 'active state changed after reinstall'
    assert_eq "$expected_enabled" "$(systemctl is-enabled zapret 2>/dev/null || true)" 'autostart state changed after reinstall'
}

assert_uninstalled() {
    [[ -z "$(nfqws_pids)" ]] || fail 'nfqws process remains after uninstall'
    assert_absent /opt/zapret
    assert_absent /etc/systemd/system/zapret.service
    local link
    for link in zapret-sonar sonar zapret-sonar-tui sonar-tui; do
        assert_absent "/usr/local/bin/$link"
    done
    if [[ "$PROFILE" == ubuntu-iptables-legacy ]]; then
        [[ -z "$(iptables-save | grep 'NFQUEUE.*--queue-num 200' || true)" ]] || fail 'iptables NFQUEUE rules remain after uninstall'
        [[ -z "$(ip6tables-save | grep -E 'zapret|NFQUEUE' || true)" ]] || fail 'IPv6 zapret rules remain after uninstall'
        [[ -z "$(iptables-save | grep -E 'zapret|NFQUEUE' || true)" ]] || fail 'IPv4 zapret chains or jumps remain after uninstall'
        local name
        for name in zapret zapret6 ipban ipban6 nozapret nozapret6; do
            ! ipset list "$name" >/dev/null 2>&1 || fail "ipset remains after uninstall: $name"
        done
    else
        ! nft list table inet zapret >/dev/null 2>&1 || fail 'nftables table remains after uninstall'
    fi
}

main() {
    (( EUID == 0 )) || fail 'guest runner requires root'
    [[ -d "${ZF_VM_INPUT_DIR:?}" ]] || fail 'verified VM input directory is missing'
    [[ "${1:-}" == lifecycle ]] || fail 'guest phase must be lifecycle'
    if [[ "$PROFILE" == fedora-nft ]]; then
        command -v getenforce >/dev/null || fail 'Fedora SELinux status command is unavailable'
        assert_eq Enforcing "$(getenforce)" 'Fedora SELinux must remain enforcing'
    fi
    prepare_curl_fixture
    [[ "$PROFILE" == ubuntu-iptables-legacy ]] && prepare_iptables_legacy

    install_project
    assert_layout
    run_command sonar use general.bat
    assert_eq general.bat "$(sed -n 's/^# zapret-sonar-strategy: //p' /opt/zapret/config | head -1)" 'use selected an unexpected strategy'
    [[ -f /opt/zapret/.zapret-sonar-firewall ]] || fail 'firewall ownership marker is missing after apply'
    run_command sonar enable
    assert_validate
    assert_running

    local first_pid second_pid strategy lists_hash user_list
    first_pid=$(nfqws_pids)
    run_command sonar restart
    second_pid=$(nfqws_pids)
    [[ "$first_pid" != "$second_pid" ]] || fail 'restart did not replace the nfqws PID'
    assert_running

    user_list=$(find /opt/zapret/flowseal-current/lists -type f -name '*-user.txt' -print -quit)
    printf 'vm-harness.example\n' >> "$user_list"
    strategy=$(sed -n 's/^# zapret-sonar-strategy: //p' /opt/zapret/config | head -1)
    lists_hash=$(user_lists_hash)

    install_project
    assert_state_preserved "$strategy" "$lists_hash" active enabled
    assert_running

    run_command sonar stop
    run_command sonar disable
    install_project
    assert_state_preserved "$strategy" "$lists_hash" inactive disabled

    run_command sonar start
    run_command sonar enable
    assert_running
    printf 'y\n' | run_command sonar uninstall
    assert_uninstalled
    printf 'PASS: guest lifecycle %s\n' "$PROFILE"
}

main "$@"
