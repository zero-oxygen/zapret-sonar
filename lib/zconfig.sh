#!/usr/bin/env bash
# ============================================================================
# lib/zconfig.sh — генерация конфига zapret v1 из транслированной стратегии
#
# Состояние (какая стратегия применена, режимы фильтров) НЕ хранится в
# отдельном файле: оно записывается маркерами в сам конфиг zapret. Один
# источник истины, нечему разъезжаться.
#
# Конфиг zapret загружается через `.` (init.d/sysv/functions:6), то есть это
# исполняемый shell-код от root. Поэтому конфиг генерируется целиком нами и
# никогда не собирается из непроверенного пользовательского ввода.
# ============================================================================

[[ -n "${_ZF_ZCONFIG_SH:-}" ]] && return 0
_ZF_ZCONFIG_SH=1

ZF_ZAPRET_BASE="${ZF_ZAPRET_BASE:-/opt/zapret}"
ZF_ZAPRET_CONFIG="${ZF_ZAPRET_CONFIG:-$ZF_ZAPRET_BASE/config}"

ZF_MARK_STRATEGY="# zapret-sonar-strategy:"
ZF_MARK_GAMEFILTER="# zapret-sonar-gamefilter:"
ZF_MARK_IPSET="# zapret-sonar-ipset:"

# --- Чтение состояния --------------------------------------------------------
# zf_state KEY — печатает применённое значение (strategy|gamefilter|ipset)
# из маркеров конфига. Пусто, если конфиг не наш или отсутствует.
zf_state() {
    local key="$1" mark
    case "$key" in
        strategy)   mark="$ZF_MARK_STRATEGY" ;;
        gamefilter) mark="$ZF_MARK_GAMEFILTER" ;;
        ipset)      mark="$ZF_MARK_IPSET" ;;
        *) return 1 ;;
    esac
    [[ -r "$ZF_ZAPRET_CONFIG" ]] || return 0
    # Значение — весь остаток строки: имена стратегий содержат пробелы и скобки.
    sed -n "s|^${mark} ||p" "$ZF_ZAPRET_CONFIG" | head -1
}

zf_write_state_marker() {
    local key="$1" value="$2" mark tmp
    case "$key" in
        strategy)   mark="$ZF_MARK_STRATEGY" ;;
        gamefilter) mark="$ZF_MARK_GAMEFILTER" ;;
        ipset)      mark="$ZF_MARK_IPSET" ;;
        *) return 1 ;;
    esac
    [[ -f "$ZF_ZAPRET_CONFIG" ]] || return 0
    tmp=$(mktemp "${ZF_ZAPRET_CONFIG}.marker.XXXXXX") || return 1
    if grep -q "^${mark} " "$ZF_ZAPRET_CONFIG"; then
        sed "s|^${mark} .*|${mark} ${value}|" "$ZF_ZAPRET_CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        cp -a "$ZF_ZAPRET_CONFIG" "$tmp" || { rm -f "$tmp"; return 1; }
        printf '%s %s\n' "$mark" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    chmod --reference="$ZF_ZAPRET_CONFIG" "$tmp" 2>/dev/null || chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
    chown --reference="$ZF_ZAPRET_CONFIG" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$ZF_ZAPRET_CONFIG"
}

