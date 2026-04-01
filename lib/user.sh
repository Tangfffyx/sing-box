#!/usr/bin/env bash

# User module extracted from sb.sh (Stage 2-3)

ensure_grpcurl() {
  if [ -x "$GRPCURL_BIN" ]; then
    return 0
  fi
  local arch asset tag api tmp_dir download_url
  case "$(uname -m)" in
    x86_64) asset_pattern='linux_x86_64.tar.gz' ;;
    aarch64|arm64) asset_pattern='linux_arm64.tar.gz' ;;
    *)
      warn "当前架构暂不支持自动下载 grpcurl：$(uname -m)"
      return 1
      ;;
  esac
  api="https://api.github.com/repos/fullstorydev/grpcurl/releases/latest"
  tag="$(curl -fsSL "$api" 2>/dev/null | jq -r '.tag_name // empty')" || true
  [ -n "$tag" ] || { warn "未获取到 grpcurl 最新版本。"; return 1; }
  download_url="$(curl -fsSL "$api" 2>/dev/null | jq -r --arg p "$asset_pattern" '.assets[]?.browser_download_url | select(contains($p))' | head -n1)" || true
  [ -n "$download_url" ] || { warn "未找到 grpcurl 适配当前架构的安装包。"; return 1; }
  tmp_dir="$(mktemp -d)"
  if ! curl -fL --connect-timeout 20 --retry 3 "$download_url" -o "$tmp_dir/grpcurl.tar.gz"; then
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

