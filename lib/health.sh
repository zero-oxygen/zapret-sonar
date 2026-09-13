#!/usr/bin/env bash
# ============================================================================
# lib/health.sh — проверка, работает ли обход
#
# Двухуровневая проверка, потому что HTTP-кода недостаточно:
#
#   1. HTTP-код — быстро, но ТСПУ умеет отдавать 200 с заглушкой или рвать
#      соединение на середине ответа.
#   2. Медиа-проверка — скачивается кусочек реального файла с CDN и
#      сверяются объём и magic bytes. Ловит throttling и подмену контента,
#      которые по коду 200 неотличимы от нормы.
#
# Проверка ничего не переключает и не пишет в конфиг: это индикатор для
# пользователя, а не автопилот. Решение о смене стратегии принимает человек.
# ============================================================================

[[ -n "${_ZF_HEALTH_SH:-}" ]] && return 0
_ZF_HEALTH_SH=1

ZF_HEALTH_TIMEOUT="${ZF_HEALTH_TIMEOUT:-8}"
ZF_HEALTH_QUIC_TIMEOUT="${ZF_HEALTH_QUIC_TIMEOUT:-5}"
ZF_HEALTH_INCLUDE_QUIC="${ZF_HEALTH_INCLUDE_QUIC:-1}"

# Цвета для CLI-вывода: включаются только в интерактивном терминале.
# В параллельном режиме (fork) наследуются дочерними процессами.
if [[ -t 1 ]]; then
    _ZF_C_OK=$'\033[32m' _ZF_C_BAD=$'\033[31m' _ZF_C_WARN=$'\033[33m' _ZF_C_DIM=$'\033[2m' _ZF_C_OFF=$'\033[0m'
else
    _ZF_C_OK='' _ZF_C_BAD='' _ZF_C_WARN='' _ZF_C_DIM='' _ZF_C_OFF=''
fi

ZF_HEALTH_PASSED=0
ZF_HEALTH_FAILED=0
ZF_HEALTH_SKIPPED=0
ZF_HEALTH_NOT_CHECKED=0
ZF_HEALTH_RESULTS=()

# Цели HTTP-проверки: "URL"
# Проверяем все ключевые точки: web, api, gateway для Discord и google/youtube
ZF_HEALTH_HOSTS=(
    "https://www.youtube.com"
    "https://discord.com"
    "https://gateway.discord.gg"
    "https://discord.com/api/v9/experiments"
)

# Отдельный набор для проверки конкретной стратегии: только те цели, что
# действительно блокируются. Смысл в том, что незаблокированный ресурс
# отвечает 200 и без обхода, поэтому по нему нельзя судить о стратегии.
ZF_HEALTH_TARGETS_STRICT=(
    "https://discord.com"
    "https://gateway.discord.gg"
    "https://discord.com/api/v9/experiments"
    "https://cdn.discordapp.com/embed/avatars/0.png"
)

# Цели контроля регрессии: ресурсы, которые работают и БЕЗ обхода. Неудачная
# стратегия способна их сломать (замерено: ALT2 роняет youtube.com в 000,
# при этом снимая блокировку Discord). Стратегия, открывшая заблокированное
# но убившая работавшее, — не рабочая.
ZF_HEALTH_TARGETS_CONTROL=(
    "https://www.youtube.com"
    "https://www.google.com"
    "https://yt3.ggpht.com/a/default-user=s88-c-k-c0x00ffffff-no-rj"
)

# Заполняется zf_baseline: какие цели заблокированы, а какие работали до
# включения обхода. Перебор стратегий опирается на этот замер.
ZF_BASELINE_BLOCKED=()
ZF_BASELINE_WORKING=()

# Цели медиа-проверки: "URL|min_bytes|magic_hex|min_speed_kb"
# 1. Аватарка Google / YT (проверка целостности и сигнатуры JPEG)
# 2. Аватарка Discord CDN (проверка целостности и сигнатуры PNG)
# 3. Текущий stable Discord tarball (бинарный блок с замером скорости для отсечения throttling)
ZF_HEALTH_MEDIA=(
    "https://yt3.ggpht.com/a/default-user=s88-c-k-c0x00ffffff-no-rj|1000|ffd8ff|0"
    "https://cdn.discordapp.com/embed/avatars/0.png|500|89504e47|0"
    "https://discord.com/api/download?platform=linux&format=tar.gz|1000000||200"
)

