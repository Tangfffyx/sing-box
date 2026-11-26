#!/usr/bin/env bash
# ============================================================
# 模块: 63_telegram_bot.sh
# 职责: Telegram Bot 配置、中心服务、节点上报、绑定链接
# 依赖: 00_base.sh, 01_utils.sh, 60_user_db.sh, 80_installer.sh
# ============================================================

tg_config_min_template() {
  cat <<'JSON'
{
  "enabled": false,
  "role": "",
  "bot_token": "",
  "bot_username": "",
  "admin_chat_ids": [],
  "listen_host": "0.0.0.0",
  "listen_port": 25888,
  "center_url": "",
  "access_secret": "",
  "vps_id": "",
  "vps_name": "",
  "notify_threshold": 90,
  "expire_warn_days": 3,
  "reports": {},
  "bindings": [],
  "pending_bind_tokens": {},
  "user_settings": {},
  "notify_state": {},
  "tasks": {},
  "pending_admin_actions": {},
  "waiting_inputs": {}
}
JSON
}

tg_config_load() {
  if [ -s "$TG_CONFIG_FILE" ]; then
    if jq -e 'type == "object"' "$TG_CONFIG_FILE" >/dev/null 2>&1; then
      cat "$TG_CONFIG_FILE"
      return 0
    fi
    backup_corrupt_json_file "$TG_CONFIG_FILE"
  fi
  tg_config_min_template
}

tg_config_save() {
  with_manager_lock _tg_config_save_body "$@"
}

_tg_config_save_body() {
  local json="$1"
  atomic_write_json_file "$TG_CONFIG_FILE" "$json" "Telegram 配置"
}

tg_task_receipts_load() {
  if [ -s "$TG_TASK_RECEIPTS_FILE" ]; then
    if jq -e 'type == "object"' "$TG_TASK_RECEIPTS_FILE" >/dev/null 2>&1; then
      cat "$TG_TASK_RECEIPTS_FILE"
      return 0
    fi
    backup_corrupt_json_file "$TG_TASK_RECEIPTS_FILE"
  fi
  echo '{"tasks":{}}'
}

# Setup 流程的"持锁原子提交" helper（6.1.6 起）。
# tg_setup_center / tg_setup_agent 在用户输入完字段后，函数体内的 cfg 已经是 5 分钟前 load 的快照，
# 整个写回去会覆盖期间 Python 端写入的 reports/tasks/bindings 等字段。
# 这里在 with_manager_lock 内 reload + merge + save，确保跨进程 RMW 原子。
_tg_setup_center_commit() {
  with_manager_lock _tg_setup_center_commit_body "$@"
}

_tg_setup_center_commit_body() {
  local token="$1" admin="$2" port="$3" url="$4" secret="$5" vps_id="$6" vps_name="$7" username="$8"
  local cfg
  cfg="$(tg_config_load)"
  cfg="$(echo "$cfg" | jq \
    --arg token "$token" \
    --arg admin "$admin" \
    --argjson port "$port" \
    --arg url "$url" \
    --arg secret "$secret" \
    --arg vps_id "$vps_id" \
    --arg vps_name "$vps_name" \
    --arg username "$username" '
      .enabled = true
      | .role = "center"
      | .bot_token = $token
      | .bot_username = $username
      | .admin_chat_ids = [$admin]
      | .listen_host = "0.0.0.0"
      | .listen_port = $port
      | .center_url = $url
      | .access_secret = $secret
      | .vps_id = $vps_id
      | .vps_name = $vps_name
    ')" || return 1
  _tg_config_save_body "$cfg"
}

_tg_setup_agent_commit() {
  with_manager_lock _tg_setup_agent_commit_body "$@"
}

_tg_setup_agent_commit_body() {
  local url="$1" secret="$2" vps_id="$3" vps_name="$4"
  local cfg
  cfg="$(tg_config_load)"
  cfg="$(echo "$cfg" | jq \
    --arg url "$url" \
    --arg secret "$secret" \
    --arg vps_id "$vps_id" \
    --arg vps_name "$vps_name" '
      .enabled = true
      | .role = "agent"
      | .center_url = $url
      | .access_secret = $secret
      | .vps_id = $vps_id
      | .vps_name = $vps_name
    ')" || return 1
  _tg_config_save_body "$cfg"
}

# 通用 RMW：持锁内 reload + 应用 jq 表达式 + save。避免 cfg 5+ 分钟前快照被整体写回时覆盖 Python 期间写入的字段。
# 用法：tg_config_merge_jq '<jq 表达式>' [jq --arg/--argjson 参数...]
tg_config_merge_jq() {
  with_manager_lock _tg_config_merge_jq_body "$@"
}

_tg_config_merge_jq_body() {
  local jq_expr="$1"
  shift
  local cfg
  cfg="$(tg_config_load)"
  cfg="$(echo "$cfg" | jq "$@" "$jq_expr")" || return 1
  _tg_config_save_body "$cfg"
}

# 专用 prune helper：reports 过期清理。fast-path 检测+实际写入都在同一把锁内，避免与 /api/report 并发写竞争。
_tg_prune_reports_with_lock() {
  with_manager_lock _tg_prune_reports_body "$@"
}

