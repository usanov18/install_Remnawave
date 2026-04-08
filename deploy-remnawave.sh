#!/usr/bin/env bash
set -Eeuo pipefail

WORKDIR="/opt/remnawave-stack"
PANEL_DIR="$WORKDIR/panel"
SUB_DIR="$WORKDIR/subscription"
PROXY_DIR="$WORKDIR/proxy"

BACKEND_COMPOSE_URL="https://raw.githubusercontent.com/remnawave/backend/main/docker-compose-prod.yml"
BACKEND_ENV_URL="https://raw.githubusercontent.com/remnawave/backend/main/.env.sample"
SUB_COMPOSE_URL="https://raw.githubusercontent.com/remnawave/subscription-page/main/docker-compose-prod.yml"
SUB_ENV_URL="https://raw.githubusercontent.com/remnawave/subscription-page/main/.env.sample"

DEFAULT_ADMIN_DOMAIN="admin.example.com"
DEFAULT_SUB_DOMAIN="sub.example.com"

ADMIN_DOMAIN=""
SUB_DOMAIN=""
LETSENCRYPT_EMAIL=""
SSH_PORT=""
PUBLIC_IP=""
API_TOKEN=""
CLEAN_INSTALL="false"
DNS_WARNING="false"
OS_ID=""
OS_VERSION_CODENAME=""
LOG_FILE="/var/log/remnawave-deploy.log"
CURRENT_STAGE="0"
TOTAL_STAGES="8"
ENABLE_TEMP_USER_CHECK="true"
AUTO_DELETE_TEMP_USER="true"
TEMP_VERIFY_USERNAME=""
TEMP_VERIFY_USER_UUID=""
TEMP_VERIFY_SUB_URL=""
TEMP_VERIFY_RESULT="skipped"
TEMP_VERIFY_USER_DELETED="false"
LAST_API_RESPONSE_CODE=""
LAST_API_RESPONSE_BODY=""
EXISTING_PANEL_ENV_BACKUP=""

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
    printf '%bУстановка Remnawave Panel + Страницы Подписок%b\n' "${C_BOLD}${C_BLUE}" "${C_RESET}"
    print_rule
    printf 'Этот мастер установит панель, HTTPS и страницу подписок.\n'
    printf 'Во время установки останется только один ручной шаг: создать superadmin и API токен.\n'
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

bool_to_yes_no() {
    local value="$1"

    if [[ "$value" == "true" ]]; then
        printf 'да'
    else
        printf 'нет'
    fi
}

on_error() {
    local line="$1"
    warn "Скрипт остановился на строке ${line}. Проверьте сообщение выше и лог ${LOG_FILE}."
}

trap 'on_error "$LINENO"' ERR

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Запустите скрипт от root: sudo bash $0"
    fi
}

require_supported_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Не удалось определить дистрибутив Linux."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        ubuntu|debian)
            ;;
        *)
            die "Поддерживаются только Ubuntu и Debian. Обнаружено: ${PRETTY_NAME:-unknown}"
            ;;
    esac

    OS_ID="$ID"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"

    if [[ -z "$OS_VERSION_CODENAME" ]]; then
        die "Не удалось определить системный codename."
    fi
}

prompt_value() {
    local var_name="$1"
    local label="$2"
    local default_value="${3:-}"
    local secret="${4:-false}"
    local value=""

    if [[ "$secret" == "true" ]]; then
        if [[ -n "$default_value" ]]; then
            read -r -s -p "$label [$default_value]: " value
        else
            read -r -s -p "$label: " value
        fi
        printf '\n'
    else
        if [[ -n "$default_value" ]]; then
            read -r -p "$label [$default_value]: " value
        else
            read -r -p "$label: " value
        fi
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
        Y|y|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

detect_public_ip() {
    local detected_ip=""

    detected_ip="$(curl -4fsSL --max-time 10 https://api.ipify.org || true)"
    if [[ -z "$detected_ip" ]]; then
        detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi

    printf '%s' "$detected_ip"
}

detect_ssh_port() {
    local detected_port=""

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        detected_port="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
    fi

    if [[ -z "$detected_port" && -f /etc/ssh/sshd_config ]]; then
        detected_port="$(awk '
            $1 == "Port" && $2 ~ /^[0-9]+$/ {
                port = $2
            }
            END {
                if (port != "") {
                    print port
                }
            }
        ' /etc/ssh/sshd_config)"
    fi

    printf '%s' "${detected_port:-22}"
}

install_base_packages() {
    export DEBIAN_FRONTEND=noninteractive

    run_logged "Обновление списка пакетов apt" apt-get update -y
    run_logged "Установка базовых пакетов" apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        jq \
        lsb-release \
        openssl \
        psmisc \
        ufw
}

install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        success "Docker и Compose уже установлены."
        systemctl enable --now docker >/dev/null 2>&1 || true
        return
    fi

    log "Устанавливаю Docker Engine и плагин Compose..."
    install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_VERSION_CODENAME} stable" \
        >/etc/apt/sources.list.d/docker.list

    run_logged "Обновление списка пакетов после добавления репозитория Docker" apt-get update -y
    run_logged "Установка пакетов Docker" apt-get install -y \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin

    run_logged "Включение службы Docker" systemctl enable --now docker
}

