#!/usr/bin/env bash
# Установка части 2 edaphia («доработка») одной командой — на сервер, где
# уже стоит часть 1 (install-edaphia.sh):
#
#   curl -fsSL https://raw.githubusercontent.com/zqpmv/edaphia_install/main/install-edaphia-part2.sh | sudo bash
#
# Скрипт открытый, код — из закрытого репозитория zqpmv/edaphia-part2: по
# ssh-ключу пользователя edaphia, если он уже добавлен в репозиторий, иначе
# по токену (Contents — Read, Administration — Read and write): тогда ключ
# сервера установщик добавляет сам, ключи прежних установок показывает и по
# вопросу удаляет. Повторный запуск — обновление. Справка: --help.
#
# Что делает: проверяет часть 1 и её контур (сеть и тома для части 2);
# заводит пользователю edaphia отдельный ключ для `sudo edaphia update part2`
# (GitHub не даёт один deploy key двум репозиториям); кладёт код в
# /opt/edaphia-part2; собирает образ и поднимает контейнер
# (`edaphia update part2`); пишет PART2_URL в файл стенда — после проверки
# check-stand-config, иначе файл возвращается из копии — и перезапускает
# control, чтобы в интерфейсе появился пункт «Доработка».
#
# На экране — только ход установки; вывод git, docker и сборки уходит в
# журнал /var/log/edaphia-part2-install.log и показывается при ошибке.
set -Eeuo pipefail

REPO="${EDAPHIA_PART2_REPO:-https://github.com/zqpmv/edaphia-part2.git}"
BRANCH="${EDAPHIA_PART2_BRANCH:-main}"
DIR="${EDAPHIA_PART2_DIR:-/opt/edaphia-part2}"
DEFAULT_DIR=/opt/edaphia-part2
APP_USER=edaphia
CONTOUR="${COMPOSE_PROJECT_NAME:-edaphia}"
PART2_URL_VALUE="http://part2:8788"
SSH_ALIAS=github.com-edaphia-part2
INSTALL_LOG=/var/log/edaphia-part2-install.log
TTY=/dev/tty

PLAN=(
  "Проверка части 1"
  "Код части 2"
  "Ключ для обновлений"
  "Сборка и запуск"
  "Пункт в интерфейсе"
)
STEP_NO=0
STEP_TITLE="подготовка"
RUN_PID=""
ATTENTION=()
DEPLOY_KEY=""
STARTED=$SECONDS

# ── оформление (как в install-edaphia.sh) ───────────────────────────────────
# Имена строчные: файл стенда задаёт прописные переменные.
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

# $1 что делается, дальше команда: вывод в журнал, на экране спиннер.
# Код команды — в RUN_CODE; решает вызывающий (run) или сам (try).
spin() {
  local label=$1 started=$SECONDS frame=0
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  shift
  RUN_CODE=0
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
  wait "$RUN_PID" || RUN_CODE=$?
  RUN_PID=""
}

show_log_tail() { # $1 что делалось
  printf '    %s✗%s %s — ошибка (код %d). Последние строки журнала:\n\n' "$c_bad" "$c_off" "$1" "$RUN_CODE" >&2
  tail -n 15 "$INSTALL_LOG" | sed 's/^/      /' >&2
}

