#!/usr/bin/env bash
# ============================================================
# 模块: 61_user_manager.sh
# 职责: 用户管理业务逻辑（投影、同步、自动控制）
# 依赖: 00_base.sh, 10_config.sh, 20_protocol.sh, 30_route.sh,
#       50_v2ray_api.sh, 60_user_db.sh
# ============================================================

migrate_socks_user_object_for_desired() {
  local inbound="$1" desired="$2" entry_key="$3"
  [ "$(user_node_part "$desired")" = "$entry_key" ] || return 1
  local business_user
  business_user="$(user_business_name "$desired")"
  echo "$inbound" | jq -c --arg desired "$desired" --arg biz "$business_user" '
    def node_part($u): if ($u | contains("@")) then ($u | split("@")[0]) else $u end;
    def business($u): if ($u | contains("@")) then ($u | split("@")[1]) else "admin" end;
    [
      (.users // [])[]?
      | (.username // "") as $u
      | select($u != "")
      | select(((node_part($u) | contains("-to-")) | not))
      | select(business($u) == $biz)
      | .username = $desired
    ][0] // empty
  '
}

user_manager_apply_to_json() {
  local json="$1" db_json="$2" meta_json="${3:-}"
  local work_json="$json"
  local inv_lines=() line idx entry_key proto port inbound
  work_json="$(config_normalize "$work_json")" || return 1
  mapfile -t inv_lines < <(protocol_entry_inventory_ext "$work_json")
  for line in "${inv_lines[@]}"; do
    IFS=$'\x01' read -r idx entry_key proto port <<< "$line"
    inbound="$(find_inbound_by_entry_key "$work_json" "$entry_key")"
    [ -n "$inbound" ] || continue

    local relay_nodes=() relay_node
    mapfile -t relay_nodes < <(echo "$inbound" | jq -r '.users[]? | (.name // .username // empty)' | while IFS= read -r n; do
      [ -n "$n" ] || continue
      np="$(user_node_part "$n")"
      if [[ "$np" == *"-to-"* && "$np" != "$entry_key" ]]; then
        echo "$np"
      fi
    done | sort -u)

    local credential_base_name="$entry_key"

    local desired_names=()
    if [ "$proto" != "socks" ] || user_db_user_is_enabled "$db_json" "admin"; then
      desired_names+=("$credential_base_name")
    fi
    local username
    while IFS= read -r username; do
      [ -n "$username" ] || continue
      [ "$username" = "admin" ] && continue
      if [ "$proto" = "socks" ] && ! user_db_user_is_enabled "$db_json" "$username"; then
        continue
      fi
      if user_db_user_allow_node "$db_json" "$username" "$entry_key"; then
        desired_names+=("$(node_user_name "$credential_base_name" "$username")")
      fi
    done < <(user_db_all_users "$db_json")

    for relay_node in "${relay_nodes[@]}"; do
      desired_names+=("$relay_node")
      while IFS= read -r username; do
        [ -n "$username" ] || continue
        [ "$username" = "admin" ] && continue
        if [ "$proto" = "socks" ] && ! user_db_user_is_enabled "$db_json" "$username"; then
          continue
        fi
        if user_db_user_allow_node "$db_json" "$username" "$relay_node"; then
          desired_names+=("$(node_user_name "$relay_node" "$username")")
        fi
      done < <(user_db_all_users "$db_json")
    done

    local users_tmp
    users_tmp="$(mktemp)"
    local desired full_name existing_obj new_obj
    for desired in "${desired_names[@]}"; do
      existing_obj="$(find_user_obj_in_inbound "$inbound" "$desired")"
      if [ -z "$existing_obj" ] && [ "$proto" = "socks" ]; then
        existing_obj="$(migrate_socks_user_object_for_desired "$inbound" "$desired" "$entry_key" || true)"
      fi
      if [ -n "$existing_obj" ]; then
        echo "$existing_obj" >> "$users_tmp"
      else
        new_obj="$(build_user_object_from_inbound "$inbound" "$desired")" || {
          rm -f "$users_tmp"
          return 1
        }
        echo "$new_obj" >> "$users_tmp"
      fi
    done
    local users_json='[]'
    if [ -s "$users_tmp" ]; then
      users_json="$(jq -s '.' "$users_tmp")"
    fi
    rm -f "$users_tmp" >/dev/null 2>&1 || true
    work_json="$(echo "$work_json" | jq --argjson idx "$idx" --argjson users "$users_json" '.inbounds[$idx].users = $users')" || return 1
  done

  if [ -n "$meta_json" ]; then
    work_json="$(route_rebuild "$work_json" "$meta_json")" || return 1
  else
    work_json="$(route_rebuild "$work_json")" || return 1
  fi
  work_json="$(filter_disabled_auth_users "$work_json" "$db_json")" || return 1
  ensure_v2ray_api_on_json "$work_json" || return 1
}

filter_disabled_auth_users() {
  local json="$1" db_json="$2"
  local enabled_json
  enabled_json="$(echo "$db_json" | jq -c '[.users | to_entries[] | select(.value.enabled == true) | .key]')"
  echo "$json" | jq "${JQ_AUTH_USERS}"'
    def user_enabled($u):
      if ($u | contains("@")) then ($enabled | index(($u | split("@")[1]))) != null
      else ($enabled | index("admin")) != null
      end;

    .route.rules |= map(
      if (.auth_user? == null) then .
      else
        (auth_users_array | map(select(user_enabled(.)))) as $remain
        | if ($remain | length) == 0 then empty
          elif ($remain | length) == 1 then .auth_user = $remain[0]
          else .auth_user = $remain
          end
      end
    )
  ' --argjson enabled "$enabled_json"
}

# 菜单传入前后快照用于提取字段补丁；在锁内将补丁合并到最新数据。
# 同字段被其他管理操作修改时拒绝提交，避免无声覆盖。
merge_user_edit() {
  local current="$1" before="$2" after="$3" mode="${4:-edit}" target="${5:-}"
  printf '%s' "$current" | jq --argjson before "$before" --argjson after "$after" --arg mode "$mode" --arg target "$target" '
    def policy: del(.used_up_bytes,.used_down_bytes,.last_live_up_bytes,.last_live_down_bytes,.manual_added_bytes);
    reduce ((($before.users|keys) + ($after.users|keys)) | unique[]) as $u (. ;
      ($before.users[$u]) as $old | ($after.users[$u]) as $new
      | if $old == null then
          if .users[$u] != null then error("用户已被其他操作创建: " + $u) else .users[$u]=$new end
        elif $new == null then
          if .users[$u] == null then .
          elif ((.users[$u]|policy) != ($old|policy)) then error("用户状态已变化，请重新确认删除: " + $u)
          else del(.users[$u]) end
        else
          ([$new|keys[] | select(. != "used_up_bytes" and . != "used_down_bytes" and . != "last_live_up_bytes" and . != "last_live_down_bytes")
            | . as $f | select($new[$f] != $old[$f])]) as $fields
          | if ($fields|length) == 0 and ($u != $target or $mode != "reset") then .
            elif .users[$u] == null then error("用户已被删除: " + $u)
            else reduce $fields[] as $f (. ;
              if $f == "manual_added_bytes" and $mode == "add" then
                .users[$u][$f] = ((.users[$u][$f] // 0) + ($new[$f] // 0) - ($old[$f] // 0))
              elif $f == "manual_added_bytes" and $mode == "reset" then .
              elif .users[$u][$f] != $old[$f] then error("字段已被其他操作修改: " + $u + "." + $f)
              else .users[$u][$f]=$new[$f] end)
            end
        end)
    | if $mode == "reset" then
        if .users[$target] == null then error("用户不存在") else
          .users[$target].used_up_bytes=0 | .users[$target].used_down_bytes=0 | .users[$target].manual_added_bytes=0
        end
      else . end
  '
}

user_manager_commit_edit() {
  with_manager_lock _user_manager_commit_edit_body "$@"
}

_user_manager_commit_edit_body() {
  local before="$1" after="$2" mode="${3:-edit}" target="${4:-}" merged
  sync_user_usage_counters || return 1
  merged="$(merge_user_edit "$(user_db_load)" "$before" "$after" "$mode" "$target")" || {
    err "数据已变化或输入无效，请重新打开菜单后操作。"
    return 1
  }
  _user_manager_apply_changes_body "$merged"
}

user_manager_apply_changes() {
  with_manager_lock _user_manager_apply_changes_body "$@"
}

_user_manager_apply_changes_body() {
  local db_json="$1" base_json="${2:-}" meta_json="${3:-}"
  if [ "${_USER_KEEP_LATEST_DB:-0}" = "1" ]; then
    sync_user_usage_counters || return 1
    db_json="$(user_db_load)"
  fi
  [ -n "$base_json" ] || base_json="$(config_load)"

  db_json="$(user_db_cleanup_missing_nodes "$db_json" "$base_json")" || return 1

  local applied_json
  applied_json="$(user_manager_apply_to_json "$base_json" "$db_json" "$meta_json")" || {
    err "生成用户节点关系失败。"
    return 1
  }

  local old_db_json="" had_db=0
  if user_db_exists; then
    old_db_json="$(user_db_load)"
    had_db=1
  fi
  # 抓 old_config 用于 meta_save 失败时回滚（即使调用方没传 meta_json 也无害——下面只在传了时才用）
  local old_config_json
  old_config_json="$(config_load 2>/dev/null)" || old_config_json='{}'

  user_db_save "$db_json" || {
    err "用户数据库保存失败，已阻止配置变更。"
    return 1
  }

  if ! _CONFIG_APPLY_QUIET_OK=1 config_apply_no_usage_sync "$applied_json"; then
    # config 失败，回滚 user_db
    if [ "$had_db" = "1" ]; then
      user_db_save "$old_db_json" || warn "配置应用失败，且用户数据库回滚失败，请手动检查：$USER_DB_FILE"
    else
      rm -f "$USER_DB_FILE" >/dev/null 2>&1 || warn "配置应用失败，且用户数据库清理失败，请手动检查：$USER_DB_FILE"
    fi
    return 1
  fi

  # config 已成功，提交 meta（如果调用方传了 meta_json）
  if [ -n "$meta_json" ]; then
    if ! meta_save "$meta_json"; then
      err "元数据保存失败，正在回滚配置和用户数据库..."
      _CONFIG_APPLY_QUIET_OK=1 _CONFIG_SKIP_USAGE_SYNC=1 config_apply "$old_config_json" \
        || err "回滚配置失败，请手动检查 $CONFIG_FILE"
      if [ "$had_db" = "1" ]; then
        user_db_save "$old_db_json" || warn "用户数据库回滚失败，请手动检查 $USER_DB_FILE"
      else
        rm -f "$USER_DB_FILE" >/dev/null 2>&1 || warn "用户数据库清理失败：$USER_DB_FILE"
      fi
      return 1
    fi
  fi

  [ "${_USER_MANAGER_APPLY_QUIET_OK:-0}" = "1" ] || ok "用户变更已应用。"
  return 0
}

user_manager_runtime_sync() {
  local db_json current_json desired_json current_norm desired_norm
  db_json="$(user_db_load)"
  if [ ! -s "$USER_DB_FILE" ]; then
    user_db_save "$db_json" || return 1
  fi

  current_json="$(config_load)"
  desired_json="$(user_manager_apply_to_json "$current_json" "$db_json")" || {
    err "生成用户流量统计配置失败。"
    return 1
  }

  current_norm="$(echo "$current_json" | jq -S .)"
  desired_norm="$(echo "$desired_json" | jq -S .)"
  if [ "$current_norm" != "$desired_norm" ]; then
    if _CONFIG_APPLY_QUIET_OK=1 config_apply "$desired_json"; then
      ok "配置已同步。"
    else
      err "配置同步失败。"
      return 1
    fi
  fi

  return 0
}

# ---------- 自动控制（到期/超额/重置） ----------

user_today_date() {
  TZ="${BUSINESS_TZ:-Asia/Shanghai}" date +%F
}

user_current_period() {
  TZ="${BUSINESS_TZ:-Asia/Shanghai}" date +%Y-%m
}

user_manager_reconcile_user_state() {
  with_manager_lock _user_manager_reconcile_user_state_body
}

_user_manager_reconcile_user_state_body() {
  init_manager_env || return 1
  user_db_exists || return 0
  sync_user_usage_counters || return 1

  local db_json json today period today_day last_day result changed
  db_json="$(user_db_load)"
  json="$(config_load)"
  # 单一时间真理源：所有派生字段都从 today 字符串切片，避免连续调多次 date 在毫秒级跨日导致字段错位
  today="$(user_today_date)"
  period="${today:0:7}"
  today_day=$((10#${today:8:2}))
  last_day=$(awk -v y="${today:0:4}" -v m="${today:5:2}" 'BEGIN {
    split("31 28 31 30 31 30 31 31 30 31 30 31", d, " ")
    d[2] = (y%4==0 && (y%100!=0 || y%400==0)) ? 29 : 28
    print d[m+0]
  }')

  result="$(echo "$db_json" | jq --arg today "$today" --arg period "$period" --argjson today_day "$today_day" --argjson last_day "$last_day" '
    .users |= with_entries(
      .value as $v
      | ($v.expire_at // "0") as $expire
      | ($v.reset_day // 0) as $reset_day
      | ($v.last_reset_period // "") as $last_reset
      | ($v.quota_gb // 0) as $quota
      | ($v.disabled_reason // null) as $reason
      | ($expire != "0" and ($today >= $expire)) as $expired
      | (
          if ($reset_day == 32) then $last_day
          elif ($reset_day >= 1 and $reset_day <= 29) then
            (if ($reset_day > $last_day) then $last_day else $reset_day end)
          else 0 end
        ) as $effective_reset_day

      | ($period | split("-") | map(tonumber)) as $ym
      | (if $ym[1] == 1 then [($ym[0]-1),12] else [$ym[0],($ym[1]-1)] end) as $prev
      | (if $today_day >= $effective_reset_day then $period
         else (($prev[0]|tostring) + "-" + ("0" + ($prev[1]|tostring))[-2:]) end) as $due_period
      # 新建用户/调整重置日先建账，不追溯清零；已有账期则补做漏掉的重置。
      | if ($effective_reset_day > 0 and $last_reset == "") then
          .value.last_reset_period = $due_period
        else . end
      # 1. 到期检查：expire_at 为到期停用日，当天即禁用
      | if $expired then
          .value.enabled = false
          | if ($reason == "manual") then
              .value.disabled_reason = "manual"
            else
              .value.disabled_reason = "expired"
            end
        end
      # 2. 重置检查
      | if (($expired | not) and $effective_reset_day > 0 and $last_reset != "" and $last_reset < $due_period) then
          .value.used_up_bytes = 0
          | .value.used_down_bytes = 0
          | .value.manual_added_bytes = 0
          | .value.last_reset_period = $due_period
          | if ((.value.disabled_reason // null) == "quota_exceeded") then
              .value.enabled = true
              | .value.disabled_reason = null
            else . end
        else . end
      # 3. 超额检查（重置后 billable 已清零，不会误判）
      | if ($quota > 0 and .value.enabled == true) then
          ((.value.used_up_bytes // 0) + (.value.used_down_bytes // 0) + (.value.manual_added_bytes // 0)) as $current_billable
          | if ($current_billable >= ($quota * 1073741824)) then
              .value.enabled = false
              | .value.disabled_reason = "quota_exceeded"
            else . end
        else . end
    )
  ')" || return 1

  changed="$(jq -n --argjson old "$db_json" --argjson new "$result" 'if ($old == $new) then "0" else "1" end' | tr -d '"')"

  if [ "$changed" = "1" ]; then
    user_manager_apply_changes "$result" "$json" >/dev/null 2>&1 || return 1
  fi
  return 0
}

apply_automatic_user_controls() {
  user_manager_reconcile_user_state
}

user_watch_run() {
  # cron 场景下用 flock 排他锁，避免与交互式操作并发修改文件
  local lock_fd
  user_db_exists || return 0
  mkdir -p "$(dirname "$SB_LOCK_FILE")" 2>/dev/null || true
  if ! has_cmd flock || ! { exec {lock_fd}>"$SB_LOCK_FILE"; } 2>/dev/null; then
    err "无法获取管理锁，本轮后台同步已跳过。"
    return 1
  fi
  flock -n "$lock_fd" || { exec {lock_fd}>&-; return 0; }
  # 设置哨兵告知嵌套的 config_apply 已持锁，避免重入死锁
  _CONFIG_LOCK_HELD=1
  if user_manager_background_sync >/dev/null 2>&1; then
    apply_automatic_user_controls >/dev/null 2>&1 || true
    user_db_touch_data_updated_at >/dev/null 2>&1 || true
  fi
  _CONFIG_LOCK_HELD=0
  exec {lock_fd}>&-
}

ensure_user_manager_ready() {
  init_manager_env || return 1
  if ! user_db_exists; then
    user_db_save "$(user_db_min_template)" || {
      err "用户数据库初始化失败：$USER_DB_FILE"
      return 1
    }
    ok "已初始化用户数据库，默认启用 admin 用户。"
  fi
  return 0
}

user_manager_background_sync() {
  user_db_exists || return 0
  init_manager_env || return 1
  user_db_cleanup_current_and_save || return 1
  user_manager_runtime_sync || return 1
  return 0
}