configure_firewall() {
    log "Настраиваю UFW..."

    ufw allow "${SSH_PORT}/tcp" >>"$LOG_FILE" 2>&1
    ufw allow 80/tcp >>"$LOG_FILE" 2>&1
    ufw allow 443/tcp >>"$LOG_FILE" 2>&1
    ufw --force enable >>"$LOG_FILE" 2>&1
    success "Правила firewall готовы."
}

port_is_busy() {
    local port="$1"
    ss -ltn "sport = :${port}" | tail -n +2 | grep -q .
}

print_port_info() {
    local port="$1"
    ss -ltnp "sport = :${port}" || true
}

stop_docker_publishers() {
    local port="$1"
    local container_ids=""

    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi

    container_ids="$(docker ps --format '{{.ID}} {{.Ports}}' | awk -v p=":${port}->" '$0 ~ p { print $1 }')"

    if [[ -n "$container_ids" ]]; then
        while read -r container_id; do
            [[ -z "$container_id" ]] && continue
            docker stop "$container_id" >/dev/null || true
        done <<<"$container_ids"
    fi
}

kill_port_processes() {
    local port="$1"
    local pids=""

    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${port}/tcp" >/dev/null 2>&1 || true
        sleep 2
        return 0
    fi

    pids="$(ss -ltnp "sport = :${port}" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)"
    if [[ -n "$pids" ]]; then
        while read -r pid; do
            [[ -z "$pid" ]] && continue
            kill -TERM "$pid" >/dev/null 2>&1 || true
        done <<<"$pids"
        sleep 2
    fi
}

free_port() {
    local port="$1"
    local label="$2"

    if ! port_is_busy "$port"; then
        return 0
    fi

    warn "Порт ${port} занят (${label})."
    print_port_info "$port"

    if ! confirm "Освободить порт ${port} автоматически?" "Y"; then
        die "Для продолжения порт ${port} должен быть свободен."
    fi

    stop_docker_publishers "$port"
    systemctl stop nginx >/dev/null 2>&1 || true
    systemctl stop apache2 >/dev/null 2>&1 || true
    systemctl stop httpd >/dev/null 2>&1 || true
    systemctl stop caddy >/dev/null 2>&1 || true
    kill_port_processes "$port"

    if port_is_busy "$port"; then
        warn "Порт ${port} всё ещё занят после автоматической очистки."
        print_port_info "$port"
        die "Освободите порт ${port} и запустите скрипт ещё раз."
    fi
}

check_dns_for_domain() {
    local domain="$1"
    local resolved_ips=""

    resolved_ips="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"

    if [[ -z "$resolved_ips" ]]; then
        warn "DNS для ${domain} пока не резолвится."
        DNS_WARNING="true"
        return 0
    fi

    if grep -qw "$PUBLIC_IP" <<<"$resolved_ips"; then
        success "DNS ${domain} -> ${resolved_ips}"
        return 0
    fi

    warn "DNS ${domain} сейчас указывает на: ${resolved_ips}. Ожидаемый IP сервера: ${PUBLIC_IP}."
    DNS_WARNING="true"
}

prepare_workdirs() {
    run_logged "Подготовка рабочих директорий" install -d -m 0755 "$PANEL_DIR" "$SUB_DIR" "$PROXY_DIR"
}

download_file() {
    local url="$1"
    local destination="$2"

    curl -fsSL "$url" -o "$destination"
}

set_env_value() {
    local file_path="$1"
    local key="$2"
    local value="$3"
    local escaped_value=""

    escaped_value="$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')"

    if grep -q "^${key}=" "$file_path"; then
        sed -i "s/^${key}=.*/${key}=${escaped_value}/" "$file_path"
    else
        printf '\n%s=%s\n' "$key" "$value" >>"$file_path"
    fi
}

