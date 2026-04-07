#!/usr/bin/env bash
set -Eeuo pipefail

WORKDIR="/opt/remnawave-stack"
PANEL_DIR="$WORKDIR/panel"
SUB_DIR="$WORKDIR/subscription"
PROXY_DIR="$WORKDIR/proxy"
LOG_FILE="/var/log/remnawave-migration.log"
CURRENT_STAGE="0"
TOTAL_STAGES="0"

MODE="${1:-}"
ARCHIVE_PATH=""
TMP_DIR=""
BACKUP_STAGING_DIR=""
ARCHIVE_WORK_DIR=""

SOURCE_PANEL_ENV=""
SOURCE_SUB_ENV=""
TARGET_PANEL_ENV="$PANEL_DIR/.env"
TARGET_SUB_ENV="$SUB_DIR/.env"
TARGET_PANEL_COMPOSE="$PANEL_DIR/docker-compose.yml"
TARGET_SUB_COMPOSE="$SUB_DIR/docker-compose.yml"
TARGET_PROXY_COMPOSE="$PROXY_DIR/docker-compose.yml"

PG_CONTAINER=""
PG_USER=""
PG_DB=""
TARGET_PANEL_DOMAIN=""
TARGET_SUB_DOMAIN=""
BACKUP_PANEL_DOMAIN=""
BACKUP_SUB_DOMAIN=""
BACKUP_CREATED_AT=""
RESTORE_SUMMARY=""
BACKUP_HAS_SUB_ENV="false"

C_RESET=""
C_BOLD=""
C_BLUE=""
C_GREEN=""
C_YELLOW=""
C_RED=""
C_DIM=""

init_ui() {
    if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_BLUE=$'\033[34m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_RED=$'\033[31m'
        C_DIM=$'\033[2m'
    fi

    mkdir -p "$(dirname "$LOG_FILE")"
    : >"$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

print_rule() {
    printf '%s\n' "----------------------------------------------------------------"
}

print_intro() {
    printf '\n'
    print_rule
    printf '%bМиграция Remnawave Panel%b\n' "${C_BOLD}${C_BLUE}" "${C_RESET}"
    print_rule

    if [[ "$MODE" == "backup" ]]; then
        printf 'Режим: backup. Сейчас скрипт соберёт архив миграции со старого сервера.\n'
        printf 'В архив попадут дамп Postgres и .env-файлы панели / страницы подписок.\n'
    else
        printf 'Режим: restore. Сейчас скрипт перенесёт архив миграции в свежую установку на новом сервере.\n'
        printf 'Он восстановит базу и важные настройки, но сохранит домены и инфраструктурные параметры нового сервера.\n'
    fi

    printf '%bФайл лога:%b %s\n' "${C_DIM}" "${C_RESET}" "$LOG_FILE"
}

start_stage() {
    local title="$1"
    local hint="${2:-}"

    CURRENT_STAGE=$((CURRENT_STAGE + 1))
    printf '\n'
    print_rule
    printf '%bЭтап %s/%s%b | %s\n' "${C_BOLD}${C_BLUE}" "$CURRENT_STAGE" "$TOTAL_STAGES" "${C_RESET}" "$title"
    if [[ -n "$hint" ]]; then
        printf '%s\n' "$hint"
    fi
    print_rule
}

log() {
    printf '%b[INFO]%b %s\n' "${C_BLUE}" "${C_RESET}" "$*"
}

success() {
    printf '%b[OK]%b %s\n' "${C_GREEN}" "${C_RESET}" "$*"
}

note() {
    printf '%b[ЗАМЕТКА]%b %s\n' "${C_DIM}" "${C_RESET}" "$*"
}

warn() {
    printf '%b[WARN]%b %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

die() {
    printf '%b[ERROR]%b %s\n' "${C_RED}" "${C_RESET}" "$*" >&2
    exit 1
}

tail_log_excerpt() {
    if [[ -f "$LOG_FILE" ]]; then
        warn "Последние строки из ${LOG_FILE}:"
        tail -n 20 "$LOG_FILE" >&2 || true
    fi
}

run_logged() {
    local label="$1"
    shift

    log "$label"
    if "$@" >>"$LOG_FILE" 2>&1; then
        success "$label"
        return 0
    fi

    warn "Шаг завершился ошибкой: ${label}"
    tail_log_excerpt
    return 1
}

on_error() {
    local line="$1"
    warn "Скрипт остановился на строке ${line}. Проверьте сообщение выше и лог ${LOG_FILE}."
}

trap 'on_error "$LINENO"' ERR

cleanup_temp_dirs() {
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup_temp_dirs EXIT

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Запустите скрипт от root: sudo bash $0"
    fi
}

require_dependencies() {
    local missing=()

    for cmd in docker tar awk sed grep; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        die "Не найдены обязательные команды: ${missing[*]}"
    fi
}

prompt_value() {
    local var_name="$1"
    local label="$2"
    local default_value="${3:-}"
    local value=""

    if [[ -n "$default_value" ]]; then
        read -r -p "$label [$default_value]: " value
    else
        read -r -p "$label: " value
    fi

    if [[ -z "$value" ]]; then
        value="$default_value"
    fi

    printf -v "$var_name" '%s' "$value"
}

confirm() {
    local label="$1"
    local default_answer="${2:-Y}"
    local prompt=""
    local answer=""

    case "$default_answer" in
        Y|y)
            prompt="Y/n"
            ;;
        N|n)
            prompt="y/N"
            ;;
        *)
            prompt="y/n"
            ;;
    esac

    read -r -p "$label [$prompt]: " answer
    answer="${answer:-$default_answer}"

    case "$answer" in
        Y|y|yes|YES|ДА|Да|да)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

