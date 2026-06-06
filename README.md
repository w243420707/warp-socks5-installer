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

The country chooser creates a systemd timer named `chooseip-warp-socks5.timer` to check the target country daily and rotate again if needed.