ensure_v2ray_api_on_json() {
  local json="$1"
  local users_json
  users_json="$(
    echo "$json" | jq -c '
      def auth_users_array:
        if (.auth_user? == null) then []
        elif ((.auth_user | type) == "array") then .auth_user
        else [ .auth_user ]
        end;

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

query_v2ray_api_stats_json() {
  ensure_grpcurl >/dev/null 2>&1 || { echo '[]'; return 0; }
  ensure_v2ray_api_proto_files
  local payload out
  payload='{"patterns":["user>>>"],"reset":false,"regexp":false}'
  out="$("$GRPCURL_BIN" -plaintext -import-path /etc/sing-box -proto v2rayapi-v2ray.proto -d "$payload" "$V2RAY_API_LISTEN" v2ray.core.app.stats.command.StatsService/QueryStats 2>/dev/null)" || true
  if [ -n "$out" ] && echo "$out" | jq -e '.stat != null' >/dev/null 2>&1; then
    echo "$out" | jq -c '.stat // []'
    return 0
  fi
  out="$("$GRPCURL_BIN" -plaintext -import-path /etc/sing-box -proto v2rayapi-experimental.proto -d "$payload" "$V2RAY_API_LISTEN" experimental.v2rayapi.StatsService/QueryStats 2>/dev/null)" || true
  if [ -n "$out" ] && echo "$out" | jq -e '.stat != null' >/dev/null 2>&1; then
    echo "$out" | jq -c '.stat // []'
    return 0
  fi
  echo '[]'
}

sum_live_downlink_for_user() {
  local username="$1"
  local stats_json full_name
  stats_json="$(query_v2ray_api_stats_json)"
  if [ "$username" = "admin" ]; then
    echo "$stats_json" | jq -r '
      map(select((.name // "") | test("^user>>>[^@>]+>>>traffic>>>downlink$")))
      | map(.value // 0)
      | add // 0
    '
  else
    echo "$stats_json" | jq -r --arg u "$username" '
      map(select((.name // "") | test("^user>>>.+@" + $u + ">>>traffic>>>downlink$")))
      | map(.value // 0)
      | add // 0
    '
  fi
}
USER_DB_FILE="/etc/sing-box-manager/user-manager.json"
META_FILE="/etc/sing-box-manager/meta.json"

meta_load() {
  json_file_load_or_fallback "$META_FILE" '{}'
}

meta_save() {
  local meta_json="$1"
  json_file_save_pretty "$META_FILE" "$meta_json"
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
  echo "$(meta_load)" | jq -r --arg t "$tag" '.[$t].public_key // ""'
}

generate_reality_keypair_auto() {
  local out priv pub
  out="$(sing-box generate reality-keypair 2>/dev/null || true)"
  priv="$(printf '%s
' "$out" | awk -F': *' '/PrivateKey/ {print $2; exit}')"
  pub="$(printf '%s
' "$out" | awk -F': *' '/PublicKey/ {print $2; exit}')"
  if [ -n "$priv" ] && [ -n "$pub" ]; then
    printf '%s	%s
' "$priv" "$pub"
    return 0
  fi
  return 1
}

get_tls_domain_candidates() {
  cat <<'EOF_TLS'
assets.adobedtm.com
lpcdn.lpsnmedia.net
s.go-mpulse.net
d0.m.awsstatic.com
a0.awsstatic.com
devblogs.microsoft.com
ds-aksb-a.akamaihd.net
tag.demandbase.com
electronics.sony.com
tag-logger.demandbase.com
d3agakyjgjv5i8.cloudfront.net
ms-python.gallerycdn.vsassets.io
img-prod-cms-rt-microsoft-com.akamaized.net
cdn.bizible.com
store-images.s-microsoft.com
catalog.gamepass.com
www.nvidia.com
mscom.demdex.net
drivers.amd.com
azure.microsoft.com
downloadmirror.intel.com
prod.us-east-1.ui.gcr-chat.marketing.aws.dev
r.bing.com
www.intel.com
ms-vscode.gallerycdn.vsassets.io
rum.hlx.page
www.tesla.com
ts2.tc.mm.bing.net
res-1.cdn.office.net
cdn-dynmedia-1.microsoft.com
EOF_TLS
}

benchmark_tls_domain_ms() {
  local domain="$1" t1 t2
  t1="$(date +%s%3N 2>/dev/null || true)"
  timeout 1 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null >/dev/null 2>&1 || return 1
  t2="$(date +%s%3N 2>/dev/null || true)"
  if [ -n "$t1" ] && [ -n "$t2" ]; then
    echo $((t2 - t1))
  else
    echo 999
  fi
}

auto_pick_tls_domain() {
  local best_domain="" best_ms=999999 ms domain
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    ms="$(benchmark_tls_domain_ms "$domain" 2>/dev/null || true)"
    if [ -n "$ms" ] && [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -lt "$best_ms" ]; then
      best_ms="$ms"
      best_domain="$domain"
    fi
  done < <(get_tls_domain_candidates)
  [ -n "$best_domain" ] || return 1
  printf '%s	%s
' "$best_domain" "$best_ms"
}

choose_tls_domain() {
  local proto_label="$1" choice manual picked picked_ms
  ui_echo "1. 手动输入"
  ui_echo "2. 自动测速选择推荐域名"
  read -r -p "请选择域名填写方式（回车默认2. 自动测速选择推荐域名）: " choice
  case "${choice:-2}" in
    1)
      read -r -p "请输入${proto_label}域名: " manual
      if [ -z "${manual:-}" ]; then
        warn "[WARN] 输入无效，已返回上一级。" >&2
        pause >&2
        return 1
      fi
      echo "$manual"
      ;;
    2)
      choose_tls_domain_auto || return 1
      ;;
    *)
      warn "输入无效，已使用默认自动测速。" >&2
      choose_tls_domain_auto || return 1
      ;;
  esac
}

choose_tls_domain_auto() {
  local picked picked_ms
  picked="$(auto_pick_tls_domain 2>/dev/null || true)"
  if [ -n "$picked" ]; then
    picked_ms="${picked#*$'\t'}"
    picked="${picked%%$'\t'*}"
    echo -e "已自动选择域名：${picked}（${picked_ms} ms）" >&2
    echo "$picked"
    return 0
  fi
  warn "自动测速失败，已返回上一级。" >&2
  pause >&2
  return 1
}

user_node_part() {
  local name="${1:-}"
  if [[ "$name" == *"@"* ]]; then
    echo "${name%%@*}"
  else
    echo "$name"
  fi
}

user_business_name() {
  local name="${1:-}"
  if [[ "$name" == *"@"* ]]; then
    echo "${name#*@}"
  else
    echo "admin"
  fi
}

node_user_name() {
  local node_key="$1" username="$2"
  if [ "$username" = "admin" ]; then
    echo "$node_key"
  else
    echo "${node_key}@${username}"
  fi
}

is_valid_user_name() {
  local u="${1:-}"
  [[ -n "$u" ]] || return 1
  [[ "$u" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$u" != *"@"* ]] || return 1
  [[ "$u" != *"/"* ]] || return 1
  [[ "$u" != *":"* ]] || return 1
  [[ "$u" != *" "* ]] || return 1
}

user_db_min_template() {
  cat <<'JSON'
{
  "enabled": true,
  "users": {
    "admin": {
      "enabled": true,
            "quota_gb": 0,
      "used_up_bytes": 0,
      "used_down_bytes": 0,
      "manual_added_bytes": 0,
      "last_live_up_bytes": 0,
      "last_live_down_bytes": 0,
      "last_reset_period": "",
      "reset_day": 0,
      "expire_at": "0",
      "nodes": []
    }
  }
}
JSON
}

user_db_exists() {
  [ -s "$USER_DB_FILE" ] && jq -e '.enabled == true and (.users.admin != null)' "$USER_DB_FILE" >/dev/null 2>&1
}

user_db_load() {
  json_file_load_or_fallback "$USER_DB_FILE" "$(user_db_min_template)" '.enabled == true and (.users.admin != null)'
}

user_db_save() {
  local db_json="$1"
  json_file_save_pretty "$USER_DB_FILE" "$db_json" /etc/sing-box
}

format_bytes_human() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1099511627776) printf("%.1f TB", b/1099511627776)
    else if (b >= 1073741824) printf("%.1f GB", b/1073741824)
    else printf("%.1f MB", b/1048576)
  }'
}

json_is_object() {
  local s="${1:-}"
  [ -n "$s" ] && echo "$s" | jq -e 'type=="object"' >/dev/null 2>&1
}

format_traffic_auto() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    if (b < 1024*1024*1024) printf("%.1f MB", b/1024/1024);
    else if (b < 1024*1024*1024*1024) printf("%.1f GB", b/1024/1024/1024);
    else printf("%.1f TB", b/1024/1024/1024/1024);
  }'
}

reset_day_text() {
  case "${1:-0}" in
    0|"") echo "不重置" ;;
    32) echo "月底" ;;
    *) echo "${1}号" ;;
  esac
}

expire_text() {
  local v="${1:-}"
  [ -n "$v" ] && [ "$v" != "0" ] && echo "$v" || echo "永久"
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
    echo "${quota}GB"
  fi
}

