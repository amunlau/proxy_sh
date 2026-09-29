# proxy_sh

Linux / WSL 通用代理开关（**v1 · 初始版本**）—— 一个通过 `source` 加载的 Bash 脚本：自动发现本机或局域网中可用的 HTTP / HTTPS / SOCKS5 代理，为当前终端设置代理环境变量，并附带成功/失败缓存、候选优先级、临时切换与联网测试能力。

> 脚本头部注释包含最完整的说明；本文档是它的提炼。

## 特性

- **自动发现代理**：按「候选数组 → 外部候选文件 → 本机 127.0.0.1 → WSL 默认网关」的顺序生成候选，标准化、去重后依次做 TCP 探测。
- **多协议支持**：`http` / `https` / `socks5` / `socks5h`；默认 `http`，适配 Clash 等 mixed-port 代理。每个地址可单独指定协议。
- **智能缓存**：成功缓存默认 300 秒、失败缓存仅 20 秒；候选指纹变化或 TTL 到期自动失效，复用前仍会重新探测 TCP，避免「缓存是死的」。
- **手动控制**：`proxy_use` 临时切换本终端、`proxy_refresh` 强制重探、`proxy_status` 查看配置与缓存、`proxy_test` 用真实 HTTPS 请求验证外网。
- **克制与安全**：不改路由、不改系统 / Git / apt 配置、不启动任何代理进程、无需 sudo；候选文件只被解析、从不 `source` / `eval`；不修改调用者的 `set -e` / `set -u` / `pipefail` 等 shell 选项。

## 安装

1. 将 `proxy.sh` 保存为 `~/.config/proxy.sh`（UTF-8、LF 换行）。
2. 删除 `~/.bashrc` 中旧的代理函数与自动开启区块，避免重复执行或相互覆盖。
3. 在 `~/.bashrc` 末尾添加：

   ```bash
   [ -r "$HOME/.config/proxy.sh" ] && source "$HOME/.config/proxy.sh"
   ```

4. 执行 `source ~/.bashrc`。

> 必须 `source`：脚本只修改当前 shell 的环境变量，直接执行 `bash proxy.sh` 无法影响父 shell（脚本会提示并退出）。

## 使用

| 命令 | 说明 |
| --- | --- |
| `proxy_on` | 自动选择最佳代理并开启（手动执行时忽略失败缓存） |
| `proxy_off` | 清除本终端代理变量；不停止代理服务 |
| `proxy_refresh` | 跳过所有缓存，按优先级重新探测并更新缓存 |
| `proxy_use 192.168.50.21:7897` | 临时切换本终端到指定地址；先探测，不写自动发现缓存 |
| `proxy_use socks5h://127.0.0.1:7890` | 每个地址可指定协议 |
| `proxy_status` | 查看配置、候选与缓存；不做联网探测 |
| `proxy_test` | 依次测试预设网址，任一通过即成功 |
| `proxy_test https://example.com/` | 可传入一个或多个 HTTPS 测试网址 |

`proxy_test` 示例输出：

```
正在测试 http://127.0.0.1:7897 → https://www.gstatic.com/generate_204 ...
✅ 当前代理可访问该测试网址（HTTP 204）。
```

## 配置

所有配置均为变量，可在 `source` 之前 `export` 覆盖，也可加载后直接修改。

### 标量变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PROXY_AUTO_ENABLE` | `1` | `1` 交互式 shell 自动开启；`0` 仅加载命令 |
| `PROXY_QUIET` | `0` | `1` 隐藏成功提示；错误 / status / test 仍显示 |
| `PROXY_AUTO_QUIET` | `1` | `1` 自动开启成功静默；`0` 显示成功提示 |
| `PROXY_PORT` | `7897` | 省略端口时的默认值 |
| `PROXY_SCHEME` | `http` | 默认协议：http / https / socks5 / socks5h |
| `PROXY_DISCOVER_LOCAL` | `1` | `1` 尝试 127.0.0.1 |
| `PROXY_DISCOVER_GATEWAY` | `auto` | `auto` 仅 WSL；`1` 所有环境；`0` 禁用 |
| `PROXY_CONNECT_TIMEOUT` | `2` | 单个 host:port 的 TCP 超时（秒） |
| `PROXY_CACHE_TTL` | `300` | 成功缓存 TTL（秒）；`0` 禁用 |
| `PROXY_FAILURE_TTL` | `20` | 自动启动失败缓存 TTL（秒）；`0` 禁用 |
| `PROXY_CACHE_FILE` | `~/.cache/shell-proxy/last` | 缓存文件路径 |
| `PROXY_CANDIDATES_FILE` | `~/.config/shell-proxy/hosts` | 外部候选文件路径 |
| `PROXY_TEST_TIMEOUT` | `12` | 每个测试网址总超时（秒）；最多 N × 此值 |
| `PROXY_EXPORT_HTTP_PROXY` | `0` | `1` 额外导出 `HTTP_PROXY`（一般不需要） |
| `NO_PROXY_LIST` | `localhost,127.0.0.1,::1,.localhost,.local,.lan,.internal,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,169.254.0.0/16` | 写入 `no_proxy` / `NO_PROXY` 的值 |

