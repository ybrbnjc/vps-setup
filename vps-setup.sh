#!/usr/bin/env bash
# =============================================================================
#  Настройка VPS под туннели. В начале скрипт спрашивает, что ставить:
#    1) Всё: VPN (TUIC v5) + fail2ban + Telegram MTProto
#    2) VPN (TUIC v5) + fail2ban
#    3) Telegram MTProto + fail2ban
#    4) Только fail2ban
#
#  Шаги:
#    1. apt update && apt upgrade без диалогов
#    2. установка curl
#    3. TUIC v5 (встроенный установщик) + гостевые ссылки
#    4. fail2ban (интерактивно)
#    5. Telegram MTProto-прокси (mtg, FakeTLS)
#
#  Запуск:  sudo bash vps-setup.sh [флаги]
#  Флаги:   --mode all|vpn|mtproto|f2b   что ставить (без флага — меню)
#           --skip-upgrade        не делать apt upgrade
#           --name NAME           короткое имя сервера в ссылках: NAME_guest_N
#           --guests N            сколько гостевых ссылок TUIC (по умолчанию 10)
#           --tuic-version TAG    версия tuic-server (по умолчанию последняя)
#           --tuic-binary PATH    свой бинарник tuic-server (без скачивания)
#           --mtg-version TAG     версия mtg (по умолчанию последняя)
#
#  Бинарники берутся из релизов github.com/etjec4/tuic и github.com/9seconds/mtg.
#  Источник TUIC можно сменить переменной TUIC_REPO=owner/repo.
# =============================================================================
set -Eeuo pipefail

# ---------- TUIC ----------
TUIC_DIR="/root/tuic"
TUIC_CONFIG="$TUIC_DIR/config.json"
TUIC_SERVICE="/etc/systemd/system/tuic.service"
TUIC_REPO="${TUIC_REPO:-etjec4/tuic}"
TUIC_VERSION="${TUIC_VERSION:-}"
TUIC_BINARY=""
TUIC_LINKS="$TUIC_DIR/client-links.txt"
GUESTS=10
SERVER_NAME=""

# ---------- MTProto (mtg) ----------
MTG_REPO="9seconds/mtg"
MTG_VERSION="${MTG_VERSION:-}"
MTG_BIN="/usr/local/bin/mtg"
MTG_DIR="/etc/mtg"
MTG_CONFIG="$MTG_DIR/config.toml"
MTG_LINKS="$MTG_DIR/links.txt"
MTG_SERVICE="/etc/systemd/system/mtg.service"

# ---------- fail2ban ----------
JAIL_FILE="/etc/fail2ban/jail.d/10-vps-setup.local"

MODE=""
SKIP_UPGRADE=0
while (( $# )); do
  case "$1" in
    --mode)         MODE="${2:?нужно значение}"; shift ;;
    --skip-upgrade) SKIP_UPGRADE=1 ;;
    --name)         SERVER_NAME="${2:?нужно значение}"; shift ;;
    --guests)       GUESTS="${2:?нужно значение}"; shift ;;
    --tuic-version) TUIC_VERSION="${2:?нужно значение}"; shift ;;
    --tuic-binary)  TUIC_BINARY="${2:?нужно значение}"; shift ;;
    --mtg-version)  MTG_VERSION="${2:?нужно значение}"; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
  shift
done

[[ "$GUESTS" =~ ^[0-9]+$ ]] && (( GUESTS >= 1 )) || { echo "--guests: нужно число >= 1"; exit 1; }
[[ -z "$MODE" || "$MODE" =~ ^(all|vpn|mtproto|f2b)$ ]] || { echo "--mode: all | vpn | mtproto | f2b"; exit 1; }

# ---------- вывод ----------
c_green='\033[1;32m'; c_yellow='\033[1;33m'; c_red='\033[1;31m'; c_blue='\033[1;34m'; c_off='\033[0m'
step() { echo -e "\n${c_blue}==> $*${c_off}"; }
ok()   { echo -e "${c_green}[ok]${c_off} $*"; }
warn() { echo -e "${c_yellow}[!]${c_off} $*"; }
die()  { echo -e "${c_red}[x]${c_off} $*" >&2; exit 1; }
trap 'die "Ошибка в строке $LINENO: $BASH_COMMAND"' ERR

