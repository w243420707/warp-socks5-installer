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

脚本默认打开中文交互菜单（TUI 界面）。直接回车会执行默认安装/修复，并启用每日自动换 IP 与重启 WARP。菜单也可查看状态、立即换 IP、启用/停用每日自动换 IP、卸载本地配置或彻底卸载 `cloudflare-warp`。

## 菜单功能

```text
[1] 安装/修复    配置 WARP SOCKS5 代理并启用每日自动换 IP
[2] 查看状态      显示当前 WARP 状态和出口 IP
[3] 立即换 IP    立即更换 WARP 出口 IP
[4] 启用定时器    启用每日自动换 IP 定时任务（04:20 运行）
[5] 停用定时器    停用每日自动换 IP 定时任务
[6] 仅卸载        移除本地 SOCKS5 配置，保留 cloudflare-warp
[7] 彻底卸载      卸载 cloudflare-warp 和所有相关配置
[H] 查看帮助      显示使用说明和快捷键
[0] 退出程序      返回到命令行
```

菜单顶部会实时显示 WARP 连接状态、当前出口 IP 和代理端口。

## 常用命令

```sh
sudo sh install-warp-socks5.sh status
sudo sh install-warp-socks5.sh rotate
sudo sh install-warp-socks5.sh enable-timer
sudo sh install-warp-socks5.sh uninstall-timer
sudo sh install-warp-socks5.sh uninstall
sudo sh install-warp-socks5.sh purge
```

卸载说明：

```text
uninstall  仅移除脚本创建的定时器、状态、日志并断开 WARP，保留 cloudflare-warp 软件包。
purge      移除 cloudflare-warp 软件包/软件源，以及脚本创建的定时器、状态、日志。
```

## 更新日志

### v1.1.2 (2026-10-10)

- 修复 TUI 菜单颜色码显示为 `\033[0;36m` 这类文本的问题。
- 根因：颜色变量用单引号存 `\033` 字面文本，终端无法解释。
- 修复：改用 `printf` 生成真实 ANSI ESC 字节，dash 已验证输出 `1b 5b 30 3b 33 36 6d`。
- 输出非终端时（如重定向到文件）自动关闭颜色。
- 补全状态面板“未安装”行的右框线。

### v1.1.1 (2026-10-10)

- 修复 Ubuntu/dash 下执行 `curl ... | sudo sh` 报 `Bad for loop variable` 的问题。
- 移除脚本中 bash 专属的 C 风格 `for ((...))` 循环，改为 POSIX sh 兼容写法。
- 已用 dash 和 sh 双重通过语法检查。

### v1.1.0 (2026-10-10)

- 交互菜单升级为 TUI 界面：彩色边框、状态面板、功能分区。
- 菜单顶部实时显示 WARP 连接状态、出口 IP 和代理端口。
- 新增 `[H] 查看帮助` 选项，展示完整操作说明与快捷命令。
- `查看状态` 改为页内展示，返回菜单后不再退出程序。
- 停用定时器后回到菜单，卸载类操作仍保持原有的二次确认与退出行为。
- 修正非 TTY 环境下的按键读取兼容性（改用 `dd` 读取单字符）。

### v1.0.0 (2026-06-07)

- 首个版本：安装/修复、查看状态、立即换 IP、定时器开关、两级卸载。
