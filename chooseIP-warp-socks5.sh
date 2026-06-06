#!/bin/sh
#
# Choose a Cloudflare WARP SOCKS5 exit country as reliably as WARP allows.
#
# Important:
#   Cloudflare WARP does not officially support selecting an exit country.
#   This script repeatedly rotates the WARP device/session and checks the
#   resulting exit IP country. It stops when TARGET_COUNTRY is reached.
#
# Usage:
#   TARGET_COUNTRY=MX sudo sh chooseIP-warp-socks5.sh
#   TARGET_COUNTRY=MX MAX_ATTEMPTS=30 sudo sh chooseIP-warp-socks5.sh choose
#   sudo sh chooseIP-warp-socks5.sh status
#   sudo sh chooseIP-warp-socks5.sh uninstall-timer

set -eu

SOCKS_HOST="127.0.0.1"
SOCKS_PORT="${SOCKS_PORT:-40000}"
TARGET_COUNTRY="${TARGET_COUNTRY:-MX}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
HARD_ROTATE_EVERY="${HARD_ROTATE_EVERY:-3}"
STATE_DIR="/var/lib/chooseip-warp-socks5"
STATE_FILE="$STATE_DIR/state"
LOG_FILE="/var/log/chooseip-warp-socks5.log"
SYSTEMD_SERVICE="/etc/systemd/system/chooseip-warp-socks5.service"
SYSTEMD_TIMER="/etc/systemd/system/chooseip-warp-socks5.timer"

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >/dev/null 2>&1 || true
}

say() {
  printf '%s\n' "$*"
  log "$*"
}

die() {
  say "ERROR: $*"
  exit 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo env TARGET_COUNTRY="$TARGET_COUNTRY" MAX_ATTEMPTS="$MAX_ATTEMPTS" HARD_ROTATE_EVERY="$HARD_ROTATE_EVERY" SOCKS_PORT="$SOCKS_PORT" sh "$0" "$@"
    fi
    die "Please run as root, or install sudo first."
  fi
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

normalize_country() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z'
}

detect_os() {
  [ -r /etc/os-release ] || die "Cannot detect Linux distribution: /etc/os-release is missing."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64|aarch64|arm64) ;;
    *) die "CPU architecture $ARCH may not be supported by the official cloudflare-warp package." ;;
  esac
}

is_debian_like() {
  case "$OS_ID $OS_ID_LIKE" in
    *debian*|*ubuntu*) return 0 ;;
    *) return 1 ;;
  esac
}

is_rpm_like() {
  case "$OS_ID $OS_ID_LIKE" in
    *fedora*|*rhel*|*centos*|*rocky*|*almalinux*) return 0 ;;
    *) return 1 ;;
  esac
}

apt_codename() {
  if [ -n "$OS_UBUNTU_CODENAME" ]; then
    printf '%s\n' "$OS_UBUNTU_CODENAME"
    return
  fi

  if [ "$OS_ID" = "linuxmint" ]; then
    case "$OS_VERSION_ID" in
      22*) printf '%s\n' "noble"; return ;;
      21*) printf '%s\n' "jammy"; return ;;
      20*) printf '%s\n' "focal"; return ;;
    esac
  fi

  [ -n "$OS_CODENAME" ] && printf '%s\n' "$OS_CODENAME" && return
  die "Cannot determine apt distribution codename."
}

install_cloudflare_warp_apt() {
  CODENAME="$(apt_codename)"
  say "Detected Debian/Ubuntu family. Using Cloudflare apt repo: $CODENAME"

  export DEBIAN_FRONTEND=noninteractive
  say "Installing apt prerequisites. Detailed apt output: $LOG_FILE"
  apt-get update >>"$LOG_FILE" 2>&1
  apt-get install -y --no-install-recommends curl ca-certificates gnupg apt-transport-https >>"$LOG_FILE" 2>&1

  install -d -m 0755 /usr/share/keyrings
  rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

  printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$CODENAME" \
    > /etc/apt/sources.list.d/cloudflare-client.list

  say "Installing cloudflare-warp. Detailed apt output: $LOG_FILE"
  apt-get update >>"$LOG_FILE" 2>&1
  apt-get install -y --no-install-recommends cloudflare-warp curl >>"$LOG_FILE" 2>&1
}

install_cloudflare_warp_rpm() {
  say "Detected RPM family. Trying Cloudflare rpm repo."
  if cmd_exists dnf; then
    PKG="dnf"
  elif cmd_exists yum; then
    PKG="yum"
  else
    die "dnf/yum was not found."
  fi

  say "Installing rpm prerequisites. Detailed package output: $LOG_FILE"
  "$PKG" install -y curl ca-certificates >>"$LOG_FILE" 2>&1
  cat >/etc/yum.repos.d/cloudflare-warp.repo <<'EOF'
[cloudflare-warp]
name=cloudflare-warp
baseurl=https://pkg.cloudflareclient.com/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
EOF
  say "Installing cloudflare-warp. Detailed package output: $LOG_FILE"
  "$PKG" install -y cloudflare-warp >>"$LOG_FILE" 2>&1
}

