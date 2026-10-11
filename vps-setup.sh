#!/usr/bin/env bash
# =============================================================================
#  VPS setup for tunnels. At start the script asks what to install:
#    1) All: VPN (TUIC v5) + fail2ban + Telegram MTProto
#    2) VPN (TUIC v5) + fail2ban
#    3) Telegram MTProto + fail2ban
#    4) fail2ban only
#
#  Steps:
#    1. non-interactive apt update && apt upgrade
#    2. install curl
#    3. TUIC v5 (built-in installer) + guest links
#    4. fail2ban (interactive)
#    5. Telegram MTProto proxy (mtg, FakeTLS)
#
#  Usage:   sudo bash vps-setup.sh [flags]
#  Flags:   --mode all|vpn|mtproto|f2b   what to install (no flag = menu)
#           --skip-upgrade        skip apt upgrade
#           --name NAME           short server name in links: NAME_guest_N
#           --guests N            number of TUIC guest links (default 10)
#           --tuic-version TAG    tuic-server version (default: latest)
#           --tuic-binary PATH    use own tuic-server binary (no download)
#           --mtg-version TAG     mtg version (default: latest)
#
#  Binaries come from releases of github.com/etjec4/tuic and github.com/9seconds/mtg.
#  TUIC source can be changed with TUIC_REPO=owner/repo.
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
    --mode)         MODE="${2:?value required}"; shift ;;
    --skip-upgrade) SKIP_UPGRADE=1 ;;
    --name)         SERVER_NAME="${2:?value required}"; shift ;;
    --guests)       GUESTS="${2:?value required}"; shift ;;
    --tuic-version) TUIC_VERSION="${2:?value required}"; shift ;;
    --tuic-binary)  TUIC_BINARY="${2:?value required}"; shift ;;
    --mtg-version)  MTG_VERSION="${2:?value required}"; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

[[ "$GUESTS" =~ ^[0-9]+$ ]] && (( GUESTS >= 1 )) || { echo "--guests: number >= 1 required"; exit 1; }
[[ -z "$MODE" || "$MODE" =~ ^(all|vpn|mtproto|f2b)$ ]] || { echo "--mode: all | vpn | mtproto | f2b"; exit 1; }

# ---------- вывод ----------
c_green='\033[1;32m'; c_yellow='\033[1;33m'; c_red='\033[1;31m'; c_blue='\033[1;34m'; c_off='\033[0m'
step() { echo -e "\n${c_blue}==> $*${c_off}"; }
ok()   { echo -e "${c_green}[ok]${c_off} $*"; }
warn() { echo -e "${c_yellow}[!]${c_off} $*"; }
die()  { echo -e "${c_red}[x]${c_off} $*" >&2; exit 1; }
trap 'die "Error at line $LINENO: $BASH_COMMAND"' ERR

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
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
command -v apt-get >/dev/null || die "Debian/Ubuntu (apt) required."
[[ -t 0 || -e /dev/tty ]] || die "Interactive terminal required."

# =============================================================================
# 0. Что ставим
# =============================================================================
if [[ -z "$MODE" ]]; then
  echo
  echo "What to install?"
  echo "  1) All: VPN (TUIC) + fail2ban + Telegram MTProto"
  echo "  2) VPN (TUIC) + fail2ban"
  echo "  3) Telegram MTProto + fail2ban"
  echo "  4) fail2ban only"
  while :; do
    case "$(ask "Choice" "1")" in
      1) MODE=all ;;
      2) MODE=vpn ;;
      3) MODE=mtproto ;;
      4) MODE=f2b ;;
      *) warn "Enter a number from 1 to 4"; continue ;;
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
ok "Installing: $plan"

# =============================================================================
# 1. Обновление системы без диалогов
# =============================================================================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a          # Ubuntu 22.04+: не спрашивать про перезапуск сервисов
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

step "Updating package lists"
apt-get update -q

if (( ! SKIP_UPGRADE )); then
  step "Upgrading system (apt upgrade)"
  apt-get "${APT_OPTS[@]}" upgrade
  apt-get "${APT_OPTS[@]}" autoremove
  ok "System upgraded"
fi

# =============================================================================
# 2. curl (+ jq, openssl, tar — нужны TUIC и mtg)
# =============================================================================
step "Installing curl, jq, openssl"
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
    *) die "Architecture $(uname -m) is not supported by TUIC" ;;
  esac
}

tuic_uninstall() {
  systemctl disable --now tuic >/dev/null 2>&1 || true
  pkill -x tuic-server 2>/dev/null || true   # -x: точное имя процесса, не задевает сам скрипт
  rm -f "$TUIC_SERVICE"
  rm -rf "$TUIC_DIR"
  systemctl daemon-reload
}

