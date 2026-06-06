#!/bin/sh
#
# Choose a Cloudflare WARP SOCKS5 exit country as reliably as WARP allows.
#
# Important:
#   Cloudflare WARP does not officially support selecting an exit country.
#   This script first tries a list of WARP custom endpoints, checks the
#   resulting exit IP country, and stops when TARGET_COUNTRY is reached.
#   If the endpoint list does not hit the target, it falls back to session
#   rotation and device re-registration.
#
# Usage:
#   sudo sh chooseIP-warp-socks5.sh
#   TARGET_COUNTRY=MX sudo sh chooseIP-warp-socks5.sh
#   TARGET_COUNTRY=MX MAX_ATTEMPTS=30 sudo sh chooseIP-warp-socks5.sh choose
#   ENDPOINTS="162.159.192.1:2408 188.114.96.1:2408" sudo sh chooseIP-warp-socks5.sh
#   sudo sh chooseIP-warp-socks5.sh list
#   sudo sh chooseIP-warp-socks5.sh status
#   sudo sh chooseIP-warp-socks5.sh uninstall-timer

set -eu

SOCKS_HOST="127.0.0.1"
SOCKS_PORT="${SOCKS_PORT:-40000}"
if [ "${TARGET_COUNTRY_WAS_SET:-}" = "1" ]; then
  TARGET_COUNTRY_WAS_SET=1
elif [ "${TARGET_COUNTRY+x}" = "x" ]; then
  TARGET_COUNTRY_WAS_SET=1
else
  TARGET_COUNTRY_WAS_SET=0
fi
TARGET_COUNTRY="${TARGET_COUNTRY:-MX}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-30}"
HARD_ROTATE_EVERY="${HARD_ROTATE_EVERY:-3}"
KEEP_DAILY_TIMER="${KEEP_DAILY_TIMER:-0}"
ENDPOINT_PORT="${ENDPOINT_PORT:-2408}"
ENDPOINTS="${ENDPOINTS:-}"
ENDPOINT_FILE="${ENDPOINT_FILE:-}"
ENDPOINT_LIST_URL="${ENDPOINT_LIST_URL:-}"
TRY_DEFAULT_ENDPOINTS="${TRY_DEFAULT_ENDPOINTS:-1}"
STATE_DIR="/var/lib/chooseip-warp-socks5"
STATE_FILE="$STATE_DIR/state"
ENDPOINT_CACHE_FILE="$STATE_DIR/endpoints"
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
      if [ "$TARGET_COUNTRY_WAS_SET" = "1" ]; then
        exec sudo env TARGET_COUNTRY="$TARGET_COUNTRY" TARGET_COUNTRY_WAS_SET=1 MAX_ATTEMPTS="$MAX_ATTEMPTS" HARD_ROTATE_EVERY="$HARD_ROTATE_EVERY" KEEP_DAILY_TIMER="$KEEP_DAILY_TIMER" SOCKS_PORT="$SOCKS_PORT" ENDPOINT_PORT="$ENDPOINT_PORT" ENDPOINTS="$ENDPOINTS" ENDPOINT_FILE="$ENDPOINT_FILE" ENDPOINT_LIST_URL="$ENDPOINT_LIST_URL" TRY_DEFAULT_ENDPOINTS="$TRY_DEFAULT_ENDPOINTS" sh "$0" "$@"
      fi
      exec sudo env TARGET_COUNTRY_WAS_SET=0 MAX_ATTEMPTS="$MAX_ATTEMPTS" HARD_ROTATE_EVERY="$HARD_ROTATE_EVERY" KEEP_DAILY_TIMER="$KEEP_DAILY_TIMER" SOCKS_PORT="$SOCKS_PORT" ENDPOINT_PORT="$ENDPOINT_PORT" ENDPOINTS="$ENDPOINTS" ENDPOINT_FILE="$ENDPOINT_FILE" ENDPOINT_LIST_URL="$ENDPOINT_LIST_URL" TRY_DEFAULT_ENDPOINTS="$TRY_DEFAULT_ENDPOINTS" sh "$0" "$@"
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