_tg_prune_reports_body() {
  local now="$1"
  local cfg removed pruned
  cfg="$(tg_config_load)"
  removed="$(echo "$cfg" | jq -r --argjson now "$now" '
    [(.reports // {}) | to_entries[] | select(($now - (.value.received_at // $now)) > 900)] | length
  ')" || return 1
  if [ "${removed:-0}" -le 0 ]; then
    echo 0
    return 0
  fi
  pruned="$(echo "$cfg" | jq --argjson now "$now" '
    .reports = ((.reports // {}) | with_entries(select(($now - (.value.received_at // $now)) <= 900)))
  ')" || return 1
  _tg_config_save_body "$pruned" || return 1
  echo "$removed"
}

tg_task_receipts_save() {
  local json="$1"
  atomic_write_json_file "$TG_TASK_RECEIPTS_FILE" "$json" "Telegram 任务回执"
}

tg_task_receipt_get() {
  local task_id="$1"
  [ -n "$task_id" ] || return 1
  tg_task_receipts_load | jq -c --arg id "$task_id" '.tasks[$id] // empty'
}

# 预留 receipt 占位：写入成功才允许执行任务，避免崩溃后无法识别已开过头的任务
tg_task_receipt_reserve() {
  local task_id="$1" now receipts
  [ -n "$task_id" ] || return 1
  now="$(date +%s)"
  receipts="$(tg_task_receipts_load | jq --arg id "$task_id" --argjson now "$now" '
    .tasks = (.tasks // {})
    | .tasks[$id] = {status:"running", started_at:$now}
    | .tasks |= with_entries(select(($now - (.value.completed_at // .value.started_at // $now)) <= 604800))
  ')" || return 1
  tg_task_receipts_save "$receipts"
}

# 任务执行结束后落盘最终结果；保存失败必须返回非零，由调用方决定是否上报主控
tg_task_receipt_finalize() {
  local task_id="$1" ok_value="$2" message="$3" now receipts ok_bool
  [ -n "$task_id" ] || return 1
  if [ "$ok_value" = "true" ]; then ok_bool="true"; else ok_bool="false"; fi
  now="$(date +%s)"
  receipts="$(tg_task_receipts_load | jq --arg id "$task_id" --arg message "$message" --argjson ok "$ok_bool" --argjson now "$now" '
    .tasks = (.tasks // {})
    | .tasks[$id] = {status:"done", ok:$ok, message:$message, completed_at:$now}
    | .tasks |= with_entries(select(($now - (.value.completed_at // .value.started_at // $now)) <= 604800))
  ')" || return 1
  tg_task_receipts_save "$receipts"
}

tg_config_enabled_value() {
  local cfg="$1"
  echo "$cfg" | jq -r '
    if has("enabled") then
      (.enabled == true)
    else
      ((.role // "") == "center" or (.role // "") == "agent")
    end
  '
}

tg_config_is_enabled() {
  local cfg="${1:-}"
  [ -n "$cfg" ] || cfg="$(tg_config_load)"
  [ "$(tg_config_enabled_value "$cfg")" = "true" ]
}

tg_mark_disabled_keep_config() {
  [ -s "$TG_CONFIG_FILE" ] || return 0
  tg_config_merge_jq '.enabled = false'
}

tg_generate_secret() {
  local raw
  raw="$(openssl rand -hex 16 2>/dev/null || true)"
  [ -n "$raw" ] || raw="$(date +%s%N | sha256sum | awk '{print $1}' | cut -c1-32)"
  echo "sb_tg_${raw}"
}

tg_normalize_url() {
  local url="${1:-}"
  url="${url%/}"
  echo "$url"
}

tg_api_request() {
  local token="$1" method="$2" payload="${3:-}"
  [ -n "$payload" ] || payload='{}'
  [ -n "$token" ] || return 1
  curl -fsS --connect-timeout 10 --max-time 20 \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.telegram.org/bot${token}/${method}"
}

tg_bot_username_from_token() {
  local token="$1" resp
  resp="$(tg_api_request "$token" "getMe" '{}')" || return 1
  echo "$resp" | jq -r '.result.username // empty'
}

tg_send_message() {
  local token="$1" chat_id="$2" text="$3"
  local payload
  [ -n "$chat_id" ] || return 1
  payload="$(jq -n --arg chat_id "$chat_id" --arg text "$text" \
    '{chat_id:$chat_id,text:$text,disable_web_page_preview:true}')"
  tg_api_request "$token" "sendMessage" "$payload" >/dev/null
}

tg_generate_vps_id() {
  local raw
  raw="$(openssl rand -hex 4 2>/dev/null || true)"
  [ -n "$raw" ] || raw="$(date +%s%N | sha256sum | awk '{print $1}' | cut -c1-8)"
  echo "node_${raw}"
}

tg_require_python3() {
  if has_cmd python3; then
    return 0
  fi
  warn "未检测到 python3，开始安装..."
  install_pkg python3
}

tg_write_center_app() {
  mkdir -p "$(dirname "$TG_CENTER_APP")"
  local repo_py=""
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    repo_py="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/py/tg_center_bot.py"
  fi
  if [ -n "$repo_py" ] && [ -f "$repo_py" ]; then
    cp -f "$repo_py" "$TG_CENTER_APP"
  else
    cat > "$TG_CENTER_APP" <<'PY'
# __EMBED_PY__:py/tg_center_bot.py
PY
  fi
  chmod 700 "$TG_CENTER_APP" >/dev/null 2>&1 || true
}

tg_install_center_service() {
  tg_require_python3 || return 1
  tg_write_center_app || return 1
  case "$INIT_SYSTEM" in
    systemd)
      cat > "/etc/systemd/system/${TG_CENTER_SERVICE}.service" <<EOF
[Unit]
Description=Sing-box Telegram Bot Center
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 ${TG_CENTER_APP} ${TG_CONFIG_FILE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable "$TG_CENTER_SERVICE" >/dev/null 2>&1 || true
      systemctl restart "$TG_CENTER_SERVICE"
      ;;
    openrc)
      cat > "/etc/init.d/${TG_CENTER_SERVICE}" <<EOF
#!/sbin/openrc-run
description="Sing-box Telegram Bot Center"
command="/usr/bin/env"
command_args="python3 ${TG_CENTER_APP} ${TG_CONFIG_FILE}"
command_background=true
pidfile="/run/${TG_CENTER_SERVICE}.pid"
depend() {
  need net
}
EOF
      chmod +x "/etc/init.d/${TG_CENTER_SERVICE}"
      openrc_enable_service "$TG_CENTER_SERVICE" default >/dev/null 2>&1 || true
      rc-service "$TG_CENTER_SERVICE" restart
      ;;
    *)
      err "未识别的 init 系统，无法安装主控服务。"
      return 1
      ;;
  esac
}

tg_stop_center_service() {
  case "$INIT_SYSTEM" in
    systemd)
      systemctl stop "$TG_CENTER_SERVICE" >/dev/null 2>&1 || true
      systemctl disable "$TG_CENTER_SERVICE" >/dev/null 2>&1 || true
      rm -f "/etc/systemd/system/${TG_CENTER_SERVICE}.service" >/dev/null 2>&1 || true
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      openrc_stop_service "$TG_CENTER_SERVICE" >/dev/null 2>&1 || true
      openrc_disable_service "$TG_CENTER_SERVICE" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/${TG_CENTER_SERVICE}" >/dev/null 2>&1 || true
      ;;
  esac
}

install_tg_agent_cron() {
  # 6.0.9 起 TG 上报已合并到 periodic-sync cron，无需独立 cron。
  # 函数保留为 no-op 以保持现有调用点兼容；TG 是否上报由 enabled 标记 + tg_agent_sync 内部自检决定。
  return 0
}
remove_tg_agent_cron()  { _remove_cron_job "$TG_AGENT_CRON_MARK"; }

tg_collect_report_json() {
  local cfg="$1" db_json
  db_json="$(user_db_load)"
  echo "$db_json" | jq \
    --arg vps_id "$(echo "$cfg" | jq -r '.vps_id // ""')" \
    --arg vps_name "$(echo "$cfg" | jq -r '.vps_name // ""')" \
    '
      {
        vps_id: $vps_id,
        vps_name: $vps_name,
        data_updated_at_text: (.meta.data_updated_at_text // ""),
        updated_at_text: (.meta.data_updated_at_text // ""),
        users: [
          .users
          | to_entries[]
          | {
              username: .key,
              enabled: (.value.enabled // false),
              disabled_reason: (.value.disabled_reason // null),
              quota_gb: (.value.quota_gb // 0),
              used_up_bytes: (.value.used_up_bytes // 0),
              used_down_bytes: (.value.used_down_bytes // 0),
              manual_added_bytes: (.value.manual_added_bytes // 0),
              last_reset_period: (.value.last_reset_period // ""),
              reset_day: (.value.reset_day // 0),
              expire_at: (.value.expire_at // "0")
            }
        ]
      }
    '
}

tg_center_api_post() {
  local url="$1" secret="$2" path="$3" payload="$4"
  curl -sS --connect-timeout 10 --max-time 20 \
    -H "Content-Type: application/json" \
    -H "X-SB-TG-Secret: ${secret}" \
    -d "$payload" \
    "${url%/}${path}"
}

tg_post_report() {
  local cfg="$1" center_url="$2" secret="$3" payload resp
  payload="$(tg_collect_report_json "$cfg")" || return 1
  resp="$(tg_center_api_post "$center_url" "$secret" "/api/report" "$payload" 2>/dev/null)" || return 1
  echo "$resp" | jq -e '.ok == true' >/dev/null 2>&1
}

tg_post_task_result() {
  local center_url="$1" secret="$2" task_id="$3" vps_id="$4" ok_value="$5" message="$6" payload
  payload="$(jq -n \
    --arg task_id "$task_id" \
    --arg vps_id "$vps_id" \
    --arg message "$message" \
    --argjson ok "$ok_value" \
    '{task_id:$task_id,vps_id:$vps_id,ok:$ok,message:$message}')"
  tg_center_api_post "$center_url" "$secret" "/api/tasks/result" "$payload" >/dev/null 2>&1 || true
}

tg_poll_tasks() {
  local center_url="$1" secret="$2" vps_id="$3" payload resp
  payload="$(jq -n --arg vps_id "$vps_id" '{vps_id:$vps_id}')"
  resp="$(tg_center_api_post "$center_url" "$secret" "/api/tasks/poll" "$payload" 2>/dev/null)" || return 1
  echo "$resp" | jq -c '.tasks // []'
}

tg_task_apply_db() {
  local new_db="$1" json
  json="$(config_load)" || return 1
  _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes "$new_db" "$json" >/dev/null 2>&1
}

tg_task_exec_set_enabled() {
  local db_json="$1" username="$2" enabled="$3" new_db
  if [ "$enabled" = "true" ]; then
    new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = true | .users[$u].disabled_reason = null')" || return 1
    tg_task_apply_db "$new_db" && echo "用户已启用。"
  else
    new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false | .users[$u].disabled_reason = "manual"')" || return 1
    tg_task_apply_db "$new_db" && echo "用户已停用。"
  fi
}

tg_task_exec_set_quota() {
  local db_json="$1" username="$2" quota="$3" new_db text
  [[ "$quota" =~ ^[0-9]+$ ]] || return 1
  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson quota "$quota" '.users[$u].quota_gb = $quota')" || return 1
  if [ "$quota" = "0" ]; then text="不限"; else text="${quota}GB"; fi
  tg_task_apply_db "$new_db" && echo "套餐已修改为 ${text}。"
}

tg_task_exec_renew() {
  local db_json="$1" username="$2" months="$3" current_expire today base_date expired=0 new_expire new_db
  [[ "$months" =~ ^[0-9]+$ ]] && [ "$months" -ge 1 ] || return 1
  current_expire="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].expire_at // "0"')"
  [ "$current_expire" != "0" ] || { echo "永久用户无需续期。"; return 1; }
  today="$(user_today_date)"
  if user_expire_is_past "$today" "$current_expire"; then
    expired=1
    base_date="$today"
  else
    base_date="$current_expire"
  fi
  new_expire="$(user_date_add_months "$base_date" "$months")" || return 1
  new_db="$(echo "$db_json" | jq --arg u "$username" --arg exp "$new_expire" --argjson expired "$expired" '
    .users[$u].expire_at = $exp
    | if $expired == 1 then
        .users[$u].used_up_bytes = 0
        | .users[$u].used_down_bytes = 0
        | .users[$u].manual_added_bytes = 0
        | .users[$u].last_reset_period = ""
        | if (.users[$u].disabled_reason // null) == "manual" then .
          else .users[$u].enabled = true | .users[$u].disabled_reason = null
          end
      else
        if (.users[$u].disabled_reason // null) == "expired" then
          .users[$u].enabled = true | .users[$u].disabled_reason = null
        else . end
      end
  ')" || return 1
  tg_task_apply_db "$new_db" && echo "已续期至 ${new_expire}。"
}

tg_task_exec_reset_usage() {
  local db_json="$1" username="$2" new_db
  new_db="$(echo "$db_json" | jq --arg u "$username" '
    .users[$u].used_up_bytes = 0
    | .users[$u].used_down_bytes = 0
    | .users[$u].manual_added_bytes = 0
  ')" || return 1
  tg_task_apply_db "$new_db" && echo "流量已重置。"
}

tg_task_exec_add_usage() {
  local db_json="$1" username="$2" bytes="$3" new_db
  [[ "$bytes" =~ ^-?[0-9]+$ ]] || return 1
  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson add "$bytes" '.users[$u].manual_added_bytes = ((.users[$u].manual_added_bytes // 0) + $add)')" || return 1
  tg_task_apply_db "$new_db" && echo "补正流量已更新：$(format_bytes_human "$bytes")。"
}

tg_task_exec_set_expire() {
  local db_json="$1" username="$2" expire_at="$3" today active new_db
  if [ "$expire_at" != "0" ] && ! is_valid_ymd_date "$expire_at"; then
    return 1
  fi
  today="$(user_today_date)"
  active=false
  if [ "$expire_at" = "0" ] || [[ "$today" < "$expire_at" ]]; then
    active=true
  fi
  new_db="$(echo "$db_json" | jq --arg u "$username" --arg exp "$expire_at" --argjson active "$active" '
    .users[$u].expire_at = $exp
    | if $active == true then
        if (.users[$u].disabled_reason // null) == "expired" then
          .users[$u].enabled = true | .users[$u].disabled_reason = null
        else . end
      else
        if (.users[$u].disabled_reason // null) == "manual" then .
        else .users[$u].enabled = false | .users[$u].disabled_reason = "expired"
        end
      end
  ')" || return 1
  tg_task_apply_db "$new_db" && echo "到期时间已修改为 $(expire_text "$expire_at")。"
}

tg_task_exec_set_reset_day() {
  local db_json="$1" username="$2" reset_day="$3" new_db
  [[ "$reset_day" =~ ^[0-9]+$ ]] || return 1
  if [ "$reset_day" != "0" ] && [ "$reset_day" != "32" ] && { [ "$reset_day" -lt 1 ] || [ "$reset_day" -gt 29 ]; }; then
    return 1
  fi
  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson reset "$reset_day" '
    (.users[$u].reset_day // 0) as $old_reset
    | .users[$u].reset_day = $reset
    | if ($old_reset != $reset) then .users[$u].last_reset_period = "" else . end
  ')" || return 1
  tg_task_apply_db "$new_db" && echo "重置日期已修改为 $(reset_day_text "$reset_day")。"
}

tg_execute_task() {
  with_manager_lock _tg_execute_task_body "$@"
}

_tg_execute_task_body() {
  local task="$1" action username db_json exists params result
  action="$(echo "$task" | jq -r '.action // empty')"
  username="$(echo "$task" | jq -r '.username // empty')"
  [ -n "$action" ] && [ -n "$username" ] || { echo "任务参数不完整。"; return 1; }
  user_db_exists || { echo "用户数据库不存在。"; return 1; }
  sync_user_usage_counters || return 1
  db_json="$(user_db_load)"
  exists="$(echo "$db_json" | jq -r --arg u "$username" 'if .users[$u] then "1" else "0" end')"
  [ "$exists" = "1" ] || { echo "用户不存在：$username"; return 1; }
  params="$(echo "$task" | jq -c '.params // {}')"
  case "$action" in
    set_enabled)
      tg_task_exec_set_enabled "$db_json" "$username" "$(echo "$params" | jq -r '.enabled // false')" ;;
    set_quota)
      tg_task_exec_set_quota "$db_json" "$username" "$(echo "$params" | jq -r '.quota_gb // empty')" ;;
    renew)
      tg_task_exec_renew "$db_json" "$username" "$(echo "$params" | jq -r '.months // empty')" ;;
    reset_usage)
      tg_task_exec_reset_usage "$db_json" "$username" ;;
    add_usage)
      tg_task_exec_add_usage "$db_json" "$username" "$(echo "$params" | jq -r '.bytes // empty')" ;;
    set_expire)
      tg_task_exec_set_expire "$db_json" "$username" "$(echo "$params" | jq -r '.expire_at // empty')" ;;
    set_reset_day)
      tg_task_exec_set_reset_day "$db_json" "$username" "$(echo "$params" | jq -r '.reset_day // empty')" ;;
    *)
      echo "不支持的任务类型：$action"
      return 1
      ;;
  esac
}

tg_process_tasks() {
  local cfg="$1" center_url="$2" secret="$3" vps_id="$4" tasks task task_id msg ok_value receipt receipt_status
  TG_TASKS_REPORTED_STATE=0
  tasks="$(tg_poll_tasks "$center_url" "$secret" "$vps_id")" || return 0
  echo "$tasks" | jq -e 'length > 0' >/dev/null 2>&1 || return 0
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    task_id="$(echo "$task" | jq -r '.id // empty')"
    [ -n "$task_id" ] || continue

    receipt="$(tg_task_receipt_get "$task_id" 2>/dev/null || true)"
    receipt_status="$(echo "${receipt:-}" | jq -r '.status // ""' 2>/dev/null || true)"

    if [ "$receipt_status" = "done" ]; then
      # 历史已完成任务：只重发结果，不再执行
      ok_value="$(echo "$receipt" | jq -r 'if (.ok // false) then "true" else "false" end')"
      msg="$(echo "$receipt" | jq -r '.message // "执行成功。"')"
    elif [ "$receipt_status" = "running" ]; then
      # 上一次执行后崩在落盘前；为安全起见不重复执行，标记失败让主控判断
      ok_value=false
      msg="任务上一次执行未完整落盘，已拒绝重复执行，请人工确认。"
      tg_task_receipt_finalize "$task_id" false "$msg" >/dev/null 2>&1 || true
    else
      # 新任务：先预留 receipt 占位，预留失败就拒绝执行（保证落盘可查）
      if ! tg_task_receipt_reserve "$task_id" >/dev/null 2>&1; then
        # 预留失败说明本地存储不可用，跳过本轮，等下次 poll 重试
        continue
      fi
      if msg="$(tg_execute_task "$task" 2>&1)"; then
        ok_value=true
      else
        ok_value=false
        [ -n "$msg" ] || msg="执行失败。"
      fi
      # 落盘最终结果；落盘失败时绝不上报成功
      if ! tg_task_receipt_finalize "$task_id" "$ok_value" "$msg" >/dev/null 2>&1; then
        warn "任务回执落盘失败：$task_id（不上报，等待下次重试）"
        continue
      fi
      if [ "$ok_value" = "true" ]; then
        tg_prepare_report_state
        if tg_post_report "$cfg" "$center_url" "$secret"; then
          TG_TASKS_REPORTED_STATE=1
        fi
      fi
    fi

    tg_post_task_result "$center_url" "$secret" "$task_id" "$vps_id" "$ok_value" "$msg"
  done < <(echo "$tasks" | jq -c '.[]')
}

tg_prepare_report_state() {
  if user_manager_reconcile_user_state >/dev/null 2>&1; then
    return 0
  fi
  sync_user_usage_counters >/dev/null 2>&1 || true
}

tg_agent_sync_once() {
  local cfg enabled role center_url secret vps_id
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  [ "$enabled" = "true" ] || return 1
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$role" = "center" ] || [ "$role" = "agent" ] || return 1
  user_db_exists || return 1
  if [ "$role" = "center" ]; then
    center_url="http://127.0.0.1:$(echo "$cfg" | jq -r '.listen_port // 25888')"
  else
    center_url="$(echo "$cfg" | jq -r '.center_url // empty')"
  fi
  secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  vps_id="$(echo "$cfg" | jq -r '.vps_id // empty')"
  [ -n "$center_url" ] && [ -n "$secret" ] || return 1
  [ -n "$vps_id" ] || return 1
  tg_process_tasks "$cfg" "$center_url" "$secret" "$vps_id" || true
  if [ "${TG_TASKS_REPORTED_STATE:-0}" != "1" ]; then
    tg_prepare_report_state
    tg_post_report "$cfg" "$center_url" "$secret" || return 1
  fi
}

tg_agent_poll_tasks_once() {
  local cfg enabled role center_url secret vps_id
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  [ "$enabled" = "true" ] || return 1
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$role" = "center" ] || [ "$role" = "agent" ] || return 1
  user_db_exists || return 1
  if [ "$role" = "center" ]; then
    center_url="http://127.0.0.1:$(echo "$cfg" | jq -r '.listen_port // 25888')"
  else
    center_url="$(echo "$cfg" | jq -r '.center_url // empty')"
  fi
  secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  vps_id="$(echo "$cfg" | jq -r '.vps_id // empty')"
  [ -n "$center_url" ] && [ -n "$secret" ] && [ -n "$vps_id" ] || return 1
  tg_process_tasks "$cfg" "$center_url" "$secret" "$vps_id" || true
}

tg_agent_sync_now() {
  local cfg lock_fd lock_dir i rc=1
  cfg="$(tg_config_load)"
  tg_config_is_enabled "$cfg" || return 1
  mkdir -p "$(dirname "$TG_AGENT_LOCK_FILE")" 2>/dev/null || true
  if has_cmd flock && { exec {lock_fd}>"$TG_AGENT_LOCK_FILE"; } 2>/dev/null; then
    if ! flock -w 5 "$lock_fd"; then
      { exec {lock_fd}>&-; } 2>/dev/null || true
      return 1
    fi
  else
    lock_fd=""
    lock_dir="${TG_AGENT_LOCK_FILE}.d"
    if ! mkdir "$lock_dir" 2>/dev/null; then
      sleep 1
      mkdir "$lock_dir" 2>/dev/null || return 1
    fi
  fi
  for i in 1 2 3; do
    if tg_agent_sync_once; then
      rc=0
      break
    fi
    sleep 1
  done
  if [ -n "$lock_fd" ]; then
    { exec {lock_fd}>&-; } 2>/dev/null || true
  else
    rmdir "${TG_AGENT_LOCK_FILE}.d" 2>/dev/null || true
  fi
  return $rc
}

tg_agent_sync() {
  local cfg lock_fd lock_dir i
  cfg="$(tg_config_load)"
  tg_config_is_enabled "$cfg" || return 0
  mkdir -p "$(dirname "$TG_AGENT_LOCK_FILE")" 2>/dev/null || true
  if has_cmd flock && { exec {lock_fd}>"$TG_AGENT_LOCK_FILE"; } 2>/dev/null; then
    flock -n "$lock_fd" || { exec {lock_fd}>&-; return 0; }
  else
    lock_fd=""
    lock_dir="${TG_AGENT_LOCK_FILE}.d"
    mkdir "$lock_dir" 2>/dev/null || return 0
  fi
  for i in 1 2 3 4 5 6; do
    if [ "$i" = "1" ]; then
      tg_agent_sync_once >/dev/null 2>&1 || true
    else
      tg_agent_poll_tasks_once >/dev/null 2>&1 || true
    fi
    [ "$i" -lt 6 ] && sleep 10
  done
  [ -n "${lock_fd:-}" ] && exec {lock_fd}>&-
  [ -n "${lock_dir:-}" ] && rmdir "$lock_dir" 2>/dev/null || true
}

tg_refresh_after_singbox_install() {
  local cfg enabled role
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$enabled" = "true" ] || return 0
  [ "$role" = "center" ] || [ "$role" = "agent" ] || return 0

  if [ "$role" = "center" ]; then
    if ! tg_install_center_service; then
      warn "TG Bot 服务刷新失败，请稍后进入 TG Bot 管理检查。"
      return 0
    fi
  fi
  install_tg_agent_cron >/dev/null 2>&1 || warn "TG Bot 上报任务刷新失败。"
  if tg_agent_sync_now; then
    ok "TG Bot 已刷新，本机数据已立即上报。"
  else
    warn "TG Bot 已刷新，但本机立即上报失败，定时任务会继续自动上报。"
  fi
}

tg_start_existing_config() {
  local cfg role
  cfg="$(tg_config_load)"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$role" = "center" ] || [ "$role" = "agent" ] || { warn "未找到可启动的 TG Bot 配置。"; return 1; }
  if [ "$role" = "center" ]; then
    tg_install_center_service || { err "主控服务启动失败。"; return 1; }
  fi
  install_tg_agent_cron || { err "TG 节点上报定时任务安装失败。"; return 1; }
  tg_config_merge_jq '.enabled = true' || { err "TG Bot 配置保存失败。"; return 1; }
  if tg_agent_sync_now; then
    ok "TG Bot 已启动，本机数据已立即上报。"
  else
    warn "TG Bot 已启动，但首次上报失败，请检查服务状态或稍后再试。"
  fi
}

tg_setup_center() {
  local cfg token admin_id port public_url secret vps_id vps_name username
  local cur_token cur_admin cur_port cur_vps_name cur_username
  cfg="$(tg_config_load)"
  cur_token="$(echo "$cfg" | jq -r '.bot_token // empty')"
  cur_admin="$(echo "$cfg" | jq -r '.admin_chat_ids[0] // empty')"
  cur_port="$(echo "$cfg" | jq -r '.listen_port // empty')"
  cur_vps_name="$(echo "$cfg" | jq -r '.vps_name // empty')"
  cur_username="$(echo "$cfg" | jq -r '.bot_username // empty')"

  # Bot Token（敏感字段不显示当前值）
  if [ -n "$cur_token" ]; then
    read -r -p "Bot Token（回车保持当前值）: " token
    [ -n "$token" ] || token="$cur_token"
  else
    read -r -p "Bot Token（回车返回）: " token
    [ -n "$token" ] || { warn "Bot Token 不能为空。"; pause; return 1; }
  fi

  # 管理员 TG ID（敏感字段不显示当前值）
  if [ -n "$cur_admin" ]; then
    read -r -p "管理员 TG ID（回车保持当前值）: " admin_id
    [ -n "$admin_id" ] || admin_id="$cur_admin"
  else
    read -r -p "管理员 TG ID（回车返回）: " admin_id
  fi
  [[ "$admin_id" =~ ^[0-9]+$ ]] || { warn "管理员 TG ID 必须是数字。"; pause; return 1; }

  # 主控监听端口（非敏感，显示当前值/默认值）
  if [ -n "$cur_port" ]; then
    read -r -p "主控监听端口（回车保持当前值: ${cur_port}）: " port
    port="${port:-$cur_port}"
  else
    read -r -p "主控监听端口（默认: 25888）: " port
    port="${port:-25888}"
  fi
  is_valid_port "$port" || { warn "端口无效。"; pause; return 1; }

  # 本机名称（非敏感，显示当前值）
  if [ -n "$cur_vps_name" ]; then
    read -r -p "本机名称（支持中文，回车保持当前值: ${cur_vps_name}）: " vps_name
    [ -n "$vps_name" ] || vps_name="$cur_vps_name"
  else
    read -r -p "本机名称（支持中文，回车返回）: " vps_name
    [ -n "$vps_name" ] || { warn "本机名称不能为空。"; pause; return 1; }
  fi

  public_url="$(tg_normalize_url "http://$(get_public_ip):${port}")"
  # Token 没变时复用已存的 bot_username，跳过在线校验 API
  if [ "$token" = "$cur_token" ] && [ -n "$cur_username" ]; then
    username="$cur_username"
  else
    username="$(tg_bot_username_from_token "$token")" || username=""
    [ -n "$username" ] || { warn "Bot Token 校验失败，无法获取 Bot 用户名。"; pause; return 1; }
  fi
  secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  [ -n "$secret" ] || secret="$(tg_generate_secret)"
  vps_id="$(echo "$cfg" | jq -r '.vps_id // empty')"
  [ -n "$vps_id" ] || vps_id="$(tg_generate_vps_id)"
  if ! _tg_setup_center_commit "$token" "$admin_id" "$port" "$public_url" "$secret" "$vps_id" "$vps_name" "$username"; then
    err "TG Bot 配置保存失败。"
    pause
    return 1
  fi
  tg_install_center_service || { err "主控服务安装失败。"; pause; return 1; }
  install_tg_agent_cron || warn "TG 节点上报定时任务安装失败。"
  if tg_agent_sync_now; then
    ok "本机数据已立即上报。"
  else
    warn "TG Bot 已配置，但首次上报失败，请检查服务状态或稍后再试。"
  fi
  ok "主控节点已配置。"
  param_echo "主控地址" "$public_url"
  param_echo "接入密钥" "$secret"
  param_echo "Bot 用户名" "@${username}"
  pause
}

tg_setup_agent() {
  local cfg center_url secret vps_id vps_name
  local cur_url cur_secret cur_vps_name
  cfg="$(tg_config_load)"
  cur_url="$(echo "$cfg" | jq -r '.center_url // empty')"
  cur_secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  cur_vps_name="$(echo "$cfg" | jq -r '.vps_name // empty')"

  # 主控地址（非敏感，显示当前值）
  if [ -n "$cur_url" ]; then
    read -r -p "主控地址（回车保持当前值: ${cur_url}）: " center_url
    [ -n "$center_url" ] || center_url="$cur_url"
  else
    read -r -p "主控地址（回车返回）: " center_url
  fi
  center_url="$(tg_normalize_url "$center_url")"
  [ -n "$center_url" ] || { warn "主控地址不能为空。"; pause; return 1; }

  # 接入密钥（敏感字段不显示当前值）
  if [ -n "$cur_secret" ]; then
    read -r -p "接入密钥（回车保持当前值）: " secret
    [ -n "$secret" ] || secret="$cur_secret"
  else
    read -r -p "接入密钥（回车返回）: " secret
    [ -n "$secret" ] || { warn "接入密钥不能为空。"; pause; return 1; }
  fi

  # 本机名称（非敏感，显示当前值）
  if [ -n "$cur_vps_name" ]; then
    read -r -p "本机名称（支持中文，回车保持当前值: ${cur_vps_name}）: " vps_name
    [ -n "$vps_name" ] || vps_name="$cur_vps_name"
  else
    read -r -p "本机名称（支持中文，回车返回）: " vps_name
    [ -n "$vps_name" ] || { warn "本机名称不能为空。"; pause; return 1; }
  fi

  vps_id="$(echo "$cfg" | jq -r '.vps_id // empty')"
  [ -n "$vps_id" ] || vps_id="$(tg_generate_vps_id)"
  if ! _tg_setup_agent_commit "$center_url" "$secret" "$vps_id" "$vps_name"; then
    err "TG Bot 配置保存失败。"
    pause
    return 1
  fi
  install_tg_agent_cron || { err "TG 节点上报定时任务安装失败。"; pause; return 1; }
  if tg_agent_sync_now; then
    ok "本机数据已立即上报。"
  else
    warn "已保存配置，但首次上报失败，请检查主控地址、接入密钥或防火墙。"
  fi
  ok "普通节点已配置。"
  pause
}

tg_setup_menu() {
  local cfg enabled role ans
  clear
  print_rect_title "设置/启动TG Bot"
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  if [ "$enabled" != "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; }; then
    read -r -p "检测到已保留配置，是否直接启动？[Y/n]: " ans
    case "${ans:-Y}" in
      [Nn]*) ;;
      *)
        tg_start_existing_config
        pause
        return
        ;;
    esac
  fi
  echo "  1. 主控节点"
  echo "  2. 普通节点"
  echo "  0. 返回上一级"
  read -r -p "请选择本机模式: " role
  case "${role:-}" in
    1) tg_setup_center ;;
    2) tg_setup_agent ;;
    0|q|Q|"") return 0 ;;
    *) warn "无效输入：$role"; pause ;;
  esac
}

tg_generate_bind_link_menu() {
  local cfg enabled role center_url secret db_json usernames=() ans username payload resp link
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$enabled" = "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; } || { warn "请先设置/启动TG Bot。"; pause; return 0; }
  user_db_exists || { warn "用户数据库不存在，请先安装并创建用户。"; pause; return 0; }
  db_json="$(user_db_load)"
  mapfile -t usernames < <(echo "$db_json" | jq -r '.users | keys[] | select(. != "admin")')
  [ ${#usernames[@]} -gt 0 ] || { warn "当前没有可绑定的普通用户。"; pause; return 0; }
  clear
  print_rect_title "生成绑定链接"
  local i=1
  for username in "${usernames[@]}"; do
    echo " [$i] $username"
    i=$((i+1))
  done
  read -r -p "请选择用户（回车返回上一级）: " ans
  [ -z "${ans:-}" ] && return 0
  if ! [[ "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt "${#usernames[@]}" ]; then
    warn "无效输入：$ans"
    pause
    return 0
  fi
  username="${usernames[$((ans-1))]}"
  if [ "$role" = "center" ]; then
    center_url="http://127.0.0.1:$(echo "$cfg" | jq -r '.listen_port // 25888')"
  else
    center_url="$(echo "$cfg" | jq -r '.center_url // empty')"
  fi
  secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  payload="$(echo "$cfg" | jq -n \
    --arg vps_id "$(echo "$cfg" | jq -r '.vps_id // empty')" \
    --arg vps_name "$(echo "$cfg" | jq -r '.vps_name // empty')" \
    --arg username "$username" \
    '{vps_id:$vps_id,vps_name:$vps_name,username:$username}')"
  resp="$(tg_center_api_post "$center_url" "$secret" "/api/bind-token" "$payload" 2>/dev/null || true)"
  link="$(echo "$resp" | jq -r '.link // empty' 2>/dev/null || true)"
  if [ -n "$link" ]; then
    ok "绑定链接已生成，有效期 10 分钟。"
    param_echo "用户" "$username"
    param_echo "链接" "$link"
  else
    err "绑定链接生成失败，请检查主控服务和接入密钥。"
  fi
  pause
}

tg_notify_test() {
  local cfg enabled role center_url secret payload resp ok_value err_msg
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  [ "$enabled" = "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; } || { warn "请先设置/启动TG Bot。"; pause; return 0; }
  if [ "$role" = "center" ]; then
    center_url="http://127.0.0.1:$(echo "$cfg" | jq -r '.listen_port // 25888')"
    secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  else
    center_url="$(echo "$cfg" | jq -r '.center_url // empty')"
    secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  fi
  payload="$(echo "$cfg" | jq -n \
    --arg vps_id "$(echo "$cfg" | jq -r '.vps_id // empty')" \
    --arg vps_name "$(echo "$cfg" | jq -r '.vps_name // empty')" \
    '{vps_id:$vps_id,vps_name:$vps_name}')"
  resp="$(tg_center_api_post "$center_url" "$secret" "/api/test" "$payload" 2>/dev/null || true)"
  ok_value="$(echo "$resp" | jq -r '.ok // false' 2>/dev/null || echo false)"
  if [ "$ok_value" = "true" ]; then
    ok "通知测试已发送到管理员。"
  else
    err_msg="$(echo "$resp" | jq -r '(.errors // []) | join("; ")' 2>/dev/null || true)"
    [ -n "$err_msg" ] || err_msg="请检查主控服务、Bot Token、管理员 TG ID，且管理员需先向 Bot 发送 /start。"
    err "通知测试失败：$err_msg"
  fi
  pause
}

tg_prune_offline_reports() {
  local now
  now="$(date +%s)"
  _tg_prune_reports_with_lock "$now"
}

tg_reload_center_service_menu() {
  local cfg enabled role pruned_count
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  if [ "$enabled" != "true" ] || [ "$role" != "center" ]; then
    warn "只有已启动的主控节点需要重启/刷新 TG Bot 服务。"
    pause
    return 1
  fi
  tg_install_center_service || { err "TG Bot 服务重启/刷新失败。"; pause; return 1; }
  install_tg_agent_cron >/dev/null 2>&1 || true
  if tg_agent_sync_now; then
    ok "TG Bot 服务已重启刷新，本机数据已立即上报。"
  else
    ok "TG Bot 服务已重启刷新。"
    warn "本机立即上报失败，定时任务会继续自动上报。"
  fi
  pruned_count="$(tg_prune_offline_reports 2>/dev/null || echo 0)"
  if [ "${pruned_count:-0}" -gt 0 ]; then
    ok "已隐藏 ${pruned_count} 个已下线节点。"
  fi
  pause
}

tg_disable_menu() {
  clear
  print_rect_title "卸载/停止TG Bot"
  warn "该操作将停止 TG Bot 服务和上报任务。"
  local keep_cfg
  read -r -p "是否保留 TG Bot 配置？[Y/n]: " keep_cfg
  remove_tg_agent_cron || true
  tg_stop_center_service || true
  rm -f "$TG_CENTER_APP" >/dev/null 2>&1 || true
  rmdir "${TG_AGENT_LOCK_FILE}.d" >/dev/null 2>&1 || true
  case "${keep_cfg:-Y}" in
    [Nn]*)
      rm -f "$TG_CONFIG_FILE" >/dev/null 2>&1 || true
      ok "TG Bot 已停止，配置已删除。"
      ;;
    *)
      tg_mark_disabled_keep_config || warn "TG Bot 配置状态保存失败。"
      ok "TG Bot 已停止，配置已保留。"
      ;;
  esac
  pause
}

telegram_bot_manager_menu() {
  while true; do
    clear
    print_rect_title "Telegram Bot 管理"
    local cfg enabled role role_label vps_name center_url access_secret
    cfg="$(tg_config_load)"
    enabled="$(tg_config_enabled_value "$cfg")"
    role="$(echo "$cfg" | jq -r '.role // "未设置"')"
    vps_name="$(echo "$cfg" | jq -r '.vps_name // ""')"
    center_url="$(echo "$cfg" | jq -r '.center_url // ""')"
    access_secret="$(echo "$cfg" | jq -r '.access_secret // ""')"
    if [ "$enabled" = "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; }; then
      install_tg_agent_cron >/dev/null 2>&1 || true
    fi
    case "$role" in
      center) role_label="主控节点" ;;
      agent) role_label="普通节点" ;;
      ""|"未设置") role_label="未设置" ;;
      *) role_label="$role" ;;
    esac
    if [ "$enabled" != "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; }; then
      role_label="${role_label}（已停止）"
    fi
    echo "当前模式：$role_label"
    [ -n "$vps_name" ] && echo "本机名称：$vps_name"
    [ -n "$center_url" ] && echo "主控地址：$center_url"
    if [ "$role" = "center" ] && [ -n "$access_secret" ]; then
      echo "接入密钥：$access_secret"
    fi
    echo -e "${B}--------------------------------------------------------${NC}"
    echo "  1. 设置/启动TG Bot"
    echo "  2. 生成用户绑定链接"
    echo "  3. 通知测试"
    if [ "$enabled" = "true" ] && [ "$role" = "center" ]; then
      echo "  4. 重启/刷新TG Bot"
      echo "  5. 卸载/停止TG Bot"
    else
      echo "  4. 卸载/停止TG Bot"
    fi
    echo "  0. 返回上一级"
    local act
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) tg_setup_menu ;;
      2) tg_generate_bind_link_menu ;;
      3) tg_notify_test ;;
      4)
        if [ "$enabled" = "true" ] && [ "$role" = "center" ]; then
          tg_reload_center_service_menu
        else
          tg_disable_menu
        fi
        ;;
      5)
        if [ "$enabled" = "true" ] && [ "$role" = "center" ]; then
          tg_disable_menu
        else
          warn "无效输入：$act"; sleep 1
        fi
        ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
