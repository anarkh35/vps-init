#!/usr/bin/env bash
# 端到端渲染回归：走真实 CLI 入口（参数解析 → 渲染），对 stdout 做 JSON 校验与字段断言。
# 只在 --print-config / --print-outbounds 两个离线路径上跑，不触碰系统。
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF/../vps-init.sh"
# 渲染回归必须可离线、可重复：不查 GeoIP（否则每次渲染都要等外网，且结果随机房漂移）
export VPS_INIT_SKIP_GEO=1
# 相对定位：被测脚本与本文件都在仓库内，换机器/换目录都不用改
PY="$(command -v python3 || command -v python || true)"
if [[ -z $PY ]]; then
    # SKIP 约定：退出码仍为 0（不算失败），但输出 RESULT: SKIP 让 all.sh 把本层
    # 记为「跳过」而不是「通过」—— 缺 python 时一行断言都没跑，绝不能报全绿
    echo "[SKIP] 未找到 python3/python，渲染回归断言未执行，不计入通过"
    echo "    替代方案：bash vps-init.sh --self-test（自带不依赖 python 的结构自检）"
    echo "RESULT: SKIP"
    exit 0
fi

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }
# expect <描述> <期望值> <实际值>
expect() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "期望=[$2] 实际=[$3]"; fi }

# run <模式> <参数...>：输出到 $OUT，退出码到 $RC
OUT=""; RC=0
run() {
    local mode="$1"; shift
    OUT="$(bash "$SCRIPT" "$mode" "$@" 2>"$SELF/render.err")"; RC=$?
}
jq_py() { # <python 表达式>，d 为已解析的 JSON
    printf '%s' "$OUT" | "$PY" -c "
import json,sys
d=json.load(sys.stdin)
print($1)
"
}
# 渲染结果是否为合法 JSON（退出码 0 且能解析）
is_json() { printf '%s' "$OUT" | "$PY" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 && echo yes || echo no; }

echo "=========== R1 服务端：单 v4 ==========="
run --print-config --ips 1.2.3.4
expect "退出码 0" '0' "$RC"
expect "输出为合法 JSON" 'yes' "$(is_json)"
expect "入站数量 2" '2' "$(jq_py 'len(d["inbounds"])')"
expect "vless 监听 ::" '::' "$(jq_py 'd["inbounds"][0]["listen"]')"
expect "hy2 监听 0.0.0.0（不写公网 v4）" '0.0.0.0' "$(jq_py 'd["inbounds"][1]["listen"]')"
expect "hy2 单实例 tag 为 hy2-in-0" 'hy2-in-0' "$(jq_py 'd["inbounds"][1]["tag"]')"

echo "=========== R1b 服务端：单 v6 / v4+v6 各一 ==========="
run --print-config --ips 2001:db8::1
expect "单 v6 → hy2 监听 ::" '::' "$(jq_py 'd["inbounds"][1]["listen"]')"
expect "单 v6 → 入站数量 2" '2' "$(jq_py 'len(d["inbounds"])')"
run --print-config --ips 1.2.3.4,2001:db8::1
expect "v4+v6 各一 → hy2 监听 ::" '::' "$(jq_py 'd["inbounds"][1]["listen"]')"

echo "=========== R2 服务端：多 v4 拆分 hy2 ==========="
run --print-config --ips 1.1.1.1,2.2.2.2
expect "入站数量 3（1 vless + 2 hy2）" '3' "$(jq_py 'len(d["inbounds"])')"
expect "hy2#1 绑定首 IP" '1.1.1.1' "$(jq_py 'd["inbounds"][1]["listen"]')"
expect "hy2#2 绑定次 IP" '2.2.2.2' "$(jq_py 'd["inbounds"][2]["listen"]')"

echo "=========== R3 服务端：--bind-all 强制单实例 ==========="
run --print-config --ips 1.1.1.1,2.2.2.2 --bind-all
expect "入站数量 2" '2' "$(jq_py 'len(d["inbounds"])')"
expect "hy2 回到 ::" '::' "$(jq_py 'd["inbounds"][1]["listen"]')"

echo "=========== R4 服务端：--ips 带方括号 IPv6 ==========="
# 单 v6 会被判定为「单实例监听 ::」，看不到具体地址；用多 v4 + 方括号 v6 逼出按 IP 拆分
run --print-config --ips "1.1.1.1,2.2.2.2,[2001:db8::1]"
expect "入站数量 4（1 vless + 3 hy2）" '4' "$(jq_py 'len(d["inbounds"])')"
expect "v6 实例已剥离方括号" '2001:db8::1' "$(jq_py 'd["inbounds"][3]["listen"]')"

echo "=========== R5 服务端：--sb-bandwidth 生成限速字段 ==========="
run --print-config --ips 1.2.3.4 --sb-bandwidth 200:500
expect "up_mbps" '200' "$(jq_py 'd["inbounds"][1]["up_mbps"]')"
expect "down_mbps" '500' "$(jq_py 'd["inbounds"][1]["down_mbps"]')"
expect "不再输出 ignore_client_bandwidth" 'absent' "$(jq_py '"absent" if "ignore_client_bandwidth" not in d["inbounds"][1] else "present"')"

echo "=========== R6 客户端：--no-hop 走单端口 ==========="
run --print-outbounds --ips 1.2.3.4 --no-hop
# 顺序已改为「先全部 vless，再全部 hy2」，所以按 tag 定位而不是按下标
expect "hy2 用 server_port" '16407' "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="hysteria2"][0]["server_port"]')"
expect "无 server_ports" 'absent' "$(jq_py '"absent" if "server_ports" not in [o for o in d["outbounds"] if o.get("type")=="hysteria2"][0] else "present"')"
expect "vless 排在 hy2 之前" 'vless' "$(jq_py 'd["outbounds"][1]["type"]')"

