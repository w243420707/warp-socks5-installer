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

安装脚本默认打开中文交互菜单，可安装/修复、查看状态、立即换 IP、启用/停用每日定时器、仅卸载本地配置或彻底卸载 `cloudflare-warp`。

## Try To Choose WARP Exit Country

Cloudflare WARP 官方并不支持指定出口国家/地区。这个脚本会打开中文交互菜单，可先扫描 endpoint 生成本机实测可用地区，再选择目标地区并固定 WARP SOCKS5。命中后默认固定住，不会每天自动更换。

中文交互菜单:

```sh
curl -fsSL https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/chooseIP-warp-socks5.sh | sudo env MAX_ATTEMPTS=50 SCAN_LIMIT=100 sh
```

菜单包含扫描 endpoint、查看可用地区、选择地区并固定、查看状态、移除定时器和卸载。

直接选择墨西哥:

```sh
curl -fsSL https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/chooseIP-warp-socks5.sh | sudo env TARGET_COUNTRY=MX MAX_ATTEMPTS=50 sh
```

使用自定义 endpoint 候选列表:

```sh
curl -fsSL https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/chooseIP-warp-socks5.sh | sudo env TARGET_COUNTRY=MX MAX_ATTEMPTS=50 ENDPOINTS="162.159.192.1:2408 188.114.96.1:2408" sh
```

也可以使用每行一个 endpoint 的文件:

```sh
sudo env TARGET_COUNTRY=MX ENDPOINT_FILE=/root/mx-endpoints.txt sh chooseIP-warp-socks5.sh choose
```

## Commands

```sh
sudo sh install-warp-socks5.sh status
sudo sh install-warp-socks5.sh rotate
sudo sh install-warp-socks5.sh uninstall-timer
sudo sh install-warp-socks5.sh uninstall
sudo sh install-warp-socks5.sh purge
```

选区脚本命令:

```sh
sudo sh chooseIP-warp-socks5.sh scan
sudo sh chooseIP-warp-socks5.sh list-available
sudo sh chooseIP-warp-socks5.sh list
sudo env TARGET_COUNTRY=MX sh chooseIP-warp-socks5.sh status
sudo env TARGET_COUNTRY=MX MAX_ATTEMPTS=30 sh chooseIP-warp-socks5.sh choose
sudo sh chooseIP-warp-socks5.sh uninstall-timer
sudo sh chooseIP-warp-socks5.sh uninstall
sudo sh chooseIP-warp-socks5.sh purge
```

安装脚本会创建 `warp-socks5-rotate.timer`，用于每天更换 WARP 出口 IP 并重启 SOCKS5。

选区脚本会把最后成功的 endpoint 保存到 `/var/lib/chooseip-warp-socks5/state`，下次优先尝试。除非设置 `KEEP_DAILY_TIMER=1`，否则不会创建每日定时器。
