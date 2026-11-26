# VPS 开荒一键配置 · 使用教程

产物：`vps-init.sh`（纯 bash 单文件，仅依赖系统自带工具 + apt 包）

给 Debian 12/13 的新 VPS 一键完成：系统基线、SSH 加固、防火墙、fail2ban、TCP 调优、
sing-box 安装、Reality 回落站、配置生成、交付汇总。跑完直接拿到可用的客户端配置与分享链接。

---

## 功能

| # | 模块 | 做什么 |
|---|---|---|
| 1 | 系统基线 | apt 升级、设时区、**时间同步**、装基础工具、低内存自动补 1G swap、journald 限容 |
| 2 | SSH 加固 | 改端口（默认 51736）、写入公钥、禁密码登录、无公钥时**保留密码登录**防锁死、校验失败自动回滚 |
| 3 | 防火墙 | iptables/ip6tables 幂等规则 + UDP 端口跳跃 NAT、INPUT 默认 DROP、自动备份与持久化 |
| 4 | fail2ban | `jail.local`（sshd 跟随自定义端口 + recidive） |
| 5 | TCP 调优 | **只安装 tcpfit**（`/usr/local/bin/tcpfit`），不做任何自动调优；调优由你手动执行 |
| 6 | sing-box | 官方脚本安装，生成 UUID / Reality 密钥 / 证书，输出 pinSHA256 指纹；重跑选「沿用旧配置」时**本模块整段跳过** |
| 7 | Reality 回落站 | 有 `--domain` + `--cf-token`（或已有同域名证书）时：Caddy + acme.sh 签证书、8443 部署伪装站；否则**降级为公共站点握手，不装 Caddy、不部署伪装站** |
| 8 | 配置生成 | 自动探测本机 v4/v6 地址 → 生成配置 → `sing-box check` 校验 → 启动；重跑选「沿用旧配置」时**不改写 config.json** |
| 9 | 交付汇总 | 每个 IP 一条 vless:// 与 hysteria2:// 链接、**客户端 outbounds JSON**、二维码、写入 `/root/vps-init.info` |

### 关键行为

**节点名 = 机房城市**

客户端 tag 的前缀是**自动识别出的机房城市**（`洛杉矶` / `大阪` / `东京`），
而不是 hostname —— 很多机器的 hostname 是随机串或重名（`vps`、`debian`），
城市名一眼就能看出线路在哪儿。

- 识别走 GeoIP 查询三级回退：`ip-api` → `ipwho.is` → `ipapi.co`，中文城市名优先。
- **英文城市名也接受**（`Los Angeles` / `Chiyoda City`）—— 很多机房只返回英文，
  早期版本只认中文，会把这类机器误判成「识别失败」而退化成 hostname。
- 中文地名末尾的行政后缀会被去掉：`东京都` → `东京`，`大阪府` → `大阪`。
- 城市拿不到时退回省份/都道府县；三个源都失败时，**真实终端上的交互部署会询问你手动输入**
  节点名前缀，结果存入 `state.env` 供重跑沿用；非交互用 `--node-name NAME` 指定，最后才用 hostname。
  `--yes` / `--modules` / `--print-*` / `--status` / 管道输入一律不弹输入，不污染输出、不阻塞自动化。
- `--node-name NAME` 显式指定时以你给的为准，不再自动识别。
- 想关掉外网查询（例如离线渲染）：`export VPS_INIT_SKIP_GEO=1`。

**客户端 `server` 用域名，不写裸 IP；v4 / v6 可以各自独立**

客户端 outbounds、分享链接、二维码里的 `server` 字段一律优先使用域名，而不是探测到的
公网 IP：IP 会变、双栈机器上还要为每个地址复制一份配置。服务端入站监听**完全不变**，
仍按真实网卡地址 / 通配地址处理。

每个地址族独立取值，优先级：**该族专属域名 > 两族共用域名 > `--domain` > 裸 IP**。
习惯把 v4 / v6 分开，就同时给两个专属域名（推荐写法）：

```bash
bash vps-init.sh --yes \
     --client-domain-v4 v4.example.com \
     --client-domain-v6 v6.example.com
# v4 节点： "server": "v4.example.com"
# v6 节点： "server": "v6.example.com"
```

| 参数 | 客户端 `server` 的结果 |
|---|---|
| `--client-domain-v4 v4.example.com` | 只有 v4 节点用该域名（只需 A 记录） |
| `--client-domain-v6 v6.example.com` | 只有 v6 节点用该域名（只需 AAAA 记录） |
| `--client-domain node.example.com` | 两族共用的兜底域名：没给专属域名时 v4 / v6 都用它，需同时有 A / AAAA。结果存入 `state.env`，重跑沿用 |
| `--domain x.example.com` | 未给上面三者时**自动回退**到该域名（同样是两族共用） |
| `--no-client-domain-v4` / `--no-client-domain-v6` | 只清除对应族的专属域名，该族回落到共用域名 / `--domain` / IP |
| `--no-client-domain` | 关闭域名模式并清空共用域名与两个专属域名，`server` 回到旧的裸 IP 行为 |

```bash
# 只给一个域名时两族共用（兼容旧写法）
bash vps-init.sh --yes --client-domain node.example.com --domain x.example.com
# 离线看客户端配置（不写任何文件）
bash vps-init.sh --print-outbounds --client-domain-v4 v4.example.com --client-domain-v6 v6.example.com
```

摘要与 `--status` 按 v4 / v6 分别列出域名和来源：分开时标注「v4 / v6 已分开」，
共用时提示可以用两个专属域名拆开。

**交互式运行会分别询问**：直接 `bash vps-init.sh` 时，脚本在模块执行前问
「v4 节点域名」「v6 节点域名」两问，两族可各给一个；留空回退共用域名 / `--domain` / IP，
输入 `-` 清掉已存值，输入非法值会当场提示并重问。`--yes`、`--modules`、管道输入
不提问，沿用命令行参数或 `state.env` 里的值，不会阻塞自动化。

四条必须注意：

- v4 域名**只需 A 记录**、v6 域名**只需 AAAA 记录**，分别指向本机对应地址；
  共用域名则必须同时有 A / AAAA。DNS-01 签发证书只验证 TXT 记录，不代表域名指向本机；
  脚本无法替你确认这一点，摘要会给出提示。
- `--domain` 只是回退来源；`www.microsoft.com` 这类公共站点握手 SNI **永远不会**被当成
  `server`。三个 `--client-domain*` 都必须是含点号的完整域名，传 IP 或无点号的裸主机会被拒绝。
- NAT 机型若 v4 / v6 被映射到**不同端口**，只有「两族共用同一个域名」时端口才会串用
  （客户端解析到哪一族就用哪一族的端口）。给两族各配独立域名即可避免；摘要在检测到
  「共用域名 + 分族端口不同」时会明确提示。
- 分族专属域名优先于共用域名：三个参数同时给也不会被共用值盖掉；`--no-client-domain`
  会把三个域名一起清空，避免 `state.env` 里残留的旧域名在重跑时回填。

**TCP 调优只安装、不代劳**

模块 5 只做一件事：把 tcpfit 装到 `/usr/local/bin/tcpfit`。
**不会**替你执行 `tune` / `shape`，也不会问你带宽 —— 调优是你的判断，
脚本替你猜反而容易把线路调坏。装完会打印手动命令：

```bash
tcpfit                                          # 交互式菜单
tcpfit tune --role proxy --bw 500               # 基础调优（把 500 换成你的套餐 Mbps）
tcpfit shape --rate 500                        # 出向整形（纯数字，不收 500mbit）
tcpfit shape --off                             # 移除整形
tcpfit status / tcpfit rollback                # 查看状态 / 一键回滚
```