echo "=========== R7 客户端：方括号 IPv6 不再污染 server ==========="
run --print-outbounds --ips "1.2.3.4,[2001:db8::1]" --node-name T
expect "v6 server 无方括号" '2001:db8::1' "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-vl")][0]["server"]')"
expect "selector 默认指向首个 vless" 'T v4-vl' "$(jq_py 'd["outbounds"][0]["default"]')"

echo "=========== R8 客户端：跳跃间隔字段 ==========="
run --print-outbounds --ips 1.2.3.4
expect "server_ports 区间" "['30000:50000']" "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="hysteria2"][0]["server_ports"]')"
expect "hop_interval" '15s' "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="hysteria2"][0]["hop_interval"]')"
expect "hop_interval_max" '30s' "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="hysteria2"][0]["hop_interval_max"]')"

echo "=========== R8b 客户端：tag 编号与机房城市前缀 ==========="
run --print-outbounds --ips 1.2.3.4,5.6.7.8,2001:db8::1 --node-name "洛杉矶"
expect "同族多地址用点号序号" '洛杉矶 v4.1-vl' "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="vless"][0]["tag"]')"
expect "第二个 v4 为 .2" '洛杉矶 v4.2-vl' "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="vless"][1]["tag"]')"
expect "单 v6 不加序号" '洛杉矶 v6-vl' "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="vless"][2]["tag"]')"
expect "selector 引用先 vless 后 hy2" '洛杉矶 v4.1-vl' "$(jq_py 'd["outbounds"][0]["outbounds"][0]')"
expect "selector 最后一个是 hy2" '洛杉矶 v6-hy2' "$(jq_py 'd["outbounds"][0]["outbounds"][-1]')"
expect "selector default 指向首个 vless" '洛杉矶 v4.1-vl' "$(jq_py 'd["outbounds"][0]["default"]')"
expect "selector tag 带城市前缀" '洛杉矶 select' "$(jq_py 'd["outbounds"][0]["tag"]')"

echo "=========== R9 非法输入必须前置拦截 ==========="
run --print-config --ips 1.2.3.4 --hy2-port abc
expect "非法端口退出码非 0" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
expect "报错含「非法」" '1' "$(grep -q '非法' "$SELF/render.err" && echo 1 || echo 0)"
run --print-config --ips 1.2.3.4 --hop-range 30000-50000
expect "非法跳跃范围退出码非 0" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --hop-interval 15
expect "非法时长退出码非 0" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --up-mbps abc
expect "非法带宽退出码非 0" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"

echo "=========== R10 --ips auto 与占位回退 ==========="
run --print-outbounds --node-name T --ips auto
expect "auto 模式退出码 0" '0' "$RC"
expect "auto 模式输出合法 JSON" 'yes' "$(is_json)"

echo "=========== R11 --status 只读不崩 ==========="
OUT="$(bash "$SCRIPT" --status 2>&1)"; RC=$?
expect "--status 退出码 0" '0' "$RC"
expect "含只读标题" '1' "$(printf '%s' "$OUT" | grep -q '只读' && echo 1 || echo 0)"

echo "=========== R12 文档示例与真实渲染一致（防漂移） ==========="
# 背景：overview.md 里那份「客户端 outbounds 示例」曾经是节选 —— selector 列了 6 个 tag，
# 正文却只定义了 2 个。用户照抄进 sing-box 会直接报 outbound not found，
# 而所有测试都是对着「脚本输出」断言的，没有一条盯着「文档写的对不对」，于是漂移了两轮没人发现。
# 这里把文档示例与真实渲染对齐断言：JSON 可解析、tag 集合一致、selector 引用无悬空。
DOC="$SELF/../overview.md"
run --print-outbounds --ips 1.2.3.4,5.6.7.8,2001:db8::1 --node-name "洛杉矶"
expect "文档示例的参照场景渲染成功" '0' "$RC"
# 文档与渲染结果都从 stdin 喂给 python：
# 不传路径，既避开 Windows python 看不懂 MSYS 路径（/c/...）的坑，也不依赖调用方的工作目录。
docres="$(
    { cat "$DOC"; printf '\n<<<SPLIT>>>\n'; printf '%s' "$OUT"; } | "$PY" -c '
import json, sys, re
raw = sys.stdin.buffer.read().decode("utf-8")
doc_raw, _, real_raw = raw.partition("\n<<<SPLIT>>>\n")
m = re.findall(r"```json\n(.*?)```", doc_raw, re.S)
if not m:
    print("json=noblock"); raise SystemExit
try:
    doc = json.loads(m[0])["outbounds"]
    real = json.loads(real_raw)["outbounds"]
except Exception:
    print("json=badjson"); raise SystemExit
sd = [o for o in doc if o["type"] == "selector"][0]
sr = [o for o in real if o["type"] == "selector"][0]
defined = set(o["tag"] for o in doc)
print("json=ok")
print("nobj=%d" % len(doc))
print("tags=%s" % ("ok" if set(o["tag"] for o in doc) == set(o["tag"] for o in real) else "mismatch"))
print("selrefs=%s" % ("ok" if sd["outbounds"] == sr["outbounds"] else "mismatch"))
print("dangling=%d" % len([t for t in sd["outbounds"] if t not in defined]))
print("default=%s" % ("ok" if sd["default"] in defined else "bad"))
'
)"
dchk() { printf '%s\n' "$docres" | awk -F= -v k="$1" '$1==k{print $2}'; }
expect "文档示例是合法 JSON" 'ok' "$(dchk json)"
expect "文档示例对象数与真实渲染一致" \
    "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)["outbounds"]))')" "$(dchk nobj)"
expect "文档示例 tag 集合与真实渲染一致" 'ok' "$(dchk tags)"
expect "文档示例 selector 引用与真实渲染同序" 'ok' "$(dchk selrefs)"
expect "selector 引用的 tag 全部有定义（悬空 0 个）" '0' "$(dchk dangling)"
expect "selector default 指向已定义 tag" 'ok' "$(dchk default)"

