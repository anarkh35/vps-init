#!/usr/bin/env bash
# 单元测试台：直接 source 真实脚本（vps-init.sh 末尾有"只被直接执行才跑 main"的守卫），
# 不再用 `head -n -1` 剪出来的 lib.sh 副本 —— 副本一旦漂移，测的就不是要发布的那个文件。
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF/../vps-init.sh"
# 被测脚本自带 set -Eeuo pipefail。作为测试台，这里必须关掉 -e：
# 否则一条"期望失败"的调用（fetch_file 重试耗尽、need_port 拒绝非法值…）
# 会直接把整个测试台带崩，后面的用例全部看不到，问题会被掩盖。
# 保留 -u / pipefail，仍然能抓到拼写错误与管道半途失败。
set +e

# Windows/MSYS 的挂载点不支持 POSIX 权限位：chmod 不报错但也不生效。
# 权限类断言在目标平台（Debian）上有意义，在本机无法验证，因此先探测能力再决定是否断言，
# 避免把"平台差异"误报成"功能回归"。
FS_HAS_PERM=0
_pp="$SELF/.perm_probe"; : > "$_pp"
chmod 600 "$_pp" 2>/dev/null || true
[[ "$(stat -c %a "$_pp" 2>/dev/null)" == "600" ]] && FS_HAS_PERM=1
rm -f "$_pp"

pass=0; fail=0
chk() { # chk <描述> <期望> <实际>
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); printf 'PASS  %s\n' "$1"
    else fail=$((fail+1)); printf 'FAIL  %s\n      期望=[%s]\n      实际=[%s]\n' "$1" "$2" "$3"; fi
}

echo "=========== T1 urlenc 百分号编码 ==========="
chk "base64 含 + / =" 'a%2Bb%2Fc%3Dd' "$(urlenc 'a+b/c=d')"
chk "空格与 # & ? :"      'x%20y%23z%26w%3Fv%3Au' "$(urlenc 'x y#z&w?v:u')"
chk "% 优先不二次编码"     '%25%20%2520' "$(urlenc '% %20')"
chk "字面 %20 编码一次"    '%2520' "$(urlenc '%20')"
chk "at 与引号"           'a%40b%22c' "$(urlenc 'a@b"c')"
chk "IPv6 冒号"           '2001%3Adb8%3A%3A1' "$(urlenc '2001:db8::1')"

echo
echo "=========== T2 分享链接（IPv6 + 特殊节点名） ==========="
NODE_IPS=('2001:db8::1')
T_VL=('东京 #1 v4-vl')
T_HY2=('东京 #1 v4-hy2')
VLESS_PORT=443; HY2_PORT=16407; HOP_RANGE=""
REALITY_SNI="a.example.com"; REALITY_PUB="PUB-KEY_123"; SHORT_ID="0123456789abcdef"
CERT_CN="bing.com"; CERT_HASH=""
UUID="11111111-2222-4333-8444-555555555555"
HY2_PW="p+q/r=s"; OBFS_PW="o+q/r=s"
v="$(vless_link_for 0)"; h="$(hy2_link_for 0)"
echo "  vless : $v"
echo "  hy2   : $h"
chk "vless 主机加方括号" '1' "$([[ $v == *"@[2001:db8::1]:443?"* ]] && echo 1 || echo 0)"
chk "vless 节点名已编码" '1' "$([[ $v == *'#东京%20%231%20v4-vl'* ]] && echo 1 || echo 0)"
chk "hy2 密码已编码"     '1' "$([[ $h == *'hysteria2://p%2Bq%2Fr%3Ds@[2001:db8::1]:16407/'* ]] && echo 1 || echo 0)"
chk "hy2 无指纹走 insecure" '1' "$([[ $h == *'&insecure=1'* ]] && echo 1 || echo 0)"
CERT_SHA256="252a35f2ee445063319242ea044c931559d60bdac7f8fd2e5669112b01a7c9dd"
CERT_HASH="ab+cd/ef="
h2="$(hy2_link_for 0)"
chk "hy2 有指纹走 pinSHA256（证书指纹 hex，非公钥哈希）" '1' \
    "$([[ $h2 == *"&pinSHA256=${CERT_SHA256}"* ]] && echo 1 || echo 0)"
chk "hy2 链接不含公钥哈希 base64" '0' \
    "$([[ $h2 == *'ab%2Bcd'* ]] && echo 1 || echo 0)"
chk "hy2 缺证书指纹时降级 insecure" '1' \
    "$( CERT_SHA256=''; l="$(hy2_link_for 0)"; \
        [[ $l == *'&insecure=1'* && $l != *'pinSHA256'* ]] && echo 1 || echo 0 )"
CERT_SHA256=""

echo
echo "=========== T3 端口跳跃 mport 与单端口 ==========="
HOP_RANGE="30000:50000"
h3="$(hy2_link_for 0)"
chk "mport 冒号转连字符" '1' "$([[ $h3 == *'&mport=30000-50000'* ]] && echo 1 || echo 0)"

echo
echo "=========== T4 is_private_addr 边界 ==========="
chk "10.0.0.1 私网"       'private' "$(is_private_addr 10.0.0.1 && echo private || echo public)"
chk "100.63.0.1 公网"     'public'  "$(is_private_addr 100.63.0.1 && echo private || echo public)"
chk "100.64.0.1 CGNAT"    'private' "$(is_private_addr 100.64.0.1 && echo private || echo public)"
chk "100.127.255.1 CGNAT" 'private' "$(is_private_addr 100.127.255.1 && echo private || echo public)"
chk "100.108.0.1 CGNAT"   'private' "$(is_private_addr 100.108.0.1 && echo private || echo public)"
chk "100.109.0.1 CGNAT"   'private' "$(is_private_addr 100.109.0.1 && echo private || echo public)"
chk "100.118.0.1 CGNAT"   'private' "$(is_private_addr 100.118.0.1 && echo private || echo public)"
chk "100.119.0.1 CGNAT"   'private' "$(is_private_addr 100.119.0.1 && echo private || echo public)"
chk "100.128.0.1 公网"    'public'  "$(is_private_addr 100.128.0.1 && echo private || echo public)"
chk "172.15.0.1 公网"     'public'  "$(is_private_addr 172.15.0.1 && echo private || echo public)"
chk "172.16.0.1 私网"     'private' "$(is_private_addr 172.16.0.1 && echo private || echo public)"
chk "172.31.255.1 私网"   'private' "$(is_private_addr 172.31.255.1 && echo private || echo public)"
chk "172.32.0.1 公网"     'public'  "$(is_private_addr 172.32.0.1 && echo private || echo public)"
chk "192.0.2.1 文档段"    'private' "$(is_private_addr 192.0.2.1 && echo private || echo public)"
chk "224.0.0.1 组播"      'private' "$(is_private_addr 224.0.0.1 && echo private || echo public)"
chk "fe80::1 链路本地"    'private' "$(is_private_addr fe80::1 && echo private || echo public)"
chk "febf::1 链路本地"    'private' "$(is_private_addr febf::1 && echo private || echo public)"
chk "fd00::1 ULA"         'private' "$(is_private_addr fd00::1 && echo private || echo public)"
chk "2001:db8::1 文档段"  'private' "$(is_private_addr 2001:db8::1 && echo private || echo public)"
chk "2606:4700::1 公网"   'public'  "$(is_private_addr 2606:4700::1 && echo private || echo public)"
chk "1.2.3.4 公网"        'public'  "$(is_private_addr 1.2.3.4 && echo private || echo public)"

echo
echo "=========== T5 状态文件优先级 ==========="
STATE_DIR="$SELF/state"; rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/state.env"
SSH_PORT=2222; UUID="keep-me"; load_state
chk "首次无状态文件不变" '2222' "$SSH_PORT"
save_state
chk "状态文件已生成" '1' "$([[ -s $STATE_FILE ]] && echo 1 || echo 0)"
if [[ $FS_HAS_PERM -eq 1 ]]; then
    chk "状态文件权限 600" '600' "$(stat -c %a "$STATE_FILE")"
else
    printf 'SKIP  状态文件权限 600（本机文件系统不支持 POSIX 权限位；Debian 上由 save_state 的 chmod 600 保证）\n'
fi
SSH_PORT=51736; UUID=""; load_state          # 无 CLI 指定 → 应回填
chk "回填 SSH_PORT" '2222' "$SSH_PORT"
chk "回填 UUID"     'keep-me' "$UUID"
SSH_PORT=51736; declare -A CLI_SET=([SSH_PORT]=1); load_state
chk "CLI 优先于状态文件" '51736' "$SSH_PORT"
declare -A CLI_SET=()

echo
echo "=========== T6 --ips 解析（方括号 IPv6） ==========="
IP_LIST="1.2.3.4,[2001:db8::1]"; detect_ips
chk "detect_ips 去方括号" '1.2.3.4 2001:db8::1' "${NODE_IPS[*]}"
IP_LIST="1.2.3.4,[2001:db8::1]"; ips_from_args
chk "ips_from_args 去方括号" '1.2.3.4 2001:db8::1' "${NODE_IPS[*]}"

