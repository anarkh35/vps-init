#!/usr/bin/env bash
# 冒烟测试：用桩程序模拟 Debian 环境，跑通全部 9 个模块，捕获变量未定义/流程错误
# 不修改任何真实系统路径，全部落在 .selftest/ 下
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

T=".selftest"
# ---- 沙箱与命令桩（与 verify.sh 共用，统一在 stubs.sh 维护）----
# 本文件会清空并重建沙箱目录，必须在写任何沙箱状态之前 source
source "$(dirname "${BASH_SOURCE[0]}")/stubs.sh"

# ---- 生成被改造的脚本副本（路径重定向到测试沙箱） ----
# 注意：/var/cache/vps-init（§3 下载缓存）也必须重定向，否则测试会往真实的
# /var/cache 里写东西 —— 自检不能有系统级副作用。
sed -e 's@\[\[ \$EUID -eq 0 \]\]@: @' \
    -e 's#/etc/#./.selftest/etc/#g' \
    -e 's#/root/#./.selftest/root/#g' \
    -e 's#/var/www/html#./.selftest/var/www/html#g' \
    -e 's#/var/cache/vps-init#./.selftest/var/cache/vps-init#g' \
    -e 's#/usr/local/sbin#./.selftest/usr/sbin#g' \
    -e 's#/usr/local/bin#./.selftest/usr/bin#g' \
    -e 's#/swapfile#./.selftest/swapfile#g' \
    -e 's#/proc/meminfo#.selftest/meminfo#g' \
    vps-init.sh > "$T/test-copy.sh"

export PATH="$PWD/$T/bin:$PATH"
echo "======== 冒烟测试开始（--yes 全模块）========"
bash "$T/test-copy.sh" --yes \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHere user@pc" \
    --domain "node1.example.com" --cf-token "cfat_fake_token" \
    --shaper-rate 1000mbit --ssh-port 51736 > "$T/first.log" 2>&1
rc=$?
cat "$T/first.log"
echo "======== 冒烟测试结束，退出码 $rc ========"

# 记录首轮凭据，用于后面断言「全量重跑必须轮换」
state="$T/root/.vps-init/state.env"
uuid_first="$(sed -n 's/^UUID="\(.*\)"$/\1/p' "$state" 2>/dev/null || true)"
priv_first="$(sed -n 's/^REALITY_PRIV="\(.*\)"$/\1/p' "$state" 2>/dev/null || true)"
hash_first="$(sed -n 's/^CERT_HASH="\(.*\)"$/\1/p' "$state" 2>/dev/null || true)"

# 伪装站必须是内置的「青山·一屏山色」页面，而不是默认的 "It works" 裸页。
# 这里只读检查产物，不修改任何文件。
page="$T/var/www/html/index.html"
if [[ -s $page ]]; then
    if grep -q '<!DOCTYPE html>' "$page" && grep -q '青山' "$page"; then
        echo "PASS  伪装站已部署为内置页面（青山·一屏山色）"
    else
        echo "FAIL  伪装站内容不是内置页面（疑似退回 It works）"
        rc=1
    fi
else
    echo "FAIL  伪装站 index.html 未生成"
    rc=1
fi

# 首轮证书必须由 acme.sh 桩签发、且 CN 与域名一致（防「装回旧域名证书被误判成功」）。
cert="$T/etc/sing-box/cert/fullchain.cer"
if [[ -s $cert ]] && openssl x509 -in "$cert" -noout -subject 2>/dev/null | grep -q 'node1.example.com'; then
    echo "PASS  首轮签发的证书 CN 与 --domain 一致"
else
    echo "FAIL  首轮证书缺失或 CN 与域名不符"
    rc=1
fi

# 关键回归：CF_TOKEN 不写状态文件，过去 --modules 7 单跑会静默降级成公共站点握手。
# 现在应复用同域名证书、不再要 Token，且 REALITY_SNI 仍保持自有域名。
echo "======== 重跑测试（--modules 7 --yes，不提供 --cf-token）========"
bash "$T/test-copy.sh" --yes --modules 7 > "$T/rerun.log" 2>&1
rerun_rc=$?
echo "======== 重跑结束，退出码 $rerun_rc ========"
if [[ $rerun_rc -eq 0 ]]; then
    echo "PASS  重跑模块 7 退出码 0"
