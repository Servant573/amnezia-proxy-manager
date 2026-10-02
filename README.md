# amnezia-proxy-manager

Linux CLI для запуска AmneziaWG VPN и локальных HTTP/SOCKS-прокси через 3proxy.
Поддерживает выборочные маршруты или полный IPv4-туннель.

Для приложений, использующих локальный прокси, цепочка выглядит так:

```text
Приложение → локальный 3proxy → VPN → upstream HTTP-прокси → интернет
```

## Технологии и зависимости

Bash 4.1+ управляет запуском и остановкой; AmneziaWG обеспечивает VPN,
3proxy — локальные прокси, nftables — сетевую защиту, flock — блокировку
параллельных запусков. Python 3 проверяет правила firewall при диагностике.

Нужны Linux с `/proc`, рабочая поддержка AmneziaWG и команды:
`awg`, `awg-quick` (amneziawg-tools), `3proxy`, `curl`, `ip`/`ss` (iproute2),
`nft` (nftables), `flock` (util-linux), `timeout` (coreutils), `sudo`.
При заданном `DNS` также нужен `resolvconf`.

## Запуск

Пока утилита запускается из каталога проекта. При первоначальной настройке
создайте пользовательский конфиг:

```bash
install -d -m 700 ~/.config/amnezia-proxy-manager
install -m 600 config.example ~/.config/amnezia-proxy-manager/config
```

Заполните ключи, адрес, endpoint и параметры AmneziaWG из своего VPN-конфига.
Укажите upstream-прокси в `PROXY_STRING="host:port:user:password"`.
Если сервер не использует PSK, оставьте `PRESHARED_KEY=` пустым.
Описание параметров есть в [config.example](config.example).

```bash
./amnezia-proxy-manager config validate
sudo -v
./amnezia-proxy-manager start
```

`start` работает в текущем терминале; `Ctrl+C` останавливает менеджер.
Из другого терминала доступны `status`, `logs` и `stop`.
Свой конфиг: `./amnezia-proxy-manager --config ./local.conf start`.
Храните конфиг с правами `600` и не добавляйте его в Git.

## Подключение приложений

По умолчанию HTTP слушает `127.0.0.1:8081`, SOCKS — `127.0.0.1:8080`:

```bash
export HTTP_PROXY=http://127.0.0.1:8081
export HTTPS_PROXY=http://127.0.0.1:8081
export ALL_PROXY=socks5h://127.0.0.1:8080
```

Либо задайте прокси в настройках приложения. Порты меняются через
`LOCAL_HTTP_PORT` и `LOCAL_SOCKS_PORT`. SOCKS поддерживает TCP CONNECT.

## Маршруты VPN

Ручные IPv4/CIDR и списки по HTTPS можно использовать отдельно или вместе:

```ini
ALLOWED_IPS="192.0.2.7,198.51.100.0/24"
IPLIST_URLS="https://example.org/ipv4.txt"
```

IP без маски означает `/32`. Списки объединяются; в HTTP-ответе допустимы
строки, пробелы, запятые и комментарии `#`. Upstream-прокси и настроенный DNS
добавляются автоматически. Ошибка запроса или список без валидных адресов
запрещает запуск.

Если оба параметра пусты или отсутствуют, используется `0.0.0.0/0`:
IPv4 идёт через VPN, кроме более специфичных системных маршрутов.
В выборочном режиме остальные адреса используют обычную сеть.
Доступ к сетям за VPN требует соответствующей настройки сервера.
Изменения конфига применяются после `restart`.

По умолчанию `BLOCK_IPV6=on` блокирует исходящий IPv6 всех локальных процессов,
кроме loopback. Endpoint и upstream должны иметь IPv4.
Защита блокирует выход к upstream вне VPN; полного IPv4 kill switch для хоста нет.
После аварии выполните `sudo -v` и `stop` перед новым запуском.

## Команды

| Команда | Назначение |
|---|---|
| `start` / `stop` / `restart` | Запуск, остановка, перезапуск |
| `status` | Состояние VPN и прокси |
| `diagnose` | Маршруты, MTU, handshake, firewall, HTTP/SOCKS |
| `test` | Доступность upstream; не подтверждает VPN |
| `logs` | Последние 100 строк и новые записи обоих логов; выход — Ctrl+C |
| `config validate` | Проверка конфига без сети и sudo |
| `--help` / `--version` | Справка и версия |

Конфиг: `~/.config/amnezia-proxy-manager/config`; логи:
`~/.local/state/amnezia-proxy-manager/`. Поддерживаются XDG-пути и переменные
`AMNEZIA_PROXY_CONFIG`, `AMNEZIA_PROXY_STATE_DIR`, `AMNEZIA_PROXY_CACHE_DIR`,
`AMNEZIA_PROXY_RUNTIME_DIR`. Старый `~/.amnezia-proxy.conf` используется как fallback.

## Разработка

Полный тестовый набор: `bash tests/docker.sh`.
Сетевые тесты выполняются в изолированном контейнере.

Подробности — в [техническом справочнике](docs/REFERENCE.md).
План развития — в [AUDIT.md](AUDIT.md).
