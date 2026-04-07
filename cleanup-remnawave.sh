#!/usr/bin/env bash
set -Eeuo pipefail

WORKDIR="/opt/remnawave-stack"
LOG_FILE="/var/log/remnawave-cleanup.log"
CURRENT_STAGE="0"
TOTAL_STAGES="4"

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
    printf '%bОчистка Установки Remnawave%b\n' "${C_BOLD}${C_BLUE}" "${C_RESET}"
    print_rule
    printf 'Этот скрипт удаляет panel, страницу подписок, Caddy, volumes, сеть и директорию установки.\n'
    printf 'Он не удаляет remnanode, Docker, UFW и другие посторонние сервисы.\n'
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

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Запустите скрипт от root: sudo bash $0"
    fi
}

confirm() {
    local label="$1"
    local default_answer="${2:-N}"
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

show_cleanup_scope() {
    cat <<EOF

Будет удалено:
- контейнеры: remnawave, remnawave-db, remnawave-redis, remnawave-subscription-page, remnawave-caddy
- volumes: remnawave-db-data, remnawave-proxy_caddy_data, remnawave-proxy_caddy_config, valkey-socket
- сеть: remnawave-network
- директория: ${WORKDIR}
- лог установки: /var/log/remnawave-deploy.log
- лог очистки: ${LOG_FILE}

Не будет удалено:
- remnanode
- Docker и Docker Compose
- UFW и системные пакеты
- любые посторонние каталоги и сервисы

EOF
}

verify_target_path() {
    if [[ ! -e "$WORKDIR" ]]; then
        return 0
    fi

    local resolved=""
    resolved="$(readlink -f "$WORKDIR")"

    if [[ "$resolved" != "$WORKDIR" ]]; then
        die "Небезопасная цель для удаления: ${resolved}"
    fi
}

remove_containers() {
    docker rm -f \
        remnawave \
        remnawave-db \
        remnawave-redis \
        remnawave-subscription-page \
        remnawave-caddy >/dev/null 2>&1 || true
}

remove_volumes() {
    docker volume rm -f \
        remnawave-db-data \
        remnawave-proxy_caddy_data \
        remnawave-proxy_caddy_config \
        valkey-socket >/dev/null 2>&1 || true
}

remove_network() {
    docker network rm remnawave-network >/dev/null 2>&1 || true
}

remove_files() {
    rm -rf "$WORKDIR"
    rm -f /var/log/remnawave-deploy.log
    rm -f "$LOG_FILE"
}

print_summary() {
    cat <<EOF

Очистка завершена.

Удалено:
- panel / sub / caddy контейнеры
- volumes и сеть этой установки
- директория ${WORKDIR}
- лог установки /var/log/remnawave-deploy.log

Сохранено:
- remnanode
- Docker
- UFW
- остальные каталоги и сервисы сервера

Теперь сервер готов к новому прогону install-скрипта.

EOF
}

main() {
    require_root
    init_ui

    print_intro
    show_cleanup_scope

    if ! confirm "Продолжить очистку этой установки Remnawave?" "N"; then
        die "Очистка отменена пользователем."
    fi

    start_stage "Проверка путей" "Проверяю, что удаляться будет только ожидаемая директория установки."
    verify_target_path
    success "Пути для удаления проверены."

    start_stage "Удаление контейнеров" "Останавливаю и удаляю только контейнеры panel / sub / caddy."
    run_logged "Удаление контейнеров установки" remove_containers

    start_stage "Удаление volumes и сети" "Удаляю тома и сеть, созданные этой установкой."
    run_logged "Удаление volumes установки" remove_volumes
    run_logged "Удаление сети установки" remove_network

    start_stage "Удаление файлов установки" "Удаляю директорию раскатки и логи установки."
    run_logged "Удаление файлов установки" remove_files

    print_summary
}

main "$@"
