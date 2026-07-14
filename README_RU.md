# Matrix Node Installer

[![Matrix](https://img.shields.io/badge/Matrix-Synapse-0DBD8B?logo=matrix&logoColor=white)](https://matrix.org/)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Debian](https://img.shields.io/badge/Debian-13.6-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![LiveKit](https://img.shields.io/badge/LiveKit-MatrixRTC-111111)](https://livekit.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md) · **Русский**

Автоматизированный установщик self-hosted Matrix-инфраструктуры для переписки, голосовых и видеозвонков.

Проект разворачивает на одном Linux-сервере готовый Docker Compose-стек:

- Matrix Synapse;
- PostgreSQL;
- Caddy;
- Coturn;
- LiveKit;
- MatrixRTC JWT Service (`lk-jwt-service`).

Установщик предназначен для личных, семейных и закрытых инсталляций. Публичная регистрация по умолчанию отключена: учётные записи создаются администратором через режимы `user` и `admin`.

## Проверено на чистых VPS

### Операционные системы

- ✔ Debian 13.6
- ✔ Ubuntu 24.04 LTS
- ✔ Ubuntu 26.04 LTS

### Проверенная функциональность

- ✔ Полная установка
- ✔ Создание администратора
- ✔ Создание пользователя
- ✔ Поиск пользователей
- ✔ Личные сообщения
- ✔ Push-уведомления
- ✔ Голосовые звонки
- ✔ Видеозвонки
- ✔ Matrix Federation
- ✔ Резервное копирование
- ✔ Восстановление

Другие актуальные версии Debian и Ubuntu, вероятно, также будут работать, но не проходили проверку.

## Возможности

- автоматическая установка полного Matrix-стека;
- HTTPS через Caddy и Let's Encrypt;
- Matrix Federation через `443/tcp` без внешнего порта `8448`;
- TURN/STUN через Coturn;
- голосовые и видеозвонки через MatrixRTC и LiveKit;
- PostgreSQL вместо встроенной SQLite;
- установка Docker и Docker Compose;
- автоматическая настройка UFW с сохранением текущего SSH-порта;
- опциональная настройка swap на VPS с небольшим объёмом памяти;
- проверка состояния всех компонентов;
- создание обычных пользователей и администраторов;
- резервное копирование и восстановление;
- контролируемый повторный запуск с предварительным бэкапом.

## Поддерживаемые команды

```text
install [--force] [--yes]
check
user USERNAME
admin USERNAME
backup
restore [ARCHIVE]
```

Примеры:

```bash
sudo bash ./matrix-node.sh install
sudo bash ./matrix-node.sh check
sudo bash ./matrix-node.sh user USERNAME
sudo bash ./matrix-node.sh admin USERNAME
sudo bash ./matrix-node.sh backup
sudo bash ./matrix-node.sh restore [ARCHIVE]
```

## Требования

Рекомендуемая конфигурация:

```text
Supported: Debian 13.6, Ubuntu 24.04 LTS, Ubuntu 26.04 LTS
CPU: 2 vCPU
RAM: 2 GB+
Disk: 20 GB+
Public IPv4: обязательно
Domain name: обязательно
```

DNS A-запись домена должна указывать на публичный IPv4-адрес сервера. Проверить её можно командой:

```bash
dig +short matrix.example.org
```

Результат должен совпадать с IP-адресом VPS. Установщик также выполняет эту проверку перед получением TLS-сертификата.

Необходимые порты:

| Порт | Протокол | Назначение |
|---|---|---|
| `80` | TCP | HTTP и ACME challenge |
| `443` | TCP | HTTPS, Matrix Client API и Federation API |
| `3478` | TCP/UDP | Coturn TURN/STUN |
| `5349` | TCP | Coturn over TLS |
| `49160-49200` | UDP | TURN relay |
| `7881` | TCP | LiveKit RTC over TCP |
| `50000-50100` | UDP | LiveKit RTC |

## Установка

Скопируйте `matrix-node.sh` на сервер, затем выполните:

```bash
chmod +x matrix-node.sh
sudo bash ./matrix-node.sh install
```

Установщик запросит домен и при необходимости публичный IPv4-адрес. Пароли и ключи PostgreSQL, Coturn и LiveKit генерируются автоматически и сохраняются в защищённых конфигурационных файлах.

После успешной установки скрипт выведет адрес homeserver и примеры команд для создания пользователей:

```text
Healthcheck passed.
Installation completed: https://matrix.example.org
```

### Автоматическое подтверждение UFW

Чтобы не подтверждать изменение правил firewall вручную:

```bash
sudo bash ./matrix-node.sh install --yes
```

Параметр `--yes` работает только в режиме `install` и относится только к запросу настройки UFW.

### Повторный запуск

Если установщик обнаруживает существующий стек, он останавливается, чтобы исключить случайное изменение данных. Для контролируемого обновления используйте:

```bash
sudo bash ./matrix-node.sh install --force
```

Перед изменением существующей работающей установки скрипт автоматически создаёт резервную копию.

## Проверка установки

```bash
sudo bash ./matrix-node.sh check
```

Проверка охватывает:

```text
Matrix/Synapse
PostgreSQL
Caddy/TLS
Federation
Coturn
LiveKit
lk-jwt-service
UFW
```

Успешный результат:

```text
Healthcheck passed.
```

## Пользователи

Создать администратора:

```bash
sudo bash ./matrix-node.sh admin dima
```

Создать обычного пользователя:

```bash
sudo bash ./matrix-node.sh user test
```

Пароль не передаётся аргументом основного скрипта, а запрашивается интерактивно:

```text
Password:
Confirm password:
```

Результат:

```text
Admin created: @dima:matrix.example.org
User created: @test:matrix.example.org
```

### Подключение Matrix-клиента

```text
Homeserver: https://matrix.example.org
Username: dima
Password: пароль пользователя
Matrix ID: @dima:matrix.example.org
```

Совместим со стандартными Matrix-клиентами.

## Архитектура

```text
Internet
   |
   v
Caddy :443
   |
   +--> Synapse :8008
   |
   +--> LiveKit :7880
   |
   +--> lk-jwt-service :8080

Coturn:
3478/tcp+udp
5349/tcp
49160-49200/udp

LiveKit RTC:
7881/tcp
50000-50100/udp
```

Контейнеры стека:

| Контейнер | Образ по умолчанию |
|---|---|
| `postgres` | `postgres:16-alpine` |
| `synapse` | `ghcr.io/element-hq/synapse:latest` |
| `caddy` | `caddy:2` |
| `coturn` | `coturn/coturn:4.6.3` |
| `livekit` | `livekit/livekit-server:latest` |
| `lk-jwt-service` | `ghcr.io/element-hq/lk-jwt-service:latest` |

Версии можно зафиксировать переменными окружения `SYNAPSE_VERSION`, `POSTGRES_VERSION`, `COTURN_VERSION`, `LIVEKIT_VERSION`, `LK_JWT_VERSION` и `CADDY_VERSION`.

## Маршрутизация Caddy

```text
/.well-known/matrix/server  -> адрес федерации DOMAIN:443
/.well-known/matrix/client  -> homeserver и MatrixRTC LiveKit focus
/livekit/jwt/*              -> lk-jwt-service:8080
/livekit/sfu/*              -> livekit:7880
остальные запросы           -> synapse:8008
```

PostgreSQL и backend-порт Synapse не публикуются в интернет напрямую.

## Matrix Federation

Caddy публикует `/.well-known/matrix/server` со следующим ответом:

```json
{
  "m.server": "matrix.example.org:443"
}
```

Схема подключения:

```text
remote homeserver
    -> https://matrix.example.org/.well-known/matrix/server
    -> matrix.example.org:443
    -> Caddy
    -> Synapse:8008
```

Отдельно открывать `8448/tcp` не требуется.

Проверить федерацию можно через [Matrix Federation Tester](https://federationtester.matrix.org/). Вводите только домен — без `https://` и номера порта.

### Ручная проверка Matrix API

```bash
curl -fsS "https://matrix.example.org/.well-known/matrix/server"
curl -fsS "https://matrix.example.org/.well-known/matrix/client"
curl -i "https://matrix.example.org/_matrix/federation/v1/version"
curl -i "https://matrix.example.org/_matrix/key/v2/server"
curl -i "https://matrix.example.org/_matrix/client/versions"
```

## Резервное копирование

Создать резервную копию:

```bash
sudo bash ./matrix-node.sh backup
```

Архив создаётся в каталоге `.backups` рядом со скриптом и включает конфигурацию, секреты, данные Synapse, конфигурацию Caddy, Coturn и LiveKit, а также согласованный дамп PostgreSQL. Храните копии важных архивов вне VPS.

## Восстановление

Восстановить последний доступный архив:

```bash
sudo bash ./matrix-node.sh restore
```

Восстановить конкретный архив:

```bash
sudo bash ./matrix-node.sh restore /path/to/matrix_backup_TIMESTAMP.tar.gz
```

Если текущий стек работает, перед восстановлением установщик автоматически создаёт страховочную копию его состояния.

## Служебные файлы

```text
.backups/             архивы резервных копий
.matrix-node-state/   журналы запусков и служебное состояние
.secrets.env          сгенерированные секреты
docker-compose.yml    сгенерированная конфигурация контейнеров
postgres/             данные PostgreSQL
synapse/              конфигурация и данные Synapse
caddy/                конфигурация и данные Caddy
coturn/                сертификаты Coturn
livekit/               конфигурация LiveKit
```

Эти данные не следует добавлять в публичный репозиторий.

## Безопасность

Проект рассчитан на закрытую инсталляцию:

- публичная регистрация отключена;
- пользователи создаются только администратором;
- административные учётные записи не создаются автоматически;
- пароли пользователей запрашиваются интерактивно;
- PostgreSQL и Synapse backend не публикуются наружу;
- TLS завершается на Caddy;
- firewall открывает только необходимые порты;
- секреты и конфигурационные файлы создаются с ограниченными правами доступа.

Не публикуйте:

```text
.secrets.env
private keys
TURN secret
LiveKit API secret
PostgreSQL password
Synapse signing key
backup archives
```

### Ограничение передачи пароля

Пароль пользователя не передаётся аргументом основного скрипта. Однако при создании учётной записи он кратковременно передаётся внутренней утилите `register_new_matrix_user` через аргумент `-p`.

Для небольшой личной инсталляции это принято как допустимый компромисс. В средах с повышенными требованиями безопасности механизм следует заменить передачей через stdin или другим способом, исключающим появление пароля в `argv` процесса.

### Изменения системы

Во время установки скрипт может:

- установить Docker, Docker Compose и необходимые системные пакеты;
- настроить и включить UFW;
- добавить правила для обнаруженного SSH-порта и сервисов Matrix;
- изменить `vm.swappiness`;
- создать `/swapfile` и запись в `/etc/fstab` при нехватке памяти.

Перед запуском ознакомьтесь со скриптом и убедитесь, что у вас есть независимая резервная копия важных данных.

## Диагностика

### Caddy не получает сертификат

Проверьте DNS и доступность HTTP:

```bash
dig +short matrix.example.org
curl -I http://matrix.example.org
```

A-запись должна указывать на публичный IP текущего VPS, а порт `80/tcp` должен быть доступен извне.

### Coturn не слушает порт 5349

```bash
ls -la ./coturn/certs/
ss -ltnp | grep 5349
```

Контейнер Coturn должен иметь возможность прочитать сертификат `DOMAIN.crt` и ключ `DOMAIN.key`.

### Федерация не работает

```bash
curl -fsS "https://matrix.example.org/.well-known/matrix/server"
curl -i "https://matrix.example.org/_matrix/federation/v1/version"
```

Первый запрос должен вернуть `matrix.example.org:443`, второй — информацию о Synapse.

### Сообщения работают, звонки не работают

Проверьте:

- Coturn на `3478/tcp`, `3478/udp` и `5349/tcp`;
- TURN relay range `49160-49200/udp`;
- LiveKit на `7881/tcp` и `50000-50100/udp`;
- содержимое `/.well-known/matrix/client`;
- маршруты `/livekit/jwt/*` и `/livekit/sfu/*`.

Для реальной проверки используйте устройства в разных сетях, например Wi-Fi и мобильную сеть.

## Обновление

Перед любым ручным обновлением создайте резервную копию:

```bash
sudo bash ./matrix-node.sh backup
```

Рекомендуемый способ повторно применить конфигурацию установщика:

```bash
sudo bash ./matrix-node.sh install --force
sudo bash ./matrix-node.sh check
```

Образы с тегом `latest` могут содержать несовместимые изменения. Для стабильной эксплуатации задайте конкретные версии контейнеров через переменные окружения.

## Что проверить в клиентах

После установки отдельно проверьте:

- вход через выбранный Matrix-клиент;
- создание комнаты и переписку;
- голосовой и видеозвонок;
- звонок через мобильную сеть;
- TURN fallback;
- федерацию между разными homeserver.

Эти сценарии зависят от конкретных клиентов, сетей и операторов связи и выходят за рамки встроенного installer healthcheck.

## Удаление

Перед удалением обязательно создайте резервную копию:

```bash
sudo bash ./matrix-node.sh backup
```

Остановить контейнеры можно из рабочей директории командой:

```bash
docker compose down
```

Удаление рабочей директории уничтожит конфигурацию, секреты и данные. Убедитесь, что резервная копия хранится отдельно и её восстановление проверено.

## Отказ от гарантий

Проект предоставляется «как есть», без гарантий работоспособности, совместимости и сохранности данных. Администратор самостоятельно отвечает за сервер, домен, пользователей, обновления, резервные копии, безопасность инсталляции и соблюдение применимого законодательства.

Перед использованием на рабочем сервере прочитайте скрипт, проверьте DNS и firewall, создайте резервную копию и протестируйте восстановление.
