# vps-init · Debian VPS 开荒一键脚本

纯 bash 单文件（`vps-init.sh`），仅依赖系统自带工具 + apt。给 Debian 12/13 的新 VPS
一键完成：系统基线、SSH 加固、防火墙、fail2ban、TCP 调优、sing-box 安装、
Reality 回落站、配置生成、交付汇总——跑完直接拿到可用的客户端配置与分享链接。

## 一键部署

```bash
# 推荐：先落盘再执行（保留 TTY，交互式向导可用）
curl -fsSL https://raw.githubusercontent.com/anarkh35/vps-init/master/vps-init.sh -o vps-init.sh \
  && bash vps-init.sh
```

> 纯管道 `curl … | bash` 没有 TTY，交互向导会自动跳过，参数必须写全。
> NAT 机务必带 `--nat --nat-ports … --nat-map …`（或直接 `--manage-only`）。

## 常用命令

```bash
bash vps-init.sh --status        # 只读查看当前状态
bash vps-init.sh --doctor        # 体检：配置/防火墙/服务/证书指纹/域名解析
bash vps-init.sh --yes --keep-config   # 重跑沿用旧配置（安全默认）
bash vps-init.sh --yes --new-config    # 重跑换新凭据（旧客户端作废）
bash vps-init.sh --rotate-secrets      # 只换凭据不动网络配置
bash vps-init.sh --uninstall           # 卸载（加 --purge-state 连状态一起清）
```

## 特性

- **9 模块化**：`--modules` 自由选择执行范围，全幂等可重跑
- **NAT 机型分族适配**：v4/v6 独立端口策略、UDP 端口跳跃、ssh-only 模式
- **安全默认**：重跑默认沿用旧配置；凭据原子落盘（0600）；实例互斥锁
- **机器可读**：`--status --json` / `--doctor --json` 输出纯 JSON
- **六层回归自测**：`bash vps-init.sh --self-test` 或 `.selftest/all.sh`

## 完整教程

参数表、NAT 机型说明、交付文件清单、JSON 契约、卸载与轮换等详见
**[overview.md](overview.md)**（使用教程，全文覆盖）。
