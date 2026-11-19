#!/usr/bin/env bash
# 定向验证：只针对容易反复回归的关键行为，全部落在 .selftest/ 沙箱内，不碰真实系统路径。
# 不依赖 python / jq：需要"执行参数解析后再读全局变量"的场景，改用 source 一个 runner 实现
# （vps-init.sh 末尾有"只有被直接执行才跑 main"的守卫，source 它只会应用默认值 + 解析参数 + 定义函数）。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
T=".selftest"
VBIN="$PWD/$T/verifybin"
mkdir -p "$VBIN"

pass=0; fail=0
chk() { # chk <描述> <期望> <实际>
    if [[ "$2" == "$3" ]]; then printf '[PASS] %s\n' "$1"; pass=$((pass+1))
    else printf '[FAIL] %s\n        期望: %s\n        实际: %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# ---------- 自建沙箱与命令桩 ----------
# 以前依赖 run.sh 先跑（$T/bin 与 $T/etc/os-release 都是它留下的），
# 单独运行时 B/D 段会把 systemctl / netfilter-persistent 等命令打到真实系统上。
# 现在统一 source stubs.sh：无论谁先跑，本层都自带完整桩，绝不碰真实系统。
# 注意 stubs.sh 会清空沙箱目录并重设 PATH —— 必须先 source，再叠加 verifybin。
T=".selftest"
source "$PWD/$T/stubs.sh"
export PATH="$VBIN:$PATH"     # verifybin 的记账桩（iptables/ip/apt-get）盖过 stubs.sh 的同名声令
mkdir -p "$T/root/.vps-init"  # stubs.sh 刚清空过沙箱，A 段的状态文件目录在这里

# ---------- 生成路径重定向后的脚本副本 ----------
# 与 run.sh 保持一致：/var/cache/vps-init 是下载缓存目录，也必须落在沙箱里
gen_copy() {
    sed -e 's@\[\[ $EUID -eq 0 \]\]@: @' \
        -e 's#/etc/#./.selftest/etc/#g' \
        -e 's#/root/#./.selftest/root/#g' \
        -e 's#/var/www/html#./.selftest/var/www/html#g' \
        -e 's#/var/cache/vps-init#./.selftest/var/cache/vps-init#g' \
        -e 's#/usr/local/sbin#./.selftest/usr/sbin#g' \
        -e 's#/usr/local/bin#./.selftest/usr/bin#g' \
        -e 's#/swapfile#./.selftest/swapfile#g' \
        -e 's#/proc/meminfo#.selftest/meminfo#g' \
        vps-init.sh
}
gen_copy > "$T/run-copy.sh"      # 可执行副本（会跑 main）
gen_copy > "$T/probe.sh"         # 仅供 source 的副本

cat > "$T/probe-run.sh" <<'PROBE'
#!/usr/bin/env bash
source "$(dirname "$0")/probe.sh"   # 顺带把 $@ 交给它的参数解析
load_state
printf 'EFF:SSH_PORT=%s;HY2_PORT=%s;VLESS_PORT=%s;HOP_RANGE=%s;TZ_NAME=%s;NODE_NAME=%s\n' \
    "$SSH_PORT" "$HY2_PORT" "$VLESS_PORT" "$HOP_RANGE" "$TZ_NAME" "$NODE_NAME"
PROBE

echo "===== A. 状态文件回填优先级（命令行 > 状态文件 > 默认值）====="
cat > "$T/root/.vps-init/state.env" <<'EOF'
SSH_PORT="2222"
HY2_PORT="20000"
VLESS_PORT="8443"
HOP_RANGE="30000:50000"
TZ_NAME="Asia/Shanghai"
NODE_NAME="tokyo-1T"
EOF

got="$(bash "$T/probe-run.sh" 2>/dev/null | grep '^EFF:')"
chk "A1 状态文件生效（旧实现下这些带默认值的参数全部回填失败）" \
    "EFF:SSH_PORT=2222;HY2_PORT=20000;VLESS_PORT=8443;HOP_RANGE=30000:50000;TZ_NAME=Asia/Shanghai;NODE_NAME=tokyo-1T" "$got"

got="$(bash "$T/probe-run.sh" --hy2-port 30000 --ssh-port 1234 2>/dev/null | grep '^EFF:')"
chk "A2 命令行显式指定仍然优先" \
    "EFF:SSH_PORT=1234;HY2_PORT=30000;VLESS_PORT=8443;HOP_RANGE=30000:50000;TZ_NAME=Asia/Shanghai;NODE_NAME=tokyo-1T" "$got"

got="$(bash "$T/probe-run.sh" --no-hop 2>/dev/null | grep '^EFF:')"
chk "A3 --no-hop 能覆盖状态文件里的跳跃范围" \
    "EFF:SSH_PORT=2222;HY2_PORT=20000;VLESS_PORT=8443;HOP_RANGE=;TZ_NAME=Asia/Shanghai;NODE_NAME=tokyo-1T" "$got"

echo
echo "===== B. --no-hop 不再生成 --dport 为空的非法规则 ====="
rm -f "$T/root/.vps-init/state.env"        # 清掉 A 段残留，避免端口被状态文件改写
IPT_LOG="$PWD/$T/ipt.log"
export IPT_LOG
cat > "$VBIN/iptables" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-C" ]] && exit 1          # 模拟规则不存在，让 ipt_add 走到 -A
printf '%s\n' "$*" >> "$IPT_LOG"
exit 0
EOF
cp "$VBIN/iptables" "$VBIN/ip6tables"; chmod +x "$VBIN/iptables" "$VBIN/ip6tables"

: > "$IPT_LOG"
bash "$T/run-copy.sh" --yes --modules 3 --no-hop --hy2-port 16407 >/dev/null 2>&1
chk "B1 关闭跳跃时没有任何残缺的 --dport 规则" "0" "$(grep -cE 'dport +-j' "$IPT_LOG")"
chk "B2 关闭跳跃时仍放行 hy2 主端口（v4+v6 各一条，插链首）" "2" "$(grep -cE -- '-I INPUT 1 -p udp --dport 16407 -j ACCEPT' "$IPT_LOG")"
chk "B3 关闭跳跃时不生成 DNAT 规则" "0" "$(grep -cE 'PREROUTING.*DNAT' "$IPT_LOG")"

: > "$IPT_LOG"
bash "$T/run-copy.sh" --yes --modules 3 --hop-range 30000:50000 --hy2-port 16407 >/dev/null 2>&1
chk "B4 开启跳跃时按范围放行（v4+v6 各一条，插链首）" "2" "$(grep -cE -- '-I INPUT 1 -p udp --dport 30000:50000 -j ACCEPT' "$IPT_LOG")"
chk "B5 开启跳跃时生成 DNAT 重定向（v4+v6 各一条）" "2" "$(grep -cE 'PREROUTING.*DNAT --to-destination :16407' "$IPT_LOG")"

echo
echo "===== C. 自动探测排除私网地址 / 轮换中的临时 IPv6 ====="
cat > "$VBIN/ip" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -4) printf '2: eth0    inet 1.2.3.4/24 scope global eth0\n'
        printf '3: docker0 inet 172.17.0.1/16 scope global docker0\n'
        printf '4: eth1    inet 172.31.5.6/20 scope global eth1\n'
        printf '5: eth0    inet 198.51.100.7/24 scope global eth0\n';;
    -6) printf '2: eth0    inet6 2606:4700::1/64 scope global dynamic mngtmpaddr noprefixroute\n'
        printf '2: eth0    inet6 2606:4700::beef/64 scope global temporary dynamic\n'
        printf '2: eth0    inet6 2001:db8::1/64 scope global\n';;
    *)  printf 'default via 1.2.3.1 dev eth0\n';;