echo
echo "=========== R13 NAT：v4 走外部端口、v6 直连走内部端口 ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat --nat-map 'vless=30443,hy2=30444,ssh=30022'
expect "退出码 0" '0' "$RC"
expect "输出为合法 JSON" 'yes' "$(is_json)"
expect "v4 vless 用外部端口 30443" '30443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-vl")][0]["server_port"]')"
expect "v6 vless 仍用内部端口 443" '443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-vl")][0]["server_port"]')"
expect "v4 hy2 用外部端口 30444" '30444' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-hy2")][0]["server_port"]')"
expect "v6 hy2 仍用内部端口 16407" '16407' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-hy2")][0]["server_port"]')"
expect "NAT 自动关闭跳跃（server_ports 消失）" 'absent' \
    "$(jq_py '"absent" if "server_ports" not in [o for o in d["outbounds"] if o.get("type")=="hysteria2"][0] else "present"')"
expect "离线渲染 stdout 无日志污染" '0' \
    "$(printf '%s' "$OUT" | grep -cE '^\[\*\]|^\[!\]' || true)"

echo
echo "=========== R14 非 NAT 对照：端口与跳跃完全不受影响 ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1
expect "v4 vless 端口=默认 443" '443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-vl")][0]["server_port"]')"
expect "v6 vless 端口=默认 443" '443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-vl")][0]["server_port"]')"
expect "hy2 仍保留 server_ports" "['30000:50000']" \
    "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="hysteria2"][0]["server_ports"]')"

echo
echo "=========== R15 NAT 内外同号：直接把外部端口传给服务端口 ==========="
run --print-outbounds --ips 1.2.3.4 --nat --vless-port 20001 --hy2-port 20002 --nat-ports 20000:20020
expect "vless 端口=20001" '20001' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="vless"][0]["server_port"]')"
expect "hy2 端口=20002" '20002' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="hysteria2"][0]["server_port"]')"
expect "跳跃已关闭" 'absent' \
    "$(jq_py '"absent" if "server_ports" not in [o for o in d["outbounds"] if o.get("type")=="hysteria2"][0] else "present"')"

echo
echo "=========== R16 --no-nat 覆盖显式映射 ==========="
run --print-outbounds --ips 1.2.3.4 --nat-map 'vless=30443' --no-nat
expect "客户端端口仍为 443" '443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="vless"][0]["server_port"]')"
expect "跳跃仍启用" "['30000:50000']" \
    "$(jq_py '[o for o in d["outbounds"] if o.get("type")=="hysteria2"][0]["server_ports"]')"

echo
echo "=========== R17 NAT 参数校验：离散端口合法、非法值拦截 ==========="
run --print-outbounds --ips 1.2.3.4 --nat-ports 20000
expect "单端口 20000 → 退出码 0" '0' "$RC"
run --print-outbounds --ips 1.2.3.4 --nat-ports 30022,30443,30444
expect "离散端口 → 退出码 0" '0' "$RC"
run --print-outbounds --ips 1.2.3.4 --nat-ports 20000:20020,30443
expect "段+单端口混合 → 退出码 0" '0' "$RC"
run --print-outbounds --ips 1.2.3.4 --nat-ports 70000
expect "越界端口 → 非 0 退出" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --nat-map 'foo=123'
expect "未知服务 → 非 0 退出" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --nat-v4-services dns
expect "未知协议 → 非 0 退出" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"

echo
echo "=========== R18 v6 全开放 + v4 少量端口：按地址族分配跳跃 ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat --nat-v6-open \
    --nat-ports 30022,30443,30444 --nat-map 'vless=30443,hy2=30444,ssh=30022'
expect "退出码 0" '0' "$RC"
expect "合法 JSON" 'yes' "$(is_json)"
expect "节点数 4" '4' "$(jq_py 'len(d["outbounds"])-1')"
expect "v4 vless 用外部端口 30443" '30443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-vl")][0]["server_port"]')"
expect "v6 vless 用内部端口 443" '443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-vl")][0]["server_port"]')"
expect "v4 hy2 用外部单端口 30444" '30444' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-hy2")][0]["server_port"]')"
expect "v4 hy2 没有 server_ports" 'absent' \
    "$(jq_py '"absent" if "server_ports" not in [o for o in d["outbounds"] if o.get("tag","").endswith("v4-hy2")][0] else "present"')"
expect "v4 hy2 没有 hop_interval" 'absent' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-hy2")][0].get("hop_interval","absent")')"
expect "v6 hy2 保留跳跃段" "['30000:50000']" \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-hy2")][0]["server_ports"]')"
expect "v6 hy2 保留 hop_interval" '15s' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-hy2")][0].get("hop_interval","absent")')"
expect "selector default 指向已定义 tag" 'True' \
    "$(jq_py 'd["outbounds"][0]["default"] in [o["tag"] for o in d["outbounds"][1:]]')"
expect "selector 列表与实际节点一致" 'True' \
    "$(jq_py 'd["outbounds"][0]["outbounds"] == [o["tag"] for o in d["outbounds"][1:]]')"
expect "离线渲染 stdout 无日志污染" '0' \
    "$(printf '%s' "$OUT" | grep -cE '^\[\*\]|^\[!\]' || true)"

echo
echo "=========== R19 v4 只有一个端口：--nat-v4-services 只留 vless ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat --nat-v6-open \
    --nat-v4-services vless --nat-ports 30022,30443 --nat-map 'vless=30443,ssh=30022'
expect "退出码 0" '0' "$RC"
expect "合法 JSON" 'yes' "$(is_json)"
expect "节点数 3" '3' "$(jq_py 'len(d["outbounds"])-1')"
expect "v4 hy2 节点已省略" '0' \
    "$(jq_py 'len([o for o in d["outbounds"] if o.get("tag","").endswith("v4-hy2")])')"
expect "v6 hy2 节点仍保留" '1' \
    "$(jq_py 'len([o for o in d["outbounds"] if o.get("tag","").endswith("v6-hy2")])')"