install_cloudflare_warp() {
  if cmd_exists warp-cli; then
    say "warp-cli found. Skipping cloudflare-warp package installation."
    return
  fi

  detect_os
  if is_debian_like; then
    install_cloudflare_warp_apt
  elif is_rpm_like; then
    install_cloudflare_warp_rpm
  else
    die "Automatic installation is not supported for this Linux distribution: $OS_ID."
  fi
}

warp() {
  if warp-cli --accept-tos "$@" >/tmp/chooseip-warp-cli.out 2>/tmp/chooseip-warp-cli.err; then
    cat /tmp/chooseip-warp-cli.out
    return 0
  fi
  if warp-cli "$@" >/tmp/chooseip-warp-cli.out 2>/tmp/chooseip-warp-cli.err; then
    cat /tmp/chooseip-warp-cli.out
    return 0
  fi
  cat /tmp/chooseip-warp-cli.out /tmp/chooseip-warp-cli.err 2>/dev/null || true
  return 1
}

systemd_available() {
  cmd_exists systemctl && [ -d /run/systemd/system ]
}

ensure_warp_service() {
  systemd_available || die "systemd is not running."
  systemctl enable --now warp-svc >/dev/null 2>&1 || systemctl restart warp-svc
  sleep 2
  systemctl is-active --quiet warp-svc || die "warp-svc failed to start."
}

registered() {
  warp registration show >/dev/null 2>&1 && return 0
  warp account >/dev/null 2>&1 && return 0
  return 1
}

ensure_registered() {
  if registered; then
    say "WARP is already registered."
    return
  fi

  say "WARP is not registered. Registering a free WARP account."
  warp registration new >/dev/null 2>&1 \
    || warp register >/dev/null 2>&1 \
    || die "WARP registration failed."
}

set_proxy_mode() {
  say "Configuring WARP SOCKS5 proxy: $SOCKS_HOST:$SOCKS_PORT"
  warp mode proxy >/dev/null 2>&1 \
    || warp set-mode proxy >/dev/null 2>&1 \
    || die "Cannot set WARP proxy mode."

  warp proxy port "$SOCKS_PORT" >/dev/null 2>&1 \
    || warp set-proxy-port "$SOCKS_PORT" >/dev/null 2>&1 \
    || die "Cannot set SOCKS5 port $SOCKS_PORT."
}

connect_warp() {
  warp connect >/dev/null 2>&1 || true
  sleep 5
}

disconnect_warp() {
  warp disconnect >/dev/null 2>&1 || true
  sleep 3
}

trace_via_warp() {
  curl --silent --show-error --max-time 20 \
    --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" \
    https://www.cloudflare.com/cdn-cgi/trace
}

warp_ip() {
  trace_via_warp | awk -F= '/^ip=/{print $2; exit}'
}

warp_health_ok() {
  TRACE="$(trace_via_warp 2>/dev/null || true)"
  printf '%s\n' "$TRACE" | grep -Eq '^warp=(on|plus)$' || return 1
  printf '%s\n' "$TRACE" | grep -Eq '^ip=' || return 1
  return 0
}

wait_for_warp_health() {
  WAIT_SECONDS="${1:-75}"
  END_TIME=$(( $(date +%s) + WAIT_SECONDS ))
  while [ "$(date +%s)" -le "$END_TIME" ]; do
    warp_health_ok && return 0
    sleep 3
  done
  warp status 2>&1 | tee -a "$LOG_FILE" >/dev/null || true
  return 1
}

country_from_ipapi() {
  curl --silent --max-time 12 "https://ipapi.co/$1/country/" | tr -cd 'A-Za-z' | tr '[:lower:]' '[:upper:]'
}

country_from_ipinfo() {
  curl --silent --max-time 12 "https://ipinfo.io/$1/country" | tr -cd 'A-Za-z' | tr '[:lower:]' '[:upper:]'
}

country_from_ipwhois() {
  curl --silent --max-time 12 "https://ipwho.is/$1" \
    | sed -n 's/.*"country_code":"\([A-Za-z][A-Za-z]\)".*/\1/p' \
    | tr '[:lower:]' '[:upper:]'
}

