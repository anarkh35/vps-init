#!/usr/bin/env bash
# CRLF 回归测试 —— 防止自愈块被改回「裸 then/fi」形态。
#
# 背景（务必读）：
#   CRLF 导致的 bash 报错发生在**解析阶段**，运行期代码救不了。而本地开发环境
#   （Git Bash / MSYS / Cygwin）的 bash 词法器**直接忽略 CR**，因此在本地
#   `bash crlf.sh` 永远不会复现 Debian 上的失败 —— 靠"本地跑通"下结论是假阳性。
#
# 所以本测试用两条互补的手段：
#   [A] 结构等价证明：自愈块每行要么是整行注释、要么以 # 收尾 ⇒ 行尾 CR 落在
#       注释里被忽略 ⇒ 剥注释后 CRLF 版与 LF 版逐字节相同 ⇒ 严格 Linux bash 下
#       解析结果必然一致 ⇒ 自愈块自身绝不会先崩。
#   [B] 机制端到端测试：grep 检出 CR → tr 净化 → exec 重跑 → 参数透传 → 副本自删。
#
# 用法： bash .selftest/crlf.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [[ -z "$PY" ]]; then
  # SKIP 约定：退出码仍为 0（不算失败），但输出 RESULT: SKIP 让 all.sh 把本层
  # 记为「跳过」而不是「通过」—— 缺 python 时一行断言都没跑，绝不能报全绿
  echo "[SKIP] 未找到 python，无法做字节级校验（本层断言未执行，不计入通过）"
  echo "RESULT: SKIP"
  exit 0
fi

"$PY" - <<'PYEOF'
import os, re, subprocess, sys, tempfile

ROOT = os.getcwd()
SRC = os.path.join(ROOT, "vps-init.sh")
BEGIN = b"# >>> CRLF-SELFHEAL-BEGIN"
END = b"# <<< CRLF-SELFHEAL-END"
fails = []

def check(name, cond, detail=""):
    if cond:
        print("  PASS ", name)
    else:
        print("  FAIL ", name, detail)
        fails.append(name)

with open(SRC, "rb") as f:
    lf = f.read()
check("源码本身无 CR 字节（仓库要求 LF）", lf.count(b"\r") == 0, "CR=%d" % lf.count(b"\r"))

def block(d):
    return d[d.index(BEGIN):d.index(END) + len(END)]

crlf = lf.replace(b"\n", b"\r\n")
blk_crlf = block(crlf)
body = [x for x in blk_crlf.split(b"\r\n") if x.strip()]

def safe(x):
    s = x.strip()
    return s.startswith(b"#") or s.endswith(b"#")

check("自愈块每行为整行注释或以 # 收尾（CRLF 下可解析）",
      all(safe(x) for x in body), [x for x in body if not safe(x)])

def strip_comment(line):
    i = line.find(b"#")
    return line[:i].rstrip() if i >= 0 else line.rstrip()

a = [strip_comment(x) for x in block(lf).split(b"\n") if x.strip()]
b = [strip_comment(x) for x in body]
check("剥注释后 CRLF 版 == LF 版（解析等价）", a == b)

work = tempfile.mkdtemp(prefix="crlf_")
env = dict(os.environ); env["TMPDIR"] = work
blk = block(lf)

for label, tail in (("尾部LF", b'echo "TAIL_OK arg=$1"\n'),
                    ("尾部CRLF", b'echo "TAIL_OK arg=$1"\r\n')):
    p = os.path.join(work, "c_%s.sh" % label)
    with open(p, "wb") as f:
        f.write(blk + b"\n" + tail)
    r = subprocess.run(["bash", p, "ARG_OK"], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, env=env)
    out = r.stdout.decode("utf-8", "replace")
    check("%s → 执行成功且参数透传" % label,
          "TAIL_OK arg=ARG_OK" in out and r.returncode == 0,
          "rc=%s out=%r" % (r.returncode, out[-200:]))

left = [f for f in os.listdir(work) if f.startswith(".vps-init.crlf.")]
check("净化副本执行后自删除", not left, left)

p = os.path.join(work, "real_crlf.sh")
with open(p, "wb") as f:
    f.write(crlf)
r = subprocess.run(["bash", p, "--self-test"], stdout=subprocess.PIPE,
                   stderr=subprocess.STDOUT, env=env, cwd=ROOT)
out = r.stdout.decode("utf-8", "replace")
m = re.search(r"自检结果：通过 (\d+) 项，失败 (\d+) 项", out)
check("真实脚本的 CRLF 版跑出自检全绿",
      bool(m) and m.group(2) == "0" and r.returncode == 0, out[-400:])
if m:
    print("       通过 %s 项 / 失败 %s 项" % (m.group(1), m.group(2)))

print()
print("CRLF 回归：%s" % ("全部通过" if not fails else "存在失败 %s" % fails))
sys.exit(1 if fails else 0)
PYEOF
rc=$?
if [[ $rc -eq 0 ]]; then echo "---- CRLF 回归测试 通过 ----"; else echo "---- CRLF 回归测试 失败 ----"; fi
exit $rc