### 数组变量（不能 export，可在 shell 中预先定义）

| 变量 | 说明 |
| --- | --- |
| `PROXY_PORTS` | 端口探测列表，如 `(7897 7890)`；`()` 禁用自动端口探测 |
| `PROXY_CANDIDATES` | 候选节点数组，如 `("192.168.50.21:7897" "socks5h://[::1]:7890")` |
| `PROXY_TEST_URLS` | 测试网址数组 |

### 外部候选文件

纯文本，每行一个地址；支持空行、前后空白、Windows CRLF、整行与行尾 `#` 注释。不会 `source` / `eval`，无需修改脚本即可增减节点：

```
192.168.50.21:7897              # 主节点
http://192.168.50.254:7897      # 备用节点
socks5h://proxy.example.lan:1080
```

## 候选优先级

① `PROXY_CANDIDATES` 数组 → ② 外部候选文件 → ③ 本机 `127.0.0.1` → ④ 默认网关（默认仅 WSL）。

- 支持 hostname、IPv4、`[IPv6]`；不接受 URL 路径或认证信息。
- 未写协议补 `PROXY_SCHEME`，未写端口补 `PROXY_PORT`。
- WSL 镜像网络 / WSL1 优先尝试 `127.0.0.1`；WSL2 NAT 再尝试 IPv4 默认网关。
- 普通 Linux 不默认把网关当作代理；不从 DNS 地址猜代理，不扫描局域网。

## 缓存与失败

- 成功缓存默认 300 秒；复用前仍探测 TCP，失败自动尝试其他候选。
- 候选地址、顺序、协议或连接超时变化会使缓存失效。
- 失败缓存仅 20 秒，且只用于自动启动——离线时反复开终端不会被反复阻塞；手动 `proxy_on` / `proxy_refresh` 随时重试。
- 缓存到期前不会主动切回更高优先级节点；需要时执行 `proxy_refresh`。
- `proxy_use` 只切换本终端；长期优先使用某节点请写到数组或候选文件前部。
- 每个不同 host:port 最多等待 `PROXY_CONNECT_TIMEOUT` 秒，依次探测会累积耗时。
- TCP 可达 ≠ 代理可用；`proxy_test` 才做实际 HTTPS 请求。

## 依赖

- Bash 4.4+（脚本不是 sh / zsh / PowerShell）。
- 探测：`timeout`（或 `gtimeout`）、`bash`、`awk`、`cksum`、`date`。
- 外网测试：`curl`。
- 缓存：`mkdir` / `dirname` / `mktemp` / `mv`（缓存不可写时仍可开启代理）。

## 常见问题

- **为什么必须 `source`？** 环境变量只属于当前 shell 及其子进程；在子进程中 export 无法影响父 shell。
- **自动开启失败、手动 `proxy_on` 却成功？** 失败缓存只对自动启动生效（默认 20 秒），手动执行会立即重试。
- **想长期固定用某个节点？** 把它写到 `PROXY_CANDIDATES` 数组或候选文件前部；缓存不是持久钉选配置。
- **提示 `⚠️ 跳过无效候选`？** 检查协议、主机与端口格式，候选不接受路径或认证信息。
- **WSL 里访问 LAN 代理不通？** 确认代理监听对应网卡、开启 Allow LAN，且防火墙允许端口入站。

## 许可证

[MIT](LICENSE)
