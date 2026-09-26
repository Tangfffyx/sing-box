#!/usr/bin/env bash
# ============================================================
# 模块: 50_v2ray_api.sh
# 职责: gRPC 流量统计查询、meta 存储、grpcurl 安装
# 依赖: 00_base.sh, 01_utils.sh
# ============================================================

# ---------- Proto 文件管理 ----------

ensure_v2ray_api_proto_files() {
  mkdir -p /etc/sing-box
  cat > "$V2RAY_PROTO_V2RAY" <<'EOF_V2V'
syntax = "proto3";
package v2ray.core.app.stats.command;
message GetStatsRequest { string name = 1; bool reset = 2; }
message Stat { string name = 1; int64 value = 2; }
message GetStatsResponse { Stat stat = 1; }
message QueryStatsRequest { string pattern = 1; bool reset = 2; repeated string patterns = 3; bool regexp = 4; }
message QueryStatsResponse { repeated Stat stat = 1; }
message SysStatsRequest {}
message SysStatsResponse {
  uint32 NumGoroutine = 1; uint32 NumGC = 2; uint64 Alloc = 3; uint64 TotalAlloc = 4;
  uint64 Sys = 5; uint64 Mallocs = 6; uint64 Frees = 7; uint64 LiveObjects = 8; uint64 PauseTotalNs = 9; uint32 Uptime = 10;
}
service StatsService {
  rpc GetStats (GetStatsRequest) returns (GetStatsResponse);
  rpc QueryStats (QueryStatsRequest) returns (QueryStatsResponse);
  rpc GetSysStats (SysStatsRequest) returns (SysStatsResponse);
}
EOF_V2V
}

# ---------- grpcurl 管理 ----------

ensure_grpcurl() {
  if [ -x "$GRPCURL_BIN" ]; then
    return 0
  fi
  local asset_pattern tag api api_json tmp_dir download_url
  case "$(uname -m)" in
    x86_64) asset_pattern='linux_x86_64.tar.gz' ;;
    aarch64|arm64) asset_pattern='linux_arm64.tar.gz' ;;
    *)
      warn "当前架构暂不支持自动下载 grpcurl：$(uname -m)"
      return 1
      ;;
  esac
  api="https://api.github.com/repos/fullstorydev/grpcurl/releases/latest"
  api_json="$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 "$api" 2>/dev/null || true)"
  [ -n "$api_json" ] || { warn "未获取到 grpcurl 最新版本。"; return 1; }
  tag="$(echo "$api_json" | jq -r '.tag_name // empty' 2>/dev/null)" || true
  [ -n "$tag" ] || { warn "未获取到 grpcurl 最新版本。"; return 1; }
  download_url="$(echo "$api_json" | jq -r --arg p "$asset_pattern" '.assets[]?.browser_download_url | select(contains($p))' 2>/dev/null | head -n1)" || true
  [ -n "$download_url" ] || { warn "未找到 grpcurl 适配当前架构的安装包。"; return 1; }
  tmp_dir="$(make_disk_tmp_dir sb-install)" || { warn "创建临时目录失败。"; return 1; }
  say "下载流量统计组件..."
  if ! download_file "$download_url" "$tmp_dir/grpcurl.tar.gz" 20 3; then
    rm -rf "$tmp_dir"
    warn "下载 grpcurl 失败。"
    return 1
  fi
  tar -xzf "$tmp_dir/grpcurl.tar.gz" -C "$tmp_dir" || { rm -rf "$tmp_dir"; warn "解压 grpcurl 失败。"; return 1; }
  [ -f "$tmp_dir/grpcurl" ] || { rm -rf "$tmp_dir"; warn "grpcurl 安装包中未找到 grpcurl。"; return 1; }
  install -m 755 "$tmp_dir/grpcurl" "$GRPCURL_BIN" || { rm -rf "$tmp_dir"; warn "安装 grpcurl 失败。"; return 1; }
  rm -rf "$tmp_dir"
  return 0
}

ensure_grpcurl_logged() {
  if [ -x "$GRPCURL_BIN" ]; then
    return 0
  fi
  if ensure_grpcurl; then
    return 0
  fi
  warn "grpcurl 安装失败，用户流量读数可能不可用。"
  return 1
}

# ---------- V2Ray API 配置注入 ----------