choose_mode_if_needed() {
    if [[ "$MODE" == "backup" || "$MODE" == "restore" ]]; then
        return 0
    fi

    cat <<'EOF'

Что нужно сделать:
1. Создать архив миграции со старого сервера
2. Восстановить архив миграции на новом сервере

EOF

    while true; do
        local answer=""
        read -r -p "Выберите режим [1/2]: " answer

        case "$answer" in
            1)
                MODE="backup"
                return 0
                ;;
            2)
                MODE="restore"
                return 0
                ;;
            *)
                warn "Введите 1 или 2."
                ;;
        esac
    done
}

set_total_stages() {
    if [[ "$MODE" == "backup" ]]; then
        TOTAL_STAGES="4"
    else
        TOTAL_STAGES="5"
    fi
}

first_existing_path() {
    local candidate=""

    for candidate in "$@"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

find_latest_home_migration_archive() {
    local latest_archive=""

    latest_archive="$(ls -1t /home/remnawave-migration-*.tar.gz 2>/dev/null | head -n 1 || true)"
    printf '%s' "$latest_archive"
}

trim_quotes() {
    local value="$1"

    if [[ "$value" =~ ^\".*\"$ ]] || [[ "$value" =~ ^\'.*\'$ ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

get_env_raw_value() {
    local file_path="$1"
    local key="$2"

    awk -F= -v wanted_key="$key" '
        $0 ~ /^[[:space:]]*#/ { next }
        $1 == wanted_key {
            sub(/^[^=]*=/, "", $0)
            print $0
            exit
        }
    ' "$file_path" 2>/dev/null || true
}

get_env_value() {
    local file_path="$1"
    local key="$2"
    local raw_value=""

    raw_value="$(get_env_raw_value "$file_path" "$key")"
    trim_quotes "$raw_value"
}

set_env_raw_value() {
    local file_path="$1"
    local key="$2"
    local raw_value="$3"
    local escaped_value=""

    escaped_value="$(printf '%s' "$raw_value" | sed -e 's/[\/&]/\\&/g')"

    if grep -q "^${key}=" "$file_path"; then
        sed -i "s/^${key}=.*/${key}=${escaped_value}/" "$file_path"
    else
        printf '\n%s=%s\n' "$key" "$raw_value" >>"$file_path"
    fi
}

key_in_list() {
    local needle="$1"
    shift
    local item=""

    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done

    return 1
}

merge_env_file() {
    local source_file="$1"
    local target_file="$2"
    shift 2
    local skip_keys=("$@")
    local line=""
    local key=""
    local raw_value=""

    [[ -f "$source_file" ]] || return 0
    [[ -f "$target_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *=* ]] && continue

        key="${line%%=*}"
        raw_value="${line#*=}"

        if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            continue
        fi

        if key_in_list "$key" "${skip_keys[@]}"; then
            continue
        fi

        set_env_raw_value "$target_file" "$key" "$raw_value"
    done <"$source_file"
}

ensure_container_running() {
    local container_name="$1"

    if ! docker ps --format '{{.Names}}' | grep -qx "$container_name"; then
        if docker ps -a --format '{{.Names}}' | grep -qx "$container_name"; then
            run_logged "Запуск контейнера ${container_name}" docker start "$container_name"
        else
            die "Контейнер ${container_name} не найден."
        fi
    fi
}

docker_compose_panel() {
    docker compose -f "$TARGET_PANEL_COMPOSE" "$@"
}

docker_compose_sub() {
    docker compose -f "$TARGET_SUB_COMPOSE" -p remnawave-subscription "$@"
}

docker_compose_proxy() {
    docker compose -f "$TARGET_PROXY_COMPOSE" -p remnawave-proxy "$@"
}

wait_for_container_running() {
    local container_name="$1"
    local timeout_seconds="${2:-90}"
    local elapsed="0"
    local state=""

    while (( elapsed < timeout_seconds )); do
        state="$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || true)"
        if [[ "$state" == "running" ]]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

wait_for_container_health() {
    local container_name="$1"
    local timeout_seconds="${2:-180}"
    local elapsed="0"
    local health_state=""
    local run_state=""

    while (( elapsed < timeout_seconds )); do
        health_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_name" 2>/dev/null || true)"
        run_state="$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || true)"

        if [[ -n "$health_state" && "$health_state" == "healthy" ]]; then
            return 0
        fi

        if [[ -z "$health_state" && "$run_state" == "running" ]]; then
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    return 1
}

show_backup_scope() {
    cat <<EOF

Будет создан архив миграции со старого сервера.

В архив попадут:
- дамп Postgres базы Remnawave;
- panel .env;
- sub .env, если он найден;
- файл manifest с краткой служебной информацией.

В архив не попадут:
- сертификаты Caddy;
- Docker volumes целиком;
- remnanode и посторонние сервисы.

EOF
}

show_restore_scope() {
    cat <<EOF

Сценарий восстановления:
- берём архив миграции со старого сервера;
- переносим базу в новую чистую установку;
- переносим важные настройки из старых .env;
- сохраняем домены и инфраструктурные параметры нового сервера.

Важно:
- сначала нужно полностью развернуть новую установку через deploy-remnawave.sh;
- restore не переносит сертификаты Caddy, новый сервер получает свои;
- текущая свежая база на новом сервере будет заменена дампом из архива.

EOF
}

prompt_backup_inputs() {
    local suggested_panel_env=""
    local suggested_sub_env=""
    local timestamp=""

    suggested_panel_env="$(first_existing_path \
        /opt/remnawave-stack/panel/.env \
        /opt/remnawave/.env \
        /srv/remnawave/.env || true)"

    suggested_sub_env="$(first_existing_path \
        /opt/remnawave-stack/subscription/.env \
        /opt/remnawave-subscription/.env \
        /srv/remnawave-subscription/.env || true)"

    prompt_value SOURCE_PANEL_ENV "Путь к panel .env на старом сервере" "${suggested_panel_env:-/opt/remnawave-stack/panel/.env}"
    if [[ ! -f "$SOURCE_PANEL_ENV" ]]; then
        die "Файл panel .env не найден: ${SOURCE_PANEL_ENV}"
    fi

    prompt_value SOURCE_SUB_ENV "Путь к sub .env на старом сервере (можно оставить пустым)" "${suggested_sub_env:-}"
    if [[ -n "$SOURCE_SUB_ENV" && ! -f "$SOURCE_SUB_ENV" ]]; then
        warn "Файл sub .env не найден: ${SOURCE_SUB_ENV}. Продолжу без него."
        SOURCE_SUB_ENV=""
    fi

    prompt_value PG_CONTAINER "Имя контейнера Postgres со старой панелью" "remnawave-db"

    PG_USER="$(get_env_value "$SOURCE_PANEL_ENV" "POSTGRES_USER")"
    PG_DB="$(get_env_value "$SOURCE_PANEL_ENV" "POSTGRES_DB")"

    prompt_value PG_USER "Postgres user старой панели" "${PG_USER:-remnawave}"
    prompt_value PG_DB "Postgres database старой панели" "${PG_DB:-remnawave}"

    timestamp="$(date +%Y%m%d-%H%M%S)"
    prompt_value ARCHIVE_PATH "Куда сохранить архив миграции" "/home/remnawave-migration-${timestamp}.tar.gz"

    BACKUP_PANEL_DOMAIN="$(get_env_value "$SOURCE_PANEL_ENV" "PANEL_DOMAIN")"
    BACKUP_SUB_DOMAIN="$(get_env_value "$SOURCE_PANEL_ENV" "SUB_PUBLIC_DOMAIN")"

    show_backup_scope
}

prompt_restore_inputs() {
    local suggested_archive=""

    suggested_archive="$(find_latest_home_migration_archive)"
    prompt_value ARCHIVE_PATH "Путь к архиву миграции на новом сервере" "${suggested_archive:-/home/remnawave-migration-YYYYMMDD-HHMMSS.tar.gz}"
    [[ -n "$ARCHIVE_PATH" ]] || die "Нужно указать путь к архиву миграции."
    [[ -f "$ARCHIVE_PATH" ]] || die "Архив не найден: ${ARCHIVE_PATH}"

    prompt_value TARGET_PANEL_ENV "Путь к panel .env новой установки" "$TARGET_PANEL_ENV"
    prompt_value TARGET_SUB_ENV "Путь к sub .env новой установки" "$TARGET_SUB_ENV"

    TARGET_PANEL_COMPOSE="$(dirname "$TARGET_PANEL_ENV")/docker-compose.yml"
    TARGET_SUB_COMPOSE="$(dirname "$TARGET_SUB_ENV")/docker-compose.yml"
    TARGET_PROXY_COMPOSE="$PROXY_DIR/docker-compose.yml"

    [[ -f "$TARGET_PANEL_ENV" ]] || die "Не найден panel .env новой установки: ${TARGET_PANEL_ENV}"
    [[ -f "$TARGET_PANEL_COMPOSE" ]] || die "Не найден docker-compose панели: ${TARGET_PANEL_COMPOSE}"
    [[ -f "$TARGET_SUB_ENV" ]] || die "Не найден sub .env новой установки: ${TARGET_SUB_ENV}"
    [[ -f "$TARGET_SUB_COMPOSE" ]] || die "Не найден docker-compose страницы подписок: ${TARGET_SUB_COMPOSE}"
    [[ -f "$TARGET_PROXY_COMPOSE" ]] || die "Не найден proxy compose новой установки: ${TARGET_PROXY_COMPOSE}"

    PG_CONTAINER="remnawave-db"
    PG_USER="$(get_env_value "$TARGET_PANEL_ENV" "POSTGRES_USER")"
    PG_DB="$(get_env_value "$TARGET_PANEL_ENV" "POSTGRES_DB")"
    TARGET_PANEL_DOMAIN="$(get_env_value "$TARGET_PANEL_ENV" "PANEL_DOMAIN")"
    TARGET_SUB_DOMAIN="$(get_env_value "$TARGET_PANEL_ENV" "SUB_PUBLIC_DOMAIN")"

    [[ -n "$PG_USER" ]] || die "Не удалось определить POSTGRES_USER из ${TARGET_PANEL_ENV}"
    [[ -n "$PG_DB" ]] || die "Не удалось определить POSTGRES_DB из ${TARGET_PANEL_ENV}"

    show_restore_scope
}

write_backup_manifest() {
    BACKUP_CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat >"$BACKUP_STAGING_DIR/manifest.env" <<EOF
BACKUP_CREATED_AT=${BACKUP_CREATED_AT}
SOURCE_PANEL_ENV=${SOURCE_PANEL_ENV}
SOURCE_SUB_ENV=${SOURCE_SUB_ENV}
SOURCE_POSTGRES_CONTAINER=${PG_CONTAINER}
SOURCE_POSTGRES_USER=${PG_USER}
SOURCE_POSTGRES_DB=${PG_DB}
BACKUP_HAS_SUB_ENV=${BACKUP_HAS_SUB_ENV}
PANEL_DOMAIN=${BACKUP_PANEL_DOMAIN}
SUB_PUBLIC_DOMAIN=${BACKUP_SUB_DOMAIN}
EOF
}

create_backup_archive() {
    TMP_DIR="$(mktemp -d /tmp/remnawave-migration-backup.XXXXXX)"
    BACKUP_STAGING_DIR="$TMP_DIR/archive"
    mkdir -p "$BACKUP_STAGING_DIR"

    cp "$SOURCE_PANEL_ENV" "$BACKUP_STAGING_DIR/panel.env"
    chmod 600 "$BACKUP_STAGING_DIR/panel.env"

    if [[ -n "$SOURCE_SUB_ENV" && -f "$SOURCE_SUB_ENV" ]]; then
        cp "$SOURCE_SUB_ENV" "$BACKUP_STAGING_DIR/sub.env"
        chmod 600 "$BACKUP_STAGING_DIR/sub.env"
        BACKUP_HAS_SUB_ENV="true"
    fi

    ensure_container_running "$PG_CONTAINER"
    log "Создаю дамп базы Postgres из контейнера ${PG_CONTAINER}..."
    docker exec "$PG_CONTAINER" pg_dump \
        -U "$PG_USER" \
        -d "$PG_DB" \
        -Fc \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges >"$BACKUP_STAGING_DIR/postgres.dump"
    chmod 600 "$BACKUP_STAGING_DIR/postgres.dump"
    success "Дамп Postgres сохранён."

    write_backup_manifest

    mkdir -p "$(dirname "$ARCHIVE_PATH")"
    run_logged "Упаковка архива миграции" tar -C "$BACKUP_STAGING_DIR" -czf "$ARCHIVE_PATH" .
    chmod 600 "$ARCHIVE_PATH"
}

read_manifest_value() {
    local key="$1"

    awk -F= -v wanted_key="$key" '$1 == wanted_key { sub(/^[^=]*=/, "", $0); print $0; exit }' \
        "$ARCHIVE_WORK_DIR/manifest.env" 2>/dev/null || true
}

unpack_archive() {
    TMP_DIR="$(mktemp -d /tmp/remnawave-migration-restore.XXXXXX)"
    ARCHIVE_WORK_DIR="$TMP_DIR/archive"
    mkdir -p "$ARCHIVE_WORK_DIR"

    run_logged "Распаковка архива миграции" tar -C "$ARCHIVE_WORK_DIR" -xzf "$ARCHIVE_PATH"

    [[ -f "$ARCHIVE_WORK_DIR/postgres.dump" ]] || die "В архиве не найден postgres.dump"
    [[ -f "$ARCHIVE_WORK_DIR/panel.env" ]] || die "В архиве не найден panel.env"
    [[ -f "$ARCHIVE_WORK_DIR/manifest.env" ]] || die "В архиве не найден manifest.env"

    BACKUP_HAS_SUB_ENV="$(read_manifest_value "BACKUP_HAS_SUB_ENV")"
    BACKUP_PANEL_DOMAIN="$(read_manifest_value "PANEL_DOMAIN")"
    BACKUP_SUB_DOMAIN="$(read_manifest_value "SUB_PUBLIC_DOMAIN")"
    BACKUP_CREATED_AT="$(read_manifest_value "BACKUP_CREATED_AT")"
}

backup_target_envs() {
    local backup_dir=""
    backup_dir="$WORKDIR/migration-rollback-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$backup_dir"
    cp "$TARGET_PANEL_ENV" "$backup_dir/panel.env.before-restore"
    cp "$TARGET_SUB_ENV" "$backup_dir/sub.env.before-restore"
    note "На всякий случай сохранил резервную копию текущих .env: ${backup_dir}"
}

merge_panel_env_for_restore() {
    merge_env_file "$ARCHIVE_WORK_DIR/panel.env" "$TARGET_PANEL_ENV" \
        APP_PORT \
        METRICS_PORT \
        DATABASE_URL \
        POSTGRES_USER \
        POSTGRES_PASSWORD \
        POSTGRES_DB \
        PANEL_DOMAIN \
        FRONT_END_DOMAIN \
        SUB_PUBLIC_DOMAIN
}

merge_sub_env_for_restore() {
    if [[ -f "$ARCHIVE_WORK_DIR/sub.env" && -f "$TARGET_SUB_ENV" ]]; then
        merge_env_file "$ARCHIVE_WORK_DIR/sub.env" "$TARGET_SUB_ENV" \
            APP_PORT \
            REMNAWAVE_PANEL_URL
    else
        note "sub.env в архиве не найден. Оставляю текущий файл новой установки без изменений."
    fi
}

stop_target_app_containers() {
    docker stop remnawave remnawave-subscription-page remnawave-caddy >/dev/null 2>&1 || true
}

start_target_dependencies() {
    run_logged "Запуск Postgres и Valkey новой установки" docker_compose_panel up -d remnawave-db remnawave-redis
    ensure_container_running "$PG_CONTAINER"

    if ! wait_for_container_health remnawave-db 120; then
        die "Контейнер remnawave-db не перешёл в healthy."
    fi
}

restore_database() {
    log "Восстанавливаю базу из архива в контейнер ${PG_CONTAINER}..."
    docker exec -i "$PG_CONTAINER" pg_restore \
        -U "$PG_USER" \
        -d "$PG_DB" \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges <"$ARCHIVE_WORK_DIR/postgres.dump" >>"$LOG_FILE" 2>&1
    success "База Remnawave восстановлена."
}

start_target_stack() {
    run_logged "Запуск панели после восстановления" docker_compose_panel up -d
    run_logged "Запуск страницы подписок после восстановления" docker_compose_sub up -d
    run_logged "Запуск Caddy после восстановления" docker_compose_proxy up -d

    if ! wait_for_container_health remnawave 240; then
        docker logs --tail 80 remnawave || true
        die "Контейнер remnawave не поднялся корректно после restore."
    fi

    if ! wait_for_container_health remnawave-subscription-page 120; then
        docker logs --tail 80 remnawave-subscription-page || true
        die "Контейнер remnawave-subscription-page не поднялся корректно после restore."
    fi

    if ! wait_for_container_running remnawave-caddy 120; then
        docker logs --tail 80 remnawave-caddy || true
        die "Контейнер remnawave-caddy не поднялся корректно после restore."
    fi
}

show_backup_summary() {
    cat <<EOF

Архив миграции готов.

Что внутри:
- panel.env
- $( [[ "$BACKUP_HAS_SUB_ENV" == "true" ]] && printf 'sub.env\n- ' )postgres.dump
- manifest.env

Путь к архиву:
- ${ARCHIVE_PATH}

Дальше:
1. Скопируйте архив на новый сервер в /home/.
2. Разверните новую чистую установку через deploy-remnawave.sh.
3. На новом сервере запустите этот же скрипт в режиме restore.

EOF
}

show_restore_summary() {
    RESTORE_SUMMARY="$(cat <<EOF

Миграция завершена.

Перенесено:
- база Remnawave со старого сервера;
- важные настройки panel .env;
- настройки sub .env, если они были в архиве.

Сохранено от новой установки:
- домен панели: ${TARGET_PANEL_DOMAIN}
- домен страницы подписок: ${TARGET_SUB_DOMAIN}
- новые Docker volumes, сеть и TLS-сертификаты Caddy

Архив:
- ${ARCHIVE_PATH}
- создан: ${BACKUP_CREATED_AT:-unknown}

Если на старом сервере были другие домены:
- проверьте ссылки и интеграции в панели после первого входа;
- при необходимости обновите DNS на новый сервер.

EOF
)"

    printf '%s' "$RESTORE_SUMMARY"
}

run_backup_mode() {
    start_stage "Сбор данных старой установки" "Покажу, откуда брать базу и .env старой панели."
    prompt_backup_inputs
    if ! confirm "Создать архив миграции с указанными параметрами?" "Y"; then
        die "Создание архива отменено пользователем."
    fi

    start_stage "Экспорт базы Remnawave" "Сейчас сниму pg_dump из Postgres старой панели."
    create_backup_archive

    start_stage "Проверка результата" "Проверяю, что архив создан и доступен для копирования."
    [[ -f "$ARCHIVE_PATH" ]] || die "Архив не найден после упаковки: ${ARCHIVE_PATH}"
    success "Архив создан: ${ARCHIVE_PATH}"

    start_stage "Финиш" "Показываю, что делать дальше на новом сервере."
    show_backup_summary
}

run_restore_mode() {
    start_stage "Проверка новой установки и архива" "Убедимся, что свежая установка уже существует, а архив миграции доступен."
    prompt_restore_inputs
    if ! confirm "Заменить текущую свежую базу на данные из архива миграции?" "N"; then
        die "Восстановление отменено пользователем."
    fi

    start_stage "Распаковка архива и резервная копия .env" "Подготовлю содержимое архива и сохраню текущие .env новой установки."
    unpack_archive
    backup_target_envs

    start_stage "Подготовка новой установки" "Остановлю приложение и перенесу важные настройки из старых .env."
    stop_target_app_containers
    merge_panel_env_for_restore
    merge_sub_env_for_restore
    start_target_dependencies

    start_stage "Восстановление базы" "Заменяю свежую базу новой установки на данные старого сервера."
    restore_database

    start_stage "Перезапуск сервисов" "Подниму панель, sub и Caddy уже с перенесёнными данными."
    start_target_stack

    start_stage "Финиш" "Печатаю краткую сводку по завершённой миграции."
    show_restore_summary
}

main() {
    require_root
    require_dependencies
    init_ui
    choose_mode_if_needed
    set_total_stages
    print_intro

    case "$MODE" in
        backup)
            run_backup_mode
            ;;
        restore)
            run_restore_mode
            ;;
        *)
            die "Неизвестный режим: ${MODE}. Используйте backup или restore."
            ;;
    esac
}

main "$@"
