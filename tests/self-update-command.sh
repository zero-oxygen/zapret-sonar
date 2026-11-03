#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

asset_dir="$TEST_DIR/assets"
bash "$PROJECT_DIR/scripts/build-release.sh" "$asset_dir" >/dev/null
release_version=$(sed -n 's/^version=//p' "$PROJECT_DIR/RELEASE")
export ZF_LIBRARY_MODE=1
export ZF_INSTALL_ROOT="$TEST_DIR/install"
export ZF_ZAPRET_BASE="$TEST_DIR/zapret"
export ZF_RUNTIME_DIR="$TEST_DIR/run"
export ZF_UPDATE_CACHE_DIR="$TEST_DIR/cache"
mkdir -p "$ZF_INSTALL_ROOT/releases/old" "$ZF_INSTALL_ROOT/lib" "$ZF_ZAPRET_BASE/nfq" "$ZF_RUNTIME_DIR"
printf '#!/usr/bin/env bash\nprintf "zapret-sonar 1.2.2\\n"\n' > "$ZF_INSTALL_ROOT/releases/old/zapret-sonar"
chmod +x "$ZF_INSTALL_ROOT/releases/old/zapret-sonar"
ln -s releases/old "$ZF_INSTALL_ROOT/current"
cat > "$ZF_INSTALL_ROOT/zapret-sonar" <<'EOF'
#!/usr/bin/env bash
root=$(cd "$(dirname "$0")" && pwd)
exec "$root/current/zapret-sonar" "$@"
EOF
chmod +x "$ZF_INSTALL_ROOT/zapret-sonar"
printf '#!/usr/bin/env bash\nprintf "github version v72.13 (test)\\n"\n' > "$ZF_ZAPRET_BASE/nfq/nfqws"
chmod +x "$ZF_ZAPRET_BASE/nfq/nfqws"

# shellcheck source=../zapret-sonar
source "$PROJECT_DIR/zapret-sonar"
need_root() { return 0; }
_zf_lock() { :; }
_zf_invalidate_update_caches() { :; }
chown() { :; }
curl() {
    local out="" src
    while (( $# )); do
        if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi
    done
    [[ "$out" == *SHA256SUMS ]] && src="$asset_dir/SHA256SUMS" || src="$asset_dir/zapret-sonar-v$release_version.tar.gz"
    cp "$src" "$out"
}

cmd_self_update --force --version "$release_version" >/dev/null
new_target=$(readlink "$ZF_INSTALL_ROOT/current")
[[ "$new_target" == "releases/$release_version"-* ]]
[[ "$(readlink "$ZF_INSTALL_ROOT/previous")" == releases/old ]]
[[ "$(ZF_LIBRARY_MODE=0 "$ZF_INSTALL_ROOT/zapret-sonar" --version)" == "zapret-sonar $release_version" ]]
cmd_self_update --force --version "$release_version" >/dev/null
[[ "$(readlink "$ZF_INSTALL_ROOT/current")" == "$new_target" ]]
printf 'PASS: self-update command downloads, verifies and activates a release\n'