else
    echo "FAIL  重跑模块 7 退出码 $rerun_rc"
    rc=1
fi
if grep -q '复用已有证书' "$T/rerun.log"; then
    echo "PASS  重跑复用了同域名证书（无需 CF Token）"
else
    echo "FAIL  重跑未走证书复用路径"
    rc=1
fi
if grep -q '^REALITY_SNI="node1.example.com"' "$T/root/.vps-init/state.env" 2>/dev/null; then
    echo "PASS  重跑后 REALITY_SNI 仍为自有域名（未静默降级）"
else
    echo "FAIL  重跑后 REALITY_SNI 被降级成公共站点"
    rc=1
fi
if grep -q 'www.microsoft.com' "$T/rerun.log"; then
    echo "FAIL  重跑日志出现公共站点回退告警"
    rc=1
else
    echo "PASS  重跑日志无公共站点回退告警"
fi

# ---- 重跑专项：感知摘要 / 覆盖前保护 ----
if grep -q '检测到已有部署' "$T/first.log"; then
    echo "FAIL  首次运行误报「已有部署」摘要"; rc=1
else
    echo "PASS  首次运行不打印重跑摘要（零行为变化）"
fi
if grep -q '检测到已有部署' "$T/rerun.log" && grep -q '本次模块' "$T/rerun.log"; then
    echo "PASS  重跑打印已有部署摘要（凭据 / Reality 模式 / 本次模块 / 将被覆盖的文件）"
else
    echo "FAIL  重跑未打印已有部署摘要"; rc=1
fi
if [[ -n $uuid_first ]] && grep -qF "UUID=\"${uuid_first}\"" "$state"; then
    echo "PASS  只重跑模块 7 不轮换凭据（模块 6 才负责生成）"
else
    echo "FAIL  只重跑模块 7 却改动了凭据"; rc=1
fi
if [[ -s "$T/root/.vps-init.Caddyfile.bak" ]]; then
    echo "PASS  重跑覆盖 Caddyfile 前留了上一版备份"
else
    echo "FAIL  Caddyfile 覆盖前没有备份"; rc=1
fi
# config.json 必须先写 .new、校验通过后再 mv：不能留临时文件，也不能截断正式配置
if [[ -s "$T/etc/sing-box/config.json" && ! -e "$T/etc/sing-box/config.json.new" ]]; then
    echo "PASS  config.json 原子替换完成且无 .new 残留"
else
    echo "FAIL  config.json 原子写入异常（缺失或有 .new 残留）"; rc=1
fi

# ---- 全量重跑：显式选择「生成新配置」，节点凭据必须全部重新生成 ----
echo "======== 全量重跑测试（--new-config，凭据应全部轮换）========"
bash "$T/test-copy.sh" --yes --new-config \
    --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHere user@pc" \
    --domain "node1.example.com" --cf-token "cfat_fake_token" \
    --shaper-rate 1000mbit --ssh-port 51736 > "$T/full.log" 2>&1
full_rc=$?
echo "======== 全量重跑结束，退出码 $full_rc ========"
uuid_second="$(sed -n 's/^UUID="\(.*\)"$/\1/p' "$state" 2>/dev/null || true)"
priv_second="$(sed -n 's/^REALITY_PRIV="\(.*\)"$/\1/p' "$state" 2>/dev/null || true)"
hash_second="$(sed -n 's/^CERT_HASH="\(.*\)"$/\1/p' "$state" 2>/dev/null || true)"
if [[ $full_rc -eq 0 ]]; then
    echo "PASS  全量重跑退出码 0"
else
    echo "FAIL  全量重跑退出码 $full_rc"; rc=1
fi
if grep -q '节点凭据已轮换' "$T/full.log"; then
    echo "PASS  日志明确警告旧客户端配置与分享链接作废"
