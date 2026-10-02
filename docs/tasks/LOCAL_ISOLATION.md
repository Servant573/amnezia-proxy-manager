# Безопасная локальная среда для dev-агентов

Статус: первый пакет lifecycle-правок реализован, усиление filesystem/network
остаётся в плане. Дата: 2026-10-02.
Основание: аудит текущего sandbox и обсуждение локальной изоляции.
Не требует ожидать миграции на Go; сначала укрепить существующий Linux runner.

В первом пакете: session lock, случайные veth имена, owner v2 с inode/ifindex,
отказ от удаления неподтверждённых ресурсов, проверка PID identity, ранние traps,
неинтерактивный retryable cleanup, READY всех listeners, HTTP/SOCKS probes и
canonical /30. Добавлены mock lifecycle, реальные signal/relay regression tests;
kernel sandbox tests ограничены явным container mode. Это не закрывает ещё
host INPUT/FORWARD, HOME-RW, environment и resource budgets. Отдельная доработка
logs добавила metadata redaction, безопасный private writer и независимость
relay от ошибок лога; rotation/размер логов ещё требуют реализации.
Route overlap checks и автоматическое восстановление неоднозначного `pending`
после SIGKILL требуют дальнейшей работы; сейчас выбран безопасный отказ от удаления.

## Цель и границы

Агент и запускаемые им зависимости считаются потенциально ошибочными/недоверенными.
Он может выполнять произвольные команды, игнорировать proxy env и пытаться
читать/удалять доступные данные. Разрешения UI агента не являются security boundary.
Защита должна обеспечиваться mount permissions, namespaces, firewall и DB roles.

Защищаем HOME, основной checkout и Git-хранилище, credentials, другие контейнеры,
локальные сервисы, менеджер VPN и доступность хоста. Не обещаем защиту от уязвимости
ядра/root, анонимность авторизованных аккаунтов или сохранность данных, которые
пользователь сознательно разрешил читать/изменять. Разрешённый proxy позволяет
отправлять наружу любую доступную агенту информацию.

Предлагаемые интерфейсы ниже ещё НЕ реализованы.

## Этап 0 — зафиксировать политику и тестовую среду

- Документировать режимы `readonly` и `disposable`; старый HOME-RW режим не считать
  безопасным default. Определить совместимость и явное согласие на legacy-режим.
- Разделить lifecycle VPN и lifecycle sandbox; отказ sandbox не выключает чужой VPN.
- Добавить обязательный изолированный kernel test job с bwrap и необходимыми
  правами namespaces. Не запускать kernel tests в host netns, не использовать
  host network, Docker socket/домашний каталог внутри тестового контейнера.
- SKIP security-тестов в обязательном job — ошибка, а не «всё прошло».
- Ввести mock fault-injection: конфликт ресурса, write failure, отказ sudo/nft,
  сигналы, занятой listener, ошибка удаления, два параллельных запуска.

Готово, когда из CI видно, какие границы реально проверены, и отрицательные
сценарии текущих находок воспроизводятся без риска для хоста.

## Этап 1 — владение ресурсами и надёжная остановка

Находки 3–5, 8–9. Это фундамент последующих firewall/mount изменений.

- Session UUID, уникальные netns/veth/table имена, приватный каталог сессии;
  lock + атомарное резервирование. Если поддерживается только один run — явно
  отказывать второй сессии без изменения первой.
- Отдельно хранить intent и подтверждённое создание; namespace inode/идентичность,
  veth ifindex и ownership marker. Никогда не удалять существующий ресурс только
  потому, что совпало имя. Учитывать восстановление после SIGKILL между шагами.
- PID + boot ID + starttime для relay/runner; не сигналить PID 0/отрицательный,
  чужой или повторно использованный процесс. TERM → bounded wait → обработка
  незавершения; сохранять owner при ошибке очистки.
- Ставить cleanup trap до первого изменения; обработать EXIT/INT/TERM и сигналы
  дочерних процессов. Cleanup не запрашивает пароль бесконечно. Аварийный stop
  согласованно останавливает собственный relay и namespace.
