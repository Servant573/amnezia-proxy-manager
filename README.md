# amnezia-proxy-manager

Небольшая Linux CLI-утилита, которая поднимает выборочный туннель AmneziaWG и
локальные HTTP/SOCKS-прокси через 3proxy.

Проект рассчитан на Linux с `/proc`, Bash 4.1+, `amneziawg-tools`, `3proxy`,
`curl`, `iproute2`, `util-linux` (`flock`) и `sudo`.

## Быстрый старт

Установите конфиг в стандартный XDG-каталог:

```bash
install -d -m 700 ~/.config/amnezia-proxy-manager
install -m 600 config.example ~/.config/amnezia-proxy-manager/config
# Заполните конфиг своими значениями.
./amnezia-proxy-manager start
```

В другом терминале можно проверить или остановить менеджер:

```bash
./amnezia-proxy-manager status
./amnezia-proxy-manager stop
```

Старый конфиг `~/.amnezia-proxy.conf` продолжает автоматически подхватываться,
если нового файла ещё нет. При этом команда выводит предупреждение с новым
путём. Корневой `amnezia-proxy-manager` также сохранён как совместимый launcher
для новой точки входа `bin/amnezia-proxy`.

Собственный конфиг можно передать через CLI или environment:

```bash
./amnezia-proxy-manager --config ./local.conf status

AMNEZIA_PROXY_CONFIG=./local.conf \
./amnezia-proxy-manager status
```

Файл содержит приватные ключи и пароль upstream-прокси. Не добавляйте
заполненный конфиг в Git и сохраняйте для него права `600`.

## Команды

```text
start       запустить туннель и локальные прокси в foreground
stop        остановить менеджер и сетевые компоненты
restart     перезапустить менеджер
status      показать состояние менеджера, туннеля и 3proxy
test        проверить upstream-прокси
diagnose    проверить MTU, маршруты, handshake, HTTP и SOCKS
```

Полная справка доступна через `./amnezia-proxy-manager --help`.

## Каталоги

По умолчанию используются стандартные пользовательские пути:

| Назначение | Путь |
|---|---|
| Конфиг | `${XDG_CONFIG_HOME:-~/.config}/amnezia-proxy-manager/config` |
| Кэш AllowedIPs | `${XDG_CACHE_HOME:-~/.cache}/amnezia-proxy-manager/` |
| Логи | `${XDG_STATE_HOME:-~/.local/state}/amnezia-proxy-manager/` |
| PID и временные конфиги | `${XDG_RUNTIME_DIR}/amnezia-proxy-manager/` |

Если `XDG_RUNTIME_DIR` отсутствует, runtime-каталог создаётся в
`${TMPDIR:-/tmp}/amnezia-proxy-manager-$UID`.

Все пути можно переопределить:

```text
AMNEZIA_PROXY_CONFIG
AMNEZIA_PROXY_STATE_DIR
AMNEZIA_PROXY_CACHE_DIR
AMNEZIA_PROXY_RUNTIME_DIR
```

## VPN и proxy transport

Перед поднятием туннеля hostname upstream-прокси преобразуется в IPv4. Все
полученные адреса добавляются в `AllowedIPs`, а выбранный адрес фиксируется в
конфиге 3proxy до следующего рестарта. Благодаря этому DNS-ответ 3proxy не может
случайно указать на адрес, который не маршрутизируется через AmneziaWG.

После запуска проверяются два обязательных инварианта:

- маршрут к endpoint не должен проходить через создаваемый AWG-интерфейс;
- маршрут к фактическому upstream-прокси обязан проходить через него.

До запуска 3proxy проверяется занятость локальных портов, а после запуска —
наличие обоих listening sockets. Одного существующего PID недостаточно для
статуса «готово».

Нарушение любого из условий считается ошибкой запуска и вызывает cleanup.

HTTP-вход 3proxy использует parent типа `http`, а SOCKS-вход — parent типа
`connect+` вместе с `fakeresolve`. Это преобразует SOCKS в upstream HTTP
CONNECT и оставляет разрешение целевого hostname upstream-прокси, как ожидает
клиент `socks5h`. Проверка `diagnose` отдельно тестирует оба локальных протокола.

### MTU

Рекомендуемый режим для новых конфигов:

```text
WG_MTU=auto
```

В этом режиме строка `MTU` не записывается во временный AWG-конфиг и
`awg-quick` самостоятельно выбирает MTU маршрута к endpoint минус 80 байт.
Фиксированное рабочее значение можно оставить без изменений, например
`WG_MTU=1390`.

Команда `diagnose` показывает настроенное значение, оценку `awg-quick` и
фактический MTU поднятого интерфейса. Значение `PROXY_MAXSEG` предназначено
только для редких проблем PMTUD, требует 3proxy 0.9.6+ и обычно не нужно при
правильном `WG_MTU`.

### DNS и стартовая проверка

Пустой `DNS` сохраняет системное разрешение имён. Если указан IPv4 DNS,
`awg-quick` временно подключает его через `resolvconf`, а менеджер автоматически
добавляет адрес DNS в `AllowedIPs`, чтобы запросы не ушли мимо туннеля.

После запуска HTTP-цепочка проверяется через `HEALTHCHECK_URL`. Поведение
настраивается параметром `STARTUP_HEALTHCHECK`:

- `off` — не проверять;
- `warn` — оставить систему запущенной и вывести предупреждение;
- `strict` — считать неуспешную проверку ошибкой и откатить запуск.

Для подробной проверки выполните:

```bash
./amnezia-proxy-manager diagnose
```

Поведение основано на штатном расчёте MTU в
[AmneziaWG `awg-quick`](https://github.com/amnezia-vpn/amneziawg-tools/blob/master/src/wg-quick/linux.bash)
и официальной документации
[3proxy parent/DNS/MSS](https://github.com/3proxy/3proxy/wiki/3proxy.cfg).

## Структура проекта

```text
amnezia-proxy-manager          совместимый launcher
bin/amnezia-proxy              CLI и разбор аргументов
lib/paths.sh                   XDG-пути
lib/log.sh                     терминальный и файловый лог
lib/config.sh                  безопасная загрузка конфига
lib/runtime.sh                 PID и блокировка операций
lib/network.sh                 получение AllowedIPs
lib/tunnel.sh                  AmneziaWG
lib/proxy.sh                   3proxy
lib/manager.sh                 orchestration команд
tests/run.sh                   локальные тесты
```

## Разработка

Проверки не поднимают туннель и не требуют сетевого доступа:

```bash
bash -n amnezia-proxy-manager bin/amnezia-proxy lib/*.sh tests/run.sh
bash tests/run.sh
```

Дальнейшее направление развития описано в [AUDIT.md](AUDIT.md).
