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
    print_rect_title "Sing-box Elite 管理系统  V${SCRIPT_VERSION}"
    singbox_status_summary
    echo -e "${B}--------------------------------------------------------${NC}"
    echo -e "  ${C}1.${NC} 安装/更新 sing-box"
    echo -e "  ${C}2.${NC} 系统工具"
    echo -e "  ${C}3.${NC} 协议管理"
    echo -e "  ${C}4.${NC} 中转管理"
    echo -e "  ${C}5.${NC} warp分流"
    echo -e "  ${C}6.${NC} 导出节点配置"
    echo -e "  ${C}7.${NC} 用户管理"
    echo -e "  ${C}8.${NC} 卸载 sing-box"
    echo -e "  ${R}0.${NC} 退出系统"
    echo -e "${B}--------------------------------------------------------${NC}"
    read -r -p "请选择操作指令: " opt
    case "${opt:-}" in
      1) install_or_update_singbox ;;
      2) system_tools_menu || true ;;
      3) protocol_manager || true ;;
      4) manage_relay_nodes || true ;;
      5) warp_manager_menu || true ;;
      6) export_configs || true ;;
      7) user_manager_menu || true ;;
      8) uninstall_singbox_keep_config ;;
      0|q|Q) exit 0 ;;
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
# is_install_complete 探针会在用户进 1.安装/更新 时引导清理这些老 cron。
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
