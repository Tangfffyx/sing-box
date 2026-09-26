#!/usr/bin/env bash

# ============================================================
# Sing-box Elite Management System
# 由 build.sh 自动合并生成，请勿直接编辑此文件
# 源码位于 lib/ 目录下的各模块文件
# ============================================================


# >>>>>>>>> BEGIN MODULE: 00_base.sh <<<<<<<<<<<
# ============================================================
# 模块: 00_base.sh
# 职责: 全局常量、颜色码、UI 基础函数、协议注册表、共享 jq 模板
# ============================================================

set -Eeuo pipefail

# -------------------- 版本 --------------------
SCRIPT_VERSION="6.1.9"

# -------------------- 路径常量 --------------------
CONFIG_FILE="/etc/sing-box/config.json"
SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
SB_TARGET_SCRIPT="/root/sb.sh"
SB_SHORTCUT="/usr/local/bin/s"
SINGBOX_RELEASE_REPO="Tangfffyx/sing-box"
SINGBOX_INSTALL_DIR="/usr/local/bin"
SINGBOX_BIN="${SINGBOX_INSTALL_DIR}/sing-box"
SINGBOX_VERSION_STAMP="/etc/sing-box/.installed_release"
GRPCURL_BIN="/usr/local/bin/grpcurl"
V2RAY_API_LISTEN="127.0.0.1:18080"
V2RAY_PROTO_V2RAY="/etc/sing-box/v2rayapi-v2ray.proto"
USER_WATCH_CRON_MARK="sb.sh --user-watch"
USER_WATCH_CRON_SCHEDULE="*/5 * * * *"
LOG_MAINTAIN_CRON_MARK="sb.sh --maintain-logs"
LOG_MAINTAIN_CRON_SCHEDULE="0 4 * * *"
TG_AGENT_CRON_MARK="sb.sh --tg-agent-sync"
TG_AGENT_CRON_SCHEDULE="* * * * *"
UPSTREAM_REFRESH_CRON_MARK="sb.sh --refresh-upstream"
UPSTREAM_REFRESH_CRON_SCHEDULE="47 3 * * *"
PERIODIC_SYNC_CRON_MARK="sb.sh --periodic-sync"
PERIODIC_SYNC_CRON_SCHEDULE="*/3 * * * *"
DAILY_MAINTENANCE_CRON_MARK="sb.sh --daily-maintenance"
DAILY_MAINTENANCE_CRON_SCHEDULE="47 4 * * *"
UPSTREAM_TAG_CACHE_FILE="/etc/sing-box-manager/.upstream-tag-cache"
UPSTREAM_TAG_CACHE_MAX_AGE_SECS=172800
SCRIPT_LOG_FILE="/var/log/sing-box/access.log"
LOG_MAX_BYTES=$((10 * 1024 * 1024))
USER_DB_FILE="/etc/sing-box-manager/user-manager.json"
META_FILE="/etc/sing-box-manager/meta.json"
TG_CONFIG_FILE="/etc/sing-box-manager/telegram.json"
TG_TASK_RECEIPTS_FILE="/etc/sing-box-manager/tg-task-receipts.json"
TG_CENTER_APP="/etc/sing-box-manager/tg-center-bot.py"
TG_CENTER_SERVICE="sb-tg-bot"
SB_LOCK_FILE="/var/lock/singbox-manager.lock"
TG_AGENT_LOCK_FILE="/var/lock/singbox-tg-agent.lock"

# 业务时区：所有"今天/本月"判断（重置日、到期日、续期）都按它算，
# 与 OS 时区无关，避免跨 VPS 因 OS 时区不同导致重置/到期时刻分裂。
BUSINESS_TZ="Asia/Shanghai"

# -------------------- 颜色 --------------------
B='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'
C='\033[1;36m'; NC='\033[0m'; W='\033[1;37m'

# -------------------- 日志/UI 函数 --------------------
say()  { echo -e "${C}[INFO]${NC} $*"; }
ok()   { echo -e "${G}[ OK ]${NC} $*"; }
warn() { echo -e "${Y}[WARN]${NC} $*" >&2; }
err()  { echo -e "${R}[ERR ]${NC} $*" >&2; }
pause(){ read -r -n 1 -p "按任意键继续..." || true; echo ""; }
ui_echo(){ printf '%b\n' "$*" >&2; }

param_echo() {
  local label="$1" value="$2"
  printf '  %b%s%b: %b%s%b\n' "$W" "$label" "$NC" "$C" "$value" "$NC" >&2
}

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

# ====================================================
# 协议注册表 — 所有协议定义的唯一权威来源
# 新增协议：只需在此注册 + 写 builder + 写 exporter
# ====================================================
SUPPORTED_PROTOCOLS=(vless-reality anytls shadowsocks socks trojan vmess-ws vless-ws tuic)

declare -A PROTO_PREFIX=(
  [vless-reality]=reality
  [anytls]=anytls
  [shadowsocks]=ss
  [trojan]=trojan
  [vmess-ws]=vmess-ws
  [vless-ws]=vless-ws
  [tuic]=tuic
  [socks]=socks
)

declare -A PREFIX_TO_PROTO=()
for proto in "${SUPPORTED_PROTOCOLS[@]}"; do
  PREFIX_TO_PROTO["${PROTO_PREFIX[$proto]}"]="$proto"
done
unset proto

declare -A PROTO_TRANSPORT=(
  [vless-reality]=tcp
  [anytls]=tcp
  [shadowsocks]="tcp udp"
  [trojan]=tcp
  [vmess-ws]=tcp
  [vless-ws]=tcp
  [tuic]=udp
  [socks]=tcp
)

# ====================================================
# 共享 jq 模板 — 消除跨模块重复定义
# 使用方式：echo "$json" | jq "${JQ_DETECT_PROTOCOL} ..."
# ====================================================
#
# 【项目标准】jq 多字段输出与 bash read 配合规范
# ----------------------------------------------------
# 当需要从 jq 输出中用 read 拆分多个字段，且任一字段可能为空时，
# 必须使用 \x01 (SOH) 作为分隔符，而不是 \t (@tsv)：
#
#   ✔ 正确：
#     jq -r '[...] | join("\u0001")' | {
#       IFS=$'\x01' read -r a b c d
#     }
#
#   ✘ 错误（已知 bug 源，v5.3.5 修复过）：
#     jq -r '[...] | @tsv' | {
#       IFS=$'\t' read -r a b c d   # 连续 tab 被折叠，空字段导致字段左移
#     }
#
# 原因：bash 默认 IFS 包含 tab，遇到连续 tab 会折叠为单个分隔符。
#       \x01 不在默认 IFS 中，连续 \x01 会严格保留空字段位置。
# ====================================================

# 协议检测：将 inbound 对象映射为协议标签（唯一定义）
JQ_DETECT_PROTOCOL='
def detect_protocol:
  if .type == "vless" and (.tls.reality.enabled // false) then "vless-reality"
  elif .type == "anytls" then "anytls"
  elif .type == "shadowsocks" then "shadowsocks"
  elif .type == "trojan" then "trojan"
  elif .type == "vmess" and ((.transport.type // "") == "ws") then "vmess-ws"
  elif .type == "vless" and ((.transport.type // "") == "ws") then "vless-ws"
  elif .type == "tuic" then "tuic"
  elif .type == "socks" then "socks"
  else ""
  end;
'

# auth_user 统一数组化（唯一定义，取代 8 处内联）
JQ_AUTH_USERS='
def auth_users_array:
  if (.auth_user? == null) then []
  elif ((.auth_user | type) == "array") then .auth_user
  else [ .auth_user ]
  end;
'

# node_part 提取（唯一定义）
JQ_NODE_PART='
def node_part($s):
  if ($s | contains("@")) then ($s | split("@")[0]) else $s end;
'

# 协议排序索引：将 tag/node_key 映射为排序序号（唯一定义）
JQ_PROTOCOL_SORT='
def protocol_sort_index($tag):
  if ($tag | startswith("reality-")) then 0
  elif ($tag | startswith("anytls-")) then 1
  elif ($tag | startswith("ss-")) then 2
  elif ($tag | startswith("socks-")) then 3
  elif ($tag | startswith("trojan-")) then 4
  elif ($tag | startswith("vmess-ws-")) then 5
  elif ($tag | startswith("vless-ws-")) then 6
  elif ($tag | startswith("tuic-")) then 7
  else 99
  end;
'

# 组合：常用 jq 前缀（包含所有共享定义）
JQ_SHARED="${JQ_DETECT_PROTOCOL}${JQ_AUTH_USERS}${JQ_NODE_PART}${JQ_PROTOCOL_SORT}"

# ====================================================
# 节点排序基础设施 — bash 层面的协议排序
# 所有需要按协议排序的地方统一调用这些函数
# ====================================================

# 返回 node key 的排序序号（00-06，未知为 99）
node_protocol_sort_key() {
  local key="$1"
  local i=0 prefix
  for proto in "${SUPPORTED_PROTOCOLS[@]}"; do
    prefix="${PROTO_PREFIX[$proto]}"
    if [[ "$key" == "${prefix}-"* ]]; then
      printf '%02d' "$i"
      return 0
    fi
    i=$((i+1))
  done
  printf '99'
}

# 从 stdin 读取 node key，按协议顺序排序后输出
sort_node_keys_by_protocol() {
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    printf '%s\t%s\n' "$(node_protocol_sort_key "$key")" "$key"
  done | sort -t$'\t' -k1,1 -k2,2 | cut -f2
}

# 从 stdin 读取 SOH(\x01) 分隔行，按指定字段的协议顺序排序
# 保留旧函数名以兼容已有调用；用法：some_command | sort_tsv_by_protocol 1
sort_tsv_by_protocol() {
  local field="${1:-1}"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local fval
    fval="$(echo "$line" | cut -d$'\x01' -f"$field")"
    printf '%s\t%s\n' "$(node_protocol_sort_key "$fval")" "$line"
  done | sort -t$'\t' -k1,1 | cut -f2-
}

# >>>>>>>>> END MODULE: 00_base.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 01_utils.sh <<<<<<<<<<<
# ============================================================
# 模块: 01_utils.sh
# 职责: 通用工具函数（无业务逻辑依赖）
# ============================================================

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 运行此脚本。"
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

make_disk_tmp_dir() {
  local prefix="${1:-sb-install}" base="/var/tmp" tmp_dir
  mkdir -p "$base" 2>/dev/null || base="/tmp"
  tmp_dir="$(mktemp -d "${base}/${prefix}.XXXXXX")" || return 1
  echo "$tmp_dir"
}

random_b64_password() {
  local bytes="${1:-16}" value
  value="$(openssl rand -base64 "$bytes" 2>/dev/null || true)"
  if [ -z "$value" ]; then
    value="$(head -c "$bytes" /dev/urandom 2>/dev/null | openssl base64 -A 2>/dev/null || true)"
  fi
  [ -n "$value" ] && echo "$value"
}

run_with_timeout() {
  local seconds="$1"
  shift
  if has_cmd timeout; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

download_file() {
  local url="$1" output="$2" connect_timeout="${3:-20}" retry_count="${4:-3}"
  if [ ! -t 1 ] || [ ! -t 2 ]; then
    curl -fsSL --connect-timeout "$connect_timeout" --retry "$retry_count" "$url" -o "$output" >/dev/null 2>&1
    return $?
  fi

  local total tmp_err curl_pid rc size tick=0
  total="$(download_file_total_bytes "$url" "$connect_timeout")"
  tmp_err="$(mktemp /tmp/sb-download-err.XXXXXX)" || return 1
  rm -f "$output" >/dev/null 2>&1 || true

  curl -fsSL --connect-timeout "$connect_timeout" --retry "$retry_count" "$url" -o "$output" 2>"$tmp_err" &
  curl_pid=$!
  while kill -0 "$curl_pid" 2>/dev/null; do
    size="$(file_size_bytes "$output")"
    print_download_progress "$size" "$total" "$tick"
    tick=$((tick + 1))
    sleep 1
  done

  if wait "$curl_pid"; then
    rc=0
  else
    rc=$?
  fi

  clear_download_progress
  if [ "$rc" -ne 0 ] && [ -s "$tmp_err" ]; then
    sed 's/^/  /' "$tmp_err" >&2
  fi
  rm -f "$tmp_err" >/dev/null 2>&1 || true
  return "$rc"
}

download_file_total_bytes() {
  local url="$1" connect_timeout="${2:-20}" total
  [ "$connect_timeout" -gt 5 ] && connect_timeout=5
  total="$(curl -fsSIL --connect-timeout "$connect_timeout" --max-time 10 "$url" 2>/dev/null \
    | awk 'tolower($1) == "content-length:" {gsub(/\r/,"",$2); n=$2} END {if (n ~ /^[0-9]+$/) print n}')" || true
  echo "${total:-0}"
}

file_size_bytes() {
  local file="$1" size
  [ -f "$file" ] || { echo 0; return 0; }
  size="$(stat -c '%s' "$file" 2>/dev/null || wc -c < "$file" 2>/dev/null || echo 0)"
  size="${size//[[:space:]]/}"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  echo "$size"
}

format_download_bytes() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1073741824) printf "%.1fG", b / 1073741824;
    else if (b >= 1048576) printf "%.1fM", b / 1048576;
    else if (b >= 1024) printf "%.1fK", b / 1024;
    else printf "%dB", b;
  }'
}

print_download_progress() {
  local size="${1:-0}" total="${2:-0}" tick="${3:-0}" width=24
  local percent filled bar spin
  if [[ "$total" =~ ^[0-9]+$ ]] && [ "$total" -gt 0 ]; then
    percent=$((size * 100 / total))
    [ "$percent" -gt 100 ] && percent=100
    filled=$((percent * width / 100))
    bar="$(printf '%*s' "$filled" '' | tr ' ' '=')"
    if [ "$filled" -lt "$width" ]; then
      bar="${bar}>$(printf '%*s' $((width - filled - 1)) '')"
    fi
    printf '\r下载中 [%-*s] %3d%% %s/%s' "$width" "$bar" "$percent" "$(format_download_bytes "$size")" "$(format_download_bytes "$total")"
  else
    case $((tick % 4)) in
      0) spin="|" ;;
      1) spin="/" ;;
      2) spin="-" ;;
      *) spin="\\" ;;
    esac
    printf '\r下载中 [%s] %s' "$spin" "$(format_download_bytes "$size")"
  fi
}

clear_download_progress() {
  local cols="${COLUMNS:-80}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  printf '\r%*s\r' "$cols" ''
}

now_ms() {
  local value
  value="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]{13,}$ ]]; then
    echo "$value"
    return 0
  fi
  value="$(date +%s 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo $((value * 1000))
  else
    echo 0
  fi
}

# ---------- 包管理器 / init 系统检测 ----------

detect_pkg_manager() {
  if has_cmd apt-get; then echo "apt"
  elif has_cmd apk;   then echo "apk"
  else                     echo "unknown"
  fi
}
PKG_MANAGER="$(detect_pkg_manager)"

detect_init_system() {
  if has_cmd systemctl && systemctl --version >/dev/null 2>&1; then echo "systemd"
  elif has_cmd rc-service; then echo "openrc"
  else                          echo "unknown"
  fi
}
INIT_SYSTEM="$(detect_init_system)"

# ---------- 包管理抽象 ----------

pkg_installed() {
  case "$PKG_MANAGER" in
    apt) [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" = "installed" ] ;;
    apk) apk info -e "$1" >/dev/null 2>&1 ;;
    *)   return 1 ;;
  esac
}

pkg_update_once() {
  local stamp="/tmp/.sb_pkg_updated"
  [ -f "$stamp" ] && return 0
  case "$PKG_MANAGER" in
    apt)
      [ "${_PKG_INSTALL_QUIET:-0}" = "1" ] || say "更新包索引..."
      if [ "${_PKG_INSTALL_QUIET:-0}" = "1" ]; then
        apt-get update -y >/dev/null 2>&1
      else
        apt-get update -y
      fi
      ;;
    apk)
      [ "${_PKG_INSTALL_QUIET:-0}" = "1" ] || say "更新包索引..."
      if [ "${_PKG_INSTALL_QUIET:-0}" = "1" ]; then
        apk update -q >/dev/null 2>&1
      else
        apk update -q
      fi
      ;;
  esac
  touch "$stamp"
}

install_pkg() {
  local pkg="$1"
  pkg_installed "$pkg" && return 0
  pkg_update_once
  [ "${_PKG_INSTALL_QUIET:-0}" = "1" ] || say "安装依赖: $pkg"
  case "$PKG_MANAGER" in
    apt)
      if [ "${_PKG_INSTALL_QUIET:-0}" = "1" ]; then
        apt-get install -y "$pkg" >/dev/null 2>&1 || { err "依赖安装失败：$pkg"; return 1; }
      else
        apt-get install -y "$pkg"
      fi
      ;;
    apk)
      if [ "${_PKG_INSTALL_QUIET:-0}" = "1" ]; then
        apk add -q "$pkg" >/dev/null 2>&1 || { err "依赖安装失败：$pkg"; return 1; }
      else
        apk add -q "$pkg"
      fi
      ;;
    *)   err "不支持的包管理器，请手动安装: $pkg"; return 1 ;;
  esac
}

# 保留旧名以避免遗漏调用
install_pkg_apt() { install_pkg "$@"; }
apt_update_once()  { pkg_update_once; }

# ---------- 服务检测 ----------

singbox_service_active() {
  case "$INIT_SYSTEM" in
    systemd) has_cmd systemctl && systemctl is-active --quiet sing-box 2>/dev/null ;;
    openrc)  rc-service sing-box status >/dev/null 2>&1 ;;
    *)       return 1 ;;
  esac
}

generate_random_alpha_path() {
  local s
  s="$(openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z' | head -c 7 || true)"
  [ ${#s} -ge 7 ] || s="$(head -c 32 /dev/urandom 2>/dev/null | tr -dc 'A-Za-z' | head -c 7 || echo "xBqLmRt")"
  echo "/${s:0:7}"
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
  if [ -n "${_CACHED_PUBLIC_IP:-}" ]; then
    echo "$_CACHED_PUBLIC_IP"
    return 0
  fi
  local ip=""
  ip=$(curl -s4 --max-time 3 --connect-timeout 2 ifconfig.me 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 api.ipify.org 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 icanhazip.com 2>/dev/null | tr -d '\n' || true)
  [ -z "$ip" ] && ip="IP"
  _CACHED_PUBLIC_IP="$ip"
  echo "$ip"
}

local_warp_socks_proxy_url() {
  local proxy_file="/etc/wireguard/proxy.conf"
  local port
  [ -s "$proxy_file" ] || return 1
  port="$(awk -F: '/^[[:space:]]*BindAddress[[:space:]]*=/{gsub(/[[:space:]]/,"",$NF); print $NF; exit}' "$proxy_file" 2>/dev/null || true)"
  [ -n "$port" ] || port="40000"
  has_cmd ss || return 1
  ss -nltp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {found=1} END {exit !found}' || return 1
  echo "socks5h://127.0.0.1:${port}"
}

curl_maybe_warp() {
  local proxy tmp_file
  proxy="$(local_warp_socks_proxy_url 2>/dev/null || true)"
  if [ -n "$proxy" ]; then
    tmp_file="$(mktemp /tmp/sb-curl-warp.XXXXXX)" || {
      curl --proxy "$proxy" "$@" || curl "$@"
      return $?
    }
    if curl --proxy "$proxy" "$@" > "$tmp_file"; then
      cat "$tmp_file"
      rm -f "$tmp_file" >/dev/null 2>&1 || true
      return 0
    fi
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    curl "$@"
  else
    curl "$@"
  fi
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

ask_confirm_yn() {
  local prompt="${1:-确认继续吗？(y/N): }"
  local ans
  printf '%s' "$prompt" >&2
  read -r ans || ans=""
  [[ "$ans" =~ ^[Yy]$ ]]
}

is_valid_ymd_date() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  awk -v value="$value" '
    function leap(y) { return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) }
    function dim(y, m) {
      if (m == 2) return leap(y) ? 29 : 28
      if (m == 4 || m == 6 || m == 9 || m == 11) return 30
      return 31
    }
    BEGIN {
      split(value, a, "-")
      y = a[1] + 0; m = a[2] + 0; d = a[3] + 0
      if (y < 1 || m < 1 || m > 12 || d < 1 || d > dim(y, m)) exit 1
    }
  '
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

format_bytes_human() { format_traffic_auto "$@"; }

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

parse_traffic_to_bytes() {
  local raw="${1:-}" normalized num unit sign=1
  normalized="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  if [[ "$normalized" == -* ]]; then
    sign=-1
    normalized="${normalized#-}"
  fi
  if [[ ! "$normalized" =~ ^([0-9]+(\.[0-9])?)(mb|gb|tb)$ ]]; then
    return 1
  fi
  num="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[3]}"
  awk -v n="$num" -v u="$unit" -v s="$sign" 'BEGIN {
    if (u == "mb") printf "%.0f", s * n * 1048576;
    else if (u == "gb") printf "%.0f", s * n * 1073741824;
    else if (u == "tb") printf "%.0f", s * n * 1099511627776;
    else exit 1;
  }'
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

# >>>>>>>>> END MODULE: 01_utils.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 10_config.sh <<<<<<<<<<<
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

# >>>>>>>>> END MODULE: 10_config.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 20_protocol.sh <<<<<<<<<<<
# ============================================================
# 模块: 20_protocol.sh
# 职责: 协议构建器、TLS 域名选择、证书生成
# 依赖: 00_base.sh (协议注册表), 01_utils.sh
# ============================================================

# ---------- 协议 entry key 映射（基于注册表，取代 6 处 case） ----------

entry_key_prefix_by_type() {
  local proto="$1"
  local prefix="${PROTO_PREFIX[$proto]:-}"
  if [ -z "$prefix" ]; then return 1; fi
  echo "$prefix"
}

entry_key_from_parts() {
  local proto="$1" port="$2"
  local prefix
  prefix="$(entry_key_prefix_by_type "$proto")" || return 1
  echo "${prefix}-${port}"
}

entry_key_to_protocol_label() {
  local key="$1"
  # 从 entry_key 提取 prefix 并查注册表
  local prefix
  for prefix in "${!PREFIX_TO_PROTO[@]}"; do
    if [[ "$key" == "${prefix}-"* ]]; then
      echo "${PREFIX_TO_PROTO[$prefix]}"
      return 0
    fi
  done
  echo "unknown"
}

entry_key_to_port() {
  echo "$1" | awk -F- '{print $NF}'
}

# ---------- TLS 证书 ----------

ensure_self_signed_cert() {
  local cn="$1" crt_path="$2" key_path="$3"
  mkdir -p "$(dirname "$crt_path")" || return 1
  openssl req -x509 -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$key_path" -out "$crt_path" -days 36500 -nodes -subj "/CN=${cn}" >/dev/null 2>&1 || return 1
  [ -s "$crt_path" ] && [ -s "$key_path" ]
}

generate_reality_keypair_auto() {
  local out priv pub
  out="$(sing-box generate reality-keypair 2>/dev/null || true)"
  priv="$(printf '%s\n' "$out" | awk -F': *' '/PrivateKey/ {print $2; exit}')"
  pub="$(printf '%s\n' "$out" | awk -F': *' '/PublicKey/ {print $2; exit}')"
  if [ -n "$priv" ] && [ -n "$pub" ]; then
    printf '%s\t%s\n' "$priv" "$pub"
    return 0
  fi
  return 1
}

# ---------- TLS 域名选择 ----------

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
  t1="$(now_ms)"
  run_with_timeout 1 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null >/dev/null 2>&1 || return 1
  t2="$(now_ms)"
  if [[ "$t1" =~ ^[0-9]+$ ]] && [[ "$t2" =~ ^[0-9]+$ ]] && [ "$t2" -ge "$t1" ]; then
    echo $((t2 - t1))
  else
    echo 999
  fi
}

auto_pick_tls_domain() {
  local best_domain="" best_ms=999999 ms domain
  local -a candidates=()
  mapfile -t candidates < <(get_tls_domain_candidates)
  # 随机抽取 10 个域名测速，避免全量串行等待过久
  local total=${#candidates[@]}
  if [ "$total" -gt 10 ]; then
    local -a sampled=()
    local -a indices=()
    while [ ${#sampled[@]} -lt 10 ]; do
      local r=$((RANDOM % total))
      local dup=0 idx
      for idx in "${indices[@]}"; do
        [ "$idx" -eq "$r" ] && { dup=1; break; }
      done
      [ $dup -eq 0 ] && { sampled+=("${candidates[$r]}"); indices+=("$r"); }
    done
    candidates=("${sampled[@]}")
  fi
  for domain in "${candidates[@]}"; do
    [ -n "$domain" ] || continue
    ms="$(benchmark_tls_domain_ms "$domain" 2>/dev/null || true)"
    if [ -n "$ms" ] && [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -lt "$best_ms" ]; then
      best_ms="$ms"
      best_domain="$domain"
    fi
  done
  [ -n "$best_domain" ] || return 1
  printf '%s\t%s\n' "$best_domain" "$best_ms"
}

choose_tls_domain() {
  local proto_label="$1" choice manual picked picked_ms
  ui_echo "1. 手动输入"
  ui_echo "2. 自动测速选择推荐域名"
  read -r -p "请选择域名填写方式（回车默认2. 自动测速选择推荐域名）: " choice
  case "${choice:-2}" in
    1)
      read -r -p "请输入${proto_label}域名（回车返回）: " manual
      if [ -z "${manual:-}" ]; then
        warn "输入无效，已返回上一级。"
        pause >&2
        return 1
      fi
      param_echo "SNI" "$manual"
      echo "$manual"
      ;;
    *)
      picked="$(auto_pick_tls_domain 2>/dev/null || true)"
      if [ -n "$picked" ]; then
        picked_ms="${picked#*$'\t'}"
        picked="${picked%%$'\t'*}"
        param_echo "SNI" "${picked} (${picked_ms} ms)"
        echo "$picked"
      else
        warn "自动测速失败，已返回上一级。"
        pause >&2
        return 1
      fi
      ;;
  esac
}

# ---------- SS 密码规范化 ----------

ss2022_normalize_password_pair() {
  local raw="$1"
  local sp up
  if [ -z "$raw" ]; then
    sp="$(random_b64_password 16)"
    up="$(random_b64_password 16)"
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

ss2022_password_part_valid() {
  local part="$1"
  local bytes
  [ -n "$part" ] || return 1
  bytes="$(printf '%s' "$part" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" || return 1
  [ "$bytes" = "16" ]
}

ss2022_prepare_password_pair() {
  local raw="${1:-}" sp up
  if [ -z "$raw" ]; then
    sp="$(random_b64_password 16)"
    up="$(random_b64_password 16)"
    [ -n "$sp" ] && [ -n "$up" ] || return 1
    echo "${sp}:${up}"
    return 0
  fi

  sp="${raw%%:*}"
  if [[ "$raw" == *:* ]]; then
    up="${raw#*:}"
  else
    up="$sp"
  fi
  ss2022_password_part_valid "$sp" || return 1
  ss2022_password_part_valid "$up" || return 1
  echo "${sp}:${up}"
}

# ====================================================
# 协议 Inbound 构建器
# 每个协议一个函数，结构统一，互不依赖
# ====================================================

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

build_anytls_inbound() {
  local port="$1" sni="$2" pass="${3:-}"
  local entry_key crt key
  entry_key="$(entry_key_from_parts anytls "$port")"
  [ -n "$pass" ] || pass="$(random_b64_password 16)"
  crt="/etc/sing-box/anytls-${port}.crt"
  key="/etc/sing-box/anytls-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key" || return 1
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

build_ss_inbound() {
  local port="$1" raw_password="${2:-}"
  local entry_key server_p user_p normalized_pw
  entry_key="$(entry_key_from_parts shadowsocks "$port")"
  normalized_pw="$(ss2022_prepare_password_pair "$raw_password")" || return 1
  server_p="${normalized_pw%%:*}"
  user_p="${normalized_pw#*:}"
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
  local port="$1" sni="$2" pass="${3:-}"
  local entry_key crt key
  entry_key="$(entry_key_from_parts trojan "$port")"
  [ -n "$pass" ] || pass="$(random_b64_password 16)"
  crt="/etc/sing-box/trojan-${port}.crt"
  key="/etc/sing-box/trojan-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key" || return 1
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
  local port="$1" sni="$2" pass="${3:-}"
  local entry_key uuid crt key
  entry_key="$(entry_key_from_parts tuic "$port")"
  uuid="$(sing-box generate uuid)"
  [ -n "$pass" ] || pass="$(random_b64_password 12)"
  crt="/etc/sing-box/tuic-${port}.crt"
  key="/etc/sing-box/tuic-${port}.key"
  ensure_self_signed_cert "$sni" "$crt" "$key" || return 1
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

build_socks_inbound() {
  local port="$1" password="${2:-}"
  local entry_key
  entry_key="$(entry_key_from_parts socks "$port")"
  [ -n "$password" ] || password="$(random_b64_password 12)"
  jq -n --arg tag "$entry_key" --arg password "$password" --argjson port "$port" '
    {
      "type":"socks",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"username":$tag,"password":$password}]
    }
  '
}

# ---------- 证书清理 ----------

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

# ---------- 用户对象构建（按协议类型分派） ----------

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
    shadowsocks|anytls|trojan)
      jq -n --arg name "$full_name" --arg pass "$(random_b64_password 16)" '{name:$name,password:$pass}'
      ;;
    tuic)
      jq -n --arg name "$full_name" --arg uuid "$(sing-box generate uuid)" --arg pass "$(random_b64_password 12)" '{name:$name,uuid:$uuid,password:$pass}'
      ;;
    socks)
      jq -n --arg username "$full_name" --arg pass "$(random_b64_password 12)" '{username:$username,password:$pass}'
      ;;
    *)
      return 1
      ;;
  esac
}

find_user_obj_in_inbound() {
  local inbound="$1" full_name="$2"
  echo "$inbound" | jq -c --arg n "$full_name" '(.users // [])[]? | select(((.name // .username // "") == $n))' | head -n1
}

# >>>>>>>>> END MODULE: 20_protocol.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 30_route.sh <<<<<<<<<<<
# ============================================================
# 模块: 30_route.sh
# 职责: 路由重建、协议清单、端口冲突检测、inbound/relay 删除
# 依赖: 00_base.sh (JQ_SHARED), 10_config.sh, 20_protocol.sh
# ============================================================

# ---------- 中转命名约定 ----------

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

# ---------- 协议清单（使用共享 jq 模板） ----------

