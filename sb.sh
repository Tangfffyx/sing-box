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
# Version : 3.0.17
# Notes   : Single-file refactor, managed-route rebuild, no legacy compatibility.
# ====================================================

CONFIG_FILE="/etc/sing-box/config.json"
TEMP_FILE="/etc/sing-box/config.json.tmp"
SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
SB_TARGET_SCRIPT="/root/sing-box.sh"
SB_SHORTCUT="/usr/local/bin/sb"
REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/Tangfffyx/Public/main/Script/sing-box.sh"
SCRIPT_VERSION="3.0.17"

# ---------- UI ----------
B='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; C='\033[1;36m'; NC='\033[0m'; W='\033[1;37m'

say()  { echo -e "${C}[INFO]${NC} $*"; }
ok()   { echo -e "${G}[ OK ]${NC} $*"; }
warn() { echo -e "${Y}[WARN]${NC} $*"; }
err()  { echo -e "${R}[ERR ]${NC} $*"; }
pause(){ read -r -n 1 -p "按任意键继续..." || true; echo ""; }

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
config_min_template() {
  cat <<'JSON'
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"rules": []}
}
JSON
}

config_normalize() {
  local json="$1"
  if [ -z "$json" ]; then
    config_min_template
    return 0
  fi
  echo "$json" | jq '
    if type != "object" then
      {
        "log": {"level":"info","timestamp":true},
        "inbounds": [],
        "outbounds": [{"type":"direct","tag":"direct"}],
        "route": {"rules": []}
      }
    else . end
    | .log = (.log // {"level":"info","timestamp":true})
    | .inbounds = (.inbounds // [])
    | .outbounds = (.outbounds // [])
    | .route = (.route // {"rules": []})
    | .route.rules = (.route.rules // [])
    | if (.outbounds | any(.tag=="direct")) then . else .outbounds += [{"type":"direct","tag":"direct"}] end
  '
}

config_load() {
  if [ -s "$CONFIG_FILE" ] && jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    config_normalize "$(cat "$CONFIG_FILE")"
  else
    config_min_template
  fi
}

config_ensure_exists() {
  mkdir -p /etc/sing-box
  if [ ! -e "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
    warn "未发现配置文件，将写入最小模板：$CONFIG_FILE"
    config_min_template | jq . > "$CONFIG_FILE"
    return 0
  fi

  if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    local ts broken
    ts="$(date +%Y%m%d_%H%M%S)"
    broken="${CONFIG_FILE}.broken.${ts}"
    cp -a "$CONFIG_FILE" "$broken" 2>/dev/null || true
    warn "检测到配置文件不是合法 JSON，已备份到：$broken"
    config_min_template | jq . > "$CONFIG_FILE"
    return 0
  fi
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
    ok "配置校验通过：sing-box check -c $CONFIG_FILE"
    return 0
  fi
  err "配置校验失败：sing-box check -c $CONFIG_FILE"
  sing-box check -c "$CONFIG_FILE" 2>&1 | sed 's/^/  /'
  return 1
}

restart_singbox_safe() {
  if ! has_cmd systemctl; then
    err "未找到 systemctl。"
    return 1
  fi
  if ! check_config_or_print; then
    err "已阻止重启：请先修复配置。"
    return 1
  fi
  say "重启服务：systemctl restart sing-box"
  systemctl restart sing-box
  ok "sing-box 已重启。"
}

enable_now_singbox_safe() {
  if ! has_cmd systemctl; then
    err "未找到 systemctl。"
    return 1
  fi
  if ! check_config_or_print; then
    err "已阻止启动/自启：请先修复配置。"
    return 1
  fi
  say "启用自启并立即启动：systemctl enable --now sing-box"
  systemctl enable --now sing-box
  ok "sing-box 已启用自启并启动。"
}

config_apply() {
  local json="$1"
  local normalized
  normalized="$(config_normalize "$json")"

  if ! echo "$normalized" | jq -e 'type=="object"' >/dev/null 2>&1; then
    err "内部错误：即将写入的配置不是 JSON object。"
    return 1
  fi

  echo "$normalized" | jq . > "$TEMP_FILE" || {
    err "JSON 格式化失败，未写入配置。"
    return 1
  }

  if ! has_cmd sing-box; then
    err "未找到 sing-box，无法校验配置。"
    return 1
  fi

  if ! sing-box check -c "$TEMP_FILE" >/dev/null 2>&1; then
    err "sing-box check 校验未通过，未写入配置。"
    sing-box check -c "$TEMP_FILE" 2>&1 | sed 's/^/  /'
    rm -f "$TEMP_FILE"
    return 1
  fi

  local ts backup prev_tmp
  ts="$(date +%Y%m%d_%H%M%S)"
  backup="/etc/sing-box/config.json.bak.fail.$ts"
  prev_tmp="/tmp/singbox_config_prev.$$"

  if [ -f "$CONFIG_FILE" ]; then
    cp -a "$CONFIG_FILE" "$prev_tmp"
  else
    : > "$prev_tmp"
  fi

  mv -f "$TEMP_FILE" "$CONFIG_FILE"

  if restart_singbox_safe; then
    systemctl enable sing-box >/dev/null 2>&1 || true
    rm -f "$prev_tmp" >/dev/null 2>&1 || true
    ok "配置已应用。"
    return 0
  fi

  err "重启失败：正在回滚。"
  if [ -f "$prev_tmp" ] && [ -s "$prev_tmp" ]; then
    cp -a "$prev_tmp" "$backup"
    cp -a "$prev_tmp" "$CONFIG_FILE"
    warn "已生成失败备份：$backup"
  else
    cp -a "$CONFIG_FILE" "$backup" 2>/dev/null || true
    warn "无旧配置可回滚，已保存失败现场：$backup"
  fi
  rm -f "$prev_tmp" >/dev/null 2>&1 || true
  restart_singbox_safe || true
  return 1
}

config_reset() {
  config_apply "$(config_min_template)"
}

init_manager_env() {
  require_root
  has_cmd jq || { err "未找到 jq，请先安装/更新 sing-box（会自动装依赖）。"; exit 1; }
  has_cmd curl || { err "未找到 curl，请先安装/更新 sing-box（会自动装依赖）。"; exit 1; }
  has_cmd openssl || { err "未找到 openssl，请先安装/更新 sing-box（会自动装依赖）。"; exit 1; }
  has_cmd sing-box || { err "未找到 sing-box，请先安装。"; exit 1; }
  has_cmd systemctl || { err "未找到 systemctl。"; exit 1; }
  config_ensure_exists
}

# ====================================================
# 300 Entry / Relay / Route helpers
# ====================================================
entry_key_prefix_by_type() {
  case "$1" in
    vless-reality) echo "reality" ;;
    anytls) echo "anytls" ;;
    shadowsocks) echo "ss" ;;
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
  local normalized managed_users_json core_users_json relay_pairs_json preserved_rules_json

  normalized="$(config_normalize "$json")" || return 1

  managed_users_json="$({
    echo "$normalized" | jq -r '''
      .inbounds[]?
      | (.users // [])[]?
      | .name // empty
    '''
  } | awk '"'"'NF'"'"' | sort -u | jq -R . | jq -s '.')" || return 1

  core_users_json="$({
    echo "$normalized" | jq -r '''
      .inbounds[]?
      | .tag as $entry
      | (.users // [])[]?
      | .name // empty
      | select(. == $entry)
    '''
  } | awk '"'"'NF'"'"' | sort -u | jq -R . | jq -s '.')" || return 1

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
    echo "$normalized" | jq -c --argjson managed "$managed_users_json" '''
      def auth_users_array:
        if (.auth_user? == null) then []
        elif ((.auth_user | type) == "array") then .auth_user
        else [ .auth_user ]
        end;

      [
        .route.rules[]?
        | select(
            (.auth_user? == null)
            or ((auth_users_array | any(. as $u | ($managed | index($u)) == null)))
          )
      ]
    '''
  )" || return 1

  echo "$normalized" | jq --argjson core "$core_users_json" --argjson relay "$relay_pairs_json" --argjson kept "$preserved_rules_json" '''
    .route.rules = (
      ($kept // [])
      + (if ($core | length) > 0 then [{auth_user:$core,outbound:"direct"}] else [] end)
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
  ''' || return 1
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

  for proto in vless-reality anytls shadowsocks vmess-ws vless-ws tuic; do
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
  while IFS=$'	' read -r entry relay_user out_tag; do
    [ -z "${relay_user:-}" ] && continue
    found=1
    echo -e "  - ${G}${relay_user}${NC}"
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
      [
        .inbounds[]?
        | select(.tag == $ek)
        | (.users // [])[]?
        | .name // empty
        | select(. != "" and . != $ek)
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
    def inbound_proto:
      if .type == "vless" and (.tls.reality.enabled // false) then "vless-reality"
      elif .type == "anytls" then "anytls"
      elif .type == "shadowsocks" then "shadowsocks"
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
        | select($name != "" and $name != $entry)
        | [
            $root.route.rules[]?
            | select((auth_users_array | index($name)) != null)
            | .outbound // empty
            | select(. != "" and . != "direct")
          ] as $outs
        | [
            (["out-" + $name] + (if ($name | contains("-to-")) then ["out-to-" + (($name | capture(".*-to-(?<land>.+)$").land)), "to-" + (($name | capture(".*-to-(?<land>.+)$").land))] else [] end))[] as $cand
            | $root.outbounds[]?
            | .tag // empty
            | select(. == $cand)
          ] as $fallback_outs
        | select(($outs | length) > 0 or ($fallback_outs | length) > 0 or ($name | contains("-to-")))
        | [$entry, $name, (if ($outs | length) > 0 then $outs[0] elif ($fallback_outs | length) > 0 then $fallback_outs[0] else "" end)]
      ]
    | unique
    | .[]
    | @tsv
  ' || return 1
}

relay_add() {
  init_manager_env
  local json lines=() entry_key choice land ip pw normalized_pw relay_user out_tag inbound
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
    tuic)
      new_user="$(jq -n --arg name "$relay_user" --arg uuid "$(sing-box generate uuid)" --arg pass "$(openssl rand -base64 12)" '{name:$name,uuid:$uuid,password:$pass}')"
      ;;
    *)
      err "不支持的主入站类型：$inbound_type"
      pause
      return 1
      ;;
  esac

  new_out="$(jq -n --arg tag "$out_tag" --arg ip "$ip" --arg pw "$normalized_pw" '{type:"shadowsocks",tag:$tag,server:$ip,server_port:8080,method:"2022-blake3-aes-128-gcm",password:$pw}')"

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
  if config_apply "$updated_json"; then
    ok "中转节点已添加/覆盖：$relay_user"
  else
    warn "中转节点添加失败，已返回上一级。"
  fi
  pause
  return 0
}

