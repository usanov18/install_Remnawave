# Скрипты для Remnawave

В репозитории четыре основных скрипта:

- `deploy-remnawave.sh` для установки `Remnawave panel + страницы подписок`
- `cleanup-remnawave.sh` для полной очистки именно этой установки перед новым прогоном
- `migrate-remnawave.sh` для переноса панели со старого сервера на новый
- `update-remnawave.sh` для безопасного обновления панели без удаления базы и конфигов

Все четыре скрипта рассчитаны на один сервер.

Сценарий работы максимально простой:

1. Запускаете скрипт на чистом сервере Ubuntu или Debian.
2. Вводите домен админ-панели.
3. Вводите домен страницы подписок.
4. При желании вводите email для Let's Encrypt.
5. Ждёте, пока скрипт сам поднимет панель и HTTPS.
6. Когда скрипт попросит токен, создаёте его в панели и вставляете в терминал.
7. Скрипт сам завершает установку.

## Что делает скрипт

`deploy-remnawave.sh` автоматически:

- устанавливает Docker, Docker Compose, UFW, curl, jq, openssl и базовые пакеты;
- открывает нужные порты в firewall;
- умеет освобождать занятые порты, если они мешают установке;
- скачивает актуальные compose-файлы из официальных репозиториев Remnawave;
- поднимает panel, Postgres и Valkey;
- настраивает HTTPS через Caddy;
- останавливается только на ручном шаге `superadmin + API token`;
- после вставки токена поднимает страницу подписок;
- может создать временного тестового пользователя и проверить реальную subscription-ссылку;
- пишет подробный технический лог в `/var/log/remnawave-deploy.log`.

Скрипт не устанавливает Remnawave node.

## Что делает скрипт очистки

`cleanup-remnawave.sh` автоматически:

- удаляет контейнеры `remnawave`, `remnawave-db`, `remnawave-redis`, `remnawave-subscription-page`, `remnawave-caddy`;
- удаляет volumes и сеть, созданные этой установкой;
- удаляет директорию `/opt/remnawave-stack`;
- удаляет лог установки `/var/log/remnawave-deploy.log`;
- после завершения удаляет свой временный лог очистки;
- оставляет нетронутыми `remnanode`, Docker, UFW и другие посторонние сервисы сервера.

Этот скрипт нужен, если вы хотите вернуть сервер в состояние перед новым прогоном install-скрипта.

## Что делает скрипт миграции

`migrate-remnawave.sh` работает в двух режимах:

- `backup` запускается на старом сервере и собирает архив миграции;
- `restore` запускается на новом сервере после свежей установки и переносит данные в новую панель.

В миграцию входят:

- дамп базы Postgres старой панели;
- `panel .env`;
- `sub .env`, если он есть;
- перенос важных настроек и токенов в новую установку.

Что важно понимать:

- сначала на новом сервере нужно выполнить обычную установку через `deploy-remnawave.sh`;
- затем уже запускать `migrate-remnawave.sh` в режиме `restore`;
- архив миграции по умолчанию сохраняется в `/home/` и оттуда же автоматически подхватывается на новом сервере;
- скрипт миграции не переносит сертификаты Caddy, новый сервер выпустит свои;
- при restore сохраняются домены и инфраструктурные параметры новой установки, а не старой.

## Что делает скрипт обновления

`update-remnawave.sh` нужен для обычного обновления уже работающей панели без переустановки.

Он автоматически:

- создаёт защитный backup базы и конфигов перед стартом;
- сверяет текущие `.env` со свежими sample-файлами Remnawave;
- скачивает актуальные compose-файлы panel и subscription-page;
- загружает новые Docker image;
- перезапускает контейнеры и проверяет, что сервисы снова поднялись.

Что важно понимать:

- скрипт не удаляет базу, volumes, домены и сертификаты Caddy;
- backup перед обновлением сохраняется в `/opt/remnawave-stack/update-backups`;
- при больших version jump всё равно стоит посмотреть release notes Remnawave.

## Что такое Caddy

В этом сценарии `Caddy` это веб-сервер и reverse proxy перед панелью и страницей подписок.

Проще говоря, он:

- принимает входящие запросы снаружи на `80` и `443`;
- выпускает и обновляет HTTPS сертификаты;
- проксирует трафик дальше внутрь, в контейнеры Remnawave.

