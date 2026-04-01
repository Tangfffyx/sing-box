#!/usr/bin/env bash

# Cron module extracted from sb.sh (Stage 1-2)

install_log_maintain_cron() {
  install_managed_cron_job "$LOG_MAINTAIN_CRON_MARK" "$LOG_MAINTAIN_CRON_SCHEDULE" "--maintain-logs"
}

remove_log_maintain_cron() {
  remove_managed_cron_job "$LOG_MAINTAIN_CRON_MARK"
}

install_user_watch_cron() {
  install_managed_cron_job "$USER_WATCH_CRON_MARK" "$USER_WATCH_CRON_SCHEDULE" "--user-watch"
}

remove_user_watch_cron() {
  remove_managed_cron_job "$USER_WATCH_CRON_MARK"
}

build_managed_cron_command() {
  local script_arg="$1"
  printf 'bash %s %s >/dev/null 2>&1' "$SB_TARGET_SCRIPT" "$script_arg"
}

install_managed_cron_job() {
  local mark="$1" schedule="$2" script_arg="$3"
  has_cmd crontab || return 1
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -F -v "$mark" > "$tmp" || true
  printf '%s %s\n' "$schedule" "$(build_managed_cron_command "$script_arg")" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
}

remove_managed_cron_job() {
  local mark="$1"
  has_cmd crontab || return 0
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -F -v "$mark" > "$tmp" || true
  if [ -s "$tmp" ]; then
    crontab "$tmp"
  else
    crontab -r 2>/dev/null || true
  fi
  rm -f "$tmp"
}

managed_cron_job_exists() {
  local mark="$1"
  has_cmd crontab || return 1
  crontab -l 2>/dev/null | grep -F "$mark" >/dev/null 2>&1
}

show_managed_cron_status() {
  local user_watch_status log_maintain_status
  if managed_cron_job_exists "$USER_WATCH_CRON_MARK"; then
    user_watch_status="已安装"
  else
    user_watch_status="未安装"
  fi
  if managed_cron_job_exists "$LOG_MAINTAIN_CRON_MARK"; then
    log_maintain_status="已安装"
  else
    log_maintain_status="未安装"
  fi
  echo -e "  用户巡检定时任务: ${user_watch_status}"
  echo -e "  日志维护定时任务: ${log_maintain_status}"
}

cron_jobs_menu() {
  while true; do
    clear
    print_rect_title "定时任务管理"
    show_managed_cron_status
    echo -e "${B}--------------------------------------------------------${NC}"
    echo -e "  ${C}1.${NC} 安装用户巡检定时任务"
    echo -e "  ${C}2.${NC} 移除用户巡检定时任务"
    echo -e "  ${C}3.${NC} 安装日志维护定时任务"
    echo -e "  ${C}4.${NC} 移除日志维护定时任务"
    echo -e "  ${C}5.${NC} 一键安装全部定时任务"
    echo -e "  ${C}6.${NC} 一键移除全部定时任务"
    echo -e "  ${R}0.${NC} 返回上一级"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) install_user_watch_cron && ok "用户巡检定时任务已安装。" || err "用户巡检定时任务安装失败。" ;;
      2) remove_user_watch_cron && ok "用户巡检定时任务已移除。" || err "用户巡检定时任务移除失败。" ;;
      3) install_log_maintain_cron && ok "日志维护定时任务已安装。" || err "日志维护定时任务安装失败。" ;;
      4) remove_log_maintain_cron && ok "日志维护定时任务已移除。" || err "日志维护定时任务移除失败。" ;;
      5)
        install_user_watch_cron && install_log_maintain_cron \
          && ok "全部定时任务安装完成。" \
          || err "一键安装失败，请检查 crontab 命令是否可用。"
        ;;
      6)
        remove_user_watch_cron && remove_log_maintain_cron \
          && ok "全部定时任务移除完成。" \
          || err "一键移除失败，请检查 crontab 命令是否可用。"
        ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act" ;;
    esac
    pause
  done
}


