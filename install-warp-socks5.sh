#!/bin/sh
#
# One-click Cloudflare WARP SOCKS5 installer/repairer for Linux.
# Creates a local SOCKS5 proxy at 127.0.0.1:40000 and installs a daily
# systemd timer to rotate the WARP exit IP and restart the proxy.
#
# Usage:
#   sh install-warp-socks5.sh          # interactive TUI menu
#   sh install-warp-socks5.sh install  # install or repair
#   sh install-warp-socks5.sh status   # show status and current WARP IP
#   sh install-warp-socks5.sh rotate   # rotate WARP IP now
#   sh install-warp-socks5.sh uninstall
#   sh install-warp-socks5.sh purge
#   sh install-warp-socks5.sh uninstall-timer
#   sh install-warp-socks5.sh --help   # show help

set -eu

SOCKS_HOST="127.0.0.1"
SOCKS_PORT="${SOCKS_PORT:-40000}"
STATE_DIR="/var/lib/warp-socks5"
STATE_IP_FILE="$STATE_DIR/current_ip"
LOG_FILE="/var/log/warp-socks5.log"
SYSTEMD_SERVICE="/etc/systemd/system/warp-socks5-rotate.service"
SYSTEMD_TIMER="/etc/systemd/system/warp-socks5-rotate.timer"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/install-warp-socks5.sh?v=20261010-1}"
SELF_PATH=""

# TUI colors (terminal escape sequences)
if [ -t 0 ] && [ -t 1 ]; then
    COLORS_ENABLED=1
else
    COLORS_ENABLED=0
fi

# ANSI color codes
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_PURPLE='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'
C_GRAY='\033[0;90m'
C_BOLD='\033[1m'
C_RESET='\033[0m'
C_CLEAR='\033[2J\033[H'

# Helper: colored output
say() {
  printf '%s\n' "$*"
  log "$*"
}

# Helper: colored output with prefix
say_c() {
  if [ "$COLORS_ENABLED" = "1" ]; then
    printf "%b%s${C_RESET}\n" "$1" "$2"
  else
    printf '%s\n' "$2"
  fi
  log "$2"
}

die() {
  if [ "$COLORS_ENABLED" = "1" ]; then
    printf "${C_RED}${C_BOLD}错误:${C_RESET} %s\n" "$*"
  else
    say "错误: $*"
  fi
  exit 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo sh "$0" "$@"
    fi
    die "请使用 root 运行，或先安装 sudo。"
  fi
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

# TUI Helper Functions
clear_screen_tui() {
  printf '\033[2J\033[H' 2>/dev/null || clear
}

# Read a single character from terminal (POSIX-safe)
read_key() {
  if [ -r /dev/tty ]; then
    if command -v stty >/dev/null 2>&1; then
      stty raw -echo 2>/dev/null </dev/tty || true
    fi
    KEY="$(dd bs=1 count=1 2>/dev/null </dev/tty || true)"
    if command -v stty >/dev/null 2>&1; then
      stty sane 2>/dev/null </dev/tty || true
    fi
    printf '%s' "$KEY"
  fi
}

# Draw a simple box with border
draw_box() {
  local x=$1 y=$2 width=$3 height=$4 title="${5:-}"
  local i j
  printf '\033[%d;%dH' "$y" "$x"
  printf '╔'
  for ((i=1; i<width-1; i++)); do printf '═'; done
  printf '╗\n'
  for ((i=1; i<height-1; i++)); do
    printf '\033[%d;%dH' "$((y+i))" "$x"
    printf '║'
    for ((j=1; j<width-1; j++)); do printf ' '; done
    printf '║\n'
  done
  printf '\033[%d;%dH' "$((y+height-1))" "$x"
  printf '╚'
  for ((i=1; i<width-1; i++)); do printf '═'; done
  printf '╝\n'
  if [ -n "$title" ]; then
    printf '\033[%d;%dH' "$y" "$((x+2))"
    printf '%s' "$title"
  fi
}

detect_os() {
  [ -r /etc/os-release ] || die "无法识别 Linux 发行版：缺少 /etc/os-release。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH_OK=1 ;;
    aarch64|arm64) ARCH_OK=1 ;;
    *) ARCH_OK=0 ;;
  esac
  [ "$ARCH_OK" = 1 ] || die "当前 CPU 架构 $ARCH 可能不受官方 cloudflare-warp 软件包支持。"
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
  die "无法识别 apt 发行版代号。请检查 /etc/os-release 中的 VERSION_CODENAME 后重试。"
}

