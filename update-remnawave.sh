#!/usr/bin/env bash
set -Eeuo pipefail

WORKDIR="/opt/remnawave-stack"
PANEL_DIR="$WORKDIR/panel"
SUB_DIR="$WORKDIR/subscription"
PROXY_DIR="$WORKDIR/proxy"
LOG_FILE="/var/log/remnawave-update.log"
BACKUP_ROOT="$WORKDIR/update-backups"

BACKEND_COMPOSE_URL="https://raw.githubusercontent.com/remnawave/backend/main/docker-compose-prod.yml"
BACKEND_ENV_URL="https://raw.githubusercontent.com/remnawave/backend/main/.env.sample"
SUB_COMPOSE_URL="https://raw.githubusercontent.com/remnawave/subscription-page/main/docker-compose-prod.yml"
SUB_ENV_URL="https://raw.githubusercontent.com/remnawave/subscription-page/main/.env.sample"

CURRENT_STAGE="0"
TOTAL_STAGES="6"
TMP_DIR=""
PANEL_ENV="$PANEL_DIR/.env"
PANEL_COMPOSE="$PANEL_DIR/docker-compose.yml"
SUB_ENV="$SUB_DIR/.env"
SUB_COMPOSE="$SUB_DIR/docker-compose.yml"
PROXY_COMPOSE="$PROXY_DIR/docker-compose.yml"
PROXY_CADDYFILE="$PROXY_DIR/Caddyfile"
HAS_SUB="false"
HAS_PROXY="false"
PG_CONTAINER="remnawave-db"
PG_USER=""
PG_DB=""
PANEL_DOMAIN=""
SUB_DOMAIN=""
BACKUP_ARCHIVE=""
ENV_WARNINGS_FOUND="false"
PRUNE_UNUSED_IMAGES="${RW_PRUNE_UNUSED_IMAGES:-false}"

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
    printf '%bОбновление Remnawave Panel%b\n' "${C_BOLD}${C_BLUE}" "${C_RESET}"
    print_rule
    printf 'Этот мастер обновит panel и страницу подписок без переустановки и без удаления базы.\n'
    printf 'Перед обновлением он автоматически создаст защитный backup базы и конфигов.\n'
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

cleanup_tmp_dir() {
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup_tmp_dir EXIT

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Запустите скрипт от root: sudo bash $0"
    fi
}

require_dependencies() {
    local missing=()
    local cmd=""

    for cmd in docker curl tar awk sed grep sort comm mktemp; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        die "Не найдены обязательные команды: ${missing[*]}"
    fi
}