- READY после успешного bind всех listeners; ошибки порта — fail-fast.
- Принимать только канонический /30, проверять конфликт подсети с маршрутами;
  по возможности минимизировать connected routes и использовать явный peer route.

Приёмка: чужие интерфейсы/netns сохраняются при конфликтах; второй run не
ломает первый; Ctrl+C/TERM и отказ на каждом шаге дают корректное состояние;
повторный cleanup безопасен, ошибки не превращаются в ложный успех.

## Этап 2 — защитить файлы и окружение

Находки 2, 6. Приоритет не ниже сетевого guard: это защита от случайного удаления.

- Synthetic HOME, приватные tmp/cache/config. Не bind реального HOME даже RO
  целиком; RO предотвращает запись, но не чтение секретов.
- Основной workspace по умолчанию RO, отдельные временные output/build directories
  RW. Никакой автоматической записи в основной checkout.
- Для разработки использовать отдельный независимый clone (пользователь готов
  выкачать его сам) или snapshot выбранных файлов с собственным Git metadata и RW;
  импорт результата только отдельным явным действием после diff.
  Сохранять результат сессии при ошибке вместо автоматического удаления.
- Обычный linked worktree НЕ достаточная граница: у него общие objects/refs/config.
  Не предоставлять основную `.git` для записи; самостоятельный snapshot + git init
  подходит для минимального контекста без старой истории. Clone должен иметь
  независимые objects без hardlinks/alternates и учитывать секреты в истории.
- Снимок должен явно учитывать незакоммиченные и выбранные untracked файлы;
  не запускать reset/clean/stash автоматически в основном checkout.
- `.env`, ключи, credential stores, manager runtime, Docker/SSH/GPG/session sockets
  и исходная Git-история не доступны по умолчанию. Allowlist доступа и предупреждение
  о чувствительных файлах; secret scanner — дополнительная проверка, не гарантия.
- `--clearenv`; явно задать PATH, HOME, USER/LOGNAME, locale, TERM и proxy vars.
  Не наследовать NODE_OPTIONS/preload hooks. Выбранные API credentials передаются
  opt-in по имени; не показывать значения в логах/diagnose/process argv без нужды.
- Клиентские credentials/config переносить минимально, отдельно от полного
  каталога Codex/Claude с историей, настройками и пользовательскими hooks.
  Доверенные executable directories монтировать RO явно.
- `/etc` минимально: необходимые passwd/group, TLS CA, nsswitch/hosts/resolv stub;
  требуемые системные пути тестировать на Debian/Ubuntu, не открывать весь `/opt`
  ради одного клиента. Рассмотреть IPC/UTS/new-session, лишние inherited FD.

Приёмка: удалить/переписать маркер HOME и основной проект невозможно; `.env`,
сокеты и host runtime недоступны; синтетический секрет shell отсутствует без
opt-in через весь sudo → setpriv → bwrap путь. Удаление disposable snapshot
не меняет файлы, refs и objects оригинала. Агент всё ещё запускается и авторизуется.

## Этап 3 — закрыть сетевой доступ к хосту

Находка 1. Можно вести параллельно этапу 2 после согласования ownership.

- Своя per-session inet table, INPUT allow только к host-side IPv4 и точным
  proxy listener ports от peer; прочий трафик с veth DROP/REJECT.
- FORWARD deny с agent veth: защищает в том числе от Docker PREROUTING/DNAT.
  Не ограничиваться INPUT. Не разрешать целиком LAN/Docker bridge.
- Explicit IPv6 deny в session policy и отключение IPv6 в guest netns;
  `ipv4first` не считать защитой. Не выключать IPv6 хоста через общий sysctl.
- Guard до link-up; отказ установки/проверки запрещает старт. Проверять содержимое
  правил, а не только существование table. При исчезновении/подмене guard
  сессию нужно завершить или гарантированно разорвать её egress.
- Проверить взаимодействие с существующим host firewall/Docker chains;
  не flush чужие таблицы, не менять общие политики.

