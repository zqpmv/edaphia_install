#!/usr/bin/env bash
# Установка edaphia одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/zqpmv/edaphia_install/main/install-edaphia.sh | sudo bash
#
# Скрипт открытый, код — из закрытого репозитория по токену только на чтение.
# Повторный запуск — обновление: данные и ключи остаются. Справка: --help.
#
# На экране — только ход установки; вывод apt, git и прочих программ уходит
# в журнал /var/log/edaphia-install.log и показывается при ошибке.
set -Eeuo pipefail

REPO="${EDAPHIA_REPO:-https://github.com/zqpmv/edaphia.git}"
BRANCH="${EDAPHIA_BRANCH:-master}"
DIR="${EDAPHIA_DIR:-/opt/edaphia}"
APP_USER=edaphia
APP_HOME=/var/lib/edaphia
CONF_DIR=/etc/edaphia
STAND_FILE="$CONF_DIR/stand.sh"
INSTALL_LOG=/var/log/edaphia-install.log
NODE_MAJOR=22
PNPM_VERSION=10.15.1
TTY=/dev/tty

PLAN=(
  "Проверка сервера"
  "Системные пакеты"
  "Docker"
  "Node.js $NODE_MAJOR и pnpm"
  "Код edaphia"
  "Адрес веб-интерфейса"
  "Ключ для обновлений"
  "Сборка и запуск"
  "Защита сервера"
)
STEP_NO=0
STEP_TITLE="подготовка"
RUN_PID=""
ATTENTION=()
DEPLOY_KEY=""
STARTED=$SECONDS

# ── оформление ──────────────────────────────────────────────────────────────
# Имена строчные: /etc/os-release и файл стенда задают прописные переменные.
c_off="" c_bold="" c_dim="" c_leaf="" c_soil="" c_deep="" c_good="" c_warn="" c_bad="" c_ask=""
IS_TERM=0
if [ -t 1 ]; then IS_TERM=1; fi
if [ "$IS_TERM" = 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_off=$'\033[0m' c_bold=$'\033[1m' c_dim=$'\033[2m'
  c_good=$'\033[32m' c_warn=$'\033[33m' c_bad=$'\033[31m'
  case "${TERM:-}" in
    linux|vt*|dumb|"") c_leaf=$'\033[32m' c_soil=$'\033[33m' c_deep=$'\033[90m' c_ask=$'\033[36m' ;;
    *) c_leaf=$'\033[38;5;113m' c_soil=$'\033[38;5;137m' c_deep=$'\033[38;5;95m' c_ask=$'\033[38;5;113m' ;;
  esac
fi

draw_sprout() {
  printf '%s' "$c_leaf"
  cat <<'ART'
              ▗▄▄▄▖
       ▗▄▄▖  ▟████▘
       ▝███▙▟█▀▀
         ▀▀██▘
           █
ART
  printf '%s' "$c_soil"
  cat <<'ART'
    ▄▄▄▄▄▄▄█▄▄▄▄▄▄▄▄▄▄
    ▓▒▓▓▒▓▓█▓▒▓▓▒▓▓▓▒▓
ART
  printf '%s' "$c_deep"
  cat <<'ART'
    ▒░▒▒░▒▒▜▖▒░▒▒░▒▒░▒
    ░ ░░ ░ ░▝▚ ░░ ░ ░░
ART
  printf '%s' "$c_off"
}

