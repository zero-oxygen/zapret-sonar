## Изменения

- Добавлен структурированный `sonar check --json-v2` с категориями HTTP, content, speed и QUIC.
- Старый `sonar check --json` сохранён для совместимых интеграций.
- Добавлена проверка Discord через `curl --http3-only` без TCP fallback и proxy.
- Добавлены явные состояния `PASS`, `FAIL` и `NOT_CHECKED` с причинами и измерениями.
- Заменена устаревшая versioned Discord media target на официальный stable download endpoint.
- Обновлены TUI, документация, regression tests и screenshots.

## Ограничения

- HTTP/3 probe проверяет одну Discord HTTP-цель и не проверяет Discord Voice/STUN.
- Результаты зависят от сети, DNS, маршрута, версии curl и доступности контрольной цели.
- `NOT_CHECKED` не является доказательством доступности или блокировки.

## English summary

- Added structured `sonar check --json-v2` results for HTTP, content, speed, and QUIC.
- Preserved the legacy `sonar check --json` contract for existing integrations.
- Added a direct Discord HTTP/3 probe using `curl --http3-only` without TCP fallback or proxies.
- Added explicit `PASS`, `FAIL`, and `NOT_CHECKED` states with reasons and measurements.
- Replaced the versioned Discord media target with the official stable download endpoint.