# ---------- ввод (читаем из терминала, даже если stdin занят) ----------
ask() {  # ask "Вопрос" "дефолт" -> echo ответ
  local prompt="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then
    read -r -p "$prompt [$def]: " ans </dev/tty || true
  else
    read -r -p "$prompt: " ans </dev/tty || true
  fi
  echo "${ans:-$def}"
}
ask_yn() {  # ask_yn "Вопрос" y|n
  local def="${2:-y}" ans hint="[Y/n]"
  [[ "$def" == "n" ]] && hint="[y/N]"
  read -r -p "$1 $hint: " ans </dev/tty || true
  ans="${ans:-$def}"
  [[ "${ans,,}" == y* || "${ans,,}" == д* ]]
}
is_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
tcp_busy() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }
udp_busy() { ss -Hlun "sport = :$1" 2>/dev/null | grep -q .; }
is_elf()   { [[ "$(head -c 4 "$1" | od -An -c | tr -d ' ')" == '177ELF' ]]; }

# Нормализует "22, 2222 80" -> "22,2222,80", проверяет каждый порт
normalize_ports() {
  local raw="$1" out=() p
  raw="${raw//,/ }"
  for p in $raw; do
    is_port "$p" || { echo "BAD:$p"; return; }
    out+=("$p")
  done
  (IFS=,; echo "${out[*]}")
}

# Публичный IPv4 — один раз на весь скрипт
PUBLIC_IP=""
get_public_ip() {
  [[ -n "$PUBLIC_IP" ]] && return
  PUBLIC_IP="$(curl -fs4 --max-time 5 https://api.ipify.org || true)"
  [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$(hostname -I | awk '{print $1}')"
}

# Последний релиз на GitHub: latest_tag owner/repo
latest_tag() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name // empty'
}

# ---------- проверки ----------
[[ $EUID -eq 0 ]] || die "Запусти от root: sudo bash $0"
command -v apt-get >/dev/null || die "Нужен Debian/Ubuntu (apt)."
[[ -t 0 || -e /dev/tty ]] || die "Нужен интерактивный терминал."

# =============================================================================
# 0. Что ставим
# =============================================================================
if [[ -z "$MODE" ]]; then
  echo
  echo "Что установить и настроить?"
  echo "  1) Всё: VPN (TUIC) + fail2ban + Telegram MTProto"
  echo "  2) VPN (TUIC) + fail2ban"
  echo "  3) Telegram MTProto + fail2ban"
  echo "  4) Только fail2ban"
  while :; do
    case "$(ask "Выбор" "1")" in
      1) MODE=all ;;
      2) MODE=vpn ;;
      3) MODE=mtproto ;;
      4) MODE=f2b ;;
      *) warn "Введи число от 1 до 4"; continue ;;
    esac
    break
  done
fi

DO_TUIC=0; DO_MTG=0
case "$MODE" in
  all)     DO_TUIC=1; DO_MTG=1 ;;
  vpn)     DO_TUIC=1 ;;
  mtproto) DO_MTG=1 ;;
esac

plan="fail2ban"
(( DO_TUIC )) && plan="VPN (TUIC) + $plan"
(( DO_MTG ))  && plan="$plan + Telegram MTProto"
ok "Ставлю: $plan"

# =============================================================================
# 1. Обновление системы без диалогов
# =============================================================================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a          # Ubuntu 22.04+: не спрашивать про перезапуск сервисов
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

step "Обновляю список пакетов"
apt-get update -q

if (( ! SKIP_UPGRADE )); then
  step "Обновляю систему (apt upgrade)"
  apt-get "${APT_OPTS[@]}" upgrade
  apt-get "${APT_OPTS[@]}" autoremove
  ok "Система обновлена"
fi

# =============================================================================
# 2. curl (+ jq, openssl, tar — нужны TUIC и mtg)
# =============================================================================
step "Ставлю curl, jq, openssl"
apt-get "${APT_OPTS[@]}" install curl jq openssl tar ca-certificates
ok "curl $(curl --version | head -1 | awk '{print $2}')"