ok() { printf '    %s✓%s %s\n' "$c_good" "$c_off" "$*"; }
info() { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
warn() { printf '    %s▲%s %s\n' "$c_warn" "$c_off" "$*"; }
attention() { warn "$1"; ATTENTION+=("$1"); } # попадёт и на итоговый экран
heading() { printf '\n  %s%s%s\n' "$c_bold" "$*" "$c_off"; }
die() {
  printf '\n  %s✗ %s%s\n' "$c_bad" "$*" "$c_off" >&2
  exit 1
}

step() {
  local total=${#PLAN[@]} filled i bar=""
  STEP_TITLE=${PLAN[STEP_NO]}
  STEP_NO=$((STEP_NO + 1))
  filled=$((STEP_NO * 18 / total))
  for ((i = 0; i < filled; i++)); do bar+="━"; done
  bar+="$c_deep"
  for ((i = filled; i < 18; i++)); do bar+="─"; done
  printf '\n  %s%s%s %s%d/%d%s  %s%s%s\n' "$c_leaf" "$bar" "$c_off" "$c_dim" "$STEP_NO" "$total" "$c_off" "$c_bold" "$STEP_TITLE" "$c_off"
}

fmt_time() { # секунды → «3 мин 12 с»
  if [ "$1" -ge 60 ]; then printf '%d мин %d с' $(($1 / 60)) $(($1 % 60)); else printf '%d с' "$1"; fi
}

run() { # $1 что делается, дальше команда: вывод в журнал, на экране спиннер
  local label=$1 started=$SECONDS frame=0 code=0
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  shift
  printf '\n=== %s %s\n' "$(date '+%F %T')" "$label" >>"$INSTALL_LOG"
  "$@" >>"$INSTALL_LOG" 2>&1 </dev/null &
  RUN_PID=$!
  if [ "$IS_TERM" = 1 ]; then
    while kill -0 "$RUN_PID" 2>/dev/null; do
      printf '\r\033[K    %s%s%s %s %s%s%s' "$c_leaf" "${frames[frame % 10]}" "$c_off" "$label" "$c_dim" "$(fmt_time $((SECONDS - started)))" "$c_off"
      frame=$((frame + 1))
      sleep 0.1
    done
    printf '\r\033[K'
  else
    printf '    … %s\n' "$label"
  fi
  wait "$RUN_PID" || code=$?
  RUN_PID=""
  if [ "$code" != 0 ]; then
    printf '    %s✗%s %s — ошибка (код %d). Последние строки журнала:\n\n' "$c_bad" "$c_off" "$label" "$code" >&2
    tail -n 15 "$INSTALL_LOG" | sed 's/^/      /' >&2
    die "Не получилось: $label. Журнал: $INSTALL_LOG. Повторный запуск продолжит установку."
  fi
}

on_interrupt() {
  if [ -n "$RUN_PID" ]; then kill "$RUN_PID" 2>/dev/null || true; fi
  printf '\r\033[K\n  Установка прервана. Запустите команду ещё раз — она продолжит с того же места.\n' >&2
  exit 130
}
trap on_interrupt INT
trap 'printf "\n  %s✗ Шаг «%s» не прошёл (строка %s). Запустите команду ещё раз — она продолжит с того же места.%s\n" "$c_bad" "$STEP_TITLE" "$LINENO" "$c_off" >&2' ERR

# ── вопросы ─────────────────────────────────────────────────────────────────
# Читаем с терминала: stdin занят трубой curl.
HAVE_TTY=0
if (exec <"$TTY") 2>/dev/null; then HAVE_TTY=1; fi

ask() { # $1 вопрос, $2 ответ по умолчанию → REPLY
  local answer=""
  if [ "$HAVE_TTY" = 1 ]; then read -r -p "    ${c_ask}?${c_off} $1${2:+ ${c_dim}[$2]${c_off}}: " answer <"$TTY" || true; fi
  REPLY="${answer:-${2:-}}"
}

ask_secret() { # $1 вопрос → REPLY
  [ "$HAVE_TTY" = 1 ] || die "Нет терминала для скрытого ввода: задайте EDAPHIA_GIT_TOKEN в окружении."
  IFS= read -r -s -p "    ${c_ask}?${c_off} $1: " REPLY <"$TTY" || true
  echo
}

ask_yes() { # $1 вопрос, $2 по умолчанию (да|нет) → код возврата
  while :; do
    ask "$1 (да/нет)" "$2"
    case "$REPLY" in
      да|Да|ДА|д|Д|yes|Yes|YES|y|Y) return 0 ;;
      нет|Нет|НЕТ|н|Н|no|No|NO|n|N) return 1 ;;
      *) warn "Ответьте «да» или «нет»." ;;
    esac
  done
}

port_busy() { [ -n "$(ss -ltnH "sport = :$1" 2>/dev/null || true)" ]; }

