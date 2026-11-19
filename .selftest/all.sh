#!/usr/bin/env bash
# 自检总入口（六层）：
#   0) vps-init.sh --self-test  内置自检 —— 语法 / 取值白名单 / JSON 转义与结构（只读，不联网）
#   1) run.sh      桩沙箱冒烟 —— 跑通全 9 个模块，捕获未定义变量与流程中断
#   2) verify.sh   定向验证   —— 状态优先级 / 防火墙规则 / 私网过滤 / apt 索引刷新 / 下载约定
#   3) unit.sh     单元测试   —— 直接 source 真实脚本（编码 / 链接 / 校验 / JSON 构造器 / 下载封装 / 状态转义）
#   4) renders.sh  渲染回归   —— 走真实 CLI 入口，对输出做 JSON 校验与字段断言
#   5) crlf.sh     CRLF 回归   —— 自愈块结构等价证明 + 检测/净化/exec 机制端到端
#
# 用法： bash .selftest/all.sh
# 前置： 无。全部落在 .selftest/ 内，不触碰真实系统路径。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

rc=0
SKIPPED=()
stage() { # stage <显示名> <命令...>
    # 退出码 0 只代表"没崩"；层内断言是否真的执行过，看输出里的 RESULT: SKIP 标记
    # （缺 python 时 renders/crlf 两层会整层跳过，必须与"通过"区分开，否则就是假绿）
    local name="$1"; shift
    echo
    echo "################ ${name} ################"
    local log; log="$(mktemp "${TMPDIR:-/tmp}/.vps-init.allstage.XXXXXX")"
    if "$@" | tee "$log"; then
        if grep -q '^RESULT: SKIP' "$log"; then
            echo "---- ${name} 跳过（缺依赖，断言未执行，不计入通过）----"
            SKIPPED+=("$name")
        else
            echo "---- ${name} 通过 ----"
        fi
    else
        echo "---- ${name} 失败 ----"; rc=1
    fi
    rm -f "$log"
}

echo "==> 语法检查"
bash -n vps-init.sh || { echo "语法错误，终止"; exit 1; }
echo "    OK"

stage "内置自检（vps-init.sh --self-test）" bash vps-init.sh --self-test
for s in run:冒烟 verify:定向 unit:单元 renders:渲染 crlf:CRLF回归; do
    f="${s%%:*}"; name="${s##*:}"
    stage "${name}测试（.selftest/${f}.sh）" bash ".selftest/${f}.sh"
done

echo
if [[ $rc -ne 0 ]]; then
    echo "======== 存在失败项，请查看上方输出 ========"
elif [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "======== 自检通过，但有 ${#SKIPPED[@]} 层跳过（断言未执行）：${SKIPPED[*]} ========"
else
    echo "======== 六层自检全部通过 ========"
fi
exit $rc
