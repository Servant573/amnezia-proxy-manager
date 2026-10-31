# Примеры правок — master

Отчёт: [REVIEW_master.md](REVIEW_master.md).
Первоначально здесь были примеры для ручного внесения. По последующему запросу пользователя все четыре исправления применены 2026-10-31; текущий статус см. в разделе 8 отчёта. Для launcher выбран вариант с передачей выбора конфига основному CLI. Нумерация совпадает с отчётом. Фрагменты «Было» относятся к рабочему дереву до исправлений.

Проверка примеров: все фрагменты «Было» автоматически сопоставлены с исходниками; все фрагменты «Стало» прошли `bash -n`. Временные проверки вне проекта подтвердили маскирование runtime и чтение XAUTHORITY после дополнительных mount-аргументов, успешный статус helper без XDG_SESSION_TYPE и раскрытие sandbox HTTP_PROXY с сохранением аргумента с пробелами. Реальный GUI-сеанс не запускался.

## Blocking

### 1. lib/sandbox.sh:308 — скрыть runtime-копии секретов

**Проблема:** bind всего runtime сеанса открывает сгенерированные конфиги менеджера, содержащие VPN-ключ и upstream-пароль.

Минимальная локальная правка в `sandbox_build_bwrap`, сразу после GUI-bindings. Она сохраняет выбранный доступ к сессионным сокетам, но маскирует внутренний runtime менеджера.

**Было:**

```bash
    BWRAP_ARGS+=( --bind "$HOME" "$HOME" --bind "$PWD" "$PWD" )
    sandbox_gui_bindings
```

**Стало:**

```bash
    BWRAP_ARGS+=( --bind "$HOME" "$HOME" --bind "$PWD" "$PWD" )
    sandbox_gui_bindings
    if (( SANDBOX_GUI )); then
        BWRAP_ARGS+=( --tmpfs "$RUNTIME_DIR" )
    fi
```

**Почему так:** пустое монтирование накрывает каталог менеджера после bind сеанса; приложение не может читать `${WG_INTERFACE}.conf` и `3proxy.cfg`. Доступ родительского процесса к исходным stub-файлам при сборке монтирований остаётся доступен bwrap. Более узкий allowlist сессионных сокетов можно рассмотреть отдельно, но он меняет документированный контракт GUI.

**Проверка:** с synthetic AWG/3proxy-конфигами внутри `$XDG_RUNTIME_DIR/amnezia-proxy-manager` запустить настоящий bwrap в обоих режимах; чтение обоих файлов должно завершаться ошибкой. Проверить доступ к нужным Wayland/X11 ресурсам после маскирования.

## Important

### 2. lib/sandbox.sh:319 — вернуть успешный статус при отсутствии необязательной переменной

**Проблема:** статус последней проверки в цикле становится результатом helper и активирует `set -e`.

**Было:**

```bash
    for var in DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XAUTHORITY XDG_SESSION_TYPE; do
        [[ -n "${!var:-}" ]] && BWRAP_ARGS+=( --setenv "$var" "${!var}" )
    done
}
```

**Стало:**

```bash
    for var in DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XAUTHORITY XDG_SESSION_TYPE; do
        [[ -n "${!var:-}" ]] && BWRAP_ARGS+=( --setenv "$var" "${!var}" )
    done
    return 0
}
```

**Почему так:** отсутствие необязательной переменной больше не считается ошибкой helper.

**Проверка:** отдельный Bash с `set -euo pipefail`, `SANDBOX_GUI=1`, `BWRAP_ARGS=()` и `unset XDG_SESSION_TYPE`; после прямого вызова `sandbox_gui_bindings` должна выполниться следующая команда. Повторить с `XDG_SESSION_TYPE=''`. Не вызывать helper в условии `if`/`||`, иначе errexit внутри функции подавляется.

### 3. bin/amnezia-proxy-gui:70 — использовать активный HTTP_PROXY внутри sandbox

**Проблема:** `--proxy-server` использует порт из пользовательского конфига, хотя forwarder работает с runtime-портом.