else
    echo "FAIL  未打印凭据轮换警告"; rc=1
fi
if [[ -n $uuid_first && -n $uuid_second && $uuid_first != "$uuid_second" ]]; then
    echo "PASS  重跑生成了新 UUID（${uuid_first} → ${uuid_second}）"
else
    echo "FAIL  重跑后 UUID 没有变化"; rc=1
fi
if [[ -n $priv_first && -n $priv_second && $priv_first != "$priv_second" ]]; then
    echo "PASS  Reality 私钥已轮换"
else
    echo "FAIL  Reality 私钥没有变化"; rc=1
fi
if [[ -n $hash_first && -n $hash_second && $hash_first != "$hash_second" ]]; then
    echo "PASS  Hysteria2 自签证书 / pinSHA256 已轮换"
else
    echo "FAIL  自签证书没有重新生成"; rc=1
fi
if grep -qF "UUID      : ${uuid_second}" "$T/root/vps-init.info" 2>/dev/null; then
    echo "PASS  交付文件 vps-init.info 已写入新 UUID"
else
    echo "FAIL  交付文件仍是旧 UUID"; rc=1
fi
# 回落站的 acme 证书不属于节点凭据，仍应复用（否则每次重跑都要 CF Token）
if grep -q '复用已有证书' "$T/full.log"; then
    echo "PASS  回落站 TLS 证书仍复用（未误伤上一轮的免 Token 重跑）"
else
    echo "FAIL  回落站证书被误判为需重新签发"; rc=1
fi