打印的是**可直接复制执行**的具体数字：早期用 `<Mbps>` 占位符，shell 会把它当成
重定向，复制即报语法错误。给了 `--tcp-bw` / `--shaper-rate` 就用你的值，
`1000mbit` 这类旧写法会归一化成 `1000`。安装时会校验下载内容是可执行 shell 脚本、
`VERSION` 可识别、`bash -n` 通过，并按版本 tag 回拉固定版本；校验失败不会覆盖
已装版本，也不会误报「已安装」。

**SSH 端口按 v4 / v6 分族（NAT 机必看）**

`--ssh-port`（默认 51736）是**容器内 sshd 监听的唯一内部端口**；v4 / v6 的
外部端口由 `--nat-map` / `--nat-v6-map` 分别指定，两族可以完全不同。
例如「v4 只给一个端口 20017 做 SSH、v6 全开放用 51736」：

```bash
bash vps-init.sh --nat --nat-v6-open \
    --nat-ports 20017 --nat-map 'ssh=20017' --nat-v4-services ssh-only
```

交付摘要会分族给出登录命令：

```text
  SSH 管理通道（按地址族区分；sshd 内部监听 51736）
    v4 : ssh -p 20017  root@<v4地址>   ← 该族只做管理
    v6 : ssh -p 51736  root@[<v6地址>]
    面板映射   : 外部端口须转到内部 51736（TCP）；防火墙已同时放行内外端口
```

- `fail2ban` / `sshd_config` / 端口监听自检始终用**内部端口**；摘要里的外部端口只用于客户端连接。
- 防火墙**按族放行**：只做管理的族只放行 SSH 内部端口 + 该族外部映射端口，
  不下发 vless / hy2 / fallback / 80 / 端口跳跃规则；全开放族照常放行。
- 面板必须把外部端口转到内部 `SSH_PORT`（TCP）。若面板是**内外同号**转发，
  请把 `--ssh-port` 设成那个外部端口，否则 sshd 没监听该端口会连不上。
- 客户端代理端口、链接、二维码都只按「实际跑代理的族」生成，不会给只做管理的 v4
  打印出不存在的 v4 代理端口。

**域名 / CF Token 与本地回落站（重要）**

`--domain` **不是必填**：留空脚本照样跑完，但会走「公共站点握手」降级路径
（`www.microsoft.com:443`），此时**不安装 Caddy、不签证书、不部署伪装站**。

- 要启用本地回落站 + 伪装站，需同时提供 `--domain` 与 `--cf-token`；缺一即回退。
- `--domain` 有 4 个来源：`--domain` 参数 > 环境变量 `DOMAIN` > 状态文件 `state.env` > 交互询问
  （`--yes` 下不会询问，必须显式传参）。模块 7 会统一校验域名合法性。
- **`CF_TOKEN` 不写状态文件**（避免 API Token 落盘）。重跑 `--modules 7` 时若 `${SB_DIR}/cert/`
  已有 CN/SAN 匹配该域名的证书，会**直接复用、不再要 Token**；否则需重新提供 `--cf-token`。
- 本地回落模式下 `REALITY_SNI` / `REALITY_DEST` / `REALITY_DEST_PORT` 由脚本按
  `<域名>:<回落端口>` 接管；手工指定的这三个参数只在**公共站点模式**生效。
- acme.sh 签发/安装失败会直接中止，并校验装回的证书 CN/SAN 是否与域名匹配
  （防止残留的旧域名证书被当成成功）。`openssl` 不可用时只告警、不中断。

**伪装站页面（内置「青山·一屏山色」）**

Reality 回落站的 8443 端口会开一个网页站点 —— **仅在本地回落模式下部署**。这个页面
**已经内嵌进脚本**（41KB 页面 → gzip+base64 约 11KB），所以哪怕你只把 `vps-init.sh`
一个文件丢到服务器上，只要给了域名，部署出来的也是一个像样的中国风站点，而不是 "It works" 裸页。

- 页面自带明暗主题切换、6 张山水壁纸轮播、诗句切换、壁纸原图保存。
- 想换成自己的页面：`--web-page /path/to/index.html`（**优先级高于内置页**）。
- 内置页解包失败（服务器缺 `gzip`/`base64`）时会自动退回 "It works" 页并照常完成部署，不会中断开荒。

> **想改内置页面**：编辑 `web/index.html`（仓库里与脚本同级的这份就是源文件），
> 然后重新压缩内嵌进脚本：
>
> ```bash
> python -c "import gzip,base64;d=open('web/index.html','rb').read();\
> print(base64.b64encode(gzip.compress(d,9)).decode())" \
> | fold -w96 > /tmp/b64.txt   # 再替换脚本里 WEBPAGE_B64_EOF 之间的内容
> ```
>
> 不想折腾压缩也行：直接 `--web-page /绝对路径/index.html` 覆盖即可。

**服务端监听地址决策**

| 场景 | hy2 入站 `listen` | vless 入站 |
|---|---|---|
| 只有单个 v4（无 v6） | `0.0.0.0`（IPv4 通配） | `::`，单实例 |
| 单 v6 / v4+v6 各一个 | `::`（双栈通配） | `::`，单实例 |
| 同族地址 ≥2 个（多 v4 / 多 v6） | **按具体 IP 逐个监听** | `::`，单实例 |

**单 IP 一律不把公网地址写进 `listen`**，只有同族出现 ≥2 个地址时才按 IP 指定。

- **vless 走 TCP**，多 IP 下监听 `::` 没有回程问题，永远只要一个入站。
- **hy2 走 UDP**，同族有 ≥2 个地址时，监听通配地址内核无法为每个目标地址选对回程源 IP，
  客户端会握手成功但随即超时 → 必须按具体 IP 逐个监听。
- 单 v4 用 `0.0.0.0` 而不是 `127.0.0.1`：外部包的目的 IP 是网卡地址，而端口跳跃 DNAT
  用 `--to-destination :${HY2_PORT}`（只改端口、保留原目的 IP），回环入站收不到包，节点会外部不可达。
- 端口跳跃的 DNAT 一条规则覆盖所有 IP。

**地址探测（v4 / v6 分族独立判定）**

- v4 与 v6 **各自**判定：先看本机 `scope global` 公网地址，没有再走出口探测，互不影响。
- 某一族网卡上只有私网地址时（典型是 NAT 机型 / 容器），会通过出口探测补上该族的公网地址 ——
  客户端连的就是这个地址。探测按族分别请求（`curl -4` / `curl -6`）并多服务回退。
- 只有**同族多地址、需要按 IP 拆分**时才会把具体地址写进 hy2 的 `listen`，且用 `bind_addr_for()`
  换成本机真实持有的那张卡（不是出口探测到的公网地址），否则 sing-box 会 `EADDRNOTAVAIL` 起不来。
- 端口跳跃依赖 `ip6tables` 的 nat 表，部分镜像不支持（只告警）。

**NAT 机型适配（共享出口 IP + 固定端口）**

脚本会**自动检测**：本机 v4 网卡上没有任何全局地址、只有私网地址（`10.x` / `172.16-31.x` /
`192.168.x` / `100.64-127.x` 等），即判定为 NAT 机型。检测只读本机网卡、不联网。误判用 `--no-nat` 关掉，
特殊机型用 `--nat` 强制。（另有一个 `BIND_MAP` 非空的兜底信号，但主流程中探测顺序决定它
实际不会触发，仅作为防御性保留；判定以「网卡只有私网地址」为准。）

