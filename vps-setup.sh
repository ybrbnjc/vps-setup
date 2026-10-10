#!/usr/bin/env bash
# =============================================================================
#  Настройка VPS под туннель:
#    1. apt update && apt upgrade без диалогов
#    2. установка curl
#    3. установка TUIC v5 (встроенный установщик, без внешних скриптов)
#    4. установка и интерактивная настройка fail2ban
#
#  Запуск:  sudo bash vps-setup.sh [флаги]
#  Флаги:   --skip-tuic           не ставить TUIC
#           --skip-upgrade        не делать apt upgrade
#           --tuic-version TAG    версия tuic-server (по умолчанию последняя)
#           --tuic-binary PATH    свой бинарник tuic-server (без скачивания)
#           --guests N            сколько гостевых ссылок создать (по умолчанию 10)
#           --name NAME           короткое имя сервера в ссылках: NAME_guest_N
#
#  Бинарник по умолчанию берётся из релизов github.com/etjec4/tuic.
#  Источник можно сменить переменной TUIC_REPO=owner/repo.
# =============================================================================
set -Eeuo pipefail

TUIC_DIR="/root/tuic"
TUIC_CONFIG="$TUIC_DIR/config.json"
TUIC_SERVICE="/etc/systemd/system/tuic.service"
TUIC_REPO="${TUIC_REPO:-etjec4/tuic}"
TUIC_VERSION="${TUIC_VERSION:-}"
TUIC_BINARY=""
TUIC_LINKS="$TUIC_DIR/client-links.txt"
GUESTS=10
SERVER_NAME=""
JAIL_FILE="/etc/fail2ban/jail.d/10-vps-setup.local"

SKIP_TUIC=0
SKIP_UPGRADE=0
while (( $# )); do
  case "$1" in
    --skip-tuic)    SKIP_TUIC=1 ;;
    --skip-upgrade) SKIP_UPGRADE=1 ;;
    --tuic-version) TUIC_VERSION="${2:?нужно значение}"; shift ;;
    --tuic-binary)  TUIC_BINARY="${2:?нужно значение}"; shift ;;
    --guests)       GUESTS="${2:?нужно значение}"; shift ;;
    --name)         SERVER_NAME="${2:?нужно значение}"; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
  shift
done

[[ "$GUESTS" =~ ^[0-9]+$ ]] && (( GUESTS >= 1 )) || { echo "--guests: нужно число >= 1"; exit 1; }

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

# ---------- проверки ----------
[[ $EUID -eq 0 ]] || die "Запусти от root: sudo bash $0"
command -v apt-get >/dev/null || die "Нужен Debian/Ubuntu (apt)."
[[ -t 0 || -e /dev/tty ]] || die "Нужен интерактивный терминал."

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
# 2. curl (+ jq и openssl для TUIC)
# =============================================================================
step "Ставлю curl, jq, openssl"
apt-get "${APT_OPTS[@]}" install curl jq openssl ca-certificates
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
    *) die "Архитектура $(uname -m) не поддерживается" ;;
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
    TUIC_VERSION="$(curl -fsSL "https://api.github.com/repos/$TUIC_REPO/releases/latest" | jq -r '.tag_name // empty')" || true
    [[ -n "$TUIC_VERSION" ]] || die "Не удалось узнать последнюю версию (лимит GitHub API?). Укажи --tuic-version TAG"
  fi
  local url="https://github.com/$TUIC_REPO/releases/download/$TUIC_VERSION/$TUIC_VERSION-$(tuic_arch)"
  echo "Скачиваю $url"
  curl -fL --retry 3 -o "$dst.tmp" "$url" || die "Не удалось скачать бинарник"
  # Проверка, что скачался ELF, а не HTML-страница с ошибкой
  [[ "$(head -c 4 "$dst.tmp" | od -An -c | tr -d ' ')" == '177ELF' ]] || { rm -f "$dst.tmp"; die "Скачанный файл не похож на бинарник"; }
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
    if ss -Hlun "sport = :$port" 2>/dev/null | grep -q .; then warn "UDP-порт $port уже занят"; continue; fi
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
  local ip; ip="$(curl -fs4 --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')"
  : > "$TUIC_LINKS"; chmod 600 "$TUIC_LINKS"
  for (( i = 1; i <= GUESTS; i++ )); do
    printf 'tuic://%s:%s@%s:%s/?congestion_control=bbr&udp_relay_mode=native&alpn=h3%%2Cspdy%%2F3.1&allow_insecure=1#%s_guest_%d\n' \
      "${g_uuid[i]}" "${g_pass[i]}" "$ip" "$port" "$server_name" "$i" >> "$TUIC_LINKS"
  done
}

if (( ! SKIP_TUIC )); then
  step "Устанавливаю TUIC v5"
  tuic_install
fi

# Порт TUIC из конфига (для подсказки в fail2ban)
TUIC_PORT=""
if [[ -f "$TUIC_CONFIG" ]]; then
  TUIC_PORT="$(jq -r '.server' "$TUIC_CONFIG" 2>/dev/null | sed 's/.*://')" || true
  is_port "${TUIC_PORT:-x}" || TUIC_PORT=""
fi

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
EXCL_DEFAULT="${TUIC_PORT}"
[[ -n "$TUIC_PORT" ]] && echo "Найден порт TUIC: $TUIC_PORT (предложен по умолчанию)."
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
while :; do MAXRETRY="$(ask "Неудачных попыток до бана" "5")";       [[ "$MAXRETRY" =~ ^[0-9]+$ ]] && break; warn "Нужно число"; done
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
# Итог
# =============================================================================
echo
echo -e "${c_green}================= Готово =================${c_off}"
[[ -n "$TUIC_PORT" ]] && echo " TUIC:        порт $TUIC_PORT/udp, конфиг $TUIC_CONFIG"
[[ -s "$TUIC_LINKS" ]] && echo " Ссылки:      $TUIC_LINKS"
echo " fail2ban:    защищает SSH на ${SSH_PORTS}/tcp"
echo " Исключения:  ${EXCLUDED:-нет}"
echo " Бан:         ${MAXRETRY} попыток за ${FINDTIME} -> ${BANTIME} (рост: ${INCREMENT})"
echo " Белый список: ${IGNOREIP}"
echo " Конфиг:      $JAIL_FILE"
echo
echo " Полезное:"
echo "   fail2ban-client status sshd           # кто забанен"
echo "   fail2ban-client set sshd unbanip IP   # разбанить"
if [[ -f /var/run/reboot-required ]]; then
  echo
  warn "После обновления нужна перезагрузка: reboot"
fi

# Ссылки для клиентов — последним блоком, чтобы было удобно копировать
if [[ -s "$TUIC_LINKS" ]]; then
  echo
  echo -e "${c_green}============ Ссылки для клиентов ============${c_off}"
  echo
  sed 'G' "$TUIC_LINKS"
fi
