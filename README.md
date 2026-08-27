# amnezia-proxy-manager

Небольшая Linux CLI-утилита, которая поднимает выборочный туннель AmneziaWG и
локальные HTTP/SOCKS-прокси через 3proxy.

Проект пока рассчитан на локальное использование и проверен только как Bash-
скрипт. Поддерживаемая среда: Linux с `/proc`, Bash 4.1+, `amneziawg-tools`,
`3proxy`, `curl`, `iproute2`, `util-linux` (`flock`) и `sudo`.

## Быстрый старт

```bash
cp config.example ~/.amnezia-proxy.conf
chmod 600 ~/.amnezia-proxy.conf
# Заполните конфиг своими значениями.
./amnezia-proxy-manager start
```

В другом терминале можно проверить или остановить менеджер:

```bash
./amnezia-proxy-manager status
./amnezia-proxy-manager stop
```

Доступные команды выводятся через `./amnezia-proxy-manager --help`.

Пути можно переопределить без изменения скрипта:

```bash
AMNEZIA_PROXY_CONFIG=./local.conf \
AMNEZIA_PROXY_RUNTIME_DIR=./.local-proxy \
./amnezia-proxy-manager status
```

Файлы конфигурации содержат приватные ключи и пароль upstream-прокси. Не
добавляйте заполненный конфиг в Git и сохраняйте для него права `600`.

## Разработка

Синтаксическая проверка и локальные тесты не поднимают туннель и не требуют
сетевого доступа:

```bash
bash -n amnezia-proxy-manager
bash tests/run.sh
```

Дальнейшее направление развития описано в [AUDIT.md](AUDIT.md).