# ==================== 重跑二选一专项复检 ====================
# 关键文件指纹：config.json / 私钥 / 自签证书 / state.env / 两份交付文件。
# 「沿用旧配置」要求这六者一个字节都不变；「生成新配置」要求全部换新。
cfg="$T/etc/sing-box/config.json"
key="$T/etc/sing-box/private.key"
crt="$T/etc/sing-box/cert.crt"
info_f="$T/root/vps-init.info"
client_f="$T/root/vps-init.client-outbounds.json"
snapshot() { sha256sum "$cfg" "$key" "$crt" "$state" "$info_f" "$client_f" 2>/dev/null; }
uuid_of() { sed -n 's/^UUID="\(.*\)"$/\1/p' "$state" 2>/dev/null || true; }
hash_of() { sed -n 's/^CERT_HASH="\(.*\)"$/\1/p' "$state" 2>/dev/null || true; }
FULL_ARGS=(--pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHere user@pc" \
           --domain "node1.example.com" --cf-token "cfat_fake_token" \
           --shaper-rate 1000mbit --ssh-port 51736)

# ---- A1：显式 --keep-config 全量重跑 ----
echo "======== 二选一 A1：--yes --keep-config 全量重跑（应完全不改动）========"
snap="$(snapshot)"; uuid_keep="$(uuid_of)"
bash "$T/test-copy.sh" --yes --keep-config "${FULL_ARGS[@]}" > "$T/keep.log" 2>&1
a_rc=$?
if [[ $a_rc -eq 0 ]]; then echo "PASS  --keep-config 全量重跑退出码 0"; else echo "FAIL  --keep-config 退出码 $a_rc"; rc=1; fi
if [[ "$(snapshot)" == "$snap" ]]; then
    echo "PASS  config.json / 私钥 / 自签证书 / state.env / 两份交付文件哈希全部不变"
else
    echo "FAIL  沿用旧配置却改动了配置文件或凭据"; rc=1
fi
if [[ "$(uuid_of)" == "$uuid_keep" ]]; then echo "PASS  UUID 保持原值（未重新生成）"; else echo "FAIL  UUID 被改动"; rc=1; fi
if grep -q '沿用旧配置' "$T/keep.log"; then echo "PASS  日志明确标注「沿用旧配置」"; else echo "FAIL  日志未标注模式"; rc=1; fi
if grep -q '节点凭据已轮换' "$T/keep.log"; then echo "FAIL  沿用旧配置却出现轮换警告"; rc=1; else echo "PASS  无凭据轮换警告"; fi
if [[ -e "$cfg.new" ]]; then echo "FAIL  沿用旧配置产生了 config.json.new"; rc=1; else echo "PASS  未产生 .new 临时文件"; fi

# ---- A2：未明确选择（--yes 不带任何模式参数）：绝不能自动覆盖 ----
echo "======== 二选一 A2：--yes 未明确选择（安全默认）========"
bash "$T/test-copy.sh" --yes "${FULL_ARGS[@]}" > "$T/unselected.log" 2>&1
b_rc=$?
if [[ $b_rc -eq 0 ]]; then echo "PASS  未明确选择时退出码 0"; else echo "FAIL  未明确选择时退出码 $b_rc"; rc=1; fi
if grep -q '未明确选择方式' "$T/unselected.log"; then
    echo "PASS  明确告警「未明确选择方式，已按沿用旧配置处理」"
else
    echo "FAIL  缺少未选择时的安全告警"; rc=1
fi
if [[ "$(snapshot)" == "$snap" ]]; then echo "PASS  未明确选择时未覆盖任何文件"; else echo "FAIL  未明确选择却自动覆盖了旧配置"; rc=1; fi

# ---- A2b：keep 下 --uuid 不得污染 state.env（状态文件与 config.json 必须同一套凭据）----
echo "======== 二选一 A2b：--keep-config + --uuid ========"
KEEP_BAD_UUID="11111111-2222-4333-8444-888888888888"
bash "$T/test-copy.sh" --yes --keep-config --modules 6,7,8,9 --uuid "$KEEP_BAD_UUID" > "$T/keep-uuid.log" 2>&1
ku_rc=$?
if [[ $ku_rc -eq 0 ]] && grep -q '命令行 --uuid 已忽略' "$T/keep-uuid.log" && [[ "$(snapshot)" == "$snap" ]]; then
    echo "PASS  keep 模式忽略 --uuid，state.env 与 config.json 仍为同一套凭据"
else
    echo "FAIL  keep 模式下 --uuid 污染了状态文件（rc=$ku_rc）"; rc=1
fi

# ---- A3：带值写法 --config-mode keep + 交互输入非法后选 1 ----
echo "======== 二选一 A3：--config-mode keep / 交互非法输入后选 1 ========"
bash "$T/test-copy.sh" --modules 6,8,9 --config-mode keep > "$T/mode-keep.log" 2>&1
mk_rc=$?
if [[ $mk_rc -eq 0 && "$(snapshot)" == "$snap" ]]; then echo "PASS  --config-mode keep 不改动任何文件且退出码 0"; else echo "FAIL  带值写法异常（rc=$mk_rc 或文件被改）"; rc=1; fi

printf '3\n1\n' | bash "$T/test-copy.sh" --modules 6,8,9 > "$T/choice-keep.log" 2>&1
c_rc=$?
if [[ $c_rc -eq 0 ]]; then echo "PASS  交互二选一（非法输入→1）退出码 0"; else echo "FAIL  交互二选一退出码 $c_rc"; rc=1; fi
if grep -q '无效选择' "$T/choice-keep.log" && grep -q '已选择「沿用旧配置」' "$T/choice-keep.log"; then
    echo "PASS  非法输入被拒绝并循环提示，重选 1 得到「沿用旧配置」"
else
    echo "FAIL  交互异常处理或选择结果不符"; rc=1
fi
if [[ "$(snapshot)" == "$snap" ]]; then echo "PASS  交互选「沿用旧配置」后文件仍不变"; else echo "FAIL  交互选沿用却改动了文件"; rc=1; fi

# ---- A4：交互输入结束（EOF）也要安全退回 keep ----
bash "$T/test-copy.sh" --modules 6,8,9 </dev/null > "$T/choice-eof.log" 2>&1
eof_rc=$?
if [[ $eof_rc -eq 0 ]] && grep -q '输入不可用' "$T/choice-eof.log" && [[ "$(snapshot)" == "$snap" ]]; then
    echo "PASS  交互 EOF 退回「沿用旧配置」且文件不变（rc=0）"
else
    echo "FAIL  EOF 未安全退回或改动了文件（rc=$eof_rc）"; rc=1
fi

# ---- B1：交互选 2 = 生成新配置，凭据与配置必须全部换新 ----
echo "======== 二选一 B1：交互选 2（生成新配置）========"
printf '2\n' | bash "$T/test-copy.sh" --modules 6,8,9 > "$T/choice-new.log" 2>&1
d_rc=$?
if [[ $d_rc -eq 0 ]]; then echo "PASS  交互选 2 退出码 0"; else echo "FAIL  交互选 2 退出码 $d_rc"; rc=1; fi
if grep -q '已选择「生成新配置」' "$T/choice-new.log"; then echo "PASS  日志明确标注「生成新配置」"; else echo "FAIL  日志未标注模式"; rc=1; fi
uuid_new1="$(uuid_of)"; hash_new1="$(hash_of)"; snap_new1="$(snapshot)"
if [[ -n $uuid_new1 && $uuid_new1 != "$uuid_keep" ]]; then
    echo "PASS  生成新配置得到了全新 UUID（${uuid_keep} → ${uuid_new1}）"
else
    echo "FAIL  生成新配置复用了上次 UUID"; rc=1
fi
if [[ "$snap_new1" != "$snap" ]]; then echo "PASS  config.json 与交付文件已更新"; else echo "FAIL  生成新配置却没有更新配置"; rc=1; fi

# ---- B2/B3：连续两次「生成新配置」，禁止复用固定值或上次结果 ----
echo "======== 二选一 B2/B3：连续两次 --new-config（不得复用）========"
bash "$T/test-copy.sh" --modules 6,8,9 --new-config > "$T/new2.log" 2>&1
uuid_new2="$(uuid_of)"; hash_new2="$(hash_of)"
bash "$T/test-copy.sh" --modules 6,8,9 --new-config > "$T/new3.log" 2>&1
uuid_new3="$(uuid_of)"; hash_new3="$(hash_of)"
if [[ -n $uuid_new2 && -n $uuid_new3 && $uuid_new2 != "$uuid_new1" && $uuid_new3 != "$uuid_new1" && $uuid_new3 != "$uuid_new2" ]]; then
    echo "PASS  连续三次 UUID 两两不同（${uuid_new1} / ${uuid_new2} / ${uuid_new3}）"
else
    echo "FAIL  重复运行时复用了上次生成的 UUID"; rc=1
fi
if [[ -n $hash_new1 && -n $hash_new2 && -n $hash_new3 && $hash_new1 != "$hash_new2" && $hash_new2 != "$hash_new3" ]]; then
    echo "PASS  重复运行时 pinSHA256 / 自签证书每次重新生成"
else
    echo "FAIL  重复运行时复用了上次的证书指纹"; rc=1
fi

# ---- C：异常选择必须报错退出，且不留任何改动 ----
echo "======== 二选一 C：异常选择 ========"
snap_c="$(snapshot)"
bad_specs=("--config-mode bogus" "--keep-config --new-config" "--config-mode keep --new-config")
for spec in "${bad_specs[@]}"; do
    bash "$T/test-copy.sh" --yes $spec > "$T/bad-choice.log" 2>&1
    bad_rc=$?
    if [[ $bad_rc -ne 0 ]] && grep -qE '非法|冲突' "$T/bad-choice.log"; then
        echo "PASS  异常选择「${spec}」被拒绝（退出码 ${bad_rc}）"
    else
        echo "FAIL  异常选择「${spec}」未被拒绝"; rc=1
    fi
done
RERUN_MODE=bogus bash "$T/test-copy.sh" --yes > "$T/bad-env.log" 2>&1
env_rc=$?
if [[ $env_rc -ne 0 ]] && grep -q '重跑方式非法' "$T/bad-env.log"; then
    echo "PASS  环境变量非法模式被拒绝（退出码 ${env_rc}）"
else
    echo "FAIL  环境变量非法模式未被拒绝"; rc=1
fi
if [[ "$(snapshot)" == "$snap_c" ]]; then echo "PASS  所有异常选择均未改动任何文件"; else echo "FAIL  异常选择造成了文件改动"; rc=1; fi

# ---- D：只选模块 8/9 时提示「不轮换凭据」，避免误解 ----
bash "$T/test-copy.sh" --modules 8,9 --new-config > "$T/new-no6.log" 2>&1
n6_rc=$?
if [[ $n6_rc -eq 0 ]] && grep -q '但未包含模块 6' "$T/new-no6.log"; then
    echo "PASS  new 模式未含模块 6 时明确提示「只重渲染配置、不轮换凭据」（rc=0）"
else
    echo "FAIL  未含模块 6 场景异常（rc=$n6_rc 或缺提示）"; rc=1
fi

# ---- 降级重跑：上次是本地回落，本次换域名且无 Token → 必须清掉 127.0.0.1 残留 ----
echo "======== 降级重跑测试（换域名 + 无 CF Token）========"
sed -i 's/^DOMAIN="[^"]*"/DOMAIN="other.example.com"/' "$T/root/.vps-init/state.env"
bash "$T/test-copy.sh" --yes --modules 7 > "$T/downgrade.log" 2>&1
dg_rc=$?
echo "======== 降级重跑结束，退出码 $dg_rc ========"
if [[ $dg_rc -eq 0 ]]; then
    echo "PASS  降级重跑退出码 0"
else
    echo "FAIL  降级重跑退出码 $dg_rc"; rc=1
fi
if grep -q '已清除该残留' "$T/downgrade.log"; then
    echo "PASS  已识别并清除上次本地回落残留"
else
    echo "FAIL  未清除本地回落残留（握手会指向无 Caddy 的 127.0.0.1）"; rc=1
fi
if grep -q '^REALITY_DEST="www.microsoft.com"' "$T/root/.vps-init/state.env" 2>/dev/null \
    && grep -q '^REALITY_DEST_PORT="443"' "$T/root/.vps-init/state.env" 2>/dev/null; then
    echo "PASS  回退后 Reality 目标已重置为公共站点 443"
else
    echo "FAIL  回退后仍残留 127.0.0.1:${FALLBACK_PORT:-8443}"; rc=1
fi

# ---- E：旧配置兼容性 —— state.env 损坏时也不得自动覆盖 config.json ----
echo "======== 旧配置兼容性：state.env 缺 UUID + 未明确选择 ========"
# 先人为破坏状态文件，再取快照；之后断言「一个字节都不动」。
sed -i 's/^UUID="[^"]*"/UUID=""/' "$state"
snap_e="$(snapshot)"
bash "$T/test-copy.sh" --yes --modules 6,8,9 > "$T/broken-state.log" 2>&1
e_rc=$?
if [[ $e_rc -eq 0 ]] && grep -q '凭据不完整' "$T/broken-state.log"; then
    echo "PASS  状态文件残缺时明确提示凭据不完整且未中断"
else
    echo "FAIL  状态文件残缺时缺少提示或异常退出（rc=$e_rc）"; rc=1
fi
if [[ "$(snapshot)" == "$snap_e" ]]; then
    echo "PASS  状态文件残缺且未明确选择时，config.json 与凭据文件仍未被覆盖"
else
    echo "FAIL  状态文件残缺时自动覆盖了旧配置"; rc=1
fi

# ---- F：--uuid 固定值在「生成新配置」下必须被忽略（禁止复用固定值）----
echo "======== 固定值校验：--new-config + --uuid ========"
FIXED_UUID="11111111-2222-4333-8444-555555555555"
bash "$T/test-copy.sh" --yes --new-config --modules 6,8,9 --uuid "$FIXED_UUID" > "$T/fixed-uuid.log" 2>&1
f_rc=$?
uuid_fixed="$(uuid_of)"
if [[ $f_rc -eq 0 ]] && grep -q '命令行 --uuid 本次被忽略' "$T/fixed-uuid.log" && [[ "$uuid_fixed" != "$FIXED_UUID" ]]; then
    echo "PASS  --new-config 忽略 --uuid 固定值，生成了全新 UUID（${uuid_fixed}）"
else
    echo "FAIL  --new-config 复用了 --uuid 固定值（rc=$f_rc, uuid=$uuid_fixed）"; rc=1
fi

# ---- G：只读模式不受二选一影响；不含模块 6/8 时不弹菜单 ----
echo "======== 原有功能回归：只读模式 / 模块 7 ========"
RERUN_MODE=bogus bash "$T/test-copy.sh" --print-outbounds --ips 1.2.3.4 > "$T/readonly.log" 2>&1
g_rc=$?
if [[ $g_rc -eq 0 ]] && grep -q '"outbounds"' "$T/readonly.log" && ! grep -q '请输入 1 或 2' "$T/readonly.log"; then
    echo "PASS  --print-outbounds 只读渲染不受二选一影响"
else
    echo "FAIL  只读渲染被二选一干扰（rc=$g_rc）"; rc=1
fi
bash "$T/test-copy.sh" --yes --modules 7 > "$T/mod7-only.log" 2>&1
m7_rc=$?
if [[ $m7_rc -eq 0 ]] && ! grep -q '请输入 1 或 2' "$T/mod7-only.log"; then
    echo "PASS  不含模块 6/8 的重跑不弹二选一菜单（rc=0）"
else
    echo "FAIL  重跑菜单行为异常（rc=$m7_rc）"; rc=1
fi

# ---- H：首次部署时 --uuid 固定值仍生效（不破坏既有参数）----
echo "======== 既有参数回归：首次部署 + --uuid ========"
FIRST_UUID="11111111-2222-4333-8444-999999999999"
# 清掉状态文件与 config.json，模拟一台全新的机器（这两个都是沙箱测试产物）。
rm -f "$state" "$cfg"
bash "$T/test-copy.sh" --yes --uuid "$FIRST_UUID" "${FULL_ARGS[@]}" > "$T/first-uuid.log" 2>&1
h_rc=$?
if [[ $h_rc -eq 0 ]] && [[ "$(uuid_of)" == "$FIRST_UUID" ]] && [[ -s $cfg ]]; then
    echo "PASS  首次部署尊重 --uuid 固定值，且正常生成 config.json"
else
    echo "FAIL  首次部署的 --uuid 被误忽略或配置未生成（rc=$h_rc, uuid=$(uuid_of)）"; rc=1
fi
if grep -q '检测到已有部署' "$T/first-uuid.log"; then
    echo "FAIL  首次部署误报「已有部署」"; rc=1
else
    echo "PASS  首次部署不弹重跑二选一、不误报已有部署"
fi

# ---- I：一次完整跑完的输出里不允许出现 shell 级解析错误 ----
# 曾经把 `# 说明` 写在 printf 的续行里，续行被就地结束、后面的实参
# （1000mbit）变成独立命令被执行：报 "command not found"、退出码 127、
# 模块 9 整段中止，而摘要前半截已经 tee 进 /root/vps-init.info。
# bash -n 查不出来，只能在真跑日志里盯这几种字样。
echo "======== 完整跑完的日志里无 shell 级错误 ========"
if grep -qE 'command not found|syntax error|unbound variable' "$T/first-uuid.log"; then
    echo "FAIL  完整部署日志里出现 shell 级错误："; grep -nE 'command not found|syntax error|unbound variable' "$T/first-uuid.log" | head -5; rc=1
else
    echo "PASS  完整部署日志里没有 command not found / syntax error / unbound variable"
fi
if grep -qF '==> [9] 交付汇总' "$T/first-uuid.log" \
   && { ! grep -q '已保存到 .*vps-init.info' "$T/first-uuid.log" \
        || ! grep -q '客户端 outbounds 已单独保存' "$T/first-uuid.log"; }; then
    echo "FAIL  模块 9 没有走完（缺 vps-init.info / client-outbounds.json 落盘确认）——交付文件可能没落盘"; rc=1
else
    echo "PASS  模块 9 走完并落了 vps-init.info 与 client-outbounds.json"
fi

exit $rc