trim_wrapped_quotes() {
    local value="$1"

    if [[ "$value" =~ ^\".*\"$ ]] || [[ "$value" =~ ^\'.*\'$ ]]; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

get_env_value() {
    local file_path="$1"
    local key="$2"
    local raw_value=""

    raw_value="$(awk -F= -v wanted_key="$key" '
        $0 ~ /^[[:space:]]*#/ { next }
        $1 == wanted_key {
            sub(/^[^=]*=/, "", $0)
            print $0
            exit
        }
    ' "$file_path" 2>/dev/null || true)"

    trim_wrapped_quotes "$raw_value"
}

random_string() {
    local length="$1"
    local bytes=$(( (length + 1) / 2 ))

    openssl rand -hex "$bytes" | cut -c "1-${length}"
}

backup_existing_panel_env_if_needed() {
    if [[ "$CLEAN_INSTALL" == "true" ]]; then
        EXISTING_PANEL_ENV_BACKUP=""
        return 0
    fi

    if [[ -f "$PANEL_DIR/.env" ]]; then
        EXISTING_PANEL_ENV_BACKUP="$(mktemp /tmp/remnawave-panel-env.XXXXXX)"
        cp "$PANEL_DIR/.env" "$EXISTING_PANEL_ENV_BACKUP"
        chmod 600 "$EXISTING_PANEL_ENV_BACKUP"
        note "Найдён существующий panel .env. Сохраню его секреты и пароль базы для безопасного повторного запуска."
    else
        EXISTING_PANEL_ENV_BACKUP=""
    fi
}

fetch_official_panel_files() {
    log "Скачиваю актуальные официальные файлы панели Remnawave..."
    download_file "$BACKEND_COMPOSE_URL" "$PANEL_DIR/docker-compose.yml"
    download_file "$BACKEND_ENV_URL" "$PANEL_DIR/.env"
    chmod 600 "$PANEL_DIR/.env"
    success "Файлы панели скачаны."
}

configure_panel_env() {
    local postgres_user="remnawave"
    local postgres_db="remnawave"
    local postgres_password=""
    local jwt_auth_secret=""
    local jwt_api_secret=""
    local metrics_user="metrics"
    local metrics_pass=""
    local database_url=""

    if [[ -n "$EXISTING_PANEL_ENV_BACKUP" && -f "$EXISTING_PANEL_ENV_BACKUP" ]]; then
        postgres_user="$(get_env_value "$EXISTING_PANEL_ENV_BACKUP" "POSTGRES_USER")"
        postgres_db="$(get_env_value "$EXISTING_PANEL_ENV_BACKUP" "POSTGRES_DB")"
        postgres_password="$(get_env_value "$EXISTING_PANEL_ENV_BACKUP" "POSTGRES_PASSWORD")"
        jwt_auth_secret="$(get_env_value "$EXISTING_PANEL_ENV_BACKUP" "JWT_AUTH_SECRET")"
        jwt_api_secret="$(get_env_value "$EXISTING_PANEL_ENV_BACKUP" "JWT_API_TOKENS_SECRET")"
        metrics_user="$(get_env_value "$EXISTING_PANEL_ENV_BACKUP" "METRICS_USER")"
        metrics_pass="$(get_env_value "$EXISTING_PANEL_ENV_BACKUP" "METRICS_PASS")"
    fi

    postgres_user="${postgres_user:-remnawave}"
    postgres_db="${postgres_db:-remnawave}"
    postgres_password="${postgres_password:-$(random_string 32)}"
    jwt_auth_secret="${jwt_auth_secret:-$(random_string 64)}"
    jwt_api_secret="${jwt_api_secret:-$(random_string 64)}"
    metrics_user="${metrics_user:-metrics}"
    metrics_pass="${metrics_pass:-$(random_string 24)}"
    database_url="postgresql://${postgres_user}:${postgres_password}@remnawave-db:5432/${postgres_db}"

    set_env_value "$PANEL_DIR/.env" "APP_PORT" "3000"
    set_env_value "$PANEL_DIR/.env" "METRICS_PORT" "3001"
    set_env_value "$PANEL_DIR/.env" "API_INSTANCES" "1"
    set_env_value "$PANEL_DIR/.env" "DATABASE_URL" "\"${database_url}\""
    set_env_value "$PANEL_DIR/.env" "POSTGRES_USER" "$postgres_user"
    set_env_value "$PANEL_DIR/.env" "POSTGRES_PASSWORD" "$postgres_password"
    set_env_value "$PANEL_DIR/.env" "POSTGRES_DB" "$postgres_db"
    set_env_value "$PANEL_DIR/.env" "JWT_AUTH_SECRET" "$jwt_auth_secret"
    set_env_value "$PANEL_DIR/.env" "JWT_API_TOKENS_SECRET" "$jwt_api_secret"
    set_env_value "$PANEL_DIR/.env" "PANEL_DOMAIN" "$ADMIN_DOMAIN"
    set_env_value "$PANEL_DIR/.env" "FRONT_END_DOMAIN" "https://${ADMIN_DOMAIN}"
    set_env_value "$PANEL_DIR/.env" "SUB_PUBLIC_DOMAIN" "$SUB_DOMAIN"
    set_env_value "$PANEL_DIR/.env" "METRICS_USER" "$metrics_user"
    set_env_value "$PANEL_DIR/.env" "METRICS_PASS" "$metrics_pass"
    set_env_value "$PANEL_DIR/.env" "IS_DOCS_ENABLED" "false"
    set_env_value "$PANEL_DIR/.env" "SWAGGER_PATH" "/docs"
    set_env_value "$PANEL_DIR/.env" "SCALAR_PATH" "/scalar"
    set_env_value "$PANEL_DIR/.env" "IS_TELEGRAM_NOTIFICATIONS_ENABLED" "false"
    set_env_value "$PANEL_DIR/.env" "WEBHOOK_ENABLED" "false"
}

fetch_official_sub_files() {
    log "Скачиваю актуальные официальные файлы страницы подписок..."
    download_file "$SUB_COMPOSE_URL" "$SUB_DIR/docker-compose.yml"
    download_file "$SUB_ENV_URL" "$SUB_DIR/.env"
    chmod 600 "$SUB_DIR/.env"
    success "Файлы страницы подписок скачаны."
}

configure_sub_env() {
    set_env_value "$SUB_DIR/.env" "APP_PORT" "3010"
    set_env_value "$SUB_DIR/.env" "REMNAWAVE_PANEL_URL" "http://remnawave:3000"
    set_env_value "$SUB_DIR/.env" "REMNAWAVE_API_TOKEN" "$API_TOKEN"
    set_env_value "$SUB_DIR/.env" "CUSTOM_SUB_PREFIX" ""
    set_env_value "$SUB_DIR/.env" "CADDY_AUTH_API_TOKEN" ""
    set_env_value "$SUB_DIR/.env" "CLOUDFLARE_ZERO_TRUST_CLIENT_ID" "\"\""
    set_env_value "$SUB_DIR/.env" "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET" "\"\""
    set_env_value "$SUB_DIR/.env" "MARZBAN_LEGACY_LINK_ENABLED" "false"
}

write_proxy_compose() {
    cat >"$PROXY_DIR/docker-compose.yml" <<'EOF'
services:
  caddy:
    image: caddy:2.10-alpine
    container_name: remnawave-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - remnawave-network

networks:
  remnawave-network:
    external: true
    name: remnawave-network

volumes:
  caddy_data:
  caddy_config:
EOF
}

write_caddyfile() {
    local mode="$1"

    if [[ -n "$LETSENCRYPT_EMAIL" ]]; then
        cat >"$PROXY_DIR/Caddyfile" <<EOF
{
    email ${LETSENCRYPT_EMAIL}
}

${ADMIN_DOMAIN} {
    encode zstd gzip
    reverse_proxy remnawave:3000
}
EOF
    else
        cat >"$PROXY_DIR/Caddyfile" <<EOF
${ADMIN_DOMAIN} {
    encode zstd gzip
    reverse_proxy remnawave:3000
}
EOF
    fi

    if [[ "$mode" == "full" ]]; then
        cat >>"$PROXY_DIR/Caddyfile" <<EOF

${SUB_DOMAIN} {
    encode zstd gzip
    reverse_proxy remnawave-subscription-page:3010
}
EOF
    fi
}

docker_compose_panel() {
    COMPOSE_ANSI=never COMPOSE_PROGRESS=plain docker compose -f "$PANEL_DIR/docker-compose.yml" "$@"
}

docker_compose_sub() {
    COMPOSE_ANSI=never COMPOSE_PROGRESS=plain docker compose -f "$SUB_DIR/docker-compose.yml" -p remnawave-subscription "$@"
}

docker_compose_proxy() {
    COMPOSE_ANSI=never COMPOSE_PROGRESS=plain docker compose -f "$PROXY_DIR/docker-compose.yml" -p remnawave-proxy "$@"
}

cleanup_existing_remnawave() {
    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi

    log "Останавливаю существующие контейнеры Remnawave, если они есть..."
    docker rm -f remnawave remnawave-db remnawave-redis remnawave-subscription-page remnawave-caddy >/dev/null 2>&1 || true
    success "Проверка старых контейнеров Remnawave завершена."

    if [[ "$CLEAN_INSTALL" == "true" ]]; then
        log "Удаляю старые тома Remnawave по запросу..."
        docker volume rm -f \
            remnawave-db-data \
            valkey-socket \
            remnawave-proxy_caddy_data \
            remnawave-proxy_caddy_config >/dev/null 2>&1 || true
        success "Запрошенные старые тома удалены."
    fi
}

wait_for_container_health() {
    local container_name="$1"
    local timeout_seconds="${2:-240}"
    local elapsed="0"
    local status=""
    local last_reported=""

    while (( elapsed < timeout_seconds )); do
        status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_name" 2>/dev/null || true)"
        case "$status" in
            healthy|running)
                if [[ "$last_reported" != "$status" ]]; then
                    success "Контейнер ${container_name} готов: ${status}."
                fi
                return 0
                ;;
        esac

        if [[ "$status" != "$last_reported" ]]; then
            log "Жду готовность контейнера ${container_name}: статус=${status:-unknown}, прошло ${elapsed}s из ${timeout_seconds}s."
            last_reported="$status"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    return 1
}

http_code_for_url() {
    local url="$1"

    curl -kLsS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true
}

wait_for_http_code_match() {
    local url="$1"
    local code_regex="$2"
    local timeout_seconds="${3:-120}"
    local elapsed="0"
    local status_code=""

    while (( elapsed < timeout_seconds )); do
        status_code="$(http_code_for_url "$url")"
        if [[ "$status_code" =~ $code_regex ]]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    return 1
}

api_request() {
    local method="$1"
    local url="$2"
    local body="${3:-}"
    local response_file=""

    response_file="$(mktemp)"

    if [[ -n "$body" ]]; then
        LAST_API_RESPONSE_CODE="$(
            curl -sS -o "$response_file" -w '%{http_code}' --max-time 20 \
                -X "$method" \
                -H "Authorization: Bearer ${API_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "$body" \
                "$url" \
                2>>"$LOG_FILE" || true
        )"
    else
        LAST_API_RESPONSE_CODE="$(
            curl -sS -o "$response_file" -w '%{http_code}' --max-time 20 \
                -X "$method" \
                -H "Authorization: Bearer ${API_TOKEN}" \
                "$url" \
                2>>"$LOG_FILE" || true
        )"
    fi

    LAST_API_RESPONSE_BODY="$(cat "$response_file" 2>/dev/null || true)"
    LAST_API_RESPONSE_CODE="${LAST_API_RESPONSE_CODE:-000}"

    rm -f "$response_file"
}

