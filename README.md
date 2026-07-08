# Cloudflare WARP SOCKS5 Installer

Cloudflare WARP SOCKS5 一键安装脚本。

默认本地 SOCKS5：

```text
127.0.0.1:40000
```

## 一键运行

```sh
curl -fsSL https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/install-warp-socks5.sh | sudo sh
```

脚本默认打开中文交互菜单。直接回车会执行默认安装/修复，并启用每日自动换 IP 与重启 WARP。菜单也可查看状态、立即换 IP、启用/停用每日自动换 IP、卸载本地配置或彻底卸载 `cloudflare-warp`。

## 常用命令

```sh
sudo sh install-warp-socks5.sh status
sudo sh install-warp-socks5.sh rotate
sudo sh install-warp-socks5.sh enable-timer
sudo sh install-warp-socks5.sh uninstall-timer
sudo sh install-warp-socks5.sh uninstall
sudo sh install-warp-socks5.sh purge
```

换 IP 默认最多尝试 3 次。只有检测到新出口 IP 和旧出口 IP 不同时才算成功；如果 Cloudflare 仍分配同一个出口 IP，脚本会明确报错，不再假报成功。

可以增加尝试次数：

```sh
curl -fsSL https://raw.githubusercontent.com/w243420707/warp-socks5-installer/main/install-warp-socks5.sh | sudo env ROTATE_ATTEMPTS=5 sh -s rotate
```

卸载说明：

```text
uninstall  仅移除脚本创建的定时器、状态、日志并断开 WARP，保留 cloudflare-warp 软件包。
purge      移除 cloudflare-warp 软件包/软件源，以及脚本创建的定时器、状态、日志。
```