region_table() {
  cat <<'EOF'
MX Mexico
US United_States
CA Canada
BR Brazil
AR Argentina
CL Chile
CO Colombia
PE Peru
GB United_Kingdom
DE Germany
FR France
NL Netherlands
ES Spain
IT Italy
SE Sweden
TR Turkey
JP Japan
KR South_Korea
SG Singapore
HK Hong_Kong
TW Taiwan
AU Australia
IN India
EOF
}

show_region_list() {
  N=1
  region_table | while read -r CODE NAME; do
    printf '%2s) %-2s %s\n' "$N" "$CODE" "$(printf '%s' "$NAME" | tr '_' ' ')"
    N=$(( N + 1 ))
  done
}

country_from_menu_number() {
  WANT="$1"
  N=1
  region_table | while read -r CODE NAME; do
    if [ "$N" = "$WANT" ]; then
      printf '%s\n' "$CODE"
      exit 0
    fi
    N=$(( N + 1 ))
  done
}

select_target_country() {
  if [ "$TARGET_COUNTRY_WAS_SET" = "1" ]; then
    TARGET_COUNTRY="$(normalize_country "$TARGET_COUNTRY")"
    return
  fi

  if [ -r /dev/tty ]; then
    printf '\nAvailable target regions:\n'
    show_region_list
    printf '\nSelect a region number or type a two-letter country code [MX]: '
    read -r CHOICE </dev/tty || CHOICE=""
    CHOICE="${CHOICE:-MX}"
    case "$CHOICE" in
      ''|*[!0-9]*)
        TARGET_COUNTRY="$(normalize_country "$CHOICE")"
        ;;
      *)
        SELECTED="$(country_from_menu_number "$CHOICE" || true)"
        [ -n "$SELECTED" ] || die "Invalid region selection: $CHOICE"
        TARGET_COUNTRY="$SELECTED"
        ;;
    esac
  else
    TARGET_COUNTRY="$(normalize_country "$TARGET_COUNTRY")"
  fi
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
endpoint=${3:-auto}
updated_at=$(date '+%F %T')
socks5=$SOCKS_HOST:$SOCKS_PORT
fixed_after_success=1
EOF
}

state_value() {
  KEY="$1"
  [ -r "$STATE_FILE" ] || return 1
  sed -n "s/^$KEY=//p" "$STATE_FILE" | sed -n '1p'
}

normalize_endpoint() {
  EP="$(printf '%s' "$1" | tr -d '\r' | sed 's/^[ 	]*//;s/[ 	]*$//')"
  [ -n "$EP" ] || return 1
  case "$EP" in
    \#*) return 1 ;;
  esac
  case "$EP" in
    *:*) printf '%s\n' "$EP" ;;
    *) printf '%s:%s\n' "$EP" "$ENDPOINT_PORT" ;;
  esac
}

write_default_endpoints() {
  OUT="$1"
  for BASE in 162.159.192 162.159.193 162.159.195 188.114.96 188.114.97; do
    for N in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      printf '%s.%s:%s\n' "$BASE" "$N" "$ENDPOINT_PORT" >>"$OUT"
    done
  done
}

build_endpoint_list() {
  install -d -m 0755 "$STATE_DIR"
  TMP="$ENDPOINT_CACHE_FILE.tmp"
  : >"$TMP"

  SUCCESS_ENDPOINT="$(state_value endpoint 2>/dev/null || true)"
  if [ -n "$SUCCESS_ENDPOINT" ] && [ "$SUCCESS_ENDPOINT" != "auto" ]; then
    normalize_endpoint "$SUCCESS_ENDPOINT" >>"$TMP" 2>/dev/null || true
  fi

  if [ -n "$ENDPOINTS" ]; then
    for EP in $(printf '%s' "$ENDPOINTS" | tr ',;' '  '); do
      normalize_endpoint "$EP" >>"$TMP" 2>/dev/null || true
    done
  fi

  if [ -n "$ENDPOINT_FILE" ] && [ -r "$ENDPOINT_FILE" ]; then
    while IFS= read -r EP; do
      normalize_endpoint "$EP" >>"$TMP" 2>/dev/null || true
    done <"$ENDPOINT_FILE"
  fi

  if [ -n "$ENDPOINT_LIST_URL" ]; then
    curl --silent --show-error --max-time 20 "$ENDPOINT_LIST_URL" 2>>"$LOG_FILE" \
      | while IFS= read -r EP; do
          normalize_endpoint "$EP" >>"$TMP" 2>/dev/null || true
        done
  fi

  if [ "$TRY_DEFAULT_ENDPOINTS" = "1" ]; then
    write_default_endpoints "$TMP"
  fi

  awk '!seen[$0]++' "$TMP" >"$ENDPOINT_CACHE_FILE"
  rm -f "$TMP"
  [ -s "$ENDPOINT_CACHE_FILE" ]
}

