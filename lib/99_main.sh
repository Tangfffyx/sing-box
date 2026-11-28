#!/usr/bin/env bash
# ============================================================
# 模块: 99_main.sh
# 职责: 主菜单 + CLI 入口路由
# 依赖: 所有其它模块
# ============================================================

main_menu() {
  ensure_local_script_entrypoint_once
  while true; do
    clear
    print_rect_title "Sing-box 管理面板  v${SCRIPT_VERSION}"
    singbox_dashboard_summary
    if ! has_cmd sing-box; then
      echo "  首次使用请选择「安装与卸载」安装 sing-box。"
    fi
    ui_hr
    ui_section "核心功能"
    echo -e "    ${C}1.${NC} 节点管理       ${D}安装 / 查看 / 删除协议节点${NC}"
    echo -e "    ${C}2.${NC} 中转管理       ${D}全流量转发 / 按网站分流中转${NC}"
    echo -e "    ${C}3.${NC} 用户管理       ${D}多用户管理 / 套餐限额 / 流量统计${NC}"
    echo -e "    ${C}4.${NC} 导出配置       ${D}通用链接 / Clash / QX${NC}"

    ui_section "系统维护"
    echo -e "    ${C}5.${NC} 安装与卸载     ${D}安装内核 / 检查更新 / 一键卸载${NC}"
    echo -e "    ${C}6.${NC} 系统工具       ${D}重启服务 / 实时日志${NC}"

    ui_section "扩展功能（可选）"
    echo -e "    ${C}7.${NC} WARP 分流      ${D}让选中的网站走 WARP${NC}"
    echo -e "    ${C}8.${NC} Telegram Bot   ${D}查流量 / 到期提醒 / 远程管理${NC}"
    echo ""
    echo -e "    ${D}0. 退出${NC}"
    ui_hr
    read -r -p "请选择操作: " opt || return 0
    case "${opt:-}" in
      1) protocol_manager || true ;;
      2) manage_relay_nodes || true ;;
      3) user_manager_menu || true ;;
      4) export_configs || true ;;
      5) install_and_uninstall_menu || true ;;
      6) system_tools_menu || true ;;
      7) warp_manager_menu || true ;;
      8) telegram_bot_manager_menu || true ;;
      0|q|Q) exit 0 ;;
      "") continue ;;
      *) warn "无效输入：$opt"; sleep 1 ;;
    esac
  done
}

# ====================================================
# CLI 入口路由
# ====================================================
if [[ "${1:-}" == "--periodic-sync" ]]; then
  periodic_sync_run
  exit 0
fi

if [[ "${1:-}" == "--daily-maintenance" ]]; then
  daily_maintenance_run
  exit 0
fi

# 6.0.8 及以前的 4 个老入口已合并到上面两个 runner。
# 保留为静默墓志铭，避免老 cron 跑过来掉进 main_menu 死循环 / 刷邮箱。
# is_install_complete 探针会在用户进入「安装与卸载」 时引导清理这些老 cron。
if [[ "${1:-}" == "--user-watch" ]] || [[ "${1:-}" == "--maintain-logs" ]] || \
   [[ "${1:-}" == "--tg-agent-sync" ]] || [[ "${1:-}" == "--refresh-upstream" ]]; then
  exit 0
fi

# 开机恢复 Hysteria2 端口跳跃规则（systemd 服务 / @reboot cron 调用，无交互）。
if [[ "${1:-}" == "--restore-hy2-hops" ]]; then
  hy2_hop_restore_all
  exit $?
fi

main_menu