ZF_HEALTH_QUIC_TARGET="${ZF_HEALTH_QUIC_TARGET:-https://discord.com/api/v9/experiments}"
ZF_HEALTH_QUIC_CONTROL="${ZF_HEALTH_QUIC_CONTROL:-https://cloudflare-quic.com/}"

# --- Хекс первых N байт файла ------------------------------------------------
# xxd есть не везде; od — часть coreutils и есть всегда. В fallback критично
# удалять и пробелы, и переводы строк: od выводит "ff d8 ff".
_zf_head_hex() {
    local file="$1" nbytes="$2"
    if command -v xxd >/dev/null 2>&1; then
        xxd -p -l "$nbytes" "$file" 2>/dev/null | tr -d '\n'
    else
        od -An -tx1 -N "$nbytes" "$file" 2>/dev/null | tr -d ' \n'
    fi
}

# --- Общий критерий «код = успех» ---------------------------------------------
# Единый источник правды для baseline и scoring: 404 для gateway.discord.gg —
# нормальный ответ эндпоинта, 204 — No Content (некоторые API). Без этой
# функции baseline и scoring расходились: gateway помечался как «заблокирован»
# в baseline (404 не матчило 200|301|…), но «исправлен» в scoring (где 404
# принят), раздувая счётчик fixed.
_zf_code_ok() {
    local url="$1" code="$2"
    [[ "$url" =~ gateway\.discord\.gg && "$code" == "404" ]] && return 0
    [[ "$code" =~ ^(200|204|301|302|303|307|308)$ ]]
}

# --- HTTP-проверка -----------------------------------------------------------
# zf_check_host URL → 0 = доступен. Печатает строку отчёта.
# Ожидаются только валидные коды: 404 для gateway.discord.gg это норма (эндпоинт отвечает),
# для остальных — 200|204|301|302|303|307|308.
_zf_health_write_result() {
    local file="$1" category="$2" target="$3" status="$4" reason="$5"
    local http_code="${6:--}" bytes="${7:--}" speed_kbps="${8:--}"
    local http_version="${9:--}" curl_exit_code="${10:--}" control_status="${11:--}"
    local control_target="${12:--}"
    [[ -n "$file" ]] || return 0
    [[ -n "$http_code" ]] || http_code=-
    [[ -n "$bytes" ]] || bytes=-
    [[ -n "$speed_kbps" ]] || speed_kbps=-
    [[ -n "$http_version" ]] || http_version=-
    [[ -n "$curl_exit_code" ]] || curl_exit_code=-
    [[ -n "$control_status" ]] || control_status=-
    [[ -n "$control_target" ]] || control_target=-
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$category" "$target" "$status" "$reason" "$http_code" "$bytes" "$speed_kbps" \
        "$http_version" "$curl_exit_code" "$control_status" "$control_target" > "$file"
}

