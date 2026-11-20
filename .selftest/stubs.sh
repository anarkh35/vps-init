# ============================================================
# stubs.sh —— 沙箱环境与命令桩（由 run.sh / verify.sh source 复用）
#
# 为什么抽出来：verify.sh 的 B/D 段要执行被测脚本（--modules 3 / 7），
# 依赖 systemctl / netfilter-persistent / caddy / acme.sh / curl 等桩。
# 以前这些桩只由 run.sh 生成，verify.sh 单独运行时会把命令打到真实系统上
# （极端情况下 netfilter-persistent save 会写真实 /etc/iptables）。
# 抽成共用文件后，两层各自独立运行都自带完整桩，谁先谁后都无所谓。
#
# 约定：
#   - 调用方必须先 cd 到仓库根（两个测试脚本开头都有），并设置 T（默认 .selftest）
#   - 本文件会 rm -rf 沙箱目录后重建 —— 必须在写入任何沙箱状态之前 source
#   - 结束时把 $T/bin 前插进 PATH；调用方可用更靠前的 PATH 项覆盖单个命令
#     （如 verify.sh 的 verifybin 记账桩）
# ============================================================
T="${T:-.selftest}"

rm -rf "$T/root" "$T/etc" "$T/var" "$T/usr" "$T/bin"
mkdir -p "$T/bin" "$T/etc/ssh" "$T/etc/systemd/system" "$T/etc/network" "$T/etc/apt/sources.list.d" \
         "$T/etc/systemd/journald.conf.d" "$T/etc/fail2ban" "$T/etc/modules-load.d" "$T/etc/sysctl.d" \
         "$T/etc/caddy" "$T/var/www" "$T/usr/sbin" "$T/usr/bin" "$T/root/.acme.sh" "$T/root/.vps-init"
printf 'ID=debian\nVERSION_ID="12"\n' > "$T/etc/os-release"
printf 'MemTotal:        2048000 kB\n' > "$T/meminfo"
printf 'Port 22\nPasswordAuthentication yes\nPermitRootLogin yes\nPubkeyAuthentication yes\n' > "$T/etc/ssh/sshd_config"

# ---- 通用桩 ----
mk_stub() { printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
for c in systemctl apt-get apt iptables ip6tables iptables-save ip6tables-save netfilter-persistent \
         sysctl modprobe ss timedatectl caddy debconf-set-selections fuser \
         fallocate mkswap swapon gpg chown hostname ip tc qrencode journalctl; do mk_stub "$c"; done
# fuser 返回 1 表示无进程占用锁（Debian 上未锁时的行为）
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/fuser"; chmod +x "$T/bin/fuser"

# ip 桩：模拟双栈多 IP（含一个应被过滤的 temporary 隐私地址）
# 注意：桩地址必须用「可全球路由」的段。脚本会连带排除私网/CGNAT/
# 文档段(192.0.2/24、198.51.100/24、203.0.113/24、2001:db8::/32)等不可承载公网服务的段，
# 若桩里用文档段，会被自动过滤掉而测不到多 IP 分支
cat > "$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -4) echo "2: eth0    inet 1.2.3.4/24 brd 1.2.3.255 scope global eth0"
        echo "2: eth0    inet 5.6.7.8/24 brd 5.6.7.255 scope global eth0";;
    -6) echo "2: eth0    inet6 2606:4700::1/64 scope global"
        echo "2: eth0    inet6 2606:4700::beef/64 scope global temporary";;
    *)  echo "default via 1.2.3.1 dev eth0";;
esac
exit 0
EOF
chmod +x "$T/bin/ip"
printf '#!/usr/bin/env bash\necho testnode\n' > "$T/bin/hostname"; chmod +x "$T/bin/hostname"

