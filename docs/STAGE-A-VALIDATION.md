# 阶段 A 施工与验收

施工基于从 GitHub 下载的 7.0.0 固定提交 `e2c5cab46ad1ff9541a8b75e40a79b8cd104cdc2`。归档 SHA-256 为 `f0658d35bf01e753bedb84d7b37b764e0c7f242ae6db632480f68d1bf5dadc5d`。工作目录为 `7.0.0-stage-a/`。[固定源码](https://github.com/Tangfffyx/sing-box/tree/e2c5cab46ad1ff9541a8b75e40a79b8cd104cdc2)

## 实现

- 用户库读取和保存均检查结构。只在用户库缺失且没有旧安装记录时初始化。空文件、无效 JSON、缺少管理员或已有安装丢失用户库时保留原文件并提示恢复。新写入保留一个独立的初始化记录，用来识别后续丢失。
- 持管理锁写入用户变更前，保存用户库、运行配置和元数据的原文件。在三个文件写完后才标记变更完成。如果写入失败立即恢复。如果进程中途退出，下一次获取锁先恢复旧文件，必要时重新加载服务。恢复失败时保留备份并阻止进一步写入。
- 重建单文件分发脚本。阶段 B 的授权和流量规则沿用 7.0.0。

## 验收

| 检查 | 结果 |
|---|---|
| 原版 Linux 发布记录 | 同一提交在 GitHub Actions 的 Ubuntu 和 Alpine 回归，以及九协议、真实流量、中转、systemd 和 OpenRC 用例均通过。核对的是已有运行记录。当前工作环境为 macOS，未重新执行原版 Linux 作业。 |
| 阶段 A 本机回归 | 使用 Bash 5.2 和 macOS flock 0.4.0 执行 `bash tests/check.sh` 成功。Linux 专用的 `/proc` 进程身份测试跳过。 |
| 损坏用户库 | 真正的首次使用成功初始化。空文件、无效 JSON、缺少管理员、管理员结构错误和旧库丢失，均通过用户管理、定时同步和 Bot 入口验证。原文件和授权没有被重建或覆盖。 |
| 两次迁移 | 第一次通过用户管理的提交路径写入，第二次写入后运行配置、用户库和元数据逐字节相同。原凭据、节点授权、历史流量、Telegram 绑定和手工路由通过对照。 |
| 写入失败与进程中断 | 数据库和运行配置写入后，分别注入元数据写入错误及 SIGKILL。正常失败时立即恢复。强制退出时由下一次获取锁恢复。原文件逐字节恢复，再次获取锁不重复恢复。 |
| 恢复后旧链接 | 用 sing-box 1.14.2 真实运行恢复出来的配置。Alice 的旧 Trojan 中转链接和 Bob 的旧 SS2022 链接均访问到本机 HTTP 目标。此测试使用回环，服务管理接口由独立的故障注入测试验证。 |

[原版 Ubuntu 与 Alpine 回归](https://github.com/Tangfffyx/sing-box/actions/runs/45840075213/job/139979096933) · [原版真实内核与服务验收](https://github.com/Tangfffyx/sing-box/actions/runs/45840075213/job/139979096379)

## 重跑

在本目录用 Bash 4 以上及 flock 运行以下命令。第二条命令要求本机回环可监听，使用的端口在迁移样本中固定。

```bash
bash tests/stage-a.sh /tmp/sb-stage-a-recovered.json
python3 tests/stage-a-reconnect.py "$(command -v sing-box)" /tmp/sb-stage-a-recovered.json
```
