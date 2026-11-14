# 永久累计流量增强版 / Lifetime traffic patch

Fork: https://github.com/luosx0403/komari-agent

在官方 Agent 上增加独立的永久累计模式，支持 Linux、macOS（Intel / Apple Silicon）。主控协议不变；增强版依旧上报 `network.totalUp` / `totalDown`，速度仍根据原始网卡读数计算。

## 一键安装到现有服务

需要 Python 3.9+、已安装的 Komari Agent，以及 Linux systemd 或 macOS launchd。脚本保留现有启动参数、主控地址和令牌，只替换二进制并增加增强版配置。Linux 自动探测用户/系统服务，macOS 自动探测官方命名的 LaunchAgent/LaunchDaemon。

```sh
curl -fL https://github.com/luosx0403/komari-agent/releases/latest/download/install-traffic-patch.sh -o install-komari-traffic-patch.sh
sh install-komari-traffic-patch.sh
```

安装前只读检查目标：

```sh
sh install-komari-traffic-patch.sh --dry-run
```

二进制从 GitHub Release 下载；安装前强制校验 GitHub API 提供的 SHA-256 digest，拒绝无摘要或校验失败的资产。Release 同时包含 `SHA256SUMS`。脚本会先备份二进制和服务设置；启动失败时恢复备份，不打印令牌或服务命令行。

系统级安装使用 Linux Polkit / macOS 图形认证窗口，密码只在图形窗口输入。脚本不会使用终端密码回退。SSH 可使用目标机器的活动图形会话认证（下节说明）；没有可用桌面时输出已准备的命令，供目标机器的本地图形桌面执行。用户级安装不需要管理员权限。

## iStoreOS 定向适配

已针对 iStoreOS 25.12.5（x86/64，Python 3.13，root、procd）适配。复用 Actions 的 `komari-agent-linux-amd64`，不要求 systemd、不安装额外依赖。支持的是现有标准单实例 procd Komari 服务；其他 OpenWrt 版本和架构未做实机验证。

在该环境直接执行同一安装脚本即可：

```sh
python3 install-komari-traffic-patch.sh --dry-run
python3 install-komari-traffic-patch.sh
```

默认探测 `/etc/init.d/komari-agent` 和 procd 的实际可执行文件，保留原有主控地址、令牌与启动参数，在 `procd_close_instance` 前插入受标记的环境设置。默认每 **300 秒**写盘，上报之间在内存累计，正常停止时再保存；默认状态文件是持久化 overlay 上的 `/etc/komari-agent-lifetime/network-total.json`，拒绝将二进制或状态放在 `/tmp`、`/run`、`/dev`（包括解析软链接后指向这些目录的 `/var`）。自动更新默认保持原有设置。

```sh
# 缩短断电时可能丢失的窗口，但会增加闪存写入
python3 install-komari-traffic-patch.sh --save-interval 60

# 每次上报前写盘；更适合状态放在外置 SSD 的情况
python3 install-komari-traffic-patch.sh --network-sync-on-report true

# 回滚与恢复官方二进制仍可使用
python3 install-komari-traffic-patch.sh --rollback
python3 install-komari-traffic-patch.sh --official
```

正常 Agent 重启和正常系统重启会保存并接续累计量；异常断电最多可能丢失上一次落盘后的增量，默认约 5 分钟。状态持久化针对普通重启，未承诺固件升级、恢复出厂或删除 overlay 后保留。通过已有 SSH 私钥登录 root 时无需再次提权；私钥不由脚本管理。

## SSH 下认证

SSH 不再被直接拒绝，默认 `--auth auto` 会探测真实的目标桌面：

- **Linux Cinnamon**：确认同一用户的活动本地图形登录、会话 D-Bus、Cinnamon 拥有者和会话 scope。先由 Cinnamon 启动无特权探测脚本，验证它进入正确 `session-*.scope`，再在该会话内发起 Polkit。若会话没有运行认证代理，但安装了 GNOME Polkit 代理，则在该图形会话临时启动一个；不重复启动或重试认证。
- **Linux GNOME/KDE 等**：本地图形终端可在验证进程与代理属于同一会话后直接使用 Polkit。目前不冒用 Cinnamon 接口从 SSH 启动其他桌面；可使用下面的免交互机制。
- **macOS**：确认 SSH 用户就是当前物理桌面登录用户，通过 `launchctl bootstrap gui/<uid>` 启动一次性授权任务，让管理员窗口出现在该桌面，任务结束后卸载。

**认证窗口在目标机器的物理桌面，不在 SSH 终端，也不因 X11 转发而转移。** 脚本触发前明确提醒，只在图形窗口输入密码。取消即停止，不回退到终端索取密码。

```sh
# 只探测认证路线，不提权、不弹窗、不安装
sh install-komari-traffic-patch.sh --auth-check

# SSH + 可用的目标桌面（默认行为）
sh install-komari-traffic-patch.sh --auth desktop

# 纯无头 SSH：显式选择事先已配置的免交互 sudo
sh install-komari-traffic-patch.sh --auth sudo-n
```

`sudo-n` 仅运行 `sudo -n`，不会配置 sudoers、请求/读取密码或改用其他认证方式；现有规则不允许该操作时立即失败。也可以由用户在现有 root SSH 会话直接执行脚本，或使用不需要管理员权限的用户级安装。`--auth none` 禁止脚本自动提权。

无法找到可靠桌面路线时会保留准备文件并给出本地执行命令。桌面授权等待超过 10 分钟或 SSH 端按 Ctrl+C 后，保留暂存文件，避免删除仍在使用的安装文件；需在目标桌面关闭窗口、确认任务结束后再重试。

