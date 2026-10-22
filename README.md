# inventory

`collect.sh` — один bash-скрипт, который определяет, какое серверное ПО установлено
и каких версий, есть ли для пакетов обновления, и выдаёт всё это в JSON. Дальше JSON
можно сохранить в файл или отправить на свой сервер учёта.

Работает на Debian/Ubuntu и RHEL-семействе (CentOS 7, Rocky, Alma, BitrixVM), bash 4.2+.

## Что делает скрипт — и чего не делает

- **Только читает.** Запускает команды вида `nginx -v`, `php -v`, спрашивает у пакетного
  менеджера, из какого пакета программа (`dpkg-query`, `rpm -qf`), состояние служб
  (`systemctl is-active`) и есть ли версия новее в уже скачанных списках пакетов
  (`apt-cache policy`, `yum -C` / `dnf -C`).
- **Ничего не устанавливает, не обновляет и не перезапускает.** `apt update` и
  `yum makecache` тоже не запускает. Файлы на сервере не пишет, кроме `-o ФАЙЛ`.
- **В сеть ходит, только если задан `--push`:** один POST-запрос с JSON на указанный адрес.
  Ответ сервера только печатается в лог — ничего из него не выполняется.
- **Сам не обновляется.** Новая версия ставится вручную (см. ниже), со сверкой хеша.

Что именно уйдёт наружу, видно заранее: запуск без `--push` печатает JSON на экран.

## Установка

Каждая версия — тег в этом репозитории. Скачайте нужную и сверьте sha256 — команда
не пойдёт дальше, если файл отличается от опубликованного:

```bash
curl -fsSLO https://raw.githubusercontent.com/Svyatoslav-r/inventory/v4.1/collect.sh \
  && echo "cfef56aecf9fcda79639e7009c5a685d1c2ecd63b774d84d2bc91427ebbd1d7e  collect.sh" | sha256sum -c
```

Или через git: `git clone --branch v4.1 https://github.com/Svyatoslav-r/inventory`.

## Запуск

```bash
sudo bash collect.sh                         # JSON в stdout
sudo bash collect.sh -n web-1 -o web-1.json  # в файл, имя сервера в поле host
```

С рабочей машины, ничего не копируя на сервер:

```bash
ssh root@web-1.example.com 'bash -s -- -n web-1' < collect.sh > web-1.json
```

Запускать нужно от root, иначе состояние служб может быть неполным.

| Ключ | Что делает |
|---|---|
| `-n`, `--name ИМЯ` | имя сервера в поле `host` (по умолчанию — hostname) |
| `-o`, `--out ФАЙЛ` | записать JSON в файл, а не в stdout |
| `--push URL` | отправить JSON POST-запросом на этот адрес |
| `--token ТОКЕН` | токен для `--push` (заголовок `Authorization: Bearer`); ещё можно `--token-file ФАЙЛ` или переменной `INVENTORY_TOKEN` |

## Отправка на сервер учёта

```bash
sudo bash collect.sh -n web-1 --push https://ваш-сервер/api/inventory/reports --token ТОКЕН
```

Адрес и токен выдаёт сервер учёта. Токен передаётся curl через stdin, поэтому в аргументах
curl его не видно. С `--push` JSON в stdout не выводится (с `-o` — ещё и сохраняется в файл),
в лог пишется ответ сервера или причина отказа. При сбое сети curl повторяет запрос
до 3 раз.

## Что в JSON

```json
{
  "host": "test",
  "hostname": "srv-test-01",
  "collected_at": "2026-10-21T15:04:50+03:00",
  "collector_version": 4,
  "os": {"id": "ubuntu", "version_id": "24.04", "name": "Ubuntu 24.04.5 LTS", "kernel": "6.8.0-45-generic", "arch": "x86_64"},
  "package_manager": "dpkg",
  "systemd": true,
  "package_lists_updated_at": "2026-10-21T06:25:13+03:00",
  "software": [
    {"id": "nginx", "version": "1.24.0", "path": "/usr/sbin/nginx", "package": "nginx", "package_version": "1.24.0-2ubuntu7.1", "services": [{"unit": "nginx", "active": "active", "enabled": "enabled"}], "raw": "nginx version: nginx/1.24.0 (Ubuntu)", "candidate": "1.24.0-2ubuntu7.5", "repos": [{"origin": "Ubuntu", "suite": "noble-updates", "url": "http://archive.ubuntu.com/ubuntu"}, {"origin": "Ubuntu", "suite": "noble-security", "url": "http://security.ubuntu.com/ubuntu"}]},
    {"id": "php", "version": "8.3.6", "path": "/usr/bin/php8.3", "package": "php8.3-cli", "package_version": "8.3.6-0ubuntu0.24.04.12", "services": [], "default": true, "raw": "PHP 8.3.6 (cli) (built: Oct  7 2026 18:06:38) (NTS)"},
    {"id": "redis-server", "version": "7.0.15", "path": "/usr/bin/redis-server", "package": "redis-server", "package_version": "5:7.0.15-1ubuntu0.24.04.5", "services": [], "raw": "Redis server v=7.0.15 ..."}
  ]
}
```