expect "v6 hy2 仍有跳跃段" "['30000:50000']" \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-hy2")][0]["server_ports"]')"
expect "selector 列表与实际节点一致" 'True' \
    "$(jq_py 'd["outbounds"][0]["outbounds"] == [o["tag"] for o in d["outbounds"][1:]]')"
expect "selector default 指向已定义 tag" 'True' \
    "$(jq_py 'd["outbounds"][0]["default"] in [o["tag"] for o in d["outbounds"][1:]]')"

echo
echo "=========== R20 分族参数不改变服务端入站 ==========="
run --print-config --ips 1.2.3.4,2001:db8::1 --nat --nat-v6-open \
    --nat-ports 30022,30443,30444 --nat-map 'vless=30443,hy2=30444,ssh=30022'
expect "退出码 0" '0' "$RC"
expect "合法 JSON" 'yes' "$(is_json)"
expect "hy2 入站仍单实例" '1' \
    "$(jq_py 'len([i for i in d["inbounds"] if i.get("type")=="hysteria2"])')"
expect "hy2 仍监听内部端口 16407" '16407' \
    "$(jq_py '[i for i in d["inbounds"] if i.get("type")=="hysteria2"][0]["listen_port"]')"
expect "服务端不出现 server_ports" '0' \
    "$(jq_py 'len([i for i in d["inbounds"] if "server_ports" in i])')"

echo
echo "=========== R21 纯 v4 + 仅 hy2：selector 保底不空 ==========="
run --print-outbounds --ips 1.2.3.4 --nat --nat-v4-services hy2 --nat-map 'hy2=30444'
expect "退出码 0" '0' "$RC"
expect "合法 JSON" 'yes' "$(is_json)"
expect "节点数 1" '1' "$(jq_py 'len(d["outbounds"])-1')"
expect "default 指向唯一节点" 'True' \
    "$(jq_py 'd["outbounds"][0]["default"] == d["outbounds"][1]["tag"]')"
expect "selector 列表与实际节点一致" 'True' \
    "$(jq_py 'd["outbounds"][0]["outbounds"] == [o["tag"] for o in d["outbounds"][1:]]')"

echo
echo "=========== R22 v4 全开放 + v6 受限（新组合） ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat --nat-v4-open \
    --nat-v6-ports 31443,31444 --nat-v6-map 'vless=31443,hy2=31444'
expect "退出码 0" '0' "$RC"
expect "合法 JSON" 'yes' "$(is_json)"
expect "节点数 4" '4' "$(jq_py 'len(d["outbounds"])-1')"
expect "v4 vless 按原配置用内部端口 443" '443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-vl")][0]["server_port"]')"
expect "v6 vless 用 v6 外部端口 31443" '31443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-vl")][0]["server_port"]')"
expect "v4 hy2 保留跳跃段" "['30000:50000']" \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-hy2")][0]["server_ports"]')"
expect "v6 hy2 用 v6 外部单端口 31444" '31444' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-hy2")][0]["server_port"]')"
expect "v6 hy2 无跳跃段" '0' \
    "$(jq_py 'len([o for o in d["outbounds"] if o.get("tag","").endswith("v6-hy2")][0].get("server_ports",[]))')"
expect "selector 列表与实际节点一致" 'True' \
    "$(jq_py 'd["outbounds"][0]["outbounds"] == [o["tag"] for o in d["outbounds"][1:]]')"

echo
echo "=========== R23 两族都受限，各自独立端口映射 ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat \
    --nat-ports 30443,30444 --nat-map 'vless=30443,hy2=30444' \
    --nat-v6-ports 31443,31444 --nat-v6-map 'vless=31443,hy2=31444'
expect "退出码 0" '0' "$RC"
expect "合法 JSON" 'yes' "$(is_json)"
expect "两族都受限 → 无节点使用跳跃段" '0' \
    "$(jq_py 'len([o for o in d["outbounds"] if "server_ports" in o])')"
expect "v4 vless 30443" '30443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-vl")][0]["server_port"]')"
expect "v6 vless 31443" '31443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-vl")][0]["server_port"]')"
expect "v4 hy2 30444" '30444' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-hy2")][0]["server_port"]')"
expect "v6 hy2 31444" '31444' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-hy2")][0]["server_port"]')"

echo
echo "=========== R24 两族都全开放 → 完全按原配置 ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat-v4-open --nat-v6-open
expect "退出码 0" '0' "$RC"
expect "合法 JSON" 'yes' "$(is_json)"
expect "节点数 4" '4' "$(jq_py 'len(d["outbounds"])-1')"
expect "4 个 hy2/vless 节点里 2 个 hy2 都带跳跃段" '2' \
    "$(jq_py 'len([o for o in d["outbounds"] if o.get("type")=="hysteria2" and "server_ports" in o])')"
expect "vless 全用内部端口 443" '2' \
    "$(jq_py 'len([o for o in d["outbounds"] if o.get("type")=="vless" and o.get("server_port")==443])')"

echo
echo "=========== R25 新增参数的非法值前置拦截 ==========="
run --print-outbounds --ips 1.2.3.4 --nat-v6-ports 70000
expect "v6 端口越界 → 非 0 退出" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --nat-v6-map 'foo=1'
expect "v6 映射未知服务 → 非 0 退出" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --nat-v6-services dns
expect "v6 services 非法 → 非 0 退出" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"

echo
echo "=========== R26 v4 单端口只够 SSH（ssh-only）+ v6 全开放 ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat \
    --nat-ports 30022 --nat-map 'ssh=30022' \
    --nat-v4-services ssh-only --nat-v6-open
expect "退出码 0" '0' "$RC"
expect "合法 JSON" 'yes' "$(is_json)"
expect "节点数 2（只剩 v6）" '2' "$(jq_py 'len(d["outbounds"])-1')"
expect "没有任何 v4 节点" '0' \
    "$(jq_py 'len([o for o in d["outbounds"] if o.get("type")!="selector" and "v4-" in o.get("tag","")])')"
