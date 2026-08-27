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