**交互式向导（推荐）**：交互式运行（不带 `--yes` / `--modules`）时，脚本先弹出
「NAT 端口配置向导」。第一个问题是「是否开启端口转发映射」——**选「否」即整机只做管理、
不跑代理**（见下一节）；选「是」才进入逐族配置，把 **v4、v6 分开问**：

| 你选的 | 脚本怎么做 |
|---|---|
| 该族「不开启端口转发映射」 | **该族彻底只做管理**：不生成任何代理节点，外部端口只供 SSH 登录（等价 `--nat-v4-services ssh-only` / `--nat-v6-services ssh-only`） |
| 该族「端口全开放」 | **按原配置**：默认服务端口 + `HOP_RANGE` 端口跳跃，不套任何固定端口 |
| 该族「只开放固定端口」 | 交互式添加端口范围 / 离散端口（可多次添加），再逐个给 vless / hy2 / fallback / ssh 选外部端口；端口太少时还能只保留一个协议的节点 |

向导每项回车即用默认值（v4 依据自动检测，v6 默认全开放）；结果写入 `state.env`，重跑沿用。
重跑时默认保留已保存的配置，想改加 `--nat-wizard`，不想被问加 `--no-nat-wizard`。
`--yes` / `--modules` / `--print-*` / `--status` 一律不进向导，这些用法继续用参数表达。

### 最省事、最安全：整机「只做管理、不跑代理」

NAT 机如果不想折腾端口映射，向导检测到 NAT 时**第一个问题**就是
「是否开启端口转发映射，在这台机器上部署 sing-box 代理？」：

| 你的选择 | 脚本怎么做 |
|---|---|
| 选「是」 | 继续逐族配置 v4 / v6 端口，按原流程部署代理 |
| 选「否」 | **直接取消后续全部代理部署**，决策写入 `state.env`，重跑沿用 |

选「否」后本机只保留 **系统基线、SSH 管理通道、fail2ban**（模块 1 / 2 / 4），其余一律不下发：

- 不安装 / 不配置 sing-box：UUID、Reality 密钥、short_id、各密码、自签证书、伪装站全部不生成；
- 不生成 `config.json`，不启动 sing-box / Caddy，不生成 v4 / v6 代理节点、客户端
  `outbounds`、分享链接，也不写 `/root/vps-init.info`（避免留下明文凭据与过期链接）；
- 不下发代理端口与端口跳跃的防火墙放行 / DNAT 规则（模块 3 整个跳过，`INPUT` 策略保持现状）；
- 不安装 tcpfit（模块 5）、不跑交付汇总（模块 9）；重跑二选一也整段跳过，因为不碰任何凭据。

非交互写法：

```bash
# 等价向导里对「是否开启端口转发映射」选「否」
bash vps-init.sh --manage-only

# 恢复代理部署：覆盖 state.env 里已保存的决策，并重新进向导逐族配置
bash vps-init.sh --no-manage-only --nat-wizard
```

`--yes` / `--modules` 不进向导，这两种用法直接用参数表达；`--modules 1,2,4` 与
`--manage-only` 同时给时也只会保留 1 / 2 / 4。重跑默认沿用「只做管理」，不会又装回 sing-box。
`--print-outbounds` 在此模式下返回空的合法 JSON，`--print-config` 明确报错退出，
`--status` 只显示管理信息，不打印任何代理凭据与节点。

> 脚本**不会自动卸载或停掉**之前部署过的 sing-box / Caddy —— 可能还有客户端在用，
> 擅自停服不可逆。若确认不再需要，收尾摘要会给出 `systemctl disable --now <服务>` 命令。

**逐族也能单独关**：向导在每一族前还会问「是否为 IPv4 / IPv6 开启端口转发映射」，
选「否」即该族只做管理、不出任何代理节点（等价 `--nat-v4-services ssh-only` /
`--nat-v6-services ssh-only`），另一族照常部署。两族都选「否」时会自动升级成整机「只做管理」。

**四种组合都支持 —— 哪族全开放，哪族就用原配置：**

| v4 | v6 | 参数 |
|---|---|---|
| 全开放 | 全开放 | 不加任何 NAT 参数（或向导里两族都选「全开放」） |
| 受限 | 受限 | `--nat --nat-ports … --nat-map … --nat-v6-ports … --nat-v6-map …` |
| 受限 | 全开放 | `--nat --nat-v6-open --nat-ports … --nat-map …` |
| 全开放 | 受限 | `--nat --nat-v4-open --nat-v6-ports … --nat-v6-map …` |

**服务商分配了哪几个外部端口、某族是否全开放，都测不到** —— 容器里看不到宿主的端口转发表，
也看不到面板配置，必须由你提供。所以脚本只做几件确定不会错的事：

| 行为 | 说明 |
|---|---|
| 自动关闭端口跳跃 | 只有 **v4 与 v6 都受限** 才关闭（默认 `30000:50000` 要两万个 UDP 端口）；任一族全开放就保留，但跳跃只发给全开放族。显式给 `--hop-range` 时保留并告警 |
| 保持现有 SSH 端口 | 模块 2 不再改成 51736 —— 改成没映射的端口会**永久锁死登录**；要改就显式 `--ssh-port` 并先在面板映射。交互模式下若把端口改成别的值，会先要求确认面板已完成转发才执行；`--yes` 非交互下自动回退现有端口 |
| 打印端口清单 | 交付摘要与 `--status` **分族**列出 vless / hy2 / fallback / ssh 的内外端口，照着去面板配置转发 |
| 端口不足时少生成节点 | `--nat-v4-services` / `--nat-v6-services` 可让对应族只保留一个协议的客户端节点；`ssh-only` 让该族完全不出代理节点（单端口被 SSH 独占，见下文） |

端口怎么给，取决于服务商的映射方式：

- **同一外部端口给两个服务**：仅当面板按 TCP / UDP 分别转发时才合法
  （vless / fallback 走 TCP，hy2 走 UDP）。脚本会警告但不会拒绝；
  面板若只转发了一种协议，另一个服务必然连不上。
- **内外端口同号（端口段 1:1）**：直接把外部端口传给服务端口参数，不需要 `--nat-map`。
  ```bash
  bash vps-init.sh --nat-ports 20000:20020 \
      --vless-port 20001 --hy2-port 20002 --fallback-port 20003 --ssh-port 20004
  ```
  `--nat-ports` 只做清单校验与提示，**不会自己挑端口**（端口是固定的，脚本猜不出来）。
  端口不连续或只有一个时，直接写离散列表，例如 `--nat-ports 30022,30443`。
- **内外端口不同号（逐条转发）**：服务端仍监听内部端口，另用 `--nat-map` 告知客户端外部端口。
  ```bash
  bash vps-init.sh --nat-ports 30000:30100 --nat-map "vless=30443,hy2=30444,ssh=30022"
  ```
  客户端 v4 节点与分享链接用外部端口；服务端 `config.json`、防火墙放行的仍是内部端口。
- **v4 / v6 各用各的一套端口**：`--nat-ports` / `--nat-map` 只作用于 v4 受限族，
  `--nat-v6-ports` / `--nat-v6-map` 只作用于 v6 受限族；脚本不会把一族的映射套到另一族。
  v6 若是独立公网、端口全开放，用 `--nat-v6-open` 直接按原配置跑。
- 服务端 `listen` 不受影响，仍是通配 / 本机地址（见上表）；对外地址由 `BIND_MAP`
  换成本机落地地址，沿用既有逻辑。

