#!/usr/bin/env bash
# Установка edaphia одной командой (28.10, по образцу Arcane):
#
#   curl -fsSL https://raw.githubusercontent.com/zqpmv/edaphia_install/main/install-edaphia.sh | sudo bash
#
# Скрипт открытый, код — из закрытого репозитория по токену только на чтение
# (спрашивается скрытым вводом или берётся из EDAPHIA_GIT_TOKEN). Что делает:
#   1. проверяет root, ОС (Ubuntu/Debian), архитектуру;
#   2. ставит недостающее: git, curl, python3, iptables, Docker (официальный
#      репозиторий docker.com) с compose, Node 22 (NodeSource), pnpm;
#   3. заводит системного пользователя edaphia (группа docker), код — /opt/edaphia;
#   4. спрашивает, куда выставить веб-интерфейс (адрес и порт), пишет
#      /etc/edaphia/stand.sh из шаблона (без tailscale; вход — по паролю);
#   5. от имени edaphia: сборка, образы, тома, контур, мастер-ключ (копию — вам),
#      логин и пароль оператора, ключи API, проверки (scripts/install.sh);
#   6. по вопросу — правило хоста Q74: контейнерам закрыт вход на сам сервер
#      (iptables, служба edaphia-hostguard; sshd не трогается).
#
# Повторный запуск — обновление: код подтягивается по токену, устаревшие
# сервисы пересобираются и пересоздаются, данные и ключи остаются.
#
# Переменные (необязательно): EDAPHIA_GIT_TOKEN, EDAPHIA_REPO
# (https://github.com/zqpmv/edaphia.git), EDAPHIA_BRANCH (master),
# EDAPHIA_DIR (/opt/edaphia), EDAPHIA_UI_BIND, EDAPHIA_UI_PORT (8787),
# EDAPHIA_VIEW_PORT (8790), EDAPHIA_HOSTGUARD (yes|no).
set -Eeuo pipefail

REPO="${EDAPHIA_REPO:-https://github.com/zqpmv/edaphia.git}"
BRANCH="${EDAPHIA_BRANCH:-master}"
DIR="${EDAPHIA_DIR:-/opt/edaphia}"
APP_USER=edaphia
APP_HOME=/var/lib/edaphia
CONF_DIR=/etc/edaphia
STAND_FILE="$CONF_DIR/stand.sh"
NODE_MAJOR=22
PNPM_VERSION=10.15.1

STEP="начало"
trap 'echo; echo "install-edaphia: шаг «$STEP» не прошёл (строка $LINENO). Повторный запуск продолжит с того же места." >&2' ERR

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; STEP="$*"; }
ok() { printf '  \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mвнимание\033[0m %s\n' "$*"; }
die() { printf '\033[31minstall-edaphia: %s\033[0m\n' "$*" >&2; exit 1; }
as_app() { runuser -u "$APP_USER" -- "$@"; }

# Вопросы — с терминала: stdin занят трубой curl.
TTY=/dev/tty
ask() { # $1 вопрос, $2 по умолчанию → ответ в REPLY
  local answer
  if [ -r "$TTY" ]; then read -r -p "  $1${2:+ [$2]}: " answer <"$TTY" || true; fi
  REPLY="${answer:-${2:-}}"
}
ask_secret() { # $1 вопрос → REPLY
  [ -r "$TTY" ] || die "нужен терминал для скрытого ввода ($1) — или переменная окружения"
  IFS= read -r -s -p "  $1: " REPLY <"$TTY"; echo
}

case "${1:-}" in
  -h|--help) sed -n '2,28p' "$0" 2>/dev/null || true; exit 0 ;;
  "") ;;
  *) die "неизвестный аргумент: $1 (--help)" ;;
esac

# ── 1. root, ОС ─────────────────────────────────────────────────────────────
say "Проверка системы"
[ "$(id -u)" = 0 ] || die "нужен root: curl … | sudo bash"
[ -r /etc/os-release ] || die "нет /etc/os-release — поддерживаются Ubuntu и Debian"
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
  ubuntu:*|debian:*|*:*debian*) ok "ОС: ${PRETTY_NAME:-$ID}" ;;
  *) die "ОС ${PRETTY_NAME:-$ID} не поддерживается — Ubuntu или Debian" ;;