Приёмка: HTTP/SOCKS работают; wildcard host listener, published Docker port,
LAN, direct Internet, DNS UDP/TCP, IPv6 link-local и произвольный host port
недоступны. Повторить с IPv6 host guard on/off, DNAT включённым и выключенным,
с подменённым интерфейсом и отсутствующим guard.

## Этап 4 — сохранить удобный доступ к локальной БД

Предлагаемый UX:

```text
amnezia-proxy run --readonly --workspace ./project \
  --allow-tcp 15432=127.0.0.1:5432 -- codex
```

Явная capability: guest `10.200.0.1:15432` → host relay → `127.0.0.1:5432`.
В Docker БД публикуется на loopback, не на всех интерфейсах. Доступ не требует
Docker socket, bridge route или полномочий Docker daemon.

- Default target — только literal loopback TCP, явное отображение guest-port →
  target-port. Валидировать диапазоны, уникальность, отсутствие конфликта с proxy;
  не принимать произвольный hostname, который может сменить адрес после проверки.
- Для новых сервисов расширять INPUT allowlist атомарно вместе с listeners.
  Один policy object должен питать firewall, relay, env и diagnose, без расхождений.
- DB credentials — отдельная роль, не owner/superuser. Для анализа только нужные
  SELECT/USAGE/CONNECT, без опасных memberships/SECURITY DEFINER возможностей.
  Не считать connection flag read-only полноценной заменой серверным правам.
- Для миграций/записи — disposable DB с отдельным volume и безопасным seed;
  доступ к основной dev DB на запись — отдельное сознательное разрешение.
- TCP allow не различает SELECT и DROP. PostgreSQL контролирует SQL-права;
  Redis/backend требуют собственной ACL/авторизации. Даже SELECT может раскрыть
  чувствительные данные, поэтому данные тестовой БД следует обезличивать.
- Profiles `strict/dev` позже, как именованные явные capabilities, без скрытого
  автоматического доступа к Redis/Postgres/host backend.

Приёмка: агент читает тестовую БД через указанный порт; другой DB/container/host
port недоступен; DROP/ALTER/TRUNCATE/DELETE запрещены сервером в readonly роли.
Для RW-тестов уничтожение disposable DB не затрагивает основной volume.

## Этап 5 — безопасные логи и ограничения ресурсов

Находки 7, 11.

- Логи только метаданных соединений, без URL path/query/userinfo и credentials.
  Ротация, максимальный размер, права 0600; synthetic-token regression tests.
- Ограничить relay connections, file descriptors, handshake/idle deadlines;
  не держать неограниченное число потоков на хосте.
- Cgroup/systemd scope budgets: memory, pids, CPU, включая relay и descendants.
  Для дисковых output/cache — квоты или лимитированный tmpfs.
- `diagnose` показывает фактические mounts, env NAMES, capabilities, guard
  identity/readiness и budgets, но не значения секретов. Разделять намерение,
  установленную политику и результаты активных проверок.

Приёмка: flood соединений/fork/логов ограничен сессией, хост сохраняет
работоспособность; завершение сессии останавливает всех её потомков.

## Рекомендуемый первый пакет работ

Этап 0 + этап 1, затем одним security-релизом базовые пункты этапов 2–3:
synthetic HOME, readonly default, clean environment и INPUT/FORWARD deny.
Явный DB-forwarding — следующий пакет, а не временное снятие host guard.
До этого текущий `run` не использовать как защиту важных локальных данных
от произвольных команд агента.

## Технические основания

- [Bubblewrap: политика определяется аргументами runner](https://github.com/containers/bubblewrap).
- [nftables: INPUT и FORWARD — разные пути](https://wiki.nftables.org/wiki-nftables/index.php/Netfilter_hooks).
- [Docker: published ports, DNAT и FORWARD](https://docs.docker.com/engine/network/firewall-iptables/).
- [Git worktree: общее хранилище linked worktrees](https://git-scm.com/docs/git-worktree).
- [PostgreSQL: привилегии ролей и объектов](https://www.postgresql.org/docs/current/ddl-priv.html).