Каждый элемент `software` — одна установленная программа:

| Поле | Что это |
|---|---|
| `id` | постоянный идентификатор: `nginx`, `php`, `php-fpm`, `mysql-server`, `mariadb-server`, `redis-server`… |
| `version` | версия программы, например `1.24.0` |
| `path` | где лежит программа; `null`, если версия взята из пакета |
| `package`, `package_version` | пакет ОС и его точная версия; `null`, если программа поставлена не из пакета |
| `services` | службы systemd и их состояние: `active` — работает, `enabled` — запускается при загрузке |
| `default` | только у `php`: этот PHP вызывается командой `php` |
| `raw` | первая строка вывода команды версии как есть, на случай если `version` разобран неверно |
| `candidate` | версия пакета, которую поставил бы `apt upgrade` / `yum update`. Совпадает с `package_version` — обновлений нет |
| `source` | только dpkg: пакет-исходник и его версия, `{"name": "php8.3", "version": "8.3.6-0ubuntu0.24.04.12"}`. По ним ищут уязвимости базы OSV и трекеры Debian/Ubuntu: `php8.3-cli` собран из `php8.3`, `redis-server` — из `redis` |
| `repos` | откуда придёт эта версия: `origin` — поле Origin из Release-файла репозитория apt (`Debian`, `Ubuntu`, `Freexian` — Debian ELTS, `deb.sury.org`, `nginx`, `Docker`, `MySQL`, `Zabbix`…), `suite` — дистрибутив (`bullseye-security`, `noble-updates`) или id репозитория yum/dnf (`baseos`, `epel`, `remi-safe`), `url` — адрес репозитория apt. `[]` — пакета нет ни в одном подключённом репозитории |

`candidate` и `repos` есть только у программ из пакетов и только когда на сервере есть
списки пакетов. Скрипт их не обновляет (`apt update` не запускает, у yum/dnf берёт кеш, `-C`),
поэтому кандидат настолько свеж, насколько свежи списки: время их последнего обновления —
в поле `package_lists_updated_at` на верхнем уровне. Если списков нет, это поле `null`,
а `candidate` и `repos` не выводятся: «обновлений нет» было бы неправдой.

Если на сервере несколько версий PHP, у каждой будет своя запись с `id: "php"`
(и `php-fpm`, если он установлен).

## Что проверяется

| Группа | `id` |
|---|---|
| Веб-серверы | `nginx`, `angie`, `apache`, `haproxy`, `varnish` |
| PHP | `php`, `php-fpm`, `php-apache`, `composer` |
| Базы данных | `mysql-server` / `mariadb-server` / `percona-server`, `mysql-client` / `mariadb-client` / `percona-client`, `postgresql-server`, `postgresql-client` |
| Кеш и очереди | `redis-server`, `redis-cli`, `valkey`, `keydb`, `memcached`, `rabbitmq`, `supervisor` |
| Окружение Битрикса | `push-server`, `bitrix-env`, `nodejs`, `npm` |
| Поиск | `sphinx`, `elasticsearch`, `opensearch` |
| Почта | `postfix`, `exim`, `msmtp` |
| Конвертеры | `imagemagick`, `ghostscript`, `ffmpeg`, `libreoffice`, `catdoc`, `poppler`, `wkhtmltopdf`, `java` |
| Безопасность | `openssl`, `openssh`, `certbot`, `fail2ban`, `firewalld`, `ufw`, `nftables`, `iptables`, `samba` |
| Мониторинг | `zabbix-agent`, `zabbix-agent2`, `node-exporter` |
| Инструменты | `git`, `curl`, `rsync`, `lsyncd`, `docker`, `docker-compose`, `python`, `ansible`, `chrony`, `cron`, `logrotate` |
| Система | `systemd`, `glibc`, `bash` |

В JSON попадает только то, что реально установлено.