# =============================================================================
# 3. TUIC v5
# =============================================================================
tuic_arch() {
  case "$(uname -m)" in
    x86_64)  echo "x86_64-unknown-linux-gnu" ;;
    i686)    echo "i686-unknown-linux-gnu" ;;
    armv7l)  echo "armv7-unknown-linux-gnueabi" ;;
    aarch64) echo "aarch64-unknown-linux-gnu" ;;
    *) die "Архитектура $(uname -m) не поддерживается TUIC" ;;
  esac
}

tuic_uninstall() {
  systemctl disable --now tuic >/dev/null 2>&1 || true
  pkill -f tuic-server 2>/dev/null || true
  rm -f "$TUIC_SERVICE"
  rm -rf "$TUIC_DIR"
  systemctl daemon-reload
}

tuic_get_binary() {  # кладёт бинарник в $TUIC_DIR/tuic-server
  local dst="$TUIC_DIR/tuic-server"
  if [[ -n "$TUIC_BINARY" ]]; then
    [[ -f "$TUIC_BINARY" ]] || die "Файл $TUIC_BINARY не найден"
    install -m 755 "$TUIC_BINARY" "$dst"
    ok "Использую свой бинарник: $TUIC_BINARY"
    return
  fi
  if [[ -z "$TUIC_VERSION" ]]; then
    TUIC_VERSION="$(latest_tag "$TUIC_REPO")" || true
    [[ -n "$TUIC_VERSION" ]] || die "Не удалось узнать версию TUIC (лимит GitHub API?). Укажи --tuic-version TAG"
  fi
  local url="https://github.com/$TUIC_REPO/releases/download/$TUIC_VERSION/$TUIC_VERSION-$(tuic_arch)"
  echo "Скачиваю $url"
  curl -fL --retry 3 -o "$dst.tmp" "$url" || die "Не удалось скачать tuic-server"
  is_elf "$dst.tmp" || { rm -f "$dst.tmp"; die "Скачанный файл не похож на бинарник"; }
  mv "$dst.tmp" "$dst"; chmod 755 "$dst"
  ok "tuic-server $TUIC_VERSION"
}

