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

## Commands

```sh
sudo sh install-warp-socks5.sh status
sudo sh install-warp-socks5.sh rotate
sudo sh install-warp-socks5.sh uninstall-timer
```

The installer creates a systemd timer named `warp-socks5-rotate.timer` to rotate the WARP exit IP daily and restart the SOCKS5 service.