# --- Генерация конфига -------------------------------------------------------
# zf_write_config STRATEGY_NAME GAMEFILTER IPSET_MODE
# Требует заранее заполненных ZF_OPT / ZF_PORTS_* (см. zf_translate).
#
# Запись атомарная: конфиг собирается в temp и подставляется через mv, чтобы
# systemctl restart никогда не прочитал полуготовый файл.
zf_write_config() {
    local strategy="$1" gamefilter="$2" ipset_mode="$3"

    [[ -n "$ZF_OPT" ]] || { printf 'zconfig: ZF_OPT пуст, сначала zf_translate\n' >&2; return 1; }

    # Первая наша запись — сохранить исходный конфиг zapret.
    if [[ -f "$ZF_ZAPRET_CONFIG" ]] && ! grep -q "^${ZF_MARK_STRATEGY}" "$ZF_ZAPRET_CONFIG"; then
        if [[ ! -f "$ZF_ZAPRET_CONFIG.orig" ]]; then
            cp -a "$ZF_ZAPRET_CONFIG" "$ZF_ZAPRET_CONFIG.orig" || return 1
            printf 'zconfig: исходный конфиг zapret сохранён в %s.orig\n' "$ZF_ZAPRET_CONFIG" >&2
        fi
    fi

    local tmp
    tmp=$(mktemp "${ZF_ZAPRET_CONFIG}.tmp.XXXXXX") || return 1

    {
        printf '# Сгенерировано zapret-sonar %s — правки будут перезаписаны.\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# Исходный конфиг zapret: %s.orig\n' "$ZF_ZAPRET_CONFIG"
        printf '%s %s\n' "$ZF_MARK_STRATEGY" "$strategy"
        printf '%s %s\n' "$ZF_MARK_GAMEFILTER" "$gamefilter"
        printf '%s %s\n' "$ZF_MARK_IPSET" "$ipset_mode"
        printf '\n'
        local fwtype="nftables"
    command -v nft >/dev/null 2>&1 || fwtype="iptables"
    printf 'FWTYPE=%s\n' "$fwtype"
        printf 'DISABLE_IPV6=1\n'
        # Без этого init.d/sysv/zapret:21 НЕ применяет правила firewall:
        # nfqws запускается, но трафик в его очередь не попадает. Проверять
        # обход в таком состоянии бессмысленно — он работать не будет
        # (либо заработает случайно, на чужих остаточных правилах).
        printf 'INIT_APPLY_FW=1\n'
        # Стратегии Flowseal несут свои --hostlist/--ipset в аргументах,
        # поэтому механизм подстановки <HOSTLIST> в zapret не используется.
        printf 'MODE_FILTER=none\n'
        printf 'FLOWOFFLOAD=none\n'
        printf 'TPWS_ENABLE=0\n'
        printf 'TPWS_SOCKS_ENABLE=0\n'
        printf 'NFQWS_ENABLE=1\n'
        printf 'NFQWS_PORTS_TCP=%s\n' "$ZF_PORTS_TCP"
        printf 'NFQWS_PORTS_UDP=%s\n' "$ZF_PORTS_UDP"
        # connbytes-лимиты: сколько первых пакетов соединения уходит в очередь.
        # Значения как в config.default zapret, экономят CPU.
        printf 'NFQWS_TCP_PKT_OUT=12\n'
        printf 'NFQWS_TCP_PKT_IN=3\n'
        printf 'NFQWS_UDP_PKT_OUT=12\n'
        printf 'NFQWS_UDP_PKT_IN=3\n'
        printf 'NFQWS_OPT="\n%s\n"\n' "$ZF_OPT"
    } > "$tmp" || { rm -f "$tmp"; return 1; }

    # Конфиг исполняется через `.` от root — синтаксическая ошибка означала бы
    # сломанный сервис. Проверяем до подстановки.
    if ! bash -n "$tmp" 2>/dev/null; then
        printf 'zconfig: сгенерирован невалидный shell-синтаксис, конфиг не заменён\n' >&2
        rm -f "$tmp"
        return 1
    fi

    if ! chmod 644 "$tmp" || ! mv -f "$tmp" "$ZF_ZAPRET_CONFIG"; then
        rm -f "$tmp"
        return 1
    fi

    # Хук пишется до рестарта сервиса. Без него первый же старт поднимает
    # UDP-десинк без сохранённой conntrack-записи, и UDP/QUIC ломается до
    # следующего применения стратегии. Ошибка записи не отменяет применение:
    # конфиг уже валиден, а doctor и check явно покажут пробел.
    zf_write_udp_conntrack_hook \
        || printf 'zconfig: не удалось записать UDP conntrack hook, UDP может не работать\n' >&2
    return 0
}

# --- UDP conntrack hook ------------------------------------------------------
# В POSTNAT-режиме zapret помечает сгенерированные nfqws копии как notrack
# (common/nft.sh:108). Для TCP это безвредно: десинк применяется после SYN,
# когда conntrack-запись уже подтверждена. Для UDP записи не остаётся вовсе:
# ответы не сопоставляются с записью и режутся политикой firewall по
# умолчанию (UFW дропает такой трафик). Внешне это выглядит как «UDP заблокирован
# провайдером», хотя без zapret тот же трафик работает.
#
# Хук возвращает tracking только сгенерированным UDP-копиям и только для
# нефрагментированного IPv4. TCP, IPv6 и фрагменты сохраняют upstream-ное
# поведение: для TCP notrack нужен для корректной работы badseq и datanoack,
# фрагменты обрабатываются отдельными правилами. IPv6 вне охвата: конфиг его
# отключает (DISABLE_IPV6=1).
#
# Хук ставится через штатный custom.d, который zapret вызывает после
# построения цепочек, поэтому переживает смену стратегии и обновления.
ZF_UDP_CONNTRACK_HOOK="50-sonar-udp-conntrack"
# Читается в cmd_doctor (zapret-sonar) при проверке правила.
# shellcheck disable=SC2034
ZF_UDP_CONNTRACK_COMMENT="sonar-udp-conntrack"

zf_udp_conntrack_hook_path() {
    printf '%s/init.d/sysv/custom.d/%s\n' "$ZF_ZAPRET_BASE" "$ZF_UDP_CONNTRACK_HOOK"
}