# sshd 桩：-t 时真校验配置结构（非注释行必须是「关键字 值」、关键字不得重复）——
# 恒真桩会把写坏的主配置 / drop-in 放行成全绿。默认读沙箱内配置（cwd=仓库根）。
cat > "$T/bin/sshd" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-t" ]]; then
    conf=".selftest/etc/ssh/sshd_config"
    [[ -f $conf ]] || conf="/etc/ssh/sshd_config"
    if [[ -f $conf ]]; then
        awk '
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            !/^[A-Za-z][A-Za-z0-9]*[[:space:]]+/ { print "sshd(stub): 非法行: " $0 > "/dev/stderr"; exit 1 }
            {
                if ($1 != "Include" && $1 != "Match" && $1 != "Subsystem" && ($1 in seen)) {
                    print "sshd(stub): 重复关键字: " $1 > "/dev/stderr"; exit 1
                }
                seen[$1]=1
            }
        ' "$conf" || exit 1
    fi
fi
exit 0
EOF
chmod +x "$T/bin/sshd"

# ---- 带行为差异的桩 ----
cat > "$T/bin/iptables" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/iptables"
cp "$T/bin/iptables" "$T/bin/ip6tables"

# systemctl 桩（白名单）：单元名拼错（如 singbox / fail2ban 写成别的）时
# is-active 必须返回失败 —— 恒真桩会把主脚本 healthcheck / 分支判定里的
# 单元名错误放行成全绿。白名单 = 脚本实际使用的全部真实单元名。
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
sub="${1:-}"; shift
# 单元名 = 第一个非旗标参数（主脚本会传 --quiet 等旗标，不能拿 $2 当单元名）
u=""
for a in "$@"; do [[ $a != -* ]] && { u="$a"; break; }; done
case "$sub" in
    is-active)
        case "$u" in
            ssh|sshd|ssh.socket|sing-box|caddy|fail2ban|systemd-timesyncd.service|systemd-journald|netfilter-persistent) exit 0;;
            "") exit 0;;   # 无单元名（不应出现）：保持旧行为避免误伤
            *) exit 1;;
        esac;;
    is-enabled)
        case "$u" in
            ssh.socket|ssh|sshd|sing-box|caddy|fail2ban|netfilter-persistent) exit 0;;
            *) exit 1;;
        esac;;
    list-unit-files) echo "ssh.socket enabled"; exit 0;;
    *) exit 0;;
esac
EOF
chmod +x "$T/bin/systemctl"

# sing-box 桩：generate 每次返回不同值；check 子命令真解析 JSON ——
# 恒真 check 会把主脚本渲染出的非法 JSON 放行成全绿，必须拒绝。
cat > "$T/bin/sing-box" <<'EOF'
#!/usr/bin/env bash
cnt=".selftest/gen.counter"
n=0
[[ -f $cnt ]] && n="$(cat "$cnt" 2>/dev/null || echo 0)"
case "${1:-}${2:-}" in
    check*)
        # sing-box check -c <file>：真校验 JSON（无 python 时退化为恒真，与
        # renders.sh 的 SKIP 约定一致）
        f=""; prev=""
        for a in "$@"; do [[ $prev == "-c" ]] && f="$a"; prev="$a"; done
        if [[ -n $f && -s $f ]]; then
            PY="$(command -v python3 || command -v python || true)"
            if [[ -n $PY ]]; then
                "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1 \
                    || { echo "sing-box(stub): 配置不是合法 JSON: $f" >&2; exit 1; }
            fi
        fi
        exit 0;;
    *uuid*) n=$((n+1)); echo "$n" > "$cnt"; printf '11111111-2222-3333-4444-%012d\n' "$n";;
    *reality-keypair*) n=$((n+1)); echo "$n" > "$cnt"; echo "PrivateKey: PRIVKEY_$n"; echo "PublicKey: PUBKEY_$n";;
    *rand*) n=$((n+1)); echo "$n" > "$cnt"; echo "cGFzc3dvcmQxMjM0NTY3ODkw$n";;
    *version*) echo "sing-box version 1.12.0";;
esac
exit 0
EOF
chmod +x "$T/bin/sing-box"
rm -f "$T/gen.counter"