tuic_get_binary() {  # кладёт бинарник в $TUIC_DIR/tuic-server
  local dst="$TUIC_DIR/tuic-server"
  if [[ -n "$TUIC_BINARY" ]]; then
    [[ -f "$TUIC_BINARY" ]] || die "File $TUIC_BINARY not found"
    install -m 755 "$TUIC_BINARY" "$dst"
    ok "Using own binary: $TUIC_BINARY"
    return
  fi
  if [[ -z "$TUIC_VERSION" ]]; then
    TUIC_VERSION="$(latest_tag "$TUIC_REPO")" || true
    [[ -n "$TUIC_VERSION" ]] || die "Could not get TUIC version (GitHub API limit?). Use --tuic-version TAG"
  fi
  local url="https://github.com/$TUIC_REPO/releases/download/$TUIC_VERSION/$TUIC_VERSION-$(tuic_arch)"
  echo "Downloading $url"
  curl -fL --retry 3 -o "$dst.tmp" "$url" || die "Failed to download tuic-server"
  is_elf "$dst.tmp" || { rm -f "$dst.tmp"; die "Downloaded file is not a binary"; }
  mv "$dst.tmp" "$dst"; chmod 755 "$dst"
  ok "tuic-server $TUIC_VERSION"
}

tuic_install() {
  if [[ -d "$TUIC_DIR" ]]; then
    echo "TUIC is already installed in $TUIC_DIR."
    echo "  1) Reinstall   2) Keep as is   3) Remove"
    case "$(ask "Choice" "2")" in
      1) tuic_uninstall ;;
      3) tuic_uninstall; ok "TUIC removed"; return ;;
      *) ok "Keeping current installation"; return ;;
    esac
  fi

  mkdir -p "$TUIC_DIR"; chmod 700 "$TUIC_DIR"
  tuic_get_binary

  # Порт
  local port
  while :; do
    port="$(ask "TUIC port (UDP)" "$(shuf -i 10000-65000 -n 1)")"
    is_port "$port" || { warn "Invalid port"; continue; }
    udp_busy "$port" && { warn "UDP port $port is already in use"; continue; }
    break
  done

  # Имя сервера — идёт в название ссылок: <name>_guest_N
  # Можно задать флагом --name, иначе спрашиваем. Подсказка — короткий hostname.
  local server_name="$SERVER_NAME" def_name
  def_name="$(hostname -s | tr -cd 'A-Za-z0-9._-' | cut -c1-12)"
  def_name="${def_name:-vps}"
  while :; do
    [[ -z "$server_name" ]] && server_name="$(ask "Short server name for links (up to 20 chars)" "$def_name")"
    server_name="${server_name// /_}"
    if [[ ! "$server_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      warn "Only latin letters, digits and . _ - are allowed"
    elif (( ${#server_name} > 20 )); then
      warn "Too long: ${#server_name} chars, max 20"
    else
      break
    fi
    server_name=""
  done
  ok "Link name: ${server_name}_guest_N"

  # Гостевые пользователи: случайные UUID и пароли
  local users_json="{}" i
  local -a g_uuid=() g_pass=()
  for (( i = 1; i <= GUESTS; i++ )); do
    g_uuid[i]="$(cat /proc/sys/kernel/random/uuid)"
    g_pass[i]="$(openssl rand -hex 12)"
    users_json="$(jq -c --arg u "${g_uuid[i]}" --arg p "${g_pass[i]}" '. + {($u): $p}' <<<"$users_json")"
  done
  ok "Guest users generated: $GUESTS"

  # Самоподписанный сертификат
  local cn; cn="$(ask "Certificate CN" "bing.com")"
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
    ok "tuic service is running"
  else
    warn "tuic service failed to start: journalctl -u tuic -n 50"
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
  step "Installing TUIC v5"
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
step "Installing fail2ban"

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
echo " fail2ban setup"
echo " Bans apply ONLY to protected ports (SSH)."
echo " Ports from the exclusion list are never touched by fail2ban."
echo "------------------------------------------------------------"

while :; do
  SSH_PORTS="$(normalize_ports "$(ask "SSH port(s) to protect" "$SSH_PORT_DETECTED")")"
  [[ "$SSH_PORTS" == BAD:* ]] && { warn "Invalid port: ${SSH_PORTS#BAD:}"; continue; }
  [[ -n "$SSH_PORTS" ]] && break
  warn "At least one port is required."
done

# --- порты-исключения ---
EXCL_DEFAULT="$(echo "$TUIC_PORT $MTG_PORT" | xargs | tr ' ' ',')"
[[ -n "$TUIC_PORT" ]] && echo "Found TUIC port: $TUIC_PORT"
[[ -n "$MTG_PORT" ]]  && echo "Found MTProto port: $MTG_PORT"
(( DO_MTG )) && echo "The MTProto port chosen later will be added to exclusions automatically."
while :; do
  EXCLUDED="$(ask "Ports fail2ban must NOT touch (comma-separated, Enter to skip)" "$EXCL_DEFAULT")"
  if [[ -z "$EXCLUDED" ]]; then break; fi
  EXCLUDED="$(normalize_ports "$EXCLUDED")"
  [[ "$EXCLUDED" == BAD:* ]] && { warn "Invalid port: ${EXCLUDED#BAD:}"; continue; }
  break
done

# Пересечение: порт не может быть одновременно защищаемым и исключённым
if [[ -n "$EXCLUDED" ]]; then
  conflict=""
  IFS=, read -ra _ssh <<<"$SSH_PORTS"
  IFS=, read -ra _ex  <<<"$EXCLUDED"
  for s in "${_ssh[@]}"; do for e in "${_ex[@]}"; do [[ "$s" == "$e" ]] && conflict+="$s "; done; done
  if [[ -n "$conflict" ]]; then
    warn "Port(s) ${conflict}are in both lists — removing them from protection."
    filtered=()
    for s in "${_ssh[@]}"; do [[ " $conflict " == *" $s "* ]] || filtered+=("$s"); done
    SSH_PORTS="$(IFS=,; echo "${filtered[*]}")"
    [[ -n "$SSH_PORTS" ]] || die "No ports left to protect — nothing to configure for fail2ban."
  fi
fi

# --- параметры банов ---
while :; do MAXRETRY="$(ask "Failed attempts before ban" "5")"; [[ "$MAXRETRY" =~ ^[0-9]+$ ]] && break; warn "Number required"; done
FINDTIME="$(ask "Attempt counting window (e.g. 10m, 1h)" "10m")"
BANTIME="$(ask "Ban duration (e.g. 1h, 1d, -1 = forever)" "1h")"

INCREMENT="false"
if [[ "$BANTIME" != "-1" ]] && ask_yn "Increase ban time for repeat offenders?" y; then
  INCREMENT="true"
fi

# --- белый список IP ---
MY_IP="$(echo "${SSH_CLIENT:-}" | awk '{print $1}')"
echo "IPs that are never banned (space-separated). Better add your own IP."
[[ -n "$MY_IP" ]] && echo "Your current IP: $MY_IP"
WHITELIST="$(ask "IP/subnet whitelist" "${MY_IP}")"
IGNOREIP="127.0.0.1/8 ::1 ${WHITELIST//,/ }"

# --- конфиг ---
[[ -f "$JAIL_FILE" ]] && cp "$JAIL_FILE" "${JAIL_FILE}.bak.$(date +%s)"

cat > "$JAIL_FILE" <<EOF
# Generated by vps-setup.sh $(date '+%F %T')
# Excluded ports (not blocked by fail2ban): ${EXCLUDED:-none}

[DEFAULT]
ignoreip  = ${IGNOREIP}
bantime   = ${BANTIME}
findtime  = ${FINDTIME}
maxretry  = ${MAXRETRY}
backend   = ${F2B_BACKEND}
# multiport: ban applies only to this jail's ports, not the whole server
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
  warn "defaults-debian.conf disabled (it banned all ports)."
fi

step "Checking config and starting fail2ban"
fail2ban-client -t >/dev/null || die "fail2ban config is invalid: fail2ban-client -t"
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 2
fail2ban-client status sshd || warn "sshd jail failed to start: journalctl -u fail2ban -n 50"

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
    *) die "Architecture $(uname -m) is not supported by mtg" ;;
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
    [[ -n "$MTG_VERSION" ]] || die "Could not get mtg version (GitHub API limit?). Use --mtg-version TAG"
  fi
  local ver="${MTG_VERSION#v}" tmp bin
  local url="https://github.com/$MTG_REPO/releases/download/v$ver/mtg-$ver-linux-$(mtg_arch).tar.gz"
  tmp="$(mktemp -d)"
  echo "Downloading $url"
  curl -fL --retry 3 -o "$tmp/mtg.tar.gz" "$url" || { rm -rf "$tmp"; die "Failed to download mtg"; }
  tar -xzf "$tmp/mtg.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "Failed to extract mtg archive"; }
  bin="$(find "$tmp" -type f -name mtg -print -quit)"
  [[ -n "$bin" ]] && is_elf "$bin" || { rm -rf "$tmp"; die "No mtg binary in archive"; }
  install -m 755 "$bin" "$MTG_BIN"
  rm -rf "$tmp"
  ok "mtg $ver"
}

mtg_install() {
  if [[ -f "$MTG_CONFIG" ]]; then
    echo "MTProto proxy is already installed ($MTG_CONFIG)."
    echo "  1) Reinstall   2) Keep as is   3) Remove"
    case "$(ask "Choice" "2")" in
      1) mtg_uninstall ;;
      3) mtg_uninstall; ok "MTProto proxy removed"; return ;;
      *) ok "Keeping current installation"; return ;;
    esac
  fi

  mtg_get_binary

  # Отдельный системный пользователь — прокси не работает от root
  id -u mtg >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin mtg

  # Порт: 443 выглядит как обычный HTTPS, берём его, если свободен
  local port def_port=443
  if tcp_busy 443; then
    def_port="$(shuf -i 10000-65000 -n 1)"
    warn "TCP 443 is in use — suggesting a random port"
  fi
  while :; do
    port="$(ask "MTProto port (TCP)" "$def_port")"
    is_port "$port" || { warn "Invalid port"; continue; }
    tcp_busy "$port" && { warn "TCP port $port is already in use"; continue; }
    [[ ",$SSH_PORTS," == *",$port,"* ]] && { warn "This is the SSH port"; continue; }
    break
  done

  # Домен для маскировки FakeTLS: трафик выглядит как HTTPS к этому сайту
  local domain
  while :; do
    domain="$(ask "FakeTLS camouflage domain" "www.google.com")"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
    warn "A domain name is required, e.g. www.google.com"
  done

  local secret
  secret="$("$MTG_BIN" generate-secret --hex "$domain")"
  [[ "$secret" == ee* ]] || die "Failed to generate mtg secret"

  mkdir -p "$MTG_DIR"
  cat > "$MTG_CONFIG" <<EOF
# Generated by vps-setup.sh $(date '+%F %T')
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
    ok "mtg service is running"
  else
    warn "mtg service failed to start: journalctl -u mtg -n 50"
  fi

  # Ссылки: t.me (открывается откуда угодно) и tg:// (сразу в приложении)
  get_public_ip
  "$MTG_BIN" access -i "$PUBLIC_IP" "$MTG_CONFIG" | jq -r '.ipv4.tme_url, .ipv4.tg_url' > "$MTG_LINKS"
  chmod 600 "$MTG_LINKS"
  MTG_PORT="$port"
}