ask_port() { # $1 название, $2 по умолчанию, $3 занятый предыдущим вопросом → REPLY
  while :; do
    ask "$1" "$2"
    if ! [[ "$REPLY" =~ ^[0-9]+$ ]] || [ "${#REPLY}" -gt 5 ] || [ "$REPLY" -lt 1 ] || [ "$REPLY" -gt 65535 ]; then
      warn "Порт — число от 1 до 65535."
    elif [ "$REPLY" = "${3:-}" ]; then
      warn "Этот порт уже выбран для другой службы."
    elif [ "$HAVE_TTY" = 1 ] && port_busy "$REPLY"; then
      local port=$REPLY
      warn "Порт $port уже занят на этой машине."
      if ask_yes "оставить его всё равно" "нет"; then REPLY=$port; return 0; fi
    else
      return 0
    fi
  done
}

choose_address() { # $1 адрес по умолчанию → REPLY
  local addrs=() notes=() ifname cidr i default=1
  while read -r ifname cidr; do
    case "$ifname" in docker*|br-*|veth*) continue ;; esac
    addrs+=("${cidr%/*}")
    case "$ifname" in
      tailscale*|netbird*|wt*) notes+=("$ifname, частная сеть") ;;
      *) notes+=("$ifname") ;;
    esac
  done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}')
  addrs+=(127.0.0.1 0.0.0.0)
  notes+=("только с этой машины, дальше свой прокси" "на всех адресах, открыт всем, кто видит сервер")
  for i in "${!addrs[@]}"; do
    if [ "${addrs[i]}" = "$1" ]; then default=$((i + 1)); fi
    printf '      %s%2d%s  %-16s %s%s%s\n' "$c_ask" $((i + 1)) "$c_off" "${addrs[i]}" "$c_dim" "${notes[i]}" "$c_off"
  done
  while :; do
    ask "номер из списка или свой адрес" "$default"
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "${#REPLY}" -le 3 ] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#addrs[@]}" ]; then
      REPLY=${addrs[REPLY - 1]}
      return 0
    elif [[ "$REPLY" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      return 0
    fi
    warn "Нужен номер от 1 до ${#addrs[@]} или адрес вида 192.168.1.10."
  done
}

as_app() { runuser -u "$APP_USER" -- "$@"; }

usage() {
  cat <<'HELP'
Установка edaphia на сервер Ubuntu или Debian:

  curl -fsSL https://raw.githubusercontent.com/zqpmv/edaphia_install/main/install-edaphia.sh | sudo bash

Повторный запуск — обновление: данные и ключи остаются.
Обновление без токена: sudo edaphia update

Что делает: проверяет сервер; ставит git, curl, python3, iptables, Docker,
Node.js 22, pnpm; заводит пользователя edaphia (код — /opt/edaphia, настройки —
/etc/edaphia/stand.sh); собирает и запускает edaphia; по вопросу закрывает
контейнерам вход на сам сервер (iptables, служба edaphia-hostguard).

Ответы заранее (необязательно):
  EDAPHIA_YES=1          не ждать Enter на первом экране
  EDAPHIA_GIT_TOKEN      токен GitHub только на чтение
  EDAPHIA_UI_BIND        адрес веб-интерфейса
  EDAPHIA_UI_PORT        порт веб-интерфейса (8787)
  EDAPHIA_VIEW_PORT      порт просмотра приложений (8790)
  EDAPHIA_HOSTGUARD      защита сервера: да | нет
  EDAPHIA_REPO, EDAPHIA_BRANCH, EDAPHIA_DIR, EDAPHIA_UPDATE_REPO

NO_COLOR=1 отключает цвета. Журнал: /var/log/edaphia-install.log
HELP
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) die "Неизвестный аргумент: $1. Справка: --help" ;;
esac

[ "$(id -u)" = 0 ] || die "Нужны права root. Запустите так: curl -fsSL … | sudo bash"
touch "$INSTALL_LOG"
chmod 600 "$INSTALL_LOG"

# ── первый экран ────────────────────────────────────────────────────────────
echo
draw_sprout
printf '\n    %s%se d a p h i a%s\n' "$c_bold" "$c_leaf" "$c_off"
printf '    %sИнфраструктура разработки на вашем сервере%s\n' "$c_dim" "$c_off"
if [ -d "$DIR/.git" ]; then
  heading "Обновление edaphia в $DIR"
  info "Данные и ключи останутся на месте."
else
  heading "Установка займёт время: образы собираются с нуля, это могут быть десятки минут."
  printf '\n  Подготовьте:\n'
  printf '    %s•%s токен GitHub только на чтение для репозитория edaphia\n' "$c_leaf" "$c_off"
  printf '    %s•%s ключи API моделей (можно добавить позже)\n' "$c_leaf" "$c_off"
  printf '    %s•%s место вне сервера для копии мастер-ключа\n' "$c_leaf" "$c_off"
fi
echo
if [ "$HAVE_TTY" = 1 ] && [ -z "${EDAPHIA_YES:-}" ]; then
  read -r -p "  ${c_ask}Enter${c_off} — начать, ${c_dim}Ctrl+C — отмена${c_off} " _ <"$TTY" || true
fi

# ── 1. сервер ───────────────────────────────────────────────────────────────
step
[ -r /etc/os-release ] || die "Не найден /etc/os-release. Поддерживаются Ubuntu и Debian."
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
  ubuntu:*|debian:*|*:*debian*) ok "${PRETTY_NAME:-$ID}" ;;
  *) die "${PRETTY_NAME:-$ID} не поддерживается. Нужна Ubuntu или Debian." ;;