set_custom_endpoint() {
  ENDPOINT="$1"
  say "Trying WARP custom endpoint: $ENDPOINT"
  warp set-custom-endpoint "$ENDPOINT" >/dev/null 2>&1 \
    || warp tunnel endpoint set "$ENDPOINT" >/dev/null 2>&1 \
    || warp endpoint set "$ENDPOINT" >/dev/null 2>&1 \
    || {
      say "This warp-cli build does not accept custom endpoint commands."
      return 2
    }
}

restart_proxy_after_endpoint_change() {
  disconnect_warp
  systemctl restart warp-svc >/dev/null 2>&1 || true
  sleep 5
  ensure_warp_service
  set_proxy_mode
  connect_warp
}

test_current_exit() {
  IP="$(warp_ip 2>/dev/null || true)"
  COUNTRY="UNKNOWN"
  [ -n "$IP" ] && COUNTRY="$(country_for_ip "$IP")"
  printf '%s %s\n' "${IP:-unknown}" "$COUNTRY"
}

try_endpoint_once() {
  ENDPOINT="$1"
  set_custom_endpoint "$ENDPOINT" || return $?
  restart_proxy_after_endpoint_change
  if ! wait_for_warp_health 75; then
    say "Endpoint $ENDPOINT did not produce a healthy SOCKS5 proxy."
    return 1
  fi

  RESULT="$(test_current_exit)"
  IP="$(printf '%s\n' "$RESULT" | awk '{print $1}')"
  COUNTRY="$(printf '%s\n' "$RESULT" | awk '{print $2}')"
  say "Endpoint $ENDPOINT result: WARP exit IP=$IP, country=$COUNTRY, target=$TARGET_COUNTRY"

  if [ "$COUNTRY" = "$TARGET_COUNTRY" ]; then
    save_state "$IP" "$COUNTRY" "$ENDPOINT"
    finalize_success
    say "Target country reached with endpoint $ENDPOINT. SOCKS5 is fixed and ready: $SOCKS_HOST:$SOCKS_PORT"
    return 0
  fi

  save_state "$IP" "$COUNTRY" "$ENDPOINT"
  return 1
}

