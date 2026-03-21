# Sing-box 多用户与中转管理脚本

这是一个基于原版 Sing-box 逻辑的一键管理脚本，专为多用户管理场景设计，自编译版本支持 v2ray_api 流量统计。

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Tangfffyx/sing-box/refs/heads/main/sb.sh)
```
**非root用户：**
```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Tangfffyx/sing-box/refs/heads/main/sb.sh)
```

* **快捷命令**：安装完成后，在终端输入 `dsb` 即可唤出管理菜单。
* **避免冲突**：如果当前系统已安装官方版本的 sing-box，推荐先在菜单中执行“9. 卸载 sing-box”（保留配置），再执行“1. 安装/更新 sing-box”进行环境接管。

---

## 核心功能

### 1. 用户管理
支持多用户独立计费与权限控制：
* 可添加多个用户，并为其分配指定的节点权限（全部节点或特定节点）。
* 支持设置用户流量限制，可选择统计方式（单向流量仅计下载，或双向流量计算上下行）。
* 支持自定义流量重置日（如每月特定日期或月底）。
* 支持设置套餐到期日，到期自动停用。
* **使用方法**：新增用户-分配节点-设置套餐，到期后如需续订，手动修改套餐，手动重置流量，手动开启用户即可。

### 2. 协议安装
提供主流协议的一键部署：
* **支持的协议**：Reality、AnyTLS、Shadowsocks2022、VMess-WS、VLESS-WS、TUIC。
* **不支持的协议**：不支持 Naive 协议安装。
* **稳定性优化**：为增强在复杂网络环境下的容错率，所有部署的协议均默认关闭了 `tcp_fast_open` 和 `多路复用 (multiplexing)`。

### 3. 中转节点搭建
提供简单的跨节点流量中转方案：
* 中转机到落地机之间的通信默认使用强加密的 `Shadowsocks2022` 协议。
* **搭建步骤**：需先在“落地机”上安装 Shadowsocks2022 协议，随后在“中转机”的管理菜单中选择安装中转节点，填入落地机信息即可完成对接。

### 4. 导出节点配置
自动生成客户端订阅与配置信息：
* 支持一键导出 Clash、Quantumult X、Surge 格式的节点配置。

---

## 其他特色

* **原生兼容性**：
  采用官方 `with_v2ray_api` 编译版本，底层运行逻辑与官方原版完全一致。
  配置文件固定在 `/etc/sing-box/config.json`。
  支持直接使用 Linux 原生命令进行管理与排错（例如：`systemctl status sing-box` 或 `sing-box check -c /etc/sing-box/config.json`）。
  
* **系统时间校准 (Chrony)**：
  系统工具中提供了一键安装并启用 `chrony` 服务的功能。**强烈推荐执行此项**，因为精准的系统时间是保障流量统计准确性以及 Shadowsocks2022 等防重放协议稳定运行的必要条件。

## 彻底卸载删除

为确保彻底卸载并清理所有残留环境，请按以下步骤操作：

1. **第一步**：先运行脚本，选择菜单中的 **`9. 卸载 sing-box`**。
2. **第二步**：在终端直接复制并执行以下命令：

```bash
rm -f /root/sing-box.sh
rm -f /usr/local/bin/sb
rm -rf /etc/sing-box
rm -rf /etc/sing-box-manager
rm -rf /var/log/sing-box
rm -rf /var/lib/sing-box
```

> 💡 **提示**：执行完毕后，即可彻底卸载干净脚本本体、所有节点配置、用户数据数据库以及运行日志，还你一个纯净的系统环境。
