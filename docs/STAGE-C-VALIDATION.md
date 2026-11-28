# 阶段 C · 协议默认值、导出和安装前校时

施工目录沿用阶段 A、B 的 7.0.0 源码。分发脚本由 `bash build.sh` 生成。

## 实现

- 节点列表和导出按 HY2、VLESS-Reality、AnyTLS、SS2022、SOCKS5、TUIC、Trojan、VMess-WS、VLESS-WS 显示。最后两种共用安装入口，回车选 VLESS-WS。每种协议先显示推荐方案，回车采用，`c` 进入自定义。区分 TCP、UDP 和 HY2 跳跃范围的占用。安装结果直接导出本批节点。
- HY2 推荐保留 Gecko 和端口跳跃，随机生成两种独立凭据。跳跃规则验证失败时清理导出用的范围并提示。AnyTLS、HY2、Trojan、TUIC 的自签 SNI 使用固定名称，已有有效证书可以复用。Reality 单独验证握手目标，并自动生成密钥对、Short ID 和 UUID。普通编辑只修改导出用的公网地址，原入站、证书、路径及凭据保留。
- SS2022 使用两段标准 Base64 密钥，SIP002 导出分别对算法和组合密码做百分号编码。HY2 自签通用链接带 `insecure=1`。AnyTLS 省略空闲会话覆盖值。TUIC 使用 BBR、`h3` 和原生 UDP，0-RTT 默认关闭。Trojan 读取原配置的 SNI 和 ALPN。公网域名、IPv4、IPv6 和映射端口与本机监听分别保存。WebSocket 缺真实公网入口时提示补录。[SIP002](https://shadowsocks.org/doc/sip002.html) · [sing-box Hysteria2 入站](https://sing-box.sagernet.org/configuration/inbound/hysteria2/) · [Mihomo Hysteria2 导出字段](https://wiki.metacubex.one/config/proxies/hysteria2/)
- 只对新装 SS2022 或 VMess 的批次核时，合装只核一次。机器已同步则直接继续。状态不明时首先只读核时，确认偏差后再复用正在运行的服务或按需安装。发现无改时权限或纠正失败时只暂缓这两种协议。系统工具移除了手动校时入口。[chronyc 跟踪状态](https://chrony-project.org/doc/4.4/chronyc.html) · [Alpine 的 chrony-openrc](https://pkgs.alpinelinux.org/package/v3.22/main/aarch64/chrony-openrc)

## 验收

| 检查 | 结果 |
|---|---|
| 九种协议默认配置 | 用实际 1.14.2 内核执行九协议 TCP 和 UDP 测试，授权用户成功，停用及未分配的用户被拒。 |
| 推荐安装、排序和编辑 | Bash 回归覆盖 HY2 的无额外输入安装、TCP 与 UDP 冲突回退、WS 默认选择、全部显示顺序及安装后导出范围。编辑前后的入站逐字节相同。跳跃验证失败时测试通过，导出资料回到主端口。 |
| 导出与 Reality | 九种通用链接通过解析和原值回读，覆盖 IPv6、保留字符、SS2022 两段相同密钥、证书策略和 WS 自定义公网端口。OpenSSL 3.5.4 实际从私钥恢复的 Reality 公钥与 sing-box 生成结果一致。默认握手目标实测通过证书、TLS 1.3 和 HTTP/2 检查。 |
| HY2 拥塞控制 | 仅在临时核心里加入算法选择日志。实际建立两条 Gecko 连接，客户端分别留空、填写带宽。两次服务端与客户端都选择 BBR。 |
| 校时 | 命令夹具覆盖已同步零安装／零重启、只读检测、复用 chronyd、两时间源确认偏差、无权限、不可达、按需安装 Alpine OpenRC 服务、混合批次部分成功。未在 Ubuntu、Debian、Alpine 的真实服务上改时或装包。 |

实机待验包括 Linux 防火墙端口跳跃和开机恢复、目标发行版校时，以及 QX 中 Gecko 和端口跳跃的导入。阶段 C 导出对尚未验证的 QX 混淆或跳跃组合显示待验证。已绑定 CDN 的回源验证按阶段 D 执行。

## 重跑

使用 Bash 4 以上及 flock 运行 `bash tests/check.sh`。真实协议检查使用 `SB_TEST_CORE=/path/to/sing-box python3 tests/protocol-smoke.py`，将同一 sing-box 放入 PATH，内核需包含 `with_v2ray_api`、`with_quic` 和 `with_utls`。