tuic_install() {
  if [[ -d "$TUIC_DIR" ]]; then
    echo "TUIC уже установлен в $TUIC_DIR."
    echo "  1) Переустановить   2) Оставить как есть   3) Удалить"
    case "$(ask "Выбор" "2")" in
      1) tuic_uninstall ;;
      3) tuic_uninstall; ok "TUIC удалён"; return ;;
      *) ok "Оставляю текущую установку"; return ;;
    esac
  fi

  mkdir -p "$TUIC_DIR"; chmod 700 "$TUIC_DIR"
  tuic_get_binary

  # Порт
  local port
  while :; do
    port="$(ask "Порт TUIC (UDP)" "$(shuf -i 10000-65000 -n 1)")"
    is_port "$port" || { warn "Некорректный порт"; continue; }
    udp_busy "$port" && { warn "UDP-порт $port уже занят"; continue; }
    break
  done

  # Имя сервера — идёт в название ссылок: <name>_guest_N
  # Можно задать флагом --name, иначе спрашиваем. Подсказка — короткий hostname.
  local server_name="$SERVER_NAME" def_name
  def_name="$(hostname -s | tr -cd 'A-Za-z0-9._-' | cut -c1-12)"
  def_name="${def_name:-vps}"
  while :; do
    [[ -z "$server_name" ]] && server_name="$(ask "Короткое имя сервера для ссылок (до 20 символов)" "$def_name")"
    server_name="${server_name// /_}"
    if [[ ! "$server_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      warn "Допустимы только латиница, цифры и . _ -"
    elif (( ${#server_name} > 20 )); then
      warn "Слишком длинное: ${#server_name} символов, максимум 20"
    else
      break
    fi
    server_name=""
  done
  ok "Имя в ссылках: ${server_name}_guest_N"

  # Гостевые пользователи: случайные UUID и пароли
  local users_json="{}" i
  local -a g_uuid=() g_pass=()
  for (( i = 1; i <= GUESTS; i++ )); do
    g_uuid[i]="$(cat /proc/sys/kernel/random/uuid)"
    g_pass[i]="$(openssl rand -hex 12)"
    users_json="$(jq -c --arg u "${g_uuid[i]}" --arg p "${g_pass[i]}" '. + {($u): $p}' <<<"$users_json")"
  done
  ok "Сгенерировано гостевых пользователей: $GUESTS"

  # Самоподписанный сертификат
  local cn; cn="$(ask "CN сертификата" "bing.com")"
  openssl ecparam -genkey -name prime256v1 -out "$TUIC_DIR/ca.key" 2>/dev/null
  openssl req -new -x509 -days 36500 -key "$TUIC_DIR/ca.key" -out "$TUIC_DIR/ca.crt" -subj "/CN=$cn" 2>/dev/null
  chmod 600 "$TUIC_DIR/ca.key"

  # Конфиг собираем через jq — гарантированно валидный JSON
  jq -n --arg port "$port" --argjson users "$users_json" --arg dir "$TUIC_DIR" '{
    server: "[::]:\($port)",
    users: $users,
    certificate: "\($dir)/ca.crt",
    private_key: "\($dir)/ca.key",
    congestion_control: "bbr",
    alpn: ["h3", "spdy/3.1"],
    udp_relay_ipv6: true,
    zero_rtt_handshake: false,
    dual_stack: true,
    auth_timeout: "3s",
    task_negotiation_timeout: "3s",
    max_idle_time: "10s",
    max_external_packet_size: 1500,
    gc_interval: "3s",
    gc_lifetime: "15s",
    log_level: "warn"
  }' > "$TUIC_CONFIG"
  chmod 600 "$TUIC_CONFIG"

  cat > "$TUIC_SERVICE" <<EOF
[Unit]
Description=TUIC v5 server
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=$TUIC_DIR
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$TUIC_DIR/tuic-server -c $TUIC_CONFIG
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now tuic >/dev/null 2>&1
  sleep 2
  if systemctl is-active --quiet tuic; then
    ok "Сервис tuic запущен"
  else
    warn "Сервис tuic не стартовал: journalctl -u tuic -n 50"
  fi

  # Ссылки для клиентов — сохраняем в файл, выводим в самом конце установки
  get_public_ip
  : > "$TUIC_LINKS"; chmod 600 "$TUIC_LINKS"
  for (( i = 1; i <= GUESTS; i++ )); do
    printf 'tuic://%s:%s@%s:%s/?congestion_control=bbr&udp_relay_mode=native&alpn=h3%%2Cspdy%%2F3.1&allow_insecure=1#%s_guest_%d\n' \
      "${g_uuid[i]}" "${g_pass[i]}" "$PUBLIC_IP" "$port" "$server_name" "$i" >> "$TUIC_LINKS"
  done
}

if (( DO_TUIC )); then
  step "Устанавливаю TUIC v5"
  tuic_install
fi

# Порты уже установленных сервисов (подсказка для исключений fail2ban)
TUIC_PORT=""
if [[ -f "$TUIC_CONFIG" ]]; then
  TUIC_PORT="$(jq -r '.server' "$TUIC_CONFIG" 2>/dev/null | sed 's/.*://')" || true
  is_port "${TUIC_PORT:-x}" || TUIC_PORT=""
fi
mtg_config_port() {
  [[ -f "$MTG_CONFIG" ]] || return 0
  sed -n 's/^bind-to *= *".*:\([0-9]*\)".*/\1/p' "$MTG_CONFIG" | head -1
}
MTG_PORT="$(mtg_config_port)"

# =============================================================================
# 4. fail2ban
# =============================================================================
step "Устанавливаю fail2ban"

# Где лежат логи SSH: если нет auth.log (Debian 12+) — читаем journald
if [[ -f /var/log/auth.log ]]; then
  F2B_BACKEND="auto"
  apt-get "${APT_OPTS[@]}" install fail2ban
else
  F2B_BACKEND="systemd"
  apt-get "${APT_OPTS[@]}" install fail2ban python3-systemd
fi

# Чем банить: nftables, если есть, иначе iptables
if command -v nft >/dev/null 2>&1; then
  F2B_BANACTION="nftables-multiport"
else
  apt-get "${APT_OPTS[@]}" install iptables
  F2B_BANACTION="iptables-multiport"
fi

# --- порт SSH ---
SSH_PORT_DETECTED="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | paste -sd, -)"
SSH_PORT_DETECTED="${SSH_PORT_DETECTED:-22}"

echo
echo "------------------------------------------------------------"
echo " Настройка fail2ban"
echo " Баны применяются ТОЛЬКО к защищаемым портам (SSH)."
echo " Порты из списка исключений fail2ban не трогает никогда."
echo "------------------------------------------------------------"

while :; do
  SSH_PORTS="$(normalize_ports "$(ask "Порт(ы) SSH для защиты" "$SSH_PORT_DETECTED")")"
  [[ "$SSH_PORTS" == BAD:* ]] && { warn "Некорректный порт: ${SSH_PORTS#BAD:}"; continue; }
  [[ -n "$SSH_PORTS" ]] && break
  warn "Нужен хотя бы один порт."
done

# --- порты-исключения ---
EXCL_DEFAULT="$(echo "$TUIC_PORT $MTG_PORT" | xargs | tr ' ' ',')"
[[ -n "$TUIC_PORT" ]] && echo "Найден порт TUIC: $TUIC_PORT"
[[ -n "$MTG_PORT" ]]  && echo "Найден порт MTProto: $MTG_PORT"
(( DO_MTG )) && echo "Порт MTProto, который будет выбран дальше, добавится в исключения автоматически."
while :; do
  EXCLUDED="$(ask "Порты, которые fail2ban трогать НЕ должен (через запятую, Enter — пропустить)" "$EXCL_DEFAULT")"
  if [[ -z "$EXCLUDED" ]]; then break; fi
  EXCLUDED="$(normalize_ports "$EXCLUDED")"
  [[ "$EXCLUDED" == BAD:* ]] && { warn "Некорректный порт: ${EXCLUDED#BAD:}"; continue; }
  break
done

# Пересечение: порт не может быть одновременно защищаемым и исключённым
if [[ -n "$EXCLUDED" ]]; then
  conflict=""
  IFS=, read -ra _ssh <<<"$SSH_PORTS"
  IFS=, read -ra _ex  <<<"$EXCLUDED"
  for s in "${_ssh[@]}"; do for e in "${_ex[@]}"; do [[ "$s" == "$e" ]] && conflict+="$s "; done; done
  if [[ -n "$conflict" ]]; then
    warn "Порт(ы) ${conflict}есть в обоих списках — убираю их из защиты."
    filtered=()
    for s in "${_ssh[@]}"; do [[ " $conflict " == *" $s "* ]] || filtered+=("$s"); done
    SSH_PORTS="$(IFS=,; echo "${filtered[*]}")"
    [[ -n "$SSH_PORTS" ]] || die "Не осталось портов для защиты — fail2ban настраивать нечего."
  fi
fi

# --- параметры банов ---
while :; do MAXRETRY="$(ask "Неудачных попыток до бана" "5")"; [[ "$MAXRETRY" =~ ^[0-9]+$ ]] && break; warn "Нужно число"; done
FINDTIME="$(ask "Окно подсчёта попыток (напр. 10m, 1h)" "10m")"
BANTIME="$(ask "Длительность бана (напр. 1h, 1d, -1 = навсегда)" "1h")"

INCREMENT="false"
if [[ "$BANTIME" != "-1" ]] && ask_yn "Увеличивать бан для повторных нарушителей?" y; then
  INCREMENT="true"
fi

# --- белый список IP ---
MY_IP="$(echo "${SSH_CLIENT:-}" | awk '{print $1}')"
echo "IP, которые никогда не банятся (через пробел). Свой IP лучше добавить."
[[ -n "$MY_IP" ]] && echo "Твой текущий IP: $MY_IP"
WHITELIST="$(ask "Белый список IP/подсетей" "${MY_IP}")"
IGNOREIP="127.0.0.1/8 ::1 ${WHITELIST//,/ }"

# --- конфиг ---
[[ -f "$JAIL_FILE" ]] && cp "$JAIL_FILE" "${JAIL_FILE}.bak.$(date +%s)"

cat > "$JAIL_FILE" <<EOF
# Сгенерировано vps-setup.sh $(date '+%F %T')
# Порты-исключения (fail2ban их не блокирует): ${EXCLUDED:-нет}

[DEFAULT]
ignoreip  = ${IGNOREIP}
bantime   = ${BANTIME}
findtime  = ${FINDTIME}
maxretry  = ${MAXRETRY}
backend   = ${F2B_BACKEND}
# multiport: бан действует только на порты конкретного jail, а не на весь сервер
banaction = ${F2B_BANACTION}
bantime.increment = ${INCREMENT}
bantime.maxtime   = 1w

[sshd]
enabled  = true
port     = ${SSH_PORTS}
protocol = tcp
EOF

# Отключаем дефолтный debian-конфиг, если он банит по всем портам
if [[ -f /etc/fail2ban/jail.d/defaults-debian.conf ]] && grep -q 'allports' /etc/fail2ban/jail.d/defaults-debian.conf; then
  mv /etc/fail2ban/jail.d/defaults-debian.conf /etc/fail2ban/jail.d/defaults-debian.conf.disabled
  warn "defaults-debian.conf отключён (там был бан по всем портам)."
fi

step "Проверяю конфиг и запускаю fail2ban"
fail2ban-client -t >/dev/null || die "Конфиг fail2ban некорректен: fail2ban-client -t"
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 2
fail2ban-client status sshd || warn "Jail sshd не поднялся: journalctl -u fail2ban -n 50"

# =============================================================================
# 5. Telegram MTProto-прокси (mtg, режим FakeTLS)
# =============================================================================
mtg_arch() {
  case "$(uname -m)" in
    x86_64)      echo "amd64" ;;
    aarch64)     echo "arm64" ;;
    armv7l)      echo "armv7" ;;
    armv6l)      echo "armv6" ;;
    i686|i386)   echo "386" ;;
    *) die "Архитектура $(uname -m) не поддерживается mtg" ;;
  esac
}

