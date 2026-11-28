#!/usr/bin/env bash
# ============================================================
# 模块: 61_user_manager.sh
# 职责: 用户管理业务逻辑（投影、同步、自动控制）
# 依赖: 00_base.sh, 10_config.sh, 20_protocol.sh, 30_route.sh,
#       50_v2ray_api.sh, 60_user_db.sh
# ============================================================

user_manager_prepare_credentials() {
  local json="$1" db_json="$2" meta_json="${3:-}"
  local work_json="$json"
  local inv_lines=() line idx entry_key proto port inbound
  work_json="$(config_normalize "$work_json")" || return 1
  mapfile -t inv_lines < <(protocol_entry_inventory_ext "$work_json")
  for line in "${inv_lines[@]}"; do
    IFS=$'\x01' read -r idx entry_key proto port <<< "$line"
    inbound="$(find_inbound_by_entry_key "$work_json" "$entry_key")"
    [ -n "$inbound" ] || continue

    # Plan credentials in one jq pass; only new credentials need external generators.
    local plan users_json desired new_obj
    plan="$(echo "$inbound" | jq -c --argjson db "$db_json" --arg entry "$entry_key" --arg proto "$proto" "${JQ_NODE_PART}"'
      def business($n): if ($n|contains("@")) then ($n|split("@")[1]) else "admin" end;
      . as $ib
      | [(.users // [])[] | (.name // .username // "") | node_part(.)
         | select(contains("-to-") and . != $entry)] | unique as $relays
      | def allowed($node):
          $db.users | to_entries[] | select(.key != "admin")
          | select(.value.allow_all_nodes == true or ((.value.nodes // []) | index($node)) != null)
          | $node + "@" + .key;
      ([ $entry, allowed($entry), ($relays[] | . as $node | $node, allowed($node)),
         ($ib.users[]? | (.name // .username) as $name | select($db.users[business($name)] != null) | $name) ]
       | reduce .[] as $name ([]; if index($name) == null then . + [$name] else . end)) as $desired
      | (reduce ($ib.users // [])[] as $u ({}; .[$u.name // $u.username] //= $u)) as $existing
      | [$desired[] | . as $name
          | ($existing[$name] // (if $proto == "socks" and node_part($name) == $entry then
              [$ib.users[]? | select((.username // "") != "")
               | select((node_part(.username)|contains("-to-")|not) and business(.username) == business($name))
               | .username=$name][0] else null end)) as $object
          | {name:$name,object:$object}]
    ')" || return 1
    users_json="$(echo "$plan" | jq -c '[.[].object | select(. != null)]')" || return 1
    while IFS= read -r desired; do
      [ -n "$desired" ] || continue
      new_obj="$(build_user_object_from_inbound "$inbound" "$desired")" || return 1
      users_json="$(echo "$users_json" | jq -c --argjson obj "$new_obj" '. + [$obj]')" || return 1
    done < <(echo "$plan" | jq -r '.[] | select(.object == null) | .name')
    # Match the original desired order, including credentials just created.
    users_json="$(echo "$users_json" | jq -c --argjson plan "$plan" '
      (reduce .[] as $u ({}; .[$u.name // $u.username]=$u)) as $by_name
      | [$plan[].name | $by_name[.]]
    ')" || return 1
    work_json="$(echo "$work_json" | jq --argjson idx "$idx" --argjson users "$users_json" '.inbounds[$idx].users = $users')" || return 1
  done

  printf '%s\n' "$work_json"
}

# The archive contains configured credentials, including those absent from the runtime.
# A missing active inbound is only restored when it was explicitly parked.
user_manager_inventory_config() {
  local runtime="$1" db="$2"
  jq --argjson db "$db" '
    (.inbounds // []) as $active
    | ($db.meta.managed_inbounds // {}) as $saved
    | .inbounds = (
        [$active[] | . as $inbound
          | if $saved[$inbound.tag] == null then . else
              .users = ([.users[]?, $saved[$inbound.tag].users[]?] |
                reduce .[] as $user ([]; if any(.[]; (.name // .username) == ($user.name // $user.username))
                  then . else . + [$user] end))
            end]
        + [$db.meta.parked_inbounds[]? as $tag
            | select(all($active[]; .tag != $tag)) | $saved[$tag] | select(. != null)])
  ' <<< "$runtime"
}

user_manager_config_for_edit() {
  local runtime db
  runtime="$(config_load)" || return 1
  if user_db_exists; then
    db="$(user_db_load)" || return 1
    user_manager_inventory_config "$runtime" "$db"
  elif user_db_is_first_use; then
    printf '%s\n' "$runtime"
  else
    user_db_restore_hint
    return 1
  fi
}

user_manager_project_runtime() {
  local canonical="$1" db="$2" meta="${3:-}" routed
  routed="$(route_rebuild "$canonical" "$meta")" || return 1
  routed="$(jq --argjson db "$db" "${JQ_DETECT_PROTOCOL}${JQ_NODE_PART}"'
    .inbounds |= map(
      if detect_protocol == "" then . else
        .tag as $entry
        | .users |= map(
          (.name // .username) as $auth
          | ($auth | node_part(.) | if contains("-to-") then . else $entry end) as $node
          | (if ($auth|contains("@")) then ($auth|split("@")[1]) else "admin" end) as $account
          | $db.users[$account] as $user
          | select($user.enabled == true and
              ($account == "admin" or $user.allow_all_nodes == true or (($user.nodes // []) | index($node)) != null)))
        | select((.users | length) > 0)
      end)
  ' <<< "$routed")" || return 1
  ensure_v2ray_api_on_json "$routed"
}

user_manager_apply_to_json() {
  local canonical db
  db="$(user_manager_evaluate_state "$2")" || return 1
  canonical="$(user_manager_prepare_credentials "$1" "$db")" || return 1
  user_manager_project_runtime "$canonical" "$db" "${3:-}"
}

# 菜单传入前后快照用于提取字段补丁；在锁内将补丁合并到最新数据。
# 同字段被其他管理操作修改时拒绝提交，避免无声覆盖。
merge_user_edit() {
  local current="$1" before="$2" after="$3" mode="${4:-edit}" target="${5:-}"
  printf '%s' "$current" | jq --argjson before "$before" --argjson after "$after" --arg mode "$mode" --arg target "$target" '
    def policy: del(.used_up_bytes,.used_down_bytes,.last_live_up_bytes,.last_live_down_bytes,.manual_added_bytes,.enabled,.disabled_reason,.last_reset_period);
    reduce ((($before.users|keys) + ($after.users|keys)) | unique[]) as $u (. ;
      ($before.users[$u]) as $old | ($after.users[$u]) as $new
      | if $old == null then
          if .users[$u] != null then error("用户已被其他操作创建: " + $u) else .users[$u]=$new end
        elif $new == null then
          if .users[$u] == null then .
          elif ((.users[$u]|policy) != ($old|policy)) then error("用户状态已变化，请重新确认删除: " + $u)
          else del(.users[$u]) end
        else
          ([$new|keys[] | select(. != "used_up_bytes" and . != "used_down_bytes" and . != "last_live_up_bytes" and . != "last_live_down_bytes" and . != "enabled" and . != "disabled_reason")
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
  local before="$1" after="$2" mode="${3:-edit}" target="${4:-}" merged current _USER_SAMPLE_FAILED
  user_manager_sample_before_change
  current="$(user_db_load)" || return 1
  merged="$(merge_user_edit "$current" "$before" "$after" "$mode" "$target")" || {
    err "数据已变化或输入无效，请重新打开菜单后操作。"
    return 1
  }
  _user_manager_apply_changes_body "$merged"
}

user_manager_apply_changes() {
  with_manager_lock _user_manager_apply_changes_body "$@"
}

_user_manager_apply_changes_body() {
  local db_json="$1" base_json="${2:-}" meta_json="${3:-}" canonical applied_json runtime
  local _USER_SAMPLE_FAILED="${_USER_SAMPLE_FAILED:-0}"
  if [ "${_USER_KEEP_LATEST_DB:-0}" = "1" ]; then
    user_manager_sample_before_change
    db_json="$(user_db_load)" || return 1
  else
    [ -n "$base_json" ] || base_json="$(config_load)" || return 1
    base_json="$(user_manager_inventory_config "$base_json" "$db_json")" || return 1
  fi
  db_json="$(user_manager_evaluate_state "$db_json")" || return 1
  db_json="$(user_db_cleanup_missing_nodes "$db_json" "$base_json")" || return 1
  canonical="$(user_manager_prepare_credentials "$base_json" "$db_json")" || return 1
  applied_json="$(user_manager_project_runtime "$canonical" "$db_json" "$meta_json")" || return 1
  db_json="$(jq --argjson canonical "$canonical" --argjson runtime "$applied_json" "${JQ_DETECT_PROTOCOL}"'
    ($runtime.inbounds | map(.tag)) as $live
    | .meta.managed_inbounds = ($canonical.inbounds | map(select(detect_protocol != ""))
        | map({key:.tag,value:.}) | from_entries)
    | .meta.parked_inbounds = [.meta.managed_inbounds | keys[] | . as $tag | select(($live | index($tag)) == null)]
  ' <<< "$db_json")" || return 1
  runtime="$(config_load)" || return 1
  if [ "${_USER_SAMPLE_FAILED:-0}" = 1 ] &&
    [ "$(jq -Sc . <<< "$applied_json")" != "$(jq -Sc . <<< "$runtime")" ]; then
    warn "最后一次流量采样失败。权限会照常更新，重启前的用量可能有缺口。"
    db_json="$(jq --arg observed "$(TZ="$BUSINESS_TZ" date '+%F %T')" '
      .meta.last_usage_gap_at_text = $observed
    ' <<< "$db_json")" || return 1
  fi
  if [ -z "$meta_json" ] && [ "$(jq -Sc . <<< "$applied_json")" = "$(jq -Sc . <<< "$runtime")" ]; then
    if [ "$(jq -Sc . <<< "$db_json")" != "$(jq -Sc . "$USER_DB_FILE")" ]; then
      user_db_save "$db_json" || return 1
    fi
    return 0
  fi

  user_db_exists || { user_db_restore_hint; return 1; }
  manager_transaction_begin || { err "无法备份本次变更涉及的数据。"; return 1; }
  if ! user_db_save "$db_json" ||
    ! _CONFIG_APPLY_QUIET_OK=1 config_apply_no_usage_sync "$applied_json" ||
    { [ -n "$meta_json" ] && ! meta_save "$meta_json"; }; then
    err "用户变更写入失败。"
    manager_recover_pending || return 1
    return 1
  fi
  manager_transaction_end || { err "提交未完成，下次操作时将恢复旧数据。"; return 1; }

  [ "${_USER_MANAGER_APPLY_QUIET_OK:-0}" = "1" ] || ok "用户变更已应用。"
  return 0
}

user_manager_sample_before_change() {
  _USER_SAMPLE_FAILED=0
  if ! sync_user_usage_counters; then
    _USER_SAMPLE_FAILED=1
  fi
}

# ---------- 自动控制（到期/超额/重置） ----------

user_today_date() {
  TZ="${BUSINESS_TZ:-Asia/Shanghai}" date +%F
}

user_manager_reconcile_user_state() {
  with_manager_lock _user_manager_reconcile_user_state_body
}

_user_manager_reconcile_user_state_body() {
  init_manager_env || return 1
  user_db_exists || return 0
  local _USER_SAMPLE_FAILED db_json
  user_manager_sample_before_change
  db_json="$(user_db_load)" || return 1
  _user_manager_apply_changes_body "$db_json"
}

user_manager_evaluate_state() {
  local db_json="$1" today period today_day last_day
  # 单一时间真理源：所有派生字段都从 today 字符串切片，避免连续调多次 date 在毫秒级跨日导致字段错位
  today="$(user_today_date)"
  period="${today:0:7}"
  today_day=$((10#${today:8:2}))
  last_day=$(awk -v y="${today:0:4}" -v m="${today:5:2}" 'BEGIN {
    split("31 28 31 30 31 30 31 31 30 31 30 31", d, " ")
    d[2] = (y%4==0 && (y%100!=0 || y%400==0)) ? 29 : 28
    print d[m+0]
  }')

  echo "$db_json" | jq --arg today "$today" --arg period "$period" --argjson today_day "$today_day" --argjson last_day "$last_day" '
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
      | if ($effective_reset_day > 0 and $last_reset != "" and $last_reset < $due_period) then
          .value.used_up_bytes = 0
          | .value.used_down_bytes = 0
          | .value.manual_added_bytes = 0
          | .value.last_reset_period = $due_period
        else . end
      | .value.admin_allowed = (
          if ($v | has("admin_allowed")) then $v.admin_allowed == true
          elif $reason == "manual" then false
          else ($v.enabled == true or $reason == "expired" or $reason == "quota" or $reason == "quota_exceeded") end)
      | ((.value.used_up_bytes // 0) + (.value.used_down_bytes // 0) + (.value.manual_added_bytes // 0)) as $used
      | .value.disabled_reason = (
          if (.value.admin_allowed | not) then
            if $reason == "manual" then "manual" else "needs_review" end
          elif $expired then "expired"
          elif ($quota > 0 and $used >= ($quota * 1073741824)) then "quota_exceeded"
          else null end)
      | .value.enabled = (.value.disabled_reason == null)
    )
  '
}

apply_automatic_user_controls() {
  user_manager_reconcile_user_state
}

user_watch_run() {
  # cron 场景下用 flock 排他锁，避免与交互式操作并发修改文件
  local lock_fd
  [ -d "$USER_DB_FILE.pending" ] || user_db_exists || { user_db_is_first_use || user_db_restore_hint; return 0; }
  mkdir -p "$(dirname "$SB_LOCK_FILE")" 2>/dev/null || true
  if ! has_cmd flock || ! { exec {lock_fd}>"$SB_LOCK_FILE"; } 2>/dev/null; then
    err "无法获取管理锁，本轮后台同步已跳过。"
    return 1
  fi
  flock -n "$lock_fd" || { exec {lock_fd}>&-; return 0; }
  # 设置哨兵告知嵌套的 config_apply 已持锁，避免重入死锁
  _CONFIG_LOCK_HELD=1
  if manager_recover_pending; then
    apply_automatic_user_controls >/dev/null || true
  fi
  _CONFIG_LOCK_HELD=0
  exec {lock_fd}>&-
}

ensure_user_manager_ready() {
  init_manager_env || return 1
  user_db_initialize
}

user_manager_background_sync() {
  user_manager_reconcile_user_state
}
