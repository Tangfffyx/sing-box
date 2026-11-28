# 阶段 D · 接入已有 CDN

阶段 D 使用同一套 7.0.0 施工目录和原有用户库。选择「节点管理 → 接入已有 CDN」后挑选 VMess-WS 或 VLESS-WS。已有域名的回源设置可在下一条路径中复用。新入口沿用当前节点的路径、UUID 和配额。已保存的旧入口继续导出。

## 接入方式

- 已有 Caddy、Nginx 或其他反代时，可以沿用现有转发规则，直接使用验证模式。把当前节点的原路径转到对应的 WS 监听地址和端口。CDN 侧需已配置 HTTPS 回源和 WebSocket。
- 如需脚本维护现有 Nginx 站点，在选定的 HTTPS `server` 中加入菜单显示的 `include /etc/sing-box-manager/ws-cdn.d/<公网域名>.*.conf;`。脚本只写该域名的托管片段，通过 `nginx -T` 后再重载。失败时用原片段回滚。托管路径先在接入菜单移除，再卸载节点。[Nginx WebSocket 反代](https://nginx.org/en/docs/http/websocket.html)
- 普通配置只填域名并采用 HTTPS 443。本机回源端口不同、源站证书域名不同或使用私有 CA 时，从自定义填写。验证先检查源站和公网入口的 TLS 证书及 WebSocket 升级，再用该节点的实际 UUID 代理一次 HTTPS 请求。已有反代的验证在管理锁外执行。托管片段在锁内暂时启用，验证失败时恢复，避免其他操作读到半完成的写入。
- 导出从保存的入口读拨号地址、SNI 和 Host。通用链接和 QX 保留纯路径。Mihomo 只有实际透传测试通过才写 Early Data。未保存入口时指向 CDN 菜单。普通单入口显示「CDN 自动」。[sing-box WebSocket 传输字段](https://sing-box.sagernet.org/configuration/shared/v2ray-transport/)

### 运营商名称

供应商提供了独立入口时，可以在自定义里提供记录文件。文件为 JSON 对象，填写 `operator`（电信、移动或联通之一）、`provider`、供应商依据 `source`（HTTPS 链接）、`host`、数字 `port` 和供应商列出的 `edge_ips` 数组。脚本验证现有入口和新入口不同，并把实际连接到的地址与记录核对，匹配后标为「电信入口」等。来源由运营者核对。「优选」需要分网端到端对照，本期导出不生成该名称。

## 验收

| 检查 | 结果 |
|---|---|
| 真实双路径链路 | 本机 Nginx 1.28.0 模拟独立 CDN 边缘，经校验证书的 HTTPS 回源到 Nginx，再转发给 sing-box 1.14.2。VMess-WS 和 VLESS-WS 在同一域名用各自 UUID 完成真实代理请求。 |
| 失败恢复与旧链接 | 故意把 VLESS 路径转到 VMess 后，两段 HTTPS 和 WebSocket 升级仍通过，但真实代理请求失败。脚本恢复第一条路径的片段和元数据，原 VMess 链接仍连通。另用故障注入覆盖进程中断后恢复。 |
| 证书与 Early Data | 回环验收覆盖公网证书不可信时的拒绝。VMess 透传 Early Data 后才写入 Mihomo。VLESS 在边缘去掉请求头后仍可普通连接，导出省略 Early Data。 |
| 导出与线路依据 | 解析 VMess 通用链接的 Base64 内容以及 VLESS URL。确认三种格式实际拨号地址为入口，源站地址和监听端口未出现在普通导出。独立地址证据不匹配时使用普通名称，匹配和单剩一个入口的情况均有回归测试。 |

当前没有已绑定的真实公网 CDN 供实机验收。上表的链路、回滚和证书检查使用回环测试站点，生产公网入口的 DNS、证书和两条代理路径仍需在实际域名验证。从零开通不在本期范围内。

带 Bash 4 以上、flock 和 Python 3 的环境中，`bash tests/check.sh` 运行无网络夹具。允许本机绑定时，给 `SB_TEST_NGINX` 和 `SB_TEST_CORE` 指定可执行文件绝对路径，再运行 `bash tests/stage-d-loopback.sh`。
