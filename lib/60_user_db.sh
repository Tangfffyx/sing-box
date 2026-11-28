#!/usr/bin/env bash
# ============================================================
# 模块: 60_user_db.sh
# 职责: 用户数据库 CRUD（纯数据操作，不含 UI）
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh (with_manager_lock)
# ============================================================

user_db_min_template() {
  cat <<'JSON'
{
  "enabled": true,
  "meta": {
    "data_updated_at_text": ""
  },
  "users": {
    "admin": {
      "enabled": true,
      "disabled_reason": null,
      "quota_gb": 0,
      "used_up_bytes": 0,
      "used_down_bytes": 0,
      "manual_added_bytes": 0,
      "last_live_up_bytes": 0,
      "last_live_down_bytes": 0,
      "last_reset_period": "",
      "reset_day": 0,
      "expire_at": "0",
      "allow_all_nodes": true,
      "nodes": []
    }
  }
}
JSON
}

user_db_exists() {
  [ -f "$USER_DB_FILE" ] && [ -s "$USER_DB_FILE" ] && user_db_valid < "$USER_DB_FILE"
}

user_db_valid() {
  jq -es 'length == 1 and (.[0] | .enabled == true and
    (.users | type == "object" and (.admin | type == "object") and
      all(.[]; type == "object" and (.enabled | type == "boolean"))))' >/dev/null 2>&1
}

user_db_is_first_use() {
  [ ! -e "$USER_DB_FILE" ] && [ ! -L "$USER_DB_FILE" ] &&
    [ ! -e "$USER_DB_FILE.initialized" ] &&
    [ ! -e "${SINGBOX_VERSION_STAMP:-}" ] &&
    [ ! -e "${META_FILE:-}" ] && [ ! -e "${TG_CONFIG_FILE:-}" ] &&
    [ ! -e "${TG_TASK_RECEIPTS_FILE:-}" ] &&
    ! compgen -G "$USER_DB_FILE.corrupt.*" >/dev/null &&
    { [ ! -e "${CONFIG_FILE:-}" ] || jq -es '
      length == 1 and (.[0] | type == "object" and
      ((.inbounds // []) | length == 0) and (.experimental.v2ray_api == null))
    ' "$CONFIG_FILE" >/dev/null 2>&1; }
}

user_db_restore_hint() {
  err "无法读取用户数据库 ${USER_DB_FILE}。请从同一次备份恢复用户数据，再重试。"
}

user_db_load() {
  local db_json
  if db_json="$(cat "$USER_DB_FILE" 2>/dev/null)" &&
    printf '%s\n' "$db_json" | user_db_valid; then
    printf '%s\n' "$db_json"
  else
    user_db_restore_hint
    return 1
  fi
}

user_db_initialize() {
  with_manager_lock _user_db_initialize_body
}

_user_db_initialize_body() {
  if ! user_db_exists; then
    user_db_is_first_use || { user_db_restore_hint; return 1; }
    atomic_write_json_file "$USER_DB_FILE" "$(user_db_min_template)" "用户数据库" || return 1
    ok "已初始化用户数据库，默认启用 admin 用户。"
  fi
  user_db_mark_initialized
}

user_db_mark_initialized() {
  [ -f "$USER_DB_FILE.initialized" ] ||
    atomic_write_json_file "$USER_DB_FILE.initialized" '{}' "用户数据库初始化记录"
}

user_db_save() {
  with_manager_lock _user_db_save_body "$@"
}

_user_db_save_body() {
  local db_json="$1"
  user_db_exists || { user_db_restore_hint; return 1; }
  printf '%s\n' "$db_json" | user_db_valid || { err "用户数据检查失败，已保留原文件。"; return 1; }
  user_db_mark_initialized || return 1
  atomic_write_json_file "$USER_DB_FILE" "$db_json" "用户数据库"
}

user_billable_bytes() {
  local db_json="$1" username="$2"
  echo "$db_json" | jq -r --arg u "$username" '
    (.users[$u].used_up_bytes // 0)
    + (.users[$u].used_down_bytes // 0)
    + (.users[$u].manual_added_bytes // 0)
  '
}

package_text_for_user() {
  local db_json="$1" username="$2"
  local quota
  quota="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].quota_gb // 0')"
  if [ "$quota" = "0" ]; then
    echo "不限"
  else
    echo "${quota} GiB"
  fi
}

user_db_set_admin_allowed() {
  local db="$1" username="$2" allowed="$3"
  jq --arg user "$username" --argjson allowed "$allowed" '
    .users[$user].admin_allowed = $allowed
    | .users[$user].enabled = $allowed
    | .users[$user].disabled_reason = (if $allowed then null else "manual" end)
  ' <<< "$db"
}

user_db_enabled_users() {
  local db_json="$1"
  echo "$db_json" | jq -r '.users | to_entries[] | select(.value.enabled == true) | .key' | awk 'NF'
}

user_db_all_users() {
  local db_json="$1"
  echo "$db_json" | jq -r '.users | to_entries[] | .key' | awk 'NF'
}

user_db_user_exists() {
  local db_json="$1" username="$2"
  echo "$db_json" | jq -e --arg u "$username" '.users[$u] != null' >/dev/null 2>&1
}

user_db_user_is_enabled() {
  local db_json="$1" username="$2"
  echo "$db_json" | jq -e --arg u "$username" '.users[$u].enabled == true' >/dev/null 2>&1
}

user_db_user_allow_node() {
  local db_json="$1" username="$2" node_key="$3"
  echo "$db_json" | jq -e --arg u "$username" --arg n "$node_key" '
    (.users[$u].allow_all_nodes == true) or ((.users[$u].nodes // []) | index($n) != null)
  ' >/dev/null 2>&1
}

# 节点添加时的扩展点（当前设计：新节点只给 admin，不自动分配给其他用户）
user_db_on_node_added() {
  local db_json="$1" node_key="$2"
  echo "$db_json"
}

user_db_cleanup_missing_nodes() {
  local db_json="$1" json="$2"
  local available_json
  available_json="$(
    list_all_node_keys "$json" | jq -R . | jq -s '.'
  )"
  echo "$db_json" | jq --argjson available "$available_json" '
    .users |= with_entries(
      .value.nodes = (
        (.value.nodes // [])
        | [.[] | . as $n | select(($available | index($n)) != null)]
        | unique
      )
    )
  '
}