esac
case "$(uname -m)" in x86_64|aarch64) ok "архитектура $(uname -m)" ;; *) die "архитектура $(uname -m) не поддерживается" ;; esac
mem_mib=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem_mib" -ge 8000 ] && ok "память ${mem_mib} МиБ" || warn "памяти ${mem_mib} МиБ — меньше 8 ГиБ, сборка и прогоны могут не уместиться"
disk_gib=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "$disk_gib" -ge 40 ] && ok "свободно на / ${disk_gib} ГиБ" || warn "на / свободно ${disk_gib} ГиБ — нужно 40+ (образы, сборки)"

# ── 2. пакеты, Docker, Node ─────────────────────────────────────────────────
say "Пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git python3 iptables >/dev/null
ok "ca-certificates, curl, gnupg, git, python3, iptables"

say "Docker"
if command -v docker >/dev/null 2>&1; then
  ok "уже стоит: $(docker --version)"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  ok "поставлен: $(docker --version)"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker info >/dev/null 2>&1 || die "демон Docker не отвечает"
docker compose version >/dev/null 2>&1 || { apt-get install -y -qq docker-compose-plugin >/dev/null; }
ok "docker compose $(docker compose version --short)"

say "Node.js $NODE_MAJOR и pnpm"
if command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]')" = "$NODE_MAJOR" ]; then
  ok "уже стоит: Node $(node -v)"
else
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
  ok "поставлен: Node $(node -v)"
fi
if ! command -v pnpm >/dev/null 2>&1 || [ "$(pnpm -v)" != "$PNPM_VERSION" ]; then
  npm install -g --silent "pnpm@$PNPM_VERSION" >/dev/null
fi
ok "pnpm $(pnpm -v)"

# ── 3. пользователь и код ───────────────────────────────────────────────────
say "Пользователь $APP_USER и код"
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$APP_HOME" --shell /bin/bash "$APP_USER"
  ok "создан пользователь $APP_USER (домашний каталог $APP_HOME)"
fi
usermod -aG docker "$APP_USER"
install -d -o "$APP_USER" -g "$APP_USER" "$DIR"

if [ -z "${EDAPHIA_GIT_TOKEN:-}" ]; then
  echo "  Код edaphia — в закрытом репозитории $REPO."
  echo "  Нужен токен только на чтение (GitHub: fine-grained, Contents: Read-only)."
  ask_secret "токен (ввод скрыт)"
  EDAPHIA_GIT_TOKEN="$REPLY"
