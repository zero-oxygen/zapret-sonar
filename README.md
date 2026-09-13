# zapret-sonar

[Русский](README.md) | [English](README.en.md)

<p align="center">
  <img src=".github/social-preview.png" alt="zapret-sonar" width="640">
</p>

Linux-обёртка над [zapret](https://github.com/bol-van/zapret) v1 со стратегиями [Flowseal](https://github.com/Flowseal/zapret-discord-youtube). Переводит `.bat`-стратегии Flowseal в аргументы `nfqws` и управляет установкой, подбором, проверкой и обновлением.

> zapret v1 находится в режиме EOL: upstream выпускает только исправления ошибок. zapret2 пока не поддерживается и исследуется отдельно.

## Быстрый старт

```bash
git clone https://github.com/zero-oxygen/zapret-sonar.git
cd zapret-sonar
sudo ./install.sh
sudo sonar try --keep
sonar check
sudo sonar enable
```

`try --keep` оставляет первую стратегию, прошедшую HTTP-проверки без обнаруженных регрессий. Это не означает, что она объективно лучшая для всех сайтов и протоколов. `enable` включает автозапуск уже настроенного сервиса.

На сервере или удалённой машине `try` временно останавливает и многократно перезапускает сервис, поэтому текущие соединения могут прерываться.

## Что это и что это не

- GNU/Linux-инструмент, ориентированный на `systemd`, `nfqws` и nftables.
- Не VPN и не прокси: трафик не отправляется на сторонний сервер.
- Не самостоятельный набор стратегий: стратегии и списки приходят из Flowseal.
- Результат зависит от провайдера, вида блокировки и конкретного протокола.
- Не устанавливайте поверх другого zapret: процессы и правила NFQUEUE будут конфликтовать.
- Для осознанной миграции обычной zapret v1 используйте `sudo env MIGRATE_ZAPRET=1 ./install.sh`; без этого установщик остановится.
- `sonar check` проверяет HTTP/CDN-цели и, при поддержке установленным `curl`, отдельно пробует Discord через HTTP/3 без TCP fallback. Успех не доказывает работу Discord Voice, видео YouTube или именно механизма zapret.

## Если не заработало

```bash
sonar doctor
sonar status
sonar baseline
sonar log
```

`baseline` сам временно останавливает активный сервис, выполняет замер без обхода и восстанавливает его состояние.

Проверьте также:

1. Secure DNS. DoT/DoH рекомендуется и необходим при DNS-подмене провайдером. `sonar status` видит системный DoT через `systemd-resolved`, но не браузерный DoH.
2. IPv6. Текущий конфиг задаёт `DISABLE_IPV6=1`; доступный IPv6 может обходить `nfqws`.
3. Туннели. Клиентский full-tunnel может направить проверки мимо локального `nfqws`. Серверный WG/AWG, чей транзит намеренно проходит через NFQUEUE, сам по себе не является ошибкой.
4. Если ни одна стратегия не помогает, используйте `/opt/zapret/blockcheck.sh` для более глубокого подбора параметров.

## Требования

- GNU/Linux с `systemd`;
- bash 4+, curl, tar, sha256sum, flock, iproute2 и стандартные GNU coreutils/findutils/grep/sed;
- nftables (рекомендуется) или iptables вместе с `ipset` и `ip6tables`;
- `restorecon` из policycoreutils на системах с активным SELinux;
- `unzip` нужен только для fallback-обновления из ветки Flowseal;
- fzf для TUI (опционально);
- git для показанного способа установки.

Bash completion: `source contrib/bash-completion.sh` или установите файл системно в `/etc/bash_completion.d/zapret-sonar`.

Установка, переустановка, управление сервисом и удаление проверены на Ubuntu Server 26.04 LTS, Arch Linux и Fedora 44 (x86_64). Матрица охватывает nftables, iptables-legacy с ipset и Fedora с SELinux Enforcing.

## Команды

### Подбор стратегии

| Команда | Назначение |
|---|---|
| `sonar list` | Показать стратегии (`*` — применённая) |
| `sudo sonar use alt12` | Применить стратегию по полному имени или уникальной части |
| `sudo sonar try [--keep]` | Перебрать стратегии; `--keep` оставляет первую прошедшую |
| `sonar baseline` | Измерить доступность целей без обхода с безопасным восстановлением сервиса |

### Диагностика

| Команда | Назначение |
|---|---|
| `sonar check [--json\|--json-v2]` | Проверить HTTP/CDN и HTTP/3/QUIC; JSON v1 сохраняет прежний HTTP/content scope, v2 добавляет категории и отдельные результаты |
| `sonar doctor` | Проверить сервис, конфиг, nfqws и активную стратегию; `sudo sonar doctor` дополнительно проверяет firewall interception |
| `sonar status [--json]` | Показать состояние, режимы и версии; JSON не включает preflight |
| `sonar validate [--json]` | Проверить все стратегии через трансляцию и `nfqws --dry-run`, ничего не применяя |
| `sonar export-diagnostic [--output файл]` | Безопасный JSON для issue без сырого конфига, логов, адресов и пользовательских списков |
| `sonar log [-f] [период]` | Показать журнал systemd |
| `sonar --debug <команда>` | Включить shell trace и подробный curl |

`PASS` означает успешную конкретную проверку, `FAIL` — ошибку, `NOT CHECKED` — проверка не дала осмысленного результата. Непроверенная цель не считается пройденной, но сама по себе не делает команду ошибочной; ненулевой код возвращается при наличии `FAIL`. `--json` сохраняет совместимую schema v1 с полем `skipped`, а `--json-v2` возвращает `not_checked` и результаты категорий `http`, `content`, `speed`, `quic`.

QUIC probe использует `curl --http3-only` и отключает proxy, чтобы TCP fallback не дал ложный успех. Если Discord не отвечает, проверяется контрольная HTTP/3-цель: её успех означает `FAIL` только для Discord, а общий сбой обеих целей даёт `NOT CHECKED`. Такой результат показывает различие сетевых путей, но сам по себе не доказывает фильтрацию. Discord Voice/STUN этим probe не проверяется.

Код завершения соответствует результату команды: `0` означает успех, ненулевой код — ошибку проверки или операции. JSON-команды сохраняют этот контракт, поэтому их можно безопасно использовать в мониторинге и автоматизации.

### Настройка

| Команда | Назначение |
|---|---|
| `sonar site <домен>` | Добавить домен; затем нужен `sudo sonar restart` |
| `sonar site --list` | Показать пользовательские домены |
| `sonar site --remove <домен>` | Удалить домен; затем нужен `sudo sonar restart` |
| `sudo sonar gamefilter off\|tcp\|udp\|both` | Настроить игровые порты и сразу применить конфиг |
| `sudo sonar ipset none\|any\|loaded` | Изменить IP-фильтр; затем нужен `sudo sonar restart` |

### Обновление и сервис

| Команда | Назначение |
|---|---|
| `sudo sonar update [--force]` | Обновить стратегии, списки и `.bin` Flowseal |
| `sudo sonar upgrade [--force]` | Обновить `nfqws`, `ip2net`, `mdig` с проверкой sha256 |
| `sonar self-update [--force]` | Обновить zapret-sonar из release asset с проверкой SHA-256 и rollback |
| `sonar snapshots [--json]` | Показать текущий и резервный snapshots Flowseal |
| `sudo sonar rollback [snapshot]` | Переключиться на предыдущий или выбранный snapshot Flowseal |
| `sudo sonar start\|stop\|restart` | Управлять сервисом |
| `sudo sonar enable\|disable` | Управлять автозапуском |
| `sudo sonar uninstall` | Полностью удалить сервис и `/opt/zapret` |

## TUI

```bash
sonar-tui
```

TUI на fzf показывает состояние сервиса и обновлений, позволяет выбирать стратегии с preview, запускать проверки и менять настройки. Проверка обновлений не блокирует интерфейс: на холодном кэше статус меняется с «проверка…» на результат автоматически. Для live-обновления header нужен fzf с `bg-transform-header`; на старых версиях статус обновится после перерисовки меню.

В разделе настроек доступны добавление, просмотр и удаление пользовательских сайтов, обновление Flowseal, откат snapshots, обновление движка и самого zapret-sonar.

<img src="screenshots/tui-main-menu.png" alt="Главное меню" width="700">

<details>
<summary>Остальные скриншоты</summary>

<img src="screenshots/tui-strategy-preview.png" alt="Выбор стратегии с preview" width="700">

<img src="screenshots/sonar-check.png" alt="sonar check" width="700">

<img src="screenshots/sonar-status.png" alt="sonar status" width="700">

<img src="screenshots/sonar-doctor.png" alt="sonar doctor" width="700">

</details>

## Как это работает

```text
.bat Flowseal -> translate.sh -> NFQWS_OPT -> nfqws --dry-run -> config -> systemctl restart
```

1. `lib/translate.sh` извлекает аргументы `winws.exe`, адаптирует пути и отбрасывает Windows batch-команды.
2. Результат проверяется на shell-метасимволы, поскольку config загружается от root.
3. `nfqws --dry-run` проверяет аргументы и ссылки на файлы до изменения конфига.
4. Конфиг записывается атомарно и содержит маркеры выбранной стратегии и режимов.
5. Сервис перезапускается только после успешной проверки; при ошибке возвращаются прежний конфиг и состояние сервиса.

## Обновления и восстановление

- Flowseal собирается в staging, затем весь набор переключается атомарным симлинком `flowseal-current`.
- Версия фиксируется, а старые snapshots удаляются только после успешного применения активной стратегии.
- При ошибке возвращается предыдущий набор, повторно проверяются конфиг и сервис, а неполное восстановление сообщается явно.
- Переустановка сначала пересобирает старый конфиг с новыми путями и только затем удаляет legacy-каталоги.
- Установщик и обновление движка создают резервные копии и восстанавливают предыдущее состояние при ошибке; остановленный до обновления сервис остаётся остановленным.
- Фоновый update-check хранит пользовательский кэш в `${XDG_CACHE_HOME:-~/.cache}/zapret-sonar`; lock изменяющих операций находится в `/run/zapret-sonar`.

Если Flowseal временно недоступен, текущий набор продолжает работать. Посмотрите сохранённые версии через `sonar snapshots` и переключитесь командой `sudo sonar rollback [snapshot]`. Для полной переустановки zapret-sonar используйте checkout или source archive нужного GitHub-тега и запустите `install.sh`; runtime asset `zapret-sonar-v*.tar.gz` предназначен для `sonar self-update` и не содержит установщик. Рабочий сервисный конфиг установщик сохраняет.

## Безопасность

- Файлы установки в `/opt` принадлежат root; `sudoers` не изменяется.
- Исполняемый shell-конфиг создаётся только из санитизированной стратегии.
- Бинарники zapret сверяются с `sha256sum.txt` upstream-релиза.
- Self-update использует собственный release archive и `SHA256SUMS`, проверяет структуру и синтаксис до атомарного переключения версии.
- Release asset собирается воспроизводимо только после тестов точного tag commit. Workflow создаёт draft release; после проверки русскоязычных release notes он публикуется вручную и делает его тег и assets неизменяемыми.
- У Flowseal нет опубликованного checksum-файла; архив загружается по TLS и проверяется структурно.
- Все операции, изменяющие конфиг, списки, snapshots, бинарники или сервис, используют общий root-owned lock.

## Ограничения проверок

- YouTube throttling на `googlevideo.com` не измеряется достоверно.
- Discord Voice и другие UDP-сценарии не проверяются.
- QUIC/HTTP3 не проверяется.
- ClientHello curl отличается от браузерного, включая многопакетный TLS.
- `check` может пройти и без zapret, если цели доступны у провайдера; дифференциальную оценку делает `try` относительно baseline.

## Удаление

`sudo sonar uninstall` удаляет сервис, unit, правила, симлинки и весь `/opt/zapret`, включая `config`, `config.orig`, snapshots и пользовательские `*-user.txt`. Скопируйте нужные данные заранее.

## Структура

```text
zapret-sonar                 CLI
zapret-sonar-tui             TUI на fzf
install.sh                   установщик
lib/translate.sh             парсер .bat -> NFQWS_OPT
lib/zconfig.sh               генерация конфига и ipset-режимы
lib/health.sh                HTTP/content checks, baseline и scoring
lib/flowseal.sh              staging, activation, rollback и pruning
tests/                       smoke, safety и pinned Flowseal tests
tests/vm/                    lifecycle-тесты в изолированных VM
schemas/                     версионированные JSON Schema для машинного вывода
scripts/build-release.sh     сборка проверяемого release asset
.github/workflows/ci.yml     ShellCheck, syntax и regression tests
contrib/bash-completion.sh   completion для bash
```

## Благодарности

- [bol-van/zapret](https://github.com/bol-van/zapret) — движок обхода DPI
- [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) — стратегии

## Лицензия

MIT
