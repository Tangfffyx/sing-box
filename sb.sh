#!/usr/bin/env bash

# ==================================================
# jq模板：统一把 auth_user 转成数组，避免字符串/数组混用导致的问题
AUTH_USER_ARRAY='
if (.auth_user? == null) then []
elif ((.auth_user | type) == "array") then .auth_user
else [ .auth_user ]
end
'
# ==================================================

set -Eeuo pipefail

# ====================================================
# Project : Sing-box Elite Management System
# Notes   : Single-file refactor, managed-route rebuild, no legacy compatibility.
# QA      : Manual regression checklist (run after each release):
#           1) 核心模块安装：Reality / AnyTLS / Shadowsocks / Trojan / VMess-WS / VLESS-WS / TUIC
#           2) 端口冲突：重复输入同协议同端口，必须提示冲突并要求重填
#           3) 导出配置：各协议链接非空，含 query 参数与 #名称片段
#           4) 用户管理：新增用户、授权节点、查看状态正常
#           5) 定时任务：系统工具 -> 定时任务管理，安装/移除状态与行为一致
#           6) 快捷入口：s 启动脚本版本与当前发布版本一致
# ====================================================

CONFIG_FILE="/etc/sing-box/config.json"
TEMP_FILE="/etc/sing-box/config.json.tmp"
SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
SCRIPT_BASE_DIR="$(cd "$(dirname "$SCRIPT_SELF")" 2>/dev/null && pwd -P || dirname "$SCRIPT_SELF")"
SCRIPT_LIB_DIR="${SCRIPT_BASE_DIR}/lib"
if [[ "$SCRIPT_SELF" == /dev/fd/* ]] || [[ "$SCRIPT_SELF" == /proc/*/fd/* ]] || [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/*/fd/* ]]; then
  SCRIPT_LIB_DIR="/tmp/sing-box/lib"
fi
SB_TARGET_SCRIPT="/root/sing-box.sh"
SB_SHORTCUT="/usr/local/bin/s"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/Tangfffyx/sing-box/refs/heads/codex/optimize-sb.sh-script/sb.sh"
REMOTE_SCRIPT_BASE_URL="${REMOTE_SCRIPT_URL%/sb.sh}"
SINGBOX_RELEASE_REPO="Tangfffyx/sing-box"
SINGBOX_INSTALL_DIR="/usr/local/bin"
SINGBOX_BIN="${SINGBOX_INSTALL_DIR}/sing-box"
SINGBOX_VERSION_STAMP="/etc/sing-box/.installed_release"
GRPCURL_BIN="/usr/local/bin/grpcurl"
V2RAY_API_LISTEN="127.0.0.1:18080"
V2RAY_PROTO_EXP="/etc/sing-box/v2rayapi-experimental.proto"
V2RAY_PROTO_V2RAY="/etc/sing-box/v2rayapi-v2ray.proto"
SCRIPT_VERSION="4.1.22"
USER_WATCH_CRON_MARK="sing-box.sh --user-watch"
USER_WATCH_CRON_SCHEDULE="*/5 * * * *"
LOG_MAINTAIN_CRON_MARK="sing-box.sh --maintain-logs"
LOG_MAINTAIN_CRON_SCHEDULE="0 4 * * *"
SCRIPT_LOG_FILE="/var/log/sing-box/access.log"
LOG_MAX_BYTES=$((10 * 1024 * 1024))

# ---------- UI ----------
B='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; NC='\033[0m'; W='\033[1;37m'

say()  { echo -e "${C}[INFO]${NC} $*"; }
ok()   { echo -e "${G}[ OK ]${NC} $*"; }
warn() { echo -e "${Y}[WARN]${NC} $*"; }
err()  { echo -e "${R}[ERR ]${NC} $*"; }
pause(){ read -r -n 1 -p "按任意键继续..." || true; echo ""; }
ui_echo(){ printf '%b\n' "$*" >&2; }

text_display_width() {
  local s="${1:-}"
  local width=0
  local i ch ord

  for ((i=0; i<${#s}; i++)); do
    ch="${s:i:1}"

    LC_ALL=C printf -v ord '%d' "'$ch" 2>/dev/null || ord=255

    if (( ord >= 32 && ord <= 126 )); then
      width=$((width + 1))
    else
      width=$((width + 2))
    fi
  done

  echo "$width"
}

pad_display_text() {
  local text="${1:-}"
  local target_width="${2:-0}"
  local current_width pad
  current_width="$(text_display_width "$text")"
  if [ "$current_width" -ge "$target_width" ]; then
    printf "%s" "$text"
    return 0
  fi
  pad=$((target_width - current_width))
  printf "%s%*s" "$text" "$pad" ""
}

print_rect_title() {
  local title="$1"
  local inner_width=46
  local title_width pad left right line

  title_width=$(text_display_width "$title")
  pad=$(( inner_width - title_width ))
  (( pad < 0 )) && pad=0

  left=$(( pad / 2 ))
  right=$(( pad - left ))

  line=$(printf '%*s' "$inner_width" '' | tr ' ' '-')

  printf "%b+%s+%b\n" "$B" "$line" "$NC"
  printf "%b|%*s%s%*s|%b\n" "$B" "$left" "" "$title" "$right" "" "$NC"
  printf "%b+%s+%b\n" "$B" "$line" "$NC"
}

cleanup() { rm -f "$TEMP_FILE"; }
trap cleanup EXIT

# ====================================================
# 100 Utils
# ====================================================
require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 运行此脚本。"
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

json_file_load_or_fallback() {
  local file="$1" fallback_json="$2" validator="${3:-.}"
  if [ -s "$file" ] && jq -e "$validator" "$file" >/dev/null 2>&1; then
    cat "$file"
  else
    printf '%s\n' "$fallback_json"
  fi
}

json_file_save_pretty() {
  local file="$1" json="$2"
  shift 2 || true

  local dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir" "$@"

  tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$json" | jq . > "$tmp"; then
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 1
  fi
  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 1
  fi
}

singbox_service_active() {
  has_cmd systemctl && systemctl is-active --quiet sing-box 2>/dev/null
}

pkg_status() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true; }
pkg_installed() { [ "$(pkg_status "$1")" = "installed" ]; }

apt_update_once() {
  local stamp="/tmp/.sb_v3_apt_updated"
  if [ -f "$stamp" ]; then
    ok "apt-get update 已执行过（本次会话）。"
    return 0
  fi
  say "执行 apt-get update"
  apt-get update -y
  touch "$stamp"
}

install_pkg_apt() {
  local pkg="$1"
  if pkg_installed "$pkg"; then
    ok "依赖已存在: $pkg"
    return 0
  fi
  apt_update_once
  say "安装依赖: $pkg"
  apt-get install -y "$pkg"
}

generate_random_alpha_path() {
  local s=""
  while [ ${#s} -lt 7 ]; do
    s="$(openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z' | head -c 7 || true)"
  done
  echo "/$s"
}

normalize_ws_path() {
  local p="${1:-}"
  if [ -z "$p" ]; then
    generate_random_alpha_path
    return 0
  fi
  [[ "$p" != /* ]] && p="/$p"
  echo "$p"
}

get_public_ip() {
  local ip=""
  ip=$(curl -s4 --max-time 3 --connect-timeout 2 ifconfig.me 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 api.ipify.org 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 icanhazip.com 2>/dev/null | tr -d '\n' || true)
  [ -z "$ip" ] && ip="IP"
  echo "$ip"
}

parse_plus_selections() {
  local s="$1"
  local -A seen=()
  local out=()
  local x
  IFS='+' read -ra parts <<< "$s"
  for x in "${parts[@]}"; do
    x="$(echo "$x" | tr -d ' ')"
    [ -z "$x" ] && continue
    if [ -z "${seen[$x]:-}" ]; then
      out+=("$x")
      seen[$x]=1
    fi
  done
  printf "%s\n" "${out[@]}"
}

ask_confirm_yes() {
  local prompt="${1:-输入 YES 确认继续，其它任意输入取消: }"
  local ans
  read -r -p "$prompt" ans
  [ "$ans" = "YES" ]
}

is_valid_port() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  [ "$v" -ge 1 ] && [ "$v" -le 65535 ]
}

ask_port_or_return() {
  local prompt="$1" default="$2" outvar="$3"
  local val __retry
  while true; do
    read -r -p "$prompt" val
    if [ -z "$val" ]; then
      val="$default"
    fi
    if is_valid_port "$val"; then
      printf -v "$outvar" '%s' "$val"
      return 0
    fi
    warn "端口输入无效：${val}。请输入 1-65535 的数字，回车使用默认值 ${default}。"
    read -r -p "输入 1 重新填写，其它任意键返回上一级: " __retry
    [ "${__retry:-}" = "1" ] || return 1
  done
}

# ====================================================
# 200 Config / Validator / Service
# ====================================================
# shellcheck source=lib/config.sh
# (loaded later via modular bootstrap)
# ====================================================
# 300 Entry / Relay / Route helpers
# ====================================================
entry_key_prefix_by_type() {
  case "$1" in
    vless-reality) echo "reality" ;;
    anytls) echo "anytls" ;;
    shadowsocks) echo "ss" ;;
    trojan) echo "trojan" ;;
    vmess-ws) echo "vmess-ws" ;;
    vless-ws) echo "vless-ws" ;;
    tuic) echo "tuic" ;;
    *) return 1 ;;
  esac
}

entry_key_from_parts() {
  local proto="$1" port="$2"
  local prefix
  prefix="$(entry_key_prefix_by_type "$proto")" || return 1
  echo "${prefix}-${port}"
}

entry_key_to_protocol_label() {
  case "$1" in
    reality-*) echo "vless-reality" ;;
    anytls-*) echo "anytls" ;;
    ss-*) echo "shadowsocks" ;;
    trojan-*) echo "trojan" ;;
    vmess-ws-*) echo "vmess-ws" ;;
    vless-ws-*) echo "vless-ws" ;;
    tuic-*) echo "tuic" ;;
    *) echo "unknown" ;;
  esac
}

entry_key_to_port() {
  echo "$1" | awk -F- '{print $NF}'
}

relay_user_name() {
  local entry_key="$1" land="$2"
  echo "${entry_key}-to-${land}"
}

relay_outbound_tag() {
  local entry_key="$1" land="$2"
  echo "to-${land}"
}

relay_user_to_outbound() {
  if [[ "$1" =~ -to-(.+)$ ]]; then echo "to-${BASH_REMATCH[1]}"; else echo "out-$1"; fi
}

protocol_entry_inventory() {
  local json="$1"
  echo "$json" | jq -r '
    .inbounds[]?
    | (
        if .type == "vless" and (.tls.reality.enabled // false) then "vless-reality"
        elif .type == "anytls" then "anytls"
        elif .type == "shadowsocks" then "shadowsocks"
        elif .type == "trojan" then "trojan"
        elif .type == "vmess" and ((.transport.type // "") == "ws") then "vmess-ws"
        elif .type == "vless" and ((.transport.type // "") == "ws") then "vless-ws"
        elif .type == "tuic" then "tuic"
        else ""
        end
      ) as $proto
    | select($proto != "")
    | [(.tag // ""), $proto, ((.listen_port // 0) | tostring)]
    | @tsv
  '
}

protocol_entry_inventory_ext() {
  local json="$1"
  echo "$json" | jq -r '
    .inbounds
    | to_entries[]?
    | .key as $idx
    | .value as $ib
    | (
        if $ib.type == "vless" and ($ib.tls.reality.enabled // false) then "vless-reality"
        elif $ib.type == "anytls" then "anytls"
        elif $ib.type == "shadowsocks" then "shadowsocks"
        elif $ib.type == "trojan" then "trojan"
        elif $ib.type == "vmess" and (($ib.transport.type // "") == "ws") then "vmess-ws"
        elif $ib.type == "vless" and (($ib.transport.type // "") == "ws") then "vless-ws"
        elif $ib.type == "tuic" then "tuic"
        else ""
        end
      ) as $proto
    | select($proto != "")
    | [$idx, ($ib.tag // ""), $proto, (($ib.listen_port // 0) | tostring)]
    | @tsv
  '
}

inbound_protocol_name() {
  local inbound="$1"
  echo "$inbound" | jq -r '
    if .type == "vless" and (.tls.reality.enabled // false) then "vless-reality"
    elif .type == "anytls" then "anytls"
    elif .type == "shadowsocks" then "shadowsocks"
    elif .type == "trojan" then "trojan"
    elif .type == "vmess" and ((.transport.type // "") == "ws") then "vmess-ws"
    elif .type == "vless" and ((.transport.type // "") == "ws") then "vless-ws"
    elif .type == "tuic" then "tuic"
    else ""
    end
  '
}

# --------------------------------------------------
# remove_relays_by_user_names
# 作用：
#   删除指定 relay user
#   更新相关 route.rules
#   不直接删除 outbound，由 route_rebuild 最终清理
# --------------------------------------------------
remove_relays_by_user_names(){
  local json="$1" users_json="$2"
  local updated_json

  updated_json="$(
    echo "$json" | jq --argjson users "$users_json" '
      def auth_users_array:
        if (.auth_user? == null) then []
        elif ((.auth_user | type) == "array") then .auth_user
        else [ .auth_user ]
        end;

      .inbounds |= map(
        if .users? then
          .users |= map(select(((.name // "") as $n | ($users | index($n))) == null))
        else . end
      )
      | .route.rules |= map(
          if (.auth_user? == null) then .
          else
            (auth_users_array | map(select(($users | index(.)) == null))) as $remain
            | if ($remain | length) == 0 then empty
              elif ($remain | length) == 1 then .auth_user = $remain[0]
              else .auth_user = $remain
              end
          end
        )
    '
  )" || return 1

  route_rebuild "$updated_json" || return 1
}

# --------------------------------------------------
# route_rebuild
# 作用：
#   根据当前 inbounds/users 重建托管 route 规则
#   自动生成 direct 规则
#   自动生成 relay 规则
#   清理无引用的 relay outbound
# 注意：
#   不会修改非托管 route
# --------------------------------------------------
route_rebuild(){
  local json="$1"
  local normalized core_users_json relay_pairs_json preserved_rules_json

  normalized="$(config_normalize "$json")" || return 1

  core_users_json="$({
    while IFS=$'	' read -r entry user_name; do
      [ -n "$user_name" ] || continue
      if [ "$(user_node_part "$user_name")" = "$entry" ]; then
        echo "$user_name"
      fi
    done < <(echo "$normalized" | jq -r '.inbounds[]? | .tag as $entry | (.users // [])[]? | [$entry, (.name // "")] | @tsv')
  } | awk 'NF' | sort -u | jq -R . | jq -s '.')" || return 1

  relay_pairs_json="$({
    while IFS=$'	' read -r entry relay_user out_tag; do
      [ -z "${relay_user:-}" ] && continue
      [ -z "${out_tag:-}" ] && continue
      if echo "$normalized" | jq -e --arg ot "$out_tag" '.outbounds[]? | select((.tag // "") == $ot)' >/dev/null 2>&1; then
        jq -n --arg u "$relay_user" --arg o "$out_tag" '{u:$u,o:$o}'
      fi
    done < <(relay_list_table "$normalized")
  } | jq -s 'sort_by(.o, .u) | unique_by(.u)')" || return 1

  preserved_rules_json="$(
    echo "$normalized" | jq -c '
      [ .route.rules[]? | select(.auth_user? == null) ]
    '
  )" || return 1

  echo "$normalized" | jq --argjson core "$core_users_json" --argjson relay "$relay_pairs_json" --argjson kept "$preserved_rules_json" '
    .route.rules = (
      ($kept // [])
      + (if ($core | length) > 0 then [{auth_user:($core | unique | sort),outbound:"direct"}] else [] end)
      + (($relay // []) | group_by(.o) | map({auth_user:(map(.u) | unique | sort), outbound:.[0].o}))
    )
    | .route.rules |= unique_by((.outbound // "") + "|" + (((.auth_user // []) | if type == "array" then . else [.] end | sort) | join(",")))
    | . as $root
    | .outbounds |= map(
        (.tag // "") as $tag
        | select(
            (
              ($tag != "direct")
              and (($tag | startswith("out-")) or ($tag | startswith("to-")))
              and (([$root.route.rules[]? | .outbound // empty] | index($tag)) == null)
            ) | not
          )
      )
    | .route.final = "reject"
  ' || return 1
}
protocol_transport_layer() {

  case "$1" in
    tuic) echo "udp" ;;
    *) echo "tcp" ;;
  esac
}

config_port_in_use_by_layer() {
  local json="$1" port="$2" layer="$3" exclude_tag="${4:-}"
  if [ "$layer" = "udp" ]; then
    echo "$json" | jq -e --arg p "$port" --arg ex "$exclude_tag" '
      .inbounds[]?
      | select((.listen_port? // empty | tostring) == $p)
      | select(.type=="tuic")
      | select(($ex == "") or ((.tag // "") != $ex))
    ' >/dev/null 2>&1
  else
    echo "$json" | jq -e --arg p "$port" --arg ex "$exclude_tag" '
      .inbounds[]?
      | select((.listen_port? // empty | tostring) == $p)
      | select(.type!="tuic")
      | select(($ex == "") or ((.tag // "") != $ex))
    ' >/dev/null 2>&1
  fi
}

port_conflict_for_protocol() {
  local json="$1" proto="$2" port="$3" exclude_tag="${4:-}"
  local layer
  layer="$(protocol_transport_layer "$proto")"
  config_port_in_use_by_layer "$json" "$port" "$layer" "$exclude_tag"
}

find_inbound_by_entry_key() {
  local json="$1" entry_key="$2"
  echo "$json" | jq -c --arg ek "$entry_key" '.inbounds[]? | select(.tag==$ek)' | head -n1
}

# ====================================================
# 400 Protocol builders / removers
# ====================================================
protocol_status_summary() {
  local json="$1"
  local all_lines proto label ports
  all_lines="$(protocol_entry_inventory "$json")"

  for proto in vless-reality anytls shadowsocks trojan vmess-ws vless-ws tuic; do
    label="$proto"
    ports="$(printf '%s
' "$all_lines" | awk -F '	' -v p="$proto" 'NF >= 3 && $2 == p { print $3 }' | sort -n | uniq | paste -sd'|' -)"

    if [ -n "$ports" ]; then
      printf '%s	%s	%s
' "$label" "已安装" "$ports"
    else
      printf '%s	%s	%s
' "$label" "未安装" ""
    fi
  done
}

protocol_entry_table() {
  local json="$1"
  protocol_entry_inventory "$json"
}

show_managed_relay_lines() {
  local json="$1"
  local found=0
  local seen=""
  local relay_node
  while IFS=$'	' read -r entry relay_user out_tag; do
    [ -z "${relay_user:-}" ] && continue
    relay_node="$(user_node_part "$relay_user")"
    [ -n "$relay_node" ] || continue
    if printf '%s
' "$seen" | grep -Fxq "$relay_node"; then
      continue
    fi
    seen="${seen}${relay_node}"$'
'
    found=1
    echo -e "  - ${G}${relay_node}${NC}"
  done < <(relay_list_table "$json")
  [ $found -eq 1 ]
}

build_vless_reality_inbound() {
  local port="$1" sni="$2" priv="$3" sid="$4"
  local entry_key uuid sid_json
  entry_key="$(entry_key_from_parts vless-reality "$port")"
  uuid="$(sing-box generate uuid)"
  if [ -n "$sid" ]; then
    sid_json="[\"$sid\"]"
  else
    sid_json='[]'
  fi
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv" --argjson sid "$sid_json" --argjson port "$port" '
    {
      "type":"vless",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid,"flow":"xtls-rprx-vision"}],
      "tls":{
        "enabled":true,
        "server_name":$sni,
        "reality":{
          "enabled":true,
          "handshake":{"server":$sni,"server_port":443},
          "private_key":$priv,
          "short_id":$sid
        }
      }
    }
  '
}

ensure_self_signed_cert() {
  local cn="$1" crt_path="$2" key_path="$3"
  mkdir -p "$(dirname "$crt_path")"
  openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$key_path" -out "$crt_path" -days 36500 -nodes -subj "/CN=${cn}" >/dev/null 2>&1
}

build_anytls_inbound() {
  local port="$1" sni="$2"
  local entry_key pass crt key
  entry_key="$(entry_key_from_parts anytls "$port")"
  pass="$(openssl rand -base64 16)"
  crt="/etc/sing-box/anytls-${port}.crt"
  key="/etc/sing-box/anytls-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key"
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"anytls",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "padding_scheme":[],
      "tls":{
        "enabled":true,
        "server_name":$sni,
        "certificate_path":$crt,
        "key_path":$key,
        "alpn":["h2","http/1.1"]
      }
    }
  '
}

ss2022_normalize_password_pair() {
  local raw="$1"
  local sp up
  if [ -z "$raw" ]; then
    sp="$(openssl rand -base64 16)"
    up="$(openssl rand -base64 16)"
    echo "${sp}:${up}"
    return 0
  fi
  sp="${raw%%:*}"
  up=""
  [[ "$raw" == *:* ]] && up="${raw#*:}"
  if ! echo "$sp" | base64 -d >/dev/null 2>&1; then sp="$(openssl rand -base64 16)"; fi
  if [ -n "$up" ] && ! echo "$up" | base64 -d >/dev/null 2>&1; then up="$(openssl rand -base64 16)"; fi
  if [ -n "$up" ]; then echo "${sp}:${up}"; else echo "$sp"; fi
}

build_ss_inbound() {
  local port="$1"
  local entry_key server_p user_p
  entry_key="$(entry_key_from_parts shadowsocks "$port")"
  server_p="$(openssl rand -base64 16)"
  user_p="$(openssl rand -base64 16)"
  jq -n --arg tag "$entry_key" --arg sp "$server_p" --arg up "$user_p" --argjson port "$port" '
    {
      "type":"shadowsocks",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "method":"2022-blake3-aes-128-gcm",
      "password":$sp,
      "users":[{"name":$tag,"password":$up}]
    }
  '
}

build_trojan_inbound() {
  local port="$1" sni="$2"
  local entry_key pass crt key
  entry_key="$(entry_key_from_parts trojan "$port")"
  pass="$(openssl rand -base64 16)"
  crt="/etc/sing-box/trojan-${port}.crt"
  key="/etc/sing-box/trojan-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key"
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"trojan",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "tls":{
        "enabled":true,
        "server_name":$sni,
        "certificate_path":$crt,
        "key_path":$key
      }
    }
  '
}

build_vmess_ws_inbound() {
  local port="$1" listen="$2" path="$3"
  local entry_key uuid
  entry_key="$(entry_key_from_parts vmess-ws "$port")"
  uuid="$(sing-box generate uuid)"
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg listen "$listen" --arg path "$path" --argjson port "$port" '
    {
      "type":"vmess",
      "tag":$tag,
      "listen":$listen,
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid,"alterId":0}],
      "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
    }
  '
}

build_vless_ws_inbound() {
  local port="$1" listen="$2" path="$3"
  local entry_key uuid
  entry_key="$(entry_key_from_parts vless-ws "$port")"
  uuid="$(sing-box generate uuid)"
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg listen "$listen" --arg path "$path" --argjson port "$port" '
    {
      "type":"vless",
      "tag":$tag,
      "listen":$listen,
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid}],
      "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
    }
  '
}

build_tuic_inbound() {
  local port="$1" sni="$2"
  local entry_key uuid pass crt key
  entry_key="$(entry_key_from_parts tuic "$port")"
  uuid="$(sing-box generate uuid)"
  pass="$(openssl rand -base64 12)"
  crt="/etc/sing-box/tuic-${port}.crt"
  key="/etc/sing-box/tuic-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key"
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"tuic",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid,"password":$pass}],
      "tls":{"enabled":true,"server_name":$sni,"alpn":["h3"],"certificate_path":$crt,"key_path":$key},
      "congestion_control":"bbr"
    }
  '
}

cleanup_inbound_generated_cert_files() {
  local json="$1" entry_key="$2"
  local crt key
  crt="$(echo "$json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.certificate_path // empty' | head -n1)"
  key="$(echo "$json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.key_path // empty' | head -n1)"
  if [ -n "$crt" ] && [[ "$crt" == /etc/sing-box/* ]]; then
    rm -f "$crt" >/dev/null 2>&1 || true
  fi
  if [ -n "$key" ] && [[ "$key" == /etc/sing-box/* ]]; then
    rm -f "$key" >/dev/null 2>&1 || true
  fi
}

# --------------------------------------------------
# remove_inbound_by_entry_key
# 作用：
#   删除指定 entry_key 对应的 inbound
#   同时清理该 inbound 关联的 users 和 route 规则
#   最终由 route_rebuild 统一收口
# --------------------------------------------------
remove_inbound_by_entry_key(){
  local json="$1" entry_key="$2"
  local inbound_users_json related_outbounds_json updated_json

  inbound_users_json="$(
    echo "$json" | jq -c --arg ek "$entry_key" '
      [
        .inbounds[]?
        | select(.tag == $ek)
        | (.users // [])[]?
        | .name // empty
        | select(. != "")
      ]
    '
  )" || return 1

  related_outbounds_json="$(
    echo "$json" | jq -c --argjson users "$inbound_users_json" '
      def auth_users_array:
        if (.auth_user? == null) then []
        elif ((.auth_user | type) == "array") then .auth_user
        else [ .auth_user ]
        end;

      (
        [
          .route.rules[]?
          | select((auth_users_array | any(. as $u | (($users | index($u)) != null))))
          | .outbound // empty
          | select(. != "" and . != "direct")
        ]
        + [
            ($users // [])[] as $u
            | (["out-" + $u] + (if ($u | contains("-to-")) then ["out-to-" + (($u | capture(".*-to-(?<land>.+)$").land)), "to-" + (($u | capture(".*-to-(?<land>.+)$").land))] else [] end))[] as $cand
            | .outbounds[]?
            | .tag // empty
            | select(. == $cand)
          ]
      ) | unique
    '
  )" || return 1

  updated_json="$(
    echo "$json" | jq --arg ek "$entry_key" --argjson users "$inbound_users_json" '
      .inbounds |= map(select((.tag // "") != $ek))
      | .route.rules |= map(
          select(
            (
              .auth_user? as $au
              | if $au == null then true
                else
                  (
                    if ($au | type) == "array" then $au else [ $au ] end
                  ) as $arr
                  | any($arr[]; . as $u | (($users | index($u)) != null)) | not
                end
            )
          )
        )
    '
  )" || return 1

  echo "$updated_json" | jq --argjson outs "$related_outbounds_json" '
    . as $root
    | .outbounds |= map(
        (.tag // "") as $tag
        | select(
            (
              (($outs | index($tag)) != null)
              and (([$root.route.rules[]? | .outbound // empty] | index($tag)) == null)
            ) | not
          )
      )
  ' || return 1
}

remove_relays_for_entry_key() {
  local json="$1" entry_key="$2"
  local relay_users_json

  relay_users_json="$(
    echo "$json" | jq -c --arg ek "$entry_key" '
      def node_part($s):
        if ($s | contains("@")) then ($s | split("@")[0]) else $s end;
      [
        .inbounds[]?
        | select(.tag == $ek)
        | (.users // [])[]?
        | .name // empty
        | select(. != "" and (node_part(.) != $ek))
      ]
    '
  )"

  remove_relays_by_user_names "$json" "$relay_users_json"
}

# ====================================================
# 500 Relay management
# ====================================================
relay_list_table() {
  local json="$1"
  echo "$json" | jq -r '
    def node_part($s):
      if ($s | contains("@")) then ($s | split("@")[0]) else $s end;

    def inbound_proto:
      if .type == "vless" and (.tls.reality.enabled // false) then "vless-reality"
      elif .type == "anytls" then "anytls"
      elif .type == "shadowsocks" then "shadowsocks"
      elif .type == "trojan" then "trojan"
      elif .type == "vmess" and ((.transport.type // "") == "ws") then "vmess-ws"
      elif .type == "vless" and ((.transport.type // "") == "ws") then "vless-ws"
      elif .type == "tuic" then "tuic"
      else ""
      end;

    def auth_users_array:
      if (.auth_user? == null) then []
      elif ((.auth_user | type) == "array") then .auth_user
      else [ .auth_user ]
      end;

    . as $root
    | [
        .inbounds[]?
        | select((inbound_proto) != "")
        | .tag as $entry
        | (.users // [])[]?
        | (.name // empty) as $name
        | (node_part($name)) as $node
        | select($name != "" and $node != $entry and ($node | contains("-to-")))
        | [
            $root.route.rules[]?
            | select((auth_users_array | index($name)) != null)
            | .outbound // empty
            | select(. != "" and . != "direct")
          ] as $outs
        | [
            (["out-" + $node] + (if ($node | contains("-to-")) then ["out-to-" + (($node | capture(".*-to-(?<land>.+)$").land)), "to-" + (($node | capture(".*-to-(?<land>.+)$").land))] else [] end))[] as $cand
            | $root.outbounds[]?
            | .tag // empty
            | select(. == $cand)
          ] as $fallback_outs
        | [$entry, $name, (if ($outs | length) > 0 then $outs[0] elif ($fallback_outs | length) > 0 then $fallback_outs[0] else "" end)]
      ]
    | unique
    | .[]
    | @tsv
  ' || return 1
}

relay_add() {
  init_manager_env
  local json lines=() entry_key choice land ip relay_port pw normalized_pw relay_user out_tag inbound
  json="$(config_load)"

  mapfile -t lines < <(protocol_entry_table "$json")
  if [ ${#lines[@]} -eq 0 ]; then
    err "当前没有任何主入站，请先在核心模块管理里安装协议。"
    pause
    return 1
  fi

  clear
  echo -e "${C}--- 添加/覆盖中转节点 ---${NC}"
  echo -e "${C}请选择主入站：${NC}"
  local i=1 tag port
  for line in "${lines[@]}"; do
    IFS=$'	' read -r tag proto port <<< "$line"
    echo -e "  [$i] ${G}${tag}${NC}"
    i=$((i+1))
  done
  echo ""
  echo -e "${C}当前已配置中转节点：${NC}"
  if ! show_managed_relay_lines "$json"; then
    echo -e "  ${Y}当前没有中转节点。${NC}"
  fi
  read -r -p "请选择编号（回车返回上一级）: " choice
  if [ -z "${choice:-}" ]; then
    return 0
  fi
  if ! [[ "${choice:-}" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#lines[@]}" ]; then
    warn "无效选择，已返回上一级。"
    pause
    return 0
  fi
  IFS=$'	' read -r entry_key _ _ <<< "${lines[$((choice-1))]}"
  inbound="$(find_inbound_by_entry_key "$json" "$entry_key")"

  read -r -p "落地标识 (如 sg01): " land
  [ -z "${land:-}" ] && { warn "已取消，返回上一级。"; pause; return 0; }
  read -r -p "落地 IP 地址: " ip
  [ -z "${ip:-}" ] && { warn "已取消，返回上一级。"; pause; return 0; }
  read -r -p "落地端口（默认: 8080）: " relay_port
  relay_port="${relay_port:-8080}"
  if ! [[ "$relay_port" =~ ^[0-9]+$ ]] || [ "$relay_port" -lt 1 ] || [ "$relay_port" -gt 65535 ]; then
    warn "落地端口无效，已返回上一级。"
    pause
    return 0
  fi
  read -r -p "落地 SS 2022 密钥（回车随机生成）: " pw
  normalized_pw="$(ss2022_normalize_password_pair "$pw")"

  relay_user="$(relay_user_name "$entry_key" "$land")"
  out_tag="$(relay_outbound_tag "$entry_key" "$land")"

  local new_user new_out updated_json inbound_type
  inbound_type="$(echo "$inbound" | jq -r '.type')"
  case "$inbound_type" in
    vless)
      if echo "$inbound" | jq -e '.tls.reality.enabled == true' >/dev/null 2>&1; then
        new_user="$(jq -n --arg name "$relay_user" --arg uuid "$(sing-box generate uuid)" '{name:$name,uuid:$uuid,flow:"xtls-rprx-vision"}')"
      else
        new_user="$(jq -n --arg name "$relay_user" --arg uuid "$(sing-box generate uuid)" '{name:$name,uuid:$uuid}')"
      fi
      ;;
    vmess)
      new_user="$(jq -n --arg name "$relay_user" --arg uuid "$(sing-box generate uuid)" '{name:$name,uuid:$uuid,alterId:0}')"
      ;;
    shadowsocks)
      new_user="$(jq -n --arg name "$relay_user" --arg pass "$(openssl rand -base64 16)" '{name:$name,password:$pass}')"
      ;;
    anytls)
      new_user="$(jq -n --arg name "$relay_user" --arg pass "$(openssl rand -base64 16)" '{name:$name,password:$pass}')"
      ;;
    trojan)
      new_user="$(jq -n --arg name "$relay_user" --arg pass "$(openssl rand -base64 16)" '{name:$name,password:$pass}')"
      ;;
    tuic)
      new_user="$(jq -n --arg name "$relay_user" --arg uuid "$(sing-box generate uuid)" --arg pass "$(openssl rand -base64 12)" '{name:$name,uuid:$uuid,password:$pass}')"
      ;;
    *)
      err "不支持的主入站类型：$inbound_type"
      pause
      return 1
      ;;
  esac

  new_out="$(jq -n --arg tag "$out_tag" --arg ip "$ip" --arg pw "$normalized_pw" --argjson p "$relay_port" '{type:"shadowsocks",tag:$tag,server:$ip,server_port:$p,method:"2022-blake3-aes-128-gcm",password:$pw}')"

  updated_json="$(echo "$json" | jq --arg ek "$entry_key" --arg ru "$relay_user" --arg ot "$out_tag" --argjson nu "$new_user" --argjson no "$new_out" '
    def auth_users_array:
      if (.auth_user? == null) then []
      elif ((.auth_user | type) == "array") then .auth_user
      else [ .auth_user ]
      end;

    .inbounds |= map(
      if .tag == $ek then
        .users = (((.users // []) | map(select((.name // "") != $ru))) + [$nu])
      else
        if .users? then .users |= map(select((.name // "") != $ru)) else . end
      end
    )
    | .outbounds = (
        ((.outbounds // []) | map(
          if (.tag // "") == $ot then $no else . end
        ))
        | if any(.[]?; (.tag // "") == $ot) then . else . + [$no] end
      )
    | .route.rules = (
        ((.route.rules // [])
          | map(select(((auth_users_array | index($ru)) == null) and ((.outbound // "") != $ot)))
        )
        + [{auth_user:[$ru], outbound:$ot}]
      )
  ')"
  updated_json="$(route_rebuild "$updated_json")" || {
    err "重建路由失败，已中止，未写入配置。"
    pause
    return 1
  }
  if user_db_exists; then
    local db_json
    db_json="$(user_db_load)"
    db_json="$(user_db_grant_node_to_enabled_users "$db_json" "$relay_user")"
    if user_manager_apply_changes "$db_json" "$updated_json"; then
      ok "中转节点已添加/覆盖：$relay_user"
    else
      warn "中转节点添加失败，已返回上一级。"
    fi
  else
    if config_apply "$updated_json"; then
      ok "中转节点已添加/覆盖：$relay_user"
    else
      warn "中转节点添加失败，已返回上一级。"
    fi
  fi
  pause
  return 0
}

relay_delete() {
  init_manager_env
  local json lines=() node_lines=() choice picks=() updated_json line entry relay_user out_tag part idx
  local node_key users_json
  json="$(config_load)"
  mapfile -t lines < <(relay_list_table "$json")
  if [ ${#lines[@]} -eq 0 ]; then
    warn "当前没有中转节点。"
    pause
    return 0
  fi

  mapfile -t node_lines < <(
    printf '%s
' "${lines[@]}" | awk -F '	' '
      function node_part(s) { sub(/@.*/, "", s); return s }
      {
        node=node_part($2)
        if (!(node in seen)) {
          seen[node]=1
          print $1 "	" node "	" $3
        }
      }'
  )

  clear
  echo -e "${R}--- 删除中转节点 ---${NC}"
  local i=1
  for line in "${node_lines[@]}"; do
    IFS=$'	' read -r entry relay_user out_tag <<< "$line"
    echo -e " [$i] ${relay_user}"
    i=$((i+1))
  done
  read -r -p "请输入要删除的编号（支持 1+2+3，回车返回）: " choice
  [ -z "${choice:-}" ] && return 0
  mapfile -t picks < <(parse_plus_selections "$choice")
  [ ${#picks[@]} -eq 0 ] && { warn "未选择任何条目。"; pause; return 1; }

  updated_json="$json"
  for part in "${picks[@]}"; do
    if ! [[ "$part" =~ ^[0-9]+$ ]] || [ "$part" -lt 1 ] || [ "$part" -gt "${#node_lines[@]}" ]; then
      err "编号超出范围：$part"
      pause
      return 1
    fi
    idx=$((part-1))
    IFS=$'	' read -r entry node_key out_tag <<< "${node_lines[$idx]}"
    users_json="$({
      printf '%s
' "${lines[@]}" | awk -F '	' -v n="$node_key" '
        function node_part(s) { sub(/@.*/, "", s); return s }
        node_part($2)==n { print $2 }'
    } | awk 'NF' | sort -u | jq -R . | jq -s '.')"
    updated_json="$(remove_relays_by_user_names "$updated_json" "$users_json")" || {
      err "删除中转失败，已中止，未写入配置。"
      pause
      return 1
    }
  done

  if user_db_exists; then
    local db_json
    db_json="$(user_db_load)"
    db_json="$(user_db_cleanup_missing_nodes "$db_json" "$updated_json")"
    if ! user_manager_apply_changes "$db_json" "$updated_json"; then
      warn "删除中转失败，已返回上一级。"
    fi
  else
    if ! config_apply "$updated_json"; then
      warn "删除中转失败，已返回上一级。"
    fi
  fi
  pause
  return 0
}

manage_relay_nodes() {
  init_manager_env
  while true; do
    clear
    local json
    json="$(config_load)"
    print_rect_title "中转节点管理"
    if relay_list_table "$json" >/tmp/.sb_relay_list.$$ && [ -s /tmp/.sb_relay_list.$$ ]; then
      awk -F '\t' 'NF >= 2 {print $2}' /tmp/.sb_relay_list.$$ | while IFS= read -r relay_user; do
        [ -n "$relay_user" ] || continue
        relay_node="$(user_node_part "$relay_user")"
        [ -n "$relay_node" ] || continue
        if [ -z "${_relay_seen:-}" ]; then _relay_seen=""; fi
        if printf '%s\n' "$_relay_seen" | grep -Fxq "$relay_node"; then
          continue
        fi
        _relay_seen="${_relay_seen}${relay_node}"$'\n'
        echo -e "  - ${G}${relay_node}${NC}"
      done
      unset _relay_seen
    else
      echo -e "  ${Y}当前没有中转节点。${NC}"
    fi
    rm -f /tmp/.sb_relay_list.$$ >/dev/null 2>&1 || true
    echo -e "${B}----------------------------------------${NC}"
    echo -e "  ${C}1.${NC} 添加/覆盖中转"
    echo -e "  ${C}2.${NC} 删除中转"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) relay_add || true ;;
      2) relay_delete || true ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}



ensure_v2ray_api_proto_files() {
  mkdir -p /etc/sing-box
  cat > "$V2RAY_PROTO_EXP" <<'EOF_V2E'
syntax = "proto3";
package experimental.v2rayapi;
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
EOF_V2E

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
      "allow_all_nodes": true,
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
    (.users[$u].allow_all_nodes == true) or ((.users[$u].nodes // []) | index($n) != null)
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
        | map(select(($available | index(.)) != null))
        | unique
      )
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
  local db_json="$1" base_json="${2:-}"
  [ -n "$base_json" ] || base_json="$(config_load)"

  say "更新用户数据库..."
  user_db_save "$db_json"
  ok "用户数据库已保存。"

  say "重新生成用户节点关系..."
  db_json="$(user_db_load)"
  db_json="$(user_db_cleanup_missing_nodes "$db_json" "$base_json")" || return 1
  user_db_save "$db_json"
  local applied_json
  applied_json="$(user_manager_apply_to_json "$base_json" "$db_json")" || {
    err "生成用户节点关系失败。"
    return 1
  }
  ok "用户节点关系已更新。"

  say "重建路由规则..."
  ok "路由规则已重建。"

  if config_apply "$applied_json"; then
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
  sync_user_usage_counters || true
  db_json="$(user_db_load)"
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
      + "到期时间：" + (if (($x.expire_at // "0") == "0") then "永久" else $x.expire_at end) + "\n"
      + "节点策略：" + (if ($x.allow_all_nodes // false) then "全部节点" else "自定义节点" end)
  '
  echo "允许节点："
  if echo "$db_json" | jq -e --arg u "$username" '.users[$u].allow_all_nodes == true' >/dev/null 2>&1; then
    echo "  - 全部节点"
  else
    echo "$db_json" | jq -r --arg u "$username" '.users[$u].nodes[]? // empty' | sed 's/^/  - /'
  fi
}

user_add_menu() {
  local db_json json username quota reset_day expire_at ans nodes_json allow_all_json
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
  allow_all_json='false'
  nodes_json='[]'
  db_json="$(echo "$db_json" | jq --arg u "$username" --argjson quota "$quota" --argjson reset "$reset_day" --arg expire "$expire_at" --argjson allow "$allow_all_json" --argjson nodes "$nodes_json" '
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
      allow_all_nodes: $allow,
      nodes: $nodes
    }
  ')"
  user_manager_apply_changes "$db_json" "$json" || { pause; return 1; }
  pause
}

user_manage_permission_menu() {
  local db_json="$1" username="$2" json="$3"
  local cleaned_db_json
  cleaned_db_json="$(user_db_cleanup_missing_nodes "$db_json" "$json")" || cleaned_db_json="$db_json"
  if [ "$(echo "$cleaned_db_json" | jq -c . 2>/dev/null)" != "$(echo "$db_json" | jq -c . 2>/dev/null)" ]; then
    user_db_save "$cleaned_db_json"
  fi
  db_json="$cleaned_db_json"
  local current_nodes_json current_allow_all
  local nodes=() node i raw picks=() invalid=0 sel idx selected_json new_db

  clear >&2
  print_rect_title "节点权限" >&2
  show_user_status_table "$db_json" >&2
  current_allow_all="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].allow_all_nodes // false')"
  current_nodes_json="$(echo "$db_json" | jq -c --arg u "$username" '(.users[$u].nodes // [])')"

  if [ "$current_allow_all" = "true" ]; then
    ui_echo "当前权限类型：全部节点"
  else
    ui_echo "当前权限类型：自定义节点"
  fi
  ui_echo "当前已分配节点："
  if [ "$current_allow_all" = "true" ]; then
    ui_echo "- 全部节点"
  else
    while IFS= read -r node; do
      [ -n "$node" ] && ui_echo "- $node"
    done < <(echo "$current_nodes_json" | jq -r '.[]?')
    if ! echo "$current_nodes_json" | jq -e 'length > 0' >/dev/null 2>&1; then
      ui_echo "- （无）"
    fi
  fi
  ui_echo "${B}--------------------------------------------------------${NC}"

  mapfile -t nodes < <(list_all_node_keys "$json")
  ui_echo "可选节点："
  ui_echo "  1. 全部节点"
  i=2
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
    if [ "$sel" -lt 1 ] || [ "$sel" -gt $(( ${#nodes[@]} + 1 )) ]; then invalid=1; break; fi
  done

  if [ $invalid -eq 1 ]; then
    ui_echo "${Y}[WARN]${NC} 输入编号无效，未做任何修改。"
    pause >&2
    return 1
  fi

  if printf '%s
' "${picks[@]}" | grep -qx '1'; then
    new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].allow_all_nodes = true | .users[$u].nodes = []')"
    echo "$new_db"
    return 0
  fi

  selected_json="$({
    for sel in "${picks[@]}"; do
      idx=$((sel-2))
      if [ $idx -ge 0 ] && [ $idx -lt ${#nodes[@]} ]; then
        echo "${nodes[$idx]}"
      fi
    done
  } | awk 'NF' | LC_ALL=C sort -u | jq -R . | jq -s '.')"

  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson nodes "$selected_json" '.users[$u].allow_all_nodes = false | .users[$u].nodes = $nodes')"
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
    user_db_cleanup_current_and_save || true
    db_json="$(user_db_load)"
    json="$(config_load)"
    clear
    print_rect_title "管理用户"
    show_user_status_table "$db_json"
    echo "当前用户：$username"
    if [ "$username" = "admin" ]; then
      echo "admin 为系统默认用户，不可删除，默认拥有全部节点权限。"
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

# ====================================================
# 600 Export
# ====================================================

for _mod in config.sh export.sh cron.sh; do
  if [ ! -s "${SCRIPT_LIB_DIR}/${_mod}" ]; then
    mkdir -p "$SCRIPT_LIB_DIR" >/dev/null 2>&1 || true
    _self_module="$(dirname "$SCRIPT_SELF")/lib/${_mod}"
    if [ -s "$_self_module" ]; then
      cp -f "$_self_module" "${SCRIPT_LIB_DIR}/${_mod}" >/dev/null 2>&1 || true
    else
      curl -fsSL "${REMOTE_SCRIPT_BASE_URL}/lib/${_mod}" -o "${SCRIPT_LIB_DIR}/${_mod}" >/dev/null 2>&1 || true
    fi
  fi
done

# shellcheck source=lib/config.sh
source "${SCRIPT_LIB_DIR}/config.sh"

# shellcheck source=lib/export.sh
source "${SCRIPT_LIB_DIR}/export.sh"

# ====================================================
# 700 Installer / system tools
# ====================================================
ensure_deps_for_installer() {
  require_root
  has_cmd apt-get || { err "未找到 apt-get，本脚本按 Debian/Ubuntu APT 方式设计。"; exit 1; }
  say "检查并安装必要依赖..."
  install_pkg_apt sudo
  install_pkg_apt ca-certificates
  install_pkg_apt curl
  install_pkg_apt gnupg
  install_pkg_apt jq
  install_pkg_apt openssl
  install_pkg_apt tar
  install_pkg_apt gzip
}

ensure_sagernet_repo() { :; }

get_release_latest_tag() {
  local repo="${SINGBOX_RELEASE_REPO:-Tangfffyx/sing-box}"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty'
}

normalize_release_tag() {
  local v="${1:-}"
  v="${v#v}"
  echo "$v"
}

get_candidate_version() {
  normalize_release_tag "$(get_release_latest_tag)"
}

get_installed_version() {
  local stamp ver
  if [ -s "$SINGBOX_VERSION_STAMP" ]; then
    stamp="$(cat "$SINGBOX_VERSION_STAMP" 2>/dev/null || true)"
    stamp="${stamp#v}"
    [ -n "$stamp" ] && { echo "$stamp"; return 0; }
  fi
  if [ -x "$SINGBOX_BIN" ]; then
    ver="$("$SINGBOX_BIN" version 2>/dev/null | awk '/^sing-box version / {print $3; exit}')"
    ver="${ver#v}"
    [ "$ver" != "unknown" ] && [ -n "$ver" ] && { echo "$ver"; return 0; }
  fi
  echo ""
}

show_versions() {
  local inst cand
  inst="$(get_installed_version)"
  cand="$(get_candidate_version)"
  echo -e "${W}-------- 版本信息 --------${NC}"
  echo -e " Installed : ${inst:-<not installed>}"
  echo -e " Candidate : ${cand:-<none>}"
  echo -e "${W}--------------------------${NC}"
}


script_version_of_file() {
  local f="${1:-}"
  [ -f "$f" ] || return 1
  grep -E '^[[:space:]]*SCRIPT_VERSION=' "$f" 2>/dev/null | head -n1 | sed -E 's/^[^"]*"([^"]+)".*$/\1/'
}

copy_running_script_to_target() {
  local current="${1:-${SCRIPT_SELF:-${BASH_SOURCE[0]:-$0}}}"
  [ -r "$current" ] || return 1
  cat "$current" > "$SB_TARGET_SCRIPT" 2>/dev/null
}

download_remote_script_to_target() {
  local tmp
  tmp="$(mktemp)"
  curl -fsSL "$REMOTE_SCRIPT_URL" -o "$tmp" || {
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 1
  }
  mv -f "$tmp" "$SB_TARGET_SCRIPT" || {
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 1
  }
  return 0
}

copy_local_module_to_target() {
  local source_script="$1" module_file="$2"
  local source_base target_base
  source_base="$(cd "$(dirname "$source_script")" 2>/dev/null && pwd -P || dirname "$source_script")"
  target_base="$(dirname "$SB_TARGET_SCRIPT")"
  [ -s "${source_base}/lib/${module_file}" ] || return 1
  mkdir -p "${target_base}/lib" >/dev/null 2>&1 || return 1
  cp -f "${source_base}/lib/${module_file}" "${target_base}/lib/${module_file}"
}

download_remote_module_to_target() {
  local module_file="$1" target_base
  target_base="$(dirname "$SB_TARGET_SCRIPT")"
  mkdir -p "${target_base}/lib" >/dev/null 2>&1 || return 1
  curl -fsSL "${REMOTE_SCRIPT_BASE_URL}/lib/${module_file}" -o "${target_base}/lib/${module_file}"
}

sync_runtime_script_entrypoints() {
  local current="${SCRIPT_SELF:-${BASH_SOURCE[0]:-$0}}"
  local resolved current_ver target_ver
  resolved="$(readlink -f "$current" 2>/dev/null || echo "$current")"
  current_ver="${SCRIPT_VERSION:-}"
  target_ver="$(script_version_of_file "$SB_TARGET_SCRIPT" || true)"

  if [[ "$resolved" == /dev/fd/* ]] || [[ "$resolved" == /proc/self/fd/* ]] || [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]]; then
    if [ ! -s "$SB_TARGET_SCRIPT" ] || [ "$target_ver" != "$current_ver" ]; then
      download_remote_script_to_target || true
      download_remote_module_to_target "config.sh" || true
      download_remote_module_to_target "export.sh" || true
      download_remote_module_to_target "cron.sh" || true
    fi
  else
    if [ "$resolved" != "$SB_TARGET_SCRIPT" ] && { [ ! -s "$SB_TARGET_SCRIPT" ] || [ "$target_ver" != "$current_ver" ]; }; then
      cp -f "$resolved" "$SB_TARGET_SCRIPT" >/dev/null 2>&1 || true
      copy_local_module_to_target "$resolved" "config.sh" >/dev/null 2>&1 || true
      copy_local_module_to_target "$resolved" "export.sh" >/dev/null 2>&1 || true
      copy_local_module_to_target "$resolved" "cron.sh" >/dev/null 2>&1 || true
    fi
  fi

  chmod +x "$SB_TARGET_SCRIPT" >/dev/null 2>&1 || true
  install_sb_shortcut >/dev/null 2>&1 || true
}

install_script_self() {
  mkdir -p /usr/local/bin
  local current="${SCRIPT_SELF:-${BASH_SOURCE[0]:-$0}}"
  if [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]] || [[ "$current" == /dev/fd/* ]] || [[ "$current" == /proc/self/fd/* ]]; then
    download_remote_script_to_target || {
      warn "快捷命令 s 安装失败：无法下载脚本到 $SB_TARGET_SCRIPT"
      return 1
    }
    download_remote_module_to_target "config.sh" || {
      warn "快捷命令 s 安装失败：无法下载 config 模块。"
      return 1
    }
    download_remote_module_to_target "export.sh" || {
      warn "快捷命令 s 安装失败：无法下载 export 模块。"
      return 1
    }
    download_remote_module_to_target "cron.sh" || {
      warn "快捷命令 s 安装失败：无法下载 cron 模块。"
      return 1
    }
  else
    current="$(readlink -f "$current" 2>/dev/null || echo "$current")"
    if [ "$current" != "$SB_TARGET_SCRIPT" ]; then
      cp -f "$current" "$SB_TARGET_SCRIPT" || {
        warn "快捷命令 s 安装失败：无法复制脚本到 $SB_TARGET_SCRIPT"
        return 1
      }
      copy_local_module_to_target "$current" "config.sh" >/dev/null 2>&1 || true
      copy_local_module_to_target "$current" "export.sh" >/dev/null 2>&1 || true
      copy_local_module_to_target "$current" "cron.sh" >/dev/null 2>&1 || true
    fi
  fi
  chmod +x "$SB_TARGET_SCRIPT" >/dev/null 2>&1 || true
}

install_sb_shortcut() {
  cat > "$SB_SHORTCUT" <<'EOF2'
#!/bin/sh
exec bash /root/sing-box.sh "$@"
EOF2
  chmod +x "$SB_SHORTCUT" >/dev/null 2>&1 || true
}

ensure_sb_shortcut() {
  install_script_self || return 1
  install_sb_shortcut
  ok "已创建脚本快捷键：s"
}



maintain_script_log_file() {
  local log_file="${1:-$SCRIPT_LOG_FILE}" max_bytes="${2:-$LOG_MAX_BYTES}"
  [ -n "$log_file" ] || return 0
  [ -f "$log_file" ] || return 0
  [ -s "$log_file" ] || return 0

  local size tmp
  size="$(wc -c < "$log_file" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  [ "$size" -le "$max_bytes" ] && return 0

  tmp="$(mktemp)"
  tail -c "$max_bytes" "$log_file" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 1
  }
  cat "$tmp" > "$log_file"
  rm -f "$tmp" >/dev/null 2>&1 || true
  return 0
}

maintain_logs() {
  maintain_script_log_file "$SCRIPT_LOG_FILE" "$LOG_MAX_BYTES" || true
  return 0
}

config_force_access_log_settings() {
  [ -s "$CONFIG_FILE" ] || return 0
  mkdir -p /var/log/sing-box >/dev/null 2>&1 || true
  local json updated
  json="$(config_load)" || return 1
  updated="$(echo "$json" | jq '.log = (.log // {}) | .log.level = "info" | .log.output = "/var/log/sing-box/access.log" | .log.timestamp = true')" || return 1
  config_apply "$updated" || return 1
}


# shellcheck source=lib/cron.sh
source "${SCRIPT_LIB_DIR}/cron.sh"

remove_all_singbox_service_units() {
  say "清理 sing-box service（包含官方残留）..."
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl disable sing-box >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sing-box.service >/dev/null 2>&1 || true
  rm -f /usr/lib/systemd/system/sing-box.service >/dev/null 2>&1 || true
  rm -f /lib/systemd/system/sing-box.service >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "sing-box service 已清理。"
}

write_managed_singbox_service() {
  mkdir -p /etc/systemd/system /var/lib/sing-box /etc/sing-box
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} -D /var/lib/sing-box -c ${CONFIG_FILE} run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

ensure_command_compat_links() {
  mkdir -p /usr/bin
  ln -sf "${SINGBOX_BIN}" /usr/bin/sing-box
}

migrate_legacy_user_db_if_needed() {
  if [ ! -e "$USER_DB_FILE" ] && [ -e "/etc/sing-box/user-manager.json" ]; then
    mkdir -p "$(dirname "$USER_DB_FILE")"
    mv -f /etc/sing-box/user-manager.json "$USER_DB_FILE" 2>/dev/null || cp -f /etc/sing-box/user-manager.json "$USER_DB_FILE"
  fi
}



is_script_managed_environment() {
  [ -f /etc/systemd/system/sing-box.service ] || return 1
  grep -Fq "ExecStart=${SINGBOX_BIN} -D /var/lib/sing-box -c /etc/sing-box/config.json run" /etc/systemd/system/sing-box.service 2>/dev/null || return 1
  [ -f /usr/local/bin/s ] && grep -Fq 'exec bash /root/sing-box.sh "$@"' /usr/local/bin/s 2>/dev/null || return 1
  return 0
}


prepare_script_runtime() {
  say "准备脚本运行环境..."
  migrate_legacy_user_db_if_needed
  write_managed_singbox_service
  ensure_command_compat_links
  mkdir -p /var/log/sing-box >/dev/null 2>&1 || true
  systemctl daemon-reload
  ok "脚本运行环境已就绪。"
}

install_or_update_singbox() {
  clear
  echo -e "${B}+----------------------------------------------+${NC}"
  echo -e "${B}|           Sing-box Installer / Updater       |${NC}"
  echo -e "${B}+----------------------------------------------+${NC}"

  ensure_deps_for_installer

  sync_user_usage_counters || true

  local arch file tag latest_ver inst ans tmp_dir base_url download_url sha_url managed_env
  arch="$(uname -m)"
  case "$arch" in
    x86_64) file="sing-box-linux-amd64.tar.gz" ;;
    aarch64|arm64) file="sing-box-linux-arm64.tar.gz" ;;
    armv7l|armv7) file="sing-box-linux-armv7.tar.gz" ;;
    i386|i686) file="sing-box-linux-386.tar.gz" ;;
    *)
      err "不支持的架构：$arch"
      pause
      return 1
      ;;
  esac

  tag="$(get_release_latest_tag)"
  latest_ver="$(normalize_release_tag "$tag")"

  managed_env="0"
  inst=""
  if is_script_managed_environment; then
    managed_env="1"
    inst="$(get_installed_version)"
  fi

  if [ -z "${latest_ver:-}" ]; then
    err "未获取到 GitHub Release 最新版本。"
    pause
    return 1
  fi

  if [ "${managed_env}" != "1" ] && command -v sing-box >/dev/null 2>&1; then
    ui_echo "[WARN] 检测到已有非本脚本安装的 sing-box 环境，请先执行“卸载 sing-box”后再安装。"
    pause >&2
    return 0
  fi

  if [ "${managed_env}" = "1" ]; then
    echo -e "当前版本：${G}${inst:-未知}${NC}"
    echo -e "最新版本：${G}${latest_ver}${NC}"
    if [ -n "${inst:-}" ] && ! dpkg --compare-versions "$inst" lt "$latest_ver"; then
      ok "当前已是最新版本。"
      pause
      return 0
    fi
    if [ -n "${inst:-}" ]; then
      read -r -p "检测到新版本，是否升级？[Y/n]: " ans
      case "${ans:-Y}" in
        [Nn]*) return 0 ;;
      esac
    else
      echo -e "当前状态：${Y}本脚本环境，但未识别到已安装版本${NC}"
      echo -e "将安装版本：${G}${latest_ver}${NC}"
    fi
  else
    echo -e "当前状态：${Y}未安装 sing-box${NC}"
    echo -e "将安装版本：${G}${latest_ver}${NC}"
  fi

  tmp_dir="$(mktemp -d)"
  base_url="https://github.com/${SINGBOX_RELEASE_REPO:-Tangfffyx/sing-box}/releases/download/${tag}"
  download_url="${base_url}/${file}"
  sha_url="${base_url}/sha256sum.txt"

  say "下载：${download_url}"
  if ! curl -fL --connect-timeout 20 --retry 3 "$download_url" -o "$tmp_dir/$file"; then
    rm -rf "$tmp_dir"
    err "下载失败。"
    pause
    return 1
  fi

  say "下载校验文件..."
  if curl -fL --connect-timeout 20 --retry 3 "$sha_url" -o "$tmp_dir/sha256sum.txt" >/dev/null 2>&1; then
    expected_sha="$(awk -v f="$file" '{n=$2; sub(/^.*\//,"",n); if (n==f) {print $1; exit}}' "$tmp_dir/sha256sum.txt")"
    actual_sha="$(sha256sum "$tmp_dir/$file" | awk '{print $1}')"
    if [ -n "$expected_sha" ] && [ "$expected_sha" = "$actual_sha" ]; then
      ok "文件校验通过。"
    else
      rm -rf "$tmp_dir"
      err "校验失败。"
      pause
      return 1
    fi
  else
    warn "未获取到 sha256sum.txt，跳过校验。"
  fi

  tar -xzf "$tmp_dir/$file" -C "$tmp_dir" || {
    rm -rf "$tmp_dir"
    err "解压失败。"
    pause
    return 1
  }

  [ -f "$tmp_dir/sing-box" ] || {
    rm -rf "$tmp_dir"
    err "安装包中未找到 sing-box 可执行文件。"
    pause
    return 1
  }

  mkdir -p "$SINGBOX_INSTALL_DIR" /etc/sing-box
  if [ -x "$SINGBOX_BIN" ]; then
    cp -f "$SINGBOX_BIN" "${SINGBOX_BIN}.bak" 2>/dev/null || true
  fi
  install -m 755 "$tmp_dir/sing-box" "$SINGBOX_BIN" || {
    rm -rf "$tmp_dir"
    err "安装失败。"
    pause
    return 1
  }
  echo "$tag" > "$SINGBOX_VERSION_STAMP"
  rm -rf "$tmp_dir"

  if ! "$SINGBOX_BIN" version | grep -q 'with_v2ray_api'; then
    err "当前安装的 sing-box 未检测到 with_v2ray_api。"
    pause
    return 1
  fi

  ok "sing-box 安装/更新完成。"
  say "准备流量统计依赖..."
  ensure_grpcurl_logged || true
  ensure_v2ray_api_proto_files || true

  # 纯安装/纯更新：准备脚本运行环境
  prepare_script_runtime
  config_ensure_exists
  config_force_access_log_settings || true
  enable_now_singbox_safe || true
  ensure_sb_shortcut || true
  install_user_watch_cron || true
  install_log_maintain_cron || true
  show_versions
  pause
}

sync_system_time_chrony() {
  require_root
  clear
  echo -e "${R}--- 一键同步系统时间 ---${NC}"
  if ! has_cmd chronyc; then
    warn "未检测到 chrony，开始安装..."
    apt_update_once
    apt-get install -y chrony || { err "chrony 安装失败。"; pause; return 1; }
  fi
  systemctl stop systemd-timesyncd >/dev/null 2>&1 || true
  systemctl disable systemd-timesyncd >/dev/null 2>&1 || true
  if chronyc tracking >/dev/null 2>&1 && [ "$(systemctl is-active chrony 2>/dev/null)" = "active" ]; then
    ok "chrony 已正常运行。"
  else
    warn "开始修复 chrony 服务状态..."
    systemctl stop chrony >/dev/null 2>&1 || true
    pkill -9 chronyd >/dev/null 2>&1 || true
    rm -f /run/chrony/chronyd.pid >/dev/null 2>&1 || true
    systemctl reset-failed chrony >/dev/null 2>&1 || true
    systemctl start chrony >/dev/null 2>&1 || true
    sleep 2
  fi
  systemctl enable chrony >/dev/null 2>&1 || true
  chronyc -a makestep >/dev/null 2>&1 || true
  ok "时间同步完成。"
  systemctl status chrony --no-pager -l || true
  pause
}

uninstall_singbox_keep_config() {
  require_root
  clear
  echo -e "${R}--- 卸载 sing-box（保留 /etc/sing-box/ 配置）---${NC}"
  echo -e "${Y}注意：该操作将卸载接管层、官方安装残留、cron 与运行文件，但保留配置、用户数据、日志文件。${NC}"
  ask_confirm_yes || { warn "已取消卸载。"; pause; return 0; }

  has_cmd apt-get || { err "未找到 apt-get。"; pause; return 1; }
  sync_user_usage_counters || true
  remove_user_watch_cron || true
  remove_log_maintain_cron || true
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl disable sing-box >/dev/null 2>&1 || true
  remove_all_singbox_service_units
  rm -f "$SINGBOX_BIN" /usr/bin/sing-box "$SINGBOX_VERSION_STAMP" "$GRPCURL_BIN" >/dev/null 2>&1 || true
  if pkg_installed sing-box || pkg_installed sing-box-beta; then
    pkg_installed sing-box && apt-get remove -y sing-box || true
    pkg_installed sing-box-beta && apt-get remove -y sing-box-beta || true
    pkg_installed sing-box && apt-get purge -y sing-box || true
    pkg_installed sing-box-beta && apt-get purge -y sing-box-beta || true
    ok "已清理脚本运行层并卸载官方包残留（如存在）。"
  else
    ok "已清理脚本运行层（如存在）。"
  fi
  [ -d /etc/sing-box ] && ok "配置目录仍存在：/etc/sing-box" || warn "未找到 /etc/sing-box"
  [ -d "$(dirname "$USER_DB_FILE")" ] && ok "用户数据库目录仍存在：$(dirname "$USER_DB_FILE")" || true
  pause
}

# ====================================================
# 800 Views / Health / protocol manager
# ====================================================

# --------------------------------------------------
# normalize_takeover
# 作用：
#   对已有 config 做一次规范化接管
#   统一 entry_key / relay user / outbound 命名
#   不改变已有节点功能
# --------------------------------------------------
normalize_takeover(){
  init_manager_env
  clear
  local json work_json
  local -a inv_lines=() issue_lines=() action_lines=()
  local -A target_seen=()
  local tag_updates=0 direct_updates=0 relay_user_updates=0 relay_out_updates=0 skipped=0

  json="$(config_load)"
  work_json="$json"
  mapfile -t inv_lines < <(protocol_entry_inventory_ext "$json")

  echo -e "${C}--- 规范化接管 ---${NC}"

  if [ ${#inv_lines[@]} -eq 0 ]; then
    warn "未识别到可接管的核心协议对象。"
    pause
    return 0
  fi

  local line idx oldtag proto port target current_count
  for line in "${inv_lines[@]}"; do
    IFS=$'	' read -r idx oldtag proto port <<< "$line"
    target="$(entry_key_from_parts "$proto" "$port")" || continue
    target_seen["$target"]=$(( ${target_seen["$target"]:-0} + 1 ))
  done

  for line in "${inv_lines[@]}"; do
    IFS=$'	' read -r idx oldtag proto port <<< "$line"
    target="$(entry_key_from_parts "$proto" "$port")" || continue

    if [ "${target_seen[$target]:-0}" -gt 1 ]; then
      issue_lines+=("主入站目标名冲突：${proto}:${port} -> ${target}（已跳过）")
      skipped=$((skipped+1))
      continue
    fi

    current_count="$(echo "$work_json" | jq -r --arg t "$target" --argjson idx "$idx" '[.inbounds | to_entries[] | select((.value.tag // "") == $t and .key != $idx)] | length')"
    if [ "$current_count" -gt 0 ]; then
      issue_lines+=("主入站目标 tag 已被其它对象占用：${target}（已跳过）")
      skipped=$((skipped+1))
      continue
    fi

    if [ "$oldtag" != "$target" ]; then
      work_json="$(echo "$work_json" | jq --argjson idx "$idx" --arg t "$target" '.inbounds[$idx].tag = $t')" || {
        err "规范化主入站 tag 失败：$proto:$port"
        pause
        return 1
      }
      action_lines+=("主入站：${oldtag:-<空>} -> ${target}")
      tag_updates=$((tag_updates+1))
    fi

    local -a user_lines=() relay_names=() direct_candidates=()
    local user_line uidx uname relay_user out_tag land new_user new_out direct_old

    mapfile -t user_lines < <(echo "$work_json" | jq -r --argjson idx "$idx" '.inbounds[$idx].users // [] | to_entries[] | [.key, (.value.name // "")] | @tsv')
    mapfile -t relay_names < <(relay_list_table "$work_json" | awk -F '	' -v ek="$target" '$1 == ek {print $2}')

    for user_line in "${user_lines[@]}"; do
      IFS=$'	' read -r uidx uname <<< "$user_line"
      local is_relay=0 rn
      for rn in "${relay_names[@]}"; do
        if [ "$uname" = "$rn" ] && [ -n "$uname" ]; then
          is_relay=1
          break
        fi
      done
      if [ $is_relay -eq 0 ] && [[ "$uname" != *"@"* ]]; then
        direct_candidates+=("$uidx:$uname")
      fi
    done

    if [ ${#direct_candidates[@]} -eq 1 ]; then
      direct_old="${direct_candidates[0]#*:}"
      uidx="${direct_candidates[0]%%:*}"
      if [ "$direct_old" != "$target" ]; then
        work_json="$(echo "$work_json" | jq --argjson idx "$idx" --argjson uidx "$uidx" --arg old "$direct_old" --arg new "$target" '
          .inbounds[$idx].users[$uidx].name = $new
          | .route.rules |= map(
              if (.auth_user? != null) then
                .auth_user |= (
                  if type == "array" then map(if . == $old then $new else . end)
                  elif . == $old then $new
                  else . end
                )
              else . end
            )
        ')" || {
          err "规范化直连用户失败：$target"
          pause
          return 1
        }
        action_lines+=("直连用户：${direct_old:-<空>} -> ${target}")
        direct_updates=$((direct_updates+1))
      fi
    elif [ ${#direct_candidates[@]} -gt 1 ]; then
      issue_lines+=("主入站存在多个直连候选用户，未自动规范化：${target}")
      skipped=$((skipped+1))
    fi

    while IFS=$'	' read -r _ relay_user out_tag; do
      [ -z "${relay_user:-}" ] && continue
      [[ "$relay_user" == *"@"* ]] && continue
      land=""
      if [[ "$out_tag" =~ ^out-.*-to-(.+)$ ]]; then
        land="${BASH_REMATCH[1]}"
      elif [[ "$out_tag" =~ ^out-to-(.+)$ ]]; then
        land="${BASH_REMATCH[1]}"
      elif [[ "$out_tag" =~ ^to-(.+)$ ]]; then
        land="${BASH_REMATCH[1]}"
      elif [[ "$relay_user" =~ -to-(.+)$ ]]; then
        land="${BASH_REMATCH[1]}"
      fi

      if [ -z "$land" ] || [ -z "$out_tag" ]; then
        issue_lines+=("中转关系不完整，未自动接管：${relay_user:-<空>} -> ${out_tag:-<空>}")
        skipped=$((skipped+1))
        continue
      fi

      new_user="$(relay_user_name "$target" "$land")"
      new_out="$(relay_outbound_tag "$target" "$land")"

      if [ "$relay_user" != "$new_user" ]; then
        work_json="$(echo "$work_json" | jq --argjson idx "$idx" --arg old "$relay_user" --arg new "$new_user" '
          (.inbounds[$idx].users // []) |= map(if (.name // "") == $old then .name = $new else . end)
          | .route.rules |= map(
              if (.auth_user? != null) then
                .auth_user |= (
                  if type == "array" then map(if . == $old then $new else . end)
                  elif . == $old then $new
                  else . end
                )
              else . end
            )
        ')" || {
          err "规范化中转用户失败：$relay_user"
          pause
          return 1
        }
        action_lines+=("中转用户：${relay_user} -> ${new_user}")
        relay_user_updates=$((relay_user_updates+1))
      fi

      if [ "$out_tag" != "$new_out" ]; then
        if echo "$work_json" | jq -e --arg o "$new_out" --arg old "$out_tag" '.outbounds[]? | select((.tag // "") == $new_out and (.tag // "") != $old)' >/dev/null 2>&1; then
          issue_lines+=("目标 outbound tag 已存在，未自动规范化：${out_tag} -> ${new_out}")
          skipped=$((skipped+1))
        else
          work_json="$(echo "$work_json" | jq --arg old "$out_tag" --arg new "$new_out" '
            .outbounds |= map(if (.tag // "") == $old then .tag = $new else . end)
            | .route.rules |= map(if (.outbound // "") == $old then .outbound = $new else . end)
          ')" || {
            err "规范化中转 outbound 失败：$out_tag"
            pause
            return 1
          }
          action_lines+=("中转 outbound：${out_tag} -> ${new_out}")
          relay_out_updates=$((relay_out_updates+1))
        fi
      fi
    done < <(relay_list_table "$work_json" | awk -F '	' -v ek="$target" '$1 == ek {print $1"	"$2"	"$3}')
  done

  echo -e "${B}--------------------------------------------------------${NC}"
  echo -e "${C}预览结果${NC}"
  echo -e "  主入站规范化：${tag_updates}"
  echo -e "  直连用户规范化：${direct_updates}"
  echo -e "  中转用户规范化：${relay_user_updates}"
  echo -e "  中转 outbound 规范化：${relay_out_updates}"
  if [ ${#action_lines[@]} -gt 0 ]; then
    echo -e "${B}--------------------------------------------------------${NC}"
    echo -e "${C}计划执行${NC}"
    local a
    for a in "${action_lines[@]}"; do
      echo -e "  - ${a}"
    done
  fi
  if [ ${#issue_lines[@]} -gt 0 ]; then
    echo -e "${B}--------------------------------------------------------${NC}"
    echo -e "${Y}发现但未自动处理${NC}"
    local it
    for it in "${issue_lines[@]}"; do
      echo -e "  - ${it}"
    done
  fi

  if [ $tag_updates -eq 0 ] && [ $direct_updates -eq 0 ] && [ $relay_user_updates -eq 0 ] && [ $relay_out_updates -eq 0 ]; then
    warn "没有可自动规范化的对象。"
    pause
    return 0
  fi

  echo ""
  ask_confirm_yes "输入 YES 确认执行规范化接管，其它任意输入取消: " || { warn "已取消规范化接管。"; pause; return 0; }

  work_json="$(route_rebuild "$work_json")" || {
    err "规范化接管后重建路由失败，已取消写入。"
    pause
    return 1
  }

  if config_apply "$work_json"; then
    ok "规范化接管完成。"
  else
    err "规范化接管应用失败。"
    pause
    return 1
  fi

  pause
}

upsert_inbound_for_entry_key() {
  local json="$1" entry_key="$2" inbound_json="$3"
  echo "$json" | jq --arg ek "$entry_key" --argjson inb "$inbound_json" '
    .inbounds |= map(select(.tag != $ek))
    | .inbounds += [$inb]
  '
}

prompt_protocol_port_and_entry_key() {
  local proto="$1" prompt="$2" default_port="$3" json="$4" port_var="$5" entry_var="$6" conflict_msg="${7:-端口 %s 已被占用，请更换。}" allow_replace="${8:-0}"
  local prompt_port prompt_entry_key conflict_line exclude_tag

  ask_port_or_return "$prompt" "$default_port" prompt_port || return 1
  prompt_entry_key="$(entry_key_from_parts "$proto" "$prompt_port")" || return 1
  if [ "$allow_replace" = "1" ]; then
    exclude_tag="$prompt_entry_key"
  else
    exclude_tag=""
  fi
  while port_conflict_for_protocol "$json" "$proto" "$prompt_port" "$exclude_tag"; do
    printf -v conflict_line "$conflict_msg" "$prompt_port"
    warn "$conflict_line"
    ask_port_or_return "$prompt" "$default_port" prompt_port || return 1
    prompt_entry_key="$(entry_key_from_parts "$proto" "$prompt_port")" || return 1
    if [ "$allow_replace" = "1" ]; then
      exclude_tag="$prompt_entry_key"
    fi
  done

  printf -v "$port_var" '%s' "$prompt_port"
  printf -v "$entry_var" '%s' "$prompt_entry_key"
  return 0
}

build_standard_protocol_inbound() {
  local proto="$1" port="$2" sni="${3:-}"
  case "$proto" in
    anytls) build_anytls_inbound "$port" "$sni" ;;
    shadowsocks) build_ss_inbound "$port" ;;
    trojan) build_trojan_inbound "$port" "$sni" ;;
    tuic) build_tuic_inbound "$port" "$sni" ;;
    *) return 1 ;;
  esac
}

protocol_tls_label() {
  case "$1" in
    anytls) echo "AnyTLS" ;;
    trojan) echo "Trojan" ;;
    tuic) echo "TUIC" ;;
    *) echo "" ;;
  esac
}

install_standard_protocol_inbound() {
  local json="$1" proto="$2" prompt="$3" default_port="$4" conflict_msg="$5" out_json_var="$6" out_entry_key_var="$7"
  local local_port local_entry_key tls_label sni inbound updated allow_replace="0"

  prompt_protocol_port_and_entry_key "$proto" "$prompt" "$default_port" "$json" local_port local_entry_key "$conflict_msg" "$allow_replace" || return 1
  tls_label="$(protocol_tls_label "$proto")"
  if [ -n "$tls_label" ]; then
    sni="$(choose_tls_domain "$tls_label")" || return 1
  fi

  inbound="$(build_standard_protocol_inbound "$proto" "$local_port" "${sni:-}")" || return 1
  updated="$(upsert_inbound_for_entry_key "$json" "$local_entry_key" "$inbound")" || return 1

  printf -v "$out_json_var" '%s' "$updated"
  printf -v "$out_entry_key_var" '%s' "$local_entry_key"
  return 0
}

protocol_install_menu() {
  local json="$1"
  local updated_json="$json"
  local choice_arr sel
  local -a added_node_keys=()
  local -a reality_meta_tags=()
  local -a reality_meta_pubs=()
  echo -e "\n${C}可安装模块（多个用 + 连接，如 1+3+5）:${NC}"
  echo -e "  [1] vless-reality"
  echo -e "  [2] anytls"
  echo -e "  [3] shadowsocks"
  echo -e "  [4] trojan"
  echo -e "  [5] vmess-ws"
  echo -e "  [6] vless-ws"
  echo -e "  [7] tuic"
  read -r -p "请输入要安装的模块编号: " sel
  mapfile -t choice_arr < <(parse_plus_selections "${sel:-}")
  [ ${#choice_arr[@]} -eq 0 ] && { warn "未选择任何模块，已返回上一级。"; pause; return 0; }

  local c port listen sni path priv sid entry_key inbound pub generated_pair
  for c in "${choice_arr[@]}"; do
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt 7 ]; then
      warn "无效模块编号：$c，已返回上一级。"
      pause
      return 0
    fi
  done

  for c in "${choice_arr[@]}"; do
    case "$c" in
      1)
        prompt_protocol_port_and_entry_key "vless-reality" "Reality 监听端口 (默认: 443): " "443" "$updated_json" port entry_key \
          || { warn "已返回上一级。"; pause; return 0; }
        read -r -p "Private Key（回车自动生成）: " priv
        pub=""
        if [ -z "$priv" ]; then
          generated_pair="$(generate_reality_keypair_auto 2>/dev/null || true)"
          priv="${generated_pair%%$'	'*}"
          pub="${generated_pair#*$'	'}"
          if [ -z "$priv" ] || [ -z "$pub" ]; then
            warn "自动生成 Reality 密钥对失败，已返回上一级。"
            pause
            return 0
          fi
          echo "已自动生成 Reality 密钥对。"
          echo "Private Key: $priv"
          echo "Public Key : $pub"
        fi
        read -r -p "Short ID (回车随机生成8位hex): " sid
        if [ -z "$sid" ]; then
          sid="$(openssl rand -hex 4 2>/dev/null || true)"
          if [ -z "$sid" ]; then sid="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' 
' | cut -c1-8)"; fi
          echo "已生成 Short ID: $sid"
        fi
        sni="$(choose_tls_domain "Reality")" || return 0
        inbound="$(build_vless_reality_inbound "$port" "$sni" "$priv" "$sid")"
        updated_json="$(upsert_inbound_for_entry_key "$updated_json" "$entry_key" "$inbound")"
        added_node_keys+=("$entry_key")
        if [ -n "$pub" ]; then
          reality_meta_tags+=("$entry_key")
          reality_meta_pubs+=("$pub")
        fi
        ;;
      2)
        install_standard_protocol_inbound "$updated_json" "anytls" "AnyTLS 端口 (默认: 443): " "443" "端口 %s 已被占用，请更换。" updated_json entry_key \
          || { warn "已返回上一级。"; pause; return 0; }
        added_node_keys+=("$entry_key")
        ;;
      3)
        install_standard_protocol_inbound "$updated_json" "shadowsocks" "Shadowsocks 监听端口 (默认: 8080): " "8080" "端口 %s 已被占用，请更换。" updated_json entry_key \
          || { warn "已返回上一级。"; pause; return 0; }
        added_node_keys+=("$entry_key")
        ;;
      4)
        install_standard_protocol_inbound "$updated_json" "trojan" "Trojan 端口 (默认: 443): " "443" "端口 %s 已被占用，请更换。" updated_json entry_key \
          || { warn "已返回上一级。"; pause; return 0; }
        added_node_keys+=("$entry_key")
        ;;
      5)
        read -r -p "vmess-ws 监听地址 (默认: 127.0.0.1): " listen; listen="${listen:-127.0.0.1}"
        prompt_protocol_port_and_entry_key "vmess-ws" "vmess-ws 监听端口 (默认: 8001): " "8001" "$updated_json" port entry_key \
          || { warn "已返回上一级。"; pause; return 0; }
        read -r -p "WS Path (回车随机生成): " path; path="$(normalize_ws_path "${path:-}")"
        inbound="$(build_vmess_ws_inbound "$port" "$listen" "$path")"
        updated_json="$(upsert_inbound_for_entry_key "$updated_json" "$entry_key" "$inbound")"
        added_node_keys+=("$entry_key")
        ;;
      6)
        read -r -p "vless-ws 监听地址 (默认: 127.0.0.1): " listen; listen="${listen:-127.0.0.1}"
        prompt_protocol_port_and_entry_key "vless-ws" "vless-ws 监听端口 (默认: 8002): " "8002" "$updated_json" port entry_key \
          || { warn "已返回上一级。"; pause; return 0; }
        read -r -p "WS Path (回车随机生成): " path; path="$(normalize_ws_path "${path:-}")"
        inbound="$(build_vless_ws_inbound "$port" "$listen" "$path")"
        updated_json="$(upsert_inbound_for_entry_key "$updated_json" "$entry_key" "$inbound")"
        added_node_keys+=("$entry_key")
        ;;
      7)
        install_standard_protocol_inbound "$updated_json" "tuic" "TUIC 端口（默认443，可与TCP协议的443端口并存）: " "443" "端口 %s 已被占用，请更换。" updated_json entry_key \
          || { warn "已返回上一级。"; pause; return 0; }
        added_node_keys+=("$entry_key")
        ;;
    esac
  done

  updated_json="$(route_rebuild "$updated_json")"
  if user_db_exists; then
    local db_json node_key
    db_json="$(user_db_load)"
    for node_key in "${added_node_keys[@]}"; do
      db_json="$(user_db_grant_node_to_enabled_users "$db_json" "$node_key")"
    done
    if ! user_manager_apply_changes "$db_json" "$updated_json"; then
      warn "核心模块安装/更新失败，已返回上一级。"
    else
      local i
      for i in "${!reality_meta_tags[@]}"; do
        meta_set_reality_public_key "${reality_meta_tags[$i]}" "${reality_meta_pubs[$i]}" || true
      done
    fi
  else
    if ! config_apply "$updated_json"; then
      warn "核心模块安装/更新失败，已返回上一级。"
    else
      local i
      for i in "${!reality_meta_tags[@]}"; do
        meta_set_reality_public_key "${reality_meta_tags[$i]}" "${reality_meta_pubs[$i]}" || true
      done
    fi
  fi
  pause
  return 0
}

protocol_remove_menu() {
  local json="$1"
  local lines=() choice_arr updated_json="$json" c entry_key related sel
  mapfile -t lines < <(protocol_entry_table "$json")
  if [ ${#lines[@]} -eq 0 ]; then
    warn "当前没有可卸载的核心模块。"
    pause
    return 0
  fi
  echo -e "
${R}已安装核心模块如下（多个用 + 连接，如 1+2）:${NC}"
  local i=1
  for line in "${lines[@]}"; do
    IFS=$'	' read -r entry_key type port <<< "$line"
    echo -e " [$i] ${entry_key}"
    i=$((i+1))
  done
  read -r -p "请输入要卸载的模块编号: " sel
  mapfile -t choice_arr < <(parse_plus_selections "${sel:-}")
  [ ${#choice_arr[@]} -eq 0 ] && { warn "未选择任何模块。"; pause; return 0; }

  for c in "${choice_arr[@]}"; do
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#lines[@]}" ]; then
      warn "无效模块编号：$c，已返回上一级。"
      pause
      return 0
    fi
  done

  for c in "${choice_arr[@]}"; do
    IFS=$'	' read -r entry_key _ <<< "${lines[$((c-1))]}"
    related="$(relay_list_table "$updated_json" | awk -F '	' -v ek="$entry_key" '{u=$2; sub(/@.*/, "", u)} $1 == ek {print u}' | awk 'NF' | sort -u)" || {
      err "读取关联中转失败，已中止卸载。"
      pause
      return 1
    }
    if [ -n "$related" ]; then
      warn "卸载 ${entry_key} 将同时删除以下关联中转："
      echo "$related" | sed 's/^/  - /'
    fi
    updated_json="$(remove_relays_for_entry_key "$updated_json" "$entry_key")" || {
      err "删除关联中转失败，已中止，未写入配置。"
      pause
      return 1
    }
    cleanup_inbound_generated_cert_files "$updated_json" "$entry_key"
    updated_json="$(remove_inbound_by_entry_key "$updated_json" "$entry_key")" || {
      err "删除核心模块失败，已中止，未写入配置。"
      pause
      return 1
    }
  done

  updated_json="$(route_rebuild "$updated_json")" || {
    err "重建路由失败，已中止，未写入配置。"
    pause
    return 1
  }
  if user_db_exists; then
    local db_json removed_nodes_json
    removed_nodes_json="$(
      for c in "${choice_arr[@]}"; do
        IFS=$'	' read -r entry_key _ <<< "${lines[$((c-1))]}"
        printf '%s
' "$entry_key"
      done | awk 'NF' | LC_ALL=C sort -u | jq -R . | jq -s '.'
    )"
    db_json="$(user_db_load)"
    db_json="$(echo "$db_json" | jq --argjson removed "$removed_nodes_json" '
      .users |= with_entries(
        .value.nodes = (((.value.nodes // []) | map(select(($removed | index(.)) == null))) | unique)
      )
    ')"
    db_json="$(user_db_cleanup_missing_nodes "$db_json" "$updated_json")"
    if ! user_manager_apply_changes "$db_json" "$updated_json"; then
      warn "核心模块卸载失败，已返回上一级。"
    fi
  else
    if ! config_apply "$updated_json"; then
      warn "核心模块卸载失败，已返回上一级。"
    fi
  fi
  pause
  return 0
}

protocol_manager() {
  init_manager_env
  while true; do
    clear
    local json
    json="$(config_load)"
    print_rect_title "核心模块管理"
    if protocol_status_summary "$json" >/tmp/.sb_protocols.$$ && [ -s /tmp/.sb_protocols.$$ ]; then
      local proto_width=15 proto_pad status_color port_text
      echo -e "${C}当前状态${NC}"
      echo -e "${B}--------------------------------------------------------${NC}"
      while IFS=$'	' read -r proto status ports; do
        proto_pad=$(printf "%-${proto_width}s" "$proto")
        if [ "$status" = "已安装" ]; then
          status_color="$G"
        else
          status_color="$Y"
        fi
        if [ -n "$ports" ]; then
          port_text="（端口${ports//|/|端口}）"
          printf "  - %b%s%b  %b【%s】%b%b%s%b
" "$W" "$proto_pad" "$NC" "$status_color" "$status" "$NC" "$C" "$port_text" "$NC"
        else
          printf "  - %b%s%b  %b【%s】%b
" "$W" "$proto_pad" "$NC" "$status_color" "$status" "$NC"
        fi
      done < /tmp/.sb_protocols.$$
    else
      echo -e "${Y}当前没有任何核心模块。${NC}"
    fi
    rm -f /tmp/.sb_protocols.$$ >/dev/null 2>&1 || true
    echo -e "${B}--------------------------------------------------------${NC}"
    echo -e "  ${C}1.${NC} 安装核心模块"
    echo -e "  ${C}2.${NC} 卸载核心模块"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) protocol_install_menu "$json" || true ;;
      2) protocol_remove_menu "$json" || true ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

clear_config_json() {
  init_manager_env
  clear
  echo -e "${Y}--- 清空/重置配置文件 ---${NC}"
  echo -e "${Y}注意：该操作将清空当前 config.json。${NC}"
  ask_confirm_yes || { warn "已取消清空/重置。"; pause; return 0; }
  config_reset
  pause
}

view_realtime_log() {
  clear
  print_rect_title "查看实时日志"
  if [ ! -f "$SCRIPT_LOG_FILE" ]; then
    warn "当前暂无日志文件：$SCRIPT_LOG_FILE"
    pause
    return 0
  fi

  echo -e "${Y}正在显示最近 10 行日志，并进入实时跟踪；按 Ctrl+C 返回菜单。${NC}"

  local old_trap
  old_trap="$(trap -p INT || true)"

  trap 'echo ""; trap - INT; return 0' INT
  tail -n 10 -f "$SCRIPT_LOG_FILE"
  trap - INT

  if [ -n "$old_trap" ]; then
    eval "$old_trap"
  fi

  echo ""
  return 0
}

system_tools_menu() {
  while true; do
    clear
    print_rect_title "系统工具"
    echo -e "  ${C}1.${NC} 一键同步系统时间"
    echo -e "  ${C}2.${NC} 规范化接管"
    echo -e "  ${C}3.${NC} 查看实时日志"
    echo -e "  ${C}4.${NC} 定时任务管理"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) sync_system_time_chrony ;;
      2) normalize_takeover ;;
      3) view_realtime_log ;;
      4) cron_jobs_menu ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

view_config_formatted() {
  init_manager_env
  clear
  echo -e "${C}--- 查看格式化配置 ---${NC}"
  sing-box format -c "$CONFIG_FILE" || err "sing-box format 执行失败。"
  echo ""
  pause
}

# ====================================================
# 900 Main menu
# ====================================================
main_menu() {
  ensure_sb_shortcut >/dev/null 2>&1 || true
  while true; do
    clear
    print_rect_title "Sing-box Elite 管理系统  V${SCRIPT_VERSION}"
    echo -e "  ${C}1.${NC} 安装/更新 sing-box"
    echo -e "  ${C}2.${NC} 清空/重置 config.json"
    echo -e "  ${C}3.${NC} 查看配置文件"
    echo -e "  ${C}4.${NC} 核心模块管理"
    echo -e "  ${C}5.${NC} 中转节点管理"
    echo -e "  ${C}6.${NC} 导出客户端配置"
    echo -e "  ${C}7.${NC} 用户管理"
    echo -e "  ${C}8.${NC} 系统工具"
    echo -e "  ${C}9.${NC} 卸载 sing-box"
    echo -e "  ${R}0.${NC} 退出系统"
    echo -e "${B}--------------------------------------------------------${NC}"
    read -r -p "请选择操作指令: " opt
    case "${opt:-}" in
      1) install_or_update_singbox ;;
      2) clear_config_json ;;
      3) view_config_formatted ;;
      4) protocol_manager || true ;;
      5) manage_relay_nodes || true ;;
      6) export_configs || true ;;
      7) user_manager_menu || true ;;
      8) system_tools_menu || true ;;
      9) uninstall_singbox_keep_config ;;
      0|q|Q) exit 0 ;;
      *) warn "无效输入：$opt"; sleep 1 ;;
    esac
  done
}

sync_runtime_script_entrypoints

if [[ "${1:-}" == "--user-watch" ]]; then
  user_watch_run
  exit 0
fi

if [[ "${1:-}" == "--maintain-logs" ]]; then
  maintain_logs
  exit 0
fi

main_menu
