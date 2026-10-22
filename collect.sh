#!/usr/bin/env bash
#
# Версии серверного ПО в JSON: веб-серверы, PHP, СУБД, кеши, очереди, почта,
# конвертеры, средства безопасности и прочее окружение.
# Ничего не устанавливает и не перезапускает: только запускает команды вида
# «--version» и спрашивает у пакетного менеджера, из какого пакета файл и есть ли
# для него обновление в уже скачанных списках пакетов (без сети и без apt update).
#
# На сервере (от root, иначе состояние служб может быть неполным):
#   ./collect.sh > versions.json
#   ./collect.sh -n test -o /var/tmp/versions.json
# С рабочей машины, ничего не копируя на сервер:
#   ssh root@host 'bash -s -- -n test' < collect.sh > test.json
# Отправить отчёт на сервер учёта (адрес и токен выдаёт он, см. README):
#   ./collect.sh -n test --push https://example.com/api/inventory/reports --token ТОКЕН
#
# Совместим с bash 4.2 (CentOS 7 / BitrixVM), Debian/Ubuntu и RHEL-семейством.

set -o pipefail

readonly COLLECTOR_VERSION=4
readonly CMD_TIMEOUT=20

OUTFILE=""
NAME=""
PUSH_URL=""
TOKEN_FILE=""
TOKEN=""
TMP_REPORT=""
PKG=""
SYSTEMD=false
ITEMS=()
ITEM_PKGS=()        # пакет каждого элемента ITEMS, по тем же индексам; пусто — не из пакета
LISTS_UPDATED_AT=""
declare -A SEEN FOUND PKG_VERSION PKG_CANDIDATE PKG_REPOS PKG_SOURCE