install_cloudflare_warp_apt() {
  CODENAME="$(apt_codename)"
  say "检测到 Debian/Ubuntu 系统，使用 Cloudflare apt 源：$CODENAME"

  export DEBIAN_FRONTEND=noninteractive
  say "正在安装 apt 前置依赖，详细日志：$LOG_FILE"
  apt-get update >>"$LOG_FILE" 2>&1
  apt-get install -y --no-install-recommends curl ca-certificates gnupg apt-transport-https >>"$LOG_FILE" 2>&1

  install -d -m 0755 /usr/share/keyrings
  rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

  printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$CODENAME" \
    > /etc/apt/sources.list.d/cloudflare-client.list

  say "正在安装 cloudflare-warp，详细日志：$LOG_FILE"
  apt-get update >>"$LOG_FILE" 2>&1
  apt-get install -y --no-install-recommends cloudflare-warp curl >>"$LOG_FILE" 2>&1
}

install_cloudflare_warp_rpm() {
  say "检测到 RPM 系统，尝试使用 Cloudflare rpm 源。"
  if cmd_exists dnf; then
    PKG="dnf"
  elif cmd_exists yum; then
    PKG="yum"
  else
    die "未找到 dnf/yum。"
  fi

  say "正在安装 rpm 前置依赖，详细日志：$LOG_FILE"
  "$PKG" install -y curl ca-certificates >>"$LOG_FILE" 2>&1
  cat >/etc/yum.repos.d/cloudflare-warp.repo <<'EOF'
[cloudflare-warp]
name=cloudflare-warp
baseurl=https://pkg.cloudflareclient.com/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
EOF
  say "正在安装 cloudflare-warp，详细日志：$LOG_FILE"
  "$PKG" install -y cloudflare-warp >>"$LOG_FILE" 2>&1
}

install_cloudflare_warp() {
  if cmd_exists warp-cli; then
    say "已检测到 warp-cli，跳过 cloudflare-warp 安装。"
    return
  fi

  detect_os
  if is_debian_like; then
    install_cloudflare_warp_apt
  elif is_rpm_like; then
    install_cloudflare_warp_rpm
  else
    die "暂不支持自动安装此 Linux 发行版：$OS_ID。支持 Debian/Ubuntu/RHEL/Fedora 系。"
  fi
}

warp() {
  if warp-cli --accept-tos "$@" >/tmp/warp-cli.out 2>/tmp/warp-cli.err; then
    cat /tmp/warp-cli.out
    return 0
  fi
  if warp-cli "$@" >/tmp/warp-cli.out 2>/tmp/warp-cli.err; then
    cat /tmp/warp-cli.out
    return 0
  fi
  cat /tmp/warp-cli.out /tmp/warp-cli.err 2>/dev/null || true
  return 1
}

systemd_available() {
  cmd_exists systemctl && [ -d /run/systemd/system ]
}

ensure_warp_service() {
  if ! systemd_available; then
    die "当前系统未运行 systemd，无法创建每日自动任务。"
  fi

  systemctl enable --now warp-svc >/dev/null 2>&1 || systemctl restart warp-svc
  sleep 2
  systemctl is-active --quiet warp-svc || die "warp-svc 启动失败。"
}

registered() {
  warp registration show >/dev/null 2>&1 && return 0
  warp account >/dev/null 2>&1 && return 0
  return 1
}

ensure_registered() {
  if registered; then
    say "WARP 已注册。"
    return
  fi

  say "WARP 尚未注册，正在注册免费 WARP 账户。"
  warp registration new >/dev/null 2>&1 \
    || warp register >/dev/null 2>&1 \
    || die "WARP 注册失败。"
}

set_proxy_mode() {
  say "正在配置本地 SOCKS5 代理：$SOCKS_HOST:$SOCKS_PORT"

  warp mode proxy >/dev/null 2>&1 \
    || warp set-mode proxy >/dev/null 2>&1 \
    || die "无法设置 WARP 代理模式。"

  warp proxy port "$SOCKS_PORT" >/dev/null 2>&1 \
    || warp set-proxy-port "$SOCKS_PORT" >/dev/null 2>&1 \
    || die "无法设置 SOCKS5 端口 $SOCKS_PORT。"
}