esac
exit 0
EOF
chmod +x "$VBIN/ip"
rm -f "$T/root/.vps-init/state.env"

got="$(bash "$T/run-copy.sh" --status 2>/dev/null | grep -m1 -E '公网地址' | sed 's/^ *//')"
chk "C1 过滤 docker0/内网网卡/CGNAT 与 temporary 地址；保留可路由的公网地址" \
    "公网地址   : 2 个 [1.2.3.4 2606:4700::1]" "$got"

got="$(bash "$T/run-copy.sh" --status --ips 172.17.0.1,10.0.0.9 2>/dev/null | grep -m1 -E '公网地址' | sed 's/^ *//')"
chk "C2 --ips 显式指定的私网地址不被过滤" \
    "公网地址   : 2 个 [172.17.0.1 10.0.0.9]" "$got"

echo
echo "===== D. 新增 caddy apt 源后必须真正刷新索引 ====="
# 回归点：apt_update 有「本会话只更新一次」的缓存位，模块 1/3 通常已把它置 1。
# 模块 7 新增 caddy 源后若不清零缓存就调用 apt_update，会被短路成空操作，
# 紧接着 apt-get install caddy 报 "Unable to locate package"（全量运行必现）。
# 桩环境里 caddy 命令是存在的，会把「新增源」分支整个跳过，所以这里把它强制打开。
APT_LOG="$PWD/$T/apt.log"; export APT_LOG
: > "$APT_LOG"
mkdir -p "$T/etc/apt/sources.list.d"
cat > "$VBIN/apt-get" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "update" ]]; then echo "update" >> "$APT_LOG"; exit 0; fi
echo "install $*" >> "$APT_LOG"
exit 0
EOF
chmod +x "$VBIN/apt-get"
sed -e 's@if ! command -v caddy >/dev/null; then@if true; then@' \
    "$T/run-copy.sh" > "$T/mod7.sh"
rm -f "$T/root/.vps-init/state.env"
bash "$T/mod7.sh" --yes --modules 7 --domain node1.example.com --cf-token cfat_fake_token >/dev/null 2>&1
chk "D1 新增源后 apt update 被调用两次（首次 + 加源后）" "2" "$(grep -c '^update$' "$APT_LOG")"
chk "D2 caddy 安装前有一次索引刷新" "1" \
    "$(awk '/^update$/{u=NR} /install .*caddy/{if(u>0 && u<NR){print 1; exit}}' "$APT_LOG" | tail -1)"

echo
echo "===== E. 下载封装（§3）的落地情况 ====="
# 这一层以前是空白：桩环境里 sing-box / caddy / acme.sh 都已存在，
# 下载分支根本不会被走到，于是"下载失败没有重试"这类问题只有到真机上才暴露。
# fetch_file/fetch_stdout 的行为由 unit.sh 的 T13 做真实断言，这里只做约定检查。
bare="$(grep -v '^[[:space:]]*#' vps-init.sh | grep -cE 'curl[^|]*[|][[:space:]]*(sh|bash)' || true)"
chk "E1 脚本内无裸 curl 管道给 sh 的下载" "0" "${bare:-0}"
chk "E2 安装类下载已全部改走 fetch_file（≥4 处）" "1" \
    "$(awk '$0 !~ /^[[:space:]]*#/ && /fetch_file /{n++} END{print (n>=4)?1:0}' vps-init.sh)"

echo
printf '结果: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