zf_check_host() {
    local url="$1" result_file="${2:-}" code
    code=$(LC_ALL=C curl -o /dev/null -s -m "$ZF_HEALTH_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null) || code="000"
    if _zf_code_ok "$url" "$code"; then
        printf '  %sOK%s    %-42s HTTP %s\n' "$_ZF_C_OK" "$_ZF_C_OFF" "$url" "$code"
        _zf_health_write_result "$result_file" http "$url" PASS http_response "$code"
        return 0
    fi
    if [[ "$code" == "000" ]]; then
        printf '  %sFAIL%s  %-42s нет соединения (таймаут/обрыв)\n' "$_ZF_C_BAD" "$_ZF_C_OFF" "$url"
        _zf_health_write_result "$result_file" http "$url" FAIL connection_failed
    else
        printf '  %sFAIL%s  %-42s HTTP %s\n' "$_ZF_C_BAD" "$_ZF_C_OFF" "$url" "$code"
        _zf_health_write_result "$result_file" http "$url" FAIL http_status "$code"
    fi
    return 1
}

# --- Медиа-проверка и замер скорости ------------------------------------------
# zf_check_media возвращает 0=PASS, 1=FAIL, 2=NOT_CHECKED.
zf_check_media() {
    local spec="$1"
    local result_file="${2:-}"
    local url="${spec%%|*}" rest="${spec#*|}"
    local min_bytes="${rest%%|*}" rest2="${rest#*|}"
    local magic="${rest2%%|*}" min_speed_kb="${rest2#*|}"
    [[ "$min_speed_kb" == "$magic" ]] && min_speed_kb="0"
    local tmp size speed_bps speed_kb actual rc=0

    tmp=$(mktemp) || return 1
    # Если указан min_speed_kb > 0, тянем порцию до 512 КБ для надёжного замера скорости.
    # Если min_speed_kb == 0, качаем файл целиком (для проверки сигнатур аватарок).
    local range_opt=()
    (( min_speed_kb > 0 )) && range_opt=(-r "0-$((min_bytes * 2))")

    local curl_out
    curl_out=$(LC_ALL=C curl -s -L --max-redirs 3 --proto '=https' --proto-redir '=https' \
        -m "$ZF_HEALTH_TIMEOUT" "${range_opt[@]}" -w '%{http_code}|%{speed_download}' \
        -o "$tmp" "$url" 2>/dev/null) || curl_out="000|0"
    local http_code="${curl_out%%|*}"
    speed_bps="${curl_out##*|}"
    speed_kb=$(( ${speed_bps%%[.,]*} / 1024 ))

    # 404/410 на медиа-цели — не сбой обхода, а устаревший URL (версия снята с CDN).
    # 451 означает блокировку по юридическим причинам и считается ошибкой.
    if [[ "$http_code" =~ ^(404|410)$ ]]; then
        printf '  %sNOT CHECKED%s  %-42s HTTP %s — цель устарела\n' "$_ZF_C_DIM" "$_ZF_C_OFF" "$url" "$http_code"
        _zf_health_write_result "$result_file" "$([[ $min_speed_kb -gt 0 ]] && printf speed || printf content)" \
            "$url" NOT_CHECKED stale_target "$http_code"
        rm -f "$tmp"
        return 2
    fi
    if ! [[ "$http_code" =~ ^(200|206)$ ]]; then
        printf '  %sFAIL%s  %-42s HTTP %s (нет соединения)\n' "$_ZF_C_BAD" "$_ZF_C_OFF" "$url" "$http_code"
        _zf_health_write_result "$result_file" "$([[ $min_speed_kb -gt 0 ]] && printf speed || printf content)" \
            "$url" FAIL http_status "$http_code"
        rm -f "$tmp"
        return 1
    fi

    size=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
    if (( size < min_bytes )); then
        printf '  %sFAIL%s  %-42s %s байт (ждали ≥%s) — обрыв\n' "$_ZF_C_BAD" "$_ZF_C_OFF" "$url" "$size" "$min_bytes"
        _zf_health_write_result "$result_file" "$([[ $min_speed_kb -gt 0 ]] && printf speed || printf content)" \
            "$url" FAIL response_too_small "$http_code" "$size" "$speed_kb"
        rm -f "$tmp"
        return 1
    fi

    if (( min_speed_kb > 0 && speed_kb < min_speed_kb )); then
        printf '  %sFAIL%s  %-42s скорость %s КБ/с (минимум %s КБ/с) — throttling\n' \
            "$_ZF_C_BAD" "$_ZF_C_OFF" "$url" "$speed_kb" "$min_speed_kb"
        _zf_health_write_result "$result_file" speed "$url" FAIL below_speed_threshold \
            "$http_code" "$size" "$speed_kb"
        rm -f "$tmp"
        return 1
    fi

    if [[ -n "$magic" ]]; then
        actual=$(_zf_head_hex "$tmp" "$(( ${#magic} / 2 ))")
        if [[ -z "$actual" ]]; then
            printf '  %sWARN%s  %-42s %s байт, сигнатуру проверить нечем\n' "$_ZF_C_WARN" "$_ZF_C_OFF" "$url" "$size"
            _zf_health_write_result "$result_file" content "$url" NOT_CHECKED signature_unavailable \
                "$http_code" "$size" "$speed_kb"
            rm -f "$tmp"
            return 2
        fi
        if [[ "${actual,,}" != "${magic,,}" ]]; then
            printf '  %sFAIL%s  %-42s %s байт, сигнатура %s ≠ %s — подмена\n' \
                "$_ZF_C_BAD" "$_ZF_C_OFF" "$url" "$size" "$actual" "$magic"
            _zf_health_write_result "$result_file" content "$url" FAIL signature_mismatch \
                "$http_code" "$size" "$speed_kb"
            rm -f "$tmp"
            return 1
        fi
    fi

    if (( min_speed_kb > 0 )); then
        printf '  %sOK%s    %-42s %s байт (%s КБ/с, тест скорости пройден)\n' "$_ZF_C_OK" "$_ZF_C_OFF" "$url" "$size" "$speed_kb"
        _zf_health_write_result "$result_file" speed "$url" PASS speed_threshold_met \
            "$http_code" "$size" "$speed_kb"
    else
        printf '  %sOK%s    %-42s %s байт, сигнатура совпала\n' "$_ZF_C_OK" "$_ZF_C_OFF" "$url" "$size"
        _zf_health_write_result "$result_file" content "$url" PASS signature_match \
            "$http_code" "$size" "$speed_kb"
    fi
    rm -f "$tmp"
    return $rc
}

# --- HTTP/3/QUIC -------------------------------------------------------------
# Проверка намеренно использует --http3-only: --http3 допускает fallback на TCP
# и не доказывает, что запрос действительно прошёл через QUIC.
_zf_curl_has_http3() {
    local version help
    command -v curl >/dev/null 2>&1 || return 1
    version=$(LC_ALL=C curl -q --version 2>/dev/null) || return 1
    awk '/^Features:/ { for (i = 2; i <= NF; i++) if ($i == "HTTP3") found=1 } END { exit !found }' \
        <<< "$version" || return 1
    help=$(LC_ALL=C curl -q --help all 2>/dev/null) || return 1
    grep -q -- '--http3-only' <<< "$help"
}

_zf_http3_request() {
    local url="$1" out rc
    if out=$(LC_ALL=C curl -q --http3-only --noproxy '*' \
        --connect-timeout "$ZF_HEALTH_QUIC_TIMEOUT" --max-time "$ZF_HEALTH_QUIC_TIMEOUT" \
        --silent --show-error --output /dev/null --write-out '%{http_code}|%{http_version}' \
        "$url" 2>/dev/null); then
        rc=0
    else
        rc=$?
    fi
    ZF_HTTP3_EXIT_CODE=$rc
    ZF_HTTP3_HTTP_CODE="${out%%|*}"
    ZF_HTTP3_VERSION="${out##*|}"
}

_zf_http3_succeeded() {
    (( ZF_HTTP3_EXIT_CODE == 0 )) \
        && [[ "$ZF_HTTP3_VERSION" == 3 && "$ZF_HTTP3_HTTP_CODE" =~ ^[1-5][0-9][0-9]$ ]]
}

zf_check_quic() {
    local result_file="${1:-}" target_rc target_code target_version
    if ! _zf_curl_has_http3; then
        printf '  %sNOT CHECKED%s  %-42s curl без HTTP/3\n' \
            "$_ZF_C_DIM" "$_ZF_C_OFF" "$ZF_HEALTH_QUIC_TARGET"
        _zf_health_write_result "$result_file" quic "$ZF_HEALTH_QUIC_TARGET" \
            NOT_CHECKED http3_unsupported
        return 2
    fi

    _zf_http3_request "$ZF_HEALTH_QUIC_TARGET"
    target_rc=$ZF_HTTP3_EXIT_CODE
    target_code=$ZF_HTTP3_HTTP_CODE
    target_version=$ZF_HTTP3_VERSION
    if _zf_http3_succeeded; then
        printf '  %sOK%s    %-42s HTTP/%s %s\n' \
            "$_ZF_C_OK" "$_ZF_C_OFF" "$ZF_HEALTH_QUIC_TARGET" "$target_version" "$target_code"
        _zf_health_write_result "$result_file" quic "$ZF_HEALTH_QUIC_TARGET" PASS \
            http3_response "$target_code" "" "" "$target_version" "$target_rc"
        return 0
    fi
    if (( target_rc == 4 )); then
        printf '  %sNOT CHECKED%s  %-42s HTTP/3 не поддерживается curl\n' \
            "$_ZF_C_DIM" "$_ZF_C_OFF" "$ZF_HEALTH_QUIC_TARGET"
        _zf_health_write_result "$result_file" quic "$ZF_HEALTH_QUIC_TARGET" \
            NOT_CHECKED http3_unsupported "" "" "" "$target_version" "$target_rc"
        return 2
    fi

    _zf_http3_request "$ZF_HEALTH_QUIC_CONTROL"
    if _zf_http3_succeeded; then
        printf '  %sFAIL%s  %-42s HTTP/3 недоступен (контрольная цель работает)\n' \
            "$_ZF_C_BAD" "$_ZF_C_OFF" "$ZF_HEALTH_QUIC_TARGET"
        _zf_health_write_result "$result_file" quic "$ZF_HEALTH_QUIC_TARGET" FAIL \
            target_http3_failed "$target_code" "" "" "$target_version" "$target_rc" PASS \
            "$ZF_HEALTH_QUIC_CONTROL"
        return 1
    fi

    printf '  %sNOT CHECKED%s  %-42s HTTP/3 недоступен и на контрольной цели\n' \
        "$_ZF_C_DIM" "$_ZF_C_OFF" "$ZF_HEALTH_QUIC_TARGET"
    _zf_health_write_result "$result_file" quic "$ZF_HEALTH_QUIC_TARGET" NOT_CHECKED \
        control_http3_failed "$target_code" "" "" "$target_version" "$target_rc" FAIL \
        "$ZF_HEALTH_QUIC_CONTROL"
    return 2
}

# --- Полная проверка ---------------------------------------------------------
# zf_health_check → 0 если всё прошло. Печатает отчёт.
# HTTP- и медиа-проверки запускаются параллельно для скорости.
zf_health_check() {
    local failed=0 skipped=0 total=0 url spec rc
    ZF_HEALTH_PASSED=0
    ZF_HEALTH_FAILED=0
    ZF_HEALTH_SKIPPED=0
    ZF_HEALTH_NOT_CHECKED=0
    ZF_HEALTH_RESULTS=()
    local tmp_dir; tmp_dir=$(mktemp -d) || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" RETURN

    local i=0
    for url in "${ZF_HEALTH_HOSTS[@]}"; do
        total=$((total + 1))
        ( zf_check_host "$url" "$tmp_dir/http_$i.result" > "$tmp_dir/http_$i.out" 2>&1; echo $? > "$tmp_dir/http_$i.rc" ) &
        i=$((i + 1))
    done

    local j=0
    for spec in "${ZF_HEALTH_MEDIA[@]}"; do
        total=$((total + 1))
        ( zf_check_media "$spec" "$tmp_dir/media_$j.result" > "$tmp_dir/media_$j.out" 2>&1; echo $? > "$tmp_dir/media_$j.rc" ) &
        j=$((j + 1))
    done

    if [[ "$ZF_HEALTH_INCLUDE_QUIC" == 1 ]]; then
        total=$((total + 1))
        ( zf_check_quic "$tmp_dir/quic.result" > "$tmp_dir/quic.out" 2>&1; echo $? > "$tmp_dir/quic.rc" ) &
    fi

    wait

    printf 'HTTP-доступность:\n'
    i=0
    for url in "${ZF_HEALTH_HOSTS[@]}"; do
        cat "$tmp_dir/http_$i.out" 2>/dev/null
        [[ -f "$tmp_dir/http_$i.result" ]] && ZF_HEALTH_RESULTS+=("$(cat "$tmp_dir/http_$i.result")")
        [[ "$(cat "$tmp_dir/http_$i.rc" 2>/dev/null)" != "0" ]] && failed=$((failed + 1))
        i=$((i + 1))
    done

    local media_category spec_speed
    for media_category in content speed; do
        [[ "$media_category" == content ]] && printf 'Целостность контента:\n' || printf 'Скорость загрузки:\n'
        j=0
        for spec in "${ZF_HEALTH_MEDIA[@]}"; do
            spec_speed=${spec##*|}
            if { [[ "$media_category" == content ]] && (( spec_speed == 0 )); } \
                || { [[ "$media_category" == speed ]] && (( spec_speed > 0 )); }; then
                cat "$tmp_dir/media_$j.out" 2>/dev/null
                [[ -f "$tmp_dir/media_$j.result" ]] && ZF_HEALTH_RESULTS+=("$(cat "$tmp_dir/media_$j.result")")
                rc=$(cat "$tmp_dir/media_$j.rc" 2>/dev/null)
                case "$rc" in
                    0) ;;
                    2) skipped=$((skipped + 1)) ;;
                    *) failed=$((failed + 1)) ;;
                esac
            fi
            j=$((j + 1))
        done
    done

    if [[ "$ZF_HEALTH_INCLUDE_QUIC" == 1 ]]; then
        printf 'HTTP/3 (QUIC):\n'
        cat "$tmp_dir/quic.out" 2>/dev/null
        [[ -f "$tmp_dir/quic.result" ]] && ZF_HEALTH_RESULTS+=("$(cat "$tmp_dir/quic.result")")
        rc=$(cat "$tmp_dir/quic.rc" 2>/dev/null)
        case "$rc" in
            0) ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    fi

    rm -rf "$tmp_dir"
    ZF_HEALTH_PASSED=$((total - failed - skipped))
    # shellcheck disable=SC2034
    ZF_HEALTH_FAILED=$failed
    # shellcheck disable=SC2034
    ZF_HEALTH_SKIPPED=$skipped
    # shellcheck disable=SC2034
    ZF_HEALTH_NOT_CHECKED=$skipped
    if (( failed == 0 )); then
        printf '\n%sИтог: %d пройдено, %d не проверено, %d ошибок%s\n' \
            "$_ZF_C_OK" "$ZF_HEALTH_PASSED" "$skipped" "$failed" "$_ZF_C_OFF"
    else
        printf '\n%sИтог: %d пройдено, %d не проверено, %d ошибок%s\n' \
            "$_ZF_C_BAD" "$ZF_HEALTH_PASSED" "$skipped" "$failed" "$_ZF_C_OFF"
    fi
    (( failed == 0 ))
}