esac
case "$(uname -m)" in
  x86_64|aarch64) ok "архитектура $(uname -m)" ;;
  *) die "Архитектура $(uname -m) не поддерживается. Нужна x86_64 или aarch64." ;;
esac
mem_mib=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$mem_mib" -ge 8000 ]; then ok "память $((mem_mib / 1024)) ГиБ"; else attention "Памяти $mem_mib МиБ, рекомендуется от 8 ГиБ: сборка и прогоны могут не уместиться."; fi
disk_gib=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
if [ "$disk_gib" -ge 40 ]; then ok "свободно на диске $disk_gib ГиБ"; else attention "На диске свободно $disk_gib ГиБ, нужно от 40 ГиБ для образов и сборок."; fi

# ── 2. пакеты ───────────────────────────────────────────────────────────────
step
export DEBIAN_FRONTEND=noninteractive
run "Обновляю список пакетов" apt-get update -qq
run "Ставлю git, curl, python3, iptables" apt-get install -y -qq ca-certificates curl gnupg git openssh-client python3 iptables
ok "пакеты на месте"

# ── 3. Docker ───────────────────────────────────────────────────────────────
install_docker() {
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}
step
if ! command -v docker >/dev/null 2>&1; then
  run "Ставлю Docker из репозитория docker.com" install_docker
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker info >/dev/null 2>&1 || die "Служба Docker не отвечает. Проверьте: systemctl status docker"
if ! docker compose version >/dev/null 2>&1; then
  run "Ставлю docker compose" apt-get install -y -qq docker-compose-plugin
fi
ok "$(docker --version | cut -d, -f1), compose $(docker compose version --short)"

# ── 4. Node и pnpm ──────────────────────────────────────────────────────────
install_node() {
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y -qq nodejs
}
step
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" != "$NODE_MAJOR" ]; then
  run "Ставлю Node.js $NODE_MAJOR" install_node
fi
if ! command -v pnpm >/dev/null 2>&1 || [ "$(pnpm -v)" != "$PNPM_VERSION" ]; then
  run "Ставлю pnpm $PNPM_VERSION" npm install -g --silent "pnpm@$PNPM_VERSION"
fi
ok "Node $(node -v), pnpm $(pnpm -v)"

# ── 5. пользователь и код ───────────────────────────────────────────────────
step
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$APP_HOME" --shell /bin/bash "$APP_USER"
  ok "создан пользователь $APP_USER"
fi
usermod -aG docker "$APP_USER"
install -d -o "$APP_USER" -g "$APP_USER" "$DIR"