# zf_write_udp_conntrack_hook — записать хук атомарно. Возвращает 0 и при
# отсутствии изменений: файл перезаписывается только если содержимое другое.
zf_write_udp_conntrack_hook() {
    local dir file tmp
    dir="$ZF_ZAPRET_BASE/init.d/sysv/custom.d"
    file="$dir/$ZF_UDP_CONNTRACK_HOOK"

    # Каталог custom.d есть в штатной раскладке zapret. Если его нет, это не
    # ошибка применения конфига: doctor сообщит о пропуске явно.
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    [[ ! -L "$file" ]] || return 1

    tmp=$(mktemp "$dir/.udp-conntrack.XXXXXX") || return 1
    cat > "$tmp" <<'EOF'
# Сгенерировано zapret-sonar. Правки будут перезаписаны.
#
# Возвращает tracking сгенерированным nfqws UDP-копиям в POSTNAT-режиме:
# без этого ответы не сопоставляются с записью и режутся локальным firewall.
# TCP и фрагменты не затрагиваются — там notrack нужен по другой причине.
zapret_custom_firewall_nft()
{
    local table mark chain
    table="${ZAPRET_NFT_TABLE:-zapret}"
    mark="${DESYNC_MARK_POSTNAT:-0x20000000}"

    chain=$(nft list chain inet "$table" predefrag_nfqws 2>/dev/null) || return 0
    case "$chain" in *sonar-udp-conntrack*) return 0 ;; esac

    nft insert rule inet "$table" predefrag_nfqws \
        meta nfproto ipv4 meta l4proto udp \
        meta mark and "$mark" != 0 \
        ip frag-off and 0x3fff == 0 \
        counter return comment '"sonar-udp-conntrack"' || {
        echo "zapret-sonar: не удалось установить правило UDP conntrack" >&2
        return 1
    }
}
EOF

    if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 0
    fi

    chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
    chown root:root "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    return 0
}

# --- Режим ipset -------------------------------------------------------------
# Flowseal переключает ipset-all.txt тремя состояниями (service.bat:948-1013):
#   loaded — реальный список IP/подсетей;
#   none   — файл с единственной заглушкой 203.0.113.113/32 (ничего не матчит);
#   any    — пустой файл (nfqws трактует как «любой IP подходит»).
# Полный список хранится в ipset-all.txt.backup.
#
# Списки Flowseal приходят в CRLF. Для nfqws это безвредно — он сам режет
# \r при чтении (nfq/hostlist.c:12, nfq/ipset.c:19), поэтому файлы не
# конвертируются. Но сравнивать с заглушкой надо без учёта \r.
ZF_IPSET_STUB="203.0.113.113/32"

zf_ipset_mode() {
    local f="$1/ipset-all.txt"
    [[ -f "$f" ]] || { printf 'unknown\n'; return 0; }
    if [[ ! -s "$f" ]]; then
        printf 'any\n'
    elif tr -d '\r' < "$f" | grep -qxF "$ZF_IPSET_STUB"; then
        printf 'none\n'
    else
        printf 'loaded\n'
    fi
}

# zf_set_ipset_mode LISTS_DIR MODE
zf_set_ipset_mode() {
    local lists_dir="$1" mode="$2" sync_marker="${3:-1}"
    local f="$lists_dir/ipset-all.txt" b="$lists_dir/ipset-all.txt.backup"
    local cur; cur=$(zf_ipset_mode "$lists_dir")
    if [[ "$cur" == "$mode" ]]; then
        if (( sync_marker )); then zf_write_state_marker ipset "$mode"; else return 0; fi
        return
    fi

    # Полный список нельзя потерять: перед уходом из loaded сохраняем его.
    if [[ "$cur" == "loaded" && ! -f "$b" ]]; then
        cp -a "$f" "$b" || return 1
    fi

    local tmp previous
    tmp=$(mktemp "$lists_dir/.ipset-all.XXXXXX") || return 1
    previous=$(mktemp "$lists_dir/.ipset-previous.XXXXXX") || { rm -f "$tmp"; return 1; }
    cp -a "$f" "$previous" || { rm -f "$tmp" "$previous"; return 1; }
    case "$mode" in
        none) printf '%s\n' "$ZF_IPSET_STUB" > "$tmp" || { rm -f "$tmp" "$previous"; return 1; } ;;
        any)  : > "$tmp" ;;
        loaded)
            if [[ ! -f "$b" ]]; then
                printf 'zconfig: нет ipset-all.txt.backup — восстановить список нечем\n' >&2
                rm -f "$tmp" "$previous"
                return 1
            fi
            cp -a "$b" "$tmp" || { rm -f "$tmp" "$previous"; return 1; } ;;
        *) rm -f "$tmp" "$previous"; printf 'zconfig: неизвестный режим ipset: %s\n' "$mode" >&2; return 1 ;;
    esac
    chmod 644 "$tmp" || { rm -f "$tmp" "$previous"; return 1; }
    mv -f "$tmp" "$f" || { rm -f "$tmp" "$previous"; return 1; }
    if (( sync_marker )) && ! zf_write_state_marker ipset "$mode"; then
        mv -f "$previous" "$f" || true
        return 1
    fi
    rm -f "$previous"
}
