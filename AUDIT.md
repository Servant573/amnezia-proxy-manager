# Аудит и план развития

## Текущее состояние

Этапы 0–2 выполнены:

- исходное состояние зафиксировано в Git;
- жизненный цикл `start`/`stop`/`restart` стабилизирован;
- добавлены PID-проверки, lock, cleanup, справка и тесты;
- реализация разделена на CLI и библиотеки по ответственности;
- config/cache/state/runtime переведены на XDG-пути;
- сохранены корневой launcher, environment overrides и fallback на старый
  `~/.amnezia-proxy.conf`.

Ручная проверка этапа 1 на реальном AmneziaWG и 3proxy прошла успешно.

Дополнительно выполнено укрепление transport-цепочки:

- hostname upstream-прокси разрешается до старта туннеля, его IPv4 явно
  включается в AllowedIPs и фиксируется в 3proxy до рестарта;
- проверяется отсутствие маршрутизационной петли к AWG endpoint;
- проверяется обязательный маршрут upstream-прокси через AWG;
- добавлен `WG_MTU=auto` на базе штатного расчёта `awg-quick`;
- HTTP и SOCKS используют подходящие типы parent (`http` и `connect+`), а
  SOCKS hostname разрешается upstream-прокси через `fakeresolve`;
- добавлены стартовая healthcheck и команда `diagnose`;
- IPv4 CIDR теперь проходят строгую синтаксическую проверку;
- DNS, управляемый `awg-quick`, автоматически добавляется в AllowedIPs;
- `PROXY_MAXSEG` доступен только на поддерживающем его 3proxy 0.9.6+.

## Архитектура

```text
amnezia-proxy-manager          совместимый launcher
bin/amnezia-proxy              CLI, опции и dispatch
lib/paths.sh                   пути и каталоги
lib/log.sh                     логирование
lib/config.sh                  загрузка конфигурации
lib/runtime.sh                 PID и блокировки
lib/network.sh                 AllowedIPs
lib/tunnel.sh                  AmneziaWG
lib/proxy.sh                   3proxy
lib/manager.sh                 жизненный цикл команд
tests/run.sh                   локальные тесты
```

Публичной остаётся одна команда. Библиотеки самостоятельно не запускаются и
подключаются точкой входа через `source`.

## Следующий этап — конфиг и диагностика

1. Разнести `PROXY_STRING` на `PROXY_HOST`, `PROXY_PORT`, `PROXY_USER` и
   `PROXY_PASSWORD`, оставив временный fallback старого формата.
2. Добавить строгую валидацию портов, endpoint, IPv4 CIDR и числовых
   AmneziaWG-параметров.
3. Добавить `config validate` без изменения сетевого состояния.
4. Расширить существующий `diagnose` до общего `doctor`: добавить права,
   занятость портов и доступность источников.
5. Добавить `logs`, не допускающий вывода ключей и паролей.

## После диагностики

### Надёжный AllowedIPs

- TTL кэша и атомарное обновление;
- fallback на последний успешный список;
- метаданные по источникам и возрасту кэша;
- защита от пустого или резко уменьшившегося списка;
- команды просмотра и принудительного обновления.

### Тестирование и CI

- ShellCheck;
- mock-интеграционные тесты полного `start`/`stop`/`restart`;
- сценарии частичного запуска и rollback;
- CI с `bash -n`, ShellCheck и `tests/run.sh`.

### Установка и сервис

- установщик или `Makefile`;
- установка в `~/.local/bin` или `/usr/local/bin`;
- systemd unit;
- безопасная модель привилегий;
- journald при запуске как service.
