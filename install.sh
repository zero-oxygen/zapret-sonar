#!/usr/bin/env bash
# ============================================================================
# install.sh — установка zapret-sonar
#
# Ставит три вещи:
#   1. zapret v1 (bol-van) в /opt/zapret — он делает firewall, systemd, демона;
#   2. versioned-набор стратегий, .bin-фейков и списков Flowseal в /opt/zapret;
#   3. versioned runtime zapret-sonar в /opt/zapret и симлинки в /usr/local/bin.
#
# Принципы:
#   • Всё скачивается в staging и заменяется только после проверки — сбой
#     сети не должен оставить систему без рабочего обхода.
#   • sha256 бинарников сверяется с sha256sum.txt из релиза.
#   • Файлы в /opt принадлежат root:root. Пользовательские списки — тоже:
#     правки идут через `zapret-sonar site`, которая поднимает права сама.
#     Записываемый пользователем бинарник, запускаемый от root, — это
#     готовая эскалация привилегий.
#   • sudoers не трогается. Пароль спрашивается штатным sudo.
# ============================================================================

set -euo pipefail

ZAPRET_VER="${ZAPRET_VER:-v72.13}"
FLOWSEAL_VER="${FLOWSEAL_VER:-1.10.2}"

ZAPRET_BASE="${ZAPRET_BASE:-/opt/zapret}"
BIN_DEST="${BIN_DEST:-/usr/local/bin}"
SERVICE_NAME="${SERVICE_NAME:-zapret}"
MIGRATE_ZAPRET="${MIGRATE_ZAPRET:-0}"
INSTALL_DRY_RUN=0

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING=""

source "$SRC_DIR/lib/flowseal.sh"

# Пути к распакованным исходникам. Через глобальные переменные, а не через
# stdout функций: иначе прогресс-вывод попал бы в захватываемое значение.
FETCHED_ZAPRET=""
FETCHED_FLOWSEAL=""
INSTALL_FLOWSEAL_RELEASE=""
INSTALL_FLOWSEAL_OLD_TARGET=""
INSTALL_LEGACY_FLOWSEAL=0
INSTALL_CAN_REMOVE_LEGACY=0
INSTALL_STARTED=0
INSTALL_COMMITTED=0
INSTALL_HAD_BASE=0
INSTALL_SERVICE_ACTIVE=0
INSTALL_UNIT="/etc/systemd/system/$SERVICE_NAME.service"
INSTALL_LINKS=(zapret-sonar sonar zapret-sonar-tui sonar-tui)

log()  { printf '\n>>> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nошибка: %s\n' "$*" >&2; exit 1; }

acquire_install_lock() {
    local runtime_dir="${ZF_RUNTIME_DIR:-/run/zapret-sonar}"
    local lock="$runtime_dir/operations.lock"
    [[ ! -L "$runtime_dir" ]] || die "небезопасный runtime-каталог: $runtime_dir"
    install -d -m 0755 "$runtime_dir" || die "не удалось создать $runtime_dir"
    [[ "$(stat -c %u "$runtime_dir" 2>/dev/null)" == "$EUID" ]] || die "неверный владелец $runtime_dir"
    [[ ! -L "$lock" ]] || die "lock-файл не должен быть симлинком: $lock"
    exec 9>"$lock"
    flock -n 9 || die "другая операция zapret-sonar уже выполняется"
}

backup_current_install() {
    mkdir -p "$STAGING/rollback"
    [[ ! -L "$ZAPRET_BASE" ]] || die "$ZAPRET_BASE не должен быть симлинком"
    if [[ -d "$ZAPRET_BASE" ]]; then
        cp -a "$ZAPRET_BASE" "$STAGING/rollback/zapret" || die "не удалось создать резервную копию текущей установки"
        INSTALL_HAD_BASE=1
    fi
    mkdir -p "$STAGING/rollback/bin"
    local name
    for name in "${INSTALL_LINKS[@]}"; do
        if [[ -e "$BIN_DEST/$name" || -L "$BIN_DEST/$name" ]]; then
            cp -a "$BIN_DEST/$name" "$STAGING/rollback/bin/$name" || die "не удалось сохранить $BIN_DEST/$name"
        fi
    done
    [[ ! -L "$INSTALL_UNIT" ]] || die "$INSTALL_UNIT не должен быть симлинком"
    [[ -f "$INSTALL_UNIT" ]] && cp -a "$INSTALL_UNIT" "$STAGING/rollback/service.unit"
    [[ "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)" == "active" ]] && INSTALL_SERVICE_ACTIVE=1
    INSTALL_STARTED=1
}

