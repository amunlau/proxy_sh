#!/usr/bin/env bash
# ====================================================================================================
# 通用代理开关 v1 —— Linux / WSL，支持本机与 LAN 代理
# ====================================================================================================
#
# 一、安装与使用
#   1. 将本文件保存为 ~/.config/proxy.sh（UTF-8 / LF 换行）。
#   2. 删除 ~/.bashrc 中旧的代理函数与自动开启区块，避免重复执行或相互覆盖。
#   3. 在 ~/.bashrc 末尾添加：
#        [ -r "$HOME/.config/proxy.sh" ] && source "$HOME/.config/proxy.sh"
#   4. 执行 source ~/.bashrc。
#
#   proxy_on                         # 自动选择；手动执行时忽略失败缓存
#   proxy_off                        # 清除本终端代理变量；不停止代理服务
#   proxy_refresh                    # 跳过所有缓存，按优先级重探并更新缓存
#   proxy_use 192.168.50.21:7897       # 临时切换本终端；先探测，不写自动发现缓存
#   proxy_use socks5h://127.0.0.1:7890 # 每个地址可指定协议
#   proxy_status                     # 查看配置、候选与缓存；不做联网探测
#   proxy_test                       # 依次测试预设网址，任一通过即成功
#   proxy_test https://example.com/  # 可传入一个或多个 HTTPS 测试网址
#
# 二、适用范围与依赖
#   - Bash 4.4+，主要面向 Linux / WSL；不是 sh、zsh 或 PowerShell 脚本。
#   - 必须 source；执行 bash proxy.sh 无法改变父 shell，会提示并退出。
#   - 探测依赖 timeout（或 gtimeout）、bash、awk、cksum、date；外网测试另需 curl。
#   - 缓存使用 mkdir / dirname / mktemp / mv；缓存不可写时仍可开启代理。
#   - 不改路由、系统设置、Git / apt 配置，不启动 Clash；无需 sudo。
#   - 仅影响本 shell 及后续子进程；程序须支持相应环境变量与代理协议。
#   - 支持 HTTP / HTTPS / SOCKS5 / SOCKS5H；默认 HTTP 适合 Clash mixed-port。
#     https_proxy=http://... 是正常写法：变量名对应目标网址，URL 协议对应代理本身。
#     socks5h 将目标域名交给代理解析；SOCKS 支持取决于客户端，不能保证所有工具通用。
#   - 不支持 PAC、带用户名密码的代理 URL、透明代理或系统全局代理。
#
# 三、候选优先级（先标准化，再去重）
#   ① PROXY_CANDIDATES 数组 → ② 外部候选文件 → ③ 本机 → ④ 网关（默认仅 WSL）
#   - 支持 hostname、IPv4、[IPv6]；不接受 URL 路径或认证信息。
#   - 未写协议补 PROXY_SCHEME，未写端口补 PROXY_PORT。
#   - 本机与网关发现可尝试 PROXY_PORTS 的多个端口。
#   - WSL 镜像网络 / WSL1 优先尝试 127.0.0.1；WSL2 NAT 再尝试 IPv4 默认网关。
#   - 普通 Linux 不默认把网关当成代理；不从 DNS 地址猜代理，不扫描局域网。
#   - 无默认路由的裸机需要配置 LAN 代理，且必须已有到代理主机的可用路由。
#
# 四、缓存、失败与手动切换
#   - 成功缓存默认 300 秒；复用前仍探测 TCP，失败自动尝试其他候选。
#   - 候选地址、顺序、协议或连接超时变化会使缓存失效。
#   - 失败缓存默认仅 20 秒，且只用于自动启动，减少离线时反复开终端的等待。
#     手动 proxy_on / proxy_refresh 随时重试，不必等待失败缓存到期。
#   - 缓存到期前不会主动切回更高优先级节点；需要时执行 proxy_refresh。
#   - proxy_use 只切换本终端，失败保留当前代理；下次 proxy_on 恢复自动选择。
#     长期优先使用某节点，请写到数组或候选文件前部；缓存不是持久钉选配置。
#   - 自动选择全部失败会清除旧代理变量；直连是否可用取决于网络。
#   - 配置错误 / 缺少必要依赖时保留原有代理并返回错误，便于修正后重试。
#   - 每个不同 host:port 最多等待 PROXY_CONNECT_TIMEOUT 秒；依次探测会累积耗时。
#     不同协议共用同一 host:port 只探测一次 TCP，不代表已验证协议支持。
#   - TCP 可达不等于代理或外网可用；proxy_test 才进行实际 HTTPS 请求。
#
# 五、启动与兼容性
#   - 仅在交互式 shell 自动开启；默认成功静默、失败提示，不因探测失败退出 shell。
#   - proxy_off 只关闭本终端；永久关闭自动开启请设置 PROXY_AUTO_ENABLE=0。
#   - LAN / WSL NAT 访问需代理监听相应网卡、开启 Allow LAN，且防火墙允许端口入站。
#   - 7897 仅为初始值，以实际配置为准；不会依据端口号认定某服务存在。
#   - no_proxy 的域名后缀、CIDR 支持取决于客户端；重要内网地址可显式逐个填写。
#   - 不修改调用者的 set -e / set -u / pipefail 等 shell 选项。
# ====================================================================================================

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    printf '请用 source 加载，例如：source ~/.config/proxy.sh\n' >&2
    exit 1
fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf '本脚本需要 Bash 4.4 或更新版本。\n' >&2
    return 1
fi

# ------------------------------------ 用户配置区 ------------------------------------
# 标量允许在 source 前 export 覆盖；加载后也可直接修改变量。
# 数组不能 export，跨终端保存节点建议使用外部候选文件。
# PROXY_AUTO 是 PROXY_AUTO_ENABLE 未设置时的兼容别名。
: "${PROXY_AUTO_ENABLE:=${PROXY_AUTO:-1}}"  # 1 自动开启；0 仅加载命令
: "${PROXY_QUIET:=0}"                    # 1 隐藏成功提示；错误、status、test 仍显示
: "${PROXY_AUTO_QUIET:=1}"               # 1 自动启动成功静默；0 显示成功提示
: "${PROXY_PORT:=7897}"                  # 省略端口时的默认值
: "${PROXY_SCHEME:=http}"                # http / https / socks5 / socks5h
: "${PROXY_DISCOVER_LOCAL:=1}"           # 1 尝试 127.0.0.1；0 不尝试
: "${PROXY_DISCOVER_GATEWAY:=auto}"      # auto 仅 WSL；1 所有环境；0 禁用
: "${PROXY_CONNECT_TIMEOUT:=2}"          # 单个 host:port 的 TCP 超时，正整数秒
: "${PROXY_CACHE_TTL:=300}"              # 成功缓存 TTL；0 禁用成功缓存
: "${PROXY_FAILURE_TTL:=20}"             # 自动启动失败缓存 TTL；0 禁用失败缓存
: "${PROXY_CACHE_FILE:=${XDG_CACHE_HOME:-$HOME/.cache}/shell-proxy/last}"
: "${PROXY_CANDIDATES_FILE:=${XDG_CONFIG_HOME:-$HOME/.config}/shell-proxy/hosts}"
: "${PROXY_TEST_TIMEOUT:=12}"            # 每个网址总超时；最多 N × 此值
: "${PROXY_EXPORT_HTTP_PROXY:=0}"        # 仅确有需要时设 1，额外导出 HTTP_PROXY
: "${NO_PROXY_LIST:=localhost,127.0.0.1,::1,.localhost,.local,.lan,.internal,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,169.254.0.0/16}"

# 数组若已在本 shell 中定义则保留；不要写成空格/逗号分隔的字符串。
if ! declare -p PROXY_PORTS >/dev/null 2>&1; then
    PROXY_PORTS=("$PROXY_PORT")          # 如 (7897 7890)；() 禁用自动端口探测
fi
if ! declare -p PROXY_CANDIDATES >/dev/null 2>&1; then
    PROXY_CANDIDATES=(
        # "192.168.50.21:7897"          # minisforum；裸机可取消注释
        # "192.168.50.254:7897"         # 仅当此设备确实运行代理才添加
        # "proxy.example.lan"          # 自动补协议与端口
        # "socks5h://[::1]:7890"        # 每个候选可单独指定协议
    )