relay_delete() {
  init_manager_env
  local json lines=() choice picks=() updated_json line entry relay_user out_tag part idx
  json="$(config_load)"
  mapfile -t lines < <(relay_list_table "$json")
  if [ ${#lines[@]} -eq 0 ]; then
    warn "当前没有中转节点。"
    pause
    return 0
  fi

  clear
  echo -e "${R}--- 删除中转节点 ---${NC}"
  local i=1
  for line in "${lines[@]}"; do
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
    if ! [[ "$part" =~ ^[0-9]+$ ]] || [ "$part" -lt 1 ] || [ "$part" -gt "${#lines[@]}" ]; then
      err "编号超出范围：$part"
      pause
      return 1
    fi
    idx=$((part-1))
    IFS=$'	' read -r entry relay_user out_tag <<< "${lines[$idx]}"
    updated_json="$(remove_relays_by_user_names "$updated_json" "$(jq -cn --arg u "$relay_user" '[$u]')")" || {
      err "删除中转失败，已中止，未写入配置。"
      pause
      return 1
    }
  done

  if ! config_apply "$updated_json"; then
    warn "删除中转失败，已返回上一级。"
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
      while IFS=$'\t' read -r entry relay_user out_tag; do
        echo -e "  - ${G}${relay_user}${NC}"
      done < /tmp/.sb_relay_list.$$
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

# ====================================================
# 600 Export
# ====================================================
export_collect_context() {
  local json="$1"
  local ip v_pbk ws_domain vm_domain inventory
  ip="$(get_public_ip)"
  v_pbk=""
  ws_domain="example.com"
  vm_domain="example.com"
  inventory="$(protocol_entry_inventory "$json")"

  if printf '%s
' "$inventory" | awk -F '	' '$2 == "vless-reality" {found=1} END{exit !found}'; then
    read -r -p "请输入 Reality Public Key（默认: PUBLIC_KEY_MISSING）: " v_pbk
    v_pbk="${v_pbk:-PUBLIC_KEY_MISSING}"
  fi
  if printf '%s
' "$inventory" | awk -F '	' '$2 == "vless-ws" {found=1} END{exit !found}'; then
    read -r -p "请输入 vless-ws 域名（默认: example.com）: " ws_domain
    ws_domain="${ws_domain:-example.com}"
  fi
  if printf '%s
' "$inventory" | awk -F '	' '$2 == "vmess-ws" {found=1} END{exit !found}'; then
    read -r -p "请输入 vmess-ws 域名（默认: example.com）: " vm_domain
    vm_domain="${vm_domain:-example.com}"
  fi

  jq -n --arg ip "$ip" --arg vpbk "$v_pbk" --arg wsd "$ws_domain" --arg vmd "$vm_domain" '{ip:$ip,v_pbk:$vpbk,ws_domain:$wsd,vm_domain:$vmd}'
}

export_configs() {
  init_manager_env
  clear
  local json ctx ip v_pbk ws_domain vm_domain relay_users_nl
  json="$(config_load)"
  ctx="$(export_collect_context "$json")"
  ip="$(echo "$ctx" | jq -r '.ip')"
  v_pbk="$(echo "$ctx" | jq -r '.v_pbk')"
  ws_domain="$(echo "$ctx" | jq -r '.ws_domain')"
  vm_domain="$(echo "$ctx" | jq -r '.vm_domain')"
  relay_users_nl="$(relay_list_table "$json" | awk -F '	' 'NF >= 2 {print $2}' | awk 'NF' | sort -u)"

  echo -e "${C}--- 节点配置导出 ---${NC}"

  local direct_tmp relay_tmp
  direct_tmp="$(mktemp)"
  relay_tmp="$(mktemp)"

  while read -r inbound; do
    local tag type port sni path sid method server_p proto
    tag="$(echo "$inbound" | jq -r '.tag')"
    type="$(echo "$inbound" | jq -r '.type')"
    proto="$(inbound_protocol_name "$inbound")"
    port="$(echo "$inbound" | jq -r '.listen_port')"
    sni="$(echo "$inbound" | jq -r '.tls.server_name // "www.icloud.com"')"
    path="$(echo "$inbound" | jq -r '.transport.path // "/"')"
    sid="$(echo "$inbound" | jq -r '.tls.reality.short_id[0] // ""')"
    method="$(echo "$inbound" | jq -r '.method // "2022-blake3-aes-128-gcm"')"
    server_p="$(echo "$inbound" | jq -r '.password // empty')"

    while read -r user; do
      local name uuid pass flow out_name pw_out target_file
      name="$(echo "$user" | jq -r '.name // empty')"
      uuid="$(echo "$user" | jq -r '.uuid // empty')"
      pass="$(echo "$user" | jq -r '.password // empty')"
      flow="$(echo "$user" | jq -r '.flow // "xtls-rprx-vision"')"
      [ -z "$name" ] && continue
      out_name="$name"

      if printf '%s
' "$relay_users_nl" | grep -Fxq "$name"; then
        target_file="$relay_tmp"
      else
        target_file="$direct_tmp"
      fi

      case "$proto" in
        vless-reality)
          [ -z "$uuid" ] && continue
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: vless, server: $ip, port: $port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: ${flow}, servername: $sni, reality-opts: {public-key: $v_pbk, short-id: '$sid'}, client-fingerprint: chrome}"
            echo ""
            echo -e " Quantumult X: vless=$ip:$port, method=none, password=$uuid, obfs=over-tls, obfs-host=$sni, reality-base64-pubkey=$v_pbk, reality-hex-shortid=$sid, vless-flow=${flow}, udp-relay=true, tag=${out_name}"
          } >> "$target_file"
          ;;
        anytls)
          [ -z "$pass" ] && continue
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: anytls, server: $ip, port: $port, password: "${pass}", client-fingerprint: chrome, udp: true, sni: "${sni}", alpn: [h2, http/1.1], skip-cert-verify: true}"
            echo ""
            echo -e " Surge: ${out_name} = anytls, ${ip}, ${port}, password=${pass}, skip-cert-verify=true, sni=${sni}"
          } >> "$target_file"
          ;;
        shadowsocks)
          [ -z "$pass" ] && continue
          if [ -n "$server_p" ] && [ "$server_p" != "$pass" ]; then pw_out="${server_p}:${pass}"; else pw_out="$pass"; fi
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: "${out_name}", type: ss, server: $ip, port: ${port}, cipher: ${method}, password: "${pw_out}", udp: true}"
            echo ""
            echo -e " Quantumult X: shadowsocks=$ip:${port}, method=${method}, password=${pw_out}, udp-relay=true, tag=${out_name}"
            echo ""
            echo -e " Surge: ${out_name} = ss, ${ip}, ${port}, encrypt-method=${method}, password=${pw_out}, udp-relay=true"
          } >> "$target_file"
          ;;
        vmess-ws)
          [ -z "$uuid" ] && continue
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: vmess, server: $ip, port: 443, uuid: ${uuid}, alterId: 0, cipher: auto, udp: true, tls: true, network: ws, servername: ${vm_domain}, ws-opts: {path: "${path}", headers: {Host: ${vm_domain}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}}"
            echo ""
            echo -e " Quantumult X: vmess=$ip:443, method=chacha20-poly1305, password=${uuid}, obfs=wss, obfs-host=${vm_domain}, obfs-uri=${path}?ed=2048, fast-open=false, udp-relay=true, tag=${out_name}"
            echo ""
            echo -e " Surge: ${out_name} = vmess, ${ip}, 443, username=${uuid}, tls=true, vmess-aead=true, ws=true, ws-path=${path}?ed=2048, sni=${vm_domain}, ws-headers=Host:${vm_domain}, skip-cert-verify=false, udp-relay=true, tfo=false"
          } >> "$target_file"
          ;;
        vless-ws)
          [ -z "$uuid" ] && continue
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: vless, server: $ip, port: 443, uuid: ${uuid}, udp: true, tls: true, network: ws, servername: ${ws_domain}, ws-opts: {path: "${path}", headers: {Host: ${ws_domain}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}}"
            echo ""
            echo -e " Quantumult X: vless=$ip:443,method=none,password=${uuid},obfs=wss,obfs-host=${ws_domain},obfs-uri=${path}?ed=2048,fast-open=false,udp-relay=true,tag=${out_name}"
          } >> "$target_file"
          ;;
        tuic)
          [ -z "$uuid" ] && continue
          [ -z "$pass" ] && continue
          {
            echo -e "
${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: tuic, server: $ip, port: $port, uuid: $uuid, password: $pass, alpn: [h3], disable-sni: false, reduce-rtt: false, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true, sni: $sni}"
            echo ""
            echo -e " Surge: ${out_name} = tuic-v5, ${ip}, ${port}, password=${pass}, sni=${sni}, uuid=${uuid}, alpn=h3, ecn=true"
          } >> "$target_file"
          ;;
      esac
    done < <(echo "$inbound" | jq -c '.users[]?')
  done < <(echo "$json" | jq -c '.inbounds[]?')

  echo -e "