# fail2ban-client 桩：对齐真实 `fail2ban-client status` 的输出格式。
# 旧版写反引号：echo "`- Jail list`: ..." 在桩运行时会执行命令替换 ——
# 字段名 "Jail list" 从 stdout 丢失、stderr 多一行 command not found，
# 主脚本 grep -i 'Jail list' 的解析成功分支从未被走到。
cat > "$T/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
echo 'Status'
echo '|- Number of jail:'$'\t''1'
echo '`- Jail list:'$'\t''sshd, recidive'
exit 0
EOF
chmod +x "$T/bin/fail2ban-client"

# caddy 桩：validate 时要求配置文件存在且非空（恒真桩会把「Caddyfile 没写出来」放行）
cat > "$T/bin/caddy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "validate" ]]; then
    f=""; prev=""
    for a in "$@"; do [[ $prev == "--config" ]] && f="$a"; prev="$a"; done
    [[ -n $f && -s $f ]] || { echo "caddy(stub): 配置文件缺失或为空: ${f:-<未指定>}" >&2; exit 1; }
fi
exit 0
EOF
chmod +x "$T/bin/caddy"

# acme.sh 桩：生成一张 CN/SAN 与 -d 域名一致的真实自签证书。
# 以前只写 "FAKE CERT" 文本，模块 7 新增的证书域名校验就永远走不到"匹配"分支，
# 覆盖不到「复用已有证书」这条关键路径。
cat > "$T/root/.acme.sh/acme.sh" <<'EOF'
#!/usr/bin/env bash
key=""; cert=""; cn=""; prev=""
for a in "$@"; do
    case "$prev" in
        --key-file) key="$a";;
        --fullchain-file) cert="$a";;
        -d) cn="$a";;
    esac
    prev="$a"
done
[[ -n $key && -n $cert ]] || exit 0
mkdir -p "$(dirname "$key")" "$(dirname "$cert")"
cn="${cn:-node1.example.com}"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$key" -out "$cert" \
    -subj "/CN=${cn}" -days 3650 \
    -addext "subjectAltName=DNS:${cn}" >/dev/null 2>&1
exit 0
EOF
chmod +x "$T/root/.acme.sh/acme.sh"

# curl 桩必须支持 -o：
# 脚本的下载统一走 §3 的 fetch_file，判断成败的依据是"文件是否真的落盘"。
# 不支持 -o 的桩会让每一次下载都判为失败，触发 3 次重试 + 6 秒退避，
# 既拖慢测试，也会掩盖"下载路径根本没被走到"这种覆盖缺口。
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""; url=""
for a in "$@"; do
    case "$prev" in -o) out="$a";; esac
    case "$a" in http://*|https://*) url="$a";; esac
    prev="$a"
done
case "$url" in
    *ipify.org*|*ip.sb*) printf '1.2.3.4\n'; exit 0;;
esac
if [[ -n $out ]]; then
    mkdir -p "$(dirname "$out")"
    printf '#!/bin/sh\n# stub payload\nexit 0\n' > "$out"
fi
exit 0
EOF
chmod +x "$T/bin/curl"

cat > "$T/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
[[ $1 == "-n" ]] && { echo bbr; exit 0; }
exit 0
EOF
chmod +x "$T/bin/sysctl"

cat > "$T/bin/ss" <<'EOF'
#!/usr/bin/env bash
echo "LISTEN 0 128 0.0.0.0:51736 0.0.0.0:* users:((\"sshd\"))"
exit 0
EOF
chmod +x "$T/bin/ss"

cat > "$T/bin/timedatectl" <<'EOF'
#!/usr/bin/env bash
echo "               Local time: Thu 2026-09-10 00:00:00 UTC"
echo "           Time zone: Etc/UTC (UTC, +0000)"
exit 0
EOF
chmod +x "$T/bin/timedatectl"

# fail2ban-client 桩只在文件前段定义一次（单引号 heredoc，`` 字面输出）。
# 此处不再重复定义：旧版双引号 heredoc 里的反引号会被 bash 执行，
# 静默覆盖前段的正确桩，让 jail 列表字段被吞掉。
export PATH="$PWD/$T/bin:$PATH"