reset_tmp_dir() {
    cleanup_tmp_dir
    TMP_DIR="$(mktemp -d /tmp/remnawave-update.XXXXXX)"
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

trim_quotes() {
    local value="$1"

    if [[ "$value" =~ ^\".*\"$ ]] || [[ "$value" =~ ^\'.*\'$ ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

normalize_host() {
    local value="$1"

    value="$(trim_quotes "$value")"
    value="${value#http://}"
    value="${value#https://}"
    value="${value%%/*}"

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

extract_env_keys() {
    local file_path="$1"

    awk -F= '
        $0 ~ /^[[:space:]]*#/ { next }
        $1 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ { print $1 }
    ' "$file_path" | sort -u
}

download_file() {
    local url="$1"
    local destination="$2"
    local tmp_download=""

    tmp_download="${destination}.tmp"
    curl -fsSL "$url" -o "$tmp_download"
    mv "$tmp_download" "$destination"
}

docker_compose_panel() {
    docker compose -f "$PANEL_COMPOSE" "$@"
}

docker_compose_sub() {
    docker compose -f "$SUB_COMPOSE" -p remnawave-subscription "$@"
}

docker_compose_proxy() {
    docker compose -f "$PROXY_COMPOSE" -p remnawave-proxy "$@"
}

ensure_installation_exists() {
    [[ -f "$PANEL_ENV" ]] || die "Не найден ${PANEL_ENV}. Сначала выполните установку deploy-remnawave.sh."
    [[ -f "$PANEL_COMPOSE" ]] || die "Не найден ${PANEL_COMPOSE}. Сначала выполните установку deploy-remnawave.sh."

    if [[ -f "$SUB_ENV" && -f "$SUB_COMPOSE" ]]; then
        HAS_SUB="true"
    fi

    if [[ -f "$PROXY_COMPOSE" ]]; then
        HAS_PROXY="true"
    fi

    PG_USER="$(get_env_value "$PANEL_ENV" "POSTGRES_USER")"
    PG_DB="$(get_env_value "$PANEL_ENV" "POSTGRES_DB")"
    PANEL_DOMAIN="$(normalize_host "$(get_env_value "$PANEL_ENV" "PANEL_DOMAIN")")"
    SUB_DOMAIN="$(normalize_host "$(get_env_value "$PANEL_ENV" "SUB_PUBLIC_DOMAIN")")"

    if [[ -z "$PANEL_DOMAIN" ]]; then
        PANEL_DOMAIN="$(normalize_host "$(get_env_value "$PANEL_ENV" "FRONT_END_DOMAIN")")"
    fi

    [[ -n "$PG_USER" ]] || die "Не удалось определить POSTGRES_USER из ${PANEL_ENV}"
    [[ -n "$PG_DB" ]] || die "Не удалось определить POSTGRES_DB из ${PANEL_ENV}"

    BACKUP_ARCHIVE="${BACKUP_ROOT}/remnawave-update-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
}

show_update_summary() {
    cat <<EOF

Что будет сделано:
- создан защитный backup базы и конфигов;
- скачаны свежие compose-файлы из официальных репозиториев Remnawave;
- выполнена проверка текущих .env по свежим sample-файлам;
- загружены новые образы и перезапущены контейнеры.

Что не будет удалено:
- база данных и volumes;
- домены панели и страницы подписок;
- настройки Caddy и сертификаты.

Параметры текущей установки:
- panel .env: ${PANEL_ENV}
- sub .env: $( [[ "$HAS_SUB" == "true" ]] && printf '%s' "$SUB_ENV" || printf 'не найден' )
- домен панели: ${PANEL_DOMAIN:-не найден}
- домен подписок: ${SUB_DOMAIN:-не найден}
- backup будет создан в: ${BACKUP_ARCHIVE}

Важно:
- если вы обновляетесь через крупные версии, проверьте release notes Remnawave;
- общий гайд обновления: https://docs.rw/docs/install/upgrading

EOF
}

ensure_container_running() {
    local container_name="$1"

    if docker ps --format '{{.Names}}' | grep -qx "$container_name"; then
        return 0
    fi

    if docker ps -a --format '{{.Names}}' | grep -qx "$container_name"; then
        run_logged "Запуск контейнера ${container_name}" docker start "$container_name"
        return 0
    fi

    die "Контейнер ${container_name} не найден."
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

http_code_for_url() {
    local url="$1"

    curl -k -L -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" || true
}

wait_for_http_code_match() {
    local url="$1"
    local regex="$2"
    local timeout_seconds="${3:-60}"
    local elapsed="0"
    local code=""

    while (( elapsed < timeout_seconds )); do
        code="$(http_code_for_url "$url")"
        if [[ "$code" =~ $regex ]]; then
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    return 1
}

write_backup_manifest() {
    local manifest_path="$1"

    cat >"$manifest_path" <<EOF
BACKUP_CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PANEL_ENV=${PANEL_ENV}
SUB_ENV=${SUB_ENV}
PANEL_COMPOSE=${PANEL_COMPOSE}
SUB_COMPOSE=${SUB_COMPOSE}
PROXY_COMPOSE=${PROXY_COMPOSE}
PANEL_DOMAIN=${PANEL_DOMAIN}
SUB_DOMAIN=${SUB_DOMAIN}
POSTGRES_CONTAINER=${PG_CONTAINER}
POSTGRES_USER=${PG_USER}
POSTGRES_DB=${PG_DB}
EOF
}

create_backup_bundle() {
    local backup_dir=""

    mkdir -p "$BACKUP_ROOT"
    reset_tmp_dir
    backup_dir="$TMP_DIR/backup"
    mkdir -p "$backup_dir"

    cp "$PANEL_ENV" "$backup_dir/panel.env"
    cp "$PANEL_COMPOSE" "$backup_dir/panel.docker-compose.yml"

    if [[ "$HAS_SUB" == "true" ]]; then
        cp "$SUB_ENV" "$backup_dir/sub.env"
        cp "$SUB_COMPOSE" "$backup_dir/sub.docker-compose.yml"
    fi

    if [[ "$HAS_PROXY" == "true" ]]; then
        cp "$PROXY_COMPOSE" "$backup_dir/proxy.docker-compose.yml"
        if [[ -f "$PROXY_CADDYFILE" ]]; then
            cp "$PROXY_CADDYFILE" "$backup_dir/Caddyfile"
        fi
    fi

    docker ps --format '{{.Names}} {{.Image}}' >"$backup_dir/images.txt" || true
    write_backup_manifest "$backup_dir/manifest.env"

    ensure_container_running "$PG_CONTAINER"

    log "Создаю pg_dump текущей базы Remnawave..."
    docker exec "$PG_CONTAINER" pg_dump \
        -U "$PG_USER" \
        -d "$PG_DB" \
        -Fc \
        --clean \
        --if-exists \
        --no-owner \
        --no-privileges >"$backup_dir/postgres.dump"
    success "Защитный дамп базы сохранён."

    run_logged "Упаковка backup-архива перед обновлением" tar -C "$backup_dir" -czf "$BACKUP_ARCHIVE" .
    chmod 600 "$BACKUP_ARCHIVE"
}

compare_env_file_with_sample() {
    local current_file="$1"
    local sample_url="$2"
    local component_label="$3"
    local sample_file=""
    local current_keys_file=""
    local sample_keys_file=""
    local missing_keys=""
    local extra_keys=""

    sample_file="$TMP_DIR/${component_label}.sample.env"
    current_keys_file="$TMP_DIR/${component_label}.current.keys"
    sample_keys_file="$TMP_DIR/${component_label}.sample.keys"

    download_file "$sample_url" "$sample_file"
    extract_env_keys "$current_file" >"$current_keys_file"
    extract_env_keys "$sample_file" >"$sample_keys_file"

    missing_keys="$(comm -23 "$sample_keys_file" "$current_keys_file" || true)"
    extra_keys="$(comm -13 "$sample_keys_file" "$current_keys_file" || true)"

    if [[ -n "$missing_keys" ]]; then
        ENV_WARNINGS_FOUND="true"
        warn "В ${component_label} .env отсутствуют переменные, которые есть в актуальном sample:"
        while IFS= read -r item; do
            [[ -n "$item" ]] && warn "  - ${item}"
        done <<<"$missing_keys"
    fi

    if [[ -n "$extra_keys" ]]; then
        ENV_WARNINGS_FOUND="true"
        warn "В ${component_label} .env есть переменные, которых нет в актуальном sample:"
        while IFS= read -r item; do
            [[ -n "$item" ]] && warn "  - ${item}"
        done <<<"$extra_keys"
    fi

    if [[ -z "$missing_keys" && -z "$extra_keys" ]]; then
        success "Проверка ${component_label} .env по актуальному sample пройдена."
    fi
}

check_env_compatibility() {
    reset_tmp_dir
    compare_env_file_with_sample "$PANEL_ENV" "$BACKEND_ENV_URL" "panel"

    if [[ "$HAS_SUB" == "true" ]]; then
        compare_env_file_with_sample "$SUB_ENV" "$SUB_ENV_URL" "subscription"
    fi

    if [[ "$ENV_WARNINGS_FOUND" == "true" ]]; then
        note "Это не всегда ошибка, но перед обновлением стоит сверить release notes Remnawave."
        if ! confirm "Продолжить обновление несмотря на предупреждения по .env?" "Y"; then
            die "Обновление остановлено пользователем для ручной проверки .env."
        fi
    fi
}

refresh_compose_files() {
    download_file "$BACKEND_COMPOSE_URL" "$PANEL_COMPOSE"
    success "Compose панели обновлён до актуальной версии."

    if [[ "$HAS_SUB" == "true" ]]; then
        download_file "$SUB_COMPOSE_URL" "$SUB_COMPOSE"
        success "Compose страницы подписок обновлён до актуальной версии."
    fi
}

pull_fresh_images() {
    run_logged "Загрузка новых образов панели" docker_compose_panel pull

    if [[ "$HAS_SUB" == "true" ]]; then
        run_logged "Загрузка новых образов страницы подписок" docker_compose_sub pull
    fi

    if [[ "$HAS_PROXY" == "true" ]]; then
        run_logged "Проверка образа Caddy" docker_compose_proxy pull
    fi
}

restart_stack() {
    run_logged "Перезапуск panel stack" docker_compose_panel up -d --remove-orphans

    if [[ "$HAS_SUB" == "true" ]]; then
        run_logged "Перезапуск subscription stack" docker_compose_sub up -d --remove-orphans
    fi

    if [[ "$HAS_PROXY" == "true" ]]; then
        run_logged "Перезапуск proxy stack" docker_compose_proxy up -d --remove-orphans
    fi

    if ! wait_for_container_health remnawave-db 120; then
        docker logs --tail 80 remnawave-db || true
        die "Контейнер remnawave-db не поднялся корректно после обновления."
    fi

    if docker ps -a --format '{{.Names}}' | grep -qx 'remnawave-redis'; then
        if ! wait_for_container_health remnawave-redis 120; then
            docker logs --tail 80 remnawave-redis || true
            die "Контейнер remnawave-redis не поднялся корректно после обновления."
        fi
    fi

    if ! wait_for_container_health remnawave 240; then
        docker logs --tail 100 remnawave || true
        die "Контейнер remnawave не поднялся корректно после обновления."
    fi

    if [[ "$HAS_SUB" == "true" ]] && docker ps -a --format '{{.Names}}' | grep -qx 'remnawave-subscription-page'; then
        if ! wait_for_container_health remnawave-subscription-page 120; then
            docker logs --tail 100 remnawave-subscription-page || true
            die "Контейнер remnawave-subscription-page не поднялся корректно после обновления."
        fi
    fi

    if [[ "$HAS_PROXY" == "true" ]] && docker ps -a --format '{{.Names}}' | grep -qx 'remnawave-caddy'; then
        if ! wait_for_container_health remnawave-caddy 120; then
            docker logs --tail 80 remnawave-caddy || true
            die "Контейнер remnawave-caddy не поднялся корректно после обновления."
        fi
    fi
}

verify_public_urls() {
    local panel_code=""
    local sub_code=""

    if [[ -n "$PANEL_DOMAIN" ]]; then
        if wait_for_http_code_match "https://${PANEL_DOMAIN}" '^(200|301|302|401|403)$' 120; then
            panel_code="$(http_code_for_url "https://${PANEL_DOMAIN}")"
            success "Панель отвечает по https://${PANEL_DOMAIN} (HTTP ${panel_code})."
        else
            warn "Публичная проверка панели по https://${PANEL_DOMAIN} не подтвердилась вовремя."
        fi
    fi

    if [[ "$HAS_SUB" == "true" && -n "$SUB_DOMAIN" ]]; then
        if wait_for_http_code_match "https://${SUB_DOMAIN}" '^[1-5][0-9][0-9]$' 120; then
            sub_code="$(http_code_for_url "https://${SUB_DOMAIN}")"
            if [[ "$sub_code" == "502" ]]; then
                warn "Корневой URL https://${SUB_DOMAIN} отвечает 502. Для персональных subscription-ссылок это может быть нормой."
            else
                success "Страница подписок отвечает по https://${SUB_DOMAIN} (HTTP ${sub_code})."
            fi
        else
            warn "Публичная проверка страницы подписок по https://${SUB_DOMAIN} не подтвердилась вовремя."
        fi
    fi
}

maybe_prune_unused_images() {
    if [[ "$PRUNE_UNUSED_IMAGES" != "true" ]]; then
        note "Очистка неиспользуемых Docker image пропущена. Для автоочистки можно запускать с RW_PRUNE_UNUSED_IMAGES=true."
        return 0
    fi

    run_logged "Очистка неиспользуемых Docker image" docker image prune -f
}

print_summary() {
    cat <<EOF

Обновление завершено.

Что сделано:
- создан backup перед обновлением;
- обновлены compose-файлы из официальных репозиториев;
- загружены свежие образы;
- контейнеры панели и страницы подписок перезапущены.

Точка отката:
- ${BACKUP_ARCHIVE}

Полезные команды:
- docker logs -f remnawave
- $( [[ "$HAS_SUB" == "true" ]] && printf '%s' 'docker logs -f remnawave-subscription-page' || printf '%s' 'subscription page не установлена, отдельный лог не нужен' )
- docker compose -f ${PANEL_COMPOSE} ps
- docker compose -f ${PANEL_COMPOSE} images
- лог обновления: ${LOG_FILE}

Важно:
- при крупных обновлениях проверьте release notes Remnawave;
- если после обновления нужен ручной шаг, смотрите: https://docs.rw/docs/install/upgrading

EOF
}

main() {
    require_root
    require_dependencies
    init_ui
    print_intro

    start_stage "Проверка текущей установки" "Проверяю, что Remnawave уже установлен и есть всё нужное для безопасного обновления."
    ensure_installation_exists
    show_update_summary
    if ! confirm "Начать обновление Remnawave?" "Y"; then
        die "Обновление отменено пользователем."
    fi

    start_stage "Создание защитного backup" "Сейчас сохраню базу и конфиги, чтобы перед обновлением была точка отката."
    create_backup_bundle

    start_stage "Проверка .env на совместимость" "Сравню ваши текущие .env с актуальными sample-файлами Remnawave."
    check_env_compatibility

    start_stage "Обновление compose-файлов" "Скачиваю актуальные compose-файлы panel и subscription-page."
    refresh_compose_files

    start_stage "Загрузка новых образов" "Подтягиваю свежие Docker image для всех компонентов."
    pull_fresh_images

    start_stage "Перезапуск и проверка" "Перезапускаю контейнеры и убеждаюсь, что панель снова поднялась штатно."
    restart_stack
    verify_public_urls
    maybe_prune_unused_images

    start_stage "Финиш" "Печатаю итог и путь к backup, который создан перед обновлением."
    print_summary
}

main "$@"
