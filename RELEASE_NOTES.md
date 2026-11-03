## Изменения

- Исправлена потеря conntrack-записи при UDP-обходе в POSTNAT-режиме: сгенерированные `nfqws` копии больше не остаются `notrack`, поэтому ответы не сопоставляются с записью и не режутся политикой firewall по умолчанию. Сбой проявлялся как ошибка «Не установлен маршрут» в Discord при подключении к голосовому каналу и как недоступный Discord HTTP/3 при активном обходе.
- Хук ограничен UDP нефрагментированного IPv4: TCP, IPv6 и фрагменты не затрагиваются.
- Хук ставится установщиком до первого старта и восстанавливается при каждой смене стратегии.
- При обновлении с 1.4.0 хук появляется не сразу: `sonar self-update` переключает только код, поэтому после него нужно применить стратегию (`sonar use`/`try`) или переустановить; `sonar doctor` до этого покажет отсутствие хука. Начиная с 1.4.1 self-update перезаписывает файл хука сам, а правило применяется после перезапуска сервиса.
- `sonar doctor` проверяет наличие правила и его позицию: отдельно сообщается об отсутствующем хуке, о хуке, который есть, но не применён до перезапуска, и о правиле, стоящем после `notrack`.
- `sonar check` при провале Discord HTTP/3 с рабочей контрольной целью печатает подсказку про локальный UDP-conntrack и `doctor`.
- Добавлен regression-тест генерации хука, расширены тесты `doctor` и VM-матрицы: структурная проверка порядка правила и дифференциальная проверка conntrack с хуком и без него.
- Фоновая проверка обновлений в тестах стала офлайн-детерминированной: воркер запускается отдельным процессом и больше не зависит от реальных релизов GitHub.

## Ограничения

- HTTP/3 probe по-прежнему проверяет одну Discord HTTP-цель и не проверяет Discord Voice/STUN.
- Успешный `check` не доказывает работу голоса: это разные проверки.
- Хук лечит локальную потерю conntrack, но не помогает, если UDP фильтруется на стороне провайдера.

## English summary

- Fixed conntrack loss for UDP copies in POSTNAT mode: generated `nfqws` copies are no longer left `notrack`, so replies are not matched against the entry and are not dropped by the default firewall policy. The failure showed up as a Discord voice "No route" error and as unreachable Discord HTTP/3 while the bypass was active.
- The hook is limited to unfragmented IPv4 UDP; TCP, IPv6, and fragments are untouched.
- The installer writes the hook before the first start, and every strategy change restores it.
- When upgrading from 1.4.0 the hook is not there immediately: `sonar self-update` only switches the code, so a strategy apply (`sonar use`/`try`) or a reinstall is needed afterwards, and `sonar doctor` reports the missing hook until then. Starting with 1.4.1, self-update rewrites the hook file itself and the rule applies after the next service restart.
- `sonar doctor` reports a missing hook, a hook that is present but not applied, and a rule placed after `notrack`.
- `sonar check` prints a UDP-conntrack hint when Discord HTTP/3 fails while the control target works.
- Added a hook-generation regression test, extended doctor tests, and added structural ordering and differential conntrack checks to the VM lifecycle matrix.
- Limitations: the hook does not help when UDP is filtered upstream, and a passing `check` does not prove voice works.