finalize_success() {
  if [ "$KEEP_DAILY_TIMER" = "1" ]; then
    install_timer
  else
    remove_timer quiet
    say "Daily rotation/check timer is disabled. The matched WARP endpoint will stay fixed."
  fi
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
  select_target_country
  TARGET_COUNTRY="$(normalize_country "$TARGET_COUNTRY")"
  [ ${#TARGET_COUNTRY} -eq 2 ] || die "TARGET_COUNTRY must be a two-letter country code, for example MX."

  prepare_socks5

  if build_endpoint_list; then
    say "Built endpoint candidate list: $ENDPOINT_CACHE_FILE"
    ATTEMPT=1
    while IFS= read -r ENDPOINT; do
      [ -n "$ENDPOINT" ] || continue
      [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ] || break
      say "Endpoint attempt $ATTEMPT/$MAX_ATTEMPTS"
      if try_endpoint_once "$ENDPOINT"; then
        return 0
      elif [ "$?" -eq 2 ]; then
        say "Custom endpoint mode is unavailable. Falling back to WARP session rotation."
        break
      fi
      if [ $(( ATTEMPT % HARD_ROTATE_EVERY )) -eq 0 ]; then
        hard_rotate
      fi
      ATTEMPT=$(( ATTEMPT + 1 ))
    done <"$ENDPOINT_CACHE_FILE"
    say "Endpoint candidate list did not reach $TARGET_COUNTRY. Falling back to WARP session rotation."
  else
    say "No endpoint candidates were available. Falling back to WARP session rotation."
  fi

  ATTEMPT=1
  while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; do
    IP="$(warp_ip 2>/dev/null || true)"
    COUNTRY="UNKNOWN"
    [ -n "$IP" ] && COUNTRY="$(country_for_ip "$IP")"
    say "Attempt $ATTEMPT/$MAX_ATTEMPTS: WARP exit IP=${IP:-unknown}, country=$COUNTRY, target=$TARGET_COUNTRY"

    if [ "$COUNTRY" = "$TARGET_COUNTRY" ]; then
      CURRENT_ENDPOINT="$(state_value endpoint 2>/dev/null || printf '%s' auto)"
      save_state "$IP" "$COUNTRY" "$CURRENT_ENDPOINT"
      finalize_success
      say "Target country reached. SOCKS5 is fixed and ready: $SOCKS_HOST:$SOCKS_PORT"
      return 0
    fi

    if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
      CURRENT_ENDPOINT="$(state_value endpoint 2>/dev/null || printf '%s' auto)"
      save_state "${IP:-unknown}" "$COUNTRY" "$CURRENT_ENDPOINT"
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
Environment="TARGET_COUNTRY=$TARGET_COUNTRY"
Environment="MAX_ATTEMPTS=$MAX_ATTEMPTS"
Environment="HARD_ROTATE_EVERY=$HARD_ROTATE_EVERY"
Environment="KEEP_DAILY_TIMER=$KEEP_DAILY_TIMER"
Environment="SOCKS_PORT=$SOCKS_PORT"
Environment="ENDPOINT_PORT=$ENDPOINT_PORT"
Environment="ENDPOINTS=$ENDPOINTS"
Environment="ENDPOINT_FILE=$ENDPOINT_FILE"
Environment="ENDPOINT_LIST_URL=$ENDPOINT_LIST_URL"
Environment="TRY_DEFAULT_ENDPOINTS=$TRY_DEFAULT_ENDPOINTS"
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
  if [ "${1:-}" != "quiet" ]; then
    say "Daily target-country timer removed."
  fi
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
  printf 'Last endpoint: %s\n' "$(state_value endpoint 2>/dev/null || printf '%s' unknown)"
  [ -r "$ENDPOINT_CACHE_FILE" ] && printf 'Endpoint cache: %s\n' "$ENDPOINT_CACHE_FILE"
  [ -r "$STATE_FILE" ] && printf 'State file: %s\n' "$STATE_FILE"
}

main() {
  ACTION="${1:-choose}"

  case "$ACTION" in
    list) show_region_list; exit 0 ;;
    help|-h|--help) usage ;;
  esac

  need_root "$@"

  case "$ACTION" in
    choose|install) choose_country ;;
    status) show_status ;;
    uninstall-timer) remove_timer ;;
    *) usage ;;
  esac
}

usage() {
  cat <<EOF
Usage:
  sh $0 [choose|install|list|status|uninstall-timer]

Environment:
  TARGET_COUNTRY       Two-letter target country code. Default: MX
  MAX_ATTEMPTS         Max country-selection attempts. Default: 30
  HARD_ROTATE_EVERY    Re-register every N attempts. Default: 3
  KEEP_DAILY_TIMER     Set to 1 to keep daily country checks. Default: 0
  SOCKS_PORT           Local SOCKS5 port. Default: 40000
  ENDPOINTS            Space/comma separated endpoint list, for example "162.159.192.1:2408 188.114.96.1:2408"
  ENDPOINT_FILE        File with one endpoint per line
  ENDPOINT_LIST_URL    URL returning one endpoint per line
  ENDPOINT_PORT        Port used when endpoint lacks a port. Default: 2408
  TRY_DEFAULT_ENDPOINTS Try built-in common WARP endpoint candidates. Default: 1
EOF
  exit 2
}

main "$@"