usage() {
    cat <<'EOF'
Использование: collect.sh [-o ФАЙЛ] [-n ИМЯ] [--push URL --token ТОКЕН]

  -o, --out ФАЙЛ         записать JSON в файл (по умолчанию — в stdout)
  -n, --name ИМЯ         имя сервера в поле "host" (по умолчанию hostname)
      --push URL         отправить отчёт POST-запросом на этот адрес
      --token ТОКЕН      токен сервера для --push (заголовок Authorization: Bearer)
      --token-file ФАЙЛ  то же, но токен из файла; ещё можно переменной INVENTORY_TOKEN
  -h, --help             эта справка
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { log "Ошибка: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Команда с таймаутом, stdout и stderr вместе (многие пишут версию в stderr).
run() { timeout -k 2 "$CMD_TIMEOUT" "$@" </dev/null 2>&1; }

# Пакетный менеджер: только stdout, таймаут больше — yum на CentOS 7 бывает медленным.
run_pm() { timeout -k 2 120 "$@" </dev/null 2>/dev/null; }

# Строка → JSON-строка в кавычках; пустая строка → null.
json_str() {
    if [[ -z $1 ]]; then
        printf 'null'
        return
    fi
    printf '"%s"' "$(printf '%s' "$1" | tr '\001-\037' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# Версия из вывода команды: первое «число.число…» в первой строке, иначе во всём выводе.
# У клиента MariaDB/MySQL 5.x первым идёт номер протокола («Ver 15.1 Distrib 10.11.6»).
version_of() {
    local first re='([0-9]+(\.[0-9]+)+[a-z0-9]*)' distrib='Distrib ([0-9]+(\.[0-9]+)+)'
    first=$(grep -m1 . <<<"$1")
    if [[ $first =~ $distrib ]] || [[ $first =~ $re ]] || [[ $1 =~ $re ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ $first =~ ([0-9]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# Версия установленного пакета; код возврата 1, если пакет не установлен.
package_version() {
    local s
    case $PKG in
        dpkg)
            s=$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$1" 2>/dev/null) || return 1
            [[ $s == ii* ]] || return 1
            printf '%s' "${s:4}"
            ;;
        rpm)
            s=$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$1" 2>/dev/null) || return 1
            printf '%s' "${s%%$'\n'*}"
            ;;
        *) return 1 ;;
    esac
}

# Пакет, которому принадлежит файл: «имя версия»; пусто, если файл не из пакета.
# Сначала сам путь (redis-server — симлинк из пакета redis-server на файл из redis-tools),
# затем цель симлинка (/usr/bin/php → alternatives → php8.3 ничьи, кроме цели).
package_of() {
    local f p=""
    for f in "$1" "$(readlink -f "$1")"; do
        case $PKG in
            dpkg)
                p=$(dpkg-query -S "$f" 2>/dev/null | grep -v '^diversion' | head -1)
                # На системах с объединённым /usr пакет мог зарегистрировать файл как /bin/…
                [[ -z $p && $f == /usr/* ]] && p=$(dpkg-query -S "${f#/usr}" 2>/dev/null | grep -v '^diversion' | head -1)
                p=${p%%: *}
                p=${p%%,*}
                p=${p%%:*}
                ;;
            rpm)
                p=$(rpm -qf --qf '%{NAME}\n' "$f" 2>/dev/null | head -1) || p=""
                ;;
        esac
        [[ -n $p ]] && break
    done
    [[ -n $p ]] && printf '%s %s' "$p" "$(package_version "$p")"
}

# Юниты systemd по шаблонам имён (без .service), например "redis redis-server".
# Печатает строки «юнит active-состояние enabled-состояние». Шаблоны вида x@.service
# пропускаются, вместо них берутся запущенные экземпляры x@….service.
unit_states() {
    [[ -n $1 && $SYSTEMD == true ]] || return 0
    local pats p u enabled
    read -ra pats <<<"$1"
    for p in "${pats[@]}"; do
        while read -r u _; do
            [[ -z $u || $u == *@.service ]] && continue
            enabled=$(systemctl is-enabled "$u" 2>/dev/null | head -1)
            # Псевдонимы (redis → redis-server, sshd → ssh) дублируют настоящий юнит.
            [[ $enabled == alias ]] && continue
            printf '%s %s %s\n' "${u%.service}" "$(systemctl is-active "$u" 2>/dev/null | head -1)" "$enabled"
        done < <(
            systemctl list-unit-files --type=service --no-legend --no-pager "$p.service" "$p@*.service" 2>/dev/null
            systemctl list-units --type=service --all --no-legend --no-pager --plain "$p@*.service" 2>/dev/null
        )
    done | sort -u
}

services_json() {
    local u a e list=""
    while read -r u a e; do
        list+="${list:+, }{\"unit\": $(json_str "$u"), \"active\": $(json_str "$a"), \"enabled\": $(json_str "$e")}"
    done < <(unit_states "$1")
    printf '[%s]' "$list"
}

# Добавить компонент в список.
# item ID ВЕРСИЯ ПУТЬ "ПАКЕТ ВЕРСИЯ_ПАКЕТА" ШАБЛОНЫ_ЮНИТОВ ВЫВОД [ДОП_ПОЛЯ]
# ВЫВОД — первая строка вывода команды версии как есть, на случай если разбор ошибся.
# ДОП_ПОЛЯ — готовый фрагмент JSON, например '"default": true'.
item() {
    local pkg="" pkgver="" obj
    if [[ -n $4 ]]; then
        pkg=${4%% *}
        pkgver=${4#* }
    fi
    obj="{\"id\": $(json_str "$1"), \"version\": $(json_str "$2"), \"path\": $(json_str "$3")"
    obj+=", \"package\": $(json_str "$pkg"), \"package_version\": $(json_str "$pkgver")"
    obj+=", \"services\": $(services_json "$5")"
    [[ -n $7 ]] && obj+=", $7"
    obj+=", \"raw\": $(json_str "$6")}"
    ITEMS+=("$obj")
    ITEM_PKGS+=("$pkg")
    [[ -n $pkg ]] && PKG_VERSION[$pkg]=$pkgver
    FOUND[$1]=1
}

# probe ID "шаблоны юнитов" команда [ключи…]
# Команда — имя в PATH или абсолютный путь; если её нет, компонент пропускается.
# Один и тот же бинарник под одним ID попадает в список один раз, поэтому можно
# перечислять запасные варианты: mysqld и mariadbd, «memcached -V» и «-h».
probe() {
    local id=$1 units=$2 bin out rc ver key
    shift 2
    bin=$(command -v "$1" 2>/dev/null) || return 0
    key="$id $(readlink -f "$bin")"
    [[ -n ${SEEN[$key]} ]] && return 0
    out=$(run "$bin" "${@:2}")
    rc=$?
    # JVM печатает JAVA_TOOL_OPTIONS первой строкой, там бывают пароли от хранилищ ключей.
    out=$(sed '/^Picked up .*_OPTIONS:/d' <<<"$out")
    ver=$(version_of "$out")
    [[ -z $ver && $rc -ne 0 ]] && return 0
    SEEN[$key]=1
    # mysqld и mysql бывают от MariaDB и Percona — у них свои версии и сроки поддержки.
    case $out in
        *MariaDB*) id=${id/mysql/mariadb} ;;
        *Percona*) id=${id/mysql/percona} ;;
    esac
    item "$id" "$ver" "$bin" "$(package_of "$bin")" "$units" "$(grep -m1 . <<<"$out")"
}

# probe_pkg ID "шаблоны юнитов" пакет…  — версия берётся у пакетного менеджера
# (для ПО, у которого «--version» медленный или требует работающего сервиса).
probe_pkg() {
    local id=$1 units=$2 p v
    shift 2
    for p in "$@"; do
        v=$(package_version "$p") || continue
        item "$id" "$(version_of "$v")" "" "$p $v" "$units" ""
        return 0
    done
}

php_cli() {
    local out
    out=$(run "$1" -v)
    item php "$(version_of "$out")" "$1" "$(package_of "$1")" "" "$(grep -m1 . <<<"$out")" "\"default\": $2"
}

php_fpm() {
    local bin=$1 out unit
    out=$(run "$bin" -v)
    if [[ ${bin##*/} =~ ^php-fpm([0-9.]+)$ ]]; then
        unit="php${BASH_REMATCH[1]}-fpm"            # Debian/Ubuntu: php-fpm8.2 → php8.2-fpm
    elif [[ $bin =~ ^/opt/remi/([^/]+)/ ]]; then
        unit="${BASH_REMATCH[1]}-php-fpm"           # Remi SCL: php81-php-fpm
    else
        unit="php-fpm"
    fi
    item php-fpm "$(version_of "$out")" "$bin" "$(package_of "$bin")" "$unit" "$(grep -m1 . <<<"$out")"
}

# Все установленные PHP: несколько версий рядом (ondrej/sury, remi) — обычное дело.
collect_php() {
    local bin real default="" seen=" " pv
    default=$(command -v php 2>/dev/null) && default=$(readlink -f "$default")
    for bin in /usr/bin/php /usr/bin/php[0-9]* /usr/local/bin/php /usr/local/bin/php[0-9]* \
               /opt/remi/php*/root/usr/bin/php /usr/local/php*/bin/php /opt/php*/bin/php; do
        [[ -x $bin && ${bin##*/} =~ ^php[0-9.]*$ ]] || continue
        real=$(readlink -f "$bin")
        [[ $seen == *" $real "* ]] && continue
        seen+="$real "
        php_cli "$real" "$([[ $real == "$default" ]] && echo true || echo false)"
    done
    for bin in /usr/sbin/php-fpm /usr/sbin/php-fpm[0-9]* /usr/local/sbin/php-fpm* \
               /opt/remi/php*/root/usr/sbin/php-fpm /usr/local/php*/sbin/php-fpm; do
        [[ -x $bin ]] || continue
        real=$(readlink -f "$bin")
        [[ $seen == *" $real "* ]] && continue
        seen+="$real "
        php_fpm "$real"
    done
    for bin in /usr/lib/apache2/modules/libphp*.so /usr/lib64/httpd/modules/libphp*.so; do
        real=$(readlink -f "$bin")
        [[ $seen == *" $real "* ]] && continue
        seen+="$real "
        pv=$(package_of "$real")
        item php-apache "$(version_of "${pv#* }")" "$real" "$pv" "" ""
    done
}

probe_push_server() {
    local f=/opt/push-server/package.json ver
    if [[ -f $f ]]; then
        ver=$(grep -m1 '"version"' "$f" | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
        item push-server "$ver" /opt/push-server "" "push-server*" ""
    else
        probe_pkg push-server "push-server*" push-server bx-push-server
    fi
}

collect_software() {
    # Веб-серверы
    probe nginx "nginx" nginx -v
    probe angie "angie" angie -v
    probe apache "apache2" apache2ctl -v
    probe apache "httpd" httpd -v
    probe haproxy "haproxy" haproxy -v
    probe varnish "varnish" varnishd -V

    # PHP
    collect_php
    probe composer "" composer --version --no-interaction

    # Базы данных
    probe mysql-server "mysql mysqld mariadb" mysqld --version
    probe mysql-server "mysql mysqld mariadb" mariadbd --version
    probe mysql-server "mysql mysqld mariadb" /usr/libexec/mysqld --version
    probe mysql-client "" mysql --version
    local pg
    for pg in /usr/lib/postgresql/*/bin/postgres /usr/pgsql-*/bin/postgres; do
        probe postgresql-server "postgresql*" "$pg" --version
    done
    probe postgresql-server "postgresql*" postgres --version
    probe postgresql-client "" psql --version

    # Кеш и очереди
    probe redis-server "redis redis-server" redis-server --version
    probe redis-cli "" redis-cli --version
    probe valkey "valkey valkey-server" valkey-server --version
    probe keydb "keydb keydb-server" keydb-server --version
    probe memcached "memcached" memcached -V
    probe memcached "memcached" memcached -h
    probe_pkg rabbitmq "rabbitmq-server" rabbitmq-server
    probe supervisor "supervisor supervisord" supervisord -v

    # Окружение Битрикса и Node.js
    probe_push_server
    probe_pkg bitrix-env "" bitrix-env
    probe nodejs "" node -v
    probe npm "" npm -v

    # Поиск
    probe sphinx "sphinxsearch searchd manticore" searchd --help
    probe_pkg elasticsearch "elasticsearch" elasticsearch
    probe_pkg opensearch "opensearch" opensearch

    # Почта
    probe postfix "postfix" postconf -h mail_version
    probe exim "exim4 exim" exim -bV
    probe msmtp "" msmtp --version

    # Конвертеры и медиа
    probe imagemagick "" magick -version
    probe imagemagick "" convert -version
    probe ghostscript "" gs --version
    probe ffmpeg "" ffmpeg -version
    probe_pkg libreoffice "" libreoffice-core libreoffice
    probe catdoc "" catdoc -V
    probe poppler "" pdftotext -v
    probe wkhtmltopdf "" wkhtmltopdf --version
    probe java "" java -version

    # Безопасность и сеть
    probe openssl "" openssl version
    probe openssh "ssh sshd" ssh -V
    probe certbot "" certbot --version
    probe fail2ban "fail2ban" fail2ban-client -V
    probe firewalld "firewalld" firewall-cmd --version
    probe ufw "ufw" ufw version
    probe nftables "nftables" nft --version
    probe iptables "iptables netfilter-persistent" iptables --version
    probe samba "smbd smb winbind" smbd --version

    # Мониторинг
    probe zabbix-agent "zabbix-agent" zabbix_agentd -V
    probe zabbix-agent2 "zabbix-agent2" zabbix_agent2 -V
    probe node-exporter "node_exporter" node_exporter --version
    probe node-exporter "prometheus-node-exporter" prometheus-node-exporter --version

    # Инструменты
    probe git "" git --version
    probe curl "" curl --version
    probe rsync "" rsync --version
    probe lsyncd "lsyncd" lsyncd --version
    probe docker "docker containerd" docker --version
    # Compose — отдельный пакет (docker-compose-plugin), поэтому сначала сам бинарник плагина:
    # через «docker compose» путь и пакет были бы от docker-ce-cli.
    probe docker-compose "" /usr/libexec/docker/cli-plugins/docker-compose version
    probe docker-compose "" /usr/lib/docker/cli-plugins/docker-compose version
    probe docker-compose "" /usr/local/lib/docker/cli-plugins/docker-compose version
    probe docker-compose "" docker-compose --version
    [[ -n ${FOUND[docker-compose]} ]] || probe docker-compose "" docker compose version
    probe python "" python3 --version
    probe ansible "" ansible --version
    probe chrony "chrony chronyd" chronyd -v
    probe_pkg cron "cron crond" cron cronie
    probe logrotate "" logrotate --version

    # Система
    probe systemd "" systemctl --version
    probe glibc "" ldd --version
    probe bash "" bash --version
}

# --- Обновления пакетов: что поставил бы пакетный менеджер и из какого репозитория ---

# Когда последний раз обновлялись списки пакетов (apt update, dnf makecache). Пусто — списков нет.
lists_updated_at() {
    local newest
    case $PKG in
        dpkg) newest=$(find /var/lib/apt/lists -maxdepth 1 -name '*Release' -printf '%T@\n' 2>/dev/null | sort -n | tail -1) ;;
        rpm) newest=$(find /var/cache/dnf /var/cache/yum -name repomd.xml -printf '%T@\n' 2>/dev/null | sort -n | tail -1) ;;
    esac
    [[ -n $newest ]] && date -d "@${newest%.*}" -Iseconds
}

repo_json() {
    printf '{"origin": %s, "suite": %s, "url": %s}' "$(json_str "$1")" "$(json_str "$2")" "$(json_str "$3")"
}

# Поле из строки apt-cache policy «release v=24.04,o=Ubuntu,a=noble-security,n=noble,c=main,b=amd64»
release_field() {
    local re="(^|,)$1=([^,]*)"
    [[ $2 =~ $re ]] && printf '%s' "${BASH_REMATCH[2]}"
}

# Имя дистрибутива: у Ubuntu оно в a= (noble-security), у Debian в n= (bullseye-security,
# а в a= — oldoldstable-security), у сторонних репозиториев a= бывает любым (stable, zabbix).
release_suite() {
    local a n
    a=$(release_field a "$1")
    n=$(release_field n "$1")
    if [[ -n $n && $a == "$n"* ]]; then
        printf '%s' "$a"
    else
        printf '%s' "${n:-$a}"
    fi
}

# apt: кандидат и его репозитории из apt-cache policy. Репозиторий узнаём по Origin
# из его Release-файла: Debian, Ubuntu, Freexian (ELTS), deb.sury.org, nginx, MySQL…
apt_updates() {
    local line src pkg="" cand="" repos="" in_cand=false
    local -A origin suite
    local re_src='^ *-?[0-9]+ (.+)$' re_rel='^ +release (.*)$' re_pkg='^([^ ].*):$'
    local re_cand='^ +Candidate: (.+)$' re_ver='^ (\*\*\*|   ) ([^ ]+) -?[0-9]+$'

    # Все источники: « 500 http://deb.debian.org/debian-security bullseye-security/main amd64 Packages»,
    # следом «release o=Debian,n=bullseye-security,...»
    src=""
    while IFS= read -r line; do
        if [[ $line =~ $re_src ]]; then
            src=${BASH_REMATCH[1]}
            [[ $src == *" Packages" ]] && src=${src% Packages} || src=""
        elif [[ -n $src && $line =~ $re_rel ]]; then
            origin[$src]=$(release_field o "${BASH_REMATCH[1]}")
            suite[$src]=$(release_suite "${BASH_REMATCH[1]}")
            src=""
        fi
    done < <(run_pm apt-cache policy)

    # По пакетам: «Candidate: …», затем таблица версий; у версии-кандидата — её источники
    while IFS= read -r line; do
        if [[ $line =~ $re_pkg ]]; then
            apt_store
            pkg=${BASH_REMATCH[1]} cand="" repos="" in_cand=false
        elif [[ $line =~ $re_cand ]]; then
            cand=${BASH_REMATCH[1]}
            [[ $cand == "(none)" ]] && cand=""
        elif [[ $line =~ $re_ver ]]; then
            [[ -n $cand && ${BASH_REMATCH[2]} == "$cand" ]] && in_cand=true || in_cand=false
        elif $in_cand && [[ $line =~ $re_src && ${BASH_REMATCH[1]} == *" Packages" ]]; then
            src=${BASH_REMATCH[1]% Packages}
            repos+="${repos:+, }$(repo_json "${origin[$src]}" "${suite[$src]}" "${src%% *}")"
        fi
    done < <(run_pm apt-cache policy "$@")
    apt_store
}

# Запомнить разобранный пакет (переменные — из apt_updates)
apt_store() {
    [[ -n $pkg ]] || return 0
    PKG_CANDIDATE[$pkg]=$cand
    PKG_REPOS[$pkg]="[$repos]"
}

# yum/dnf: обновления из кеша (-C, без сети) и репозиторий, из которого пакет поставлен.
# Origin у rpm-репозиториев нет — сообщаем id репозитория: baseos, appstream, epel, remi-safe…
rpm_updates() {
    local mgr line name p f=() re_name='^Name +: (.+)$' re_from='^From repo +: (.+)$'
    local -a w
    local -A upd from
    if have dnf; then mgr=dnf; elif have yum; then mgr=yum; else return 0; fi

    # «имя.архитектура [эпоха:]версия-релиз репозиторий»; yum переносит длинное имя
    # на следующую строку, поэтому поля собираем по три
    while read -r -a w; do
        (( ${#w[@]} )) || continue
        case ${w[0]} in
            Obsoleting) break ;;
            Updated|Available|Last|Security:) continue ;;
        esac
        f+=("${w[@]}")
        [[ ${f[0]} == *.* ]] || { f=(); continue; }
        if (( ${#f[@]} >= 3 )); then
            upd[${f[0]%.*}]="${f[1]#*:} ${f[2]}"
            f=()
        fi
    done < <(run_pm "$mgr" -q -C list updates "$@")

    while IFS= read -r line; do
        if [[ $line =~ $re_name ]]; then
            name=${BASH_REMATCH[1]}
        elif [[ $line =~ $re_from ]]; then
            from[$name]=${BASH_REMATCH[1]#@}
        fi
    done < <(run_pm "$mgr" -q -C info installed "$@")

    for p in "$@"; do
        if [[ -n ${upd[$p]} ]]; then
            PKG_CANDIDATE[$p]=${upd[$p]% *}
            PKG_REPOS[$p]="[$(repo_json "" "${upd[$p]##* }" "")]"
        else
            PKG_CANDIDATE[$p]=${PKG_VERSION[$p]}
            PKG_REPOS[$p]="[${from[$p]:+$(repo_json "" "${from[$p]}" "")}]"
        fi
    done
}

# Пакет-исходник и его версия. По ним базы уязвимостей (OSV, трекеры Debian и Ubuntu)
# ищут уязвимости: php8.3-cli собран из php8.3, redis-server — из redis, libc-bin — из glibc
dpkg_sources() {
    local bin src ver
    while IFS=$'\t' read -r bin src ver; do
        [[ -n $bin && -n $src ]] && PKG_SOURCE[${bin%%:*}]="$src"$'\t'"$ver"
    done < <(run_pm dpkg-query -W -f='${binary:Package}\t${source:Package}\t${source:Version}\n' "$@")
}

# Если списков пакетов нет (apt update ни разу не запускался), кандидатов не сообщаем:
# «обновлений нет» было бы неправдой.
collect_updates() {
    local p pkgs=()
    local -A uniq

    for p in "${ITEM_PKGS[@]}"; do
        [[ -n $p && -z ${uniq[$p]} ]] || continue
        uniq[$p]=1
        pkgs+=("$p")
    done
    (( ${#pkgs[@]} )) || return 0

    # Исходники пакетов от списков пакетов не зависят — их знает сам dpkg
    [[ $PKG == dpkg ]] && dpkg_sources "${pkgs[@]}"

    LISTS_UPDATED_AT=$(lists_updated_at)
    [[ -n $LISTS_UPDATED_AT ]] || return 0

    case $PKG in
        dpkg) apt_updates "${pkgs[@]}" ;;
        rpm) rpm_updates "${pkgs[@]}" ;;
    esac
}

# Элемент software[] с полями обновлений, если они известны
item_json() {
    local obj=${ITEMS[$1]} p=${ITEM_PKGS[$1]} src
    if [[ -n $p && -n ${PKG_REPOS[$p]+x} ]]; then
        obj="${obj%\}}, \"candidate\": $(json_str "${PKG_CANDIDATE[$p]}"), \"repos\": ${PKG_REPOS[$p]}}"
    fi
    if [[ -n $p && -n ${PKG_SOURCE[$p]+x} ]]; then
        src=${PKG_SOURCE[$p]}
        obj="${obj%\}}, \"source\": {\"name\": $(json_str "${src%%$'\t'*}"), \"version\": $(json_str "${src#*$'\t'}")}}"
    fi
    printf '%s' "$obj"
}

# --- Отправка отчёта ---

# Токен сервера для --push: --token, --token-file или переменная INVENTORY_TOKEN
read_token() {
    if [[ -z $TOKEN && -n $TOKEN_FILE ]]; then
        [[ -r $TOKEN_FILE ]] || die "не читается файл токена $TOKEN_FILE"
        TOKEN=$(tr -d ' \t\r\n' < "$TOKEN_FILE")
    fi
    [[ -n $TOKEN ]] || TOKEN=${INVENTORY_TOKEN:-}
    [[ -n $TOKEN ]] || die "для --push нужен токен: --token, --token-file или переменная INVENTORY_TOKEN"
}

# Отправить готовый отчёт. Ответ сервера только печатается: ничего из него не выполняется.
# Повторять отправку при сбое сети безопасно — сервер сам отличит уже полученный отчёт.
push_report() {
    local file=$1 resp code rc message
    have curl || die "для --push нужен curl"
    resp=$(mktemp) || die "не удалось создать временный файл"
    # Токен передаём конфигом curl через stdin, а не аргументом: аргументы видны всем в ps
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
        curl -sS --config - --max-time 60 --retry 3 --retry-delay 10 \
            -H 'Content-Type: application/json' --data-binary @"$file" \
            -o "$resp" -w '%{http_code}' "$PUSH_URL")
    rc=$?
    message=$(sed -n 's/.*"message": *"\([^"]*\)".*/\1/p' "$resp")
    rm -f "$resp"

    (( rc == 0 )) || die "не удалось отправить отчёт на $PUSH_URL (curl: код $rc)"
    case $code in
        2??) log "Отправлено: ${message:-HTTP $code}" ;;
        401) die "сервер не принял токен (HTTP 401)" ;;
        *) die "сервер не принял отчёт (HTTP $code): ${message:-без пояснений}" ;;
    esac
}

os_json() {
    local id="" version_id="" name=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        { read -r id; read -r version_id; read -r name; } < <(
            . /etc/os-release
            printf '%s\n%s\n%s\n' "$ID" "$VERSION_ID" "$PRETTY_NAME"
        )
    elif [[ -f /etc/redhat-release ]]; then
        name=$(head -1 /etc/redhat-release)
    fi
    printf '{"id": %s, "version_id": %s, "name": %s, "kernel": %s, "arch": %s}' \
        "$(json_str "$id")" "$(json_str "$version_id")" "$(json_str "$name")" \
        "$(json_str "$(uname -r)")" "$(json_str "$(uname -m)")"
}

render() {
    local i last=$(( ${#ITEMS[@]} - 1 ))
    printf '{\n'
    printf '  "host": %s,\n' "$(json_str "$NAME")"
    printf '  "hostname": %s,\n' "$(json_str "$(uname -n)")"
    printf '  "collected_at": %s,\n' "$(json_str "$(date -Iseconds)")"
    printf '  "collector_version": %s,\n' "$COLLECTOR_VERSION"
    printf '  "os": %s,\n' "$(os_json)"
    printf '  "package_manager": %s,\n' "$(json_str "$PKG")"
    printf '  "systemd": %s,\n' "$SYSTEMD"
    printf '  "package_lists_updated_at": %s,\n' "$(json_str "$LISTS_UPDATED_AT")"
    printf '  "software": [\n'
    for i in "${!ITEMS[@]}"; do
        printf '    %s%s\n' "$(item_json "$i")" "$( (( i < last )) && printf ',')"
    done
    printf '  ]\n}\n'
}

main() {
    # При запуске «ssh … bash -s < collect.sh» скрипт читается из stdin, поэтому
    # main вызывается последней строкой и сразу отключает stdin от команд.
    exec </dev/null

    while (( $# )); do
        case $1 in
            -o|--out) OUTFILE=$2; shift 2 ;;
            -n|--name) NAME=$2; shift 2 ;;
            --push) PUSH_URL=$2; shift 2 ;;
            --token) TOKEN=$2; shift 2 ;;
            --token-file) TOKEN_FILE=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "неизвестный параметр: $1" ;;
        esac
    done

    export LC_ALL=C COMPOSER_ALLOW_SUPERUSER=1
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
    shopt -s nullglob

    [[ -n $NAME ]] || NAME=$(uname -n | cut -d. -f1)
    if [[ -f /var/lib/dpkg/status ]] && have dpkg-query; then
        PKG=dpkg
    elif have rpm; then
        PKG=rpm
    fi
    [[ -d /run/systemd/system ]] && SYSTEMD=true
    # Без токена отправить не получится — понять это до сбора, а не после
    [[ -n $PUSH_URL ]] && read_token
    (( EUID == 0 )) || log "Внимание: запуск не от root — состояние служб может быть неполным"

    log "Сбор версий ПО на $NAME…"
    collect_software
    collect_updates

    if [[ -n $OUTFILE ]]; then
        # Через временный файл, чтобы внешняя система не прочитала недописанный JSON.
        render >"$OUTFILE.tmp" && mv -f "$OUTFILE.tmp" "$OUTFILE" || die "не удалось записать $OUTFILE"
        log "Готово: $OUTFILE, компонентов: ${#ITEMS[@]}"
    elif [[ -z $PUSH_URL ]]; then
        render
    fi

    if [[ -n $PUSH_URL ]]; then
        if [[ -z $OUTFILE ]]; then
            TMP_REPORT=$(mktemp) || die "не удалось создать временный файл"
            trap 'rm -f "$TMP_REPORT"' EXIT
            render >"$TMP_REPORT" || die "не удалось записать отчёт"
        fi
        push_report "${OUTFILE:-$TMP_REPORT}"
    fi
}

main "$@"