**双栈能力不对等：v6 端口全开放，v4 只有 1 个或少量端口**

这类机器很常见：v6 是独立公网地址、不经宿主转发，端口随便用；v4 走共享出口，
面板只给一个端口或几个离散端口。**服务商怎么分配端口、v6 是否也受限，脚本都测不到**，
所以用 `--nat-v6-open` 显式声明，脚本不猜、也不会替你验证这个声明。

```bash
# v6 全开放 + v4 少量离散端口（vless / hy2 / SSH 各一个）
bash vps-init.sh --nat --nat-v6-open \
    --nat-ports 30022,30443,30444 \
    --nat-map "vless=30443,hy2=30444,ssh=30022"

# v4 只有一个端口：只给 v4 保留 vless 节点，hy2 只出 v6 节点
bash vps-init.sh --nat --nat-v6-open --nat-v4-services vless \
    --nat-ports 30022,30443 --nat-map "vless=30443,ssh=30022"
```

开启后的分族规则：

| 地址族 | vless 端口 | hy2 端口 | 端口跳跃 |
|---|---|---|---|
| v4（受限） | `--nat-map` 的外部端口 | `--nat-map` 的外部端口，单端口 | **不启用**，不会把两万个没转发的端口写给客户端 |
| v6（直连全开放） | 服务端 `VLESS_PORT` | 服务端 `HY2_PORT` + `server_ports` 跳跃段 | 保留 `HOP_RANGE`，分享链接带 `mport` |

反过来也支持 —— **v4 全开放、v6 只给少量端口**（少见，但有些机型 IPv6 也走宿主转发）：

```bash
bash vps-init.sh --nat --nat-v4-open \
    --nat-v6-ports 31443,31444,31022 \
    --nat-v6-map "vless=31443,hy2=31444,ssh=31022"
```

此时 v4 节点按原配置（内部端口 + 跳跃段），v6 节点走自己的外部端口、不跳跃；
防火墙的跳跃段放行与 DNAT 只下到 `iptables`（v4 侧）。

- 服务端仍只有一个 hy2 入站监听 `HY2_PORT`：v6 跳跃段由容器内 `ip6tables` DNAT 重定向到它，
  v4 外部端口由宿主转发到它，两者互不冲突。
- 跳跃段的 `INPUT` 放行与 DNAT **只下到 ip6tables**，v4 那套 iptables 不会多出两万条端口范围。
  如果镜像裁剪了 IPv6 NAT（脚本会告警），v6 跳跃也无效，请加 `--no-hop` 退回单端口。
- 本机防火墙仍按既有安全策略把 `INPUT` 设为 DROP，只放行服务端口与 v6 跳跃段 ——
  「v6 全开放」指服务商不限制，不代表脚本会把本机所有端口敞开。
- `--nat-v4-services` 只影响**客户端节点与分享链接**，服务端入站、凭据、配置文件都不变；
  selector 的 `default` 会自动指向第一个实际生成的节点。

**极端情况：某一族只有一个端口，且被 SSH 独占**

先说物理约束：SSH 与 vless 都是 TCP，**同一个外部 TCP 端口不能同时转给两者**；hy2 走 UDP，
只有当面板允许「同一外部端口分别建 TCP 一条 + UDP 一条」时才可能挤进去，多数 NAT 面板一个
外部端口只建一条规则，不能指望。Reality 的回落只处理 TLS 握手，不会把 SSH 明文流量转给 sshd。
所以这族默认没有任何端口能承载代理。

脚本在这类输入下会明确告警「该族目前只够 SSH 用」并给出推荐；**不会**再下发注定连不上的
v4 / v6 节点、更不会把 selector 的 `default` 指向它。按推荐度排：

1. **把 SSH 迁到另一地址族**（另一族全开放时最优）。v6 是独立公网、端口全开放，把 sshd 与
   日常登录切到 v6 地址，v4 唯一端口让给 vless（TCP），v6 承担 hy2 + 端口跳跃：

   ```bash
   bash vps-init.sh --nat --nat-v6-open \
       --nat-ports 30443 --nat-map "vless=30443" \
       --nat-v4-services vless
   ```

   面板把外部 `30443` 转到容器内 `443`。先验证 `ssh -6` 能登录再改 v4 映射；SSH 端口本身
   不要动 —— NAT 机型上脚本会保持现有 sshd 端口不改，改成没映射的端口会锁死登录。

2. **该族彻底只做管理、不跑代理**（最省事、最安全）。用新增的 `ssh-only` 取值，该族不生成
   任何代理节点，全部流量走另一族：

   ```bash
   bash vps-init.sh --nat --nat-v6-open \
       --nat-ports 30022 --nat-map "ssh=30022" \
       --nat-v4-services ssh-only
   ```

   v6 反过来同理：`--nat-v6-services ssh-only`。selector 只引用另一族节点，`default` 自动
   指向该族第一个实际生成的节点。`ssh-only` 不能与 `vless` / `hy2` 混用。

3. **两族都只有一个端口且都被 SSH 占，或整机只有单族单端口**：物理上无解，必须让服务商
   增加外部端口。脚本此时直接报错退出（不产出无效配置），错误信息里写明推荐路径。唯一技术
   旁路是用 sslh / HAProxy 在单 TCP 端口按协议分流 SSH 与 TLS，但 SSH 是唯一生命线，
   复用器配置错就永久失联 —— 除非有带外 VNC / 控制台可救援，否则不要这么做，脚本也不代做。

**SSH 配置写在哪**

改的正是 `/etc/ssh/sshd_config`，但用 Debian 标准的 **drop-in** 方式：

| 文件 | 脚本做了什么 |
|---|---|
| `/etc/ssh/sshd_config` | 备份到 `/root/.vps-init.sshd_config.<时间戳>.bak`（时间戳备份自动轮转，只保留最近 5 份）；首行插入 `Include /etc/ssh/sshd_config.d/*.conf`；把冲突指令注释掉并标 `# vps-init` |
| `/etc/ssh/sshd_config.d/00-vps-init.conf` | 新建，写入 `Port`、`PermitRootLogin prohibit-password`、`PasswordAuthentication` 等加固项 |

> **为什么要绕**：sshd 对同一指令**以首次出现为准**。若主配置里留着未注释的 `Port 22`，
> 它会先被读到并覆盖 drop-in 里的 `Port 51736` —— 现象是"脚本说改好了，实际还是 22 端口"。
> 改完立刻 `sshd -t` 校验，**失败会连同 drop-in 一起回滚**。

**容器 / LXC 兼容性**

缺 `CAP_SYS_TIME` 时内核 NTP 不可用，脚本自动降级为 `ntpdate` 一次性校时 + 每日校时任务；
`journald` 限容、fail2ban 等也可能不生效 —— 遇到这些只**告警不中断**，不会让整轮开荒失败。

**重跑脚本（第二次及以后）—— 必须二选一**

检测到已有部署（存在 `config.json`，或有 `state.env` + 有效凭据）且本次会触及模块 6/8 时，
脚本会在**任何模块执行之前**要求你明确选择一次：

```text
  1) 沿用旧配置  —— 完整保留现有 config.json、UUID、Reality 密钥、各密码、
                     Hysteria2 自签证书与交付文件：不覆盖、不改动、不重启服务；
                     已下发的客户端继续可用
  2) 生成新配置  —— 每次都重新生成一整套新的 UUID / Reality 密钥 / short_id /
                     各密码 / 自签证书与 pinSHA256，并更新 config.json 与交付文件；
                     不复用固定值或上次生成结果；旧客户端全部作废
```

