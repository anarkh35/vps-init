#!/usr/bin/env bash
# ============================================================
# ---- CRLF 自愈（必须放在最前面，早于任何其它代码）----
# Windows 编辑器 / 某些传输工具会把 LF 存成 CRLF。bash 解析到行尾的 \r
# 会报 "$'\r': command not found" 与 "syntax error" —— 而且是**解析阶段**
# 就失败，运行期代码（哪怕写在文件开头）也救不了：复合命令（if/then/fi）
# 必须整块解析成功才执行，then\r / fi\r 会让自愈块自己先崩。
#
# 对策：下面这个块里**每一行都以 # 结尾**，行尾的 \r 落进注释被忽略，
# 于是整块在任何行尾风格下都能解析成功 → 执行 tr -d '\r' 生成净化副本
# → exec 重跑净化副本。参数用 "$@" 原样带过去（exec 会重置位置参数，
# 但显式传 "$@" 就没问题），净化副本跑完自己删掉自己。
#
# 注意：块内第一行是 sh→bash 兜底。Debian 的 sh=dash，不认 pipefail，
# 而且 dash 也不认 $'\r' 语法；先用 exec 换回 bash，后面的逻辑才有效。
# >>> CRLF-SELFHEAL-BEGIN #
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi #
if [ -n "${BASH_VERSION:-}" ] && grep -q $'\r' "$0" 2>/dev/null; then #
  _crlf_clean="${TMPDIR:-/tmp}/.vps-init.crlf.$$" #
  export _VPSINIT_CLEAN="$_crlf_clean" #
  if tr -d '\r' < "$0" > "$_crlf_clean" 2>/dev/null; then #
    exec bash "$_crlf_clean" "$@" #
  fi #
  echo "[!] 检测到 CRLF 行尾但净化失败，请手动执行: sed -i 's/\\r\$//' $0" >&2 #
  exit 1 #
fi #
# 仅净化副本路径会命中：跑完（无论成功失败）删掉自己
if [ -n "${_VPSINIT_CLEAN:-}" ]; then #
  trap 'rm -f "${_VPSINIT_CLEAN}"' EXIT #
fi #
# <<< CRLF-SELFHEAL-END #
# ============================================================
# vps-init.sh  —  Debian 12/13 新 VPS 开荒一键配置
#
# 覆盖：系统基线 / SSH 加固 / iptables 防火墙 / fail2ban /
#       BBR+TCP 调优 / sing-box / Reality 回落站 / 配置生成 / 交付汇总
#
# 用法：
#   bash vps-init.sh                      # 交互式菜单
#   bash vps-init.sh --yes                # 非交互，全部模块按默认/参数执行
#   bash vps-init.sh --modules 1,2,3 --ssh-port 51736 --pubkey "ssh-ed25519 AAAA..."
#   bash vps-init.sh --print-config       # 仅渲染 sing-box 配置到 stdout（校验用）
#   bash vps-init.sh --self-test          # 内置自检（只读、不联网、不改系统）
#
# ------------------------------------------------------------
# 分区目录
#   用 grep -n '^# ===== §' vps-init.sh 可直接跳转，锚点不会随行号漂移。
# ------------------------------------------------------------
#   §1  输出与日志        info/ok/warn/err/die/run
#   §2  apt 助手          apt_wait_lock / apt_update / apt_install
#   §3  网络下载          fetch_file / fetch_stdout（超时 + 退避重试 + 本地缓存）
#   §4  分享链接编码      urlenc
#   §5  交互助手          ask / ask_yn
#   §6  参数解析          usage / need_val / mark_cli / while-case
#   §7  取值合法性        is_port/need_port/is_duration/is_hostname/is_uuid/… + validate_settings
#   §8  状态存取          STATE_KEYS / save_state / load_state
#   §9  环境校验          preflight
#   §10 模块注册表         MOD_NAMES / MOD_FUNCS / MOD_ON / menu_select
#   §11 业务模块 1-9       m_base … m_summary
#   §12 JSON 构造器        json_escape / j_kv / j_lit / j_obj / j_arr
#   §13 配置渲染           render_config / render_client_outbounds / 分享链接
#   §14 只读状态           show_status
#   §14b 只读体检         cmd_doctor（--doctor）
#   §15 内置自检           self_test
#   §16 主流程             main
#
# ------------------------------------------------------------
# 工程约定（改动前请先读这三条）
# ------------------------------------------------------------
#   1) 默认值只在 init_defaults() 一处定义；状态持久化只在 STATE_KEYS 一处登记。
#      其它任何位置都不得再出现 `VAR="${VAR:-默认}"`，否则默认值会有两个来源。
#   2) 凡会进入 JSON 的动态值，必须经 json_escape()（§12）渲染，
#      禁止把变量直接拼进 JSON 模板 —— 一个引号就能拼出非法配置。
#   3) 凡网络下载必须走 fetch_file / fetch_stdout（§3），
#      不要裸 `curl … | sh`：那样既无超时也无重试，失败只剩一行行号。
# ============================================================

# 防护：若被 `sh vps-init.sh`（Debian 的 sh=dash）误执行，dash 不认 pipefail，
# 会报 "invalid option name set: pipefail" 并直接退出。此处自动切回 bash 重跑。
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

# ===== §0 路径常量（不属于参数，不写状态文件） =====
# 状态目录默认 /root/.vps-init；允许环境变量覆盖（自测层用它隔离沙箱），默认行为不变
STATE_DIR="${STATE_DIR:-/root/.vps-init}"
STATE_FILE="${STATE_DIR}/state.env"
SB_DIR="/etc/sing-box"
SB_CONF="${SB_DIR}/config.json"
WEB_ROOT="/var/www/html"
CACHE_DIR="/var/cache/vps-init"     # §3 下载缓存（GPG key / 安装脚本）

# Reality 公共站点握手的默认目标：默认值只在这里定义一处。
# 模块 7 的实际赋值与重跑预告（report_rerun）共用同一组常量 ——
# 以前两处各写一份 ${VAR:-www.microsoft.com}，改一处就会让"预告"和"实际写入"不一致。
REALITY_PUBLIC_SNI_DEFAULT="www.microsoft.com"
REALITY_PUBLIC_DEST_DEFAULT="www.microsoft.com"
REALITY_PUBLIC_PORT_DEFAULT="443"

# ===== §0 内置伪装站（Realm/青山·一屏山色） =====
# 单文件部署时也要有像样的伪装站，所以把整页 gzip+base64 内嵌进来。
# 41KB 的页面压到约 11KB，脚本体积可接受；部署时再解回 index.html。
# 想换成自己的页面：--web-page /path/to/index.html（优先级高于本内置页）。
BUNDLED_WEB_GZ_B64=$(cat <<'WEBPAGE_B64_EOF'
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
WEBPAGE_B64_EOF
)

# ===== §0 默认参数（全脚本唯一的默认值来源） =====
# 用 "${VAR:-默认}" 赋值是有意的：既给默认值，又保留"环境变量预置"这一既有用法
# （如 `TZ_NAME=Asia/Shanghai bash vps-init.sh`）。
# 各模块内**不得**再出现同样写法，否则默认值就有了第二个来源。
init_defaults() {
    TZ_NAME="${TZ_NAME:-Etc/UTC}"
    SSH_PORT="${SSH_PORT:-51736}"
    PUBKEY="${PUBKEY:-}"
    PUBKEY_FILE="${PUBKEY_FILE:-}"
    PUBKEY_URL="${PUBKEY_URL:-}"

    VLESS_PORT="${VLESS_PORT:-443}"
    HY2_PORT="${HY2_PORT:-16407}"
    FALLBACK_PORT="${FALLBACK_PORT:-8443}"
    HOP_RANGE="${HOP_RANGE:-30000:50000}"
    SHAPER_RATE="${SHAPER_RATE:-}"
    TCP_BW="${TCP_BW:-}"

    DOMAIN="${DOMAIN:-}"
    # 客户端 server 字段用域名而不是 IP。留空时自动回退到 --domain（若它是合法域名），
    # 都没有才用 IP；--no-client-domain 可显式强制回退到 IP 保持旧行为。
    CLIENT_DOMAIN="${CLIENT_DOMAIN:-}"              # 两族共用的域名（兜底）
    CLIENT_DOMAIN_V4="${CLIENT_DOMAIN_V4:-}"         # v4 节点单独用的域名（可选）
    CLIENT_DOMAIN_V6="${CLIENT_DOMAIN_V6:-}"         # v6 节点单独用的域名（可选）
    CLIENT_DOMAIN_FORCE_IP="${CLIENT_DOMAIN_FORCE_IP:-0}"
    CF_TOKEN="${CF_TOKEN:-}"
    ACME_EMAIL="${ACME_EMAIL:-}"
    ACME_CA="${ACME_CA:-letsencrypt}"
    WEB_PAGE="${WEB_PAGE:-}"
    SB_VERSION="${SB_VERSION:-}"

    REALITY_SNI="${REALITY_SNI:-}"
    REALITY_DEST="${REALITY_DEST:-}"
    REALITY_DEST_PORT="${REALITY_DEST_PORT:-}"
    CERT_CN="${CERT_CN:-bing.com}"

    UUID="${UUID:-}"
    REALITY_PRIV="${REALITY_PRIV:-}"
    REALITY_PUB="${REALITY_PUB:-}"
    SHORT_ID="${SHORT_ID:-}"
    HY2_PW="${HY2_PW:-}"
    OBFS_PW="${OBFS_PW:-}"
    CERT_HASH="${CERT_HASH:-}"
    # 链接用的「证书指纹」（hex，openssl x509 -fingerprint -sha256 口径）。
    # 与 CERT_HASH 不是一回事：CERT_HASH 是公钥 DER 的 sha256+base64（sing-box 的
    # certificate_public_key_sha256 字段要这个），而 Hysteria2 URI 的 pinSHA256
    # 官方口径是整张证书的 sha256 指纹（hex）。混用会导致客户端 pin 校验必失败。
    CERT_SHA256="${CERT_SHA256:-}"
    NODE_NAME="${NODE_NAME:-}"

    # 多 IP：留空自动探测本机 scope global 地址，每个 IP 生成一组 hy2 + vless
    IP_LIST="${IP_LIST:-}"
    BIND_ALL="${BIND_ALL:-}"          # 1 = 强制 hy2 也用单一 :: 监听（默认仅同族多地址时才按 IP 拆分）

    # NAT 机型（共享出口 IP + 服务商固定端口转发）：
    #   auto  = 自动检测；force = --nat 强制；off = --no-nat 关闭（两族都按原配置）
    #   NAT_PORTS / NAT_MAP 是 v4 受限族的固定端口清单与「服务=外部端口」映射；
    #   NAT_V6_PORTS / NAT_V6_MAP 是 v6 受限族的对应配置。
    #   服务商分配了哪些端口容器里看不到，脚本只校验与提示，绝不自己猜、也不擅自改端口。
    # 这些值放 STATE_KEYS 持久化 —— 端口是固定的，不该每次重跑都重填。
    NAT_MODE="${NAT_MODE:-auto}"
    NAT_PORTS="${NAT_PORTS:-}"
    NAT_MAP="${NAT_MAP:-}"
    NAT_V6_PORTS="${NAT_V6_PORTS:-}"
    NAT_V6_MAP="${NAT_V6_MAP:-}"
    # 双栈能力不对等：某一族是独立公网、端口全开放时，该族就按原配置
    #   （默认服务端口 + HOP_RANGE 端口跳跃），只有受限族才用固定端口。
    #   1 = 该族全开放；0 = 该族受限（用上面各自的端口清单 / 映射）。
    #   NAT_ACTIVE=0（非 NAT 机）时两族一律按原配置，这两个标志不参与判断。
    #   服务商的端口策略脚本测不出，默认 0（保守：整机按受限处理），由交互向导或 CLI 显式声明。
    NAT_V4_OPEN="${NAT_V4_OPEN:-0}"
    NAT_V6_OPEN="${NAT_V6_OPEN:-0}"
    # 某一族端口太少（只有 1 个）时，指定该族只生成哪些协议的客户端节点。
    #   留空 = 全部生成（旧行为）。
    NAT_V4_SERVICES="${NAT_V4_SERVICES:-}"
    NAT_V6_SERVICES="${NAT_V6_SERVICES:-}"
    # 交互式 NAT 端口向导：auto = 交互运行时自动进入（--yes / --modules 不进入），
    #   on = 强制进入；off = 不进入。刻意不写 state.env —— 这是本次运行行为，不该被「记住」。
    NAT_WIZARD="${NAT_WIZARD:-auto}"
    # 「只做管理、不跑代理」整机开关：向导检测到 NAT 时会问「是否开启端口转发映射」，
    #   选否 = 1 → 本次及后续重跑都不部署代理：不装 sing-box（密钥/证书/伪装站全不生成）、
    #   不生成 v4 / v6 代理节点与客户端 outbounds、不下发代理端口的防火墙 / DNAT 规则；
    #   只保留系统基线、SSH 管理通道、fail2ban。0 = 正常部署（默认，旧行为不变）。
    #   写进 STATE_KEYS：重跑沿用，不会又装回 sing-box；用 --no-manage-only 显式恢复。
    MANAGE_ONLY="${MANAGE_ONLY:-0}"

    # 客户端侧参数
    UP_MBPS="${UP_MBPS:-50}"          # hy2 客户端上行带宽(Mbps)，空则用 BBR CC
    DOWN_MBPS="${DOWN_MBPS:-200}"     # hy2 客户端下行带宽(Mbps)
    HOP_INTERVAL="${HOP_INTERVAL:-15s}"
    HOP_INTERVAL_MAX="${HOP_INTERVAL_MAX:-30s}"   # 需 sing-box >= 1.14.0
    TCP_KEEP_ALIVE="${TCP_KEEP_ALIVE:-2m}"
    TCP_KEEP_ALIVE_INTERVAL="${TCP_KEEP_ALIVE_INTERVAL:-30s}"
    SB_UP_MBPS="${SB_UP_MBPS:-}"      # 服务端 hy2 限速，留空则 ignore_client_bandwidth:false
    SB_DOWN_MBPS="${SB_DOWN_MBPS:-}"

    ASSUME_YES="${ASSUME_YES:-}"
    MODULES_ARG="${MODULES_ARG:-}"
    # 重跑二选一：keep = 沿用旧配置（不覆盖任何文件/凭据），new = 重新生成全套凭据并更新配置。
    # 空 = 尚未选择。**刻意不放进 STATE_KEYS**：模式绝不能被"记住"，
    # 否则下一次重跑就会在用户没有表态的情况下自动沿用上次的选择去覆盖配置。
    # 允许通过环境变量预置，方便批量脚本化调用。
    RERUN_MODE="${RERUN_MODE:-}"
    # 本次是否「首次部署」：由 choose_rerun_mode 判定后锁定，后续模块只读。
    # 不能在模块 6 里用 has_existing_deployment 现场判断 —— 模块 2/3 会先 save_state
    # 创建 state.env，把首次部署误判成重跑，连 --uuid 都会被强制忽略。
    RERUN_IS_FIRST=0
    PRINT_CONFIG="${PRINT_CONFIG:-}"
    PRINT_OUTBOUNDS="${PRINT_OUTBOUNDS:-}"
    SHOW_STATUS="${SHOW_STATUS:-}"
    DOCTOR="${DOCTOR:-}"
    SELF_TEST="${SELF_TEST:-}"
    # 只读 JSON 输出开关（--json）：--status / --doctor 输出机器可读 JSON 而非人类文本
    STATUS_JSON="${STATUS_JSON:-0}"
    DOCTOR_JSON="${DOCTOR_JSON:-0}"
    # 子命令开关：--rotate-secrets 快速换凭据 / --uninstall 干净下线（均不写进 state.env）
    ROTATE_SECRETS="${ROTATE_SECRETS:-0}"
    UNINSTALL="${UNINSTALL:-0}"
    PURGE_STATE="${PURGE_STATE:-0}"

    # §3 下载行为
    FETCH_RETRIES="${FETCH_RETRIES:-3}"        # 单个 URL 的最大尝试次数
    FETCH_TIMEOUT="${FETCH_TIMEOUT:-15}"       # 连接超时（秒）；总超时取 6 倍
    FETCH_BACKOFF="${FETCH_BACKOFF:-2}"        # 首次退避秒数，之后翻倍（自检里置 0 以免拖慢）
    NO_CACHE="${NO_CACHE:-}"                   # 非空 = 忽略下载缓存，强制重新拉取
}
init_defaults

# ===== §1 输出与日志 =====
if [[ -t 1 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_N=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_N=""
fi
info() { printf '%s[*]%s %s\n' "$C_B" "$C_N" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_N" "$*" >&2; }
err()  { printf '%s[✗]%s %s\n' "$C_R" "$C_N" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

run() { info "执行: $*"; "$@"; }

# ===== §2 apt 助手 =====
APT_UPDATED=0
# 等待 apt/dpkg 锁释放（新机开机常遇到 unattended-upgrades 占用）
apt_wait_lock() {
    local i
    for i in {1..30}; do
        if command -v fuser >/dev/null 2>&1; then
            fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || return 0
        else
            # 最小镜像可能没装 psmisc（fuser）：用 util-linux 的 flock 探测。
            # dpkg/apt 的锁就是 flock 语义 —— 探测性的短暂加锁/释放对它们无副作用。
            flock -n /var/lib/dpkg/lock-frontend true 2>/dev/null && return 0
        fi
        [[ $i -eq 1 ]] && info "apt 锁被占用，等待释放..."
        sleep 5
    done
    die "apt 锁长时间未释放，请检查是否有其他包管理进程"
}
apt_update() {
    [[ $APT_UPDATED -eq 1 ]] && return 0
    export DEBIAN_FRONTEND=noninteractive
    apt_wait_lock
    # 上次 apt/dpkg 被中断的自愈：升级耗时長，SSH 掉线 / Ctrl-C / 断电后 dpkg 会留下
    # pending 状态，锁虽已随进程释放，但此后每次 apt-get 都会报
    # "dpkg was interrupted, you must manually run 'dpkg --configure -a'" ——
    # 若不自愈，重跑永远卡死在同一点。检测到残留就先修复。
    if [[ -n "$(dpkg -C 2>/dev/null || true)" ]]; then
        info "检测到 dpkg 中断残留，执行 dpkg --configure -a 修复"
        dpkg --configure -a || warn "dpkg --configure -a 未完全成功，后续安装可能失败，请查看上方输出"
    fi
    apt-get update -qq
    APT_UPDATED=1
}
# 安装失败时回显输出，避免只留一个行号
apt_install() {
    apt_update
    local out
    if ! out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" 2>&1)"; then
        printf '%s\n' "$out" >&2
        die "软件包安装失败: $*"
    fi
}

# ===== §3 网络下载：超时 + 退避重试 + 本地缓存 =====
# 为什么不再用 `curl … | sh`：一次性管道既没有超时也没有重试，网络抖一下整个开荒就得重来，
# 而且失败信息被管道吞掉，最后只剩 ERR 陷阱的一行行号。
# 这里统一包一层：连接超时 FETCH_TIMEOUT 秒、最多 FETCH_RETRIES 次、退避 FETCH_BACKOFF 翻倍，
# 成功产物留在 CACHE_DIR（NO_CACHE=1 可强制刷新）。
# 刻意的取舍：只有"下载"被重试；apt/dpkg 本身互斥，安装步骤保持串行、日志保持线性。

# 缓存文件名：URL 末段（去掉 query）+ 完整 URL 校验和前缀。
# 必须带校验和：否则 https://a/x.sh 与 https://b/x.sh 会共用一个缓存文件，
# 第二次下载会静默命中别人的内容 —— 这类"缓存污染"极难排查。
# 校验和必须按完整 URL（含 query）计算：剥掉 query 再算的话，
# https://a/x.sh?ver=1 与 ?ver=2 会拿到同一个缓存键 —— 升级内容被旧缓存顶掉。
fetch_cache_path() {
    local full="$1" u="${1%%\?*}" name sum
    name="${u##*/}"
    [[ -n $name ]] || name="index"
    name="${name//[^A-Za-z0-9._-]/_}"
    sum="$(printf '%s' "$full" | cksum 2>/dev/null | tr -d ' ' | cut -c1-8)"
    printf '%s/%s.%s' "$CACHE_DIR" "$name" "${sum:-00000000}"
}

# write_bundled_web_page <输出路径>
#   把 §0 里内嵌的 gzip+base64 伪装站解回 HTML。成功返回 0。
#   解压失败（缺 gzip/base64、base64 被截断）返回 1，由调用方退回默认 It works 页。
write_bundled_web_page() {
    local out="$1" tmp="${1}.tmp"
    [[ -n ${BUNDLED_WEB_GZ_B64:-} ]] || return 1
    command -v base64 >/dev/null 2>&1 || return 1
    command -v gzip   >/dev/null 2>&1 || return 1
    printf '%s' "$BUNDLED_WEB_GZ_B64" | base64 -d 2>/dev/null | gzip -dc 2>/dev/null > "$tmp" || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    if [[ -s $tmp ]] && [[ "$(head -c 15 "$tmp" 2>/dev/null || true)" == '<!DOCTYPE'* ]]; then
        mv -f "$tmp" "$out"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# cert_domain_matches <证书路径> <域名>
#   校验证书的 CN 或 SAN 是否覆盖该域名。0=匹配，1=不匹配 / 无法解析。
#   用途：① 重跑模块 7 时判断能否复用已有证书（不必再要 CF Token）；
#        ② 防止 acme.sh 装回旧域名证书、却因"文件存在"被误判为签发成功。
#   同时接受通配符证书（*.example.com 覆盖 node1.example.com），避免把用户
#   自己放的通配符证书判成不匹配 —— 旧版本根本不校验，不能让修复反而收窄兼容性。
cert_domain_matches() {
    local cert="$1" domain="$2"
    [[ -s $cert && -n $domain ]] || return 1
    command -v openssl >/dev/null 2>&1 || return 1

    local cn sans entry
    # head -n1 提前退出会让上游吃 SIGPIPE；pipefail 下整条管道会变成 141，
    # 因此这里必须 || true（与 §0 的同类管道处理保持一致）。
    cn="$(openssl x509 -in "$cert" -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n 's/^[[:space:]]*commonName[[:space:]]*=[[:space:]]*//p' | head -n1 || true)"
    if [[ $cn == "$domain" ]] \
        || [[ $cn == '*.'* && $domain == *".${cn#*.}" ]]; then
        return 0
    fi

    sans="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null || true)"
    while IFS= read -r entry; do
        entry="${entry#DNS:}"
        [[ $entry == "$domain" ]] && return 0
        [[ $entry == '*.'* && $domain == *".${entry#*.}" ]] && return 0
    done < <(printf '%s\n' "$sans" | grep -oE 'DNS:[^,[:space:]]+' || true)
    return 1
}

# 判断 state 里的 REALITY_* 三元组是不是「脚本自己写的本地回落」，而不是用户
# 自定义的公共站点目标。只有满足这个精确特征时，回退分支才允许重置它们：
#   重跑时若上次是本地回落（DEST=127.0.0.1 / PORT=FALLBACK_PORT），本次因缺
#   Token 或换域名而回退公共站点，旧值会被 ${VAR:-默认} 原样保留下来，
#   握手就指向一个已经没有 Caddy 的本机端口，且 warn 还会把它打印成"正常"。
# 用户自己设的目标（例如 www.caltech.edu:443）绝不能碰。
is_local_fallback_state() {
    [[ ${REALITY_DEST:-} == "127.0.0.1" && ${REALITY_DEST_PORT:-} == "${FALLBACK_PORT:-}" ]] || return 1
    # 显式命令行指定的值一律尊重，不做自动重置
    [[ -z ${CLI_SET[REALITY_DEST]:-} && -z ${CLI_SET[REALITY_DEST_PORT]:-} ]] || return 1
    return 0
}

# fetch_file <目标路径> <URL> [缓存路径]
#   命中缓存（非空且未设 NO_CACHE）直接复用；否则带重试下载，先写 .part 再 mv（原子替换，
#   避免中断留下半个文件被下次当成有效缓存）。失败返回 1，由调用方决定 die 还是 warn。
fetch_file() {
    local dest="$1" url="$2" cached="${3:-}"
    [[ -n $cached ]] || cached="$(fetch_cache_path "$url")"

    # 先建目录：否则命中缓存时 cp 会因为目标目录不存在而失败，
    # 白白退回一次网络请求 —— 缓存等于没命中。
    mkdir -p "$(dirname "$dest")" "$CACHE_DIR" 2>/dev/null || true

    if [[ -z $NO_CACHE && -s $cached ]]; then
        info "命中下载缓存：${cached}"
        if [[ $dest == "$cached" ]]; then return 0; fi
        # cp 也走 .part + mv：复制中途被打断（Ctrl-C / 断电）不能留下半个目标文件，
        # 否则下次「目标已存在」的判定会拿到残缺内容。
        if cp -f "$cached" "${dest}.part" 2>/dev/null && mv -f "${dest}.part" "$dest"; then
            return 0
        fi
        rm -f "${dest}.part" 2>/dev/null || true
        warn "缓存复制失败，回退网络下载：${cached}"
    fi

    local attempt=1 delay="$FETCH_BACKOFF" err="" rc=0
    while (( attempt <= FETCH_RETRIES )); do
        if curl -fsSL --connect-timeout "$FETCH_TIMEOUT" --max-time "$((FETCH_TIMEOUT * 6))" \
                -o "${dest}.part" "$url" 2>"${dest}.err"; then
            if [[ -s ${dest}.part ]]; then
                mv -f "${dest}.part" "$dest"
                rm -f "${dest}.err"
                mkdir -p "$CACHE_DIR" 2>/dev/null || true
                # 写缓存同样原子化：半截缓存会被后续运行当作有效内容命中
                if [[ $dest == "$cached" ]] || { cp -f "$dest" "${cached}.part" 2>/dev/null \
                    && mv -f "${cached}.part" "$cached"; }; then :; else rm -f "${cached}.part" 2>/dev/null || true; fi
                (( attempt > 1 )) && info "第 ${attempt} 次尝试下载成功：$url"
                return 0
            fi
            err="下载内容为空"
        else
            rc=$?
            err="$(tail -n 3 "${dest}.err" 2>/dev/null | tr '\n' ' ')"
            [[ -n ${err// /} ]] || err="curl 退出码 ${rc}"
        fi
        rm -f "${dest}.part" "${dest}.err"
        warn "下载失败（${attempt}/${FETCH_RETRIES}）：${url} —— ${err}"
        if (( attempt < FETCH_RETRIES )); then sleep "$delay"; delay=$((delay * 2)); fi
        attempt=$((attempt + 1))
    done
    return 1
}

# fetch_stdout <URL>：内容打到 stdout（喂给 sh/sed 这类必须走管道的场景）。
# 同样带重试；失败返回 1 且不输出任何内容 —— 这样 `fetch_stdout U | sh` 不会喂半个脚本给 sh。
fetch_stdout() {
    local url="$1" attempt=1 delay="$FETCH_BACKOFF" out=""
    while (( attempt <= FETCH_RETRIES )); do
        if out="$(curl -fsSL --connect-timeout "$FETCH_TIMEOUT" --max-time "$((FETCH_TIMEOUT * 6))" "$url" 2>/dev/null)"; then
            printf '%s' "$out"
            return 0
        fi
        warn "下载失败（${attempt}/${FETCH_RETRIES}）：${url}"
        if (( attempt < FETCH_RETRIES )); then sleep "$delay"; delay=$((delay * 2)); fi
        attempt=$((attempt + 1))
    done
    return 1
}

# ===== §4 分享链接编码 =====
# 分享链接的 userinfo / fragment 需要百分号编码。
# 密码是 Base64（含 + / =），节点名可能含 # & ? 空格等 —— 任一未编码都会让 URI 被截断。
urlenc() {
    local s="$1"
    s="${s//%/%25}"                      # % 必须最先处理，否则会二次编码
    s="${s//+/%2B}"; s="${s//\//%2F}"; s="${s//=/%3D}"; s="${s// /%20}"
    s="${s//#/%23}"; s="${s//&/%26}"; s="${s//\?/%3F}"; s="${s//:/%3A}"
    s="${s//@/%40}"; s="${s//\"/%22}"; s="${s//$'\n'/%0A}"; s="${s//$'\r'/%0D}"
    printf '%s' "$s"
}

# ===== §5 交互助手 =====
ask() { # ask "提示" "默认值"
    local prompt="$1" default="$2" v=""
    [[ -n $ASSUME_YES ]] && { printf '%s\n' "$default"; return 0; }
    read -r -p "$(printf '%s[?]%s %s [%s]: ' "$C_B" "$C_N" "$prompt" "$default")" v || true
    printf '%s\n' "${v:-$default}"
}
ask_yn() { # ask_yn "提示" y|n
    local prompt="$1" default="$2" v=""
    [[ -n $ASSUME_YES ]] && { [[ $default == y ]] && return 0 || return 1; }
    while true; do
        read -r -p "$(printf '%s[?]%s %s [%s]: ' "$C_B" "$C_N" "$prompt" "$default")" v || true
        v="${v:-$default}"
        case "${v,,}" in y|yes) return 0;; n|no) return 1;; *) warn "请输入 y 或 n";; esac
    done
}

# ===== §6 参数解析 =====
usage() {
    cat <<'EOF'
用法: bash vps-init.sh [选项]

  --ssh-port N          SSH 端口（默认 51736）
  --pubkey STR          公钥内容，如 "ssh-ed25519 AAAA... user@pc"
  --pubkey-file PATH    从本地文件读取公钥
  --pubkey-url URL      从 URL 拉取公钥（如 https://github.com/xxx.keys）
  --domain DOMAIN       Reality 回落域名（本地回落需配合 --cf-token；留空则用公共站点握手，且不部署伪装站）
                        它同时是客户端 server 的默认域名：请确认 DNS 已解析到本机 v4 / v6 地址
  --client-domain HOST  两族共用的客户端 server 域名（优先于 --domain，结果存入 state.env）
                        必须含点号、不能是 IP；不给分族域名时 v4 / v6 都用这一个
  --client-domain-v4 HOST
                        v4 节点单独使用的域名（优先于 --client-domain；只需 A 记录）
  --no-client-domain-v4 清除 v4 专属域名，v4 节点跟随 --client-domain / --domain
  --client-domain-v6 HOST
                        v6 节点单独使用的域名（只需 AAAA 记录；域名只有 A 记录时必备）
  --no-client-domain-v6 清除 v6 专属域名，v6 节点跟随 --client-domain / --domain
  --no-client-domain    显式关闭域名模式，server 回到旧的裸 IP 行为（同时清空共用与两个分族域名）
  推荐分开写：--client-domain-v4 v4.example.com --client-domain-v6 v6.example.com
  --cf-token TOKEN      Cloudflare API Token（DNS-01 签发证书；不写状态文件，重跑需再给，除非已有同域名证书）
  --acme-email MAIL     acme.sh 注册邮箱（默认 admin@<domain>）
  --reality-sni HOST    公共站点握手 SNI（默认 www.microsoft.com；本地回落时自动用 --domain）
  --reality-dest HOST   公共站点握手目标（默认 www.microsoft.com；本地回落时自动用 127.0.0.1）
  --reality-dest-port N 公共站点握手端口（默认 443；本地回落时自动用 --fallback-port）
  --cert-cn HOST        Hysteria2 自签证书 CN / 客户端 server_name（默认 bing.com）
  --web-page PATH       自定义伪装站 index.html（默认使用内置的「青山·一屏山色」页面）
  --vless-port N        VLESS-Reality 端口（默认 443）
  --hy2-port N          Hysteria2 端口（默认 16407）
  --fallback-port N     Caddy 回落端口（默认 8443）
  --hop-range A:B       Hysteria2 端口跳跃范围（默认 30000:50000）
  --no-hop              关闭端口跳跃，客户端只连单个 hy2 端口
  --ips LIST            手动指定 IP 列表（逗号分隔），留空则自动探测本机公网地址
                        v4/v6 分族独立判定：某族网卡上无私网地址时走出口探测补齐
                        写 auto 表示忽略状态文件里保存的旧列表、强制重新探测
  --bind-all            强制 hy2 也用单一 :: 监听（默认仅当同族多地址时才按 IP 拆分入站）
  --nat / --no-nat      强制开启 / 关闭 NAT 适配（默认自动检测 v4 网卡是否只有私网地址）
  --manage-only         整机「只做管理、不跑代理」：不装 sing-box（密钥/证书/伪装站全不生成）、
                        不生成 v4 / v6 代理节点与客户端 outbounds、不下发代理端口的
                        防火墙 / DNAT 规则；只保留系统基线、SSH 管理通道、fail2ban。
                        等价交互式向导里对「是否开启端口转发映射」选「否」；结果存入 state.env
  --no-manage-only      恢复代理部署（覆盖 state.env 里已保存的「只做管理」）
  --nat-wizard          交互运行时强制进入「NAT 端口配置向导」
  --no-nat-wizard       跳过向导（--yes / --modules / --print-* / --status 本来就不进入）
                        向导先问「是否开启端口转发映射」：选否即整机只做管理；
                        选是再逐族问是否全开放 / 只给固定端口 / 该族只做管理。
                        全开放族按原配置（默认端口 + 端口跳跃）。结果存入 state.env
  --nat-ports LIST      v4 受限族的固定外部端口清单，仅用于校验与提示
                        支持单端口/离散端口/连续段，逗号混用：
                          30443 | 30022,30443,30444 | 20000:20020 | 20000:20020,30443
  --nat-map SPEC        v4 受限族的外部端口映射，如 "vless=30443,hy2=30444,ssh=30022"
                        内外端口不同号时才需要；未登记 = 内外同号，直接用服务端口
  --nat-v4-open         v4 端口全开放 → 按原配置（默认端口 + 跳跃），不套固定端口
  --no-nat-v4-open      v4 受限（默认）
  --nat-v6-open         v6 端口全开放 → 按原配置（默认端口 + 跳跃）
  --no-nat-v6-open      v6 受限（默认）
  --nat-v6-ports LIST   v6 受限族的固定外部端口清单（格式同 --nat-ports）
  --nat-v6-map SPEC     v6 受限族的外部端口映射（格式同 --nat-map）
  --nat-v4-services LIST
                        v4 端口不足时只生成指定协议的节点：vless / hy2 / vless,hy2；
                        ssh-only = 该族唯一端口被 SSH 占用，不生成任何 v4 代理节点
  --nat-v6-services LIST
                        v6 同上；ssh-only = v6 只跑 SSH，不生成任何 v6 代理节点
  --up-mbps N           客户端 hy2 上行带宽（默认 50；仅当 state.env 中该值为空时
                        才省略限速字段、客户端回落 BBR CC——CLI 不传参拿到的就是 50）
  --down-mbps N         客户端 hy2 下行带宽（默认 200）
  --hop-interval D      端口跳跃间隔（默认 15s）
  --hop-interval-max D  跳跃间隔上限，随机化（默认 30s，需 sing-box >= 1.14.0）
  --tcp-keep-alive D    TCP 保活时长（默认 2m）
  --tcp-keep-alive-int D
                        TCP 保活探测间隔（默认 30s）
  --sb-bandwidth U:D    服务端 hy2 限速，如 200:500（留空则不限制）
  --node-name NAME      节点名（客户端 tag 前缀）。留空自动识别机房城市；识别失败时
                        交互运行会询问手动输入，非交互用本参数指定，最后才回退 hostname
  --shaper-rate RATE    出向整形速率（Mbps 数字，如 1000）；留空不整形
                        仅打印可复制的 tcpfit 命令，不会自动执行；旧写法 1000mbit 兼容，打印时归一化为数字
  --tcp-bw N            本机带宽（Mbps），仅用于打印可复制的 tcpfit 调优命令
  --uuid UUID           固定 UUID（仅首次部署生效；重跑选任一模式都不会使用这个固定值）
  --sb-version VER      安装指定版本 sing-box（留空装最新；该选择不写状态文件，重跑需重新指定）
  --acme-ca NAME        证书颁发机构，默认 letsencrypt（可选 zerossl）
  --modules LIST        只执行指定模块，如 1,2,3
  --keep-config         重跑二选一之「沿用旧配置」：完整保留 config.json 与全部密码/密钥/证书，
                        不覆盖、不改动、不重启服务；已下发的客户端继续可用
  --new-config          重跑二选一之「生成新配置」：每次重新生成一整套 UUID / Reality 密钥 /
                        short_id / 各密码 / 自签证书并更新 config.json，旧客户端全部作废
  --config-mode keep|new
                        上面两个开关的带值写法；非法值直接报错退出
  --yes                 非交互，全部模块按默认值执行
                        重跑时若未指定上面任一模式，一律按「沿用旧配置」处理（绝不自动覆盖）
  --print-config        仅渲染服务端 sing-box 配置到 stdout
  --print-outbounds     仅渲染客户端 outbounds 到 stdout（可配 --ips，或 IP=1.2.3.4 环境变量）
  --status              查看当前机器配置状态（不修改任何东西）
  --doctor              一键体检（只读）：服务 / 配置校验 / 监听端口 / 防火墙关键规则 /
                        证书与指纹 / 客户端域名解析 / NAT 端口清单；有异常时退出码 1
  --json                与 --status / --doctor 搭配：输出机器可读 JSON（便于面板/脚本解析）
  --rotate-secrets      快速换钥匙：只轮换 UUID / short_id / hy2 密码 / obfs 密码并
                        重写配置与客户端交付、重启 sing-box（Reality 密钥与证书不变）；
                        现有客户端全部作废，需重新导入
  --uninstall           干净下线代理：停用并移除 sing-box、删除配置与证书及 /root 交付文件、
                        拆除本脚本部署的 Caddy 回落站、清除代理端口的防火墙规则与跳跃 DNAT
                        （保留 SSH 放行 / fail2ban / tcpfit）；
                        state.env 保留供日后重部署，加 --purge-state 一并删除
  --purge-state         与 --uninstall 搭配：连 state.env 一起删除（彻底遗忘本机部署）；
                        单独使用不做任何事
  --self-test           内置自检：只读、不联网、不修改系统
  -h, --help            显示本帮助
EOF
}
need_val() { [[ $# -ge 2 && -n ${2:-} && ${2:0:1} != "-" ]] || die "参数 $1 缺少取值（用法见 --help）"; }

# ===== §7 取值合法性 =====
# 端口、跳跃范围、时长这三类值以前完全不校验：非法值会一路带进
# sing-box 配置（"listen_port": abc）或 iptables 规则（--dport 30000-50000），
# 直到模块 8 的 sing-box check 才以一句难懂的报错终止。这里前置拦截。
# 端口号：1-65535 的十进制整数。显式禁止前导零 —— bash 算术把 0443 当八进制 291，
# 会"校验通过"并把 0443 原样渲染进 JSON（"listen_port": 0443 是非法 JSON）。
is_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
need_port() { # need_port <选项名> <值>
    is_port "$2" || die "$1 非法：必须是 1-65535 的整数（收到: $2）"
}
# Go duration 写法，sing-box 的 hop_interval / tcp_keep_alive 都用它
is_duration() { [[ $1 =~ ^(0|[1-9][0-9]*)(ns|us|ms|s|m|h)$ ]]; }
need_duration() { # need_duration <选项名> <值>
    is_duration "$2" || die "$1 非法：应为时长写法（如 15s / 2m / 1h，收到: $2）"
}
need_posint() { # 带宽等正整数：同样拒绝前导零（050 会被当成八进制 40 并原样写进配置）
    [[ $2 =~ ^[1-9][0-9]*$ ]] || die "$1 非法：必须是大于 0 的整数（收到: $2）"
}
# 主机名/域名：这些值会被直接内插进 sing-box 的 JSON 与 Caddyfile。
# 不做白名单的话，一个引号（--domain 'a"b.com'）就能拼出非法 JSON，
# --print-* 离线渲染下没有任何 check 兜底，用户会拿到一份坏配置。
is_hostname() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; }
# 握手目标可以是域名或裸 IPv4/IPv6（不加方括号），因此额外放行冒号
is_host()     { [[ $1 =~ ^[A-Za-z0-9:.]([A-Za-z0-9:._-]*[A-Za-z0-9:.])?$ ]]; }
is_uuid()     { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
is_rate()     { [[ $1 =~ ^[1-9][0-9]*$ || $1 =~ ^[1-9][0-9]*[a-z]+$ ]]; }   # Mbps 数字（1000）或 tc 写法（1000mbit），后者兼容旧版
need_hostname() { [[ -z ${2:-} ]] || is_hostname "$2" || die "$1 非法：只能是域名/主机名（收到: $2）"; }
need_host()     { [[ -z ${2:-} ]] || is_host     "$2" || die "$1 非法：只能是主机名或 IP（收到: $2）"; }
# 是否像「能当客户端连接域名」的值：必须含点号，且不能是纯数字/点（IPv4 字面量）。
# 只用于 --domain 的自动回退判定 —— 公共站点握手 SNI（www.microsoft.com）绝不能当 server。
looks_like_domain() { [[ -n ${1:-} && $1 == *.* && ! $1 =~ ^[0-9.]+$ ]]; }
need_client_domain() { # <选项名> <值>：客户端连接域名必须是真域名，不能塞 IP
    [[ -z ${2:-} ]] && return 0
    need_hostname "$1" "$2"
    looks_like_domain "$2" || die "$1 需要完整域名（含点号，如 node.example.com），不能是 IP 或裸主机名（收到: $2）"
    return 0
}
need_hop_range() { # 校验全局 HOP_RANGE，形如 A:B 且 1<=A<B<=65535
    [[ -n $HOP_RANGE ]] || return 0
    [[ $HOP_RANGE =~ ^([0-9]+):([0-9]+)$ ]] \
        || die "--hop-range 格式应为 起始:结束（如 30000:50000，收到: $HOP_RANGE）"
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    is_port "$a" && is_port "$b" || die "--hop-range 端口必须落在 1-65535（收到: $HOP_RANGE）"
    (( a < b )) || die "--hop-range 起始端口必须小于结束端口（收到: $HOP_RANGE）"
}

# ---------- NAT 机型端口参数 ----------
# NAT 机的「固定端口」是服务商分配的，容器里看不到宿主的转发表，脚本不可能自动探测，
# 因此只做两件事：校验格式、把用户给的外部端口记进 NAT_EXT。
# 内外端口同号时根本不用 --nat-map：直接把 --vless-port 等设成外部端口即可。
declare -A NAT_EXT=() NAT_EXT6=()
declare -A SHARED_PORT_WARNED=()   # 共用端口警告的去重（进程级）
# 固定端口清单支持三种写法，可逗号混用：
#   单端口 30443 / 离散端口 30022,30443,30444 / 连续段 20000:20020 / 混合 20000:20020,30443
# 很多 NAT 机只给 1 个或少数几个不连续的端口，只认 A:B 连续段是表达不了的。
need_nat_ports() { # <spec> [选项名]
    local spec="${1:-}" opt="${2:---nat-ports}" item a b
    [[ -n $spec ]] || die "$opt 不能为空"
    local -a items=()
    IFS=',' read -r -a items <<< "$spec"
    ((${#items[@]} > 0)) || die "$opt 格式应为 端口或 起始:结束，逗号分隔（收到: $spec）"
    for item in "${items[@]}"; do
        item="${item// /}"
        [[ -n $item ]] || die "$opt 含有空项（收到: $spec）"
        if [[ $item == *:* ]]; then
            [[ $item =~ ^([0-9]+):([0-9]+)$ ]] \
                || die "$opt 端口段格式应为 起始:结束（如 20000:20020，收到: $item）"
            a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
            is_port "$a" && is_port "$b" || die "$opt 端口必须落在 1-65535（收到: $item）"
            (( a < b )) || die "$opt 起始端口必须小于结束端口（收到: $item）"
        else
            [[ $item =~ ^[0-9]+$ ]] \
                || die "$opt 单端口应为数字（收到: $item）"
            is_port "$item" || die "$opt 端口必须落在 1-65535（收到: $item）"
        fi
    done
    return 0
}
# 端口是否落在服务商给的固定端口清单内；未给清单时不做判断（返回 0）
# 第二参数可显式传清单（v6 用 NAT_V6_PORTS），省略时用全局 NAT_PORTS（v4）。
nat_ports_contains() { # <port> [spec]
    # 显式传入空 spec 就是「没有清单」，不能回退到 NAT_PORTS：
    # v6 未配置端口而 v4 有清单时，回退会把 v6 端口拿 v4 清单去判，告警与计数全是错的。
    local p="${1:-}" spec item a b
    if (( $# >= 2 )); then spec="$2"; else spec="${NAT_PORTS:-}"; fi
    [[ -n $spec ]] || return 0
    [[ $p =~ ^[0-9]+$ ]] || return 1
    local -a items=()
    IFS=',' read -r -a items <<< "$spec"
    for item in "${items[@]}"; do
        item="${item// /}"
        if [[ $item == *:* ]]; then
            a="${item%%:*}"; b="${item##*:}"
            (( p >= a && p <= b )) && return 0
        else
            [[ $item == "$p" ]] && return 0
        fi
    done
    return 1
}
# v4 端口不足时只允许列出确实有端口可用的协议；
# ssh-only = 该族唯一端口被 SSH 占用，彻底不生成该族的代理节点。
need_nat_v4_services() { # <spec>
    local spec="${1:-}" it
    [[ -n $spec ]] || return 0
    spec="${spec// /}"; spec="${spec,,}"
    local -a items=()
    IFS=',' read -r -a items <<< "$spec"
    for it in "${items[@]}"; do
        it="${it// /}"; it="${it,,}"
        case "$it" in
            vless|hy2|ssh-only) ;;
            *) die "--nat-v4-services 只支持 vless / hy2 / ssh-only，逗号分隔（收到: $spec）";;
        esac
    done
    [[ ${#items[@]} -eq 1 || $spec != *ssh-only* ]] \
        || die "--nat-v4-services 的 ssh-only 不能与 vless / hy2 混用（收到: $spec）"
    return 0
}
need_nat_v6_services() { # <spec> —— v6 受限族的同类校验
    local spec="${1:-}" it
    [[ -n $spec ]] || return 0
    spec="${spec// /}"; spec="${spec,,}"
    local -a items=()
    IFS=',' read -r -a items <<< "$spec"
    for it in "${items[@]}"; do
        it="${it// /}"; it="${it,,}"
        case "$it" in
            vless|hy2|ssh-only) ;;
            *) die "--nat-v6-services 只支持 vless / hy2 / ssh-only，逗号分隔（收到: $spec）";;
        esac
    done
    [[ ${#items[@]} -eq 1 || $spec != *ssh-only* ]] \
        || die "--nat-v6-services 的 ssh-only 不能与 vless / hy2 混用（收到: $spec）"
    return 0
}
parse_nat_map() { # <spec> 形如 vless=30443,hy2=30444,ssh=30022
    NAT_EXT=()
    [[ -n ${1:-} ]] || return 0
    local -a items=()
    IFS=',' read -r -a items <<< "$1"
    local it k v
    for it in "${items[@]}"; do
        it="${it// /}"
        [[ -z $it ]] && continue
        [[ $it == *=* ]] \
            || die "--nat-map 每项应为「服务=外部端口」，如 vless=30443（收到: $it）"
        k="${it%%=*}"; v="${it#*=}"; k="${k,,}"
        case "$k" in
            vless|hy2|ssh|fallback) ;;
            *) die "--nat-map 未知服务「$k」：只支持 vless / hy2 / ssh / fallback";;
        esac
        is_port "$v" || die "--nat-map 的 ${k} 外部端口非法：$v"
        NAT_EXT["$k"]="$v"
    done
    warn_shared_ext_ports NAT_EXT "--nat-map"
    return 0
}
warn_shared_ext_ports() { # <表名> <参数名>：同一外部端口被多个服务共用时提醒（不拒绝）
    # 仅当面板按 TCP / UDP 分别转发（vless/fallback 走 TCP、hy2 走 UDP）时才合法；
    # 否则其中一个服务必然连不上。因此只警告、不 die，让分协议转发的合法场景照常通过。
    local -n _tbl="$1"   # 注意：nameref 声明必须单独一行，同一 local 语句的其它赋值也会被当成 nameref
    local _arg="$2"
    local -a _seen=()
    local kk vv dup=""
    for kk in vless hy2 ssh fallback; do
        [[ -n ${_tbl[$kk]:-} ]] || continue
        vv="${_tbl[$kk]}"
        if [[ " ${_seen[*]:-} " == *" $vv "* ]]; then dup="$vv"; fi
        _seen+=("$vv")
    done
    if [[ -n $dup ]]; then
        # parse_nat_map 在一次运行里会被多处调用（CLI 解析 / 摘要 / 重跑载入），
        # 同一端口只提醒一次，避免同一屏刷三遍
        local key="${_arg}:${dup}"
        [[ -n ${SHARED_PORT_WARNED[$key]:-} ]] && return 0
        SHARED_PORT_WARNED[$key]=1
        warn "${_arg}：外部端口 ${dup} 被多个服务共用 —— 仅当面板按 TCP / UDP 分别转发时才合法，请确认，否则其中一个服务连不上"
    fi
    return 0
}
# v6 也走宿主端口转发时，外部端口可能与 v4 不同，因此单独一张映射表。
parse_nat_map6() { # <spec> 形如 vless=31443,hy2=31444,ssh=31022
    NAT_EXT6=()
    [[ -n ${1:-} ]] || return 0
    local -a items=()
    IFS=',' read -r -a items <<< "$1"
    local it k v
    for it in "${items[@]}"; do
        it="${it// /}"
        [[ -z $it ]] && continue
        [[ $it == *=* ]] \
            || die "--nat-v6-map 每项应为「服务=外部端口」，如 vless=31443（收到: $it）"
        k="${it%%=*}"; v="${it#*=}"; k="${k,,}"
        case "$k" in
            vless|hy2|ssh|fallback) ;;
            *) die "--nat-v6-map 未知服务「$k」：只支持 vless / hy2 / ssh / fallback";;
        esac
        is_port "$v" || die "--nat-v6-map 的 ${k} 外部端口非法：$v"
        NAT_EXT6["$k"]="$v"
    done
    warn_shared_ext_ports NAT_EXT6 "--nat-v6-map"
    return 0
}
# 客户端该连哪个端口（按地址族独立判定）：
#   NAT_ACTIVE=0（两族都全开放）→ 一律用服务端监听端口，按原配置。
#   受限族：登记过外部端口就用外部端口（宿主 DNAT 转到内部端口）；未登记 = 内外同号，用内部端口。
#   全开放族：不套映射，仍用服务端监听端口。
client_port_for() { # <vless|hy2|ssh|fallback> <ip>
    local kind="$1" ip="${2:-}" internal="" ext=""
    case "$kind" in
        vless)    internal="$VLESS_PORT";;
        hy2)      internal="$HY2_PORT";;
        ssh)      internal="$SSH_PORT";;
        fallback) internal="$FALLBACK_PORT";;
    esac
    [[ ${NAT_ACTIVE:-0} -eq 1 ]] || { printf '%s' "$internal"; return 0; }
    if [[ $ip == *:* ]]; then
        [[ ${NAT_V6_OPEN:-0} -eq 0 ]] && ext="${NAT_EXT6[$kind]:-}"
    else
        [[ ${NAT_V4_OPEN:-0} -eq 0 ]] && ext="${NAT_EXT[$kind]:-}"
    fi
    [[ -n $ext ]] && internal="$ext"
    printf '%s' "$internal"
}

# ---- 客户端 server 地址：域名优先 -----------------------------------------
# 客户端 outbounds / 分享链接 / 二维码里的 server 不该写裸 IP：IP 会变、
# 双栈机型上还要为每个地址复制一份配置，而域名可以同时挂 A / AAAA 记录。
# 服务端入站监听仍按真实网卡地址处理（见 render_config），这一段只影响客户端。
# 每个地址族独立解析：分族专属域名 > --client-domain（两族共用） > --domain > IP。
# 习惯把 v4 / v6 分开的人给 --client-domain-v4 与 --client-domain-v6 两个域名即可，
# 两族各自的 DNS 只解析到本族地址，端口也不会被另一族的记录串用。
# --no-client-domain 置 CLIENT_DOMAIN_FORCE_IP=1，显式回到旧的裸 IP 行为。
client_host_for() { # <ip>
    local ip="${1:-}" host=""
    if [[ ${CLIENT_DOMAIN_FORCE_IP:-0} -eq 1 ]]; then
        printf '%s' "$ip"; return 0
    fi
    # 分族专属域名优先于共用域名，否则同时给三个参数时分族设置会被共用值盖掉。
    if [[ $ip == *:* && -n ${CLIENT_DOMAIN_V6:-} ]]; then
        host="$CLIENT_DOMAIN_V6"
    elif [[ $ip != *:* && -n ${CLIENT_DOMAIN_V4:-} ]]; then
        host="$CLIENT_DOMAIN_V4"
    elif [[ -n ${CLIENT_DOMAIN:-} ]]; then
        host="$CLIENT_DOMAIN"
    elif looks_like_domain "${DOMAIN:-}"; then
        host="$DOMAIN"
    fi
    [[ -n $host ]] || host="$ip"
    printf '%s' "$host"
}
client_host_uses_domain() { # 当前是否处于域名模式（供摘要 / 告警使用，不产生输出副作用）
    [[ ${CLIENT_DOMAIN_FORCE_IP:-0} -eq 1 ]] && return 1
    [[ -n ${CLIENT_DOMAIN:-} || -n ${CLIENT_DOMAIN_V4:-} || -n ${CLIENT_DOMAIN_V6:-} ]] && return 0
    looks_like_domain "${DOMAIN:-}" && return 0
    return 1
}
client_host_source_for() { # <ip>：该地址族 server 的来源，分开配置时逐族说明
    local ip="${1:-}"
    if [[ ${CLIENT_DOMAIN_FORCE_IP:-0} -eq 1 ]]; then printf 'IP（--no-client-domain）'
    elif [[ $ip == *:* && -n ${CLIENT_DOMAIN_V6:-} ]]; then printf -- '--client-domain-v6'
    elif [[ $ip != *:* && -n ${CLIENT_DOMAIN_V4:-} ]]; then printf -- '--client-domain-v4'
    elif [[ -n ${CLIENT_DOMAIN:-} ]]; then printf -- '--client-domain'
    elif looks_like_domain "${DOMAIN:-}"; then printf -- '--domain 回退'
    else printf 'IP（未指定域名）'
    fi
}
client_host_source() { # 整体来源说明（兼容旧调用方）
    if [[ ${CLIENT_DOMAIN_FORCE_IP:-0} -eq 1 ]]; then printf '已用 --no-client-domain 显式关闭，server 使用 IP'
    elif [[ -n ${CLIENT_DOMAIN_V4:-} && -n ${CLIENT_DOMAIN_V6:-} ]]; then printf -- '--client-domain-v4 / --client-domain-v6 分族指定'
    elif [[ -n ${CLIENT_DOMAIN_V4:-} ]]; then printf -- '--client-domain-v4 指定（v4）；v6 用共用域名 / --domain / IP'
    elif [[ -n ${CLIENT_DOMAIN_V6:-} ]]; then printf -- '--client-domain-v6 指定（v6）；v4 用共用域名 / --domain / IP'
    elif [[ -n ${CLIENT_DOMAIN:-} ]]; then printf -- '--client-domain 指定'
    elif looks_like_domain "${DOMAIN:-}"; then printf -- '--domain 自动回退'
    else printf '未指定域名，server 使用 IP'
    fi
}
client_domain_report() { # <summary|status>：按 v4 / v6 分族打印客户端 server 的来源
    local h4 h6 s4 s6 mode="${1:-status}" pfx=''
    h4="$(client_host_for '1.2.3.4')"
    h6="$(client_host_for '2001:db8::1')"
    s4="$(client_host_source_for '1.2.3.4')"
    s6="$(client_host_source_for '2001:db8::1')"
    [[ $mode == status ]] && pfx='  '
    if ! client_host_uses_domain; then
        # 这里绝不能打印 h4 / h6：它们只是用来判断「该族会用哪个域名」的占位地址
        # （1.2.3.4 / 2001:db8::1），当成客户端地址展示会和同屏的真实公网地址自相矛盾。
        printf '%s客户端地址 : 使用 IP（未指定域名；server 仍是 IP）\n' "$pfx"
        printf '%s             想用域名：--client-domain-v4 / --client-domain-v6 分开指定\n' "$pfx"
        return 0
    fi
    if [[ $h4 == "$h6" ]]; then
        printf '%s客户端域名 : v4 %s / v6 %s（两族共用；%s）\n' "$pfx" "$h4" "$h6" "$s4"
        printf '%s             确认该域名同时有 A / AAAA 记录并指向本机；想分开就给 --client-domain-v4 / --client-domain-v6\n' "$pfx"
    else
        printf '%s客户端域名 : v4 %s（%s）\n' "$pfx" "$h4" "$s4"
        printf '%s              v6 %s（%s）  ← v4 / v6 已分开\n' "$pfx" "$h6" "$s6"
        printf '%s             分别确认 v4 域名的 A 记录、v6 域名的 AAAA 记录指向本机\n' "$pfx"
    fi
    # 只有两族共用同一域名时，NAT 分族端口不同才会串用端口；分开域名后不存在该问题。
    if [[ $mode == summary && $h4 == "$h6" && ${NAT_ACTIVE:-0} -eq 1 ]] && \
       [[ "$(client_port_for vless '1.2.3.4')" != "$(client_port_for vless '2001:db8::1')" || \
          "$(client_port_for hy2 '1.2.3.4')" != "$(client_port_for hy2 '2001:db8::1')" ]]; then
        printf '%s             注意：共用域名 + NAT 分族端口不同会串用端口，建议给两族各配独立域名\n' "$pfx"
    fi
    return 0
}

# ---- 分族（v4 / v6）统一判定 ----------------------------------------------
# 为什么需要这一组：SSH_PORT 是「容器内 sshd 监听的唯一内部端口」，而 NAT 机的
# v4 / v6 外部端口可能完全不同（例如 v4 只给 20017 做 SSH、v6 全开放用 51736）。
# 之前摘要、--status、防火墙都只用一个 client_port_for ssh（不带 IP 时默认按 v4 算），
# 于是「SSH 命令写 20017 / fail2ban 写 51736 / 防火墙只放行 51736」前后矛盾。
# 这组函数按地址族给出唯一口径，供展示、防火墙、交付摘要共同使用。
ssh_port_for_family() { # <4|6>：该族客户端该连的 SSH 端口
    local ext=""
    if [[ ${NAT_ACTIVE:-0} -eq 1 ]]; then
        if [[ $1 == 6 ]]; then
            [[ ${NAT_V6_OPEN:-0} -eq 0 ]] && ext="${NAT_EXT6[ssh]:-}"
        else
            [[ ${NAT_V4_OPEN:-0} -eq 0 ]] && ext="${NAT_EXT[ssh]:-}"
        fi
    fi
    printf '%s' "${ext:-$SSH_PORT}"
}
family_runs_proxy() { # <4|6>：返回 0 = 该族要跑代理；1 = 该族只做管理
    [[ ${MANAGE_ONLY:-0} -eq 1 ]] && return 1
    local svc
    if [[ $1 == 6 ]]; then svc="${NAT_V6_SERVICES:-}"; else svc="${NAT_V4_SERVICES:-}"; fi
    [[ ${svc,,} == ssh-only ]] && return 1
    return 0
}
family_state_desc() { # <4|6>：分族策略的人类可读描述
    family_runs_proxy "$1" || { printf '只做管理（不跑代理）'; return 0; }
    local open
    if [[ $1 == 6 ]]; then open="${NAT_V6_OPEN:-0}"; else open="${NAT_V4_OPEN:-0}"; fi
    if [[ ${NAT_ACTIVE:-0} -eq 0 || $open -eq 1 ]]; then
        printf '端口全开放（按原配置）'
    else
        printf '受限（外部端口转发）'
    fi
    return 0
}
ssh_ports_for_family() { # <4|6>：该族防火墙需放行的 SSH TCP 端口，每行一个
    printf '%s\n' "$SSH_PORT"
    local ext; ext="$(ssh_port_for_family "$1")"
    [[ $ext != "$SSH_PORT" ]] && printf '%s\n' "$ext"
    # 显式返回 0：最后一条 [[ ]] 为假时返回 1，会在 set -e 下中断调用者
    return 0
}
ssh_access_report() { # 统一的 SSH 管理通道说明（交付摘要 / --status / 收尾）
    local p4 p6 v4ip="" v6ip="" x h4 h6
    p4="$(ssh_port_for_family 4)"; p6="$(ssh_port_for_family 6)"
    for x in "${NODE_IPS[@]:-}"; do
        [[ -z $x ]] && continue
        if [[ $x == *:* ]]; then [[ -z $v6ip ]] && v6ip="$x"
        else [[ -z $v4ip ]] && v4ip="$x"; fi
    done
    h4="${v4ip:-<IPv4地址>}"
    if [[ -n $v6ip ]]; then h6="[${v6ip}]"; else h6="[<IPv6地址>]"; fi
    if [[ $p4 == "$p6" ]]; then
        printf '  SSH 管理通道 : ssh -p %s root@<服务器IP>（v4 / v6 同端口，sshd 内部监听 %s）\n' \
            "$p4" "$SSH_PORT"
        return 0
    fi
    printf '  SSH 管理通道（按地址族区分；sshd 内部监听 %s）\n' "$SSH_PORT"
    printf '    v4 : ssh -p %-6s root@%s%s\n' "$p4" "$h4" \
        "$( family_runs_proxy 4 || printf '   ← 该族只做管理' )"
    printf '    v6 : ssh -p %-6s root@%s%s\n' "$p6" "$h6" \
        "$( family_runs_proxy 6 || printf '   ← 该族只做管理' )"
    if [[ ${NAT_ACTIVE:-0} -eq 1 ]]; then
        printf '    面板映射   : 外部端口须转到内部 %s（TCP）；防火墙已同时放行内外端口\n' "$SSH_PORT"
    fi
    return 0
}
# 该 IP 的客户端是否该用端口跳跃段（返回段字符串；不该用则输出空）。
#   非 NAT / 该族全开放 → 用全局 HOP_RANGE；该族受限 → 空（只用固定单端口）。
#   两族都受限时 apply_nat_adaptation 会清空 HOP_RANGE，此时本函数也直接返回空。
hop_range_for_ip() { # <ip>
    local ip="${1:-}"
    [[ -n ${HOP_RANGE:-} ]] || return 0
    if [[ ${NAT_ACTIVE:-0} -eq 1 ]]; then
        if [[ $ip == *:* ]]; then
            [[ ${NAT_V6_OPEN:-0} -eq 1 ]] || return 0
        else
            [[ ${NAT_V4_OPEN:-0} -eq 1 ]] || return 0
        fi
    fi
    printf '%s' "$HOP_RANGE"
}
# 该 IP 是否要生成指定协议的客户端节点。
#   只有「NAT 生效 + 该族受限 + 显式给了该族 services 白名单」时才过滤；
#   非 NAT、占位符 <服务器IP>、未给白名单一律不过滤。
nat_ip_needs() { # <ip> <vless|hy2>
    local ip="${1:-}" kind="$2" spec=""
    [[ ${NAT_ACTIVE:-0} -eq 1 ]] || return 0
    if [[ $ip == *:* ]]; then
        spec="${NAT_V6_SERVICES:-}"
    else
        spec="${NAT_V4_SERVICES:-}"
    fi
    # ssh-only：该族端口全给 SSH，不生成任何代理节点（占位符 IP 同样生效，
    # 否则不带 --ips 的离线渲染会意外吐出注定连不上的节点）
    [[ ${spec,,} == ssh-only ]] && return 1
    [[ -n $spec ]] || return 0
    [[ $ip == *:* || $ip =~ ^[0-9.]+$ ]] || return 0
    [[ ",${spec,,}," == *",${kind},"* ]]
}

# 两族都声明 ssh-only 时配置物理无解：必须在改系统或产出配置之前拦住。
# CLI / state.env 走 validate_settings，向导内的选择走 apply_nat_adaptation，
# 剩下的组合（单族无地址等）由 render_client_outbounds 兜底。
die_if_no_proxy_family() {
    # 「只做管理」是明确的整机意图：两族都不跑代理正是目标，不能当成配置错误拦下来。
    [[ ${MANAGE_ONLY:-0} -eq 0 ]] || return 0
    [[ ${NAT_V4_SERVICES:-} == ssh-only && ${NAT_V6_SERVICES:-} == ssh-only ]] || return 0
    die "v4 / v6 都设为 ssh-only：没有任何地址族能承载代理节点。请至少保留一族可跑代理（把 SSH 迁到另一族、把端口让给 vless），让服务商增加外部端口，或整机改用 --manage-only 只做管理"
}

# 渲染配置/下发规则前统一复查一遍（防状态文件被手工改坏）
validate_settings() {
    die_if_no_proxy_family
    need_port "--ssh-port"      "$SSH_PORT"
    need_port "--vless-port"    "$VLESS_PORT"
    need_port "--hy2-port"      "$HY2_PORT"
    need_port "--fallback-port" "$FALLBACK_PORT"
    need_hop_range
    # state.env 里的 NAT 参数同样要校验，不能只在 CLI 解析时查。
    # CLI 侧会归一化（去空格+小写），state.env 手工写入的 " vless, hy2 " 也要归一，
    # 否则 ssh-only 判定（== 比较）失配，该族被误判成「跑代理」。
    NAT_V4_SERVICES="${NAT_V4_SERVICES// /}"; NAT_V4_SERVICES="${NAT_V4_SERVICES,,}"
    NAT_V6_SERVICES="${NAT_V6_SERVICES// /}"; NAT_V6_SERVICES="${NAT_V6_SERVICES,,}"
    [[ -z $NAT_PORTS ]]    || need_nat_ports "$NAT_PORTS"
    [[ -z $NAT_V6_PORTS ]] || need_nat_ports "$NAT_V6_PORTS"
    need_nat_v4_services "$NAT_V4_SERVICES"
    need_nat_v6_services "$NAT_V6_SERVICES"
    parse_nat_map "$NAT_MAP"
    parse_nat_map6 "$NAT_V6_MAP"
    need_duration "--hop-interval"        "$HOP_INTERVAL"
    need_duration "--hop-interval-max"    "$HOP_INTERVAL_MAX"
    need_duration "--tcp-keep-alive"      "$TCP_KEEP_ALIVE"
    need_duration "--tcp-keep-alive-int"  "$TCP_KEEP_ALIVE_INTERVAL"
    # 会被直接写进 config.json 的自由文本，必须过白名单
    need_hostname "--reality-sni"          "$REALITY_SNI"
    need_hostname "--cert-cn"              "$CERT_CN"
    # 客户端连接域名会直接写进 outbounds 的 server，state.env 里被手工改坏也要挡住。
    need_client_domain "--client-domain"    "${CLIENT_DOMAIN:-}"
    need_client_domain "--client-domain-v4" "${CLIENT_DOMAIN_V4:-}"
    need_client_domain "--client-domain-v6" "${CLIENT_DOMAIN_V6:-}"
    # 这批 0/1 开关都会被 [[ … -eq 1 ]] 判定：手工把 state.env 改成 "1x" 时 bash 算术
    # 会报错并按 0 处理（例如「只做管理」被静默反转成完整部署），必须在入口统一挡住。
    local _bk _bv
    for _bk in CLIENT_DOMAIN_FORCE_IP NAT_V4_OPEN NAT_V6_OPEN MANAGE_ONLY BIND_ALL; do
        _bv="${!_bk:-0}"
        [[ $_bv == 0 || $_bv == 1 ]] \
            || die "${_bk} 只能是 0 / 1（收到: ${_bv}）；请修正 ${STATE_FILE} 或删除该文件后重跑"
    done
    need_host     "--reality-dest"         "$REALITY_DEST"
    [[ -z ${REALITY_DEST_PORT:-} ]] || is_port "$REALITY_DEST_PORT" \
        || die "reality 握手端口非法：$REALITY_DEST_PORT"
    [[ -z ${UUID:-} ]] || is_uuid "$UUID" \
        || die "--uuid 非法：需为标准 UUID，如 11111111-2222-4333-8444-555555555555（收到: $UUID）"
    [[ -z ${SHAPER_RATE:-} ]] || is_rate "$SHAPER_RATE" \
        || die "--shaper-rate 非法：应为 Mbps 数字，如 1000（收到: $SHAPER_RATE）"
    # --acme-ca 会原样作为 `acme.sh --server` 的取值。拼错时错误要等到 DNS 记录生效、
    # 走到签发那一步才暴露（前面已经等了 TXT 记录），成本很高，入口先挡一道。
    case "${ACME_CA:-letsencrypt}" in
        letsencrypt|letsencrypt_test|zerossl|buypass|buypass_test|google|googletest|sslcom|http://*|https://*) ;;
        *) die "--acme-ca 只接受 letsencrypt / zerossl 等已知名称，或 CA 的 http(s) 地址（收到: ${ACME_CA}）；详见 --help";;
    esac
    [[ -z ${TCP_BW:-} ]] || [[ ${TCP_BW} =~ ^[1-9][0-9]*$ ]] \
        || die "--tcp-bw 非法：应为正整数（Mbps），如 1000（收到: $TCP_BW）"
    # SB_* 与 TCP_BW 同权兜底：state.env 被手工改坏（如写入 abc）时在此就报错，
    # 否则要拖到渲染层 j_lit 才 die，且报错不指向 state.env。
    [[ -z ${SB_UP_MBPS:-} ]] || [[ ${SB_UP_MBPS} =~ ^[1-9][0-9]*$ ]] \
        || die "SB_UP_MBPS 非法（${STATE_FILE}）：应为正整数（Mbps）（收到: $SB_UP_MBPS）"
    [[ -z ${SB_DOWN_MBPS:-} ]] || [[ ${SB_DOWN_MBPS} =~ ^[1-9][0-9]*$ ]] \
        || die "SB_DOWN_MBPS 非法（${STATE_FILE}）：应为正整数（Mbps）（收到: $SB_DOWN_MBPS）"
    # 跳跃范围覆盖 hy2 端口时，DNAT 会把落在监听端口上的包再次改写成同一端口，语义混乱
    if [[ -n $HOP_RANGE ]]; then
        local a="${HOP_RANGE%%:*}" b="${HOP_RANGE##*:}"
        (( HY2_PORT >= a && HY2_PORT <= b )) && warn "hy2 端口 ${HY2_PORT} 落在跳跃范围 ${HOP_RANGE} 内，建议把监听端口移出该区间"
    fi
    return 0
}

# 记录「命令行显式指定过」的变量名。load_state 依赖它判断优先级：
# 显式指定 > 状态文件 > 内置默认值（详见 load_state 的注释）
declare -A CLI_SET=()
# 记录「模式是否由命令行显式给出」，用来拦截 --keep-config 与 --new-config 同时出现。
# 与 RERUN_MODE 分开：后者也可能来自环境变量，不能拿它判断用户是否本轮表过态。
RERUN_MODE_CLI=""
mark_cli() {
    local opt="$1" key
    case "$opt" in
        --ips)          key="IP_LIST";;
        --no-hop)       key="HOP_RANGE";;
        --nat|--no-nat) key="NAT_MODE";;
        --no-nat-v4-open) key="NAT_V4_OPEN";;
        --no-nat-v6-open) key="NAT_V6_OPEN";;
        # 共用域名只标记 CLIENT_DOMAIN：分族域名（--client-domain-v4/-v6）**优先于**共用值，
        # 若这里连带把 V4/V6 记成"命令行指定过"，load_state 就不再回填，save_state 会把
        # 状态文件里的分族域名写成空串 —— 一次 --client-domain 就永久抹掉分族配置。
        # 要清空分族域名请用 --no-client-domain（或分族的 --no-client-domain-v4/-v6）。
        --client-domain)
            CLI_SET[CLIENT_DOMAIN]=1; CLI_SET[CLIENT_DOMAIN_FORCE_IP]=1; return 0;;
        --no-client-domain)
            CLI_SET[CLIENT_DOMAIN]=1; CLI_SET[CLIENT_DOMAIN_V4]=1
            CLI_SET[CLIENT_DOMAIN_V6]=1
            CLI_SET[CLIENT_DOMAIN_FORCE_IP]=1; return 0;;
        --client-domain-v4)
            CLI_SET[CLIENT_DOMAIN_V4]=1; CLI_SET[CLIENT_DOMAIN_FORCE_IP]=1; return 0;;
        --client-domain-v6)
            CLI_SET[CLIENT_DOMAIN_V6]=1; CLI_SET[CLIENT_DOMAIN_FORCE_IP]=1; return 0;;
        --no-client-domain-v4) key="CLIENT_DOMAIN_V4";;
        --no-client-domain-v6) key="CLIENT_DOMAIN_V6";;
        --manage-only|--no-manage-only) key="MANAGE_ONLY";;
        --sb-bandwidth) CLI_SET[SB_UP_MBPS]=1; CLI_SET[SB_DOWN_MBPS]=1; return 0;;
        --tcp-keep-alive-int) key="TCP_KEEP_ALIVE_INTERVAL";;
        --*)            key="${opt#--}"; key="${key//-/_}"; key="${key^^}";;
        *)              return 0;;
    esac
    CLI_SET["$key"]=1
    return 0
}

while [[ $# -gt 0 ]]; do
    mark_cli "$1"
    case "$1" in
        --ssh-port) need_val "$@"; need_port "--ssh-port" "$2"; SSH_PORT="$2"; shift 2;;
        --pubkey) need_val "$@"; PUBKEY="$2"; shift 2;;
        --pubkey-file) need_val "$@"; PUBKEY_FILE="$2"; shift 2;;
        --pubkey-url) need_val "$@"; PUBKEY_URL="$2"; shift 2;;
        --domain) need_val "$@"; need_hostname "--domain" "$2"; DOMAIN="$2"; shift 2;;
        --client-domain) need_val "$@"; need_client_domain "--client-domain" "$2"
            CLIENT_DOMAIN="$2"; CLIENT_DOMAIN_FORCE_IP=0; shift 2;;
        # v4 / v6 对称：两个分族域名都优先于共用域名，习惯分开就各给一个。
        --client-domain-v4) need_val "$@"; need_client_domain "--client-domain-v4" "$2"
            CLIENT_DOMAIN_V4="$2"; CLIENT_DOMAIN_FORCE_IP=0; shift 2;;
        --no-client-domain-v4) CLIENT_DOMAIN_V4=""; shift;;
        --client-domain-v6) need_val "$@"; need_client_domain "--client-domain-v6" "$2"
            CLIENT_DOMAIN_V6="$2"; CLIENT_DOMAIN_FORCE_IP=0; shift 2;;
        --no-client-domain-v6) CLIENT_DOMAIN_V6=""; shift;;
        # 关闭域名模式要连两个分族专属域名一起清掉，否则状态文件里残留的域名
        # 会在下次给 --client-domain 时又把节点偷偷改成另一个域名。
        --no-client-domain)
            CLIENT_DOMAIN=""; CLIENT_DOMAIN_V4=""; CLIENT_DOMAIN_V6=""
            CLIENT_DOMAIN_FORCE_IP=1; shift;;
        --cf-token) need_val "$@"; CF_TOKEN="$2"; shift 2;;
        --acme-email) need_val "$@"; ACME_EMAIL="$2"; shift 2;;
        --acme-ca) need_val "$@"; ACME_CA="$2"; shift 2;;
        --reality-sni) need_val "$@"; need_hostname "--reality-sni" "$2"; REALITY_SNI="$2"; shift 2;;
        --reality-dest) need_val "$@"; need_host "--reality-dest" "$2"; REALITY_DEST="$2"; shift 2;;
        --reality-dest-port) need_val "$@"; need_port "--reality-dest-port" "$2"; REALITY_DEST_PORT="$2"; shift 2;;
        --cert-cn) need_val "$@"; need_hostname "--cert-cn" "$2"; CERT_CN="$2"; shift 2;;
        --web-page) need_val "$@"; WEB_PAGE="$2"; shift 2;;
        --vless-port) need_val "$@"; need_port "--vless-port" "$2"; VLESS_PORT="$2"; shift 2;;
        --hy2-port) need_val "$@"; need_port "--hy2-port" "$2"; HY2_PORT="$2"; shift 2;;
        --fallback-port) need_val "$@"; need_port "--fallback-port" "$2"; FALLBACK_PORT="$2"; shift 2;;
        --hop-range) need_val "$@"; HOP_RANGE="$2"; need_hop_range; shift 2;;
        --no-hop) HOP_RANGE=""; shift;;
        --ips) need_val "$@"
            # auto = 显式放弃状态文件里的旧 IP 列表，回到自动探测
            # （mark_cli 已把 IP_LIST 记为"命令行指定过"，因此置空不会被 load_state 回填）
            if [[ $2 == auto ]]; then IP_LIST=""; else IP_LIST="$2"; fi
            shift 2;;
        --bind-all) BIND_ALL=1; shift;;
        --nat) NAT_MODE=force; shift;;
        --no-nat) NAT_MODE=off; shift;;
        --nat-ports) need_val "$@"; need_nat_ports "$2" "--nat-ports"; NAT_PORTS="$2"; shift 2;;
        --nat-map) need_val "$@"; parse_nat_map "$2"; NAT_MAP="$2"; shift 2;;
        --nat-v4-open) NAT_V4_OPEN=1; shift;;
        --no-nat-v4-open) NAT_V4_OPEN=0; shift;;
        --nat-v6-open) NAT_V6_OPEN=1; shift;;
        --no-nat-v6-open) NAT_V6_OPEN=0; shift;;
        --nat-v6-ports) need_val "$@"; need_nat_ports "$2" "--nat-v6-ports"; NAT_V6_PORTS="$2"; shift 2;;
        --nat-v6-map) need_val "$@"; parse_nat_map6 "$2"; NAT_V6_MAP="$2"; shift 2;;
        --nat-v4-services) need_val "$@"; need_nat_v4_services "$2"
            # 校验时剥离了空格，存值也必须剥离：否则 "vless, hy2" 会被下游按
            # 字面量比对（",hy2," 匹配不到），节点静默少一半
            NAT_V4_SERVICES="${2// /}"; NAT_V4_SERVICES="${NAT_V4_SERVICES,,}"; shift 2;;
        --nat-v6-services) need_val "$@"; need_nat_v6_services "$2"
            NAT_V6_SERVICES="${2// /}"; NAT_V6_SERVICES="${NAT_V6_SERVICES,,}"; shift 2;;
        --nat-wizard) NAT_WIZARD=on; shift;;
        --no-nat-wizard) NAT_WIZARD=off; shift;;
        --manage-only) MANAGE_ONLY=1; shift;;
        --no-manage-only) MANAGE_ONLY=0; shift;;
        --up-mbps) need_val "$@"; need_posint "--up-mbps" "$2"; UP_MBPS="$2"; shift 2;;
        --down-mbps) need_val "$@"; need_posint "--down-mbps" "$2"; DOWN_MBPS="$2"; shift 2;;
        --hop-interval) need_val "$@"; need_duration "--hop-interval" "$2"; HOP_INTERVAL="$2"; shift 2;;
        --hop-interval-max) need_val "$@"; need_duration "--hop-interval-max" "$2"; HOP_INTERVAL_MAX="$2"; shift 2;;
        --tcp-keep-alive) need_val "$@"; need_duration "--tcp-keep-alive" "$2"; TCP_KEEP_ALIVE="$2"; shift 2;;
        --tcp-keep-alive-int) need_val "$@"; need_duration "--tcp-keep-alive-int" "$2"; TCP_KEEP_ALIVE_INTERVAL="$2"; shift 2;;
        --sb-bandwidth) need_val "$@"
            # 严格两段校验：一个冒号、两侧均为正整数。"200:500:100" 这类三段值
            # 若放行会被 %%: / ##: 静默解析成 200:100，限速悄悄打折。
            [[ $2 =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]] \
                || die "--sb-bandwidth 格式应为 上行:下行（两个正整数，仅一个冒号），如 200:500（收到: $2）"
            SB_UP_MBPS="${2%%:*}"; SB_DOWN_MBPS="${2##*:}"
            shift 2;;
        --node-name) need_val "$@"; NODE_NAME="$2"; shift 2;;
        --shaper-rate) need_val "$@"; is_rate "$2" || die "--shaper-rate 非法：应为 Mbps 数字，如 1000（收到: $2）"; SHAPER_RATE="$2"; shift 2;;
        --tcp-bw) need_val "$@"
            [[ $2 =~ ^[1-9][0-9]*$ ]] \
                || die "--tcp-bw 非法：应为正整数（Mbps），如 1000（收到: $2）"
            TCP_BW="$2"; shift 2;;
        --uuid) need_val "$@"; is_uuid "$2" || die "--uuid 非法：需为标准 UUID（收到: $2）"; UUID="$2"; shift 2;;
        --keep-config|--new-config)
            _rm_v="keep"; [[ $1 == --new-config ]] && _rm_v="new"
            [[ -z $RERUN_MODE_CLI || $RERUN_MODE_CLI == "$_rm_v" ]] \
                || die "选项冲突：--keep-config（沿用旧配置）与 --new-config（生成新配置）只能选一个"
            RERUN_MODE_CLI="$_rm_v"; RERUN_MODE="$_rm_v"; shift;;
        --config-mode) need_val "$@"
            _rm_v=""
            case "${2,,}" in
                keep|1|old|reuse|沿用旧配置)   _rm_v="keep";;
                new|2|regen|rotate|生成新配置) _rm_v="new";;
                *) die "--config-mode 非法：只能是 keep（沿用旧配置）或 new（生成新配置），收到: $2";;
            esac
            [[ -z $RERUN_MODE_CLI || $RERUN_MODE_CLI == "$_rm_v" ]] \
                || die "选项冲突：已指定 --config-mode ${RERUN_MODE_CLI}，不能再指定 ${_rm_v}"
            RERUN_MODE_CLI="$_rm_v"; RERUN_MODE="$_rm_v"; shift 2;;
        --sb-version) need_val "$@"; SB_VERSION="$2"; shift 2;;
        --modules) need_val "$@"; MODULES_ARG="$2"; shift 2;;
        --yes|-y) ASSUME_YES=1; shift;;
        --print-config) PRINT_CONFIG=1; shift;;
        --print-outbounds) PRINT_OUTBOUNDS=1; shift;;
        --status) SHOW_STATUS=1; shift;;
        --doctor) DOCTOR=1; shift;;
        --json) STATUS_JSON=1; DOCTOR_JSON=1; shift;;
        --rotate-secrets)
            ROTATE_SECRETS=1; MODULES_ARG="6,8,9"
            # 环境变量 RERUN_MODE=keep 会与新配置模式静默冲突：轮换必须重写 config.json，
            # keep 语义在此不成立 —— 必须留痕，不能无声覆盖用户显式给出的 keep。
            [[ ${RERUN_MODE:-} == keep ]] && warn "环境变量 RERUN_MODE=keep 与 --rotate-secrets 冲突：轮换必须重写配置，已按「生成新配置」处理"
            RERUN_MODE=new; shift;;
        --uninstall) UNINSTALL=1; shift;;
        --purge-state) PURGE_STATE=1; shift;;
        --self-test) SELF_TEST=1; shift;;
        -h|--help) usage; exit 0;;
        *) err "未知参数: $1"; usage; exit 1;;
    esac
done

# --rotate-secrets 的语义是「必须走到模块 6 才有凭据可换」。如果同一命令行里
# --modules 把它盖掉（例如 --rotate-secrets --modules 1），就会出现
# 「提示正在轮换、实际一个凭据都没动，还报告成功」的假成功，这里统一拉回。
if [[ ${ROTATE_SECRETS:-0} -eq 1 ]]; then
    # 轮换的本质是「生成新凭据 + 重写配置」，与「沿用旧配置」互斥。
    # 用户显式给了 --keep-config 时，把 RERUN_MODE 悄悄改成 new 违背其明确意图 —— 报错而非覆盖。
    if [[ ${RERUN_MODE_CLI:-} == keep ]]; then
        die "--rotate-secrets 与 --keep-config 冲突：轮换必须重写 config.json 与客户端交付，请去掉 --keep-config（或改用 --new-config）"
    fi
    if [[ -n ${MODULES_ARG:-} && ${MODULES_ARG// /} != "6,8,9" ]]; then
        warn "--rotate-secrets 只跑模块 6/8/9，本次 --modules ${MODULES_ARG} 已被覆盖（轮换必须包含凭据生成与渲染）"
    fi
    MODULES_ARG="6,8,9"
    RERUN_MODE=new
fi

# --purge-state 只是 --uninstall 的修饰符：单独出现时什么都不会发生。
# 提示在解析后立即给出：若后面 preflight 因缺依赖 / 非 root 直接 die，
# 这里的提示是用户能看到的唯一线索（否则会误以为 state.env 已经被删了）。
if [[ ${PURGE_STATE:-0} -eq 1 && ${UNINSTALL:-0} -ne 1 ]]; then
    warn "--purge-state 只与 --uninstall 搭配生效；本次没有 --uninstall，该参数被忽略（state.env 未删除）"
fi

# ===== §8 状态存取 =====
# STATE_KEYS 是**唯一**的持久化清单：save_state 与 load_state 都由它派生，
# 避免"写的时候漏一个键、读的时候多一个键"这种只有跑到线上才发现的偏差。
STATE_KEYS=(SSH_PORT TZ_NAME VLESS_PORT HY2_PORT FALLBACK_PORT HOP_RANGE IP_LIST BIND_ALL \
    NAT_MODE NAT_PORTS NAT_MAP NAT_V4_OPEN NAT_V6_OPEN \
    NAT_V6_PORTS NAT_V6_MAP NAT_V4_SERVICES NAT_V6_SERVICES MANAGE_ONLY \
    UP_MBPS DOWN_MBPS HOP_INTERVAL HOP_INTERVAL_MAX TCP_KEEP_ALIVE TCP_KEEP_ALIVE_INTERVAL \
    SB_UP_MBPS SB_DOWN_MBPS SHAPER_RATE TCP_BW DOMAIN \
    CLIENT_DOMAIN CLIENT_DOMAIN_V4 CLIENT_DOMAIN_V6 CLIENT_DOMAIN_FORCE_IP ACME_CA ACME_EMAIL WEB_PAGE \
    REALITY_SNI REALITY_DEST REALITY_DEST_PORT CERT_CN \
    UUID REALITY_PRIV REALITY_PUB SHORT_ID HY2_PW OBFS_PW CERT_HASH CERT_SHA256 NODE_NAME SB_STATE_AHEAD)

# 节点凭据清单：选择「生成新配置」且执行模块 6 时全部重新生成，让旧客户端配置与分享链接作废。
# 与 STATE_KEYS 分开——前者是「需要持久化」的清单，这里是「生成新配置时必须轮换」的清单。
# 「沿用旧配置」时模块 6 整段跳过，这套值一个都不会动。
# 注意：回落站的 acme.sh 证书（${SB_DIR}/cert/）不属于节点凭据，仍按模块 7 的
# 复用逻辑处理，否则每次重跑都会重新要求 CF Token。
CRED_KEYS=(UUID SHORT_ID HY2_PW OBFS_PW REALITY_PRIV REALITY_PUB CERT_HASH CERT_SHA256)
CRED_ROTATED=0
# 状态/配置分叉标记：模块 6 把轮换后的新凭据写入 state.env、而磁盘上仍有旧
# config.json 时置 1 —— 此后模块 7/8 失败出口据此提醒用户必须重选「生成新配置」，
# 否则 keep 重跑会按 state 的新凭据渲染出「与线上不一致」的假配置。
# 进 STATE_KEYS 持久化：半失败后进程退出，下次 --status / keep 重跑也能看到警示；
# 模块 8 成功路径（配置已校验、服务已起）会清零。若用户在脚本外手工修好了
# config.json，可手工把 state.env 里这行改回 0（或重跑一次模块 8）。
SB_STATE_AHEAD=0
regen_credentials() { # [force] force=1 时连命令行显式指定的值也清空（「生成新配置」专用）
    local k force="${1:-0}"
    CRED_ROTATED=0
    for k in "${CRED_KEYS[@]}"; do
        # force=0：命令行显式指定的值（目前只有 --uuid）是用户的明确意图，保留。
        # force=1：「生成新配置」要求整套全新、禁止复用固定值，因此一律清空重生成。
        if [[ $force -eq 0 && -n ${CLI_SET[$k]:-} ]]; then continue; fi
        # 只要有一个非空凭据被清空，就是「轮换过」。
        # 不能拿 UUID 是否变化来判断：--uuid 固定 UUID 时其它凭据照样全换了。
        [[ -n ${!k:-} ]] && CRED_ROTATED=1
        printf -v "$k" '%s' ''
    done
    return 0
}

# --rotate-secrets 的定向轮换（纯函数，自检可直接断言）：
# 只清 UUID / SHORT_ID / HY2_PW / OBFS_PW 四项 —— 现有客户端全部作废，
# 但 Reality 密钥对与自签证书保持不变（客户端只需重新导入账号密码类凭据）。
# 轮换结果与 regen_credentials 同约定：CRED_ROTATED=1 表示至少清空了一个非空凭据。
rotate_session_credentials() {
    local k
    CRED_ROTATED=0
    for k in UUID SHORT_ID HY2_PW OBFS_PW; do
        [[ -n ${!k:-} ]] && CRED_ROTATED=1
        printf -v "$k" '%s' ''
    done
    return 0
}

# 值里可能出现 " 或 \（例如 --web-page 的路径），直接内插会把引号配对弄坏，
# 下次读回来就是一个被截断的值。写入转义、读取反转义，成对使用。
state_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/}"; s="${s//$'\r'/}"
    printf '%s' "$s"
}
state_unescape() {
    local s="$1"
    s="${s//\\\"/\"}"
    s="${s//\\\\/\\}"
    printf '%s' "$s"
}

rotate_old_baks() { # <glob模式> [保留份数=5]：时间戳备份轮转，防止 /root 无限堆积
    local pattern="$1" keep="${2:-5}"
    local -a old_baks=()
    mapfile -t old_baks < <(ls -1t $pattern 2>/dev/null || true)
    local f
    for f in "${old_baks[@]:$keep}"; do rm -f "$f"; done
    return 0
}

tee_600() { # 与 tee 相同，但以 umask 077 创建目标文件：
            # 交付文件内含凭据明文，不允许「创建到 chmod 之间」的全局可读瞬间
    umask 077
    tee "$1"
}

save_state() {
    mkdir -p "$STATE_DIR"
    local k buf=""
    for k in "${STATE_KEYS[@]}"; do
        buf+="${k}=\"$(state_escape "${!k}")\""$'\n'
    done
    # 原子写：state.env 是凭据的唯一记录，直接 `> 文件` 若在磁盘满/中断时截断，
    # 等于一次性丢失 UUID 与 Reality 私钥。先写临时文件再 mv，读者永远看不到半份文件。
    # umask 077 保证新建的临时文件从一开始就是 600，不给 644 的窗口。
    if ! ( umask 077; printf '%s' "$buf" > "${STATE_FILE}.tmp" ) \
       || ! mv -f "${STATE_FILE}.tmp" "$STATE_FILE"; then
        rm -f "${STATE_FILE}.tmp"
        die "写入 ${STATE_FILE} 失败（磁盘满 / 权限不足）；凭据未持久化，请处理后重跑"
    fi
    chmod 600 "$STATE_FILE"
}

# 只回填「命令行没有显式指定」的变量：优先级 = 命令行 > 状态文件 > 内置默认值
load_state() {
    [[ -f $STATE_FILE ]] || return 0
    local line k v
    # `|| [[ -n $line ]]`：state.env 若被编辑器去掉末尾换行，最后一行也要读到；
    # CR 剥离：state.env 是纯手工可编辑文件，Windows 编辑器存成 CRLF 会把 \r
    # 混进凭据值（UUID 后跟一个 CR）—— 轮换/渲染全部静默变错，必须在这里拦住。
    while IFS= read -r line || [[ -n $line ]]; do
        line="${line%$'\r'}"
        [[ $line == *=* ]] || continue
        k="${line%%=*}"; v="${line#*=}"
        # 白名单：state.env 是可以手工编辑的，不能盲信里面的键名
        [[ " ${STATE_KEYS[*]} " == *" ${k} "* ]] || continue
        v="${v#\"}"; v="${v%\"}"
        v="$(state_unescape "$v")"
        # 判据是「命令行是否显式指定过」，而不是「当前值是否为空」：
        # 大量参数自带内置默认值，用空值判断会让状态文件永远无法生效
        # （例如上次 --ssh-port 2222，本次 --modules 3 会错误地放行默认的 51736）
        if [[ -z ${CLI_SET[$k]:-} ]]; then printf -v "$k" '%s' "$v"; fi
    done < "$STATE_FILE"
    return 0
}

# ===== 重跑二选一：沿用旧配置 / 生成新配置 =====
# 三条硬约束，改动前务必先读：
#  1. 没有明确选择时绝不自动覆盖任何已有配置或凭据 —— 一律落到 keep。
#  2. 模式**不写进 state.env**：下一次重跑必须重新表态，不能被上次的选择"自动续期"。
#  3. 首次部署没有旧配置可沿用，强制按 new 处理，保证开荒流程照常完成。
validate_rerun_mode() { # <值>："" / keep / new 合法
    case "${1:-}" in ""|keep|new) return 0;; *) return 1;; esac
}
has_existing_deployment() { # 是否已有「不可无表态覆盖的部署痕迹」
    # 只要 config.json 存在，就说明这台机器上有旧配置 —— 哪怕 state.env 被手工改坏
    # （UUID 被清空、旧版本状态文件缺键），也不能在用户没明确选择时覆盖它。
    # 「状态文件 + 有效凭据、但 config.json 还没生成」属于首次部署中途，同样算痕迹。
    if [[ -s $SB_CONF ]]; then return 0; fi
    [[ -f $STATE_FILE && -n ${UUID:-} ]]
}
should_force_regen() { # 是否「重跑 + 生成新配置」→ 连 --uuid 这类固定值也清空
    # 首次部署不算「重新运行」，显式给的 UUID 要尊重；重跑才必须整套换新。
    [[ ${RERUN_MODE:-} == new && ${RERUN_IS_FIRST:-0} -eq 0 ]]
}
restore_credentials_for_keep() {
    # 「沿用旧配置」时若命令行还带了 --uuid，不能让它生效：config.json 不会被重写，
    # 但模块 7 的 save_state 会把新值写进 state.env，造成「状态文件与正在运行的配置
    # 用的是两套凭据」。这里统一以 state.env 为准，把凭据变量恢复回来。
    [[ ${RERUN_MODE:-} == keep ]] || return 0
    [[ -n ${CLI_SET[UUID]:-} ]] || return 0
    [[ -f $STATE_FILE ]] || return 0
    local line k v
    while IFS= read -r line; do
        [[ $line == *=* ]] || continue
        k="${line%%=*}"; v="${line#*=}"
        [[ " ${CRED_KEYS[*]} " == *" ${k} "* ]] || continue
        v="${v#\"}"; v="${v%\"}"
        v="$(state_unescape "$v")"
        printf -v "$k" '%s' "$v"
    done < "$STATE_FILE"
    unset 'CLI_SET[UUID]'
    warn "选择了「沿用旧配置」，命令行 --uuid 已忽略：以 ${STATE_FILE} 里的现有凭据为准，避免状态文件与 config.json 不一致"
}
restore_client_domain_for_keep() {
    # 「沿用旧配置」时命令行给的 --client-domain 不能生效：模块 9 虽然不重写文件，
    # 但仍会把 outbounds 打到终端，如果沿用 CLI 的新域名就会显示一份线上并不存在的配置。
    # 与 restore_credentials_for_keep 同策略：以 state.env 为准恢复四个域名键。
    [[ ${RERUN_MODE:-} == keep ]] || return 0
    [[ -f $STATE_FILE ]] || return 0
    local k line v _found
    for k in CLIENT_DOMAIN CLIENT_DOMAIN_V4 CLIENT_DOMAIN_V6 CLIENT_DOMAIN_FORCE_IP; do
        [[ -n ${CLI_SET[$k]:-} ]] || continue
        v=""; _found=0
        while IFS= read -r line; do
            [[ $line == "$k="* ]] || continue
            v="${line#*=}"; v="${v#\"}"; v="${v%\"}"; v="$(state_unescape "$v")"; _found=1; break
        done < "$STATE_FILE"
        # state 缺键（旧版本状态文件）时保留 CLI 值不动：把空串写回去会静默清掉用户参数
        if [[ $_found -eq 1 ]]; then
            printf -v "$k" '%s' "$v"
            unset "CLI_SET[$k]"
        fi
    done
    return 0
}
restore_server_params_for_keep() {
    # 「沿用旧配置」时命令行给的服务端参数不能生效：config.json 不会被重写，
    # 但模块 7 仍会用新 DOMAIN 重写 Caddyfile / 复用证书，模块 9 仍会把带新
    # 参数的 outbounds 打到终端 —— 都会造出「线上并不存在」的配置。
    # 与 restore_client_domain_for_keep 同策略：以 state.env 为准恢复。
    [[ ${RERUN_MODE:-} == keep ]] || return 0
    [[ -f $STATE_FILE ]] || return 0
    local k line v _touched=""
    # 端口三件套必须一并恢复：keep 下 config.json 不重写，sing-box 仍监听旧端口；
    # 但模块 3 防火墙 / 模块 9 分享链接会拿新端口下发 —— 新端口对外放行、旧端口才在监听，
    # 节点静默不可达（Reality 的 fallback-port 甚至会直接打断回落握手）。
    for k in DOMAIN VLESS_PORT HY2_PORT FALLBACK_PORT REALITY_SNI REALITY_DEST REALITY_DEST_PORT \
             TCP_KEEP_ALIVE TCP_KEEP_ALIVE_INTERVAL HOP_INTERVAL HOP_INTERVAL_MAX HOP_RANGE; do
        [[ -n ${CLI_SET[$k]:-} ]] || continue
        v=""; _found=0
        while IFS= read -r line; do
            [[ $line == "$k="* ]] || continue
            v="${line#*=}"; v="${v#\"}"; v="${v%\"}"; v="$(state_unescape "$v")"; _found=1; break
        done < "$STATE_FILE"
        # state 缺键（旧版本状态文件）时保留 CLI 值不动：把空串写回去会静默清掉用户参数，
        # 而端口被清空后 need_port 的报错还指向 state，让人白查一轮。
        if [[ $_found -eq 1 ]]; then
            printf -v "$k" '%s' "$v"
            unset "CLI_SET[$k]"
            _touched+=" ${k}"
        fi
    done
    if [[ -n $_touched ]]; then
        warn "选择了「沿用旧配置」，命令行参数（${_touched# }）已忽略：以 ${STATE_FILE} 现值为准，避免状态文件 / config.json / Caddyfile 三者不一致"
    fi
    return 0
}
ask_client_domain() { # <提示> <默认值> → 输出合法域名 / 空（清空）；输入 - 也视为清空
    local p="$1" d="$2" v
    while true; do
        v="$(ask "$p" "$d")"
        [[ $v == - ]] && { printf ''; return 0; }
        [[ -z $v ]] && { printf ''; return 0; }
        # 校验必须与 CLI（need_client_domain）同标准：is_hostname 挡非法字符
        # （引号 / $ / 空格会拼坏 JSON 与 state.env），looks_like_domain 挡 IP 与裸主机名。
        if is_hostname "$v" && looks_like_domain "$v"; then printf '%s' "$v"; return 0; fi
        # 提示必须走 stderr：本函数的 stdout 会被调用方的命令替换捕获。
        warn "「${v}」不是合法域名：需要含点号的完整域名（如 node.example.com），不能是 IP、裸主机名或含空格 / 引号等特殊字符" >&2
        d=""
    done
}
ask_client_domains() { # 交互式部署前按 v4 / v6 分别询问客户端 server 域名
    [[ -n ${ASSUME_YES:-} ]] && return 0
    [[ ${MANAGE_ONLY:-0} -eq 1 ]] && return 0
    [[ -z ${MODULES_ARG:-} ]] || return 0
    stdin_is_tty || return 0
    local d4 d6 a4 a6 old_force="${CLIENT_DOMAIN_FORCE_IP:-0}"
    local old4="${CLIENT_DOMAIN_V4:-}" old6="${CLIENT_DOMAIN_V6:-}"
    # 已有分族值优先；否则把共用域名当默认值，直接回车即保持「两族共用」的旧语义。
    d4="${CLIENT_DOMAIN_V4:-${CLIENT_DOMAIN:-}}"
    d6="${CLIENT_DOMAIN_V6:-${CLIENT_DOMAIN:-}}"
    hr
    info "客户端 server 地址（建议用域名）：v4 / v6 可各给一个，互不影响"
    printf '  留空 = 该族回退到共用域名 / 回落域名 / IP；输入 - 表示清掉已存的值\n'
    a4="$(ask_client_domain "v4 节点域名" "$d4")"
    a6="$(ask_client_domain "v6 节点域名" "$d6")"
    # 回车沿用默认（该族此前未设专属、默认值来自共用域名）时**不**把共用域名
    # 物化进分族键 —— 物化会让之后改 --client-domain 无法传播到该族，
    # 也与上方「留空 = 该族回退到共用域名」的说明自相矛盾。
    if [[ -z $old4 && $a4 == "${CLIENT_DOMAIN:-}" ]]; then CLIENT_DOMAIN_V4=""; else CLIENT_DOMAIN_V4="$a4"; fi
    if [[ -z $old6 && $a6 == "${CLIENT_DOMAIN:-}" ]]; then CLIENT_DOMAIN_V6=""; else CLIENT_DOMAIN_V6="$a6"; fi
    if [[ -z $a4 && -z $a6 ]]; then
        # 两族都清空：共用域名一并清掉，避免「看着分开了、实际又回退到同一个域名」。
        CLIENT_DOMAIN=""
        CLIENT_DOMAIN_FORCE_IP="$old_force"
    else
        CLIENT_DOMAIN_FORCE_IP=0   # 给了域名就不能再被 --no-client-domain 的旧值压成 IP
    fi
    save_state
    if [[ -n $a4 && -n $a6 ]]; then
        info "客户端域名已按族分开：v4 ${a4} / v6 ${a6}"
    elif [[ -n $a4 ]]; then
        info "客户端域名：v4 ${a4}；v6 未设专属域名（回退共用域名 / 回落域名 / IP）"
    elif [[ -n $a6 ]]; then
        info "客户端域名：v6 ${a6}；v4 未设专属域名（回退共用域名 / 回落域名 / IP）"
    else
        warn "两族都未设域名：server 将回退到回落域名（若已设）或本机 IP"
    fi
    return 0
}
rerun_choice_needed() { # 本次是否会触及凭据 / config.json（模块 6 或 8）
    has_existing_deployment || return 1
    [[ ${MOD_ON[5]:-0} -eq 1 || ${MOD_ON[7]:-0} -eq 1 ]] || return 1
    return 0
}
warn_rerun_params_ignored() { # keep 下 CLI 新参数不会写进配置，必须讲清楚
    [[ ${RERUN_MODE:-} == keep ]] || return 0
    local k _ign=""
    # 端口三件套 / HOP_RANGE / DOMAIN 组 / 域名组 / UUID 已被 keep 恢复链真正打回
    # （见 restore_server_params_for_keep / restore_client_domain_for_keep /
    #   restore_credentials_for_keep），这里的「忽略」名单必须与恢复链严格一致。
    for k in IP_LIST UP_MBPS DOWN_MBPS \
             SB_UP_MBPS SB_DOWN_MBPS CERT_CN \
             DOMAIN REALITY_SNI REALITY_DEST REALITY_DEST_PORT \
             TCP_KEEP_ALIVE TCP_KEEP_ALIVE_INTERVAL HOP_INTERVAL HOP_INTERVAL_MAX \
             CLIENT_DOMAIN CLIENT_DOMAIN_V4 CLIENT_DOMAIN_V6 CLIENT_DOMAIN_FORCE_IP; do
        [[ -n ${CLI_SET[$k]:-} ]] && _ign+=" ${k}"
    done
    # NAT 组没有恢复链：keep 下仍会实时生效（模块 3 按新映射下发防火墙规则）并落盘，
    # 绝不能混进上面「不会写入」的名单 —— 否则告警与实际行为相反。
    # 注意两条告警相互独立：只带 NAT 参数（_ign 为空）时也要能看到本警示。
    local _nat_live=""
    for k in NAT_MODE NAT_PORTS NAT_MAP NAT_V4_OPEN NAT_V6_OPEN \
             NAT_V6_PORTS NAT_V6_MAP NAT_V4_SERVICES NAT_V6_SERVICES; do
        [[ -n ${CLI_SET[$k]:-} ]] && _nat_live+=" ${k}"
    done
    if [[ -n $_ign ]]; then
        warn "本次命令行指定了会影响 config.json / 客户端 outbounds 的参数（${_ign# }），但选择了「沿用旧配置」：这些参数不会写入配置文件"
        warn "若要让新参数生效，请改用「生成新配置」（--new-config）"
    fi
    if [[ -n $_nat_live ]]; then
        warn "注意：NAT 参数（${_nat_live# }）在「沿用旧配置」下仍会实时生效（模块 3 防火墙按新映射下发）并写入状态文件；要让部署按旧参数原样保留，请不要在 keep 时携带 NAT 参数，或改用 --new-config"
    fi
    [[ -n $_ign || -n $_nat_live ]] || return 0
}
warn_incomplete_credentials() { # keep 下若状态文件残缺，明确告知而不是静默跳过
    [[ ${RERUN_MODE:-} == keep ]] || return 0
    [[ -z ${UUID:-} || -z ${REALITY_PRIV:-} ]] || return 0
    warn "状态文件里的凭据不完整（UUID / Reality 私钥为空）：本次仍按「沿用旧配置」处理，未改动任何文件"
    warn "如需重建一套完整配置与凭据，请显式选「生成新配置」（--new-config）"
}
warn_new_without_mod6() { # 选了 new 却没选模块 6：只重渲染配置，凭据不会轮换，须讲清楚
    [[ ${RERUN_MODE:-} == new ]] || return 0
    [[ ${MOD_ON[5]:-0} -eq 1 ]] && return 0
    warn "本次选择了「生成新配置」但未包含模块 6：只会重新渲染 config.json，凭据不会轮换"
    warn "需要一整套全新密码/密钥时，请加 --modules 6,8,9 或直接全量重跑"
}
print_rerun_choice() {
    hr
    printf '  %s检测到已有部署，请选择本次重跑方式（必须二选一）：%s\n' "$C_B" "$C_N"
    hr
    printf '   %s1) 沿用旧配置%s  —— 完整保留现有 config.json、UUID、Reality 密钥、各密码、\n' "$C_G" "$C_N"
    printf '                        Hysteria2 自签证书与交付文件：不覆盖、不改动、不重启服务；\n'
    printf '                        已下发的客户端配置与分享链接继续可用\n'
    printf '   %s2) 生成新配置%s  —— 每次都重新生成一整套新的 UUID、Reality 密钥、short_id、\n' "$C_Y" "$C_N"
    printf '                        各密码、自签证书与 pinSHA256，并更新 config.json 与交付文件；\n'
    printf '                        不复用固定值或上次生成结果；旧客户端配置与分享链接全部作废\n'
    hr
}
choose_rerun_mode() {
    RERUN_IS_FIRST=0
    validate_rerun_mode "${RERUN_MODE:-}" \
        || die "重跑方式非法：只能是 keep（沿用旧配置）或 new（生成新配置），收到: ${RERUN_MODE}"

    # 首次部署：没有旧配置可沿用
    if ! has_existing_deployment; then
        RERUN_IS_FIRST=1
        [[ $RERUN_MODE != keep ]] || warn "首次部署尚无旧配置可沿用，已自动按「生成新配置」处理"
        RERUN_MODE=new
        return 0
    fi

    # 已通过命令行 / 环境变量明确选择
    if [[ -n $RERUN_MODE ]]; then
        if [[ $RERUN_MODE == new ]]; then
            info "本次重跑方式：生成新配置 —— 全套密码/密钥重新生成，config.json 与交付文件将更新"
        else
            info "本次重跑方式：沿用旧配置 —— config.json 与全部密码/密钥保持原样，不做任何覆盖"
        fi
        warn_rerun_params_ignored
        return 0
    fi

    # 本次不触及模块 6/8（例如 --modules 7）：没有任何会覆盖配置/凭据的动作
    if ! rerun_choice_needed; then
        RERUN_MODE=keep
        return 0
    fi

    # --yes 非交互：绝不猜测、绝不自动覆盖
    if [[ -n $ASSUME_YES ]]; then
        RERUN_MODE=keep
        warn "重跑未明确选择方式，已按最安全的「沿用旧配置」处理：本次不会覆盖 config.json，也不会重新生成任何密码/密钥"
        warn "需要重新生成全套配置与凭据时，请显式加 --new-config（或 --config-mode new）"
        warn_rerun_params_ignored
        return 0
    fi

    # 交互式二选一：非法输入循环提示；输入结束（EOF）一律退回 keep
    local c=""
    while true; do
        print_rerun_choice
        if ! read -r -p "$(printf '%s[?]%s 请输入 1 或 2 [1]: ' "$C_B" "$C_N")" c; then
            RERUN_MODE=keep
            warn "输入不可用（非交互环境），已按「沿用旧配置」处理：不会覆盖任何文件"
            break
        fi
        case "${c,,}" in
            ""|1|k|keep|沿用旧配置)    RERUN_MODE=keep; break;;
            2|new|regen|生成新配置)  RERUN_MODE=new;  break;;
            *) warn "无效选择「${c}」：请输入 1（沿用旧配置）或 2（生成新配置）";;
        esac
    done
    if [[ $RERUN_MODE == new ]]; then
        info "已选择「生成新配置」：本次将重新生成全套凭据并更新 config.json"
    else
        info "已选择「沿用旧配置」：本次不覆盖 config.json，也不改动任何密码/密钥/证书"
    fi
    warn_rerun_params_ignored
    return 0
}

# ===== 重跑感知（纯只读、纯打印） =====
# 这里在执行前一次性讲清楚本次选了哪种模式、哪些东西会被保留 / 覆盖。
# 选择动作在 choose_rerun_mode() 里完成（--yes 批量调用不打断，按安全的 keep 处理）。
report_rerun() {
    # 交互式向导可能在模块之前创建 state.env（保存分族端口配置），但首次部署时
    # UUID 仍为空，不能因为文件存在就把首次部署误报成「已有部署」。
    [[ ${RERUN_IS_FIRST:-0} -eq 0 && -f $STATE_FILE ]] || return 0
    hr
    if [[ ${RERUN_MODE:-} == new ]]; then
        info "检测到已有部署（${STATE_FILE}）—— 本次重跑方式：生成新配置"
    else
        info "检测到已有部署（${STATE_FILE}）—— 本次重跑方式：沿用旧配置（未明确选择时的默认值）"
    fi
    if [[ ${RERUN_MODE:-} == keep ]]; then
        printf '  凭据      : 完整保留现有 UUID（%s…）/ Reality 密钥 / 各密码 / 自签证书\n' "${UUID:0:8}"
        printf '  配置文件  : %s 与交付文件保持原样，不覆盖、不改动、不重启服务\n' "$SB_CONF"
        printf '  已下发客户端继续可用；想换一套全新凭据请显式加 --new-config\n'
    elif [[ ${MOD_ON[5]:-0} -eq 1 ]]; then
        printf '  凭据      : 本次重新生成 UUID / Reality 密钥 / short_id / 各密码 / 自签证书（不复用上次结果）\n'
        printf '  ! 重要    : 旧客户端配置与分享链接全部失效，请重新导入 /root/vps-init.info 与 client-outbounds.json\n'
    else
        printf '  凭据      : 本次不含模块 6，沿用现有凭据（UUID %s…）；要换凭据请加 --modules 6\n' "${UUID:0:8}"
    fi
    if [[ ${REALITY_DEST:-} == "127.0.0.1" ]]; then
        printf '  Reality   : 本地回落  %s:%s\n' "${DOMAIN:-<未设域名>}" "$FALLBACK_PORT"
    else
        printf '  Reality   : 公共站点  %s:%s\n' \
            "${REALITY_DEST:-$REALITY_PUBLIC_DEST_DEFAULT}" \
            "${REALITY_DEST_PORT:-$REALITY_PUBLIC_PORT_DEFAULT}"
    fi
    printf '  端口      : SSH %s / vless %s / hy2 %s\n' "$SSH_PORT" "$VLESS_PORT" "$HY2_PORT"
    if [[ ${RERUN_MODE:-} == keep ]]; then
        printf '  sing-box  : %s、vps-init.info、client-outbounds.json 本次不改写\n' "$SB_CONF"
        printf '  其它模块  : Caddyfile / 伪装站 index.html 等仍按所选模块正常维护\n'
    else
        printf '  将被覆盖  : %s、Caddyfile、伪装站 index.html、vps-init.info、client-outbounds.json（仅限本次所选模块）\n' "$SB_CONF"
        printf '  配置文件覆盖前会留备份；要改某项请用对应 CLI 参数，或编辑 %s\n' "$STATE_FILE"
    fi
    local sel="" i
    for i in "${!MOD_ON[@]}"; do
        [[ ${MOD_ON[$i]} -eq 1 ]] && sel+=" $((i+1))"
    done
    printf '  本次模块  : %s\n' "${sel# }"

    # 备份会随每次重跑累积，这里只提示、绝不自动删除任何文件
    local n=0 f
    for f in /root/.vps-init.config.json.*.bak; do
        [[ -f $f ]] && n=$((n+1))
    done
    if (( n > 5 )); then
        warn "配置备份已有 ${n} 份，占空间时可自行清理：ls -t /root/.vps-init.config.json.*.bak | tail -n +6 | xargs -r rm --"
    fi
    hr
    return 0
}

# ===== §9 环境校验 =====
preflight() {
    [[ $EUID -eq 0 ]] || die "请以 root 身份运行（sudo -i 后执行）"
    command -v systemctl >/dev/null || die "未检测到 systemd，本脚本仅支持 Debian 12/13 + systemd"
    [[ -r /etc/os-release ]] || die "无法识别系统版本"
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian) [[ "${VERSION_ID:-}" =~ ^(12|13) ]] || warn "当前为 Debian ${VERSION_ID:-未知}，脚本按 Debian 12/13 编写，继续请自担风险";;
        *) warn "当前系统为 ${ID:-未知}，脚本按 Debian 12/13 编写，继续请自担风险";;
    esac
}

# ===== §10 模块注册表与菜单 =====
MOD_NAMES=(
    "系统基线（更新/时区/NTP/工具）"
    "SSH 加固（改端口+密钥登录）"
    "防火墙（iptables/ip6tables 持久化）"
    "fail2ban 防爆破"
    "TCP 调优（仅安装 tcpfit，调优手动执行）"
    "sing-box 安装 + 密钥与证书"
    "Reality 回落站（Caddy + 证书）"
    "生成 sing-box 配置并启动"
    "交付汇总（参数/链接/存档）"
)
MOD_FUNCS=(m_base m_ssh m_firewall m_fail2ban m_tcp m_singbox m_reality m_genconfig m_summary)
MOD_ON=(1 1 1 1 1 1 1 1 1)
# 「只做管理、不跑代理」时允许执行的模块（1 = 允许）：
#   模块 1 系统基线 / 2 SSH 加固 / 4 fail2ban 属于管理通道，保留；
#   模块 3 防火墙（含代理端口放行、跳跃 DNAT、INPUT DROP）/ 5 tcpfit /
#   6 sing-box 安装与凭据 / 7 Reality 回落站 / 8 生成配置 / 9 交付汇总
#   （内含明文凭据）全部不下发 —— 用户选「不开启端口转发映射」时就是要这些彻底取消。
MANAGE_ONLY_ALLOW=(1 1 0 1 0 0 0 0 0)
MANAGE_ONLY_DROPPED=0
# 注意：绝不能用 "$(apply_manage_only_modules)" 取值 —— 命令替换会开子 shell，
# 对 MOD_ON 的修改传不回主流程，结果是「日志说取消了 6 个模块、实际 9 个照跑」。
# 计数走全局变量返回，函数本体在当前 shell 里直接改数组。
apply_manage_only_modules() {
    local i
    MANAGE_ONLY_DROPPED=0
    for i in "${!MOD_ON[@]}"; do
        if [[ ${MOD_ON[$i]} -eq 1 && ${MANAGE_ONLY_ALLOW[$i]} -eq 0 ]]; then
            MANAGE_ONLY_DROPPED=$((MANAGE_ONLY_DROPPED+1))
        fi
        MOD_ON[$i]=$(( MOD_ON[$i] & MANAGE_ONLY_ALLOW[$i] ))
    done
    return 0
}

draw_menu() {
    hr
    printf '  %sVPS 开荒一键配置%s  —— 输入数字切换，a 全选，n 全不选，r 执行，q 退出\n' "$C_B" "$C_N"
    hr
    local i
    for i in "${!MOD_NAMES[@]}"; do
        local mark=" "
        [[ ${MOD_ON[$i]} -eq 1 ]] && mark="x"
        printf '  [%s] %d. %s\n' "$mark" "$((i+1))" "${MOD_NAMES[$i]}"
    done
    hr
}
menu_select() {
    local c
    while true; do
        draw_menu
        read -r -p "选择: " c || { echo; warn "输入结束（非交互环境），退出。非交互请用 --yes 或 --modules"; exit 0; }
        case "$c" in
            [1-9]) local i=$((c-1)); MOD_ON[$i]=$((1-MOD_ON[$i]));;
            a|A) MOD_ON=(1 1 1 1 1 1 1 1 1);;
            n|N) MOD_ON=(0 0 0 0 0 0 0 0 0);;
            r|R) break;;
            q|Q) exit 0;;
            *) warn "无效输入";;
        esac
    done
}

# ============================================================
# 1. 系统基线
# ============================================================
m_base() {
    info "==> [1] 系统基线"
    TZ_NAME="$(ask "时区（Asia/Shanghai 或 Etc/UTC）" "$TZ_NAME")"
    # 非法时区会让 timedatectl 失败，set -e 下整个脚本第一步就中止（后面全没跑）。
    # 校验 zoneinfo 实体文件，非法值回退 UTC 并明确告知。
    if [[ -z ${TZ_NAME:-} || $TZ_NAME == *..* || ! -e "/usr/share/zoneinfo/${TZ_NAME}" ]]; then
        warn "时区「${TZ_NAME:-空}」不存在，已回退 Etc/UTC（查看可用值：timedatectl list-timezones）"
        TZ_NAME="Etc/UTC"
    fi
    run timedatectl set-timezone "$TZ_NAME" \
        || warn "时区设置失败（容器常见），当前仍为 $(timedatectl show -p Timezone --value 2>/dev/null || echo 未知)"

    apt_update
    info "升级系统软件包（耗时较长，请耐心等待）"
    # 失败时不能只留一行 ERR 陷阱：apt 的真实报错才是排查依据（磁盘不足/源不可达/dpkg 中断）
    # confdef/confold：dpkg 的 conffile 提示不走 debconf，非 TTY（管道喂入）时会挂起或按失败处理；
    # 保持旧配置最安全 —— sshd_config 等正是本脚本会改的文件
    # mktemp：/tmp 是世界可写目录，$$ 可预测的固定名可被并发用户抢注（symlink 攻击面）。
    # 模板固定用 POSIX /tmp（不用 TMPDIR）：Debian 上目标位置不变；
    # 若从 Windows/MSYS 环境跑回归，TMPDIR 里的盘符路径会让后续 rm 触发沙箱拒绝。
    local up_log; up_log="$(mktemp "/tmp/.vps-init.upgrade.XXXXXX.log")"
    if ! DEBIAN_FRONTEND=noninteractive apt-get -y upgrade \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold >"$up_log" 2>&1; then
        tail -n 30 "$up_log" >&2
        die "系统升级失败（完整日志：${up_log}）"
    fi
    rm -f "$up_log"
    ok "系统软件包已升级"
    apt_install curl wget ca-certificates gnupg vim git unzip cron sudo qrencode jq
    ok "基础工具已安装"

    # --- 时间同步：容器/LXC/OpenVZ 下 timedatectl 可能报 "NTP not supported" ---
    # 这属于环境限制而非失败，脚本必须继续跑完，否则后续所有模块都做不了。
    # 三级降级：timesyncd → 重启 timesyncd → cron + ntpdate。
    _sync_note=""
    _ntp_ok=0
    apt_wait_lock   # 裸 apt-get 也要等锁：开机 unattended-upgrades 占锁会被误判成"不支持 NTP"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-timesyncd >/dev/null 2>&1; then
        systemctl unmask systemd-timesyncd.service >/dev/null 2>&1 || true
        systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true
        # 注意：容器里 set-ntp 有时必须先 restart 才生效，因此两轮都试
        for _try in 1 2; do
            if timedatectl set-ntp true >/dev/null 2>&1; then _ntp_ok=1; break; fi
            systemctl restart systemd-timesyncd.service >/dev/null 2>&1 || true
        done
    fi

    if [[ $_ntp_ok -eq 1 ]]; then
        ok "时间同步已开启：$(timedatectl 2>/dev/null | grep -m1 'Time zone' | xargs || true)"
    else
        warn "本机不支持内核 NTP（timedatectl: NTP not supported，常见于容器/LXC），改用 cron + ntpdate"
        apt_wait_lock
        if DEBIAN_FRONTEND=noninteractive apt-get install -y ntpdate >/dev/null 2>&1; then
            if ntpdate -s -b pool.ntp.org >/dev/null 2>&1 \
               || ntpdate -s -b time.cloudflare.com >/dev/null 2>&1 \
               || ntpdate -s -b ntp.aliyun.com >/dev/null 2>&1; then
                ok "已完成一次性校时"
            else
                _sync_note="一次性校时失败（可能无外网 DNS），当前时间可能存在偏差"
                warn "$_sync_note"
            fi
            # 每日校时，防止长期漂移
            cat >/etc/cron.daily/vps-init-ntpdate <<'NTPJOB'
#!/bin/sh
/usr/sbin/ntpdate -s -b pool.ntp.org >/dev/null 2>&1 || \
/usr/sbin/ntpdate -s -b time.cloudflare.com >/dev/null 2>&1 || \
/usr/sbin/ntpdate -s -b ntp.aliyun.com >/dev/null 2>&1
NTPJOB
            chmod 0755 /etc/cron.daily/vps-init-ntpdate
            ok "已安装每日校时任务：/etc/cron.daily/vps-init-ntpdate"
        else
            warn "ntpdate 安装也失败，跳过时间同步（不影响后续配置，但日志时间可能不准）"
        fi
        ok "当前时区：$(timedatectl 2>/dev/null | grep -m1 'Time zone' | xargs || date +%Z)"
    fi
    unset _try

    # 低内存机器补 swap。判据用「swap 已激活」而不是「文件存在」：进程被杀（SSH
    # 掉线 / Ctrl-C）可能留下 /swapfile 已创建但未 swapon 的半成品，按文件判断
    # 会让重跑永远跳过创建，内存不足的状态被永久固化。
    local mem_mb; mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [[ $mem_mb -lt 900 ]] \
       && ! { swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; }; then
        if ask_yn "内存仅 ${mem_mb}MB，是否创建 1G swap？" y; then
            if fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
                grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
                ok "swap 已启用"
            else
                # 失败要收尾：否则残留未启用的 /swapfile（占 1G），且下次重跑会因
                # [[ ! -f /swapfile ]] 判假而永远跳过创建，卡在「文件在、未启用」的半成品状态
                rm -f /swapfile
                warn "swap 创建失败，已清理残留的 /swapfile（不影响后续模块）"
            fi
        fi
    fi

    # ssh/scp 期间别让日志炸：限制 journal
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-vps-init.conf <<'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=7day
EOF
    systemctl restart systemd-journald 2>/dev/null \
        || warn "journald 重启失败（容器环境常见），日志限制可能未生效"
    ok "系统基线完成"
}

# ============================================================
# 2. SSH 加固
# ============================================================
m_ssh() {
    info "==> [2] SSH 加固"
    # NAT 机的 SSH 外部端口由服务商面板固定映射。把 sshd 改成脚本默认的 51736，
    # 而面板没有转发 51736 时，用户会被永久锁在机器外面 —— 这是本适配最危险的一点。
    # 因此：NAT 生效且用户没有显式 --ssh-port 时，保持当前 sshd 端口不改动。
    if [[ ${NAT_ACTIVE:-0} -eq 1 && -z ${CLI_SET[SSH_PORT]:-} ]]; then
        local cur; cur="$(current_ssh_port)"
        if [[ -n $cur && $cur != "$SSH_PORT" ]]; then
            warn "NAT 机型：保持现有 SSH 端口 ${cur} 不改动（改成未映射的 ${SSH_PORT} 会锁死登录）"
            SSH_PORT="$cur"
        fi
    fi
    SSH_PORT="$(ask "SSH 端口" "$SSH_PORT")"
    # 用统一的 is_port：交互输入与状态文件都可能带进前导零（0443），
    # 而 bash 算术会把 0443 当八进制 291 —— 校验与实际写进 sshd 的值就对不上了。
    is_port "$SSH_PORT" || die "SSH 端口非法（1-65535 的十进制数字，不接受前导零）: $SSH_PORT"
    # NAT 机上改端口是第二处高危点：外部端口没在服务商面板转发时，改完 sshd 就锁死登录。
    # 上面的防护只覆盖「未显式指定端口」的情形，这里对交互输入的新端口补一道确认；
    # 非 TTY（--yes）下 ask_yn 走默认 n，自动回退现有端口，绝不盲改。
    if [[ ${NAT_ACTIVE:-0} -eq 1 ]]; then
        local cur_port; cur_port="$(current_ssh_port)"
        if [[ -n $cur_port && $cur_port != "$SSH_PORT" ]]; then
            warn "NAT 机型：改用端口 ${SSH_PORT} 前必须先在服务商面板把外部端口转发到 ${SSH_PORT}，否则会锁死登录"
            if ! ask_yn "确认面板已完成转发，继续改端口？" n; then
                SSH_PORT="$cur_port"
                warn "已保持现有端口 ${cur_port}"
            fi
        fi
    fi

    # --- 公钥来源 ---
    if [[ -z $PUBKEY && -n $PUBKEY_FILE ]]; then
        [[ -r $PUBKEY_FILE ]] || die "公钥文件不可读：$PUBKEY_FILE"
        PUBKEY="$(cat "$PUBKEY_FILE")"
    fi
    if [[ -z $PUBKEY && -n $PUBKEY_URL ]]; then PUBKEY="$(fetch_stdout "$PUBKEY_URL" || true)"; fi
    # 统一去掉 CR：在 Windows 上导出的公钥文件是 CRLF，read 会保留行尾的 \r，
    # 结果既会写进 authorized_keys（行尾多一个控制字符），又会让下面的 grep -qxF 去重失效
    PUBKEY="${PUBKEY//$'\r'/}"
    if [[ -z $PUBKEY && -s /root/.ssh/authorized_keys ]]; then
        warn "检测到已存在 /root/.ssh/authorized_keys："
        grep -v '^\s*$' /root/.ssh/authorized_keys | sed 's/^/      /' >&2
    fi
    if [[ -z $PUBKEY ]]; then
        if [[ -n $ASSUME_YES ]]; then
            warn "未提供公钥，将只改端口，不关闭密码登录"
        else
            warn "未检测到公钥。直接关闭密码登录会导致无法登录！"
            read -r -p "请粘贴公钥（或直接回车跳过，保持密码登录）: " PUBKEY || true
        fi
    fi

    if [[ -n $PUBKEY ]]; then
        # 格式校验，避免把私钥或整段文本写进 authorized_keys 导致锁死
        if ! printf '%s\n' "$PUBKEY" | grep -qE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256))[[:space:]]+[A-Za-z0-9+/=]+'; then
            err "公钥格式无法识别（应以 ssh-rsa / ssh-ed25519 / ecdsa-sha2-* / sk-* 开头）"
            die "为避免锁死，已中止。请确认后用 --pubkey-file 重新执行"
        fi
    fi

    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    if [[ -n $PUBKEY ]]; then
        touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
        local line
        while IFS= read -r line; do
            [[ -z ${line// /} ]] && continue
            grep -qxF "$line" /root/.ssh/authorized_keys 2>/dev/null || printf '%s\n' "$line" >> /root/.ssh/authorized_keys
        done <<< "$PUBKEY"
        ok "公钥已写入 /root/.ssh/authorized_keys"
    fi

    # --- sshd 配置 ---
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    cp -a /etc/ssh/sshd_config "/root/.vps-init.sshd_config.${ts}.bak"
    rotate_old_baks '/root/.vps-init.sshd_config.*.bak'
    grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
        || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    mkdir -p /etc/ssh/sshd_config.d

    # 已有可用公钥（新传入或机器上原本就有）才关闭密码登录
    local has_key=0
    [[ -n $PUBKEY ]] && has_key=1
    if [[ $has_key -eq 0 && -s /root/.ssh/authorized_keys ]] \
        && grep -qE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-|sk-)' /root/.ssh/authorized_keys; then
        has_key=1
    fi
    local pw_auth="yes"          # PasswordAuthentication 取值
    # PermitRootLogin 必须与 PasswordAuthentication 同源：prohibit-password 本身
    # 就禁止 root 用密码登录，而绝大多数 VPS 只有 root 账号 —— 无公钥时若仍写它，
    # 「只改端口、保留密码登录」的承诺就是假的，重连即被拒（锁死登录）。
    local root_login="yes"
    if [[ $has_key -eq 1 ]]; then pw_auth="no"; root_login="prohibit-password"; fi

    cat > /etc/ssh/sshd_config.d/00-vps-init.conf <<EOF
# 由 vps-init.sh 生成 $(date -Is)
Port ${SSH_PORT}
PubkeyAuthentication yes
PermitRootLogin ${root_login}
PermitEmptyPasswords no
PasswordAuthentication ${pw_auth}
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF

    # 注释主配置中的冲突项（sshd 以首次出现为准，Include 在最前故 drop-in 生效）
    # 只匹配"未被注释"的行：重复执行本脚本不会叠加 # ，也不会把已有的 # vps-init 标记再包一层
    local k
    for k in Port PasswordAuthentication PermitRootLogin PubkeyAuthentication \
             KbdInteractiveAuthentication PermitEmptyPasswords ChallengeResponseAuthentication; do
        sed -i -E "s|^([[:space:]]*${k}[[:space:]].*)$|# \\1  # vps-init|" /etc/ssh/sshd_config
    done

    # 校验失败必须连同 drop-in 一起回滚，否则主配置恢复后 Include 仍会载入错误项
    if ! sshd -t; then
        cp -a "/root/.vps-init.sshd_config.${ts}.bak" /etc/ssh/sshd_config
        rm -f /etc/ssh/sshd_config.d/00-vps-init.conf
        die "sshd 配置校验失败，已回滚主配置与 drop-in"
    fi

    # socket 激活场景（Ubuntu/Debian 新装）需同步端口。
    # 不用 grep -q：list-unit-files 输出较大时 grep 提前退出会让上游吃 SIGPIPE（141），
    # pipefail 下整条管道非零 —— 明明存在 ssh.socket 却被判成不存在
    if systemctl list-unit-files 2>/dev/null | grep '^ssh\.socket' >/dev/null; then
        if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
            mkdir -p /etc/systemd/system/ssh.socket.d
            cat > /etc/systemd/system/ssh.socket.d/10-port.conf <<EOF
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
EOF
            systemctl daemon-reload
        fi
    fi

    # 先放行新端口，避免锁死。NAT 机的 v4 / v6 外部 SSH 端口可能不同：
    # 只放行内部 SSH_PORT 时，若面板是「同号转发」，外部端口仍会被 INPUT DROP 挡掉。
    if command -v iptables >/dev/null; then
        local fam fw p
        for fam in 4 6; do
            if [[ $fam == 4 ]]; then fw=iptables
            else command -v ip6tables >/dev/null || continue; fw=ip6tables; fi
            while read -r p; do
                [[ -n $p ]] || continue
                "$fw" -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
                    || "$fw" -I INPUT 1 -p tcp --dport "$p" -j ACCEPT || true
            done < <(ssh_ports_for_family "$fam")
        done
        # 新端口规则必须落盘：若本机此前持久化过 INPUT DROP，而这次新增的放行没存下来，
        # 重启后就是「DROP + 只有旧端口」，直接锁死。失败必须明确告警，不能 || true 吞掉。
        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save >/dev/null 2>&1 \
                || warn "新 SSH 端口规则未持久化：重启后可能无法登录，请立即执行 netfilter-persistent save"
        fi
    fi

    # socket 激活与 service 两种场景分别重启。restart 是「先停后启」：
    # sshd -t 只验语法不验绑定，新端口被占用时旧 sshd 已停、新的起不来 ——
    # 这是最危险的锁死路径，必须回滚配置并按原端口拉起，不能只报错。
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket
    else
        systemctl restart ssh 2>/dev/null || systemctl restart sshd
    fi
    sleep 1
    if ! { systemctl is-active --quiet ssh || systemctl is-active --quiet sshd \
        || systemctl is-active --quiet ssh.socket; }; then
        # 回滚：恢复主配置、删除 drop-in 与 socket 端口覆盖，再尝试按原配置重启
        cp -a "/root/.vps-init.sshd_config.${ts}.bak" /etc/ssh/sshd_config 2>/dev/null || true
        rm -f /etc/ssh/sshd_config.d/00-vps-init.conf
        rm -f /etc/systemd/system/ssh.socket.d/10-port.conf
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        die "SSH 服务未正常运行（常见原因：新端口被占用），已回滚 sshd 配置并尝试按原端口重启；请保留当前连接，另行验证登录后排查"
    fi

    # 端口监听自检：不用 `ss | grep -q`——grep 命中即退出会让 ss 吃 SIGPIPE(141)，
    # pipefail 下整条管道非零，明明在监听却报「未发现监听」。
    if command -v ss >/dev/null; then
        if ss -tlnp 2>/dev/null | grep ":${SSH_PORT}[[:space:]]" >/dev/null; then
            ok "端口 ${SSH_PORT} 已监听"
        else
            warn "未在 ${SSH_PORT} 上发现监听，请立即检查：ss -tlnp"
        fi
    fi

    local pw_state="已关闭"; [[ $pw_auth == yes ]] && pw_state="保留开启（未检测到可用公钥）"
    ok "SSH 已切换至端口 ${SSH_PORT}，密码登录：${pw_state}"
    warn "请保留当前窗口，另开终端验证 SSH 登录后再断开：v4 用端口 $(ssh_port_for_family 4) / v6 用端口 $(ssh_port_for_family 6)（sshd 内部监听 ${SSH_PORT}）"
    save_state
}

# ============================================================
# 3. 防火墙
# ============================================================
# 说明：添加失败只告警不中断（容器/精简内核常缺模块），DROP 前会单独校验关键规则
ipt_add() { # ipt_add <iptables-cmd> <args...>  幂等追加
    local cmd="$1"; shift
    "$cmd" -C "$@" 2>/dev/null && return 0
    if "$cmd" -A "$@" 2>/dev/null; then return 0; fi
    warn "规则添加失败（已跳过）: $cmd $*"
    return 0
}
ipt_head() { # ipt_head <iptables-cmd> <链> <args...>  幂等插到链首
    local cmd="$1" chain="$2"; shift 2
    "$cmd" -C "$chain" "$@" 2>/dev/null && return 0
    if "$cmd" -I "$chain" 1 "$@" 2>/dev/null; then return 0; fi
    warn "规则插入失败（已跳过）: $cmd -I $chain $*"
    return 0
}
ipt_add_nat() { # nat 表专用：失败返回 1（IPv6 NAT 常被裁剪，交由调用方降级）
    local cmd="$1"; shift
    if "$cmd" -t nat -C "$@" 2>/dev/null; then return 0; fi
    "$cmd" -t nat -A "$@" 2>/dev/null || return 1
}
m_firewall() {
    info "==> [3] 防火墙"
    # 规则里的端口/跳跃范围直接来自这些变量，先复查一遍再下发
    validate_settings
    apt_update
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    apt_install iptables-persistent

    local ts; ts=$(date +%Y%m%d-%H%M%S)
    # 备份是用户被误封后唯一的逃生通道，必须知道它到底存不存在，
    # 否则最后那句"备份：xxx"会把用户指向一个不存在的文件。
    local bak4=0 bak6=0
    iptables-save  > "/root/.vps-init.iptables.${ts}.bak"  2>/dev/null && bak4=1 || true
    rotate_old_baks '/root/.vps-init.iptables.*.bak'
    ip6tables-save > "/root/.vps-init.ip6tables.${ts}.bak" 2>/dev/null && bak6=1 || true
    rotate_old_baks '/root/.vps-init.ip6tables.*.bak'

    local v4="iptables" v6="ip6tables"
    command -v ip6tables >/dev/null || v6=""
    [[ -n $v6 ]] && ip6tables -L -n >/dev/null 2>&1 || v6=""   # 内核未启用 IPv6 时跳过

    local fw
    for fw in $v4 $v6; do
        ipt_head "$fw" INPUT -i lo -j ACCEPT
        # 优先 conntrack，老内核回退到 state
        if ! "$fw" -C INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
            ipt_head "$fw" INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
            "$fw" -C INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
                || ipt_head "$fw" INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
        fi
        # SSH 端口按族放行：内部端口 + 该受限族声明的外部映射端口。
        local fam p proxy_ok=1
        if [[ $fw == "iptables" ]]; then fam=4; else fam=6; fi
        family_runs_proxy "$fam" || proxy_ok=0
        while read -r p; do
            [[ -n $p ]] || continue
            # SSH 放行必须插到链首：若镜像自带终止性规则（如 -A INPUT -j DROP），
            # 追加到链尾的 ACCEPT 会被遮蔽 —— 后面的 -C 校验只看"规则存在"，
            # 挡不住"存在但不可达"，置 DROP 后就是锁死登录。
            ipt_head "$fw" INPUT -p tcp --dport "$p" -j ACCEPT
        done < <(ssh_ports_for_family "$fam")
        # 「只做管理」的族不下发任何代理端口：之前 v4 只做 SSH 却仍放行
        # 443 / 8443 / UDP 16407，展示与防火墙互相矛盾。
        if [[ $proxy_ok -eq 1 ]]; then
            ipt_head "$fw" INPUT -p tcp --dport 80 -j ACCEPT
            ipt_head "$fw" INPUT -p tcp --dport "$VLESS_PORT" -j ACCEPT
            ipt_head "$fw" INPUT -p tcp --dport "$FALLBACK_PORT" -j ACCEPT
            ipt_head "$fw" INPUT -p udp --dport "$HY2_PORT" -j ACCEPT
        fi
        # 跳跃段只下发给「端口全开放」的那一族：受限族既没转发整段 UDP，也没必要放行。
        local hop_fw=1
        if [[ ${NAT_ACTIVE:-0} -eq 1 ]]; then
            if [[ $fw == "iptables"  && ${NAT_V4_OPEN:-0} -eq 0 ]]; then hop_fw=0; fi
            if [[ $fw == "ip6tables" && ${NAT_V6_OPEN:-0} -eq 0 ]]; then hop_fw=0; fi
        fi
        # 历史跳跃规则清扫：换范围 / --no-hop / 族由全开放转受限后，旧的整段放行
        # 与 DNAT 不会自动消失（ipt_add 的 -C 按完整参数匹配，换参数只会追加新规则），
        # 残留规则会继续把 UDP 段转发到已无人监听的端口 —— 必须在追加新规则前删掉。
        local _hop_keep=0 _hop_line _hop_r _hop_d _hop_cleaned=""
        [[ -n ${HOP_RANGE:-} && $hop_fw -eq 1 && $proxy_ok -eq 1 ]] && _hop_keep=1
        while IFS= read -r _hop_line; do
            [[ $_hop_line == *'--dport '*'-j ACCEPT' ]] || continue
            _hop_r="${_hop_line#*--dport }"; _hop_r="${_hop_r%% -j*}"
            [[ $_hop_r == *:* ]] || continue
            if [[ $_hop_keep -eq 1 && $_hop_r == "$HOP_RANGE" ]]; then continue; fi
            ipt_un "$fw" INPUT -p udp --dport "$_hop_r" -j ACCEPT
            _hop_cleaned+=" INPUT/${_hop_r}"
        done < <("$fw" -S INPUT 2>/dev/null | grep -E -- '--dport [0-9]+:[0-9]+ .*-j ACCEPT' || true)
        while IFS= read -r _hop_line; do
            [[ $_hop_line == *'--dport '*'-j DNAT'* ]] || continue
            _hop_r="${_hop_line#*--dport }"; _hop_r="${_hop_r%% *}"
            _hop_d="${_hop_line#*--to-destination :}"; _hop_d="${_hop_d%% *}"
            [[ $_hop_r == *:* && -n $_hop_d ]] || continue
            if [[ $_hop_keep -eq 1 && $_hop_r == "$HOP_RANGE" && $_hop_d == "$HY2_PORT" ]]; then continue; fi
            ipt_un "$fw" -t nat PREROUTING -p udp --dport "$_hop_r" -j DNAT --to-destination ":$_hop_d"
            _hop_cleaned+=" DNAT/${_hop_r}→:${_hop_d}"
        done < <("$fw" -t nat -S PREROUTING 2>/dev/null | grep -E -- '--dport [0-9]+:[0-9]+ .*-j DNAT' || true)
        # 删除必须留痕：同形规则也可能是用户自建的转发（比如手动给某个 UDP 段做过 DNAT），
        # 静默删掉会让用户排查无门 —— 告警里给出确切规则，可手动恢复。
        [[ -z $_hop_cleaned ]] || warn "${fw} 清扫了非当前配置的整段 UDP 跳跃规则:${_hop_cleaned}（若是自行添加的规则，请手动恢复；当前生效范围见交付摘要）"
        # HOP_RANGE 为空（--no-hop）时必须跳过，否则会拼出 "-p udp --dport -j ACCEPT" 的非法规则
        if [[ -n $HOP_RANGE && $hop_fw -eq 1 && $proxy_ok -eq 1 ]]; then
            ipt_head "$fw" INPUT -p udp --dport "$HOP_RANGE" -j ACCEPT
        fi
        if [[ $fw == "iptables" ]]; then
            ipt_head "$fw" INPUT -p icmp -j ACCEPT
        else
            ipt_head "$fw" INPUT -p ipv6-icmp -j ACCEPT
            ipt_head "$fw" INPUT -s fe80::/64 -j ACCEPT
        fi
        # Hysteria2 端口跳跃：UDP 段重定向到监听端口
        # --to-destination 只改端口、保留原始目的 IP，因此多 IP + 按 IP 监听的入站同样适用
        if [[ -n $HOP_RANGE && $hop_fw -eq 1 && $proxy_ok -eq 1 ]]; then
            # 旧目标端口 / 旧范围的 DNAT 已在上方统一清扫（换端口重跑时旧规则
            # 若残留会在 PREROUTING 首条命中，把整段 UDP 转到无人监听的端口）。
            ipt_add_nat "$fw" PREROUTING -p udp --dport "$HOP_RANGE" -j DNAT --to-destination ":${HY2_PORT}" \
                || warn "${fw} 的 nat 表不可用，端口跳跃在该协议族下无效（常见：IPv6 NAT 被裁剪）"
        fi
        # 与 ipt_add 的降级策略保持一致：容器/裁剪内核缺能力时只告警不中断（OUTPUT 链不影响入站防护）
        "$fw" -P OUTPUT ACCEPT 2>/dev/null || warn "${fw} 设置 OUTPUT ACCEPT 失败（容器/裁剪内核常见）"
    done

    # 置 DROP 前逐族校验所有 SSH 放行规则（内部端口 + 外部映射端口）确实存在，
    # 避免把自己关在门外。只查内部端口会漏掉 NAT 外部端口被挡的情形。
    local chk_fam chk_fw chk_p
    for chk_fam in 4 6; do
        if [[ $chk_fam == 4 ]]; then chk_fw=iptables
        else [[ -n $v6 ]] || continue; chk_fw=ip6tables; fi
        while read -r chk_p; do
            [[ -n $chk_p ]] || continue
            "$chk_fw" -C INPUT -p tcp --dport "$chk_p" -j ACCEPT 2>/dev/null \
                || die "SSH 端口 ${chk_p}（v${chk_fam}）放行规则缺失，已中止设置 DROP（当前 INPUT 仍为 ACCEPT）"
        done < <(ssh_ports_for_family "$chk_fam")
        # 代理端口只做告警：ipt_add/ipt_head 在容器/精简内核上可能失败（模块缺失），
        # 那种环境本来也放不下完整规则集；但绝不能"规则没加上还报全部就绪"。
        if family_runs_proxy "$chk_fam"; then
            for chk_p in "$VLESS_PORT" "$FALLBACK_PORT" "$HY2_PORT"; do
                [[ -n $chk_p ]] || continue
                "$chk_fw" -C INPUT -p tcp --dport "$chk_p" -j ACCEPT 2>/dev/null \
                    || "$chk_fw" -C INPUT -p udp --dport "$chk_p" -j ACCEPT 2>/dev/null \
                    || warn "${chk_fw} 缺少端口 ${chk_p} 的放行规则：该端口对外不可达（常见于容器/精简内核）"
            done
        fi
    done

    iptables -P INPUT DROP || warn "IPv4 INPUT DROP 设置失败：当前 INPUT 仍为 ACCEPT（防护未完全生效），请手动执行 iptables -P INPUT DROP"
    if [[ -n $v6 ]]; then
        ip6tables -P INPUT DROP || warn "IPv6 INPUT DROP 设置失败（内核可能未启用 IPv6）"
    fi

    if netfilter-persistent save >/dev/null 2>&1; then
        ok "防火墙规则已应用并持久化（INPUT 默认 DROP）"
    else
        warn "规则已生效但持久化失败，重启后会丢失，请检查 netfilter-persistent"
    fi
    systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    if [[ $bak4 -eq 1 ]]; then
        warn "备份：/root/.vps-init.iptables.${ts}.bak ；误封自救：iptables -P INPUT ACCEPT"
    else
        warn "iptables-save 备份失败（/root 可能不可写）：误封自救请记牢 iptables -P INPUT ACCEPT"
    fi
    [[ $bak6 -eq 1 || -z $v6 ]] || warn "ip6tables-save 备份失败，IPv6 规则回滚需手动处理"
    save_state
}

# ============================================================
# 4. fail2ban
# ============================================================
m_fail2ban() {
    info "==> [4] fail2ban"
    apt_install fail2ban
    mkdir -p /etc/fail2ban
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 2h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd

[recidive]
enabled  = true
bantime  = 7d
findtime = 1d
maxretry = 5
backend  = systemd
EOF
    systemctl enable --now fail2ban >/dev/null 2>&1 \
        || warn "fail2ban 服务启动失败（容器环境常见），如非 systemd 环境请改用宿主机或 docker 的 fail2ban"
    systemctl restart fail2ban 2>/dev/null || true
    sleep 2
    fail2ban-client status sshd >/dev/null 2>&1 && ok "fail2ban 运行中（sshd jail 端口 ${SSH_PORT}）" \
        || warn "fail2ban 已安装但 sshd jail 未就绪，请执行 fail2ban-client status 检查"
    save_state
}

# ============================================================
# 5. TCP 调优
# ============================================================
# 本模块只做一件事：把 tcpfit 装到 /usr/local/bin/tcpfit。
# 调优（BBR/fq/缓冲区/initcwnd/整形）一律由用户自己手动跑 tcpfit 触发 ——
# tcpfit 的 tune 在虚拟网卡上读不到标称带宽会直接中止，而"该给多少带宽、
# 要不要整形"是机主的判断，脚本替用户猜反而容易把线路调坏。
# 因此这里既不问带宽，也不执行 tune/shape，只负责安装并把手动命令打印清楚。
TCPFIT_BIN="/usr/local/bin/tcpfit"
TCPFIT_MAIN_URL="https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh"
m_tcp() {
    info "==> [5] TCP 调优（安装 tcpfit，调优由你手动执行）"

    local src="$CACHE_DIR/tcpfit.sh"
    if ! fetch_file "$src" "$TCPFIT_MAIN_URL"; then
        warn "tcpfit 下载失败，已跳过（可稍后重跑本模块）"
        return 0
    fi

    # fetch_file 只保证「非空」：404 页面 / 运营商劫持页同样非空。
    # 不校验就 cp 会把坏文件装成 /usr/local/bin/tcpfit，还误报「已安装」。
    local head1 ver="" pinned="$CACHE_DIR/tcpfit.pinned.sh"
    head1="$(head -n1 "$src" 2>/dev/null || true)"
    if [[ $head1 != '#!'* ]] || ! bash -n "$src" 2>/dev/null; then
        warn "tcpfit 下载内容不是可执行 shell 脚本（首行：${head1:-空}，或语法错误），已跳过安装；已装版本保持不变"
        return 0
    fi
    # 注意 || true：set -e -o pipefail 下，grep 无匹配（1）或 head 提前退出让 grep 收到
    # SIGPIPE（141），都会让赋值语句本身失败并终止脚本。版本读不到不该中断流程。
    ver="$(grep -oE '^VERSION="[^"]+"' "$src" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)"
    if [[ -z $ver ]]; then
        warn "下载的 tcpfit 里没有 VERSION=，无法确认版本，已跳过安装（不装未校验版本）"
        return 0
    fi

    # 与 tcpfit 自带 self_install 同策略：按版本 tag 回拉并校验 VERSION 一致。
    if fetch_file "$pinned" "https://raw.githubusercontent.com/Kylin010/tcpfit/v${ver}/tcpfit.sh" \
        && grep -q "^VERSION=\"${ver}\"" "$pinned" 2>/dev/null \
        && bash -n "$pinned" 2>/dev/null; then
        src="$pinned"
    else
        warn "未能取到 tcpfit v${ver} 的固定版本或校验失败，将安装 main 分支版本"
        src="$CACHE_DIR/tcpfit.sh"
    fi

    local dest_dir backup=""
    dest_dir="$(dirname "$TCPFIT_BIN")"
    if [[ -f $TCPFIT_BIN ]]; then backup="${TCPFIT_BIN}.vps-init.bak"; fi
    [[ -z $backup ]] || cp -f "$TCPFIT_BIN" "$backup" 2>/dev/null || true
    if ! mkdir -p "$dest_dir" 2>/dev/null || ! cp -f "$src" "$TCPFIT_BIN" 2>/dev/null \
        || ! chmod 755 "$TCPFIT_BIN" 2>/dev/null || ! bash -n "$TCPFIT_BIN" 2>/dev/null; then
        warn "写入或校验 ${TCPFIT_BIN} 失败，已回滚；可手动执行：install -m 755 <下载的脚本> ${TCPFIT_BIN}"
        [[ -n $backup && -f $backup ]] && mv -f "$backup" "$TCPFIT_BIN" 2>/dev/null || true
        return 0
    fi
    [[ -z $backup ]] || rm -f "$backup" 2>/dev/null || true
    ok "tcpfit 已安装：${TCPFIT_BIN}（版本 ${ver}）"

    # 打印的命令必须能直接复制执行：尖括号占位符在 shell 里是重定向，
    # 复制 `tcpfit shape --rate <Mbps>` 会直接语法错误。统一给具体示例数字。
    # SHAPER_RATE 兼容旧写法 1000mbit，但 tcpfit 的 --rate 只收纯整数，这里归一化。
    local bw="${TCP_BW:-500}" rate="${SHAPER_RATE:-}" bw_note rate_note
    rate="${rate%%[!0-9]*}"
    [[ -n $rate ]] || rate="500"
    if [[ -n $TCP_BW ]]; then bw_note="--tcp-bw 指定"; else bw_note="示例值，请换成套餐带宽"; fi
    if [[ -n $SHAPER_RATE ]]; then rate_note="--shaper-rate 指定（已归一化）"; else rate_note="示例值，请换成实际速率"; fi
    printf '  %s\n' "手动调优（脚本不会替你执行；示例数字请换成你的实际带宽）："
    printf '    %-46s # %s\n' "tcpfit" "交互式菜单（含一键调优向导）"
    printf '    %-46s # %s\n' "tcpfit tune --role proxy --bw ${bw}" "基础调优（${bw_note}）"
    printf '    %-46s # %s\n' "tcpfit shape --rate ${rate}" "出向整形（${rate_note}）"
    printf '    %-46s # %s\n' "tcpfit shape --off" "移除出向整形"
    printf '    %-46s # %s\n' "tcpfit status" "查看当前调优状态"
    printf '    %-46s # %s\n' "tcpfit rollback" "一键回滚到基线"
    return 0
}

# ============================================================
# 6. sing-box 安装 + 密钥/证书
# ============================================================
m_singbox() {
    info "==> [6] sing-box 安装与凭据生成"
    # 「沿用旧配置」：模块 6 整个跳过 —— 连 sing-box 程序与 systemd 覆盖文件都不动，
    # 更不重新生成任何凭据 / 自签证书、不写 state.env。
    if [[ ${RERUN_MODE:-} == keep ]] && has_existing_deployment; then
        CRED_ROTATED=0
        ok "沿用旧配置：模块 6 全部跳过 —— sing-box 程序、UUID / Reality 密钥 / 各密码 / 自签证书、state.env 均保持原样"
        return 0
    fi
    if ! command -v sing-box >/dev/null; then
        # 走 §3 统一下载：带超时/重试/缓存，失败能给出可读原因，而不是只留一行行号
        local inst="$CACHE_DIR/sing-box-install.sh"
        fetch_file "$inst" https://sing-box.app/install.sh \
            || die "sing-box 安装脚本下载失败（可重跑本模块；缓存目录 ${CACHE_DIR}）"
        # 官方安装脚本失败时只留一行 ERR 陷阱看不清原因：捕获输出，失败时回显末尾
        # mktemp：/tmp 世界可写，$$ 可预测的固定名可被并发用户抢注（模板固定 POSIX /tmp）
        local inst_log; inst_log="$(mktemp "/tmp/.vps-init.sbinstall.XXXXXX.log")"
        local inst_rc=0
        if [[ -n $SB_VERSION ]]; then
            sh -s -- --version "$SB_VERSION" < "$inst" >"$inst_log" 2>&1 || inst_rc=$?
        else
            sh -s < "$inst" >"$inst_log" 2>&1 || inst_rc=$?
        fi
        if (( inst_rc != 0 )); then
            tail -n 30 "$inst_log" >&2
            die "sing-box 安装脚本失败（退出码 ${inst_rc}，完整日志：${inst_log}）"
        fi
        rm -f "$inst_log"
    else
        local _cur; _cur="$(sing-box version 2>/dev/null | head -1 || true)"
        info "sing-box 已安装：${_cur:-版本未知}"
        # 已装版本与 --sb-version 不一致时明确告知（不擅自升级，避免打断正在运行的代理）
        if [[ -n $SB_VERSION && $_cur != *"$SB_VERSION"* ]]; then
            warn "当前版本与 --sb-version ${SB_VERSION} 不一致：已装版本不会被自动替换；需要时先 apt-get purge sing-box 再重跑本模块"
        fi
    fi
    command -v sing-box >/dev/null || die "sing-box 安装失败"
    # 装完必须复核版本：--version 由第三方安装脚本解释，脚本退出 0 不代表真的装了指定版本
    # （旧版本脚本可能静默忽略未知参数）。宁可 fail-fast，也不让「锁了 1.13 实装 1.11」的
    # 机器带着版本差继续往下跑配置渲染。
    if [[ -n $SB_VERSION ]]; then
        local _ver_now; _ver_now="$(sing-box version 2>/dev/null | head -1 || true)"
        [[ $_ver_now == *"$SB_VERSION"* ]] \
            || die "sing-box 版本复核失败：要求 ${SB_VERSION}，实际安装为「${_ver_now:-未知}」。请先 apt-get purge sing-box 后重跑，或手动到 GitHub Releases 安装指定版本"
        info "sing-box 版本复核通过：${_ver_now}"
    fi
    # 放开文件句柄上限，高并发下避免 too many open files
    mkdir -p /etc/systemd/system/sing-box.service.d
    cat > /etc/systemd/system/sing-box.service.d/10-limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    mkdir -p "$SB_DIR"
    command -v openssl >/dev/null || apt_install openssl

    # 重跑语义：只有「生成新配置」才轮换凭据；「沿用旧配置」在开头已整体跳过。
    # force=1 会连 --uuid 这类命令行固定值也清空，保证每次都是全新一套，
    # 既不复用上次生成结果，也不复用固定值。
    local old_rotated force=0
    # 只有「重跑且选了生成新配置」才强制忽略 --uuid 等固定值。
    # 首次部署时 config.json 还没生成，不属于「重新运行」，用户显式给的 UUID 应被尊重，
    # 否则会破坏既有的 --uuid 参数与旧版本部署习惯。
    if should_force_regen; then force=1; fi
    if [[ $force -eq 1 && -n ${CLI_SET[UUID]:-} ]]; then
        warn "--new-config 要求整套凭据全新，命令行 --uuid 本次被忽略（不复用固定值）"
    fi
    if [[ ${ROTATE_SECRETS:-0} -eq 1 ]]; then
        # --rotate-secrets：定向轮换，Reality 密钥对与自签证书保持不变
        rotate_session_credentials
        info "--rotate-secrets：只轮换 UUID / short_id / hy2 密码 / obfs 密码"
    else
        regen_credentials "$force"
    fi
    old_rotated=$CRED_ROTATED

    [[ -n $UUID      ]] || UUID="$(sing-box generate uuid)"
    [[ -n $SHORT_ID  ]] || SHORT_ID="$(sing-box generate rand 8 --hex)"
    [[ -n $HY2_PW    ]] || HY2_PW="$(sing-box generate rand 16 --base64)"
    [[ -n $OBFS_PW   ]] || OBFS_PW="$(sing-box generate rand 16 --base64)"
    if [[ -z $REALITY_PRIV || -z $REALITY_PUB ]]; then
        local kp; kp="$(sing-box generate reality-keypair)"
        REALITY_PRIV="$(printf '%s\n' "$kp" | awk '/PrivateKey/{print $2}')"
        REALITY_PUB="$(printf '%s\n'  "$kp" | awk '/PublicKey/{print $2}')"
    fi
    [[ -n $REALITY_PRIV && -n $REALITY_PUB ]] || die "Reality 密钥对生成失败"
    if [[ $old_rotated -eq 1 ]]; then
        if [[ ${ROTATE_SECRETS:-0} -eq 1 ]]; then
            warn "凭据已定向轮换：UUID / short_id / hy2 密码 / obfs 密码均为新值，旧客户端配置与分享链接全部作废"
            warn "Reality 密钥对与自签证书保持不变；服务端配置与客户端交付由模块 8/9 重写"
        else
            warn "节点凭据已轮换：UUID / Reality 密钥 / short_id / 各密码均为新值，旧客户端配置与分享链接全部作废"
            if [[ ${MOD_ON[7]:-0} -eq 0 || ${MOD_ON[8]:-0} -eq 0 ]]; then
                warn "本次未包含模块 8/9：服务端 config.json 与交付文件仍是旧凭据，请再执行 --modules 8,9 重新生成"
            fi
        fi
        ok "UUID / short_id / hy2 密码 已重新生成"
    else
        ok "UUID / short_id / Reality 密钥 / hy2 密码 已生成"
    fi

    # Hysteria2 自签证书与私钥同样属于节点凭据，重跑一并轮换；
    # CERT_HASH 会跟着变，客户端的 pinSHA256 / insecure 设置需重新导入。
    # --rotate-secrets 明确保留证书（CERT_HASH 不变，客户端 pinSHA256 无需更新）。
    if [[ ${ROTATE_SECRETS:-0} -eq 1 && -s ${SB_DIR}/cert.crt && -s ${SB_DIR}/private.key ]]; then
        ok "自签证书保持不变（--rotate-secrets）：pinSHA256 仍为 ${CERT_SHA256:-（状态文件原值）}"
    else
    # 原子化生成：先写 .new，校验私钥与证书配对后再替换。
    # 否则「私钥写成功、证书签发失败」会留下新私钥 + 旧证书：-s 校验照样通过，
    # CERT_HASH 算的却是旧证书，hy2 握手必失败而脚本仍报"证书已生成"。
    local _ck="${SB_DIR}/private.key.new" _cc="${SB_DIR}/cert.crt.new"
    rm -f "$_ck" "$_cc"
    # umask 077：私钥文件在 mv 之前就已是最终形态，不能存在默认 umask 的全局可读瞬间
    if ! ( umask 077; openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$_ck" -out "$_cc" -subj "/CN=${CERT_CN}" -days 36500 ) 2>/dev/null \
       || [[ ! -s $_ck || ! -s $_cc ]]; then
        rm -f "$_ck" "$_cc"
        die "自签证书生成失败，请检查 openssl 与磁盘空间/权限"
    fi
    local _pk_cert _pk_key
    _pk_cert="$(openssl x509 -in "$_cc" -pubkey -noout 2>/dev/null \
                | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)"
    _pk_key="$(openssl pkey -in "$_ck" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)"
    if [[ -z $_pk_cert || $_pk_cert != "$_pk_key" ]]; then
        rm -f "$_ck" "$_cc"
        die "自签证书与私钥不配对（生成异常），已放弃写入，请重试"
    fi
    mv -f "$_ck" "${SB_DIR}/private.key"; mv -f "$_cc" "${SB_DIR}/cert.crt"
    if [[ $old_rotated -eq 1 ]]; then
        ok "自签证书已重新生成（CN=${CERT_CN}，100 年）"
    else
        ok "自签证书已生成（CN=${CERT_CN}，100 年）"
    fi
    fi
    chmod 600 "${SB_DIR}/private.key" 2>/dev/null || true
    chmod 644 "${SB_DIR}/cert.crt" 2>/dev/null || true
    # 两个指纹都从证书文件现算（--rotate-secrets 保留证书时同样有效，旧状态文件缺
    # CERT_SHA256 也能自愈）：
    #   CERT_HASH   = 公钥 DER 的 sha256 + base64 → sing-box 的 certificate_public_key_sha256
    #   CERT_SHA256 = 整张证书的 sha256（hex）   → Hysteria2 URI 的 pinSHA256
    if [[ -s ${SB_DIR}/cert.crt ]]; then
        # || true 兜底：mv 已把新证书落盘，若指纹计算意外失败（磁盘满等）绝不能在
        # save_state 之前中止 —— 否则磁盘是新证书、state 里残留旧指纹，keep 重跑
        # 会按旧指纹 pin 导致握手必失败。失败置空后由既有降级路径兜底
        # （JSON → insecure，链接 → insecure=1），state 与磁盘不再分叉。
        CERT_HASH="$(openssl x509 -in "${SB_DIR}/cert.crt" -pubkey -noout 2>/dev/null | \
                     openssl pkey -pubin -outform DER 2>/dev/null | \
                     openssl dgst -sha256 -binary 2>/dev/null | openssl enc -base64 2>/dev/null)" || true
        CERT_SHA256="$(openssl x509 -in "${SB_DIR}/cert.crt" -outform DER 2>/dev/null \
                     | openssl dgst -sha256 2>/dev/null | sed 's/^.*= //' | tr -d ' \r\n')" || true
        [[ ${#CERT_SHA256} -eq 64 ]] || CERT_SHA256=""
    fi
    ok "证书指纹：链接 pinSHA256=${CERT_SHA256:-<未取到>}；JSON 公钥哈希=${CERT_HASH:-<未取到>}"
    # 分叉点：凭据轮换且旧 config.json 仍在磁盘上，此刻 state.env 与 config.json
    # 已经不一致；后续任何失败出口都要据此给出准确的恢复指引。
    [[ $CRED_ROTATED -eq 1 && -f $SB_CONF ]] && SB_STATE_AHEAD=1
    save_state
}

# 模块 6 轮换凭据后模块 8 渲染/校验失败时的统一提醒。
# 不能只在「未选模块 8/9」时提醒（2473 行区）——「选了但失败了」这条路同样会分叉。
warn_state_config_divergence() {
    [[ ${SB_STATE_AHEAD:-0} -eq 1 ]] || return 0
    warn "模块 6 已把新凭据写入 ${STATE_FILE}，但 config.json 未更新成功，两者已分叉："
    warn "  下次重跑必须选「生成新配置」重新应用新凭据；选「沿用旧配置」将按旧凭据继续运行，"
    warn "  而摘要 / 分享链接会按 state.env 的新凭据渲染 —— 与线上不一致，导入必失败"
    return 0
}

# ============================================================
# 7. Reality 回落站
# ============================================================
m_reality() {
    info "==> [7] Reality 回落站"
    if [[ -z $DOMAIN ]]; then
        DOMAIN="$(ask "回落域名（留空则回退公共站点握手：不建本地回落、不签证书、伪装站页面不部署）" "$DOMAIN")"
    fi
    # DOMAIN 有 4 个来源：CLI / 环境变量 / 状态文件 / 交互询问，而原来只有 CLI 那条会校验。
    # 在这里统一补一次，只拦非法域名；刻意不新增 validate_settings 调用点，
    # 否则 --modules 7 单跑时会被状态文件里其它字段的旧值连带误伤。
    need_hostname "--domain" "$DOMAIN"

    # 重跑场景：CF_TOKEN 不在 STATE_KEYS（不把 API Token 落到 state.env），
    # 过去 --modules 7 单跑 / --yes 重跑时 Token 为空 → 静默降级成公共站点握手，
    # 把 REALITY_SNI/DEST 覆盖掉，导致线上客户端全部失效。
    # 若本机已有 CN/SAN 匹配当前域名的证书，就直接复用，不再要求 Token。
    local reuse_cert=0
    if [[ -n $DOMAIN && -s ${SB_DIR}/cert/private.key && -s ${SB_DIR}/cert/fullchain.cer ]] \
        && cert_domain_matches "${SB_DIR}/cert/fullchain.cer" "$DOMAIN"; then
        reuse_cert=1
        # 复用只校验域名不校验有效期：快到期时明确提醒（保留复用 —— 降级成公共站点握手
        # 会立刻打断线上客户端，比"证书快过期"严重得多）
        if command -v openssl >/dev/null 2>&1 \
           && ! openssl x509 -in "${SB_DIR}/cert/fullchain.cer" -checkend 2592000 -noout 2>/dev/null; then
            warn "现有证书将在 30 天内到期或已过期：请确认 acme.sh 续期任务正常（crontab -l | grep acme），必要时手动 --renew"
        fi
    fi

    if [[ -n $DOMAIN && -z $CF_TOKEN && $reuse_cert -eq 0 ]]; then
        warn "本机没有可复用的 ${DOMAIN} 证书，Cloudflare DNS 签发需要 API Token"
        CF_TOKEN="$(ask "CF Token（留空则回退公共站点握手：不建本地回落、不签证书、伪装站页面不部署）" "$CF_TOKEN")"
    fi

    if [[ -n $DOMAIN && ( -n $CF_TOKEN || $reuse_cert -eq 1 ) ]]; then
        [[ -n $ACME_EMAIL ]] || ACME_EMAIL="admin@${DOMAIN}"
        apt_install debian-keyring debian-archive-keyring apt-transport-https cron socat

        # Caddy
        if ! command -v caddy >/dev/null; then
            local caddy_key="$CACHE_DIR/caddy-stable.gpg.key"
            local caddy_repo="$CACHE_DIR/caddy-stable.list"
            fetch_file "$caddy_key" 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                || die "caddy 仓库公钥下载失败，无法添加 apt 源"
            fetch_file "$caddy_repo" 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
                || die "caddy 仓库地址下载失败，无法添加 apt 源"
            mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
            # --batch --yes：keyring 已存在时（上次在本步之后失败）gpg 会交互询问覆盖，
            # 而 stdin 已被重定向为 key 文件 —— 非交互下必然报错，重跑永远过不去
            gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg < "$caddy_key"
            cat "$caddy_repo" > /etc/apt/sources.list.d/caddy-stable.list
            # 刚新增了 caddy 源，必须真正刷新一次索引。apt_update 有「本次会话只更新一次」
            # 的缓存位，模块 1/3 通常已经把它置 1；此处不清零就会被短路成空操作，
            # 紧接着 apt-get install caddy 直接报 "Unable to locate package"（全量运行必现）
            APT_UPDATED=0
            apt_update
            apt_install caddy
        fi

        if [[ $reuse_cert -eq 1 ]]; then
            ok "复用已有证书（CN/SAN 匹配 ${DOMAIN}），跳过 acme.sh 签发，无需 CF Token"
            # 复用路径同样统一一次属主/权限：证书可能是从备份手工恢复的，
            # 若 private.key 只有 root 可读，Caddy（caddy 用户）会起不来。
            chown -R caddy:caddy "${SB_DIR}/cert" 2>/dev/null || true
            chmod 644 "${SB_DIR}/cert/fullchain.cer" 2>/dev/null || true
            chmod 600 "${SB_DIR}/cert/private.key" 2>/dev/null || true
        else
            # acme.sh + CF DNS 签发
            export CF_Token="$CF_TOKEN"
            if [[ ! -d /root/.acme.sh ]]; then
                local acme_inst="$CACHE_DIR/acme-install.sh"
                if fetch_file "$acme_inst" https://get.acme.sh; then
                    sh -s "email=${ACME_EMAIL}" < "$acme_inst" >/dev/null 2>&1 \
                        || warn "acme.sh 安装脚本返回非 0（若已安装可忽略）"
                else
                    warn "acme.sh 安装脚本下载失败，将尝试使用机器上已有的 acme.sh"
                fi
            fi
            local ACME="/root/.acme.sh/acme.sh"
            [[ -x $ACME ]] || die "acme.sh 安装失败"
            # 已签发过时 acme.sh 的 --issue 会以非 0 退出（"Domains not changed"），
            # 所以这里不能立刻 die：继续尝试 --install-cert 是原有的恢复路径，必须保留。
            # 真正的兜底在下面：install-cert 的返回码 + 证书 CN/SAN 校验。
            if ! "$ACME" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256 --server "$ACME_CA" >/dev/null; then
                warn "签发步骤返回非 0（若此前已签发可忽略），继续尝试安装证书"
            fi
            mkdir -p "${SB_DIR}/cert"
            if ! "$ACME" --install-cert -d "$DOMAIN" --ecc \
                --key-file       "${SB_DIR}/cert/private.key" \
                --fullchain-file "${SB_DIR}/cert/fullchain.cer" \
                --reloadcmd      "chown -R caddy:caddy ${SB_DIR}/cert; chmod 600 ${SB_DIR}/cert/private.key; systemctl reload caddy"; then
                warn_state_config_divergence
                die "证书安装失败，请检查域名解析与 CF Token 权限（需 Zone.DNS 编辑权限）"
            fi
            [[ -s ${SB_DIR}/cert/private.key && -s ${SB_DIR}/cert/fullchain.cer ]] \
                || { warn_state_config_divergence; die "证书安装失败：证书文件为空，请检查 acme.sh 输出"; }
            # 旧实现只看"文件存在"：签发失败后目录里残留的旧域名证书会被当成成功，
            # Caddy 拿着错域名的证书，Reality 握手必然失败。这里确认装回来的是当前域名。
            if cert_domain_matches "${SB_DIR}/cert/fullchain.cer" "$DOMAIN"; then
                ok "证书校验通过：CN/SAN 与 ${DOMAIN} 匹配"
            elif openssl x509 -in "${SB_DIR}/cert/fullchain.cer" -noout -subject >/dev/null 2>&1; then
                warn_state_config_divergence
                die "装回的证书与 ${DOMAIN} 不匹配（可能残留了旧域名证书），Reality 握手会失败"
            else
                # openssl 不可用 / 证书格式异常时保持兼容：只告警，不中断部署
                warn "无法解析证书内容做域名校验，已跳过（请自行确认证书域名）"
            fi
            chown -R caddy:caddy "${SB_DIR}/cert"
            chmod 755 "${SB_DIR}/cert"; chmod 644 "${SB_DIR}/cert/fullchain.cer"; chmod 600 "${SB_DIR}/cert/private.key"
        fi

        # Caddyfile 重跑会被整份覆盖：留一份「上一版」备份。
        # 用固定文件名而不是时间戳，避免每次重跑都在 /root 下堆一摞备份。
        mkdir -p /etc/caddy
        if [[ -s /etc/caddy/Caddyfile ]]; then
            cp -a /etc/caddy/Caddyfile /root/.vps-init.Caddyfile.bak 2>/dev/null || true
            info "已备份上一版 Caddyfile：/root/.vps-init.Caddyfile.bak（本次将按当前域名/端口覆盖）"
        fi
        cat > /etc/caddy/Caddyfile <<EOF
{
    auto_https off
}

${DOMAIN}:${FALLBACK_PORT} {
    tls ${SB_DIR}/cert/fullchain.cer ${SB_DIR}/cert/private.key
    root * ${WEB_ROOT}
    file_server
}
EOF
        mkdir -p "$WEB_ROOT"
        if [[ -n $WEB_PAGE && -f $WEB_PAGE ]]; then
            cp -f "$WEB_PAGE" "${WEB_ROOT}/index.html"
            ok "伪装站已使用自定义页面：${WEB_PAGE}"
        elif write_bundled_web_page "${WEB_ROOT}/index.html"; then
            ok "伪装站已使用内置页面（青山·一屏山色）"
        else
            cat > "${WEB_ROOT}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>It works</title>
<style>
  html,body{height:100%;margin:0}
  body{display:flex;align-items:center;justify-content:center;
       background:#f7f5f0;color:#2b2b2b;
       font-family:"PingFang SC","Microsoft YaHei",system-ui,sans-serif}
  h1{font-weight:400;letter-spacing:.2em;font-size:1.4rem;opacity:.75}
</style>
</head>
<body><h1>It works</h1></body>
</html>
EOF
        fi
        chown -R caddy:caddy "$WEB_ROOT" 2>/dev/null || true
        caddy fmt --overwrite /etc/caddy/Caddyfile
        caddy validate --config /etc/caddy/Caddyfile >/dev/null
        systemctl enable --now caddy >/dev/null
        systemctl restart caddy
        sleep 1
        curl -ksS --max-time 8 --resolve "${DOMAIN}:${FALLBACK_PORT}:127.0.0.1" \
            "https://${DOMAIN}:${FALLBACK_PORT}" >/dev/null && ok "回落站自检通过" || warn "回落站自检未通过，请检查 caddy 状态"

        if [[ -n ${CLI_SET[REALITY_SNI]:-} || -n ${CLI_SET[REALITY_DEST]:-} || -n ${CLI_SET[REALITY_DEST_PORT]:-} ]]; then
            warn "本地回落模式下 REALITY_SNI/DEST/DEST_PORT 由脚本按 ${DOMAIN}:${FALLBACK_PORT} 接管，忽略手工指定的值"
        fi
        REALITY_SNI="$DOMAIN"; REALITY_DEST="127.0.0.1"; REALITY_DEST_PORT="$FALLBACK_PORT"
        ok "本地回落已就绪：${DOMAIN}:${FALLBACK_PORT}"
    else
        # 重跑降级：上次若走的是本地回落，state.env 里会残留 DEST=127.0.0.1 /
        # PORT=FALLBACK_PORT，而 ${VAR:-默认} 不会覆盖它。结果是握手指向一个
        # 已经没有 Caddy 的本机端口，warn 还把 127.0.0.1 打印成"正常目标"。
        # 只在这个「脚本自己写入的精确特征」下重置；用户自定义的公共站点
        # 目标（如 www.caltech.edu）和命令行显式指定的值一律保留。
        if is_local_fallback_state; then
            warn "上次是本地回落（127.0.0.1:${FALLBACK_PORT}），本次改用公共站点握手，已清除该残留"
            REALITY_SNI=""; REALITY_DEST=""; REALITY_DEST_PORT=""
        fi
        REALITY_SNI="${REALITY_SNI:-$REALITY_PUBLIC_SNI_DEFAULT}"
        REALITY_DEST="${REALITY_DEST:-$REALITY_PUBLIC_DEST_DEFAULT}"
        REALITY_DEST_PORT="${REALITY_DEST_PORT:-$REALITY_PUBLIC_PORT_DEFAULT}"
        # keep 下降级只改了 state 与摘要：config.json 的 Reality 握手目标不会跟着变，
        # 必须明示这个错位窗口，否则用户以为「降级完成 = 配置已同步」。
        if [[ ${RERUN_MODE:-} == keep ]] && has_existing_deployment; then
            warn "沿用旧配置下模块 7 只更新了 state.env 与摘要：config.json 的 Reality 握手目标仍是旧值，重跑模块 8 后才会按新目标重写配置"
        fi
        if [[ -n $DOMAIN && -z $CF_TOKEN ]]; then
            warn "已提供域名 ${DOMAIN}，但缺少 CF Token 且本机没有可复用的同域名证书 → 回退公共站点握手"
        fi
        warn "Reality 握手将使用公共站点：${REALITY_DEST}:${REALITY_DEST_PORT}（SNI: ${REALITY_SNI}）"
        warn "本模式不安装 Caddy、不签证书，【伪装站页面不会部署】（内置页面与 --web-page 均不生效）"
        warn "如需本地回落站与伪装站：同时提供 --domain 与 --cf-token；重跑时若已有同域名证书则只需 --domain"
        warn "注意：公共站点目标必须支持 TLS1.3 + X25519 + HTTP/1.1，否则 Reality 不可用"
    fi
    save_state
}

# ============================================================
# §11 业务模块 —— 8. 生成配置并启动
# ============================================================

# ===== §12 JSON 构造器（零依赖） =====
# 目标：动态值只经由 json_escape 一处进入 JSON；逗号由 j_join 统一补、
# 缩进由 j_obj/j_arr 统一加 —— 模板里不再手写逗号，也就不会漏逗号 / 多尾逗号 / 漏转义。
# 不引入 jq 或 python：--print-* 离线渲染继续保持"只用系统自带工具"。
#
# 用法示意：
#   local -a m=()
#   m+=("$(j_kv type hysteria2)")                       # "type": "hysteria2"
#   m+=("$(j_lit listen_port "$HY2_PORT")")             # "listen_port": 443
#   m+=("\"tls\": $(j_obj '    ' "$(j_lit enabled true)")")   # 嵌套对象
#   j_obj '' "${m[@]}"                                  # 渲染成一个块

# JSON 字符串转义（RFC 8259）：\ " 以及全部控制字符
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"        # 反斜杠必须最先处理，否则会把随后加上的转义再转义一遍
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    # 其余控制字符（0x00-0x1F）不允许以字面出现在 JSON 里，直接剔除
    if [[ $s == *[$'\001'-$'\037']* ]]; then
        s="$(printf '%s' "$s" | tr -d '\001-\010\013\014\016-\037')"
    fi
    printf '%s' "$s"
}

# j_kv <键> <值>        → "键": "已转义的值"
j_kv()  { printf '"%s": "%s"' "$1" "$(json_escape "$2")"; }
# j_lit <键> <字面量>   → "键": 443 / true（数字与布尔不做字符串转义）
# 这里会拒绝空值：端口/带宽这类量一旦漏填，渲染出 "server_port": , 的非法配置
# 会一路带到 sing-box check 才炸，且报错指向 JSON 而不是真正的源头。
j_lit() {
    local k="$1" v="$2"
    # 前导零（如手工把 state.env 的 SSH_PORT 改成 0443）会拼出非法 JSON 字面量 "0443"，
    # json.load 直接解析失败 —— 在这里拦住并给出指向 state.env 的报错。
    if [[ ! $v =~ ^-?(0|[1-9][0-9]*)$ && $v != true && $v != false ]]; then
        die "内部错误：字段 ${k} 期望数字或布尔（且不带前导零），实际为「${v}」（检查是否漏填参数或手工改坏了 ${STATE_FILE}）"
    fi
    printf '"%s": %s' "$k" "$v"
}

# j_join <缩进> <行...>：每行加缩进、行间补逗号（末行不补）
j_join() {
    local indent="$1"; shift
    local out="" sep="" line
    for line in "$@"; do
        out+="${sep}${indent}${line}"; sep=$',\n'
    done
    printf '%s' "$out"
}
# j_obj <本层缩进> <成员行...>：渲染 {...}，成员缩进 = 本层缩进 + 4
j_obj() {
    local indent="$1"; shift
    printf '{\n%s\n%s}' "$(j_join "${indent}    " "$@")" "$indent"
}
# j_arr <本层缩进> <元素行...>：渲染 [...]
j_arr() {
    local indent="$1"; shift
    printf '[\n%s\n%s]' "$(j_join "${indent}    " "$@")" "$indent"
}

# ---------- §13 多 IP 探测 ----------
NODE_IPS=()
sanitize_name() {
    # 控制字符会让节点名在 JSON 里断行、让分享链接的 fragment 失效，统一清掉
    local s="${1//$'\r'/}";  s="${s//$'\n'/}"; s="${s//$'\t'/ }"
    s="${s//\"/}"; s="${s//\\/}"; s="${s//\$/}"
    printf '%s' "$s"
}

# ---------- 机房位置（城市名）识别 ----------
# 节点名前缀用「机房所在城市」比用 hostname 有用得多：hostname 在很多机器上
# 是随机串或重复的名字（vps、debian、localhost），而城市名一眼就能看出
# 这条线路在哪儿、回程延迟如何。
#
# 数据源与降级链（均已实测）：
#   1) ip-api   http://ip-api.com/json/<ip>?lang=zh-CN
#      免费版只有 HTTP（HTTPS 直接报 SSL unavailable），能返回中文城市名，
#      但日本部分 IP 的 city 会退回英文（Chiyoda City / Sumiyoshichō）。
#   2) ipwho.is https://ipwho.is/<ip>?lang=zh-CN
#      HTTPS 可用、city 稳定为中文（美国 → 洛杉矶 / 皮斯卡特维），
#      但日本只精确到都道府县级（东京都）。
#   3) 上面两源的 city 都不是中文时，退回 regionName（东京都 / 大阪府 / 新泽西州），
#      去掉行政后缀后当作位置（东京 / 大阪 / 新泽西）。
#   4) 全部失败 → 用 hostname 兜底，绝不让节点名变空。
#
# 地名末尾的行政后缀（市/区/都/府/县/州）会被去掉，
# 让「东京都」变成「东京」、「大阪府」变成「大阪」，与用户口述的叫法一致。
has_cjk() { # <字符串>：是否含非 ASCII（中日韩）字符
    [[ -n ${1:-} ]] || return 1
    # 用 wc -c 而不是 `grep -q .`：grep -q 命中后立刻退出会让上游收到 SIGPIPE，
    # 在 pipefail 下整条管道的退出码变成 141，把"有中文"误判成"没有"。
    local n
    n="$(LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\000-\177' | LC_ALL=C wc -c 2>/dev/null || echo 0)"
    n="${n//[^0-9]/}"
    [[ -n $n ]] && (( n > 0 ))
}
trim_place_suffix() { # <地名>：去掉末尾的市/区/都/府/县/州等行政后缀
    local s="$1"
    local len=${#s}
    [[ $len -ge 3 ]] || { printf '%s' "$s"; return 0; }
    case "${s: -1}" in
        市|區|区|都|府|縣|县|州) s="${s:0:$((len-1))}";;
    esac
    printf '%s' "$s"
}
json_pick() { # <json文本> <字段名>：取出 "字段":"值" 里的值
    # 兼容带缩进的 JSON（"city": "Los Angeles"），字段与冒号之间允许空白。
    # || true：set -e -o pipefail 下，head 提前退出会让 sed 收到 SIGPIPE（141），
    # 取不到字段属于正常情况，不该让脚本中断。
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1 || true
}
usable_place() { # <地名>：非空且不是服务返回的「查不到」占位值
    local s="${1:-}"
    [[ -n $s ]] || return 1
    case "${s,,}" in unknown|"-"|null|none|n/a) return 1;; esac
    return 0
}
pick_place() { # <city> <region>：中文优先，其次接受英文/任意有效地名
    local city="$1" region="$2"
    if usable_place "$city" && has_cjk "$city"; then trim_place_suffix "$city"; return 0; fi
    if usable_place "$region" && has_cjk "$region"; then trim_place_suffix "$region"; return 0; fi
    if usable_place "$city"; then printf '%s' "$city"; return 0; fi
    if usable_place "$region"; then printf '%s' "$region"; return 0; fi
    return 1
}
# 取某个 IP 的机房位置（中文优先）。成功返回 0 并打印位置名。
# VPS_INIT_SKIP_GEO=1 可关闭外网查询（离线渲染 / 回归测试用）。
detect_location() { # <ip>
    local ip="${1:-}" body out
    [[ -n $ip ]] || return 1
    [[ "${VPS_INIT_SKIP_GEO:-0}" == "1" ]] && return 1

    # 1) ip-api（免费版仅 HTTP）。很多机房只返回英文 city（Chiyoda City /
    #    Los Angeles），旧版只认中文 → 一律判「识别失败」退化成 hostname，这是
    #    「机房检测错误」的主要来源，现在英文地名也接受。
    body="$(curl -fsS --max-time 5 "http://ip-api.com/json/${ip}?lang=zh-CN" 2>/dev/null || true)"
    if [[ -n $body && $body == *'"status":"success"'* ]]; then
        if out="$(pick_place "$(json_pick "$body" city)" "$(json_pick "$body" regionName)")" \
            && [[ -n $out ]]; then printf '%s' "$out"; return 0; fi
    fi

    # 2) ipwho.is（HTTPS，city 中文更稳定）
    body="$(curl -fsS --max-time 5 "https://ipwho.is/${ip}?lang=zh-CN" 2>/dev/null || true)"
    if [[ -n $body && $body == *'"success":true'* ]]; then
        if out="$(pick_place "$(json_pick "$body" city)" "$(json_pick "$body" region)")" \
            && [[ -n $out ]]; then printf '%s' "$out"; return 0; fi
    fi

    # 3) ipapi.co（带缩进 JSON；json_pick 已允许字段后空白）
    body="$(curl -fsS --max-time 5 "https://ipapi.co/${ip}/json/" 2>/dev/null || true)"
    if [[ -n $body && $body == *'"city"'* ]]; then
        if out="$(pick_place "$(json_pick "$body" city)" "$(json_pick "$body" region)")" \
            && [[ -n $out ]]; then printf '%s' "$out"; return 0; fi
    fi

    return 1
}

# 节点名前缀：
#   显式 --node-name  >  自动识别的机房城市  >  交互手动输入  >  hostname
# 结果缓存在 LOC_NAME 里，避免同一次运行反复外网查询。
# LOC_ASK_ENABLED 只由 main 在「真实终端 + 完整交互部署」时置 1：
#   --yes / --modules / --print-* / --status / 管道输入一律不弹，
#   否则会污染离线渲染的 stdout JSON，或让自动化流程卡在等输入。
LOC_NAME=""; LOC_DONE=0; NODE_PREFIX=""; LOC_ASK_ENABLED=0
# 结果同时写进全局变量：node_prefix 可能要弹交互输入、写 NODE_NAME 和 state.env。
# 若调用方用 $(...) 捕获输出，这些修改全被关进子 shell，父 shell 后续 save_state
# 又会把刚写入的 NODE_NAME 覆盖掉。因此由调用方在当前 shell 直接执行本函数。
NODE_PREFIX_RESULT=""
# 单独抽成函数便于单元测试 stub：只有真实终端才允许弹手动输入。
stdin_is_tty() { [[ -t 0 ]]; }
node_prefix() { # <ip>
    local ip="${1:-}" loc hn ans out
    NODE_PREFIX_RESULT=""
    if [[ -n $NODE_NAME ]]; then
        hn="$(hostname 2>/dev/null || echo vps)"
        # 旧版本会把 hostname 自动写进状态文件；这种值不当作用户指定，
        # 否则第一次运行后节点名就永远固定成 hostname，位置检测再也生效不了。
        if [[ $NODE_NAME != "$hn" ]]; then
            NODE_PREFIX_RESULT="$(sanitize_name "$NODE_NAME")"
            printf '%s' "$NODE_PREFIX_RESULT"
            return 0
        fi
    fi
    if [[ $LOC_DONE -eq 0 ]]; then
        LOC_DONE=1
        if loc="$(detect_location "$ip")" && [[ -n $loc ]]; then
            LOC_NAME="$(sanitize_name "$loc")"
        fi
    fi
    if [[ -z $LOC_NAME && ${LOC_ASK_ENABLED:-0} -eq 1 ]] && stdin_is_tty; then
        hn="$(sanitize_name "$(hostname 2>/dev/null || echo vps)")"
        warn "机房位置自动识别失败（${ip:-未取到对外 IP}）：可手动指定节点名前缀"
        ans="$(ask "节点名前缀（机房城市，回车用 ${hn}）" "")"
        if [[ -n $ans ]]; then
            # 用户显式输入等同于 --node-name：写入 state.env，重跑沿用。
            NODE_NAME="$(sanitize_name "$ans")"
            LOC_NAME="$NODE_NAME"
            save_state
            # 调用方把本函数的 stdout 收进了 /dev/null，提示必须走 stderr 才看得见。
            info "节点名前缀已设为「${LOC_NAME}」（也可用 --node-name 修改）" >&2
        fi
    fi
    if [[ -n $LOC_NAME ]]; then
        out="$LOC_NAME"
    else
        out="$(sanitize_name "$(hostname 2>/dev/null || echo vps)")"
    fi
    NODE_PREFIX_RESULT="$out"
    printf '%s' "$out"
}

# 非公网地址：私网 / 回环 / 链路本地 / CGNAT / 保留 / 组播 / ULA。
# 自动探测必须排除，否则 docker0(172.17.0.1)、云厂商内网网卡(172.31.x.x)、
# 内网管理网段都会被写进入站监听与分享链接，生成一批必然连不通的节点。
is_private_addr() {
    case "$1" in
        # IPv4：RFC1918 / 回环 / 链路本地
        10.*|127.*|169.254.*|192.168.*) return 0;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0;;
        # CGNAT 100.64.0.0/10 = 100.64.x.x - 100.127.x.x
        # （原写法 100.1[0-2][0-9] 会连到 100.128/100.129，把公网地址误判成私网而丢弃；
        #   之前的收窄写法 100.1[0-2][0-7] 又漏掉 108/109/118/119 四个第三八位组）
        100.6[4-9].*|100.[7-9][0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0;;
        # 保留 / 文档 / 基准测试段，以及组播与预留（都不可能承载公网服务）
        0.*|192.0.0.*|192.0.2.*|198.18.*|198.19.*|198.51.100.*|203.0.113.*) return 0;;
        22[4-9].*|23[0-9].*|24[0-9].*|25[0-5].*) return 0;;
        # IPv6：ULA(fc00::/7) / 链路本地(fe80::/10，原写法 fe80:* 漏掉 fe81-febf)
        #      / 回环 / 未指定 / 组播 / 文档段
        fc*|fd*|fe8*|fe9*|fea*|feb*|ff*|::1|::|2001:db8:*) return 0;;
        *) return 1;;
    esac
}

# 逗号分隔的 IP 列表 → 规范化为数组（去空格、剥掉 IPv6 的方括号、丢弃空项）。
# 本机探测与 --ips 两条路径共用：此前只有探测路径容忍 [IPv6] 写法，
# --ips "[2001:db8::1]" 会把方括号原样带进客户端配置，生成连不通的节点。
SPLIT_IPS=()
split_ip_list() { # <列表字符串>
    SPLIT_IPS=()
    [[ -n ${1:-} ]] || return 0
    local -a raw=()
    IFS=',' read -r -a raw <<< "$1"
    local x
    for x in "${raw[@]}"; do
        x="${x// /}"
        x="${x//[\[\]]/}"
        [[ -n $x ]] || continue
        # 只接受地址字面量：手滑写成 --ips 1.2.3.4:443 或域名时，
        # 会被原样写进节点 server 与订阅链接，生成必然连不通的配置。
        if is_ipv4_addr "$x" || is_ipv6_addr "$x"; then
            SPLIT_IPS+=("$x")
        else
            warn "忽略非法地址「${x}」：--ips / IP_LIST 只接受 IPv4 / IPv6 字面量（不要带端口或协议头）"
        fi
    done
    return 0
}

# 收集本机 scope global 地址
collect_local_addrs() {
    local addr
    while read -r addr; do
        addr="${addr%%/*}"
        if [[ -n $addr ]]; then printf '%s\n' "$addr"; fi
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}')
    # 只排除 temporary/deprecated/tentative。
    # temporary 才是 RFC4941 会轮换的隐私地址；带 mngtmpaddr 标记的恰恰是"稳定"的那个
    # （mngtmpaddr = 用于生成临时地址的模板地址），过滤它反而会留下会失效的节点。
    while read -r addr; do
        addr="${addr%%/*}"
        if [[ -n $addr && $addr != fe80* ]]; then printf '%s\n' "$addr"; fi
    done < <(ip -6 -o addr show scope global 2>/dev/null \
             | grep -vE 'temporary|deprecated|tentative' | awk '{print $4}')
}

# 优先级：--ips 显式指定  >  本机公网 scope global 地址  >  公网出口探测
#
# 关键：v4 与 v6 必须「分族独立判定」。
# 早期实现把两族塞进同一个 pub 数组，只要数组非空就整体采纳、整体跳过探测分支。
# 在容器 / NAT 机型上（本机 v6 是全局公网地址，v4 却是私网地址），
# 结果 v6 命中公网 → v4 的出口探测分支被整个跳过 → 客户端 outbounds 只剩 v6 节点。
# 现在每族各自走一遍「本机公网地址 → 出口探测」的判断，互不影响。
#
# 同时区分两个概念：
#   NODE_IPS  —— 对外公布的地址（写进客户端 outbounds / 分享链接）
#   BIND_MAP  —— 对外地址 → 本机可 bind 地址的映射（服务端 hy2 监听用）
# 二者在 NAT 场景下并不相同：出口探测拿到的是公网地址，客户端要连它，
# 但本机网卡上并没有这张卡，服务端只能 bind 本机的落地地址。
# 映射表默认为「查不到即用原地址」，因此直挂公网地址与 --ips 显式指定的场景
# 行为与从前完全一致。
declare -A BIND_MAP=()
detect_ips() {
    NODE_IPS=()
    BIND_MAP=()
    local x
    if [[ -n $IP_LIST ]]; then
        split_ip_list "$IP_LIST"
        NODE_IPS=("${SPLIT_IPS[@]}")
        # 用户显式指定的地址：视为本机自有，可直接 bind
    else
        local -a pub4=() pub6=() priv4=() priv6=()
        while read -r x; do
            [[ -z $x ]] && continue
            if [[ $x == *:* ]]; then
                if is_private_addr "$x"; then priv6+=("$x"); else pub6+=("$x"); fi
            else
                if is_private_addr "$x"; then priv4+=("$x"); else pub4+=("$x"); fi
            fi
        done < <(collect_local_addrs)

        local -a adv4=() adv6=()

        # --- v4 族 ---
        if [[ ${#pub4[@]} -gt 0 ]]; then
            adv4=("${pub4[@]}")
        elif [[ ${#priv4[@]} -gt 0 || ${#pub6[@]} -eq 0 ]]; then
            # 本机确有 v4 但网卡上不是全局地址（NAT 机型：私网地址 + 宿主 1:1 NAT）
            local e4; e4="$(get_public_ip_family 4)"
            if [[ -n $e4 ]]; then
                adv4+=("$e4")
                info "IPv4 本机网卡上只有私网地址，已通过出口探测获取公网地址：${e4}（客户端连这个）"
                # 服务端不能 bind 公网地址（本机没这张卡），要 bind 入站流量的实际落点
                local b4; b4="$(local_bind_addr 4 "${priv4[@]}")"
                [[ -n $b4 ]] && BIND_MAP["$e4"]="$b4"
            fi
        fi

        # --- v6 族 ---
        if [[ ${#pub6[@]} -gt 0 ]]; then
            adv6=("${pub6[@]}")
        elif [[ ${#priv6[@]} -gt 0 || ${#pub4[@]} -eq 0 ]]; then
            local e6; e6="$(get_public_ip_family 6)"
            if [[ -n $e6 ]]; then
                adv6+=("$e6")
                info "IPv6 本机网卡上只有本地地址，已通过出口探测获取公网地址：${e6}（客户端连这个）"
                local b6; b6="$(local_bind_addr 6 "${priv6[@]}")"
                [[ -n $b6 ]] && BIND_MAP["$e6"]="$b6"
            fi
        fi

        # 顺序固定为 v4 在前、v6 在后：客户端 tag 编号与 hy2 监听决策都依赖这个顺序
        NODE_IPS=("${adv4[@]}" "${adv6[@]}")

        local -a priv=("${priv4[@]}" "${priv6[@]}")
        if [[ ${#NODE_IPS[@]} -eq 0 && ${#priv[@]} -gt 0 ]]; then
            NODE_IPS=("${priv[@]}")
            warn "只探测到私网地址：${NODE_IPS[*]}；若这不是对外可达地址，请用 --ips 指定公网 IP"
        elif [[ ${#priv[@]} -gt 0 ]]; then
            info "自动忽略 ${#priv[@]} 个私网地址：${priv[*]}（要用请 --ips 显式指定）"
        fi
    fi
    # 去重
    local -A seen=()
    local -a out=()
    for x in "${NODE_IPS[@]}"; do
        if [[ -z ${seen[$x]:-} ]]; then seen[$x]=1; out+=("$x"); fi
    done
    NODE_IPS=("${out[@]}")
    if [[ ${#NODE_IPS[@]} -eq 0 ]]; then
        local pub_ip; pub_ip="$(get_public_ip)"
        if [[ -n $pub_ip ]]; then NODE_IPS=("$pub_ip"); fi
    fi
    return 0
}

# 取某族中「本机真实持有、且入站流量会落到它上面」的地址。
# 优先用默认路由的源地址：NAT 机型上，宿主把公网地址的入站流量
# DNAT 到本机默认路由所用的那张网卡，正是这个地址。
# 退化：取该族第一个私网地址；都没有则返回空（该族无可 bind 地址）。
local_bind_addr() { # <4|6> [候选私网地址...]
    local fam="$1"; shift
    local probe="1.1.1.1" src=""
    [[ $fam == 6 ]] && probe="2606:4700::1"
    src="$(ip -"$fam" route get "$probe" 2>/dev/null \
           | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    if [[ -n $src ]]; then printf '%s' "$src"; return 0; fi
    local a
    for a in "$@"; do
        [[ -z $a ]] && continue
        if [[ $fam == 6 ]]; then
            [[ $a == *:* ]] || continue
        else
            [[ $a == *:* ]] && continue
        fi
        printf '%s' "$a"; return 0
    done
    return 0
}

# ---------- NAT 机型检测与端口适配 ----------
# 能自动测出来的：本机 v4 网卡上没有任何全局地址、只有私网地址 → v4 必经宿主 NAT。
#   这是容器 / LXC / 共享出口 IP 的 NAT 小鸡最可靠的信号，不联网、不依赖出口探测，
#   也不受 --ips 显式指定影响。出口探测得到的公网地址与本机地址不一致
#   （BIND_MAP 非空）是第二条佐证。
# 测不出来的：服务商分配了哪几个外部端口、内外端口是否同号、v6 是否也受限。
#   容器里看不到宿主的端口转发表，也看不到面板配置 → 必须用户给 --nat-ports / --nat-map。
#   同理「v6 是独立公网、端口全开放」也只能由用户用 --nat-v6-open 声明，脚本不猜。
# 因此脚本只做几件确定不会错的事：
#   1) 自动关闭端口跳跃（默认 30000:50000 要两万个 UDP 端口，NAT 机不可能转发）
#      例外：--nat-v6-open 声明 v6 全开放时保留跳跃，但只对 v6 节点生效
#   2) 不擅自改 SSH 端口（改成未映射的端口会直接锁死登录）
#   3) 打印端口清单，并在给了 --nat-map 时把客户端 v4 端口换成外部端口
#   4) v4 端口不足时按 --nat-v4-services 只生成确实有端口可用的 v4 节点
NAT_ACTIVE=0
NAT_REASON=""
detect_nat() {
    NAT_ACTIVE=0; NAT_REASON=""
    case "${NAT_MODE:-auto}" in
        off)   return 0;;
        force) NAT_ACTIVE=1; NAT_REASON="由 --nat 显式指定"; return 0;;
    esac
    # 两族都声明端口全开放、且没有任何受限族配置 → 等同非 NAT 机，全部按原配置跑。
    if [[ ${NAT_V4_OPEN:-0} -eq 1 && ${NAT_V6_OPEN:-0} -eq 1 \
          && -z ${NAT_PORTS:-} && -z ${NAT_MAP:-} \
          && -z ${NAT_V6_PORTS:-} && -z ${NAT_V6_MAP:-} \
          && -z ${NAT_V4_SERVICES:-} && -z ${NAT_V6_SERVICES:-} ]]; then
        NAT_REASON="v4 / v6 均已声明端口全开放"
        return 0
    fi
    # 显式给了任一族的端口清单 / 映射表 / 开放声明 = 用户声明分族策略
    if [[ -n ${NAT_PORTS:-} || -n ${NAT_MAP:-} || -n ${NAT_V6_PORTS:-} || -n ${NAT_V6_MAP:-} \
          || ${NAT_V6_OPEN:-0} -eq 1 || ${NAT_V4_OPEN:-0} -eq 1 \
          || -n ${NAT_V4_SERVICES:-} || -n ${NAT_V6_SERVICES:-} ]]; then
        NAT_ACTIVE=1; NAT_REASON="已声明 v4 / v6 分族端口策略（--nat-* 参数）"; return 0
    fi
    local x n_pub4=0 n_priv4=0 sample=""
    while read -r x; do
        [[ -z $x || $x == *:* ]] && continue
        if is_private_addr "$x"; then
            n_priv4=$((n_priv4+1)); [[ -z $sample ]] && sample="$x"
        else
            n_pub4=$((n_pub4+1))
        fi
    done < <(collect_local_addrs)
    if [[ $n_pub4 -eq 0 && $n_priv4 -gt 0 ]]; then
        NAT_ACTIVE=1
        NAT_REASON="IPv4 网卡只有私网地址（如 ${sample}），无全局地址 → v4 经宿主 NAT"
        return 0
    fi
    # 兜底信号：出口探测拿到公网地址但本机 bind 不上（BIND_MAP 非空）。
    # 注意可达性：主流程里 detect_nat 跑在 detect_ips 之前，BIND_MAP 此时还是空的，
    # 这个分支实际触达不到 —— 主信号是上面的「v4 网卡只有私网地址」。
    # 保留它作为防御性兜底（未来若有调用方先跑过 detect_ips 再进来，它就能生效）。
    if [[ ${#BIND_MAP[@]} -gt 0 ]]; then
        NAT_ACTIVE=1
        NAT_REASON="对外地址与本机可 bind 地址不一致（出口探测拿到的是宿主公网 IP）"
    fi
    return 0
}
# 当前 sshd 实际监听端口（NAT 模式下不许脚本擅自改它）
current_ssh_port() {
    local p=""
    if command -v sshd >/dev/null 2>&1; then
        p="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2; exit}' || true)"
    fi
    # sshd -T 在容器里可能因缺 HostKey 失败，再用 ss 找一次 sshd 实际监听端口
    if [[ -z $p ]] && command -v ss >/dev/null 2>&1; then
        p="$(ss -tlnp 2>/dev/null \
             | awk '/sshd/ { for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/) { n=split($i,a,":"); print a[n]; exit } }' || true)"
    fi
    if [[ -z $p ]]; then
        warn "无法确认当前 SSH 监听端口，按 22 处理；请在面板确认 22 已转发，或用 --ssh-port 显式指定"
        p=22
    fi
    printf '%s' "$p"
}
# 离线渲染（--print-outbounds）：不读本机网卡、不打印日志，只用显式参数决定端口。
# 这条分支绝不能调用 info()/warn() —— 它们会污染 stdout 上的 JSON。
init_nat_for_render() {
    parse_nat_map "$NAT_MAP"
    parse_nat_map6 "$NAT_V6_MAP"
    NAT_ACTIVE=0; NAT_REASON=""
    [[ ${NAT_MODE:-auto} == force || -n ${NAT_MAP:-} || -n ${NAT_PORTS:-} \
       || -n ${NAT_V6_MAP:-} || -n ${NAT_V6_PORTS:-} \
       || ${NAT_V6_OPEN:-0} -eq 1 || ${NAT_V4_OPEN:-0} -eq 1 \
       || -n ${NAT_V4_SERVICES:-} || -n ${NAT_V6_SERVICES:-} ]] && NAT_ACTIVE=1
    [[ ${NAT_MODE:-auto} == off ]] && NAT_ACTIVE=0
    # 两族都声明全开放、且无受限族端口配置 → 按非 NAT 机处理（原配置）
    if [[ ${NAT_V4_OPEN:-0} -eq 1 && ${NAT_V6_OPEN:-0} -eq 1 \
          && -z ${NAT_PORTS:-} && -z ${NAT_MAP:-} \
          && -z ${NAT_V6_PORTS:-} && -z ${NAT_V6_MAP:-} \
          && -z ${NAT_V4_SERVICES:-} && -z ${NAT_V6_SERVICES:-} ]]; then
        NAT_ACTIVE=0
    fi
    # 只有「两族都受限」才清空跳跃；任一族全开放就保留，由 hop_range_for_ip() 只发给该族。
    if [[ $NAT_ACTIVE -eq 1 && ${NAT_V4_OPEN:-0} -eq 0 && ${NAT_V6_OPEN:-0} -eq 0 \
          && -n ${HOP_RANGE:-} && -z ${CLI_SET[HOP_RANGE]:-} ]]; then
        HOP_RANGE=""
    fi
    return 0
}
nat_port_report() { # 分族端口清单（stdout，供交付摘要 / --status）
    local k internal ext proto fam open spec svc
    printf '  分族端口策略（v4 / v6 独立判定）\n'
    for fam in v4 v6; do
        if [[ $fam == v4 ]]; then
            open="${NAT_V4_OPEN:-0}"; spec="${NAT_PORTS:-}"; svc="${NAT_V4_SERVICES:-}"
        else
            open="${NAT_V6_OPEN:-0}"; spec="${NAT_V6_PORTS:-}"; svc="${NAT_V6_SERVICES:-}"
        fi
        if [[ $open -eq 1 ]]; then
            printf '    %s：端口全开放 → 按原配置（服务端内部端口 + 端口跳跃）\n' "$fam"
            continue
        fi
        # 该族不开启端口转发映射：只列 SSH。继续列 vless / hy2 / fallback 会让人误以为
        # 还要去面板映射这些端口，而实际该族一个代理节点都不生成。
        if [[ $svc == ssh-only ]]; then
            local ext_ssh
            if [[ $fam == v4 ]]; then ext_ssh="${NAT_EXT[ssh]:-$SSH_PORT}"; else ext_ssh="${NAT_EXT6[ssh]:-$SSH_PORT}"; fi
            printf '    %s：不开启端口转发映射 → 只做管理、不跑代理（无代理节点）\n' "$fam"
            if [[ $ext_ssh == "$SSH_PORT" ]]; then
                printf '      ssh      TCP  %s（内外同号，唯一需要转发的端口）\n' "$SSH_PORT"
            else
                printf '      ssh      TCP  外部 %-6s → 内部 %s（唯一需要转发的端口）\n' "$ext_ssh" "$SSH_PORT"
            fi
            continue
        fi
        printf '    %s：受限，固定端口清单 [%s]\n' "$fam" "${spec:-未给，请自行确认已转发}"
        for k in vless hy2 fallback ssh; do
            case "$k" in
                vless)    internal="$VLESS_PORT";    proto="TCP" ;;
                hy2)      internal="$HY2_PORT";      proto="UDP" ;;
                fallback) internal="$FALLBACK_PORT"; proto="TCP" ;;
                ssh)      internal="$SSH_PORT";      proto="TCP" ;;
            esac
            if [[ $fam == v4 ]]; then ext="${NAT_EXT[$k]:-$internal}"; else ext="${NAT_EXT6[$k]:-$internal}"; fi
            if [[ $ext == "$internal" ]]; then
                printf '      %-9s %-4s %s（内外同号）\n' "$k" "$proto" "$internal"
            else
                printf '      %-9s %-4s 外部 %-6s → 内部 %s\n' "$k" "$proto" "$ext" "$internal"
            fi
        done
        if [[ -n $svc ]]; then
            printf '      %s 客户端节点仅生成：%s\n' "$fam" "$svc"
        fi
    done
    # 必须显式返回 0：循环体里可能有条件语句返回 1，函数在 set -e 下会中断调用者
    return 0
}
apply_nat_adaptation() {
    # 「只做管理」：不生成任何代理节点、不下发任何代理端口的防火墙规则，
    # 但 NAT 机的 SSH 端口仍必须保住（改成没映射的端口会永久锁死登录）。
    if [[ ${MANAGE_ONLY:-0} -eq 1 ]]; then
        parse_nat_map "$NAT_MAP"; parse_nat_map6 "$NAT_V6_MAP"
        detect_nat
        if [[ $NAT_ACTIVE -eq 1 && -z ${CLI_SET[SSH_PORT]:-} ]]; then
            local cur; cur="$(current_ssh_port)"
            if [[ -n $cur && $cur != "$SSH_PORT" ]]; then
                warn "NAT 机型：保持现有 SSH 端口 ${cur} 不改动（改成未映射的 ${SSH_PORT} 会锁死登录）"
                SSH_PORT="$cur"
            fi
        fi
        info "只做管理、不跑代理：跳过 NAT 代理端口适配（不生成 v4 / v6 节点、不下发防火墙规则）"
        return 0
    fi
    die_if_no_proxy_family        # 向导刚选的双 ssh-only 也必须在动系统前拦住
    parse_nat_map "$NAT_MAP"      # state.env 载入的映射也要生效
    parse_nat_map6 "$NAT_V6_MAP"
    detect_nat
    [[ $NAT_ACTIVE -eq 1 ]] || return 0
    info "检测到 NAT 机型：${NAT_REASON}"
    local v4open="${NAT_V4_OPEN:-0}" v6open="${NAT_V6_OPEN:-0}" x n4=0 n6=0

    # 1) SSH 端口：必须在端口清单校验与打印之前定下来，否则清单显示默认 51736，
    #    而模块 2 实际保持 22，两份信息对不上会误导人去面板映射错端口。
    if [[ -z ${CLI_SET[SSH_PORT]:-} ]]; then
        local cur; cur="$(current_ssh_port)"
        if [[ -n $cur && $cur != "$SSH_PORT" ]]; then
            warn "NAT 机型：保持现有 SSH 端口 ${cur} 不改动（改成未映射的 ${SSH_PORT} 会锁死登录）"
            SSH_PORT="$cur"
        fi
    fi

    # 2) 端口跳跃：只有「两族都受限」才清空；任一族全开放就保留，
    #    由 hop_range_for_ip() 与 m_firewall 只发给全开放的那一族。
    if [[ $v4open -eq 0 && $v6open -eq 0 ]]; then
        if [[ -n $HOP_RANGE && -z ${CLI_SET[HOP_RANGE]:-} ]]; then
            HOP_RANGE=""
            warn "v4 / v6 端口均受限，已自动关闭端口跳跃（默认 30000:50000 需要 2 万个 UDP 端口，宿主不会转发）"
            warn "若服务商确实转发了整段 UDP 端口，请显式传 --hop-range A:B 保留"
        elif [[ -n $HOP_RANGE ]]; then
            warn "已显式指定 --hop-range ${HOP_RANGE}：请确认服务商转发了整段 UDP 端口，否则 hy2 不可用"
            [[ -n ${NAT_EXT[hy2]:-} || -n ${NAT_EXT6[hy2]:-} ]] \
                && warn "跳跃模式下客户端用 server_ports 段，--nat-map / --nat-v6-map 里的 hy2 外部端口不会生效"
        fi
    else
        while read -r x; do
            [[ -z $x ]] && continue
            if [[ $x == *:* && $x != fe80:* ]]; then n6=$((n6+1))
            elif [[ $x != *:* ]]; then n4=$((n4+1)); fi
        done < <(collect_local_addrs)
        [[ -n ${IP_LIST:-} && $IP_LIST =~ [0-9]+\.[0-9]+ ]] && n4=1
        [[ -n ${IP_LIST:-} && $IP_LIST == *:* ]] && n6=1
        local open_fam=""
        [[ $v4open -eq 1 ]] && open_fam+="v4 "
        [[ $v6open -eq 1 ]] && open_fam+="v6"
        if [[ -n $HOP_RANGE ]]; then
            info "端口跳跃 ${HOP_RANGE} 只对全开放族生效：${open_fam}；受限族用固定外部端口"
            warn "端口跳跃依赖该协议族 iptables 的 nat 表；镜像裁剪时请改用 --no-hop"
        fi
        if (( v4open == 1 && n4 == 0 )); then
            warn "已声明 v4 端口全开放，但本机无 IPv4 地址、--ips 也未给 v4：v4 节点不会生成，跳跃实际不生效"
        fi
        if (( v6open == 1 && n6 == 0 )); then
            warn "已声明 v6 端口全开放，但本机无全局 IPv6 地址、--ips 也未给 v6：v6 节点不会生成，跳跃实际不生效"
        fi
    fi

    # 3) 固定端口清单校验：只提示，绝不擅自改端口（端口是服务商固定的，脚本猜不出来）。
    #    v4 / v6 各自用自己的清单；清单为空时 nat_ports_contains 直接返回 0。
    local fam k p ext spec svc hit other
    for fam in v4 v6; do
        if [[ $fam == v4 ]]; then
            [[ $v4open -eq 1 ]] && continue
            spec="$NAT_PORTS"; svc="$NAT_V4_SERVICES"
        else
            [[ $v6open -eq 1 ]] && continue
            spec="$NAT_V6_PORTS"; svc="$NAT_V6_SERVICES"
        fi
        hit=0
        for k in vless hy2 fallback ssh; do
            # 已声明 ssh-only 的族只核对 SSH，不再为代理服务刷无意义的转发提醒
            [[ $svc == ssh-only && $k != ssh ]] && continue
            case $k in vless) p=$VLESS_PORT;; hy2) p=$HY2_PORT;; fallback) p=$FALLBACK_PORT;; ssh) p=$SSH_PORT;; esac
            if [[ $fam == v4 ]]; then ext="${NAT_EXT[$k]:-$p}"; else ext="${NAT_EXT6[$k]:-$p}"; fi
            if nat_ports_contains "$ext" "$spec"; then
                [[ $k != ssh && -n $spec ]] && hit=1
            else
                warn "${fam} 固定端口清单 ${spec} 不含 ${k} 的外部端口 ${ext}；请到服务商面板确认该端口已转发"
            fi
        done
        if [[ $svc == ssh-only ]]; then
            warn "${fam} 已声明 ssh-only：该族不生成任何代理节点，外部端口只用于 SSH 登录"
        elif [[ -n $spec && $hit -eq 0 ]]; then
            # 单端口被 SSH 独占：TCP 上 SSH 与 vless 不能共用一个外部端口，该族物理上跑不了代理
            other="v6"; [[ $fam == v6 ]] && other="v4"
            warn "${fam} 固定端口清单 [${spec}] 不含任何可承载代理服务（vless / hy2 / fallback）的外部端口：该族目前只够 SSH 用"
            if [[ $fam == v4 && $v6open -eq 1 || $fam == v6 && $v4open -eq 1 ]]; then
                warn "  推荐：把 SSH 迁到全开放的 ${other} 族登录，把这个端口让给 vless（TCP），再加 --nat-${fam}-services vless"
                warn "  或该族彻底不跑代理：--nat-${fam}-services ssh-only，代理全部走 ${other} 族"
            else
                warn "  两族都没有可承载代理的端口，物理上无解：请让服务商增加外部端口"
            fi
        elif [[ -z $spec ]]; then
            warn "未给 ${fam} 固定端口清单（--nat-ports / --nat-v6-ports）：请确认 vless/hy2/fallback/SSH 端口都已转发"
        elif [[ $spec != *:* && -z $svc ]]; then
            local -a _ps=(); IFS=',' read -r -a _ps <<< "$spec"
            if (( ${#_ps[@]} < 4 )); then
                warn "${fam} 固定端口只有 ${#_ps[@]} 个：默认仍会为该族生成 vless + hy2 两个节点（另需 fallback / SSH）"
                warn "端口不够时用 --nat-${fam}-services vless 或 hy2 只保留一个协议的节点"
            fi
        fi
    done
    nat_port_report
    return 0
}

# ===== 交互式 NAT 端口配置向导 =====
# 服务商分了哪些端口、某族是否全开放，容器里都测不到 —— 这部分必须问用户。
# 设计约束：
#   - 只在真正的交互式运行（无 --yes / --modules）进入；离线渲染、--status、--self-test 一律不进入。
#   - 命令行已经把 NAT 策略说清楚 → 不打断（--nat-wizard 可强制重新配置）。
#   - 重跑且已保存过配置 → 默认保留，给「重新配置」入口，不每次都问一遍。
#   - 任何 read 结束（EOF / 非交互）都退回默认值，不无限循环。
#   - 结果写进 state.env，下次重跑沿用；「沿用旧配置」也不会被向导覆盖。
# 把多次输入的端口段拼成一份清单（纯函数，自检可直接断言）
nat_join_port_specs() { # <spec...>
    local out="" s
    for s in "$@"; do
        s="${s// /}"
        [[ -n $s ]] || continue
        [[ -n $out ]] && out+=","
        out+="$s"
    done
    printf '%s' "$out"
}
interactive_nat_wizard() {
    [[ ${NAT_WIZARD:-auto} == off ]] && return 0
    [[ -n ${ASSUME_YES:-} || -n ${MODULES_ARG:-} ]] && return 0
    # stdin 不可交互（/dev/null 等）时不询问、不写任何配置，直接沿用自动检测结果。
    # 交互终端 / 管道 / 输入文件都允许；EOF 也不会造成 read 死循环。
    [[ -t 0 || -p /dev/stdin || -f /dev/stdin ]] || return 0

    # 命令行已显式声明 NAT 策略 → 参数优先，不再打断（--nat-wizard 显式强制时除外）
    local k _declared=0
    for k in NAT_MODE NAT_PORTS NAT_MAP NAT_V4_OPEN NAT_V6_OPEN \
             NAT_V6_PORTS NAT_V6_MAP NAT_V4_SERVICES NAT_V6_SERVICES; do
        [[ -n ${CLI_SET[$k]:-} ]] && _declared=1
    done
    if [[ ${NAT_WIZARD:-auto} != on && $_declared -eq 1 ]]; then return 0; fi

    detect_nat
    local auto_nat="$NAT_ACTIVE" auto_reason="$NAT_REASON" x has_v6=0
    while read -r x; do [[ $x == *:* && $x != fe80:* ]] && has_v6=1; done < <(collect_local_addrs)
    [[ -n ${IP_LIST:-} && $IP_LIST == *:* ]] && has_v6=1

    hr
    printf '  %sNAT 端口配置向导%s（逐族选择，随时回车用默认值）\n' "$C_B" "$C_N"
    hr
    if [[ $auto_nat -eq 1 ]]; then
        printf '  自动检测：疑似 NAT 机 —— %s\n' "$auto_reason"
    else
        printf '  自动检测：未发现 NAT 特征（v4 网卡有全局地址）\n'
    fi
    printf '  IPv6 地址：%s\n' "$([[ $has_v6 -eq 1 ]] && echo '已检测到' || echo '未检测到')"
    printf '  规则：某族「端口全开放」→ 该族按原配置（默认服务端口 + 端口跳跃）；\n'
    printf '        「只开放固定端口」→ 交互式添加端口范围并分配各服务外部端口。\n'
    hr

    # ---- 整机级：是否在这台 NAT 机上开启端口转发映射、部署代理 ----
    # 选「否」就是「彻底只做管理、不跑代理」：后续 sing-box / v4、v6 节点 /
    # 代理端口与跳跃段的防火墙规则一律取消。只在向导检测到 NAT 时提供；
    # 非 NAT 机保持原有分族流程，不受影响。
    if [[ $auto_nat -eq 1 ]]; then
        local _mdef="y"; [[ ${MANAGE_ONLY:-0} -eq 1 ]] && _mdef="n"
        # 重跑时已保存过「只做管理」→ 默认沿用，不每次弹一遍
        if [[ ${NAT_WIZARD:-auto} != on && ${MANAGE_ONLY:-0} -eq 1 ]]; then
            info "已保存「只做管理、不跑代理」：本次沿用。恢复代理部署请加 --no-manage-only --nat-wizard"
            return 0
        fi
        hr
        printf '  是否开启端口转发映射，在这台机器上部署 sing-box 代理？\n'
        printf '    选 y → 继续逐族配置（v4 / v6 各自选全开放或固定端口），按原流程部署\n'
        printf '    选 n → 本机彻底只做管理、不跑代理（最省事、最安全）：\n'
        printf '            不装 sing-box，不生成 v4 / v6 节点与客户端配置，\n'
        printf '            不配置代理端口 / 端口跳跃的防火墙规则\n'
        hr
        if ! ask_yn "是否开启端口转发映射（部署代理）？" "$_mdef"; then
            MANAGE_ONLY=1
            info "已选择「不开启端口转发映射」：本次将取消全部代理部署，仅保留管理通道"
            save_state
            ok "「只做管理」已写入 ${STATE_FILE}（重跑沿用；恢复用 --no-manage-only --nat-wizard）"
            return 0
        fi
        MANAGE_ONLY=0
    fi

    # 重跑且已有配置：默认保留，避免每次执行都弹一遍。
    # SERVICES 也要算「已有配置」：v4/v6 设过 ssh-only 或单协议（OPEN=0、PORTS 为空）
    # 时，光看端口与 OPEN 会漏判，导致该族的特殊配置不被展示、也没机会重新配置。
    if [[ ${NAT_WIZARD:-auto} != on && -f $STATE_FILE \
          && ( -n ${NAT_PORTS:-} || -n ${NAT_V6_PORTS:-} \
               || ${NAT_V4_OPEN:-0} -eq 1 || ${NAT_V6_OPEN:-0} -eq 1 \
               || -n ${NAT_V4_SERVICES:-} || -n ${NAT_V6_SERVICES:-} ) ]]; then
        printf '  当前已保存的分族端口配置：\n'
        nat_port_report
        if ! ask_yn "是否重新配置 v4 / v6 端口？" n; then
            info "保留已保存的分族端口配置"
            return 0
        fi
    else
        local _def="n"; [[ $auto_nat -eq 1 ]] && _def="y"
        if ! ask_yn "是否现在配置 v4 / v6 的端口开放方式？" "$_def"; then
            info "跳过向导：按自动检测结果继续，全开放的族保持原配置"
            return 0
        fi
    fi

    local fam label def ans spec svc map _opt p defp
    for fam in v4 v6; do
        if [[ $fam == v4 ]]; then
            label="IPv4"; def="y"; [[ $auto_nat -eq 0 ]] && def="n"
            NAT_V4_SERVICES=""; NAT_PORTS=""; NAT_MAP=""
        else
            label="IPv6"; def="n"     # v6 通常是独立公网、端口全开放，保守默认
            NAT_V6_SERVICES=""; NAT_V6_PORTS=""; NAT_V6_MAP=""
        fi
        hr
        # 该族是否开启端口转发映射：选「否」= 该族彻底只做管理，不出任何代理节点。
        # 复用 ssh-only 语义，因此 CLI / state.env / 渲染路径的行为完全一致。
        if ! ask_yn "是否为 ${label} 开启端口转发映射（该族跑代理）？" y; then
            if [[ $fam == v4 ]]; then
                NAT_V4_OPEN=0; NAT_V4_SERVICES="ssh-only"; NAT_PORTS=""; NAT_MAP=""
            else
                NAT_V6_OPEN=0; NAT_V6_SERVICES="ssh-only"; NAT_V6_PORTS=""; NAT_V6_MAP=""
            fi
            info "${label}：不开启端口转发映射 → 该族只做管理，不生成任何代理节点"
            continue
        fi
        if ! ask_yn "${label} 是否只开放了服务商分配的固定端口（受限）？" "$def"; then
            if [[ $fam == v4 ]]; then
                NAT_V4_OPEN=1
            else
                NAT_V6_OPEN=1
            fi
            info "${label}：端口全开放 → 按原配置（默认服务端口 + 端口跳跃）"
            continue
        fi
        if [[ $fam == v4 ]]; then NAT_V4_OPEN=0; else NAT_V6_OPEN=0; fi

        # ---- 交互式添加端口范围 / 离散端口（可多次添加，回车结束）----
        _opt="--nat-ports"; [[ $fam == v6 ]] && _opt="--nat-v6-ports"
        printf '  %s 固定端口：每次输入一段，直接回车结束。\n' "$label"
        printf '    支持 单端口 30443 / 离散 30022,30443 / 连续段 20000:20020 / 混合写法\n'
        local -a _items=()
        while true; do
            ans="$(ask "添加${label}端口范围（回车结束）" "")"
            [[ -z $ans ]] && break
            if ! ( need_nat_ports "$ans" "$_opt" ) 2>/dev/null; then
                warn "格式不合法，请重新输入（示例：20000:20020 或 30443 或 30022,30443）"
                continue
            fi
            _items+=("$ans")
        done
        spec="$(nat_join_port_specs "${_items[@]}")"
        [[ -n $spec ]] || warn "未添加任何 ${label} 端口：后续会按内外同号处理，请自行到面板确认转发"

        # ---- 交互式为各服务选择外部端口 ----
        printf '  为 %s 的每个服务指定外部端口；内外同号就直接回车。\n' "$label"
        map=""; svc=""
        for k in vless hy2 fallback ssh; do
            case $k in
                vless) defp="$VLESS_PORT";; hy2) defp="$HY2_PORT";;
                fallback) defp="$FALLBACK_PORT";; ssh) defp="$SSH_PORT";;
            esac
            while true; do
                p="$(ask "${label} ${k} 外部端口" "$defp")"
                if ! is_port "$p"; then warn "端口必须是 1-65535 的整数"; continue; fi
                break
            done
            [[ $p != "$defp" ]] && { [[ -n $map ]] && map+=","; map+="${k}=${p}"; }
            [[ -n $spec ]] && { nat_ports_contains "$p" "$spec" \
                || warn "${p} 不在刚添加的 ${label} 端口清单 [${spec}] 内，请到面板确认该端口已转发"; }
        done

        # ---- 端口太少时：可只跑 SSH（不出代理节点），或只保留一个协议 ----
        if [[ -n $spec && $spec != *:* ]]; then
            local -a _ps=(); IFS=',' read -r -a _ps <<< "$spec"
            if (( ${#_ps[@]} < 2 )); then
                if ask_yn "${label} 只有一个端口：是否让该族只跑 SSH、完全不生成代理节点？" n; then
                    svc="ssh-only"
                    info "${label}：设为 ssh-only，外部端口只用于 SSH 登录，该族不出代理节点"
                elif ask_yn "是否只保留一个协议的节点（避免下发连不上的节点）？" n; then
                    svc="$(ask "只保留 vless 还是 hy2" "vless")"
                    svc="${svc,,}"; [[ $svc == hy2 ]] || svc="vless"
                fi
            fi
        fi

        if [[ $fam == v4 ]]; then
            NAT_PORTS="$spec"; NAT_MAP="$map"; NAT_V4_SERVICES="$svc"
        else
            NAT_V6_PORTS="$spec"; NAT_V6_MAP="$map"; NAT_V6_SERVICES="$svc"
        fi
        info "${label}：受限，端口清单 [${spec:-未给}]，映射 [${map:-内外同号}]"
    done

    # 两族都选「不开启端口转发映射」→ 整机没有任何族能跑代理，
    # 自动升级成整机「只做管理」，让 sing-box / 防火墙 / 客户端配置也一并取消。
    # （CLI 直接写两族 ssh-only 仍按上一轮规则报错，只有向导里的明确表态才升级。）
    if [[ ${NAT_V4_SERVICES:-} == ssh-only && ${NAT_V6_SERVICES:-} == ssh-only ]]; then
        MANAGE_ONLY=1; NAT_MODE=force
        info "v4 / v6 都选择只做管理 → 整机进入「只做管理」模式：sing-box / 防火墙 / 客户端配置全部取消"
    elif [[ ${NAT_V4_OPEN:-0} -eq 1 && ${NAT_V6_OPEN:-0} -eq 1 ]]; then
        NAT_MODE=off
        info "v4 / v6 均端口全开放：整体按非 NAT 机处理（原配置）"
    else
        NAT_MODE=force
        info "分族端口配置完成：v4 $([[ ${NAT_V4_OPEN:-0} -eq 1 ]] && echo '全开放' || echo '受限')；v6 $([[ ${NAT_V6_OPEN:-0} -eq 1 ]] && echo '全开放' || echo '受限')"
    fi
    parse_nat_map "$NAT_MAP"; parse_nat_map6 "$NAT_V6_MAP"
    save_state
    ok "分族端口配置已写入 ${STATE_FILE}（重跑沿用；交互时可加 --nat-wizard 重新配置）"
    # 整机只做管理时不打印代理端口清单：两族都为空，只会刷「未给，请自行确认」的误导信息。
    [[ ${MANAGE_ONLY:-0} -eq 1 ]] || nat_port_report
    return 0
}

# ---------- §13 服务端入站 ----------
# 决策：vless 走 TCP，多 IP 下监听 :: 天然没问题，永远只要一个。
# hy2 走 UDP，监听 :: 时若同族存在 ≥2 个地址，内核无法为每地址选对回程源 IP，
#   客户端会握手成功但随即超时 → 此时才需按 IP 逐个监听。
# 单 IP 一律不写公网 IP：只有单个 v4 时用 0.0.0.0（IPv4 通配），
#   含 v6 时（单 v6 或 v4+v6 各一）用 ::（双栈通配）。
# 下面两个渲染函数全部经由 §12 构造器输出，函数名后缀 -in 与客户端 -out 区分。
json_hy2_inbound() { # <listen> <index>
    local listen="$1" idx="$2"
    [[ -n $listen ]] || die "内部错误：json_hy2_inbound 的 listen 为空"

    local -a m=()
    m+=("$(j_kv type hysteria2)")
    m+=("$(j_kv tag "hy2-in-${idx}")")
    m+=("$(j_kv listen "$listen")")
    m+=("$(j_lit listen_port "$HY2_PORT")")
    m+=("\"users\": $(j_arr '            ' \
        "$(j_obj '                ' "$(j_kv password "$HY2_PW")")")")
    if [[ -n $SB_UP_MBPS && -n $SB_DOWN_MBPS ]]; then
        m+=("$(j_lit up_mbps "$SB_UP_MBPS")")
        m+=("$(j_lit down_mbps "$SB_DOWN_MBPS")")
    else
        m+=("$(j_lit ignore_client_bandwidth false)")
    fi
    m+=("\"obfs\": $(j_obj '            ' \
        "$(j_kv type salamander)" \
        "$(j_kv password "$OBFS_PW")")")
    m+=("\"tls\": $(j_obj '            ' \
        "$(j_lit enabled true)" \
        "\"alpn\": $(j_arr '                ' '"h3"')" \
        "$(j_kv certificate_path "${SB_DIR}/cert.crt")" \
        "$(j_kv key_path "${SB_DIR}/private.key")")")
    j_obj '        ' "${m[@]}"
}

json_vless_inbound() { # <listen> <index>
    local listen="$1" idx="$2"
    [[ -n $listen ]] || die "内部错误：json_vless_inbound 的 listen 为空"

    local -a m=()
    m+=("$(j_kv type vless)")
    m+=("$(j_kv tag "vless-in-${idx}")")
    m+=("$(j_kv listen "$listen")")
    m+=("$(j_lit listen_port "$VLESS_PORT")")
    m+=("\"users\": $(j_arr '            ' \
        "$(j_obj '                ' \
            "$(j_kv uuid "$UUID")" \
            "$(j_kv flow xtls-rprx-vision)")")")
    m+=("\"tls\": $(j_obj '            ' \
        "$(j_lit enabled true)" \
        "$(j_kv server_name "$REALITY_SNI")" \
        "\"reality\": $(j_obj '                ' \
            "$(j_lit enabled true)" \
            "\"handshake\": $(j_obj '                    ' \
                "$(j_kv server "$REALITY_DEST")" \
                "$(j_lit server_port "$REALITY_DEST_PORT")")" \
            "$(j_kv private_key "$REALITY_PRIV")" \
            "\"short_id\": $(j_arr '                    ' \
                "\"$(json_escape "$SHORT_ID")\"")")")")
    j_obj '        ' "${m[@]}"
}

# ---------- §13 通用监听地址 ----------
# 有些精简镜像把 IPv6 在内核里关掉了，此时 bind "::" 会失败、sing-box 直接起不来，
# 统一走这个入口退化为 "0.0.0.0"。判断不了时（非 Linux / 无该 proc 节点）按可用处理。
LISTEN_ANY=""
listen_any() {
    if [[ -z $LISTEN_ANY ]]; then
        local f=/proc/sys/net/ipv6/conf/all/disable_ipv6
        if [[ -r $f && $(<"$f") == 1 ]]; then LISTEN_ANY="0.0.0.0"; else LISTEN_ANY="::"; fi
    fi
    printf '%s' "$LISTEN_ANY"
}
LISTEN_ANY="$(listen_any)"

# hy2 需要哪些 listen 地址？
#   返回全局 HY2_LISTEN_ADDRS[]，并置 HY2_SPLIT_BY_IP：
#     1 = 按 IP 逐个监听（仅同族多地址时）；0 = 单一本地/通配地址。
#   原则：**单 IP 一律不写公网 IP**，只有同族出现 ≥2 个地址才按 IP 指定。
#     只有单个 v4（无 v6）        → 0.0.0.0（IPv4 通配，本机地址族，外部可达）
#     单 v6 / v4+v6 各一个        → ::  （IPv6 内核不可用时 listen_any 退化为 0.0.0.0）
#     同族 ≥2 个（多 v4 / 多 v6）→ 按 IP 逐个监听
#   为什么多地址才拆分：hy2 走 UDP，同族多个地址时内核无法为每个目标地址选对
#     回程源 IP，客户端会握手成功但随即超时。
#   按 IP 监听时，真正写进 listen 的地址用 bind_addr_for() 换成本机真实持有的那张卡：
#     NAT 机型上对外公布的是出口探测到的公网地址，本机并没有这张卡，
#     直接拿它当 listen 会 EADDRNOTAVAIL，让 sing-box 起不来。
#   注意：单 IP 场景不能监听 127.0.0.1 —— 外部包的目的 IP 是网卡地址，
#     而端口跳跃 DNAT 只改端口不改 IP，回环入站收不到，节点会外部不可达。
HY2_LISTEN_ADDRS=()
HY2_SPLIT_BY_IP=0
hy2_listen_addrs() {
    HY2_LISTEN_ADDRS=()
    HY2_SPLIT_BY_IP=0
    # BIND_ALL 只接受 0 / 1（validate_settings 已挡其它值）：不能用 -n 判真，
    # 否则默认值 "0" 会被当成「强制通配」，多 IP 机器的 hy2 拆分监听永远不触发。
    if [[ ${BIND_ALL:-} == 1 || ${#NODE_IPS[@]} -eq 0 ]]; then
        HY2_LISTEN_ADDRS=("$(listen_any)"); return 0
    fi
    local n4=0 n6=0 x
    for x in "${NODE_IPS[@]}"; do
        if [[ $x == *:* ]]; then n6=$((n6+1)); else n4=$((n4+1)); fi
    done
    if [[ $n4 -gt 1 || $n6 -gt 1 ]]; then
        HY2_SPLIT_BY_IP=1
        for x in "${NODE_IPS[@]}"; do
            HY2_LISTEN_ADDRS+=("$(bind_addr_for "$x")")
        done
    elif [[ $n6 -eq 0 && $n4 -ge 1 ]]; then
        # 只有单个 IPv4：IPv4 通配，绝不把公网 IPv4 写进 listen
        HY2_LISTEN_ADDRS=("0.0.0.0")
    else
        # 含 v6（单 v6 或 v4+v6 各一）：双栈通配，同样不含公网 IP
        HY2_LISTEN_ADDRS=("$(listen_any)")
    fi
    return 0
}

# 对外公布的地址 → 本机可 bind 的地址。
# 默认返回原地址（--ips 显式指定、以及本机直挂公网地址的情形）；
# 只有 NAT 机型下「出口探测得到的公网地址」才需要换成实际的落地地址。
bind_addr_for() { # <对外地址>
    local ip="$1"
    if [[ -n ${BIND_MAP[$ip]:-} ]]; then printf '%s' "${BIND_MAP[$ip]}"; else printf '%s' "$ip"; fi
}

render_config() {
    local -a parts=()
    local i addr
    # vless：永远单一入站即可
    parts+=("$(json_vless_inbound "$(listen_any)" 0)")
    # hy2：仅在同族多地址时按 IP 拆分；单 IP 用本地/通配地址，tag 固定 hy2-in-0。
    # 是否拆分看 HY2_SPLIT_BY_IP，不要比较地址字符串（单 v4 的 0.0.0.0 != :: 会误判）。
    hy2_listen_addrs
    for i in "${!HY2_LISTEN_ADDRS[@]}"; do
        addr="${HY2_LISTEN_ADDRS[$i]}"
        if [[ ${HY2_SPLIT_BY_IP:-0} -eq 0 ]]; then
            parts+=("$(json_hy2_inbound "$addr" 0)")
        else
            parts+=("$(json_hy2_inbound "$addr" "$((i+1))")")
        fi
    done
    j_obj '' \
        "\"log\": $(j_obj '    ' "$(j_kv level info)" "$(j_lit timestamp true)")" \
        "\"inbounds\": $(j_arr '    ' "${parts[@]}")" \
        "\"outbounds\": $(j_arr '    ' \
            "$(j_obj '        ' "$(j_kv type direct)" "$(j_kv tag direct)")")" \
        "\"route\": $(j_obj '    ' \
            "\"rules\": $(j_arr '        ' \
                "$(j_obj '            ' "$(j_kv action sniff)" "$(j_kv timeout 300ms)")")")"
    printf '\n'
}

# ---------- §13 客户端出站 ----------
# 生成每个 IP 对应的 tag，写入全局 T_HY2[] / T_VL[]（与 NODE_IPS 同序）
# tag 形如 "<机房城市> v4-vl" / "<机房城市> v6.1-hy2"：
#   前缀 = 机房所在城市（自动识别，见 detect_location），或用户显式给的 --node-name
#   中段 = v4 / v6；同族有多个地址时才加序号，且用点号分隔（v6.1 / v6.2 / v6.3）
#   后缀 = -vl / -hy2
T_HY2=(); T_VL=(); NODE_PREFIX=""
build_node_tags() {
    # 同一进程内已算过就跳过：m_summary 先算一次，render_client_outbounds 内部还会再调一次。
    # 第二次若发生在 $(...) 子 shell 里，机房识别失败时的手动输入只会写进子 shell，
    # 父 shell 的 save_state 又把 NODE_NAME 覆盖回空值 —— 等于白问一场。
    if [[ ${NODE_TAGS_READY:-0} -eq 1 && ${#T_VL[@]} -eq ${#NODE_IPS[@]} ]]; then return 0; fi
    T_HY2=(); T_VL=(); NODE_PREFIX=""
    local n4=0 n6=0 i4=0 i6=0 x base
    # 前缀按「主地址」判定一次，所有节点共用：
    # 同一台机器的 v4/v6 通常落在同一机房，逐个查反而会得到两套名字。
    # 必须在当前 shell 执行：识别失败时的手动输入会写 NODE_NAME 并 save_state，
    # 用 $(...) 捕获输出会把这些改动关进子 shell，随后父 shell 的 save_state
    # 会把刚落盘的节点名又覆盖回空值。
    node_prefix "${NODE_IPS[0]:-}" >/dev/null || true
    local prefix="${NODE_PREFIX_RESULT:-}"
    [[ -n $prefix ]] || prefix="$(sanitize_name "$(hostname 2>/dev/null || echo vps)")"
    NODE_PREFIX="$prefix"
    for x in "${NODE_IPS[@]}"; do
        if [[ $x == *:* ]]; then n6=$((n6+1)); else n4=$((n4+1)); fi
    done
    for x in "${NODE_IPS[@]}"; do
        if [[ $x == *:* ]]; then
            i6=$((i6+1)); base="v6"
            if [[ $n6 -gt 1 ]]; then base="v6.${i6}"; fi
        else
            i4=$((i4+1)); base="v4"
            if [[ $n4 -gt 1 ]]; then base="v4.${i4}"; fi
        fi
        T_HY2+=("${prefix} ${base}-hy2")
        T_VL+=("${prefix} ${base}-vl")
    done
    NODE_TAGS_READY=1
    return 0
}

json_hy2_out() { # <ip> <tag>
    local ip="$1" tag="$2"
    [[ -n $ip ]] || die "内部错误：json_hy2_out 的 ip 为空"

    local -a m=()
    # server 用域名；端口与跳跃段仍按真实 IP 的地址族判定（NAT 分族端口不能按域名算）。
    local host; host="$(client_host_for "$ip")"
    local hop; hop="$(hop_range_for_ip "$ip")"
    m+=("$(j_kv type hysteria2)")
    m+=("$(j_kv tag "$tag")")
    m+=("$(j_kv server "$host")")
    if [[ -n $hop ]]; then
        m+=("\"server_ports\": $(j_arr '            ' "\"$(json_escape "$hop")\"")")
    else
        # 整机受限 NAT：v4 连宿主转发的外部端口；v6 受限时也连内部端口。
        # v6 全开放的 NAT 机：v4 只有少量固定端口，绝不套用 v6 的跳跃段。
        m+=("$(j_lit server_port "$(client_port_for hy2 "$ip")")")
    fi
    [[ -n $UP_MBPS ]]   && m+=("$(j_lit up_mbps "$UP_MBPS")")
    [[ -n $DOWN_MBPS ]] && m+=("$(j_lit down_mbps "$DOWN_MBPS")")
    # 跳跃间隔只在真的启用跳跃时才有意义，否则客户端会拿着一个无处生效的字段
    [[ -n $hop && -n $HOP_INTERVAL     ]] && m+=("$(j_kv hop_interval "$HOP_INTERVAL")")
    [[ -n $hop && -n $HOP_INTERVAL_MAX ]] && m+=("$(j_kv hop_interval_max "$HOP_INTERVAL_MAX")")
    m+=("$(j_kv password "$HY2_PW")")
    m+=("\"obfs\": $(j_obj '            ' \
        "$(j_kv type salamander)" \
        "$(j_kv password "$OBFS_PW")")")

    # 自签证书：有指纹就 pin，没有才降级 insecure —— 与分享链接保持同一套策略
    local -a tls=()
    tls+=("$(j_lit enabled true)")
    tls+=("$(j_kv server_name "$CERT_CN")")
    if [[ -n $CERT_HASH ]]; then
        tls+=("$(j_lit insecure false)")
        # sing-box 1.13+ 的 certificate_public_key_sha256 是字符串数组（SHA-256 指纹列表），
        # 渲染成裸字符串会让客户端 unmarshal 失败、整份配置被拒绝
        tls+=("\"certificate_public_key_sha256\": $(j_arr '                ' "\"$(json_escape "$CERT_HASH")\"")")
    else
        tls+=("$(j_lit insecure true)")
    fi
    tls+=("\"alpn\": $(j_arr '                ' '"h3"')")
    m+=("\"tls\": $(j_obj '            ' "${tls[@]}")")
    j_obj '        ' "${m[@]}"
}

json_vless_out() { # <ip> <tag>
    local ip="$1" tag="$2"
    [[ -n $ip ]] || die "内部错误：json_vless_out 的 ip 为空"

    # server 用域名；server_port 仍按真实 IP 的地址族取 NAT 映射端口。
    local host; host="$(client_host_for "$ip")"
    local -a m=()
    m+=("$(j_kv type vless)")
    m+=("$(j_kv tag "$tag")")
    [[ -n $TCP_KEEP_ALIVE          ]] && m+=("$(j_kv tcp_keep_alive "$TCP_KEEP_ALIVE")")
    [[ -n $TCP_KEEP_ALIVE_INTERVAL ]] && m+=("$(j_kv tcp_keep_alive_interval "$TCP_KEEP_ALIVE_INTERVAL")")
    m+=("$(j_kv uuid "$UUID")")
    m+=("$(j_kv flow xtls-rprx-vision)")
    m+=("$(j_kv packet_encoding xudp)")
    m+=("$(j_kv server "$host")")
    m+=("$(j_lit server_port "$(client_port_for vless "$ip")")")
    m+=("\"tls\": $(j_obj '            ' \
        "$(j_lit enabled true)" \
        "$(j_kv server_name "$REALITY_SNI")" \
        "\"utls\": $(j_obj '                ' \
            "$(j_lit enabled true)" \
            "$(j_kv fingerprint chrome)")" \
        "\"reality\": $(j_obj '                ' \
            "$(j_lit enabled true)" \
            "$(j_kv public_key "$REALITY_PUB")" \
            "$(j_kv short_id "$SHORT_ID")")")")
    j_obj '        ' "${m[@]}"
}

# 客户端 outbounds：每个 IP 一组（vless + hy2），tag 形如 "<城市> v4-vl" / "<城市> v6.1-hy2"
# 顺序：先全部 vless，再全部 hy2（vless 是主力协议，排在前面更好找）
render_client_outbounds() {
    # 位置参数分支已删除：全部 4 处调用都无参，而一旦有人传参会悄悄覆盖全局 NODE_IPS，
    # 破坏依赖全量列表的调用方（如 m_summary 的分族循环）—— 与其留陷阱不如删掉。
    if [[ ${#NODE_IPS[@]} -eq 0 ]]; then NODE_IPS=("<服务器IP>"); fi
    build_node_tags
    local prefix="${NODE_PREFIX}"
    [[ -n $prefix ]] || prefix="$(sanitize_name "$(hostname 2>/dev/null || echo vps)")"

    # v4 端口不足时可以只生成部分协议的 v4 节点；tag 仍按 NODE_IPS 全量构建以保持索引对齐，
    # 这里只挑出真正要下发的索引。顺序不变：先全部 vless，再全部 hy2。
    local -a sel=() parts=() vl_i=() hy_i=()
    local i x
    for i in "${!NODE_IPS[@]}"; do
        nat_ip_needs "${NODE_IPS[$i]}" vless && vl_i+=("$i")
        nat_ip_needs "${NODE_IPS[$i]}" hy2  && hy_i+=("$i")
    done
    # 两族都被过滤（例如都声明 ssh-only）时配置物理无解：直接报错，
    # 绝不靠保底硬塞一个注定连不上的节点、还让 selector 默认指向它。
    if (( ${#vl_i[@]} + ${#hy_i[@]} == 0 )); then
        die "没有任何地址族能承载代理节点（v4 / v6 均为 ssh-only 或全被过滤）：请至少保留一族可跑代理，或让服务商增加外部端口；单端口被 SSH 独占时可把 SSH 迁到另一族、把该端口让给 vless"
    fi
    for i in "${vl_i[@]}";  do sel+=("\"$(json_escape "${T_VL[$i]}")\""); done
    for i in "${hy_i[@]}";  do sel+=("\"$(json_escape "${T_HY2[$i]}")\""); done
    for i in "${vl_i[@]}";  do parts+=("$(json_vless_out "${NODE_IPS[$i]}" "${T_VL[$i]}")"); done
    for i in "${hy_i[@]}";  do parts+=("$(json_hy2_out "${NODE_IPS[$i]}" "${T_HY2[$i]}")"); done

    # selector：默认走第一个实际生成的 vless（若只生成 hy2 则退到第一个 hy2）
    local def d0="${vl_i[0]:-}" h0="${hy_i[0]:-}"
    if [[ -n $d0 ]]; then def="${T_VL[$d0]}"; else def="${T_HY2[$h0]}"; fi
    local selector; selector="$(j_obj '        ' \
        "$(j_kv type selector)" \
        "$(j_kv tag "${prefix} select")" \
        "\"outbounds\": $(j_arr '            ' "${sel[@]}")" \
        "$(j_kv default "$def")")"

    j_obj '' "\"outbounds\": $(j_arr '    ' "$selector" "${parts[@]}")"
    printf '\n'
}

m_genconfig() {
    info "==> [8] 生成 sing-box 配置"
    # 「沿用旧配置」：config.json 一个字节都不动 —— 不备份、不写 .new、不 mv、不重启服务。
    # 只做一次只读校验，把现有配置是否健康告诉用户。
    if [[ ${RERUN_MODE:-} == keep ]] && [[ -s $SB_CONF ]]; then
        if command -v sing-box >/dev/null 2>&1 && sing-box check -c "$SB_CONF" >/dev/null 2>&1; then
            ok "沿用旧配置：${SB_CONF} 保持原样（未覆盖、未备份、未重启服务），现有凭据全部保留"
        else
            warn "沿用旧配置：${SB_CONF} 无法校验或校验未通过；本次仍未改动任何文件，需要重建请选「生成新配置」"
        fi
        return 0
    fi
    validate_settings
    command -v sing-box >/dev/null || die "未安装 sing-box，请先执行模块 6"
    # 五个凭据一个都不能少：缺 hy2 密码/obfs 密码/Reality 公钥时渲染出的 config.json
    # 检查能过（字段缺失对 sing-box 是合法 schema），但节点必然握手失败。
    # 在渲染前就拦住并指向模块 6，而不是等用户客户端连不上再回头排查。
    [[ -n $UUID && -n $REALITY_PRIV ]] || die "缺少凭据（UUID / Reality 私钥），请先执行模块 6"
    [[ -n $REALITY_PUB ]]             || die "缺少凭据（Reality 公钥），请先执行模块 6"
    [[ -n $HY2_PW && -n $OBFS_PW ]]   || die "缺少凭据（hy2 / obfs 密码），请先执行模块 6"
    [[ -n $REALITY_SNI && -n $REALITY_DEST ]] || die "缺少 Reality 目标，请先执行模块 7"

    detect_ips
    if [[ ${#NODE_IPS[@]} -eq 0 ]]; then
        warn "未探测到任何 IP，入站将监听通配地址（多 IP 机器请用 --ips 指定）"
    else
        info "检测到 ${#NODE_IPS[@]} 个地址：${NODE_IPS[*]}"
        hy2_listen_addrs
        local hv="${#HY2_LISTEN_ADDRS[@]}" la; la="$(listen_any)"
        if [[ ${HY2_SPLIT_BY_IP:-0} -eq 0 ]]; then
            info "vless 监听 ${la} (单实例)；hy2 同族地址各 ≤1，监听 ${HY2_LISTEN_ADDRS[0]}（单实例，未绑定公网 IP）"
        else
            info "vless 监听 ${la} (单实例)；hy2 检测到同族多地址（≥2 个 v4 或 ≥2 个 v6），需按 IP 逐个监听 ${hv} 个入站"
        fi
    fi

    if [[ -z $PRINT_CONFIG && -f $SB_CONF ]]; then
        # 备份轮转：只保留最近 5 份 —— 历史配置内含监听端口/证书路径等敏感信息，
        # 无上限累积既占空间又扩大泄露面
        rotate_old_baks '/root/.vps-init.config.json.*.bak'
        cp -a "$SB_CONF" "/root/.vps-init.config.json.$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null || true
    fi
    # 先写临时文件、sing-box check 通过后再替换：渲染中途失败不会把正在运行的
    # config.json 截断成半截 JSON —— 重跑时这会让 sing-box 直接起不来。
    local cfg_new="${SB_CONF}.new"
    # umask 077：.new 里已是完整服务端配置（含凭据），不能按默认 umask 落盘
    if ! ( umask 077; render_config > "$cfg_new" ); then
        err "配置渲染失败，原配置保持不变"; rm -f "$cfg_new"
        warn_state_config_divergence
        return 1
    fi
    # 渲染链里的 die 跑在命令替换的子 shell 中，只终止子 shell，父进程可能拿到
    # 半截输出（那一行变空、后续照常拼）。这里先做一次零依赖结构自检，
    # 免得用户面对 sing-box check 的一句难懂解析报错。
    if ! json_balance_ok "$(cat "$cfg_new")"; then
        err "渲染结果不是合法 JSON（括号/引号不配平），原配置保持不变；新内容留在 ${cfg_new} 供排查"
        warn_state_config_divergence
        return 1
    fi
    chmod 600 "$cfg_new"
    if ! sing-box check -c "$cfg_new"; then
        err "配置校验失败，原配置保持不变（新内容留在 ${cfg_new} 供排查）"
        warn_state_config_divergence
        return 1
    fi
    mv -f "$cfg_new" "$SB_CONF"
    ok "配置校验通过：${SB_CONF}"

    systemctl enable --now sing-box >/dev/null
    systemctl restart sing-box
    sleep 2
    if ! { systemctl is-active --quiet sing-box; }; then
        # 这里 config.json 已是新凭据（mv 已完成），只是服务没起来：
        # 与渲染/校验失败不同，此时 keep 重跑反而能按新配置校验并启动。
        err "sing-box 未启动，日志：journalctl -u sing-box -e"
        warn "config.json 已更新为新凭据但服务未运行：修复后重跑选「沿用旧配置」即可按新配置校验并启动"
        warn "交付文件（vps-init.info / client-outbounds.json）仍是旧凭据（模块 9 未执行）；若放弃新配置回滚 config.json，旧交付文件恰好有效，若保留新配置请重跑 --modules 9 刷新"
        return 1
    fi
    ok "sing-box 运行中"
    # 配置已按新凭据写入并通过校验、服务已起：分叉解除（含跨进程遗留的旧标记）
    SB_STATE_AHEAD=0
    save_state
}

# ============================================================
# 9. 交付汇总
# ============================================================
get_public_ip() {
    local ip="" a
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -z $ip ]] && ip="$(curl -4 -fsS --max-time 5 https://ip.sb 2>/dev/null || true)"
    if [[ -z $ip ]]; then
        # 断网时退化为本机地址，但只挑非私网的，避免把 docker0/内网网卡当成公网 IP
        while read -r a; do
            [[ -z $a ]] && continue
            if ! is_private_addr "$a"; then ip="$a"; break; fi
        done < <(hostname -I 2>/dev/null | tr ' ' '\n')
    fi
    printf '%s' "$ip"
}

# 出口公网地址探测（按族）。
# 为什么必须按族分开探测：
#   容器 / NAT 机型上常见「v6 有全局地址、v4 只有私网地址（或反之）」。
#   若把两族塞进同一个 pub 数组判断，只要 v6 命中公网就会连带跳过 v4 的探测分支，
#   于是客户端 outbounds 只剩 v6 节点，v4 整组消失。
# 为什么要多服务 + 正则提取：
#   my.ip.cn 之类国内服务返回的是带中文的整行（如 "ip：1.2.3.4 归属地：中国 …"），
#   不是纯 IP，必须用正则从中摘出来；不同服务可用性也不同，串行回退提高成功率。
# 严格地址校验：探测服务的响应正文里可能混着时间/错误码（"12:34:56"、"404.1.2.3"），
# 正则抓到的子串必须过这一关，否则会被当成本机公网地址写进节点、链接与 BIND_MAP。
is_ipv4_addr() {
    local o
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    local -a parts=($1)
    for o in "${parts[@]}"; do
        [[ $o =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}
is_ipv6_addr() {
    local s="$1" grp cnt=0
    [[ $s == *:* && $s =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ ${s#*::} != *::* ]] || return 1                  # 至多一个 "::"
    [[ $s == :* && $s != ::* ]] && return 1
    [[ $s == *: && $s != *:: ]] && return 1
    local -a g
    IFS=':' read -r -a g <<< "$s"
    for grp in "${g[@]}"; do
        [[ -z $grp ]] && continue
        [[ $grp =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        cnt=$((cnt+1))
    done
    if [[ $s == *::* ]]; then (( cnt <= 7 )); else (( cnt == 8 )); fi
}

get_public_ip_family() { # <4|6>
    local fam="$1" ip="" body
    # 国内服务优先（目标用户多在国内 VPS），再退到国际服务
    local -a urls=()
    if [[ $fam == 6 ]]; then
        urls=(
            "https://ipv6.icanhazip.com"
            "https://api64.ipify.org"
            "https://ifconfig.co/ip"
        )
    else
        urls=(
            "https://my.ip.cn/"
            "https://ip.3322.net"
            "https://api.ipify.org"
            "https://ip.sb"
        )
    fi
    for u in "${urls[@]}"; do
        body="$(curl -"$fam" -fsS --max-time 6 "$u" 2>/dev/null || true)"
        [[ -z $body ]] && continue
        if [[ $fam == 6 ]]; then
            # IPv6 正则：允许 :: 压缩写法；抓不到完整 8 组时退而求其次也要能识别
            ip="$(printf '%s' "$body" | grep -oE '([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}' | head -n1 || true)"
        else
            ip="$(printf '%s' "$body" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)"
        fi
        [[ -z $ip ]] && continue
        # 抓到的必须是目标族、是合法地址，且不能是私网/保留段
        if [[ $fam == 6 ]]; then
            is_ipv6_addr "$ip" || continue
        else
            is_ipv4_addr "$ip" || continue
        fi
        is_private_addr "$ip" && continue
        printf '%s' "$ip"
        return 0
    done
    return 0
}
# 分享链接里的主机部分：IPv6 需要方括号
link_host() { if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi; }

# 「只做管理」收尾：模块 9 被裁掉，不写 /root/vps-init.info（避免留下代理凭据与过期链接），
# 只在终端说清楚本次没做什么、以及怎么恢复。已有服务绝不擅自停掉或卸载 —— 可能还有客户端在用。
manage_only_finish() {
    hr
    info "==> 只做管理、不跑代理（已取消全部代理部署）"
    hr
    ssh_access_report
    printf '  本次未执行   : 模块 3 防火墙 / 5 tcpfit / 6 sing-box 安装与凭据 /\n'
    printf '                 7 Reality 回落站 / 8 生成配置 / 9 交付汇总\n'
    printf '  本次未生成   : config.json、v4 / v6 代理节点、客户端 outbounds、分享链接、\n'
    printf '                 Reality 密钥 / 自签证书 / 伪装站 / 端口跳跃 DNAT 规则\n'
    printf '  已写入       : %s（MANAGE_ONLY=1，重跑沿用）\n' "$STATE_FILE"
    printf '  恢复代理部署 : bash vps-init.sh --no-manage-only --nat-wizard\n'
    hr
    if command -v systemctl >/dev/null 2>&1; then
        local s
        for s in sing-box caddy; do
            if systemctl is-active --quiet "$s" 2>/dev/null; then
                warn "检测到 ${s} 仍在运行：本次未改动它。确认不再需要后自行执行 systemctl disable --now ${s}"
            fi
        done
    fi
    return 0
}

m_summary() {
    info "==> [9] 交付汇总"
    # 单跑模块 9（没跑模块 6、状态文件也没有凭据）时，渲染出的链接 / outbounds
    # 是「凭据空壳」（vless://@ip:443?pbk=…），用户粘进客户端必然连不上，
    # 还会覆盖掉旧部署的正常交付文件 —— 入口直接拦住并指向模块 6。
    # keep 模式放行：keep 本来就不写任何文件、且 warn_incomplete_credentials
    # 已对残缺状态专门提示（state.env 被破坏 + 未明确选择时按 keep 兜底是该有的行为）。
    if [[ ${MANAGE_ONLY:-0} -ne 1 && ${RERUN_MODE:-} != keep && ( -z ${UUID:-} || -z ${REALITY_PUB:-} \
          || -z ${SHORT_ID:-} || -z ${HY2_PW:-} || -z ${OBFS_PW:-} ) ]]; then
        die "缺少节点凭据，无法生成交付文件：本次未执行模块 6 且 ${STATE_FILE} 里也没有可用的凭据（请用 --modules 6,8,9 重新生成）"
    fi
    if [[ ${#NODE_IPS[@]} -eq 0 ]]; then detect_ips; fi
    # 注意：不要在这里给 NODE_NAME 赋 hostname 默认值 ——
    # NODE_NAME 的语义是「用户显式指定的节点名」，赋了默认值会让状态文件把它记下来，
    # 之后每次运行都当成用户指定，机房位置自动识别就永远失效了。
    local primary="${NODE_IPS[0]:-}"
    [[ -n $primary ]] || primary="<服务器IP>"
    # 「代理主地址」必须跳过 ssh-only 的族：NODE_IPS 固定 v4 在前，
    # 直接取 NODE_IPS[0] 会给「v4 只做 SSH」的机器打印出根本不存在的 v4 代理端口。
    # vless / hy2 分别选主地址：每族"只保留一个协议"是向导支持的组合，
    # 只按 vless 选会让"只有 hy2 节点"的机器被误报成"本轮无任何代理节点"，
    # 也会让 hy2 段借用 vless 主地址、打印出该族根本不存在的 hy2 端口。
    local proxy_primary="" proxy_primary_hy2="" _x
    for _x in "${NODE_IPS[@]:-}"; do
        [[ -z $_x ]] && continue
        if [[ -z $proxy_primary ]] && nat_ip_needs "$_x" vless; then proxy_primary="$_x"; fi
        if [[ -z $proxy_primary_hy2 ]] && nat_ip_needs "$_x" hy2; then proxy_primary_hy2="$_x"; fi
    done
    build_node_tags
    local node_prefix_used="${NODE_PREFIX}"
    hy2_listen_addrs

    local info_file="/root/vps-init.info"
    # 「沿用旧配置」连交付文件（内含明文凭据）也不重写：只把摘要打到终端。
    local keep_mode=0 info_out="$info_file"
    if [[ ${RERUN_MODE:-} == keep ]] && has_existing_deployment; then
        keep_mode=1; info_out="/dev/null"
    else
        # 先写 .tmp 再原子 mv：直接写目标文件，创建到 chmod 之间会以默认 umask
        # 短暂全局可读（内容含凭据明文），且写一半失败会留半截文件。
        info_out="${info_file}.tmp"
    fi
    local la; la="$(listen_any)"
    # outbounds 只渲染一次：tee 摘要与单独落盘两路复用同一份输出，避免重复触发
    # build_node_tags / node_prefix（机房识别要联网查询，交互模式下还可能再次询问）。
    # 渲染输出以单个换行结尾，命令替换剥离后用 %s\n 补回，字节与直接落盘一致。
    local outbounds_render; outbounds_render="$(render_client_outbounds)"
    # 落盘前先配平自检：outbounds 没有服务端渲染那条 sing-box check / python 解析兜底，
    # 状态文件被手工塞进特殊字符时产出的坏 JSON 会被原样交付给客户端 ——
    # 宁可在这里 fail-fast，也不交一份粘进客户端就报错的配置。
    json_balance_ok "$outbounds_render" \
        || die "客户端 outbounds 渲染结果未通过 JSON 配平自检（疑似特殊字符污染），已中止交付"
    {
        hr
        printf '  VPS 开荒配置摘要   生成时间: %s\n' "$(date -Is)"
        hr
        ssh_access_report
        printf '时区       : %s   防火墙: iptables(INPUT DROP)   fail2ban: sshd/%s（sshd 内部端口）\n' "$TZ_NAME" "$SSH_PORT"
        client_domain_report summary
        # 整形速率展示：SHAPER_RATE 允许 tc 写法（1000mbit 自带单位），只在纯数字时补 Mbps。
        # 注意这段取值不能写成 printf 续行里的注释 —— 续行中的 # 会提前结束整条命令，
        # 后面的实参变成一个独立命令被执行（退出码 127，整个模块 9 中止）。
        local _shape_show
        if [[ -z ${SHAPER_RATE:-} ]]; then
            _shape_show='未设置'
        elif [[ $SHAPER_RATE =~ ^[0-9]+$ ]]; then
            _shape_show="${SHAPER_RATE} Mbps"
        else
            _shape_show="$SHAPER_RATE"
        fi
        printf 'BBR        : %s / %s   整形: %s\n' \
            "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')" \
            "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '-')" \
            "$_shape_show"
        printf '公网地址   : %s 个（%s）\n' "${#NODE_IPS[@]}" "${NODE_IPS[*]}"
        if [[ ${NAT_ACTIVE:-0} -eq 1 ]]; then
            printf '机型       : NAT / 共享出口（%s）\n' "$NAT_REASON"
            nat_port_report
        fi
        hr
        printf '[服务端入站]\n'
        if ! family_runs_proxy 4 || ! family_runs_proxy 6; then
            printf '  说明：入站是双栈通配监听；只做管理的族不下发代理端口放行 / 面板转发，该族代理实际不可达\n'
        fi
        printf '  VLESS-Reality : 单实例，监听 %s（TCP 多 IP 无需拆分），端口 %s\n' "$la" "$VLESS_PORT"
        if [[ ${HY2_SPLIT_BY_IP:-0} -eq 0 ]]; then
            printf '  Hysteria2     : 单实例，监听 %s（单 IP，未绑定公网地址），端口 %s\n' \
                "${HY2_LISTEN_ADDRS[0]}" "$HY2_PORT"
        else
            printf '  Hysteria2     : %s 个实例（检测到同族多地址，按 IP 逐个监听），端口 %s\n' \
                "${#HY2_LISTEN_ADDRS[@]}" "$HY2_PORT"
        fi
        hr
        printf '[VLESS-Reality 节点链接（每个可用 IP 一条；NAT 受限族 ssh-only 的 IP 不生成，server 用域名）]\n'
        printf '  UUID      : %s\n  Flow      : xtls-rprx-vision\n' "$UUID"
        printf '  SNI       : %s\n  PublicKey : %s\n  ShortID   : %s\n  握手目标  : %s:%s\n' \
            "$REALITY_SNI" "$REALITY_PUB" "$SHORT_ID" "$REALITY_DEST" "$REALITY_DEST_PORT"
        printf '  uTLS      : chrome   端口: %s\n' "$VLESS_PORT"
        if [[ ${NAT_ACTIVE:-0} -eq 1 ]]; then
            if [[ -n $proxy_primary ]]; then
                printf '  客户端端口（代理主地址 %s，NAT 映射后）: %s\n' \
                    "$proxy_primary" "$(client_port_for vless "$proxy_primary")"
            else
                printf '  客户端端口：本轮无 vless 节点（v4/v6 都未跑 vless 代理）\n'
            fi
        fi
        local i
        for i in "${!NODE_IPS[@]}"; do
            nat_ip_needs "${NODE_IPS[$i]}" vless || continue
            printf '  %s\n' "$(vless_link_for "$i")"
        done
        hr
        printf '[Hysteria2 节点链接（每个可用 IP 一条；NAT 受限族 ssh-only 的 IP 不生成，server 用域名）]\n'
        printf '  密码      : %s\n  Obfs      : salamander / %s\n' "$HY2_PW" "$OBFS_PW"
        printf '  SNI       : %s   证书校验: %s\n' "$CERT_CN" \
            "$([[ -n $CERT_SHA256 ]] && echo 'pinSHA256 指纹' || echo '允许不安全(未取到指纹)')"
        printf '  pinSHA256 : %s（链接用证书指纹）\n' "${CERT_SHA256:-<未生成>}"
        [[ -n $CERT_HASH ]] && printf '  公钥哈希  : %s（sing-box 客户端 JSON 用）\n' "$CERT_HASH"
        local hop_note='未启用跳跃'
        # 不能只看全局 HOP_RANGE：两族都受限时 apply_nat_adaptation 会清空它，
        # 但用户显式传了 --hop-range 时它会被保留，而实际没有任何节点带跳跃段。
        # 判据改为「有地址真的会用跳跃」。
        local -a _hop_ips=()
        local _hx
        for _hx in "${NODE_IPS[@]:-}"; do
            [[ -n $_hx ]] || continue
            [[ -n "$(hop_range_for_ip "$_hx")" ]] && _hop_ips+=("$_hx")
        done
        if [[ -n $HOP_RANGE && ${#_hop_ips[@]} -gt 0 ]]; then
            hop_note="端口跳跃 ${HOP_RANGE}（间隔 ${HOP_INTERVAL}~${HOP_INTERVAL_MAX}），生效于：${_hop_ips[*]}"
        elif [[ -n $HOP_RANGE ]]; then
            hop_note="未启用跳跃（所有地址族都不是端口全开放，客户端用固定外部端口）"
        fi
        printf '  监听端口  : %s   %s\n' "$HY2_PORT" "$hop_note"
        if [[ ${NAT_ACTIVE:-0} -eq 1 ]]; then
            if [[ -n $proxy_primary_hy2 ]]; then
                # hy2 自己的主地址：借用 vless 主地址会打印该族不存在的 hy2 端口。
                # 该地址若走端口跳跃，客户端实际连的是跳跃段而不是固定端口。
                local _hp; _hp="$(hop_range_for_ip "$proxy_primary_hy2")"
                if [[ -n $_hp ]]; then
                    printf '  客户端端口（代理主地址 %s）: %s（端口跳跃）\n' \
                        "$proxy_primary_hy2" "$_hp"
                else
                    printf '  客户端端口（代理主地址 %s，NAT 映射后）: %s\n' \
                        "$proxy_primary_hy2" "$(client_port_for hy2 "$proxy_primary_hy2")"
                fi
            else
                printf '  客户端端口：本轮无 hy2 节点（v4/v6 都未跑 hy2 代理）\n'
            fi
            printf '  分族策略  : v4 %s；v6 %s\n' \
                "$(family_state_desc 4)" "$(family_state_desc 6)"
        fi
        for i in "${!NODE_IPS[@]}"; do
            nat_ip_needs "${NODE_IPS[$i]}" hy2 || continue
            printf '  %s\n' "$(hy2_link_for "$i")"
        done
        hr
        printf '[sing-box 客户端 outbounds —— 可直接复制]\n'
        printf '  节点名前缀：%s（自动识别机房城市；识别失败可交互手动输入，或用 --node-name 指定）\n' "$node_prefix_used"
        printf '  tag 形如「<城市> v4-vl」「<城市> v6.1-hy2」：v4/v6 为地址族，同族多地址时加点号序号\n'
        printf '  顺序：先全部 vless，再全部 hy2\n'
        [[ -n ${NAT_V4_SERVICES:-} ]] \
            && printf '  v4 节点策略：%s（--nat-v4-services）\n' \
                "$([[ ${NAT_V4_SERVICES} == ssh-only ]] && echo '端口只供 SSH，不生成 v4 代理节点' || echo "仅保留 ${NAT_V4_SERVICES}")"
        [[ -n ${NAT_V6_SERVICES:-} ]] \
            && printf '  v6 节点策略：%s（--nat-v6-services）\n' \
                "$([[ ${NAT_V6_SERVICES} == ssh-only ]] && echo '端口只供 SSH，不生成 v6 代理节点' || echo "仅保留 ${NAT_V6_SERVICES}")"
        printf '  用法：粘进客户端配置的 outbounds 数组；若客户端还没有 direct/block，请自行补上\n'
        printf '  客户端版本：JSON 里 hy2 的 certificate_public_key_sha256 字段需较新 sing-box（≥ 1.13）；\n'
        printf '             旧版客户端请改用上方分享链接（自带 pinSHA256 / insecure 校验信息）\n'
        printf '%s\n' "$outbounds_render"
        hr
    } | tee_600 "$info_out"
    if [[ $keep_mode -eq 1 ]]; then
        # 跨进程分叉警示：上次轮换半失败（state 已是新凭据、config.json 未更新）
        # 后用户重跑 keep，必须在这里看到提醒，而不是等模块 7/8 失败才发现
        warn_state_config_divergence
        ok "沿用旧配置：vps-init.info / client-outbounds.json 保持原样，未重写；state.env 未改动"
        return 0
    fi
    if ! mv -f "${info_file}.tmp" "$info_file"; then
        rm -f "${info_file}.tmp"
        die "保存 ${info_file} 失败（磁盘满 / 权限不足）；原文件未改动"
    fi
    chmod 600 "$info_file" 2>/dev/null || true
    ok "已保存到 ${info_file}（权限 600）"

    # 单独落一份纯 JSON，方便 scp / 复制（复用上面渲染好的同一份输出）
    local client_file="/root/vps-init.client-outbounds.json"
    if ! ( umask 077; printf '%s\n' "$outbounds_render" > "${client_file}.tmp" ) \
       || ! mv -f "${client_file}.tmp" "$client_file"; then
        rm -f "${client_file}.tmp"
        die "写入 ${client_file} 失败（磁盘满 / 权限不足）；原文件未改动"
    fi
    chmod 600 "$client_file" 2>/dev/null || true
    ok "客户端 outbounds 已单独保存到 ${client_file}"

    if command -v qrencode >/dev/null && [[ -z $ASSUME_YES ]]; then
        local i
        for i in "${!NODE_IPS[@]}"; do
            # 只做管理的族不画二维码：否则会给出注定连不上的 v4 / v6 链接
            if nat_ip_needs "${NODE_IPS[$i]}" vless; then
                hr; printf 'VLESS %s 二维码：\n' "$(client_host_for "${NODE_IPS[$i]}")"; qrencode -t ANSIUTF8 "$(vless_link_for "$i")" || true
            fi
            if nat_ip_needs "${NODE_IPS[$i]}" hy2; then
                hr; printf 'Hysteria2 %s 二维码：\n' "$(client_host_for "${NODE_IPS[$i]}")"; qrencode -t ANSIUTF8 "$(hy2_link_for "$i")" || true
            fi
        done
    fi
    save_state
}

vless_link_for() { # <index>
    local i="$1"
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
        "$UUID" "$(link_host "$(client_host_for "${NODE_IPS[$i]}")")" "$(client_port_for vless "${NODE_IPS[$i]}")" \
        "$REALITY_SNI" "$REALITY_PUB" "$SHORT_ID" \
        "$(urlenc "${T_VL[$i]}")"
}
hy2_link_for() { # <index>
    local i="$1" hop="" tlsarg=""
    # v6 全开放的 NAT 机：只有 v6 链接带跳跃段，v4 链接仍连固定外部单端口
    # 变量名不要用 hr —— 那会遮蔽全局的分隔线函数 hr()
    local _hr; _hr="$(hop_range_for_ip "${NODE_IPS[$i]}")"
    # 官方 Hysteria2 URI 规范：端口跳跃写在 authority（多段逗号分隔、范围用连字符）
    # —— sing-box / 官方客户端只认这里，只带 &mport= 的链接在官方客户端会丢失跳跃。
    # mport= 是 NekoBox 等第三方客户端沿用至今的历史写法；query 参数对官方客户端
    # 无害（未知参数被忽略），两个都给以兼容两类客户端。
    local _auth_ports; _auth_ports="$(client_port_for hy2 "${NODE_IPS[$i]}")"
    [[ -n $_hr ]] && { _auth_ports="${_auth_ports},${_hr/:/-}"; hop="&mport=${_hr/:/-}"; }
    # 服务端是自签证书：链接必须携带校验信息，否则客户端会因证书不受信任而握手失败。
    # 注意用的是「证书指纹 CERT_SHA256（hex）」，不是 JSON 里的公钥哈希 CERT_HASH ——
    # Hysteria2 URI 的 pinSHA256 口径是整张证书的 sha256（openssl x509 -fingerprint -sha256），
    # 拿公钥哈希去 pin 必然校验失败。取不到指纹时才降级 insecure。
    if [[ -n $CERT_SHA256 ]]; then
        tlsarg="&pinSHA256=${CERT_SHA256}"
    else
        tlsarg="&insecure=1"
    fi
    printf 'hysteria2://%s@%s:%s/?sni=%s%s&alpn=h3&obfs=salamander&obfs-password=%s%s#%s' \
        "$(urlenc "$HY2_PW")" "$(link_host "$(client_host_for "${NODE_IPS[$i]}")")" \
        "$_auth_ports" "$CERT_CN" "$hop" \
        "$(urlenc "$OBFS_PW")" "$tlsarg" "$(urlenc "${T_HY2[$i]}")"
}

# ============================================================
# §14 只读状态查看
# ============================================================
svc_state() { # is-active 对 inactive 单元会先往 stdout 打 "inactive" 再以退出码 3 失败，
              # 直接 || echo 会捕获到两行错乱文本；这里显式判 active
    local s
    s="$(systemctl is-active "$1" 2>/dev/null || true)"
    [[ $s == active ]] || s="未运行/未安装"
    printf '%s' "$s"
}
show_manage_status() { # 「只做管理」模式下的只读状态视图：不打印任何代理凭据与节点
    hr; printf '  当前配置状态（只读）—— 只做管理、不跑代理\n'; hr
    if [[ -f $STATE_FILE ]]; then
        info "状态文件：$STATE_FILE"
        grep -E '^(MANAGE_ONLY|SSH_PORT|TZ_NAME|NAT_MODE|NAT_V4_OPEN|NAT_V6_OPEN)=' \
            "$STATE_FILE" 2>/dev/null | sed 's/^/    /'
    else
        warn "未找到 $STATE_FILE，本机可能尚未执行过本脚本"
    fi
    # --status --manage-only 只是本次覆盖，不改文件：上面若显示 0 是正常的，别写成「已沿用」。
    printf '  本次生效   : MANAGE_ONLY=1（只做管理）；若上方文件里仍为 0，说明本次只是命令行临时覆盖，\n'
    printf '               不带 --status 跑一次 --manage-only 才会写入状态文件供重跑沿用。\n'
    hr
    ssh_access_report
    printf '  服务         : sing-box=%s  caddy=%s  fail2ban=%s\n' \
        "$(svc_state sing-box)" "$(svc_state caddy)" "$(svc_state fail2ban)"
    printf '  本轮不部署代理：无 v4 / v6 节点、无客户端 outbounds、无分享链接、\n'
    printf '                  无代理端口防火墙 / 端口跳跃 DNAT 规则。\n'
    printf '  恢复代理部署  ：bash vps-init.sh --no-manage-only --nat-wizard\n'
    hr
    if command -v iptables >/dev/null; then
        info "防火墙 INPUT 策略（脚本本轮未改动）："
        iptables -S INPUT 2>/dev/null | grep '^-P' | sed 's/^/    /' || true
    fi
    if command -v fail2ban-client >/dev/null; then
        info "fail2ban：$(fail2ban-client status 2>/dev/null | grep -i 'Jail list' || echo '未就绪')"
    fi
    return 0
}
show_status() {
    [[ ${MANAGE_ONLY:-0} -eq 1 ]] && { show_manage_status; return 0; }
    # 状态/配置分叉（上次轮换半失败）跨进程提醒：--status 是用户排查的第一入口
    warn_state_config_divergence
    hr; printf '  当前配置状态（只读，不修改任何东西）\n'; hr
    if [[ -f $STATE_FILE ]]; then
        info "状态文件：$STATE_FILE"
        grep -E '^(SSH_PORT|DOMAIN|CLIENT_DOMAIN|CLIENT_DOMAIN_V4|CLIENT_DOMAIN_V6|CLIENT_DOMAIN_FORCE_IP|TZ_NAME|HY2_PORT|VLESS_PORT|SHAPER_RATE|REALITY_SNI|NAT_MODE|NAT_V4_OPEN|NAT_V6_OPEN|NAT_PORTS|NAT_V6_PORTS)=' "$STATE_FILE" 2>/dev/null | sed 's/^/    /'
    else
        warn "未找到 $STATE_FILE，本机可能尚未执行过本脚本"
    fi
    client_domain_report status
    hr
    ssh_access_report
    printf '  服务       : sing-box=%s  caddy=%s  fail2ban=%s\n' \
        "$(svc_state sing-box)" "$(svc_state caddy)" "$(svc_state fail2ban)"
    printf '  拥塞控制   : %s / %s\n' \
        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')" \
        "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '-')"
    printf '  TCP 调优   : %s\n' \
        "$([[ -f /etc/sysctl.d/99-tcpfit.conf ]] && echo 'tcpfit 已应用' || echo 'tcpfit 未应用')"
    detect_ips
    hy2_listen_addrs
    local la; la="$(listen_any)"
    printf '  公网地址   : %s 个 [%s]\n' "${#NODE_IPS[@]}" "${NODE_IPS[*]:-未探测到}"
    if [[ ${NAT_ACTIVE:-0} -eq 1 ]]; then
        printf '  机型       : NAT / 共享出口（%s）\n' "$NAT_REASON"
        printf '  分族策略   : v4 %s；v6 %s（端口跳跃只作用于全开放族）\n' \
            "$(family_state_desc 4)" "$(family_state_desc 6)"
        nat_port_report
    fi
    if [[ ${HY2_SPLIT_BY_IP:-0} -eq 1 ]]; then
        printf '  服务端入站 : vless 监听 %s ；hy2 监听 %s（按 IP）\n' "$la" "${HY2_LISTEN_ADDRS[*]}"
    else
        printf '  服务端入站 : vless 监听 %s ；hy2 监听 %s\n' "$la" "${HY2_LISTEN_ADDRS[0]}"
    fi
    hr
    if command -v ss >/dev/null; then
        info "监听端口："
        ss -tulnp 2>/dev/null | grep -E ":(22|${SSH_PORT}|${VLESS_PORT}|${HY2_PORT}|${FALLBACK_PORT})\b" | sed 's/^/    /' || true
    fi
    if command -v iptables >/dev/null; then
        info "防火墙 INPUT 策略："
        iptables -S INPUT 2>/dev/null | grep '^-P' | sed 's/^/    /' || true
    fi
    if command -v fail2ban-client >/dev/null; then
        info "fail2ban：$(fail2ban-client status 2>/dev/null | grep -i 'Jail list' || echo '未就绪')"
    fi
    hr
    if [[ -f /root/vps-init.info ]]; then
        info "完整参数（/root/vps-init.info）："
        sed 's/^/    /' /root/vps-init.info
    fi
}

# ============================================================
# §14b 只读体检 --doctor
# ============================================================
# 设计约束：
#   1) 绝不修改任何状态 —— 只跑查询类命令（systemctl is-active / ss / iptables -S /
#      openssl x509 / sing-box check / getent），不写 state.env、不碰服务。
#   2) 逐项容错：本机缺组件（无 ss / 无 getent / 非 root / 非 systemd）一律降级为
#      WARN，绝不 die —— 体检本身不能变成新的故障源。
#   3) 三档结论：[✓] 通过 / [!] 提示（多为未部署组件的正常降级）/ [✗] 异常（需处理）。
#   4) 退出码：只有存在 [✗] 才返回 1，方便脚本化调用判断。
DOCTOR_FAILS=0
DOCTOR_WARNS=0
DOC_REC_ST=(); DOC_REC_NAME=(); DOC_REC_DETAIL=()
dinfo() { # 体检小节标头：--json 模式下不打印（小节信息由 checks 数组的结构承载）
    [[ ${DOCTOR_JSON:-0} -ne 1 ]] && info "$@"
    return 0
}
dchk() { # dchk <ok|warn|fail> <描述> [详情]
    # 每条结论同时记入数组：--json 模式据此渲染机器可读结果，人类模式照旧打印
    DOC_REC_ST+=("$1"); DOC_REC_NAME+=("$2"); DOC_REC_DETAIL+=("${3:-}")
    if [[ ${DOCTOR_JSON:-0} -ne 1 ]]; then
        case "$1" in
            ok)   printf '  [✓] %s%s\n' "$2" "${3:+ —— $3}";;
            warn) printf '  [!] %s%s\n' "$2" "${3:+ —— $3}";;
            fail) printf '  [✗] %s%s\n' "$2" "${3:+ —— $3}";;
        esac
    fi
    case "$1" in
        warn) DOCTOR_WARNS=$((DOCTOR_WARNS+1));;
        fail) DOCTOR_FAILS=$((DOCTOR_FAILS+1));;
    esac
    return 0
}

doctor_svc() { # doctor_svc <服务名> <中文说明> [可选=1 表示"未部署属正常"]
    if ! command -v systemctl >/dev/null 2>&1; then
        dchk warn "$2" "本机无 systemctl（非 systemd 环境），跳过"
        return 0
    fi
    local s
    s="$(systemctl is-active "$1" 2>/dev/null || true)"
    if [[ $s == active ]]; then
        dchk ok "$2 运行中"
    elif [[ ${3:-} == 1 ]]; then
        dchk warn "$2 未运行（属可选项）"
    else
        dchk fail "$2 未运行" "修复：systemctl restart $1；日志：journalctl -u $1 -e"
    fi
    return 0
}

# doctor_port_check <协议 tcp|udp> <端口> <描述>
doctor_port_check() {
    if ! command -v ss >/dev/null 2>&1; then
        dchk warn "$3" "本机无 ss 命令，跳过监听检查"
        return 0
    fi
    local flag="-tln"; [[ $1 == udp ]] && flag="-uln"
    # 不用 grep -q：命中首行即退出会触发 SIGPIPE，pipefail 下整个条件判假，
    # 把「正在监听」误报成「未监听」（与 Round H 防火墙检查同类问题）。
    # 去掉 -q 让 grep 消费完整个输入，再按退出码判断。
    if ss "$flag" 2>/dev/null | awk '{print $4}' | grep -E ":${2}\$" >/dev/null; then
        dchk ok "$3 正在监听" "端口 ${2}/${1}"
    else
        dchk fail "$3 未监听" "端口 ${2}/${1} 无进程 —— 检查服务是否运行、配置 listen_port"
    fi
    return 0
}

cmd_doctor() {
    DOCTOR_FAILS=0; DOCTOR_WARNS=0; DOC_REC_ST=(); DOC_REC_NAME=(); DOC_REC_DETAIL=()
    if [[ ${DOCTOR_JSON:-0} -ne 1 ]]; then
        hr; printf '  一键体检（只读）—— 服务 / 配置 / 端口 / 防火墙 / 证书 / 域名解析\n'; hr
    fi

    # 「只做管理」没有代理组件，直接给管理视图
    if [[ ${MANAGE_ONLY:-0} -eq 1 ]]; then
        if [[ ${DOCTOR_JSON:-0} -eq 1 ]]; then
            printf '{"mode": "manage_only", "summary": {"total": 0, "warn": 0, "fail": 0}, "checks": []}\n'
        else
            info "本机为「只做管理、不跑代理」模式，代理相关项全部跳过："
            show_manage_status
        fi
        return 0
    fi

    # ---- 1. 状态与凭据 ----
    dinfo "[1/7] 状态与凭据"
    if [[ -s $STATE_FILE ]]; then
        dchk ok "状态文件存在" "$STATE_FILE"
    else
        dchk fail "状态文件不存在（$STATE_FILE）" "本机从未完成部署，请先运行完整部署"
    fi
    if [[ -s $SB_CONF ]]; then
        dchk ok "服务端配置存在" "$SB_CONF"
    else
        dchk fail "服务端配置不存在（$SB_CONF）" "模块 6/8 未执行或未完成"
    fi
    if [[ -n $UUID && -n $REALITY_PRIV ]]; then
        dchk ok "Reality 凭据齐全（UUID / 私钥）"
    else
        dchk fail "Reality 凭据缺失（UUID / REALITY_PRIV 为空）" "重跑模块 6 并选「生成新配置」"
    fi
    if [[ -n $HY2_PW && $HY2_PW != changeme ]]; then
        dchk ok "hy2 密码已生成"
    else
        dchk fail "hy2 密码缺失或仍是占位值" "重跑模块 6 并选「生成新配置」"
    fi

    # ---- 2. 服务状态 ----
    dinfo "[2/7] 服务状态"
    doctor_svc sing-box "sing-box"
    # 本地回落站是可选组件：没给 --domain/--cf-token 时未部署属正常降级
    if [[ -n $DOMAIN && -s ${SB_DIR}/cert/fullchain.cer ]]; then
        doctor_svc caddy "Caddy（本地回落伪装站）"
    else
        dchk warn "Caddy 未部署本地回落站（无同域名证书）" "公共站点握手模式，属正常形态"
    fi
    doctor_svc fail2ban "fail2ban"

    # ---- 3. 配置校验 ----
    dinfo "[3/7] sing-box 配置校验"
    if command -v sing-box >/dev/null 2>&1 && [[ -s $SB_CONF ]]; then
        if sing-box check -c "$SB_CONF" >/dev/null 2>&1; then
            dchk ok "sing-box check 通过"
        else
            dchk fail "sing-box check 未通过" "运行 sing-box check -c $SB_CONF 查看具体报错"
        fi
    else
        dchk warn "无法校验" "sing-box 未安装或配置文件不存在"
    fi

    # ---- 4. 监听端口 ----
    dinfo "[4/7] 监听端口"
    doctor_port_check tcp "$VLESS_PORT" "VLESS-Reality (TCP)"
    doctor_port_check udp "$HY2_PORT"  "Hysteria2 (UDP)"
    if [[ -n $DOMAIN && -s ${SB_DIR}/cert/fullchain.cer ]]; then
        doctor_port_check tcp "$FALLBACK_PORT" "Caddy 回落伪装站 (TCP)"
    fi
    # SSH 永远是最后的救命通道，单独盯一眼
    doctor_port_check tcp "$SSH_PORT" "SSH (TCP)"

    # ---- 5. 证书与指纹 ----
    dinfo "[5/7] 证书与指纹"
    if command -v openssl >/dev/null 2>&1; then
        if [[ -s ${SB_DIR}/cert.crt ]]; then
            local hy2_end
            hy2_end="$(openssl x509 -in "${SB_DIR}/cert.crt" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
            dchk ok "hy2 自签证书在位" "有效期至 ${hy2_end:-未知}"
        else
            dchk fail "hy2 自签证书缺失（${SB_DIR}/cert.crt）" "重跑模块 6 并选「生成新配置」"
        fi
        if [[ -n $CERT_HASH ]]; then
            dchk ok "hy2 公钥哈希已生成（客户端 JSON 严格校验，需 sing-box ≥ 1.13）"
        else
            dchk warn "未取到 hy2 公钥哈希，客户端 JSON 降级为 insecure"
        fi
        # 链接里的 pinSHA256 用的是证书指纹（hex），与上面的公钥哈希不是同一个值；
        # 若状态文件记录与磁盘证书不一致，说明证书换过而状态没跟着更新。
        if [[ -s ${SB_DIR}/cert.crt && -n $CERT_SHA256 ]]; then
            local _fp
            _fp="$(openssl x509 -in "${SB_DIR}/cert.crt" -outform DER 2>/dev/null \
                  | openssl dgst -sha256 2>/dev/null | sed 's/^.*= //' | tr -d ' \r\n')"
            if [[ ${#_fp} -eq 64 && $_fp != "$CERT_SHA256" ]]; then
                dchk fail "链接 pinSHA256 与当前证书指纹不一致" "重跑模块 6 重新写入状态（或 --print-outbounds 重新生成交付文件）"
            else
                dchk ok "链接 pinSHA256 与证书指纹一致"
            fi
        fi
        if [[ -n $DOMAIN && -s ${SB_DIR}/cert/fullchain.cer ]]; then
            if cert_domain_matches "${SB_DIR}/cert/fullchain.cer" "$DOMAIN"; then
                dchk ok "回落站证书与域名匹配" "$DOMAIN"
            else
                dchk fail "回落站证书与域名不匹配" "acme.sh 装回了旧域名的证书，重跑模块 7 重新签发"
            fi
            if openssl x509 -in "${SB_DIR}/cert/fullchain.cer" -checkend 2592000 -noout >/dev/null 2>&1; then
                dchk ok "回落站证书有效期 > 30 天"
            else
                dchk warn "回落站证书 30 天内到期" "acme.sh 会自动续期；若已失效请重跑模块 7"
            fi
        fi
    else
        dchk warn "本机无 openssl，跳过证书检查"
    fi

    # ---- 6. 防火墙关键规则 ----
    dinfo "[6/7] 防火墙关键规则"
    if [[ $EUID -ne 0 ]]; then
        dchk warn "防火墙" "非 root 运行，跳过（请用 root 再跑一次 --doctor 查完整）"
    elif ! command -v iptables >/dev/null 2>&1; then
        dchk warn "防火墙" "本机无 iptables，跳过"
    else
        # 规则集先整体捕获再匹配：grep -q 命中即退出会让上游 iptables 吃 SIGPIPE（141），
        # pipefail 下整条管道判假 —— 规则明明在位却被报成「未设 / 未放行」（假阴性）
        local _in4 _in6 _nat4 _nat6=""
        _in4="$(iptables -S INPUT 2>/dev/null || true)"
        _in6="$(ip6tables -S INPUT 2>/dev/null || true)"
        _nat4="$(iptables -t nat -S PREROUTING 2>/dev/null || true)"
        if command -v ip6tables >/dev/null 2>&1; then
            _nat6="$(ip6tables -t nat -S PREROUTING 2>/dev/null || true)"
        fi
        if [[ $_in4 == *'-P INPUT DROP'* ]]; then
            dchk ok "iptables INPUT 默认 DROP"
        else
            dchk fail "iptables INPUT 未设 DROP" "重跑模块 3 下发规则"
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            if [[ $_in6 == *'-P INPUT DROP'* ]]; then
                dchk ok "ip6tables INPUT 默认 DROP"
            else
                dchk fail "ip6tables INPUT 未设 DROP" "重跑模块 3 下发规则"
            fi
        fi
        # SSH 放行：内部端口 + NAT 外部映射端口都要在，缺一个就锁死
        local ssh_p
        for ssh_p in $(printf '%s\n' "$SSH_PORT" $(ssh_ports_for_family 4 2>/dev/null || true) \
                            $(ssh_ports_for_family 6 2>/dev/null || true) | sort -u); do
            if [[ $_in4 == *"--dport ${ssh_p} "* || $_in6 == *"--dport ${ssh_p} "* ]]; then
                dchk ok "SSH 端口 ${ssh_p} 已放行"
            else
                dchk fail "SSH 端口 ${ssh_p} 未放行" "立即处理：iptables -A INPUT -p tcp --dport ${ssh_p} -j ACCEPT（否则会锁死）"
            fi
        done
        # 端口跳跃 DNAT（只在启用且该族全开放时应当存在；v4 / v6 的 nat 表分开查，
        # 此前只查 v4 —— NAT 机型 v4 受限、v6 全开放时，v6 的 DNAT 缺失体检完全看不见）
        local _doct_hop_v4=0 _doct_hop_v6=0
        if [[ -n $HOP_RANGE ]]; then
            if [[ ${NAT_ACTIVE:-0} -eq 1 ]]; then
                [[ ${NAT_V4_OPEN:-0} -eq 1 ]] && _doct_hop_v4=1   # 受限族没有整段 DNAT，不作要求
                [[ ${NAT_V6_OPEN:-0} -eq 1 ]] && _doct_hop_v6=1
            else
                _doct_hop_v4=1
                command -v ip6tables >/dev/null 2>&1 && _doct_hop_v6=1
            fi
            if [[ $_doct_hop_v4 -eq 1 ]]; then
                if [[ $_nat4 == *"--to-destination :${HY2_PORT}"* ]]; then
                    dchk ok "端口跳跃 DNAT 在位（v4）" "${HOP_RANGE} → :${HY2_PORT}"
                else
                    dchk fail "端口跳跃 DNAT 缺失（v4）" "重跑模块 3；并确认服务商防火墙/安全组已放行 ${HOP_RANGE} 的 UDP"
                fi
            fi
            if [[ $_doct_hop_v6 -eq 1 ]]; then
                if [[ $_nat6 == *"--to-destination :${HY2_PORT}"* ]]; then
                    dchk ok "端口跳跃 DNAT 在位（v6）" "${HOP_RANGE} → :${HY2_PORT}"
                else
                    dchk warn "端口跳跃 DNAT 缺失（v6）" "该族端口跳跃无效（内核/服务商常裁剪 IPv6 NAT）；仅影响 v6 侧跳跃，需要时重跑模块 3"
                fi
            fi
        fi
    fi

    # ---- 7. 客户端域名解析 ----
    dinfo "[7/7] 客户端域名解析"
    # --no-client-domain（FORCE_IP=1）下客户端 server 一律用裸 IP：域名解析比对
    # 不会反映真实连接，检查整段跳过，否则「显式关了域名却拿域名去体检」自相矛盾。
    if [[ ${CLIENT_DOMAIN_FORCE_IP:-0} -eq 1 ]]; then
        dchk ok "域名解析" "已用 --no-client-domain 显式回到裸 IP，跳过域名比对"
    elif ! command -v getent >/dev/null 2>&1; then
        dchk warn "域名解析" "本机无 getent，跳过（可手动 dig 确认 A / AAAA 记录）"
    elif [[ ${#NODE_IPS[@]} -eq 0 ]]; then
        dchk warn "域名解析" "未探测到本机公网地址，无法比对（可用 --ips 显式指定后重跑）"
    else
        local -a mach_v4=() mach_v6=() ips_all=("${NODE_IPS[@]}")
        local _ip
        for _ip in "${ips_all[@]}"; do
            [[ $_ip == *:* ]] && mach_v6+=("$_ip") || mach_v4+=("$_ip")
        done
        # 客户端实际会用的域名：分族专属 > 共用 > --domain（与 client_host_for 同一条链）
        local dom_v4="${CLIENT_DOMAIN_V4:-${CLIENT_DOMAIN:-}}"
        local dom_v6="${CLIENT_DOMAIN_V6:-${CLIENT_DOMAIN:-}}"
        if [[ -z $dom_v4 && $(looks_like_domain "$DOMAIN" && echo 1 || echo 0) == 1 ]]; then dom_v4="$DOMAIN"; fi
        if [[ -z $dom_v6 && $(looks_like_domain "$DOMAIN" && echo 1 || echo 0) == 1 ]]; then dom_v6="$DOMAIN"; fi
        local fam dom need recs hit
        for fam in 4 6; do
            if [[ $fam == 4 ]]; then dom="$dom_v4"; need="A"; else dom="$dom_v6"; need="AAAA"; fi
            [[ -n $dom ]] || { dchk warn "${need} 记录" "该族未配置客户端域名（server 用裸 IP），属正常形态"; continue; }
            # 注意：getent 的数据库名是 ahostsv4 / ahostsv6（不是 ahosts4/ahosts6）——
            # 名字写错时 getent 直接失败，doctor 会把「域名正常解析」误报成「无记录」
            recs="$(getent "ahostsv${fam}" "$dom" 2>/dev/null | awk '{print $1}' | sort -u || true)"
            if [[ -z $recs ]]; then
                local needtxt="IPv4"; [[ $fam == 6 ]] && needtxt="IPv6"
                dchk fail "$dom 无 ${need} 记录" "请到 DNS 服务商把 ${need} 记录指到本机${needtxt}地址"
                continue
            fi
            hit=0
            for _ip in $recs; do
                if [[ $fam == 4 && " ${mach_v4[*]} " == *" $_ip "* ]] \
                    || [[ $fam == 6 && " ${mach_v6[*]} " == *" $_ip "* ]]; then
                    hit=1; break
                fi
            done
            if [[ $hit -eq 1 ]]; then
                dchk ok "$dom 的 ${need} 记录指向本机" "解析值：$(printf '%s ' $recs)"
            else
                dchk fail "$dom 的 ${need} 记录没有指向本机" "解析到：$(printf '%s ' $recs)—— 本机：$(printf '%s ' "${mach_v4[@]}" "${mach_v6[@]}")"
            fi
        done
    fi

    # NAT 端口清单（参照物，供面板核对）。
    # 仅文本模式输出：nat_port_report 直接 printf 到 stdout，JSON 模式下会把
    # 机器可读输出冲掉，脚本 / 面板拿到手的就是解析失败的残渣。
    if [[ ${NAT_ACTIVE:-0} -eq 1 && ${DOCTOR_JSON:-0} -ne 1 ]]; then
        hr
        info "NAT 机型端口清单（照此到服务商面板核对转发）："
        nat_port_report
    fi

    # --json：把全部结论渲染成机器可读 JSON（stdout 只含 JSON，便于面板 / 脚本解析）
    if [[ ${DOCTOR_JSON:-0} -eq 1 ]]; then
        local -a _recs=()
        local _i
        for _i in "${!DOC_REC_ST[@]}"; do
            _recs+=("$(j_obj '            ' \
                "$(j_kv status "${DOC_REC_ST[$_i]}")" \
                "$(j_kv name   "${DOC_REC_NAME[$_i]}")" \
                "$(j_kv detail "${DOC_REC_DETAIL[$_i]}")")")
        done
        j_obj '' \
            "\"mode\": \"$( [[ ${MANAGE_ONLY:-0} -eq 1 ]] && echo manage_only || echo proxy )\"" \
            "\"summary\": $(j_obj '        ' \
                "$(j_lit total ${#DOC_REC_ST[@]})" \
                "$(j_lit warn $DOCTOR_WARNS)" \
                "$(j_lit fail $DOCTOR_FAILS)")" \
            "\"checks\": $(j_arr '        ' "${_recs[@]}")"
        # JSON 模式同样保持退出码语义：有 fail 项则退出码 1
        (( DOCTOR_FAILS > 0 )) && return 1
        return 0
    fi

    hr
    if (( DOCTOR_FAILS > 0 )); then
        err "体检完成：${DOCTOR_FAILS} 项异常，${DOCTOR_WARNS} 项提示 —— 请逐项处理上方 [✗]"
        return 1
    elif (( DOCTOR_WARNS > 0 )); then
        warn "体检完成：关键项全部通过，${DOCTOR_WARNS} 项提示（多为未部署组件的正常降级）"
        return 0
    else
        ok "体检完成：全部通过"
        return 0
    fi
}

# ---------- §14c --status --json：机器可读状态输出 ----------
# stdout 只含一份合法 JSON（人类可读文本一律走 stderr 的 info/ok/warn），
# 供面板 / 批量管理工具解析：服务状态、分族端口、NAT 策略、凭据存在性（不含凭据明文）。
cmd_status_json() {
    local -a _ip_items=() _svc_items=()
    local _x _s
    # 先过一遍设置校验：state.env 被手工改坏（如端口带前导零）时，
    # 给出指向 state.env 的明确报错，而不是拼出一份 json.load 必失败的 JSON。
    validate_settings
    real_ips_from_args    # NODE_IPS ← IP_LIST / --ips / 真实探测（绝不用渲染占位地址）
    for _x in "${NODE_IPS[@]:-}"; do
        [[ -n $_x ]] && _ip_items+=("\"$(json_escape "$_x")\"")
    done
    for _x in sing-box caddy fail2ban; do
        _s="$(svc_state "$_x")"
        _svc_items+=("$(j_obj '                ' "$(j_kv name "$_x")" "$(j_kv state "$_s")")")
    done

    local _d4="${CLIENT_DOMAIN_V4:-}" _d6="${CLIENT_DOMAIN_V6:-}"
    # v4 / v6 未分族指定时回退共用域名（与渲染路径 client_host_for 的取值顺序一致）
    [[ -n $_d4 ]] || _d4="${CLIENT_DOMAIN:-}"
    [[ -n $_d6 ]] || _d6="${CLIENT_DOMAIN:-}"

    local _hy2_end=""
    if command -v openssl >/dev/null 2>&1 && [[ -s ${SB_DIR}/cert.crt ]]; then
        _hy2_end="$(openssl x509 -in "${SB_DIR}/cert.crt" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
    fi

    j_obj '' \
        "\"mode\": \"$( [[ ${MANAGE_ONLY:-0} -eq 1 ]] && echo manage_only || echo proxy )\"" \
        "$(j_kv state_file "$STATE_FILE")" \
        "\"ssh\": $(j_obj '        ' \
            "$(j_lit port "$SSH_PORT")" \
            "$(j_lit v4_external "$(ssh_port_for_family 4)")" \
            "$(j_lit v6_external "$(ssh_port_for_family 6)")")" \
        "\"nat\": $(j_obj '        ' \
            "$(j_lit active "${NAT_ACTIVE:-0}")" \
            "$(j_kv mode "${NAT_MODE:-auto}")" \
            "$(j_lit v4_open "${NAT_V4_OPEN:-0}")" \
            "$(j_lit v6_open "${NAT_V6_OPEN:-0}")" \
            "$(j_kv v4_ports "${NAT_PORTS:-}")" \
            "$(j_kv v4_map "${NAT_MAP:-}")" \
            "$(j_kv v6_ports "${NAT_V6_PORTS:-}")" \
            "$(j_kv v6_map "${NAT_V6_MAP:-}")")" \
        "\"ports\": $(j_obj '        ' \
            "$(j_lit vless "$VLESS_PORT")" \
            "$(j_lit hy2 "$HY2_PORT")" \
            "$(j_lit fallback "$FALLBACK_PORT")" \
            "$(j_kv hop_range "${HOP_RANGE:-}")")" \
        "\"services\": $(j_arr '        ' "${_svc_items[@]}")" \
        "\"client\": $(j_obj '        ' \
            "\"ips\": $(j_arr '            ' "${_ip_items[@]}")" \
            "\"domain_v4\": \"$(json_escape "$_d4")\"" \
            "\"domain_v6\": \"$(json_escape "$_d6")\"" \
            "\"outbounds_file\": \"/root/vps-init.client-outbounds.json\"" \
            "\"info_file\": \"/root/vps-init.info\"")" \
        "\"credentials_present\": $(j_obj '        ' \
            "\"uuid\": $( [[ -n $UUID ]] && printf true || printf false )" \
            "\"reality_key\": $( [[ -n $REALITY_PRIV ]] && printf true || printf false )" \
            "\"hy2_password\": $( [[ -n $HY2_PW && $HY2_PW != changeme ]] && printf true || printf false )" \
            "\"cert_hash\": $( [[ -n $CERT_HASH ]] && printf true || printf false )" \
            "\"cert_fingerprint\": $( [[ -n $CERT_SHA256 ]] && printf true || printf false )")" \
        "\"cert\": $(j_obj '        ' \
            "\"hy2_crt_present\": $( [[ -s ${SB_DIR}/cert.crt ]] && printf true || printf false )" \
            "$(j_kv hy2_cert_enddate "${_hy2_end:-}")")"
    printf '\n'
}

# ---------- §14d --uninstall：干净下线代理 ----------
# 反向拆除本脚本部署的代理组件；管理通道（SSH 加固、fail2ban）一律保留。
# 每步只删除「本脚本部署」的固定路径，删除失败只告警不中断，保证能走到防火墙清理。
ipt_un() { # ipt_un <iptables-cmd> <args...>  规则存在才删除，幂等
    # -C 只判"存在"，-D 只删第一条。历史重跑（或镜像自带同名规则）可能留下多条，
    # 只删一次会残留，卸载后规则依旧生效 —— 这里循环删到 -C 不再匹配为止。
    # 删除失败/超限计入全局 IPT_UN_FAIL（调用方如 --uninstall 据实汇报），自身仍返回 0
    # （m_firewall 的降级语义是"只告警不中断"，返回值变化会被 set -e 放大成中断）。
    local cmd="$1"; shift
    local n=0
    IPT_UN_FAIL="${IPT_UN_FAIL:-0}"
    while "$cmd" -C "$@" 2>/dev/null; do
        if "$cmd" -D "$@" 2>/dev/null; then
            n=$((n+1))
        else
            warn "规则删除失败（请手动清理）: $cmd -D $*"
            IPT_UN_FAIL=$((IPT_UN_FAIL+1))
            break
        fi
        (( n < 32 )) || { warn "规则重复过多（>32 条），已停止清理: $cmd $*"; IPT_UN_FAIL=$((IPT_UN_FAIL+1)); break; }
    done
    return 0
}

# Caddyfile 是否由本脚本写入（回落站）：签名是 tls 指令引用 ${SB_DIR}/cert/ 下的证书。
# 带路径参数便于回归测试；非脚本写入的 Caddyfile（用户自建站点）绝不改动。
caddyfile_is_ours() {
    local f="${1:-/etc/caddy/Caddyfile}"
    [[ -f $f ]] || return 1
    grep -q "${SB_DIR}/cert/" "$f" 2>/dev/null
}

# 写路径实例互斥：两个实例并发跑会交错写 state.env / config.json / iptables，
# 结果不可预测（后写的凭据覆盖先写的、防火墙规则半套）。用 flock 独占锁挡住。
# 锁文件在 STATE_DIR 下（root 属主），fd 9 随进程退出自动释放，无需手动清理。
# 读路径（--status / --doctor / --print-* / --self-test）不取锁：只读不冲突。
acquire_instance_lock() {
    command -v flock >/dev/null 2>&1 || { warn "本机无 flock，跳过实例互斥；请勿同时运行多个本脚本实例"; return 0; }
    if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
        warn "无法创建 ${STATE_DIR}，跳过实例互斥"
        return 0
    fi
    if ! exec 9>>"${STATE_DIR}/.instance.lock" 2>/dev/null; then
        warn "实例锁文件不可写（${STATE_DIR}/.instance.lock），跳过互斥"
        return 0
    fi
    if ! flock -n 9; then
        die "检测到另一个本脚本实例正在运行（锁：${STATE_DIR}/.instance.lock）。请等它结束后再执行写操作；若确认没有，可删除该锁文件后重试。"
    fi
}

cmd_uninstall() {
    if [[ -z ${ASSUME_YES:-} ]]; then
        hr; printf '  --uninstall 将执行以下拆除（管理通道保留）：\n'
        printf '    1. 停用并移除 sing-box（服务 / 二进制 / systemd 单元）\n'
        printf '    2. 删除 %s（服务端配置 + hy2 自签证书 + 回落证书）\n' "$SB_DIR"
        printf '    3. 拆除回落站：停用 caddy、删除本脚本写入的 Caddyfile 与伪装站页面\n'
        printf '       （回落站是代理组件：其证书就在 %s 里，删证书后 Caddy 必然起不来）\n' "$SB_DIR"
        printf '    4. 删除 /root/vps-init.info / vps-init.client-outbounds.json（含凭据明文）\n'
        printf '    5. 清除防火墙代理端口放行（vless / hy2 / fallback / 80 / 跳跃段）与跳跃 DNAT\n'
        printf '    6. 状态文件：写入「只做管理」或按 --purge-state 删除\n'
        printf '    保留：SSH 加固与放行规则、fail2ban、tcpfit、系统基线（caddy 程序本体也保留）。\n'
        printf '    state.env 保留供日后重部署（加 --purge-state 一并删除）。\n'
        hr
        if [[ -t 0 || -p /dev/stdin || -f /dev/stdin ]]; then
            ask_yn "确认拆除本机的 sing-box 代理部署？" n || die "已取消（未做任何改动）"
        else
            die "非交互环境执行 --uninstall 必须显式加 --yes 确认"
        fi
    fi

    info "==> [卸载 1/6] 停用并移除 sing-box"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now sing-box >/dev/null 2>&1 || true
        rm -rf /etc/systemd/system/sing-box.service.d
        [[ -f /etc/systemd/system/sing-box.service ]] && { rm -f /etc/systemd/system/sing-box.service; systemctl daemon-reload; } || true
        systemctl reset-failed sing-box 2>/dev/null || true
    fi
    if command -v sing-box >/dev/null 2>&1; then
        local sb_bin; sb_bin="$(command -v sing-box)"
        if dpkg -s sing-box >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get -y purge sing-box >/dev/null 2>&1 || true
        elif [[ $sb_bin == /usr/local/bin/* || $sb_bin == /usr/bin/* ]]; then
            rm -f "$sb_bin"
        fi
        ok "sing-box 已移除（原路径 $sb_bin）"
    else
        info "sing-box 未安装，跳过"
    fi

    info "==> [卸载 2/6] 删除服务端配置与证书"
    if [[ -d $SB_DIR ]]; then
        rm -rf "$SB_DIR"
        ok "已删除 $SB_DIR"
    else
        info "$SB_DIR 不存在，跳过"
    fi

    info "==> [卸载 3/6] 拆除回落站（本脚本部署的 Caddy 配置）"
    # 回落站是代理部署的一部分：Caddyfile 的 tls 指令引用 $SB_DIR/cert/ 下的证书，
    # 上一步删除后 Caddy 一旦重启就因证书缺失起不来；FALLBACK_PORT 放行也会被清除，
    # 「保留一个连不上、起不来的 Caddy」毫无意义 —— 本脚本部署的一并拆除才干净。
    # 只拆「确认为本脚本写入」的 Caddyfile（签名：引用 $SB_DIR/cert/）；用户自建站点不动。
    if caddyfile_is_ours; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable --now caddy >/dev/null 2>&1 || true
        fi
        rm -f /etc/caddy/Caddyfile /root/.vps-init.Caddyfile.bak
        if [[ -f ${WEB_ROOT}/index.html ]]; then
            rm -f "${WEB_ROOT}/index.html"
            ok "已删除伪装站页面 ${WEB_ROOT}/index.html"
        fi
        ok "回落站已拆除：caddy 服务已停用，站点配置已移除"
        command -v caddy >/dev/null 2>&1 && \
            info "caddy 程序本体保留；不再需要请执行: apt-get purge caddy"
        # 证书随 $SB_DIR 已删除，acme.sh 的续期任务会一直报错 —— 明确提醒清理
        if [[ -d "$HOME/.acme.sh" && -n ${DOMAIN:-} ]]; then
            warn "acme.sh 续期任务仍在（~/.acme.sh），会尝试续签已删除的 ${DOMAIN} 证书；请执行: ~/.acme.sh/acme.sh --remove -d ${DOMAIN}"
        fi
    elif [[ -f /etc/caddy/Caddyfile ]]; then
        info "检测到非本脚本部署的 Caddy 配置，未改动（若其引用了 $SB_DIR 下的证书，请自行调整）"
    else
        info "未部署 Caddy 回落站，跳过"
    fi

    info "==> [卸载 4/6] 删除 /root 交付文件（含凭据明文）"
    local _f
    for _f in /root/vps-init.info /root/vps-init.client-outbounds.json; do
        if [[ -f $_f ]]; then rm -f "$_f"; ok "已删除 $_f"; else info "$_f 不存在，跳过"; fi
    done
    if compgen -G '/root/.vps-init.config.json.*.bak' >/dev/null; then
        warn "历史配置备份仍保留：/root/.vps-init.config.json.*.bak（含旧凭据，确认不再需要请手动删除）"
    fi
    if [[ -d $CACHE_DIR ]]; then rm -rf "$CACHE_DIR"; ok "已清理下载缓存 $CACHE_DIR"; fi

    info "==> [卸载 5/6] 清除防火墙代理端口规则与跳跃 DNAT"
    local _fw
    for _fw in iptables ip6tables; do
        command -v "$_fw" >/dev/null 2>&1 || continue
        "$_fw" -L -n >/dev/null 2>&1 || continue
        ipt_un "$_fw" INPUT -p tcp --dport "$VLESS_PORT" -j ACCEPT
        ipt_un "$_fw" INPUT -p tcp --dport "$FALLBACK_PORT" -j ACCEPT
        ipt_un "$_fw" INPUT -p udp --dport "$HY2_PORT" -j ACCEPT
        ipt_un "$_fw" INPUT -p tcp --dport 80 -j ACCEPT
        if [[ -n ${HOP_RANGE:-} ]]; then
            ipt_un "$_fw" INPUT -p udp --dport "$HOP_RANGE" -j ACCEPT
            ipt_un "$_fw" -t nat PREROUTING -p udp --dport "$HOP_RANGE" -j DNAT --to-destination ":${HY2_PORT}"
        fi
        ipt_un "$_fw" -t nat PREROUTING -p udp --dport "$HY2_PORT" -j DNAT --to-destination ":${HY2_PORT}"
    done
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 && ok "防火墙规则已持久化（重启后同样生效）" \
            || warn "netfilter-persistent save 失败：重启后已删规则可能回来，请手动检查"
    else
        info "本机无 netfilter-persistent：无开机恢复的规则集，已删规则重启后不会回来"
    fi
    # 删除规则后立刻复核 SSH 放行仍然在位（绝不能因为卸载把管理通道拆掉）
    local _chk _chk_fw _miss_p _miss=0
    for _chk in 4 6; do
        [[ $_chk == 6 ]] && { command -v ip6tables >/dev/null 2>&1 && ip6tables -L -n >/dev/null 2>&1 || continue; }
        while read -r _miss_p; do
            [[ -n $_miss_p ]] || continue
            if [[ $_chk == 4 ]]; then _chk_fw=iptables; else _chk_fw=ip6tables; fi
            "$_chk_fw" -C INPUT -p tcp --dport "$_miss_p" -j ACCEPT 2>/dev/null || { _miss=1; warn "SSH 放行规则缺失：${_chk_fw} INPUT tcp/${_miss_p}"; }
        done < <(ssh_ports_for_family "$_chk")
    done
    (( _miss == 0 )) && ok "SSH 管理通道放行规则复核通过"

    info "==> [卸载 6/6] 状态文件处理"
    if [[ ${PURGE_STATE:-0} -eq 1 ]]; then
        if [[ -f $STATE_FILE ]]; then rm -f "$STATE_FILE"; ok "已删除 $STATE_FILE"; else info "$STATE_FILE 不存在"; fi
    else
        MANAGE_ONLY=1; save_state
        ok "已把「只做管理」写入 ${STATE_FILE}（日后重跑不会再部署代理；彻底清除请加 --purge-state）"
    fi

    hr
    # 收尾必须据实：删除失败 / SSH 复核缺失时报出未竟项并以非零退出，
    # 否则「卸载完成」与实际残留状态矛盾。
    if [[ ${IPT_UN_FAIL:-0} -gt 0 || $_miss -gt 0 ]]; then
        err "卸载未完全成功：${IPT_UN_FAIL:-0} 条规则删除失败 / SSH 放行复核 ${_miss} 处缺失，请按上方告警手动处理"
        return 1
    fi
    ok "卸载完成：sing-box / 配置 / 证书 / 回落站 / 交付文件 / 代理防火墙规则已清除"
    printf '  保留组件：SSH 加固、fail2ban、tcpfit；caddy 程序本体保留（不再需要: apt-get purge caddy）。\n'
    printf '  INPUT 默认策略保持 DROP（更安全）；如需恢复 ACCEPT 请手动执行：iptables -P INPUT ACCEPT\n'
    return 0
}


# ============================================================
# §15 内置自检 --self-test
# ============================================================
# 设计约束（很重要：自检本身不能变成新的故障源）
#   1) 零副作用：不联网、不写 /etc 与 /root、不动 iptables、不碰状态文件；
#   2) 不需要 root、不需要 systemd；
#   3) 支持 `curl … | bash -s -- --self-test`，因此不依赖脚本自身的磁盘路径；
#   4) 只断言纯 bash 能判断的东西；JSON 语法校验尽力而为（有 python3/jq/sing-box 就做，
#      否则退回到"括号配平 + 字符串内无裸换行"的兜底检查）。
# 返回 0 表示全部通过。

ST_PASS=0
ST_FAIL=0
ST_SKIP=0
st_ok()  { ST_PASS=$((ST_PASS+1)); printf '  %sPASS%s  %s\n' "$C_G" "$C_N" "$1"; }
# 跳过 ≠ 通过：组件缺失时没跑过的断言不能混进 PASS 计数，否则「全绿」名不副实
st_skip() { ST_SKIP=$((ST_SKIP+1)); printf '  %sSKIP%s  %s\n' "$C_Y" "$C_N" "$1"; }
st_bad() { ST_FAIL=$((ST_FAIL+1)); printf '  %sFAIL%s  %s\n        期望=[%s]\n        实际=[%s]\n' "$C_R" "$C_N" "$1" "$2" "$3"; }
st_eq()  { if [[ "$2" == "$3" ]]; then st_ok "$1"; else st_bad "$1" "$2" "$3"; fi; }
# 断言某个调用会被拒绝（die）——放进子 shell 跑，免得把自检自己干掉
st_rejects() { local d="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then st_bad "$d（应被拒绝）" "非 0 退出" "0"; else st_ok "$d"; fi; }
st_accepts() { local d="$1"; shift; if ( "$@" ) >/dev/null 2>&1; then st_ok "$d"; else st_bad "$d" "0 退出" "非 0"; fi; }

# 极简 JSON 结构自检：字符串之外的 {} [] 必须配平，字符串内部不允许出现裸换行。
# 不是完整解析器，只用于在没有 python/jq/sing-box 的机器上兜住"括号没闭上/引号没配上"这类低级错误。
json_balance_ok() {
    local s="$1"
    # 空输入不是「配平」，是「什么都没产出」——必须判失败，
    # 否则渲染函数返回空串时这两条断言会假通过。
    [[ -n $s ]] || return 1
    local i=0 n=${#s} c depth=0 in_str=0 esc=0
    while (( i < n )); do
        c="${s:i:1}"
        if (( in_str )); then
            if (( esc )); then esc=0
            elif [[ $c == "\\" ]]; then esc=1
            elif [[ $c == '"' ]]; then in_str=0
            elif [[ $c == $'\n' || $c == $'\r' ]]; then return 1
            fi
        else
            case "$c" in
                '"')      in_str=1;;
                '{'|'[')  depth=$((depth+1));;
                '}'|']')  depth=$((depth-1)); (( depth < 0 )) && return 1;;
                *[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']*) return 1;;
            esac
        fi
        i=$((i+1))
    done
    (( depth == 0 && in_str == 0 ))
}

self_test() {
    hr
    printf '  vps-init.sh 内置自检 —— 只读，不联网，不修改系统\n'
    hr

    # ---------- 1) 语法 ----------
    info "1) 语法"
    if [[ -r ${BASH_SOURCE[0]:-} ]]; then
        if "${BASH:-bash}" -n "${BASH_SOURCE[0]}"; then st_ok "bash -n 语法通过"; else st_bad "bash -n 语法" "通过" "有不合法语法"; fi
    else
        warn "  脚本来自 stdin，无法读取自身路径，跳过语法检查"
    fi

    # ---------- 2) 取值白名单 / 边界 ----------
    info "2) 取值白名单与边界"
    st_rejects "端口 abc 被拒"            need_port --p abc
    st_rejects "端口 0 被拒"              need_port --p 0
    st_rejects "端口 70000 被拒"          need_port --p 70000
    st_accepts "端口 443 通过"            need_port --p 443
    st_rejects "时长 15（漏单位）被拒"     need_duration --d 15
    st_accepts "时长 15s 通过"            need_duration --d 15s
    st_rejects "域名含引号被拒"           need_hostname --domain 'a"b.com'
    st_accepts "域名 a.example.com 通过"  need_hostname --domain a.example.com
    st_rejects "UUID 非法被拒"            is_uuid not-a-uuid
    st_accepts "UUID 合法通过"            is_uuid 11111111-2222-4333-8444-555555555555
    st_rejects "速率含空格被拒"           is_rate '1000 mbit'
    st_accepts "速率 1000mbit 通过"       is_rate 1000mbit

    local saved_hop="$HOP_RANGE"
    HOP_RANGE="30000:50000"; st_accepts "跳跃范围 A:B 通过"   need_hop_range
    HOP_RANGE="30000-50000"; st_rejects "跳跃范围连字符被拒"  need_hop_range
    HOP_RANGE="50000:30000"; st_rejects "跳跃范围倒序被拒"    need_hop_range
    HOP_RANGE="$saved_hop"

    # 2b) CLI 可达性：校验函数在报错里引用的选项，必须真的能传、且登记到正确的变量。
    # 曾经出现过 need_duration "--tcp-keep-alive-int" 却没有任何对应分支/mark_cli 映射的情况，
    # 用户照着报错去传参只会得到「未知参数」，且 state.env 还会把值覆盖回去。
    local _self_src=""
    [[ -r ${BASH_SOURCE[0]:-} ]] && _self_src="$(<"${BASH_SOURCE[0]}")"
    if [[ -n $_self_src ]]; then
        st_eq '报错引用的 --tcp-keep-alive-int 有 CLI 分支' '1' \
            "$([[ $_self_src == *'--tcp-keep-alive-int)'* ]] && echo 1 || echo 0)"
        st_eq '--help 列出了两个 TCP 保活参数' '1' \
            "$([[ $_self_src == *'--tcp-keep-alive D'* && $_self_src == *'--tcp-keep-alive-int D'* ]] && echo 1 || echo 0)"
    fi
    st_eq 'mark_cli 把 --tcp-keep-alive-int 映射到 TCP_KEEP_ALIVE_INTERVAL' '1' \
        "$( unset 'CLI_SET[TCP_KEEP_ALIVE_INTERVAL]'; mark_cli --tcp-keep-alive-int; \
            [[ -n ${CLI_SET[TCP_KEEP_ALIVE_INTERVAL]:-} ]] && echo 1 || echo 0 )"

    # 2c) hy2 监听决策：单 IP 绝不把公网地址写进 listen，只有同族多地址才按 IP 拆分。
    # 每个用例都在子 shell 里跑，不污染自检自身的 NODE_IPS / BIND_ALL / BIND_MAP。
    st_eq '单 v4 → hy2 监听 0.0.0.0' '0.0.0.0' \
        "$( NODE_IPS=(1.2.3.4); BIND_ALL=''; BIND_MAP=(); hy2_listen_addrs; printf '%s' "${HY2_LISTEN_ADDRS[*]}" )"
    st_eq '单 v4 → 不按 IP 拆分' '0' \
        "$( NODE_IPS=(1.2.3.4); BIND_ALL=''; BIND_MAP=(); hy2_listen_addrs; printf '%s' "$HY2_SPLIT_BY_IP" )"
    st_eq '单 v4 → listen 不含该公网地址' '0' \
        "$( NODE_IPS=(1.2.3.4); BIND_ALL=''; BIND_MAP=(); hy2_listen_addrs; \
            [[ " ${HY2_LISTEN_ADDRS[*]} " == *' 1.2.3.4 '* ]] && echo 1 || echo 0 )"
    st_eq '单 v6 → hy2 监听 ::' '::' \
        "$( NODE_IPS=(2001:db8::1); BIND_ALL=''; BIND_MAP=(); hy2_listen_addrs; printf '%s' "${HY2_LISTEN_ADDRS[*]}" )"
    st_eq 'v4+v6 各一 → hy2 监听 ::' '::' \
        "$( NODE_IPS=(1.2.3.4 2001:db8::1); BIND_ALL=''; BIND_MAP=(); hy2_listen_addrs; printf '%s' "${HY2_LISTEN_ADDRS[*]}" )"
    st_eq '多 v4 → 按 IP 拆分且标志置 1' '1:1.1.1.1 2.2.2.2' \
        "$( NODE_IPS=(1.1.1.1 2.2.2.2); BIND_ALL=''; BIND_MAP=(); hy2_listen_addrs; \
            printf '%s:%s' "$HY2_SPLIT_BY_IP" "${HY2_LISTEN_ADDRS[*]}" )"

    # 2d) NAT 机型检测与固定端口适配。全部在子 shell 里用桩替换 collect_local_addrs，
    #     不联网、不读本机网卡、不改任何系统状态。
    st_eq '本机 v4 只有私网地址 → 判定 NAT' '1' \
        "$( collect_local_addrs() { printf '%s\n' '10.0.0.5'; }; \
            BIND_MAP=(); NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; detect_nat; printf '%s' "$NAT_ACTIVE" )"
    st_eq '本机直挂公网地址 → 不判定 NAT' '0' \
        "$( collect_local_addrs() { printf '%s\n' '1.2.3.4' '2001:db8::1'; }; \
            BIND_MAP=(); NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; detect_nat; printf '%s' "$NAT_ACTIVE" )"
    st_eq '--no-nat 覆盖自动检测' '0' \
        "$( collect_local_addrs() { printf '%s\n' '10.0.0.5'; }; \
            BIND_MAP=(); NAT_MODE=off; NAT_PORTS=''; NAT_MAP=''; detect_nat; printf '%s' "$NAT_ACTIVE" )"
    st_eq '--nat 强制开启' '1' \
        "$( collect_local_addrs() { printf '%s\n' '1.2.3.4'; }; \
            BIND_MAP=(); NAT_MODE=force; NAT_PORTS=''; NAT_MAP=''; detect_nat; printf '%s' "$NAT_ACTIVE" )"
    st_eq '给了 --nat-map 即按 NAT 处理' '1' \
        "$( collect_local_addrs() { printf '%s\n' '1.2.3.4'; }; \
            BIND_MAP=(); NAT_MODE=auto; NAT_PORTS=''; NAT_MAP='vless=30443'; detect_nat; printf '%s' "$NAT_ACTIVE" )"
    st_accepts '--nat-ports 单端口通过'        need_nat_ports 30443
    st_accepts '--nat-ports 离散端口通过'      need_nat_ports 30022,30443,30444
    st_accepts '--nat-ports 段+单端口混合通过' need_nat_ports 20000:20020,30443
    st_accepts '--nat-ports A:B 通过'          need_nat_ports 20000:20020
    st_rejects '--nat-ports 倒序被拒'          need_nat_ports 30000:20000
    st_rejects '--nat-ports 非数字被拒'        need_nat_ports abc
    st_rejects '--nat-ports 空项被拒'          need_nat_ports '30443,,30444'
    st_rejects '--nat-ports 单端口越界被拒'    need_nat_ports 70000
    st_rejects '--nat-v4-services 非法协议被拒' need_nat_v4_services 'vless,dns'
    st_accepts '--nat-v4-services 单协议通过'   need_nat_v4_services 'vless'
    st_accepts '--nat-v4-services 双协议通过'   need_nat_v4_services 'vless,hy2'
    st_accepts '--nat-v4-services ssh-only 通过' need_nat_v4_services 'ssh-only'
    st_accepts '--nat-v6-services ssh-only 通过' need_nat_v6_services 'ssh-only'
    st_rejects 'ssh-only 与 vless 混用被拒'     need_nat_v4_services 'ssh-only,vless'
    st_rejects 'v6 ssh-only 与 hy2 混用被拒'    need_nat_v6_services 'hy2,ssh-only'
    st_eq '两族都 ssh-only → 前置拦截返回非 0' '1' \
        "$( MANAGE_ONLY=0; NAT_V4_SERVICES=ssh-only; NAT_V6_SERVICES=ssh-only; \
            ( die_if_no_proxy_family ) >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && echo 1 || echo 0 )"
    st_eq '单族 ssh-only 不误拦' '0' \
        "$( MANAGE_ONLY=0; NAT_V4_SERVICES=ssh-only; NAT_V6_SERVICES=''; \
            die_if_no_proxy_family >/dev/null 2>&1; printf '%s' "$?" )"
    st_eq 'MANAGE_ONLY 已进 STATE_KEYS（重跑沿用）' '1' \
        "$( [[ " ${STATE_KEYS[*]} " == *' MANAGE_ONLY '* ]] && echo 1 || echo 0 )"
    st_eq '只做管理全模块 → 只保留 1/2/4，取消 6 个' '1 1 0 1 0 0 0 0 0:6' \
        "$( MOD_ON=(1 1 1 1 1 1 1 1 1); apply_manage_only_modules; \
            printf '%s:%s' "${MOD_ON[*]}" "$MANAGE_ONLY_DROPPED" )"
    st_eq '模块裁剪幂等（第二次 dropped=0）' '1 1 0 1 0 0 0 0 0:0' \
        "$( MOD_ON=(1 1 1 1 1 1 1 1 1); apply_manage_only_modules; apply_manage_only_modules; \
            printf '%s:%s' "${MOD_ON[*]}" "$MANAGE_ONLY_DROPPED" )"
    st_eq '只选 1/4 时不被强加管理模块' '1 0 0 1 0 0 0 0 0:0' \
        "$( MOD_ON=(1 0 0 1 0 0 0 0 0); apply_manage_only_modules; \
            printf '%s:%s' "${MOD_ON[*]}" "$MANAGE_ONLY_DROPPED" )"
    st_eq '只做管理时两族 ssh-only 不再被拦' '0' \
        "$( MANAGE_ONLY=1; NAT_V4_SERVICES=ssh-only; NAT_V6_SERVICES=ssh-only; \
            die_if_no_proxy_family >/dev/null 2>&1; printf '%s' "$?" )"
    st_eq 'nat_ports_contains 离散端口命中' '1' \
        "$( NAT_PORTS='30022,30443,30444'; nat_ports_contains 30443 && echo 1 || echo 0 )"
    st_eq 'nat_ports_contains 端口段内命中' '1' \
        "$( NAT_PORTS='20000:20020,30443'; nat_ports_contains 20010 && echo 1 || echo 0 )"
    st_eq 'nat_ports_contains 不在清单被拒' '0' \
        "$( NAT_PORTS='30022,30443,30444'; nat_ports_contains 30445 && echo 1 || echo 0 )"
    st_eq 'nat_ports_contains 未给清单时放行' '1' \
        "$( NAT_PORTS=''; nat_ports_contains 30445 && echo 1 || echo 0 )"
    st_rejects '--nat-map 未知服务被拒'   parse_nat_map 'foo=123'
    st_rejects '--nat-map 端口非法被拒'   parse_nat_map 'vless=abc'
    st_accepts '--nat-map 合法映射通过'   parse_nat_map 'vless=30443,hy2=30444'
    st_eq '共用外部端口时给出警告' '1' \
        "$( parse_nat_map 'vless=30443,hy2=30443' 2>&1 | grep -c '被多个服务共用' )"
    st_eq '不共用端口时无该警告' '0' \
        "$( parse_nat_map 'vless=30443,hy2=30444' 2>&1 | grep -c '被多个服务共用' )"
    st_eq 'NAT + v4 → 客户端用外部端口' '30443' \
        "$( NAT_ACTIVE=1; parse_nat_map 'vless=30443,hy2=30444,ssh=30022' >/dev/null 2>&1; \
            VLESS_PORT=443; client_port_for vless 1.2.3.4 )"
    st_eq 'NAT + v6 直连 → 仍用内部端口' '443' \
        "$( NAT_ACTIVE=1; parse_nat_map 'vless=30443' >/dev/null 2>&1; \
            VLESS_PORT=443; client_port_for vless 2001:db8::1 )"
    st_eq '非 NAT → 一律用内部端口' '443' \
        "$( NAT_ACTIVE=0; parse_nat_map 'vless=30443' >/dev/null 2>&1; \
            VLESS_PORT=443; client_port_for vless 1.2.3.4 )"
    st_eq 'NAT 但未登记映射 → 用内部端口（内外同号）' '16407' \
        "$( NAT_ACTIVE=1; parse_nat_map '' >/dev/null 2>&1; \
            HY2_PORT=16407; client_port_for hy2 1.2.3.4 )"
    st_eq '省略 ip 视为 v4 客户端（SSH 提示用）' '30022' \
        "$( NAT_ACTIVE=1; parse_nat_map 'ssh=30022' >/dev/null 2>&1; \
            SSH_PORT=22; client_port_for ssh )"
    st_eq '非 NAT：跳跃段对所有地址生效' '30000:50000' \
        "$( NAT_ACTIVE=0; NAT_V6_OPEN=0; HOP_RANGE='30000:50000'; hop_range_for_ip 1.2.3.4 )"
    st_eq '整机受限 NAT：v4 不套跳跃段' '' \
        "$( NAT_ACTIVE=1; NAT_V6_OPEN=0; HOP_RANGE='30000:50000'; hop_range_for_ip 1.2.3.4 )"
    st_eq 'v6 全开放 NAT：v6 仍用跳跃段' '30000:50000' \
        "$( NAT_ACTIVE=1; NAT_V6_OPEN=1; HOP_RANGE='30000:50000'; hop_range_for_ip 2001:db8::1 )"
    st_eq 'v6 全开放 NAT：v4 不套跳跃段' '' \
        "$( NAT_ACTIVE=1; NAT_V6_OPEN=1; HOP_RANGE='30000:50000'; hop_range_for_ip 1.2.3.4 )"
    st_eq 'v4 端口不足：只留 vless 节点' '1:0' \
        "$( NAT_ACTIVE=1; NAT_V4_SERVICES='vless'; \
            printf '%s:%s' \
              "$(nat_ip_needs 1.2.3.4 vless && echo 1 || echo 0)" \
              "$(nat_ip_needs 1.2.3.4 hy2 && echo 1 || echo 0)" )"
    st_eq 'v4 过滤不影响 v6 节点' '1' \
        "$( NAT_ACTIVE=1; NAT_V4_SERVICES='vless'; \
            nat_ip_needs 2001:db8::1 hy2 && echo 1 || echo 0 )"
    st_eq 'v4 过滤不影响占位符与未指定时' '1' \
        "$( NAT_ACTIVE=1; NAT_V4_SERVICES=''; \
            nat_ip_needs '<服务器IP>' hy2 && echo 1 || echo 0 )"
    st_eq 'v4 ssh-only：vless / hy2 都不生成' '0:0' \
        "$( NAT_ACTIVE=1; NAT_V4_SERVICES='ssh-only'; printf '%s:%s' \
            "$(nat_ip_needs 1.2.3.4 vless && echo 1 || echo 0)" \
            "$(nat_ip_needs 1.2.3.4 hy2 && echo 1 || echo 0)" )"
    st_eq 'ssh-only 对占位符 IP 同样生效' '0' \
        "$( NAT_ACTIVE=1; NAT_V4_SERVICES='ssh-only'; \
            nat_ip_needs '<服务器IP>' vless && echo 1 || echo 0 )"
    st_eq 'v6 ssh-only：v6 两协议都不生成' '0:0' \
        "$( NAT_ACTIVE=1; NAT_V6_SERVICES='ssh-only'; printf '%s:%s' \
            "$(nat_ip_needs 2001:db8::1 vless && echo 1 || echo 0)" \
            "$(nat_ip_needs 2001:db8::1 hy2 && echo 1 || echo 0)" )"
    st_eq 'v6 ssh-only 不影响 v4 节点' '1' \
        "$( NAT_ACTIVE=1; NAT_V6_SERVICES='ssh-only'; \
            nat_ip_needs 1.2.3.4 hy2 && echo 1 || echo 0 )"
    st_eq 'NAT 自动关闭默认端口跳跃' '' \
        "$( collect_local_addrs() { printf '%s\n' '10.0.0.5'; }; BIND_MAP=(); CLI_SET=(); \
            NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; \
            HOP_RANGE='30000:50000'; \
            VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=51736; \
            apply_nat_adaptation >/dev/null 2>&1; printf '%s' "$HOP_RANGE" )"
    st_eq '显式 --hop-range 时 NAT 不强行关闭' '40000:40100' \
        "$( collect_local_addrs() { printf '%s\n' '10.0.0.5'; }; BIND_MAP=(); \
            CLI_SET=(); CLI_SET[HOP_RANGE]=1; \
            NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; \
            HOP_RANGE='40000:40100'; \
            VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=51736; \
            apply_nat_adaptation >/dev/null 2>&1; printf '%s' "$HOP_RANGE" )"
    st_eq 'v6 全开放 NAT 不清空跳跃段' '30000:50000' \
        "$( collect_local_addrs() { printf '%s\n' '10.0.0.5' '2001:db8::1'; }; BIND_MAP=(); CLI_SET=(); \
            NAT_MODE=auto; NAT_PORTS='30443'; NAT_MAP=''; NAT_V6_OPEN=1; NAT_V4_SERVICES=''; \
            HOP_RANGE='30000:50000'; \
            VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=22; \
            apply_nat_adaptation >/dev/null 2>&1; printf '%s' "$HOP_RANGE" )"
    st_eq 'init_nat_for_render 在 v6 全开放时保留跳跃' '30000:50000' \
        "$( NAT_MAP=''; NAT_MODE=auto; NAT_PORTS=''; NAT_V6_OPEN=1; NAT_V4_SERVICES=''; CLI_SET=(); \
            HOP_RANGE='30000:50000'; init_nat_for_render; printf '%s' "$HOP_RANGE" )"
    st_eq 'NAT 且未显式 --ssh-port → 保持现有 SSH 端口' '22' \
        "$( collect_local_addrs() { printf '%s\n' '10.0.0.5'; }; BIND_MAP=(); CLI_SET=(); \
            sshd() { return 1; }; ss() { return 1; }; \
            NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; HOP_RANGE=''; \
            VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=51736; \
            apply_nat_adaptation >/dev/null 2>&1; printf '%s' "$SSH_PORT" )"
    st_eq 'mark_cli 把 --nat / --no-nat 映射到 NAT_MODE' '1' \
        "$( unset 'CLI_SET[NAT_MODE]'; mark_cli --nat; \
            [[ -n ${CLI_SET[NAT_MODE]:-} ]] && echo 1 || echo 0 )"
    st_eq 'mark_cli 把 --no-nat-v6-open 映射到 NAT_V6_OPEN' '1' \
        "$( unset 'CLI_SET[NAT_V6_OPEN]'; mark_cli --no-nat-v6-open; \
            [[ -n ${CLI_SET[NAT_V6_OPEN]:-} ]] && echo 1 || echo 0 )"
    st_eq 'mark_cli 把 --nat-v4-services 映射到 NAT_V4_SERVICES' '1' \
        "$( unset 'CLI_SET[NAT_V4_SERVICES]'; mark_cli --nat-v4-services; \
            [[ -n ${CLI_SET[NAT_V4_SERVICES]:-} ]] && echo 1 || echo 0 )"
    st_eq 'NAT 参数写入 STATE_KEYS（重跑无需重填）' '1' \
        "$( [[ " ${STATE_KEYS[*]} " == *' NAT_MODE '* && " ${STATE_KEYS[*]} " == *' NAT_PORTS '* \
              && " ${STATE_KEYS[*]} " == *' NAT_MAP '* && " ${STATE_KEYS[*]} " == *' NAT_V6_OPEN '* \
              && " ${STATE_KEYS[*]} " == *' NAT_V4_SERVICES '* ]] && echo 1 || echo 0 )"

    # ---------- 2e) 交互式分族端口配置（向导 + 按族决策）----------
    info "2e) 交互式分族端口配置"
    st_eq 'nat_join_port_specs 拼接并跳过空项' '20000:20020,30443,31022' \
        "$( nat_join_port_specs '20000:20020' '' ' 30443 ' '31022' )"
    st_accepts 'need_nat_ports 带选项名校验通过' need_nat_ports 30022,30443 --nat-v6-ports
    st_rejects 'need_nat_ports 越界端口被拒'     need_nat_ports 70000 --nat-v6-ports
    st_accepts 'parse_nat_map6 合法映射通过'     parse_nat_map6 'vless=31443,hy2=31444'
    st_rejects 'parse_nat_map6 未知服务被拒'     parse_nat_map6 'foo=31443'
    st_rejects 'parse_nat_map6 端口非法被拒'     parse_nat_map6 'vless=abc'
    st_eq 'v6 受限 → 客户端用 v6 外部端口' '31443' \
        "$( NAT_ACTIVE=1; NAT_V6_OPEN=0; NAT_V4_OPEN=0; \
            parse_nat_map6 'vless=31443,hy2=31444' >/dev/null 2>&1; \
            VLESS_PORT=443; client_port_for vless 2001:db8::1 )"
    st_eq 'v4 全开放 → 客户端用内部端口（不套映射）' '443' \
        "$( NAT_ACTIVE=1; NAT_V4_OPEN=1; NAT_V6_OPEN=0; \
            parse_nat_map 'vless=30443' >/dev/null 2>&1; \
            VLESS_PORT=443; client_port_for vless 1.2.3.4 )"
    st_eq 'v4 全开放 → v6 受限时 v4 仍有跳跃段' '30000:50000' \
        "$( NAT_ACTIVE=1; NAT_V4_OPEN=1; NAT_V6_OPEN=0; HOP_RANGE='30000:50000'; hop_range_for_ip 1.2.3.4 )"
    st_eq 'v4 全开放 → v6 受限时 v6 不跳跃' '' \
        "$( NAT_ACTIVE=1; NAT_V4_OPEN=1; NAT_V6_OPEN=0; HOP_RANGE='30000:50000'; hop_range_for_ip 2001:db8::1 )"
    st_eq 'v6 services 只留 vless（不影响 v4）' '1:0:1' \
        "$( NAT_ACTIVE=1; NAT_V6_OPEN=0; NAT_V4_OPEN=0; NAT_V6_SERVICES='vless'; \
            printf '%s:%s:%s' \
              "$(nat_ip_needs 2001:db8::1 vless && echo 1 || echo 0)" \
              "$(nat_ip_needs 2001:db8::1 hy2 && echo 1 || echo 0)" \
              "$(nat_ip_needs 1.2.3.4 hy2 && echo 1 || echo 0)" )"
    st_eq '两族都全开放且无受限配置 → 按非 NAT 机' '0' \
        "$( collect_local_addrs() { printf '%s\n' '10.0.0.5'; }; BIND_MAP=(); \
            NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_PORTS=''; NAT_V6_MAP=''; \
            NAT_V4_OPEN=1; NAT_V6_OPEN=1; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; \
            detect_nat; printf '%s' "$NAT_ACTIVE" )"
    st_eq 'init_nat_for_render v4 全开放时保留跳跃' '30000:50000' \
        "$( NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_PORTS=''; NAT_V6_MAP=''; \
            NAT_V4_OPEN=1; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; CLI_SET=(); \
            HOP_RANGE='30000:50000'; init_nat_for_render; printf '%s' "$HOP_RANGE" )"
    st_eq 'apply_nat_adaptation v4 全开放时保留跳跃' '30000:50000' \
        "$( collect_local_addrs() { printf '%s\n' '1.2.3.4' '2001:db8::1'; }; BIND_MAP=(); CLI_SET=(); \
            NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_PORTS='31443,31444'; NAT_V6_MAP=''; \
            NAT_V4_OPEN=1; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; \
            HOP_RANGE='30000:50000'; \
            VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=22; \
            apply_nat_adaptation >/dev/null 2>&1; printf '%s' "$HOP_RANGE" )"
    st_eq 'mark_cli --no-nat-v4-open 映射到 NAT_V4_OPEN' '1' \
        "$( unset 'CLI_SET[NAT_V4_OPEN]'; mark_cli --no-nat-v4-open; \
            [[ -n ${CLI_SET[NAT_V4_OPEN]:-} ]] && echo 1 || echo 0 )"
    st_eq 'nat_port_report 受限族无 services 时仍返回 0' '0' \
        "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; \
            nat_port_report >/dev/null 2>&1; printf '%s' "$?" )"
    st_eq '向导开关不写入 STATE_KEYS（不被记住）' '0' \
        "$( [[ " ${STATE_KEYS[*]} " == *' NAT_WIZARD '* ]] && echo 1 || echo 0 )"
    st_eq '新分族参数写入 STATE_KEYS' '1' \
        "$( [[ " ${STATE_KEYS[*]} " == *' NAT_V4_OPEN '* && " ${STATE_KEYS[*]} " == *' NAT_V6_PORTS '* \
              && " ${STATE_KEYS[*]} " == *' NAT_V6_MAP '* && " ${STATE_KEYS[*]} " == *' NAT_V6_SERVICES '* ]] \
            && echo 1 || echo 0 )"

    # ---------- 2b) 分族 SSH 端口 / 机房识别 / tcpfit ----------
    info "2b) 分族 SSH 端口、机房识别与 tcpfit"
    st_eq 'v4 受限族 SSH 用外部端口 20017' '20017' \
        "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=1; \
            parse_nat_map 'ssh=20017' >/dev/null 2>&1; SSH_PORT=51736; ssh_port_for_family 4 )"
    st_eq 'v6 全开放族 SSH 仍用内部端口 51736' '51736' \
        "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=1; \
            parse_nat_map 'ssh=20017' >/dev/null 2>&1; SSH_PORT=51736; ssh_port_for_family 6 )"
    st_eq '非 NAT 两族同用内部端口' '51736' \
        "$( NAT_ACTIVE=0; SSH_PORT=51736; ssh_port_for_family 4 )"
    st_eq 'v4 防火墙同时放行内外 SSH 端口' '1' \
        "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; parse_nat_map 'ssh=20017' >/dev/null 2>&1; \
            SSH_PORT=51736; _s="$(ssh_ports_for_family 4 | tr '\n' ' ')"; \
            [[ $_s == *'51736'* && $_s == *'20017'* ]] && echo 1 || echo 0 )"
    st_eq 'ssh_ports_for_family 显式返回 0（set -e 安全）' '0' \
        "$( NAT_ACTIVE=0; SSH_PORT=51736; ssh_ports_for_family 4 >/dev/null 2>&1; printf '%s' "$?" )"
    st_eq 'v4 ssh-only → 不跑代理' '1' \
        "$( MANAGE_ONLY=0; NAT_V4_SERVICES='ssh-only'; NAT_V6_SERVICES=''; \
            family_runs_proxy 4 && echo 0 || echo 1 )"
    st_eq 'v6 全开放 → 跑代理' '0' \
        "$( MANAGE_ONLY=0; NAT_V4_SERVICES='ssh-only'; NAT_V6_SERVICES=''; \
            family_runs_proxy 6 && echo 0 || echo 1 )"
    st_eq 'MANAGE_ONLY=1 → 两族都不跑代理' '1 1' \
        "$( MANAGE_ONLY=1; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; \
            _a=0; _b=0; family_runs_proxy 4 || _a=1; family_runs_proxy 6 || _b=1; \
            printf '%s %s' "$_a" "$_b" )"
    st_eq '分族策略文案：v4 只做管理' '只做管理（不跑代理）' \
        "$( MANAGE_ONLY=0; NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V4_SERVICES='ssh-only'; \
            NAT_V6_SERVICES=''; family_state_desc 4 )"
    st_eq '分族策略文案：v6 全开放' '端口全开放（按原配置）' \
        "$( MANAGE_ONLY=0; NAT_ACTIVE=1; NAT_V6_OPEN=1; NAT_V4_SERVICES='ssh-only'; \
            NAT_V6_SERVICES=''; family_state_desc 6 )"
    st_eq 'ssh_access_report 分族给出 v4/v6 与内部端口' '1' \
        "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=1; NAT_V4_SERVICES='ssh-only'; \
            NAT_V6_SERVICES=''; MANAGE_ONLY=0; parse_nat_map 'ssh=20017' >/dev/null 2>&1; \
            SSH_PORT=51736; NODE_IPS=('1.2.3.4' '2001:db8::1'); _r="$(ssh_access_report)"; \
            [[ $_r == *'20017'* && $_r == *'51736'* && $_r == *'v4 :'* && $_r == *'v6 :'* ]] && echo 1 || echo 0 )"
    st_eq 'usable_place 接受英文城市、拒绝占位值' '1' \
        "$( usable_place 'Los Angeles' && ! usable_place 'Unknown' && ! usable_place '' && echo 1 || echo 0 )"
    st_eq 'pick_place 中文优先' '东京' "$( pick_place '东京都' 'Tokyo' )"
    st_eq 'pick_place 英文城市兜底' 'Los Angeles' "$( pick_place 'Los Angeles' 'California' )"
    st_eq 'json_pick 兼容带空格的缩进 JSON' 'Los Angeles' \
        "$( json_pick '{"city": "Los Angeles", "region": "California"}' city )"
    st_eq '机房识别默认不弹手动输入' '0' "${LOC_ASK_ENABLED:-0}"
    st_eq 'build_node_tags 在当前 shell 取节点名前缀（不丢 NODE_NAME）' '1' \
        "$( declare -f build_node_tags | grep -qF 'NODE_PREFIX_RESULT' && \
            ! declare -f build_node_tags | grep -qF 'prefix="$(node_prefix' && echo 1 || echo 0 )"
    st_eq 'm_firewall 按族决定代理端口放行' '1' \
        "$( declare -f m_firewall | grep -qF 'family_runs_proxy "$fam"' && echo 1 || echo 0 )"
    st_eq 'm_tcp 安装前校验脚本语法' '1' \
        "$( declare -f m_tcp | grep -qF 'bash -n "$src"' && echo 1 || echo 0 )"
    st_eq 'm_tcp 打印命令不含尖括号占位符' '1' \
        "$( ! declare -f m_tcp | grep -qF '<Mbps>' && ! declare -f m_tcp | grep -qF '<你的带宽Mbps>' && echo 1 || echo 0 )"

    # ---------- 2c) 客户端 server 域名 ----------
    info "2c) 客户端连接域名"
    st_eq 'looks_like_domain 接受域名、拒绝 IP 与裸主机名' '1' \
        "$( looks_like_domain 'node.example.com' && ! looks_like_domain '1.2.3.4' \
            && ! looks_like_domain 'vps' && ! looks_like_domain '' && echo 1 || echo 0 )"
    st_eq 'client_host_for 未给分族域名时两族共用 --client-domain' 'node.example.com/node.example.com' \
        "$( CLIENT_DOMAIN='node.example.com'; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''; \
            CLIENT_DOMAIN_FORCE_IP=0; DOMAIN='other.example.com'; \
            printf '%s/%s' "$(client_host_for '1.2.3.4')" "$(client_host_for '2001:db8::1')" )"
    st_eq 'client_domain_v6 只覆盖 v6 节点' 'node.example.com/v6.example.com' \
        "$( CLIENT_DOMAIN='node.example.com'; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6='v6.example.com'; \
            CLIENT_DOMAIN_FORCE_IP=0; DOMAIN=''; \
            printf '%s/%s' "$(client_host_for '1.2.3.4')" "$(client_host_for '2001:db8::1')" )"
    st_eq 'client_domain_v4 只覆盖 v4 节点' 'v4.example.com/node.example.com' \
        "$( CLIENT_DOMAIN='node.example.com'; CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6=''; \
            CLIENT_DOMAIN_FORCE_IP=0; DOMAIN=''; \
            printf '%s/%s' "$(client_host_for '1.2.3.4')" "$(client_host_for '2001:db8::1')" )"
    st_eq 'v4 / v6 分族独立域名（习惯分开的写法）' 'v4.example.com/v6.example.com' \
        "$( CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6='v6.example.com'; \
            CLIENT_DOMAIN_FORCE_IP=0; DOMAIN=''; \
            printf '%s/%s' "$(client_host_for '1.2.3.4')" "$(client_host_for '2001:db8::1')" )"
    st_eq '分族域名优先于两族共用域名' 'v4.example.com/v6.example.com' \
        "$( CLIENT_DOMAIN='shared.example.com'; CLIENT_DOMAIN_V4='v4.example.com'; \
            CLIENT_DOMAIN_V6='v6.example.com'; CLIENT_DOMAIN_FORCE_IP=0; DOMAIN=''; \
            printf '%s/%s' "$(client_host_for '1.2.3.4')" "$(client_host_for '2001:db8::1')" )"
    st_eq 'client_host_source_for 逐族标注来源' '--client-domain-v4:--client-domain-v6' \
        "$( CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6='v6.example.com'; \
            CLIENT_DOMAIN_FORCE_IP=0; \
            printf '%s:%s' "$(client_host_source_for '1.2.3.4')" "$(client_host_source_for '2001:db8::1')" )"
    st_eq 'client_domain_report 明确区分共用与已分开' '1' \
        "$( declare -f client_domain_report | grep -qF '两族共用' && \
            declare -f client_domain_report | grep -qF 'v4 / v6 已分开' && echo 1 || echo 0 )"
    st_eq 'client_host_for 回退到 --domain' 'fallback.example.com' \
        "$( CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''; CLIENT_DOMAIN_FORCE_IP=0; \
            DOMAIN='fallback.example.com'; client_host_for '1.2.3.4' )"
    st_eq 'client_host_for 不把 IP 形态的 --domain 当域名' '1.2.3.4' \
        "$( CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''; CLIENT_DOMAIN_FORCE_IP=0; \
            DOMAIN='203.0.113.10'; client_host_for '1.2.3.4' )"
    st_eq '--no-client-domain 强制回到 IP' '1.2.3.4' \
        "$( CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''; CLIENT_DOMAIN_FORCE_IP=1; \
            DOMAIN='fallback.example.com'; client_host_for '1.2.3.4' )"
    st_eq '没有任何域名时 client_host_for 用 IP' '2001:db8::1' \
        "$( CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''; CLIENT_DOMAIN_FORCE_IP=0; \
            DOMAIN=''; client_host_for '2001:db8::1' )"
    st_eq 'client_host_uses_domain 判定三种状态' '1:1:0' \
        "$( CLIENT_DOMAIN='node.example.com'; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''; \
            CLIENT_DOMAIN_FORCE_IP=0; DOMAIN=''; \
            client_host_uses_domain && _a=1 || _a=0; \
           CLIENT_DOMAIN=''; DOMAIN='fallback.example.com'; client_host_uses_domain && _b=1 || _b=0; \
           CLIENT_DOMAIN_FORCE_IP=1; client_host_uses_domain && _c=1 || _c=0; \
            printf '%s:%s:%s' "$_a" "$_b" "$_c" )"
    st_eq '只给分族域名也算域名模式' '1' \
        "$( CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6=''; \
            CLIENT_DOMAIN_FORCE_IP=0; DOMAIN=''; client_host_uses_domain && echo 1 || echo 0 )"
    st_eq 'need_client_domain 拒绝 IP 字面量' '1' \
        "$( ( need_client_domain '--client-domain' '1.2.3.4' ) >/dev/null 2>&1; \
            [[ $? -ne 0 ]] && echo 1 || echo 0 )"
    st_eq '客户端域名四个键写入 STATE_KEYS' '1' \
        "$( [[ " ${STATE_KEYS[*]} " == *' CLIENT_DOMAIN '* && " ${STATE_KEYS[*]} " == *' CLIENT_DOMAIN_V4 '* \
              && " ${STATE_KEYS[*]} " == *' CLIENT_DOMAIN_V6 '* \
              && " ${STATE_KEYS[*]} " == *' CLIENT_DOMAIN_FORCE_IP '* ]] && echo 1 || echo 0 )"
    st_eq 'mark_cli --client-domain-v4 也覆盖 FORCE_IP（防状态回填）' '1' \
        "$( unset 'CLI_SET[CLIENT_DOMAIN_V4]' 'CLI_SET[CLIENT_DOMAIN_FORCE_IP]'; mark_cli --client-domain-v4; \
            [[ -n ${CLI_SET[CLIENT_DOMAIN_V4]:-} && -n ${CLI_SET[CLIENT_DOMAIN_FORCE_IP]:-} ]] && echo 1 || echo 0 )"
    st_eq 'mark_cli --client-domain-v6 也覆盖 FORCE_IP（防状态回填）' '1' \
        "$( unset 'CLI_SET[CLIENT_DOMAIN_V6]' 'CLI_SET[CLIENT_DOMAIN_FORCE_IP]'; mark_cli --client-domain-v6; \
            [[ -n ${CLI_SET[CLIENT_DOMAIN_V6]:-} && -n ${CLI_SET[CLIENT_DOMAIN_FORCE_IP]:-} ]] && echo 1 || echo 0 )"
    st_eq 'mark_cli --no-client-domain 覆盖全部四个键' '1' \
        "$( unset 'CLI_SET[CLIENT_DOMAIN]' 'CLI_SET[CLIENT_DOMAIN_V4]' \
                  'CLI_SET[CLIENT_DOMAIN_V6]' 'CLI_SET[CLIENT_DOMAIN_FORCE_IP]'; \
            mark_cli --no-client-domain; \
            [[ -n ${CLI_SET[CLIENT_DOMAIN]:-} && -n ${CLI_SET[CLIENT_DOMAIN_V4]:-} \
               && -n ${CLI_SET[CLIENT_DOMAIN_V6]:-} \
               && -n ${CLI_SET[CLIENT_DOMAIN_FORCE_IP]:-} ]] && echo 1 || echo 0 )"
    st_eq 'restore_client_domain_for_keep 覆盖 v4 专属域名' '1' \
        "$( declare -f restore_client_domain_for_keep | grep -qF 'CLIENT_DOMAIN_V4' && echo 1 || echo 0 )"
    st_eq 'restore_server_params_for_keep 覆盖 DOMAIN / 端口三件套 / 保活 / 跳跃键' '1' \
        "$( declare -f restore_server_params_for_keep | grep -qF 'DOMAIN VLESS_PORT HY2_PORT FALLBACK_PORT REALITY_SNI' && \
            declare -f restore_server_params_for_keep | grep -qF 'HOP_INTERVAL_MAX' && echo 1 || echo 0 )"
    st_eq 'main 的 keep 恢复链包含服务端参数恢复' '1' \
        "$( declare -f main | grep -qF 'restore_server_params_for_keep' && echo 1 || echo 0 )"
    st_eq 'warn_rerun_params_ignored 列出 DOMAIN 组键' '1' \
        "$( declare -f warn_rerun_params_ignored | grep -qF 'DOMAIN REALITY_SNI' && echo 1 || echo 0 )"
    st_eq '写路径有实例互斥锁（flock）' '1' \
        "$( declare -f acquire_instance_lock | grep -qF 'flock' && \
            declare -f main | grep -qF 'acquire_instance_lock' && echo 1 || echo 0 )"
    st_eq 'doctor_port_check 不用 grep -q（防 SIGPIPE 假阴性）' '1' \
        "$( declare -f doctor_port_check | grep -qF 'grep -q' && echo 0 || echo 1 )"
    st_eq 'ask_client_domain 用 is_hostname 挡非法字符' '1' \
        "$( declare -f ask_client_domain | grep -qF 'is_hostname' && echo 1 || echo 0 )"
    st_eq 'NAT 向导保留判断含 SERVICES 键' '1' \
        "$( declare -f interactive_nat_wizard | grep -qF 'NAT_V4_SERVICES:-}' && \
            declare -f interactive_nat_wizard | grep -qF 'NAT_V6_SERVICES:-}' && echo 1 || echo 0 )"
    st_eq '交互式向导会分别询问 v4 / v6 客户端域名' '1' \
        "$( declare -f main | grep -qF 'ask_client_domains' && \
            declare -f ask_client_domains | grep -qF 'v4 节点域名' && \
            declare -f ask_client_domains | grep -qF 'v6 节点域名' && echo 1 || echo 0 )"
    # 交互式询问的验证：ask 在命令替换的子 shell 里执行，计数器 / 标记只能用文件跨 shell 观察。
    # 抽成局部辅助函数，避免在断言字符串里嵌套引号 + 命令替换被 shell 解析破坏。
    # 用子 shell 函数体（(...) 而不是 {...}）：stub 的 ask / save_state 不能污染后面的真实断言。
    _st_ask_probe_noask() (
        local h="${TMPDIR:-/tmp}/ask-hit.$$" r=""
        rm -f "$h"
        ask() { : > "$h"; printf 'x'; }
        ASSUME_YES=1; ask_client_domains >/dev/null 2>&1
        [[ -e $h ]] && r+="1:" || r+="0:"
        rm -f "$h"; ASSUME_YES=''; MODULES_ARG='8'
        ask_client_domains >/dev/null 2>&1
        [[ -e $h ]] && r+="1:" || r+="0:"
        rm -f "$h"; MODULES_ARG=''; stdin_is_tty() { return 1; }
        ask_client_domains >/dev/null 2>&1
        [[ -e $h ]] && r+="1" || r+="0"
        rm -f "$h"
        printf '%s' "$r"
    )
    # 用真实 ask + 管道喂两行输入：第一行是 IP（应被拒），第二行合法（应被采纳）。
    # 不写临时文件，避免 MSYS 下 rm 包装器对带盘符路径的拦截干扰断言。
    _st_ask_probe_retry() (
        ASSUME_YES=''
        printf '1.2.3.4\nv4.example.com\n' | ask_client_domain 'v4 节点域名' ''
    )
    _st_ask_probe_pair() (
        ask() { case "$1" in
                    'v4 节点域名') printf '%s' 'v4.example.com';;
                    'v6 节点域名') printf '%s' 'v6.example.com';;
                    *) printf '%s' "$2";;
                esac; }
        save_state() { :; }
        stdin_is_tty() { return 0; }
        ASSUME_YES=''; MODULES_ARG=''; MANAGE_ONLY=0
        CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''
        CLIENT_DOMAIN_FORCE_IP=1
        ask_client_domains >/dev/null 2>&1
        printf '%s/%s/%s' "$CLIENT_DOMAIN_V4" "$CLIENT_DOMAIN_V6" "$CLIENT_DOMAIN_FORCE_IP"
    )
    _st_ask_probe_clear() (
        ask() { printf -- '-'; }
        save_state() { :; }
        stdin_is_tty() { return 0; }
        ASSUME_YES=''; MODULES_ARG=''; MANAGE_ONLY=0
        CLIENT_DOMAIN='shared.example.com'
        CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6='v6.example.com'
        ask_client_domains >/dev/null 2>&1
        printf '%s/%s/%s' "$CLIENT_DOMAIN" "$CLIENT_DOMAIN_V4" "$CLIENT_DOMAIN_V6"
    )
    st_eq 'ask_client_domains 在 --yes / --modules / 非 TTY 下不提问' '0:0:0' "$(_st_ask_probe_noask)"
    st_eq 'ask_client_domain 拒绝 IP 后重问直到合法' 'v4.example.com' "$(_st_ask_probe_retry)"
    st_eq 'ask_client_domain 输入 - 清空已存值' '' \
        "$( ask() { printf -- '-'; }; ask_client_domain 'v4 节点域名' 'old.example.com' )"
    st_eq 'ask_client_domains 写入两族独立域名并解除 FORCE_IP' 'v4.example.com/v6.example.com/0' \
        "$(_st_ask_probe_pair)"
    st_eq 'ask_client_domains 两族都清空时共用域名一并清掉' '//' "$(_st_ask_probe_clear)"
    st_eq 'keep 模式会恢复客户端域名（防摘要打印不存在的配置）' '1' \
        "$( declare -f main | grep -qF 'restore_client_domain_for_keep' && \
            declare -f restore_client_domain_for_keep | grep -qF 'printf -v' && echo 1 || echo 0 )"
    st_eq 'json_vless_out / json_hy2_out / 分享链接都走 client_host_for' '1' \
        "$( declare -f json_vless_out | grep -qF 'client_host_for' && \
            declare -f json_hy2_out   | grep -qF 'client_host_for' && \
            declare -f vless_link_for | grep -qF 'client_host_for' && \
            declare -f hy2_link_for   | grep -qF 'client_host_for' && echo 1 || echo 0 )"

    # ---------- 3) 私网 / 保留地址判定 ----------
    info "3) 私网与保留地址判定"
    local addr want kind
    while read -r addr want; do
        [[ -n ${addr:-} ]] || continue
        if is_private_addr "$addr"; then kind=private; else kind=public; fi
        st_eq "is_private_addr ${addr}" "$want" "$kind"
    done <<'CASES'
10.0.0.1 private
100.63.0.1 public
100.64.0.1 private
100.127.255.1 private
100.128.0.1 public
172.15.0.1 public
172.31.255.1 private
172.32.0.1 public
192.168.1.1 private
198.51.100.7 private
203.0.113.10 private
1.2.3.4 public
fe80::1 private
febf::1 private
fd00::1 private
2001:db8::1 private
2606:4700::1 public
CASES

    # ---------- 3b) 多 IP 分族独立判定（NAT 机型回归） ----------
    # 回归点：早期实现把 v4/v6 塞进同一个 pub 数组，v6 命中公网就把 v4 的
    # 出口探测分支整个跳过 → 容器（v6 公网 + v4 私网）只出 v6 节点，v4 整组消失。
    info "3b) v4/v6 分族独立判定"
    # 桩化出口探测：v4 → 1.2.3.4，v6 → 2606:4700::2222
    get_public_ip_family() { [[ $1 == 6 ]] && printf '2606:4700::2222' || printf '1.2.3.4'; }
    # 桩化本机网卡地址采集：按 $STUB_LOCAL_ADDRS 逐行输出
    collect_local_addrs() { printf '%s\n' "${STUB_LOCAL_ADDRS[@]}"; }
    local -a STUB_LOCAL_ADDRS=()

    STUB_LOCAL_ADDRS=('172.17.0.5' '2606:4700::1111')
    IP_LIST=""; detect_ips >/dev/null 2>&1
    st_eq 'v6 公网时不丢弃 v4 族' '1.2.3.4 2606:4700::1111' "${NODE_IPS[*]}"

    # 反向场景：v4 公网 + v6 私网，v6 族也必须独立探测
    STUB_LOCAL_ADDRS=('1.2.3.4' 'fe80::1')
    detect_ips >/dev/null 2>&1
    st_eq 'v4 公网时不丢弃 v6 族' '1.2.3.4 2606:4700::2222' "${NODE_IPS[*]}"

    # NAT 机型：对外公布公网地址，但服务端只能 bind 本机落地地址
    STUB_LOCAL_ADDRS=('172.17.0.5' '2606:4700::1111')
    detect_ips >/dev/null 2>&1
    st_eq 'NAT 场景记录 bind 映射' '172.17.0.5' "${BIND_MAP[1.2.3.4]:-}"
    st_eq 'bind_addr_for 换成本机地址' '172.17.0.5' "$(bind_addr_for 1.2.3.4)"
    st_eq '未登记的地址原样返回' '9.9.9.9' "$(bind_addr_for 9.9.9.9)"

    # ---------- 4) JSON 转义与构造器 ----------
    info "4) JSON 转义与构造器"
    st_eq '转义引号'        'a\"b'          "$(json_escape 'a"b')"
    st_eq '转义反斜杠'      'a\\b'          "$(json_escape 'a\b')"
    st_eq '转义制表符'      'a\tb'          "$(json_escape $'a\tb')"
    st_eq '转义换行'        'a\nb'          "$(json_escape $'a\nb')"
    st_eq '控制字符被剔除'  'ab'            "$(json_escape $'a\vb')"
    st_eq 'j_kv 基本'       '"k": "v"'      "$(j_kv k v)"
    st_eq 'j_kv 值已转义'   '"k": "a\"b"'   "$(j_kv k 'a"b')"
    st_eq 'j_lit 数字'      '"p": 443'      "$(j_lit p 443)"
    st_eq 'j_lit 布尔'      '"e": true'     "$(j_lit e true)"
    st_eq 'j_obj 单成员'    $'{\n    "a": 1\n}'                "$(j_obj '' "$(j_lit a 1)")"
    st_eq 'j_obj 两成员自动逗号' $'{\n    "a": 1,\n    "b": 2\n}' "$(j_obj '' "$(j_lit a 1)" "$(j_lit b 2)")"
    st_eq 'j_obj 嵌套缩进'  $'{\n      "a": 1\n  }'            "$(j_obj '  ' "$(j_lit a 1)")"
    st_eq 'j_arr 单元素'    $'[\n    "a"\n]'                  "$(j_arr '' '"a"')"
    st_eq 'j_arr 两元素'    $'[\n    "a",\n    "b"\n]'         "$(j_arr '' '"a"' '"b"')"

    # ---------- 5) 分享链接 ----------
    info "5) 分享链接（编码 / 方括号 / 证书校验）"
    NODE_IPS=('2001:db8::1')
    T_VL=('东京 #1'); T_HY2=('东京 #1')
    VLESS_PORT=443; HY2_PORT=16407; HOP_RANGE=""
    REALITY_SNI="a.example.com"; REALITY_PUB="PBK"; SHORT_ID="0123456789abcdef"
    CERT_CN="bing.com"; CERT_HASH=""
    UUID="11111111-2222-4333-8444-555555555555"
    HY2_PW="p+q/r=s"; OBFS_PW="o+q/r=s"
    local link
    link="$(vless_link_for 0)"
    st_eq 'vless 主机加方括号'   '1' "$([[ $link == *"@[2001:db8::1]:443?"* ]] && echo 1 || echo 0)"
    st_eq 'vless 节点名已编码'   '1' "$([[ $link == *'#东京%20%231'* ]] && echo 1 || echo 0)"
    link="$(hy2_link_for 0)"
    st_eq 'hy2 密码已百分号编码' '1' "$([[ $link == *'p%2Bq%2Fr%3Ds@'* ]] && echo 1 || echo 0)"
    st_eq 'hy2 无指纹降级 insecure' '1' "$([[ $link == *'&insecure=1'* ]] && echo 1 || echo 0)"
    CERT_SHA256="252a35f2ee445063319242ea044c931559d60bdac7f8fd2e5669112b01a7c9dd"
    link="$(hy2_link_for 0)"
    st_eq 'hy2 有证书指纹走 pinSHA256（hex，非公钥哈希）' '1' \
        "$([[ $link == *"&pinSHA256=${CERT_SHA256}"* && $link != *'ab%2Bcd'* ]] && echo 1 || echo 0)"
    CERT_SHA256=""
    HOP_RANGE="30000:50000"
    link="$(hy2_link_for 0)"
    st_eq 'hy2 mport 冒号转连字符' '1' "$([[ $link == *'&mport=30000-50000'* ]] && echo 1 || echo 0)"

    # ---------- 6) 渲染结果的结构 ----------
    info "6) 渲染结果的结构自检"
    NODE_IPS=(1.2.3.4 2001:db8::1)
    BIND_ALL=""; NODE_NAME="selftest"; HOP_RANGE="30000:50000"; CERT_HASH=""
    # 走真实渲染路径（占位值由 fill_render_placeholders 统一补齐）；
    # 这一步同时验证 j_lit 的守卫：漏填端口会立刻报错而不是渲染出空值
    fill_render_placeholders
    local cfg out
    cfg="$(render_config)"
    out="$(render_client_outbounds)"
    st_eq '服务端配置括号/引号配平'   '0' "$(json_balance_ok "$cfg" && echo 0 || echo 1)"
    st_eq '客户端 outbounds 括号配平' '0' "$(json_balance_ok "$out" && echo 0 || echo 1)"

    local checker=""
    if command -v python3 >/dev/null 2>&1; then checker="python3"
    elif command -v python >/dev/null 2>&1; then checker="python"
    elif command -v jq >/dev/null 2>&1; then checker="jq"
    elif command -v sing-box >/dev/null 2>&1; then checker="sing-box"
    fi
    if [[ -z $checker ]]; then
        warn "  无 python3 / jq / sing-box，跳过真正的 JSON 解析（已用括号配平兜底）"
    elif [[ $checker == python3 || $checker == python ]]; then
        if printf '%s' "$cfg" | "$checker" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 \
        && printf '%s' "$out" | "$checker" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
            st_ok "服务端与客户端 JSON 解析通过（${checker}）"
        else
            st_bad "JSON 解析（${checker}）" "两份都合法" "至少一份非法"
        fi
    elif [[ $checker == jq ]]; then
        if printf '%s' "$cfg" | jq -e . >/dev/null 2>&1 \
        && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
            st_ok "服务端与客户端 JSON 解析通过（jq）"
        else
            st_bad "JSON 解析（jq）" "两份都合法" "至少一份非法"
        fi
    else
        local tmp; tmp="$(mktemp)"      # sing-box check 只接受文件
        printf '%s\n' "$cfg" > "$tmp"
        if sing-box check -c "$tmp" >/dev/null 2>&1; then st_ok "sing-box check 通过"
        else st_bad "sing-box check" "通过" "失败"; fi
        rm -f "$tmp"
    fi

    # ---------- 7) 状态存取的自洽性 ----------
    info "7) 状态存取自洽性"
    local orig='a"b\c'
    st_eq 'state_escape/unescape 往返' "$orig" "$(state_unescape "$(state_escape "$orig")")"
    st_eq 'STATE_KEYS 无重复项' '0' "$(printf '%s\n' "${STATE_KEYS[@]}" | sort | uniq -d | wc -l | tr -d ' ')"
    local k missing=""
    for k in "${STATE_KEYS[@]}"; do
        [[ -v $k ]] || missing+=" ${k}"
    done
    st_eq 'STATE_KEYS 每项都有同名变量' '' "$missing"

    # ---------- 8) 工程约定的机器检查 ----------
    info "8) 工程约定"

    # 内置伪装站必须能原样解出：base64 段落若被编辑器截断/改坏，部署时会静默退回
    # 简陋的 "It works" 页而不报错 —— 这里先验一次，保证单文件部署也带着完整页面。
    local _wp_tmp; _wp_tmp="$(mktemp 2>/dev/null || echo /tmp/.vps-init-web.$$)"
    if write_bundled_web_page "$_wp_tmp" 2>/dev/null; then
        st_eq '内置伪装站可解出且是完整 HTML' '1' \
            "$(head -c 200 "$_wp_tmp" | grep -c '<!DOCTYPE html>' || true)"
        st_eq '内置伪装站包含标题与画廊' '1' \
            "$(grep -q '青山' "$_wp_tmp" && echo 1 || echo 0)"
    else
        st_eq '内置伪装站可解出且是完整 HTML' '1' '0'
    fi
    rm -f "$_wp_tmp" 2>/dev/null || true
    if [[ -r ${BASH_SOURCE[0]:-} ]]; then
        # 关键字故意拆开拼接：否则这行检查会匹配到它自己，永远报失败
        local needle="cur""l[^|]*[|][[:space:]]*(s""h|bash)"
        local bare
        bare="$(grep -v '^[[:space:]]*#' "${BASH_SOURCE[0]}" | grep -cE "$needle" || true)"
        st_eq '无裸 curl 管道给 sh 的写法（须走 fetch_file/fetch_stdout）' '0' "${bare:-0}"

        # 「伪续行」检查：脚本化编辑最容易把行尾的续行反斜杠误写成字面序列 反斜杠+n，
        # 而 bash 会把它解析成「转义后的字符 n」—— 于是它悄悄变成命令的一个多余参数
        # （`cmd a b <反斜杠 n> || fallback` 实际执行 `cmd a b n`，第 3 个参数是垃圾）。
        # 这类缺陷 `bash -n` 查不出、桩测试也常因分支未覆盖而漏掉，只有真跑到那一行才出问题，
        # 因此必须用机器检查兜住。正则里用 `[n]` 字符类拼写，避免检查行匹配到自身。
        local stray_n
        stray_n="$(awk '
            /^[[:space:]]*#/ { next }
            {
                line = $0
                while (match(line, /(^|[[:space:]])\\[n]([[:space:]]|$)/)) {
                    c++
                    line = substr(line, RSTART + RLENGTH)
                }
            }
            END { print c + 0 }
        ' "${BASH_SOURCE[0]}")"
        st_eq '不存在「反斜杠 n」伪续行（会变成多余参数）' '0' "${stray_n:-0}"

        # TCP 调优已整体收敛到 tcpfit：脚本自带的 sysctl 固定值、initcwnd 服务、
        # HTB 整形服务都应已删除。两套并存会互相覆盖（tcpfit 写的
        # /etc/sysctl.d/99-tcpfit.conf 与脚本的 99-vps-tune.conf 互相打架）。
        # 用机器检查兜住，防止后续"顺手加回来"。
        # 关键字同样拆开拼写：否则这行检查会匹配到它自己，永远报失败
        local legacy_tune
        legacy_tune="$(grep -v '^[[:space:]]*#' "${BASH_SOURCE[0]}" \
            | grep -cE "99-vps-""tune|vps-init""cwnd|vps-sha""per\.service|vps-init\.sha""per" || true)"
        st_eq 'TCP 调优已收敛到 tcpfit（无手写 sysctl/initcwnd/整形服务）' '0' "${legacy_tune:-0}"

        # CRLF 自愈必须在文件最开头：CRLF 是**解析阶段**就失败，
        # 防护代码若不在最前面，等于没有。这项检查守住它的位置。
        local crlf_pos
        crlf_pos="$(grep -n "grep -q \$'\\\\r'" "${BASH_SOURCE[0]}" | head -n1 | cut -d: -f1 || true)"
        if [[ -n $crlf_pos ]]; then
            st_eq 'CRLF 自愈在文件前 40 行内（解析阶段失败，只有最开头才救得了）' '1' \
                "$([[ $crlf_pos -le 40 ]] && echo 1 || echo 0)"
        else
            st_eq 'CRLF 自愈代码存在' '1' '0'
        fi

        # 关键约束：CRLF 自愈块里**每一行都必须以 # 结尾**。
        # 原因：bash 是"整块解析复合命令"，if/then/fi 必须整块解析成功才执行；
        # 若整份文件是 CRLF，then 会变成 then\r、fi 变成 fi\r → 解析阶段就报错，
        # 自愈代码自己先崩，永远跑不到。行尾挂个 # 注释，\r 落进注释被忽略，
        # 于是无论 LF 还是 CRLF，这块都能解析成功并执行到 exec 重跑。
        local crlf_block_bad
        # 哨兵字符串在源码里拼接，避免这段检查代码本身命中哨兵
        local _sb="CRLF-SELFHEAL"
        crlf_block_bad="$(awk -v B="${_sb}-BEGIN" -v E="${_sb}-END" '
            index($0, B) { inblk=1; next }
            index($0, E) { inblk=0; next }
            inblk==1 {
                line=$0
                sub(/\r$/, "", line)
                if (line ~ /^[[:space:]]*$/) { next }
                # 整行注释：以 # 开头，CR 落在注释里，同样安全
                if (line ~ /^[[:space:]]*#/) { next }
                if (line !~ /#[ \t]*$/) { print NR": "line; exit }
            }
        ' "${BASH_SOURCE[0]}" | wc -l | tr -d ' ')"
        st_eq 'CRLF 自愈块每行以 # 结尾（保证 CRLF 下也能解析）' '0' "${crlf_block_bad:-0}"
    else
        warn "  脚本来自 stdin，跳过源码级约定检查（本节若干项未执行，无法读取自身源码）"
    fi

    # ---------- 9) 证书域名校验（模块 7 复用/防旧证书误判的判据） ----------
    info "9) 证书域名校验"
    if command -v openssl >/dev/null 2>&1; then
        local _cd; _cd="$(mktemp -d 2>/dev/null || true)"
        if [[ -n $_cd ]] && openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout "${_cd}/k.pem" -out "${_cd}/c.pem" \
                -subj '/CN=node1.example.com' -days 1 \
                -addext 'subjectAltName=DNS:node1.example.com,DNS:*.wild.example.com' \
                >/dev/null 2>&1; then
            st_eq '证书 CN 命中当前域名' '0' \
                "$(cert_domain_matches "${_cd}/c.pem" node1.example.com && echo 0 || echo 1)"
            st_eq '证书不匹配其它域名' '1' \
                "$(cert_domain_matches "${_cd}/c.pem" other.example.com && echo 0 || echo 1)"
            st_eq '通配符 SAN 可覆盖子域名' '0' \
                "$(cert_domain_matches "${_cd}/c.pem" a.wild.example.com && echo 0 || echo 1)"
            st_eq '证书文件不存在时判为不匹配' '1' \
                "$(cert_domain_matches "${_cd}/nope.pem" node1.example.com && echo 0 || echo 1)"
        else
            st_skip '本机 openssl 无法生成临时证书，跳过证书校验用例'
        fi
        [[ -n $_cd ]] && rm -rf "$_cd" 2>/dev/null || true
    else
        st_skip '本机无 openssl，跳过证书校验用例'
    fi

    # ---------- 10) 重跑语义 ----------
    info "10) 重跑语义"
    local _saved_dest="$REALITY_DEST" _saved_port="$REALITY_DEST_PORT" _saved_fp="$FALLBACK_PORT"
    FALLBACK_PORT=8443
    REALITY_DEST="127.0.0.1"; REALITY_DEST_PORT="8443"
    st_eq '识别脚本自己写入的本地回落残留' '0' \
        "$(is_local_fallback_state && echo 0 || echo 1)"
    REALITY_DEST="www.caltech.edu"
    st_eq '用户自定义公共站点目标不被重置' '1' \
        "$(is_local_fallback_state && echo 0 || echo 1)"
    REALITY_DEST="127.0.0.1"; REALITY_DEST_PORT="443"
    st_eq '端口与 FALLBACK_PORT 不符时不重置' '1' \
        "$(is_local_fallback_state && echo 0 || echo 1)"
    REALITY_DEST_PORT="8443"; CLI_SET[REALITY_DEST]=1
    st_eq '命令行显式指定的 Reality 目标优先保留' '1' \
        "$(is_local_fallback_state && echo 0 || echo 1)"
    unset 'CLI_SET[REALITY_DEST]'
    st_eq '无状态文件时不打印重跑摘要（首次运行零变化）' '' \
        "$(STATE_FILE="${STATE_FILE}.no-such-rerun-test" report_rerun 2>&1 || true)"
    REALITY_DEST="$_saved_dest"; REALITY_DEST_PORT="$_saved_port"; FALLBACK_PORT="$_saved_fp"

    # 凭据轮换语义：force=0 时保留命令行显式值；force=1（生成新配置）一律清空
    local _su="$UUID" _sp="$REALITY_PRIV" _ss="$SHORT_ID" _miss="" k
    UUID="11111111-2222-3333-4444-555555555555"
    REALITY_PRIV="PRIV_OLD"; SHORT_ID="0123456789abcdef"
    CLI_SET[UUID]=1; CLI_SET[SHORT_ID]=1
    regen_credentials
    st_eq '轮换时保留 CLI 显式指定的 UUID' '11111111-2222-3333-4444-555555555555' "$UUID"
    st_eq '轮换时保留 CLI 显式指定的 short_id' '0123456789abcdef' "$SHORT_ID"
    st_eq '轮换时清空未显式指定的凭据' '' "$REALITY_PRIV"
    st_eq '即使 --uuid 固定 UUID，仍标记为已轮换（其它凭据确实换了）' '1' "$CRED_ROTATED"
    unset 'CLI_SET[UUID]' 'CLI_SET[SHORT_ID]'
    for k in "${CRED_KEYS[@]}"; do
        printf -v "$k" '%s' ''
    done
    regen_credentials
    st_eq '首次运行（凭据全空）不误报轮换' '0' "$CRED_ROTATED"
    for k in "${CRED_KEYS[@]}"; do
        [[ " ${STATE_KEYS[*]} " == *" ${k} "* ]] || _miss+=" ${k}"
    done
    st_eq '所有轮换凭据都在持久化清单里' '' "$_miss"
    UUID="$_su"; REALITY_PRIV="$_sp"; SHORT_ID="$_ss"

    # ---------- 11) 重跑二选一 ----------
    info "11) 重跑二选一"
    local _rm_tmp=""; _rm_tmp="$(mktemp -d 2>/dev/null || true)"
    if [[ -n $_rm_tmp && -d $_rm_tmp ]]; then
        local _s="${_rm_tmp}/state.env" _c="${_rm_tmp}/config.json"
        : > "$_s"; printf '{}\n' > "$_c"
        st_eq '空模式合法（表示尚未选择）' '0' "$(validate_rerun_mode '' && echo 0 || echo 1)"
        st_eq 'keep / new 均为合法模式' '0' \
            "$(validate_rerun_mode keep && validate_rerun_mode new && echo 0 || echo 1)"
        st_eq '非法模式被拒绝' '1' "$(validate_rerun_mode bogus && echo 0 || echo 1)"
        st_eq 'config.json 存在即判定已有部署（state.env 损坏也不能覆盖）' '0' \
            "$( STATE_FILE="${_s}.none"; SB_CONF="$_c"; UUID=''; has_existing_deployment && echo 0 || echo 1 )"
        st_eq '状态文件+有效凭据但无 config.json 也算已有部署' '0' \
            "$( STATE_FILE="$_s"; SB_CONF="${_c}.none"; UUID='abc'; has_existing_deployment && echo 0 || echo 1 )"
        st_eq '两者皆无才是首次部署' '1' \
            "$( STATE_FILE="${_s}.none"; SB_CONF="${_c}.none"; UUID=''; has_existing_deployment && echo 0 || echo 1 )"
        st_eq '首次部署强制按「生成新配置」处理（即便传了 keep）' 'new' \
            "$( RERUN_MODE=keep; ASSUME_YES=1; STATE_FILE="${_s}.none"; SB_CONF="${_c}.none"; UUID=''; choose_rerun_mode >/dev/null 2>&1; printf '%s' "$RERUN_MODE" )"
        st_eq 'state.env 损坏但 config.json 在时，未选择仍默认沿用（不自动覆盖）' 'keep' \
            "$( RERUN_MODE=''; ASSUME_YES=1; STATE_FILE="${_s}.none"; SB_CONF="$_c"; UUID=''; MOD_ON=(0 0 0 0 0 1 0 1 0); choose_rerun_mode >/dev/null 2>&1; printf '%s' "$RERUN_MODE" )"
        st_eq '重跑 --yes 未选择时默认沿用旧配置（绝不自动覆盖）' 'keep' \
            "$( RERUN_MODE=''; ASSUME_YES=1; STATE_FILE="$_s"; SB_CONF="$_c"; UUID='abc'; MOD_ON=(0 0 0 0 0 1 0 1 0); choose_rerun_mode >/dev/null 2>&1; printf '%s' "$RERUN_MODE" )"
        st_eq '交互输入非法后重选 2 得到 new' 'new' \
            "$( RERUN_MODE=''; ASSUME_YES=''; STATE_FILE="$_s"; SB_CONF="$_c"; UUID='abc'; MOD_ON=(0 0 0 0 0 1 0 1 0); choose_rerun_mode <<< $'9\n2\n' >/dev/null 2>&1; printf '%s' "$RERUN_MODE" )"
        st_eq '交互直接回车默认沿用旧配置' 'keep' \
            "$( RERUN_MODE=''; ASSUME_YES=''; STATE_FILE="$_s"; SB_CONF="$_c"; UUID='abc'; MOD_ON=(0 0 0 0 0 1 0 1 0); choose_rerun_mode <<< $'\n' >/dev/null 2>&1; printf '%s' "$RERUN_MODE" )"
        st_eq '交互输入结束（EOF）仍退回沿用旧配置' 'keep' \
            "$( RERUN_MODE=''; ASSUME_YES=''; STATE_FILE="$_s"; SB_CONF="$_c"; UUID='abc'; MOD_ON=(0 0 0 0 0 1 0 1 0); choose_rerun_mode </dev/null >/dev/null 2>&1; printf '%s' "$RERUN_MODE" )"
        st_eq '模式不写进状态文件（下次重跑必须重新表态）' '1' \
            "$( [[ " ${STATE_KEYS[*]} " == *' RERUN_MODE '* ]] && echo 0 || echo 1 )"
        st_eq '生成新配置时连 --uuid 固定值也清空（不复用固定值）' '' \
            "$( UUID='fixed-uuid'; CLI_SET[UUID]=1; regen_credentials 1; printf '%s' "$UUID" )"
        st_eq '首次部署不强制清空固定值（保留既有 --uuid 参数）' '1' \
            "$( RERUN_MODE=new; RERUN_IS_FIRST=1; should_force_regen && echo 0 || echo 1 )"
        st_eq '重跑选生成新配置时强制清空固定值' '0' \
            "$( RERUN_MODE=new; RERUN_IS_FIRST=0; should_force_regen && echo 0 || echo 1 )"
        st_eq 'choose_rerun_mode 把首次部署标记为 RERUN_IS_FIRST=1' '1' \
            "$( RERUN_IS_FIRST=0; RERUN_MODE=''; ASSUME_YES=1; STATE_FILE="${_s}.none"; SB_CONF="${_c}.none"; UUID=''; choose_rerun_mode >/dev/null 2>&1; printf '%s' "$RERUN_IS_FIRST" )"
        st_eq '重跑时 RERUN_IS_FIRST 保持 0' '0' \
            "$( RERUN_IS_FIRST=0; RERUN_MODE=new; STATE_FILE="$_s"; SB_CONF="$_c"; UUID='abc'; MOD_ON=(0 0 0 0 0 1 0 1 0); choose_rerun_mode >/dev/null 2>&1; printf '%s' "$RERUN_IS_FIRST" )"
        st_eq 'keep 下命令行 --uuid 被恢复为 state.env 原值' 'OLD_UUID' \
            "$( printf 'UUID="OLD_UUID"\nREALITY_PRIV="OLD_PRIV"\n' > "$_s"; RERUN_MODE=keep; STATE_FILE="$_s"; CLI_SET[UUID]=1; UUID='NEW_UUID'; restore_credentials_for_keep >/dev/null 2>&1; printf '%s' "$UUID" )"
        rm -rf "$_rm_tmp" 2>/dev/null || true
    else
        st_skip '本机无法创建临时目录，跳过重跑二选一用例'
    fi

    local suite; suite="$(dirname "${BASH_SOURCE[0]:-}")/.selftest/all.sh"
    if [[ -r $suite ]]; then
        info "检测到完整回归套件，可另行执行（未自动跑，以保持 --self-test 严格只读）："
        printf '    bash .selftest/all.sh\n'
    fi

    hr
    if (( ST_SKIP > 0 )); then
        printf '  自检结果：通过 %d 项，失败 %d 项（跳过 %d 项未执行）\n' "$ST_PASS" "$ST_FAIL" "$ST_SKIP"
    else
        printf '  自检结果：通过 %d 项，失败 %d 项\n' "$ST_PASS" "$ST_FAIL"
    fi
    hr
    if (( ST_FAIL == 0 )); then ok "内置自检全部通过"; return 0; fi
    err "内置自检存在 ${ST_FAIL} 项失败"; return 1
}

# ============================================================
# §16 主流程
# ============================================================
# 离线渲染模式：不联网探测，优先 --ips > IP 环境变量 > 占位地址
ips_from_args() {
    NODE_IPS=()
    split_ip_list "$IP_LIST"
    NODE_IPS=("${SPLIT_IPS[@]}")
    # IP= 环境变量与 --ips 同语义：支持逗号分隔清单，不能整串塞进一个元素
    if [[ ${#NODE_IPS[@]} -eq 0 && -n ${IP:-} ]]; then split_ip_list "$IP"; NODE_IPS=("${SPLIT_IPS[@]}"); fi
    if [[ ${#NODE_IPS[@]} -eq 0 ]]; then NODE_IPS=("203.0.113.10"); fi
}
# 只读体检 / 机器可读状态用：**绝不能**拿占位地址冒充"本机真实 IP"。
# 占位值 203.0.113.10 只服务离线渲染（--print-config / --print-outbounds）；
# 若被 --doctor 的域名解析比对或 --status --json 的 ips 字段当作事实使用，
# 正常机器会必然被判成「A 记录没有指向本机」，给出完全错误的处置建议。
# 语义：--ips / IP_LIST 优先，否则真实探测；探测不到就留空，由调用方降级成 warn / 空数组。
real_ips_from_args() {
    NODE_IPS=()
    split_ip_list "$IP_LIST"
    NODE_IPS=("${SPLIT_IPS[@]}")
    if [[ ${#NODE_IPS[@]} -eq 0 && -n ${IP:-} ]]; then split_ip_list "$IP"; NODE_IPS=("${SPLIT_IPS[@]}"); fi
    if [[ ${#NODE_IPS[@]} -eq 0 ]]; then
        # detect_ips 会打印探测提示；全部导到 stderr —— --json 模式下 stdout 必须只含 JSON
        detect_ips >&2 2>/dev/null || true
    fi
    return 0
}
# 离线渲染（--print-config / --print-outbounds）的占位值：
# 它们不是"默认值"，只是让渲染在没有任何凭据的机器上也能产出可校验的配置。
# 与 init_defaults() 分开存放，避免把"真实默认值"和"演示占位值"混成一个来源。
fill_render_placeholders() {
    REALITY_SNI="${REALITY_SNI:-shandun.example.com}"
    REALITY_DEST="${REALITY_DEST:-127.0.0.1}"
    REALITY_DEST_PORT="${REALITY_DEST_PORT:-8443}"
    CERT_CN="${CERT_CN:-bing.com}"
    UUID="${UUID:-00000000-0000-4000-8000-000000000000}"
    REALITY_PRIV="${REALITY_PRIV:-PRIVATEKEY}"
    REALITY_PUB="${REALITY_PUB:-PUBLICKEY}"
    SHORT_ID="${SHORT_ID:-0123456789abcdef}"
    HY2_PW="${HY2_PW:-changeme}"
    OBFS_PW="${OBFS_PW:-changeme}"
}

main() {
    # --self-test 走独立分支：必须排在 preflight / load_state 之前，
    # 这样非 root、没有 systemd、甚至 `curl | bash` 的场景都能自检
    if [[ -n ${SELF_TEST:-} ]]; then self_test; exit $?; fi

    # 只读命令与动作选项（--rotate-secrets / --uninstall）同用时，动作分支在后面
    # 会被只读分支提前 exit 掉 —— 静默吞掉会让用户以为轮换 / 卸载已经做了。
    if [[ ${ROTATE_SECRETS:-0} -eq 1 || ${UNINSTALL:-0} -eq 1 ]] \
       && [[ -n $PRINT_OUTBOUNDS || -n $PRINT_CONFIG || -n $SHOW_STATUS || -n $DOCTOR ]]; then
        if [[ ${UNINSTALL:-0} -eq 1 ]]; then
            warn "--uninstall 是写操作，与只读命令（--status / --doctor / --print-*）同用时不会执行；请单独运行"
        else
            warn "--rotate-secrets 是写操作，与只读命令（--status / --doctor / --print-*）同用时不会执行；请单独运行"
        fi
    fi

    if [[ -n $PRINT_OUTBOUNDS ]]; then
        load_state
        # 「只做管理」不产出任何节点：仍给一份合法空 JSON，保持 stdout 纯净、便于脚本消费。
        if [[ ${MANAGE_ONLY:-0} -eq 1 ]]; then
            printf '  只做管理、不跑代理：不生成客户端 outbounds（恢复请加 --no-manage-only）\n' >&2
            printf '{ "outbounds": [] }\n'
            exit 0
        fi
        validate_settings
        fill_render_placeholders
        ips_from_args
        init_nat_for_render      # 静默：只读显式参数，不联网、不打印，避免污染 stdout 的 JSON
        # 离线路径不做 NAT 自动判定（不读网卡、不联网）。给的 --ips 全是私网地址时
        # 基本可以断定是 NAT 机：渲染出的节点用的是内部端口、必然连不上。
        # 提示走 stderr，stdout 仍是纯 JSON。
        if [[ ${NAT_ACTIVE:-0} -eq 0 && -z ${CLI_SET[NAT_MODE]:-} ]]; then
            local _ip _natish=0
            for _ip in "${NODE_IPS[@]:-}"; do
                [[ -n $_ip ]] || continue
                if is_private_addr "$_ip"; then _natish=1; break; fi
            done
            if [[ $_natish -eq 1 ]]; then
                printf '  提示：--ips 给的是私网地址且未带任何 --nat 参数 —— 若这是 NAT 机，请加 --nat --nat-ports … --nat-map …，否则渲染的节点使用内部端口、无法连通\n' >&2
            fi
        fi
        render_client_outbounds
        exit 0
    fi

    if [[ -n $PRINT_CONFIG ]]; then
        load_state
        # 不部署 sing-box 就没有服务端配置可渲染；报错比给出一份用不上的 JSON 更诚实。
        if [[ ${MANAGE_ONLY:-0} -eq 1 ]]; then
            printf '  只做管理、不跑代理：未部署 sing-box，没有服务端 config.json 可渲染。\n' >&2
            printf '  恢复代理部署：bash vps-init.sh --no-manage-only --nat-wizard\n' >&2
            exit 1
        fi
        validate_settings
        fill_render_placeholders
        ips_from_args
        render_config
        exit 0
    fi

    load_state
    # --uninstall 是写路径但独立于模块流程：不进 preflight / 向导 / 菜单。
    # 但 root 校验必须自己补：非 root 时 rm/iptables 会中途失败，
    # 留下「拆到一半」的状态（配置删了、规则还在），比不执行更危险。
    if [[ ${UNINSTALL:-0} -eq 1 ]]; then
        [[ $EUID -eq 0 ]] || die "请以 root 身份运行 --uninstall（sudo -i 后执行）"
        # 卸载同样是写路径：ERR trap（意外失败不能裸退出，留下「拆到一半」的状态）
        # 与实例互斥锁同样适用 —— 与下方模块流程同策略。
        trap 'rc=$?; err "卸载在第 ${LINENO} 行出错（退出码 ${rc}）。已完成步骤不会自动回滚，请查看上方输出后重跑 --uninstall 补齐。"; exit $rc' ERR
        acquire_instance_lock
        parse_nat_map "$NAT_MAP"; parse_nat_map6 "$NAT_V6_MAP"; detect_nat
        cmd_uninstall; exit $?
    fi
    if [[ -n $SHOW_STATUS ]]; then
        parse_nat_map "$NAT_MAP"; parse_nat_map6 "$NAT_V6_MAP"; detect_nat
        if [[ ${STATUS_JSON:-0} -eq 1 ]]; then cmd_status_json; else show_status; fi
        exit 0
    fi

    # --doctor 同样是只读路径：不进 preflight / 向导 / 模块流程。
    # detect_nat 放在 if 条件里调用：探测失败（无 ip 命令等）按非 NAT 处理，不中断体检。
    if [[ -n $DOCTOR ]]; then
        parse_nat_map "$NAT_MAP"; parse_nat_map6 "$NAT_V6_MAP"
        if ! detect_nat 2>/dev/null; then NAT_ACTIVE=0; fi
        # 用真实探测而非占位地址：域名比对必须以本机实际公网 IP 为参照
        real_ips_from_args
        cmd_doctor
        exit $?
    fi

    # 从这里开始是写路径（向导写 state、模块写配置/防火墙）：先拿实例互斥锁。
    # ERR trap 必须在进入向导 / NAT 适配之前就装好：这几段若发生非 die 的意外失败，
    # set -e 会静默退出，没有行号输出会让用户完全摸不着头脑。
    trap 'rc=$?; err "脚本在第 ${LINENO} 行出错（退出码 ${rc}）。已完成步骤不会自动回滚，请查看上方输出。"; exit $rc' ERR
    acquire_instance_lock
    preflight
    # --rotate-secrets：轻量换钥匙（只跑模块 6/8/9），先确认意图再动凭据
    if [[ ${ROTATE_SECRETS:-0} -eq 1 ]]; then
        if [[ ${MANAGE_ONLY:-0} -eq 1 ]]; then
            die "本机为「只做管理」模式，没有代理凭据可轮换；恢复代理部署请先 --no-manage-only --nat-wizard"
        fi
        hr
        printf '  --rotate-secrets 将只轮换 UUID / short_id / hy2 密码 / obfs 密码：\n'
        printf '    服务端配置与客户端交付文件重写、sing-box 重启；Reality 密钥与证书不变。\n'
        printf '    现有客户端配置与分享链接全部作废，需要重新导入。\n'
        hr
        if [[ -z ${ASSUME_YES:-} ]]; then
            ask_yn "确认轮换凭据？" n || die "已取消轮换（未做任何改动）"
        fi
        info "本次仅执行模块 6/8/9（凭据生成 / 服务端配置 / 交付汇总）"
    fi
    # 机房位置识别失败时给手动输入机会，但只在「真实终端 + 完整交互部署」下开放：
    # --yes / --modules / 管道输入一律不弹，避免阻塞自动化或污染离线渲染的 JSON。
    if [[ -z $ASSUME_YES && -z $MODULES_ARG ]] && stdin_is_tty; then LOC_ASK_ENABLED=1; fi
    # 交互式逐族选择端口开放方式（--yes / --modules / 离线渲染 / --status 不进入）。
    # 必须排在 apply_nat_adaptation 之前：后者要读取向导定下的分族配置。
    interactive_nat_wizard
    # 必须在任何模块之前：模块 2 要据此决定「不改 SSH 端口」，
    # 模块 3 下发防火墙规则、模块 8/9 渲染客户端端口都要看到适配后的值。
    apply_nat_adaptation

    if [[ ${MANAGE_ONLY:-0} -eq 1 ]]; then
        hr
        info "==> 已选择「不开启端口转发映射」：本机只做管理、不跑代理"
        printf '  后续将取消：sing-box 安装与全部凭据/证书/伪装站、v4 / v6 代理节点与\n'
        printf '  客户端配置、代理端口与端口跳跃的防火墙 / DNAT 规则、交付汇总。\n'
        printf '  仅保留：系统基线、SSH 管理通道、fail2ban。\n'
        hr
    fi

    if [[ -n $MODULES_ARG ]]; then
        MOD_ON=(0 0 0 0 0 0 0 0 0)
        local i
        IFS=',' read -r -a _sel <<< "$MODULES_ARG"
        for i in "${_sel[@]}"; do
            i="${i// /}"
            [[ -z $i ]] && continue
            if [[ $i =~ ^[1-9]$ ]]; then
                MOD_ON[$((i-1))]=1
            else
                # 原先是静默丢弃：--modules 10 或 --modules 1-3 会当成"没选"，白跑一趟
                warn "忽略无效模块号「$i」：有效值为 1-${#MOD_NAMES[@]}，多个用逗号分隔（如 3,8,9）"
            fi
        done
    elif [[ -z $ASSUME_YES && ${MANAGE_ONLY:-0} -eq 0 ]]; then
        menu_select
    fi

    # 「只做管理」不再弹模块菜单，且无论 --yes / --modules / 交互勾选了什么，
    # 代理相关模块一律裁掉。放在菜单解析之后，保证 --modules 的显式意图同样被尊重。
    if [[ ${MANAGE_ONLY:-0} -eq 1 ]]; then
        apply_manage_only_modules
        if (( MANAGE_ONLY_DROPPED > 0 )); then
            info "「只做管理」已自动取消 ${MANAGE_ONLY_DROPPED} 个代理相关模块"
        fi
        save_state      # CLI --manage-only 路径没进向导，这里保证决策落盘
    fi

    local i count=0
    for i in "${!MOD_ON[@]}"; do [[ ${MOD_ON[$i]} -eq 1 ]] && count=$((count+1)); done
    [[ $count -eq 0 ]] && { warn "未选择任何模块，退出"; exit 0; }
    info "将执行 ${count} 个模块"
    # 二选一必须在任何模块执行之前完成：一旦选了「沿用旧配置」，
    # 模块 6/8/9 会整段跳过写入，config.json 与凭据从一开始就不会被碰到。
    # 「只做管理」不触及任何凭据与配置文件，这套选择没有意义，整段跳过。
    if [[ ${MANAGE_ONLY:-0} -eq 0 ]]; then
        choose_rerun_mode
        restore_credentials_for_keep
        restore_client_domain_for_keep
        restore_server_params_for_keep
        warn_new_without_mod6
        warn_incomplete_credentials
        report_rerun
    fi

    # 客户端 server 域名：交互式部署时按 v4 / v6 分别询问（--yes / --modules / 管道自动跳过）。
    # 放在重跑恢复之后：keep 模式的默认值就是 state.env 里的现有域名，回车即保持不动。
    # keep 模式下不询问：CLI 新域名本来就会被 restore_client_domain_for_keep 打回，
    # 交互里确认完再被告知「已忽略」是自相矛盾的体验；keep 的域名就是 state.env 现值。
    # 模块号 1-9 对应 MOD_ON 索引 0-8；此前误写了不存在的 MOD_ON[9]（恒为 0 的死条件）
    if [[ ( ${MOD_ON[5]:-0} -eq 1 || ${MOD_ON[6]:-0} -eq 1 || ${MOD_ON[7]:-0} -eq 1 ) \
          && ${RERUN_MODE:-} != keep ]]; then
        ask_client_domains
    fi

    for i in "${!MOD_ON[@]}"; do
        [[ ${MOD_ON[$i]} -eq 1 ]] || continue
        hr
        "${MOD_FUNCS[$i]}"
    done

    hr
    ok "全部所选模块执行完毕"
    if [[ ${MANAGE_ONLY:-0} -eq 1 ]]; then
        manage_only_finish
        return 0
    fi
    [[ -f /root/vps-init.info ]] && info "完整参数：cat /root/vps-init.info"
    info "常用检查：systemctl status sing-box / fail2ban-client status sshd / iptables -L --line"
    info "查看当前配置：bash vps-init.sh --status"
    if [[ ${MOD_ON[1]} -eq 1 ]]; then
        if [[ ${NAT_ACTIVE:-0} -eq 1 && -z ${CLI_SET[SSH_PORT]:-} ]]; then
            warn "NAT 机型：SSH 内部端口保持 ${SSH_PORT} 未改动；另开终端按族验证（v4 端口 $(ssh_port_for_family 4) / v6 端口 $(ssh_port_for_family 6)）能登录后再关闭当前会话"
        else
            warn "SSH 已改端口：请在新终端按族验证（v4 端口 $(ssh_port_for_family 4) / v6 端口 $(ssh_port_for_family 6)，内部 ${SSH_PORT}）能登录后再关闭当前会话"
        fi
    fi
}

# 只有被直接执行时才启动主流程。
# 被 `source` 载入时（.selftest 的单元测试直接引用本文件里的函数）只加载定义，
# 这样就不必再维护一份 `head -n -1` 剪出来的 lib.sh 副本 —— 副本一旦漂移，
# 测的就不是真正要发布的那个文件了。
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
