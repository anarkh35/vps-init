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
         sshd sysctl modprobe ss timedatectl fail2ban-client caddy debconf-set-selections fuser \
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

# ---- 带行为差异的桩 ----
cat > "$T/bin/iptables" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/iptables"
cp "$T/bin/iptables" "$T/bin/ip6tables"

cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    is-active) echo active; exit 0;;
    is-enabled) exit 0;;          # 让 ssh.socket 分支也被走到
    list-unit-files) echo "ssh.socket enabled"; exit 0;;
    *) exit 0;;
esac
EOF
chmod +x "$T/bin/systemctl"

# 每次 generate 都返回不同的值，才能验证「重跑必须轮换凭据」而不是碰巧一样。
# 计数器落在沙箱里，测试开头会清零，保证可复现。
cat > "$T/bin/sing-box" <<'EOF'
#!/usr/bin/env bash
cnt=".selftest/gen.counter"
n=0
[[ -f $cnt ]] && n="$(cat "$cnt" 2>/dev/null || echo 0)"
case "${1:-}${2:-}" in
    *uuid*) n=$((n+1)); echo "$n" > "$cnt"; printf '11111111-2222-3333-4444-%012d\n' "$n";;
    *reality-keypair*) n=$((n+1)); echo "$n" > "$cnt"; echo "PrivateKey: PRIVKEY_$n"; echo "PublicKey: PUBKEY_$n";;
    *rand*) n=$((n+1)); echo "$n" > "$cnt"; echo "cGFzc3dvcmQxMjM0NTY3ODkw$n";;
    *version*) echo "sing-box version 1.12.0";;
esac
exit 0
EOF
chmod +x "$T/bin/sing-box"
rm -f "$T/gen.counter"

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

cat > "$T/bin/fail2ban-client" <<'EOF'
#!/usr/bin/env bash
echo "Status for the jail: sshd"; echo "`- Jail list`:   sshd, recidive"
exit 0
EOF
chmod +x "$T/bin/fail2ban-client"

export PATH="$PWD/$T/bin:$PATH"
