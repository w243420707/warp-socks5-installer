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

Cloudflare WARP does not officially support selecting an exit country. This command repeatedly rotates the WARP session/device and stops only when the detected exit IP country matches the target.

Example for Mexico:

```sh
curl -fsSL https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/chooseIP-warp-socks5.sh | sudo env TARGET_COUNTRY=MX MAX_ATTEMPTS=30 sh
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
sudo env TARGET_COUNTRY=MX sh chooseIP-warp-socks5.sh status
sudo env TARGET_COUNTRY=MX MAX_ATTEMPTS=30 sh chooseIP-warp-socks5.sh choose
sudo sh chooseIP-warp-socks5.sh uninstall-timer
```

The installer creates a systemd timer named `warp-socks5-rotate.timer` to rotate the WARP exit IP daily and restart the SOCKS5 service.

The country chooser creates a systemd timer named `chooseip-warp-socks5.timer` to check the target country daily and rotate again if needed. It stores the last successful endpoint in `/var/lib/chooseip-warp-socks5/state` and tries it first next time.
