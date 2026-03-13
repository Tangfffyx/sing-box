# 📦 Sing-box Elite Management System

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Sing-Box](https://img.shields.io/badge/Sing--Box-Latest-success)](https://sing-box.sagernet.org/)
[![Bash](https://img.shields.io/badge/Language-Bash-yellow.svg)](https://www.gnu.org/software/bash/)
[![Version](https://img.shields.io/badge/Version-3.0.17-brightgreen.svg)]()

> 🚀 一款强大、健壮且优雅的 Sing-Box 服务端一键部署与全生命周期管理工具。

本项目致力于简化 Sing-Box 的部署与维护流程。基于强大的动态 JSON 解析能力（`jq`），实现了从核心协议部署、智能路由构建、中转网络搭建到全平台客户端配置导出的全链路自动化。告别繁琐易错的手动配置，助你轻松构建专属的高性能代理网络。

## ✨ 核心特性 (Features)

### 1. 🛡️ 官方规范化的一键管理
* **极简部署与更新**：接入 Sagernet 官方 APT 源，一键全自动安装/平滑升级 Sing-box 核心程序。
* **全局守护机制**：自动配置 Systemd 守护进程，并在每次配置变更时进行严格的 `sing-box check` 语法校验。一旦发现异常，系统将**自动拦截并安全回滚**至上一个可用版本，确保服务永不失联。
* **全局快捷键**：内置 `sb` 快捷命令，随时随地唤出可视化管理菜单。

### 2. 🔌 六大主流协议矩阵
高度集成的交互式菜单，支持自由组合、一键部署并存多个协议入站（Inbounds），智能防端口冲突：
* **VLESS-Reality** (推荐，内置防探测与 XTLS Vision 流控)
* **AnyTLS**
* **Shadowsocks** (原生支持 ss2022-blake3-aes-128-gcm 强加密)
* **VMess-WS**
* **VLESS-WS**
* **TUIC** (基于 QUIC 协议，内置 BBR 拥塞控制)

### 3. 🛫 高效流量中转 (Relay)
* **极简中继拓扑**：针对跨国或跨网段线路优化，支持基于任一已部署的主协议一键派生中转节点。
* **原生安全隧道**：中转通信默认强制采用 **ss2022** AEAD 强加密协议作为底层数据链路，兼顾极高的安全性与超低延迟损耗。
* **动态路由级联**：新增或删除中转节点时，脚本会自动通过 `jq` 重建并收敛路由规则（Route Rules），确保流量精准分发，不产生冗余规则。

### 4. 📱 全平台客户端订阅导出
摒弃繁琐的手动参数组装，脚本能够遍历当前服务器拓扑，一键生成并导出适用于主流客户端的配置代码：
* 支持 **Clash / Surge / Quantumult X**。
* 直连节点与中转节点智能分类展示。

### 5. 🛠️ 进阶系统工具与自适应优化
* **智能时钟同步**：内置一键部署 `chrony` 工具，强力修复/对齐系统时间，彻底杜绝因时间误差导致的 Reality 或 TLS 握手失败（如 `certificate has expired` 错误）。
* **配置规范化接管**：内置**智能重构器 (Normalize Takeover)**，可无缝接管旧版不规范配置或手写配置。自动统一节点命名规范、修复数组/字符串混用问题，并重组路由表，实现版本平滑过渡。

## 💻 运行环境 (Requirements)

* **操作系统**: 推荐使用主流的 Debian 10+ / Ubuntu 20.04+ (基于 APT 包管理器)
* **系统权限**: 必须使用 `root` 用户执行
* **核心依赖**: `curl`, `jq`, `openssl` (脚本运行时会自动检测并安装缺失依赖)

## 🚀 快速开始 (Quick Start)

通过 SSH 登录到您的服务器，执行以下命令一键下载并启动管理菜单：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Tangfffyx/sing-box/refs/heads/main/sb.sh)
