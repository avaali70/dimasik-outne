#!/bin/bash

set -euo pipefail  # Обрабатываем ошибки: завершение при ошибке, неопределённые переменные и ошибки в пайпах

# Функция для вывода справки по использованию
function display_usage() {
  cat <<EOF
Использование: install_server.sh [--hostname <hostname>] [--api-port <port>] [--keys-port <port>]

  --hostname   Хостнейм для доступа к API и ключам доступа
  --api-port   Порт для управления API
  --keys-port  Порт для ключей доступа
EOF
}

readonly SENTRY_LOG_FILE=${SENTRY_LOG_FILE:-}  # Путь к логам для отправки в Sentry, если включено

# Создаём временные файлы для логов
FULL_LOG="$(mktemp -t outline_logXXXXXXXXXX)"
LAST_ERROR="$(mktemp -t outline_last_errorXXXXXXXXXX)"
readonly FULL_LOG LAST_ERROR

# Логируем команду и сохраняем результат в логи
function log_command() {
  "$@" > >(tee -a "${FULL_LOG}") 2> >(tee -a "${FULL_LOG}" > "${LAST_ERROR}")
}

# Функция для вывода сообщений об ошибках в красном цвете
function log_error() {
  local -r ERROR_TEXT="\033[0;31m"  # Красный цвет
  local -r NO_COLOR="\033[0m"
  echo -e "${ERROR_TEXT}$1${NO_COLOR}"
  echo "$1" >> "${FULL_LOG}"
}

