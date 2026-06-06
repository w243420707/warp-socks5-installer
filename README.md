# Cloudflare WARP SOCKS5 Installer

One-click Linux installer for Cloudflare WARP local SOCKS5 proxy.

Default SOCKS5 endpoint:

```text
127.0.0.1:40000
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/install-warp-socks5.sh | sudo sh
```

## Try To Choose WARP Exit Country

Cloudflare WARP does not officially support selecting an exit country. This script shows a region list, lets you choose a target, tries WARP endpoint candidates first, and stops when the detected exit IP country matches the target. After a successful match, it keeps that endpoint fixed and does not rotate daily by default.

Interactive menu:

```sh
curl -fsSL https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/chooseIP-warp-socks5.sh | sudo env MAX_ATTEMPTS=50 SCAN_LIMIT=100 sh
```

Menu options include scanning endpoints, showing scanned regions, choosing a region to fix, status, and timer removal.

Directly choose Mexico:

```sh
curl -fsSL https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/chooseIP-warp-socks5.sh | sudo env TARGET_COUNTRY=MX MAX_ATTEMPTS=50 sh
```

With endpoint candidates:

```sh
curl -fsSL https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/chooseIP-warp-socks5.sh | sudo env TARGET_COUNTRY=MX MAX_ATTEMPTS=50 ENDPOINTS="162.159.192.1:2408 188.114.96.1:2408" sh
```

Or use a file with one endpoint per line:

```sh
sudo env TARGET_COUNTRY=MX ENDPOINT_FILE=/root/mx-endpoints.txt sh chooseIP-warp-socks5.sh choose
```

## Commands

```sh
sudo sh install-warp-socks5.sh status
sudo sh install-warp-socks5.sh rotate
sudo sh install-warp-socks5.sh uninstall-timer
```

For the country chooser:

```sh
sudo sh chooseIP-warp-socks5.sh scan
sudo sh chooseIP-warp-socks5.sh list-available
sudo sh chooseIP-warp-socks5.sh list
sudo env TARGET_COUNTRY=MX sh chooseIP-warp-socks5.sh status
sudo env TARGET_COUNTRY=MX MAX_ATTEMPTS=30 sh chooseIP-warp-socks5.sh choose
sudo sh chooseIP-warp-socks5.sh uninstall-timer
```

The installer creates a systemd timer named `warp-socks5-rotate.timer` to rotate the WARP exit IP daily and restart the SOCKS5 service.

The country chooser stores the last successful endpoint in `/var/lib/chooseip-warp-socks5/state` and tries it first next time. It does not create a daily timer unless `KEEP_DAILY_TIMER=1` is set.