connect_warp() {
  warp connect >/dev/null 2>&1 || true
  sleep 5
}

disconnect_warp() {
  warp disconnect >/dev/null 2>&1 || true
  sleep 2
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
  WAIT_SECONDS="${1:-60}"
  END_TIME=$(( $(date +%s) + WAIT_SECONDS ))

  while [ "$(date +%s)" -le "$END_TIME" ]; do
    if warp_health_ok; then
      return 0
    fi
    sleep 3
  done

  say "WARP 状态输出："
  warp status 2>&1 | tee -a "$LOG_FILE" >/dev/null || true
  if cmd_exists ss; then
    say "SOCKS5 端口监听情况："
    ss -lntp 2>/dev/null | grep ":$SOCKS_PORT " | tee -a "$LOG_FILE" >/dev/null || true
  fi
  return 1
}

save_current_ip() {
  install -d -m 0755 "$STATE_DIR"
  IP="$(warp_ip 2>/dev/null || true)"
  if [ -n "$IP" ]; then
    printf '%s\n' "$IP" > "$STATE_IP_FILE"
    say "当前 WARP 出口 IP：$IP"
  else
    say "未能读取当前 WARP 出口 IP。"
  fi
}

install_timer() {
  SELF_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s\n' "$0")"
  if [ -r "$SELF_PATH" ] && grep -q 'warp-socks5-rotate.timer' "$SELF_PATH" 2>/dev/null; then
    TIMER_EXEC="/bin/sh $SELF_PATH rotate"
  else
    TIMER_EXEC="/bin/sh -c 'curl -fsSL \"$SCRIPT_URL\" | /bin/sh -s rotate'"
  fi

  cat >"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Rotate Cloudflare WARP SOCKS5 exit IP
After=network-online.target warp-svc.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$TIMER_EXEC
EOF

  cat >"$SYSTEMD_TIMER" <<'EOF'
[Unit]
Description=Daily Cloudflare WARP SOCKS5 IP rotation

[Timer]
OnCalendar=*-*-* 04:20:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now warp-socks5-rotate.timer >/dev/null
  say "每日自动换 IP 定时器已创建：warp-socks5-rotate.timer"
}

remove_timer() {
  systemctl disable --now warp-socks5-rotate.timer >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER"
  systemctl daemon-reload || true
  if [ "${1:-}" != "quiet" ]; then
    say "每日自动换 IP 定时器已移除。"
  fi
}

disable_proxy_and_disconnect() {
  if cmd_exists warp-cli; then
    warp disconnect >/dev/null 2>&1 || true
    warp mode warp >/dev/null 2>&1 || warp set-mode warp >/dev/null 2>&1 || true
  fi
}

uninstall_local_config() {
  remove_timer quiet
  disable_proxy_and_disconnect
  rm -rf "$STATE_DIR"
  rm -f "$LOG_FILE"
  say "本地 WARP SOCKS5 配置已移除，cloudflare-warp 软件包已保留。"
}

purge_cloudflare_warp() {
  uninstall_local_config
  touch "$LOG_FILE" 2>/dev/null || true
  systemctl disable --now chooseip-warp-socks5.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/chooseip-warp-socks5.service /etc/systemd/system/chooseip-warp-socks5.timer
  rm -rf /var/lib/chooseip-warp-socks5
  rm -f /var/log/chooseip-warp-socks5.log
  detect_os
  if is_debian_like && cmd_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get remove -y cloudflare-warp >>"$LOG_FILE" 2>&1 || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    apt-get update >>"$LOG_FILE" 2>&1 || true
  elif is_rpm_like; then
    if cmd_exists dnf; then
      dnf remove -y cloudflare-warp >>"$LOG_FILE" 2>&1 || true
    elif cmd_exists yum; then
      yum remove -y cloudflare-warp >>"$LOG_FILE" 2>&1 || true
    fi
    rm -f /etc/yum.repos.d/cloudflare-warp.repo
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  say "cloudflare-warp 软件包和本脚本相关配置已移除。"
}

