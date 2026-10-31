# amnezia-proxy-manager

Linux CLI для AmneziaWG VPN и локальных HTTP/SOCKS-прокси через 3proxy.
VPN и proxy можно запускать вместе или отдельно; поддерживаются выборочные
маршруты и полный IPv4-туннель. Основная команда — `apm`.

## Быстрый старт

Установите [зависимости](docs/REFERENCE.md#зависимости), затем программу:

```bash
make install
export PATH="$HOME/.local/bin:$PATH"
```

Создайте конфиг:

```bash
apm config init
```

Заполните параметры VPN и upstream-прокси для выбранного режима.
[Все параметры, значения по умолчанию и примеры конфигурации](docs/CONFIGURATION.md).

```bash
apm config validate
apm doctor
sudo -v
apm start
```

`start` работает в терминале; `Ctrl+C` останавливает менеджер.
Из другого терминала доступны `status`, `logs` и `stop`.
Установка и обновление описаны в [инструкции](docs/INSTALLATION.md).
Изменения конфига применяются через `restart`. Конфиг содержит секреты:
сохраняйте права `600` и не добавляйте его в Git.

## Подключение приложений

При включённом proxy по умолчанию доступны HTTP и SOCKS:

```bash
export HTTP_PROXY=http://127.0.0.1:8081
export HTTPS_PROXY=http://127.0.0.1:8081
export ALL_PROXY=socks5h://127.0.0.1:8080
```

## Команды

| Команда | Назначение |
|---|---|
| `start` / `stop` / `restart` | Запуск, остановка, перезапуск |
| `status` / `diagnose` | Состояние и диагностика |
| `test` | Проверка upstream-прокси |
| `logs` | Просмотр логов |
| `run [--gui] -- <команда>` | Запуск приложения в sandbox |
| `config init` | Создать конфиг без перезаписи |
| `doctor [--sandbox]` | Проверить зависимости |
| `config validate` | Офлайн-проверка конфига |
| `--help` / `--version` | Справка и версия |

## Документация

- [Установка, обновление и удаление](docs/INSTALLATION.md).
- [Конфигурация и переменные окружения](docs/CONFIGURATION.md).
- [Технический справочник: зависимости, защита, sandbox](docs/REFERENCE.md).
- [Подготовка релиза](docs/RELEASING.md).
- [Лицензия MIT](LICENSE).
- [План развития](AUDIT.md).

## Разработка

Тесты в изолированном контейнере: `bash tests/docker.sh`.
Линтеры: `bash tests/lint.sh` (ShellCheck 0.11.0, actionlint 1.7.12).