| 输入方式 | 沿用旧配置 | 生成新配置 |
|---|---|---|
| 交互 | `1` / `keep` / 直接回车 | `2` / `new` / `regen` |
| 命令行开关 | `--keep-config` | `--new-config` |
| 带值写法 | `--config-mode keep` | `--config-mode new` |
| 环境变量 | `RERUN_MODE=keep` | `RERUN_MODE=new` |

- **未明确选择时绝不自动覆盖**：交互时回车、输入不可用（EOF）一律默认 `1`；
  `--yes` 非交互且没给任何模式参数时，也默认「沿用旧配置」并打印醒目告警。
  输入非法值（如 `3`）会循环提示，不会当成某个选项；两个开关同时给会直接报错退出。
- 模式**不写进 `state.env`**：每次重跑都必须重新表态，不会被上次的选择「自动续期」。
- 首次部署（既无 `config.json` 也无状态文件）没有旧配置可沿用，无论传什么都按「生成新配置」处理，开荒流程照常完成。
- **旧配置兼容性**：只要 `config.json` 存在，即使 `state.env` 被手工改坏（UUID 为空、旧版本缺键），
  也一律按「已有部署」处理 —— 未表态时绝不覆盖它。此时会提示凭据不完整，要重建请显式选「生成新配置」。
- 本次不含模块 6/8（如 `--modules 7`、`--modules 3`）时没有会覆盖配置的动作，不弹选择，
  直接按「沿用旧配置」处理。
- 选了「沿用旧配置」却又传了 `--ips` / `--vless-port` 等影响 `config.json` 的参数时，
  脚本会明确告警这些参数**不会写入配置**，并按 `state.env` 现值恢复（含 `--domain` /
  `--reality-*` / `--tcp-keep-alive*` / `--hop-interval*` / 端口三件套 `--vless-port` /
  `--hy2-port` / `--fallback-port` / `--hop-range`：否则模块 3 会按新端口下发防火墙、
  模块 7 会用新域名重写 Caddyfile、模块 9 会把线上不存在的参数打到终端，造出三方不一致）；
  要生效请改选「生成新配置」。
- **例外：NAT 参数不在恢复链里**。keep 时携带 `--nat-*` 系列参数仍会实时生效
  （模块 3 按新映射下发防火墙规则）并写入 `state.env`，脚本会单独告警这一点；
  要让部署按旧参数原样保留，请不要在 keep 时携带 NAT 参数，或直接改选「生成新配置」。
- keep 恢复按 `state.env` 实际存在的键执行：旧版本状态文件缺键时保留命令行值不动
  （不会把参数清成空串），并照常打印恢复告警。
- 选了「生成新配置」但没包含模块 6（如 `--modules 8,9`），会告警「只重渲染配置、不轮换凭据」。
- **实例互斥**：写路径（部署 / `--rotate-secrets` / `--uninstall`）运行期间会在
  `~/.vps-init/.instance.lock` 上加 `flock` 独占锁，第二个实例会直接拒绝启动；
  只读命令（`--status` / `--doctor` / `--print-*`）不取锁。
- **状态目录**：`state.env` 与锁文件默认在 `/root/.vps-init/`，可用环境变量
  `STATE_DIR` 整体改到别的目录（主要给测试 / 多实例隔离用，普通部署无需关心）；
  下载缓存固定在 `/var/cache/vps-init/`，不受 `STATE_DIR` 影响。

**两种模式的实际行为**

| 项目 | 沿用旧配置 | 生成新配置 |
|---|---|---|
| `/etc/sing-box/config.json` | 一个字节都不动；不备份、不写 `.new`、不 `mv`、不重启服务 | 时间戳备份 → 写 `.new` → `sing-box check` → 原子替换 → 重启 |
| UUID / Reality 密钥 / short_id / 各密码 | 原样保留，模块 6 整段跳过 | 每次全换新；`--uuid` 固定值也被忽略，避免复用固定值 |
| Hysteria2 自签证书 / pinSHA256 | 原样保留 | 每次重新签发 |
| `state.env`、`vps-init.info`、`client-outbounds.json` | 凭据字段不改写，交付文件不重写 | 随新凭据重写，**必须重新导入客户端** |
| Caddyfile / 伪装站 `index.html` | 按所选模块照常维护 | 同左 |
| 回落站 acme.sh TLS 证书 | 复用（无需再给 `--cf-token`） | 同左 |

其余与既有行为一致：端口/域名/带宽等参数沿用 `state.env`（优先级「命令行 > state.env > 默认值」）；
`--cf-token` 不落状态文件；从「本地回落」改走「公共站点握手」时会自动清掉 `127.0.0.1:8443` 残留；
自定义公共站点目标不会被重置；生成新配置时旧 `config.json` 备份**自动轮转，只保留最近 5 份**。

---

## 如何使用

### 一键部署（仓库公开版）

新机器上直接拉取执行：

```bash
# 推荐写法：先落盘再执行（文件保留在机器上，便于复查与重跑；stdin 保留 TTY，交互式向导可用）
curl -fsSL https://raw.githubusercontent.com/anarkh35/vps-init/master/vps-init.sh -o vps-init.sh \
  && bash vps-init.sh

# 进程替换写法：不落盘、直接执行
bash <(curl -fsSL https://raw.githubusercontent.com/anarkh35/vps-init/master/vps-init.sh)

# 带参数全自动（注意：--cf-token 等敏感值会留在 shell history，私有环境请用环境变量传入）
curl -fsSL https://raw.githubusercontent.com/anarkh35/vps-init/master/vps-init.sh -o vps-init.sh \
  && bash vps-init.sh --yes --ssh-port 51736 --pubkey "ssh-ed25519 AAAA..." \
     --domain x.example.com --cf-token cfat_xxx
```

注意：

- **纯管道 `curl … | bash` 没有 TTY**：交互式向导、重跑二选一会自动跳过，参数必须写全；
  NAT 机务必带 `--nat --nat-ports … --nat-map …`（或直接 `--manage-only`），否则分族端口配置缺失。
- **来源完整性校验**：`master` 分支会随迭代更新，静态指纹会过期；要锁定版本请用
  **提交哈希固定的 raw 地址**（内容不可变，指纹校验才有意义）：

  ```bash
  # 把 <commit> 换成 GitHub 页面上的提交哈希（仓库首页右上角 commits 历史）
  curl -fsSL https://raw.githubusercontent.com/anarkh35/vps-init/<commit>/vps-init.sh -o vps-init.sh
  sha256sum vps-init.sh
  # 再到该提交的 GitHub 页面点击 vps-init.sh 的「View raw」对照，或本地
  # git clone 后 sha256sum 同提交的文件比对
  ```

```bash
# 1) 交互式菜单（推荐首次使用）
bash vps-init.sh

# 1b) NAT 机只做管理、不跑代理：向导首问「是否开启端口转发映射」选「否」，
#     或非交互直接一条命令（结果存入 state.env，重跑沿用）
bash vps-init.sh --manage-only

# 2) 全自动
bash vps-init.sh --yes --ssh-port 51736 --pubkey "ssh-ed25519 AAAA..." \
     --domain x.example.com --cf-token cfat_xxx \
     --client-domain-v4 v4.example.com --client-domain-v6 v6.example.com \
     --tcp-bw 1000

# 3) 重跑：交互式会先让你二选一；非交互必须显式指定
bash vps-init.sh --yes --keep-config   # 沿用旧配置：config.json 与密码/密钥一律不动
bash vps-init.sh --yes --new-config    # 生成新配置：全套凭据换新并更新配置（旧客户端作废）
bash vps-init.sh --yes                 # 未指定 → 安全默认「沿用旧配置」，绝不自动覆盖

# 4) 只重跑某几个模块
bash vps-init.sh --modules 3                     # 只重跑防火墙（不会弹二选一）
bash vps-init.sh --modules 8,9 --new-config     # 换 IP 后重生成配置与汇总

# 5) 只读查看当前状态
bash vps-init.sh --status

# 6) 本地预览配置（不改服务器、零依赖）
bash vps-init.sh --print-config       # 服务端 sing-box 配置
bash vps-init.sh --print-outbounds    # 客户端 outbounds
```