country_for_ip() {
  IP="$1"
  COUNTRY="$(country_from_ipapi "$IP" 2>/dev/null || true)"
  [ ${#COUNTRY} -eq 2 ] && printf '%s\n' "$COUNTRY" && return 0

  COUNTRY="$(country_from_ipinfo "$IP" 2>/dev/null || true)"
  [ ${#COUNTRY} -eq 2 ] && printf '%s\n' "$COUNTRY" && return 0

  COUNTRY="$(country_from_ipwhois "$IP" 2>/dev/null || true)"
  [ ${#COUNTRY} -eq 2 ] && printf '%s\n' "$COUNTRY" && return 0

  printf '%s\n' "UNKNOWN"
}

save_state() {
  install -d -m 0755 "$STATE_DIR"
  cat >"$STATE_FILE" <<EOF
target_country=$TARGET_COUNTRY
exit_ip=$1
exit_country=$2
updated_at=$(date '+%F %T')
socks5=$SOCKS_HOST:$SOCKS_PORT
EOF
}

soft_rotate() {
  disconnect_warp
  connect_warp
}

hard_rotate() {
  say "Re-registering WARP device to force a larger rotation."
  disconnect_warp
  printf 'y\n' | warp-cli --accept-tos registration delete >/dev/null 2>&1 \
    || printf 'y\n' | warp-cli registration delete >/dev/null 2>&1 \
    || printf 'y\n' | warp-cli delete >/dev/null 2>&1 \
    || true
  sleep 3
  ensure_registered
  set_proxy_mode
  connect_warp
}

prepare_socks5() {
  install -d -m 0755 "$STATE_DIR"
  touch "$LOG_FILE" 2>/dev/null || true
  install_cloudflare_warp
  ensure_warp_service
  ensure_registered
  set_proxy_mode
  connect_warp
  wait_for_warp_health 90 || die "SOCKS5 proxy is unavailable. Check $LOG_FILE and systemctl status warp-svc."
}

choose_country() {
  TARGET_COUNTRY="$(normalize_country "$TARGET_COUNTRY")"
  [ ${#TARGET_COUNTRY} -eq 2 ] || die "TARGET_COUNTRY must be a two-letter country code, for example MX."

  prepare_socks5

  ATTEMPT=1
  while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    IP="$(warp_ip 2>/dev/null || true)"
    COUNTRY="UNKNOWN"
    [ -n "$IP" ] && COUNTRY="$(country_for_ip "$IP")"
    say "Attempt $ATTEMPT/$MAX_ATTEMPTS: WARP exit IP=${IP:-unknown}, country=$COUNTRY, target=$TARGET_COUNTRY"

    if [ "$COUNTRY" = "$TARGET_COUNTRY" ]; then
      save_state "$IP" "$COUNTRY"
      install_timer
      say "Target country reached. SOCKS5 is ready: $SOCKS_HOST:$SOCKS_PORT"
      return 0
    fi

    if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
      save_state "${IP:-unknown}" "$COUNTRY"
      die "Could not reach target country $TARGET_COUNTRY after $MAX_ATTEMPTS attempts. WARP may not be routing this VPS to that country."
    fi

    if [ $(( ATTEMPT % HARD_ROTATE_EVERY )) -eq 0 ]; then
      hard_rotate
    else
      soft_rotate
    fi

    systemctl restart warp-svc >/dev/null 2>&1 || true
    sleep 5
    ensure_warp_service
    set_proxy_mode
    connect_warp
    wait_for_warp_health 75 || true

    ATTEMPT=$(( ATTEMPT + 1 ))
  done
}

install_timer() {
  SELF_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s\n' "$0")"
  [ -r "$SELF_PATH" ] || return 0

  cat >"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Keep Cloudflare WARP SOCKS5 on target country
After=network-online.target warp-svc.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=TARGET_COUNTRY=$TARGET_COUNTRY
Environment=MAX_ATTEMPTS=$MAX_ATTEMPTS
Environment=HARD_ROTATE_EVERY=$HARD_ROTATE_EVERY
Environment=SOCKS_PORT=$SOCKS_PORT
ExecStart=/bin/sh $SELF_PATH choose
EOF

  cat >"$SYSTEMD_TIMER" <<'EOF'
[Unit]
Description=Daily Cloudflare WARP target-country check

[Timer]
OnCalendar=*-*-* 04:40:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now chooseip-warp-socks5.timer >/dev/null
  say "Daily target-country timer created: chooseip-warp-socks5.timer"
}

remove_timer() {
  systemctl disable --now chooseip-warp-socks5.timer >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER"
  systemctl daemon-reload || true
  say "Daily target-country timer removed."
}

show_status() {
  prepare_socks5
  IP="$(warp_ip 2>/dev/null || true)"
  COUNTRY="UNKNOWN"
  [ -n "$IP" ] && COUNTRY="$(country_for_ip "$IP")"
  printf 'SOCKS5: %s:%s\n' "$SOCKS_HOST" "$SOCKS_PORT"
  printf 'Target country: %s\n' "$(normalize_country "$TARGET_COUNTRY")"
  printf 'Current IP: %s\n' "${IP:-unknown}"
  printf 'Current country: %s\n' "$COUNTRY"
  [ -r "$STATE_FILE" ] && printf 'State file: %s\n' "$STATE_FILE"
}

main() {
  need_root "$@"
  ACTION="${1:-choose}"

  case "$ACTION" in
    choose|install) choose_country ;;
    status) show_status ;;
    uninstall-timer) remove_timer ;;
    *)
      cat <<EOF
Usage:
  TARGET_COUNTRY=MX sh $0 [choose|install|status|uninstall-timer]

Environment:
  TARGET_COUNTRY       Two-letter target country code. Default: MX
  MAX_ATTEMPTS         Max country-selection attempts. Default: 30
  HARD_ROTATE_EVERY    Re-register every N attempts. Default: 3
  SOCKS_PORT           Local SOCKS5 port. Default: 40000
EOF
      exit 2
      ;;
  esac
}

main "$@"