extract_api_error_message() {
    if [[ -z "$LAST_API_RESPONSE_BODY" ]]; then
        return 0
    fi

    jq -r '.message // .error // empty' <<<"$LAST_API_RESPONSE_BODY" 2>/dev/null || true
}

create_temporary_verification_user() {
    local expire_at=""
    local payload=""

    TEMP_VERIFY_USERNAME="rwcheck$(date +%H%M%S)"
    expire_at="$(date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')"
    payload="$(jq -nc --arg username "$TEMP_VERIFY_USERNAME" --arg expireAt "$expire_at" '{username: $username, expireAt: $expireAt}')"

    log "Создаю временного пользователя для проверки..."
    api_request POST "https://${ADMIN_DOMAIN}/api/users" "$payload"

    if [[ ! "$LAST_API_RESPONSE_CODE" =~ ^(200|201)$ ]]; then
        warn "Не удалось создать временного пользователя для проверки (HTTP ${LAST_API_RESPONSE_CODE})."
        local api_error=""
        api_error="$(extract_api_error_message)"
        if [[ -n "$api_error" ]]; then
            warn "Ответ API: ${api_error}"
        fi
        TEMP_VERIFY_RESULT="warning"
        return 1
    fi

    TEMP_VERIFY_USER_UUID="$(jq -r '.response.uuid // empty' <<<"$LAST_API_RESPONSE_BODY")"
    TEMP_VERIFY_SUB_URL="$(jq -r '.response.subscriptionUrl // empty' <<<"$LAST_API_RESPONSE_BODY")"

    if [[ -z "$TEMP_VERIFY_USER_UUID" || -z "$TEMP_VERIFY_SUB_URL" ]]; then
        warn "В ответе API нет UUID временного пользователя или ссылки подписки."
        TEMP_VERIFY_RESULT="warning"
        return 1
    fi

    success "Временный пользователь для проверки создан: ${TEMP_VERIFY_USERNAME}"
    note "Временная ссылка подписки: ${TEMP_VERIFY_SUB_URL}"
    return 0
}