expect "v6 vless 按原配置用 443" '443' \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-vl")][0]["server_port"]')"
expect "v6 hy2 保留跳跃段" "['30000:50000']" \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-hy2")][0]["server_ports"]')"
expect "selector default 指向 v6 vless" '1' \
    "$(jq_py '1 if d["outbounds"][0]["default"].endswith("v6-vl") else 0')"
expect "selector 列表与实际节点一致" '2' "$(jq_py 'len(d["outbounds"][0]["outbounds"])')"

echo
echo "=========== R27 v6 单端口只够 SSH + v4 全开放（对称） ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat \
    --nat-v4-open --nat-v6-services ssh-only
expect "退出码 0" '0' "$RC"
expect "节点数 2（只剩 v4）" '2' "$(jq_py 'len(d["outbounds"])-1')"
expect "没有任何 v6 节点" '0' \
    "$(jq_py 'len([o for o in d["outbounds"] if o.get("type")!="selector" and "v6" in o.get("tag","")])')"
expect "v4 hy2 保留跳跃段" "['30000:50000']" \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v4-hy2")][0]["server_ports"]')"

echo
echo "=========== R28 无解场景：绝不生成连不上的假节点 ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat \
    --nat-v4-services ssh-only --nat-v6-services ssh-only
expect "两族都 ssh-only → 非 0 退出" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
expect "报错含「没有任何地址族」" '1' \
    "$(grep -q '没有任何地址族' "$SELF/render.err" && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --nat --nat-v4-services ssh-only
expect "单 v4 且无另一族 → 非 0 退出" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --nat-v4-services 'ssh-only,vless'
expect "ssh-only 与 vless 混用被拒" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"

echo
echo "=========== R29 整机只做管理、不跑代理（MANAGE_ONLY） ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat --manage-only
expect "退出码 0" '0' "$RC"
expect "outbounds 为空（无节点、无 selector）" '0' "$(jq_py 'len(d["outbounds"])')"
expect "stderr 说明只做管理" '1' \
    "$(grep -q '只做管理、不跑代理' "$SELF/render.err" && echo 1 || echo 0)"
run --print-config --manage-only
expect "--print-config 在管理-only 下非 0 退出" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
expect "报错给出恢复命令" '1' \
    "$(grep -q -- '--no-manage-only' "$SELF/render.err" && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat --manage-only --no-manage-only
expect "--no-manage-only 恢复代理部署（CLI 后者优先）" '4' "$(jq_py 'len(d["outbounds"])-1')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat \
    --nat-v4-services ssh-only --nat-v6-services ssh-only --manage-only
expect "两族 ssh-only + --manage-only 不再 die，返回空 JSON" '0' "$(jq_py 'len(d["outbounds"])')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat \
    --nat-v4-services ssh-only --nat-v6-services ssh-only
expect "缺 --manage-only 时两族 ssh-only 仍报错（旧行为不变）" '1' \
    "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat --nat-v6-open
expect "不加 --manage-only 的正常场景不受影响" '4' "$(jq_py 'len(d["outbounds"])-1')"

echo "=========== R30 v4 只做 SSH(20017) + v6 全开放 ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat \
    --nat-ports 20017 --nat-map 'ssh=20017' --nat-v4-services ssh-only --nat-v6-open
expect "只生成 2 个代理节点" '2' "$(jq_py 'len(d["outbounds"])-1')"
expect "无任何 v4 节点" '0' \
    "$(jq_py 'len([o for o in d["outbounds"] if "v4-" in o.get("tag","")])')"
expect "selector default 指向 v6 vless" '1' \
    "$(jq_py '1 if d["outbounds"][0]["default"].endswith("v6-vl") else 0')"
expect "v6 hy2 保留跳跃段" "['30000:50000']" \
    "$(jq_py '[o for o in d["outbounds"] if o.get("tag","").endswith("v6-hy2")][0]["server_ports"]')"
run --print-config --ips 1.2.3.4,2001:db8::1 --nat \
    --nat-ports 20017 --nat-map 'ssh=20017' --nat-v4-services ssh-only --nat-v6-open
expect "服务端入站仍是 2 个单实例（未误按 v4 拆分）" '2' "$(jq_py 'len(d["inbounds"])')"

echo "=========== R31 客户端 server 使用域名 ==========="
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --client-domain node.example.com
expect "域名模式退出码 0" '0' "$RC"
expect "输出为合法 JSON" 'yes' "$(is_json)"
expect "4 个代理节点仍全量生成" '4' "$(jq_py 'len(d["outbounds"])-1')"
expect "所有节点 server 都是域名" 'True' \
    "$(jq_py 'all(o.get("server")=="node.example.com" for o in d["outbounds"][1:])')"
expect "没有任何节点 server 是裸 IP" 'True' \
    "$(jq_py 'not any(o.get("server") in ("1.2.3.4","2001:db8::1") for o in d["outbounds"][1:])')"