run() { # команда обязана пройти
  spin "$@"
  if [ "$RUN_CODE" != 0 ]; then
    show_log_tail "$1"
    die "Не получилось: $1. Журнал: $INSTALL_LOG. Повторный запуск продолжит установку."
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

ask_secret() { # $1 вопрос → REPLY
  [ "$HAVE_TTY" = 1 ] || die "Нет терминала для скрытого ввода: задайте EDAPHIA_PART2_GIT_TOKEN в окружении или добавьте ключ (см. --help)."
  IFS= read -r -s -p "    ${c_ask}?${c_off} $1: " REPLY <"$TTY" || true
  echo
}

ask() { # $1 вопрос, $2 ответ по умолчанию → REPLY
  local answer=""
  if [ "$HAVE_TTY" = 1 ]; then read -r -p "    ${c_ask}?${c_off} $1${2:+ ${c_dim}[$2]${c_off}}: " answer <"$TTY" || true; fi
  REPLY="${answer:-${2:-}}"
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

as_app() { runuser -u "$APP_USER" -- "$@"; }

# ── ключ сервера в GitHub (deploy key) ──────────────────────────────────────
# 20.11, решение оператора: установка чистая — ключ сервера регистрирует сам
# установщик, ключи прежних установок показывает и по вопросу удаляет. Иначе
# новый сервер оставался без доступа (обновление молча не работало), а ключ
# старого сервера — с доступом. Нужен токен с правом Administration на
# репозиторий; без него — ручной путь: показать ключ и ждать, пока добавят.
#
# Токен — в переменной окружения, имя которой в GH_TOKEN_VAR: заголовок
# авторизации идёт curl через stdin (-H @-), в argv токена нет.
gh_api() { # $1 метод, $2 путь, $3 тело JSON (необязательно) → GH_STATUS, GH_BODY
  local out data=()
  if [ -n "${3:-}" ]; then data=(--data "$3"); fi
  if ! out=$(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "${!GH_TOKEN_VAR}" |
    curl -sS -m 20 -H @- -X "$1" ${data[@]+"${data[@]}"} -w '\n%{http_code}' "https://api.github.com$2" 2>>"$INSTALL_LOG"); then
    GH_STATUS=000 GH_BODY=""
    return 0
  fi
  GH_STATUS=${out##*$'\n'}
  GH_BODY=${out%$'\n'*}
}

ssh_reaches() { # $1 адрес репозитория по ssh: пускает ли ключ сервера
  as_app env GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=yes' git ls-remote --quiet "$1" HEAD >/dev/null 2>&1
}

# $1 owner/repo, $2 файл .pub, $3 название ключа, $4 ssh-адрес для проверки,
# $5 удалять старые по умолчанию (да|нет). Итог: KEY_OK=1, или KEY_OK=0 и
# DEPLOY_KEY — ключ для итогового экрана.
register_deploy_key() {
  local slug=$1 pubfile=$2 title=$3 ssh_url=$4 remove_default=$5 pub listing id name created used same old=() i
  KEY_OK=0
  pub=$(cut -d' ' -f1,2 "$pubfile")
  gh_api GET "/repos/$slug/keys?per_page=100"
  if [ "$GH_STATUS" != 200 ]; then
    warn "Токен не даёт управлять ключами репозитория (ответ GitHub $GH_STATUS): нужно право Administration."
    manual_deploy_key "$slug" "$pubfile" "$ssh_url"
    return 0
  fi
  # Строки «id<TAB>название<TAB>создан<TAB>последний вход<TAB>это ключ сервера».
  listing=$(printf '%s' "$GH_BODY" | node -e '
    const pub = process.argv[1]
    let text = ""; process.stdin.on("data", (d) => (text += d)).on("end", () => {
      for (const k of JSON.parse(text)) {
        const day = (v) => (v ? v.slice(0, 10) : "никогда")
        const clean = (v) => String(v).replace(/[\t\n]/g, " ")
        console.log([k.id, clean(k.title), day(k.created_at), day(k.last_used), k.key.split(" ").slice(0, 2).join(" ") === pub ? 1 : 0].join("\t"))
      }
    })' "$pub")
  while IFS=$'\t' read -r id name created used same; do
    [ -n "$id" ] || continue
    if [ "$same" = 1 ]; then KEY_OK=1; else old+=("$id"$'\t'"$name"$'\t'"$created"$'\t'"$used"); fi
  done <<<"$listing"
  if [ "${#old[@]}" -gt 0 ]; then
    info "В репозитории $slug уже есть ключи других установок:"
    for i in "${old[@]}"; do
      IFS=$'\t' read -r id name created used <<<"$i"
      printf '      %s•%s %-34s %sдобавлен %s, последний вход %s%s\n' "$c_leaf" "$c_off" "$name" "$c_dim" "$created" "$used" "$c_off"
    done
    info "Ключ сервера, которым больше не пользуются, — открытый доступ к коду."
    if ask_yes "удалить их" "$remove_default"; then
      for i in "${old[@]}"; do
        IFS=$'\t' read -r id name _ <<<"$i"
        gh_api DELETE "/repos/$slug/keys/$id"
        if [ "$GH_STATUS" = 204 ]; then ok "удалён ключ «$name»"; else attention "Ключ «$name» не удалён (ответ GitHub $GH_STATUS) — удалите в Settings → Deploy keys."; fi
      done
    else
      info "оставляю"
    fi
  fi
  if [ "$KEY_OK" = 1 ]; then
    ok "ключ этого сервера уже добавлен в $slug"
  else
    gh_api POST "/repos/$slug/keys" "$(printf '{"title":"%s","key":"%s","read_only":true}' "$title" "$pub")"
    case "$GH_STATUS" in
      201) ok "ключ сервера добавлен в $slug (только чтение): «$title»" ;;
      422) die "GitHub не принял ключ $pubfile: он уже добавлен в другой репозиторий (один deploy key — один репозиторий). Удалите его там или удалите файл ключа и запустите снова." ;;
      *) warn "Ключ не добавлен (ответ GitHub $GH_STATUS)."; manual_deploy_key "$slug" "$pubfile" "$ssh_url"; return 0 ;;
    esac
  fi
  # GitHub применяет ключ не мгновенно — несколько попыток.
  for i in 1 2 3 4 5; do
    if ssh_reaches "$ssh_url"; then KEY_OK=1; ok "вход по ключу проверен: обновления пойдут без токена"; return 0; fi
    sleep 2
  done
  KEY_OK=0
  attention "Ключ есть в $slug, но вход по нему не прошёл. Проверьте: sudo -u $APP_USER git ls-remote $ssh_url"
}

manual_deploy_key() { # $1 owner/repo, $2 файл .pub, $3 ssh-адрес: показать ключ и ждать
  local slug=$1 pubfile=$2 ssh_url=$3
  DEPLOY_KEY=$(cat "$pubfile")
  if [ "$HAVE_TTY" != 1 ]; then
    warn "Ключ не добавлен. Что сделать, покажу в конце."
    return 0
  fi
  info "Добавьте ключ сами: github.com/$slug → Settings → Deploy keys → Add deploy key,"
  info "«Allow write access» не отмечать. Ключи прежних серверов там же — удалите."
  printf '\n    %s\n\n' "$DEPLOY_KEY"
  while :; do
    ask "Enter — проверить, «потом» — продолжить без ключа" ""
    if [ "$REPLY" = потом ]; then warn "Продолжаю без ключа. Ключ — ещё раз в конце."; return 0; fi
    if ssh_reaches "$ssh_url"; then KEY_OK=1; DEPLOY_KEY=""; ok "вход по ключу проверен: обновления пойдут без токена"; return 0; fi
    warn "Вход по ключу пока не проходит."
  done
}

usage() {
  cat <<'HELP'
Установка части 2 edaphia («доработка») на сервер, где уже стоит часть 1:

  curl -fsSL https://raw.githubusercontent.com/zqpmv/edaphia_install/main/install-edaphia-part2.sh | sudo bash

Повторный запуск — обновление. Обновление без токена: sudo edaphia update part2

Что делает: проверяет часть 1 и её контур; заводит пользователю edaphia
отдельный ключ для обновлений части 2; кладёт код в /opt/edaphia-part2;
собирает образ и поднимает контейнер; пишет PART2_URL в файл стенда (после
проверки check-stand-config) и перезапускает control — в интерфейсе
появляется «Доработка».

Ответы заранее (необязательно):
  EDAPHIA_YES=1               не ждать Enter на первом экране
  EDAPHIA_PART2_GIT_TOKEN     токен GitHub (если ключ ещё не добавлен): Contents — Read,
                              Administration — Read and write
  EDAPHIA_REMOVE_OLD_KEYS     ключи прежних установок в GitHub: да | нет
  EDAPHIA_PART2_REPO, EDAPHIA_PART2_BRANCH (main), EDAPHIA_PART2_DIR (/opt/edaphia-part2)

NO_COLOR=1 отключает цвета. Журнал: /var/log/edaphia-part2-install.log
HELP
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) die "Неизвестный аргумент: $1. Справка: --help" ;;
esac

[ "$(id -u)" = 0 ] || die "Нужны права root. Запустите так: curl -fsSL … | sudo bash"
# Ветка уходит аргументом git: значение с дефиса git прочёл бы как флаг.
[[ "$BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ ]] || die "EDAPHIA_PART2_BRANCH «$BRANCH» — не имя ветки."
touch "$INSTALL_LOG"
chmod 600 "$INSTALL_LOG"

# ── первый экран ────────────────────────────────────────────────────────────
echo
draw_sprout
printf '\n    %s%se d a p h i a  ·  часть 2%s\n' "$c_bold" "$c_leaf" "$c_off"
printf '    %sДоработка готового приложения%s\n' "$c_dim" "$c_off"
if [ -d "$DIR/.git" ]; then
  heading "Обновление части 2 в $DIR"
  info "Прогоны конвейера обновлению не мешают."
else
  heading "Установка части 2 рядом с работающей частью 1."
  printf '\n  Подготовьте:\n'
  printf '    %s•%s токен GitHub для репозитория edaphia-part2: Contents — Read, Administration — Read and write\n' "$c_leaf" "$c_off"
  printf '      %s(Administration — чтобы установщик сам добавил ключ сервера и убрал ключи прежних установок)%s\n' "$c_dim" "$c_off"
  printf '      %s(не нужен, если ключ edaphia уже добавлен в репозиторий)%s\n' "$c_dim" "$c_off"
  info "В конце control перезапустится, чтобы показать пункт «Доработка»:"
  info "если идут прогоны, это отложится — скажу, что сделать."
fi
echo
if [ "$HAVE_TTY" = 1 ] && [ -z "${EDAPHIA_YES:-}" ]; then
  read -r -p "  ${c_ask}Enter${c_off} — начать, ${c_dim}Ctrl+C — отмена${c_off} " _ <"$TTY" || true
fi

# ── 1. часть 1 и её контур ──────────────────────────────────────────────────
step
command -v git >/dev/null 2>&1 || die "Нет git. Часть 1 ставится раньше: install-edaphia.sh"
id "$APP_USER" >/dev/null 2>&1 || die "Нет пользователя $APP_USER — часть 1 не установлена. Сначала: install-edaphia.sh"
APP_HOME=$(getent passwd "$APP_USER" | cut -d: -f6)
CONFIG="$APP_HOME/.config/edaphia/config.json"
[ -r "$CONFIG" ] || die "Нет $CONFIG — часть 1 ставилась не через install-edaphia.sh."
config_get() { node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const v=process.argv[2].split(".").reduce((o,k)=>o?.[k],c); process.stdout.write(typeof v==="string"?v:"")' "$CONFIG" "$1"; }
P1_DIR=$(config_get home)
STAND_FILE=$(config_get stand)
[ -n "$P1_DIR" ] && [ -f "$P1_DIR/scripts/edaphia.mjs" ] || die "Рабочая копия части 1 не найдена (home в $CONFIG: «$P1_DIR»)."
[ -n "$STAND_FILE" ] && [ -f "$STAND_FILE" ] || die "Файл стенда не найден (stand в $CONFIG: «$STAND_FILE»)."
command -v edaphia >/dev/null 2>&1 || die "Нет команды edaphia — повторите установку части 1."
ok "часть 1: $P1_DIR ($(as_app git -C "$P1_DIR" log -1 --format='%h %ad' --date=short))"
docker info >/dev/null 2>&1 || die "Служба Docker не отвечает. Проверьте: systemctl status docker"
[ -n "$(docker ps -q --filter "name=^${CONTOUR}-control$")" ] || die "control части 1 не запущен (${CONTOUR}-control). Проверьте: sudo -u $APP_USER edaphia doctor"
missing=()
docker network inspect "${CONTOUR}_edaphia" >/dev/null 2>&1 || missing+=("сеть ${CONTOUR}_edaphia")
for vol in "${CONTOUR}_p2_caller" "${CONTOUR}_runtime_secrets"; do
  docker volume inspect "$vol" >/dev/null 2>&1 || missing+=("том $vol")
done
[ "${#missing[@]}" = 0 ] || die "У контура нет: ${missing[*]}. Часть 1 старее поддержки части 2 — сначала: sudo edaphia update"
ok "контур «$CONTOUR» готов к части 2: сеть и тома на месте"

# ── 2. код ──────────────────────────────────────────────────────────────────
# Свой ключ, а не ключ части 1: GitHub не принимает один deploy key во второй
# репозиторий («key is already in use»). Псевдоним хоста в ~/.ssh/config
# выбирает ключ; origin рабочей копии — через него, и `edaphia update part2`
# (scripts/update.mjs: git fetch origin) тянет без токена. Ключ уже пускает —
# код по нему; нет — по токену, и ключ регистрирует следующий шаг.
step
KEY="$APP_HOME/.ssh/id_ed25519_part2"
case "$REPO" in
  https://github.com/*) slug="${REPO#https://github.com/}"; slug="${slug%.git}"; UPDATE_REPO="git@${SSH_ALIAS}:${slug}.git" ;;
  *) slug=""; UPDATE_REPO="$REPO" ;;
esac
as_app install -d -m 0700 "$APP_HOME/.ssh"
[ -f "$KEY" ] || as_app ssh-keygen -q -t ed25519 -N '' -C "edaphia@$(hostname) part2 update" -f "$KEY"
# Ключ хоста GitHub — опубликованный (api.github.com/meta, отпечаток
# SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU), не первое подключение.
# Верно, пока: GitHub не сменил ключ ed25519 (последняя смена — RSA, 03.2023).
GITHUB_ED25519='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
as_app touch "$APP_HOME/.ssh/known_hosts"
grep -qxF "$GITHUB_ED25519" "$APP_HOME/.ssh/known_hosts" || printf '%s\n' "$GITHUB_ED25519" | as_app tee -a "$APP_HOME/.ssh/known_hosts" >/dev/null
as_app touch "$APP_HOME/.ssh/config"
chmod 600 "$APP_HOME/.ssh/config"
if ! grep -qE "^Host ${SSH_ALIAS}\$" "$APP_HOME/.ssh/config"; then
  # HostKeyAlias: ключ хоста сверяется с записью github.com, а не с псевдонимом.
  printf '\n# edaphia-part2: свой deploy key (install-edaphia-part2.sh)\nHost %s\n  HostName github.com\n  User git\n  HostKeyAlias github.com\n  IdentityFile %s\n  IdentitiesOnly yes\n' "$SSH_ALIAS" "$KEY" |
    as_app tee -a "$APP_HOME/.ssh/config" >/dev/null
fi
SSH_OK=0
if ssh_reaches "$UPDATE_REPO"; then SSH_OK=1; fi
install -d -o "$APP_USER" -g "$APP_USER" "$DIR"
export GIT_TERMINAL_PROMPT=0
if [ "$SSH_OK" = 1 ]; then
  SOURCE="$UPDATE_REPO"
  GIT_AUTH=(-c core.sshCommand='ssh -o BatchMode=yes -o StrictHostKeyChecking=yes')
  ok "ключ сервера уже пускает в репозиторий — код по нему, токен не нужен"
else
  # Токен — только из окружения: в argv git попадает строка помощника с
  # «$EDAPHIA_PART2_GIT_TOKEN», не значение; в .git/config не пишется.
  SOURCE="$REPO"
  GIT_AUTH=(-c credential.helper= -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$EDAPHIA_PART2_GIT_TOKEN"; }; f')
  if [ -z "${EDAPHIA_PART2_GIT_TOKEN:-}" ]; then
    info "Код лежит в закрытом репозитории. Нужен токен:"
    info "github.com/settings/personal-access-tokens → Fine-grained → репозиторий edaphia-part2 →"
    info "Contents: Read-only, Administration: Read and write (ключ сервера установщик добавит сам)."
    info "Токен нигде не сохраняется; поставьте ему короткий срок. Дальше обновления — по ключу."
    for attempt in 1 2 3 4; do
      [ "$attempt" != 4 ] || die "Токен не подошёл три раза. Проверьте его срок и доступ к $REPO."
      ask_secret "токен (ввод скрыт)"
      export EDAPHIA_PART2_GIT_TOKEN="$REPLY"
      if [ -z "$EDAPHIA_PART2_GIT_TOKEN" ]; then
        warn "Токен пустой."
      elif as_app env EDAPHIA_PART2_GIT_TOKEN="$EDAPHIA_PART2_GIT_TOKEN" git "${GIT_AUTH[@]}" ls-remote --quiet "$REPO" HEAD >/dev/null 2>&1; then
        ok "токен принят"
        break
      else
        warn "GitHub не принял токен или у него нет доступа к $REPO."
      fi
    done
  fi
  export EDAPHIA_PART2_GIT_TOKEN
fi
# runuser не передаёт окружение целиком: токен — явно, и только git.
as_git() { as_app env EDAPHIA_PART2_GIT_TOKEN="${EDAPHIA_PART2_GIT_TOKEN:-}" git "${GIT_AUTH[@]}" "$@"; }
FRESH_CODE=0
if [ -d "$DIR/.git" ]; then
  if [ -n "$(as_app git -C "$DIR" status --porcelain)" ]; then die "В $DIR есть незакоммиченные правки. Обновление их не трогает: уберите их и запустите снова."; fi
  run "Получаю обновления" as_git -C "$DIR" fetch --quiet "$SOURCE" "$BRANCH"
  as_app git -C "$DIR" merge --ff-only --quiet FETCH_HEAD || die "В $DIR есть коммиты, которых нет в $REPO. Обновление возможно только вперёд."
  ok "код обновлён: $(as_app git -C "$DIR" log -1 --format='%h %s' | cut -c1-70)"
else
  [ -z "$(ls -A "$DIR")" ] || die "$DIR не пуст и это не рабочая копия git. Уберите содержимое или задайте EDAPHIA_PART2_DIR."
  run "Загружаю код" as_git clone --quiet --branch "$BRANCH" "$SOURCE" "$DIR"
  FRESH_CODE=1
  ok "код получен: $(as_app git -C "$DIR" log -1 --format='%h %s' | cut -c1-70)"
fi
# origin — по ключу: им пользуется `edaphia update part2`.
if as_app git -C "$DIR" remote get-url origin >/dev/null 2>&1; then
  as_app git -C "$DIR" remote set-url origin "$UPDATE_REPO"
else
  as_app git -C "$DIR" remote add origin "$UPDATE_REPO"
fi
[ -f "$DIR/scripts/update.mjs" ] || die "В $DIR нет scripts/update.mjs — это не рабочая копия части 2."
# Нестандартный каталог — в конфиг CLI (part2.home), иначе диспетчер его не найдёт.
if [ "$DIR" != "$DEFAULT_DIR" ]; then
  as_app node -e 'const fs=require("fs"); const [f,d]=process.argv.slice(1); const c=JSON.parse(fs.readFileSync(f,"utf8")); c.part2={...(c.part2||{}),home:d}; fs.writeFileSync(f, JSON.stringify(c)+"\n")' "$CONFIG" "$DIR"
  ok "каталог части 2 записан в $CONFIG"
fi

# ── 3. ключ для обновлений ──────────────────────────────────────────────────
step
if [ "$SSH_OK" = 1 ]; then
  ok "обновления пойдут без токена: sudo edaphia update part2"
elif [ -n "$slug" ]; then
  # Новая установка — ключи прежних по умолчанию удаляются; обновление — нет.
  remove_default=нет
  if [ "$FRESH_CODE" = 1 ]; then remove_default=да; fi
  case "${EDAPHIA_REMOVE_OLD_KEYS:-}" in да|yes) remove_default=да ;; нет|no) remove_default=нет ;; esac
  GH_TOKEN_VAR=EDAPHIA_PART2_GIT_TOKEN
  register_deploy_key "$slug" "$KEY.pub" "edaphia@$(hostname) part2 update" "$UPDATE_REPO" "$remove_default"
else
  DEPLOY_KEY=$(cat "$KEY.pub")
  warn "Репозиторий не на GitHub: ключ добавьте сами. Покажу в конце."
fi
unset EDAPHIA_PART2_GIT_TOKEN

# ── 4. сборка и запуск ──────────────────────────────────────────────────────
# Сценарий части 2 (scripts/update.mjs) через диспетчер CLI части 1: тот же
# путь, что у `sudo edaphia update part2` — пользователь edaphia, замок
# сессии, имя контура. Прогоны конвейера не проверяются и не трогаются.
step
log_from=$(($(stat -c %s "$INSTALL_LOG") + 1))
run "Собираю образ и запускаю контейнер части 2" edaphia update part2 --no-fetch
container="${CONTOUR}-part2"
health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)
[ "$health" = healthy ] || die "Контейнер $container не здоров («${health:-нет}»). Журнал: $INSTALL_LOG"
ok "контейнер $container здоров, версия $(docker inspect -f '{{index .Config.Labels "edaphia.commit"}}' "$container")"
# Только вывод этого запуска: в журнале — и прошлые установки.
if tail -c "+$log_from" "$INSTALL_LOG" | grep -q "ВНИМАНИЕ"; then
  attention "Часть 2 запущена, но связь с control не «совместима» — строка в журнале $INSTALL_LOG. Конвейер работает как раньше."
fi

# ── 5. пункт в интерфейсе: PART2_URL ────────────────────────────────────────
# control проксирует /p2/* на PART2_URL; пусто — пункта «Доработка» нет.
# Файл стенда правится только строкой формата `export ИМЯ='значение'` и
# проверяется check-stand-config до перезапуска; отказ — файл из копии.
step
current=$(sed -n "s/^export PART2_URL='\(.*\)'\$/\1/p" "$STAND_FILE" | tail -1)
if [ "$current" = "$PART2_URL_VALUE" ]; then
  ok "PART2_URL уже в $STAND_FILE"
elif [ -n "$current" ]; then
  attention "В $STAND_FILE свой PART2_URL='$current' — оставляю как есть."
else
  backup="$STAND_FILE.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p "$STAND_FILE" "$backup"
  grep -v '^export PART2_URL=' "$STAND_FILE" >"$STAND_FILE.tmp" || true
  printf "# часть 2 («доработка»): control проксирует /p2/* сюда (install-edaphia-part2.sh)\nexport PART2_URL='%s'\n" "$PART2_URL_VALUE" >>"$STAND_FILE.tmp"
  chmod 0644 "$STAND_FILE.tmp"
  mv "$STAND_FILE.tmp" "$STAND_FILE"
  spin "Проверяю файл стенда" as_app env EDAPHIA_STAND="$STAND_FILE" bash -c "cd '$P1_DIR' && node scripts/check-stand-config.mjs"
  if [ "$RUN_CODE" != 0 ]; then
    show_log_tail "Проверка файла стенда"
    cp -p "$backup" "$STAND_FILE"
    die "check-stand-config не принял файл — $STAND_FILE возвращён из $backup, control не тронут. Часть 2 запущена; пункт в интерфейсе — после исправления: PART2_URL='$PART2_URL_VALUE' и sudo edaphia update --no-fetch"
  fi
  ok "PART2_URL='$PART2_URL_VALUE' записан в $STAND_FILE (копия: $backup)"
fi
live=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${CONTOUR}-control" | sed -n 's/^PART2_URL=//p')
want=$(sed -n "s/^export PART2_URL='\(.*\)'\$/\1/p" "$STAND_FILE" | tail -1)
if [ "$live" = "$want" ]; then
  ok "control уже знает адрес части 2"
else
  info "control перезапускается с новым адресом: пересобирается только изменившееся."
  spin "Перезапускаю control (edaphia update --no-fetch)" edaphia update --no-fetch
  if [ "$RUN_CODE" = 0 ]; then
    ok "control перезапущен"
  else
    attention "control не перезапущен (идут прогоны или сборка не прошла — журнал $INSTALL_LOG). Адрес записан; когда можно: sudo edaphia update --no-fetch"
  fi
fi

# ── итоговый экран ──────────────────────────────────────────────────────────
STEP_TITLE="итоговый экран"
EDAPHIA_UI_URL=$(sed -n "s/^export EDAPHIA_UI_URL='\(.*\)'\$/\1/p" "$STAND_FILE" | tail -1)
p2_state=$(as_app env EDAPHIA_STAND="$STAND_FILE" edaphia status 2>/dev/null | sed -n 's/^часть 2: *//p' || true)
FINISHED_AS="установлена"
[ "$FRESH_CODE" = 1 ] || FINISHED_AS="обновлена"

echo
draw_sprout
printf '\n  %s%sчасть 2 %s%s  %s%s, версия %s%s\n' "$c_bold" "$c_leaf" "$FINISHED_AS" "$c_off" \
  "$c_dim" "$(fmt_time $((SECONDS - STARTED)))" "$(as_app git -C "$DIR" log -1 --format='%h')" "$c_off"

heading "Откройте в браузере"
printf '    %s%s/p2/%s\n' "$c_bold" "${EDAPHIA_UI_URL%/}" "$c_off"
info "Или пункт «Доработка» в меню. Состояние части 2 у control: ${p2_state:-не получено}"

if [ "${#ATTENTION[@]}" -gt 0 ] || [ -n "$DEPLOY_KEY" ]; then
  heading "Требует внимания"
  for item in ${ATTENTION[@]+"${ATTENTION[@]}"}; do warn "$item"; done
  if [ -n "$DEPLOY_KEY" ]; then
    warn "Чтобы работало sudo edaphia update part2, добавьте ключ в репозиторий edaphia-part2:"
    info "GitHub → zqpmv/edaphia-part2 → Settings → Deploy keys → Add deploy key, «Allow write access» не отмечать"
    info "(это другой ключ, не тот, что у репозитория edaphia)"
    printf '\n    %s\n\n' "$DEPLOY_KEY"
  fi
fi

heading "Команды"
printf '    %-40s %s%s%s\n' "sudo edaphia update part2" "$c_dim" "обновить часть 2" "$c_off"
printf '    %-40s %s%s%s\n' "sudo edaphia update part2 --rollback" "$c_dim" "вернуть прежний образ" "$c_off"
printf '    %-40s %s%s%s\n' "sudo -u $APP_USER edaphia status" "$c_dim" "состояние обеих частей" "$c_off"
printf '\n  %sКод: %s · настройки: %s · журнал: %s%s\n\n' "$c_dim" "$DIR" "$STAND_FILE" "$INSTALL_LOG" "$c_off"