if (( DO_MTG )); then
  step "Installing Telegram MTProto proxy"
  mtg_install

  # Добавляем порт MTProto в список исключений fail2ban
  if [[ -n "$MTG_PORT" && ",$EXCLUDED," != *",$MTG_PORT,"* ]]; then
    EXCLUDED="${EXCLUDED:+$EXCLUDED,}$MTG_PORT"
    sed -i "s|^# Excluded ports.*|# Excluded ports (not blocked by fail2ban): $EXCLUDED|" "$JAIL_FILE"
  fi
fi

# =============================================================================
# Итог
# =============================================================================
echo
echo -e "${c_green}================= Done =================${c_off}"
if (( DO_TUIC )) && [[ -n "$TUIC_PORT" ]]; then
  echo " TUIC:         port $TUIC_PORT/udp, config $TUIC_CONFIG"
  [[ -s "$TUIC_LINKS" ]] && echo "               links: $TUIC_LINKS"
fi
if (( DO_MTG )) && [[ -n "$MTG_PORT" ]]; then
  echo " MTProto:      port $MTG_PORT/tcp, config $MTG_CONFIG"
  [[ -s "$MTG_LINKS" ]] && echo "               links: $MTG_LINKS"
fi
echo " fail2ban:     protects SSH on ${SSH_PORTS}/tcp"
echo " Excluded:     ${EXCLUDED:-none}"
echo " Ban:          ${MAXRETRY} attempts in ${FINDTIME} -> ${BANTIME} (increment: ${INCREMENT})"
echo " Whitelist:    ${IGNOREIP}"
echo " Config:       $JAIL_FILE"
echo
echo " Useful:"
echo "   fail2ban-client status sshd           # who is banned"
echo "   fail2ban-client set sshd unbanip IP   # unban"
(( DO_MTG )) && echo "   mtg access $MTG_CONFIG     # show MTProto links again"
if [[ -f /var/run/reboot-required ]]; then
  echo
  warn "Reboot required after upgrade: reboot"
fi

# Ссылки для клиентов — последним блоком, чтобы было удобно копировать
if (( DO_TUIC )) && [[ -s "$TUIC_LINKS" ]]; then
  echo
  echo -e "${c_green}============ TUIC links ============${c_off}"
  echo
  sed 'G' "$TUIC_LINKS"
fi
if (( DO_MTG )) && [[ -s "$MTG_LINKS" ]]; then
  echo
  echo -e "${c_green}============ Telegram MTProto ============${c_off}"
  echo
  sed 'G' "$MTG_LINKS"
fi
