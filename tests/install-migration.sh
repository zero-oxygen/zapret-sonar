#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    exec sudo -n -- bash "$0"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export ZF_INSTALL_LIBRARY_MODE=1
export ZAPRET_BASE="$TEST_DIR/zapret"
export BIN_DEST="$TEST_DIR/bin-dest"
export SERVICE_NAME=zapret-test
export ZF_RUNTIME_DIR="$TEST_DIR/run"
mkdir -p "$ZAPRET_BASE/flowseal-strategies" "$ZAPRET_BASE/flowseal-bin" \
    "$ZAPRET_BASE/flowseal-lists" "$ZAPRET_BASE/zapret-sonar" "$ZAPRET_BASE/nfq" "$BIN_DEST" "$ZF_RUNTIME_DIR"
printf '# zapret-sonar-strategy: general.bat\n# zapret-sonar-gamefilter: off\n# zapret-sonar-ipset: none\nNFQWS_OPT="--hostlist=%s/flowseal-lists/list-general.txt"\n' \
    "$ZAPRET_BASE" > "$ZAPRET_BASE/config"
printf 'user.example\n' > "$ZAPRET_BASE/flowseal-lists/list-general-user.txt"

mkdir -p "$TEST_DIR/source/bin" "$TEST_DIR/source/lists"
printf '@echo off\n"%%BIN%%winws.exe" --wf-tcp=443 --dpi-desync=fake\n' > "$TEST_DIR/source/general.bat"
: > "$TEST_DIR/source/bin/fake.bin"
printf '203.0.113.113/32\n' > "$TEST_DIR/source/lists/ipset-all.txt"
cat > "$ZAPRET_BASE/nfq/nfqws" <<EOF
#!/usr/bin/env bash
printf 'called\n' > "$TEST_DIR/nfqws-called"
exit 1
EOF
chmod +x "$ZAPRET_BASE/nfq/nfqws"

# shellcheck source=../install.sh
source "$PROJECT_DIR/install.sh"
chown() { :; }
acquire_install_lock
install_flowseal "$TEST_DIR/source"
[[ -d "$ZAPRET_BASE/flowseal-lists" ]]

cat > "$ZAPRET_BASE/zapret-sonar/zapret-sonar" <<EOF
#!/usr/bin/env bash
exec env ZF_ZAPRET_BASE="$ZAPRET_BASE" ZF_RUNTIME_DIR="$ZF_RUNTIME_DIR" \\
    "$PROJECT_DIR/zapret-sonar" "\$@"
EOF
chmod +x "$ZAPRET_BASE/zapret-sonar/zapret-sonar"
if ( rebuild_existing_config ) >/dev/null 2>&1; then
    printf 'FAIL: installer accepted a failed real _render process\n' >&2
    exit 1
fi
[[ -d "$ZAPRET_BASE/flowseal-lists" ]]
[[ ! -e "$ZAPRET_BASE/flowseal-current" ]]
(( EUID != 0 )) || [[ -f "$TEST_DIR/nfqws-called" ]]
printf 'PASS: failed real _render preserves legacy directories\n'

install_flowseal "$TEST_DIR/source"
cat > "$ZAPRET_BASE/zapret-sonar/zapret-sonar" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ "$1" == _render && "$2" == general.bat ]]
cat > "$ZAPRET_BASE/config" <<CONFIG
# zapret-sonar-strategy: general.bat
# zapret-sonar-gamefilter: off
# zapret-sonar-ipset: none
NFQWS_OPT="--hostlist=$ZAPRET_BASE/flowseal-current/lists/list-general.txt"
CONFIG
EOF
chmod +x "$ZAPRET_BASE/zapret-sonar/zapret-sonar"
export ZAPRET_BASE