rollback_install() {
    (( INSTALL_STARTED && ! INSTALL_COMMITTED )) || return 0
    printf '\nошибка установки: восстанавливаю предыдущее состояние\n' >&2
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -rf "$ZAPRET_BASE"
    if (( INSTALL_HAD_BASE )); then
        cp -a "$STAGING/rollback/zapret" "$ZAPRET_BASE" || printf 'КРИТИЧНО: не удалось восстановить %s\n' "$ZAPRET_BASE" >&2
    fi
    local name
    for name in "${INSTALL_LINKS[@]}"; do
        rm -f "$BIN_DEST/$name"
        if [[ -e "$STAGING/rollback/bin/$name" || -L "$STAGING/rollback/bin/$name" ]]; then
            cp -a "$STAGING/rollback/bin/$name" "$BIN_DEST/$name" || printf 'КРИТИЧНО: не удалось восстановить %s\n' "$BIN_DEST/$name" >&2
        fi
    done
    if [[ -f "$STAGING/rollback/service.unit" ]]; then
        cp -a "$STAGING/rollback/service.unit" "$INSTALL_UNIT" || printf 'КРИТИЧНО: не удалось восстановить %s\n' "$INSTALL_UNIT" >&2
    else
        rm -f "$INSTALL_UNIT"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    (( INSTALL_SERVICE_ACTIVE )) && systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
}

cleanup() {
    local rc=$?
    (( rc == 0 )) || rollback_install
    [[ -n "$STAGING" && -d "$STAGING" ]] && rm -rf "$STAGING"
    return "$rc"
}
trap cleanup EXIT

# --- Проверки ----------------------------------------------------------------
# --- Чужой обитатель каталога ------------------------------------------------
# В /opt/zapret может стоять другой проект — в частности zapret-ng, который
# использует и тот же путь, и то же имя systemd-юнита. Копирование поверх дало
# бы смесь двух проектов, а перезапись юнита молча сломала бы предыдущий.
# Поэтому такое состояние обнаруживается и требует явного решения.
detect_occupant() {
    local f
    # Файлы, которых нет у zapret v1, но есть у zapret-ng.
    for f in conf.env zapret-ctl service.sh update-strategies; do
        [[ -e "$ZAPRET_BASE/$f" ]] && { printf 'zapret-ng\n'; return 0; }
    done
    [[ -f "$ZAPRET_BASE/zapret-sonar/lib/install.conf" || -f "$ZAPRET_BASE/zapret-sonar/lib/paths.sh" ]] \
        && { printf 'zapret-sonar\n'; return 0; }
    [[ -f "$ZAPRET_BASE/init.d/sysv/functions" ]] && { printf 'zapret\n'; return 0; }
    [[ -d "$ZAPRET_BASE" ]] && [[ -n "$(ls -A "$ZAPRET_BASE" 2>/dev/null)" ]] && { printf 'unknown\n'; return 0; }
    printf 'none\n'
}

unit_is_foreign() {
    local u="/etc/systemd/system/$SERVICE_NAME.service"
    [[ -f "$u" ]] || return 1
    # Юнит zapret v1 запускает init.d/sysv/zapret. Всё остальное — чужое.
    grep -q 'init.d/sysv/zapret' "$u" && return 1
    return 0
}