mtg_uninstall() {
  systemctl disable --now mtg >/dev/null 2>&1 || true
  rm -f "$MTG_SERVICE" "$MTG_BIN"
  rm -rf "$MTG_DIR"
  systemctl daemon-reload
  MTG_PORT=""
}

mtg_get_binary() {
  if [[ -z "$MTG_VERSION" ]]; then
    MTG_VERSION="$(latest_tag "$MTG_REPO")" || true
    [[ -n "$MTG_VERSION" ]] || die "Не удалось узнать версию mtg (лимит GitHub API?). Укажи --mtg-version TAG"
  fi
  local ver="${MTG_VERSION#v}" tmp bin
  local url="https://github.com/$MTG_REPO/releases/download/v$ver/mtg-$ver-linux-$(mtg_arch).tar.gz"
  tmp="$(mktemp -d)"
  echo "Скачиваю $url"
  curl -fL --retry 3 -o "$tmp/mtg.tar.gz" "$url" || { rm -rf "$tmp"; die "Не удалось скачать mtg"; }
  tar -xzf "$tmp/mtg.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "Не удалось распаковать архив mtg"; }
  bin="$(find "$tmp" -type f -name mtg -print -quit)"
  [[ -n "$bin" ]] && is_elf "$bin" || { rm -rf "$tmp"; die "В архиве нет бинарника mtg"; }
  install -m 755 "$bin" "$MTG_BIN"
  rm -rf "$tmp"
  ok "mtg $ver"
}