rebuild_existing_config
[[ -d "$ZAPRET_BASE/flowseal-lists" ]]
grep -Fq "$ZAPRET_BASE/flowseal-current/lists" "$ZAPRET_BASE/config"
finalize_flowseal_install
[[ ! -e "$ZAPRET_BASE/flowseal-lists" ]]
[[ "$(cat "$ZAPRET_BASE/.flowseal-version")" == 1.10.2 ]]
[[ "$(cat "$ZAPRET_BASE/flowseal-current/lists/list-general-user.txt")" == user.example ]]

printf 'PASS: legacy directories are removed only after config rebuild\n'

rollback_root="$TEST_DIR/rollback-case"
mkdir -p "$rollback_root/zapret" "$rollback_root/bin" "$rollback_root/staging"
printf 'old-base\n' > "$rollback_root/zapret/marker"
ln -s /old/target "$rollback_root/bin/sonar"
# shellcheck disable=SC2034
ZAPRET_BASE="$rollback_root/zapret"
BIN_DEST="$rollback_root/bin"
# shellcheck disable=SC2034
STAGING="$rollback_root/staging"
INSTALL_UNIT="$rollback_root/zapret.service"
# shellcheck disable=SC2034
INSTALL_STARTED=0
# shellcheck disable=SC2034
INSTALL_COMMITTED=0
# shellcheck disable=SC2034
INSTALL_HAD_BASE=0
# shellcheck disable=SC2034
INSTALL_SERVICE_ACTIVE=0
printf 'old-unit\n' > "$INSTALL_UNIT"
backup_current_install
printf 'new-base\n' > "$ZAPRET_BASE/marker"
ln -sfn /new/target "$BIN_DEST/sonar"
printf 'new-unit\n' > "$INSTALL_UNIT"
systemctl() { :; }
rollback_install
[[ "$(cat "$ZAPRET_BASE/marker")" == old-base ]]
[[ "$(readlink "$BIN_DEST/sonar")" == /old/target ]]
[[ "$(cat "$INSTALL_UNIT")" == old-unit ]]
printf 'PASS: installer rollback restores base, command links and unit\n'

restore_calls=()
getenforce() { printf 'Enforcing\n'; }
restorecon() { restore_calls+=("$*"); }
ZAPRET_BASE="$TEST_DIR/selinux-zapret"
INSTALL_UNIT="$TEST_DIR/selinux-zapret.service"
restore_security_contexts
[[ "${restore_calls[0]}" == "-R -x $ZAPRET_BASE" ]]
[[ "${restore_calls[1]}" == "$INSTALL_UNIT" ]]
restore_calls=()
getenforce() { printf 'Disabled\n'; }
restore_security_contexts
(( ${#restore_calls[@]} == 0 ))
printf 'PASS: installer restores labels only when SELinux is active\n'

layout_root="$TEST_DIR/layout-case"
mkdir -p "$layout_root/zapret" "$layout_root/bin"
ZAPRET_BASE="$layout_root/zapret"
BIN_DEST="$layout_root/bin"
SERVICE_NAME=zapret-layout
install_flow
[[ -x "$ZAPRET_BASE/zapret-sonar/zapret-sonar" ]]
[[ -x "$ZAPRET_BASE/zapret-sonar/zapret-sonar-tui" ]]
[[ "$(readlink "$ZAPRET_BASE/zapret-sonar/current")" == releases/1.4.0 ]]
[[ -f "$ZAPRET_BASE/zapret-sonar/releases/1.4.0/RELEASE" ]]
grep -Fq 'ZF_BIN_DEST="${ZF_BIN_DEST:-'"$BIN_DEST"'}"' "$ZAPRET_BASE/zapret-sonar/lib/paths.sh"
[[ "$(readlink -f "$BIN_DEST/sonar")" == "$ZAPRET_BASE/zapret-sonar/zapret-sonar" ]]
grep -Fq -- '--install-root "$root"' "$ZAPRET_BASE/zapret-sonar/zapret-sonar"
printf 'PASS: installer creates versioned application layout and stable launchers\n'