echo
echo "=========== T7 sshd 主配置注释（幂等性） ==========="
cat > "$SELF/sshd_config" <<'EOF'
Include /etc/ssh/sshd_config.d/*.conf
#Port 22
Port 22
PermitRootLogin yes
PasswordAuthentication yes
#PasswordAuthentication yes
EOF
KEYS=(Port PasswordAuthentication PermitRootLogin PubkeyAuthentication \
      KbdInteractiveAuthentication PermitEmptyPasswords ChallengeResponseAuthentication)
for k in "${KEYS[@]}"; do
    sed -i -E "s|^([[:space:]]*${k}[[:space:]].*)$|# \\1  # vps-init|" "$SELF/sshd_config"
done
cp "$SELF/sshd_config" "$SELF/sshd_config.1"
for k in "${KEYS[@]}"; do
    sed -i -E "s|^([[:space:]]*${k}[[:space:]].*)$|# \\1  # vps-init|" "$SELF/sshd_config"
done
sed 's/^/      /' "$SELF/sshd_config"
chk "二次执行不叠加注释" '1' "$(cmp -s "$SELF/sshd_config" "$SELF/sshd_config.1" && echo 1 || echo 0)"

echo
echo "=========== T8 ipt_add / ipt_head 幂等（桩 iptables） ==========="
# 桩目录可能在上次清理后不存在；单独跑 unit.sh（不经 all.sh 的冒烟层）也要能自建
mkdir -p "$SELF/bin"
cat > "$SELF/bin/fakeipt" <<'EOF'
#!/usr/bin/env bash
# 只按"链 + 规则体"记账，忽略动作符（-C/-A/-I）与 -I 的位置参数，
# 这样才能模拟真实 iptables 的：-C 命中则不再重复插入
log="$FAKE_LOG"
op="${1:-}"; shift || true
chain="${1:-}"; shift || true
if [[ "$op" == "-I" ]]; then shift || true; fi
key="$chain $*"
if [[ "$op" == "-C" ]]; then
    grep -qxF "RULE $key" "$log" 2>/dev/null && exit 0 || exit 1
fi
echo "RULE $key" >> "$log"
EOF
chmod +x "$SELF/bin/fakeipt"
: > "$SELF/unit-ipt.log"; FAKE_LOG="$SELF/unit-ipt.log"; export FAKE_LOG
ipt_add "$SELF/bin/fakeipt" INPUT -p tcp --dport 22 -j ACCEPT
ipt_add "$SELF/bin/fakeipt" INPUT -p tcp --dport 22 -j ACCEPT
ipt_head "$SELF/bin/fakeipt" INPUT -i lo -j ACCEPT
ipt_head "$SELF/bin/fakeipt" INPUT -i lo -j ACCEPT
chk "重复调用只落两条规则" '2' "$(wc -l < "$SELF/unit-ipt.log" | tr -d ' ')"

echo
echo "=========== T9 入站监听决策 hy2_listen_addrs ==========="
BIND_MAP=()
NODE_IPS=(1.1.1.1); BIND_ALL=""
hy2_listen_addrs; chk "单 v4 → 单实例 0.0.0.0" '0.0.0.0' "${HY2_LISTEN_ADDRS[*]}"
chk "单 v4 → listen 不含公网 IP" '0' "$( [[ " ${HY2_LISTEN_ADDRS[*]} " == *' 1.1.1.1 '* ]] && echo 1 || echo 0 )"
chk "单 v4 → 拆分标志 0" '0' "$HY2_SPLIT_BY_IP"
NODE_IPS=(2001:db8::1)
hy2_listen_addrs; chk "单 v6 → 单实例 ::" '::' "${HY2_LISTEN_ADDRS[*]}"
chk "单 v6 → 拆分标志 0" '0' "$HY2_SPLIT_BY_IP"
NODE_IPS=(1.1.1.1 2001:db8::1)
hy2_listen_addrs; chk "单 v4+单 v6 → 单实例 ::" '::' "${HY2_LISTEN_ADDRS[*]}"
NODE_IPS=(1.1.1.1 2.2.2.2)
hy2_listen_addrs; chk "多 v4 → 按 IP 拆分" '1.1.1.1 2.2.2.2' "${HY2_LISTEN_ADDRS[*]}"
chk "多 v4 → 拆分标志 1" '1' "$HY2_SPLIT_BY_IP"
NODE_IPS=(2001:db8::1 2001:db8::2)
hy2_listen_addrs; chk "多 v6 → 按 IP 拆分" '2001:db8::1 2001:db8::2' "${HY2_LISTEN_ADDRS[*]}"
NODE_IPS=(1.1.1.1 2.2.2.2)
BIND_ALL=1
hy2_listen_addrs; chk "--bind-all 强制单实例" '::' "${HY2_LISTEN_ADDRS[*]}"
chk "--bind-all → 拆分标志 0" '0' "$HY2_SPLIT_BY_IP"
BIND_ALL=""

echo
echo "=========== T10 tag 编号 build_node_tags ==========="
# 前缀优先用显式 --node-name；不给时自动识别机房城市（测试环境关掉外网查询）
export VPS_INIT_SKIP_GEO=1
NODE_NAME="东京 1T"; NODE_IPS=(1.1.1.1 2.2.2.2 2001:db8::1)
build_node_tags
chk "多 v4+v6 的 tag" '东京 1T v4.1-hy2 东京 1T v4.2-hy2 东京 1T v6-hy2' "${T_HY2[*]}"
chk "vless tag"       '东京 1T v4.1-vl 东京 1T v4.2-vl 东京 1T v6-vl' "${T_VL[*]}"
# 单地址同族不带序号
NODE_IPS=(1.1.1.1 2001:db8::1); build_node_tags
chk "单 v4+单 v6 不带序号" '东京 1T v4-hy2 东京 1T v6-hy2' "${T_HY2[*]}"
# 多个 v6 时用点号序号
NODE_IPS=(2001:db8::1 2001:db8::2 2001:db8::3); build_node_tags
chk "多 v6 用点号序号" '东京 1T v6.1-hy2 东京 1T v6.2-hy2 东京 1T v6.3-hy2' "${T_HY2[*]}"
# 未指定 --node-name 时前缀走自动识别（此处关掉了外网查询 → 回退 hostname）
# 用 shell 函数覆盖 hostname，让断言与真实主机名无关
hostname() { echo testnode; }
NODE_NAME=""; NODE_IPS=(1.1.1.1); build_node_tags
chk "无 node-name 时回退 hostname" "testnode v4-hy2" "${T_HY2[*]}"
NODE_NAME="东京 1T"
unset -f hostname

echo
echo "=========== T10b 机房位置识别工具 ==========="
chk "has_cjk 中文"   '1' "$(has_cjk "洛杉矶" && echo 1 || echo 0)"
chk "has_cjk 英文"   '0' "$(has_cjk "Chiyoda City" && echo 1 || echo 0)"
chk "has_cjk 空串"   '0' "$(has_cjk "" && echo 1 || echo 0)"
chk "去市后缀"       '大阪'     "$(trim_place_suffix '大阪市')"
chk "去府后缀"       '大阪'     "$(trim_place_suffix '大阪府')"
chk "去都后缀"       '东京'     "$(trim_place_suffix '东京都')"
chk "去州后缀"       '新泽西'   "$(trim_place_suffix '新泽西州')"
chk "两字不误伤"     '市'       "$(trim_place_suffix '市')"
chk "无后缀原样"     '洛杉矶'   "$(trim_place_suffix '洛杉矶')"
chk "json_pick city" '洛杉矶'   "$(json_pick '{"city":"洛杉矶","regionName":"加州"}' city)"
chk "json_pick 缺字段" ''      "$(json_pick '{"city":"洛杉矶"}' regionName)"

echo
echo "=========== T11 取值校验（die 在子 shell 中捕获） ==========="
rc() { ( "$@" ) >/dev/null 2>&1; echo $?; }
chk "端口 443 通过"      '0' "$(rc need_port --p 443)"
chk "端口 abc 拦截"      '1' "$(rc need_port --p abc)"
chk "端口 0 拦截"        '1' "$(rc need_port --p 0)"
chk "端口 70000 拦截"    '1' "$(rc need_port --p 70000)"
chk "时长 15s 通过"      '0' "$(rc need_duration --d 15s)"
chk "时长 15 拦截"       '1' "$(rc need_duration --d 15)"
chk "时长 1sec 拦截"     '1' "$(rc need_duration --d 1sec)"
HOP_RANGE="30000:50000"; chk "跳跃 A:B 通过"  '0' "$(rc need_hop_range)"
HOP_RANGE="30000-50000"; chk "跳跃连字符拦截" '1' "$(rc need_hop_range)"
HOP_RANGE="50000:30000"; chk "跳跃倒序拦截"   '1' "$(rc need_hop_range)"
HOP_RANGE="0:100";       chk "跳跃 0 端口拦截" '1' "$(rc need_hop_range)"
HOP_RANGE="";            chk "空跳跃放行"      '0' "$(rc need_hop_range)"
HY2_PORT=16407
HOP_RANGE="30000:50000"
# T5 从状态文件回填了 UUID="keep-me"（合法状态文件语义），这里换成合法 UUID 再校验
UUID="11111111-2222-4333-8444-555555555555"
chk "validate_settings 全通过" '0' "$(rc validate_settings)"
VLESS_PORT=abc; chk "validate_settings 拦非法端口" '1' "$(rc validate_settings)"
VLESS_PORT=443
chk "域名白名单拦截引号"  '1' "$(rc need_hostname --domain 'a"b.com')"
chk "域名白名单放行正常域" '0' "$(rc need_hostname --domain 'a.example.com')"
chk "UUID 白名单拦截"     '1' "$(rc is_uuid not-a-uuid)"
chk "UUID 白名单放行"     '0' "$(rc is_uuid 11111111-2222-4333-8444-555555555555)"
chk "速率白名单拦截空格"  '1' "$(rc is_rate '1000 mbit')"
chk "速率白名单放行"      '0' "$(rc is_rate 1000mbit)"
# tcpfit 的 shape --rate 用 Mbps 数字，is_rate 两种写法都要放行
chk "速率白名单放行纯数字(Mbps)" '0' "$(rc is_rate 1000)"
chk "速率白名单拦截非数字"  '1' "$(rc is_rate abc)"
# --tcp-bw 必须是正整数：0 会被 tcpfit 当成无效带宽（真校验入口在 validate_settings；
# 此前两行断言用 bash -c 测正则本身，是恒真伪断言 —— 已改为打真函数，并在 renders 层补 CLI 级场景）
chk "tcp-bw 拦截 0（validate_settings）"     '1' "$( ( TCP_BW=0; validate_settings ) >/dev/null 2>&1 && echo 0 || echo 1 )"
chk "tcp-bw 放行正整数（validate_settings）"  '0' "$( ( TCP_BW=1000; validate_settings ) >/dev/null 2>&1 && echo 0 || echo 1 )"
TCP_BW=""
chk "REALITY_DEST 放行 IPv6" '0' "$(rc need_host --reality-dest 2001:db8::1)"

echo
echo "=========== T12 名称清洗与 IP 列表拆分 ==========="
chk "sanitize 去换行"   'ab' "$(sanitize_name $'a\nb')"
chk "sanitize 去制表"   'a b' "$(sanitize_name $'a\tb')"
chk "sanitize 去引号反斜杠美元" 'abcd' "$(sanitize_name 'a"b\c$d')"
split_ip_list " 1.2.3.4 , [2001:db8::1] ,,"; chk "split 去空格去方括号" '1.2.3.4 2001:db8::1' "${SPLIT_IPS[*]}"
split_ip_list ""; chk "split 空串安全" '0' "${#SPLIT_IPS[@]}"

echo
echo "=========== T13 JSON 构造器（统一转义 / 自动逗号 / 空值守卫） ==========="
chk "json_escape 引号"     'a\"b'   "$(json_escape 'a"b')"
chk "json_escape 反斜杠"   'a\\b'   "$(json_escape 'a\b')"
# 反斜杠必须先于引号处理：否则 a\"b 会被处理成 a\\"b（二次转义）
chk "json_escape 反斜杠优先" 'a\\\"b' "$(json_escape 'a\"b')"
chk "json_escape 制表符"   'a\tb'   "$(json_escape $'a\tb')"
chk "json_escape 换行"     'a\nb'   "$(json_escape $'a\nb')"
chk "json_escape 控制字符剔除" 'ab' "$(json_escape $'a\vb')"
chk "j_kv 基本"            '"k": "v"' "$(j_kv k v)"
chk "j_kv 值已转义"        '"k": "a\"b"' "$(j_kv k 'a"b')"
chk "j_lit 数字"           '"p": 443' "$(j_lit p 443)"
chk "j_lit 布尔"           '"e": true' "$(j_lit e true)"
chk "j_lit 拒绝前导零"      '1' "$(rc j_lit port 0443)"
chk "j_lit 接受 0"          '0' "$(rc j_lit port 0)"
chk "j_lit 接受负数"        '0' "$(rc j_lit x -5)"
chk "j_obj 单成员"         $'{\n    "a": 1\n}' "$(j_obj '' "$(j_lit a 1)")"
chk "j_obj 两成员自动逗号" $'{\n    "a": 1,\n    "b": 2\n}' "$(j_obj '' "$(j_lit a 1)" "$(j_lit b 2)")"
chk "j_obj 嵌套缩进"       $'{\n      "a": 1\n  }' "$(j_obj '  ' "$(j_lit a 1)")"
chk "j_arr 单元素"         $'[\n    "a"\n]' "$(j_arr '' '"a"')"
chk "j_arr 两元素"         $'[\n    "a",\n    "b"\n]' "$(j_arr '' '"a"' '"b"')"
# 空值守卫：宁可在这里明确报错，也不要吐出 "server_port": , 这种非法 JSON
chk "j_lit 拒绝空值"       '1' "$(rc j_lit port '')"
chk "j_lit 拒绝非数字"     '1' "$(rc j_lit port abc)"
chk "json_balance_ok 配平通过" '0' "$(json_balance_ok '{"a":[1,2],"b":"x"}' && echo 0 || echo 1)"
chk "json_balance_ok 抓未闭合" '1' "$(json_balance_ok '{"a":[1,2}' && echo 0 || echo 1)"
chk "json_balance_ok 抓字符串内裸换行" '1' "$(json_balance_ok $'{"a":"x\ny"}' && echo 0 || echo 1)"
# 转义引号不能误判成字符串结束，否则会把合法 JSON 报成非法
chk "json_balance_ok 识别 \\\" 转义" '0' "$(json_balance_ok '{"a":"x\"y"}' && echo 0 || echo 1)"
chk "json_balance_ok 识别结尾反斜杠转义" '0' "$(json_balance_ok '{"a":"x\\"}' && echo 0 || echo 1)"

echo
echo "=========== T14 下载封装（重试 / 缓存 / 原子落盘） ==========="
T14DIR="$SELF/t14"; rm -rf "$T14DIR"; mkdir -p "$T14DIR/bin" "$T14DIR/cache"
cat > "$T14DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
# 可控桩：T14_FAIL_UNTIL 决定"前几次失败"，调用次数记进 T14_LOG
echo call >> "$T14_LOG"
n=$(wc -l < "$T14_LOG" | tr -d ' ')
out=""; prev=""; url=""
for a in "$@"; do
    case "$prev" in -o) out="$a";; esac
    case "$a" in http://*|https://*) url="$a";; esac
    prev="$a"
done
if (( n <= ${T14_FAIL_UNTIL:-0} )); then
    echo "curl: (7) Failed to connect to ${url}" >&2
    exit 7
fi
if [[ -n $out ]]; then mkdir -p "$(dirname "$out")"; printf 'payload:%s' "$url" > "$out"
else printf 'payload:%s' "$url"; fi
exit 0
EOF
chmod +x "$T14DIR/bin/curl"
export PATH="$T14DIR/bin:$PATH"
export T14_LOG="$T14DIR/curl.log"
export T14_FAIL_UNTIL=0
CACHE_DIR="$T14DIR/cache"
FETCH_RETRIES=3
FETCH_BACKOFF=0

: > "$T14_LOG"
r=0; fetch_file "$T14DIR/dest/a.sh" "https://example.com/a.sh" >/dev/null 2>&1 || r=$?
chk "首次下载成功" '0' "$r"
chk "内容已落盘" 'payload:https://example.com/a.sh' "$(cat "$T14DIR/dest/a.sh")"
ca="$(fetch_cache_path 'https://example.com/a.sh')"
chk "同时写入缓存" '1' "$([[ -s $ca ]] && echo 1 || echo 0)"
# 缓存键必须带 URL 指纹，否则不同站点上的同名文件会互相污染缓存（静默命中别人的内容）
chk "同名不同站的缓存键不同" '1' \
    "$([[ "$(fetch_cache_path 'https://example.com/x.sh')" != "$(fetch_cache_path 'https://other.example.org/x.sh')" ]] && echo 1 || echo 0)"
chk "同一 URL 的缓存键稳定" '1' \
    "$([[ "$(fetch_cache_path 'https://example.com/x.sh')" == "$(fetch_cache_path 'https://example.com/x.sh')" ]] && echo 1 || echo 0)"

: > "$T14_LOG"
fetch_file "$T14DIR/dest2/a.sh" "https://example.com/a.sh" >/dev/null 2>&1
chk "命中缓存时不再发起网络请求" '0' "$(wc -l < "$T14_LOG" | tr -d ' ')"
chk "缓存内容已复制到新目标（目标目录不存在也成立）" 'payload:https://example.com/a.sh' "$(cat "$T14DIR/dest2/a.sh" 2>/dev/null)"

rm -rf "$T14DIR/cache"; T14_FAIL_UNTIL=2; : > "$T14_LOG"
r=0; fetch_file "$T14DIR/dest/b.sh" "https://example.com/b.sh" >/dev/null 2>&1 || r=$?
chk "前两次失败后第三次成功" '0' "$r"
chk "恰好尝试 3 次" '3' "$(wc -l < "$T14_LOG" | tr -d ' ')"

rm -rf "$T14DIR/cache"; T14_FAIL_UNTIL=99; : > "$T14_LOG"
r=0; fetch_file "$T14DIR/dest/c.sh" "https://example.com/c.sh" >/dev/null 2>&1 || r=$?
chk "全部失败时返回 1" '1' "$r"
chk "失败后不残留 .part 半成品" '0' "$(ls -A "$T14DIR/dest" 2>/dev/null | grep -c '\.part$' || true)"
chk "失败后目标文件不存在" '0' "$([[ -e $T14DIR/dest/c.sh ]] && echo 1 || echo 0)"

T14_FAIL_UNTIL=0; : > "$T14_LOG"
chk "fetch_stdout 输出内容" 'payload:https://example.com/s.sh' "$(fetch_stdout https://example.com/s.sh 2>/dev/null)"
T14_FAIL_UNTIL=99
r=0; fetch_stdout https://example.com/x.sh >/dev/null 2>&1 || r=$?
chk "fetch_stdout 失败时无输出且返回非 0" '1' "$r"
PATH="${PATH#"$T14DIR/bin:"}"; export PATH
CACHE_DIR="/var/cache/vps-init"

echo
echo "=========== T15 状态值转义往返 ==========="
chk "escape/unescape 引号"   'a"b'   "$(state_unescape "$(state_escape 'a"b')")"
chk "escape/unescape 反斜杠" 'a\b'   "$(state_unescape "$(state_escape 'a\b')")"
chk "escape/unescape 混合"   'a\"b\c' "$(state_unescape "$(state_escape 'a\"b\c')")"
chk "escape 去掉换行"        'ab'    "$(state_escape $'a\nb')"
chk "STATE_KEYS 无重复"      '0'     "$(printf '%s\n' "${STATE_KEYS[@]}" | sort | uniq -d | wc -l | tr -d ' ')"
STATE_DIR="$SELF/state2"; STATE_FILE="$STATE_DIR/state.env"; rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
WEB_PAGE='/tmp/a"b.txt'; NODE_NAME='x\y"z'
save_state
chk "状态文件已写入" '1' "$([[ -s $STATE_FILE ]] && echo 1 || echo 0)"
WEB_PAGE=""; NODE_NAME=""; declare -A CLI_SET=(); load_state
chk "带引号的值往返一致"     '/tmp/a"b.txt' "$WEB_PAGE"
chk "反斜杠+引号的值往返一致" 'x\y"z'       "$NODE_NAME"
WEB_PAGE=""; NODE_NAME=""
save_state
chk "空值写为引号空串（读回来仍是空）" '1' "$(grep -c '^WEB_PAGE=""$' "$STATE_FILE" || true)"
declare -A CLI_SET=(); WEB_PAGE="sentinel"; load_state
chk "空值往返后仍为空" '' "$WEB_PAGE"

echo
echo "=========== T16 NAT 机型检测与固定端口适配 ==========="
chk "need_nat_ports 合法 A:B"       '0' "$(rc need_nat_ports 20000:20020)"
chk "need_nat_ports 单端口通过"     '0' "$(rc need_nat_ports 30443)"
chk "need_nat_ports 离散端口通过"   '0' "$(rc need_nat_ports 30022,30443,30444)"
chk "need_nat_ports 段+单端口通过"  '0' "$(rc need_nat_ports 20000:20020,30443)"
chk "need_nat_ports 倒序拦截"       '1' "$(rc need_nat_ports 30000:20000)"
chk "need_nat_ports 空项拦截"       '1' "$(rc need_nat_ports '30443,,30444')"
chk "need_nat_ports 越界拦截"       '1' "$(rc need_nat_ports 70000)"
chk "need_nat_v4_services 合法"     '0' "$(rc need_nat_v4_services 'vless,hy2')"
chk "need_nat_v4_services 非法拦截" '1' "$(rc need_nat_v4_services 'dns')"
chk "parse_nat_map 合法映射"    '0' "$(rc parse_nat_map 'vless=30443,hy2=30444')"
chk "parse_nat_map 空串放行"    '0' "$(rc parse_nat_map '')"
chk "parse_nat_map 未知服务拦截" '1' "$(rc parse_nat_map 'foo=123')"
chk "parse_nat_map 缺等号拦截"   '1' "$(rc parse_nat_map 'vless')"
chk "parse_nat_map 非法端口拦截" '1' "$(rc parse_nat_map 'vless=99999')"
chk "rotate_old_baks 只保留最新 5 份" '5' \
    "$( mkdir -p "$SELF/rot"; rm -f "$SELF/rot"/*.bak 2>/dev/null; \
        for i in 1 2 3 4 5 6 7; do printf x > "$SELF/rot/b.2026010${i}-000000.bak"; done; \
        rotate_old_baks "$SELF/rot/*.bak"; ls -1 "$SELF/rot"/*.bak 2>/dev/null | wc -l )"
rm -rf "$SELF/rot"
chk "parse_nat_map6 共用外部端口警告" '1' \
    "$( parse_nat_map6 'vless=31443,hy2=31443' 2>&1 | grep -c '被多个服务共用' )"
chk "parse_nat_map6 各端口独立时无警告" '0' \
    "$( parse_nat_map6 'vless=31443,hy2=31444' 2>&1 | grep -c '被多个服务共用' )"
chk "parse_nat_map 共用外部端口警告" '1' \
    "$( parse_nat_map 'vless=30443,hy2=30443' 2>&1 | grep -c '被多个服务共用' )"
chk "parse_nat_map 合法共用（只 ssh）不误报 v6 表" '0' \
    "$( parse_nat_map6 'ssh=31022,vless=31443' 2>&1 | grep -c '被多个服务共用' )"
chk "detect_nat 私网卡 → NAT" '1' \
    "$( collect_local_addrs() { printf '%s\n' '10.0.0.5'; }; BIND_MAP=(); \
        NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; detect_nat; printf '%s' "$NAT_ACTIVE" )"
chk "detect_nat 公网直挂 → 非 NAT" '0' \
    "$( collect_local_addrs() { printf '%s\n' '1.2.3.4'; }; BIND_MAP=(); \
        NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; detect_nat; printf '%s' "$NAT_ACTIVE" )"
chk "detect_nat --no-nat 覆盖" '0' \
    "$( collect_local_addrs() { printf '%s\n' '10.0.0.5'; }; BIND_MAP=(); \
        NAT_MODE=off; NAT_PORTS=''; NAT_MAP=''; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; detect_nat; printf '%s' "$NAT_ACTIVE" )"
chk "detect_nat BIND_MAP 非空也是佐证" '1' \
    "$( collect_local_addrs() { printf '%s\n' '2001:db8::1'; }; \
        declare -A BIND_MAP=(); BIND_MAP[1.2.3.4]='10.0.0.5'; \
        NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; detect_nat; printf '%s' "$NAT_ACTIVE" )"
chk "client_port_for NAT+v4 → 外部端口" '30443' \
    "$( NAT_ACTIVE=1; parse_nat_map 'vless=30443' >/dev/null 2>&1; VLESS_PORT=443; client_port_for vless 1.2.3.4 )"
chk "client_port_for NAT+v6 → 内部端口" '443' \
    "$( NAT_ACTIVE=1; parse_nat_map 'vless=30443' >/dev/null 2>&1; VLESS_PORT=443; client_port_for vless 2001:db8::1 )"
chk "client_port_for 非 NAT → 内部端口" '443' \
    "$( NAT_ACTIVE=0; parse_nat_map 'vless=30443' >/dev/null 2>&1; VLESS_PORT=443; client_port_for vless 1.2.3.4 )"
chk "client_port_for 内外同号 → 内部端口" '16407' \
    "$( NAT_ACTIVE=1; parse_nat_map '' >/dev/null 2>&1; HY2_PORT=16407; client_port_for hy2 1.2.3.4 )"
chk "client_port_for 省略 ip 视为 v4" '30022' \
    "$( NAT_ACTIVE=1; parse_nat_map 'ssh=30022' >/dev/null 2>&1; SSH_PORT=22; client_port_for ssh )"
chk "init_nat_for_render 关闭默认跳跃" '1:' \
    "$( NAT_MODE=force; NAT_PORTS=''; NAT_MAP=''; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; \
        CLI_SET=(); HOP_RANGE='30000:50000'; \
        init_nat_for_render >/dev/null; printf '%s:%s' "$NAT_ACTIVE" "$HOP_RANGE" )"
chk "init_nat_for_render v6 全开放保留跳跃" '1:30000:50000' \
    "$( NAT_MODE=force; NAT_PORTS=''; NAT_MAP=''; NAT_V6_OPEN=1; NAT_V4_SERVICES=''; \
        CLI_SET=(); HOP_RANGE='30000:50000'; \
        init_nat_for_render >/dev/null; printf '%s:%s' "$NAT_ACTIVE" "$HOP_RANGE" )"
chk "hop_range_for_ip 非 NAT 全族生效" '30000:50000' \
    "$( NAT_ACTIVE=0; NAT_V6_OPEN=0; HOP_RANGE='30000:50000'; hop_range_for_ip 1.2.3.4 )"
chk "hop_range_for_ip 整机受限 NAT 全族为空" '' \
    "$( NAT_ACTIVE=1; NAT_V6_OPEN=0; HOP_RANGE='30000:50000'; hop_range_for_ip 2001:db8::1 )"
chk "hop_range_for_ip v6 全开放：v6 保留" '30000:50000' \
    "$( NAT_ACTIVE=1; NAT_V6_OPEN=1; HOP_RANGE='30000:50000'; hop_range_for_ip 2001:db8::1 )"
chk "hop_range_for_ip v6 全开放：v4 单端口" '' \
    "$( NAT_ACTIVE=1; NAT_V6_OPEN=1; HOP_RANGE='30000:50000'; hop_range_for_ip 1.2.3.4 )"
chk "nat_ip_needs v4 只留 vless" '1:0' \
    "$( NAT_ACTIVE=1; NAT_V4_SERVICES='vless'; \
        printf '%s:%s' "$(nat_ip_needs 1.2.3.4 vless && echo 1 || echo 0)" \
                       "$(nat_ip_needs 1.2.3.4 hy2 && echo 1 || echo 0)" )"
chk "nat_ip_needs 不影响 v6" '1' \
    "$( NAT_ACTIVE=1; NAT_V4_SERVICES='vless'; nat_ip_needs 2001:db8::1 hy2 && echo 1 || echo 0 )"
chk "nat_ip_needs 不影响占位符" '1' \
    "$( NAT_ACTIVE=1; NAT_V4_SERVICES='vless'; nat_ip_needs '<服务器IP>' hy2 && echo 1 || echo 0 )"
chk "nat_ports_contains 离散端口命中" '0' \
    "$( NAT_PORTS='30022,30443,30444'; rc nat_ports_contains 30443 )"
chk "nat_ports_contains 端口段内命中" '0' \
    "$( NAT_PORTS='20000:20020,30443'; rc nat_ports_contains 20010 )"
chk "nat_ports_contains 清单外端口被拒" '1' \
    "$( NAT_PORTS='30022,30443,30444'; rc nat_ports_contains 30445 )"
chk "apply_nat_adaptation 保持现有 SSH 端口" '22' \
    "$( collect_local_addrs() { printf '%s\n' '10.0.0.5'; }; BIND_MAP=(); CLI_SET=(); \
        sshd() { return 1; }; ss() { return 1; }; NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; \
        NAT_V6_OPEN=0; NAT_V4_SERVICES=''; HOP_RANGE=''; \
        VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=51736; \
        apply_nat_adaptation >/dev/null 2>&1; printf '%s' "$SSH_PORT" )"
chk "apply_nat_adaptation v6 全开放保留跳跃" '30000:50000' \
    "$( collect_local_addrs() { printf '%s\n' '10.0.0.5' '2001:db8::1'; }; BIND_MAP=(); CLI_SET=(); \
        NAT_MODE=auto; NAT_PORTS='30443'; NAT_MAP=''; NAT_V6_OPEN=1; NAT_V4_SERVICES=''; \
        HOP_RANGE='30000:50000'; \
        VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=22; \
        apply_nat_adaptation >/dev/null 2>&1; printf '%s' "$HOP_RANGE" )"
chk "mark_cli --nat 映射到 NAT_MODE" '1' \
    "$( unset 'CLI_SET[NAT_MODE]'; mark_cli --nat; [[ -n ${CLI_SET[NAT_MODE]:-} ]] && echo 1 || echo 0 )"
chk "mark_cli --no-nat-v6-open 映射到 NAT_V6_OPEN" '1' \
    "$( unset 'CLI_SET[NAT_V6_OPEN]'; mark_cli --no-nat-v6-open; \
        [[ -n ${CLI_SET[NAT_V6_OPEN]:-} ]] && echo 1 || echo 0 )"
chk "mark_cli --nat-v4-services 映射到 NAT_V4_SERVICES" '1' \
    "$( unset 'CLI_SET[NAT_V4_SERVICES]'; mark_cli --nat-v4-services; \
        [[ -n ${CLI_SET[NAT_V4_SERVICES]:-} ]] && echo 1 || echo 0 )"
chk "NAT 参数已进 STATE_KEYS" '1' \
    "$( [[ " ${STATE_KEYS[*]} " == *' NAT_MAP '* && " ${STATE_KEYS[*]} " == *' NAT_V6_OPEN '* \
          && " ${STATE_KEYS[*]} " == *' NAT_V4_SERVICES '* ]] && echo 1 || echo 0 )"

echo
echo "=========== T17 交互式分族端口配置 ==========="
chk "nat_join_port_specs 拼接并跳过空项" '20000:20020,30443' \
    "$( nat_join_port_specs '20000:20020' '' ' 30443 ' )"
chk "need_nat_ports 离散端口通过" '0' "$(rc need_nat_ports 30022,30443 --nat-v6-ports)"
chk "need_nat_ports 越界被拒" '1' "$(rc need_nat_ports 70000 --nat-v6-ports)"
chk "parse_nat_map6 合法映射" '0' "$(rc parse_nat_map6 'vless=31443,hy2=31444')"
chk "parse_nat_map6 未知服务被拒" '1' "$(rc parse_nat_map6 'foo=31443')"
chk "parse_nat_map6 端口非法被拒" '1' "$(rc parse_nat_map6 'vless=abc')"
chk "v6 受限 → 用 v6 外部端口" '31443' \
    "$( NAT_ACTIVE=1; NAT_V6_OPEN=0; NAT_V4_OPEN=0; parse_nat_map6 'vless=31443' >/dev/null 2>&1; \
        VLESS_PORT=443; client_port_for vless 2001:db8::1 )"
chk "v4 全开放 → 不套 v4 映射" '443' \
    "$( NAT_ACTIVE=1; NAT_V4_OPEN=1; NAT_V6_OPEN=0; parse_nat_map 'vless=30443' >/dev/null 2>&1; \
        VLESS_PORT=443; client_port_for vless 1.2.3.4 )"
chk "v6 全开放 → 不套 v6 映射" '443' \
    "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=1; parse_nat_map6 'vless=31443' >/dev/null 2>&1; \
        VLESS_PORT=443; client_port_for vless 2001:db8::1 )"
chk "v4 全开放 → v4 保留跳跃" '30000:50000' \
    "$( NAT_ACTIVE=1; NAT_V4_OPEN=1; NAT_V6_OPEN=0; HOP_RANGE='30000:50000'; hop_range_for_ip 1.2.3.4 )"
chk "v4 全开放 → v6 受限不跳跃" '' \
    "$( NAT_ACTIVE=1; NAT_V4_OPEN=1; NAT_V6_OPEN=0; HOP_RANGE='30000:50000'; hop_range_for_ip 2001:db8::1 )"
chk "v6 services 只留 vless" '1:0' \
    "$( NAT_ACTIVE=1; NAT_V6_OPEN=0; NAT_V4_OPEN=0; NAT_V6_SERVICES='vless'; \
        printf '%s:%s' "$(nat_ip_needs 2001:db8::1 vless && echo 1 || echo 0)" \
                       "$(nat_ip_needs 2001:db8::1 hy2 && echo 1 || echo 0)" )"
chk "v6 services 不影响 v4" '1' \
    "$( NAT_ACTIVE=1; NAT_V6_OPEN=0; NAT_V4_OPEN=0; NAT_V6_SERVICES='vless'; \
        nat_ip_needs 1.2.3.4 hy2 && echo 1 || echo 0 )"
chk "两族都全开放 → 按非 NAT 机" '0' \
    "$( collect_local_addrs() { printf '%s\n' '10.0.0.5'; }; BIND_MAP=(); \
        NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_PORTS=''; NAT_V6_MAP=''; \
        NAT_V4_OPEN=1; NAT_V6_OPEN=1; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; \
        detect_nat; printf '%s' "$NAT_ACTIVE" )"
chk "init_nat_for_render v4 全开放保留跳跃" '30000:50000' \
    "$( NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_PORTS=''; NAT_V6_MAP=''; \
        NAT_V4_OPEN=1; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; CLI_SET=(); \
        HOP_RANGE='30000:50000'; init_nat_for_render >/dev/null; printf '%s' "$HOP_RANGE" )"
chk "apply_nat_adaptation v4 全开放保留跳跃" '30000:50000' \
    "$( collect_local_addrs() { printf '%s\n' '1.2.3.4' '2001:db8::1'; }; BIND_MAP=(); CLI_SET=(); \
        NAT_MODE=auto; NAT_PORTS=''; NAT_MAP=''; NAT_V6_PORTS='31443'; NAT_V6_MAP=''; \
        NAT_V4_OPEN=1; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; HOP_RANGE='30000:50000'; \
        VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=22; \
        apply_nat_adaptation >/dev/null 2>&1; printf '%s' "$HOP_RANGE" )"
chk "nat_port_report 受限族无 services 仍返回 0" '0' \
    "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=0; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; \
        nat_port_report >/dev/null 2>&1; printf '%s' "$?" )"
chk "mark_cli --no-nat-v4-open 映射" '1' \
    "$( unset 'CLI_SET[NAT_V4_OPEN]'; mark_cli --no-nat-v4-open; \
        [[ -n ${CLI_SET[NAT_V4_OPEN]:-} ]] && echo 1 || echo 0 )"
chk "向导开关不进 STATE_KEYS" '0' \
    "$( [[ " ${STATE_KEYS[*]} " == *' NAT_WIZARD '* ]] && echo 1 || echo 0 )"
chk "新分族参数已进 STATE_KEYS" '1' \
    "$( [[ " ${STATE_KEYS[*]} " == *' NAT_V4_OPEN '* && " ${STATE_KEYS[*]} " == *' NAT_V6_PORTS '* \
          && " ${STATE_KEYS[*]} " == *' NAT_V6_MAP '* && " ${STATE_KEYS[*]} " == *' NAT_V6_SERVICES '* ]] \
        && echo 1 || echo 0 )"

echo
echo "=========== T18 单端口只够 SSH（ssh-only） ==========="
chk "need_nat_v4_services 接受 ssh-only" '0' \
    "$( need_nat_v4_services 'ssh-only' >/dev/null 2>&1; printf '%s' "$?" )"
chk "need_nat_v6_services 接受 ssh-only" '0' \
    "$( need_nat_v6_services 'ssh-only' >/dev/null 2>&1; printf '%s' "$?" )"
chk "ssh-only 与 vless 混用被拒" '1' \
    "$( ( need_nat_v4_services 'ssh-only,vless' ) >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && echo 1 || echo 0 )"
chk "v6 ssh-only 与 hy2 混用被拒" '1' \
    "$( ( need_nat_v6_services 'hy2,ssh-only' ) >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && echo 1 || echo 0 )"
chk "v4 ssh-only → 两个协议都不生成节点" '0:0' \
    "$( NAT_ACTIVE=1; NAT_V4_SERVICES='ssh-only'; printf '%s:%s' \
        "$(nat_ip_needs 1.2.3.4 vless && echo 1 || echo 0)" \
        "$(nat_ip_needs 1.2.3.4 hy2 && echo 1 || echo 0)" )"
chk "v6 ssh-only → v6 IP 不生成节点" '0' \
    "$( NAT_ACTIVE=1; NAT_V6_SERVICES='ssh-only'; \
        nat_ip_needs 2001:db8::1 vless && echo 1 || echo 0 )"
chk "v4 ssh-only → 占位符 IP 也不生成节点" '0' \
    "$( NAT_ACTIVE=1; NAT_V4_SERVICES='ssh-only'; \
        nat_ip_needs '<服务器IP>' vless && echo 1 || echo 0 )"
chk "一族 ssh-only 不影响另一族" '1' \
    "$( NAT_ACTIVE=1; NAT_V4_SERVICES='ssh-only'; \
        nat_ip_needs 2001:db8::1 hy2 && echo 1 || echo 0 )"
chk "单端口仅 SSH 时给出「只够 SSH」告警与迁 SSH 建议" '1' \
    "$( collect_local_addrs() { printf '%s\n' '10.0.0.5' '2001:db8::1'; }; BIND_MAP=(); \
        CLI_SET=(); CLI_SET[SSH_PORT]=1; NAT_MODE=force; NAT_PORTS='30022'; NAT_MAP='ssh=30022'; \
        NAT_V6_PORTS=''; NAT_V6_MAP=''; NAT_V4_OPEN=0; NAT_V6_OPEN=1; \
        NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; HOP_RANGE=''; \
        VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=30022; \
        apply_nat_adaptation 2>&1 | grep -q '只够 SSH' && echo 1 || echo 0 )"

echo
echo "=========== T19 整机只做管理（MANAGE_ONLY） ==========="
chk "MANAGE_ONLY 已进 STATE_KEYS（重跑沿用）" '1' \
    "$( [[ " ${STATE_KEYS[*]} " == *' MANAGE_ONLY '* ]] && echo 1 || echo 0 )"
chk "MANAGE_ONLY_ALLOW 只放行模块 1/2/4" '1 1 0 1 0 0 0 0 0' "${MANAGE_ONLY_ALLOW[*]}"
# 关键回归：必须在当前 shell 生效，绝不能改成 "$(apply_manage_only_modules)"（子 shell 会吞掉修改）
MOD_ON=(1 1 1 1 1 1 1 1 1)
apply_manage_only_modules
chk "裁剪在当前 shell 生效（防子 shell 回归）" '1 1 0 1 0 0 0 0 0' "${MOD_ON[*]}"
chk "取消 6 个代理相关模块" '6' "$MANAGE_ONLY_DROPPED"
apply_manage_only_modules
chk "重复裁剪幂等" '1 1 0 1 0 0 0 0 0' "${MOD_ON[*]}"
chk "重复裁剪 dropped=0" '0' "$MANAGE_ONLY_DROPPED"
MOD_ON=(1 0 0 1 0 0 0 0 0)
apply_manage_only_modules
chk "--modules 1,4 不被强加管理模块" '1 0 0 1 0 0 0 0 0' "${MOD_ON[*]}"
MOD_ON=(1 1 1 1 1 1 1 1 1)
chk "管理-only 收尾与状态视图函数已定义" '1' \
    "$( declare -F manage_only_finish >/dev/null && declare -F show_manage_status >/dev/null && echo 1 || echo 0 )"
chk "MANAGE_ONLY=1 时两族 ssh-only 不再被拦" '0' \
    "$( MANAGE_ONLY=1; NAT_V4_SERVICES='ssh-only'; NAT_V6_SERVICES='ssh-only'; \
        die_if_no_proxy_family >/dev/null 2>&1; printf '%s' "$?" )"
chk "MANAGE_ONLY=0 时两族 ssh-only 仍被拦" '1' \
    "$( MANAGE_ONLY=0; NAT_V4_SERVICES='ssh-only'; NAT_V6_SERVICES='ssh-only'; \
        ( die_if_no_proxy_family ) >/dev/null 2>&1; rc=$?; [[ $rc -ne 0 ]] && echo 1 || echo 0 )"
chk "MANAGE_ONLY=1 时 NAT 适配短路（不发代理端口规则）" '1' \
    "$( MANAGE_ONLY=1; NAT_MODE=force; NAT_MAP=''; NAT_V6_MAP=''; CLI_SET=(); \
        CLI_SET[SSH_PORT]=1; SSH_PORT=22; NAT_PORTS='30022'; NAT_V6_PORTS=''; \
        apply_nat_adaptation 2>&1 | grep -q '跳过 NAT 代理端口适配' && echo 1 || echo 0 )"
chk "MANAGE_ONLY=1 时仍保住 NAT 机现有 SSH 端口" '22' \
    "$( MANAGE_ONLY=1; NAT_MODE=force; NAT_MAP=''; NAT_V6_MAP=''; CLI_SET=(); \
        SSH_PORT=51736; NAT_PORTS='30022'; NAT_V6_PORTS=''; \
        current_ssh_port() { printf '22'; }; \
        apply_nat_adaptation >/dev/null 2>&1; printf '%s' "$SSH_PORT" )"
chk "nat_port_report 对 ssh-only 族只列 SSH" '1' \
    "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=1; NAT_PORTS='30022'; NAT_V4_SERVICES='ssh-only'; \
        NAT_EXT=(); NAT_EXT6=(); VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=30022; \
        nat_port_report 2>/dev/null | grep -q '唯一需要转发的端口' && echo 1 || echo 0 )"

echo "=========== T20 分族 SSH 端口 / 机房识别 / tcpfit ==========="
chk "v4 受限 SSH 外部端口与 v6 内部端口不同" '20017/51736' \
    "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=1; parse_nat_map 'ssh=20017' >/dev/null 2>&1; \
        SSH_PORT=51736; printf '%s/%s' "$(ssh_port_for_family 4)" "$(ssh_port_for_family 6)" )"
chk "v6 受限时用 v6 自己的 SSH 外部端口" '31022' \
    "$( NAT_ACTIVE=1; NAT_V4_OPEN=1; NAT_V6_OPEN=0; parse_nat_map6 'ssh=31022' >/dev/null 2>&1; \
        SSH_PORT=51736; ssh_port_for_family 6 )"
chk "v6 全开放时防火墙只放内部 SSH 端口" '51736' \
    "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=1; parse_nat_map 'ssh=20017' >/dev/null 2>&1; \
        SSH_PORT=51736; ssh_ports_for_family 6 | tr '\n' ' ' | sed 's/ $//' )"
chk "非 NAT 时 family_state_desc 判定全开放" '端口全开放（按原配置）' \
    "$( NAT_ACTIVE=0; MANAGE_ONLY=0; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''; family_state_desc 4 )"
chk "ssh_access_report 两族同端口时只输出一行" '1' \
    "$( NAT_ACTIVE=0; MANAGE_ONLY=0; SSH_PORT=51736; NODE_IPS=(); \
        ssh_access_report | wc -l | tr -d ' ' )"
chk "ssh_access_report 明确标出只做管理的族" '1' \
    "$( NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=1; MANAGE_ONLY=0; \
        NAT_V4_SERVICES='ssh-only'; NAT_V6_SERVICES=''; parse_nat_map 'ssh=20017' >/dev/null 2>&1; \
        SSH_PORT=51736; NODE_IPS=('1.2.3.4' '2001:db8::1'); \
        _r="$(ssh_access_report)"; [[ $_r == *'该族只做管理'* ]] && echo 1 || echo 0 )"
chk "family_runs_proxy 与 MANAGE_ONLY_ALLOW 白名单一致" '1' \
    "$( MANAGE_ONLY=0; NAT_V4_SERVICES='ssh-only'; NAT_V6_SERVICES=''; \
        _v4=0; _v6=0; family_runs_proxy 4 || _v4=1; family_runs_proxy 6 || _v6=1; \
        [[ $_v4 -eq 1 && $_v6 -eq 0 ]] && echo 1 || echo 0 )"
chk "json_pick 同时兼容紧凑与带空格 JSON" 'Tokyo/Osaka' \
    "$( printf '%s/%s' "$(json_pick '{"city":"Tokyo"}' city)" \
        "$(json_pick '{ "city" : "Osaka", "region": "Osaka" }' city)" )"
chk "usable_place 拒绝 unknown / 空 / 连字符" '1' \
    "$( ! usable_place 'Unknown' && ! usable_place '' && ! usable_place '-' && usable_place '大阪' && echo 1 || echo 0 )"
chk "pick_place 退回中文 region 并去行政后缀" '大阪' \
    "$( pick_place '' '大阪府' )"
chk "VPS_INIT_SKIP_GEO=1 时 detect_location 直接失败" '1' \
    "$( VPS_INIT_SKIP_GEO=1; detect_location '1.2.3.4' >/dev/null 2>&1; printf '%s' "$?" )"
chk "LOC_ASK_ENABLED 默认 0（渲染路径不弹输入）" '0' "${LOC_ASK_ENABLED:-0}"
chk "node_prefix 在开关关闭时静默回退 hostname" '1' \
    "$( VPS_INIT_SKIP_GEO=1; NODE_NAME=''; LOC_NAME=''; LOC_DONE=0; LOC_ASK_ENABLED=0; \
        NODE_PREFIX_RESULT=''; node_prefix '1.2.3.4' >/dev/null; \
        [[ -n ${NODE_PREFIX_RESULT:-} && -z ${NODE_NAME:-} ]] && echo 1 || echo 0 )"
chk "build_node_tags 在当前 shell 取前缀（手动输入不会被子 shell 吃掉）" '1' \
    "$( declare -f build_node_tags | grep -qF 'NODE_PREFIX_RESULT' && \
        ! declare -f build_node_tags | grep -qF 'prefix="$(node_prefix' && echo 1 || echo 0 )"
chk "m_tcp 归一化旧速率写法" '1' \
    "$( declare -f m_tcp | grep -qF 'rate="${rate%%' && echo 1 || echo 0 )"
chk "m_tcp 校验 VERSION 后才安装" '1' \
    "$( declare -f m_tcp | grep -qF '无法确认版本' && echo 1 || echo 0 )"
chk "m_firewall 对只做管理族跳过代理端口" '1' \
    "$( declare -f m_firewall | grep -qF 'proxy_ok -eq 1' && echo 1 || echo 0 )"
chk "m_summary 用代理主地址而非 NODE_IPS[0]" '1' \
    "$( declare -f m_summary | grep -qF 'proxy_primary' && echo 1 || echo 0 )"
# 单跑模块 9 且无任何凭据时：m_summary 必须拒绝渲染（否则产出凭据空壳交付文件）
# 注意：die 会 exit，直接放在 $() 里会终止整个命令替换 —— 必须套两层子壳取回退出码
chk "m_summary 无凭据时拒绝渲染" '1' \
    "$( ( UUID=''; REALITY_PUB=''; SHORT_ID=''; HY2_PW=''; OBFS_PW=''; MANAGE_ONLY=0; \
          STATE_FILE='state.env'; m_summary >/dev/null 2>&1 ); echo $? )"
# doctor 的 getent 数据库名必须是 ahostsv4 / ahostsv6（ahosts4 不是合法数据库名）
chk "doctor 使用 ahostsv4/ahostsv6 数据库名" '1' \
    "$( declare -f cmd_doctor | grep -qF 'ahostsv${fam}' && echo 1 || echo 0 )"
chk "doctor 不再使用非法的 ahosts4 写法" '0' \
    "$( declare -f cmd_doctor | grep -cF 'ahosts${fam}' )"
chk "node_prefix 识别失败时交互询问并写入 NODE_NAME" '1' \
    "$( VPS_INIT_SKIP_GEO=1; NODE_NAME=''; LOC_NAME=''; LOC_DONE=0; LOC_ASK_ENABLED=1; \
        NODE_PREFIX_RESULT=''; SAVE_SEEN=''; \
        stdin_is_tty() { return 0; }; ask() { printf '香港'; }; \
        save_state() { SAVE_SEEN=${NODE_NAME:-}; return 0; }; warn() { :; }; info() { :; }; \
        node_prefix '1.2.3.4' >/dev/null; \
        [[ ${NODE_PREFIX_RESULT:-} == '香港' && ${NODE_NAME:-} == '香港' && $SAVE_SEEN == '香港' ]] && echo 1 || echo 0 )"
chk "非 TTY 时即使开关打开也不弹输入" '1' \
    "$( VPS_INIT_SKIP_GEO=1; NODE_NAME=''; LOC_NAME=''; LOC_DONE=0; LOC_ASK_ENABLED=1; \
        NODE_PREFIX_RESULT=''; \
        stdin_is_tty() { return 1; }; ask() { printf '不该被调用'; }; \
        save_state() { return 0; }; warn() { :; }; info() { :; }; \
        node_prefix '1.2.3.4' >/dev/null; \
        [[ ${NODE_PREFIX_RESULT:-} != '不该被调用' && -z ${NODE_NAME:-} ]] && echo 1 || echo 0 )"

echo "=========== T21 客户端 server 使用域名 ==========="
# 把渲染所需的全局量一次性备齐，避免依赖前面用例的残留值（unit.sh 保留 -u）。
_t21_env() {
    CLIENT_DOMAIN='node.example.com'; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''
    CLIENT_DOMAIN_FORCE_IP=0; DOMAIN=''
    NODE_IPS=('1.2.3.4' '2001:db8::1')
    VLESS_PORT=443; HY2_PORT=16407; FALLBACK_PORT=8443; SSH_PORT=51736
    UUID='11111111-2222-4333-8444-555555555555'
    REALITY_SNI='www.microsoft.com'; REALITY_PUB='PUB-KEY_123'; SHORT_ID='0123456789abcdef'
    REALITY_DEST='www.microsoft.com'; REALITY_DEST_PORT=443
    CERT_CN='bing.com'; CERT_HASH=''; HY2_PW='p+q/r=s'; OBFS_PW='o+q/r=s'
    NAT_ACTIVE=0; NAT_V4_OPEN=1; NAT_V6_OPEN=1; NAT_V4_SERVICES=''; NAT_V6_SERVICES=''
    HOP_RANGE=''; HOP_INTERVAL=''; HOP_INTERVAL_MAX=''
    TCP_KEEP_ALIVE=''; TCP_KEEP_ALIVE_INTERVAL=''; UP_MBPS=''; DOWN_MBPS=''
    MANAGE_ONLY=0; NAT_MODE='off'; NAT_PORTS=''; NAT_MAP=''; NAT_V6_PORTS=''; NAT_V6_MAP=''
    NODE_NAME='东京'; LOC_NAME='东京'; LOC_DONE=1; NODE_PREFIX='东京'; VPS_INIT_SKIP_GEO=1
}
# 交互式询问：用子 shell 函数体隔离 stub，避免污染后续断言里的真实 ask / save_state。
_t21_ask_pair() (
    ask() { case "$1" in
                'v4 节点域名') printf 'v4.example.com';;
                'v6 节点域名') printf 'v6.example.com';;
                *) printf '%s' "$2";; esac; }
    save_state() { :; }
    stdin_is_tty() { return 0; }
    ASSUME_YES=''; MODULES_ARG=''; MANAGE_ONLY=0
    CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''; CLIENT_DOMAIN_FORCE_IP=1
    ask_client_domains >/dev/null 2>&1
    printf '%s/%s/%s' "$CLIENT_DOMAIN_V4" "$CLIENT_DOMAIN_V6" "$CLIENT_DOMAIN_FORCE_IP"
)
_t21_ask_clear() (
    ask() { printf -- '-'; }
    save_state() { :; }
    stdin_is_tty() { return 0; }
    ASSUME_YES=''; MODULES_ARG=''; MANAGE_ONLY=0
    CLIENT_DOMAIN='shared.example.com'
    CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6='v6.example.com'
    ask_client_domains >/dev/null 2>&1
    printf '%s/%s/%s' "$CLIENT_DOMAIN" "$CLIENT_DOMAIN_V4" "$CLIENT_DOMAIN_V6"
)
_t21_ask_noask() (
    ask() { printf 'called.example.com'; }
    save_state() { :; }
    ASSUME_YES=1; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''
    ask_client_domains >/dev/null 2>&1
    _a="${CLIENT_DOMAIN_V4:-}-${CLIENT_DOMAIN_V6:-}"
    ASSUME_YES=''; MODULES_ARG='8'; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''
    ask_client_domains >/dev/null 2>&1
    _b="${CLIENT_DOMAIN_V4:-}-${CLIENT_DOMAIN_V6:-}"
    MODULES_ARG=''; stdin_is_tty() { return 1; }; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''
    ask_client_domains >/dev/null 2>&1
    _c="${CLIENT_DOMAIN_V4:-}-${CLIENT_DOMAIN_V6:-}"
    printf '%s:%s:%s' "$_a" "$_b" "$_c"
)
chk "交互式向导按 v4 / v6 分别询问客户端域名" 'v4.example.com/v6.example.com/0' "$(_t21_ask_pair)"
chk "交互式两族都清空时共用域名一并清掉" '//' "$(_t21_ask_clear)"
chk "交互式在 --yes / --modules / 非 TTY 下不问域名" '-:-:-' "$(_t21_ask_noask)"
chk "交互式询问函数已挂到主流程" '1' \
    "$( declare -f main | grep -qF 'ask_client_domains' && echo 1 || echo 0 )"
chk "json_vless_out 的 server 是域名而不是 IP" '1' \
    "$( _t21_env; _o="$(json_vless_out '1.2.3.4' '东京 v4-vl')"; \
        [[ $_o == *'"server": "node.example.com"'* && $_o != *'"server": "1.2.3.4"'* ]] && echo 1 || echo 0 )"
chk "json_hy2_out 的 server 是域名而不是 IP" '1' \
    "$( _t21_env; _o="$(json_hy2_out '2001:db8::1' '东京 v6-hy2')"; \
        [[ $_o == *'"server": "node.example.com"'* && $_o != *'"server": "[2001:db8::1]"'* ]] && echo 1 || echo 0 )"
chk "vless 分享链接用域名且不带方括号" '1' \
    "$( _t21_env; T_VL=('东京 v4-vl' '东京 v6-vl'); T_HY2=(); _l="$(vless_link_for 1)"; \
        [[ $_l == *'@node.example.com:443?'* && $_l != *'2001:db8::1'* && $_l != *'[node.example.com]'* ]] && echo 1 || echo 0 )"
chk "hy2 分享链接用域名且不带方括号" '1' \
    "$( _t21_env; T_HY2=('东京 v4-hy2' '东京 v6-hy2'); T_VL=(); _l="$(hy2_link_for 1)"; \
        [[ $_l == *'@node.example.com:16407/'* && $_l != *'2001:db8::1'* ]] && echo 1 || echo 0 )"
chk "v6 专属域名只改 v6 节点的 server" '1' \
    "$( _t21_env; CLIENT_DOMAIN_V6='v6.example.com'; \
        _a="$(json_vless_out '1.2.3.4' 't4')"; _b="$(json_vless_out '2001:db8::1' 't6')"; \
        [[ $_a == *'"server": "node.example.com"'* && $_b == *'"server": "v6.example.com"'* ]] && echo 1 || echo 0 )"
chk "v4 专属域名只改 v4 节点的 server" '1' \
    "$( _t21_env; CLIENT_DOMAIN_V4='v4.example.com'; \
        _a="$(json_vless_out '1.2.3.4' 't4')"; _b="$(json_vless_out '2001:db8::1' 't6')"; \
        [[ $_a == *'"server": "v4.example.com"'* && $_b == *'"server": "node.example.com"'* ]] && echo 1 || echo 0 )"
chk "v4 / v6 各给独立域名时两族 server 完全分开" '1' \
    "$( _t21_env; CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6='v6.example.com'; \
        _a="$(json_vless_out '1.2.3.4' 't4')"; _b="$(json_hy2_out '2001:db8::1' 't6')"; \
        [[ $_a == *'"server": "v4.example.com"'* && $_b == *'"server": "v6.example.com"'* \
           && $_a != *'v6.example.com'* && $_b != *'v4.example.com'* ]] && echo 1 || echo 0 )"
chk "分族域名优先于共用域名" 'v4.example.com/v6.example.com' \
    "$( _t21_env; CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6='v6.example.com'; \
        printf '%s/%s' "$(client_host_for '1.2.3.4')" "$(client_host_for '2001:db8::1')" )"
chk "分族域名模式下分享链接也按族分开" '1' \
    "$( _t21_env; CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6='v6.example.com'; \
        T_VL=('东京 v4-vl' '东京 v6-vl'); T_HY2=(); \
        _a="$(vless_link_for 0)"; _b="$(vless_link_for 1)"; \
        [[ $_a == *'@v4.example.com:'* && $_b == *'@v6.example.com:'* ]] && echo 1 || echo 0 )"
chk "client_domain_report 分开时输出两行且标注已分开" '1' \
    "$( _t21_env; CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6='v6.example.com'; \
        _r="$(client_domain_report status)"; \
        [[ $_r == *'v4.example.com'* && $_r == *'v6.example.com'* && $_r == *'已分开'* ]] && echo 1 || echo 0 )"
chk "client_domain_report 共用时提示可分开" '1' \
    "$( _t21_env; _r="$(client_domain_report status)"; \
        [[ $_r == *'两族共用'* && $_r == *'--client-domain-v4'* ]] && echo 1 || echo 0 )"
chk "--no-client-domain 仍能回到裸 IP（旧行为）" '1' \
    "$( _t21_env; CLIENT_DOMAIN=''; DOMAIN='fallback.example.com'; CLIENT_DOMAIN_FORCE_IP=1; \
        _o="$(json_vless_out '1.2.3.4' 't4')"; [[ $_o == *'"server": "1.2.3.4"'* ]] && echo 1 || echo 0 )"
chk "link_host 给 IPv6 加方括号、给域名不加" '[2001:db8::1]/node.example.com' \
    "$( printf '%s/%s' "$(link_host '2001:db8::1')" "$(link_host 'node.example.com')" )"
chk "render_client_outbounds 全量节点的 server 都是域名" '1' \
    "$( _t21_env; _j="$(render_client_outbounds)"; \
        [[ $_j == *'"server": "node.example.com"'* && $_j != *'"server": "1.2.3.4"'* \
           && $_j != *'"server": "2001:db8::1"'* ]] && echo 1 || echo 0 )"
chk "域名模式下 NAT 分族端口仍按真实 IP 取" '30443/443' \
    "$( _t21_env; NAT_ACTIVE=1; NAT_V4_OPEN=0; NAT_V6_OPEN=1; \
        parse_nat_map 'ssh=20017,vless=30443' >/dev/null 2>&1; \
        printf '%s/%s' "$(client_port_for vless '1.2.3.4')" "$(client_port_for vless '2001:db8::1')" )"
chk "四个域名键在 keep 模式被提示忽略" '1' \
    "$( declare -f warn_rerun_params_ignored | grep -qF 'CLIENT_DOMAIN_V4' && \
        declare -f warn_rerun_params_ignored | grep -qF 'CLIENT_DOMAIN_FORCE_IP' && echo 1 || echo 0 )"
chk "show_status 走分族域名报告" '1' \
    "$( declare -f show_status | grep -qF 'client_domain_report status' && echo 1 || echo 0 )"
chk "四个域名键都持久化并被 load_state 读回" 'node.example.com/v4.example.com/v6.example.com/0' \
    "$( _t21_env; CLIENT_DOMAIN_V4='v4.example.com'; CLIENT_DOMAIN_V6='v6.example.com'; \
        STATE_DIR="$SELF/state-domain-v4"; STATE_FILE="$STATE_DIR/state.env"; \
        rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; declare -A CLI_SET=(); save_state; \
        CLIENT_DOMAIN=''; CLIENT_DOMAIN_V4=''; CLIENT_DOMAIN_V6=''; CLIENT_DOMAIN_FORCE_IP=1; load_state; \
        _r="$(printf '%s/%s/%s/%s' "$CLIENT_DOMAIN" "$CLIENT_DOMAIN_V4" "$CLIENT_DOMAIN_V6" "$CLIENT_DOMAIN_FORCE_IP")"; \
        rm -rf "$STATE_DIR"; printf '%s' "$_r" )"
chk "客户端域名写入 state.env 并被 load_state 读回" 'node.example.com/v6.example.com/0' \
    "$( _t21_env; CLIENT_DOMAIN_V6='v6.example.com'; \
        STATE_DIR="$SELF/state-domain"; STATE_FILE="$STATE_DIR/state.env"; \
        rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; declare -A CLI_SET=(); save_state; \
        CLIENT_DOMAIN=''; CLIENT_DOMAIN_V6=''; CLIENT_DOMAIN_FORCE_IP=0; load_state; \
        _r="$(printf '%s/%s/%s' "$CLIENT_DOMAIN" "$CLIENT_DOMAIN_V6" "$CLIENT_DOMAIN_FORCE_IP")"; \
        rm -rf "$STATE_DIR"; printf '%s' "$_r" )"
chk "keep 模式按 state.env 恢复域名，不吃命令行新值" 'old.example.com' \
    "$( _t21_env; STATE_DIR="$SELF/state-domain-keep"; STATE_FILE="$STATE_DIR/state.env"; \
        rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; \
        printf 'CLIENT_DOMAIN="old.example.com"\nCLIENT_DOMAIN_FORCE_IP="0"\n' > "$STATE_FILE"; \
        RERUN_MODE=keep; CLIENT_DOMAIN='new.example.com'; declare -A CLI_SET=([CLIENT_DOMAIN]=1); \
        restore_client_domain_for_keep >/dev/null 2>&1; _r="$CLIENT_DOMAIN"; \
        rm -rf "$STATE_DIR"; printf '%s' "$_r" )"
chk "keep 模式按 state.env 恢复 DOMAIN 等服务端参数" 'old.example.com/10s/30s' \
    "$( _t21_env; STATE_DIR="$SELF/state-srv-keep"; STATE_FILE="$STATE_DIR/state.env"; \
        rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; \
        printf 'DOMAIN="old.example.com"\nTCP_KEEP_ALIVE="10s"\nHOP_INTERVAL_MAX="30s"\n' > "$STATE_FILE"; \
        RERUN_MODE=keep; DOMAIN='new.example.com'; TCP_KEEP_ALIVE='5s'; HOP_INTERVAL_MAX='60s'; \
        declare -A CLI_SET=([DOMAIN]=1 [TCP_KEEP_ALIVE]=1 [HOP_INTERVAL_MAX]=1); \
        restore_server_params_for_keep >/dev/null 2>&1; \
        _r="$(printf '%s/%s/%s' "$DOMAIN" "$TCP_KEEP_ALIVE" "$HOP_INTERVAL_MAX")"; \
        rm -rf "$STATE_DIR"; RERUN_MODE=''; printf '%s' "$_r" )"
chk "keep 恢复函数会清掉对应 CLI_SET 标记" '0' \
    "$( _t21_env; STATE_DIR="$SELF/state-srv-keep2"; STATE_FILE="$STATE_DIR/state.env"; \
        rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; \
        printf 'DOMAIN="old.example.com"\n' > "$STATE_FILE"; \
        RERUN_MODE=keep; DOMAIN='new.example.com'; declare -A CLI_SET=([DOMAIN]=1); \
        restore_server_params_for_keep >/dev/null 2>&1; \
        _r="$( [[ -n ${CLI_SET[DOMAIN]:-} ]] && echo 1 || echo 0 )"; \
        rm -rf "$STATE_DIR"; RERUN_MODE=''; printf '%s' "$_r" )"
chk "非 keep 模式恢复函数不动 CLI 新值" 'new.example.com' \
    "$( _t21_env; STATE_DIR="$SELF/state-srv-keep3"; STATE_FILE="$STATE_DIR/state.env"; \
        rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; \
        printf 'DOMAIN="old.example.com"\n' > "$STATE_FILE"; \
        RERUN_MODE=new; DOMAIN='new.example.com'; declare -A CLI_SET=([DOMAIN]=1); \
        restore_server_params_for_keep >/dev/null 2>&1; _r="$DOMAIN"; \
        rm -rf "$STATE_DIR"; RERUN_MODE=''; printf '%s' "$_r" )"
chk "warn_rerun_params_ignored 覆盖 DOMAIN / 保活 / 跳跃间隔键" '1' \
    "$( declare -f warn_rerun_params_ignored | grep -qF 'DOMAIN REALITY_SNI' && \
        declare -f warn_rerun_params_ignored | grep -qF 'TCP_KEEP_ALIVE' && \
        declare -f warn_rerun_params_ignored | grep -qF 'HOP_INTERVAL_MAX' && echo 1 || echo 0 )"
chk "写路径有实例互斥锁（flock）" '1' \
    "$( declare -f acquire_instance_lock | grep -qF 'flock' && \
        declare -f main | grep -qF 'acquire_instance_lock' && echo 1 || echo 0 )"
chk "doctor_port_check 不用 grep -q（防 SIGPIPE 假阴性）" '1' \
    "$( declare -f doctor_port_check | grep -qF 'grep -q' && echo 0 || echo 1 )"
chk "ask_client_domain 用 is_hostname 挡非法字符" '1' \
    "$( declare -f ask_client_domain | grep -qF 'is_hostname' && echo 1 || echo 0 )"
chk "--no-client-domain 的 FORCE_IP 也持久化" '1' \
    "$( _t21_env; CLIENT_DOMAIN=''; CLIENT_DOMAIN_V6=''; CLIENT_DOMAIN_FORCE_IP=1; \
        STATE_DIR="$SELF/state-domain"; STATE_FILE="$STATE_DIR/state.env"; \
        rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; declare -A CLI_SET=(); save_state; \
        CLIENT_DOMAIN_FORCE_IP=0; load_state; _r="$CLIENT_DOMAIN_FORCE_IP"; \
        rm -rf "$STATE_DIR"; printf '%s' "$_r" )"

# ---- T22 --rotate-secrets 定向轮换（纯函数） ----
chk "rotate 清空四项会话凭据" '4' \
    "$( UUID='u1'; SHORT_ID='s1'; HY2_PW='h1'; OBFS_PW='o1'; rotate_session_credentials; \
        printf '%s' "$( [[ -z $UUID && -z $SHORT_ID && -z $HY2_PW && -z $OBFS_PW ]] && echo 4 || echo 0 )" )"
chk "rotate 标记 CRED_ROTATED=1" '1' \
    "$( UUID='u1'; rotate_session_credentials; printf '%s' "$CRED_ROTATED" )"
chk "rotate 后 Reality 密钥保持不变" 'kept' \
    "$( REALITY_PRIV='kp'; rotate_session_credentials; printf '%s' "$( [[ $REALITY_PRIV == kp ]] && echo kept || echo lost )" )"
chk "rotate 空凭据时不误报轮换" '0' \
    "$( UUID=''; SHORT_ID=''; HY2_PW=''; OBFS_PW=''; rotate_session_credentials; printf '%s' "$CRED_ROTATED" )"

# ---- T23 --uninstall：Caddyfile 归属判定（决定回落站是否拆除） ----
# 用套件沙箱内的相对路径：Windows 上 mktemp 返回带反斜杠的路径会干扰 grep 匹配，
# 且目标平台 Debian 上 SB_DIR 恒为 /etc/sing-box 这样的 POSIX 路径。
_t23="$SELF/state-caddy"
rm -rf "$_t23"; mkdir -p "$_t23/cert"
chk "Caddyfile 不存在判为非脚本部署" '0' \
    "$( SB_DIR="$_t23"; caddyfile_is_ours "$_t23/none.conf" && echo 1 || echo 0 )"
chk "非脚本 Caddyfile（无 SB_DIR 证书引用）不拆" '0' \
    "$( SB_DIR="$_t23"; printf 'example.com {\n  file_server\n}\n' > "$_t23/user.conf"; \
        caddyfile_is_ours "$_t23/user.conf" && echo 1 || echo 0 )"
chk "引用 SB_DIR 证书的 Caddyfile 判为脚本部署" '1' \
    "$( SB_DIR="$_t23"; printf 'd:8443 {\n  tls %s/cert/fullchain.cer %s/cert/private.key\n}\n' "$_t23" "$_t23" > "$_t23/ours.conf"; \
        caddyfile_is_ours "$_t23/ours.conf" && echo 1 || echo 0 )"
chk "判定不匹配其他路径的证书引用" '0' \
    "$( SB_DIR="$_t23/other"; printf 'tls /etc/ssl/cert.pem\n' > "$_t23/foreign.conf"; \
        caddyfile_is_ours "$_t23/foreign.conf" && echo 1 || echo 0 )"
rm -rf "$_t23"

# ---- T24 端口/数值进制与清单边界（bash 算术会把 0443 当八进制 291） ----
chk "is_port 接受 1" '1' "$(is_port 1 && echo 1 || echo 0)"
chk "is_port 接受 443" '1' "$(is_port 443 && echo 1 || echo 0)"
chk "is_port 接受边界 65535" '1' "$(is_port 65535 && echo 1 || echo 0)"
chk "is_port 拒绝 0" '0' "$(is_port 0 && echo 1 || echo 0)"
chk "is_port 拒绝前导零 0443" '0' "$(is_port 0443 && echo 1 || echo 0)"
chk "is_port 拒绝越界 65536" '0' "$(is_port 65536 && echo 1 || echo 0)"
chk "need_posint 拒绝前导零 050" '1' "$( ( need_posint --up-mbps 050 ) >/dev/null 2>&1 && echo 0 || echo 1 )"
chk "need_posint 接受 50" '1' "$( need_posint --up-mbps 50 >/dev/null 2>&1 && echo 1 || echo 0 )"
chk "显式空清单不回退 v4 清单（约定：空清单直接判为包含）" '1' \
    "$( NAT_PORTS='30022,30443'; nat_ports_contains 30445 "" && echo 1 || echo 0 )"
chk "nat_ports_contains 缺省第二参数仍用 NAT_PORTS" '1' \
    "$( NAT_PORTS='30022,30443'; nat_ports_contains 30443 && echo 1 || echo 0 )"
chk "mark_cli --client-domain 不把分族域名记成命令行指定" '0' \
    "$( declare -A CLI_SET=(); mark_cli --client-domain; \
        [[ -z ${CLI_SET[CLIENT_DOMAIN_V4]:-} && -z ${CLI_SET[CLIENT_DOMAIN_V6]:-} ]] && echo 0 || echo 1 )"
chk "mark_cli --no-client-domain 仍标记三个域名键" '1' \
    "$( declare -A CLI_SET=(); mark_cli --no-client-domain; \
        [[ -n ${CLI_SET[CLIENT_DOMAIN]:-} && -n ${CLI_SET[CLIENT_DOMAIN_V4]:-} && -n ${CLI_SET[CLIENT_DOMAIN_V6]:-} ]] && echo 1 || echo 0 )"

# ---- T25 静态 lint：续行中间夹注释 ----
# 真实踩过的坑：printf 的续行里插了一行 `# 说明`，注释会就地结束整条命令，
# 后面的实参变成一个独立命令被执行（shaper 写成 1000mbit 时就是
# "1000mbit: command not found" → 退出码 127 → 模块 9 整段中止）。
# 这种错误 bash -n 查不出来，只能靠文本扫描兜住。
_SRC="$SELF/../vps-init.sh"
chk "脚本里没有夹在续行中间的注释行" '0' \
    "$( awk 'prev ~ /\\[ \t]*$/ && $0 ~ /^[ \t]*#/ {n++} {prev=$0} END{print n+0}' "$_SRC" )"
# 端口校验只能有一个入口（is_port）。内联 `[[ $X =~ ^[0-9]+$ ]] + 算术比较` 会放过
# 前导零（0443），而 bash 算术把它当八进制 291，校验值与实际写入值就对不上。
chk "SSH 端口校验统一走 is_port（无内联数字正则）" '0' \
    "$(grep -c 'SSH_PORT =~ \^\[0-9\]' "$_SRC" || true)"

echo
echo "================================================"
printf '通过 %d 项，失败 %d 项\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