## 安装参数

```sh
# 指定 systemd 服务、作用域和版本
sh install-komari-traffic-patch.sh --service komari-agent --scope system --version 1.5.10001

# macOS 非默认 plist
sh install-komari-traffic-patch.sh --plist "$HOME/Library/LaunchAgents/com.komari.my-agent.plist"

# 状态路径和离线时的保存间隔（秒）
sh install-komari-traffic-patch.sh --state-file /absolute/path/network-total.json --save-interval 5

# 仍使用增强版二进制，改回官方统计逻辑
sh install-komari-traffic-patch.sh --mode official

# 换回真正的官方二进制，删除增强版服务设置
sh install-komari-traffic-patch.sh --official

# 恢复上一次安装前的二进制和配置，保留永久累计状态文件
sh install-komari-traffic-patch.sh --rollback

# 仅下载校验后的二进制；不修改服务
sh install-komari-traffic-patch.sh --download-only ./komari-download

# 默认不改变自动更新设置；可显式启用/禁用
sh install-komari-traffic-patch.sh --enable-auto-update
sh install-komari-traffic-patch.sh --disable-auto-update

# 安装后延迟重启服务
sh install-komari-traffic-patch.sh --no-restart
```

脚本只支持给现有服务打补丁，不负责首次创建主控认证配置。`--binary` 必须与检测到的服务可执行文件一致。`--official`、`--rollback`、`--mode official` 是不同操作；切换不删除历史累计状态。`--rollback` 恢复最近一次成功安装前的版本，不循环切换。

## Agent 新参数

| 参数 | 环境变量 / JSON 字段 | 默认值 |
| --- | --- | --- |
| `--network-mode official\|lifetime` | `AGENT_NETWORK_MODE` / `network_mode` | `official`；安装脚本设置 `lifetime` |
| `--network-state-file /absolute/path` | `AGENT_NETWORK_STATE_FILE` / `network_state_file` | 工作目录的 `network-total.json` |
| `--network-save-interval 5` | `AGENT_NETWORK_SAVE_INTERVAL` / `network_save_interval` | 5 秒，允许 0.1–3600 |
| `--network-sync-on-report=true/false` | `AGENT_NETWORK_SYNC_ON_REPORT` / `network_sync_on_report` | Agent 默认为 true，iStoreOS 安装脚本设为 false |
| `--update-repo owner/name` | `AGENT_UPDATE_REPO` / `update_repo` | 编译时的仓库；本 fork 为 `luosx0403/komari-agent` |
| `--update-repo official` | 同上 | 选择官方更新源；实际降级应使用安装脚本 `--official` |

保留官方 `--disable-auto-update` 默认 false，不因永久累计而强制关闭。增强版自动从 fork 同 major.minor 的新版本更新，避免被官方二进制覆盖功能。官方配置优先级不变：默认值 < CLI < 环境变量 < JSON；如果原 JSON 显式写了这些新字段，它会覆盖安装脚本环境变量。

`lifetime` 与 `--month-rotate` 非零互斥。要使用原有月度模式，先切到 `--network-mode official`。`build-info` 子命令只输出构建/功能信息，不启动采集或连接主控。

## 持久化语义

- 首次启用时接入当前筛选后网卡的已有累计量，之后永远增量累计，不按月清零。
- Linux 使用内核 boot ID；macOS 使用 `kern.boottime`。同次开机重启 Agent 只计算新流量；系统重启则将新开机网卡读数加到历史总量。
- 每张网卡单独保留基线，沿用上游 `--include-nics` / `--exclude-nics` 规则，防止单个网卡归零影响其他网卡。
- 默认后台每 5 秒保存一次，主控不可达时仍采样；默认每次上报前也先保存；iStoreOS 的减少写盘模式除外。正常关闭做最后一次保存。
- 状态文件通过临时文件、fsync、原子 rename 写入，另有进程锁；状态损坏或被另一进程占用会拒绝启动，不静默清零。运行中写盘失败保留已提交的累计量和基线，并报告错误，恢复后补计。
- 默认系统服务位置：Linux `/var/lib/komari-agent-lifetime/network-total.json`；macOS `/Library/Application Support/Komari/network-total.json`。用户服务使用所属用户的状态目录。备份位于二进制旁 `.traffic-patch-backups/`。

突然断电、内核崩溃或强制重启可能丢失最后一次落盘后、上一次开机尚未保存的增量；不能恢复启用前已经丢失的历史流量。网卡在两次采样间重建且计数已超过旧读数时，无法仅靠字节计数精确识别。切回官方模式期间跨重启的未采集流量也不能补回。

## 构建与验证

GitHub Actions `Test and Release Lifetime Traffic` 在 Linux/macOS 原生运行 Go race 测试和安装器回滚测试，然后构建 Linux/macOS × amd64/arm64 四个二进制。全部通过才发布 Release。版本为 `1.5.(10000 + Actions run_number)`，与 fork 内继承的官方标签区分，并保持官方更新器可比较的 SemVer。

```sh
go test -race -skip '^(TestICMPPing|TestTCPPing|TestHTTPPing)$' ./...
python3 -m unittest discover -s scripts -p 'test_traffic_installer.py' -v
```

排除的三项是上游依赖外部 IPv4/IPv6 测试目标或 raw ICMP 权限的联网集成测试，不属于此次修改。原上游 Docker/发布工作流在 fork 中跳过，由增强版工作流负责测试和发布。