### 常用参数

| 参数 | 说明 |
|---|---|
| `--ssh-port N` | **容器内 sshd 监听的内部端口**（默认 51736）。v4 / v6 外部端口另由 `--nat-map` / `--nat-v6-map` 指定，摘要会分族列出 |
| `--pubkey STR` / `--pubkey-file PATH` / `--pubkey-url URL` | 公钥内容 / 从文件读 / 从 URL 拉取 |
| `--domain DOMAIN` | Reality 回落域名。**留空则回退公共站点握手**（不部署伪装站）；本地回落需配合 `--cf-token`。同时是客户端 `server` 的默认域名回退来源，需确认 DNS 指向本机 |
| `--client-domain HOST` / `--no-client-domain` | 两族**共用**的客户端 `server` 域名（优先于 `--domain`，结果存入 `state.env`）/ 显式回到裸 IP 并清空分族域名 |
| `--client-domain-v4 HOST` / `--no-client-domain-v4` | 只给 v4 节点用的独立域名（优先于共用域名）/ 清除该覆盖 |
| `--client-domain-v6 HOST` / `--no-client-domain-v6` | 只给 v6 节点用的独立域名（共用域名只有 A 记录时必备）/ 清除该覆盖 |
| `--cf-token TOKEN` | Cloudflare API Token（DNS-01 签发证书）。**不写状态文件**；重跑若已有同域名证书则无需再给 |
| `--acme-email MAIL` / `--acme-ca NAME` | acme.sh 注册邮箱（默认 `admin@<domain>`）/ CA（默认 letsencrypt；可选 letsencrypt_test / zerossl / buypass / buypass_test / google / googletest / sslcom，或 CA 的 http(s) 地址，原样传给 acme.sh --server） |
| `--reality-sni HOST` | 公共站点握手 SNI（默认 `www.microsoft.com`；本地回落时自动用 `--domain`） |
| `--reality-dest HOST` | 公共站点握手目标（默认 `www.microsoft.com`；本地回落时自动用 `127.0.0.1`） |
| `--reality-dest-port N` | 公共站点握手端口（默认 443；本地回落时自动用 `--fallback-port`） |
| `--cert-cn HOST` | Hysteria2 自签证书 CN / 客户端 `server_name`（默认 `bing.com`） |
| `--uuid UUID` | 固定 UUID，**仅首次部署生效**。重跑选「沿用旧配置」时忽略（避免状态文件与 `config.json` 用两套凭据），选「生成新配置」时也忽略（不复用固定值） |
| `--vless-port N` / `--hy2-port N` / `--fallback-port N` | 端口（默认 443 / 16407 / 8443） |
| `--keep-config` | 重跑二选一之**沿用旧配置**：完整保留 `config.json` 与全部密码/密钥/证书，不覆盖、不改动、不重启服务 |
| `--new-config` | 重跑二选一之**生成新配置**：每次重新生成全套凭据并更新 `config.json`，旧客户端全部作废 |
| `--config-mode keep\|new` | 上面两个开关的带值写法；非法值直接报错退出。也可用环境变量 `RERUN_MODE=keep\|new` |
| `--modules LIST` | 只执行指定模块，如 `1,2,3` |
| `--yes`（短写 `-y`） | 非交互，全部模块按默认值执行。**重跑时未指定模式一律按「沿用旧配置」处理**，绝不自动覆盖 |
| `--ips LIST` | 手动指定 IP（逗号分隔），留空自动探测；写 `auto` 强制重新探测。离线渲染（`--print-outbounds`）不做 NAT 自动判定：给的 IP 全是私网地址且未带 `--nat` 参数时会在 stderr 提示（NAT 机请带 `--nat --nat-ports … --nat-map …`，否则节点用的是内部端口、连不上） |
| `--node-name NAME` | 客户端 tag 前缀；留空则**自动识别机房城市**（如 `洛杉矶` → `洛杉矶 v4-vl`）。识别失败时真实终端上的交互部署会询问手动输入，结果存入 `state.env`；非交互用本参数指定 |
| `--web-page PATH` | 自定义伪装站 `index.html`；留空则用内置的「青山·一屏山色」页面 |
| `--tcp-bw N` | 本机带宽（Mbps）。脚本不自动调优，此值只用于在模块 5 打印可直接复制的 `tcpfit tune --role proxy --bw N` 命令；不给则打印示例值 500 |
| `--shaper-rate RATE` | 出向整形速率（Mbps 数字，如 `1000`）。只用于打印 `tcpfit shape --rate N`，不会自动执行；旧写法 `1000mbit` 仍兼容，打印时归一化为 `1000` |
| `--bind-all` | 强制 hy2 统一监听 `::`、不按 IP 拆分（显式指定时优先于单 v4 的 `0.0.0.0`） |
| `--no-hop` | 关闭端口跳跃，客户端用单端口。**v4 与 v6 都受限**的 NAT 机自动执行这一项 |
| `--nat` / `--no-nat` | 强制开启 / 关闭 NAT 适配（默认自动检测） |
| `--manage-only` / `--no-manage-only` | 整机**只做管理、不跑代理**：取消 sing-box 与全部凭据/证书/伪装站、v4 / v6 节点与客户端配置、代理端口与跳跃段的防火墙规则，只保留系统基线、SSH、fail2ban。等价向导里对「是否开启端口转发映射」选「否」；结果写入 `state.env`，重跑沿用；`--no-manage-only` 恢复 |
| `--nat-wizard` / `--no-nat-wizard` | 交互运行时强制进入 / 跳过「NAT 端口配置向导」；`--yes` / `--modules` / 离线渲染不进入。向导首问「是否开启端口转发映射」，选否即整机只做管理；逐族还可单独关闭某一族 |
| `--nat-ports LIST` | **v4 受限族**的固定外部端口，只做校验与提示。支持单端口 / 离散 / 连续段混用：`30443`、`30022,30443,30444`、`20000:20020`、`20000:20020,30443` |
| `--nat-map SPEC` | **v4 受限族**的外部端口映射，如 `"vless=30443,hy2=30444,ssh=30022"`；内外同号时不用给 |
| `--nat-v4-open` / `--no-nat-v4-open` | 声明 **v4 端口全开放** → 按原配置（默认端口 + 跳跃）/ 受限（默认） |
| `--nat-v6-open` / `--no-nat-v6-open` | 声明 **v6 端口全开放** → 按原配置 / 受限（默认）；全开放族的跳跃段只发给该族 |
| `--nat-v6-ports LIST` | **v6 受限族**的固定外部端口清单，格式同 `--nat-ports` |
| `--nat-v6-map SPEC` | **v6 受限族**的外部端口映射，格式同 `--nat-map` |
| `--nat-v4-services LIST` / `--nat-v6-services LIST` | 对应族端口不足时只生成指定协议的节点：`vless` / `hy2` / `vless,hy2`；`ssh-only` = 该族唯一端口被 SSH 占用、**不生成任何代理节点**；留空 = 全部生成。`ssh-only` 不能与协议名混用 |
| `--up-mbps` / `--down-mbps` | 客户端 hy2 带宽（默认 50 / 200） |
| `--hop-interval D` | 端口跳跃间隔（默认 `15s`），上文示例配置里的 `hop_interval` 就是它 |
| `--hop-interval-max D` | 跳跃间隔上限、区间内随机化（默认 `30s`，需客户端 sing-box ≥ 1.14.0） |
| `--hop-range LO:HI` | 自定义 UDP 跳跃端口区间（默认 `30000:50000`；NAT 机改用 `--nat-ports` / `--nat-v6-ports` 指定固定端口） |
| `--tcp-keep-alive D` / `--tcp-keep-alive-int D` | 客户端 TCP 保活时长与探测间隔（默认 `2m` / `30s`） |
| `--sb-version V` | 锁定 sing-box 安装版本 tag（默认装官方最新版） |
| `--sb-bandwidth U:D` | **服务端** hy2 限速（上下行 Mbps，如 `200:500`；严格两段、仅一个冒号，三段值会被拒绝）；留空不限制 |
| `--doctor` | 只读体检：**状态与凭据** / 服务 / 配置校验 / 监听端口 / 证书与指纹 / 防火墙关键规则（含 v4 / v6 分族的跳跃 DNAT；v6 侧缺失按提示降级）/ 客户端域名解析 / NAT 端口清单一次看完，详见「跑完之后」 |
| `--json` | 与 `--status` / `--doctor` 搭配：输出机器可读 JSON（stdout 只含 JSON，NAT 端口清单等文本输出在 JSON 模式下自动关闭），供面板、批量管理工具或脚本解析；凭据只报存在性布尔，绝不含明文；`--status --json` 读取前先校验 state.env，被手工改坏时明确报错而不是产出解析失败的 JSON |
| `--rotate-secrets` | 快速换钥匙：只轮换 UUID / short_id / hy2 密码 / obfs 密码并重写服务端配置与客户端交付、重启 sing-box（Reality 密钥与自签证书不变，pinSHA256 无需更新）；现有客户端全部作废，需重新导入。仅跑模块 6/8/9，比完整重跑快得多；与 `--modules` 同时给时以 6/8/9 为准（会提示覆盖），避免「提示在轮换、实际一个凭据都没动」；与 `--keep-config` 互斥（轮换必须重写配置，显式报错不静默覆盖） |
| `--uninstall` | 干净下线代理：停用并移除 sing-box、删除 `/etc/sing-box` 与 `/root` 交付文件（含凭据明文）、**拆除本脚本部署的 Caddy 回落站**（其证书就在 `/etc/sing-box` 里，不拆会留下起不来的 Caddy；用户自建的 Caddy 站点自动识别、不碰）、清除代理端口防火墙规则与跳跃 DNAT（先复核 SSH 放行仍在位）；保留 SSH 加固 / fail2ban / tcpfit；state.env 默认保留供日后重部署，加 `--purge-state` 一并删除 |
| `--purge-state` | `--uninstall` 的修饰符：连 `state.env` 一起删除，彻底遗忘本机部署。单独使用不做任何事（会给一句提示后忽略） |