repair_or_install() {
  install -d -m 0755 "$STATE_DIR"
  touch "$LOG_FILE" 2>/dev/null || true

  install_cloudflare_warp
  ensure_warp_service
  ensure_registered
  set_proxy_mode
  connect_warp

  if wait_for_warp_health 75; then
    say "SOCKS5 代理工作正常：$SOCKS_HOST:$SOCKS_PORT"
  else
    say "健康检查失败，正在重启 warp-svc 后重试。"
    systemctl restart warp-svc
    sleep 4
    ensure_registered
    set_proxy_mode
    connect_warp
    wait_for_warp_health 75 || die "SOCKS5 代理仍不可用，请查看 $LOG_FILE 和 systemctl status warp-svc。"
  fi

  save_current_ip
  install_timer
}

force_new_registration() {
  say "正在重新注册 WARP 设备以尝试获取新的出口 IP。"
  disconnect_warp
  printf 'y\n' | warp-cli --accept-tos registration delete >/dev/null 2>&1 \
    || printf 'y\n' | warp-cli registration delete >/dev/null 2>&1 \
    || printf 'y\n' | warp-cli delete >/dev/null 2>&1 \
    || true
  sleep 2
  ensure_registered
}

rotate_ip() {
  install -d -m 0755 "$STATE_DIR"

  install_cloudflare_warp
  ensure_warp_service
  ensure_registered
  set_proxy_mode

  OLD_IP=""
  [ -r "$STATE_IP_FILE" ] && OLD_IP="$(sed -n '1p' "$STATE_IP_FILE" || true)"
  [ -z "$OLD_IP" ] && OLD_IP="$(warp_ip 2>/dev/null || true)"

  say "开始更换 WARP IP，旧 IP：${OLD_IP:-unknown}"
  disconnect_warp
  connect_warp

  NEW_IP="$(warp_ip 2>/dev/null || true)"
  if [ -n "$OLD_IP" ] && [ -n "$NEW_IP" ] && [ "$NEW_IP" = "$OLD_IP" ]; then
    say "重连后 IP 未变化，尝试重新注册设备。"
    force_new_registration
    set_proxy_mode
    connect_warp
    NEW_IP="$(warp_ip 2>/dev/null || true)"
  fi

  systemctl restart warp-svc
  sleep 4
  ensure_registered
  set_proxy_mode
  connect_warp

  wait_for_warp_health 75 || die "换 IP 后 SOCKS5 健康检查失败。"
  save_current_ip
  say "换 IP 完成，SOCKS5 已重启并恢复正常：$SOCKS_HOST:$SOCKS_PORT"
}

show_status() {
  install_cloudflare_warp
  ensure_warp_service
  ensure_registered
  set_proxy_mode
  connect_warp

  printf '\n'
  warp status || true
  printf '\nSOCKS5: %s:%s\n' "$SOCKS_HOST" "$SOCKS_PORT"
  if wait_for_warp_health 30; then
    IP="$(warp_ip 2>/dev/null || true)"
    printf 'WARP 健康状态：正常\n'
    printf 'WARP 出口 IP：%s\n' "${IP:-unknown}"
  else
    printf 'WARP 健康状态：失败\n'
    exit 1
  fi
}

read_tty() {
  PROMPT="$1"
  DEFAULT="${2:-}"
  if [ -r /dev/tty ]; then
    printf '%s' "$PROMPT" >/dev/tty
    read -r ANSWER </dev/tty || ANSWER=""
    printf '%s\n' "${ANSWER:-$DEFAULT}"
  else
    printf '%s\n' "$DEFAULT"
  fi
}

confirm_tty() {
  PROMPT="$1"
  ANSWER="$(read_tty "$PROMPT [y/N/是]: " "n")"
  case "$ANSWER" in
    y|Y|yes|YES|是|确认) return 0 ;;
    *) return 1 ;;
  esac
}

show_current_ip() {
  IP=""
  [ -r "$STATE_IP_FILE" ] && IP="$(sed -n '1p' "$STATE_IP_FILE" || true)"
  if [ -z "$IP" ]; then
    IP="$(warp_ip 2>/dev/null || true)"
  fi
  if [ -n "$IP" ]; then
    printf '%s' "$IP"
  else
    printf 'unknown'
  fi
}