protocol_entry_inventory() {
  local json="$1"
  echo "$json" | jq -r "${JQ_DETECT_PROTOCOL}"'
    .inbounds[]?
    | (detect_protocol) as $proto
    | select($proto != "")
    | [(.tag // ""), $proto, ((.listen_port // 0) | tostring)]
    | join("\u0001")
  '
}

protocol_entry_inventory_ext() {
  local json="$1"
  echo "$json" | jq -r "${JQ_DETECT_PROTOCOL}"'
    .inbounds
    | to_entries[]?
    | .key as $idx
    | .value as $ib
    | ($ib | detect_protocol) as $proto
    | select($proto != "")
    | [$idx, ($ib.tag // ""), $proto, (($ib.listen_port // 0) | tostring)]
    | join("\u0001")
  '
}

inbound_protocol_name() {
  local inbound="$1"
  echo "$inbound" | jq -r "${JQ_DETECT_PROTOCOL}"'detect_protocol'
}

# ---------- 端口冲突检测（使用注册表） ----------

protocol_transport_layer() {
  local proto="$1"
  echo "${PROTO_TRANSPORT[$proto]:-tcp}"
}

config_port_in_use_by_layer() {
  local json="$1" port="$2" layer="$3" exclude_tag="${4:-}"
  echo "$json" | jq -e --arg p "$port" --arg ex "$exclude_tag" --arg layer "$layer" '
    .inbounds[]?
    | select((.listen_port? // empty | tostring) == $p)
    | select(($ex == "") or ((.tag // "") != $ex))
    | (if .type == "tuic" or .type == "hysteria2" or .type == "hysteria" then ["udp"]
       elif .type == "shadowsocks" then
         if (.network // "") == "" then ["tcp","udp"]
         elif (.network|type) == "array" then .network else (.network|split(",")) end
       else ["tcp"] end) as $layers
    | select(($layers | index($layer)) != null)
  ' >/dev/null 2>&1
}

port_conflict_for_protocol() {
  local json="$1" proto="$2" port="$3" exclude_tag="${4:-}"
  local layer
  layer="$(protocol_transport_layer "$proto")"
  local transport
  for transport in $layer; do
    if config_port_in_use_by_layer "$json" "$port" "$transport" "$exclude_tag"; then return 0; fi
  done
  return 1
}

find_inbound_by_entry_key() {
  local json="$1" entry_key="$2"
  echo "$json" | jq -c --arg ek "$entry_key" '.inbounds[]? | select(.tag==$ek)' | head -n1
}

# ---------- 辅助：列出所有节点 key ----------

list_all_node_keys() {
  local json="$1"
  {
    echo "$json" | jq -r '.inbounds[]?.tag // empty'
    echo "$json" | jq -r '
      .inbounds[]?
      | (.users // [])[]?
      | (.name // .username // empty)
    ' | while IFS= read -r n; do
      [ -n "$n" ] || continue
      np="$(user_node_part "$n")"
      if [[ "$np" == *"-to-"* ]]; then
        echo "$np"
      fi
    done
  } | awk 'NF' | LC_ALL=C sort -u | sort_node_keys_by_protocol
}

# ====================================================
# 路由重建（核心函数，使用共享 jq 模板去重）
# ====================================================

route_rebuild(){
  local json="$1"
  local meta_json="${2:-}"
  local normalized core_auth_users_json relay_pairs_json preserved_rules_json
  local warp_mode="off" warp_tags_json='[]'
  local warp_available_tags_json='[]'
  local relay_rule_groups_json='[]'
  local relay_available_groups_json='[]'

  normalized="$(config_normalize "$json")" || return 1

  [ -n "$meta_json" ] || meta_json="$(meta_load)"

  if echo "$meta_json" | jq -e . >/dev/null 2>&1; then
    warp_mode="$(echo "$meta_json" | jq -r 'if (.warp.mode // "off") == "rules" then "rules" else "off" end' 2>/dev/null || echo "off")"
    warp_tags_json="$(echo "$meta_json" | jq -c '
      [
        .warp.rules[]?
        | (.file // "") as $file
        | select($file != "")
        | "relay-" + (($file | sub("\\.srs$"; "")) | gsub("[^A-Za-z0-9_-]"; "-"))
      ] | unique
    ' 2>/dev/null || echo '[]')"
  fi
  if ! echo "$normalized" | jq -e '.outbounds[]? | select((.tag // "") == "warp")' >/dev/null 2>&1; then
    warp_mode="off"
    warp_tags_json='[]'
  fi
  if [ "$warp_mode" = "rules" ]; then
    warp_available_tags_json="$(
      echo "$normalized" | jq -c --argjson wanted "$warp_tags_json" '
        [
          .route.rule_set[]?
          | (.tag // empty) as $tag
          | select(($wanted | index($tag)) != null)
          | $tag
        ] | unique
      '
    )" || warp_available_tags_json='[]'
  else
    warp_available_tags_json='[]'
  fi

  if echo "$meta_json" | jq -e . >/dev/null 2>&1; then
    relay_rule_groups_json="$(echo "$meta_json" | jq -c '
      (.relay // {}) as $relay
      | ($relay.landing // null) as $legacy_landing
      | (
          if (($relay.landings // null) | type) == "object" then
            ($relay.landings // {})
          elif (($legacy_landing // null) | type) == "object" then
            {($legacy_landing.id // "default"): $legacy_landing}
          else
            {}
          end
        ) as $landings
      | [
          ($relay.rules // [])[]?
          | (.landing_id // ($legacy_landing.id // "default")) as $landing_id
          | select(($landing_id != "") and (($landings[$landing_id] // null) != null))
          | (.tag // empty) as $tag
          | select($tag != "")
          | {tag:$tag, out:("relay-" + $landing_id)}
        ]
    ' 2>/dev/null || echo '[]')"
  fi
  relay_available_groups_json="$(
    echo "$normalized" | jq -c --argjson wanted "$relay_rule_groups_json" '
      def uniq:
        reduce .[] as $x ([]; if index($x) then . else . + [$x] end);
      ([.route.rule_set[]?.tag // empty] | uniq) as $available_rules
      | ([.outbounds[]?.tag // empty] | uniq) as $available_outbounds
      | [
          ($wanted // [])[]
          | . as $wanted_rule
          | select(($available_rules | index($wanted_rule.tag)) != null)
          | select(($available_outbounds | index($wanted_rule.out)) != null)
        ]
      | group_by(.out)
      | map({o:.[0].out, tags:([.[].tag] | uniq | sort)})
    '
  )" || relay_available_groups_json='[]'

  core_auth_users_json="$(echo "$normalized" | jq -c "${JQ_NODE_PART}"'
    [.inbounds[]? | .tag as $entry | .users[]? | (.name // .username // "")
      | select(. != "" and node_part(.) == $entry)] | unique
  ')" || return 1
  relay_pairs_json="$(relay_list_table "$normalized" | jq -Rsc --argjson config "$normalized" '
    [$config.outbounds[]?.tag] as $tags
    | [split("\n")[] | select(length > 0) | split("\u0001")
       | select(.[1] != "" and .[2] != "") | {u:.[1],o:.[2]}
       | select(.o as $o | ($tags|index($o)) != null)] | sort_by(.o,.u) | unique_by(.u)
  ')" || return 1

  preserved_rules_json="$(
    echo "$normalized" | jq -c '
      [ .route.rules[]? | select(.auth_user? == null and .inbound? == null and . != {action:"reject"}) ]
    '
  )" || return 1

  echo "$normalized" | jq \
    --argjson core_auth "$core_auth_users_json" \
    --argjson relay "$relay_pairs_json" \
    --argjson kept "$preserved_rules_json" \
    --argjson relay_rule_groups "$relay_available_groups_json" \
    --argjson warp_tags "$warp_available_tags_json" '
    .route.rules = (
      ($kept // [])
      + (($relay // []) | group_by(.o) | map({auth_user:(map(.u) | unique | sort), outbound:.[0].o}))
      + (if ($core_auth | length) > 0 then (($relay_rule_groups // []) | map(select((.tags // []) | length > 0) | {auth_user:($core_auth | unique | sort),rule_set:(.tags | unique | sort),outbound:.o})) else [] end)
      + (if (($core_auth | length) > 0 and ($warp_tags | length) > 0) then [{auth_user:($core_auth | unique | sort),rule_set:$warp_tags,outbound:"warp"}] else [] end)
      + (if ($core_auth | length) > 0 then [{auth_user:($core_auth | unique | sort),outbound:"direct"}] else [] end)
    )
    # 保留规则的完整条件和顺序；生成的用户列表已在上面 unique。
    # 不可用 outbound/auth_user/rule_set 三字段对用户规则做全局去重。
    | . as $root
    | .outbounds |= map(
        (.tag // "") as $tag
        | select(
            (
              ($tag != "direct")
              and (($tag | startswith("out-")) or ($tag | startswith("to-")) or ($tag | startswith("relay-")))
              and (([$root.route.rules[]? | .outbound // empty] | index($tag)) == null)
            ) | not
          )
      )
    | if (.route.rule_set? == null) then .
      else
        (($warp_tags // []) + (($relay_rule_groups // []) | map(.tags[]?))) as $active_split_rule_tags
        | .route.rule_set = (
            ((.route.rule_set // []) | if type == "array" then . else [.] end)
            | map(
                (.tag // "") as $tag
                | select(
                    (
                      ((($tag | startswith("warp-geosite-")) or ($tag | startswith("relay-geosite-")))
                        and (($active_split_rule_tags | index($tag)) == null))
                    ) | not
                  )
              )
          )
      end
    | .route.rules += [{action:"reject"}]
    | del(.route.final)
  ' || return 1
}

# ====================================================
# 删除操作（使用共享 jq 模板去重）
# ====================================================

remove_relays_by_user_names(){
  local json="$1" users_json="$2"
  local updated_json

  updated_json="$(
    echo "$json" | jq "${JQ_AUTH_USERS}"'
      .inbounds |= map(
        if .users? then
          .users |= map(select(((.name // .username // "") as $n | ($users | index($n))) == null))
        else . end
      )
      | .route.rules |= map(
          if (.auth_user? == null) then .
          else
            (auth_users_array | [.[] | . as $u | select(($users | index($u)) == null)]) as $remain
            | if ($remain | length) == 0 then empty
              elif ($remain | length) == 1 then .auth_user = $remain[0]
              else .auth_user = $remain
              end
          end
        )
    ' --argjson users "$users_json"
  )" || return 1

  route_rebuild "$updated_json" || return 1
}

remove_inbound_by_entry_key(){
  local json="$1" entry_key="$2"
  local inbound_users_json related_outbounds_json updated_json

  inbound_users_json="$(
    echo "$json" | jq -c --arg ek "$entry_key" '
      [
        .inbounds[]?
        | select(.tag == $ek)
        | (.users // [])[]?
        | (.name // .username // empty)
        | select(. != "")
      ]
    '
  )" || return 1

  related_outbounds_json="$(
    echo "$json" | jq -c "${JQ_AUTH_USERS}"'
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
    ' --argjson users "$inbound_users_json"
  )" || return 1

  updated_json="$(
    echo "$json" | jq "${JQ_AUTH_USERS}"'
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
    ' --arg ek "$entry_key" --argjson users "$inbound_users_json"
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
    echo "$json" | jq -c "${JQ_NODE_PART}"'
      [
        .inbounds[]?
        | select(.tag == $ek)
        | (.users // [])[]?
        | (.name // .username // empty)
        | select(. != "" and (node_part(.) | contains("-to-")))
      ]
    ' --arg ek "$entry_key"
  )"

  remove_relays_by_user_names "$json" "$relay_users_json"
}

# >>>>>>>>> END MODULE: 30_route.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 35_split_rule_conflict.sh <<<<<<<<<<<
# ============================================================
# 模块: 35_split_rule_conflict.sh
# 职责: WARP 分流与部分流量中转之间的规则归属互斥
# 依赖: 00_base.sh, 01_utils.sh, 40_relay.sh, 64_warp.sh
# ============================================================

split_rule_files_json_from_args() {
  if [ "$#" -eq 0 ]; then
    echo '[]'
    return 0
  fi
  printf '%s\n' "$@" | awk 'NF' | jq -R . | jq -s 'unique'
}

split_rule_relay_conflicts_json() {
  local files_json="$1"
  relay_meta_rules_json | jq -c --argjson files "$files_json" '
    [
      .[]?
      | (.file // "") as $file
      | select($file != "" and (($files | index($file)) != null))
    ] | unique_by(.file)
  '
}

split_rule_warp_conflicts_json() {
  local files_json="$1"
  warp_meta_rules_json | jq -c --argjson files "$files_json" '
    [
      .[]?
      | (.file // "") as $file
      | select($file != "" and (($files | index($file)) != null))
    ] | unique_by(.file)
  '
}

split_rule_has_warp_conflicts() {
  local files_json="$1" conflicts
  conflicts="$(split_rule_warp_conflicts_json "$files_json")" || return 1
  [ "$(echo "$conflicts" | jq 'length')" -gt 0 ]
}

split_rule_clear_all_meta() {
  local meta_json
  meta_json="$(meta_load)"
  meta_json="$(echo "$meta_json" | jq 'del(.warp) | del(.relay)')" || return 1
  meta_save "$meta_json"
}

split_rule_confirm_relay_to_warp() {
  local files_json="$1" conflicts count
  conflicts="$(split_rule_relay_conflicts_json "$files_json")" || return 1
  count="$(echo "$conflicts" | jq 'length')" || return 1
  [ "$count" -gt 0 ] || return 0

  warn "以下规则已在部分流量中转中使用："
  echo "$conflicts" | jq -r '
    .[]?
    | "  - \(.name // .file) -> 落地\(.landing_id // "未设置")：\(.file // "")"
  '
  ask_confirm_yn "是否改为 WARP 分流？(y/N): " || return 1
}

split_rule_take_over_relay_to_warp() {
  local files_json="$1"
  split_rule_confirm_relay_to_warp "$files_json" || return 1
  relay_rule_remove_meta_by_files_json "$files_json"
}

split_rule_confirm_warp_to_relay() {
  local files_json="$1" conflicts count
  conflicts="$(split_rule_warp_conflicts_json "$files_json")" || return 1
  count="$(echo "$conflicts" | jq 'length')" || return 1
  [ "$count" -gt 0 ] || return 0

  warn "以下规则已在 WARP 分流中使用："
  echo "$conflicts" | jq -r '
    .[]?
    | "  - \(.name // .file)：\(.file // "")"
  '
  ask_confirm_yn "是否改为部分流量中转？(y/N): " || return 1
}

split_rule_take_over_warp_to_relay() {
  local files_json="$1"
  warp_rule_remove_meta_by_files_json "$files_json"
}

# 预设规则的规范显示名：按 file 反查，未匹配返回空。
# relay/warp 两边的"规则展示"都走它，避免老 meta 里 .name 与新预设名不同步。
split_rule_preset_display_name() {
  case "${1:-}" in
    geosite-category-ai-!cn.srs) echo "AI 服务" ;;
    geosite-google.srs)          echo "Google" ;;
    geosite-netflix.srs)         echo "Netflix" ;;
    geosite-disney.srs)          echo "Disney+" ;;
    geosite-youtube.srs)         echo "YouTube" ;;
    geosite-tiktok.srs)          echo "TikTok" ;;
    *) echo "" ;;
  esac
}

# 分流总览：把 relay 部分流量规则与 WARP 分流规则合并展示，按预设顺序输出"规则名 → 去向"。
# 中转管理菜单与 WARP 分流管理菜单顶部都调它，两边视图一字不差。
split_rule_overview_lines() {
  local relay_rules warp_rules combined count sorted file name dest display arrow padded
  relay_rules="$(relay_meta_rules_json 2>/dev/null)" || relay_rules='[]'
  warp_rules="$(warp_meta_rules_json 2>/dev/null)" || warp_rules='[]'
  [ -n "$relay_rules" ] || relay_rules='[]'
  [ -n "$warp_rules" ] || warp_rules='[]'
  combined="$(jq -nc \
    --argjson relay "$relay_rules" \
    --argjson warp "$warp_rules" '
    ($relay | map({file:(.file // ""), name:(.name // ""), dest:("relay:" + (.landing_id // "未设置"))}))
    + ($warp | map({file:(.file // ""), name:(.name // ""), dest:"warp"}))
    | unique_by(.file)
  ' 2>/dev/null)" || combined='[]'
  count="$(echo "$combined" | jq 'length' 2>/dev/null)" || count=0
  if [ "$count" -eq 0 ]; then
    echo "分流总览：暂无规则"
    return 0
  fi
  echo "分流总览：（共 ${count} 条）"
  sorted="$(echo "$combined" | jq -r '
    def preset_index($file):
      if   $file == "geosite-category-ai-!cn.srs" then 0
      elif $file == "geosite-google.srs"          then 1
      elif $file == "geosite-netflix.srs"         then 2
      elif $file == "geosite-disney.srs"          then 3
      elif $file == "geosite-youtube.srs"         then 4
      elif $file == "geosite-tiktok.srs"          then 5
      else 99 end;
    sort_by(preset_index(.file), .file, .name)
    | .[]
    | (.file // "") + "" + (.name // "") + "" + (.dest // "")
  ' 2>/dev/null)" || return 0
  while IFS=$'\x01' read -r file name dest; do
    [ -z "$file" ] && [ -z "$name" ] && continue
    display="$(split_rule_preset_display_name "$file")"
    [ -n "$display" ] || display="$name"
    [ -n "$display" ] || display="$file"
    case "$dest" in
      warp)    arrow="WARP" ;;
      relay:*) arrow="落地机 ${dest#relay:}" ;;
      *)       arrow="$dest" ;;
    esac
    padded="$(pad_display_text "$display" 22)"
    printf '  %s → %s\n' "$padded" "$arrow"
  done <<< "$sorted"
}

# >>>>>>>>> END MODULE: 35_split_rule_conflict.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 40_relay.sh <<<<<<<<<<<
# ============================================================
# 模块: 40_relay.sh
# 职责: 中转节点列表、全量中转、部分流量中转、删除、菜单
# 依赖: 00_base.sh, 10_config.sh, 20_protocol.sh, 30_route.sh
# ============================================================

RELAY_RULE_BASE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
RELAY_RULE_LOOKUP_URL="https://github.com/SagerNet/sing-geosite/tree/rule-set"

relay_hr() {
  echo -e "${B}--------------------------------------------------------${NC}"
}

relay_partial_outbound_tag() {
  local land="$1"
  echo "relay-${land}"
}

# ---------- 中转节点列表（纯数据查询） ----------

relay_list_table() {
  local json="$1"
  echo "$json" | jq -r "${JQ_SHARED}"'
    . as $root
    | [
        .inbounds[]?
        | select((detect_protocol) != "")
        | .tag as $entry
        | (.users // [])[]?
        | (.name // .username // empty) as $name
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
    | join("\u0001")
  ' || return 1
}

# ---------- UI: 显示全量中转节点 ----------

show_managed_relay_lines() {
  local json="$1"
  local found=0
  local seen=""
  local relay_node
  while IFS=$'\x01' read -r entry relay_user out_tag; do
    [ -z "${relay_user:-}" ] && continue
    relay_node="$(user_node_part "$relay_user")"
    [ -n "$relay_node" ] || continue
    if printf '%s\n' "$seen" | grep -Fxq "$relay_node"; then
      continue
    fi
    seen="${seen}${relay_node}"$'\n'
    found=1
    echo -e "  - ${G}${relay_node}${NC}"
  done < <(relay_list_table "$json")
  [ $found -eq 1 ]
}

relay_full_summary_lines() {
  local json="$1" summary
  summary="$(
    relay_list_table "$json" | awk -F '\x01' '
      function node_part(s) { sub(/@.*/, "", s); return s }
      function land_part(s) { sub(/^.*-to-/, "", s); return s }
      NF >= 2 {
        node = node_part($2)
        if (node !~ /-to-/) next
        entry = node
        sub(/-to-.*/, "", entry)
        land = land_part(node)
        key = entry SUBSEP land
        if (!(key in seen)) {
          seen[key] = 1
          if (!(entry in entry_seen)) {
            entry_seen[entry] = 1
            entries[++entry_count] = entry
          }
          lands[entry] = lands[entry] (lands[entry] == "" ? "" : "、") land
        }
      }
      END {
        if (entry_count == 0) {
          print "全部流量转发：未启用"
        } else {
          print "全部流量转发："
          for (i = 1; i <= entry_count; i++) {
            entry = entries[i]
            printf "  - %-18s → 落地机：%s\n", entry, lands[entry]
          }
        }
      }
    '
  )"
  printf '%s\n' "$summary"
}

# ---------- SOCKS 落地 ----------

relay_socks_outbound_json() {
  local tag="$1" ip="$2" port="$3" username="${4:-}" password="${5:-}"
  jq -n --arg tag "$tag" --arg ip "$ip" --arg username "$username" --arg password "$password" --argjson p "$port" '
    {type:"socks", tag:$tag, server:$ip, server_port:$p}
    | if $username != "" then . + {username:$username, password:$password} else . end
  '
}

relay_prompt_landing_id() {
  local land_var="$1" _land
  read -r -p "落地标识（回车返回，如 sg01）: " _land
  [ -z "${_land:-}" ] && { warn "已取消，返回上一级。"; return 1; }
  if ! [[ "$_land" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    warn "落地标识仅允许字母、数字、点、下划线、短横线。"
    return 1
  fi
  printf -v "$land_var" '%s' "$_land"
}

relay_prompt_landing_details() {
  local ip_var="$2" port_var="$3" username_var="$4" password_var="$5"
  local _ip _relay_port _username _password

  read -r -p "落地 IP 地址（回车返回）: " _ip
  [ -z "${_ip:-}" ] && { warn "已取消，返回上一级。"; return 1; }

  read -r -p "落地 SOCKS 端口（默认: 1080）: " _relay_port
  _relay_port="${_relay_port:-1080}"
  if ! is_valid_port "$_relay_port"; then
    warn "落地 SOCKS 端口无效，已返回上一级。"
    return 1
  fi

  read -r -p "落地 SOCKS Username（无认证可留空）: " _username
  if [ -n "${_username:-}" ]; then
    read -r -p "落地 SOCKS Password: " _password
  else
    _password=""
  fi

  printf -v "$ip_var" '%s' "$_ip"
  printf -v "$port_var" '%s' "$_relay_port"
  printf -v "$username_var" '%s' "${_username:-}"
  printf -v "$password_var" '%s' "${_password:-}"
  return 0
}

relay_prompt_socks_landing() {
  local land_var="$1" ip_var="$2" port_var="$3" username_var="$4" password_var="$5"
  local _land
  relay_prompt_landing_id _land || return 1
  relay_prompt_landing_details "$_land" "$ip_var" "$port_var" "$username_var" "$password_var" || return 1
  printf -v "$land_var" '%s' "$_land"
}

relay_landing_to_meta_json() {
  local land="$1" ip="$2" port="$3" username="${4:-}" password="${5:-}"
  jq -n --arg id "$land" --arg server "$ip" --arg username "$username" --arg password "$password" --argjson port "$port" '
    {id:$id, server:$server, port:$port, username:$username, password:$password}
  '
}

relay_landing_from_outbound_json() {
  local json="$1" land="$2" tag="$3"
  echo "$json" | jq -c --arg id "$land" --arg tag "$tag" '
    .outbounds[]?
    | select((.tag // "") == $tag and (.type // "") == "socks")
    | {
        id:$id,
        server:(.server // ""),
        port:(.server_port // 0),
        username:(.username // ""),
        password:(.password // "")
      }
  ' | head -n1
}

relay_known_landing_json() {
  local json="$1" land="$2" existing=""
  existing="$(relay_meta_json | jq -c --arg id "$land" '.landings[$id] // empty' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  existing="$(relay_landing_from_outbound_json "$json" "$land" "$(relay_outbound_tag "" "$land")" 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  existing="$(relay_landing_from_outbound_json "$json" "$land" "$(relay_partial_outbound_tag "$land")" 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  echo "null"
}

relay_landing_display() {
  local landing_json="$1"
  echo "$landing_json" | jq -r '
    "\(.id // "default")（\(.server // ""):\(.port // 0)" +
    (if (.username // "") != "" then "，认证：" + (.username // "") else "，无认证" end) +
    "）"
  '
}

relay_choose_landing_or_return() {
  local json="$1" outvar="$2"
  local selected_land

  relay_prompt_landing_id selected_land || return 1
  relay_choose_landing_by_id_or_return "$json" "$selected_land" "$outvar"
}

relay_choose_landing_by_id_or_return() {
  local json="$1" selected_land="$2" outvar="$3"
  local selected_ip selected_port selected_username selected_password candidate existing choice

  existing="$(relay_known_landing_json "$json" "$selected_land")"

  if echo "$existing" | jq -e 'type == "object" and (.server // "") != ""' >/dev/null 2>&1; then
    echo
    echo "当前落地机：$(relay_landing_display "$existing")"
    echo
    echo -e "  ${C}1.${NC} 使用已有落地机"
    echo -e "  ${C}2.${NC} 更新落地机信息"
    echo -e "  ${R}0.${NC} 返回上一级"
    read -r -p "请选择操作: " choice
    case "${choice:-}" in
      1) printf -v "$outvar" '%s' "$existing"; return 0 ;;
      2)
        relay_prompt_landing_details "$selected_land" selected_ip selected_port selected_username selected_password || return 1
        candidate="$(relay_landing_to_meta_json "$selected_land" "$selected_ip" "$selected_port" "$selected_username" "$selected_password")" || return 1
        printf -v "$outvar" '%s' "$candidate"
        return 0
        ;;
      *) warn "已取消，返回上一级。"; return 1 ;;
    esac
  fi

  relay_prompt_landing_details "$selected_land" selected_ip selected_port selected_username selected_password || return 1
  candidate="$(relay_landing_to_meta_json "$selected_land" "$selected_ip" "$selected_port" "$selected_username" "$selected_password")" || return 1
  printf -v "$outvar" '%s' "$candidate"
  return 0
}

# ---------- 全部流量中转 ----------

relay_add() {
  init_manager_env || { pause; return 0; }
  local json lines=() entry_key choice land ip relay_port username password relay_user out_tag inbound landing_json
  json="$(config_load)"

  mapfile -t lines < <(protocol_entry_inventory "$json" | sort_tsv_by_protocol 1 | head -100)
  if [ ${#lines[@]} -eq 0 ]; then
    err "当前没有任何入站协议，请先在协议管理里安装协议。"
    pause
    return 1
  fi

  clear
  echo -e "${C}--- 添加/覆盖全部流量中转 ---${NC}"
  echo -e "${C}请选择入站协议：${NC}"
  local i=1 tag proto port
  for line in "${lines[@]}"; do
    IFS=$'\x01' read -r tag proto port <<< "$line"
    echo -e "  [$i] ${G}${tag}${NC}"
    i=$((i+1))
  done
  echo ""
  echo -e "${C}当前已配置全部流量中转：${NC}"
  if ! show_managed_relay_lines "$json"; then
    echo -e "  ${Y}当前没有全部流量中转。${NC}"
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
  IFS=$'\x01' read -r entry_key _ _ <<< "${lines[$((choice-1))]}"
  inbound="$(find_inbound_by_entry_key "$json" "$entry_key")"

  relay_choose_landing_or_return "$json" landing_json || { pause; return 0; }
  IFS=$'\x01' read -r land ip relay_port username password < <(
    echo "$landing_json" | jq -r '[.id, .server, ((.port // 0) | tostring), (.username // ""), (.password // "")] | join("\u0001")'
  )

  relay_user="$(relay_user_name "$entry_key" "$land")"
  out_tag="$(relay_outbound_tag "$entry_key" "$land")"

  local new_user new_out updated_json meta_json relay_json
  new_user="$(build_user_object_from_inbound "$inbound" "$relay_user")" || {
    err "不支持的入站协议，无法生成中转用户。"
    pause
    return 1
  }
  new_out="$(relay_socks_outbound_json "$out_tag" "$ip" "$relay_port" "$username" "$password")"

  updated_json="$(echo "$json" | jq "${JQ_AUTH_USERS}"'
    .inbounds |= map(
      if .tag == $ek then
        .users = (((.users // []) | map(select((.name // .username // "") != $ru))) + [$nu])
      else
        if .users? then .users |= map(select((.name // .username // "") != $ru)) else . end
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
  ' --arg ek "$entry_key" --arg ru "$relay_user" --arg ot "$out_tag" --argjson nu "$new_user" --argjson no "$new_out")"
  relay_json="$(relay_meta_upsert_landing_to_json "$(relay_meta_json)" "$landing_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$(meta_load)" "$relay_json")" || return 1
  updated_json="$(relay_project_partial_state_with_meta "$updated_json" "$meta_json")" || {
    err "重建路由失败，已中止，未写入配置。"
    pause
    return 1
  }
  local _relay_ok=0
  if user_db_exists; then
    local db_json
    sync_user_usage_counters || true
    db_json="$(user_db_load)"
    db_json="$(user_db_on_node_added "$db_json" "$relay_user")"
    if _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes "$db_json" "$updated_json" "$meta_json"; then
      _relay_ok=1
    fi
  else
    if _CONFIG_APPLY_QUIET_OK=1 config_and_meta_apply "$updated_json" "$meta_json"; then
      _relay_ok=1
    fi
  fi
  if [ "$_relay_ok" -eq 1 ]; then
    ok "全部流量中转已添加：${relay_user}（落地 SOCKS: ${ip}:${relay_port}）"
  else
    warn "全部流量中转添加失败，已返回上一级。"
  fi
  pause
  return 0
}

# ---------- 部分流量中转元数据 ----------

relay_meta_json_from_meta() {
  local meta_json="$1"
  echo "$meta_json" | jq -c '
    (.relay // {}) as $relay
    | ($relay.landing // null) as $legacy_landing
    | (
        if (($relay.landings // null) | type) == "object" then
          ($relay.landings // {})
        elif (($legacy_landing // null) | type) == "object" then
          {($legacy_landing.id // "default"): $legacy_landing}
        else
          {}
        end
      ) as $landings
    | ($legacy_landing.id // "default") as $legacy_id
    | {
        landings: $landings,
        rules: [
          ($relay.rules // [])[]?
          | (.landing_id = (.landing_id // $legacy_id))
          | select((.tag // "") != "" and (.file // "") != "" and (.landing_id // "") != "")
        ]
      }
  '
}

relay_meta_json() {
  relay_meta_json_from_meta "$(meta_load)"
}

relay_meta_rules_json() {
  relay_meta_json | jq -c '[.rules[]? | select((.tag // "") != "" and (.file // "") != "" and (.landing_id // "") != "")] | unique_by(.tag)'
}

relay_meta_landings_json() {
  relay_meta_json | jq -c '.landings // {}'
}

relay_meta_save_obj() {
  local relay_json="$1" meta_json
  meta_json="$(meta_load)"
  meta_json="$(echo "$meta_json" | jq --argjson r "$relay_json" '.relay = $r')" || return 1
  meta_save "$meta_json"
}

relay_meta_save_rules_obj() {
  local relay_json="$1"
  relay_json="$(echo "$relay_json" | jq '
    .landings = (.landings // {})
    | .rules = (.rules // [])
  ')" || return 1
  relay_meta_save_obj "$relay_json"
}

relay_meta_normalize_obj() {
  local relay_json="$1"
  echo "$relay_json" | jq -c '
    .landings = (.landings // {})
    | .rules = (.rules // [])
  '
}

relay_meta_replace_in_meta_json() {
  local meta_json="$1" relay_json="$2" normalized
  normalized="$(relay_meta_normalize_obj "$relay_json")" || return 1
  echo "$meta_json" | jq --argjson r "$normalized" '.relay = $r'
}

relay_meta_upsert_landing() {
  local landing_json="$1" relay_json
  relay_json="$(relay_meta_json | jq --argjson landing "$landing_json" '
    .landings = (.landings // {})
    | .landings[$landing.id] = $landing
  ')" || return 1
  relay_meta_save_rules_obj "$relay_json"
}

relay_rule_tag_for_file() {
  local file="$1" base tag
  base="${file%.srs}"
  tag="${base//[^A-Za-z0-9_-]/-}"
  echo "relay-${tag}"
}

relay_rule_url_for_file() {
  echo "${RELAY_RULE_BASE_URL}/$1"
}

relay_meta_upsert_landing_to_json() {
  local relay_json="$1" landing_json="$2"
  echo "$relay_json" | jq --argjson landing "$landing_json" '
    .landings = (.landings // {})
    | .landings[$landing.id] = $landing
  '
}

relay_rule_add_meta_to_json() {
  local relay_json="$1" name="$2" file="$3" landing_json="$4" tag url
  tag="$(relay_rule_tag_for_file "$file")"
  url="$(relay_rule_url_for_file "$file")"
  echo "$relay_json" | jq --arg name "$name" --arg file "$file" --arg tag "$tag" --arg url "$url" --argjson landing "$landing_json" '
    .landings = (.landings // {})
    | .landings[$landing.id] = $landing
    | .rules = (
        ((.rules // []) | map(select((.tag // "") != $tag)))
        + [{name:$name,file:$file,tag:$tag,url:$url,landing_id:$landing.id}]
      )
  '
}

relay_rule_remove_meta_by_tags_json_from() {
  local relay_json="$1" tags_json="$2"
  echo "$relay_json" | jq --argjson tags "$tags_json" '
    .rules = [
      (.rules // [])[]
      | (.tag // "") as $tag
      | select(($tags | index($tag)) == null)
    ]
  '
}

relay_rule_remove_meta_by_files_json_from() {
  local relay_json="$1" files_json="$2"
  echo "$relay_json" | jq --argjson files "$files_json" '
    .rules = [
      (.rules // [])[]
      | (.file // "") as $file
      | select(($files | index($file)) == null)
    ]
  '
}

relay_normalize_rule_file() {
  local raw="${1:-}" value
  value="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$value" ] || return 1
  if [[ "$value" == *"://"* ]]; then
    err "请输入 rule-set 文件名，不要输入完整 URL。"
    return 1
  fi
  [[ "$value" == geosite-* ]] || value="geosite-${value}"
  [[ "$value" == *.srs ]] || value="${value}.srs"
  [[ "$value" =~ ^geosite-[A-Za-z0-9._@!+-]+\.srs$ ]] || {
    err "规则名格式无效：$value"
    return 1
  }
  echo "$value"
}

relay_validate_rule_file() {
  local file="$1" url
  url="$(relay_rule_url_for_file "$file")"
  curl -fsIL --connect-timeout 10 --max-time 20 "$url" >/dev/null 2>&1
}

relay_preset_rule() {
  case "$1" in
    1) echo "AI 服务|geosite-category-ai-!cn.srs" ;;
    2) echo "Google|geosite-google.srs" ;;
    3) echo "Netflix|geosite-netflix.srs" ;;
    4) echo "Disney+|geosite-disney.srs" ;;
    5) echo "YouTube|geosite-youtube.srs" ;;
    6) echo "TikTok|geosite-tiktok.srs" ;;
    *) return 1 ;;
  esac
}

relay_rule_add_meta() {
  local name="$1" file="$2" landing_json="$3" relay_json
  relay_json="$(relay_rule_add_meta_to_json "$(relay_meta_json)" "$name" "$file" "$landing_json")" || return 1
  relay_meta_save_rules_obj "$relay_json"
}

relay_rule_remove_meta_by_tags_json() {
  local tags_json="$1" relay_json
  relay_json="$(relay_rule_remove_meta_by_tags_json_from "$(relay_meta_json)" "$tags_json")" || return 1
  relay_meta_save_rules_obj "$relay_json"
}

relay_rule_remove_meta_by_files_json() {
  local files_json="$1" relay_json
  relay_json="$(relay_rule_remove_meta_by_files_json_from "$(relay_meta_json)" "$files_json")" || return 1
  relay_meta_save_rules_obj "$relay_json"
}

relay_rule_clear_meta() {
  relay_meta_save_obj '{"landings":{},"rules":[]}'
}

relay_rules_count() {
  relay_meta_rules_json | jq 'length'
}

relay_rules_print_summary() {
  local relay_json rules_json count
  relay_json="$(relay_meta_json)"
  rules_json="$(echo "$relay_json" | jq -c '.rules // []')"
  count="$(echo "$rules_json" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    echo "部分流量转发：无"
    return 0
  fi
  echo "部分流量转发："
  echo "$relay_json" | jq -r '
    (.landings // {}) as $landings
    | (.rules // [])
    | sort_by(.landing_id // "", .name // "")
    | group_by(.landing_id // "")
    | .[]
    | (.[0].landing_id // "未设置") as $landing_id
    | "  - \($landing_id)：\([.[].name] | join("、"))"
  '
}

relay_rules_print_numbered() {
  local idx=0 file name display landing
  while IFS=$'\x01' read -r file name landing; do
    [ -z "$file" ] && continue
    idx=$((idx+1))
    display="$(split_rule_preset_display_name "$file")"
    [ -n "$display" ] || display="$name"
    [ -n "$display" ] || display="$file"
    printf '  %s. %s -> %s：%s\n' "$idx" "$display" "$landing" "$file"
  done < <(relay_meta_rules_json | jq -r '.[] | (.file // "") + "" + (.name // "") + "" + (.landing_id // "")')
}

relay_select_or_prompt_partial_landing() {
  local json="$1" outvar="$2"
  relay_choose_landing_or_return "$json" "$outvar"
}

relay_config_project_json() {
  local json="$1" rules_json="$2" landings_json="$3"
  echo "$json" | jq \
    --argjson rules "$rules_json" \
    --argjson landings "$landings_json" '
    def socks_out($tag; $landing):
      ({type:"socks", tag:$tag, server:($landing.server // ""), server_port:(($landing.port // 0) | tonumber)}
      | if (($landing.username // "") != "") then . + {username:$landing.username, password:($landing.password // "")} else . end);
    def rule_set_array:
      ((.rule_set // []) | if type == "array" then . else [.] end);
    ($rules | map(.tag // "") | unique) as $managed_tags
    |
    ($rules | map(.landing_id // "") | unique | map(select(. != "" and (($landings[.] // null) != null)))) as $used_landings
    |
    .route = (.route // {"rules":[],"final":"reject"})
    | .route.rules = (.route.rules // [])
    | .route.rules = (
        .route.rules
        | map(select(
            (((.outbound // "") == "relay-partial") | not)
            and (((.outbound // "") | startswith("relay-")) | not)
            and ((rule_set_array | any(. as $tag | ($managed_tags | index($tag)) != null)) | not)
          ))
      )
    | .route.rule_set = (
        ((.route.rule_set // [])
          | map((.tag // "") as $tag | select(($managed_tags | index($tag)) == null))
        )
        + (if (($rules | length) > 0 and ($used_landings | length) > 0) then
            ($rules | map(. as $rule | select(($used_landings | index($rule.landing_id // "")) != null) | {type:"remote", tag:$rule.tag, format:"binary", url:$rule.url, http_client:{version:2,detour:"direct"}}))
          else [] end)
      )
    | .outbounds = (
        ((.outbounds // [])
          | map(
              (.tag // "") as $tag
              | if ($tag | startswith("to-")) and (($landings[($tag | sub("^to-"; ""))] // null) != null) then
                  socks_out($tag; $landings[($tag | sub("^to-"; ""))])
                else .
                end
            )
          | map(select(((.tag // "") != "relay-partial") and (((.tag // "") | startswith("relay-")) | not)))
        )
        + (if ($used_landings | length) > 0 then
            ($used_landings | map(. as $landing_id | socks_out(("relay-" + $landing_id); $landings[$landing_id])))
          else [] end)
      )
  '
}

relay_project_partial_state_with_meta() {
  local json="$1" meta_json="$2" relay_json rules_json landings_json projected
  relay_json="$(relay_meta_json_from_meta "$meta_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  rules_json="$(echo "$relay_json" | jq -c '[.rules[]? | select((.tag // "") != "" and (.file // "") != "" and (.landing_id // "") != "")] | unique_by(.tag)')" || return 1
  landings_json="$(echo "$relay_json" | jq -c '.landings // {}')" || return 1
  projected="$(relay_config_project_json "$json" "$rules_json" "$landings_json")" || return 1
  route_rebuild "$projected" "$meta_json"
}

relay_project_partial_state() {
  relay_project_partial_state_with_meta "$1" "$(meta_load)"
}

relay_apply_meta_json_state() {
  local meta_json="$1" json projected normalized_relay
  normalized_relay="$(relay_meta_json_from_meta "$meta_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$normalized_relay")" || return 1
  json="$(config_load)"
  projected="$(relay_project_partial_state_with_meta "$json" "$meta_json")" || return 1
  _CONFIG_APPLY_QUIET_OK=1 _CONFIG_SKIP_USAGE_SYNC=1 config_and_meta_apply "$projected" "$meta_json"
}

relay_apply_partial_state() {
  relay_apply_meta_json_state "$(meta_load)"
}

relay_add_preset_rules() {
  local raw="$1" picks=() names=() files=() pick preset item name file landing_json json files_json has_warp_conflict=0
  local meta_json relay_json warp_json
  init_manager_env || return 1
  json="$(config_load)"
  mapfile -t picks < <(parse_plus_selections "$raw")
  [ "${#picks[@]}" -gt 0 ] || return 1
  for pick in "${picks[@]}"; do
    if ! [[ "$pick" =~ ^[2-7]$ ]]; then
      err "只能使用 2-7，并用 + 连接。"
      pause
      return 1
    fi
  done
  for pick in "${picks[@]}"; do
    preset=$((pick - 1))
    item="$(relay_preset_rule "$preset")" || return 1
    name="${item%%|*}"
    file="${item#*|}"
    names+=("$name")
    files+=("$file")
  done
  files_json="$(split_rule_files_json_from_args "${files[@]}")" || return 1
  if split_rule_has_warp_conflicts "$files_json"; then
    has_warp_conflict=1
    split_rule_confirm_warp_to_relay "$files_json" || {
      warn "已取消，未修改部分流量中转规则。"
      pause
      return 0
    }
  fi
  relay_select_or_prompt_partial_landing "$json" landing_json || { pause; return 0; }
  meta_json="$(meta_load)"
  warp_json="$(warp_rule_remove_meta_by_files_json_from "$(warp_meta_json)" "$files_json")" || return 1
  relay_json="$(relay_meta_json)"
  for pick in "${!files[@]}"; do
    relay_json="$(relay_rule_add_meta_to_json "$relay_json" "${names[$pick]}" "${files[$pick]}" "$landing_json")" || return 1
  done
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  relay_apply_meta_json_state "$meta_json" || return 1
  ok "部分流量中转规则已应用。"
  pause
}

relay_custom_rule_menu() {
  local raw file name landing_json json files_json has_warp_conflict=0 meta_json relay_json warp_json
  init_manager_env || return 1
  json="$(config_load)"
  clear
  print_rect_title "自定义网站规则"
  echo "请先在以下页面查找规则名："
  echo "$RELAY_RULE_LOOKUP_URL"
  echo
  echo "例如：openai 或 geosite-openai 或 geosite-openai.srs"
  read -r -p "请输入规则名（回车返回）：" raw
  [ -n "${raw:-}" ] || return 0
  file="$(relay_normalize_rule_file "$raw")" || { pause; return 1; }
  if ! relay_validate_rule_file "$file"; then
    err "未在 SagerNet rule-set 中找到：$file"
    pause
    return 1
  fi
  name="自定义：${file%.srs}"
  files_json="$(split_rule_files_json_from_args "$file")" || return 1
  if split_rule_has_warp_conflicts "$files_json"; then
    has_warp_conflict=1
    split_rule_confirm_warp_to_relay "$files_json" || {
      warn "已取消，未修改部分流量中转规则。"
      pause
      return 0
    }
  fi
  relay_select_or_prompt_partial_landing "$json" landing_json || { pause; return 0; }
  meta_json="$(meta_load)"
  warp_json="$(warp_rule_remove_meta_by_files_json_from "$(warp_meta_json)" "$files_json")" || return 1
  relay_json="$(relay_rule_add_meta_to_json "$(relay_meta_json)" "$name" "$file" "$landing_json")" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  relay_apply_meta_json_state "$meta_json" || return 1
  ok "自定义部分流量中转已添加：$file"
  pause
}

# ---------- 删除中转规则 ----------

relay_delete() {
  init_manager_env || { pause; return 0; }
  local json lines=() node_lines=() partial_json partial_count item_lines=() choice picks=()
  local updated_json line entry relay_user out_tag node_key users_json type payload display idx part
  local partial_changed=0 full_changed=0 has_delete_all=0 tags_json tag final_json meta_json relay_json
  local -a selected_tags=()

  json="$(config_load)"
  mapfile -t lines < <(relay_list_table "$json")
  mapfile -t node_lines < <(
    printf '%s\n' "${lines[@]}" | awk -F '\x01' '
      function node_part(s) { sub(/@.*/, "", s); return s }
      NF>=2 {
        node=node_part($2)
        if (!(node in seen)) {
          seen[node]=1
          print $1 "\001" node "\001" $3
        }
      }' | sort_tsv_by_protocol 2
  )
  partial_json="$(relay_meta_rules_json)"
  partial_count="$(echo "$partial_json" | jq 'length')"
  if [ ${#node_lines[@]} -eq 0 ] && [ "$partial_count" -eq 0 ]; then
    warn "当前没有中转规则。"
    pause
    return 0
  fi

  clear
  print_rect_title "删除中转规则"
  relay_hr
  local i=1
  if [ ${#node_lines[@]} -gt 0 ]; then
    echo "全部流量转发至落地机："
    for line in "${node_lines[@]}"; do
      IFS=$'\x01' read -r entry relay_user out_tag <<< "$line"
      display="全部流量：${relay_user}"
      item_lines+=("full"$'\x01'"$relay_user"$'\x01'"$display")
      echo -e "  ${C}${i}.${NC} ${display}"
      i=$((i+1))
    done
  fi
  if [ "$partial_count" -gt 0 ]; then
    echo "部分流量转发至落地机："
    while IFS=$'\x01' read -r tag display; do
      item_lines+=("partial"$'\x01'"$tag"$'\x01'"部分流量：${display}")
      echo -e "  ${C}${i}.${NC} 部分流量：${display}"
      i=$((i+1))
    done < <(echo "$partial_json" | jq -r '.[] | [(.tag // ""), ((.landing_id // "未设置") + "：" + (.name // "") + "：" + (.file // ""))] | join("\u0001")')
  fi
  relay_hr
  echo -e "  ${C}99.${NC} 删除全部中转规则"
  echo -e "  ${R}0.${NC} 返回上一级"
  echo
  echo "多个编号用+连接，例如：1+3"
  read -r -p "请输入要删除的编号：" choice
  [ -n "${choice:-}" ] || return 0
  [ "$choice" = "0" ] && return 0

  mapfile -t picks < <(parse_plus_selections "$choice")
  [ "${#picks[@]}" -gt 0 ] || { warn "未选择任何中转规则。"; pause; return 0; }
  for part in "${picks[@]}"; do
    [ "$part" = "99" ] && has_delete_all=1
  done
  if [ "$has_delete_all" = "1" ]; then
    if [ "${#picks[@]}" -ne 1 ]; then
      err "删除全部中转规则不能和其它编号一起使用。"
      pause
      return 1
    fi
    ask_confirm_yn "确认删除全部中转规则？(y/N): " || return 0
  fi

  updated_json="$json"
  meta_json="$(meta_load)"
  relay_json="$(relay_meta_json)"
  if [ "$has_delete_all" = "1" ]; then
    for line in "${node_lines[@]}"; do
      IFS=$'\x01' read -r entry node_key out_tag <<< "$line"
      users_json="$({
        printf '%s\n' "${lines[@]}" | awk -F '\x01' -v n="$node_key" '
          function node_part(s) { sub(/@.*/, "", s); return s }
          node_part($2)==n { print $2 }'
      } | awk 'NF' | sort -u | jq -R . | jq -s '.')"
      updated_json="$(remove_relays_by_user_names "$updated_json" "$users_json")" || {
        err "删除全部流量中转失败，已中止，未写入配置。"
        pause
        return 1
      }
      full_changed=1
    done
    relay_json='{"landings":{},"rules":[]}'
    [ "$partial_count" -gt 0 ] && partial_changed=1
  else
    for part in "${picks[@]}"; do
      if ! [[ "$part" =~ ^[0-9]+$ ]] || [ "$part" -lt 1 ] || [ "$part" -gt "${#item_lines[@]}" ]; then
        err "编号超出范围：$part"
        pause
        return 1
      fi
      idx=$((part-1))
      IFS=$'\x01' read -r type payload display <<< "${item_lines[$idx]}"
      case "$type" in
        full)
          node_key="$payload"
          users_json="$({
            printf '%s\n' "${lines[@]}" | awk -F '\x01' -v n="$node_key" '
              function node_part(s) { sub(/@.*/, "", s); return s }
              node_part($2)==n { print $2 }'
          } | awk 'NF' | sort -u | jq -R . | jq -s '.')"
          updated_json="$(remove_relays_by_user_names "$updated_json" "$users_json")" || {
            err "删除全部流量中转失败，已中止，未写入配置。"
            pause
            return 1
          }
          full_changed=1
          ;;
        partial)
          selected_tags+=("$payload")
          partial_changed=1
          ;;
      esac
    done
    if [ ${#selected_tags[@]} -gt 0 ]; then
      tags_json="$(printf '%s\n' "${selected_tags[@]}" | jq -R . | jq -s '.')" || { pause; return 1; }
      relay_json="$(relay_rule_remove_meta_by_tags_json_from "$relay_json" "$tags_json")" || return 1
    fi
  fi

  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  final_json="$(relay_project_partial_state_with_meta "$updated_json" "$meta_json")" || {
    err "重建中转规则失败，已中止，未写入配置。"
    pause
    return 1
  }

  local _delete_ok=0
  if user_db_exists; then
    local db_json
    sync_user_usage_counters || true
    db_json="$(user_db_load)"
    db_json="$(user_db_cleanup_missing_nodes "$db_json" "$final_json")"
    if _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes "$db_json" "$final_json" "$meta_json"; then
      _delete_ok=1
    fi
  else
    if _CONFIG_APPLY_QUIET_OK=1 config_and_meta_apply "$final_json" "$meta_json"; then
      _delete_ok=1
    fi
  fi

  if [ "$_delete_ok" -eq 1 ]; then
    if [ "$full_changed" -eq 1 ] && [ "$partial_changed" -eq 1 ]; then
      ok "中转规则已删除。"
    elif [ "$full_changed" -eq 1 ]; then
      ok "全部流量中转已删除。"
    else
      ok "部分流量中转已删除。"
    fi
  else
    warn "中转规则删除失败，已返回上一级。"
  fi
  pause
  return 0
}

# ---------- 中转管理主菜单 ----------

manage_relay_nodes() {
  init_manager_env || { pause; return 0; }
  while true; do
    clear
    local json act count
    json="$(config_load)"
    print_rect_title "中转管理"
    echo "当前中转规则："
    while IFS= read -r line; do
      echo "  $line"
    done < <(relay_full_summary_lines "$json")
    echo
    while IFS= read -r line; do
      echo "  $line"
    done < <(split_rule_overview_lines)
    relay_hr
    echo "----- 全部流量转发至落地机 -----"
    echo -e "  ${C}1.${NC} 本机作为中转机"
    echo
    echo "----- 部分流量转发至落地机 -----"
    echo -e "  ${C}2.${NC} AI 服务"
    echo -e "  ${C}3.${NC} Google"
    echo -e "  ${C}4.${NC} Netflix"
    echo -e "  ${C}5.${NC} Disney+"
    echo -e "  ${C}6.${NC} YouTube"
    echo -e "  ${C}7.${NC} TikTok"
    echo -e "  ${C}8.${NC} 自定义网站规则"
    count="$(relay_rules_count)"
    if [ "$count" -gt 0 ] || relay_list_table "$json" | awk 'NF {found=1} END {exit !found}'; then
      echo -e "  ${C}9.${NC} 删除中转规则"
    fi
    echo -e "  ${R}0.${NC} 返回主菜单"
    echo
    echo "2-7支持用+连接，例如：2+4+7"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) relay_add || true ;;
      8) relay_custom_rule_menu || true ;;
      9) relay_delete || true ;;
      0|q|Q|"") return 0 ;;
      *+*|[2-7]) relay_add_preset_rules "$act" || true ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

# >>>>>>>>> END MODULE: 40_relay.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 50_v2ray_api.sh <<<<<<<<<<<
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

# >>>>>>>>> END MODULE: 50_v2ray_api.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 60_user_db.sh <<<<<<<<<<<
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
  [ -s "$USER_DB_FILE" ] && jq -e '.enabled == true and (.users.admin != null)' "$USER_DB_FILE" >/dev/null 2>&1
}

user_db_load() {
  if user_db_exists; then
    cat "$USER_DB_FILE"
  else
    user_db_min_template
  fi
}

user_db_save() {
  with_manager_lock _user_db_save_body "$@"
}

user_db_touch_data_updated_at() {
  with_manager_lock _user_db_touch_data_updated_at_body "$@"
}

_user_db_touch_data_updated_at_body() {
  user_db_exists || return 0
  local db_json now_text
  db_json="$(user_db_load)"
  now_text="$(date '+%Y-%m-%d %H:%M:%S')"
  db_json="$(echo "$db_json" | jq --arg now "$now_text" '
    .meta = (.meta // {})
    | .meta.data_updated_at_text = $now
  ')" || return 1
  user_db_save "$db_json"
}

_user_db_save_body() {
  local db_json="$1"
  mkdir -p "$(dirname "$USER_DB_FILE")" /etc/sing-box
  chmod 700 "$(dirname "$USER_DB_FILE")" 2>/dev/null || true
  local tmp_file
  tmp_file="$(mktemp "${USER_DB_FILE}.tmp.XXXXXX")" || return 1
  if echo "$db_json" | jq . > "$tmp_file"; then
    if ! mv -f "$tmp_file" "$USER_DB_FILE"; then
      err "用户数据库写入失败：$USER_DB_FILE"
      rm -f "$tmp_file" >/dev/null 2>&1 || true
      return 1
    fi
    chmod 600 "$USER_DB_FILE" 2>/dev/null || true
  else
    rm -f "$tmp_file"
    return 1
  fi
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

user_db_cleanup_current_and_save() {
  with_manager_lock _user_db_cleanup_current_and_save_body "$@"
}

_user_db_cleanup_current_and_save_body() {
  local db_json json cleaned
  user_db_exists || return 0
  db_json="$(user_db_load)"
  json="$(config_load)"
  cleaned="$(user_db_cleanup_missing_nodes "$db_json" "$json")" || return 1
  user_db_save "$cleaned"
  return 0
}

# >>>>>>>>> END MODULE: 60_user_db.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 61_user_manager.sh <<<<<<<<<<<
# ============================================================
# 模块: 61_user_manager.sh
# 职责: 用户管理业务逻辑（投影、同步、自动控制）
# 依赖: 00_base.sh, 10_config.sh, 20_protocol.sh, 30_route.sh,
#       50_v2ray_api.sh, 60_user_db.sh
# ============================================================

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

    # Plan credentials in one jq pass; only new credentials need external generators.
    local plan users_json missing desired new_obj
    plan="$(echo "$inbound" | jq -c --argjson db "$db_json" --arg entry "$entry_key" --arg proto "$proto" "${JQ_NODE_PART}"'
      def business($n): if ($n|contains("@")) then ($n|split("@")[1]) else "admin" end;
      . as $ib
      | [(.users // [])[] | (.name // .username // "") | node_part(.)
         | select(contains("-to-") and . != $entry)] | unique as $relays
      | def allowed($node):
          $db.users | to_entries[] | select(.key != "admin")
          | select($proto != "socks" or .value.enabled == true)
          | select(.value.allow_all_nodes == true or ((.value.nodes // []) | index($node)) != null)
          | $node + "@" + .key;
      [if $proto != "socks" or $db.users.admin.enabled == true then $entry else empty end,
       allowed($entry), ($relays[] | . as $node | $node, allowed($node))] as $desired
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

# >>>>>>>>> END MODULE: 61_user_manager.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 62_user_menu.sh <<<<<<<<<<<
# ============================================================
# 模块: 62_user_menu.sh
# 职责: 用户管理交互菜单（纯 UI 层）
# 依赖: 00_base.sh, 01_utils.sh, 60_user_db.sh, 61_user_manager.sh
# ============================================================

user_package_invalid_return() {
  ui_echo "${Y}[WARN]${NC} 输入无效，未作修改，已返回上一级。"
}

show_user_status_table() {
  local db_json="$1"
  local sep=$'\t'
  local header widths_line row_line
  local -a rows=()
  local -a cols=()

  header="用户名${sep}状态${sep}上传流量${sep}下载流量${sep}补正流量${sep}已用总量${sep}套餐${sep}重置日${sep}到期时间"
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
          ((.value.manual_added_bytes // 0) | tostring),
          (((.value.used_up_bytes // 0) + (.value.used_down_bytes // 0) + (.value.manual_added_bytes // 0)) | tostring),
          ((if (.value.quota_gb // 0) == 0 then "不限" else ((.value.quota_gb|tostring) + "GB") end)),
          (if (.value.reset_day // 0) == 0 then "不重置" elif (.value.reset_day // 0) == 32 then "月底" else ((.value.reset_day|tostring) + "号") end),
          (if (.value.expire_at // "0") == "0" then "永久" else (.value.expire_at // "0") end)
        ] | join("\u0001")
    ' | while IFS=$'\x01' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9; do
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$c1" \
            "$c2" \
            "$(format_bytes_human "$c3")" \
            "$(format_bytes_human "$c4")" \
            "$(format_bytes_human "$c5")" \
            "$(format_bytes_human "$c6")" \
            "$c7" \
            "$c8" \
            "$c9"
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
  read -r -p "请输入到期日期（格式：YYYY-MM-DD，输入 0 表示永久，回车返回）: " val
  if [ "$val" = "0" ]; then
    printf -v "$outvar" '%s' '0'
    return 0
  fi
  if is_valid_ymd_date "$val"; then
    printf -v "$outvar" '%s' "$val"
    return 0
  fi
  ui_echo "${Y}[WARN]${NC} 日期不合法，未作修改，已返回上一级。"
  return 1
}

select_nodes_multi() {
  local json="$1" outvar="$2"
  local nodes=()
  # 节点按协议顺序排序
  mapfile -t nodes < <(list_all_node_keys "$json")
  if [ ${#nodes[@]} -eq 0 ]; then
    printf -v "$outvar" '%s' '[]'
    return 0
  fi
  ui_echo "请选择可用节点（多个用 + 连接，0 清除全部，回车跳过）："
  local i=1 node
  for node in "${nodes[@]}"; do
    ui_echo " [$i] $node"
    i=$((i+1))
  done
  local ans part selected=()
  read -r -p "请输入编号: " ans
  [ -z "${ans:-}" ] && { printf -v "$outvar" '%s' '__SKIP__'; return 0; }
  mapfile -t picks < <(parse_plus_selections "$ans")
  if [ ${#picks[@]} -eq 1 ] && [ "${picks[0]}" = "0" ]; then
    printf -v "$outvar" '%s' '[]'
    return 0
  fi
  for part in "${picks[@]}"; do
    if [[ "$part" =~ ^[0-9]+$ ]] && [ "$part" -ge 1 ] && [ "$part" -le "${#nodes[@]}" ]; then
      selected+=("${nodes[$((part-1))]}")
    fi
  done
  if [ ${#selected[@]} -gt 0 ]; then
    local picks_json
    picks_json="$(printf '%s\n' "${selected[@]}" | awk 'NF' | sort -u | jq -R . | jq -s '.')"
    printf -v "$outvar" '%s' "$picks_json"
  else
    printf -v "$outvar" '%s' '[]'
  fi
}

show_user_allowed_nodes() {
  local db_json="$1" username="$2"
  ui_echo "允许节点："
  if echo "$db_json" | jq -e --arg u "$username" '.users[$u].allow_all_nodes == true' >/dev/null 2>&1; then
    if [ "$username" = "admin" ]; then
      ui_echo "  - 全部节点（admin）"
    else
      ui_echo "  - 全部节点"
    fi
    return 0
  fi

  local has_node=0 node
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    ui_echo "  - $node"
    has_node=1
  done < <(echo "$db_json" | jq -r --arg u "$username" '.users[$u].nodes[]? // empty' | sort_node_keys_by_protocol)
  [ "$has_node" -eq 1 ] || ui_echo "  - （无）"
}

user_add_menu() {
  local db_json json username quota reset_day expire_at ans nodes_json allow_all_json before_db
  db_json="$(user_db_load)"
  before_db="$db_json"
  json="$(config_load)"
  clear
  print_rect_title "新增用户"
  show_user_status_table "$db_json"
  read -r -p "请输入用户名（回车返回）: " username
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
  read -r -p "请输入流量限制（GB，输入 0 表示不限，回车返回）: " quota
  [[ "$quota" =~ ^[0-9]+$ ]] || { warn "输入无效，未作修改，已返回上一级。"; pause; return 0; }
  prompt_reset_day reset_day
  if ! prompt_expire_date expire_at; then pause; return 0; fi

  # 节点权限设置（按协议顺序展示）
  allow_all_json='false'
  nodes_json='[]'
  ui_echo "${C}--- 节点权限 ---${NC}"
  select_nodes_multi "$json" nodes_json
  if [ "$nodes_json" = "__SKIP__" ]; then
    nodes_json='[]'
    ui_echo "已跳过节点权限设置，默认不分配节点。"
  fi

  db_json="$(echo "$db_json" | jq --arg u "$username" --argjson quota "$quota" --argjson reset "$reset_day" --arg expire "$expire_at" --argjson allow "$allow_all_json" --argjson nodes "$nodes_json" '
    .users[$u] = {
      enabled: true,
      disabled_reason: null,
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
  user_manager_commit_edit "$before_db" "$db_json" || { pause; return 1; }
  pause
}

user_manage_permission_menu() {
  local db_json="$1" username="$2" json="$3"
  local cleaned_db_json
  cleaned_db_json="$(user_db_cleanup_missing_nodes "$db_json" "$json")" || cleaned_db_json="$db_json"
  db_json="$cleaned_db_json"
  local current_nodes_json
  local nodes=() node i raw picks=() invalid=0 sel idx selected_json new_db

  clear >&2
  print_rect_title "节点权限" >&2
  show_user_status_table "$db_json" >&2
  current_nodes_json="$(echo "$db_json" | jq -c --arg u "$username" '(.users[$u].nodes // [])')"

  ui_echo "当前已分配节点："
  while IFS= read -r node; do
    [ -n "$node" ] && ui_echo "- $node"
  done < <(echo "$current_nodes_json" | jq -r '.[]?')
  if ! echo "$current_nodes_json" | jq -e 'length > 0' >/dev/null 2>&1; then
    ui_echo "- （无）"
  fi
  ui_echo "${B}--------------------------------------------------------${NC}"

  # 节点列表按协议顺序排序
  mapfile -t nodes < <(list_all_node_keys "$json")
  ui_echo "可选节点："
  ui_echo "  0. 清除全部节点权限"
  i=1
  for node in "${nodes[@]}"; do
    ui_echo "  ${i}. ${node}"
    i=$((i+1))
  done
  read -r -p "请输入编号（多个用 + 连接，回车返回上一级）: " raw
  [ -z "${raw:-}" ] && return 1
  mapfile -t picks < <(parse_plus_selections "$raw")
  [ ${#picks[@]} -eq 0 ] && return 1

  # 选择 0 = 清除全部
  if [ ${#picks[@]} -eq 1 ] && [ "${picks[0]}" = "0" ]; then
    new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].allow_all_nodes = false | .users[$u].nodes = []')"
    echo "$new_db"
    return 0
  fi

  for sel in "${picks[@]}"; do
    if ! [[ "$sel" =~ ^[0-9]+$ ]]; then invalid=1; break; fi
    if [ "$sel" -lt 1 ] || [ "$sel" -gt ${#nodes[@]} ]; then invalid=1; break; fi
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

  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson nodes "$selected_json" '.users[$u].allow_all_nodes = false | .users[$u].nodes = $nodes')"
  echo "$new_db"
}

user_manage_package_menu() {
  local db_json="$1" username="$2"
  local current_quota current_reset current_expire quota_in reset_in expire_in quota_val reset_val expire_val
  clear >&2
  print_rect_title "套餐设置" >&2
  show_user_status_table "$db_json" >&2

  IFS=$'\x01' read -r current_quota current_reset current_expire < <(
    echo "$db_json" | jq -r --arg u "$username" '
      [((.users[$u].quota_gb // 0) | tostring),
       ((.users[$u].reset_day // 0) | tostring),
       (.users[$u].expire_at // "0")] | join("\u0001")
    '
  )

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
  elif is_valid_ymd_date "$expire_in"; then
    expire_val="$expire_in"
  else
    user_package_invalid_return; pause >&2; return 1
  fi

  if [ "$quota_val" = "$current_quota" ] && [ "$reset_val" = "$current_reset" ] && [ "$expire_val" = "$current_expire" ]; then
    ui_echo "${C}[INFO]${NC} 未检测到改动，按任意键返回。"
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
  ui_echo "支持负值输入（如 -100MB）减少补正流量。"
  read -r -p "请输入要增添的流量（精确到小数点后一位，需带单位 MB、GB、TB，回车返回）: " raw
  bytes="$(parse_traffic_to_bytes "$raw")" || {
    warn "输入无效，未作修改，已返回上一级。"
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
  ui_echo "将清零该用户的上传流量、下载流量和手动补正流量。"
  ui_echo "此操作不会修改用户的启用状态、套餐设置、到期时间或重置日。"
  local ans
  read -r -p "输入 YES 确认重置该用户流量，其它任意输入取消: " ans
  if [ "$ans" != "YES" ]; then
    return 1
  fi
  echo "$db_json" | jq --arg u "$username" '
    .users[$u].used_up_bytes = 0
    | .users[$u].used_down_bytes = 0
    | .users[$u].manual_added_bytes = 0
  '
}

user_date_add_months() {
  local base_date="$1" months="$2"
  awk -v base="$base_date" -v add="$months" '
    function leap(y) { return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) }
    function dim(y, m) {
      if (m == 2) return leap(y) ? 29 : 28
      if (m == 4 || m == 6 || m == 9 || m == 11) return 30
      return 31
    }
    BEGIN {
      split(base, a, "-")
      y = a[1] + 0; m = a[2] + 0; d = a[3] + 0; add += 0
      if (y < 1 || m < 1 || m > 12 || d < 1 || d > dim(y, m) || add < 1) exit 1
      is_eom = (d == dim(y, m))
      total = y * 12 + (m - 1) + add
      ty = int(total / 12)
      tm = (total % 12) + 1
      td = is_eom ? dim(ty, tm) : d
      if (td > dim(ty, tm)) td = dim(ty, tm)
      printf "%04d-%02d-%02d\n", ty, tm, td
    }
  '
}

user_expire_is_past() {
  local today="$1" expire_at="$2"
  [ "$expire_at" != "0" ] && { [[ "$today" > "$expire_at" ]] || [[ "$today" == "$expire_at" ]]; }
}

user_renew_menu() {
  local db_json="$1" username="$2"
  local current_expire today base_date expired=0 choice months custom_months new_expire

  clear >&2
  print_rect_title "一键续期" >&2
  show_user_status_table "$db_json" >&2

  current_expire="$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].expire_at // "0"')"
  if [ "$current_expire" = "0" ]; then
    warn "永久用户无需续期。"
    pause >&2
    return 1
  fi

  today="$(user_today_date)"
  if user_expire_is_past "$today" "$current_expire"; then
    expired=1
    base_date="$today"
    warn "用户已过期：按今天续期，并重置流量。"
  else
    base_date="$current_expire"
  fi

  ui_echo "当前到期时间：$(expire_text "$current_expire")"
  ui_echo "续期起点：$base_date"
  ui_echo "1. 续期一个月"
  ui_echo "2. 续期一个季度"
  ui_echo "3. 自定义续期月数"
  read -r -p "请选择操作（回车返回上一级）: " choice
  case "${choice:-}" in
    1) months=1 ;;
    2) months=3 ;;
    3)
      read -r -p "填写需要续期的月数（回车返回）: " custom_months
      if ! [[ "$custom_months" =~ ^[0-9]+$ ]] || [ "$custom_months" -lt 1 ]; then
        user_package_invalid_return
        pause >&2
        return 1
      fi
      months="$custom_months"
      ;;
    "") return 1 ;;
    *)
      user_package_invalid_return
      pause >&2
      return 1
      ;;
  esac

  new_expire="$(user_date_add_months "$base_date" "$months")" || {
    err "续期日期计算失败，未作修改。"
    pause >&2
    return 1
  }
  param_echo "续期后到期时间" "$new_expire"
  ask_confirm_yn "确认续期吗？(y/N): " || {
    warn "已取消续期。"
    pause >&2
    return 1
  }

  echo "$db_json" | jq --arg u "$username" --arg exp "$new_expire" --argjson expired "$expired" '
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
  '
}

user_manage_single() {
  local username="$1"
  local db_json json act new_db mode is_admin=0
  [ "$username" = "admin" ] && is_admin=1
  while true; do
    sync_user_usage_counters || return 1
    db_json="$(user_db_load)"
    json="$(config_load)"
    clear
    print_rect_title "管理用户"
    show_user_status_table "$db_json"
    echo "当前用户：$username"
    [ $is_admin -eq 1 ] && echo "admin 为系统默认用户，不可删除，默认拥有全部节点权限。"
    show_user_allowed_nodes "$db_json" "$username"
    echo "  1. 启用/停用"
    [ $is_admin -eq 0 ] && echo "  2. 节点权限"
    echo "  3. 套餐设置"
    echo "  4. 手动重置流量"
    echo "  5. 手动添加流量（对齐总量）"
    echo "  6. 一键续期"
    echo "  0. 返回上一级"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1)
        if user_db_user_is_enabled "$db_json" "$username"; then
          new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = false | .users[$u].disabled_reason = "manual"')"
        else
          new_db="$(echo "$db_json" | jq --arg u "$username" '.users[$u].enabled = true | .users[$u].disabled_reason = null')"
        fi
        user_manager_commit_edit "$db_json" "$new_db" edit "$username" || true
        ;;
      2)
        if [ $is_admin -eq 1 ]; then
          warn "无效输入：$act"; sleep 1
        else
          new_db="$(user_manage_permission_menu "$db_json" "$username" "$json")" || new_db=""
          if json_is_object "$new_db"; then
            user_manager_commit_edit "$db_json" "$new_db" edit "$username" || true
          fi
        fi
        ;;
      3)
        new_db="$(user_manage_package_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_commit_edit "$db_json" "$new_db" edit "$username" || true
        fi
        ;;
      4)
        new_db="$(user_reset_usage_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_commit_edit "$db_json" "$new_db" reset "$username" || true
        fi
        ;;
      5)
        new_db="$(user_add_usage_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_commit_edit "$db_json" "$new_db" add "$username" || true
        fi
        ;;
      6)
        mode=edit
        if user_expire_is_past "$(user_today_date)" "$(echo "$db_json" | jq -r --arg u "$username" '.users[$u].expire_at // "0"')"; then mode=reset; fi
        new_db="$(user_renew_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_commit_edit "$db_json" "$new_db" "$mode" "$username" || true
        fi
        ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

user_select_and_manage_menu() {
  local db_json usernames=() ans idx username
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
  read -r -p "请选择用户（回车返回上一级）: " ans
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
  local db_json json usernames=() ans new_db picks=() part idx username
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
  read -r -p "请选择要删除的用户（支持 1+2+3，回车返回上一级）: " ans
  [ -z "${ans:-}" ] && return 0
  mapfile -t picks < <(parse_plus_selections "$ans")
  [ ${#picks[@]} -eq 0 ] && { warn "未选择任何用户。"; pause; return 1; }

  local names_to_delete=()
  for part in "${picks[@]}"; do
    if ! [[ "$part" =~ ^[0-9]+$ ]] || [ "$part" -lt 1 ] || [ "$part" -gt "${#usernames[@]}" ]; then
      err "编号超出范围：$part"
      pause
      return 1
    fi
    names_to_delete+=("${usernames[$((part-1))]}")
  done

  echo "即将删除以下用户："
  for username in "${names_to_delete[@]}"; do
    echo "  - $username"
  done
  ask_confirm_yes "输入 YES 确认彻底删除，其它任意输入取消: " || { warn "已取消删除。"; pause; return 0; }

  new_db="$db_json"
  for username in "${names_to_delete[@]}"; do
    new_db="$(echo "$new_db" | jq --arg u "$username" 'del(.users[$u])')" || return 1
  done
  user_manager_commit_edit "$db_json" "$new_db" || true
  pause
}

user_manager_menu() {
  if ! user_db_exists; then
    init_manager_env || { pause; return 0; }
    # 自愈：6.1.5 安装事务把 ensure_user_manager_ready 失败改成 warn，
    # 这里给用户管理菜单一个"进入时重试创建"的机会，避免用户卡在死循环。
    ensure_user_manager_ready || {
      err "用户数据库初始化失败，请检查 $USER_DB_FILE 所在磁盘和权限后再试。"
      pause
      return 0
    }
  fi
  while true; do
    local db_json
    db_json="$(user_db_load)"
    clear
    print_rect_title "用户管理"
    show_user_status_table "$db_json"
    echo -e "  ${C}1.${NC} 新增用户"
    echo -e "  ${C}2.${NC} 管理用户"
    echo -e "  ${C}3.${NC} 删除用户"
    echo -e "  ${C}4.${NC} Telegram Bot 管理"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) user_add_menu || true ;;
      2) user_select_and_manage_menu || true ;;
      3) user_delete_menu || true ;;
      4) telegram_bot_manager_menu || true ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

# >>>>>>>>> END MODULE: 62_user_menu.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 63_telegram_bot.sh <<<<<<<<<<<
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
  if [ -s "$TG_CONFIG_FILE" ] && jq -e . "$TG_CONFIG_FILE" >/dev/null 2>&1; then
    cat "$TG_CONFIG_FILE"
  else
    tg_config_min_template
  fi
}

tg_config_save() {
  with_manager_lock _tg_config_save_body "$@"
}

_tg_config_save_body() {
  local json="$1"
  mkdir -p "$(dirname "$TG_CONFIG_FILE")"
  chmod 700 "$(dirname "$TG_CONFIG_FILE")" 2>/dev/null || true
  local tmp_file
  tmp_file="$(mktemp "${TG_CONFIG_FILE}.tmp.XXXXXX")" || return 1
  if echo "$json" | jq . > "$tmp_file"; then
    if ! mv -f "$tmp_file" "$TG_CONFIG_FILE"; then
      err "TG 配置写入失败：$TG_CONFIG_FILE"
      rm -f "$tmp_file" >/dev/null 2>&1 || true
      return 1
    fi
    chmod 600 "$TG_CONFIG_FILE" 2>/dev/null || true
  else
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi
}

tg_task_receipts_load() {
  if [ -s "$TG_TASK_RECEIPTS_FILE" ] && jq -e . "$TG_TASK_RECEIPTS_FILE" >/dev/null 2>&1; then
    cat "$TG_TASK_RECEIPTS_FILE"
  else
    echo '{"tasks":{}}'
  fi
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
  mkdir -p "$(dirname "$TG_TASK_RECEIPTS_FILE")"
  chmod 700 "$(dirname "$TG_TASK_RECEIPTS_FILE")" 2>/dev/null || true
  local tmp_file
  tmp_file="$(mktemp "${TG_TASK_RECEIPTS_FILE}.tmp.XXXXXX")" || return 1
  if echo "$json" | jq . > "$tmp_file"; then
    if ! mv -f "$tmp_file" "$TG_TASK_RECEIPTS_FILE"; then
      err "TG 任务回执写入失败：$TG_TASK_RECEIPTS_FILE"
      rm -f "$tmp_file" >/dev/null 2>&1 || true
      return 1
    fi
    chmod 600 "$TG_TASK_RECEIPTS_FILE" 2>/dev/null || true
  else
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi
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
  local token="$1" method="$2" payload="${3:-{}}"
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
  cat > "$TG_CENTER_APP" <<'PY'
#!/usr/bin/env python3
import contextlib
import datetime
import fcntl
import http.server
import json
import os
import re
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

CONFIG_PATH = sys.argv[1] if len(sys.argv) > 1 else "/etc/sing-box-manager/telegram.json"
LOCK_PATH = "/var/lock/singbox-manager.lock"
REPORT_ONLINE_SECONDS = 900


def load_config():
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_config(cfg):
    # 与 bash 端 with_manager_lock 共享同一个 lock 文件。
    # 这是"单次写"的对外入口，自带文件锁。RMW（load→改→save）必须用 cfg_lock() 包，
    # 否则 load 和 save 之间存在间隙，跨进程 RMW 仍会丢更新。
    with file_lock():
        save_config_unlocked(cfg)


@contextlib.contextmanager
def file_lock():
    """跨进程文件锁，与 bash with_manager_lock 共享 SB_LOCK_FILE。"""
    os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
    fd = os.open(LOCK_PATH, os.O_CREAT | os.O_WRONLY, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass


def save_config_unlocked(cfg):
    """save_config 的不持锁版本——调用方已在 file_lock / cfg_lock 内时用这个。"""
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, CONFIG_PATH)
    try:
        os.chmod(CONFIG_PATH, 0o600)
    except OSError:
        pass


@contextlib.contextmanager
def cfg_lock():
    """RMW 双锁：threading.Lock 防同进程多线程竞争 + file_lock 防跨进程并发。
    替代 `with CFG_LOCK:` 块——后者只防同进程线程，没防 bash 与 Python 跨进程 RMW 丢更新。
    内部 load_config / save_config_unlocked 在同一把锁内进行。
    注意：CFG_LOCK 是非重入 threading.Lock，调用方不能在已持有 cfg_lock 的情况下再进入。"""
    with CFG_LOCK:
        with file_lock():
            yield


CFG_LOCK = threading.Lock()


def bot_api(method, payload=None):
    cfg = load_config()
    token = cfg.get("bot_token", "")
    if not token:
        return {"ok": False, "description": "bot token missing"}
    data = json.dumps(payload or {}).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read().decode("utf-8"))
        except Exception:
            return {"ok": False, "description": str(exc)}
    except Exception as exc:
        return {"ok": False, "description": str(exc)}


def send_message(chat_id, text, keyboard=None):
    payload = {
        "chat_id": chat_id,
        "text": text,
        "disable_web_page_preview": True,
    }
    if keyboard is not None:
        payload["reply_markup"] = {"inline_keyboard": keyboard}
    return bot_api("sendMessage", payload)


def edit_message(chat_id, message_id, text, keyboard=None):
    payload = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": text,
        "disable_web_page_preview": True,
    }
    if keyboard is not None:
        payload["reply_markup"] = {"inline_keyboard": keyboard}
    return bot_api("editMessageText", payload)


def render_page(chat_id, text, keyboard=None, message_id=None):
    if message_id:
        resp = edit_message(chat_id, message_id, text, keyboard)
        if resp.get("ok") or "message is not modified" in (resp.get("description") or ""):
            return resp
    return send_message(chat_id, text, keyboard)


def answer_callback(callback_id, text=None):
    payload = {"callback_query_id": callback_id}
    if text:
        payload["text"] = text
    bot_api("answerCallbackQuery", payload)


def get_bot_username(cfg):
    """读 bot_username。如果 cfg 里缺，在线 getMe 获取并写入 cfg（**只更新内存**）。
    调用方负责后续 save——避免与外层 cfg_lock 嵌套死锁（CFG_LOCK 是非重入锁）。"""
    username = cfg.get("bot_username") or ""
    if username:
        return username
    resp = bot_api("getMe", {})
    username = ((resp.get("result") or {}).get("username") or "")
    if username:
        cfg["bot_username"] = username
    return username


def today():
    # 锁定北京时间（UTC+8），与 bash 端的 user_today_date / BUSINESS_TZ 保持一致。
    # 用 utcnow + 8h 而非 zoneinfo，零依赖、不挑 Python 版本。
    return (datetime.datetime.utcnow() + datetime.timedelta(hours=8)).date()


def parse_date(value):
    if not value or value == "0":
        return None
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        return None


def fmt_bytes(value):
    try:
        b = float(value or 0)
    except Exception:
        b = 0.0
    gb = 1024 ** 3
    tb = 1024 ** 4
    if abs(b) >= tb:
        return f"{b / tb:.1f}TB"
    return f"{b / gb:.1f}GB"


def user_total(user):
    return int(user.get("used_up_bytes") or 0) + int(user.get("used_down_bytes") or 0) + int(user.get("manual_added_bytes") or 0)


def status_text(user):
    if user.get("enabled") is True:
        return "开启"
    reason = user.get("disabled_reason")
    if reason == "expired":
        return "关闭（到期）"
    if reason == "quota_exceeded":
        return "关闭（超量）"
    if reason == "manual":
        return "关闭（手动停用）"
    return "关闭"


def find_report_user(cfg, binding):
    report = (cfg.get("reports") or {}).get(binding.get("vps_id") or "")
    if not report:
        return None, None
    username = binding.get("username") or ""
    for user in report.get("users") or []:
        if user.get("username") == username:
            return report, user
    return report, None


def is_admin(cfg, tg_id):
    return str(tg_id) in {str(x) for x in cfg.get("admin_chat_ids") or []}


def user_home_keyboard(bindings=None):
    bindings = bindings or []
    rows = []
    row = []
    for idx, binding in enumerate(bindings):
        label = binding.get("vps_name") or binding.get("vps_id") or str(idx + 1)
        row.append({"text": label, "callback_data": f"u:detail:{idx}"})
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    if bindings:
        rows.append([{"text": "提醒设置", "callback_data": "u:notify"}, {"text": "解除绑定", "callback_data": "u:bind"}])
    return rows


def render_unbound_user_state(chat_id, message_id=None, text=None):
    render_page(
        chat_id,
        text or "当前没有绑定。\n请联系管理员生成绑定链接。",
        None,
        message_id,
    )


def back_keyboard(back_to):
    return [[{"text": "返回", "callback_data": back_to}]]


def clear_waiting_input(tg_id):
    with cfg_lock():
        cfg = load_config()
        waiting = cfg.setdefault("waiting_inputs", {})
        if str(tg_id) in waiting:
            waiting.pop(str(tg_id), None)
            save_config_unlocked(cfg)


def send_home(chat_id, tg_id, message_id=None):
    cfg = load_config()
    if is_admin(cfg, tg_id):
        admin_overview(chat_id, message_id)
    else:
        user_status(chat_id, tg_id, message_id)


def bind_token(chat_id, tg_id, token):
    with cfg_lock():
        cfg = load_config()
        pending = cfg.setdefault("pending_bind_tokens", {})
        item = pending.get(token)
        now = int(time.time())
        if not item or int(item.get("expires_at") or 0) < now:
            send_message(chat_id, "绑定链接已失效，请联系管理员重新生成。")
            return
        bindings = cfg.setdefault("bindings", [])
        exists = False
        for b in bindings:
            if str(b.get("tg_user_id")) == str(tg_id) and b.get("vps_id") == item.get("vps_id") and b.get("username") == item.get("username"):
                b["active"] = True
                b["chat_id"] = chat_id
                exists = True
                break
        if not exists:
            bindings.append({
                "tg_user_id": tg_id,
                "chat_id": chat_id,
                "vps_id": item.get("vps_id"),
                "vps_name": item.get("vps_name"),
                "username": item.get("username"),
                "active": True,
                "created_at": now,
            })
        pending.pop(token, None)
        settings = cfg.setdefault("user_settings", {})
        settings.setdefault(str(tg_id), {"notify": True})
        save_config_unlocked(cfg)
    send_message(chat_id, f"绑定成功：{item.get('vps_name')} / {item.get('username')}")
    send_home(chat_id, tg_id)


def user_bindings(cfg, tg_id):
    return [
        b for b in (cfg.get("bindings") or [])
        if b.get("active") is not False and str(b.get("tg_user_id")) == str(tg_id)
    ]


def user_status(chat_id, tg_id, message_id=None):
    cfg = load_config()
    bindings = user_bindings(cfg, tg_id)
    if not bindings:
        render_unbound_user_state(chat_id, message_id)
        return
    lines = ["我的绑定", ""]
    for b in bindings:
        lines.append(f"{b.get('vps_name') or b.get('vps_id')} / {b.get('username')}")
    render_page(chat_id, "\n".join(lines), user_home_keyboard(bindings), message_id)


def user_detail(chat_id, tg_id, idx, message_id=None):
    cfg = load_config()
    bindings = user_bindings(cfg, tg_id)
    if idx < 0 or idx >= len(bindings):
        user_status(chat_id, tg_id, message_id)
        return
    binding = bindings[idx]
    report, user = find_report_user(cfg, binding)
    title = f"{binding.get('vps_name') or binding.get('vps_id')} / {binding.get('username')}"
    if report is None:
        render_page(chat_id, f"{title}\n状态：节点暂无上报", back_keyboard("u:home"), message_id)
        return
    if user is None:
        render_page(chat_id, f"{title}\n状态：绑定已失效，请联系管理员", back_keyboard("u:home"), message_id)
        return
    render_page(chat_id, "\n".join(user_detail_lines(title, report, user)), back_keyboard("u:home"), message_id)


def notify_settings(chat_id, tg_id, admin=False, message_id=None):
    cfg = load_config()
    settings = cfg.setdefault("user_settings", {})
    item = settings.setdefault(str(tg_id), {"notify": True})
    state = "开启" if item.get("notify", True) else "关闭"
    text = f"提醒设置\n\n提醒：{state}\n规则：流量达到{cfg.get('notify_threshold', 90)}%、到期前{cfg.get('expire_warn_days', 3)}天提醒"
    back_to = "a:home" if admin else "u:home"
    keyboard = [[
        {"text": "关闭提醒" if item.get("notify", True) else "开启提醒", "callback_data": "a:toggle_notify" if admin else "u:toggle_notify"},
        {"text": "返回", "callback_data": back_to},
    ]]
    render_page(chat_id, text, keyboard, message_id)


def toggle_notify(chat_id, tg_id, admin=False, message_id=None):
    with cfg_lock():
        cfg = load_config()
        settings = cfg.setdefault("user_settings", {})
        item = settings.setdefault(str(tg_id), {"notify": True})
        item["notify"] = not bool(item.get("notify", True))
        save_config_unlocked(cfg)
    notify_settings(chat_id, tg_id, admin, message_id)


def binding_list(chat_id, tg_id, message_id=None):
    cfg = load_config()
    bindings = user_bindings(cfg, tg_id)
    if not bindings:
        render_page(chat_id, "当前没有绑定的用户。", back_keyboard("u:home"), message_id)
        return
    lines = ["绑定状态", "", "已绑定："]
    keyboard = []
    for idx, b in enumerate(bindings):
        label = f"{b.get('vps_name') or b.get('vps_id')} / {b.get('username')}"
        lines.append(f"- {label}")
        keyboard.append([{"text": f"解绑 {label}", "callback_data": f"u:ask_unbind:{idx}"}])
    keyboard.append([{"text": "返回", "callback_data": "u:home"}])
    render_page(chat_id, "\n".join(lines), keyboard, message_id)


def ask_unbind(chat_id, tg_id, idx, message_id=None):
    cfg = load_config()
    bindings = user_bindings(cfg, tg_id)
    if idx < 0 or idx >= len(bindings):
        binding_list(chat_id, tg_id, message_id)
        return
    b = bindings[idx]
    label = f"{b.get('vps_name') or b.get('vps_id')} / {b.get('username')}"
    render_page(chat_id, f"确认解除绑定：{label}？", [
        [{"text": "确认解除", "callback_data": f"u:do_unbind:{idx}"}, {"text": "取消", "callback_data": "u:bind"}],
    ], message_id)


def do_unbind(chat_id, tg_id, idx, message_id=None):
    with cfg_lock():
        cfg = load_config()
        real_indices = [
            i for i, b in enumerate(cfg.get("bindings") or [])
            if b.get("active") is not False and str(b.get("tg_user_id")) == str(tg_id)
        ]
        if idx < 0 or idx >= len(real_indices):
            save_config_unlocked(cfg)
            binding_list(chat_id, tg_id, message_id)
            return
        cfg["bindings"][real_indices[idx]]["active"] = False
        save_config_unlocked(cfg)
    render_unbound_user_state(chat_id, message_id, "绑定已解除。\n当前没有绑定。")


def quota_text(quota):
    quota = int(quota or 0)
    return "不限" if quota == 0 else f"{quota}GB"


def reset_day_text(value):
    try:
        value = int(value or 0)
    except Exception:
        value = 0
    if value == 0:
        return "不重置"
    if value == 32:
        return "月底"
    return f"{value}号"


def user_summary_line(user):
    total = fmt_bytes(user_total(user))
    quota = quota_text(user.get("quota_gb") or 0)
    expire = user.get("expire_at") or "0"
    exp = parse_date(expire)
    if exp is None:
        exp_text = "永久"
    else:
        days = (exp - today()).days
        exp_text = f"剩{days}天" if days > 0 else "已过期"
    return f"{user.get('username')}：{total}/{quota}，{exp_text}，{status_text(user)}"


def expire_display(value):
    return "永久" if not value or value == "0" else str(value)


def usage_current_line(user):
    return f"当前用量：{fmt_bytes(user_total(user))} / {quota_text(user.get('quota_gb') or 0)}"


def traffic_detail_lines(user):
    return [
        f"上传：{fmt_bytes(user.get('used_up_bytes') or 0)}",
        f"下载：{fmt_bytes(user.get('used_down_bytes') or 0)}",
        f"补正：{fmt_bytes(user.get('manual_added_bytes') or 0)}",
    ]


def usage_summary(user):
    return [usage_current_line(user)]


def used_detail_text(user):
    total = user_total(user)
    quota = int(user.get("quota_gb") or 0)
    if quota > 0:
        return f"{fmt_bytes(total)} / {quota}GB（{int(total * 100 / (quota * 1024 ** 3))}%）"
    return f"{fmt_bytes(total)} / 不限"


def expire_detail_text(user):
    expire = user.get("expire_at") or "0"
    exp = parse_date(expire)
    if exp is None:
        return "永久"
    days = (exp - today()).days
    return f"{expire}（剩余{days}天）" if days > 0 else f"{expire}（已过期）"


def user_detail_lines(title, report, user):
    return [
        title,
        f"状态：{status_text(user)}",
        f"已用：{used_detail_text(user)}",
        *traffic_detail_lines(user),
        f"重置日期：{reset_day_text(user.get('reset_day') or 0)}",
        f"到期：{expire_detail_text(user)}",
        f"更新时间：{report.get('updated_at_text') or '未知'}",
    ]


def report_user_title(report, vps_id, user):
    return f"{report.get('vps_name') or vps_id} / {user.get('username')}"


def add_calendar_months(base_date, months):
    def last_day(year, month):
        if month == 12:
            nxt = datetime.date(year + 1, 1, 1)
        else:
            nxt = datetime.date(year, month + 1, 1)
        return (nxt - datetime.timedelta(days=1)).day

    is_eom = base_date.day == last_day(base_date.year, base_date.month)
    total = base_date.year * 12 + (base_date.month - 1) + int(months)
    year = total // 12
    month = total % 12 + 1
    day = last_day(year, month) if is_eom else min(base_date.day, last_day(year, month))
    return datetime.date(year, month, day)


def renewal_preview(user, months):
    current = user.get("expire_at") or "0"
    current_date = parse_date(current)
    if current_date is None:
        return None
    base_date = today() if today() >= current_date else current_date
    return add_calendar_months(base_date, int(months)).isoformat()


def renew_months_text(months):
    months = int(months)
    if months == 1:
        return "1 个月"
    if months == 3:
        return "1 个季度"
    return f"{months} 个月"


def renew_confirm_text(report, vps_id, user, months):
    new_expire = renewal_preview(user, months)
    if new_expire is None:
        return None
    return "\n".join([
        f"当前到期：{expire_display(user.get('expire_at') or '0')}",
        f"续期后：{new_expire}",
        "",
        f"确认将 {report_user_title(report, vps_id, user)}",
        f"续期 {renew_months_text(months)}？",
    ])


def signed_gb_text(bytes_value):
    return f"{float(bytes_value) / (1024 ** 3):+.1f}GB"


def sorted_reports(reports):
    return sorted(
        (reports or {}).items(),
        key=lambda item: ((item[1].get("vps_name") or item[0]).casefold(), item[0]),
    )


def admin_machine_keyboard(reports):
    buttons = [
        {"text": (report.get("vps_name") or vps_id), "callback_data": f"a:vps:{vps_id}"}
        for vps_id, report in sorted_reports(reports)
    ]
    rows = []
    i = 0
    while i + 1 < len(buttons):
        rows.append([buttons[i], buttons[i + 1]])
        i += 2
    if i < len(buttons):
        rows.append([buttons[i]])
    rows.append([{"text": "刷新", "callback_data": "a:home"}, {"text": "提醒设置", "callback_data": "a:notify"}])
    return rows


def admin_overview(chat_id, message_id=None):
    cfg = load_config()
    reports = cfg.get("reports") or {}
    if not reports:
        render_page(chat_id, "当前没有节点上报数据。", [[{"text": "刷新", "callback_data": "a:home"}, {"text": "提醒设置", "callback_data": "a:notify"}]], message_id)
        return
    lines = []
    now = int(time.time())
    for vps_id, report in sorted_reports(reports):
        users = report.get("users") or []
        warn_count = 0
        expire_count = 0
        for user in users:
            quota = int(user.get("quota_gb") or 0)
            if quota > 0 and user_total(user) >= quota * 1024 ** 3 * int(cfg.get("notify_threshold", 90)) / 100:
                warn_count += 1
            exp = parse_date(user.get("expire_at") or "0")
            if exp is not None and 1 <= (exp - today()).days <= int(cfg.get("expire_warn_days", 3)):
                expire_count += 1
        age = now - int(report.get("received_at") or now)
        state_text = "在线 ✅" if age <= REPORT_ONLINE_SECONDS else "离线 ❌"
        parts = [f"{report.get('vps_name') or vps_id}：用户{len(users)}"]
        if warn_count > 0:
            parts.append(f"预警{warn_count}⚠️")
        if expire_count > 0:
            parts.append(f"到期{expire_count}⚠️")
        parts.append(state_text)
        lines.append("，".join(parts))
    render_page(chat_id, "\n".join(lines), admin_machine_keyboard(reports), message_id)


def admin_vps(chat_id, vps_id, message_id=None):
    cfg = load_config()
    report = (cfg.get("reports") or {}).get(vps_id)
    if not report:
        admin_overview(chat_id, message_id)
        return
    users = report.get("users") or []
    if len(users) == 1:
        render_page(
            chat_id,
            "\n".join(user_detail_lines(report_user_title(report, vps_id, users[0]), report, users[0])),
            admin_user_keyboard(vps_id, 0, users[0], "a:home"),
            message_id,
        )
        return
    lines = [report.get("vps_name") or vps_id]
    keyboard = []
    row = []
    for idx, user in enumerate(users):
        lines.append(user_summary_line(user))
        row.append({"text": str(user.get("username") or idx), "callback_data": f"a:user:{vps_id}:{idx}"})
        if len(row) == 2:
            keyboard.append(row)
            row = []
    if row:
        keyboard.append(row)
    keyboard.append([{"text": "返回", "callback_data": "a:home"}])
    render_page(chat_id, "\n".join(lines), keyboard, message_id)


def find_report_user_by_index(cfg, vps_id, idx):
    report = (cfg.get("reports") or {}).get(vps_id)
    if not report:
        return None, None
    users = report.get("users") or []
    if idx < 0 or idx >= len(users):
        return report, None
    return report, users[idx]


def admin_user_back_data(report, vps_id):
    return "a:home" if len(report.get("users") or []) == 1 else f"a:vps:{vps_id}"


def admin_user_keyboard(vps_id, idx, user, back_data=None):
    toggle_text = "停用" if user.get("enabled") is True else "启用"
    back_data = back_data or f"a:vps:{vps_id}"
    return [
        [{"text": toggle_text, "callback_data": f"a:toggle:{vps_id}:{idx}"}, {"text": "续期", "callback_data": f"a:renew_menu:{vps_id}:{idx}"}],
        [{"text": "套餐", "callback_data": f"a:quota_menu:{vps_id}:{idx}"}, {"text": "更多", "callback_data": f"a:more:{vps_id}:{idx}"}],
        [{"text": "返回", "callback_data": back_data}],
    ]


def admin_user_detail(chat_id, vps_id, idx, message_id=None):
    cfg = load_config()
    report, user = find_report_user_by_index(cfg, vps_id, idx)
    if not report or not user:
        admin_vps(chat_id, vps_id, message_id)
        return
    render_page(
        chat_id,
        "\n".join(user_detail_lines(report_user_title(report, vps_id, user), report, user)),
        admin_user_keyboard(vps_id, idx, user, admin_user_back_data(report, vps_id)),
        message_id,
    )


def admin_quota_menu(chat_id, vps_id, idx, message_id=None):
    cfg = load_config()
    report, user = find_report_user_by_index(cfg, vps_id, idx)
    if not report or not user:
        admin_vps(chat_id, vps_id, message_id)
        return
    text = f"套餐设置\n\n{report.get('vps_name') or vps_id} / {user.get('username')}\n当前套餐：{quota_text(user.get('quota_gb') or 0)}"
    keyboard = [
        [{"text": "50G", "callback_data": f"a:quota:{vps_id}:{idx}:50"}, {"text": "100G", "callback_data": f"a:quota:{vps_id}:{idx}:100"}, {"text": "250G", "callback_data": f"a:quota:{vps_id}:{idx}:250"}],
        [{"text": "自定义", "callback_data": f"a:quota_custom:{vps_id}:{idx}"}, {"text": "返回", "callback_data": f"a:user:{vps_id}:{idx}"}],
    ]
    render_page(chat_id, text, keyboard, message_id)


def admin_renew_menu(chat_id, vps_id, idx, message_id=None):
    cfg = load_config()
    report, user = find_report_user_by_index(cfg, vps_id, idx)
    if not report or not user:
        admin_vps(chat_id, vps_id, message_id)
        return
    text = f"一键续期\n\n{report.get('vps_name') or vps_id} / {user.get('username')}\n当前到期：{user.get('expire_at') or '0'}"
    keyboard = [
        [{"text": "1个月", "callback_data": f"a:renew:{vps_id}:{idx}:1"}, {"text": "1季度", "callback_data": f"a:renew:{vps_id}:{idx}:3"}],
        [{"text": "自定义", "callback_data": f"a:renew_custom:{vps_id}:{idx}"}, {"text": "返回", "callback_data": f"a:user:{vps_id}:{idx}"}],
    ]
    render_page(chat_id, text, keyboard, message_id)


def admin_more_menu(chat_id, vps_id, idx, message_id=None):
    cfg = load_config()
    report, user = find_report_user_by_index(cfg, vps_id, idx)
    if not report or not user:
        admin_vps(chat_id, vps_id, message_id)
        return
    text = f"更多操作\n\n{report.get('vps_name') or vps_id} / {user.get('username')}"
    keyboard = [
        [{"text": "重置流量", "callback_data": f"a:reset:{vps_id}:{idx}"}, {"text": "补正流量", "callback_data": f"a:add_usage:{vps_id}:{idx}"}],
        [{"text": "到期设置", "callback_data": f"a:expire_set:{vps_id}:{idx}"}, {"text": "重置日期", "callback_data": f"a:reset_day_set:{vps_id}:{idx}"}],
        [{"text": "返回", "callback_data": f"a:user:{vps_id}:{idx}"}],
    ]
    render_page(chat_id, text, keyboard, message_id)


def parse_quota_input(text):
    raw = (text or "").strip()
    if not re.fullmatch(r"\d+", raw):
        return None
    return int(raw)


def parse_months_input(text):
    raw = (text or "").strip()
    if not re.fullmatch(r"\d+", raw):
        return None
    months = int(raw)
    return months if months >= 1 else None


def parse_traffic_input(text):
    raw = (text or "").strip().replace(" ", "")
    m = re.fullmatch(r"([+-]?\d+(?:\.\d)?)", raw)
    if not m:
        return None
    value = float(m.group(1))
    return int(value * (1024 ** 3))


def parse_expire_input(text):
    raw = (text or "").strip()
    if raw == "0":
        return "0"
    try:
        return datetime.date.fromisoformat(raw).isoformat()
    except ValueError:
        return None


def parse_reset_day_input(text):
    raw = (text or "").strip()
    if raw in {"0", "32"}:
        return int(raw)
    if re.fullmatch(r"\d+", raw):
        value = int(raw)
        if 1 <= value <= 29:
            return value
    return None


def create_admin_confirmation(chat_id, tg_id, text, action, vps_id, username, params, back_data, message_id=None):
    token = secrets.token_urlsafe(6)
    with cfg_lock():
        cfg = load_config()
        pending = cfg.setdefault("pending_admin_actions", {})
        pending[token] = {
            "tg_user_id": str(tg_id),
            "chat_id": chat_id,
            "action": action,
            "vps_id": vps_id,
            "username": username,
            "params": params or {},
            "back_data": back_data,
            "expires_at": int(time.time()) + 300,
        }
        save_config_unlocked(cfg)
    keyboard = [[
        {"text": "确认执行", "callback_data": f"a:confirm:{token}"},
        {"text": "取消", "callback_data": back_data},
    ]]
    render_page(chat_id, text, keyboard, message_id)


def create_task_from_confirmation(chat_id, tg_id, token, message_id=None):
    with cfg_lock():
        cfg = load_config()
        pending = cfg.setdefault("pending_admin_actions", {})
        action = pending.pop(token, None)
        if not action or str(action.get("tg_user_id")) != str(tg_id) or int(action.get("expires_at") or 0) < int(time.time()):
            save_config_unlocked(cfg)
            render_page(chat_id, "确认已失效，请重新操作。", back_keyboard("a:home"), message_id)
            return
        task_id = secrets.token_urlsafe(8)
        tasks = cfg.setdefault("tasks", {})
        tasks[task_id] = {
            "id": task_id,
            "status": "pending",
            "created_at": int(time.time()),
            "created_by": str(tg_id),
            "created_chat_id": chat_id,
            "action": action.get("action"),
            "vps_id": action.get("vps_id"),
            "username": action.get("username"),
            "params": action.get("params") or {},
            "attempts": 0,
        }
        save_config_unlocked(cfg)
    render_page(chat_id, "任务已提交，等待节点执行，通常 10 秒内完成。", None, message_id)


def start_waiting_input(chat_id, tg_id, action, vps_id, idx, username, prompt, message_id=None):
    with cfg_lock():
        cfg = load_config()
        waiting = cfg.setdefault("waiting_inputs", {})
        waiting[str(tg_id)] = {
            "action": action,
            "vps_id": vps_id,
            "idx": idx,
            "username": username,
            "expires_at": int(time.time()) + 300,
        }
        save_config_unlocked(cfg)
    render_page(chat_id, prompt, back_keyboard(f"a:user:{vps_id}:{idx}"), message_id)


def handle_waiting_input(chat_id, tg_id, text):
    cfg = load_config()
    waiting = (cfg.get("waiting_inputs") or {}).get(str(tg_id))
    if not waiting or not is_admin(cfg, tg_id):
        return False
    if int(waiting.get("expires_at") or 0) < int(time.time()):
        clear_waiting_input(tg_id)
        send_message(chat_id, "输入已超时，请重新操作。")
        return True
    action = waiting.get("action")
    vps_id = waiting.get("vps_id")
    idx = int(waiting.get("idx") or 0)
    username = waiting.get("username")
    back_data = f"a:user:{vps_id}:{idx}"
    report, user = find_report_user_by_index(cfg, vps_id, idx)
    title = f"{vps_id} / {username}" if not report or not user else report_user_title(report, vps_id, user)
    if action == "set_quota":
        quota = parse_quota_input(text)
        if quota is None:
            send_message(chat_id, "输入无效，请输入数字，例如 300；输入 0 表示不限。")
            return True
        clear_waiting_input(tg_id)
        create_admin_confirmation(chat_id, tg_id, "\n".join([
            f"确认将 {title}",
            f"套餐改为 {quota_text(quota)}？",
        ]), "set_quota", vps_id, username, {"quota_gb": quota}, back_data)
        return True
    if action == "renew":
        months = parse_months_input(text)
        if months is None:
            send_message(chat_id, "输入无效，请输入需要续期的月数，例如 2。")
            return True
        if not user:
            send_message(chat_id, "用户状态已变化，请重新操作。")
            clear_waiting_input(tg_id)
            return True
        confirm_text = renew_confirm_text(report, vps_id, user, months)
        if confirm_text is None:
            send_message(chat_id, "永久用户无需续期。")
            clear_waiting_input(tg_id)
            return True
        clear_waiting_input(tg_id)
        create_admin_confirmation(chat_id, tg_id, confirm_text, "renew", vps_id, username, {"months": months}, back_data)
        return True
    if action == "add_usage":
        bytes_value = parse_traffic_input(text)
        if bytes_value is None:
            send_message(chat_id, "输入无效，请输入数字，单位G，最多1位小数。例如 +10.1 或 -5.5。")
            return True
        clear_waiting_input(tg_id)
        lines = []
        if user:
            lines += usage_summary(user) + [""]
        lines += [
            f"补正变化：{signed_gb_text(bytes_value)}",
            "",
            f"确认给 {title}",
            "补正流量？",
        ]
        create_admin_confirmation(chat_id, tg_id, "\n".join(lines), "add_usage", vps_id, username, {"bytes": bytes_value}, back_data)
        return True
    if action == "set_expire":
        expire_at = parse_expire_input(text)
        if expire_at is None:
            send_message(chat_id, "输入无效，请输入 YYYY-MM-DD，或输入 0 表示永久。")
            return True
        clear_waiting_input(tg_id)
        current = expire_display(user.get("expire_at") if user else "")
        new_value = expire_display(expire_at)
        create_admin_confirmation(chat_id, tg_id, "\n".join([
            f"当前到期：{current}",
            f"修改后：{new_value}",
            "",
            f"确认修改 {title}",
            "的到期时间？",
        ]), "set_expire", vps_id, username, {"expire_at": expire_at}, back_data)
        return True
    if action == "set_reset_day":
        reset_day = parse_reset_day_input(text)
        if reset_day is None:
            send_message(chat_id, "输入无效，请输入 0、1-29 或 32。")
            return True
        clear_waiting_input(tg_id)
        current = reset_day_text(user.get("reset_day") if user else 0)
        new_value = reset_day_text(reset_day)
        create_admin_confirmation(chat_id, tg_id, "\n".join([
            f"当前重置日期：{current}",
            f"修改后：{new_value}",
            "",
            f"确认修改 {title}",
            "的重置日期？",
        ]), "set_reset_day", vps_id, username, {"reset_day": reset_day}, back_data)
        return True
    clear_waiting_input(tg_id)
    return False


def handle_message(msg):
    text = msg.get("text") or ""
    chat = msg.get("chat") or {}
    user = msg.get("from") or {}
    chat_id = chat.get("id")
    tg_id = user.get("id")
    if not chat_id or not tg_id:
        return
    if handle_waiting_input(chat_id, tg_id, text):
        return
    if text.startswith("/start"):
        parts = text.split(maxsplit=1)
        if len(parts) == 2 and parts[1].startswith("bind_"):
            bind_token(chat_id, tg_id, parts[1][5:])
        else:
            send_home(chat_id, tg_id)
    else:
        send_home(chat_id, tg_id)


def handle_callback(cb):
    data = cb.get("data") or ""
    msg = cb.get("message") or {}
    chat_id = (msg.get("chat") or {}).get("id")
    message_id = msg.get("message_id")
    user = cb.get("from") or {}
    tg_id = user.get("id")
    if not chat_id or not tg_id:
        return
    if cb.get("id"):
        answer_callback(cb.get("id"))
    cfg = load_config()
    admin = is_admin(cfg, tg_id)
    if data == "u:home":
        clear_waiting_input(tg_id)
        send_home(chat_id, tg_id, message_id)
    elif data == "u:notify":
        clear_waiting_input(tg_id)
        notify_settings(chat_id, tg_id, message_id=message_id)
    elif data == "u:toggle_notify":
        clear_waiting_input(tg_id)
        toggle_notify(chat_id, tg_id, message_id=message_id)
    elif data == "u:bind":
        clear_waiting_input(tg_id)
        binding_list(chat_id, tg_id, message_id)
    elif data.startswith("u:detail:"):
        clear_waiting_input(tg_id)
        user_detail(chat_id, tg_id, int(data.rsplit(":", 1)[1]), message_id)
    elif data.startswith("u:ask_unbind:"):
        clear_waiting_input(tg_id)
        ask_unbind(chat_id, tg_id, int(data.rsplit(":", 1)[1]), message_id)
    elif data.startswith("u:do_unbind:"):
        clear_waiting_input(tg_id)
        do_unbind(chat_id, tg_id, int(data.rsplit(":", 1)[1]), message_id)
    elif admin and data == "a:home":
        clear_waiting_input(tg_id)
        send_home(chat_id, tg_id, message_id)
    elif admin and data == "a:notify":
        clear_waiting_input(tg_id)
        notify_settings(chat_id, tg_id, admin=True, message_id=message_id)
    elif admin and data == "a:toggle_notify":
        clear_waiting_input(tg_id)
        toggle_notify(chat_id, tg_id, admin=True, message_id=message_id)
    elif admin and data.startswith("a:vps:"):
        clear_waiting_input(tg_id)
        admin_vps(chat_id, data.split(":", 2)[2], message_id)
    elif admin and data.startswith("a:user:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        admin_user_detail(chat_id, vps_id, int(idx), message_id)
    elif admin and data.startswith("a:toggle:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            target = not bool(user.get("enabled") is True)
            word = "启用" if target else "停用"
            create_admin_confirmation(chat_id, tg_id, f"确认{word}用户 {report.get('vps_name') or vps_id} / {user.get('username')}？", "set_enabled", vps_id, user.get("username"), {"enabled": target}, f"a:user:{vps_id}:{idx}", message_id)
    elif admin and data.startswith("a:renew_menu:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        admin_renew_menu(chat_id, vps_id, int(idx), message_id)
    elif admin and data.startswith("a:renew:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx, months = data.split(":", 4)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            confirm_text = renew_confirm_text(report, vps_id, user, int(months))
            if confirm_text is None:
                render_page(chat_id, "永久用户无需续期。", back_keyboard(f"a:user:{vps_id}:{idx}"), message_id)
            else:
                create_admin_confirmation(chat_id, tg_id, confirm_text, "renew", vps_id, user.get("username"), {"months": int(months)}, f"a:user:{vps_id}:{idx}", message_id)
    elif admin and data.startswith("a:renew_custom:"):
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            start_waiting_input(chat_id, tg_id, "renew", vps_id, idx, user.get("username"), "请输入需要续期的月数，例如 2。", message_id)
    elif admin and data.startswith("a:quota_menu:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        admin_quota_menu(chat_id, vps_id, int(idx), message_id)
    elif admin and data.startswith("a:quota:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx, quota = data.split(":", 4)
        idx = int(idx)
        quota = int(quota)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            create_admin_confirmation(chat_id, tg_id, "\n".join([
                f"确认将 {report_user_title(report, vps_id, user)}",
                f"套餐改为 {quota_text(quota)}？",
            ]), "set_quota", vps_id, user.get("username"), {"quota_gb": quota}, f"a:user:{vps_id}:{idx}", message_id)
    elif admin and data.startswith("a:quota_custom:"):
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            start_waiting_input(chat_id, tg_id, "set_quota", vps_id, idx, user.get("username"), "\n".join([
                "折算成单向流量填入。",
                "双向800G流量填写400。",
                "单向500G流量填写500。",
                "",
                "请输入新的套餐流量，0 表示不限。",
            ]), message_id)
    elif admin and data.startswith("a:more:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        admin_more_menu(chat_id, vps_id, int(idx), message_id)
    elif admin and data.startswith("a:reset:"):
        clear_waiting_input(tg_id)
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            create_admin_confirmation(chat_id, tg_id, "\n".join(
                usage_summary(user) + [
                    "",
                    f"确认重置 {report_user_title(report, vps_id, user)}",
                    "的流量？",
                ]
            ), "reset_usage", vps_id, user.get("username"), {}, f"a:user:{vps_id}:{idx}", message_id)
    elif admin and data.startswith("a:add_usage:"):
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            start_waiting_input(chat_id, tg_id, "add_usage", vps_id, idx, user.get("username"), "\n".join(
                usage_summary(user) + [
                    "",
                    "单位G，精确到小数点后1位",
                    "例如 +10.1 或 -5.5",
                    "",
                    "请输入补正流量：",
                ]
            ), message_id)
    elif admin and data.startswith("a:expire_set:"):
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            start_waiting_input(chat_id, tg_id, "set_expire", vps_id, idx, user.get("username"), "\n".join([
                f"当前到期：{expire_display(user.get('expire_at') or '0')}",
                "",
                "请输入新的到期日期：",
                "YYYY-MM-DD，输入 0 表示永久。",
            ]), message_id)
    elif admin and data.startswith("a:reset_day_set:"):
        _, _, vps_id, idx = data.split(":", 3)
        idx = int(idx)
        cfg = load_config()
        report, user = find_report_user_by_index(cfg, vps_id, idx)
        if user:
            start_waiting_input(chat_id, tg_id, "set_reset_day", vps_id, idx, user.get("username"), "\n".join([
                f"当前重置日期：{reset_day_text(user.get('reset_day') or 0)}",
                "0. 不重置",
                "1-29. 指定日期",
                "32. 月底",
                "请输入重置日期：",
            ]), message_id)
    elif admin and data.startswith("a:confirm:"):
        clear_waiting_input(tg_id)
        create_task_from_confirmation(chat_id, tg_id, data.rsplit(":", 1)[1], message_id)
    else:
        clear_waiting_input(tg_id)
        send_home(chat_id, tg_id, message_id)


def process_updates():
    offset = None
    while True:
        payload = {"timeout": 25}
        if offset is not None:
            payload["offset"] = offset
        resp = bot_api("getUpdates", payload)
        for upd in resp.get("result") or []:
            offset = max(offset or 0, int(upd.get("update_id", 0)) + 1)
            if "message" in upd:
                handle_message(upd["message"])
            elif "callback_query" in upd:
                handle_callback(upd["callback_query"])
        time.sleep(1)


def authorized(handler):
    secret = load_config().get("access_secret") or ""
    got = handler.headers.get("X-SB-TG-Secret", "")
    return secret and got == secret


def read_json(handler):
    length = int(handler.headers.get("Content-Length") or 0)
    body = handler.rfile.read(length) if length > 0 else b"{}"
    return json.loads(body.decode("utf-8") or "{}")


def write_json(handler, code, payload):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def evaluate_reminders(cfg, report):
    threshold = int(cfg.get("notify_threshold") or 90)
    expire_days = int(cfg.get("expire_warn_days") or 3)
    notify_state = cfg.setdefault("notify_state", {})
    settings = cfg.setdefault("user_settings", {})
    changed = False
    users_by_name = {u.get("username"): u for u in report.get("users") or []}
    for b in cfg.get("bindings") or []:
        if b.get("active") is False or b.get("vps_id") != report.get("vps_id"):
            continue
        tg_id = str(b.get("tg_user_id"))
        if not settings.get(tg_id, {"notify": True}).get("notify", True):
            continue
        user = users_by_name.get(b.get("username"))
        if not user:
            continue
        if user.get("disabled_reason") == "manual":
            continue
        title = f"{report.get('vps_name')} / {b.get('username')}"
        total = user_total(user)
        quota = int(user.get("quota_gb") or 0)
        if quota > 0:
            ratio = int(total * 100 / (quota * 1024 ** 3))
            if ratio >= threshold:
                period = user.get("last_reset_period") or today().strftime("%Y-%m")
                key = f"{tg_id}:{report.get('vps_id')}:{b.get('username')}:traffic:{threshold}:{period}"
                if not notify_state.get(key):
                    send_message(b.get("chat_id"), f"{title}\n流量已使用 {ratio}%，请留意。")
                    notify_state[key] = int(time.time())
                    changed = True
        exp = parse_date(user.get("expire_at") or "0")
        if exp is not None:
            days = (exp - today()).days
            if 1 <= days <= expire_days:
                key = f"{tg_id}:{report.get('vps_id')}:{b.get('username')}:expire:{exp.isoformat()}:{days}"
                if not notify_state.get(key):
                    send_message(b.get("chat_id"), f"{title}\n距离到期还有 {days} 天。")
                    notify_state[key] = int(time.time())
                    changed = True
            elif days <= 0 and user.get("disabled_reason") == "expired":
                key = f"{tg_id}:{report.get('vps_id')}:{b.get('username')}:expired:{exp.isoformat()}"
                if not notify_state.get(key):
                    send_message(b.get("chat_id"), f"{title}\n用户已到期。")
                    notify_state[key] = int(time.time())
                    changed = True
    return changed


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        if not authorized(self):
            write_json(self, 403, {"ok": False, "error": "forbidden"})
            return
        try:
            payload = read_json(self)
        except Exception:
            write_json(self, 400, {"ok": False, "error": "bad_json"})
            return

        if self.path == "/api/report":
            with cfg_lock():
                cfg = load_config()
                reports = cfg.setdefault("reports", {})
                payload["received_at"] = int(time.time())
                payload["received_at_text"] = (datetime.datetime.utcnow() + datetime.timedelta(hours=8)).strftime("%Y-%m-%d %H:%M:%S")
                payload["updated_at_text"] = payload.get("data_updated_at_text") or ""
                reports[payload.get("vps_id") or "unknown"] = payload
                changed = evaluate_reminders(cfg, payload)
                if changed:
                    save_config_unlocked(cfg)
                else:
                    save_config_unlocked(cfg)
            write_json(self, 200, {"ok": True})
            return

        if self.path == "/api/tasks/poll":
            vps_id = payload.get("vps_id") or ""
            if not vps_id:
                write_json(self, 400, {"ok": False, "error": "vps_id_missing"})
                return
            now = int(time.time())
            available = []
            expired_notifications = []
            with cfg_lock():
                cfg = load_config()
                tasks = cfg.setdefault("tasks", {})
                for task_id in list(tasks.keys()):
                    task = tasks[task_id]
                    if task.get("status") in {"success", "failed"} and now - int(task.get("completed_at") or now) > 86400:
                        tasks.pop(task_id, None)
                for task_id, task in tasks.items():
                    if task.get("vps_id") != vps_id:
                        continue
                    status = task.get("status")
                    picked_at = int(task.get("picked_at") or 0)
                    attempts = int(task.get("attempts") or 0)
                    if status == "running" and picked_at and now - picked_at > 120 and attempts >= 3:
                        message = "节点超过重试次数仍未回传结果，任务已停止重试。"
                        task["status"] = "failed"
                        task["message"] = message
                        task["completed_at"] = now
                        expired_notifications.append((
                            task.get("created_chat_id"),
                            f"{vps_id} / {task.get('username') or ''}".strip(" /"),
                            message,
                        ))
                        continue
                    runnable = status == "pending" or (status == "running" and now - picked_at > 120 and attempts < 3)
                    if not runnable:
                        continue
                    task["status"] = "running"
                    task["picked_at"] = now
                    task["attempts"] = attempts + 1
                    available.append({
                        "id": task_id,
                        "action": task.get("action"),
                        "username": task.get("username"),
                        "params": task.get("params") or {},
                    })
                save_config_unlocked(cfg)
            for chat_id, title, message in expired_notifications:
                if chat_id:
                    send_message(chat_id, f"执行失败：{title}\n{message}")
            write_json(self, 200, {"ok": True, "tasks": available})
            return

        if self.path == "/api/tasks/result":
            task_id = payload.get("task_id") or ""
            vps_id = payload.get("vps_id") or ""
            ok_value = bool(payload.get("ok"))
            message = payload.get("message") or ("执行成功" if ok_value else "执行失败")
            with cfg_lock():
                cfg = load_config()
                task = (cfg.setdefault("tasks", {})).get(task_id)
                if not task or task.get("vps_id") != vps_id:
                    write_json(self, 404, {"ok": False, "error": "task_not_found"})
                    return
                task["status"] = "success" if ok_value else "failed"
                task["message"] = message
                task["completed_at"] = int(time.time())
                chat_id = task.get("created_chat_id")
                tg_id = task.get("created_by")
                username = task.get("username") or ""
                save_config_unlocked(cfg)
            if chat_id:
                title = f"{vps_id} / {username}".strip(" /")
                prefix = "执行成功" if ok_value else "执行失败"
                send_message(chat_id, f"{prefix}：{title}\n{message}")
                if ok_value and tg_id:
                    send_home(chat_id, tg_id)
            write_json(self, 200, {"ok": True})
            return

        if self.path == "/api/bind-token":
            with cfg_lock():
                cfg = load_config()
                token = secrets.token_urlsafe(8)
                pending = cfg.setdefault("pending_bind_tokens", {})
                pending[token] = {
                    "vps_id": payload.get("vps_id"),
                    "vps_name": payload.get("vps_name"),
                    "username": payload.get("username"),
                    "expires_at": int(time.time()) + 600,
                }
                username = get_bot_username(cfg)
                save_config_unlocked(cfg)
            if not username:
                write_json(self, 500, {"ok": False, "error": "bot_username_missing"})
            else:
                write_json(self, 200, {"ok": True, "link": f"https://t.me/{username}?start=bind_{token}"})
            return

        if self.path == "/api/test":
            cfg = load_config()
            errors = []
            admin_ids = cfg.get("admin_chat_ids") or []
            if not admin_ids:
                errors.append("管理员 TG ID 未配置")
            for chat_id in admin_ids:
                resp = send_message(chat_id, f"通知测试成功：{payload.get('vps_name') or payload.get('vps_id') or '主控节点'}")
                if not resp.get("ok"):
                    errors.append(resp.get("description") or "sendMessage failed")
            write_json(self, 200, {"ok": len(errors) == 0, "errors": errors})
            return

        write_json(self, 404, {"ok": False, "error": "not_found"})


def run_http():
    cfg = load_config()
    host = cfg.get("listen_host") or "0.0.0.0"
    port = int(cfg.get("listen_port") or 25888)
    server = http.server.ThreadingHTTPServer((host, port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    threading.Thread(target=process_updates, daemon=True).start()
    run_http()
PY
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

# >>>>>>>>> END MODULE: 63_telegram_bot.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 64_warp.sh <<<<<<<<<<<
# ============================================================
# 模块: 64_warp.sh
# 职责: 借用外部 WireProxy SOCKS，为 sing-box 管理 WARP 网站分流
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 30_route.sh, 50_v2ray_api.sh
# ============================================================

WARP_PROXY_FILE="/etc/wireguard/proxy.conf"
WARP_RULE_BASE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
WARP_RULE_LOOKUP_URL="https://github.com/SagerNet/sing-geosite/tree/rule-set"
WARP_SCRIPT_DOC_URL="https://gitlab.com/fscarmen/warp"
WARP_SCRIPT_RAW_URL="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"

warp_hr() {
  echo -e "${B}--------------------------------------------------------${NC}"
}

warp_meta_json() {
  meta_load | jq -c '
    (.warp // {mode:"off", rules:[]})
    | .mode = (if (.mode // "off") == "rules" then "rules" else "off" end)
    | .rules = [
        (.rules // [])[]?
        | select((.file // "") != "")
        | .tag = ("relay-" + ((.file // "" | sub("\\.srs$"; "")) | gsub("[^A-Za-z0-9_-]"; "-")))
      ]
  '
}

warp_meta_rules_json() {
  warp_meta_json | jq -c '[.rules[]? | select((.tag // "") != "" and (.file // "") != "")] | unique_by(.tag)'
}

warp_meta_save_obj() {
  local warp_json="$1" meta_json
  meta_json="$(meta_load)"
  meta_json="$(echo "$meta_json" | jq --argjson w "$warp_json" '.warp = $w')" || return 1
  meta_save "$meta_json"
}

warp_meta_save_rules_obj() {
  local warp_json="$1"
  warp_json="$(echo "$warp_json" | jq '
    .mode = (if ((.rules // []) | length) > 0 then "rules" else "off" end)
    | .rules = (.rules // [])
  ')" || return 1
  warp_meta_save_obj "$warp_json"
}

warp_meta_normalize_obj() {
  local warp_json="$1"
  echo "$warp_json" | jq -c '
    .mode = (if ((.rules // []) | length) > 0 then "rules" else "off" end)
    | .rules = (.rules // [])
  '
}

warp_meta_replace_in_meta_json() {
  local meta_json="$1" warp_json="$2" normalized
  normalized="$(warp_meta_normalize_obj "$warp_json")" || return 1
  echo "$meta_json" | jq --argjson w "$normalized" '.warp = $w'
}

warp_rule_tag_for_file() {
  local file="$1" base tag
  base="${file%.srs}"
  tag="${base//[^A-Za-z0-9_-]/-}"
  echo "relay-${tag}"
}

warp_rule_url_for_file() {
  echo "${WARP_RULE_BASE_URL}/$1"
}

warp_rule_add_meta_to_json() {
  local warp_json="$1" name="$2" file="$3" tag url
  tag="$(warp_rule_tag_for_file "$file")"
  url="$(warp_rule_url_for_file "$file")"
  echo "$warp_json" | jq --arg name "$name" --arg file "$file" --arg tag "$tag" --arg url "$url" '
    .rules = ((.rules // []) + [{name:$name,file:$file,tag:$tag,url:$url}])
    | .rules |= unique_by(.tag)
  '
}

warp_rule_remove_meta_by_tags_json_from() {
  local warp_json="$1" tags_json="$2"
  echo "$warp_json" | jq --argjson tags "$tags_json" '
    .rules = [
      (.rules // [])[]
      | (.tag // "") as $tag
      | select(($tags | index($tag)) == null)
    ]
  '
}

warp_rule_remove_meta_by_files_json_from() {
  local warp_json="$1" files_json="$2"
  echo "$warp_json" | jq --argjson files "$files_json" '
    .rules = [
      (.rules // [])[]
      | (.file // "") as $file
      | select(($files | index($file)) == null)
    ]
  '
}

warp_normalize_rule_file() {
  local raw="${1:-}" value
  value="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$value" ] || return 1
  if [[ "$value" == *"://"* ]]; then
    err "请输入 rule-set 文件名，不要输入完整 URL。"
    return 1
  fi
  [[ "$value" == geosite-* ]] || value="geosite-${value}"
  [[ "$value" == *.srs ]] || value="${value}.srs"
  [[ "$value" =~ ^geosite-[A-Za-z0-9._@!+-]+\.srs$ ]] || {
    err "规则名格式无效：$value"
    return 1
  }
  echo "$value"
}

warp_validate_rule_file() {
  local file="$1" url
  url="$(warp_rule_url_for_file "$file")"
  curl_maybe_warp -fsIL --connect-timeout 10 --max-time 20 "$url" >/dev/null 2>&1
}

warp_rule_add_meta() {
  local name="$1" file="$2" warp_json
  warp_json="$(warp_rule_add_meta_to_json "$(warp_meta_json)" "$name" "$file")" || return 1
  warp_meta_save_rules_obj "$warp_json"
}

warp_rule_remove_meta_by_tags_json() {
  local tags_json="$1" warp_json
  warp_json="$(warp_rule_remove_meta_by_tags_json_from "$(warp_meta_json)" "$tags_json")" || return 1
  warp_meta_save_rules_obj "$warp_json"
}

warp_rule_remove_meta_by_files_json() {
  local files_json="$1" warp_json
  warp_json="$(warp_rule_remove_meta_by_files_json_from "$(warp_meta_json)" "$files_json")" || return 1
  warp_meta_save_rules_obj "$warp_json"
}

warp_rule_clear_meta() {
  warp_meta_save_obj '{"mode":"off","rules":[]}'
}

warp_init_env() {
  [ "${_WARP_ENV_READY:-0}" = "1" ] && return 0
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 运行此脚本。"
    return 1
  fi
  has_cmd jq || { err "未找到 jq，无法管理 WARP 分流。"; return 1; }
  has_cmd curl || { err "未找到 curl，无法校验规则文件。"; return 1; }
  _WARP_ENV_READY=1
}

warp_require_singbox() {
  has_cmd sing-box || {
    err "未找到 sing-box，无法写入 WARP 分流策略。"
    warn "请先在主菜单执行 1. 安装/更新 sing-box。"
    pause
    return 1
  }
  config_ensure_exists
  ensure_manager_file_permissions
}

warp_proxy_conf_bind_address() {
  [ -s "$WARP_PROXY_FILE" ] || return 1
  awk -F= '
    /^[[:space:]]*BindAddress[[:space:]]*=/ {
      value=$2
      gsub(/[[:space:]]/, "", value)
      if (value != "") print value
      exit
    }
  ' "$WARP_PROXY_FILE"
}

warp_ss_line_for_addr() {
  local addr="$1"
  [ -n "$addr" ] || return 1
  has_cmd ss || return 1
  ss -nltp 2>/dev/null | awk -v a="$addr" '$4 == a && $0 ~ /wireproxy/ {print; found=1; exit} END {exit !found}'
}

warp_wireproxy_socks_addr() {
  local addr
  addr="$(warp_proxy_conf_bind_address 2>/dev/null || true)"
  if [ -n "$addr" ] && warp_ss_line_for_addr "$addr" >/dev/null 2>&1; then
    echo "$addr"
    return 0
  fi
  has_cmd ss || return 1
  ss -nltp 2>/dev/null | awk '/wireproxy/ {print $4; found=1; exit} END {exit !found}'
}

warp_wireproxy_ready() {
  warp_wireproxy_socks_addr >/dev/null 2>&1
}

warp_wireproxy_port() {
  local addr port
  addr="$(warp_wireproxy_socks_addr)" || return 1
  port="${addr##*:}"
  port="${port%]}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  echo "$port"
}

warp_wireproxy_display() {
  local addr
  addr="$(warp_wireproxy_socks_addr 2>/dev/null || true)"
  [ -n "$addr" ] && echo "$addr" || echo "无"
}

warp_preset_rule() {
  case "$1" in
    1) echo "AI 服务|geosite-category-ai-!cn.srs" ;;
    2) echo "Google|geosite-google.srs" ;;
    3) echo "Netflix|geosite-netflix.srs" ;;
    4) echo "Disney+|geosite-disney.srs" ;;
    5) echo "YouTube|geosite-youtube.srs" ;;
    6) echo "TikTok|geosite-tiktok.srs" ;;
    *) return 1 ;;
  esac
}

warp_rules_count() {
  warp_meta_rules_json | jq 'length'
}

warp_rules_print_summary() {
  local rules_json count
  rules_json="$(warp_meta_rules_json)"
  count="$(echo "$rules_json" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    echo "当前分流至 WARP 的服务：无"
    return 0
  fi
  echo "当前分流至 WARP 的服务："
  echo "$rules_json" | jq -r '.[] | "  - \(.name)：\(.file)"'
}

warp_rules_print_numbered() {
  local idx=0 file name display
  while IFS=$'\x01' read -r file name; do
    [ -z "$file" ] && continue
    idx=$((idx+1))
    display="$(split_rule_preset_display_name "$file")"
    [ -n "$display" ] || display="$name"
    [ -n "$display" ] || display="$file"
    printf '  %s. %s：%s\n' "$idx" "$display" "$file"
  done < <(warp_meta_rules_json | jq -r '.[] | (.file // "") + "" + (.name // "")')
}

warp_config_project_json() {
  local json="$1" rules_json="$2" ready="$3" port="$4"
  echo "$json" | jq \
    --argjson rules "$rules_json" \
    --argjson ready "$ready" \
    --argjson port "$port" '
    def rule_set_array:
      ((.rule_set // []) | if type == "array" then . else [.] end);
    ($rules | map(.tag // "") | unique) as $managed_tags
    |
    .route = (.route // {"rules":[],"final":"reject"})
    | .route.rules = (.route.rules // [])
    | .route.rules = (
        .route.rules
        | map(select(
            ((.outbound // "") != "warp")
            and ((rule_set_array | any(. as $tag | ($tag | startswith("warp-geosite-")) or (($managed_tags | index($tag)) != null))) | not)
          ))
      )
    | .route.rule_set = (
        ((.route.rule_set // [])
          | map(
              (.tag // "") as $tag
              | select((($tag | startswith("warp-geosite-")) or (($managed_tags | index($tag)) != null)) | not)
            )
        )
        + (if $ready then
            ($rules | map({type:"remote", tag:.tag, format:"binary", url:.url, http_client:{version:2,detour:"direct"}}))
          else [] end)
      )
    | .outbounds = (
        ((.outbounds // []) | map(select((.tag // "") != "warp")))
        + (if $ready then [{type:"socks", tag:"warp", server:"127.0.0.1", server_port:$port}] else [] end)
      )
  '
}

warp_apply_meta_json_state() {
  local meta_json="$1" json warp_json rules_json ready port projected rebuilt
  warp_require_singbox || return 1
  warp_json="$(echo "$meta_json" | jq -c '
    (.warp // {mode:"off", rules:[]})
    | .mode = (if (.mode // "off") == "rules" then "rules" else "off" end)
    | .rules = [
        (.rules // [])[]?
        | select((.file // "") != "")
        | .tag = ("relay-" + ((.file // "" | sub("\\.srs$"; "")) | gsub("[^A-Za-z0-9_-]"; "-")))
      ]
  ')" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  json="$(config_load)"
  rules_json="$(echo "$warp_json" | jq -c '[.rules[]? | select((.tag // "") != "" and (.file // "") != "")] | unique_by(.tag)')" || return 1
  ready=false
  port=0
  if warp_wireproxy_ready; then
    ready=true
    port="$(warp_wireproxy_port)" || return 1
  fi
  projected="$(warp_config_project_json "$json" "$rules_json" "$ready" "$port")" || return 1
  rebuilt="$(route_rebuild "$projected" "$meta_json")" || return 1
  _CONFIG_APPLY_QUIET_OK=1 _CONFIG_SKIP_USAGE_SYNC=1 config_and_meta_apply "$rebuilt" "$meta_json"
}

warp_apply_current_state() {
  warp_apply_meta_json_state "$(meta_load)"
}

warp_require_wireproxy_ready() {
  if warp_wireproxy_ready; then
    return 0
  fi
  err "WireProxy SOCKS 未就绪，无法添加 WARP 分流。"
  warn "请先按页面提示安装 fscarmen WARP 脚本的 WireProxy 方案。"
  pause
  return 1
}

warp_add_preset_rules() {
  local raw="$1" picks=() names=() files=() pick item name file files_json meta_json relay_json warp_json
  warp_require_singbox || return 1
  warp_require_wireproxy_ready || return 1
  mapfile -t picks < <(parse_plus_selections "$raw")
  [ "${#picks[@]}" -gt 0 ] || return 1
  for pick in "${picks[@]}"; do
    if ! [[ "$pick" =~ ^[1-6]$ ]]; then
      err "只能使用 1-6，并用 + 连接。"
      pause
      return 1
    fi
  done
  for pick in "${picks[@]}"; do
    item="$(warp_preset_rule "$pick")" || return 1
    name="${item%%|*}"
    file="${item#*|}"
    names+=("$name")
    files+=("$file")
  done
  files_json="$(split_rule_files_json_from_args "${files[@]}")" || return 1
  split_rule_confirm_relay_to_warp "$files_json" || {
    warn "已取消，未修改 WARP 分流规则。"
    pause
    return 0
  }
  meta_json="$(meta_load)"
  relay_json="$(relay_rule_remove_meta_by_files_json_from "$(relay_meta_json)" "$files_json")" || return 1
  warp_json="$(warp_meta_json)"
  for pick in "${!files[@]}"; do
    warp_json="$(warp_rule_add_meta_to_json "$warp_json" "${names[$pick]}" "${files[$pick]}")" || return 1
  done
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  warp_apply_meta_json_state "$meta_json" || return 1
  ok "WARP 分流规则已应用。"
  pause
}

warp_custom_rule_menu() {
  local raw file name files_json meta_json relay_json warp_json
  warp_require_singbox || return 1
  warp_require_wireproxy_ready || return 1
  clear
  print_rect_title "自定义网站规则"
  echo "请先在以下页面查找规则名："
  echo "$WARP_RULE_LOOKUP_URL"
  echo
  echo "例如：openai 或 geosite-openai 或 geosite-openai.srs"
  read -r -p "请输入规则名（回车返回）：" raw
  [ -n "${raw:-}" ] || return 0
  file="$(warp_normalize_rule_file "$raw")" || { pause; return 1; }
  if ! warp_validate_rule_file "$file"; then
    err "未在 SagerNet rule-set 中找到：$file"
    pause
    return 1
  fi
  name="自定义：${file%.srs}"
  files_json="$(split_rule_files_json_from_args "$file")" || return 1
  split_rule_confirm_relay_to_warp "$files_json" || {
    warn "已取消，未修改 WARP 分流规则。"
    pause
    return 0
  }
  meta_json="$(meta_load)"
  relay_json="$(relay_rule_remove_meta_by_files_json_from "$(relay_meta_json)" "$files_json")" || return 1
  warp_json="$(warp_rule_add_meta_to_json "$(warp_meta_json)" "$name" "$file")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  warp_apply_meta_json_state "$meta_json" || return 1
  ok "自定义 WARP 分流已添加：$file"
  pause
}

warp_rules_delete_menu() {
  local rules_json count raw n tag tags_json has_delete_all=0 meta_json warp_json
  local -a idx=()
  local -a selected_tags=()
  rules_json="$(warp_meta_rules_json)"
  count="$(echo "$rules_json" | jq 'length')"
  [ "$count" -gt 0 ] || { warn "当前没有可删除的 WARP 分流。"; pause; return 0; }

  clear
  print_rect_title "删除 WARP 分流"
  warp_hr
  echo "当前分流至 WARP 的服务："
  warp_rules_print_numbered
  warp_hr
  echo -e "  ${C}99.${NC} 删除全部分流"
  echo -e "  ${R}0.${NC} 返回上一级"
  echo
  echo "多个编号用+连接，例如：1+3"
  read -r -p "请输入要删除的编号：" raw
  [ -n "${raw:-}" ] || return 0
  [ "$raw" = "0" ] && return 0

  mapfile -t idx < <(parse_plus_selections "$raw")
  [ "${#idx[@]}" -gt 0 ] || { warn "未选择任何分流。"; pause; return 0; }
  for n in "${idx[@]}"; do
    [ "$n" = "99" ] && has_delete_all=1
  done
  if [ "$has_delete_all" = "1" ]; then
    if [ "${#idx[@]}" -ne 1 ]; then
      err "删除全部分流不能和其它编号一起使用。"
      pause
      return 1
    fi
    ask_confirm_yn "确认删除全部 WARP 分流？(y/N): " || return 0
    meta_json="$(warp_meta_replace_in_meta_json "$(meta_load)" '{"mode":"off","rules":[]}')" || return 1
    warp_apply_meta_json_state "$meta_json" || return 1
    ok "已删除全部 WARP 分流。"
    pause
    return 0
  fi

  for n in "${idx[@]}"; do
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "$count" ]; then
      err "编号超出范围：$n"
      pause
      return 1
    fi
    tag="$(echo "$rules_json" | jq -r --argjson i "$((n-1))" '.[$i].tag')"
    [ -n "$tag" ] && [ "$tag" != "null" ] && selected_tags+=("$tag")
  done
  tags_json="$(printf '%s\n' "${selected_tags[@]}" | jq -R . | jq -s '.')" || { pause; return 1; }
  warp_json="$(warp_rule_remove_meta_by_tags_json_from "$(warp_meta_json)" "$tags_json")" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$(meta_load)" "$warp_json")" || return 1
  warp_apply_meta_json_state "$meta_json" || return 1
  ok "已删除指定 WARP 分流。"
  pause
}

warp_print_header() {
  print_rect_title "WARP 分流管理"
  warp_hr
  echo "说明：WARP 分流依赖 fscarmen WARP 脚本的 WireProxy 方案。"
  echo "详情：$WARP_SCRIPT_DOC_URL"
  warp_hr
}

warp_print_status() {
  if warp_wireproxy_ready; then
    echo "WireProxy SOCKS：已就绪"
  else
    echo "WireProxy SOCKS：未就绪"
  fi
  echo "本地 SOCKS：$(warp_wireproxy_display)"
  echo
  split_rule_overview_lines
  warp_hr
}

warp_print_install_hint() {
  echo "请先安装 WireProxy 方案："
  echo
  echo "wget -N $WARP_SCRIPT_RAW_URL"
  echo "bash menu.sh w"
  echo
  echo "安装完成后重新进入本菜单即可。"
  echo
}

warp_manager_menu() {
  local act count
  warp_init_env || { pause; return 0; }
  while true; do
    clear
    warp_print_header
    warp_print_status
    count="$(warp_rules_count)"
    if ! warp_wireproxy_ready; then
      warp_print_install_hint
      if [ "$count" -gt 0 ]; then
        echo -e "  ${C}8.${NC} 删除分流"
      fi
      echo -e "  ${R}0.${NC} 返回上一级"
      read -r -p "请选择操作: " act
      case "${act:-}" in
        0|q|Q|"") return 0 ;;
        8) [ "$count" -gt 0 ] && warp_rules_delete_menu || { warn "无效输入：$act"; sleep 1; } ;;
        *) warn "无效输入：$act"; sleep 1 ;;
      esac
      continue
    fi

    echo -e "  ${C}1.${NC} AI 服务"
    echo -e "  ${C}2.${NC} Google"
    echo -e "  ${C}3.${NC} Netflix"
    echo -e "  ${C}4.${NC} Disney+"
    echo -e "  ${C}5.${NC} YouTube"
    echo -e "  ${C}6.${NC} TikTok"
    echo -e "  ${C}7.${NC} 自定义网站规则"
    echo -e "  ${C}8.${NC} 删除分流"
    echo -e "  ${R}0.${NC} 返回上一级"
    echo
    echo "1-6支持用+连接，例如：1+3+6"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      0|q|Q|"") return 0 ;;
      7) warp_custom_rule_menu || true ;;
      8) warp_rules_delete_menu || true ;;
      *+*|[1-6]) warp_add_preset_rules "$act" || true ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

# >>>>>>>>> END MODULE: 64_warp.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 70_export.sh <<<<<<<<<<<
# ============================================================
# 模块: 70_export.sh
# 职责: 客户端配置导出（链接生成 + 多格式输出）
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 20_protocol.sh,
#       30_route.sh, 40_relay.sh, 50_v2ray_api.sh
# ============================================================

# ---------- 编码工具 ----------

b64_std_no_wrap() {
  printf '%s' "${1:-}" | openssl base64 -A 2>/dev/null | tr -d '\n'
}

url_encode() {
  printf '%s' "${1:-}" | jq -sRr @uri
}

# ---------- V2RayN 链接构建器（每协议一个函数） ----------

build_v2rayn_ss_link() {
  local server="$1" port="$2" method="$3" password="$4" name="$5"
  local userinfo enc
  userinfo="${method}:${password}"
  enc="$(b64_std_no_wrap "$userinfo")"
  printf 'ss://%s@%s:%s#%s' "$enc" "$server" "$port" "$(url_encode "$name")"
}

build_v2rayn_vmess_ws_link() {
  local server="$1" uuid="$2" host="$3" path="$4" name="$5"
  local payload enc
  payload="$(jq -nc \
    --arg ps "$name" \
    --arg add "$server" \
    --arg port "443" \
    --arg id "$uuid" \
    --arg aid "0" \
    --arg scy "auto" \
    --arg net "ws" \
    --arg type "none" \
    --arg host "$host" \
    --arg path "$path" \
    --arg tls "tls" \
    --arg sni "$host" \
    '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:$aid,scy:$scy,net:$net,type:$type,host:$host,path:$path,tls:$tls,sni:$sni}')"
  enc="$(b64_std_no_wrap "$payload")"
  printf 'vmess://%s' "$enc"
}

build_v2rayn_vless_reality_link() {
  local server="$1" port="$2" uuid="$3" sni="$4" pbk="$5" sid="$6" flow="$7" name="$8"
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$uuid" "$server" "$port" \
    "$(url_encode "$flow")" \
    "$(url_encode "$sni")" \
    "$(url_encode "$pbk")" \
    "$(url_encode "$sid")" \
    "$(url_encode "$name")"
}

build_v2rayn_vless_ws_link() {
  local server="$1" uuid="$2" host="$3" path="$4" name="$5"
  printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
    "$uuid" "$server" \
    "$(url_encode "$host")" \
    "$(url_encode "$host")" \
    "$(url_encode "$path")" \
    "$(url_encode "$name")"
}

build_v2rayn_anytls_link() {
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  # password 不做 url_encode：AnyTLS 客户端（mihomo/QX）实际未对 userinfo 做
  # URL 解码，编码后的 %2B/%3D 会被当成字面字符导致密码不匹配。
  # base64 字符集（A-Za-z0-9+/=）在 URL userinfo 中无歧义，可直接使用。
  printf 'anytls://%s@%s:%s?sni=%s&fp=chrome&alpn=%s&allowInsecure=1#%s' \
    "$password" "$server" "$port" \
    "$(url_encode "$sni")" \
    "$(url_encode "h2,http/1.1")" \
    "$(url_encode "$name")"
}

build_v2rayn_trojan_link() {
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  printf 'trojan://%s@%s:%s?security=tls&sni=%s&alpn=%s&allowInsecure=1#%s' \
    "$(url_encode "$password")" "$server" "$port" \
    "$(url_encode "$sni")" \
    "$(url_encode "h2,http/1.1")" \
    "$(url_encode "$name")"
}

build_v2rayn_tuic_link() {
  local server="$1" port="$2" uuid="$3" password="$4" sni="$5" name="$6"
  printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=%s&allow_insecure=1&congestion_control=bbr#%s' \
    "$uuid" "$(url_encode "$password")" "$server" "$port" \
    "$(url_encode "$sni")" \
    "$(url_encode "h3")" \
    "$(url_encode "$name")"
}

# ---------- 导出上下文收集 ----------

export_collect_context() {
  local json="$1"
  local ip ws_domain vm_domain inventory
  ip="$(get_public_ip)"
  ws_domain="example.com"
  vm_domain="example.com"
  inventory="$(protocol_entry_inventory "$json")"

  if printf '%s\n' "$inventory" | awk -F '\x01' '$2 == "vless-ws" {found=1} END{exit !found}'; then
    read -r -p "请输入 vless-ws 域名（默认: example.com）: " ws_domain
    ws_domain="${ws_domain:-example.com}"
  fi
  if printf '%s\n' "$inventory" | awk -F '\x01' '$2 == "vmess-ws" {found=1} END{exit !found}'; then
    read -r -p "请输入 vmess-ws 域名（默认: example.com）: " vm_domain
    vm_domain="${vm_domain:-example.com}"
  fi

  jq -n --arg ip "$ip" --arg wsd "$ws_domain" --arg vmd "$vm_domain" '{ip:$ip,ws_domain:$wsd,vm_domain:$vmd}'
}

# ---------- 主导出函数 ----------

export_configs() {
  init_manager_env || { pause; return 0; }
  clear
  local json ctx ip ws_domain vm_domain relay_users_nl
  local tag proto port sni path sid method server_p
  local name uuid pass flow out_name pw_out target_file business_user safe_user reality_public_key v2rayn_link
  json="$(config_load)"
  ctx="$(export_collect_context "$json")"
  IFS=$'\x01' read -r ip ws_domain vm_domain < <(
    echo "$ctx" | jq -r '[.ip, .ws_domain, .vm_domain] | join("\u0001")'
  )
  relay_users_nl="$(relay_list_table "$json" | awk -F '\x01' 'NF >= 2 {print $2}' | awk 'NF' | sort -u)"

  echo -e "${C}--- 节点配置导出 ---${NC}"

  local direct_tmp relay_tmp user_dir
  direct_tmp="$(mktemp)"
  relay_tmp="$(mktemp)"
  user_dir="$(mktemp -d)"
  _export_cleanup() {
    rm -rf "$user_dir" >/dev/null 2>&1 || true
    rm -f "$direct_tmp" "$relay_tmp" >/dev/null 2>&1 || true
  }
  trap '_export_cleanup; trap - RETURN' RETURN

  while read -r inbound; do
    IFS=$'\x01' read -r tag proto port sni path sid method server_p < <(
      echo "$inbound" | jq -r "${JQ_DETECT_PROTOCOL}"'
        [(.tag // ""), detect_protocol, ((.listen_port // 0) | tostring),
         (.tls.server_name // "www.icloud.com"), (.transport.path // "/"),
         (.tls.reality.short_id[0] // ""), (.method // "2022-blake3-aes-128-gcm"),
         (.password // "")] | join("\u0001")
      '
    )

    while read -r user; do
      IFS=$'\x01' read -r name uuid pass flow < <(
        echo "$user" | jq -r '[(.name // .username // ""), (.uuid // ""), (.password // ""),
          (.flow // "xtls-rprx-vision")] | join("\u0001")'
      )
      [ -z "$name" ] && continue
      out_name="$name"

      if [[ "$name" == *"@"* ]]; then
        business_user="$(user_business_name "$name")"
        safe_user="$(printf '%s' "$business_user" | tr '/ ' '__')"
        target_file="${user_dir}/${safe_user}.tmp"
      elif printf '%s\n' "$relay_users_nl" | grep -Fxq "$name"; then
        target_file="$relay_tmp"
      else
        target_file="$direct_tmp"
      fi

      case "$proto" in
        vless-reality)
          [ -z "$uuid" ] && continue
          reality_public_key="$(meta_get_reality_public_key "$tag")"
          [ -n "$reality_public_key" ] || reality_public_key="PUBLIC_KEY_MISSING"
          {
            echo -e "\n${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: vless, server: $ip, port: $port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: ${flow}, servername: $sni, reality-opts: {public-key: $reality_public_key, short-id: '$sid'}, client-fingerprint: chrome}"
            echo ""
            echo -e " Quantumult X: vless=$ip:$port, method=none, password=$uuid, obfs=over-tls, obfs-host=$sni, reality-base64-pubkey=$reality_public_key, reality-hex-shortid=$sid, vless-flow=${flow}, udp-relay=true, tag=${out_name}"
            echo ""
            v2rayn_link="$(build_v2rayn_vless_reality_link "$ip" "$port" "$uuid" "$sni" "$reality_public_key" "$sid" "$flow" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
          } >> "$target_file"
          ;;
        anytls)
          [ -z "$pass" ] && continue
          {
            echo -e "\n${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: anytls, server: $ip, port: $port, password: \"${pass}\", client-fingerprint: chrome, udp: true, sni: \"${sni}\", alpn: [h2, http/1.1], skip-cert-verify: true}"
            echo ""
            echo -e " Quantumult X: anytls=${ip}:${port}, password=${pass}, over-tls=true, tls-host=${sni}, udp-relay=true, tag=${out_name}"
            echo ""
            v2rayn_link="$(build_v2rayn_anytls_link "$ip" "$port" "$pass" "$sni" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
            echo ""
            echo -e " Surge: ${out_name} = anytls, ${ip}, ${port}, password=${pass}, skip-cert-verify=true, sni=${sni}"
          } >> "$target_file"
          ;;
        shadowsocks)
          [ -z "$pass" ] && continue
          if [ -n "$server_p" ]; then pw_out="${server_p}:${pass}"; else pw_out="$pass"; fi
          {
            echo -e "\n${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: \"${out_name}\", type: ss, server: $ip, port: ${port}, cipher: ${method}, password: \"${pw_out}\", udp: true}"
            echo ""
            echo -e " Quantumult X: shadowsocks=$ip:${port}, method=${method}, password=${pw_out}, udp-relay=true, tag=${out_name}"
            echo ""
            v2rayn_link="$(build_v2rayn_ss_link "$ip" "$port" "$method" "$pw_out" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
            echo ""
            echo -e " Surge: ${out_name} = ss, ${ip}, ${port}, encrypt-method=${method}, password=${pw_out}, udp-relay=true"
          } >> "$target_file"
          ;;
        trojan)
          [ -z "$pass" ] && continue
          {
            echo -e "\n${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: \"${out_name}\", type: trojan, server: $ip, port: ${port}, password: \"${pass}\", client-fingerprint: chrome, udp: true, sni: \"${sni}\", alpn: [h2, http/1.1], skip-cert-verify: true}"
            echo ""
            echo -e " Quantumult X: trojan=${ip}:${port}, password=${pass}, over-tls=true, tls-host=${sni}, tls-verification=false, fast-open=false, udp-relay=true, tag=${out_name}"
            echo ""
            v2rayn_link="$(build_v2rayn_trojan_link "$ip" "$port" "$pass" "$sni" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
            echo ""
            echo -e " Surge: ${out_name} = trojan, ${ip}, ${port}, password=${pass}, skip-cert-verify=true, sni=${sni}"
          } >> "$target_file"
          ;;
        vmess-ws)
          [ -z "$uuid" ] && continue
          {
            echo -e "\n${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: vmess, server: $ip, port: 443, uuid: ${uuid}, alterId: 0, cipher: auto, udp: true, tls: true, network: ws, servername: ${vm_domain}, ws-opts: {path: \"${path}\", headers: {Host: ${vm_domain}}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}"
            echo ""
            echo -e " Quantumult X: vmess=$ip:443, method=chacha20-poly1305, password=${uuid}, obfs=wss, obfs-host=${vm_domain}, obfs-uri=${path}?ed=2048, fast-open=false, udp-relay=true, tag=${out_name}"
            echo ""
            v2rayn_link="$(build_v2rayn_vmess_ws_link "$ip" "$uuid" "$vm_domain" "${path}?ed=2048" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
            echo ""
            echo -e " Surge: ${out_name} = vmess, ${ip}, 443, username=${uuid}, tls=true, vmess-aead=true, ws=true, ws-path=${path}?ed=2048, sni=${vm_domain}, ws-headers=Host:${vm_domain}, skip-cert-verify=false, udp-relay=true, tfo=false"
          } >> "$target_file"
          ;;
        vless-ws)
          [ -z "$uuid" ] && continue
          {
            echo -e "\n${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: vless, server: $ip, port: 443, uuid: ${uuid}, udp: true, tls: true, network: ws, servername: ${ws_domain}, ws-opts: {path: \"${path}\", headers: {Host: ${ws_domain}}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}"
            echo ""
            echo -e " Quantumult X: vless=$ip:443,method=none,password=${uuid},obfs=wss,obfs-host=${ws_domain},obfs-uri=${path}?ed=2048,fast-open=false,udp-relay=true,tag=${out_name}"
            echo ""
            v2rayn_link="$(build_v2rayn_vless_ws_link "$ip" "$uuid" "$ws_domain" "${path}?ed=2048" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
          } >> "$target_file"
          ;;
        tuic)
          [ -z "$uuid" ] && continue
          [ -z "$pass" ] && continue
          {
            echo -e "\n${W}[${out_name}]${NC}"
            echo -e " Clash: - {name: ${out_name}, type: tuic, server: $ip, port: $port, uuid: $uuid, password: $pass, alpn: [h3], disable-sni: false, reduce-rtt: false, udp-relay-mode: native, congestion-controller: bbr, skip-cert-verify: true, sni: $sni}"
            echo ""
            v2rayn_link="$(build_v2rayn_tuic_link "$ip" "$port" "$uuid" "$pass" "$sni" "$out_name")"
            echo -e " 通用链接: ${v2rayn_link}"
            echo ""
            echo -e " Surge: ${out_name} = tuic-v5, ${ip}, ${port}, password=${pass}, sni=${sni}, uuid=${uuid}, alpn=h3, ecn=true"
          } >> "$target_file"
          ;;
        socks)
          [ -z "$name" ] && continue
          [ -z "$pass" ] && continue
          {
            echo -e "\n${W}[${out_name}]${NC}"
            echo -e " 参数: server=${ip}  port=${port}  username=${name}  password=${pass}"
          } >> "$target_file"
          ;;
      esac
    done < <(echo "$inbound" | jq -c '.users[]?')
  done < <(echo "$json" | jq -c "${JQ_PROTOCOL_SORT}"'[.inbounds[]?] | sort_by(protocol_sort_index(.tag // "")) | .[]')

  echo -e "\n${C}直连节点${NC}"
  if [ -s "$direct_tmp" ]; then
    cat "$direct_tmp"
  else
    echo -e "  ${Y}当前没有直连节点。${NC}"
  fi

  echo -e "\n${C}中转节点${NC}"
  if [ -s "$relay_tmp" ]; then
    cat "$relay_tmp"
  else
    echo -e "  ${Y}当前没有中转节点。${NC}"
  fi

  local user_file printed=0 user_name
  while IFS= read -r -d '' user_file; do
    printed=1
    user_name="$(basename "$user_file" .tmp)"
    echo -e "\n${C}${user_name}节点${NC}"
    cat "$user_file"
  done < <(find "$user_dir" -maxdepth 1 -type f -name '*.tmp' -print0 | sort -z)

  if [ "$printed" -eq 0 ]; then
    echo -e "\n${C}用户节点${NC}"
    echo -e "  ${Y}当前没有用户节点。${NC}"
  fi

  echo ""
  pause
}

# >>>>>>>>> END MODULE: 70_export.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 80_installer.sh <<<<<<<<<<<
# ============================================================
# 模块: 80_installer.sh
# 职责: sing-box 安装/更新/卸载、systemd 服务、cron、系统工具
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 50_v2ray_api.sh
# ============================================================

# ---------- 依赖安装 ----------

ensure_deps_for_installer() {
  require_root
  [ "$PKG_MANAGER" = "unknown" ] && { err "未找到受支持的包管理器（apt-get 或 apk）。"; exit 1; }
  say "安装必要依赖..."
  local _PKG_INSTALL_QUIET=1
  install_pkg curl
  install_pkg jq
  install_pkg openssl
  install_pkg tar
  case "$PKG_MANAGER" in
    apt) install_pkg ca-certificates; install_pkg gnupg; install_pkg gzip; install_pkg util-linux ;;
    apk) install_pkg ca-certificates; install_pkg gcompat; install_pkg flock ;;
  esac
}

version_ge() {
  # version_ge A B → true if A >= B
  local a="${1#v}" b="${2#v}"
  if sort -V </dev/null >/dev/null 2>&1; then
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" = "$b" ]
    return $?
  fi
  awk -v a="$a" -v b="$b" '
    function clean(v) { sub(/[-+].*/, "", v); return v }
    BEGIN {
      split(clean(a), av, ".")
      split(clean(b), bv, ".")
      for (i = 1; i <= 4; i++) {
        ai = av[i] + 0
        bi = bv[i] + 0
        if (ai > bi) exit 0
        if (ai < bi) exit 1
      }
      exit 0
    }
  '
}

ensure_sagernet_repo() { :; }

# ---------- 版本管理 ----------

get_release_latest_tag() {
  local repo="${SINGBOX_RELEASE_REPO:-Tangfffyx/sing-box}"
  curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty'
}

normalize_release_tag() {
  local v="${1:-}"
  v="${v#v}"
  echo "$v"
}

# 远端版本缓存：菜单摘要只读这个文件，永不发起网络请求，避免阻塞交互。
# 写入由后台 cron 和安装/更新流程负责。
refresh_upstream_tag_cache() {
  local tag="${1:-}"
  if [ -z "$tag" ]; then
    tag="$(get_release_latest_tag)"
  fi
  [ -n "$tag" ] || return 1
  mkdir -p "$(dirname "$UPSTREAM_TAG_CACHE_FILE")" >/dev/null 2>&1 || true
  local now tmp
  now="$(date +%s)"
  tmp="${UPSTREAM_TAG_CACHE_FILE}.tmp.$$"
  if jq -nc --arg tag "$tag" --argjson now "$now" '{tag:$tag, fetched_at:$now}' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$UPSTREAM_TAG_CACHE_FILE" || { rm -f "$tmp"; return 1; }
    return 0
  fi
  rm -f "$tmp" >/dev/null 2>&1 || true
  return 1
}

# 读缓存中的 upstream 版本号（已 strip "v" 前缀）。
# 缓存不存在或过期返回空字符串，调用方据此显示"未知"。
get_cached_upstream_version() {
  [ -s "$UPSTREAM_TAG_CACHE_FILE" ] || return 0
  local now fetched age tag
  now="$(date +%s)"
  fetched="$(jq -r '.fetched_at // 0' "$UPSTREAM_TAG_CACHE_FILE" 2>/dev/null || echo 0)"
  [[ "$fetched" =~ ^[0-9]+$ ]] || fetched=0
  age=$((now - fetched))
  [ "$age" -le "$UPSTREAM_TAG_CACHE_MAX_AGE_SECS" ] || return 0
  tag="$(jq -r '.tag // ""' "$UPSTREAM_TAG_CACHE_FILE" 2>/dev/null || true)"
  [ -n "$tag" ] || return 0
  normalize_release_tag "$tag"
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
  echo -e " 当前版本 : ${inst:-未安装}"
  echo -e " 最新版本 : ${cand:-无}"
  echo -e "${W}--------------------------${NC}"
}

# 完整性探针：所有关键组件都就位才算真正装好
# 用于区分"版本号匹配"与"组件齐全"，避免半完成状态被误判为已安装
is_install_complete() {
  [ -x "$SINGBOX_BIN" ] || return 1
  [ -s "$SINGBOX_VERSION_STAMP" ] || return 1
  user_db_exists || return 1
  _cron_job_installed "$PERIODIC_SYNC_CRON_MARK" || return 1
  _cron_job_installed "$DAILY_MAINTENANCE_CRON_MARK" || return 1
  # 6.0.8 及以前的老 cron 残留也算"组件不一致"，引导用户清理。
  ! _cron_job_installed "$USER_WATCH_CRON_MARK" || return 1
  ! _cron_job_installed "$LOG_MAINTAIN_CRON_MARK" || return 1
  ! _cron_job_installed "$TG_AGENT_CRON_MARK" || return 1
  ! _cron_job_installed "$UPSTREAM_REFRESH_CRON_MARK" || return 1
  singbox_service_active || return 1
  return 0
}

# ---------- 脚本自身管理 ----------

resolve_current_script_file() {
  local current="${SCRIPT_SELF:-${BASH_SOURCE[0]:-$0}}"
  local fd_path
  if [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]] || [[ "$current" == /dev/fd/* ]] || [[ "$current" == /proc/self/fd/* ]]; then
    fd_path="$(readlink -f "$current" 2>/dev/null || true)"
    [ -n "$fd_path" ] && [ -r "$fd_path" ] && { echo "$fd_path"; return 0; }
    return 1
  fi
  current="$(readlink -f "$current" 2>/dev/null || echo "$current")"
  [ -r "$current" ] || return 1
  echo "$current"
}

write_local_script_entrypoint() {
  mkdir -p /usr/local/bin
  local source_file
  source_file="$(resolve_current_script_file)" || {
    warn "快捷命令 s 安装失败：无法读取当前脚本。"
    return 1
  }
  if [ "$source_file" != "$SB_TARGET_SCRIPT" ]; then
    cp -f "$source_file" "$SB_TARGET_SCRIPT" || {
      warn "快捷命令 s 安装失败：无法写入 $SB_TARGET_SCRIPT"
      return 1
    }
  fi
  chmod +x "$SB_TARGET_SCRIPT" >/dev/null 2>&1 || true
  install_sb_shortcut
}

install_sb_shortcut() {
  cat > "$SB_SHORTCUT" <<'EOF2'
#!/bin/sh
exec bash /root/sb.sh "$@"
EOF2
  chmod +x "$SB_SHORTCUT" >/dev/null 2>&1 || true
}

ensure_local_script_entrypoint_once() {
  [ -s "$SB_TARGET_SCRIPT" ] && [ -x "$SB_SHORTCUT" ] && return 0
  write_local_script_entrypoint >/dev/null 2>&1 || true
}

ensure_sb_shortcut() {
  write_local_script_entrypoint
}

# ---------- 日志维护 ----------

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

# ---------- Cron 管理 ----------

_cron_job_match_pattern() {
  local mark="$1"
  case "$mark" in
    "$USER_WATCH_CRON_MARK") echo "--user-watch" ;;
    "$LOG_MAINTAIN_CRON_MARK") echo "--maintain-logs" ;;
    "$TG_AGENT_CRON_MARK") echo "--tg-agent-sync" ;;
    "$UPSTREAM_REFRESH_CRON_MARK") echo "--refresh-upstream" ;;
    "$PERIODIC_SYNC_CRON_MARK") echo "--periodic-sync" ;;
    "$DAILY_MAINTENANCE_CRON_MARK") echo "--daily-maintenance" ;;
    *) echo "$mark" ;;
  esac
}

_cron_job_installed() {
  local mark="$1" pattern
  has_cmd crontab || return 1
  pattern="$(_cron_job_match_pattern "$mark")"
  crontab -l 2>/dev/null | awk -v p="$pattern" '
    /^[[:space:]]*#/ { next }
    index($0, p) { found=1 }
    END { exit !found }
  '
}

_crond_daemon_active() {
  case "$INIT_SYSTEM" in
    systemd)
      systemctl is-active --quiet crond 2>/dev/null || systemctl is-active --quiet cron 2>/dev/null
      ;;
    openrc)
      rc-service crond status >/dev/null 2>&1 || rc-service cron status >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

_ensure_crond_running() {
  # 1. 确保 crontab 命令可用，不可用时按包管理器装对应包
  if ! has_cmd crontab; then
    case "$PKG_MANAGER" in
      apt) install_pkg cron 2>/dev/null || install_pkg cronie 2>/dev/null || return 1 ;;
      apk) install_pkg cronie 2>/dev/null || install_pkg dcron 2>/dev/null || return 1 ;;
      *) return 1 ;;
    esac
  fi

  # 2. 已运行直接通过
  _crond_daemon_active && return 0

  # 3. 启动 daemon（systemd / openrc 兼容 crond 和 cron 两种服务名）
  case "$INIT_SYSTEM" in
    systemd)
      systemctl start crond >/dev/null 2>&1 || systemctl start cron >/dev/null 2>&1 || true
      systemctl enable crond >/dev/null 2>&1 || systemctl enable cron >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-service crond start >/dev/null 2>&1 || rc-service cron start >/dev/null 2>&1 || true
      rc-update add crond default >/dev/null 2>&1 || rc-update add cron default >/dev/null 2>&1 || true
      ;;
    *) return 1 ;;
  esac

  # 4. 等待 daemon 稳定后再次验证
  sleep 1
  _crond_daemon_active
}

cron_job_status_line() {
  local label="$1" mark="$2"
  local installed daemon_state
  if _cron_job_installed "$mark"; then
    installed="${G}已安装${NC}"
  else
    installed="${R}未安装${NC}"
  fi
  if _crond_daemon_active; then
    daemon_state="${G}运行中${NC}"
  else
    daemon_state="${R}未运行${NC}"
  fi
  printf '  %b%s%b : %b  定时服务 %b\n' "$W" "$label" "$NC" "$installed" "$daemon_state"
}

_install_cron_job() {
  local mark="$1" schedule="$2" cmd="$3"
  # 先让 _ensure_crond_running 负责装 cron 包 + 启动 daemon
  _ensure_crond_running || { err "cron 服务不可用（未能自动安装或启动 crond）。"; return 1; }
  # 到这里 crontab 命令必然可用（_ensure_crond_running 会主动安装）
  local tmp pattern
  pattern="$(_cron_job_match_pattern "$mark")"
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | awk -v p="$pattern" 'index($0, p) == 0 { print }' > "$tmp" || true
  echo "${schedule} ${cmd} >/dev/null 2>&1" >> "$tmp"
  crontab "$tmp" || { rm -f "$tmp"; err "crontab 写入失败。"; return 1; }
  rm -f "$tmp"
  _cron_job_installed "$mark" || { err "crontab 写入后验证失败：未找到 mark $mark"; return 1; }
  return 0
}

_remove_cron_job() {
  local mark="$1"
  has_cmd crontab || return 0
  local tmp pattern
  pattern="$(_cron_job_match_pattern "$mark")"
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | awk -v p="$pattern" 'index($0, p) == 0 { print }' > "$tmp" || true
  if [ -s "$tmp" ]; then
    crontab "$tmp"
  else
    crontab -r 2>/dev/null || true
  fi
  rm -f "$tmp"
}

install_log_maintain_cron() { _install_cron_job "$LOG_MAINTAIN_CRON_MARK" "$LOG_MAINTAIN_CRON_SCHEDULE" "bash ${SB_TARGET_SCRIPT} --maintain-logs"; }
remove_log_maintain_cron()  { _remove_cron_job "$LOG_MAINTAIN_CRON_MARK"; }
install_user_watch_cron()   { _install_cron_job "$USER_WATCH_CRON_MARK" "$USER_WATCH_CRON_SCHEDULE" "bash ${SB_TARGET_SCRIPT} --user-watch"; }
remove_user_watch_cron()    { _remove_cron_job "$USER_WATCH_CRON_MARK"; }
install_upstream_refresh_cron() { _install_cron_job "$UPSTREAM_REFRESH_CRON_MARK" "$UPSTREAM_REFRESH_CRON_SCHEDULE" "bash ${SB_TARGET_SCRIPT} --refresh-upstream"; }
remove_upstream_refresh_cron()  { _remove_cron_job "$UPSTREAM_REFRESH_CRON_MARK"; }
install_periodic_sync_cron()    { _install_cron_job "$PERIODIC_SYNC_CRON_MARK" "$PERIODIC_SYNC_CRON_SCHEDULE" "bash ${SB_TARGET_SCRIPT} --periodic-sync"; }
remove_periodic_sync_cron()     { _remove_cron_job "$PERIODIC_SYNC_CRON_MARK"; }
install_daily_maintenance_cron(){ _install_cron_job "$DAILY_MAINTENANCE_CRON_MARK" "$DAILY_MAINTENANCE_CRON_SCHEDULE" "bash ${SB_TARGET_SCRIPT} --daily-maintenance"; }
remove_daily_maintenance_cron() { _remove_cron_job "$DAILY_MAINTENANCE_CRON_MARK"; }

# 6.0.9 起合并定时任务的执行入口。
# periodic-sync：每 3 分钟，跑 user_watch + tg_agent_sync（TG 内部自检 enabled）。
# daily-maintenance：本地凌晨一次，跑 log 截尾 + 上游版本号刷新缓存。
# 两个 runner 内部都用 `|| true` 隔离故障，避免一步挂导致另一步不跑。
periodic_sync_run() {
  user_watch_run || true
  tg_agent_sync || true
}

daily_maintenance_run() {
  maintain_logs || true
  refresh_upstream_tag_cache >/dev/null 2>&1 || true
}

# ---------- 服务管理（systemd / OpenRC） ----------

remove_all_singbox_service_units() {
  case "$INIT_SYSTEM" in
    systemd)
      systemctl stop sing-box >/dev/null 2>&1 || true
      systemctl disable sing-box >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/sing-box.service \
            /usr/lib/systemd/system/sing-box.service \
            /lib/systemd/system/sing-box.service >/dev/null 2>&1 || true
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      if openrc_service_exists sing-box; then
        openrc_stop_service sing-box >/dev/null 2>&1 || true
      fi
      openrc_disable_service sing-box default >/dev/null 2>&1 || true
      find /etc/runlevels -type l -name sing-box -exec rm -f {} + 2>/dev/null || true
      rm -f /etc/init.d/sing-box >/dev/null 2>&1 || true
      ;;
  esac
}

write_managed_singbox_service() {
  mkdir -p /var/lib/sing-box /etc/sing-box
  case "$INIT_SYSTEM" in
    systemd)
      mkdir -p /etc/systemd/system
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
      ;;
    openrc)
      cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="${SINGBOX_BIN}"
command_args="-D /var/lib/sing-box -c ${CONFIG_FILE} run"
command_background=true
pidfile="/run/sing-box.pid"
depend() {
  need net
  after firewall
}
EOF
      chmod +x /etc/init.d/sing-box
      ;;
  esac
}

ensure_command_compat_links() {
  mkdir -p /usr/bin
  ln -sf "${SINGBOX_BIN}" /usr/bin/sing-box
}

migrate_legacy_script_name() {
  if [ -f /root/sing-box.sh ]; then
    rm -f /root/sing-box.sh
  fi
  if has_cmd crontab; then
    local tmp
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v 'sing-box\.sh --user-watch\|sing-box\.sh --maintain-logs' > "$tmp" || true
    if [ -s "$tmp" ]; then
      crontab "$tmp"
    fi
    rm -f "$tmp"
  fi
}

is_script_managed_environment() {
  case "$INIT_SYSTEM" in
    systemd)
      [ -f /etc/systemd/system/sing-box.service ] || return 1
      grep -Fq "ExecStart=${SINGBOX_BIN} -D /var/lib/sing-box -c /etc/sing-box/config.json run" /etc/systemd/system/sing-box.service 2>/dev/null || return 1
      ;;
    openrc)
      [ -f /etc/init.d/sing-box ] || return 1
      grep -Fq "${SINGBOX_BIN}" /etc/init.d/sing-box 2>/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
  [ -f /usr/local/bin/s ] && grep -Fq 'exec bash /root/sb.sh "$@"' /usr/local/bin/s 2>/dev/null || return 1
  return 0
}

refresh_command_cache() {
  hash -r 2>/dev/null || true
}

singbox_command_exists() {
  refresh_command_cache
  command -v sing-box >/dev/null 2>&1
}

prepare_script_runtime() {
  migrate_legacy_script_name || return 1
  write_managed_singbox_service || return 1
  ensure_command_compat_links || return 1
  mkdir -p /var/log/sing-box || return 1
  if [ "$INIT_SYSTEM" = "systemd" ]; then systemctl daemon-reload || return 1; fi
  return 0
}

# ---------- 安装/更新 sing-box ----------

install_or_update_singbox() {
  clear
  print_rect_title "sing-box 安装/更新"

  ensure_deps_for_installer

  local arch file tag latest_ver inst ans tmp_dir base_url download_url sha_url managed_env
  arch="$(uname -m)"
  case "$arch" in
    x86_64) file="sing-box-linux-amd64.tar.gz" ;;
    aarch64|arm64) file="sing-box-linux-arm64.tar.gz" ;;
    *)
      err "不支持的架构：$arch"
      pause
      return 1
      ;;
  esac

  tag="$(get_release_latest_tag)"
  latest_ver="$(normalize_release_tag "$tag")"

  refresh_command_cache
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

  if [ "${managed_env}" != "1" ] && singbox_command_exists; then
    warn "检测到已有非本脚本安装的 sing-box 环境，请先执行“卸载 sing-box”后再安装。"
    pause >&2
    return 0
  fi

  if [ "${managed_env}" = "1" ]; then
    echo -e "当前版本：${G}${inst:-未知}${NC}"
    echo -e "最新版本：${G}${latest_ver}${NC}"
    if [ -n "${inst:-}" ] && version_ge "$inst" "$latest_ver"; then
      if is_install_complete; then
        config_apply "$(config_load)" || { pause; return 1; }
        ok "当前已是最新版本。"
        pause
        return 0
      fi
      warn "版本号匹配但部分组件缺失。"
      read -r -p "是否重新安装以补齐组件？[Y/n]: " ans
      case "${ans:-Y}" in
        [Nn]*) return 0 ;;
      esac
    elif [ -n "${inst:-}" ]; then
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

  if [ "${managed_env}" = "1" ] && [ -x "$SINGBOX_BIN" ]; then
    sync_user_usage_counters || { pause; return 1; }
  fi

  tmp_dir="$(make_disk_tmp_dir sb-install)" || {
    err "创建临时目录失败。"
    pause
    return 1
  }
  base_url="https://github.com/${SINGBOX_RELEASE_REPO:-Tangfffyx/sing-box}/releases/download/${tag}"
  download_url="${base_url}/${file}"
  sha_url="${base_url}/sha256sum.txt"

  say "下载 sing-box..."
  if ! download_file "$download_url" "$tmp_dir/$file" 20 3; then
    rm -rf "$tmp_dir"
    err "下载失败，请检查网络或稍后重试。"
    pause
    return 1
  fi

  if curl -fsSL --connect-timeout 20 --retry 3 "$sha_url" -o "$tmp_dir/sha256sum.txt" >/dev/null 2>&1; then
    expected_sha="$(awk -v f="$file" '{n=$2; sub(/^.*\//,"",n); if (n==f) {print $1; exit}}' "$tmp_dir/sha256sum.txt")"
    actual_sha="$(sha256sum "$tmp_dir/$file" | awk '{print $1}')"
    if [ -z "$expected_sha" ] || [ "$expected_sha" != "$actual_sha" ]; then
      rm -rf "$tmp_dir"
      err "校验失败。"
      pause
      return 1
    fi
  else
    warn "未获取到校验文件。"
    if ! ask_confirm_yes "输入 YES 确认跳过校验继续安装，其它任意输入取消: "; then
      rm -rf "$tmp_dir"
      err "已取消安装。"
      pause
      return 1
    fi
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

  # staging 验证：在替换正式位置之前先验证 with_v2ray_api，避免坏二进制进入 $SINGBOX_BIN
  chmod +x "$tmp_dir/sing-box" 2>/dev/null || true
  if ! "$tmp_dir/sing-box" version 2>/dev/null | grep -q 'with_v2ray_api'; then
    rm -rf "$tmp_dir"
    err "下载的 sing-box 未检测到 with_v2ray_api。"
    if [ "$PKG_MANAGER" = "apk" ]; then
      warn "Alpine 环境提示：若报 'cannot execute' 错误，请手动执行：apk add gcompat"
    fi
    pause
    return 1
  fi

  if ! ensure_grpcurl_logged || ! ensure_v2ray_api_proto_files; then
    rm -rf "$tmp_dir"
    err "统计组件未就绪，已取消升级。"
    pause
    return 1
  fi
  if ! with_manager_lock install_candidate_singbox "$tmp_dir/sing-box" "$tag"; then
    rm -rf "$tmp_dir"
    pause
    return 1
  fi
  rm -rf "$tmp_dir"
  # 内核事务已提交；可重试的菜单/cron 初始化不影响已验证的内核。
  ensure_sb_shortcut || true
  ensure_user_manager_ready || warn "用户数据库初始化失败，用户管理菜单进入时会重试初始化。"
  install_periodic_sync_cron || warn "cron 定时任务安装失败：实时同步（环境: ${PKG_MANAGER}/${INIT_SYSTEM}）。is_install_complete 探针会引导后续修复。"
  install_daily_maintenance_cron || warn "cron 定时任务安装失败：日常维护（环境: ${PKG_MANAGER}/${INIT_SYSTEM}）。is_install_complete 探针会引导后续修复。"
  # 清理 6.0.8 及以前残留的 4 个老 cron（墓志铭入口让它们不出错，但应清掉避免无意义触发）
  remove_user_watch_cron || true
  remove_log_maintain_cron || true
  remove_tg_agent_cron || true
  remove_upstream_refresh_cron || true
  refresh_upstream_tag_cache "$tag" >/dev/null 2>&1 || true
  user_manager_background_sync || warn "用户管理后台同步初始化失败。下次 periodic-sync cron 会重试。"
  tg_refresh_after_singbox_install || true

  ok "安装完成。"
  pause
}

# 调用方持管理锁。候选文件在正式路径之外完成校验；保留最近一次成功版本。
install_candidate_singbox() {
  local candidate="$1" tag="$2" next_config old_config next_bin old_bin stamp_tmp had_config=0 had_bin=0
  mkdir -p "$SINGBOX_INSTALL_DIR" "$(dirname "$CONFIG_FILE")" || return 1
  if [ -e "$CONFIG_FILE" ]; then
    jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null || { err "现有配置无效，已取消升级。"; return 1; }
    had_config=1
  fi
  next_config="$(mktemp "${CONFIG_FILE}.upgrade.XXXXXX")" || return 1
  if [ "$had_config" = 1 ]; then
    config_normalize "$(cat "$CONFIG_FILE")" > "$next_config" || { rm -f "$next_config"; return 1; }
  else
    config_normalize "$(config_min_template)" > "$next_config" || { rm -f "$next_config"; return 1; }
  fi
  if ! "$candidate" check -c "$next_config"; then
    rm -f "$next_config"
    err "新内核不接受当前配置，正式文件未替换。"
    return 1
  fi
  sync_user_usage_counters || { rm -f "$next_config"; return 1; }
  old_config="$(mktemp "${CONFIG_FILE}.rollback.XXXXXX")" || { rm -f "$next_config"; return 1; }
  if [ "$had_config" = 1 ]; then
    cp -p "$CONFIG_FILE" "$old_config" || { rm -f "$old_config" "$next_config"; return 1; }
  fi
  next_bin="$(mktemp "${SINGBOX_BIN}.new.XXXXXX")" || { rm -f "$old_config" "$next_config"; return 1; }
  old_bin="$(mktemp "${SINGBOX_BIN}.rollback.XXXXXX")" || { rm -f "$next_bin" "$old_config" "$next_config"; return 1; }
  if [ -x "$SINGBOX_BIN" ]; then
    had_bin=1
    cp -p "$SINGBOX_BIN" "$old_bin" || { rm -f "$old_bin" "$next_bin" "$old_config" "$next_config"; return 1; }
  fi
  if ! install -m 755 "$candidate" "$next_bin"; then
    rm -f "$old_bin" "$next_bin" "$old_config" "$next_config"
    return 1
  fi
  stamp_tmp="$(mktemp "${SINGBOX_VERSION_STAMP}.tmp.XXXXXX")" || {
    rm -f "$old_bin" "$next_bin" "$old_config" "$next_config"; return 1;
  }
  if ! printf '%s\n' "$tag" > "$stamp_tmp"; then
    rm -f "$stamp_tmp" "$old_bin" "$next_bin" "$old_config" "$next_config"; return 1
  fi
  if mv -f "$next_bin" "$SINGBOX_BIN" && mv -f "$next_config" "$CONFIG_FILE" &&
      prepare_script_runtime && _RESTART_SINGBOX_QUIET_OK=1 reload_or_restart_singbox_safe &&
      mv -f "$stamp_tmp" "$SINGBOX_VERSION_STAMP"; then
    if [ "$had_bin" = 1 ]; then
      mv -f "$old_bin" "${SINGBOX_BIN}.bak" || warn "旧内核保留于 $old_bin"
    else
      rm -f "$old_bin"
    fi
    if [ "$had_config" = 1 ]; then
      mv -f "$old_config" "${CONFIG_FILE}.bak.upgrade" || warn "旧配置保留于 $old_config"
    else
      rm -f "$old_config"
    fi
    case "$INIT_SYSTEM" in
      systemd) systemctl enable sing-box >/dev/null 2>&1 || warn "设置自启失败。" ;;
      openrc) openrc_enable_service sing-box default >/dev/null 2>&1 || warn "设置自启失败。" ;;
    esac
    return 0
  fi
  err "升级未通过运行检查，正在恢复旧内核及配置。"
  rm -f "$next_bin" "$next_config" "$stamp_tmp"
  if [ "$had_config" = 1 ]; then
    mv -f "$old_config" "$CONFIG_FILE" || { err "配置回滚失败，备份：$old_config"; return 1; }
  else
    rm -f "$CONFIG_FILE" "$old_config"
  fi
  if [ "$had_bin" = 1 ]; then
    mv -f "$old_bin" "$SINGBOX_BIN" || { err "内核回滚失败，备份：$old_bin"; return 1; }
    _RESTART_SINGBOX_QUIET_OK=1 reload_or_restart_singbox_safe || err "旧内核恢复后启动失败，请检查服务日志。"
  else
    case "$INIT_SYSTEM" in
      systemd) systemctl stop sing-box >/dev/null 2>&1 || true ;;
      openrc) rc-service sing-box stop >/dev/null 2>&1 || true ;;
    esac
    rm -f "$SINGBOX_BIN" "$old_bin"
  fi
  return 1
}

# ---------- 时间同步 ----------

chrony_service_name() {
  case "$INIT_SYSTEM" in
    systemd)
      if systemctl cat chrony >/dev/null 2>&1; then
        echo "chrony"
      elif systemctl cat chronyd >/dev/null 2>&1; then
        echo "chronyd"
      else
        echo "chrony"
      fi
      ;;
    openrc)
      if openrc_service_exists chronyd; then
        echo "chronyd"
      elif openrc_service_exists chrony; then
        echo "chrony"
      fi
      ;;
  esac
}

chrony_service_running() {
  local service="$1"
  case "$INIT_SYSTEM" in
    systemd) systemctl is-active --quiet "$service" 2>/dev/null ;;
    openrc)  openrc_service_running "$service" ;;
    *)       return 1 ;;
  esac
}

chrony_service_start() {
  local service="$1"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl reset-failed "$service" >/dev/null 2>&1 || true
      systemctl start "$service"
      ;;
    openrc)
      openrc_start_service "$service"
      ;;
    *) return 1 ;;
  esac
}

chrony_service_enable() {
  local service="$1"
  case "$INIT_SYSTEM" in
    systemd) systemctl enable "$service" >/dev/null 2>&1 || true ;;
    openrc)  openrc_enable_service "$service" default >/dev/null 2>&1 || true ;;
  esac
}

chrony_timeout() {
  run_with_timeout "$@"
}

chronyc_tracking_ready() {
  chrony_timeout 3 chronyc tracking >/dev/null 2>&1
}

chrony_service_status() {
  local service="$1"
  if chrony_service_running "$service"; then
    ok "chrony: 运行中"
  else
    warn "chrony: 未运行"
  fi
}

chrony_prepare_for_service_control() {
  local service="$1"
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl stop systemd-timesyncd >/dev/null 2>&1 || true
    systemctl disable systemd-timesyncd >/dev/null 2>&1 || true
    systemctl reset-failed "$service" >/dev/null 2>&1 || true
  fi
}

chrony_repair_service() {
  local service="$1"
  chrony_prepare_for_service_control "$service"
  if chrony_service_start "$service" >/dev/null 2>&1; then
    sleep 1
    chrony_service_running "$service"
    return
  fi

  case "$INIT_SYSTEM" in
    systemd) systemctl stop "$service" >/dev/null 2>&1 || true ;;
    openrc)  openrc_stop_service "$service" >/dev/null 2>&1 || true ;;
  esac
  pkill -9 chronyd >/dev/null 2>&1 || true
  rm -f /run/chrony/chronyd.pid >/dev/null 2>&1 || true
  chrony_service_start "$service" >/dev/null 2>&1 || return 1
  sleep 1
  chrony_service_running "$service"
}

sync_system_time_chrony() {
  require_root
  clear
  echo -e "${R}--- 一键同步系统时间 ---${NC}"
  if ! has_cmd chronyc; then
    warn "未检测到 chrony，开始安装..."
    install_pkg chrony || { err "chrony 安装失败。"; pause; return 1; }
    local installed_service
    installed_service="$(chrony_service_name)"
    [ -n "$installed_service" ] && chrony_service_enable "$installed_service"
  fi
  has_cmd chronyc || { err "chrony 安装后仍未找到 chronyc，无法继续校时。"; pause; return 1; }

  local chrony_service
  chrony_service="$(chrony_service_name)"
  if [ -z "$chrony_service" ]; then
    err "chrony 已安装，但未找到可用服务（OpenRC 通常应为 chronyd）。"
    warn "当前可能是 Alpine/LXC 精简环境，缺少 chrony 的 OpenRC 服务脚本。"
    warn "如果这是 LXC 容器，请在宿主机校准时间，容器会跟随宿主机时间。"
    pause
    return 1
  fi

  if ! chrony_service_running "$chrony_service" || ! chronyc_tracking_ready; then
    warn "开始修复 chrony 服务状态..."
    if ! chrony_repair_service "$chrony_service"; then
      err "chrony 服务未能启动：${chrony_service}"
      warn "当前环境可能不允许容器主动校时，请在宿主机校准时间。"
      chrony_service_status "$chrony_service"
      pause
      return 1
    fi
    chrony_service_enable "$chrony_service"
  fi

  if ! chronyc_tracking_ready; then
    err "chrony 服务已启动，但无法读取同步状态。"
    warn "当前环境可能不允许容器主动校时，请在宿主机校准时间。"
    chrony_service_status "$chrony_service"
    pause
    return 1
  fi

  local step_out
  if step_out="$(chrony_timeout 5 chronyc -a makestep 2>&1)"; then
    ok "时间同步完成。"
  else
    warn "当前环境可能不允许容器主动校时，请在宿主机校准时间。"
    [ -n "$step_out" ] && ui_echo "$step_out"
  fi
  chrony_service_status "$chrony_service"
  pause
}

# ---------- 卸载 ----------

wireproxy_warp_environment_present() {
  [ -s /etc/wireguard/proxy.conf ] && return 0
  local_warp_socks_proxy_url >/dev/null 2>&1 && return 0
  if has_cmd pgrep && pgrep -x wireproxy >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

print_full_cleanup_hint() {
  echo
  echo "如需彻底删除脚本与相关配置，可在退出脚本后手动执行："
  echo "rm -f /root/sb.sh"
  echo "rm -f /usr/local/bin/s"
  echo "rm -rf /etc/sing-box-manager"
  echo "rm -rf /etc/sing-box"
  echo "rm -rf /var/log/sing-box"
  echo "rm -f /var/lock/singbox-manager.lock /var/lock/singbox-tg-agent.lock"
  echo "rm -rf /var/lock/singbox-tg-agent.lock.d"
}

print_wireproxy_cleanup_hint_if_present() {
  wireproxy_warp_environment_present || return 0
  echo
  echo "检测到 WireProxy/WARP 仍存在。"
  echo
  echo "如需卸载 WARP，可在退出脚本后执行："
  echo "wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
  echo "bash menu.sh u"
}

uninstall_singbox_keep_config() {
  require_root
  clear
  print_rect_title "卸载 sing-box"
  echo "该操作将停止并删除 sing-box 运行组件："
  echo "  - sing-box 服务"
  echo "  - sing-box 主程序"
  echo "  - 流量统计/日志维护定时任务"
  echo "  - TG Bot 服务与上报任务"
  echo
  echo "以下内容会保留："
  echo "  - sing-box 配置：/etc/sing-box"
  echo "  - 用户数据与 TG 配置：/etc/sing-box-manager"
  echo "  - 日志文件：/var/log/sing-box"
  echo "  - 管理脚本入口：/root/sb.sh、/usr/local/bin/s"
  echo
  ask_confirm_yes "输入 YES 确认卸载，其它任意输入取消: " || { warn "已取消卸载。"; pause; return 0; }

  sync_user_usage_counters || true
  remove_periodic_sync_cron || true
  remove_daily_maintenance_cron || true
  remove_user_watch_cron || true
  remove_log_maintain_cron || true
  remove_tg_agent_cron || true
  remove_upstream_refresh_cron || true
  rm -f "$UPSTREAM_TAG_CACHE_FILE" >/dev/null 2>&1 || true
  tg_stop_center_service || true
  tg_mark_disabled_keep_config || true
  remove_all_singbox_service_units
  # 清理官方包可能创建的系统用户/组
  if has_cmd deluser; then
    deluser --system sing-box >/dev/null 2>&1 || true
  else
    userdel sing-box >/dev/null 2>&1 || true
  fi
  if has_cmd delgroup; then
    delgroup --system sing-box >/dev/null 2>&1 || true
  else
    groupdel sing-box >/dev/null 2>&1 || true
  fi
  rm -f "$SINGBOX_BIN" /usr/bin/sing-box "$SINGBOX_VERSION_STAMP" "$GRPCURL_BIN" >/dev/null 2>&1 || true
  rm -rf /var/tmp/sb-install.* >/dev/null 2>&1 || true
  refresh_command_cache
  if pkg_installed sing-box || pkg_installed sing-box-beta; then
    case "$PKG_MANAGER" in
      apt)
        pkg_installed sing-box && apt-get remove -y sing-box >/dev/null 2>&1 || true
        pkg_installed sing-box-beta && apt-get remove -y sing-box-beta >/dev/null 2>&1 || true
        pkg_installed sing-box && apt-get purge -y sing-box >/dev/null 2>&1 || true
        pkg_installed sing-box-beta && apt-get purge -y sing-box-beta >/dev/null 2>&1 || true
        ;;
      apk)
        pkg_installed sing-box && apk del sing-box >/dev/null 2>&1 || true
        pkg_installed sing-box-beta && apk del sing-box-beta >/dev/null 2>&1 || true
        ;;
    esac
  fi
  refresh_command_cache
  ok "卸载完成，配置和用户数据已保留。"
  print_full_cleanup_hint
  print_wireproxy_cleanup_hint_if_present
  pause
}

# >>>>>>>>> END MODULE: 80_installer.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 90_protocol_menu.sh <<<<<<<<<<<
# ============================================================
# 模块: 90_protocol_menu.sh
# 职责: 协议管理菜单、安装/卸载协议、规范化接管
# 依赖: 00_base.sh, 10_config.sh, 20_protocol.sh, 30_route.sh
# ============================================================

# ---------- 协议状态摘要 ----------

protocol_status_summary() {
  local json="$1"
  local all_lines proto label ports
  all_lines="$(protocol_entry_inventory "$json")"

  for proto in "${SUPPORTED_PROTOCOLS[@]}"; do
    label="$proto"
    ports="$(printf '%s\n' "$all_lines" | awk -F '\x01' -v p="$proto" 'NF >= 3 && $2 == p { print $3 }' | sort -n | uniq | paste -sd'|' -)"

    if [ -n "$ports" ]; then
      printf '%s\t%s\t%s\n' "$label" "已安装" "$ports"
    else
      printf '%s\t%s\t%s\n' "$label" "未安装" ""
    fi
  done
}

protocol_entry_table() {
  local json="$1"
  protocol_entry_inventory "$json" | sort_tsv_by_protocol 1
}

# ---------- 规范化接管 ----------

normalize_takeover(){
  init_manager_env || { pause; return 0; }
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
    IFS=$'\x01' read -r idx oldtag proto port <<< "$line"
    target="$(entry_key_from_parts "$proto" "$port")" || continue
    target_seen["$target"]=$(( ${target_seen["$target"]:-0} + 1 ))
  done

  for line in "${inv_lines[@]}"; do
    IFS=$'\x01' read -r idx oldtag proto port <<< "$line"
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

    mapfile -t user_lines < <(echo "$work_json" | jq -r --argjson idx "$idx" '.inbounds[$idx].users // [] | to_entries[] | [.key, (.value.name // .value.username // "")] | join("\u0001")')
    mapfile -t relay_names < <(relay_list_table "$work_json" | awk -F '\x01' -v ek="$target" '$1 == ek {print $2}')

    for user_line in "${user_lines[@]}"; do
      IFS=$'\x01' read -r uidx uname <<< "$user_line"
      local is_relay=0 rn
      for rn in "${relay_names[@]}"; do
        if [ "$uname" = "$rn" ] && [ -n "$uname" ]; then
          is_relay=1
          break
        fi
      done
      if [ "$proto" != "socks" ] && [ $is_relay -eq 0 ] && [[ "$uname" != *"@"* ]]; then
        direct_candidates+=("$uidx:$uname")
      fi
    done

    if [ ${#direct_candidates[@]} -eq 1 ]; then
      direct_old="${direct_candidates[0]#*:}"
      uidx="${direct_candidates[0]%%:*}"
      if [ "$direct_old" != "$target" ]; then
        work_json="$(echo "$work_json" | jq --argjson idx "$idx" --argjson uidx "$uidx" --arg old "$direct_old" --arg new "$target" '
          if (.inbounds[$idx].users[$uidx].name? // "") == $old then
            .inbounds[$idx].users[$uidx].name = $new
          elif (.inbounds[$idx].users[$uidx].username? // "") == $old then
            .inbounds[$idx].users[$uidx].username = $new
          else . end
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

    while IFS=$'\x01' read -r _ relay_user out_tag; do
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
          (.inbounds[$idx].users // []) |= map(
            if (.name // "") == $old then .name = $new
            elif (.username // "") == $old then .username = $new
            else . end
          )
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
    done < <(relay_list_table "$work_json" | awk -F '\x01' -v ek="$target" '$1 == ek {print $1"\001"$2"\001"$3}')
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

# ---------- 协议安装菜单 ----------

prompt_password_or_return() {
  local prompt="${1:-Password（回车随机生成）: }" outvar="$2" val
  read -r -p "$prompt" val
  printf -v "$outvar" '%s' "${val:-}"
  return 0
}

prompt_ss2022_password_or_return() {
  local outvar="$1" val
  read -r -p "Password（回车随机生成）: " val
  if [ -n "${val:-}" ] && ! ss2022_prepare_password_pair "$val" >/dev/null 2>&1; then
    warn "Shadowsocks 2022 Password 必须是解码后 16 字节的 base64；如需分别设置服务端/用户密码，请使用 base64:base64。"
    return 1
  fi
  printf -v "$outvar" '%s' "${val:-}"
  return 0
}

protocol_install_menu() {
  local json="$1"
  local updated_json="$json"
  local choice_arr sel
  local -a added_node_keys=()
  local -a reality_meta_tags=()
  local -a reality_meta_pubs=()
  echo -e "\n${C}可安装协议（多个用 + 连接，如 1+3+5）:${NC}"
  echo -e "  [1] vless-reality"
  echo -e "  [2] anytls"
  echo -e "  [3] shadowsocks"
  echo -e "  [4] socks"
  echo -e "  [5] trojan"
  echo -e "  [6] vmess-ws"
  echo -e "  [7] vless-ws"
  echo -e "  [8] tuic"
  read -r -p "请输入要安装的协议编号（回车返回）: " sel
  mapfile -t choice_arr < <(parse_plus_selections "${sel:-}")
  [ ${#choice_arr[@]} -eq 0 ] && { warn "未选择任何协议，已返回上一级。"; pause; return 0; }

  local c port listen sni path priv sid entry_key inbound pub generated_pair uuid pass method server_pass user_pass username
  for c in "${choice_arr[@]}"; do
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt 8 ]; then
      warn "无效协议编号：$c，已返回上一级。"
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
        read -r -p "Private Key（回车自动生成）: " priv
        pub=""
        if [ -z "$priv" ]; then
          generated_pair="$(generate_reality_keypair_auto 2>/dev/null || true)"
          priv="${generated_pair%%$'\t'*}"
          pub="${generated_pair#*$'\t'}"
          if [ -z "$priv" ] || [ -z "$pub" ]; then
            warn "自动生成 Reality 密钥对失败，已返回上一级。"
            pause
            return 0
          fi
          param_echo "Private Key" "$priv"
          param_echo "Public Key" "$pub"
        else
          read -r -p "Public Key（必填，与 Private Key 配对，回车返回）: " pub
          if [ -z "$pub" ]; then
            warn "手动输入 Private Key 时必须同时提供 Public Key，已返回上一级。"
            pause
            return 0
          fi
        fi
        read -r -p "Short ID (回车随机生成8位hex): " sid
        if [ -z "$sid" ]; then
          sid="$(openssl rand -hex 4 2>/dev/null || true)"
          if [ -z "$sid" ]; then sid="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-8)"; fi
          param_echo "Short ID" "$sid"
        fi
        sni="$(choose_tls_domain "Reality")" || return 0
        inbound="$(build_vless_reality_inbound "$port" "$sni" "$priv" "$sid")"
        uuid="$(echo "$inbound" | jq -r '.users[0].uuid // empty')"
        param_echo "UUID" "$uuid"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        added_node_keys+=("$entry_key")
        if [ -n "$pub" ]; then
          reality_meta_tags+=("$entry_key")
          reality_meta_pubs+=("$pub")
        fi
        ;;
      2)
        ask_port_or_return "AnyTLS 端口 (默认: 443): " "443" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts anytls "$port")"
        while port_conflict_for_protocol "$updated_json" anytls "$port" "$entry_key"; do
          warn "端口 ${port} 已被占用，请更换。"
          ask_port_or_return "AnyTLS 端口 (默认: 443): " "443" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts anytls "$port")"
        done
        sni="$(choose_tls_domain "AnyTLS")" || return 0
        prompt_password_or_return "Password（回车随机生成）: " pass || { pause; return 0; }
        if ! inbound="$(build_anytls_inbound "$port" "$sni" "$pass")"; then
          err "生成 AnyTLS 配置失败：证书文件未能生成，已返回上一级。"
          pause
          return 0
        fi
        pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        param_echo "Password" "$pass"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        added_node_keys+=("$entry_key")
        ;;
      3)
        ask_port_or_return "Shadowsocks 监听端口 (默认: 8080): " "8080" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts shadowsocks "$port")"
        while port_conflict_for_protocol "$updated_json" shadowsocks "$port" "$entry_key"; do
          warn "端口 ${port} 已被同层协议占用，请更换。"
          ask_port_or_return "Shadowsocks 监听端口 (默认: 8080): " "8080" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts shadowsocks "$port")"
        done
        prompt_ss2022_password_or_return pass || { pause; return 0; }
        if ! inbound="$(build_ss_inbound "$port" "$pass")"; then
          err "生成 Shadowsocks 配置失败，已返回上一级。"
          pause
          return 0
        fi
        method="$(echo "$inbound" | jq -r '.method // empty')"
        server_pass="$(echo "$inbound" | jq -r '.password // empty')"
        user_pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        if [ -n "$server_pass" ] && [ "$server_pass" != "$user_pass" ]; then
          pass="${server_pass}:${user_pass}"
        else
          pass="$user_pass"
        fi
        param_echo "Method" "$method"
        param_echo "Password" "$pass"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        added_node_keys+=("$entry_key")
        ;;
      4)
        ask_port_or_return "SOCKS 监听端口 (默认: 1080): " "1080" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts socks "$port")"
        while port_conflict_for_protocol "$updated_json" socks "$port" "$entry_key"; do
          warn "端口 ${port} 已被同层协议占用，请更换。"
          ask_port_or_return "SOCKS 监听端口 (默认: 1080): " "1080" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts socks "$port")"
        done
        prompt_password_or_return "Password（回车随机生成）: " pass || { pause; return 0; }
        [ -n "$pass" ] || pass="$(random_b64_password 12)"
        if ! inbound="$(build_socks_inbound "$port" "$pass")"; then
          err "生成 SOCKS 配置失败，已返回上一级。"
          pause
          return 0
        fi
        username="$(echo "$inbound" | jq -r '.users[0].username // empty')"
        pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        param_echo "Username" "$username"
        param_echo "Password" "$pass"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        added_node_keys+=("$entry_key")
        ;;
      5)
        ask_port_or_return "Trojan 端口 (默认: 443): " "443" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts trojan "$port")"
        while port_conflict_for_protocol "$updated_json" trojan "$port" "$entry_key"; do
          warn "端口 ${port} 已被占用，请更换。"
          ask_port_or_return "Trojan 端口 (默认: 443): " "443" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts trojan "$port")"
        done
        sni="$(choose_tls_domain "Trojan")" || return 0
        prompt_password_or_return "Password（回车随机生成）: " pass || { pause; return 0; }
        if ! inbound="$(build_trojan_inbound "$port" "$sni" "$pass")"; then
          err "生成 Trojan 配置失败：证书文件未能生成，已返回上一级。"
          pause
          return 0
        fi
        pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        param_echo "Password" "$pass"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        added_node_keys+=("$entry_key")
        ;;
      6)
        read -r -p "vmess-ws 监听地址 (默认: 127.0.0.1): " listen; listen="${listen:-127.0.0.1}"
        ask_port_or_return "vmess-ws 监听端口 (默认: 8001): " "8001" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts vmess-ws "$port")"
        while port_conflict_for_protocol "$updated_json" vmess-ws "$port" "$entry_key"; do
          warn "端口 ${port} 已被占用，请更换。"
          ask_port_or_return "vmess-ws 监听端口 (默认: 8001): " "8001" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts vmess-ws "$port")"
        done
        read -r -p "WS Path (回车随机生成): " path; path="$(normalize_ws_path "${path:-}")"
        param_echo "WS Path" "$path"
        inbound="$(build_vmess_ws_inbound "$port" "$listen" "$path")"
        uuid="$(echo "$inbound" | jq -r '.users[0].uuid // empty')"
        param_echo "UUID" "$uuid"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        added_node_keys+=("$entry_key")
        ;;
      7)
        read -r -p "vless-ws 监听地址 (默认: 127.0.0.1): " listen; listen="${listen:-127.0.0.1}"
        ask_port_or_return "vless-ws 监听端口 (默认: 8002): " "8002" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts vless-ws "$port")"
        while port_conflict_for_protocol "$updated_json" vless-ws "$port" "$entry_key"; do
          warn "端口 ${port} 已被占用，请更换。"
          ask_port_or_return "vless-ws 监听端口 (默认: 8002): " "8002" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts vless-ws "$port")"
        done
        read -r -p "WS Path (回车随机生成): " path; path="$(normalize_ws_path "${path:-}")"
        param_echo "WS Path" "$path"
        inbound="$(build_vless_ws_inbound "$port" "$listen" "$path")"
        uuid="$(echo "$inbound" | jq -r '.users[0].uuid // empty')"
        param_echo "UUID" "$uuid"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        added_node_keys+=("$entry_key")
        ;;
      8)
        ask_port_or_return "TUIC 端口（默认443，可与TCP协议的443端口并存）: " "443" port || { warn "已返回上一级。"; pause; return 0; }
        entry_key="$(entry_key_from_parts tuic "$port")"
        while port_conflict_for_protocol "$updated_json" tuic "$port" "$entry_key"; do
          warn "端口 ${port} 已被其它 TUIC 占用，请更换。"
          ask_port_or_return "TUIC 端口（默认443，可与TCP协议的443端口并存）: " "443" port || { warn "已返回上一级。"; pause; return 0; }
          entry_key="$(entry_key_from_parts tuic "$port")"
        done
        sni="$(choose_tls_domain "TUIC")" || return 0
        prompt_password_or_return "Password（回车随机生成）: " pass || { pause; return 0; }
        if ! inbound="$(build_tuic_inbound "$port" "$sni" "$pass")"; then
          err "生成 TUIC 配置失败：证书文件未能生成，已返回上一级。"
          pause
          return 0
        fi
        uuid="$(echo "$inbound" | jq -r '.users[0].uuid // empty')"
        pass="$(echo "$inbound" | jq -r '.users[0].password // empty')"
        param_echo "UUID" "$uuid"
        param_echo "Password" "$pass"
        updated_json="$(echo "$updated_json" | jq --arg ek "$entry_key" --argjson inb "$inbound" '.inbounds |= map(select(.tag != $ek)) | .inbounds += [$inb]')"
        added_node_keys+=("$entry_key")
        ;;
    esac
  done

  updated_json="$(route_rebuild "$updated_json")"
  # 构造候选 meta：把所有 reality 公钥写进去，与 config 一起原子提交
  local candidate_meta i
  candidate_meta="$(meta_load 2>/dev/null)" || candidate_meta='{}'
  [ -n "$candidate_meta" ] || candidate_meta='{}'
  for i in "${!reality_meta_tags[@]}"; do
    candidate_meta="$(echo "$candidate_meta" | jq \
      --arg t "${reality_meta_tags[$i]}" --arg pk "${reality_meta_pubs[$i]}" \
      '.[$t] = ((.[$t] // {}) + {public_key:$pk, private_key_auto_generated:true})')" || {
      err "构造 reality meta 失败。"
      pause
      return 1
    }
  done
  local _install_ok=0
  if user_db_exists; then
    local db_json node_key
    sync_user_usage_counters || true
    db_json="$(user_db_load)"
    for node_key in "${added_node_keys[@]}"; do
      db_json="$(user_db_on_node_added "$db_json" "$node_key")"
    done
    if _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes "$db_json" "$updated_json" "$candidate_meta"; then
      _install_ok=1
    else
      warn "协议安装/更新失败，已返回上一级。"
    fi
  else
    if _CONFIG_APPLY_QUIET_OK=1 config_and_meta_apply "$updated_json" "$candidate_meta"; then
      _install_ok=1
    else
      warn "协议安装/更新失败，已返回上一级。"
    fi
  fi
  if [ "$_install_ok" -eq 1 ]; then
    ok "协议已安装/更新。"
  fi
  pause
  return 0
}

# ---------- 协议卸载菜单 ----------

protocol_remove_menu() {
  local json="$1"
  local lines=() choice_arr updated_json="$json" c entry_key related sel
  mapfile -t lines < <(protocol_entry_table "$json")
  if [ ${#lines[@]} -eq 0 ]; then
    warn "当前没有可卸载的协议。"
    pause
    return 0
  fi
  echo -e "\n${R}已安装协议如下（多个用 + 连接，如 1+2）:${NC}"
  local i=1
  for line in "${lines[@]}"; do
    IFS=$'\x01' read -r entry_key type port <<< "$line"
    echo -e " [$i] ${entry_key}"
    i=$((i+1))
  done
  read -r -p "请输入要卸载的协议编号（回车返回）: " sel
  mapfile -t choice_arr < <(parse_plus_selections "${sel:-}")
  [ ${#choice_arr[@]} -eq 0 ] && { warn "未选择任何协议。"; pause; return 0; }

  for c in "${choice_arr[@]}"; do
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#lines[@]}" ]; then
      warn "无效协议编号：$c，已返回上一级。"
      pause
      return 0
    fi
  done

  local _cert_files_to_clean=()
  for c in "${choice_arr[@]}"; do
    IFS=$'\x01' read -r entry_key _ <<< "${lines[$((c-1))]}"
    related="$(relay_list_table "$updated_json" | awk -F '\x01' -v ek="$entry_key" '{u=$2; sub(/@.*/, "", u)} $1 == ek {print u}' | awk 'NF' | sort -u)" || {
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
    local _crt _key
    _crt="$(echo "$updated_json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.certificate_path // empty' | head -n1)"
    _key="$(echo "$updated_json" | jq -r --arg ek "$entry_key" '.inbounds[]? | select((.tag // "") == $ek) | .tls.key_path // empty' | head -n1)"
    [ -n "$_crt" ] && [[ "$_crt" == /etc/sing-box/* ]] && _cert_files_to_clean+=("$_crt")
    [ -n "$_key" ] && [[ "$_key" == /etc/sing-box/* ]] && _cert_files_to_clean+=("$_key")
    updated_json="$(remove_inbound_by_entry_key "$updated_json" "$entry_key")" || {
      err "删除协议失败，已中止，未写入配置。"
      pause
      return 1
    }
  done

  updated_json="$(route_rebuild "$updated_json")" || {
    err "重建路由失败，已中止，未写入配置。"
    pause
    return 1
  }
  local _apply_ok=0
  if user_db_exists; then
    local db_json
    sync_user_usage_counters || true
    db_json="$(user_db_load)"
    if _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes "$db_json" "$updated_json"; then
      _apply_ok=1
    else
      warn "协议卸载失败，已返回上一级。"
    fi
  else
    if _CONFIG_APPLY_QUIET_OK=1 config_apply "$updated_json"; then
      _apply_ok=1
    else
      warn "协议卸载失败，已返回上一级。"
    fi
  fi
  if [ "$_apply_ok" -eq 1 ] && [ ${#_cert_files_to_clean[@]} -gt 0 ]; then
    for _f in "${_cert_files_to_clean[@]}"; do
      rm -f "$_f" >/dev/null 2>&1 || true
    done
  fi
  [ "$_apply_ok" -eq 1 ] && ok "协议已卸载。"
  pause
  return 0
}

# ---------- 协议管理主菜单 ----------

protocol_manager() {
  init_manager_env || { pause; return 0; }
  while true; do
    clear
    local json
    json="$(config_load)"
    print_rect_title "协议管理"
    local _proto_tmp
    _proto_tmp="$(mktemp)"
    if protocol_status_summary "$json" >"$_proto_tmp" && [ -s "$_proto_tmp" ]; then
      local proto_width=15 proto_pad status_color port_text
      echo -e "${C}当前状态${NC}"
      echo -e "${B}--------------------------------------------------------${NC}"
      while IFS=$'\t' read -r proto status ports; do
        proto_pad=$(printf "%-${proto_width}s" "$proto")
        if [ "$status" = "已安装" ]; then
          status_color="$G"
        else
          status_color="$Y"
        fi
        if [ -n "$ports" ]; then
          port_text="（端口${ports//|/|端口}）"
          printf "  - %b%s%b  %b【%s】%b%b%s%b\n" "$W" "$proto_pad" "$NC" "$status_color" "$status" "$NC" "$C" "$port_text" "$NC"
        else
          printf "  - %b%s%b  %b【%s】%b\n" "$W" "$proto_pad" "$NC" "$status_color" "$status" "$NC"
        fi
      done < "$_proto_tmp"
    else
      echo -e "${Y}当前没有任何协议。${NC}"
    fi
    rm -f "$_proto_tmp" >/dev/null 2>&1 || true
    echo -e "${B}--------------------------------------------------------${NC}"
    echo -e "  ${C}1.${NC} 安装协议"
    echo -e "  ${C}2.${NC} 卸载协议"
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

# ---------- 其它工具入口 ----------

clear_config_json() {
  init_manager_env || { pause; return 0; }
  clear
  echo -e "${Y}--- 清空/重置配置文件 ---${NC}"
  echo -e "${Y}注意：该操作将清空当前 config.json。${NC}"
  ask_confirm_yes || { warn "已取消清空/重置。"; pause; return 0; }
  # 原子提交：config 重置 + meta 删 .warp/.relay 在同一把锁内一起做，避免分裂
  local empty_config empty_meta
  empty_config="$(config_min_template)"
  empty_meta="$(meta_load 2>/dev/null | jq 'del(.warp, .relay)' 2>/dev/null)"
  [ -n "$empty_meta" ] || empty_meta='{}'
  if config_and_meta_apply "$empty_config" "$empty_meta"; then
    ok "配置已清空，分流状态已重置。"
  else
    err "配置或分流状态清空失败。"
  fi
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

view_config_formatted() {
  init_manager_env || { pause; return 0; }
  clear
  echo -e "${C}--- 查看格式化配置 ---${NC}"
  sing-box format -c "$CONFIG_FILE" || err "sing-box format 执行失败。"
  echo ""
  pause
}

singbox_status_summary() {
  local _status _version _state _upstream _suffix
  case "$INIT_SYSTEM" in
    systemd)
      _state="$(systemctl is-active sing-box 2>/dev/null || true)"
      case "$_state" in
        active) _status="${G}运行中${NC}" ;;
        failed) _status="${Y}异常${NC}" ;;
        activating) _status="${Y}启动中${NC}" ;;
        *) _status="${R}已停止${NC}" ;;
      esac
      ;;
    openrc)
      _state="$(rc-service sing-box status 2>&1 || true)"
      case "$_state" in
        *crashed*) _status="${Y}异常${NC}" ;;
        *started*|*running*) _status="${G}运行中${NC}" ;;
        *stopped*) _status="${R}已停止${NC}" ;;
        *)
          if singbox_service_active; then
            _status="${G}运行中${NC}"
          else
            _status="${R}已停止${NC}"
          fi
          ;;
      esac
      ;;
    *)
      if singbox_service_active; then
        _status="${G}运行中${NC}"
      else
        _status="${R}已停止${NC}"
      fi
      ;;
  esac
  _version=""
  if [ -x "$SINGBOX_BIN" ]; then
    _version="$("$SINGBOX_BIN" version 2>/dev/null | awk '/^sing-box version / {print $3; exit}')"
  fi
  [ -n "$_version" ] || _version="未知"

  _suffix=""
  _upstream="$(get_cached_upstream_version 2>/dev/null || true)"
  if [ "$_version" != "未知" ] && [ -n "$_upstream" ]; then
    if [ "$_version" != "$_upstream" ] && version_ge "$_upstream" "$_version"; then
      _suffix="  ${Y}(有新版 ${_upstream})${NC}"
    fi
  elif [ "$_version" != "未知" ] && [ -z "$_upstream" ]; then
    _suffix="  ${Y}(新版检测: 未知)${NC}"
  fi

  printf '  %bsing-box%b : %b  版本 %b%s%b%b\n' "$W" "$NC" "$_status" "$G" "$_version" "$NC" "$_suffix"
}

singbox_start() {
  clear
  print_rect_title "启动 sing-box"
  case "$INIT_SYSTEM" in
    systemd)
      if systemctl start sing-box; then
        sleep 1
        if systemctl is-active --quiet sing-box 2>/dev/null; then
          ok "sing-box 已启动并正常运行。"
        else
          err "启动命令已执行，但服务未能正常运行，请检查配置或日志。"
        fi
      else
        err "启动失败，请检查配置或日志。"
      fi
      ;;
    openrc)
      if openrc_start_service sing-box >/dev/null 2>&1; then
        sleep 1
        if openrc_service_running sing-box; then
          ok "sing-box 已启动并正常运行。"
        else
          err "启动命令已执行，但服务未能正常运行，请检查配置或日志。"
        fi
      else
        err "启动失败，请检查配置或日志。"
      fi
      ;;
    *) err "未识别的 init 系统，无法启动 sing-box。" ;;
  esac
  echo ""
  pause
}

singbox_stop() {
  clear
  print_rect_title "停止 sing-box"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl stop sing-box && ok "sing-box 已停止。" || err "停止失败。"
      ;;
    openrc)
      openrc_stop_service sing-box >/dev/null 2>&1 && ok "sing-box 已停止。" || err "停止失败。"
      ;;
    *) err "未识别的 init 系统，无法停止 sing-box。" ;;
  esac
  echo ""
  pause
}

system_tools_menu() {
  while true; do
    clear
    print_rect_title "系统工具"
    singbox_status_summary
    cron_job_status_line "实时同步" "$PERIODIC_SYNC_CRON_MARK"
    cron_job_status_line "日常维护" "$DAILY_MAINTENANCE_CRON_MARK"
    echo -e "${B}----------------------------------------${NC}"
    echo -e "  ${C}1.${NC} 启动 sing-box"
    echo -e "  ${C}2.${NC} 停止 sing-box"
    echo -e "  ${C}3.${NC} 查看 sing-box 实时日志"
    echo -e "  ${C}4.${NC} 查看 config 配置文件"
    echo -e "  ${C}5.${NC} 清空/重置 config 配置文件"
    echo -e "  ${C}6.${NC} 一键校准系统时间"
    echo -e "  ${C}7.${NC} 规范化接管旧配置"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) singbox_start ;;
      2) singbox_stop ;;
      3) view_realtime_log ;;
      4) view_config_formatted ;;
      5) clear_config_json ;;
      6) sync_system_time_chrony ;;
      7) normalize_takeover ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

# >>>>>>>>> END MODULE: 90_protocol_menu.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 99_main.sh <<<<<<<<<<<
# ============================================================
# 模块: 99_main.sh
# 职责: 主菜单 + CLI 入口路由
# 依赖: 所有其它模块
# ============================================================

main_menu() {
  ensure_local_script_entrypoint_once
  while true; do
    clear
    print_rect_title "Sing-box Elite 管理系统  V${SCRIPT_VERSION}"
    singbox_status_summary
    echo -e "${B}--------------------------------------------------------${NC}"
    echo -e "  ${C}1.${NC} 安装/更新 sing-box"
    echo -e "  ${C}2.${NC} 系统工具"
    echo -e "  ${C}3.${NC} 协议管理"
    echo -e "  ${C}4.${NC} 中转管理"
    echo -e "  ${C}5.${NC} warp分流"
    echo -e "  ${C}6.${NC} 导出节点配置"
    echo -e "  ${C}7.${NC} 用户管理"
    echo -e "  ${C}8.${NC} 卸载 sing-box"
    echo -e "  ${R}0.${NC} 退出系统"
    echo -e "${B}--------------------------------------------------------${NC}"
    read -r -p "请选择操作指令: " opt
    case "${opt:-}" in
      1) install_or_update_singbox ;;
      2) system_tools_menu || true ;;
      3) protocol_manager || true ;;
      4) manage_relay_nodes || true ;;
      5) warp_manager_menu || true ;;
      6) export_configs || true ;;
      7) user_manager_menu || true ;;
      8) uninstall_singbox_keep_config ;;
      0|q|Q) exit 0 ;;
      *) warn "无效输入：$opt"; sleep 1 ;;
    esac
  done
}

# ====================================================
# CLI 入口路由
# ====================================================
if [[ "${1:-}" == "--periodic-sync" ]]; then
  periodic_sync_run
  exit 0
fi

if [[ "${1:-}" == "--daily-maintenance" ]]; then
  daily_maintenance_run
  exit 0
fi

# 6.0.8 及以前的 4 个老入口已合并到上面两个 runner。
# 保留为静默墓志铭，避免老 cron 跑过来掉进 main_menu 死循环 / 刷邮箱。
# is_install_complete 探针会在用户进 1.安装/更新 时引导清理这些老 cron。
if [[ "${1:-}" == "--user-watch" ]] || [[ "${1:-}" == "--maintain-logs" ]] || \
   [[ "${1:-}" == "--tg-agent-sync" ]] || [[ "${1:-}" == "--refresh-upstream" ]]; then
  exit 0
fi

main_menu

# >>>>>>>>> END MODULE: 99_main.sh <<<<<<<<<<<