delete_temporary_verification_user() {
    if [[ -z "$TEMP_VERIFY_USER_UUID" ]]; then
        return 0
    fi

    api_request DELETE "https://${ADMIN_DOMAIN}/api/users/${TEMP_VERIFY_USER_UUID}"

    if [[ "$LAST_API_RESPONSE_CODE" =~ ^(200|204)$ ]]; then
        TEMP_VERIFY_USER_DELETED="true"
        success "Временный пользователь для проверки удалён."
    else
        warn "Не удалось автоматически удалить временного пользователя для проверки (HTTP ${LAST_API_RESPONSE_CODE})."
        TEMP_VERIFY_USER_DELETED="false"
    fi
}

verify_temporary_subscription_link() {
    local public_code=""
    local fallback_code=""
    local short_uuid=""
    local fallback_url=""

    if [[ "$ENABLE_TEMP_USER_CHECK" != "true" ]]; then
        TEMP_VERIFY_RESULT="skipped"
        return 0
    fi

    if ! create_temporary_verification_user; then
        return 0
    fi

    log "Проверяю реальную ссылку подписки..."
    if wait_for_http_code_match "$TEMP_VERIFY_SUB_URL" '^(200|301|302)$' 30; then
        public_code="$(http_code_for_url "$TEMP_VERIFY_SUB_URL")"
        success "Временная ссылка подписки доступна (HTTP ${public_code})."
        TEMP_VERIFY_RESULT="success"
    else
        short_uuid="${TEMP_VERIFY_SUB_URL##*/}"
        fallback_url="https://${ADMIN_DOMAIN}/api/sub/${short_uuid}"

        if wait_for_http_code_match "$fallback_url" '^(200|301|302)$' 30; then
            fallback_code="$(http_code_for_url "$fallback_url")"
            warn "Публичная ссылка подписки не подтвердилась вовремя, но резервный endpoint backend доступен (HTTP ${fallback_code})."
            note "Ссылку всё ещё можно проверить вручную: ${TEMP_VERIFY_SUB_URL}"
            TEMP_VERIFY_RESULT="warning"
        else
            public_code="$(http_code_for_url "$TEMP_VERIFY_SUB_URL")"
            warn "Не удалось автоматически проверить временную ссылку подписки (HTTP ${public_code:-unknown})."
            note "Проверьте её вручную после установки: ${TEMP_VERIFY_SUB_URL}"
            TEMP_VERIFY_RESULT="warning"
        fi
    fi

    if [[ "$TEMP_VERIFY_RESULT" == "success" && "$AUTO_DELETE_TEMP_USER" == "true" ]]; then
        delete_temporary_verification_user
    elif [[ "$TEMP_VERIFY_RESULT" != "success" ]]; then
        TEMP_VERIFY_USER_DELETED="false"
        note "Временный пользователь сохранён, чтобы вы могли проверить ссылку вручную."
    fi
}