完整列表：`bash vps-init.sh --help`

### 跑完之后

- **客户端配置**：`/root/vps-init.client-outbounds.json`，直接粘进 sing-box 客户端的 `outbounds` 数组
- **分享链接**：`/root/vps-init.info` 里每个 IP 一条 vless:// 与 hysteria2://，可直接导入
- **查看全部结果**：`bash vps-init.sh --status`
- **一键体检（只读，不改任何东西）**：`bash vps-init.sh --doctor`
  检查 sing-box / caddy / fail2ban 服务状态、`sing-box check` 配置校验、监听端口
  （vless TCP / hy2 UDP / Caddy 回落）、防火墙关键规则（INPUT DROP、SSH 放行、跳跃 DNAT）、
  证书与指纹（自签证书在位与有效期、公钥哈希、链接 pinSHA256 与磁盘证书比对）、
  客户端域名是否解析到本机地址、NAT 内外端口清单。全绿 = 每项都通过；
  有 FAIL 时按提示逐项处理，WARN 通常是「本机没有装对应组件」的正常降级。
- **给面板 / 脚本吃的机器可读输出**：`--status --json` / `--doctor --json`
  stdout 只输出一份合法 JSON（人类文本全部走 stderr）；`doctor` 的 JSON 里每项检查
  都有 `status`（ok / warn / fail）、`name`、`detail`，外加 `summary` 计数，
  退出码语义与人类模式一致（有 fail 才返回 1）。
- **泄露后快速换钥匙**：`bash vps-init.sh --rotate-secrets`
  只轮换 UUID / short_id / hy2 密码 / obfs 密码，Reality 密钥与自签证书不动
  （客户端 pinSHA256 无需更新）；服务端配置与客户端交付文件重写、sing-box 自动重启。
  交互下需确认；`--yes` 直接执行。
- **彻底不跑了**：`bash vps-init.sh --uninstall`
  拆除代理但保留管理通道（SSH / fail2ban / tcpfit）；本脚本部署的 Caddy 回落站一并
  拆除（证书随 `/etc/sing-box` 删除，留着只会得到一个起不来的 Caddy；caddy 程序本体
  保留，`apt-get purge caddy` 可彻底移除）；用户自建的 Caddy 站点自动识别、绝不改动。
  删除规则后自动复核 SSH 放行仍在位，绝不锁死登录。state.env 默认保留
  （重跑可随时重新部署代理），确认不再用这台机跑代理就加 `--purge-state` 一并删除。

> 客户端配置里**不含** `direct` / `block` —— 脚本只给"本机节点 + selector"。
> sing-box 客户端侧通常本来就有，按需自行补上。

## 客户端 outbounds 输出示例（2×v4 + 1×v6）

节点名前缀是**机房城市**（自动识别；这里用 `洛杉矶` 演示，也可以 `--node-name` 指定）。
顺序固定：**先全部 vless，再全部 hy2**；同族多个地址自动加点号序号（`v4.1` / `v4.2`），同族只有一个时不加序号（`v6`）。selector 默认走第一个 vless。

> 下面是**完整输出**：1 个 selector + 3 个 vless + 3 个 hysteria2，**共 7 个对象**。密钥类字段此处用占位符表示；离线渲染（`--print-outbounds`）实际打印的是 `changeme` 这类占位值，IP 取 `--ips` 传入的值。
>
> ⚠️ **selector 里列出的每个 tag，都必须在同一个数组内定义**，否则 sing-box 启动会直接报 `outbound not found`。示例完整列出 7 条正是为了这个——别只抄其中一条。