# Старт нового шага установки и его логирование
function log_start_step() {
  log_for_sentry "$@"
  local -r str="> $*"
  local -ir lineLength=47
  echo -n "${str}"
  local -ir numDots=$(( lineLength - ${#str} - 1 ))
  if (( numDots > 0 )); then
    echo -n " "
    for _ in $(seq 1 "${numDots}"); do echo -n .; done
  fi
  echo -n " "
}

# Выполнение шага и логирование результата
function run_step() {
  local -r msg="$1"
  log_start_step "${msg}"
  shift 1
  if log_command "$@"; then
    echo "OK"
  else
    return
  fi
}

# Подтверждение действия от пользователя
function confirm() {
  echo -n "> $1 [Y/n] "
  local RESPONSE
  read -r RESPONSE
  RESPONSE=$(echo "${RESPONSE}" | tr '[:upper:]' '[:lower:]') || return
  [[ -z "${RESPONSE}" || "${RESPONSE}" == "y" || "${RESPONSE}" == "yes" ]]
}

# Проверяем наличие команды в системе
function command_exists {
  command -v "$@" &> /dev/null
}

# Логируем шаг для Sentry и полного лога
function log_for_sentry() {
  if [[ -n "${SENTRY_LOG_FILE}" ]]; then
    echo "[$(date "+%Y-%m-%d@%H:%M:%S")] install_server.sh" "$@" >> "${SENTRY_LOG_FILE}"
  fi
  echo "$@" >> "${FULL_LOG}"
}

# Проверка, установлен ли Docker
function verify_docker_installed() {
  if command_exists docker; then
    return 0
  fi
  log_error "Docker не установлен"
  if ! confirm "Хотите установить Docker? Команда 'curl https://get.docker.com/ | sh' будет выполнена."; then
    exit 0
  fi
  if ! run_step "Установка Docker" install_docker; then
    log_error "Установка Docker не удалась. См. https://docs.docker.com/install."
    exit 1
  fi
  log_start_step "Проверка установки Docker"
  command_exists docker
}

# Проверка, запущен ли Docker
function verify_docker_running() {
  local STDERR_OUTPUT
  STDERR_OUTPUT="$(docker info 2>&1 >/dev/null)"
  local -ir RET=$?
  if (( RET == 0 )); then
    return 0
  elif [[ "${STDERR_OUTPUT}" == *"Is the docker daemon running"* ]]; then
    start_docker
    return
  fi
  return "${RET}"
}

# Функция для получения данных через curl
function fetch() {
  curl --silent --show-error --fail "$@"
}

# Установка Docker через скрипт
function install_docker() {
  (
    umask 0022  # Устанавливаем права на ключи
    fetch https://get.docker.com/ | sh
  ) >&2
}

# Запуск службы Docker
function start_docker() {
  systemctl enable --now docker.service >&2
}

# Проверка существования контейнера Docker
function docker_container_exists() {
  docker ps -a --format '{{.Names}}' | grep --quiet "^$1$"
}

# Удаление контейнера Shadowbox
function remove_shadowbox_container() {
  remove_docker_container "${CONTAINER_NAME}"
}

# Удаление контейнера Watchtower
function remove_watchtower_container() {
  remove_docker_container watchtower
}

# Удаление указанного контейнера Docker
function remove_docker_container() {
  docker rm -f "$1" >&2
}

# Обработка конфликта контейнеров
function handle_docker_container_conflict() {
  local -r CONTAINER_NAME="$1"
  local -r EXIT_ON_NEGATIVE_USER_RESPONSE="$2"
  local PROMPT="Контейнер \"${CONTAINER_NAME}\" уже используется. Хотите его заменить?"
  if ! confirm "${PROMPT}"; then
    if ${EXIT_ON_NEGATIVE_USER_RESPONSE}; then
      exit 0
    fi
    return 0
  fi
  if run_step "Удаление контейнера ${CONTAINER_NAME}" "remove_${CONTAINER_NAME}_container"; then
    log_start_step "Перезапуск ${CONTAINER_NAME}"
    "start_${CONTAINER_NAME}"
    return $?
  fi
  return 1
}

# Завершаем скрипт и очищаем временные файлы
function finish {
  local -ir EXIT_CODE=$?
  if (( EXIT_CODE != 0 )); then
    if [[ -s "${LAST_ERROR}" ]]; then
      log_error "\nПоследняя ошибка: $(< "${LAST_ERROR}")" >&2
    fi
    log_error "\nЧто-то пошло не так. Пожалуйста, отправьте этот лог в Outline Manager." >&2
    log_error "Полный лог: ${FULL_LOG}" >&2
  else
    rm "${FULL_LOG}"
  fi
  rm "${LAST_ERROR}"
}

# Генерация случайного порта
function get_random_port {
  local -i num=0
  until (( 1024 <= num && num < 65536 )); do
    num=$(( RANDOM + (RANDOM % 2) * 32768 ))
  done
  echo "${num}"
}

# Создаём директорию для хранения данных сервера
function create_persisted_state_dir() {
  readonly STATE_DIR="${SHADOWBOX_DIR}/persisted-state"
  mkdir -p "${STATE_DIR}"
  chmod ug+rwx,g+s,o-rwx "${STATE_DIR}"
}

# Генерация секретного ключа для API
function generate_secret_key() {
  SB_API_PREFIX="$(head -c 16 /dev/urandom | base64 | tr '/+' '_-' | tr -d '=')"
  readonly SB_API_PREFIX
}

# Генерация самоподписанного сертификата
function generate_certificate() {
  local -r CERTIFICATE_NAME="${STATE_DIR}/shadowbox-selfsigned"
  readonly SB_CERTIFICATE_FILE="${CERTIFICATE_NAME}.crt"
  readonly SB_PRIVATE_KEY_FILE="${CERTIFICATE_NAME}.key"
  openssl req -x509 -nodes -days 36500 -newkey rsa:4096 -subj "/CN=${PUBLIC_HOSTNAME}" \
    -keyout "${SB_PRIVATE_KEY_FILE}" -out "${SB_CERTIFICATE_FILE}" >&2
}

# Генерация отпечатка сертификата
function generate_certificate_fingerprint() {
  local CERT_HEX_FINGERPRINT
  CERT_HEX_FINGERPRINT="$(openssl x509 -in "${SB_CERTIFICATE_FILE}" -noout -sha256 -fingerprint | tr -d ':=SHA256 Fingerprint')" || return
  output_config "certSha256:${CERT_HEX_FINGERPRINT}"
}

# Функция для вывода настроек в файл
function output_config() {
  local -r CONFIG_FILE="$1"
  echo "$2" >> "${CONFIG_FILE}" >&2
}

# Основная функция для установки сервера
function main() {
  # Обработка аргументов командной строки
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --hostname) PUBLIC_HOSTNAME="$2"; shift ;;
      --api-port) API_PORT="$2"; shift ;;
      --keys-port) KEYS_PORT="$2"; shift ;;
      --help) display_usage; exit 0 ;;
      *) log_error "Неизвестный аргумент: $1"; display_usage; exit 1 ;;
    esac
    shift
  done

  # Проверка необходимых переменных
  if [[ -z "${PUBLIC_HOSTNAME:-}" ]]; then
    log_error "Необходимо указать --hostname."
    exit 1
  fi
  if [[ -z "${API_PORT:-}" ]]; then
    API_PORT=$(get_random_port)  # Генерируем случайный порт, если не указан
  fi
  if [[ -z "${KEYS_PORT:-}" ]]; then
    KEYS_PORT=$(get_random_port)  # Генерируем случайный порт, если не указан
  fi

  # Проверка установки Docker
  verify_docker_installed
  verify_docker_running

  # Создание директории для хранения данных сервера
  create_persisted_state_dir

  # Генерация секретного ключа
  generate_secret_key

  # Генерация самоподписанного сертификата
  generate_certificate

  # Генерация отпечатка сертификата
  generate_certificate_fingerprint

  # Вывод настроек в файл
  output_config "${STATE_DIR}/shadowbox-config.yml" "hostname: ${PUBLIC_HOSTNAME}"
  output_config "${STATE_DIR}/shadowbox-config.yml" "apiPort: ${API_PORT}"
  output_config "${STATE_DIR}/shadowbox-config.yml" "keysPort: ${KEYS_PORT}"

  # Запуск контейнера Shadowbox
  run_step "Запуск контейнера Shadowbox" \
    docker run -d --name shadowbox \
    -p "${API_PORT}":80 -p "${KEYS_PORT}":443 \
    -v "${STATE_DIR}:/var/lib/shadowbox" \
    --restart unless-stopped \
    outline/shadowbox
}

# Удаляем временные файлы при завершении
trap finish EXIT

# Запускаем основную функцию
main "$@"