prompt_install_mode() {
    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi

    if docker volume inspect remnawave-db-data >/dev/null 2>&1; then
        warn "Найдены существующие данные Remnawave."
        if confirm "Выполнить чистую переустановку и удалить старую базу и сертификаты Caddy?" "N"; then
            CLEAN_INSTALL="true"
        fi
    fi
}

show_configuration_summary() {
    cat <<EOF

Проверка конфигурации:
- Домен админ-панели: ${ADMIN_DOMAIN}
- Домен страницы подписок: ${SUB_DOMAIN}
- Email для Let's Encrypt: ${LETSENCRYPT_EMAIL:-автоматический режим по умолчанию}
- SSH порт, который останется открыт: ${SSH_PORT}
- IP сервера для проверки DNS: ${PUBLIC_IP:-не определён}
- Чистая переустановка: $(bool_to_yes_no "$CLEAN_INSTALL")
- Временный пользователь для проверки: $(bool_to_yes_no "$ENABLE_TEMP_USER_CHECK")
- Автоудаление временного пользователя: $(bool_to_yes_no "$AUTO_DELETE_TEMP_USER")

EOF
}

prompt_main_inputs() {
    PUBLIC_IP="$(detect_public_ip)"
    SSH_PORT="$(detect_ssh_port)"

    log "Этот скрипт устанавливает только панель и страницу подписок."
    log "Remnawave node он не устанавливает."
    log "Рабочая директория установки: ${WORKDIR}"
    if [[ -n "$PUBLIC_IP" ]]; then
        note "Определён публичный IP сервера: ${PUBLIC_IP}"
    fi

    prompt_value ADMIN_DOMAIN "Домен админ-панели" "$DEFAULT_ADMIN_DOMAIN"
    prompt_value SUB_DOMAIN "Домен страницы подписок" "$DEFAULT_SUB_DOMAIN"
    prompt_value LETSENCRYPT_EMAIL "Email для Let's Encrypt (можно оставить пустым)" "${RW_LETSENCRYPT_EMAIL:-}"
    SSH_PORT="${RW_SSH_PORT:-$SSH_PORT}"
    ENABLE_TEMP_USER_CHECK="${RW_ENABLE_TEMP_USER_CHECK:-true}"
    AUTO_DELETE_TEMP_USER="${RW_AUTO_DELETE_TEMP_USER:-true}"
}