fi
[ -n "$EDAPHIA_GIT_TOKEN" ] || die "без токена код не получить"
export EDAPHIA_GIT_TOKEN
# Токен — только из окружения: в argv git попадает строка помощника с
# «$EDAPHIA_GIT_TOKEN», не значение; в .git/config не пишется.
GIT_AUTH=(-c credential.helper= -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$EDAPHIA_GIT_TOKEN"; }; f')
FRESH_CODE=0
if [ -d "$DIR/.git" ]; then
  as_app git -C "$DIR" "${GIT_AUTH[@]}" fetch --quiet "$REPO" "$BRANCH" || die "git fetch не прошёл — токен или доступ к $REPO"
  if [ -n "$(as_app git -C "$DIR" status --porcelain)" ]; then die "в $DIR незакоммиченные правки — обновление их не трогает"; fi
  as_app git -C "$DIR" merge --ff-only --quiet FETCH_HEAD || die "в $DIR коммиты, которых нет в $REPO — обновление только fast-forward"
  ok "код обновлён: $(as_app git -C "$DIR" log -1 --format='%h %s' | cut -c1-80)"
else
  as_app git "${GIT_AUTH[@]}" clone --quiet --branch "$BRANCH" "$REPO" "$DIR" || die "git clone не прошёл — токен или доступ к $REPO"
  FRESH_CODE=1
  ok "код получен: $(as_app git -C "$DIR" log -1 --format='%h %s' | cut -c1-80)"
fi
unset EDAPHIA_GIT_TOKEN

# ── 4. куда выставить веб-интерфейс ─────────────────────────────────────────
say "Веб-интерфейс"
install -d -m 0755 "$CONF_DIR"
primary_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
if [ -f "$STAND_FILE" ] && [ -z "${EDAPHIA_UI_BIND:-}" ]; then
  ok "конфигурация есть: $STAND_FILE — не меняю (удалите файл, чтобы спросить заново)"
else
  echo "  Адреса этой машины:"
  ip -4 -o addr show scope global | awk '{print "    " $4 " (" $2 ")"}'
  echo "    127.0.0.1 — только с этой машины (дальше — свой прокси: tailscale, netbird, nginx)"
  echo "    0.0.0.0   — на всех адресах"
  bind="${EDAPHIA_UI_BIND:-}"; [ -n "$bind" ] || { ask "на каком адресе слушать UI" "${primary_ip:-127.0.0.1}"; bind="$REPLY"; }
  ui_port="${EDAPHIA_UI_PORT:-}"; [ -n "$ui_port" ] || { ask "порт UI" "8787"; ui_port="$REPLY"; }
  view_port="${EDAPHIA_VIEW_PORT:-}"; [ -n "$view_port" ] || { ask "порт просмотра приложений (deploy-view)" "8790"; view_port="$REPLY"; }
  [[ "$ui_port" =~ ^[0-9]+$ && "$view_port" =~ ^[0-9]+$ ]] || die "порт — число"
  host="$bind"; [ "$bind" = 0.0.0.0 ] && host="${primary_ip:-127.0.0.1}"
  sed -e "s|@UI_BIND@|$bind|g" -e "s|@UI_PORT@|$ui_port|g" -e "s|@VIEW_PORT@|$view_port|g" -e "s|@UI_HOST@|$host|g" \
    "$DIR/deploy/stand/default.sh.template" >"$STAND_FILE.tmp"
  ! grep -q '@[A-Z_]*@' "$STAND_FILE.tmp" || die "в шаблоне остались неподставленные поля"
  chmod 0644 "$STAND_FILE.tmp"; mv "$STAND_FILE.tmp" "$STAND_FILE"
  ok "записано $STAND_FILE: UI http://$host:$ui_port, просмотр http://$host:$view_port"
fi

# ── 5. установка от имени edaphia ───────────────────────────────────────────
say "Установка (сборка, контур, ключи, проверки — от имени $APP_USER)"
as_app mkdir -p "$APP_HOME/.config/edaphia"
as_app bash -c "printf '{\"home\":\"%s\",\"repo\":\"%s\",\"branch\":\"%s\",\"stand\":\"%s\"}\n' '$DIR' '$REPO' '$BRANCH' '$STAND_FILE' >'$APP_HOME/.config/edaphia/config.json'"
ln -sf "$DIR/scripts/edaphia.mjs" /usr/local/bin/edaphia
running=$(docker ps -q --filter label=com.docker.compose.project=edaphia | head -1)
cd "$DIR"
if [ -n "$running" ] && [ "$FRESH_CODE" = 0 ]; then
  # Стенд уже стоит — обновление: сборка и пересоздание устаревшего.
  as_app env EDAPHIA_STAND="$STAND_FILE" bash -c "cd '$DIR' && pnpm install --frozen-lockfile --silent && pnpm build >/dev/null && node scripts/edaphia.mjs upgrade --no-fetch" <"$TTY"
else
  as_app env EDAPHIA_STAND="$STAND_FILE" "$DIR/scripts/install.sh" <"$TTY" || warn "install.sh закончил с замечаниями — выше список; повторный запуск продолжит"
fi

# ── 6. правило хоста Q74 ────────────────────────────────────────────────────
say "Правило хоста (Q74)"
cat <<'EOF'
  Код модели исполняется в контейнерах. Правило закрывает им вход на сам
  сервер (sshd, базы и прочие службы хоста), трафик наружу не трогает.
  Только iptables, sshd и ufw не меняются.
EOF
guard="${EDAPHIA_HOSTGUARD:-}"; [ -n "$guard" ] || { ask "включить правило? [да/нет]" "да"; guard="$REPLY"; }
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
    ok "правило действует: к хосту из сетей стенда закрыто, наружу открыто"
  else
    warn "проба правила не совпала — /tmp/edaphia-q74.txt"
  fi
else
  warn "правило не включено: bash модели сможет достучаться до служб этого сервера"
fi

# ── итог ────────────────────────────────────────────────────────────────────
say "Готово"
. "$STAND_FILE"
echo "  Веб-интерфейс:  $EDAPHIA_UI_URL  (вход — логин и пароль оператора)"
echo "  Конфигурация:   $STAND_FILE"
echo "  Команда:        sudo -u $APP_USER edaphia status | doctor | upgrade | secrets"
echo "  Обновление:     тот же curl … | sudo bash"
echo "  Подключить tailscale, netbird или свой прокси — README, «Вход через прокси»."
