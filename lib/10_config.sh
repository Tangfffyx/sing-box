#!/usr/bin/env bash
# ============================================================
# 模块: 10_config.sh
# 职责: 配置文件加载/校验/应用/回滚/重启服务
# 依赖: 00_base.sh, 01_utils.sh
# ============================================================

config_min_template() {
  cat <<'JSON'
{
  "log": {"level": "info", "output": "/var/log/sing-box/access.log", "timestamp": true},
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "reject"}
  ],
  "route": {"rules": [], "final": "reject"},
  "experimental": {"cache_file": {"enabled": true}}
}
JSON
}

config_normalize() {
  local json="$1"
  if [ -z "$json" ]; then
    json="$(config_min_template)"
  fi
  echo "$json" | jq '
    if type != "object" then
      {
        "log": {"level":"info","output":"/var/log/sing-box/access.log","timestamp":true},
        "inbounds": [],
        "outbounds": [
          {"type":"direct","tag":"direct"},
          {"type":"block","tag":"reject"}
        ],
        "route": {"rules": [], "final": "reject"}
      }
    else . end
    | .log = (.log // {"level":"info","output":"/var/log/sing-box/access.log","timestamp":true})
    | .inbounds = (.inbounds // [])
    | .outbounds = (.outbounds // [])
    | .route = (.route // {"rules": [], "final": "reject"})
    | .route.rules = (.route.rules // [])
    | .route.final = "reject"
    | if (.route.rule_set? == null) then .
      else
        .route.rule_set = (
          (.route.rule_set | if type == "array" then . else [.] end)
          | map(
              if ((.type // "") == "remote" and (((.tag // "") | startswith("warp-geosite-")) or ((.tag // "") | startswith("relay-geosite-")))) then
                .format = (.format // "binary")

              else .
              end
            )
          | reduce .[] as $rs ({seen:{}, out:[]};
              ($rs.tag // "") as $tag
              | if $tag == "" then
                  .out += [$rs]
                elif (.seen[$tag] == null) then
                  .seen[$tag] = (.out | length)
                  | .out += [$rs]
                else
                  .out[.seen[$tag]] = $rs
                end
            )
          | .out
        )
      end
    | .experimental = (.experimental // {})
    | .experimental.cache_file = (.experimental.cache_file // {})
    | .experimental.cache_file.enabled = true
    | if (.outbounds | any((.tag // "")=="direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end
    | if (.outbounds | any((.tag // "")=="reject")) then . else .outbounds += [{"type":"block","tag":"reject"}] end
  ' | config_migrate_114

}

# Canonical 1.14 format. Preserve custom download detours and direct dialer options.
config_migrate_114() {
  jq '
    . as $root
    | def client($tag):
        ([$root.outbounds[]? | select(.tag == $tag)][0]) as $out
        | if $out.type == "direct" and ($out | del(.type,.tag) | length) == 0
          then {version:2} else {version:2,detour:$tag} end;
    .route.rule_set |= (if . == null then . else map(
      if .type == "remote" then
        if (.http_client? == null) then
          .http_client = (if (.download_detour // "") != "" then client(.download_detour)
            elif ($root.http_clients // [] | length) > 0 or ($root.route.default_http_client // "") != "" then null
            else client(if ($root.route.final // "reject") == "reject" then "direct" else $root.route.final end) end)
        else . end
        | del(.download_detour)
        | if .http_client == null then del(.http_client)
          elif (.http_client|type) == "object" and (.http_client.detour // "") != "" then
            .http_client as $c | client($c.detour) as $base
            | if $base.detour? == null then .http_client |= del(.detour) else . end
          else . end
      else . end) end)
    | if .route.rule_set == null then del(.route.rule_set) else . end
    | [.outbounds[]? | select(.type == "block") | .tag] as $blocks
    | .route.rules |= map(walk(if type == "object" and .outbound? != null
        then .outbound as $o | if ($blocks|index($o)) != null then del(.outbound) | .action="reject" else . end
        else . end))
    | .outbounds |= map(select(.type != "block"))
    | del(.route.final)
    | .route.rules = ([.route.rules[]? | select(. != {action:"reject"})] + [{action:"reject"}])
  '
}

config_load() {
  if [ -s "$CONFIG_FILE" ] && jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    config_normalize "$(cat "$CONFIG_FILE")"
  else
    config_min_template | config_migrate_114
  fi
}

config_ensure_exists() {
  mkdir -p /etc/sing-box
  chmod 700 /etc/sing-box 2>/dev/null || true
  if [ ! -e "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
    warn "未发现配置文件，将写入最小模板：$CONFIG_FILE"
    config_min_template | config_migrate_114 > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    return 0
  fi

  if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    local ts broken
    ts="$(date +%Y%m%d_%H%M%S)"
    broken="${CONFIG_FILE}.broken.${ts}"
    cp -a "$CONFIG_FILE" "$broken" 2>/dev/null || true
    warn "检测到配置文件不是合法 JSON，已备份到：$broken"
    config_min_template | config_migrate_114 > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    return 0
  fi
}

ensure_manager_file_permissions() {
  mkdir -p /etc/sing-box "$(dirname "$USER_DB_FILE")" "$(dirname "$META_FILE")"
  chmod 700 /etc/sing-box "$(dirname "$USER_DB_FILE")" "$(dirname "$META_FILE")" 2>/dev/null || true
  [ -e "$CONFIG_FILE" ] && chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  [ -e "$USER_DB_FILE" ] && chmod 600 "$USER_DB_FILE" 2>/dev/null || true
  [ -e "$META_FILE" ] && chmod 600 "$META_FILE" 2>/dev/null || true
}

check_config_or_print() {
  if ! has_cmd sing-box; then
    err "未找到 sing-box 命令。请先安装。"
    return 1
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    err "未找到配置文件：$CONFIG_FILE"
    return 1
  fi
  if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi
  err "配置校验失败：sing-box check -c $CONFIG_FILE"
  sing-box check -c "$CONFIG_FILE" 2>&1 | sed 's/^/  /'
  return 1
}

openrc_service_exists() {
  local service="$1"
  [ -e "/etc/init.d/$service" ] || rc-service -e "$service" >/dev/null 2>&1
}

openrc_service_enabled() {
  local service="$1" runlevel="${2:-default}"
  rc-update show "$runlevel" 2>/dev/null | awk -v svc="$service" '$1 == svc {found=1} END {exit !found}'
}

openrc_enable_service() {
  local service="$1" runlevel="${2:-default}"
  openrc_service_enabled "$service" "$runlevel" && return 0
  rc-update add "$service" "$runlevel"
}

openrc_disable_service() {
  local service="$1" runlevel="${2:-default}"
  openrc_service_enabled "$service" "$runlevel" || return 0
  rc-update del "$service" "$runlevel"
}

openrc_service_running() {
  local service="$1"
  rc-service "$service" status >/dev/null 2>&1
}

openrc_start_service() {
  local service="$1"
  openrc_service_running "$service" && return 0
  rc-service "$service" start
}

openrc_stop_service() {
  local service="$1"
  openrc_service_running "$service" || return 0
  rc-service "$service" stop
}

# HUP 会在原进程中重建实例；这里明确重启并验证新的进程，兼顾升级与计费代次。
singbox_process_token() {
  local pid stat boot
  case "$INIT_SYSTEM" in
    systemd) pid="$(systemctl show sing-box -p MainPID --value 2>/dev/null)" || return 1 ;;
    openrc) pid="$(cat /run/sing-box.pid 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  stat="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
  # comm 字段可以包含空格及括号；删到最后一个右括号后再取 starttime。
  stat="${stat##*) }"
  stat="$(printf '%s\n' "$stat" | awk '{print $20}')"
  [[ "$stat" =~ ^[0-9]+$ ]] || return 1
  boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || return 1
  printf '%s:%s:%s\n' "$boot" "$pid" "$stat"
}

wait_singbox_ready() {
  local old_token="${1:-}" token="" last_token="" stable=0 attempt api_enabled
  api_enabled="$(jq -r '.experimental.v2ray_api.stats.enabled // false' "$CONFIG_FILE")" || return 1
  for ((attempt=0; attempt<20; attempt++)); do
    token="$(singbox_process_token 2>/dev/null)" || token=""
    if singbox_service_active && [ -n "$token" ] && [ "$token" != "$old_token" ]; then
      if [ "$api_enabled" != true ] || query_v2ray_api_uptime >/dev/null 2>&1; then
        if [ "$token" = "$last_token" ]; then stable=$((stable + 1)); else stable=1; fi
        last_token="$token"
        [ "$stable" -ge 3 ] && return 0
      else
        stable=0
      fi
    else
      stable=0
    fi
    sleep 1
  done
  err "sing-box 未在期限内稳定启动或统计 API 不可用。"
  return 1
}

reload_or_restart_singbox_safe() {
  check_config_or_print || return 1
  local old_token quiet="${_RESTART_SINGBOX_QUIET_OK:-0}"
  old_token="$(singbox_process_token 2>/dev/null)" || old_token=""
  case "$INIT_SYSTEM" in
    systemd) systemctl restart sing-box >/dev/null 2>&1 || return 1 ;;
    openrc) rc-service sing-box restart >/dev/null 2>&1 || return 1 ;;
    *) err "未识别的 init 系统，无法重启 sing-box。"; return 1 ;;
  esac
  wait_singbox_ready "$old_token" || return 1
  [ "$quiet" = "1" ] || ok "sing-box 已重启并通过运行检查。"
  return 0
}

enable_now_singbox_safe() {
  local quiet="${_SINGBOX_ENABLE_QUIET_OK:-0}"
  if ! check_config_or_print; then
    err "已阻止启动/自启：请先修复配置。"
    return 1
  fi
  case "$INIT_SYSTEM" in
    systemd)
      systemctl enable sing-box >/dev/null 2>&1 || return 1
      systemctl start sing-box >/dev/null 2>&1 || return 1
      sleep 1
      systemctl is-active --quiet sing-box 2>/dev/null || return 1
      ;;
    openrc)
      openrc_enable_service sing-box default >/dev/null 2>&1 || return 1
      openrc_start_service sing-box >/dev/null 2>&1 || return 1
      sleep 1
      openrc_service_running sing-box || return 1
      ;;
    *)
      err "未识别的 init 系统，无法启动 sing-box。"
      return 1
      ;;
  esac
  [ "$quiet" = "1" ] || ok "sing-box 已启用自启并启动。"
}

with_manager_lock() {
  local _lock_fd _rc=0

  # 并发保护：通过 _CONFIG_LOCK_HELD 哨兵防止重入死锁
  if [ "${_CONFIG_LOCK_HELD:-0}" = "1" ]; then
    if "$@"; then return 0; else return $?; fi
  fi

  if ! has_cmd flock; then
    err "缺少 flock，已阻止无锁写入；请先安装 util-linux（Alpine: flock）。"
    return 1
  fi

  mkdir -p "$(dirname "$SB_LOCK_FILE")" 2>/dev/null || true

  # 注意：exec 行的尾部重定向是永久作用于当前 shell 的，不能写成
  # `exec {_lock_fd}>"$SB_LOCK_FILE" 2>/dev/null`（会把整个 shell 的
  # stderr 永久关闭到 /dev/null，后续 err/warn/read -p 提示全丢失）。
  # 必须用命令组 { ... } 2>/dev/null，把重定向锚定在组作用域内。
  if { exec {_lock_fd}>"$SB_LOCK_FILE"; } 2>/dev/null; then
    if flock "$_lock_fd"; then
      _CONFIG_LOCK_HELD=1
      if "$@"; then _rc=0; else _rc=$?; fi
      _CONFIG_LOCK_HELD=0
      { exec {_lock_fd}>&-; } 2>/dev/null || true
    else
      { exec {_lock_fd}>&-; } 2>/dev/null || true
      err "获取管理锁失败，未执行写入。"
      _rc=1
    fi
  else
    err "无法创建管理锁：$SB_LOCK_FILE，未执行写入。"
    _rc=1
  fi
  return $_rc
}

config_apply() {
  with_manager_lock _config_apply_body "$@"
}

config_apply_no_usage_sync() {
  _CONFIG_SKIP_USAGE_SYNC=1 config_apply "$@"
}

# 配套提交 config + meta：先 config_apply 后 meta_save，meta_save 失败时回滚 config。
# 用法：config_and_meta_apply <config_json> <meta_json>
# 环境变量 _CONFIG_APPLY_QUIET_OK / _CONFIG_SKIP_USAGE_SYNC 透传给内部 config_apply。
# 整个流程在同一把 with_manager_lock 内执行，避免并发会话在 config 已写、meta 未写的间隙插入修改。
config_and_meta_apply() {
  with_manager_lock _config_and_meta_apply_body "$@"
}

_config_and_meta_apply_body() {
  local config_json="$1" meta_json="$2"
  local old_config
  old_config="$(config_load 2>/dev/null)" || old_config='{}'
  # _config_apply_body 直接调用（持锁状态下 sentinel 会让 config_apply wrapper 走 fast path，
  # 但直接调 body 更清晰，省一次条件判断）
  _config_apply_body "$config_json" || return 1
  if ! meta_save "$meta_json"; then
    err "元数据保存失败，正在回滚配置..."
    if ! _CONFIG_APPLY_QUIET_OK=1 _CONFIG_SKIP_USAGE_SYNC=1 _config_apply_body "$old_config"; then
      err "回滚也失败，sing-box 可能运行在新配置上但 meta 是旧的。请手动检查 $CONFIG_FILE 和 $META_FILE"
    fi
    return 1
  fi
}

_config_apply_body() {
  local json="$1"
  local normalized
  normalized="$(config_normalize "$json")"

  if ! echo "$normalized" | jq -e 'type=="object"' >/dev/null 2>&1; then
    err "内部错误：即将写入的配置不是 JSON object。"
    return 1
  fi

  if ! echo "$normalized" | jq -e '
    (.route.final // "") as $final
    | ($final == "" or ([.outbounds[]? | (.tag // "")] | index($final) != null))
  ' >/dev/null 2>&1; then
    err "配置校验失败：route.final 指向的 outbound 不存在。"
    return 1
  fi

  if [ "${_CONFIG_FORCE_RESTART:-0}" != "1" ] && [ -s "$CONFIG_FILE" ] && singbox_service_active; then
    if [ "$(printf '%s' "$normalized" | jq -Sc .)" = "$(jq -Sc . "$CONFIG_FILE")" ]; then
      return 0
    fi
  fi
  if [ "${_CONFIG_SKIP_USAGE_SYNC:-0}" != "1" ]; then
    sync_user_usage_counters || return 1
  fi

  local tmp_file
  tmp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || {
    err "创建临时配置文件失败。"
    return 1
  }

  echo "$normalized" | jq . > "$tmp_file" || {
    err "JSON 格式化失败，未写入配置。"
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  }

  if ! has_cmd sing-box; then
    err "未找到 sing-box，无法校验配置。"
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi

  if ! sing-box check -c "$tmp_file" >/dev/null 2>&1; then
    err "sing-box check 校验未通过，未写入配置。"
    sing-box check -c "$tmp_file" 2>&1 | sed 's/^/  /'
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi

  local ts backup prev_tmp
  ts="$(date +%Y%m%d_%H%M%S)"
  backup="/etc/sing-box/config.json.bak.fail.$ts"
  prev_tmp="$(mktemp "${CONFIG_FILE}.prev.XXXXXX")" || {
    err "创建回滚临时文件失败。"
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  }
  chmod 600 "$prev_tmp" 2>/dev/null || true

  if [ -f "$CONFIG_FILE" ]; then
    if ! cp -a "$CONFIG_FILE" "$prev_tmp"; then
      err "无法备份旧配置：$CONFIG_FILE → $prev_tmp"
      rm -f "$tmp_file" "$prev_tmp" >/dev/null 2>&1 || true
      return 1
    fi
  else
    if ! : > "$prev_tmp"; then
      err "无法初始化回滚备份文件：$prev_tmp"
      rm -f "$tmp_file" "$prev_tmp" >/dev/null 2>&1 || true
      return 1
    fi
  fi

  mv -f "$tmp_file" "$CONFIG_FILE" || {
    err "配置文件写入失败：$CONFIG_FILE"
    rm -f "$tmp_file" "$prev_tmp" >/dev/null 2>&1 || true
    return 1
  }
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true

  if _RESTART_SINGBOX_QUIET_OK=1 reload_or_restart_singbox_safe; then
    case "$INIT_SYSTEM" in
      systemd) systemctl enable sing-box >/dev/null 2>&1 || true ;;
      openrc)  openrc_enable_service sing-box default >/dev/null 2>&1 || true ;;
    esac
    rm -f "$prev_tmp" >/dev/null 2>&1 || true
    # 自动清理旧备份，保留最近 1 个
    ls -1t /etc/sing-box/config.json.bak.fail.* 2>/dev/null | tail -n +2 | xargs rm -f -- 2>/dev/null || true
    [ "${_CONFIG_APPLY_QUIET_OK:-0}" = "1" ] || ok "配置已应用。"
    return 0
  fi

  err "热载/重启失败：正在回滚。"
  if [ -f "$prev_tmp" ] && [ -s "$prev_tmp" ]; then
    cp -a "$prev_tmp" "$backup" || warn "失败现场备份未能保存到 $backup"
    if ! cp -a "$prev_tmp" "$CONFIG_FILE"; then
      err "回滚 cp 失败，sing-box 可能仍运行在坏配置上。手动恢复：cp $prev_tmp $CONFIG_FILE"
      return 1
    fi
    warn "已生成失败备份：$backup"
  else
    cp -a "$CONFIG_FILE" "$backup" 2>/dev/null || true
    warn "无旧配置可回滚，已保存失败现场：$backup"
  fi
  rm -f "$prev_tmp" >/dev/null 2>&1 || true
  if ! reload_or_restart_singbox_safe; then
    err "回滚后热载/重启仍失败，sing-box 当前可能处于异常状态。"
    warn "手动恢复命令："
    case "$INIT_SYSTEM" in
      systemd) warn "  systemctl start sing-box" ;;
      openrc)  warn "  rc-service sing-box start" ;;
    esac
    warn "如需恢复到失败前的配置，请检查：$backup"
  fi
  return 1
}

config_reset() {
  config_apply "$(config_min_template)"
}

init_manager_env() {
  # 幂等哨兵：首次执行后标记，避免菜单循环重复跑 require_root/has_cmd/磁盘读
  [ "${_MANAGER_ENV_READY:-0}" = "1" ] && return 0
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 运行此脚本。"
    return 1
  fi
  has_cmd jq || { err "未找到 jq，请先安装/更新 sing-box（会自动装依赖）。"; return 1; }
  has_cmd curl || { err "未找到 curl，请先安装/更新 sing-box（会自动装依赖）。"; return 1; }
  has_cmd openssl || { err "未找到 openssl，请先安装/更新 sing-box（会自动装依赖）。"; return 1; }
  has_cmd sing-box || { err "未找到 sing-box，请先安装。"; return 1; }
  local core_version
  core_version="$(sing-box version | awk '/^sing-box version / {print $3; exit}')"
  version_ge "$core_version" "1.14.0" || { err "此脚本需要 sing-box 1.14.0 或更新版本，请先在安装/更新菜单升级内核。"; return 1; }
  [ "$INIT_SYSTEM" = "unknown" ] && { err "未识别的 init 系统（需要 systemd 或 OpenRC）。"; return 1; }
  config_ensure_exists
  ensure_manager_file_permissions
  _MANAGER_ENV_READY=1
}