mtg_install() {
  if [[ -f "$MTG_CONFIG" ]]; then
    echo "MTProto-прокси уже установлен ($MTG_CONFIG)."
    echo "  1) Переустановить   2) Оставить как есть   3) Удалить"
    case "$(ask "Выбор" "2")" in
      1) mtg_uninstall ;;
      3) mtg_uninstall; ok "MTProto-прокси удалён"; return ;;
      *) ok "Оставляю текущую установку"; return ;;
    esac
  fi

  mtg_get_binary

  # Отдельный системный пользователь — прокси не работает от root
  id -u mtg >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin mtg

  # Порт: 443 выглядит как обычный HTTPS, берём его, если свободен
  local port def_port=443
  if tcp_busy 443; then
    def_port="$(shuf -i 10000-65000 -n 1)"
    warn "TCP 443 занят — предлагаю случайный порт"
  fi
  while :; do
    port="$(ask "Порт MTProto (TCP)" "$def_port")"
    is_port "$port" || { warn "Некорректный порт"; continue; }
    tcp_busy "$port" && { warn "TCP-порт $port уже занят"; continue; }
    [[ ",$SSH_PORTS," == *",$port,"* ]] && { warn "Это порт SSH"; continue; }
    break
  done

  # Домен для маскировки FakeTLS: трафик выглядит как HTTPS к этому сайту
  local domain
  while :; do
    domain="$(ask "Домен для маскировки FakeTLS" "www.google.com")"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
    warn "Нужно доменное имя, например www.google.com"
  done

  local secret
  secret="$("$MTG_BIN" generate-secret --hex "$domain")"
  [[ "$secret" == ee* ]] || die "Не удалось сгенерировать секрет mtg"

  mkdir -p "$MTG_DIR"
  cat > "$MTG_CONFIG" <<EOF
