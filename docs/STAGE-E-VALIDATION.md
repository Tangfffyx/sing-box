# 阶段 E · SOCKS5 落地和中转

- 安装 SOCKS5 后直接显示「落地链接」。公网地址、域名和映射端口可从编辑节点设置。链接分别编码账号和密码，IPv6 使用方括号。
- 全量和按网站中转共用导入。首次粘贴链接并填写落地标识，转发通过后保存。已有落地点可直接选。单个本机入口自动选择。更新同一标识先列出受影响线路，所有引用走新出口，入口原账号和凭据保留。
- UDP 默认原生。诊断先验证 TCP，再检查两次原生 UDP，必要时通过临时配置测试 UDP over TCP。只有收到有效回包才提供启用选项，确认后只改这台落地。可以恢复原生方式。探测以 DNS 回包作为验证，因此落地需能访问探测目标的 53 端口。[sing-box SOCKS 出站](https://sing-box.sagernet.org/configuration/outbound/socks/) · [UDP over TCP](https://sing-box.sagernet.org/configuration/shared/udp-over-tcp/)

## 验收

- 无网络回归覆盖链接往返、IPv6、域名、映射端口、特殊字符、首装最少输入、重复导入、错误密码和取消更新。更换后对照全量和按网站的出站设置，并逐字节核对原入站认证资料。
- 真实 sing-box 1.14.2 本机回环覆盖认证 TCP、原生 UDP、UDP over TCP 和真实错误密码拒绝。原生成功、仅 UDP over TCP 成功、两种都失败，以及确认、取消和恢复的决策由命令夹具覆盖。
- 跨两台独立机器的实际出口切换和 NAT 实测仍待验收。

`bash tests/check.sh` 运行命令夹具。回环实测使用 `SB_TEST_CORE=/path/to/sing-box python3 tests/stage-e-loopback.py`。