То есть именно Caddy делает так, что панель открывается как нормальный сайт по вашему домену и по HTTPS.

## Что нужно перед запуском

Нужно подготовить:

- сервер на Ubuntu или Debian;
- доступ `sudo` или root;
- две DNS `A` записи, уже направленные на этот сервер:
- `admin.your-domain.com -> your-server-ip`
- `sub.your-domain.com -> your-server-ip`

## Как запустить

На любом сервере установку можно запустить так:

```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/install_Remnawave/main/deploy-remnawave.sh -o deploy-remnawave.sh
sudo bash deploy-remnawave.sh
```

Очистку этой установки на любом сервере можно запустить так:

```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/install_Remnawave/main/cleanup-remnawave.sh -o cleanup-remnawave.sh
sudo bash cleanup-remnawave.sh
```

Архив миграции со старого сервера можно создать так:

```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/install_Remnawave/main/migrate-remnawave.sh -o migrate-remnawave.sh
sudo bash migrate-remnawave.sh backup
```

А восстановить его на новом сервере так:

```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/install_Remnawave/main/migrate-remnawave.sh -o migrate-remnawave.sh
sudo bash migrate-remnawave.sh restore
```

Обновить уже установленную панель на любом сервере можно так:

```bash
curl -fsSL https://raw.githubusercontent.com/usanov18/install_Remnawave/main/update-remnawave.sh -o update-remnawave.sh
sudo bash update-remnawave.sh
```

При обычном запуске на чистом сервере скрипт спрашивает только:

- домен админ-панели;
- домен страницы подписок;
- email для Let's Encrypt, если хотите указать его явно;
- API токен позже, когда панель уже запущена.

Дополнительные подтверждения появятся только если:

- на сервере уже найдены старые данные Remnawave;
- нужные порты заняты и их нужно освободить;
- DNS ещё указывает не на этот сервер.

## Как выглядит миграция по шагам

1. На старом сервере запустите `migrate-remnawave.sh backup`.
2. Скрипт создаст архив миграции с базой и `.env`.
3. Перенесите этот архив на новый сервер в `/home/`.
4. На новом сервере сначала выполните обычную установку через `deploy-remnawave.sh`.
5. После этого запустите `migrate-remnawave.sh restore`.
6. Скрипт заменит свежую базу на старую, перенесёт важные настройки и перезапустит панель.

## Как выглядит обновление по шагам

1. На рабочем сервере запустите `update-remnawave.sh`.
2. Скрипт сам создаст backup базы и конфигов.
3. Затем он проверит `.env` по актуальным sample-файлам.
4. После этого скачает свежие compose-файлы и новые образы.
5. Перезапустит контейнеры и покажет итоговую сводку.

## Ручной шаг во время установки

Когда скрипт остановится:

1. Откройте `https://<ваш-домен-админки>`.
2. Создайте `superadmin`.
3. Откройте `Remnawave Settings -> API Tokens`.
4. Создайте API токен для страницы подписок.
5. Вставьте этот токен обратно в терминал.

После этого скрипт снова продолжит работу сам.

## Важный момент по sub-домену

Корневой URL `https://<ваш-домен-страницы-подписок>` может отдавать `502`, и это не всегда ошибка.

Такое поведение нормально, если страница подписок используется только через персональные subscription-ссылки пользователей, а не как обычная публичная страница на корне домена.

## Необязательные переменные окружения

По умолчанию мастер установки старается задавать минимум вопросов, но при желании можно заранее переопределить несколько параметров:

```bash
export RW_LETSENCRYPT_EMAIL="you@example.com"
# Обычно указывать не нужно: скрипт сам определяет текущий SSH-порт.
# Нужен только как ручной override, если автоопределение не сработало.
export RW_SSH_PORT="13022"
export RW_ENABLE_TEMP_USER_CHECK="true"
export RW_AUTO_DELETE_TEMP_USER="true"
sudo bash deploy-remnawave.sh
```

## Источники

- [Документация по установке панели](https://docs.rw/docs/install/remnawave-panel)
- [Переменные окружения](https://docs.rw/docs/install/environment-variables)
- [backend docker-compose-prod.yml](https://github.com/remnawave/backend/blob/main/docker-compose-prod.yml)
- [subscription-page docker-compose-prod.yml](https://github.com/remnawave/subscription-page/blob/main/docker-compose-prod.yml)