fi
if ! declare -p PROXY_TEST_URLS >/dev/null 2>&1; then
    PROXY_TEST_URLS=(
        "https://www.gstatic.com/generate_204"
        "https://www.example.com/"
    )
fi

# 外部候选文件是纯文本，不会 source / eval；无需修改脚本即可增减节点。
# 每行一个地址，支持空行、前后空白、Windows CRLF、整行与行尾 # 注释：
#   192.168.50.21:7897              # 主节点
#   http://192.168.50.254:7897      # 备用节点
#   socks5h://proxy.example.lan:1080

# ------------------------------------ 地址与候选 ------------------------------------
_proxy_is_wsl() {
    [[ -n ${WSL_INTEROP:-} || -n ${WSL_DISTRO_NAME:-} ]] ||
        grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
}

# 输出标准 URL；只解析数据，不把地址拼入 shell 代码。
_proxy_normalize() {
    local c=${1:-} scheme=$PROXY_SCHEME host port=$PROXY_PORT
    c="${c#"${c%%[![:space:]]*}"}"
    c="${c%"${c##*[![:space:]]}"}"
    if [[ $c == *://* ]]; then scheme=${c%%://*}; c=${c#*://}; fi
    scheme=${scheme,,}
    case $scheme in http|https|socks5|socks5h) ;; *) return 1 ;; esac
    c=${c%/}                        # 允许只有末尾 /，拒绝真正的路径
    if [[ $c =~ ^\[([a-zA-Z0-9:.%_-]+)\](:([0-9]{1,5}))?$ ]]; then
        host=${BASH_REMATCH[1]}
        [[ $host == *:* ]] || return 1
        port=${BASH_REMATCH[3]:-$port}; host="[$host]"
    elif [[ $c =~ ^([a-zA-Z0-9_][a-zA-Z0-9_.-]*)(:([0-9]{1,5}))?$ ]]; then
        host=${BASH_REMATCH[1],,}; port=${BASH_REMATCH[3]:-$port}
    else return 1; fi
    [[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    printf '%s://%s:%s\n' "$scheme" "$host" "$((10#$port))"
}

_proxy_raw_candidates() {
    local c port gateway
    for c in "${PROXY_CANDIDATES[@]}"; do printf '%s\n' "$c"; done
    if [[ -r $PROXY_CANDIDATES_FILE ]]; then
        while IFS= read -r c || [[ -n $c ]]; do printf '%s\n' "${c%%#*}"; done < "$PROXY_CANDIDATES_FILE"
    elif [[ -e $PROXY_CANDIDATES_FILE ]]; then
        printf '⚠️  候选文件不可读：%s\n' "$PROXY_CANDIDATES_FILE" >&2
    fi
    if [[ $PROXY_DISCOVER_LOCAL == 1 ]]; then
        for port in "${PROXY_PORTS[@]}"; do printf '127.0.0.1:%s\n' "$port"; done
    fi
    if [[ $PROXY_DISCOVER_GATEWAY == 1 ]] ||
       { [[ $PROXY_DISCOVER_GATEWAY == auto ]] && _proxy_is_wsl; }; then
        if command -v ip >/dev/null 2>&1; then
            while IFS= read -r gateway; do
                for port in "${PROXY_PORTS[@]}"; do printf '%s:%s\n' "$gateway" "$port"; done
            done < <(ip -4 route show default 2>/dev/null |
                awk '{for (i=1;i<NF;i++) if ($i=="via") print $(i+1)}')
        fi
    fi
    return 0
}

_proxy_candidates() {
    local c normalized
    while IFS= read -r c; do
        [[ $c =~ ^[[:space:]]*$ ]] && continue
        if normalized=$(_proxy_normalize "$c"); then printf '%s\n' "$normalized"
        else printf '⚠️  跳过无效候选（检查协议、主机及端口）。\n' >&2; fi
    done < <(_proxy_raw_candidates) | awk '!seen[$0]++'
}

# ------------------------------------ 依赖、探测与缓存 ------------------------------
_proxy_check_config() {
    local name value
    for name in PROXY_AUTO_ENABLE PROXY_QUIET PROXY_AUTO_QUIET PROXY_DISCOVER_LOCAL PROXY_EXPORT_HTTP_PROXY; do
        [[ ${!name} == 0 || ${!name} == 1 ]] || { printf '❌ %s 必须为 0 或 1。\n' "$name" >&2; return 1; }
    done
    case $PROXY_DISCOVER_GATEWAY in auto|0|1) ;; *) printf '❌ 网关发现须为 auto、0 或 1。\n' >&2; return 1 ;; esac
    for name in PROXY_CONNECT_TIMEOUT PROXY_TEST_TIMEOUT; do
        [[ ${!name} =~ ^[1-9][0-9]{0,3}$ ]] || { printf '❌ %s 须为 1–9999 秒。\n' "$name" >&2; return 1; }
    done
    for name in PROXY_CACHE_TTL PROXY_FAILURE_TTL; do
        [[ ${!name} =~ ^(0|[1-9][0-9]{0,8})$ ]] || { printf '❌ %s 须为非负整数（至多 9 位）。\n' "$name" >&2; return 1; }
    done
    if ! _proxy_normalize localhost >/dev/null; then printf '❌ 默认协议或端口错误。\n' >&2; return 1; fi
    for value in "${PROXY_PORTS[@]}"; do
        [[ $value =~ ^[0-9]{1,5}$ ]] && (( 10#$value >= 1 && 10#$value <= 65535 )) || {
            printf '❌ PROXY_PORTS 中存在无效端口。\n' >&2; return 1;
        }
    done
    return 0
}

_proxy_check_deps() {
    local dependency
    for dependency in bash awk cksum date; do
        command -v "$dependency" >/dev/null 2>&1 || { printf '❌ 缺少依赖：%s\n' "$dependency" >&2; return 1; }
    done
    command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || {
        printf '❌ 缺少 timeout / gtimeout；不会降级为可能无限等待的探测。\n' >&2; return 1;
    }
}

_proxy_tcp_ok() {
    local c endpoint host port limiter=timeout
    c=$(_proxy_normalize "$1") || return 1
    endpoint=${c#*://}; host=${endpoint%:*}; port=${endpoint##*:}
    host=${host#\[}; host=${host%\]}
    command -v timeout >/dev/null 2>&1 || limiter=gtimeout
    "$limiter" "$PROXY_CONNECT_TIMEOUT" bash -c \
        'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null
}

# 四行数据：版本、候选指纹、时间戳、标准 URL（- 表示失败）；从不执行缓存内容。
# 同目录原子替换，避免读到半份内容；写失败不影响本次开启。
# 多终端同时更新时最后写入生效；缓存不是持久节点配置。
_proxy_cache_write() (
    local key=$1 endpoint=$2 dir tmp
    if [[ $endpoint == - ]]; then (( PROXY_FAILURE_TTL > 0 )) || return 0
    else (( PROXY_CACHE_TTL > 0 )) || return 0; fi
    dir=$(dirname -- "$PROXY_CACHE_FILE") || return 0
    umask 077
    mkdir -p -- "$dir" 2>/dev/null || return 0
    tmp=$(mktemp "$dir/.last.XXXXXX" 2>/dev/null) || return 0
    if ! { printf 'v1\n%s\n%s\n%s\n' "$key" "$(date +%s)" "$endpoint" > "$tmp" &&
           mv -f -- "$tmp" "$PROXY_CACHE_FILE"; } 2>/dev/null; then
        rm -f -- "$tmp" 2>/dev/null || :
    fi
    return 0
)

_proxy_detect() {
    local c endpoint now key version='' cached_key='' ts='' cached='' age
    local -a candidates=()
    local -A tried=()
    mapfile -t candidates < <(_proxy_candidates)
    now=$(date +%s)
    key=$(printf '%s\n' "$PROXY_CONNECT_TIMEOUT" "${candidates[@]}" | cksum)
    if [[ ${_PROXY_FORCE_REFRESH:-0} != 1 && -r $PROXY_CACHE_FILE ]]; then
        { IFS= read -r version; IFS= read -r cached_key; IFS= read -r ts; IFS= read -r cached; } \
            < "$PROXY_CACHE_FILE" || :
        if [[ $version == v1 && $cached_key == "$key" && $ts =~ ^[0-9]{1,12}$ ]] && (( now >= 10#$ts )); then
            age=$((now - 10#$ts))
            if [[ $cached == - && ${_PROXY_AUTO_START:-0} == 1 ]] && (( age < PROXY_FAILURE_TTL )); then
                printf '⚠️  最近探测失败（%ss 前）；手动 proxy_on 可立即重试。\n' "$age" >&2
                return 1
            fi
            if (( age < PROXY_CACHE_TTL )); then
                for c in "${candidates[@]}"; do
                    [[ $c == "$cached" ]] || continue
                    if _proxy_tcp_ok "$c"; then printf '%s\n' "$c"; return 0; fi
                    tried["${c#*://}"]=1
                    break
                done
            fi
        fi
    fi
    for c in "${candidates[@]}"; do
        endpoint=${c#*://}
        [[ ${tried[$endpoint]:-0} == 1 ]] && continue
        tried["$endpoint"]=1
        if _proxy_tcp_ok "$c"; then
            _proxy_cache_write "$key" "$c"
            printf '%s\n' "$c"
            return 0
        fi
    done
    # 删除旧成功缓存，避免写失败或禁用失败缓存时继续残留旧结果。
    rm -f -- "$PROXY_CACHE_FILE" 2>/dev/null || :
    _proxy_cache_write "$key" -
    return 1
}

# ------------------------------------ 环境变量与对外命令 ----------------------------
_proxy_clear_env() {
    unset http_proxy https_proxy all_proxy ftp_proxy no_proxy
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY FTP_PROXY NO_PROXY
}

_proxy_apply() {
    local url=$1
    export http_proxy="$url" https_proxy="$url" all_proxy="$url" ftp_proxy="$url"
    export HTTPS_PROXY="$url" ALL_PROXY="$url" FTP_PROXY="$url"
    export no_proxy="$NO_PROXY_LIST" NO_PROXY="$NO_PROXY_LIST"
    # curl 不读取大写 HTTP_PROXY；默认清除遗留值，可按客户端需要显式开启。
    if [[ $PROXY_EXPORT_HTTP_PROXY == 1 ]]; then export HTTP_PROXY="$url"; else unset HTTP_PROXY; fi
}

_proxy_success() { [[ $PROXY_QUIET == 1 ]] || printf '%s\n' "$*"; return 0; }

proxy_on() {
    local c
    _proxy_check_config && _proxy_check_deps || return 1
    if ! c=$(_proxy_detect); then
        _proxy_clear_env
        printf '❌ 自动选择未成功，已清除旧代理变量；用 proxy_status 查看候选。\n' >&2
        return 1
    fi
    _proxy_apply "$c"
    _proxy_success "✅ Proxy is ON ($c；TCP 端口可达，外网请用 proxy_test 验证)"
}

proxy_off() {
    _proxy_clear_env
    _proxy_success '✅ Proxy is OFF（当前 shell；新终端仍按配置自动开启）'
}

proxy_refresh() {
    local _PROXY_FORCE_REFRESH=1
    # 标志保证跳过读取；无需依赖删除成功；新结果仍按 TTL 配置写入。
    proxy_on
}

proxy_use() {
    local c
    [[ $# == 1 ]] || { printf '用法：proxy_use [协议://]主机[:端口]\n' >&2; return 1; }
    _proxy_check_config && _proxy_check_deps || return 1
    c=$(_proxy_normalize "$1") || { printf '❌ 地址格式无效；当前代理保持不变。\n' >&2; return 1; }
    _proxy_tcp_ok "$c" || { printf '❌ 指定端口不可达；当前代理保持不变。\n' >&2; return 1; }
    _proxy_apply "$c"
    _proxy_success "✅ 已临时切换至 $c；proxy_on 恢复自动选择，proxy_test 验证外网。"
}

proxy_status() {
    local c name version='' key='' ts='' cached='' age ttl
    if _proxy_is_wsl; then printf '环境        = WSL\n'; else printf '环境        = 非 WSL\n'; fi
    for name in http_proxy https_proxy all_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY FTP_PROXY NO_PROXY; do
        printf '%-12s= %s\n' "$name" "${!name:-未设置}"
    done
    printf '自动开启    = %s；网关发现 = %s；默认协议 = %s\n' "$PROXY_AUTO_ENABLE" "$PROXY_DISCOVER_GATEWAY" "$PROXY_SCHEME"
    printf '候选文件    = %s\n缓存文件    = %s\n候选列表（优先级从高到低）：\n' "$PROXY_CANDIDATES_FILE" "$PROXY_CACHE_FILE"
    while IFS= read -r c; do printf '  %s\n' "$c"; done < <(_proxy_candidates)
    if [[ -r $PROXY_CACHE_FILE ]]; then
        { IFS= read -r version; IFS= read -r key; IFS= read -r ts; IFS= read -r cached; } < "$PROXY_CACHE_FILE" || :
        if [[ $version == v1 && $ts =~ ^[0-9]{1,12}$ ]]; then
            age=$(( $(date +%s) - 10#$ts )); ttl=$PROXY_CACHE_TTL
            if [[ $cached == - ]]; then cached='全部失败（仅自动启动复用）'; ttl=$PROXY_FAILURE_TTL; fi
            printf '缓存记录    = %s (age %ss / TTL %ss)\n' "$cached" "$age" "$ttl"
            printf '              历史记录；是否复用还取决于时间、候选指纹和端口检查。\n'
        else printf '缓存        = 旧版或无效格式，下次自动忽略\n'; fi
    else printf '缓存        = 无\n'; fi
}

proxy_test() {
    local url code rc
    local -a urls=("${PROXY_TEST_URLS[@]}")
    [[ $# == 0 ]] || urls=("$@")
    [[ -n ${https_proxy:-} ]] || { printf '❌ 请先执行 proxy_on 或 proxy_use。\n' >&2; return 1; }
    command -v curl >/dev/null 2>&1 || { printf '❌ 请先安装 curl。\n' >&2; return 1; }
    [[ $PROXY_TEST_TIMEOUT =~ ^[1-9][0-9]{0,3}$ ]] || { printf '❌ 测试超时须为 1–9999 秒。\n' >&2; return 1; }
    (( ${#urls[@]} > 0 )) || { printf '❌ 未配置测试网址。\n' >&2; return 1; }
    for url in "${urls[@]}"; do
        [[ $url == https://* && $url != *[[:space:]]* ]] || { printf '❌ 测试网址须为有效的 https:// URL。\n' >&2; return 1; }
    done
    for url in "${urls[@]}"; do
        printf '正在测试 %s → %s ...\n' "$https_proxy" "$url"
        # -q 忽略 .curlrc；显式指定代理，禁止 no_proxy 绕过；保留 TLS 证书校验。
        # 不跟随重定向；2xx/3xx 只表示这个目标有正常响应，不保证所有网站可访问。
        if code=$(curl -q --silent --show-error --output /dev/null \
            --write-out '%{http_code}' --proxy "$https_proxy" --noproxy '' \
            --connect-timeout "$PROXY_CONNECT_TIMEOUT" --max-time "$PROXY_TEST_TIMEOUT" --url "$url"); then
            case $code in
                2[0-9][0-9]|3[0-9][0-9]) printf '✅ 当前代理可访问该测试网址（HTTP %s）。\n' "$code"; return 0 ;;
            esac
            rc=0
        else rc=$?; fi
        printf '⚠️  本网址未通过（curl=%s，HTTP=%s）。\n' "$rc" "${code:-000}" >&2
    done
    printf '❌ 所有测试网址均未通过；检查代理协议、上游网络，或更换测试网址。\n' >&2
    return 1
}

# ---- AUTO_PROXY_BLOCK：仅交互式终端；局部设置不覆盖手动命令偏好 ----
_proxy_auto_start() {
    local _PROXY_AUTO_START=1 PROXY_QUIET=$PROXY_AUTO_QUIET
    proxy_on
}
if [[ $- == *i* && $PROXY_AUTO_ENABLE == 1 ]]; then
    if ! _proxy_auto_start; then
        printf '⚠️  自动开启未成功；检查配置后执行 proxy_on / proxy_refresh 重试。\n' >&2
    fi
fi
# source 成功不等于代理或外网可用；加载函数后正常返回。
:
# ---- end AUTO_PROXY_BLOCK ----
