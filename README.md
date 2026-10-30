# Localsocks

本地 Hysteria2 SOCKS5 / HTTP 代理管理器，附带 macOS AppKit 菜单栏客户端。
这里保存的是脱敏后的源码存档；仓库不提供代理节点、账号或预编译的第三方内核。

## 功能

- macOS 菜单栏界面：节点编辑、服务启停、健康检测、日志与系统 SOCKS 代理开关
- 命令行前台运行，或安装为用户级 / 系统级 launchd 服务
- 断线重试、指数退避和日志轮转
- 配置文件与源码分开保存，示例默认启用 TLS 证书校验

## 准备配置

需要 macOS 13 或更新版本、Xcode Command Line Tools，以及自行准备的 Hysteria2 服务端。

```bash
git clone https://github.com/kongdayan/localsocks.git ~/Projects/localsocks
cd ~/Projects/localsocks
cp examples/hysteria2-client.example.yaml hysteria2-client.yaml
cp examples/nodes.example.json nodes.json
chmod 600 hysteria2-client.yaml nodes.json
```

编辑这两个本地文件，填入自己的服务端、密码及 TLS SNI；这些文件已被 Git 忽略。
两个示例应指向同一节点：脚本使用 YAML，菜单栏客户端使用节点 JSON 并生成 YAML。
`proxy.example.com` 和 `CHANGE_ME` 是占位符，不能直接连接。

## 运行

```bash
./run.sh
```

默认监听 `127.0.0.1:10800`（SOCKS5）和 `127.0.0.1:10801`（HTTP）。
`lib.sh` 保留了原项目的 Hysteria v2.6.0 下载逻辑；也可用 `HYS2_BIN` 指向自行安装的内核：

```bash
HYS2_BIN=/path/to/hysteria ./run.sh
curl --proxy socks5h://127.0.0.1:10800 https://www.google.com/generate_204
```

## macOS 菜单栏客户端

```bash
./macos/build.sh
open dist/Localsocks.app
```

默认项目目录为 `~/Projects/localsocks`，也可在客户端内设置目录或使用 `LOCALSOCKS_DIR`。
应用设置和节点保存在 `~/.config/localsocks`；服务日志位于项目的 `logs/`。
App 使用本地 ad-hoc 签名，未做 Apple 公证。构建命令只生成 App，不安装或开启后台服务。

## 后台服务

登录后运行，优先使用用户域：

```bash
./install.sh user
./install.sh status
./install.sh restart user
./healthcheck.sh
```

确实需要开机即运行时，可使用 `sudo ./install.sh system`。
服务会在 App 窗口关闭后继续运行；关闭 App 与卸载服务是两件独立的操作。

## 完整停用

先在客户端关闭系统 SOCKS 代理，再移除安装过的服务：

```bash
./install.sh uninstall user
sudo ./install.sh uninstall system
```

然后可删除 App 和项目目录。`~/.config/localsocks` 中的本地设置、节点与项目的日志、
内核文件也可按需移除。删除 App 本身不会自动移除独立安装的 launchd 服务。

## 检查与限制

```bash
./scripts/check.sh
./macos/build.sh
```

检查命令不安装服务、不修改系统代理，也不连接代理节点。
源码来自个人工具的整理存档，尚未完成新安装后的端到端验证。
健康检测会访问第三方公网 IP 查询服务；其中的“直连”对照仍可能受其他 VPN 或 TUN 接管。
Linux 的 systemd 文件仅作为模板，需自行安装 Linux 内核并修改路径与运行用户。

TLS 验证默认开启。日志、配置和代理分享链接可能含敏感信息，发布问题或截图前请自行脱敏。

## License

[MIT](LICENSE)。Hysteria 内核由其上游项目独立维护，不随本仓库分发。