${C}直连节点${NC}"
  if [ -s "$direct_tmp" ]; then
    cat "$direct_tmp"
  else
    echo -e "  ${Y}当前没有直连节点。${NC}"
  fi

  echo -e "
${C}中转节点${NC}"
  if [ -s "$relay_tmp" ]; then
    cat "$relay_tmp"
  else
    echo -e "  ${Y}当前没有中转节点。${NC}"
  fi

  rm -f "$direct_tmp" "$relay_tmp" >/dev/null 2>&1 || true
  echo ""
  pause
}

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
}

ensure_sagernet_repo() {
  say "检查/配置 sing-box APT 源..."
  mkdir -p /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/sagernet.asc ]; then
    curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
    chmod a+r /etc/apt/keyrings/sagernet.asc
    ok "GPG key 已配置。"
  else
    ok "GPG key 已存在。"
  fi
  if [ ! -f /etc/apt/sources.list.d/sagernet.sources ]; then
    cat > /etc/apt/sources.list.d/sagernet.sources <<'SRC'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
SRC
    ok "APT 源文件已创建。"
  else
    ok "APT 源文件已存在。"
  fi
  apt-get update -y
}

get_candidate_version() { apt-cache policy sing-box | awk '/Candidate:/ {print $2}' | head -n1; }
get_installed_version() {
  local st ver
  st="$(dpkg-query -W -f='${db:Status-Status}' sing-box 2>/dev/null || true)"
  ver="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  if [ "$st" = "installed" ] && [ -n "$ver" ]; then echo "$ver"; else echo ""; fi
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

install_script_self() {
  mkdir -p /usr/local/bin
  local current="${SCRIPT_SELF:-${BASH_SOURCE[0]:-$0}}"
  if [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]] || [[ "$current" == /dev/fd/* ]] || [[ "$current" == /proc/self/fd/* ]]; then
    curl -Ls "$REMOTE_SCRIPT_URL" -o "$SB_TARGET_SCRIPT" || {
      warn "快捷命令 sb 安装失败：无法下载脚本到 $SB_TARGET_SCRIPT"
      return 1
    }
  else
    current="$(readlink -f "$current" 2>/dev/null || echo "$current")"
    if [ "$current" != "$SB_TARGET_SCRIPT" ]; then
      cp -f "$current" "$SB_TARGET_SCRIPT" || {
        warn "快捷命令 sb 安装失败：无法复制脚本到 $SB_TARGET_SCRIPT"
        return 1
      }
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
  ok "已创建脚本快捷键：sb"
}

install_or_update_singbox() {
  clear
  echo -e "${B}+----------------------------------------------+${NC}"
  echo -e "${B}|           Sing-box Installer / Updater       |${NC}"
  echo -e "${B}+----------------------------------------------+${NC}"

  ensure_deps_for_installer
  ensure_sagernet_repo

  local cand inst ans
  inst="$(get_installed_version)"
  cand="$(get_candidate_version)"

  if [ -z "${cand:-}" ] || [ "$cand" = "(none)" ]; then
    err "未获取到仓库最新稳定版。"
    pause
    return 1
  fi

  if [ -z "${inst:-}" ]; then
    echo -e "当前状态：${Y}未安装 sing-box${NC}"
    echo -e "将安装最新稳定版：${G}${cand}${NC}"
    apt-get install -y sing-box || { err "安装失败。"; pause; return 1; }
    ok "sing-box 安装完成。"
  else
    echo -e "当前版本：${G}${inst}${NC}"
    echo -e "最新稳定版：${G}${cand}${NC}"
    if dpkg --compare-versions "$inst" lt "$cand"; then
      read -r -p "检测到新版本，是否升级？[Y/n]: " ans
      case "${ans:-Y}" in
        n|N) warn "已取消升级。"; pause; return 0 ;;
      esac
      apt-get install -y --only-upgrade sing-box || { err "升级失败。"; pause; return 1; }
      ok "sing-box 升级完成。"
    else
      ok "当前已是最新稳定版。"
      pause
      return 0
    fi
  fi

  config_ensure_exists
  enable_now_singbox_safe || true
  ensure_sb_shortcut || true
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
  echo -e "${Y}注意：该操作将卸载 sing-box 程序包，配置目录 /etc/sing-box/ 保留。${NC}"
  ask_confirm_yes || { warn "已取消卸载。"; pause; return 0; }

  has_cmd apt-get || { err "未找到 apt-get。"; pause; return 1; }
  systemctl stop sing-box >/dev/null 2>&1 || true
  if pkg_installed sing-box || pkg_installed sing-box-beta; then
    pkg_installed sing-box && apt-get remove -y sing-box || true
    pkg_installed sing-box-beta && apt-get remove -y sing-box-beta || true
    ok "卸载流程完成。"
  else
    warn "未检测到 sing-box/sing-box-beta 已安装。"
  fi
  [ -d /etc/sing-box ] && ok "配置目录仍存在：/etc/sing-box" || warn "未找到 /etc/sing-box"
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
      if [ $is_relay -eq 0 ]; then
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

protocol_install_menu() {
  local json="$1"
  local updated_json="$json"
  local choice_arr sel
  echo -e "\n${C}可安装模块（多个用 + 连接，如 1+3+5）:${NC}"
  echo -e "  [1] vless-reality"
  echo -e "  [2] anytls"
  echo -e "  [3] shadowsocks"
  echo -e "  [4] vmess-ws"
  echo -e "  [5] vless-ws"
  echo -e "  [6] tuic"
  read -r -p "请输入要安装的模块编号: " sel
  mapfile -t choice_arr < <(parse_plus_selections "${sel:-}")
  [ ${#choice_arr[@]} -eq 0 ] && { warn "未选择任何模块，已返回上一级。"; pause; return 0; }

  local c port listen sni path priv sid entry_key inbound
  for c in "${choice_arr[@]}"; do
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt 6 ]; then
      warn "无效模块编号：$c，已返回上一级。"
      pause
      return 0
    fi
  done

  for c in "${choice_arr[@]}"; do
    case "$c" in
      1)
        ask_port_or_return "Reality 监听端口 (默认: 443): " "443" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts vless-reality "$port")"
        while port_conflict_for_protocol "$updated_json" vless-reality "$port" "$entry_key"; do
          warn "端口 ${port} 已被占用，请更换。"
          ask_port_or_return "Reality 监听端口 (默认: 443): " "443" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts vless-reality "$port")"
        done
        read -r -p "Private Key: " priv
        read -r -p "Short ID (回车随机生成8位hex): " sid
        if [ -z "$sid" ]; then
          sid="$(openssl rand -hex 4 2>/dev/null || true)"
          if [ -z "$sid" ]; then sid="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' 
' | cut -c1-8)"; fi
          echo "已生成 Short ID: $sid"
        fi
        read -r -p "SNI 域名 (默认: www.icloud.com): " sni; sni="${sni:-www.icloud.com}"
        inbound="$(build_vless_reality_inbound "$port" "$sni" "$priv" "$sid")"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        ;;
      2)
        ask_port_or_return "AnyTLS 端口 (默认: 443): " "443" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts anytls "$port")"
        while port_conflict_for_protocol "$updated_json" anytls "$port" "$entry_key"; do
          warn "端口 ${port} 已被占用，请更换。"
          ask_port_or_return "AnyTLS 端口 (默认: 443): " "443" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts anytls "$port")"
        done
        read -r -p "AnyTLS 域名 (默认: www.icloud.com): " sni; sni="${sni:-www.icloud.com}"
        inbound="$(build_anytls_inbound "$port" "$sni")"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        ;;
      3)
        ask_port_or_return "Shadowsocks 监听端口 (默认: 8080): " "8080" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts shadowsocks "$port")"
        while port_conflict_for_protocol "$updated_json" shadowsocks "$port" "$entry_key"; do
          warn "端口 ${port} 已被同层协议占用，请更换。"
          ask_port_or_return "Shadowsocks 监听端口 (默认: 8080): " "8080" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts shadowsocks "$port")"
        done
        inbound="$(build_ss_inbound "$port")"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        ;;
      4)
        read -r -p "vmess-ws 监听地址 (默认: 127.0.0.1): " listen; listen="${listen:-127.0.0.1}"
        ask_port_or_return "vmess-ws 监听端口 (默认: 8001): " "8001" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts vmess-ws "$port")"
        while port_conflict_for_protocol "$updated_json" vmess-ws "$port" "$entry_key"; do
          warn "端口 ${port} 已被占用，请更换。"
          ask_port_or_return "vmess-ws 监听端口 (默认: 8001): " "8001" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts vmess-ws "$port")"
        done
        read -r -p "WS Path (回车随机生成): " path; path="$(normalize_ws_path "${path:-}")"
        inbound="$(build_vmess_ws_inbound "$port" "$listen" "$path")"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        ;;
      5)
        read -r -p "vless-ws 监听地址 (默认: 127.0.0.1): " listen; listen="${listen:-127.0.0.1}"
        ask_port_or_return "vless-ws 监听端口 (默认: 8002): " "8002" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts vless-ws "$port")"
        while port_conflict_for_protocol "$updated_json" vless-ws "$port" "$entry_key"; do
          warn "端口 ${port} 已被占用，请更换。"
          ask_port_or_return "vless-ws 监听端口 (默认: 8002): " "8002" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts vless-ws "$port")"
        done
        read -r -p "WS Path (回车随机生成): " path; path="$(normalize_ws_path "${path:-}")"
        inbound="$(build_vless_ws_inbound "$port" "$listen" "$path")"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        ;;
      6)
        ask_port_or_return "TUIC 端口（默认443，可与TCP协议的443端口并存）: " "443" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts tuic "$port")"
        while port_conflict_for_protocol "$updated_json" tuic "$port" "$entry_key"; do
          warn "端口 ${port} 已被其它 TUIC 占用，请更换。"
          ask_port_or_return "TUIC 端口（默认443，可与TCP协议的443端口并存）: " "443" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts tuic "$port")"
        done
        read -r -p "TUIC 域名 (默认: www.icloud.com): " sni; sni="${sni:-www.icloud.com}"
        inbound="$(build_tuic_inbound "$port" "$sni")"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        ;;
    esac
  done

  updated_json="$(route_rebuild "$updated_json")"
  if ! config_apply "$updated_json"; then
    warn "核心模块安装/更新失败，已返回上一级。"
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
    related="$(relay_list_table "$updated_json" | awk -F '	' -v ek="$entry_key" '$1 == ek {print $2}')" || {
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
  if ! config_apply "$updated_json"; then
    warn "核心模块卸载失败，已返回上一级。"
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

system_tools_menu() {
  while true; do
    clear
    print_rect_title "系统工具"
    echo -e "  ${C}1.${NC} 一键同步系统时间"
    echo -e "  ${C}2.${NC} 规范化接管"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) sync_system_time_chrony ;;
      2) normalize_takeover ;;
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
    echo -e "  ${C}7.${NC} 系统工具"
    echo -e "  ${C}8.${NC} 卸载 sing-box"
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
      7) system_tools_menu || true ;;
      8) uninstall_singbox_keep_config ;;
      0|q|Q) exit 0 ;;
      *) warn "无效输入：$opt"; sleep 1 ;;
    esac
  done
}

main_menu