install_config_literal() {
    local key="$1" line value
    line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$ZAPRET_BASE/config" 2>/dev/null | tail -1)
    [[ -n "$line" ]] || return 2
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}=([^#[:space:]]+)([[:space:]]+#.*)?[[:space:]]*$ ]] || return 1
    value="${BASH_REMATCH[2]}"
    case "$value" in
        \"*\") [[ "$value" == *\" && ${#value} -ge 2 ]] || return 1; value="${value:1:${#value}-2}" ;;
        \'*\') [[ "$value" == *\' && ${#value} -ge 2 ]] || return 1; value="${value:1:${#value}-2}" ;;
    esac
    [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    printf '%s\n' "$value"
}

install_effective_fwtype() {
    local config="$ZAPRET_BASE/config" fwtype="" rc
    if [[ -f "$config" ]] && ! grep -q '^# zapret-sonar-strategy: ' "$config"; then
        set +e
        fwtype=$(install_config_literal FWTYPE); rc=$?
        set -e
        case "$rc" in
            0) ;;
            2)
                if command -v nft >/dev/null 2>&1 && install_kernel_at_least_4_16; then fwtype=nftables
                else fwtype=iptables
                fi
                ;;
            *) die "не удалось определить FWTYPE существующего конфига; укажите канонический FWTYPE=nftables или FWTYPE=iptables" ;;
        esac
    elif command -v nft >/dev/null 2>&1; then
        fwtype=nftables
    else
        fwtype=iptables
    fi
    case "$fwtype" in
        nftables|iptables) printf '%s\n' "$fwtype" ;;
        *) die "неподдерживаемый FWTYPE существующего конфига: $fwtype" ;;
    esac
}

install_kernel_at_least_4_16() {
    local release major minor
    release=$(uname -r)
    major=${release%%.*}
    release=${release#*.}
    minor=${release%%.*}
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    (( major > 4 || (major == 4 && minor >= 16) ))
}

preflight() {
    (( INSTALL_DRY_RUN )) || [[ $EUID -eq 0 ]] || die "запускать от root: sudo ./install.sh"
    (( BASH_VERSINFO[0] >= 4 )) || die "нужен bash 4 или новее"

    local missing=()
    local c
    for c in curl tar sha256sum systemctl flock stat install find grep sed readlink sort head tail wc mktemp; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    (( ${#missing[@]} == 0 )) || die "не хватает утилит: ${missing[*]}"

    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null || true)" != Disabled ]]; then
        command -v restorecon >/dev/null 2>&1 \
            || die "SELinux активен, но не найдена утилита restorecon (пакет policycoreutils)"
    fi

    # Managed configs are rebuilt with the locally available backend. A plain
    # zapret config is preserved during explicit migration, so its FWTYPE wins.
    local fwtype; fwtype=$(install_effective_fwtype)
    case "$fwtype" in
        nftables)
            command -v nft >/dev/null 2>&1 || die "существующий конфиг требует nftables (nft)"
            ;;
        iptables)
            command -v iptables >/dev/null 2>&1 || die "существующий конфиг требует iptables"
            command -v ip6tables >/dev/null 2>&1 || die "для iptables backend нужна утилита ip6tables"
            command -v ipset >/dev/null 2>&1 || die "для iptables backend нужна утилита ipset"
            command -v nft >/dev/null 2>&1 || info "ПРЕДУПРЕЖДЕНИЕ: nft не найден, zapret пойдёт через iptables"
            ;;
    esac

    [[ -d /run/systemd/system ]] || die "systemd не обнаружен — этот установщик рассчитан на systemd"

    local f
    for f in zapret-sonar zapret-sonar-tui RELEASE lib/translate.sh lib/zconfig.sh lib/health.sh lib/flowseal.sh lib/self-update.sh; do
        [[ -f "$SRC_DIR/$f" ]] || die "рядом с install.sh нет $f"
    done

    # Занятый каталог и чужой юнит — повод остановиться, а не «доустановить».
    local occ; occ=$(detect_occupant)
    case "$occ" in
        none|zapret-sonar) ;;
        zapret)
            if [[ "$MIGRATE_ZAPRET" != 1 ]]; then
                printf '\nВ %s установлена обычная zapret v1, не управляемая zapret-sonar.\n' "$ZAPRET_BASE" >&2
                printf 'Для осознанной миграции повторите с MIGRATE_ZAPRET=1.\n' >&2
                die "каталог занят: zapret v1"
            fi
            info "включена явная миграция существующей zapret v1"
            ;;
        zapret-ng)
            printf '\nВ %s установлен zapret-ng (другой проект).\n' "$ZAPRET_BASE" >&2
            printf 'Копирование поверх дало бы смесь двух проектов.\n' >&2
            printf 'Сначала сохраните и уберите его, либо ставьте в другой путь:\n' >&2
            printf '  ZAPRET_BASE=/opt/zapret-sonar SERVICE_NAME=zapret-sonar ./install.sh\n' >&2
            die "каталог занят: zapret-ng"
            ;;
        *)
            printf '\nВ %s есть посторонние файлы (неизвестный проект).\n' "$ZAPRET_BASE" >&2
            die "каталог занят — очистите его или укажите другой ZAPRET_BASE"
            ;;
    esac

    if unit_is_foreign; then
        printf '\nЮнит %s.service принадлежит другому проекту.\n' "$SERVICE_NAME" >&2
        printf 'Перезапись молча сломала бы его. Укажите другое имя:\n' >&2
        printf '  SERVICE_NAME=zapret-sonar ./install.sh\n' >&2
        die "имя сервиса занято: $SERVICE_NAME"
    fi
}