# Токен — только из окружения: в argv git попадает строка помощника с
# «$EDAPHIA_GIT_TOKEN», не значение; в .git/config не пишется.
GIT_AUTH=(-c credential.helper= -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$EDAPHIA_GIT_TOKEN"; }; f')
export GIT_TERMINAL_PROMPT=0
if [ -z "${EDAPHIA_GIT_TOKEN:-}" ]; then
  info "Код лежит в закрытом репозитории. Нужен токен только на чтение:"
  info "github.com/settings/personal-access-tokens → Fine-grained → репозиторий edaphia → Contents: Read-only"
  info "Токен нигде не сохраняется."
  for attempt in 1 2 3 4; do
    [ "$attempt" != 4 ] || die "Токен не подошёл три раза. Проверьте его срок и доступ к $REPO."
    ask_secret "токен (ввод скрыт)"
    export EDAPHIA_GIT_TOKEN="$REPLY"
    if [ -z "$EDAPHIA_GIT_TOKEN" ]; then
      warn "Токен пустой."
    elif as_app git "${GIT_AUTH[@]}" ls-remote --quiet "$REPO" HEAD >/dev/null 2>&1; then
      ok "токен принят"
      break
    else
      warn "GitHub не принял токен или у него нет доступа к $REPO."
    fi
  done
fi
export EDAPHIA_GIT_TOKEN
FRESH_CODE=0
if [ -d "$DIR/.git" ]; then
  run "Получаю обновления" as_app git -C "$DIR" "${GIT_AUTH[@]}" fetch --quiet "$REPO" "$BRANCH"
  if [ -n "$(as_app git -C "$DIR" status --porcelain)" ]; then die "В $DIR есть незакоммиченные правки. Обновление их не трогает: уберите их и запустите снова."; fi
  as_app git -C "$DIR" merge --ff-only --quiet FETCH_HEAD || die "В $DIR есть коммиты, которых нет в $REPO. Обновление возможно только вперёд."
  ok "код обновлён: $(as_app git -C "$DIR" log -1 --format='%h %s' | cut -c1-70)"
else
  run "Загружаю код" as_app git "${GIT_AUTH[@]}" clone --quiet --branch "$BRANCH" "$REPO" "$DIR"
  FRESH_CODE=1
  ok "код получен: $(as_app git -C "$DIR" log -1 --format='%h %s' | cut -c1-70)"
fi
unset EDAPHIA_GIT_TOKEN

# ── 6. адрес веб-интерфейса ─────────────────────────────────────────────────
step
install -d -m 0755 "$CONF_DIR"
primary_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
if [ -f "$STAND_FILE" ] && [ -z "${EDAPHIA_UI_BIND:-}" ]; then
  ok "настройки уже есть в $STAND_FILE, оставляю (удалите файл, чтобы выбрать заново)"
else
  bind="${EDAPHIA_UI_BIND:-}"
  if [ -z "$bind" ]; then
    info "Где будет открываться веб-интерфейс:"
    choose_address "${primary_ip:-127.0.0.1}"
    bind="$REPLY"
  fi
  ui_port="${EDAPHIA_UI_PORT:-}"
  if [ -z "$ui_port" ]; then ask_port "порт веб-интерфейса" 8787; ui_port="$REPLY"; fi
  view_port="${EDAPHIA_VIEW_PORT:-}"
  if [ -z "$view_port" ]; then ask_port "порт просмотра приложений" 8790 "$ui_port"; view_port="$REPLY"; fi
  [[ "$ui_port" =~ ^[0-9]+$ && "$view_port" =~ ^[0-9]+$ ]] || die "Порт должен быть числом."
  host="$bind"
  if [ "$bind" = 0.0.0.0 ]; then host="${primary_ip:-127.0.0.1}"; fi
  sed -e "s|@UI_BIND@|$bind|g" -e "s|@UI_PORT@|$ui_port|g" -e "s|@VIEW_PORT@|$view_port|g" -e "s|@UI_HOST@|$host|g" \
    "$DIR/deploy/stand/default.sh.template" >"$STAND_FILE.tmp"
  ! grep -q '@[A-Z_]*@' "$STAND_FILE.tmp" || die "В шаблоне настроек остались незаполненные поля."
  chmod 0644 "$STAND_FILE.tmp"
  mv "$STAND_FILE.tmp" "$STAND_FILE"
  ok "интерфейс: http://$host:$ui_port, просмотр приложений: http://$host:$view_port"
fi

# ── 7. ключ для обновлений ──────────────────────────────────────────────────
# `sudo edaphia update` тянет код от edaphia по ssh: свой ключ, deploy key
# репозитория только на чтение. Токен для этого не хранится.
step
case "$REPO" in
  https://github.com/*) gh_path="${REPO#https://github.com/}"; UPDATE_REPO_DEFAULT="git@github.com:${gh_path%.git}.git" ;;
  *) UPDATE_REPO_DEFAULT="$REPO" ;;