expect "域名不带 IPv6 方括号" 'True' \
    "$(jq_py 'not any("[" in (o.get("server") or "") for o in d["outbounds"][1:])')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --domain fallback.example.com
expect "--domain 自动回退为客户端域名" 'True' \
    "$(jq_py 'all(o.get("server")=="fallback.example.com" for o in d["outbounds"][1:])')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 \
    --domain fallback.example.com --client-domain node.example.com
expect "--client-domain 优先于 --domain" 'True' \
    "$(jq_py 'all(o.get("server")=="node.example.com" for o in d["outbounds"][1:])')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 \
    --client-domain node.example.com --client-domain-v6 v6.example.com
expect "v4 节点用主域名" 'True' \
    "$(jq_py 'all(o.get("server")=="node.example.com" for o in d["outbounds"][1:] if "v4-" in o.get("tag",""))')"
expect "v6 节点用专属域名" 'True' \
    "$(jq_py 'all(o.get("server")=="v6.example.com" for o in d["outbounds"][1:] if "v6-" in o.get("tag",""))')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 \
    --domain fallback.example.com --no-client-domain
expect "--no-client-domain 恢复裸 IP（旧行为）" 'True' \
    "$(jq_py 'sorted([o.get("server") for o in d["outbounds"][1:]])==sorted(["1.2.3.4"]*2+["2001:db8::1"]*2)')"
run --print-config --ips 1.2.3.4,2001:db8::1 --client-domain node.example.com
expect "服务端 config.json 不含客户端域名" 'False' \
    "$(jq_py '"node.example.com" in json.dumps(d)')"
expect "服务端入站仍按网卡地址监听" '2' "$(jq_py 'len(d["inbounds"])')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat \
    --nat-ports 20017 --nat-map 'ssh=20017' --nat-v4-services ssh-only --nat-v6-open \
    --client-domain node.example.com
expect "v4 只做 SSH 时域名模式仍只出 v6 节点" '2' "$(jq_py 'len(d["outbounds"])-1')"
expect "剩下的节点 server 也是域名" 'True' \
    "$(jq_py 'all(o.get("server")=="node.example.com" for o in d["outbounds"][1:])')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 \
    --domain fallback.example.com --client-domain-v6 v6.example.com
expect "只给 v6 专属域名时 v4 仍用 --domain" 'True' \
    "$(jq_py 'all(o.get("server")=="fallback.example.com" for o in d["outbounds"][1:] if "v4-" in o.get("tag",""))')"
expect "只给 v6 专属域名时 v6 用专属域名" 'True' \
    "$(jq_py 'all(o.get("server")=="v6.example.com" for o in d["outbounds"][1:] if "v6-" in o.get("tag",""))')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 \
    --domain fallback.example.com --client-domain-v6 v6.example.com --no-client-domain-v6
expect "--no-client-domain-v6 清除覆盖，两族都回 --domain" 'True' \
    "$(jq_py 'all(o.get("server")=="fallback.example.com" for o in d["outbounds"][1:])')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 \
    --client-domain-v4 v4.example.com --client-domain-v6 v6.example.com
expect "分族域名：v4 节点全用 v4 域名" 'True' \
    "$(jq_py 'all(o.get("server")=="v4.example.com" for o in d["outbounds"][1:] if "v4-" in o.get("tag",""))')"
expect "分族域名：v6 节点全用 v6 域名" 'True' \
    "$(jq_py 'all(o.get("server")=="v6.example.com" for o in d["outbounds"][1:] if "v6-" in o.get("tag",""))')"
expect "分族域名：两族 server 没有交叉" 'True' \
    "$(jq_py 'sorted(set(o.get("server") for o in d["outbounds"][1:]))==["v4.example.com","v6.example.com"]')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 \
    --client-domain shared.example.com --client-domain-v4 v4.example.com --client-domain-v6 v6.example.com
expect "同时给共用与分族域名时分族优先" 'True' \
    "$(jq_py 'sorted(set(o.get("server") for o in d["outbounds"][1:]))==["v4.example.com","v6.example.com"]')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 \
    --client-domain-v4 v4.example.com --client-domain-v6 v6.example.com --no-client-domain-v4
expect "--no-client-domain-v4 只清 v4 覆盖" 'True' \
    "$(jq_py 'all(o.get("server")=="1.2.3.4" for o in d["outbounds"][1:] if "v4-" in o.get("tag","")) and all(o.get("server")=="v6.example.com" for o in d["outbounds"][1:] if "v6-" in o.get("tag",""))')"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 \
    --client-domain shared.example.com --client-domain-v4 v4.example.com \
    --client-domain-v6 v6.example.com --no-client-domain
expect "--no-client-domain 清空全部分族域名并回 IP" 'True' \
    "$(jq_py 'sorted([o.get("server") for o in d["outbounds"][1:]])==sorted(["1.2.3.4"]*2+["2001:db8::1"]*2)')"
run --print-outbounds --ips 1.2.3.4 --client-domain-v4 1.2.3.4
expect "拒绝把 IP 当 --client-domain-v4" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4,2001:db8::1 --nat \
    --nat-ports 20017 --nat-map 'ssh=20017' --nat-v4-services ssh-only --nat-v6-open \
    --client-domain-v4 v4.example.com --client-domain-v6 v6.example.com
expect "v4 只做 SSH 时只生成 v6 节点且用 v6 域名" 'True' \
    "$(jq_py 'len(d["outbounds"])-1==2 and all(o.get("server")=="v6.example.com" for o in d["outbounds"][1:])')"
run --print-outbounds --ips 1.2.3.4 --client-domain 1.2.3.4
expect "拒绝把 IP 当 --client-domain" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --client-domain localhost
expect "拒绝无点号的裸主机名" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"

echo "=========== R32 hy2 证书指纹字段（CERT_HASH 预置） ==========="
# 背景：certificate_public_key_sha256 在 sing-box >= 1.13 是「字符串数组」，
# 曾被渲染成裸字符串 —— 客户端 unmarshal 失败拒绝整份配置，而服务端 sing-box check
# 只校验服务端 config.json、自检只验 JSON 语法，六层测试全部探不到。
# 这里用环境变量预置 CERT_HASH 端到端实例化该字段，锁死数组形态。
CERT_HASH="AbCdEf123456=" run --print-outbounds --ips 1.2.3.4
expect "预置指纹渲染退出码 0" '0' "$RC"
expect "指纹字段为字符串数组" 'list' \
    "$(jq_py 'type([o for o in d["outbounds"] if o["type"]=="hysteria2"][0]["tls"]["certificate_public_key_sha256"]).__name__')"
expect "指纹数组只有一个元素" '1' \
    "$(jq_py 'len([o for o in d["outbounds"] if o["type"]=="hysteria2"][0]["tls"]["certificate_public_key_sha256"])')"
expect "指纹值原样保留" 'AbCdEf123456=' \
    "$(jq_py '[o for o in d["outbounds"] if o["type"]=="hysteria2"][0]["tls"]["certificate_public_key_sha256"][0]')"
expect "有指纹时 insecure 为 false" 'False' \
    "$(jq_py '[o for o in d["outbounds"] if o["type"]=="hysteria2"][0]["tls"]["insecure"]')"
run --print-outbounds --ips 1.2.3.4
expect "无指纹时省略该字段" '0' \
    "$(jq_py 'len([o for o in d["outbounds"] if o["type"]=="hysteria2" and "certificate_public_key_sha256" in o.get("tls",{})])')"
expect "无指纹时 insecure 为 true" 'True' \
    "$(jq_py '[o for o in d["outbounds"] if o["type"]=="hysteria2"][0]["tls"]["insecure"]')"

echo "=========== R33 --doctor 只读体检（离线环境不崩） ==========="
# 本层跑在无 systemd / 无 ss / 无 iptables 的环境（Windows CI / 精简容器），
# 断言重点是"缺组件逐项降级为 WARN、绝不中断、永远输出汇总行"，
# 而不是各项结论 —— 结论依赖真实部署，离线渲染环境必然 FAIL/WARN 居多。
# 退出码约定：存在 [✗] 才返回 1，warn 不影响。
run --doctor --ips 1.2.3.4,2001:db8::1
DOCTOR_ALL="$OUT
$(cat "$SELF/render.err" 2>/dev/null || true)"
expect "体检退出码只为 0/1（缺组件降级不崩）" 'ok' \
    "$([[ $RC -eq 0 || $RC -eq 1 ]] && echo ok || echo bad)"
expect "输出含体检小节标题" '1' "$(printf '%s\n' "$DOCTOR_ALL" | grep -cF '[1/7]')"
expect "输出含汇总行（无论结论）" '1' "$(printf '%s\n' "$DOCTOR_ALL" | grep -cF '体检完成')"
expect "缺组件项降级为 [!] 提示而非中断" '1' \
    "$(printf '%s\n' "$DOCTOR_ALL" | grep -qF '[!]' && echo 1 || echo 0)"
expect "七个检查小节全部输出（无中途退出）" '7' \
    "$(printf '%s\n' "$DOCTOR_ALL" | grep -cE '^\[\*\] \[[1-7]/7\]')"

echo "=========== R34 --doctor --json 机器可读体检输出 ==========="
run --doctor --json --ips 1.2.3.4,2001:db8::1
expect "doctor --json 退出码仍为 0/1（缺组件降级不崩）" 'ok' \
    "$([[ $RC -eq 0 || $RC -eq 1 ]] && echo ok || echo bad)"
expect "mode 字段正确" 'proxy' "$(jq_py 'd["mode"]')"
expect "summary 三项计数齐全" '3' \
    "$(jq_py 'len([k for k in ("total","warn","fail") if k in d["summary"]])')"
expect "checks 逐项 status 合规且 name 非空" 'True' \
    "$(jq_py 'all(c["status"] in ("ok","warn","fail") and c["name"] for c in d["checks"])')"
expect "fail 计数与 summary.fail 一致" 'True' \
    "$(jq_py 'sum(1 for c in d["checks"] if c["status"]=="fail") == d["summary"]["fail"]')"

echo "=========== R35 --status --json 机器可读状态输出 ==========="
run --status --json
expect "status --json 输出合法 JSON 且 mode 正确" 'proxy' "$(jq_py 'd["mode"]')"
expect "ssh 分族端口三项齐全" '3' \
    "$(jq_py 'len([k for k in ("port","v4_external","v6_external") if k in d["ssh"]])')"
expect "nat 对象包含分族策略全字段" 'True' \
    "$(jq_py 'all(k in d["nat"] for k in ("active","mode","v4_open","v6_open","v4_ports","v4_map","v6_ports","v6_map"))')"
expect "ports 含三服务端口与跳跃段" 'True' \
    "$(jq_py 'all(k in d["ports"] for k in ("vless","hy2","fallback","hop_range"))')"
expect "services 覆盖 sing-box/caddy/fail2ban" 'True' \
    "$(jq_py 'all(s["name"] in ("sing-box","caddy","fail2ban") for s in d["services"])')"
expect "凭据只报存在性布尔、不含明文" 'True' \
    "$(jq_py 'all(v is True or v is False for v in d["credentials_present"].values())')"
# 渲染占位地址 203.0.113.10 只允许出现在离线渲染里；机器可读状态必须报真实探测结果
expect "status --json 的 ips 不含渲染占位地址" 'True' \
    "$(jq_py '"203.0.113.10" not in d["client"]["ips"]')"
# 文本模式同理：client_domain_report 曾把 family 判定用的占位地址当成客户端地址打印，
# 与同屏「公网地址」一行自相矛盾。判定用的 2001:db8::1 绝不能出现在输出里。
run --status
expect "status 文本不把占位 IPv6 当客户端地址" '0' \
    "$(printf '%s' "$OUT" | grep -c '客户端地址.*2001:db8' || true)"

echo
echo "=========== R36 端口进制与服务清单归一化 ==========="
# 前导零：bash 算术会按八进制解释，0443 曾经"校验通过"并被原样写进 JSON
# （"listen_port": 0443 是非法 JSON），必须在参数层直接拒绝。
run --print-outbounds --ips 1.2.3.4 --vless-port 0443
expect "前导零端口 0443 被拒绝" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
expect "拒绝信息明确指出端口非法" '1' \
    "$(grep -q '0443' "$SELF/render.err" && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --vless-port 65535
expect "边界端口 65535 被接受且 JSON 合法" 'yes' "$(is_json)"
run --print-outbounds --ips 1.2.3.4 --vless-port 65536
expect "越界端口 65536 被拒绝" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
run --print-outbounds --ips 1.2.3.4 --up-mbps 050
expect "前导零带宽 050 被拒绝" '1' "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
# 服务清单带空格：校验会剥离空格，存值也必须剥离，否则 hy2 节点静默消失
run --print-outbounds --ips 1.2.3.4 --nat --nat-v4-services 'vless, hy2' \
    --nat-ports 30443,30444 --nat-map 'vless=30443,hy2=30444'
_n_space="$(jq_py 'len([o for o in d["outbounds"] if "server" in o])' 2>/dev/null)"
run --print-outbounds --ips 1.2.3.4 --nat --nat-v4-services 'vless,hy2' \
    --nat-ports 30443,30444 --nat-map 'vless=30443,hy2=30444'
_n_tight="$(jq_py 'len([o for o in d["outbounds"] if "server" in o])' 2>/dev/null)"
expect "带空格服务清单与紧凑写法节点数一致" "$_n_tight" "$_n_space"
expect "带空格服务清单保留 vless + hy2 两个节点" '2' "$_n_space"

echo
echo "=========== R37 --acme-ca 取值校验 ==========="
# 拼错的 CA 名称原本要等到 DNS 记录生效、走到 acme.sh 签发那一步才报错，成本很高
run --print-outbounds --ips 1.2.3.4 --acme-ca bogus
expect "非法 --acme-ca 在参数层就被拒绝" '1' "$RC"
expect "拒绝信息指明可接受取值" '1' \
    "$(grep -c 'acme-ca 只接受' "$SELF/render.err" || true)"
run --print-outbounds --ips 1.2.3.4 --acme-ca zerossl
expect "合法 --acme-ca 正常渲染" '0' "$RC"
run --print-outbounds --ips 1.2.3.4 --acme-ca https://acme.example.com/directory
expect "ACME 自定义目录 URL 被接受" '0' "$RC"

echo
echo "=========== R38 离线渲染的私网地址 NAT 提示 ==========="
# 离线路径不做 NAT 自动判定：--ips 全是私网地址且无 --nat 参数时，
# 渲染的节点用的是内部端口、必然连不上 —— 必须在 stderr 提示，且 stdout 保持纯 JSON
run --print-outbounds --ips 10.0.0.5
expect "私网 IP 触发 NAT 提示（stderr）" '1' \
    "$(grep -c '若这是 NAT 机' "$SELF/render.err" || true)"
expect "私网 IP 时 stdout 仍是合法 JSON" 'True' \
    "$(jq_py 'isinstance(d.get("outbounds"), list)')"
run --print-outbounds --ips 1.2.3.4
expect "公网 IP 不触发 NAT 提示" '0' \
    "$(grep -c '若这是 NAT 机' "$SELF/render.err" || true)"
run --print-outbounds --ips 10.0.0.5 --nat --nat-ports 30443 --nat-map 'vless=30443'
expect "显式 --nat 时不再提示" '0' \
    "$(grep -c '若这是 NAT 机' "$SELF/render.err" || true)"

run --print-outbounds --ips 1.2.3.4 --rotate-secrets --keep-config
expect "rotate-secrets 与 keep-config 冲突被拒绝" '1' "$RC"
expect "冲突报错说明原因" '1' \
    "$(grep -c '互斥\|冲突：轮换必须' "$SELF/render.err" || true)"

echo
echo "=========== R39a doctor --json 在 NAT 激活时仍是纯 JSON ==========="
# nat_port_report 直接 printf 到 stdout：JSON 模式下必须关闭，否则机器可读输出被冲掉
run --doctor --json --ips 1.2.3.4 --nat --nat-ports 30443 --nat-map 'vless=30443'
expect "doctor --json（NAT 激活）输出仍是合法 JSON" 'True' \
    "$(jq_py 'isinstance(d.get("checks"), list) and d["summary"]["total"] > 0')"

echo
echo "=========== R39 损坏状态的 status --json 报错而非产出非法 JSON ==========="
mkdir -p "$SELF/state-bad.d"
printf 'SSH_PORT="0443"\nUUID="11111111-2222-3333-4444-555555555555"\n' > "$SELF/state-bad.d/state.env"
OUT="$(STATE_DIR="$SELF/state-bad.d" bash "$SCRIPT" --status --json 2>"$SELF/render.err")"; RC=$?
expect "前导零端口使 status --json 报错退出" '1' "$RC"
expect "报错指明非法端口设置而非抛解析错" '1' \
    "$(grep -c 'ssh-port 非法' "$SELF/render.err" || true)"
expect "stdout 不残留半截 JSON" '0' "$(printf '%s' "$OUT" | grep -c 'ssh')"
rm -rf "$SELF/state-bad.d"

echo
echo "=========== R40 --sb-bandwidth 严格两段校验 ==========="
# 三段值（200:500:100）若放行会被 %%:/##: 静默解析成 200:100，限速悄悄打折
run --print-config --ips 1.2.3.4 --sb-bandwidth 200:500:100
expect "三段带宽值被拒绝（rc=1）" '1' "$RC"
expect "报错说明只允许一个冒号" '1' \
    "$(grep -c '仅一个冒号\|上行:下行' "$SELF/render.err" || true)"
run --print-config --ips 1.2.3.4 --sb-bandwidth 200:
expect "缺下行段被拒绝（rc=1）" '1' "$RC"
run --print-config --ips 1.2.3.4 --sb-bandwidth 200:500
expect "两段合法值仍放行" '0' "$RC"
run --print-outbounds --ips 1.2.3.4 --rotate-secrets
expect "只读命令 + --rotate-secrets 给出忽略警告" '1' \
    "$(grep -c '与只读命令' "$SELF/render.err" || true)"

echo
echo "=========== R41 --tcp-bw 取值校验（此前 unit 层只有恒真伪断言） ==========="
run --print-config --ips 1.2.3.4 --tcp-bw 0
expect "tcp-bw 0 被拒绝（rc=1）" '1' "$RC"
expect "报错说明应为正整数" '1' \
    "$(grep -c '应为正整数' "$SELF/render.err" || true)"
run --print-config --ips 1.2.3.4 --tcp-bw 0100
expect "tcp-bw 前导零被拒绝（rc=1）" '1' "$RC"
run --print-config --ips 1.2.3.4 --tcp-bw 1000
expect "tcp-bw 正整数放行（rc=0）" '0' "$RC"

echo
echo "================================================"
printf '通过 %d 项，失败 %d 项\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