detect_arch() {
    local m; m=$(uname -m)
    case "$m" in
        x86_64|amd64) printf 'linux-x86_64\n' ;;
        i?86)         printf 'linux-x86\n' ;;
        aarch64|arm64) printf 'linux-arm64\n' ;;
        armv7l|armv6l|arm) printf 'linux-arm\n' ;;
        *) die "неизвестная архитектура: $m (нет готовых бинарников)" ;;
    esac
}

# --- Скачивание --------------------------------------------------------------
fetch_zapret() {
    local arch="$1" url sums
    url="https://github.com/bol-van/zapret/releases/download/$ZAPRET_VER/zapret-$ZAPRET_VER.tar.gz"
    sums="https://github.com/bol-van/zapret/releases/download/$ZAPRET_VER/sha256sum.txt"

    log "Скачивание zapret $ZAPRET_VER ($arch)"
    curl -fsSL --retry 2 -o "$STAGING/zapret.tar.gz" "$url" || die "не скачался zapret"
    curl -fsSL --retry 2 -o "$STAGING/sha256sum.txt" "$sums" || die "не скачался sha256sum.txt"

    tar -xzf "$STAGING/zapret.tar.gz" -C "$STAGING" || die "архив zapret не распаковался"
    local root="$STAGING/zapret-$ZAPRET_VER"
    [[ -d "$root" ]] || die "в архиве нет каталога zapret-$ZAPRET_VER"

    # sha256sum.txt содержит хеши бинарников внутри архива (не самого архива),
    # пути в нём относительно распакованного каталога.
    log "Проверка целостности бинарников"
    ( cd "$STAGING" && sha256sum -c --ignore-missing --quiet sha256sum.txt 2>/dev/null ) \
        || die "sha256 не совпал — скачанные бинарники повреждены или подменены"

    local binary name
    for name in nfqws ip2net mdig; do
        binary="$root/binaries/$arch/$name"
        [[ -f "$binary" ]] || die "в релизе нет бинарника для $arch/$name"
        grep -Eq "^[[:xdigit:]]{64}[[:space:]]+\\*?zapret-${ZAPRET_VER}/binaries/${arch}/${name}$" "$STAGING/sha256sum.txt" \
            || die "в sha256sum.txt нет записи для $arch/$name — целостность не подтверждена"
        info "$name $arch: sha256 подтверждён"
    done
    FETCHED_ZAPRET="$root"
}