```json
{
    "outbounds": [
        { "type": "selector", "tag": "洛杉矶 select",
          "outbounds": ["洛杉矶 v4.1-vl", "洛杉矶 v4.2-vl", "洛杉矶 v6-vl",
                        "洛杉矶 v4.1-hy2", "洛杉矶 v4.2-hy2", "洛杉矶 v6-hy2"],
          "default": "洛杉矶 v4.1-vl" },

        { "type": "vless", "tag": "洛杉矶 v4.1-vl",
          "tcp_keep_alive": "2m", "tcp_keep_alive_interval": "30s",
          "uuid": "<UUID>", "flow": "xtls-rprx-vision", "packet_encoding": "xudp",
          "server": "1.2.3.4", "server_port": 443,
          "tls": { "enabled": true, "server_name": "<SNI>",
                   "utls": { "enabled": true, "fingerprint": "chrome" },
                   "reality": { "enabled": true, "public_key": "<PUB>", "short_id": "<SID>" } } },

        { "type": "vless", "tag": "洛杉矶 v4.2-vl",
          "tcp_keep_alive": "2m", "tcp_keep_alive_interval": "30s",
          "uuid": "<UUID>", "flow": "xtls-rprx-vision", "packet_encoding": "xudp",
          "server": "5.6.7.8", "server_port": 443,
          "tls": { "enabled": true, "server_name": "<SNI>",
                   "utls": { "enabled": true, "fingerprint": "chrome" },
                   "reality": { "enabled": true, "public_key": "<PUB>", "short_id": "<SID>" } } },

        { "type": "vless", "tag": "洛杉矶 v6-vl",
          "tcp_keep_alive": "2m", "tcp_keep_alive_interval": "30s",
          "uuid": "<UUID>", "flow": "xtls-rprx-vision", "packet_encoding": "xudp",
          "server": "2001:db8::1", "server_port": 443,
          "tls": { "enabled": true, "server_name": "<SNI>",
                   "utls": { "enabled": true, "fingerprint": "chrome" },
                   "reality": { "enabled": true, "public_key": "<PUB>", "short_id": "<SID>" } } },

        { "type": "hysteria2", "tag": "洛杉矶 v4.1-hy2", "server": "1.2.3.4",
          "server_ports": ["30000:50000"], "up_mbps": 50, "down_mbps": 200,
          "hop_interval": "15s", "hop_interval_max": "30s", "password": "<PW>",
          "obfs": { "type": "salamander", "password": "<OBFS-PW>" },
          "tls": { "enabled": true, "server_name": "bing.com", "insecure": false,
                   "certificate_public_key_sha256": ["<pinSHA256>"], "alpn": ["h3"] } },

        { "type": "hysteria2", "tag": "洛杉矶 v4.2-hy2", "server": "5.6.7.8",
          "server_ports": ["30000:50000"], "up_mbps": 50, "down_mbps": 200,
          "hop_interval": "15s", "hop_interval_max": "30s", "password": "<PW>",
          "obfs": { "type": "salamander", "password": "<OBFS-PW>" },
          "tls": { "enabled": true, "server_name": "bing.com", "insecure": false,
                   "certificate_public_key_sha256": ["<pinSHA256>"], "alpn": ["h3"] } },

        { "type": "hysteria2", "tag": "洛杉矶 v6-hy2", "server": "2001:db8::1",
          "server_ports": ["30000:50000"], "up_mbps": 50, "down_mbps": 200,
          "hop_interval": "15s", "hop_interval_max": "30s", "password": "<PW>",
          "obfs": { "type": "salamander", "password": "<OBFS-PW>" },
          "tls": { "enabled": true, "server_name": "bing.com", "insecure": false,
                   "certificate_public_key_sha256": ["<pinSHA256>"], "alpn": ["h3"] } }
    ]
}
```

三个容易踩的点：

- **`direct` / `block` 不在输出里**：脚本只给"本机节点 + selector"，需按需自行补上。
- **hy2 的 TLS 指纹**：有 `CERT_HASH` 时输出 `insecure: false` + `certificate_public_key_sha256`（上例即是，
  **字符串数组**——这是 sing-box ≥ 1.13 要求的类型，客户端内核过旧会报未知字段）；取不到指纹才降级为 `insecure: true` 并省略该字段。
- **两种指纹别混用**：JSON 里的 `certificate_public_key_sha256` 是**公钥哈希（base64）**；
  分享链接里的 `pinSHA256` 是**整张证书的 sha256 指纹（hex）**——Hysteria2 官方口径就是
  `openssl x509 -noout -fingerprint -sha256`。两者数值不同，交付摘要里会分开列出。
- **`hop_interval_max` 需要客户端 sing-box ≥ 1.14**：默认会写入该字段（跳跃间隔随机化）；
  如果客户端内核是 1.13，会因未知字段拒绝整份 outbounds —— 此时去掉该字段或改用 1.14+ 客户端。
- **v6 的 `server` 不带方括号**：填 `2001:db8::1`，不是 `[2001:db8::1]`。

> 示例里的 IP 与上文命令一致，可直接用
> `bash vps-init.sh --print-outbounds --ips 1.2.3.4,5.6.7.8,2001:db8::1 --node-name "洛杉矶"` 复现
> （不加 `--node-name` 时前缀会自动识别成本机机房城市；
> 需在**无 state.env 的干净机器**上复现——已有状态时 `server` 会优先取 state 里存的域名而非裸 IP）。

---

## 注意事项

- **脚本必须是 LF 行尾**。CRLF 会让 bash 解析到行尾的 `\r` 直接报
  `$'\r': command not found` + `syntax error`，而且是**解析阶段**就失败，运行期代码救不了。
  脚本已内置**自愈**：开头一段检测到 CRLF 会自动生成净化副本并重跑，无需手动转换。
  实现要点：自愈块内**每一行都以 `#` 收尾**（行尾 CR 落进注释被忽略），
  这样整块在任何行尾风格下都能解析成功 —— 否则自愈块自己会先崩。
  实在手工修复：`sed -i 's/\r$//' vps-init.sh`（`.gitattributes` 已配置 `*.sh text eol=lf`，在 git 仓库内生效）。
- **用 `bash` 执行**，不要用 `sh`。Debian 的 `/bin/sh` 是 dash，不支持 `pipefail`（脚本也会自愈）。
- **NAT 机型**：详见上文「NAT 机型适配」。若服务商做的是**端口转发**（而非 1:1 NAT），
  探测到的公网 v4 客户端可能连不通 —— 请用 `--ips` 显式指定真实可达的地址。
  交互式运行会逐族询问「端口全开放 / 只给固定端口」，全开放族自动按原配置；
  非交互用 `--nat-v4-open` / `--nat-v6-open` 声明全开放族，受限族用
  `--nat-ports` / `--nat-map`（v4）与 `--nat-v6-ports` / `--nat-v6-map`（v6）告知固定端口。
  不想跑代理就直接在向导里对「是否开启端口转发映射」选「否」，或用 `--manage-only` ——
  脚本会取消 sing-box、v4 / v6 节点与代理防火墙规则，只留管理通道（详见上文）。
  防火墙**按族放行**：只做管理的族只放 SSH 内外端口，不再下发 vless / hy2 / 跳跃段规则。
- **域名解析**：客户端 `server` 默认用域名，v4 / v6 可各给一个独立域名
  （`--client-domain-v4` / `--client-domain-v6`），只给 `--client-domain` 则两族共用，
  未给则回退 `--domain`；详见上文。上线前分别确认 A / AAAA 记录指向本机；
  DNS-01 签出的证书不能证明域名解析正确。想回到裸 IP 用 `--no-client-domain`。
- **虚拟网卡**：手动跑 `tcpfit tune` 时必须显式给 `--bw <Mbps>`，否则 tcpfit 读不到标称带宽会中止；
  脚本本身不自动调优，`--tcp-bw` 只影响打印出来的那条命令。
- 首次请在**可重装的新机**上跑。

## 自检

```bash
bash vps-init.sh --self-test    # 内置自检：只读、不联网、不写系统路径
bash .selftest/all.sh           # 完整六层：内置 → 冒烟 → 定向 → 单元 → 渲染 → CRLF
bash .selftest/crlf.sh          # 单独跑 CRLF 回归（自愈块结构 + 机制端到端）
```