show_help() {
  clear_screen_tui
  printf '%s\n' "${C_BOLD}Cloudflare WARP SOCKS5 管理工具 - 使用说明${C_RESET}"
  printf '\n%s\n' "${C_CYAN}菜单操作:${C_RESET}"
  if [ "$COLORS_ENABLED" = "1" ]; then
    printf '  %s数字键 1-9%s  直接选择菜单项\n' "$C_BLUE" "$C_RESET"
    printf '  %sEnter 键%s    执行所选操作\n' "$C_BLUE" "$C_RESET"
    printf '  %s0 键%s       退出程序\n' "$C_BLUE" "$C_RESET"
  else
    printf '  数字键 1-9  直接选择菜单项\n'
    printf '  Enter 键    执行所选操作\n'
    printf '  0 键       退出程序\n'
  fi

  printf '\n%s\n' "${C_CYAN}快捷命令:${C_RESET}"
  printf '  sh install-warp-socks5.sh install          安装或修复\n'
  printf '  sh install-warp-socks5.sh status           查看状态\n'
  printf '  sh install-warp-socks5.sh rotate           立即换IP\n'
  printf '  sh install-warp-socks5.sh enable-timer     启用定时器\n'
  printf '  sh install-warp-socks5.sh uninstall-timer  停用定时器\n'
  printf '  sh install-warp-socks5.sh uninstall        仅卸载本地配置\n'
  printf '  sh install-warp-socks5.sh purge            彻底卸载\n'
  printf '  sh install-warp-socks5.sh help             显示帮助\n'

  printf '\n'
  printf '%s\n' "${C_GRAY}按任意键返回..."
  read_key >/dev/null
}

show_status_tui() {
  clear_screen_tui
  printf '%s\n' "${C_BOLD}Cloudflare WARP SOCKS5 管理工具 - 状态信息${C_RESET}"
  printf '\n'

  if cmd_exists warp-cli; then
    printf '%sWARP 服务:%s 已安装\n' "$C_GREEN" "$C_RESET"
    printf '%sWARP 状态:%s ' "$C_YELLOW" "$C_RESET"
    warp status 2>/dev/null || printf '无法获取状态\n'
    printf '\n'
  else
    printf '%sWARP 服务:%s 未安装\n' "$C_RED" "$C_RESET"
  fi

  printf '%s代理地址:%s %s:%s\n' "$C_CYAN" "$C_RESET" "$SOCKS_HOST" "$SOCKS_PORT"

  if systemd_available && cmd_exists systemctl; then
    if systemctl is-active --quiet warp-svc 2>/dev/null; then
      printf '%s服务状态:%s %s正常运行%s\n' "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
    else
      printf '%s服务状态:%s %s已停止%s\n' "$C_RED" "$C_RESET" "$C_BOLD" "$C_RESET"
    fi

    if systemctl is-active --quiet warp-socks5-rotate.timer 2>/dev/null; then
      printf '%s定时器状态:%s %s已启用%s\n' "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
    else
      printf '%s定时器状态:%s %s已停用%s\n' "$C_YELLOW" "$C_RESET" "$C_BOLD" "$C_RESET"
    fi
  fi

  printf '\n%s当前出口 IP:%s %s\n' "$C_BLUE" "$C_RESET" "$(show_current_ip)"
  printf '%s日志文件:%s %s\n' "$C_GRAY" "$C_RESET" "$LOG_FILE"

  printf '\n'
  printf '%s\n' "${C_GRAY}按任意键返回..."
  read_key >/dev/null
}

