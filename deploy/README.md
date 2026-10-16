# Ubuntu systemd 一键安装

在全新 Ubuntu（x86_64）上，把本仓库放到机器后执行：

```bash
sudo bash deploy/install-ubuntu-systemd.sh
```

脚本会安装编译依赖、Rust、Lighter 官方签名库，编译 `arb-web` / `arb-scan` / `arb-paper` / `arb-live`，登记 systemd 服务并启动看板。

| 路径 | 用途 |
| --- | --- |
| `/opt/arb-bot/` | 程序（只读） |
| `/var/lib/arb-bot/` | 台账、价差历史等运行数据，必须备份 |
| `/etc/arb-bot.env` | 密钥与配置（0600，已有文件不会覆盖） |
| `/opt/lighter/lighter-signer-linux-amd64.so` | Lighter 官方签名库 v1.0.10 |

```bash
sudo arbctl status
sudo arbctl logs
sudo arbctl restart
```

默认不开实盘。`/etc/arb-bot.env` 和仓库 `.env.example` 都按 **必填 / 条件必填 / 选填** 分组。
填密钥后把 `ARB_WEB_LIVE` 改成 `trade`，并设置 `ARB_WEB_MARKET_SLIPPAGE`。

可选参数：`--deps-only`、`--no-start`、`--skip-build`、`--uninstall`、`--purge`。