Ниже — замена всей части от `cfg_val()` до конца файла. Выбор пути `CONFIG` выше сохраняется, но второй парсер параметров и вычисление proxy endpoint больше не нужны.

**Было:**

```bash
cfg_val() {
    local v
    v=$(grep -E "^[[:space:]]*${1}[[:space:]]*=" "$CONFIG" | tail -1)
    [[ -n "$v" ]] || return 0
    v="${v#*=}"
    v="${v%%#*}"
    v="${v//\"/}"; v="${v//\'/}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

VETH_SUBNET="$(cfg_val SANDBOX_VETH_SUBNET)"; VETH_SUBNET="${VETH_SUBNET:-10.200.0.0/30}"
HTTP_PORT="$(cfg_val LOCAL_HTTP_PORT)"; HTTP_PORT="${HTTP_PORT:-8081}"

base="${VETH_SUBNET%/*}"
IFS=. read -r a b c d <<< "$base"
host_ip="$a.$b.$c.$((10#$d + 1))"

exec "$MANAGER" --config "$CONFIG" run --gui -- "$@" \
    --no-sandbox \
    --proxy-server="http://${host_ip}:${HTTP_PORT}" \
    --disable-quic \
    --force-webrtc-ip-handling-policy=disable_non_proxied_udp
```

**Стало:**

```bash
exec "$MANAGER" --config "$CONFIG" run --gui -- /bin/sh -c '
    exec "$@" \
        --no-sandbox \
        --proxy-server="$HTTP_PROXY" \
        --disable-quic \
        --force-webrtc-ip-handling-policy=disable_non_proxied_udp
' amnezia-proxy-gui "$@"
```

**Почему так:** `/bin/sh` выполняется уже внутри bwrap, где `HTTP_PROXY` задан менеджером из `SANDBOX_HOST_IP` и активного `SANDBOX_HTTP_PORT`. Одинарные кавычки откладывают раскрытие переменной до запуска в sandbox; `"$@"` сохраняет границы аргументов приложения, а отдельный `amnezia-proxy-gui` занимает `$0` команды `sh -c`. Ни пользовательская команда, ни её аргументы не вставляются в shell-код.

**Проверка:** runtime listener 8081, пользовательский конфиг 8181; перехваченные аргументы приложения должны содержать `--proxy-server=http://10.200.0.1:8081`. Дополнительно проверить путь приложения и аргументы с пробелами.

### 4. lib/sandbox.sh:319 — монтировать конкретный XAUTHORITY-файл

**Проблема:** путь cookie передаётся через env, но файл в `/tmp` скрыт tmpfs.

Вставка в `sandbox_gui_bindings` после bind X11-сокетов:

**Было:**

```bash
    [[ -e /tmp/.X11-unix ]] && BWRAP_ARGS+=( --bind /tmp/.X11-unix /tmp/.X11-unix )
    # POSIX shared memory нужен Chromium.
```

**Стало:**

```bash
    [[ -e /tmp/.X11-unix ]] && BWRAP_ARGS+=( --bind /tmp/.X11-unix /tmp/.X11-unix )
    if [[ -n "${XAUTHORITY:-}" && -f "$XAUTHORITY" && -r "$XAUTHORITY" ]]; then
        BWRAP_ARGS+=( --ro-bind "$XAUTHORITY" "$XAUTHORITY" )
    fi
    # POSIX shared memory нужен Chromium.
```

**Почему так:** bwrap открывает существующий cookie снаружи tmpfs и публикует только этот файл read-only по пути из env. Весь host `/tmp` открывать не требуется. Явный `return 0` из правки №2 также нужен.

**Проверка:** задать `XAUTHORITY` на временный файл `/tmp/xauth-*` с synthetic-cookie, собрать GUI-аргументы и проверить чтение ожидаемого содержимого внутри настоящего bwrap. CLI-режим не должен получать этот bind. Для полноценной проверки авторизации дополнительно нужен реальный X11-сеанс.

## Nit / Suggestion

Находок нет.
