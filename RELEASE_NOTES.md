## Изменения

- Исправлена потеря conntrack-записи при UDP-обходе в POSTNAT-режиме: сгенерированные `nfqws` копии больше не остаются `notrack`, поэтому ответы не дропаются локальным firewall как `INVALID`. Сбой проявлялся как ошибка «Не установлен маршрут» в Discord при подключении к голосовому каналу и как недоступный Discord HTTP/3 при активном обходе.
- Хук ограничен UDP нефрагментированного IPv4 и не затрагивает TCP, IPv6 и фрагменты, для которых `notrack` нужен по другим причинам.
- Хук ставится установщиком до первого старта и восстанавливается при каждой смене стратегии.
- `sonar self-update` перезаписывает файл хука сразу, но правило применяется при следующем перезапуске сервиса: до этого `sonar doctor` честно покажет, что хук не применён.
- `sonar doctor` проверяет наличие правила и его позицию: отдельно сообщается об отсутствующем хуке, о хуке, который есть, но не применён до перезапуска, и о правиле, стоящем после `notrack`. Если POSTNAT не используется, проверка возвращает `SKIP`.
- `sonar check` при провале Discord HTTP/3 с рабочей контрольной целью печатает подсказку про локальный UDP-conntrack и `doctor`.
- Добавлен regression-тест генерации хука, расширены тесты `doctor` и VM-матрицы: структурная проверка порядка правила и дифференциальная проверка conntrack с хуком и без него.
- Фоновая проверка обновлений в тестах стала офлайн-детерминированной: воркер запускается отдельным процессом и больше не зависит от реальных релизов GitHub.

## Ограничения

- HTTP/3 probe по-прежнему проверяет одну Discord HTTP-цель и не проверяет Discord Voice/STUN.
- Успешный `check` не доказывает работу голоса: это разные проверки.
- Хук лечит локальную потерю conntrack, но не помогает, если UDP фильтруется на стороне провайдера.

## English summary

- Fixed conntrack loss for UDP copies in POSTNAT mode: generated `nfqws` copies are no longer left `notrack`, so replies are not dropped as `INVALID` by a local firewall. The failure showed up as a Discord voice "No route" error and as unreachable Discord HTTP/3 while the bypass was active.
- The hook is limited to unfragmented IPv4 UDP and leaves TCP, IPv6, and fragments untouched.
- The installer writes the hook before the first start, and every strategy change restores it. `sonar self-update` rewrites the file immediately; the rule applies after the next service restart, and `sonar doctor` reports the gap until then.
- `sonar doctor` reports a missing hook, a hook that is present but not applied, and a rule placed after `notrack`; it returns `SKIP` when POSTNAT is not used.
- `sonar check` prints a UDP-conntrack hint when Discord HTTP/3 fails while the control target works.
- Added a hook-generation regression test, extended doctor tests, and added structural ordering and differential conntrack checks to the VM lifecycle matrix.
- Limitations: the hook does not help when UDP is filtered upstream, and a passing `check` does not prove voice works.