esac
UPDATE_REPO="${EDAPHIA_UPDATE_REPO:-$UPDATE_REPO_DEFAULT}"
as_app install -d -m 0700 "$APP_HOME/.ssh"
[ -f "$APP_HOME/.ssh/id_ed25519" ] || as_app ssh-keygen -q -t ed25519 -N '' -C "edaphia@$(hostname) update" -f "$APP_HOME/.ssh/id_ed25519"
# Ключ хоста GitHub — опубликованный (api.github.com/meta, отпечаток
# SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU), не первое подключение.
# Верно, пока: GitHub не сменил ключ ed25519 (последняя смена — RSA, 03.2023).
GITHUB_ED25519='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
as_app touch "$APP_HOME/.ssh/known_hosts"
grep -qxF "$GITHUB_ED25519" "$APP_HOME/.ssh/known_hosts" || printf '%s\n' "$GITHUB_ED25519" | as_app tee -a "$APP_HOME/.ssh/known_hosts" >/dev/null
if as_app env GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' git ls-remote --quiet "$UPDATE_REPO" HEAD >/dev/null 2>&1; then
  ok "обновления будут работать: sudo edaphia update"
else
  DEPLOY_KEY=$(cat "$APP_HOME/.ssh/id_ed25519.pub" 2>/dev/null || true)
  warn "Ключ ещё не добавлен в репозиторий. Что сделать, покажу в конце."
fi

# ── 8. сборка и запуск ──────────────────────────────────────────────────────
step
as_app mkdir -p "$APP_HOME/.config/edaphia"
as_app bash -c "printf '{\"home\":\"%s\",\"repo\":\"%s\",\"branch\":\"%s\",\"stand\":\"%s\"}\n' '$DIR' '$UPDATE_REPO' '$BRANCH' '$STAND_FILE' >'$APP_HOME/.config/edaphia/config.json'"
ln -sf "$DIR/scripts/edaphia.mjs" /usr/local/bin/edaphia
running=$(docker ps -q --filter label=com.docker.compose.project=edaphia | head -1)
cd "$DIR"
FINISHED_AS="установлена"
if [ -n "$running" ] && [ "$FRESH_CODE" = 0 ]; then
  # Стенд уже стоит — обновление: сборка и пересоздание устаревшего.
  info "Пересобираю и перезапускаю только то, что изменилось. Ниже — вывод сборки."
  as_app env EDAPHIA_STAND="$STAND_FILE" bash -c "cd '$DIR' && pnpm install --frozen-lockfile --silent && pnpm build >/dev/null && node scripts/edaphia.mjs upgrade --no-fetch" <"$TTY"
  FINISHED_AS="обновлена"
else
  info "Самая долгая часть. По ходу сборка спросит: как сохранить мастер-ключ,"
  info "логин и пароль для входа, ключи API. Ниже — вывод сборки."
  if ! as_app env EDAPHIA_STAND="$STAND_FILE" "$DIR/scripts/install.sh" <"$TTY"; then
    attention "Сборка закончилась с замечаниями: список выше. Повторный запуск продолжит."
    FINISHED_AS="установлена с замечаниями"
  fi
fi

# ── 9. защита сервера (правило хоста Q74) ───────────────────────────────────
step
info "Код, который пишут модели, выполняется в контейнерах. Защита закрывает им"
info "вход на сам сервер: ssh, базы, другие службы. Выход в интернет не меняется,"
info "настройки ssh и ufw тоже."
guard="${EDAPHIA_HOSTGUARD:-}"
if [ -z "$guard" ]; then
  if ask_yes "включить защиту" "да"; then guard=да; else guard=нет; fi