show_dns_warning_if_needed() {
    if [[ "$DNS_WARNING" == "false" ]]; then
        return 0
    fi

    warn "Для выпуска TLS-сертификатов A-записи должны указывать на ${PUBLIC_IP:-IP этого сервера}."
    if ! confirm "Продолжить всё равно? Caddy выпустит сертификаты, когда DNS станет правильным." "Y"; then
        die "Исправьте DNS-записи и запустите скрипт ещё раз."
    fi
}

deploy_panel_stack() {
    run_logged "Запуск базового стека панели" docker_compose_panel up -d

    if ! wait_for_container_health remnawave-db 120; then
        die "Контейнер remnawave-db не перешёл в состояние healthy."
    fi

    if ! wait_for_container_health remnawave-redis 120; then
        die "Контейнер remnawave-redis не перешёл в состояние healthy."
    fi

    if ! wait_for_container_health remnawave 240; then
        docker logs --tail 100 remnawave || true
        die "Контейнер remnawave не перешёл в состояние healthy."
    fi

    success "Контейнеры панели Remnawave работают штатно."
}

deploy_proxy_panel_only() {
    write_proxy_compose
    write_caddyfile "panel-only"

    run_logged "Запуск обратного прокси с TLS" docker_compose_proxy up -d

    if wait_for_http_code_match "https://${ADMIN_DOMAIN}" '^(200|301|302|401|403)$' 120; then
        success "Админ-панель отвечает по адресу https://${ADMIN_DOMAIN}"
    else
        warn "https://${ADMIN_DOMAIN} пока не отвечает. Обычно это связано с распространением DNS или ожиданием сертификата."
    fi
}

pause_for_superadmin_and_api_token() {
    cat <<EOF

Ручной шаг в панели:
1. Откройте https://${ADMIN_DOMAIN}
2. Создайте superadmin
3. Откройте Remnawave Settings -> API Tokens
4. Создайте API токен для страницы подписок
5. Вернитесь сюда и вставьте токен

Во время вставки ввод токена скрыт. Это нормально.

EOF

    while true; do
        prompt_value API_TOKEN "Вставьте API токен Remnawave" "" "true"
        if [[ -n "$API_TOKEN" ]]; then
            success "API токен получен."
            break
        fi
        warn "API токен не может быть пустым."
    done
}

