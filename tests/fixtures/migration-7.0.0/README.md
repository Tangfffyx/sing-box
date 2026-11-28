# 阶段 A · 7.0.0 基线与迁移对照样本

## 原版基线

2026-11-28 使用固定提交 `e2c5cab46ad1ff9541a8b75e40a79b8cd104cdc2` 的源码归档。归档内 38 个文件与测试目录逐字节相同，`lib/00_base.sh` 和 `sb.sh` 均声明 7.0.0。归档 SHA-256 为 `f0658d35bf01e753bedb84d7b37b764e0c7f242ae6db632480f68d1bf5dadc5d`。用原版 `build.sh` 重建的 `sb.sh` 与归档中的分发文件逐字节相同。存放样本的工作目录脚本仍为 6.1.9。[固定源码](https://github.com/Tangfffyx/sing-box/tree/e2c5cab46ad1ff9541a8b75e40a79b8cd104cdc2)

| 原版检查 | 实际结果 |
|---|---|
| macOS 系统 Bash 3.2 执行 `bash tests/check.sh` | 到界面测试退出 127。旧兼容分支只载入 jq 变量，未载入 `run_with_spinner`。 |
| 临时 Bash 5.2 执行同一命令 | 通过前段可靠性、迁移与导出检查。Telegram 用例因缺少 `flock` 退出。 |
| Bash 5.2 加 macOS 版 `flock` 0.4.0 重跑 | 12 次并发写入全部正确。原版随后读取 Linux `/proc/<pid>/stat`，全套以 1 退出。 |
| macOS 下分跑现有用例 | Shell 语法、除 Linux 进程分支以外的可靠性用例、迁移、SS2022 导出、Telegram 离线任务、4 个 Python 单测、独立和内嵌 Python 语法，以及分发文件重建对比均通过。 |
| Linux 原版全套、真实内核及服务回滚 | 待在 Linux 环境运行 `bash tests/check.sh` 和仓库 CI 对应的 smoke 用例。 |

## 迁移对照

所有身份、凭据、绑定编号和证书均为测试数据。配置只监听回环。旧链接回连测试在临时目录生成自签证书和私钥。仓库中的公开证书仅用于证书识别测试。测试时将样本复制到临时目录，证书路径需以该目录为基准。

- `config.json` 保存原运行结构，涵盖 SS2022、Trojan、SOCKS5 和未保存 CDN 域名的旧 VMess-WS。包含直连、Alice 的 Trojan 中转和一条手工拒绝规则。`landing.json` 是带认证的本地落地机，`meta.json` 保存落地引用。
- `user-manager.json` 有管理员、权限不同的 Alice 和 Bob，以及手动停用的账号。保存原认证名、授权节点、账期、历史用量、手动补正和按认证名记录的采样基线。`telegram.json` 保留一条虚构绑定。
- `old-exports/` 保存由原版导出器生成的管理员、Alice、Bob 三份文本。只替换了地址收集与终端输出环境，导出逻辑使用原版。VMess 的 `example.com` 是旧版占位值，此处用于复现历史行为。
- `expected.json` 保存账本对照值。Alice 原有 2,010,000 字节，Bob 原有 305,000 字节。重放同一份上报两次，Alice 最终为 2,010,100 字节，Bob 仍为 305,000 字节。

在能读取固定 7.0.0 源码的环境中，用 Bash 4 以上运行 `verify-original.sh`，将该源码目录作为第一个参数。校验已保存的旧版导出、用户权限和重复采样结果。真实客户端连通、迁移运行两次、损坏用户库保护和写入中断恢复属于阶段 A 后续实现验收。
