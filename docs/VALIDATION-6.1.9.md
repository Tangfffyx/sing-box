# 6.1.9 验证记录

日期：2026-09-26。目标内核：SagerNet/sing-box v1.14.2（核对当日官方最新稳定 Release）。测试 VPS：Debian 13.3 / amd64 / systemd。保留全部八种协议、用户管理、计费、中转、WARP SOCKS 接入和 Telegram 管理功能；新版最低内核为 1.14.0。

## 已完成

| 场景 | 验证方式与结果 |
| --- | --- |
| 八种协议配置 | 使用生产构建器生成 Reality、AnyTLS、SS2022、SOCKS、Trojan、VMess WS、VLESS WS、TUIC，真实内核 check 全部通过 |
| 八种协议传输 | sing-box 客户端经服务端访问本地 HTTP 和 UDP echo，TCP/UDP 全部通过 |
| 用户停用、未分配节点 | 同一份原凭证重新连接，八种协议全部拒绝 |
| 凭证保留 | 重复投影配置结果一致；测试机部署前后原节点凭证摘要一致 |
| 现有 AnyTLS 节点 | 部署后以原凭证完成真实代理传输 |
| 流量 | 空统计、重复采样、实例变化、节点移除由回归覆盖；真实内核重启前后下载累计通过 |
| 路由与规则下载 | 全量中转、按规则中转、WARP SOCKS 分流均完成真实转发，并通过出站计数确认路径；后两者从本地 HTTP 下载二进制规则集，无弃用警告 |
| 配置迁移 | download_detour 转 http_client；保留自定义下载出站、direct 参数、已有 HTTP client；默认拒绝迁移与幂等测试通过 |
| 端口冲突 | SS 默认 TCP/UDP、显式 TCP-only、TUIC UDP、编辑排除自身的检测通过 |
| systemd | 独立真实服务验证无变化不重启、额度修改不重启、配置修改换进程、候选启动失败回滚，以及成功升级保留备份 |
| OpenRC | Alpine 3.22 临时容器中，真实启动、配置重启、进程验证和候选失败回滚全部通过；测试容器自动删除 |
| 并发与账期 | Linux 真实 flock 竞争；菜单字段冲突、流量保留、补正/清零、错过账期、跨年与闰月夹具通过 |
| 导出 | SS2022 服务端与用户密钥相同时，实际导出链接解码仍包含两段密钥 |
| Telegram 任务 | 离线执行套餐、启停、补正/清零、到期日、重置日命令；非法输入拒绝；没有调用真实 Bot API |
| 构建 | Shell 语法、内嵌 Python 语法、生成 sb.sh 与源码一致性通过 |

用户投影性能对照：同一 VPS、4 个 SOCKS 节点、40 个业务用户加 admin、凭证已存在。优化前 10483 ms，优化后 998 ms，输出 JSON 规范化后完全相同。基线为 PR 前一提交 `5db954a74396cef6662e7078109150167533f877` 的 user_manager_apply_to_json；两次使用相同的新路由实现，衡量的是投影优化。单次测量，不代表所有操作或所有机器都提升相同比例。

## 可复现入口

```bash
bash tests/check.sh
bash tests/core-smoke.sh /path/to/sing-box /path/to/grpcurl
# PATH 中需要真实 sing-box；内核包含 with_v2ray_api,with_quic,with_utls
SB_TEST_CORE=/path/to/sing-box python3 tests/protocol-smoke.py
bash tests/routing-smoke.sh
# 仅在可测试的 Linux 主机上：创建并清理独立 systemd 服务
sudo bash tests/systemd-smoke.sh --allow-systemd
```

核心协议和中转测试使用 loopback 临时端口，不修改正在使用的 sing-box 服务。systemd 测试会创建独立临时 unit 并在结束后删除。测试机实际部署另外经过原凭证保留和原 AnyTLS 节点连接检查。

## 旧代码问题与处理

- 升级后可能仍运行旧内核、配置生效结果未验证：改为明确重启、进程/API 健康检查和失败回滚。
- 重启后流量少计、删除节点影响累计：按节点用户和实例保存基线。
- 菜单提交覆盖后台统计：在锁内合并字段并检测冲突。
- 条件不同的路由被错误去重：保留完整规则和顺序。
- 错过重置日不补执行：按应属账期补执行。
- SS 的 UDP 冲突漏检：按实际传输集合判断。
- SS2022 相同双密钥导出省略一段：始终保留多用户完整密码。
- WS Clash 导出的 early-data 设置混入 headers：调整为 ws-opts 的字段。

## 保留的限制与未验证范围

- Telegram 原有公网明文 HTTP 和共享接入密钥存在风险，尚未改为 HTTPS/每节点独立凭证。需要可信私网/隧道等保护，不应将当前接口直接暴露到不受信任网络。真实 Telegram 收发、通知和不同账号的绑定流程未进行端到端测试。
- WARP 验证的是脚本管理的本地 SOCKS 接入/分流，没有注册 Cloudflare 账户或验证外部 WARP 服务。WS 已验证协议传输，没有验证用户的 CDN、域名和反向代理。
- Reality 使用本地 TLS 握手服务测试；不同公网握手目标的可用性受网络影响。
- 未逐一运行 Clash、Quantumult X、Surge 等第三方 GUI 客户端，不能把导出语法检查等同于所有客户端版本兼容。
- 流量仍为周期采样；异常退出前未采样的尾流量无法恢复，外部极短间隔连续 HUP 不能保证精确识别。限额并非逐字节即时切断。
- 运行配置改变仍会重启服务，短暂中断连接；纯额度等不改变配置的操作不会重启。
- 旧进程退出时的 `use of closed network connection` 来自内核统计监听关闭路径；未修改上游内核。它应与新进程是否正常启动分别判断。
- 本轮直接实测架构为 amd64，arm64 尚未实机验证。