fi
if [ "$guard" = да ] || [ "$guard" = yes ]; then
  cat >/usr/local/sbin/edaphia-hostguard <<'GUARD'
#!/bin/sh
# Q74: из сетей docker на хост — только ответы на уже установленные соединения.
set -e
for ipt in iptables ip6tables; do
  command -v "$ipt" >/dev/null 2>&1 || continue
  for ifc in 'br-+' docker0; do
    $ipt -C INPUT -i "$ifc" -j DROP 2>/dev/null || $ipt -I INPUT 1 -i "$ifc" -j DROP
    $ipt -C INPUT -i "$ifc" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
      || $ipt -I INPUT 1 -i "$ifc" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  done
done
GUARD
  chmod 0755 /usr/local/sbin/edaphia-hostguard
  cat >/etc/systemd/system/edaphia-hostguard.service <<'UNIT'
[Unit]
Description=edaphia: контейнерам закрыт вход на хост (Q74)
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/edaphia-hostguard
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now edaphia-hostguard >/dev/null
  if as_app env TAILNET_PEER=none "$DIR/tools/probe/q74-host-check.sh" --expect after >/tmp/edaphia-q74.txt 2>&1; then
    ok "защита включена и проверена"
  else
    attention "Защита включена, но проверка не совпала: /tmp/edaphia-q74.txt"
  fi
else
  attention "Защита выключена: код моделей сможет обращаться к службам этого сервера."
fi

# ── итоговый экран ──────────────────────────────────────────────────────────
STEP_TITLE="итоговый экран"
. "$STAND_FILE"
if curl -s -o /dev/null -m 5 "$EDAPHIA_UI_URL"; then ui_state="${c_good}отвечает${c_off}"; else
  ui_state="${c_warn}пока не отвечает${c_off}"
  ATTENTION+=("Интерфейс не ответил по адресу $EDAPHIA_UI_URL. Проверьте: sudo -u $APP_USER edaphia doctor")
fi

echo
draw_sprout
printf '\n  %s%sedaphia %s%s  %s%s, версия %s%s\n' "$c_bold" "$c_leaf" "$FINISHED_AS" "$c_off" \
  "$c_dim" "$(fmt_time $((SECONDS - STARTED)))" "$(as_app git -C "$DIR" log -1 --format='%h')" "$c_off"

heading "Откройте в браузере"
printf '    %s%s%s  %s\n' "$c_bold" "$EDAPHIA_UI_URL" "$c_off" "$ui_state"
info "Вход — логин и пароль, которые вы задали при сборке."

if [ "${#ATTENTION[@]}" -gt 0 ] || [ -n "$DEPLOY_KEY" ]; then
  heading "Требует внимания"
  for item in ${ATTENTION[@]+"${ATTENTION[@]}"}; do warn "$item"; done
  if [ -n "$DEPLOY_KEY" ]; then
    warn "Чтобы работало sudo edaphia update, добавьте ключ в репозиторий edaphia:"
    info "GitHub → Settings → Deploy keys → Add deploy key, «Allow write access» не отмечать"
    printf '\n    %s\n\n' "$DEPLOY_KEY"
  fi
fi

if [ "$FRESH_CODE" = 1 ]; then
  heading "Не забудьте"
  printf '    Храните копию мастер-ключа вне этого сервера.\n'
  info "Частный доступ через tailscale, netbird или свой прокси — README, «Вход через прокси»."
fi

heading "Команды"
printf '    %-34s %s%s%s\n' "sudo edaphia update" "$c_dim" "обновить" "$c_off"
printf '    %-34s %s%s%s\n' "sudo -u $APP_USER edaphia status" "$c_dim" "состояние" "$c_off"
printf '    %-34s %s%s%s\n' "sudo -u $APP_USER edaphia doctor" "$c_dim" "найти неполадки" "$c_off"
printf '    %-34s %s%s%s\n' "sudo -u $APP_USER edaphia secrets" "$c_dim" "ключи API" "$c_off"
printf '\n  %sНастройки: %s · журнал установки: %s%s\n\n' "$c_dim" "$STAND_FILE" "$INSTALL_LOG" "$c_off"