parse_traffic_to_bytes() {
  local raw="${1:-}" normalized num unit
  normalized="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  if [[ ! "$normalized" =~ ^([0-9]+(\.[0-9])?)(mb|gb)$ ]]; then
    return 1
  fi
  num="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[3]}"
  awk -v n="$num" -v u="$unit" 'BEGIN {
    if (u == "mb") printf "%.0f", n * 1048576;
    else if (u == "gb") printf "%.0f", n * 1073741824;
    else exit 1;
  }'
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
    ((.users[$u].nodes // []) | index($n) != null)
  ' >/dev/null 2>&1
}

list_all_node_keys() {
  local json="$1"
  {
    echo "$json" | jq -r '.inbounds[]?.tag // empty'
    echo "$json" | jq -r '
      .inbounds[]?
      | (.users // [])[]?
      | .name // empty
    ' | while IFS= read -r n; do
      [ -n "$n" ] || continue
      np="$(user_node_part "$n")"
      if [[ "$np" == *"-to-"* ]]; then
        echo "$np"
      fi
    done
  } | awk 'NF' | LC_ALL=C sort -u
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
  user_db_exists || return 0
  [ -x "$GRPCURL_BIN" ] || return 0
  singbox_service_active || return 0

  local stats_json usage_json db_json
  stats_json="$(query_v2ray_api_stats_json)"
  echo "$stats_json" | jq -e 'type=="array"' >/dev/null 2>&1 || return 0
  usage_json="$(build_live_usage_object "$stats_json")" || return 0
  db_json="$(user_db_load)"
  db_json="$(echo "$db_json" | jq --argjson usage "$usage_json" '
    .users |= with_entries(
      .value as $v
      | ($usage[.key].up // 0) as $live_up
      | ($usage[.key].down // 0) as $live_down
      | ($v.last_live_up_bytes // 0) as $last_up
      | ($v.last_live_down_bytes // 0) as $last_down
      | .value.used_up_bytes = (($v.used_up_bytes // 0) + (if $live_up >= $last_up then ($live_up - $last_up) else $live_up end))
      | .value.used_down_bytes = (($v.used_down_bytes // 0) + (if $live_down >= $last_down then ($live_down - $last_down) else $live_down end))
      | .value.last_live_up_bytes = $live_up
      | .value.last_live_down_bytes = $live_down
    )
  ')" || return 0
  user_db_save "$db_json"
}

user_package_invalid_return() {
  ui_echo "${Y}[WARN]${NC} 输入无效，未作修改，已返回上一级。"
}


table_compute_widths() {
  local sep="$1"
  shift
  local -a rows=("$@")
  local -a widths=()
  local row i w
  local -a cols=()
  for row in "${rows[@]}"; do
    IFS="$sep" read -r -a cols <<< "$row"
    for i in "${!cols[@]}"; do
      w="$(text_display_width "${cols[$i]}")"
      if [ -z "${widths[$i]:-}" ] || [ "$w" -gt "${widths[$i]}" ]; then
        widths[$i]="$w"
      fi
    done
  done
  local -a out=()
  for i in "${!widths[@]}"; do
    out+=("$((widths[$i] + 2))")
  done
  printf '%s\n' "${out[*]}"
}

table_print_row() {
  local widths_line="$1"
  shift
  local -a widths=()
  local -a cells=("$@")
  local i out=""
  read -r -a widths <<< "$widths_line"
  for i in "${!cells[@]}"; do
    out+="$(pad_display_text "${cells[$i]}" "${widths[$i]}")"
  done
  printf '%s\n' "$out"
}

show_user_status_table() {
  local db_json="$1"
  local sep=$'\t'
  local header widths_line row_line
  local -a rows=()
  local -a cols=()

  header="用户名${sep}状态${sep}上传流量${sep}下载流量${sep}已用总量${sep}套餐${sep}重置日${sep}到期时间"
  rows+=("$header")

  while IFS= read -r row_line; do
    [ -n "$row_line" ] && rows+=("$row_line")
  done < <(
    echo "$db_json" | jq -r '
      .users
      | to_entries
      | .[]
      | [
          .key,
          (if (.value.enabled == true) then "开启" else "关闭" end),
          ((.value.used_up_bytes // 0) | tostring),
          ((.value.used_down_bytes // 0) | tostring),
          (((.value.used_up_bytes // 0) + (.value.used_down_bytes // 0) + (.value.manual_added_bytes // 0)) | tostring),
          ((if (.value.quota_gb // 0) == 0 then "不限" else ((.value.quota_gb|tostring) + "GB") end)),
          (if (.value.reset_day // 0) == 0 then "不重置" elif (.value.reset_day // 0) == 32 then "月底" else ((.value.reset_day|tostring) + "号") end),
          (if (.value.expire_at // "0") == "0" then "永久" else (.value.expire_at // "0") end)
        ] | @tsv
    ' | while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 c8; do
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$c1" \
            "$c2" \
            "$(format_bytes_human "$c3")" \
            "$(format_bytes_human "$c4")" \
            "$(format_bytes_human "$c5")" \
            "$c6" \
            "$c7" \
            "$c8"
      done
  )

  widths_line="$(table_compute_widths "$sep" "${rows[@]}")"

  IFS="$sep" read -r -a cols <<< "$header"
  local header_line divider_line divider_width
  header_line="$(table_print_row "$widths_line" "${cols[@]}")"
  divider_width="$(text_display_width "$header_line")"
  divider_line="$(printf '%*s' "$divider_width" '' | tr ' ' '-')"

  ui_echo "\033[1m${header_line}${NC}"
  ui_echo "${B}${divider_line}${NC}"

  for row_line in "${rows[@]:1}"; do
    IFS="$sep" read -r -a cols <<< "$row_line"
    table_print_row "$widths_line" "${cols[@]}"
  done

  ui_echo "${B}${divider_line}${NC}"
}

show_user_status_table_from_file() {
  local db_json
  sync_user_usage_counters || true
  db_json="$(user_db_load)"
  show_user_status_table "$db_json"
}

build_user_object_from_inbound() {
  local inbound="$1" full_name="$2"
  local inbound_type
  inbound_type="$(echo "$inbound" | jq -r '.type')"
  case "$inbound_type" in
    vless)
      if echo "$inbound" | jq -e '.tls.reality.enabled == true' >/dev/null 2>&1; then
        jq -n --arg name "$full_name" --arg uuid "$(sing-box generate uuid)" '{name:$name,uuid:$uuid,flow:"xtls-rprx-vision"}'
      else
        jq -n --arg name "$full_name" --arg uuid "$(sing-box generate uuid)" '{name:$name,uuid:$uuid}'
      fi
      ;;
    vmess)
      jq -n --arg name "$full_name" --arg uuid "$(sing-box generate uuid)" '{name:$name,uuid:$uuid,alterId:0}'
      ;;
    shadowsocks)
      jq -n --arg name "$full_name" --arg pass "$(openssl rand -base64 16)" '{name:$name,password:$pass}'
      ;;
    anytls)
      jq -n --arg name "$full_name" --arg pass "$(openssl rand -base64 16)" '{name:$name,password:$pass}'
      ;;
    trojan)
      jq -n --arg name "$full_name" --arg pass "$(openssl rand -base64 16)" '{name:$name,password:$pass}'
      ;;
    tuic)
      jq -n --arg name "$full_name" --arg uuid "$(sing-box generate uuid)" --arg pass "$(openssl rand -base64 12)" '{name:$name,uuid:$uuid,password:$pass}'
      ;;
    *)
      return 1
      ;;
  esac
}

find_user_obj_in_inbound() {
  local inbound="$1" full_name="$2"
  echo "$inbound" | jq -c --arg n "$full_name" '(.users // [])[]? | select((.name // "") == $n)' | head -n1
}

user_manager_apply_to_json() {
  local json="$1" db_json="$2"
  local work_json="$json"
  local inv_lines=() line idx entry_key proto port inbound
  work_json="$(config_normalize "$work_json")" || return 1
  mapfile -t inv_lines < <(protocol_entry_inventory_ext "$work_json")
  for line in "${inv_lines[@]}"; do
    IFS=$'\t' read -r idx entry_key proto port <<< "$line"
    inbound="$(find_inbound_by_entry_key "$work_json" "$entry_key")"
    [ -n "$inbound" ] || continue

    local relay_nodes=() relay_node
    mapfile -t relay_nodes < <(echo "$inbound" | jq -r '.users[]?.name // empty' | while IFS= read -r n; do
      [ -n "$n" ] || continue
      np="$(user_node_part "$n")"
      if [[ "$np" == *"-to-"* && "$np" != "$entry_key" ]]; then
        echo "$np"
      fi
    done | sort -u)

    local desired_names=("$entry_key")
    local username
    while IFS= read -r username; do
      [ -n "$username" ] || continue
      [ "$username" = "admin" ] && continue
      if user_db_user_allow_node "$db_json" "$username" "$entry_key"; then
        desired_names+=("$(node_user_name "$entry_key" "$username")")
      fi
    done < <(user_db_all_users "$db_json")

    for relay_node in "${relay_nodes[@]}"; do
      desired_names+=("$relay_node")
      while IFS= read -r username; do
        [ -n "$username" ] || continue
        [ "$username" = "admin" ] && continue
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

  work_json="$(route_rebuild "$work_json")" || return 1
  work_json="$(filter_disabled_auth_users "$work_json" "$db_json")" || return 1
  ensure_v2ray_api_on_json "$work_json" || return 1
}

filter_disabled_auth_users() {
  local json="$1" db_json="$2"
  local enabled_json
  enabled_json="$(echo "$db_json" | jq -c '[.users | to_entries[] | select(.value.enabled == true) | .key]')"
  echo "$json" | jq --argjson enabled "$enabled_json" '
    def auth_users_array:
      if (.auth_user? == null) then []
      elif ((.auth_user | type) == "array") then .auth_user
      else [ .auth_user ]
      end;
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
  '
}

user_db_materialize_allow_all_nodes() {
  local db_json="$1" json="$2"
  local available_json
  available_json="$(
    list_all_node_keys "$json" | jq -R . | jq -s '.'
  )"
  echo "$db_json" | jq --argjson available "$available_json" '
    .users |= with_entries(
      if (.value.allow_all_nodes // false) == true then
        .value.nodes = $available
      else
        .
      end
      | .value |= del(.allow_all_nodes)
    )
  '
}

user_db_cleanup_missing_nodes() {
  local db_json="$1" json="$2"
  db_json="$(user_db_materialize_allow_all_nodes "$db_json" "$json")" || return 1
  local available_json
  available_json="$(
    list_all_node_keys "$json" | jq -R . | jq -s '.'
  )"
  echo "$db_json" | jq --argjson available "$available_json" '
    .users |= with_entries(
      .value.nodes = (
        (.value.nodes // [])
        | map(select(($available | index(.)) != null))
        | unique
      )
      | .value |= del(.allow_all_nodes)
    )
  '
}

user_db_cleanup_current_and_save() {
  local db_json json cleaned
  user_db_exists || return 0
  db_json="$(user_db_load)"
  json="$(config_load)"
  cleaned="$(user_db_cleanup_missing_nodes "$db_json" "$json")" || return 1
  user_db_save "$cleaned"
  return 0
}

user_db_grant_node_to_enabled_users() {
  local db_json="$1" node_key="$2"
  echo "$db_json"
}

user_manager_apply_changes() {
  local db_json="$1" base_json="${2:-}" skip_node_cleanup="${3:-0}"
  [ -n "$base_json" ] || base_json="$(config_load)"

  say "重新生成用户节点关系..."
  if [ "$skip_node_cleanup" != "1" ]; then
    db_json="$(user_db_materialize_allow_all_nodes "$db_json" "$base_json")" || return 1
    db_json="$(user_db_cleanup_missing_nodes "$db_json" "$base_json")" || return 1
  fi
  local applied_json
  applied_json="$(user_manager_apply_to_json "$base_json" "$db_json")" || {
    err "生成用户节点关系失败。"
    return 1
  }
  ok "用户节点关系已更新。"

  say "重建路由规则..."
  ok "路由规则已重建。"

  if config_apply "$applied_json"; then
    say "更新用户数据库..."
    user_db_save "$db_json"
    ok "用户数据库已保存。"
    ok "用户变更已应用。"
    return 0
  fi
  return 1
}


prompt_reset_day() {
  local outvar="$1" val
  while true; do
    ui_echo "0  不重置"
    ui_echo "1-29 指定日期"
    ui_echo "32 月底"
    read -r -p "请输入重置日: " val
    case "$val" in
      0|32) printf -v "$outvar" '%s' "$val"; return 0 ;;
      '') ui_echo "${Y}[WARN]${NC} 请输入 0、1-29 或 32。" ;;
      *)
        if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 29 ]; then
          printf -v "$outvar" '%s' "$val"
          return 0
        fi
        ui_echo "${Y}[WARN]${NC} 请输入 0、1-29 或 32。"
        ;;
    esac
  done
}

prompt_expire_date() {
  local outvar="$1" val
  read -r -p "请输入到期日期（格式：YYYY-MM-DD，输入 0 表示永久）: " val
  if [ "$val" = "0" ]; then
    printf -v "$outvar" '%s' '0'
    return 0
  fi
  if [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf -v "$outvar" '%s' "$val"
    return 0
  fi
  ui_echo "${Y}[WARN]${NC} 输入无效，未作修改，已返回上一级。"
  return 1
}

select_nodes_multi() {
  local json="$1" outvar="$2"
  local nodes=()
  mapfile -t nodes < <(list_all_node_keys "$json")
  if [ ${#nodes[@]} -eq 0 ]; then
    printf -v "$outvar" '%s' '[]'
    return 0
  fi
  ui_echo "请选择可用节点（多个用空格分隔，回车表示不选择）："
  local i=1 node
  for node in "${nodes[@]}"; do
    ui_echo " [$i] $node"
    i=$((i+1))
  done
  local ans picks_json='[]' part selected=()
  read -r -p "请输入编号: " ans
  for part in $ans; do
    if [[ "$part" =~ ^[0-9]+$ ]] && [ "$part" -ge 1 ] && [ "$part" -le "${#nodes[@]}" ]; then
      selected+=("${nodes[$((part-1))]}")
    fi
  done
  if [ ${#selected[@]} -gt 0 ]; then
    picks_json="$(printf '%s
' "${selected[@]}" | awk 'NF' | sort -u | jq -R . | jq -s '.')"
  fi
  printf -v "$outvar" '%s' "$picks_json"
}

user_show_info() {
  local db_json="$1" username="$2"
  local used_up used_down manual_added total_used quota_bytes used_up_text used_down_text manual_text total_text quota_text
  local effective_nodes_json
  sync_user_usage_counters || true
  db_json="$(user_db_load)"
  effective_nodes_json="$(echo "$db_json" | jq -c --arg u "$username" '(.users[$u].nodes // []) | unique')"
  used_up="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].used_up_bytes // 0')"
  used_down="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].used_down_bytes // 0')"
  manual_added="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].manual_added_bytes // 0')"
  total_used="$(user_billable_bytes "$db_json" "$username")"
  quota_bytes="$(echo "$db_json" | jq -r --arg u "$username" '(.users[$u].quota_gb // 0) * 1073741824')"
  used_up_text="$(format_traffic_auto "$used_up")"
  used_down_text="$(format_traffic_auto "$used_down")"
  manual_text="$(format_traffic_auto "$manual_added")"
  total_text="$(format_traffic_auto "$total_used")"
  if [ "$quota_bytes" -eq 0 ]; then
    quota_text="不限"
  else
    quota_text="$(format_traffic_auto "$quota_bytes")"
  fi
  echo "$db_json" | jq -r     --arg u "$username"     --arg up "$used_up_text"     --arg down "$used_down_text"     --arg manual "$manual_text"     --arg total "$total_text"     --arg quota "$quota_text" '
    .users[$u] as $x
    | "用户名：" + $u + "\n"
      + "状态：" + (if $x.enabled then "开启" else "关闭" end) + "\n"
      + "上传流量：" + $up + "\n"
      + "下载流量：" + $down + "\n"
      + "手动补正流量：" + $manual + "\n"
      + "已用总量：" + $total + "\n"
      + "套餐总量：" + $quota + "\n"
      + "重置日：" + (if (($x.reset_day // 0) == 0) then "不重置" elif (($x.reset_day // 0) == 32) then "月底" else (($x.reset_day|tostring)+"号") end) + "\n"
      + "到期时间：" + (if (($x.expire_at // "0") == "0") then "永久" else $x.expire_at end)
  '
  echo "允许节点："
  echo "$effective_nodes_json" | jq -r '.[]? // empty' | sed 's/^/  - /'
}

user_add_menu() {
  local db_json json username quota reset_day expire_at ans nodes_json
  db_json="$(user_db_load)"
  json="$(config_load)"
  clear
  print_rect_title "新增用户"
  show_user_status_table "$db_json"
  read -r -p "请输入用户名: " username
  if ! is_valid_user_name "$username"; then
    warn "用户名仅允许字母、数字、点、下划线、短横线。"
    pause
    return 1
  fi
  [ "$username" = "admin" ] && { warn "admin 为系统默认用户，不能新增。"; pause; return 1; }
  if user_db_user_exists "$db_json" "$username"; then
    warn "用户已存在：$username"
    pause
    return 1
  fi
  ui_echo "${Y}折算成单向流量填入。示例：双向800G流量就填写400，单向500G流量就填写500${NC}"
  read -r -p "请输入流量限制（GB，输入 0 表示不限）: " quota
  [[ "$quota" =~ ^[0-9]+$ ]] || { warn "[WARN] 输入无效，未作修改，已返回上一级。"; pause; return 0; }
  prompt_reset_day reset_day
  if ! prompt_expire_date expire_at; then pause; return 0; fi
  nodes_json='[]'
  db_json="$(echo "$db_json" | jq --arg u "$username" --argjson quota "$quota" --argjson reset "$reset_day" --arg expire "$expire_at" --argjson nodes "$nodes_json" '
    .users[$u] = {
      enabled: true,
      quota_gb: $quota,
      used_up_bytes: 0,
      used_down_bytes: 0,
      manual_added_bytes: 0,
      last_live_up_bytes: 0,
      last_live_down_bytes: 0,
      last_reset_period: "",
      reset_day: $reset,
      expire_at: $expire,
      nodes: $nodes
    }
  ')"
  user_manager_apply_changes "$db_json" "$json" || { pause; return 1; }
  pause
}

user_manage_permission_menu() {
  local db_json="$1" username="$2" json="$3"
  db_json="$db_json"
  local current_nodes_json
  local nodes=() node i raw picks=() invalid=0 sel idx selected_json new_db

  clear >&2
  print_rect_title "节点权限" >&2
  show_user_status_table "$db_json" >&2
  current_nodes_json="$(echo "$db_json" | jq -c --arg u "$username" '(.users[$u].nodes // []) | unique')"

  ui_echo "当前权限类型：自定义节点"
  ui_echo "当前已分配节点："
  while IFS= read -r node; do
    [ -n "$node" ] && ui_echo "- $node"
  done < <(echo "$current_nodes_json" | jq -r '.[]?')
  if ! echo "$current_nodes_json" | jq -e 'length > 0' >/dev/null 2>&1; then
    ui_echo "- （无）"
  fi
  ui_echo "${B}--------------------------------------------------------${NC}"

  mapfile -t nodes < <(list_all_node_keys "$json")
  ui_echo "可选节点："
  i=1
  for node in "${nodes[@]}"; do
    ui_echo "  ${i}. ${node}"
    i=$((i+1))
  done
  read -r -p "请输入编号（多个用 + 连接，回车返回）: " raw
  [ -z "${raw:-}" ] && return 1
  mapfile -t picks < <(parse_plus_selections "$raw")
  [ ${#picks[@]} -eq 0 ] && return 1

  for sel in "${picks[@]}"; do
    if ! [[ "$sel" =~ ^[0-9]+$ ]]; then invalid=1; break; fi
    if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#nodes[@]}" ]; then invalid=1; break; fi
  done

  if [ $invalid -eq 1 ]; then
    ui_echo "${Y}[WARN]${NC} 输入编号无效，未做任何修改。"
    pause >&2
    return 1
  fi

  selected_json="$({
    for sel in "${picks[@]}"; do
      idx=$((sel-1))
      if [ $idx -ge 0 ] && [ $idx -lt ${#nodes[@]} ]; then
        echo "${nodes[$idx]}"
      fi
    done
  } | awk 'NF' | LC_ALL=C sort -u | jq -R . | jq -s '.')"

  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson nodes "$selected_json" '.users[$u].nodes = $nodes | .users[$u] |= del(.allow_all_nodes)')"
  echo "$new_db"
}

user_manage_package_menu() {
  local db_json="$1" username="$2"
  local current_quota current_reset current_expire quota_in reset_in expire_in quota_val reset_val expire_val
  clear >&2
  print_rect_title "套餐设置" >&2
  show_user_status_table "$db_json" >&2

  current_quota="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].quota_gb // 0')"
  current_reset="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].reset_day // 0')"
  current_expire="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].expire_at // "0"')"

  ui_echo "当前流量限制：${current_quota} GB"
  ui_echo "${Y}折算成单向流量填入。示例：双向800G流量就填写400，单向500G流量就填写500${NC}"
  ui_echo "单位为 GB ，输入 0 表示不限"
  ui_echo "回车：保持当前值"
  read -r -p "请输入: " quota_in
  if [ -z "$quota_in" ]; then
    quota_val="$current_quota"
  elif [[ "$quota_in" =~ ^[0-9]+$ ]]; then
    quota_val="$quota_in"
  else
    user_package_invalid_return; pause >&2; return 1
  fi

  ui_echo "当前重置日期：$(reset_day_text "$current_reset")"
  ui_echo "0. 不重置"
  ui_echo "1-29. 指定日期"
  ui_echo "32. 月底"
  ui_echo "回车：保持当前值"
  read -r -p "请输入: " reset_in
  if [ -z "$reset_in" ]; then
    reset_val="$current_reset"
  elif [ "$reset_in" = "0" ] || [ "$reset_in" = "32" ]; then
    reset_val="$reset_in"
  elif [[ "$reset_in" =~ ^[0-9]+$ ]] && [ "$reset_in" -ge 1 ] && [ "$reset_in" -le 29 ]; then
    reset_val="$reset_in"
  else
    user_package_invalid_return; pause >&2; return 1
  fi

  ui_echo "当前到期时间：$(expire_text "$current_expire")"
  ui_echo "请输入到期日期（格式：YYYY-MM-DD，输入 0 表示永久）:"
  ui_echo "回车：保持当前值"
  read -r -p "请输入: " expire_in
  if [ -z "$expire_in" ]; then
    expire_val="$current_expire"
  elif [ "$expire_in" = "0" ]; then
    expire_val="0"
  elif [[ "$expire_in" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    expire_val="$expire_in"
  else
    user_package_invalid_return; pause >&2; return 1
  fi

  if [ "$quota_val" = "$current_quota" ] && [ "$reset_val" = "$current_reset" ] && [ "$expire_val" = "$current_expire" ]; then
    ui_echo "[INFO] 未检测到改动，按任意键返回。"
    pause >&2
    return 1
  fi

  echo "$db_json" | jq --arg u "$username" --argjson quota "$quota_val" --argjson reset "$reset_val" --arg exp "$expire_val" '
    (.users[$u].reset_day // 0) as $old_reset
    | .users[$u].quota_gb = $quota
    | .users[$u].reset_day = $reset
    | .users[$u].expire_at = $exp
    | if ($old_reset != $reset) then .users[$u].last_reset_period = "" else . end
  '
}


user_add_usage_menu() {
  local db_json="$1" username="$2" raw bytes
  clear >&2
  print_rect_title "手动添加流量" >&2
  show_user_status_table "$db_json" >&2
  ui_echo "此操作会增加该用户的手动补正流量，用于对齐总量。"
  read -r -p "请输入要增添的流量（精确到小数点后一位，需带单位 MB、GB）: " raw
  bytes="$(parse_traffic_to_bytes "$raw")" || {
    warn "[WARN] 输入无效，未作修改，已返回上一级。" >&2
    pause >&2
    return 1
  }
  echo "$db_json" | jq --arg u "$username" --argjson add "$bytes" '
    .users[$u].manual_added_bytes = ((.users[$u].manual_added_bytes // 0) + $add)
  '
}

user_reset_usage_menu() {
  local db_json="$1" username="$2"
  clear >&2
  print_rect_title "手动重置流量" >&2
  show_user_status_table "$db_json" >&2
  ui_echo "将清零该用户的上传流量、下载流量、手动补正流量以及统计基线。"
  ui_echo "此操作不会修改用户的启用状态、套餐设置、到期时间或重置日。"
  local ans
  read -r -p "输入 YES 确认重置该用户流量，其它任意输入取消: " ans
  if [ "$ans" != "YES" ]; then
    return 1
  fi
  echo "$db_json" | jq --arg u "$username" '
    .users[$u].used_up_bytes = 0
    | .users[$u].used_down_bytes = 0
    | .users[$u].last_live_up_bytes = 0
    | .users[$u].last_live_down_bytes = 0
  '
}

user_manage_single() {
  local username="$1"
  local db_json json act new_db
  while true; do
    db_json="$(user_db_load)"
    json="$(config_load)"
    clear
    print_rect_title "管理用户"
    show_user_status_table "$db_json"
    echo "当前用户：$username"
    if [ "$username" = "admin" ]; then
      echo "admin 为系统默认用户，不可删除，节点权限由系统自动维护。"
      echo "  1. 启用/停用"
      echo "  2. 套餐设置"
      echo "  3. 手动重置流量"
      echo "  4. 手动添加流量（对齐总量）"
      echo "  5. 查看用户信息"
      echo "  0. 返回"
      read -r -p "请选择操作: " act
      case "${act:-}" in
        1)
          if user_db_user_is_enabled "$db_json" "$username"; then
            new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false')"
          else
            new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = true')"
          fi
          user_manager_apply_changes "$new_db" "$json" || true
          ;;
        2)
          new_db="$(user_manage_package_menu "$db_json" "$username")" || new_db=""
          if json_is_object "$new_db"; then
            user_manager_apply_changes "$new_db" "$json" || true
          fi
          ;;
        3)
          new_db="$(user_reset_usage_menu "$db_json" "$username")" || new_db=""
          if json_is_object "$new_db"; then
            user_manager_apply_changes "$new_db" "$json" || true
          fi
          ;;
        4)
          new_db="$(user_add_usage_menu "$db_json" "$username")" || new_db=""
          if json_is_object "$new_db"; then
            user_manager_apply_changes "$new_db" "$json" || true
          fi
          ;;
        5) clear; print_rect_title "用户信息"; user_show_info "$db_json" "$username"; echo ""; pause ;;
        0|q|Q|"") return 0 ;;
        *) warn "无效输入：$act"; sleep 1 ;;
      esac
      continue
    fi
    echo "  1. 启用/停用"
    echo "  2. 节点权限"
    echo "  3. 套餐设置"
    echo "  4. 手动重置流量"
    echo "  5. 手动添加流量（对齐总量）"
    echo "  6. 用户信息"
    echo "  0. 返回"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1)
        if user_db_user_is_enabled "$db_json" "$username"; then
          new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false')"
        else
          new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = true')"
        fi
        user_manager_apply_changes "$new_db" "$json" || true
        ;;
      2)
        new_db="$(user_manage_permission_menu "$db_json" "$username" "$json")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_apply_changes "$new_db" "$json" || true
        fi
        ;;
      3)
        new_db="$(user_manage_package_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_apply_changes "$new_db" "$json" || true
        fi
        ;;
      4)
        new_db="$(user_reset_usage_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_apply_changes "$new_db" "$json" || true
        fi
        ;;
      5)
        new_db="$(user_add_usage_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_apply_changes "$new_db" "$json" || true
        fi
        ;;
      6)
        clear
        print_rect_title "用户信息"
        user_show_info "$db_json" "$username"
        echo ""
        pause
        ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

user_select_and_manage_menu() {
  local db_json usernames=() ans idx username
  user_db_cleanup_current_and_save >/dev/null 2>&1 || true
  db_json="$(user_db_load)"
  clear
  print_rect_title "管理用户"
  show_user_status_table "$db_json"
  mapfile -t usernames < <(user_db_all_users "$db_json")
  local i=1
  for username in "${usernames[@]}"; do
    echo " [$i] $username"
    i=$((i+1))
  done
  read -r -p "请选择用户（回车返回）: " ans
  [ -z "${ans:-}" ] && return 0
  if ! [[ "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt "${#usernames[@]}" ]; then
    warn "无效输入：$ans"
    pause
    return 1
  fi
  idx=$((ans-1))
  user_manage_single "${usernames[$idx]}"
}

user_delete_menu() {
  local db_json json usernames=() ans idx username new_db
  sync_user_usage_counters || true
  db_json="$(user_db_load)"
  json="$(config_load)"
  clear
  print_rect_title "删除用户"
  show_user_status_table "$db_json"
  mapfile -t usernames < <(echo "$db_json" | jq -r '.users | keys[] | select(. != "admin")')
  if [ ${#usernames[@]} -eq 0 ]; then
    warn "当前没有可删除的普通用户。"
    pause
    return 0
  fi
  local i=1
  for username in "${usernames[@]}"; do
    echo " [$i] $username"
    i=$((i+1))
  done
  read -r -p "请选择要删除的用户（回车返回）: " ans
  [ -z "${ans:-}" ] && return 0
  if ! [[ "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt "${#usernames[@]}" ]; then
    warn "无效输入：$ans"
    pause
    return 1
  fi
  idx=$((ans-1))
  username="${usernames[$idx]}"
  ask_confirm_yes "输入 YES 确认彻底删除用户 ${username}，其它任意输入取消: " || { warn "已取消删除。"; pause; return 0; }
  new_db="$(echo "$db_json" | jq --arg u "$username" 'del(.users[$u])')" || return 1
  user_manager_apply_changes "$new_db" "$json" || true
  pause
}

ensure_grpcurl_logged() {
  if [ -x "$GRPCURL_BIN" ]; then
    ok "grpcurl 已就绪。"
    return 0
  fi
  say "安装 grpcurl..."
  if ensure_grpcurl; then
    ok "grpcurl 已安装。"
    return 0
  fi
  warn "grpcurl 安装失败，用户流量读数可能不可用。"
  return 1
}

user_manager_runtime_sync() {
  local db_json current_json desired_json current_norm desired_norm
  db_json="$(user_db_load)"
  if [ ! -s "$USER_DB_FILE" ]; then
    say "初始化用户数据库..."
    user_db_save "$db_json"
    ok "用户数据库已初始化。"
  fi

  ensure_grpcurl >/dev/null 2>&1 || true

  current_json="$(config_load)"
  desired_json="$(user_manager_apply_to_json "$current_json" "$db_json")" || {
    err "生成用户流量统计配置失败。"
    return 1
  }

  current_norm="$(echo "$current_json" | jq -S .)"
  desired_norm="$(echo "$desired_json" | jq -S .)"
  if [ "$current_norm" != "$desired_norm" ]; then
    say "检测到用户流量统计配置需要更新..."
    if config_apply "$desired_json"; then
      ok "用户流量统计配置已更新。"
    else
      err "用户流量统计配置更新失败。"
      return 1
    fi
  fi

  sync_user_usage_counters || true
  return 0
}

user_today_date() {
  date +%F
}

user_current_period() {
  date +%Y-%m
}

apply_automatic_user_controls() {
  init_manager_env
  user_db_exists || return 0
  sync_user_usage_counters || true

  local db_json json changed=0 today period today_day
  db_json="$(user_db_load)"
  json="$(config_load)"
  today="$(user_today_date)"
  period="$(user_current_period)"
  today_day=$((10#$(date +%d)))

  local username expire_at reset_day last_reset enabled quota billable hit_reset last_day effective_reset_day
  while IFS= read -r username; do
    [ -n "$username" ] || continue

    expire_at="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].expire_at // "0"')"
    reset_day="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].reset_day // 0')"
    last_reset="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].last_reset_period // ""')"
    enabled="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].enabled // false')"

    if [ "$expire_at" != "0" ] && [[ "$today" > "$expire_at" || "$today" == "$expire_at" ]]; then
      if [ "$enabled" = "true" ]; then
        db_json="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false')"
        changed=1
      fi
      continue
    fi

    hit_reset=0
    if [[ "$reset_day" =~ ^[0-9]+$ ]]; then
      last_day=$((10#$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)))
      if [ "$reset_day" -eq 32 ]; then
        effective_reset_day="$last_day"
      elif [ "$reset_day" -ge 1 ] && [ "$reset_day" -le 29 ]; then
        if [ "$reset_day" -gt "$last_day" ]; then
          effective_reset_day="$last_day"
        else
          effective_reset_day="$reset_day"
        fi
      else
        effective_reset_day=0
      fi
      [ "$effective_reset_day" -gt 0 ] && [ "$today_day" -eq "$effective_reset_day" ] && hit_reset=1
    fi
    if [ "$hit_reset" -eq 1 ] && [ "$last_reset" != "$period" ]; then
      db_json="$(echo "$db_json" | jq --arg u "$username" --arg p "$period" '
        .users[$u].used_up_bytes = 0
        | .users[$u].used_down_bytes = 0
        | .users[$u].last_live_up_bytes = 0
        | .users[$u].last_live_down_bytes = 0
        | .users[$u].last_reset_period = $p
        | .users[$u].enabled = true
      ')"
      changed=1
    fi

    quota="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].quota_gb // 0')"
    if [[ "$quota" =~ ^[0-9]+$ ]] && [ "$quota" -gt 0 ]; then
      billable="$(user_billable_bytes "$db_json" "$username")"
      if [ "$billable" -ge $((quota * 1073741824)) ]; then
        enabled="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].enabled // false')"
        if [ "$enabled" = "true" ]; then
          db_json="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false')"
          changed=1
        fi
      fi
    fi
  done < <(user_db_all_users "$db_json")

  if [ "$changed" -eq 1 ]; then
    user_manager_apply_changes "$db_json" "$json" >/dev/null 2>&1 || return 1
  fi
  return 0
}

user_watch_run() {
  init_user_manager_if_needed >/dev/null 2>&1 || return 0
  apply_automatic_user_controls >/dev/null 2>&1 || true
}

init_user_manager_if_needed() {
  init_manager_env
  if [ ! -e "$USER_DB_FILE" ] && [ -e "/etc/sing-box/user-manager.json" ]; then
    mkdir -p "$(dirname "$USER_DB_FILE")"
    mv -f /etc/sing-box/user-manager.json "$USER_DB_FILE" 2>/dev/null || cp -f /etc/sing-box/user-manager.json "$USER_DB_FILE"
  fi
  if ! user_db_exists; then
    say "首次进入用户管理，已默认启用 admin 用户。"
    user_db_save "$(user_db_min_template)"
    ok "默认用户 admin 已启用。"
  fi
  user_db_cleanup_current_and_save || true
  user_manager_runtime_sync || true
  return 0
}

user_manager_menu() {
  init_user_manager_if_needed || return 0
  sync_user_usage_counters >/dev/null 2>&1 || true
  user_db_cleanup_current_and_save >/dev/null 2>&1 || true
  while true; do
    local db_json
    db_json="$(user_db_load)"
    clear
    print_rect_title "用户管理"
    db_json="$(user_db_load)"
    show_user_status_table "$db_json"
    echo -e "  ${C}1.${NC} 新增用户"
    echo -e "  ${C}2.${NC} 管理用户"
    echo -e "  ${C}3.${NC} 删除用户"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) user_add_menu || true ;;
      2) user_select_and_manage_menu || true ;;
      3) user_delete_menu || true ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}