# Сгенерировано vps-setup.sh $(date '+%F %T')
secret    = "$secret"
bind-to   = "0.0.0.0:$port"
prefer-ip = "prefer-ipv4"
EOF
  chown root:mtg "$MTG_CONFIG"; chmod 640 "$MTG_CONFIG"

  cat > "$MTG_SERVICE" <<EOF
[Unit]
Description=Telegram MTProto proxy (mtg)
After=network-online.target
Wants=network-online.target

[Service]
User=mtg
Group=mtg
ExecStart=$MTG_BIN run $MTG_CONFIG
Restart=always
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now mtg >/dev/null 2>&1
  sleep 2
  if systemctl is-active --quiet mtg; then
    ok "Сервис mtg запущен"
  else
    warn "Сервис mtg не стартовал: journalctl -u mtg -n 50"
  fi

  # Ссылки: t.me (открывается откуда угодно) и tg:// (сразу в приложении)
  get_public_ip
  "$MTG_BIN" access -i "$PUBLIC_IP" "$MTG_CONFIG" | jq -r '.ipv4.tme_url, .ipv4.tg_url' > "$MTG_LINKS"
  chmod 600 "$MTG_LINKS"
  MTG_PORT="$port"
}

if (( DO_MTG )); then
  step "Устанавливаю Telegram MTProto-прокси"
  mtg_install

  # Добавляем порт MTProto в список исключений fail2ban
  if [[ -n "$MTG_PORT" && ",$EXCLUDED," != *",$MTG_PORT,"* ]]; then
    EXCLUDED="${EXCLUDED:+$EXCLUDED,}$MTG_PORT"
    sed -i "s|^# Порты-исключения.*|# Порты-исключения (fail2ban их не блокирует): $EXCLUDED|" "$JAIL_FILE"
  fi
fi

# =============================================================================
# Итог
# =============================================================================
echo
echo -e "${c_green}================= Готово =================${c_off}"
if (( DO_TUIC )) && [[ -n "$TUIC_PORT" ]]; then
  echo " TUIC:         порт $TUIC_PORT/udp, конфиг $TUIC_CONFIG"
  [[ -s "$TUIC_LINKS" ]] && echo "               ссылки: $TUIC_LINKS"
fi
if (( DO_MTG )) && [[ -n "$MTG_PORT" ]]; then
  echo " MTProto:      порт $MTG_PORT/tcp, конфиг $MTG_CONFIG"
  [[ -s "$MTG_LINKS" ]] && echo "               ссылки: $MTG_LINKS"
fi
echo " fail2ban:     защищает SSH на ${SSH_PORTS}/tcp"
echo " Исключения:   ${EXCLUDED:-нет}"
echo " Бан:          ${MAXRETRY} попыток за ${FINDTIME} -> ${BANTIME} (рост: ${INCREMENT})"
echo " Белый список: ${IGNOREIP}"
echo " Конфиг:       $JAIL_FILE"
echo
echo " Полезное:"
echo "   fail2ban-client status sshd           # кто забанен"
echo "   fail2ban-client set sshd unbanip IP   # разбанить"
(( DO_MTG )) && echo "   mtg access $MTG_CONFIG     # ссылки MTProto ещё раз"
if [[ -f /var/run/reboot-required ]]; then
  echo
  warn "После обновления нужна перезагрузка: reboot"
fi

# Ссылки для клиентов — последним блоком, чтобы было удобно копировать
if (( DO_TUIC )) && [[ -s "$TUIC_LINKS" ]]; then
  echo
  echo -e "${c_green}============ Ссылки TUIC ============${c_off}"
  echo
  sed 'G' "$TUIC_LINKS"
fi
if (( DO_MTG )) && [[ -s "$MTG_LINKS" ]]; then
  echo
  echo -e "${c_green}============ Telegram MTProto ============${c_off}"
  echo
  sed 'G' "$MTG_LINKS"
fi
