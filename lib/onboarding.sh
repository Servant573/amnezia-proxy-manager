#!/bin/bash

config_template() {
    local path
    for path in "$PROJECT_ROOT/config.example" "$PROJECT_ROOT/share/config.example"; do
        if [[ -f "$path" ]]; then printf '%s' "$path"; return 0; fi
    done
    echo 'Шаблон config.example не найден в поставке' >&2
    return 1
}

do_config_init() {
    command -v python3 >/dev/null || { echo 'Для config init нужен python3' >&2; return 1; }
    local template
    template=$(config_template) || return 1
    python3 "$PROJECT_ROOT/lib/config_init.py" "$template" "$CONFIG_FILE" || return 1
    printf 'Конфиг создан: %s\nЗаполните параметры, затем выполните config validate, doctor и start.\n' "$CONFIG_FILE"
}

doctor_require() {
    local dependency="$1" purpose="$2"
    if command -v "$dependency" >/dev/null 2>&1; then
        printf 'OK: %s — %s\n' "$dependency" "$purpose"
    else
        printf 'MISSING: %s — %s\n' "$dependency" "$purpose"
        doctor_failures=$((doctor_failures + 1))
    fi
}

do_doctor() {
    local doctor_sandbox=0 doctor_failures=0 summary
    local doctor_vpn=1 doctor_proxy=1 doctor_ipv6=on doctor_dns='' doctor_lists='' doctor_config_known=0
    if (( $# )); then
        if [[ $# == 1 && "$1" == --sandbox ]]; then doctor_sandbox=1
        else echo 'Использование: doctor [--sandbox]' >&2; return 2; fi
    fi
    if [[ "$OSTYPE" == linux* ]]; then echo 'OK: Linux'
    else echo 'FAIL: требуется Linux'; doctor_failures=$((doctor_failures + 1)); fi
    if [[ -r /proc/self/stat && -r /proc/sys/kernel/random/boot_id ]]; then echo 'OK: /proc'
    else echo 'FAIL: требуется доступный /proc'; doctor_failures=$((doctor_failures + 1)); fi
    echo "OK: Bash $BASH_VERSION (требуется 4.1+)"
    if [[ -f "$CONFIG_FILE" ]]; then
        if summary=$( ( LOG_TO_FILE=0; load_config >/dev/null
            printf '%s\n' "$VPN_ON" "$PROXY_ON" "$BLOCK_IPV6" "$DNS" "$IPLIST_URLS" ) 2>/dev/null); then
            local -a fields
            mapfile -t fields <<< "$summary"
            doctor_vpn=${fields[0]}; doctor_proxy=${fields[1]}; doctor_ipv6=${fields[2]}
            doctor_dns=${fields[3]:-}; doctor_lists=${fields[4]:-}; doctor_config_known=1
            echo "OK: конфиг; VPN=$doctor_vpn proxy=$doctor_proxy IPv6=$doctor_ipv6"
        else
            echo 'FAIL: конфиг не прошёл проверку; выполните config validate. Проверяю зависимости обоих компонентов.'
            doctor_failures=$((doctor_failures + 1))
        fi
    else
        echo 'INFO: конфиг отсутствует; проверяю зависимости режима по умолчанию (VPN + proxy). DNS-зависимости не определены.'
    fi
    doctor_require flock 'блокировки сессии'
    doctor_require timeout 'ограничение привилегированных операций'
    doctor_require getent 'разрешение имён'
    if (( doctor_vpn )); then
        doctor_require awg 'управление AmneziaWG'
        doctor_require awg-quick 'запуск и очистка VPN'
    fi
    if (( doctor_vpn || doctor_sandbox )); then doctor_require ip 'интерфейсы и маршруты'; fi
    if (( doctor_vpn || doctor_sandbox )) || [[ "$doctor_ipv6" == on ]]; then doctor_require sudo 'сетевые операции (авторизация сейчас не выполняется)'; fi
    if (( doctor_vpn || doctor_sandbox )) || [[ "$doctor_ipv6" == on ]]; then doctor_require python3 'маршруты, конфигурация или проверка защиты'; fi
    if [[ "$doctor_ipv6" == on ]] || (( doctor_vpn && doctor_proxy )); then doctor_require nft 'сетевая защита'; fi
    if (( doctor_proxy )); then
        doctor_require 3proxy 'локальные HTTP/SOCKS-прокси'
        doctor_require ss 'принадлежность listeners'
    fi
    if (( doctor_proxy || doctor_sandbox )) || [[ -n "$doctor_lists" ]]; then doctor_require curl 'HTTP/SOCKS-проверки или списки маршрутов'; fi
    if (( doctor_vpn && doctor_config_known )) && [[ -n "$doctor_dns" ]]; then doctor_require resolvconf 'DNS туннеля'; fi
    if (( doctor_sandbox )); then
        doctor_require bwrap 'файловая изоляция'
        doctor_require setpriv 'учётные данные sandbox'
        if (( ! doctor_proxy )); then echo 'FAIL: run требует включённый proxy'; doctor_failures=$((doctor_failures + 1)); fi
    fi
    echo 'INFO: проверено наличие команд. AWG kernel module, namespace-права, sudo-доступ и VPN-соединение не проверены.'
    (( doctor_failures == 0 ))
}