deploy_subscription_stack() {
    fetch_official_sub_files
    configure_sub_env

    run_logged "Запуск страницы подписок" docker_compose_sub up -d

    if ! wait_for_container_health remnawave-subscription-page 120; then
        if ! docker ps --format '{{.Names}}' | grep -qx 'remnawave-subscription-page'; then
            docker_compose_sub ps || true
        fi
        docker logs --tail 100 remnawave-subscription-page || true
        die "Контейнер remnawave-subscription-page не запустился корректно."
    fi

    write_caddyfile "full"
    if ! docker exec remnawave-caddy caddy reload --config /etc/caddy/Caddyfile >>"$LOG_FILE" 2>&1; then
        run_logged "Перезапуск обратного прокси после обновления Caddyfile" docker_compose_proxy up -d
    else
        success "Конфигурация Caddy перезагружена."
    fi

    if wait_for_http_code_match "https://${SUB_DOMAIN}" '^[1-5][0-9][0-9]$' 120; then
        local sub_status_code=""
        sub_status_code="$(http_code_for_url "https://${SUB_DOMAIN}")"

        if [[ "$sub_status_code" == "502" ]]; then
            warn "https://${SUB_DOMAIN} доступен по HTTPS, но корневой URL сейчас возвращает HTTP 502."
            warn "Это может быть нормой, если страница подписок используется только через персональные ссылки пользователей."
        else
            success "Страница подписок доступна по адресу https://${SUB_DOMAIN} (HTTP ${sub_status_code})."
        fi
    else
        warn "https://${SUB_DOMAIN} пока не отвечает. Проверьте DNS и дайте Caddy время выпустить сертификат."
    fi

    verify_temporary_subscription_link
}

print_summary() {
    cat <<EOF

Установка завершена.

Домены:
- Админ-панель: https://${ADMIN_DOMAIN}
- Страница подписок: https://${SUB_DOMAIN}

Локальные директории:
- ${PANEL_DIR}
- ${SUB_DIR}
- ${PROXY_DIR}

Контейнеры:
- remnawave
- remnawave-db
- remnawave-redis
- remnawave-subscription-page
- remnawave-caddy

Полезные команды:
- docker logs -f remnawave
- docker logs -f remnawave-subscription-page
- docker compose -f ${PANEL_DIR}/docker-compose.yml pull
- docker compose -f ${PANEL_DIR}/docker-compose.yml up -d
- Лог установки: ${LOG_FILE}

Важно:
- Корневой URL https://${SUB_DOMAIN} может возвращать HTTP 502, если вы используете только персональные ссылки подписки.

EOF

    if [[ "$ENABLE_TEMP_USER_CHECK" == "true" && -n "$TEMP_VERIFY_SUB_URL" ]]; then
        cat <<EOF
Проверка:
- Временный пользователь: ${TEMP_VERIFY_USERNAME}
- Временная ссылка подписки: ${TEMP_VERIFY_SUB_URL}
- Результат проверки: ${TEMP_VERIFY_RESULT}
- Временный пользователь удалён автоматически: $(bool_to_yes_no "$TEMP_VERIFY_USER_DELETED")

EOF
    fi
}

main() {
    require_root
    init_ui
    require_supported_os

    print_intro
    start_stage "Сбор конфигурации" "Сейчас соберём домены и проверим базовые параметры установки."
    prompt_main_inputs
    prompt_install_mode
    show_configuration_summary

    if [[ -n "$PUBLIC_IP" ]]; then
        check_dns_for_domain "$ADMIN_DOMAIN"
        check_dns_for_domain "$SUB_DOMAIN"
        show_dns_warning_if_needed
    fi

    start_stage "Подготовка пакетов" "Устанавливаю базовые зависимости и Docker."
    install_base_packages
    install_docker

    start_stage "Подготовка портов и firewall" "Открою нужные порты и освобожу конфликтующие слушатели, если это потребуется."
    cleanup_existing_remnawave
    free_port 80 "HTTP для выпуска сертификата"
    free_port 443 "HTTPS для панели и страницы подписок"
    free_port 3000 "локальный порт панели"
    free_port 3001 "локальный порт метрик панели"
    free_port 3010 "локальный порт страницы подписок"
    free_port 6767 "локальный порт контейнера Postgres"

    configure_firewall
    prepare_workdirs

    start_stage "Развёртывание панели" "Скачиваю официальные файлы панели и запускаю Remnawave."
    backup_existing_panel_env_if_needed
    fetch_official_panel_files
    configure_panel_env
    deploy_panel_stack

    start_stage "Включение HTTPS" "Запускаю Caddy и запрашиваю сертификаты для домена админ-панели."
    deploy_proxy_panel_only

    start_stage "Ручной шаг в панели" "Создайте superadmin в панели, затем сгенерируйте API токен."
    pause_for_superadmin_and_api_token

    start_stage "Развёртывание страницы подписок" "Запускаю страницу подписок и подключаю публичный домен."
    deploy_subscription_stack

    start_stage "Финиш" "Печатаю итоговую сводку и полезные дальнейшие команды."
    print_summary
}

main "$@"