interactive_menu() {
  while :; do
    clear_screen_tui

    printf '%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$C_CYAN" "$C_RESET"
    printf '%s║%s%s  Cloudflare WARP SOCKS5 管理工具 (TUI)                  %s%s%s   ║%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_CYAN" "$C_RESET" "$(date '+%H:%M')" "$C_RESET"
    printf '%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$C_CYAN" "$C_RESET"
    printf '\n'

    IP="$(show_current_ip)"
    printf '%s┌─ 系统状态 ──────────────────────────────────────────────────────────┐%s\n' "$C_BLUE" "$C_RESET"
    if cmd_exists warp-cli && warp status >/dev/null 2>&1; then
      printf '│  WARP 状态: %s已连接%s    │  出口 IP: %s%-15s%s    │  端口: %s%s%s%s%s\n' "$C_GREEN" "$C_RESET" "$C_BOLD" "$IP" "$C_RESET" "$C_CYAN" "$C_RESET" "$SOCKS_PORT" "$C_BLUE" "$C_RESET"
    else
      printf '│  WARP 状态: %s未安装/未连接%s  │  出口 IP: %-15s    │  端口: %s\n' "$C_RED" "$C_RESET" "$IP" "$SOCKS_PORT"
    fi
    printf '%s└──────────────────────────────────────────────────────────────────────┘%s\n' "$C_BLUE" "$C_RESET"
    printf '\n'

    printf '%s┌─ 功能菜单 ──────────────────────────────────────────────────────────┐%s\n' "$C_BLUE" "$C_RESET"
    printf '│  %s[1]%s 安装/修复      配置 WARP SOCKS5 代理并启用每日自动换 IP              │\n' "$C_GREEN" "$C_RESET"
    printf '│  %s[2]%s 查看状态      显示当前 WARP 状态和出口 IP                        │\n' "$C_BLUE" "$C_RESET"
    printf '│  %s[3]%s 立即换 IP      立即更换 WARP 出口 IP                              │\n' "$C_PURPLE" "$C_RESET"
    printf '│  %s[4]%s 启用定时器    启用每日自动换 IP 定时任务 (04:20 运行)             │\n' "$C_YELLOW" "$C_RESET"
    printf '│  %s[5]%s 停用定时器    停用每日自动换 IP 定时任务                          │\n' "$C_YELLOW" "$C_RESET"
    printf '│  %s[6]%s 仅卸载        移除本地 SOCKS5 配置，保留 cloudflare-warp          │\n' "$C_RED" "$C_RESET"
    printf '│  %s[7]%s 彻底卸载      卸载 cloudflare-warp 和所有相关配置                  │\n' "$C_RED" "$C_RESET"
    printf '│  %s[H]%s 查看帮助      显示使用说明和快捷键                                │\n' "$C_CYAN" "$C_RESET"
    printf '│  %s[0]%s 退出程序      返回到命令行                                       │\n' "$C_GRAY" "$C_RESET"
    printf '%s└──────────────────────────────────────────────────────────────────────┘%s\n' "$C_BLUE" "$C_RESET"
    printf '\n'

    printf '%s请选择操作 (直接回车默认 [1]):%s ' "$C_BOLD" "$C_RESET"

    CHOICE="$(read_tty '' '1')"

    case "$CHOICE" in
      1|'') repair_or_install; exit 0 ;;
      2) show_status_tui ;;
      3) rotate_ip; exit 0 ;;
      4) install_timer; exit 0 ;;
      5)
        remove_timer
        printf '\n%s\n' "${C_YELLOW}按任意键返回..."
        read_key >/dev/null
        ;;
      6)
        if confirm_tty "确认移除定时器、状态、日志并断开 WARP，但保留 cloudflare-warp 软件包吗？"; then
          uninstall_local_config
        fi
        exit 0
        ;;
      7)
        if confirm_tty "确认彻底卸载 cloudflare-warp 软件包、软件源、定时器、状态和配置吗？"; then
          purge_cloudflare_warp
        fi
        exit 0
        ;;
      h|H) show_help ;;
      0) exit 0 ;;
      *) printf '%s无效选择。%s\n' "$C_RED" "$C_RESET" ;;
    esac

    if [ "$CHOICE" != "0" ]; then
      printf '%s按任意键返回菜单...%s' "$C_GRAY" "$C_RESET"
      read_key >/dev/null
    fi
  done
}

usage() {
  cat <<EOF
用法:
  sh $0 [menu|install|repair|status|rotate|enable-timer|uninstall-timer|uninstall|purge]

默认动作: menu
SOCKS5: $SOCKS_HOST:$SOCKS_PORT

卸载模式:
  uninstall  移除本脚本创建的定时器、状态、日志并断开 WARP，保留 cloudflare-warp 软件包。
  purge      移除 cloudflare-warp 软件包/软件源，以及本脚本创建的定时器、状态、日志。
EOF
  exit 2
}

main() {
  ACTION="${1:-menu}"
  case "$ACTION" in
    help|-h|--help) usage ;;
  esac

  need_root "$@"

  case "$ACTION" in
    menu|interactive) interactive_menu ;;
    install|repair) repair_or_install ;;
    rotate) rotate_ip ;;
    status) show_status ;;
    enable-timer) install_timer ;;
    uninstall-timer) remove_timer ;;
    uninstall) uninstall_local_config ;;
    purge) purge_cloudflare_warp ;;
    *) usage ;;
  esac
}

main "$@"
