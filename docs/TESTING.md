# 6.1.8 验收清单

先在测试 VPS 上做以下验证，再更新正式节点。GitHub CI 验证自动化场景，VPS 验收确认实际系统服务、网络和客户端行为。

## 1. 自动化检查

在仓库目录执行：

```bash
bash tests/check.sh
```

需要 Bash、jq、Python 3；Linux 上还需要 flock。CI 在 Ubuntu/Alpine 执行相同回归，并编译带 V2Ray API 的 sing-box 1.14.2，验证实际 SOCKS 放行/拒绝及重启前后流量累计。

macOS 的 Bash 3 会跳过真实 flock 和 /proc 进程测试。systemd/OpenRC 操作由回归中的模拟命令覆盖，必须继续在实际 VPS 上验收。

## 2. 更新前留存

保留旧的 `/root/sb.sh`、`/usr/local/bin/sing-box`，以及 `/etc/sing-box`、`/etc/sing-box-manager` 两个目录。记录原内核版本、测试用户流量和客户端连接情况。

测试机建议先创建专用测试用户，至少分配两个节点；保留一个正常用户作为对照。不要用正式用户做超额、到期或清零实验。

## 3. 检查真实运行版本与服务

更新脚本后，脚本版本应为 6.1.8；内核版本与脚本版本是两个不同的数字。

Debian/Ubuntu（systemd）：

```bash
grep '^SCRIPT_VERSION=' /root/sb.sh
/usr/local/bin/sing-box version
/usr/local/bin/sing-box check -c /etc/sing-box/config.json
systemctl is-active sing-box
systemctl show sing-box -p MainPID -p NRestarts -p ExecMainStatus
pid=$(systemctl show sing-box -p MainPID --value)
/proc/$pid/exe version
journalctl -u sing-box --since '10 minutes ago' --no-pager -n 100
```

Alpine（OpenRC）：

```bash
grep '^SCRIPT_VERSION=' /root/sb.sh
/usr/local/bin/sing-box version
/usr/local/bin/sing-box check -c /etc/sing-box/config.json
rc-service sing-box status
pid=$(cat /run/sing-box.pid)
/proc/$pid/exe version
tail -n 100 /var/log/sing-box/access.log
```

通过条件：配置检查返回 0；服务运行；`/proc/<PID>/exe version` 与磁盘内核版本一致；一分钟后服务仍在运行，没有反复崩溃重启。只看 `.installed_release` 或磁盘 `version` 不能证明运行进程已更新。

## 4. 验证连接与用户限制

用实际客户端逐项测试：

| 操作 | 应有结果 |
| --- | --- |
| 正常用户连接每个已部署协议 | 能访问目标网站/下载文件 |
| 测试用户只分配节点 A | A 可用，未分配的 B 不可用 |
| 停用测试用户 | 新建连接被拒绝 |
| 再启用测试用户 | 新建连接恢复 |
| 将测试用户到期时间设为今天，执行 `bash /root/sb.sh --periodic-sync` | 自动停用，新建连接失败 |
| 给测试用户设置小额度，使用手动补正流量使总量超过额度，再执行 periodic-sync | 标记超额并停用 |
| 测试用户被限制后检查正常对照用户 | 对照用户仍可用 |

应关闭客户端旧连接并重新连接来检查认证；不要仅看客户端是否仍显示“已连接”。周期任务计划每 3 分钟运行，限额不是逐字节实时硬切断。

## 5. 验证流量累计

1. 记录测试用户当前上传、下载及总量。
2. 经代理下载一个已知大小文件，执行 `bash /root/sb.sh --periodic-sync`，查看累计值上升。
3. 不产生新业务流量，再执行两次同步，不应重复累计同一份流量；客户端后台连接可能产生少量新增流量。
4. 重启 sing-box，继续通过同一用户下载文件，再同步。累计值应包含重启前与重启后的两段，不能从零开始，也不能减少。
5. 在两个节点都产生流量，删除其中一个测试节点后再次同步。剩余节点的历史流量不应重新累计。
6. 手动重置测试用户流量，再下载并同步，应从重置后的新增量开始累计。

协议和 TCP 开销、上传请求会影响总字节数，不应要求与文件大小逐字节相等。异常退出前尚未采样的尾流量无法恢复；旧版首次迁移前发生的计数器清零也无法追溯重建。

## 6. 验证并发编辑与配置不变时不重启

1. 打开终端 A 的用户套餐编辑菜单，停在输入阶段。
2. 在终端 B 产生代理流量并执行 periodic-sync，记录新的流量值。
3. 回到终端 A，只修改额度并提交。
4. 新额度应生效，终端 B 已累计的流量应保留。若 B 修改了相同套餐字段，A 应提示冲突，不能静默覆盖。
5. 记录服务 PID，仅修改不影响认证/路由的额度或补正值；在无其他节点变更的情况下，PID 应保持不变。
6. 改变需要生效的节点权限后，服务 PID 应改变，并在几秒后恢复连接。应用此类配置会短暂中断连接。

## 7. 账期与回滚

账期的“错过重置日、跨年、闰年月底、重复执行不重置、新用户建账”由回归夹具覆盖。正式 VPS 不要为了测试而修改系统时间。

升级失败回滚在自动化夹具中通过候选内核启动失败、候选配置检查失败模拟。实际首次部署可在可恢复的测试机上验收升级；成功后应保留：

- `/usr/local/bin/sing-box.bak`：上一版内核。
- `/etc/sing-box/config.json.bak.upgrade`：升级前配置。

首次安装没有上一版备份。不要通过破坏正式节点的证书、端口或配置来制造回滚故障。

## 8. 报告问题时记录

记录操作步骤、预期/实际结果、Linux 发行版、systemd/OpenRC、脚本版本、运行内核版本，以及问题发生前后各一次用户流量值。附最近的服务错误日志和对应 GitHub Actions 失败链接；配置中的密码、私钥、TG Token、接入密钥应先遮盖。