ensure_v2ray_api_on_json() {
  local json="$1"
  local users_json
  users_json="$(
    echo "$json" | jq -c "${JQ_AUTH_USERS}"'
      [
        .route.rules[]?
        | auth_users_array[]?
        | select(length > 0)
      ] | unique | sort
    '
  )"
  echo "$json" | jq --arg listen "$V2RAY_API_LISTEN" --argjson users "$users_json" '
    .experimental = (.experimental // {})
    | .experimental.v2ray_api = (.experimental.v2ray_api // {})
    | .experimental.v2ray_api.listen = $listen
    | .experimental.v2ray_api.stats = {
        "enabled": true,
        "users": $users
      }
  '
}

# ---------- 流量查询 ----------

v2ray_api_query() {
  local method="$1" payload="$2"
  [ -x "$GRPCURL_BIN" ] || { warn "缺少 grpcurl，统计不可用。"; return 1; }
  [ -s "$V2RAY_PROTO_V2RAY" ] || ensure_v2ray_api_proto_files || return 1
  "$GRPCURL_BIN" -plaintext -connect-timeout 2 -max-time 3 \
    -import-path "$(dirname "$V2RAY_PROTO_V2RAY")" -proto "$(basename "$V2RAY_PROTO_V2RAY")" \
    -d "$payload" "$V2RAY_API_LISTEN" "v2ray.core.app.stats.command.StatsService/$method"
}

query_v2ray_api_stats_json() {
  local out
  out="$(v2ray_api_query QueryStats '{"patterns":["user>>>"],"reset":false,"regexp":false}')" || return 1
  printf '%s' "$out" | jq -ce '(.stat // []) | select(type == "array")'
}

query_v2ray_api_uptime() {
  local out
  out="$(v2ray_api_query GetSysStats '{}')" || return 1
  printf '%s' "$out" | jq -er '(.Uptime // .uptime // 0) | tonumber | select(. >= 0)'
}

query_usage_snapshot() {
  local before after first last stats monotonic
  before="$(singbox_process_token)" || return 1
  first="$(query_v2ray_api_uptime)" || return 1
  stats="$(query_v2ray_api_stats_json)" || return 1
  last="$(query_v2ray_api_uptime)" || return 1
  monotonic="$(awk '{print int($1)}' /proc/uptime)" || return 1
  after="$(singbox_process_token)" || return 1
  [ "$before" = "$after" ] && [ "$last" -ge "$first" ] || return 1
  jq -nc --arg process "$after" --argjson start "$((monotonic - last))" --argjson stats "$stats" \
    '{process:$process, start:$start, stats:$stats}'
}

# 纯变换：按完整 auth_user 保存基线，再聚合业务用户。start 用单调时钟，避免 NTP 校时误判。
account_usage_snapshot() {
  local db="$1" snapshot="$2"
  printf '%s' "$db" | jq --argjson snap "$snapshot" '
    def business($name): if ($name|contains("@")) then ($name|split("@")[1]) else "admin" end;
    def delta($now; $old): if $now >= $old then $now-$old else $now end;
    . as $db
    | (.meta.usage // {}) as $prev
    | (($prev.process // "") != $snap.process or (($prev.start // 0) - $snap.start | fabs) > 2) as $new_epoch
    | (reduce ($snap.stats[]? | select((.name // "")|test("^user>>>.+>>>traffic>>>(uplink|downlink)$"))) as $s
        ({}; ($s.name|capture("^user>>>(?<user>.+)>>>traffic>>>(?<dir>uplink|downlink)$")) as $m
          | .[$m.user][$m.dir] = ($s.value|tonumber))) as $live
    | (reduce ($live|to_entries[]) as $item ({};
        business($item.key) as $u
        | ($item.value.uplink // 0) as $up | ($item.value.downlink // 0) as $down
        | (if $new_epoch then {} else ($prev.counters[$item.key] // {}) end) as $old
        | .[$u].up = ((.[$u].up // 0) + delta($up; ($old.uplink // 0)))
        | .[$u].down = ((.[$u].down // 0) + delta($down; ($old.downlink // 0)))
        | .[$u].live_up = ((.[$u].live_up // 0) + $up)
        | .[$u].live_down = ((.[$u].live_down // 0) + $down))) as $usage
    | .users |= with_entries(
        .key as $u | .value as $v | ($usage[$u] // {}) as $n
        # 首次从旧版迁移：沿用旧聚合基线结算一次，然后保存节点基线。
        | .value.used_up_bytes = (($v.used_up_bytes // 0) +
            (if $prev.process == null then delta(($n.live_up // 0); ($v.last_live_up_bytes // 0)) else ($n.up // 0) end))
        | .value.used_down_bytes = (($v.used_down_bytes // 0) +
            (if $prev.process == null then delta(($n.live_down // 0); ($v.last_live_down_bytes // 0)) else ($n.down // 0) end))
        | .value.last_live_up_bytes = ($n.live_up // 0)
        | .value.last_live_down_bytes = ($n.live_down // 0))
    | .meta.usage = {
        process:$snap.process,
        start:(if $new_epoch then $snap.start else $prev.start end),
        counters:((if $new_epoch then {} else ($prev.counters // {}) end) * $live)
      }
  '
}

build_live_usage_object() {
  local stats_json="$1"
  echo "$stats_json" | jq -c '
    reduce (.[]? | select((.name // "") | test("^user>>>.*>>>traffic>>>(downlink|uplink)$"))) as $s
      ({admin:{up:0,down:0}};
        (($s.name // "") | capture("^user>>>(?<user>.+)>>>traffic>>>(?<dir>downlink|uplink)$")) as $m
        | ($m.user) as $uname
        | ($m.dir) as $dir
        | ($s.value // 0 | tonumber? // 0) as $val
        | (if ($uname | contains("@")) then ($uname | split("@")[1]) else "admin" end) as $biz
        | .[$biz] = (.[$biz] // {up:0,down:0})
        | if $dir == "uplink" then
            .[$biz].up = ((.[$biz].up // 0) + $val)
          else
            .[$biz].down = ((.[$biz].down // 0) + $val)
          end
      )
  '
}

sync_user_usage_counters() {
  with_manager_lock _sync_user_usage_counters_body
}

_sync_user_usage_counters_body() {
  user_db_exists || return 0
  singbox_service_active || return 0
  # 尚未启用统计的首次安装，不读取不存在的 API。
  jq -e '.experimental.v2ray_api.stats.enabled == true' "$CONFIG_FILE" >/dev/null 2>&1 || return 0
  local snapshot db_json
  snapshot="$(query_usage_snapshot)" || { warn "统计采样失败，本次未修改流量基线。"; return 1; }
  db_json="$(account_usage_snapshot "$(user_db_load)" "$snapshot")" || return 1
  user_db_save "$db_json" || { warn "用户流量统计落盘失败：$USER_DB_FILE"; return 1; }
}

# ---------- Meta 存储（Reality 公钥等） ----------

meta_load() {
  if [ -s "$META_FILE" ] && jq -e . "$META_FILE" >/dev/null 2>&1; then
    cat "$META_FILE"
  else
    echo '{}'
  fi
}

meta_save() {
  local meta_json="$1"
  mkdir -p "$(dirname "$META_FILE")"
  chmod 700 "$(dirname "$META_FILE")" 2>/dev/null || true
  local tmp_file
  tmp_file="$(mktemp "${META_FILE}.tmp.XXXXXX")" || return 1
  if echo "$meta_json" | jq . > "$tmp_file"; then
    if ! mv -f "$tmp_file" "$META_FILE"; then
      err "元数据写入失败：$META_FILE"
      rm -f "$tmp_file" >/dev/null 2>&1 || true
      return 1
    fi
    chmod 600 "$META_FILE" 2>/dev/null || true
  else
    rm -f "$tmp_file"
    return 1
  fi
}

meta_set_reality_public_key() {
  local tag="$1" public_key="$2"
  [ -n "$tag" ] && [ -n "$public_key" ] || return 0
  local meta_json
  meta_json="$(meta_load)"
  meta_json="$(echo "$meta_json" | jq --arg t "$tag" --arg pk "$public_key" '.[$t] = ((.[$t] // {}) + {public_key:$pk, private_key_auto_generated:true})')" || return 1
  meta_save "$meta_json"
}

meta_get_reality_public_key() {
  local tag="$1"
  meta_load | jq -r --arg t "$tag" '.[$t].public_key // ""'
}