# --- Базовая линия -----------------------------------------------------------
# zf_baseline — замер состояния БЕЗ обхода. Вызывать при остановленном сервисе.
#
# Замеряется два набора:
#   • цели из ZF_HEALTH_TARGETS_STRICT — что заблокировано (по ним судим,
#     сработала ли стратегия);
#   • цели из ZF_HEALTH_TARGETS_CONTROL — что работало до обхода (по ним
#     ловим регрессию: стратегия не должна ломать доступное).
#
# Результат складывается в ZF_BASELINE_BLOCKED / ZF_BASELINE_WORKING.
zf_baseline() {
    local url code
    ZF_BASELINE_BLOCKED=()
    ZF_BASELINE_WORKING=()

    local tmp_dir; tmp_dir=$(mktemp -d) || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" RETURN

    local -a all_urls=("${ZF_HEALTH_TARGETS_STRICT[@]}" "${ZF_HEALTH_TARGETS_CONTROL[@]}")
    local i=0
    for url in "${all_urls[@]}"; do
        (
            code=$(LC_ALL=C curl -o /dev/null -s -m "$ZF_HEALTH_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null) || code="000"
            printf '%s|%s' "$url" "$code" > "$tmp_dir/result_$i"
        ) &
        i=$((i + 1))
    done
    wait

    printf 'Замер целей:\n'
    i=0
    for url in "${all_urls[@]}"; do
        local line; line=$(cat "$tmp_dir/result_$i" 2>/dev/null)
        code="${line#*|}"
        if _zf_code_ok "$url" "$code"; then
            printf '  %sдоступен%s             %-42s HTTP %s\n' "$_ZF_C_OK" "$_ZF_C_OFF" "$url" "$code"
            ZF_BASELINE_WORKING+=("$url")
        else
            printf '  %sЗАБЛОКИРОВАН%s         %-42s %s\n' "$_ZF_C_BAD" "$_ZF_C_OFF" "$url" "$code"
            ZF_BASELINE_BLOCKED+=("$url")
        fi
        i=$((i + 1))
    done

    rm -rf "$tmp_dir"

    if (( ${#ZF_BASELINE_BLOCKED[@]} == 0 )); then
        printf '\nНи одна цель не блокируется — проверить эффективность стратегий нечем.\n'
        return 1
    fi
    printf '\nЗаблокировано: %d (проверяем обход) | работает: %d (проверяем регрессию)\n' \
        "${#ZF_BASELINE_BLOCKED[@]}" "${#ZF_BASELINE_WORKING[@]}"
    return 0
}

# --- Оценка стратегии относительно базовой линии ------------------------------
# zf_score_strategy — печатает вердикт и возвращает:
#   0 — обход работает и ничего не сломано;
#   1 — обход не работает;
#   2 — обход работает, но сломаны ранее доступные ресурсы (регрессия).
#
# Третий случай выделен отдельно, потому что он самый коварный: проверка
# «только по заблокированным целям» показала бы успех. Замерено на ALT2:
# Discord открывается, а youtube.com перестаёт отвечать вовсе.
zf_score_strategy() {
    local url code fixed=0 still=0 broke=0
    local -a broken=()

    local tmp_dir; tmp_dir=$(mktemp -d) || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" RETURN

    local -a all_urls=("${ZF_BASELINE_BLOCKED[@]}" "${ZF_BASELINE_WORKING[@]}")
    local i=0
    for url in "${all_urls[@]}"; do
        (
            code=$(LC_ALL=C curl -o /dev/null -s -m "$ZF_HEALTH_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null) || code="000"
            printf '%s|%s' "$url" "$code" > "$tmp_dir/result_$i"
        ) &
        i=$((i + 1))
    done
    wait

    i=0
    for url in "${ZF_BASELINE_BLOCKED[@]}"; do
        local line; line=$(cat "$tmp_dir/result_$i" 2>/dev/null)
        code="${line#*|}"
        if _zf_code_ok "$url" "$code"; then
            fixed=$((fixed + 1))
        else
            still=$((still + 1))
        fi
        i=$((i + 1))
    done

    for url in "${ZF_BASELINE_WORKING[@]}"; do
        local line; line=$(cat "$tmp_dir/result_$i" 2>/dev/null)
        code="${line#*|}"
        if ! _zf_code_ok "$url" "$code"; then
            broke=$((broke + 1)); broken+=("$url")
        fi
        i=$((i + 1))
    done

    rm -rf "$tmp_dir"

    if (( broke > 0 )); then
        printf '%sСЛОМАЛА%s %d/%d (обход %d/%d) — %s' \
            "$_ZF_C_BAD" "$_ZF_C_OFF" "$broke" "${#ZF_BASELINE_WORKING[@]}" "$fixed" "${#ZF_BASELINE_BLOCKED[@]}" "${broken[0]}"
        (( ${#broken[@]} > 1 )) && printf ' и ещё %d' "$(( ${#broken[@]} - 1 ))"
        printf '\n'
        return 2
    fi
    if (( still == 0 )); then
        printf '%sРАБОТАЕТ%s (%d/%d, регрессий нет)\n' "$_ZF_C_OK" "$_ZF_C_OFF" "$fixed" "${#ZF_BASELINE_BLOCKED[@]}"
        return 0
    fi
    printf '%sне работает%s (%d/%d)\n' "$_ZF_C_BAD" "$_ZF_C_OFF" "$fixed" "${#ZF_BASELINE_BLOCKED[@]}"
    return 1
}

# --- Предполётная проверка окружения -----------------------------------------
# Диагностика того, что искажает результаты проверок. Ничего не исправляет,
# только сообщает: причины могут быть намеренными (рабочий VPN, обход на
# роутере), и решать должен пользователь.
zf_preflight() {
    local warn=0

    # Открытый DNS позволяет провайдеру подменять ответы до подключения.
    # Проверка видит только системный DoT через systemd-resolved, но не DoH
    # браузера или роутера, поэтому это предупреждение, а не вердикт.
    if command -v resolvectl >/dev/null 2>&1; then
        local dns_status
        dns_status=$(resolvectl status 2>/dev/null)
        if [[ -n "$dns_status" ]] && ! printf '%s' "$dns_status" | grep -qE '\+DNSOverTLS|DNSOverTLS: yes'; then
            printf '  %sWARN%s  DNS без шифрования (нет DoT/DoH)\n' "$_ZF_C_WARN" "$_ZF_C_OFF"
            printf '        Secure DNS нужен при DNS-подмене; браузерный DoH здесь не определяется.\n'
            warn=$((warn + 1))
        fi
    fi

    # IPv6: конфиг задаёт DISABLE_IPV6=1, поэтому трафик по IPv6 идёт мимо
    # nfqws. Если у провайдера рабочий IPv6, YouTube/Google ходят по v6 —
    # обход не нужен и проверки дадут ложный результат.
    local v6addr
    v6addr=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6 || true)
    if (( v6addr > 0 )) && ip -6 route show default 2>/dev/null | grep -q .; then
        printf '  %sWARN%s  активен IPv6 (DISABLE_IPV6=1 в конфиге)\n' "$_ZF_C_WARN" "$_ZF_C_OFF"
        printf '        Трафик по IPv6 идёт мимо nfqws — проверки могут быть недостоверны.\n'
        warn=$((warn + 1))
    fi

    # Туннели: трафик может идти через VPN-туннель мимо nfqws, и тогда
    # «работает» ничего не доказывает. Исключаем только PPPoE-линки (ppp*)
    # — это WAN, а не туннель. Настоящие туннели (tun*/wg*/awg*) флагуем
    # ВСЕГДА, даже если они default route — full-tunnel VPN это главный кейс.
    local tun
    tun=$(ip -brief link show 2>/dev/null \
        | awk '$1 ~ /^(tun|wg|awg)/ && $0 ~ /UP/ {print $1}' \
        | paste -sd' ')
    if [[ -n "$tun" ]]; then
        printf '  %sWARN%s  активны туннели: %s\n' "$_ZF_C_WARN" "$_ZF_C_OFF" "$tun"
        printf '        Трафик может идти мимо nfqws — проверки недостоверны.\n'
        warn=$((warn + 1))
    fi

    # Конкурирующие обходы: два nfqws на одной очереди NFQUEUE конфликтуют.
    # Проверяем известные имена: zapret2 (Lua-форк) и zapret (оригинал bol-van,
    # если установлен штатно без нашей обёртки). Имя нашего сервиса не
    # проверяем — оно в $ZF_SERVICE, и активный сервис это мы сами.
    local other
    for other in zapret2 zapret; do
        [[ "$other" == "$ZF_SERVICE" ]] && continue
        if [[ "$(systemctl is-active "$other" 2>/dev/null)" == "active" ]]; then
            printf '  %sWARN%s  активен сервис %s — конфликт за NFQUEUE\n' "$_ZF_C_WARN" "$_ZF_C_OFF" "$other"
            warn=$((warn + 1))
        fi
    done

    (( warn == 0 )) && printf '  %sOK%s    окружение чистое\n' "$_ZF_C_OK" "$_ZF_C_OFF"
    return 0
}