fetch_flowseal() {
    local url
    url="https://github.com/Flowseal/zapret-discord-youtube/releases/download/$FLOWSEAL_VER/zapret-discord-youtube-$FLOWSEAL_VER.tar.gz"

    log "Скачивание стратегий Flowseal $FLOWSEAL_VER"
    # У Flowseal нет файла с контрольными суммами в релизе; целостность
    # обеспечивается только TLS. Сообщаем честно.
    info "у релиза Flowseal нет sha256-файла — доверяем TLS"
    curl -fsSL --retry 2 -o "$STAGING/flowseal.tar.gz" "$url" || die "не скачались стратегии"

    mkdir -p "$STAGING/fs"
    tar -xzf "$STAGING/flowseal.tar.gz" -C "$STAGING/fs" || die "архив Flowseal не распаковался"

    # В архиве возможен как корень с файлами, так и вложенный каталог.
    local root
    root=$(find "$STAGING/fs" -maxdepth 2 -name 'general*.bat' -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$root" ]] || die "в архиве Flowseal не найдено стратегий general*.bat"
    [[ -d "$root/bin" && -d "$root/lists" ]] || die "в архиве Flowseal нет bin/ или lists/"
    FETCHED_FLOWSEAL="$root"
}

# --- Установка ---------------------------------------------------------------
install_zapret() {
    local src="$1" arch="$2"

    # Конфиг — единственное, что нельзя потерять при переустановке.
    local saved=""
    if [[ -f "$ZAPRET_BASE/config" ]]; then
        saved="$STAGING/config.saved"
        cp -a "$ZAPRET_BASE/config" "$saved"
        info "текущий config сохранён и будет возвращён"
    fi

    log "Установка zapret в $ZAPRET_BASE"
    mkdir -p "$ZAPRET_BASE"
    # Обновляем содержимое, не удаляя каталог целиком: так переустановка не
    # оставляет систему без файлов при обрыве.
    cp -a "$src/." "$ZAPRET_BASE/"

    install -Dm755 "$src/binaries/$arch/nfqws" "$ZAPRET_BASE/nfq/nfqws"
    install -Dm755 "$src/binaries/$arch/ip2net" "$ZAPRET_BASE/ip2net/ip2net"
    install -Dm755 "$src/binaries/$arch/mdig"   "$ZAPRET_BASE/mdig/mdig"

    [[ -n "$saved" ]] && cp -a "$saved" "$ZAPRET_BASE/config"
    chown -R root:root "$ZAPRET_BASE"
    info "nfqws: $("$ZAPRET_BASE/nfq/nfqws" --version 2>&1 | head -1)"

    # Хук обязателен до первого старта: иначе UDP-десинк поднимется без
    # conntrack-совместимости и сломает UDP/QUIC до следующего `sonar use`.
    install_udp_conntrack_hook
    info "udp conntrack hook: $ZAPRET_BASE/init.d/sysv/custom.d/50-sonar-udp-conntrack"
}

# Генерирует хук тем же кодом, что и CLI (lib/zconfig.sh). Subshell нужен,
# чтобы переменные библиотеки не перетирали ZAPRET_BASE/окружение установщика.
install_udp_conntrack_hook() {
    (
        export ZF_ZAPRET_BASE="$ZAPRET_BASE"
        export ZF_ZAPRET_CONFIG="$ZAPRET_BASE/config"
        # shellcheck source=lib/zconfig.sh
        source "$SRC_DIR/lib/zconfig.sh"
        zf_write_udp_conntrack_hook
    ) || die "не удалось записать UDP conntrack hook"
}

install_flowseal() {
    local src="$1"
    log "Установка стратегий и списков Flowseal"

    local current="$ZAPRET_BASE/flowseal-current"
    local old_lists="$ZAPRET_BASE/flowseal-lists"
    local legacy=0
    [[ -d "$ZAPRET_BASE/flowseal-strategies" || -d "$ZAPRET_BASE/flowseal-bin" || -d "$ZAPRET_BASE/flowseal-lists" ]] && legacy=1
    [[ -d "$current/lists" ]] && old_lists="$current/lists"
    local stage="$ZAPRET_BASE/.flowseal-stage.$$"
    local release
    release="$ZAPRET_BASE/.flowseal-releases/$FLOWSEAL_VER-$(date +%s)-$$"
    local old_target=""
    [[ -L "$current" ]] && old_target=$(readlink "$current")
    if [[ -n "$old_target" && -f "$ZAPRET_BASE/.flowseal-version" ]]; then
        local old_release="$ZAPRET_BASE/$old_target" old_version
        old_version=$(tr -d '[:space:]' < "$ZAPRET_BASE/.flowseal-version")
        [[ -f "$old_release/.flowseal-release" ]] \
            || zf_write_flowseal_metadata "$old_release" "$ZAPRET_BASE/.flowseal-releases" "${old_version#v}" \
            || die "не удалось записать metadata предыдущего Flowseal release"
    fi

    rm -rf "$stage"
    zf_prepare_flowseal_tree "$src" "$stage" "$old_lists" || die "не удалось подготовить набор Flowseal"
    zf_activate_flowseal_tree "$stage" "$release" "$current" || die "не удалось активировать набор Flowseal"
    chown -R root:root "$release"
    zf_write_flowseal_metadata "$release" "$ZAPRET_BASE/.flowseal-releases" "$FLOWSEAL_VER" \
        || die "не удалось записать metadata Flowseal release"
    INSTALL_FLOWSEAL_RELEASE="$release"
    INSTALL_FLOWSEAL_OLD_TARGET="$old_target"
    INSTALL_LEGACY_FLOWSEAL="$legacy"
    info "стратегий: $(find "$current/strategies" -name '*.bat' | wc -l), фейков: $(find "$current/bin" -name '*.bin' | wc -l)"
}

install_flow() {
    log "Установка zapret-sonar в $BIN_DEST"
    local dest="$ZAPRET_BASE/zapret-sonar" version release
    version=$(sed -n 's/^version=//p' "$SRC_DIR/RELEASE")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "некорректный RELEASE"
    release="$dest/releases/$version"
    install -d -m 0755 "$dest" "$dest/releases" "$release" "$release/lib" "$dest/lib"
    install -m 755 "$SRC_DIR/zapret-sonar" "$release/zapret-sonar"
    install -m 755 "$SRC_DIR/zapret-sonar-tui" "$release/zapret-sonar-tui"
    install -m 644 "$SRC_DIR/RELEASE" "$release/RELEASE"
    install -m 644 "$SRC_DIR/lib/"*.sh "$release/lib/"

    # Фиксируем пути установки. Переменные окружения тут не годятся: CLI
    # перезапускает себя через sudo, который окружение не пробрасывает.
    cat > "$dest/lib/paths.sh" <<EOF
# Сгенерировано install.sh — путь и имя сервиса этой установки.
# Значения заданы установщиком, но допускают override через окружение
# (нужно для тестирования и нестандартных конфигураций).
ZF_ZAPRET_BASE="\${ZF_ZAPRET_BASE:-$ZAPRET_BASE}"
ZF_SERVICE="\${ZF_SERVICE:-$SERVICE_NAME}"
ZF_BIN_DEST="\${ZF_BIN_DEST:-$BIN_DEST}"
EOF
    cat > "$dest/lib/install.conf" <<EOF
ZAPRET_BASE=$ZAPRET_BASE
SERVICE_NAME=$SERVICE_NAME
BIN_DEST=$BIN_DEST
EOF
    chmod 644 "$dest/lib/paths.sh"

cat > "$dest/zapret-sonar" <<'EOF'
#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
exec "$root/current/zapret-sonar" --install-root "$root" "$@"
EOF
    cat > "$dest/zapret-sonar-tui" <<'EOF'
#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
exec "$root/current/zapret-sonar-tui" --install-root "$root" "$@"
EOF
    chmod 755 "$dest/zapret-sonar" "$dest/zapret-sonar-tui"
    local old_app_target=""
    [[ -L "$dest/current" ]] && old_app_target=$(readlink "$dest/current")
    ln -sfn "releases/$version" "$dest/current"
    if [[ -n "$old_app_target" && "$old_app_target" != "releases/$version" ]]; then
        ln -sfn "$old_app_target" "$dest/previous"
    fi

    ln -sf "$dest/zapret-sonar" "$BIN_DEST/zapret-sonar"
    ln -sf "$dest/zapret-sonar" "$BIN_DEST/sonar"

    # TUI ставится, только если рядом лежит и есть fzf: на headless-сервере
    # он бесполезен, а тянуть зависимость ради неиспользуемого файла незачем.
    if [[ -f "$SRC_DIR/zapret-sonar-tui" ]]; then
        ln -sf "$dest/zapret-sonar-tui" "$BIN_DEST/zapret-sonar-tui"
        ln -sf "$dest/zapret-sonar-tui" "$BIN_DEST/sonar-tui"
        if command -v fzf >/dev/null 2>&1; then
            info "TUI: zapret-sonar-tui"
        else
            info "TUI установлен, но нужен fzf (без него не запустится)"
        fi
    fi

    chown -R root:root "$dest"
    chmod 0755 "$dest" "$dest/releases" "$release" "$release/lib" "$dest/lib"
    info "команда: zapret-sonar --help (или: sonar --help)"
}

install_unit() {
    log "Установка systemd-юнита"
    # Юнит берём из самого zapret: он знает свою схему запуска
    # (init.d/sysv/zapret start|stop, Type=forking).
    local src="$ZAPRET_BASE/init.d/systemd/zapret.service"
    [[ -f "$src" ]] || die "в zapret нет init.d/systemd/zapret.service"

    # Пути в юните жёстко прописаны как /opt/zapret — правим, если ставим не туда.
    sed "s|/opt/zapret|$ZAPRET_BASE|g" "$src" > "/etc/systemd/system/$SERVICE_NAME.service"
    chmod 644 "/etc/systemd/system/$SERVICE_NAME.service"
    systemctl daemon-reload
    info "юнит: /etc/systemd/system/$SERVICE_NAME.service (автозапуск не включён)"
}

restore_security_contexts() {
    command -v getenforce >/dev/null 2>&1 || return 0
    [[ "$(getenforce 2>/dev/null || true)" != Disabled ]] || return 0
    command -v restorecon >/dev/null 2>&1 \
        || die "SELinux активен, но не найдена утилита restorecon (пакет policycoreutils)"
    restorecon -R -x "$ZAPRET_BASE" \
        && restorecon "$INSTALL_UNIT" \
        || die "не удалось восстановить SELinux contexts установленных файлов"
}

record_firewall_ownership() {
    [[ -f "$ZAPRET_BASE/config" ]] || return 0
    grep -q '^# zapret-sonar-strategy: ' "$ZAPRET_BASE/config" || return 0
    local fwtype qnum table tmp owner="$ZAPRET_BASE/.zapret-sonar-firewall"
    fwtype=$(install_config_literal FWTYPE) || die "не удалось определить FWTYPE для firewall ownership"
    qnum=$(install_config_literal QNUM 2>/dev/null || printf '200\n')
    table=$(install_config_literal ZAPRET_NFT_TABLE 2>/dev/null || printf 'zapret\n')
    [[ "$fwtype" == nftables || "$fwtype" == iptables ]] || die "некорректный FWTYPE для firewall ownership"
    [[ "$qnum" =~ ^[0-9]+$ && qnum -le 65535 ]] || die "некорректный QNUM для firewall ownership"
    [[ "$table" =~ ^[A-Za-z0-9_.-]+$ ]] || die "некорректная nftables table для firewall ownership"
    tmp=$(mktemp "$ZAPRET_BASE/.firewall-owner.XXXXXX") || die "не удалось создать firewall ownership"
    printf 'FWTYPE=%s\nQNUM=%s\nTABLE=%s\n' "$fwtype" "$qnum" "$table" > "$tmp"
    chmod 600 "$tmp" && chown root:root "$tmp" && mv -f "$tmp" "$owner" \
        || { rm -f "$tmp"; die "не удалось записать firewall ownership"; }
}

rebuild_existing_config() {
    local cli="$ZAPRET_BASE/zapret-sonar/zapret-sonar"
    local strategy gamefilter ipset
    if [[ ! -f "$ZAPRET_BASE/config" ]]; then
        INSTALL_CAN_REMOVE_LEGACY=1
        return 0
    fi
    strategy=$(sed -n 's/^# zapret-sonar-strategy: //p' "$ZAPRET_BASE/config" | head -1)
    if [[ -z "$strategy" ]]; then
        (( INSTALL_LEGACY_FLOWSEAL == 0 )) || info "старые flowseal-* сохранены: конфиг не содержит маркер стратегии"
        return 0
    fi
    gamefilter=$(sed -n 's/^# zapret-sonar-gamefilter: //p' "$ZAPRET_BASE/config" | head -1)
    ipset=$(sed -n 's/^# zapret-sonar-ipset: //p' "$ZAPRET_BASE/config" | head -1)
    gamefilter="${gamefilter:-off}"
    if [[ -z "$ipset" ]]; then
        ipset=$(zf_ipset_mode "$ZAPRET_BASE/flowseal-current/lists")
        [[ "$ipset" != unknown ]] || ipset=none
    fi

    log "Пересборка существующего конфига"
    if ! ZF_LOCK_HELD=1 "$cli" _render "$strategy" "$gamefilter" "$ipset"; then
        if [[ -n "$INSTALL_FLOWSEAL_OLD_TARGET" ]]; then
            zf_restore_flowseal_tree "$ZAPRET_BASE/flowseal-current" "$INSTALL_FLOWSEAL_OLD_TARGET" \
                || die "не удалось пересобрать конфиг и откатить набор Flowseal"
        else
            rm -f "$ZAPRET_BASE/flowseal-current"
        fi
        zf_remove_flowseal_release "$ZAPRET_BASE/.flowseal-releases" "$INSTALL_FLOWSEAL_RELEASE" \
            || die "набор Flowseal откатан, но не удалось удалить нерабочий snapshot"
        die "не удалось пересобрать существующую стратегию; предыдущий набор восстановлен"
    fi
    INSTALL_CAN_REMOVE_LEGACY=1
}

finalize_flowseal_install() {
    if [[ "${INSTALL_LEGACY_FLOWSEAL:-0}" == "1" && "$INSTALL_CAN_REMOVE_LEGACY" == "1" ]]; then
        rm -rf "$ZAPRET_BASE/flowseal-strategies" "$ZAPRET_BASE/flowseal-bin" "$ZAPRET_BASE/flowseal-lists"
        info "старые каталоги flowseal-* удалены после успешной пересборки"
    fi
    printf '%s\n' "$FLOWSEAL_VER" > "$ZAPRET_BASE/.flowseal-version"
    zf_prune_flowseal_releases "$ZAPRET_BASE/.flowseal-releases" \
        "$INSTALL_FLOWSEAL_RELEASE" "$INSTALL_FLOWSEAL_OLD_TARGET" \
        || die "установка завершена, но не удалось очистить старые snapshots"
}

check_conflicts() {
    local other
    for other in zapret2 zapret-ng; do
        [[ "$other" == "$SERVICE_NAME" ]] && continue
        if [[ "$(systemctl is-active "$other" 2>/dev/null)" == "active" ]]; then
            printf '\nВНИМАНИЕ: активен сервис %s — он займёт NFQUEUE и будет конфликтовать.\n' "$other"
            printf 'Остановите его перед запуском: systemctl stop %s\n' "$other"
        fi
        if [[ "$(systemctl is-enabled "$other" 2>/dev/null)" == "enabled" ]]; then
            printf 'ВНИМАНИЕ: %s включён в автозапуск — после перезагрузки поднимется вместе с zapret.\n' "$other"
        fi
    done
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) INSTALL_DRY_RUN=1 ;;
            --non-interactive) ;;
            -h|--help)
                printf 'Использование: sudo ./install.sh [--non-interactive] [--dry-run]\n'
                printf '  --dry-run          проверить окружение и показать план без изменений\n'
                printf '  --non-interactive  явно подтвердить отсутствие интерактивных запросов\n'
                return 0 ;;
            *) die "неизвестный параметр: $arg" ;;
        esac
    done
    preflight
    if (( INSTALL_DRY_RUN )); then
        printf 'Проверка пройдена. План установки:\n'
        printf '  zapret %s -> %s\n' "$ZAPRET_VER" "$ZAPRET_BASE"
        printf '  Flowseal %s -> %s/flowseal-current\n' "$FLOWSEAL_VER" "$ZAPRET_BASE"
        printf '  команды -> %s\n' "$BIN_DEST"
        printf '  systemd unit -> /etc/systemd/system/%s.service\n' "$SERVICE_NAME"
        return 0
    fi
    acquire_install_lock
    local arch; arch=$(detect_arch)
    STAGING=$(mktemp -d /tmp/zapret-sonar-install.XXXXXX)

    fetch_zapret "$arch"
    fetch_flowseal
    backup_current_install

    install_zapret "$FETCHED_ZAPRET" "$arch"
    install_flowseal "$FETCHED_FLOWSEAL"
    install_flow
    install_unit
    rebuild_existing_config
    finalize_flowseal_install
    record_firewall_ownership
    restore_security_contexts
    check_conflicts
    if (( INSTALL_SERVICE_ACTIVE )); then
        systemctl restart "$SERVICE_NAME" || die "сервис не запустился после переустановки"
        info "активный сервис перезапущен с обновлёнными файлами"
    fi
    INSTALL_COMMITTED=1

    cat <<EOF

Готово.

  zapret-sonar baseline          что заблокировано без обхода
  zapret-sonar try --keep        найти и оставить первую рабочую стратегию
  zapret-sonar use <стратегия>   применить
  zapret-sonar status            состояние

Автозапуск (после того как нашли рабочую стратегию):
  systemctl enable $SERVICE_NAME

Стратегии подбираются опытом: рабочая зависит от провайдера.
EOF
}

if [[ "${ZF_INSTALL_LIBRARY_MODE:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

main "$@"
