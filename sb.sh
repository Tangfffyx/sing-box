#!/usr/bin/env bash

# ============================================================
# Sing-box Management System
# 由 build.sh 自动合并生成，请勿直接编辑此文件
# 源码位于 lib/ 与 py/ 目录
# ============================================================


# >>>>>>>>> BEGIN MODULE: 00_base.sh <<<<<<<<<<<
# ============================================================
# 模块: 00_base.sh
# 职责: 全局常量、颜色码、UI 基础函数、协议注册表、共享 jq 模板
# ============================================================

set -Eeuo pipefail

# -------------------- 版本 --------------------
SCRIPT_VERSION="7.0.0"

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
C='\033[1;36m'; NC='\033[0m'; W='\033[1;37m'; D='\033[2m'

# -------------------- 日志/UI 函数 --------------------
say()  { echo -e "${C}•${NC} $*"; }
ok()   { echo -e "${G}✓${NC} $*"; }
warn() { echo -e "${Y}!${NC} $*" >&2; }
err()  { echo -e "${R}✗${NC} $*" >&2; }
pause(){ read -r -n 1 -p "按任意键继续..." || true; echo ""; }
ui_echo(){ printf '%b\n' "$*" >&2; }

ui_hr() {
  printf '%b%s%b\n' "$D" "──────────────────────────────────────────────────────" "$NC"
}

ui_section() {
  printf '\n  %b%s%b\n' "$W" "$1" "$NC"
}

# 生成轻量可视化进度条（默认 10 格，如 ████░░░░░░）
ui_mini_bar() {
  local percent="${1:-0}" width="${2:-10}" filled empty
  [[ "$percent" =~ ^[0-9]+$ ]] || percent=0
  (( percent < 0 )) && percent=0
  (( percent > 100 )) && percent=100
  filled=$(( (percent * width + 50) / 100 ))
  (( filled > width )) && filled=$width
  empty=$(( width - filled ))
  local bar_f="" bar_e="" i
  for ((i=0; i<filled; i++)); do bar_f+="█"; done
  for ((i=0; i<empty; i++)); do bar_e+="░"; done
  printf '%s%s' "$bar_f" "$bar_e"
}

ui_step() {
  local cur="$1" total="$2" msg="$3"
  printf '%b[%s/%s]%b %s\n' "$C" "$cur" "$total" "$NC" "$msg"
}

# 为耗时命令提供旋转进度提示 + 已用秒数，避免假死感。
# 非交互终端（如 cron/管道/测试）自动降级为直接执行，不输出控制字符。
run_with_spinner() {
  local label="$1"
  shift
  if [ ! -t 1 ] || [ ! -t 2 ]; then
    "$@"
    return $?
  fi

  local tmp_out pid rc start_ts now_ts elapsed tick=0
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  tmp_out="$(mktemp /tmp/sb-spin.XXXXXX)" || { "$@"; return $?; }
  start_ts="$(date +%s)"

  "$@" >"$tmp_out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    now_ts="$(date +%s)"
    elapsed=$((now_ts - start_ts))
    if [ "$elapsed" -gt 0 ]; then
      printf '\r%b%s%b %s %b(%ds)%b\033[K' "$C" "${frames[$((tick % 10))]}" "$NC" "$label" "$D" "$elapsed" "$NC" >&2
    else
      printf '\r%b%s%b %s\033[K' "$C" "${frames[$((tick % 10))]}" "$NC" "$label" >&2
    fi
    tick=$((tick + 1))
    sleep 0.12 2>/dev/null || sleep 1
  done

  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi
  now_ts="$(date +%s)"
  elapsed=$((now_ts - start_ts))
  printf '\r\033[K' >&2

  if [ "$rc" -eq 0 ]; then
    if [ "$elapsed" -ge 1 ]; then
      printf '%b✓%b %s %b(%ds)%b\n' "$G" "$NC" "$label" "$D" "$elapsed" "$NC" >&2
    else
      printf '%b✓%b %s\n' "$G" "$NC" "$label" >&2
    fi
  else
    printf '%b✗%b %s\n' "$R" "$NC" "$label" >&2
    if [ -s "$tmp_out" ]; then
      tail -n 20 "$tmp_out" | sed 's/^/  /' >&2
    fi
  fi
  rm -f "$tmp_out" >/dev/null 2>&1 || true
  return "$rc"
}

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
  local inner_width=52
  local title_width pad left right line

  title_width=$(text_display_width "$title")
  pad=$(( inner_width - title_width ))
  (( pad < 0 )) && pad=0

  left=$(( pad / 2 ))
  right=$(( pad - left ))

  line=""
  local i
  for ((i=0; i<inner_width; i++)); do line+="─"; done

  printf "%b╭%s╮%b\n" "$C" "$line" "$NC"
  printf "%b│%b%*s%b%s%b%*s%b│%b\n" "$C" "$NC" "$left" "" "$W" "$title" "$NC" "$right" "" "$C" "$NC"
  printf "%b╰%s╯%b\n" "$C" "$line" "$NC"
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
SUPPORTED_PROTOCOLS=(hysteria2 vless-reality anytls shadowsocks socks tuic trojan vmess-ws vless-ws)

declare -A PROTO_PREFIX=(
  [vless-reality]=reality
  [anytls]=anytls
  [hysteria2]=hy2
  [shadowsocks]=ss
  [trojan]=trojan
  [vmess-ws]=vmess-ws
  [vless-ws]=vless-ws
  [tuic]=tuic
  [socks]=socks
)

declare -A PROTO_DESC=(
  [vless-reality]="推荐，免域名抗封锁"
  [anytls]="轻量抗特征，适合新客户端"
  [hysteria2]="UDP 加速，适合高丢包线路"
  [shadowsocks]="SS2022，简单高速"
  [socks]="SOCKS5 代理，常用于中转落地"
  [trojan]="经典伪装，兼容性好"
  [vmess-ws]="配合 CDN / 反代域名使用"
  [vless-ws]="配合 CDN / 反代域名使用"
  [tuic]="QUIC 低延迟 UDP 协议"
)

declare -A PREFIX_TO_PROTO=()
for proto in "${SUPPORTED_PROTOCOLS[@]}"; do
  PREFIX_TO_PROTO["${PROTO_PREFIX[$proto]}"]="$proto"
done
unset proto

declare -A PROTO_TRANSPORT=(
  [vless-reality]=tcp
  [anytls]=tcp
  [hysteria2]=udp
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
  elif .type == "hysteria2" then "hysteria2"
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
  if ($tag | startswith("hy2-")) then 0
  elif ($tag | startswith("reality-")) then 1
  elif ($tag | startswith("anytls-")) then 2
  elif ($tag | startswith("ss-")) then 3
  elif ($tag | startswith("socks-")) then 4
  elif ($tag | startswith("tuic-")) then 5
  elif ($tag | startswith("trojan-")) then 6
  elif ($tag | startswith("vmess-ws-")) then 7
  elif ($tag | startswith("vless-ws-")) then 8
  else 99
  end;
'

# 组合：常用 jq 前缀（包含所有共享定义）
JQ_SHARED="${JQ_DETECT_PROTOCOL}${JQ_AUTH_USERS}${JQ_NODE_PART}${JQ_PROTOCOL_SORT}"

# 由注册表派生排序定义，覆盖上面作为 bash 3 回退保留的静态版本；
# 新增协议只需改 SUPPORTED_PROTOCOLS/PROTO_PREFIX，排序自动跟随。
# 注意：这段必须在 JQ_SHARED= 之后，tests/reliability.sh 在 bash 3 下只截取
# JQ_DETECT_PROTOCOL 到 JQ_SHARED 之间的静态定义，不会执行到这里。
{
  _jq_sort_lines=('def protocol_sort_index($tag):')
  _jq_sort_i=0
  for _jq_sort_proto in "${SUPPORTED_PROTOCOLS[@]}"; do
    _jq_sort_prefix="${PROTO_PREFIX[$_jq_sort_proto]}"
    if [ "$_jq_sort_i" -eq 0 ]; then _jq_sort_kw='if'; else _jq_sort_kw='elif'; fi
    _jq_sort_lines+=("  ${_jq_sort_kw} (\$tag | startswith(\"${_jq_sort_prefix}-\")) then ${_jq_sort_i}")
    _jq_sort_i=$((_jq_sort_i + 1))
  done
  _jq_sort_lines+=('  else 99' '  end;')
  JQ_PROTOCOL_SORT="$(printf '%s\n' "${_jq_sort_lines[@]}")"
  JQ_SHARED="${JQ_DETECT_PROTOCOL}${JQ_AUTH_USERS}${JQ_NODE_PART}${JQ_PROTOCOL_SORT}"
  unset _jq_sort_lines _jq_sort_i _jq_sort_proto _jq_sort_prefix _jq_sort_kw
}

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
  local url="$1" output="$2" connect_timeout="${3:-20}" retry_count="${4:-3}" label="${5:-正在下载}"
  if [ ! -t 1 ] || [ ! -t 2 ]; then
    curl -fsSL --connect-timeout "$connect_timeout" --retry "$retry_count" "$url" -o "$output" >/dev/null 2>&1
    return $?
  fi

  local total tmp_err curl_pid rc size prev_size=0 speed=0 tick=0
  printf '\r%b⠋%b %s（连接中...）\033[K' "$C" "$NC" "$label" >&2
  total="$(download_file_total_bytes "$url" "$connect_timeout")"
  tmp_err="$(mktemp /tmp/sb-download-err.XXXXXX)" || return 1
  rm -f "$output" >/dev/null 2>&1 || true

  curl -fsSL --connect-timeout "$connect_timeout" --retry "$retry_count" "$url" -o "$output" 2>"$tmp_err" &
  curl_pid=$!
  while kill -0 "$curl_pid" 2>/dev/null; do
    size="$(file_size_bytes "$output")"
    if [ "$size" -ge "$prev_size" ]; then
      speed=$((size - prev_size))
    else
      speed=0
    fi
    prev_size="$size"
    print_download_progress "$size" "$total" "$tick" "$speed" "$label"
    tick=$((tick + 1))
    sleep 1
  done

  if wait "$curl_pid"; then
    rc=0
  else
    rc=$?
  fi

  clear_download_progress
  if [ "$rc" -eq 0 ]; then
    size="$(file_size_bytes "$output")"
    printf '%b✓%b %s完成 %b(%s)%b\n' "$G" "$NC" "$label" "$D" "$(format_download_bytes "$size")" "$NC" >&2
  else
    printf '%b✗%b %s失败\n' "$R" "$NC" "$label" >&2
    if [ -s "$tmp_err" ]; then
      sed 's/^/  /' "$tmp_err" >&2
    fi
  fi
  rm -f "$tmp_err" >/dev/null 2>&1 || true
  return "$rc"
}

download_file_total_bytes() {
  local url="$1" connect_timeout="${2:-20}" total
  [ "$connect_timeout" -gt 5 ] && connect_timeout=5
  total="$(curl -fsSIL --connect-timeout "$connect_timeout" --max-time 8 "$url" 2>/dev/null \
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
    if (b >= 1073741824) printf "%.1f GB", b / 1073741824;
    else if (b >= 1048576) printf "%.1f MB", b / 1048576;
    else if (b >= 1024) printf "%.1f KB", b / 1024;
    else printf "%d B", b;
  }'
}

print_download_progress() {
  local size="${1:-0}" total="${2:-0}" tick="${3:-0}" speed="${4:-0}" label="${5:-正在下载}" width=22
  local percent filled empty bar="" i speed_txt=""
  if [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -gt 0 ]; then
    speed_txt="  $(format_download_bytes "$speed")/s"
  fi
  if [[ "$total" =~ ^[0-9]+$ ]] && [ "$total" -gt 0 ]; then
    percent=$((size * 100 / total))
    [ "$percent" -gt 100 ] && percent=100
    filled=$((percent * width / 100))
    empty=$((width - filled))
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    printf '\r%b%s%b [%b%s%b] %3d%%  %s / %s%s\033[K' \
      "$C" "$label" "$NC" "$G" "$bar" "$NC" "$percent" \
      "$(format_download_bytes "$size")" "$(format_download_bytes "$total")" "$speed_txt" >&2
  else
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    printf '\r%b%s%b %s  %s%s\033[K' \
      "$C" "${frames[$((tick % 10))]}" "$NC" "$label" "$(format_download_bytes "$size")" "$speed_txt" >&2
  fi
}

clear_download_progress() {
  printf '\r\033[K' >&2
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
  local prompt="${1:-输入 yes 确认继续（直接回车取消）: }"
  local ans
  printf '%s' "$prompt" >&2
  read -r ans || ans=""
  [[ "${ans,,}" == "yes" ]]
}

ask_confirm_yn() {
  local prompt="${1:-确认继续吗？[y/N]: }"
  local ans
  printf '%s' "$prompt" >&2
  read -r ans || ans=""
  [[ "$ans" =~ ^[Yy]$ ]]
}

ask_confirm_default_yes() {
  local prompt="${1:-是否继续？[Y/n]: }"
  local ans
  printf '%s' "$prompt" >&2
  read -r ans || ans=""
  [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]
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
  local val
  while true; do
    read -r -p "$prompt" val || return 1
    if [ "$val" = "0" ] || [ "${val,,}" = "q" ]; then
      return 1
    fi
    if [ -z "$val" ]; then
      val="$default"
    fi
    if is_valid_port "$val"; then
      printf -v "$outvar" '%s' "$val"
      return 0
    fi
    warn "端口无效（请输入 1-65535，回车默认 ${default}，输入 0 返回）"
  done
}

json_is_object() {
  local s="${1:-}"
  [ -n "$s" ] && printf '%s' "$s" | jq -e 'type=="object"' >/dev/null 2>&1
}

backup_corrupt_json_file() {
  local path="$1" ts backup
  [ -s "$path" ] || return 0
  ts="$(date +%Y%m%d_%H%M%S)"
  backup="${path}.corrupt.${ts}"
  if [ ! -e "$backup" ]; then
    cp -a "$path" "$backup" 2>/dev/null || true
    warn "检测到文件格式损坏，已自动备份到：${backup}" >&2
  fi
}

atomic_write_json_file() {
  local target="$1" json="$2" label="${3:-数据文件}"
  local dir tmp_file
  dir="$(dirname "$target")"
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  tmp_file="$(mktemp "${target}.tmp.XXXXXX")" || return 1
  if printf '%s\n' "$json" | jq . > "$tmp_file"; then
    chmod 600 "$tmp_file" 2>/dev/null || true
    if ! mv -f "$tmp_file" "$target"; then
      err "${label}写入失败：${target}"
      rm -f "$tmp_file" >/dev/null 2>&1 || true
      return 1
    fi
    chmod 600 "$target" 2>/dev/null || true
    return 0
  fi
  rm -f "$tmp_file" >/dev/null 2>&1 || true
  err "${label}格式无效，已放弃写入。"
  return 1
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
  if [ -s "$CONFIG_FILE" ]; then
    if jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
      config_normalize "$(cat "$CONFIG_FILE")"
      return 0
    fi
    backup_corrupt_json_file "$CONFIG_FILE"
  fi
  config_min_template | config_migrate_114
}

config_ensure_exists() {
  mkdir -p /etc/sing-box
  chmod 700 /etc/sing-box 2>/dev/null || true
  if [ ! -e "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
    config_min_template | config_migrate_114 > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    return 0
  fi

  if ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
    backup_corrupt_json_file "$CONFIG_FILE"
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
      if manager_recover_pending && "$@"; then _rc=0; else _rc=$?; fi
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

manager_transaction_begin() {
  local pending="$USER_DB_FILE.pending" snapshot entry path
  snapshot="$(mktemp -d "$pending.new.XXXXXX")" || return 1
  for entry in db config meta; do
    path="$(manager_transaction_path "$entry")"
    if [ -e "$path" ] || [ -L "$path" ]; then
      cp -p "$path" "$snapshot/$entry" || { rm -rf "$snapshot"; return 1; }
    fi
  done
  if singbox_service_active; then
    touch "$snapshot/service-active" || { rm -rf "$snapshot"; return 1; }
  fi
  mv "$snapshot" "$pending" || { rm -rf "$snapshot"; return 1; }
}

manager_transaction_path() {
  case "$1" in
    db) printf '%s\n' "$USER_DB_FILE" ;;
    config) printf '%s\n' "$CONFIG_FILE" ;;
    meta) printf '%s\n' "$META_FILE" ;;
  esac
}

manager_transaction_end() {
  local pending="$USER_DB_FILE.pending" completed
  completed="$(mktemp -d "$pending.done.XXXXXX")" || return 1
  mv "$pending" "$completed/snapshot" || return 1
  rm -rf "$completed" || true
}

manager_recover_pending() {
  [ -n "${USER_DB_FILE:-}" ] || return 0
  local pending="$USER_DB_FILE.pending" entry path tmp
  [ -d "$pending" ] || return 0
  warn "发现未完成的用户变更，正在恢复上一次配置和账本。"
  if [ -f "$pending/config" ] || [ -e "$CONFIG_FILE" ]; then
    if ! cmp -s "$pending/config" "$CONFIG_FILE"; then
      touch "$pending/runtime-changed" || return 1
    fi
  fi
  for entry in config meta db; do
    path="$(manager_transaction_path "$entry")"
    if [ -f "$pending/$entry" ]; then
      tmp="$(mktemp "$path.restore.XXXXXX")" || return 1
      if ! cp -p "$pending/$entry" "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        err "恢复失败，请检查 ${path}。备份保留在 ${pending}。"
        return 1
      fi
    else
      rm -f "$path" || return 1
    fi
  done
  if [ -f "$pending/ws-origin-host" ] && ! ws_cdn_restore_pending "$pending"; then
    err "反代恢复未完成，备份已保留，请检查 Nginx 后再试。"
    return 1
  fi
  if [ -f "$pending/runtime-changed" ]; then
    if [ -f "$pending/service-active" ]; then
      if ! reload_or_restart_singbox_safe; then
        err "已恢复磁盘数据，服务尚未就绪。请检查 sing-box 后重试。"
        return 1
      fi
    elif singbox_service_active; then
      case "$INIT_SYSTEM" in
        systemd) systemctl stop sing-box || return 1 ;;
        openrc) openrc_stop_service sing-box || return 1 ;;
        *) return 1 ;;
      esac
    fi
  fi
  manager_transaction_end
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
    | ($final == "" or ([(.outbounds[]?, .endpoints[]?) | (.tag // "")] | index($final) != null))
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
    err "新配置检查未通过，已保留原配置（原因如下）："
    sing-box check -c "$tmp_file" 2>&1 | sed 's/^/  /'
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  fi

  local ts backup prev_tmp
  ts="$(date +%Y%m%d_%H%M%S)"
  backup="${CONFIG_FILE}.bak.fail.$ts"
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

  if [ -t 1 ] && [ -t 2 ] && [ "${_RESTART_SINGBOX_QUIET_OK:-0}" != "1" ]; then
    if run_with_spinner "正在重启 sing-box 服务并等待就绪..." reload_or_restart_singbox_safe; then
      case "$INIT_SYSTEM" in
        systemd) systemctl enable sing-box >/dev/null 2>&1 || true ;;
        openrc)  openrc_enable_service sing-box default >/dev/null 2>&1 || true ;;
      esac
      rm -f "$prev_tmp" >/dev/null 2>&1 || true
      ls -1t "${CONFIG_FILE}".bak.fail.* 2>/dev/null | tail -n +2 | xargs rm -f -- 2>/dev/null || true
      [ "${_CONFIG_APPLY_QUIET_OK:-0}" = "1" ] || ok "配置已生效。"
      return 0
    fi
  elif _RESTART_SINGBOX_QUIET_OK=1 reload_or_restart_singbox_safe; then
    case "$INIT_SYSTEM" in
      systemd) systemctl enable sing-box >/dev/null 2>&1 || true ;;
      openrc)  openrc_enable_service sing-box default >/dev/null 2>&1 || true ;;
    esac
    rm -f "$prev_tmp" >/dev/null 2>&1 || true
    # 自动清理旧备份，保留最近 1 个
    ls -1t "${CONFIG_FILE}".bak.fail.* 2>/dev/null | tail -n +2 | xargs rm -f -- 2>/dev/null || true
    [ "${_CONFIG_APPLY_QUIET_OK:-0}" = "1" ] || ok "配置已生效。"
    return 0
  fi

  err "新配置启动失败，正在自动恢复原配置..."
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
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$key_path" -out "$crt_path" -days 36500 -nodes -subj "/CN=${cn}" >/dev/null 2>&1 || return 1
  [ -s "$crt_path" ] && [ -s "$key_path" ]
}

# 自签证书（按 <前缀>-<端口> 命名，如 hy2-443.crt）：设置 _TLS_CRT/_TLS_KEY，失败返回 1。
# AnyTLS/Trojan/TUIC/Hysteria2 共用同一套逻辑，证书文件一眼能看出属于哪个节点。
tls_cert_for_prefix() {
  local prefix="$1" port="$2" sni="$3"
  _TLS_CRT="/etc/sing-box/${prefix}-${port}.crt"
  _TLS_KEY="/etc/sing-box/${prefix}-${port}.key"
  local cert_public key_public
  if openssl x509 -in "$_TLS_CRT" -checkend 0 -noout >/dev/null 2>&1 &&
    cert_public="$(openssl x509 -in "$_TLS_CRT" -pubkey -noout 2>/dev/null)" &&
    key_public="$(openssl pkey -in "$_TLS_KEY" -pubout 2>/dev/null)" &&
    [ "$cert_public" = "$key_public" ]; then
    return 0
  fi
  ensure_self_signed_cert "$sni" "$_TLS_CRT" "$_TLS_KEY"
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

# Self-signed listeners have a stable SNI. Only Reality contacts a handshake host.
SELF_SIGNED_SNI="sing-box.local"
REALITY_DEFAULT_HANDSHAKE="www.microsoft.com"

protocol_password_urlsafe() (
  set -o pipefail
  openssl rand -base64 16 | tr '/+' '_-' | tr -d '=\n'
)

reality_handshake_check() {
  local name="$1" result
  [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$name" == *.* ]] || return 1
  result="$(run_with_timeout 8 openssl s_client -connect "${name}:443" -servername "$name" \
    -verify_hostname "$name" -verify_return_error -tls1_3 -alpn h2 </dev/null 2>&1)" || return 1
  grep -q 'ALPN protocol: h2' <<< "$result"
}

reality_public_key_from_private() (
  set -o pipefail
  local private="$1"
  [[ "$private" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
  # RFC 8410 PKCS#8 wrapper for a raw 32-byte X25519 private key.
  { printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040'
    printf '%s=' "$private" | tr '_-' '/+' | openssl base64 -d -A
  } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null |
    tail -c 32 | openssl base64 -A | tr '/+' '_-' | tr -d '=\n'
)

# ---------- SS 密码规范化 ----------

ss2022_normalize_password_pair() {
  local raw="$1"
  local sp up
  if [ -z "$raw" ]; then
    sp="$(openssl rand -base64 16)" || return 1
    up="$(openssl rand -base64 16)" || return 1
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
    sp="$(openssl rand -base64 16)" || return 1
    up="$(openssl rand -base64 16)" || return 1
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
  uuid="$(sing-box generate uuid)" || return 1
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
  [ -n "$pass" ] || pass="$(protocol_password_urlsafe)" || return 1
  tls_cert_for_prefix "anytls" "$port" "$sni" || return 1
  crt="$_TLS_CRT"; key="$_TLS_KEY"
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"anytls",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
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
  [ -n "$pass" ] || pass="$(protocol_password_urlsafe)" || return 1
  tls_cert_for_prefix "trojan" "$port" "$sni" || return 1
  crt="$_TLS_CRT"; key="$_TLS_KEY"
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
  uuid="$(sing-box generate uuid)" || return 1
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg listen "$listen" --arg path "$path" --argjson port "$port" '
    {
      "type":"vmess",
      "tag":$tag,
      "listen":$listen,
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid}],
      "transport":{"type":"ws","path":$path,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}
    }
  '
}

build_vless_ws_inbound() {
  local port="$1" listen="$2" path="$3"
  local entry_key uuid
  entry_key="$(entry_key_from_parts vless-ws "$port")"
  uuid="$(sing-box generate uuid)" || return 1
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
  uuid="$(sing-box generate uuid)" || return 1
  [ -n "$pass" ] || pass="$(random_b64_password 12)" || return 1
  tls_cert_for_prefix "tuic" "$port" "$sni" || return 1
  crt="$_TLS_CRT"; key="$_TLS_KEY"
  jq -n --arg tag "$entry_key" --arg uuid "$uuid" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" --argjson port "$port" '
    {
      "type":"tuic",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"uuid":$uuid,"password":$pass}],
      "tls":{"enabled":true,"server_name":$sni,"alpn":["h3"],"certificate_path":$crt,"key_path":$key},
      "congestion_control":"bbr",
      "zero_rtt_handshake":false
    }
  '
}

build_hysteria2_inbound() {
  local port="$1" sni="$2" pass="${3:-}" obfs_type="${4:-}" obfs_pass="${5:-}"
  local entry_key crt key
  entry_key="$(entry_key_from_parts hysteria2 "$port")"
  case "$obfs_type" in
    ""|salamander|gecko) ;;
    *) err "不支持的 Hysteria2 混淆类型：$obfs_type（仅支持 salamander/gecko/不启用）。"; return 1 ;;
  esac
  [ -n "$pass" ] || pass="$(protocol_password_urlsafe)" || return 1
  if [ -n "$obfs_type" ]; then
    [ -n "$obfs_pass" ] || obfs_pass="$(protocol_password_urlsafe)" || return 1
  fi
  tls_cert_for_prefix "hy2" "$port" "$sni" || return 1
  crt="$_TLS_CRT"; key="$_TLS_KEY"
  # 带宽不限：不写 up_mbps/down_mbps；不设 gecko min/max 包大小，用 sing-box 默认 512/1200。
  # 忽略客户端上报带宽、双端强制走 BBR：不写 up/down 时 ignore_client_bandwidth=true 才会生效，
  # 客户端报多少都不切 Brutal；若以后填了 up/down，二者会冲突，届时须去掉这一行。
  jq -n --arg tag "$entry_key" --arg pass "$pass" --arg sni "$sni" --arg crt "$crt" --arg key "$key" \
    --arg obfs_type "$obfs_type" --arg obfs_pass "$obfs_pass" --argjson port "$port" '
    {
      "type":"hysteria2",
      "tag":$tag,
      "listen":"::",
      "listen_port":$port,
      "users":[{"name":$tag,"password":$pass}],
      "ignore_client_bandwidth":true,
      "tls":{"enabled":true,"server_name":$sni,"certificate_path":$crt,"key_path":$key}
    }
    | if $obfs_type != "" then .obfs = {"type":$obfs_type,"password":$obfs_pass} else . end
  '
}

build_socks_inbound() {
  local port="$1" password="${2:-}"
  local entry_key
  entry_key="$(entry_key_from_parts socks "$port")"
  [ -n "$password" ] || password="$(random_b64_password 12)" || return 1
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

# ---------- 用户对象构建（按协议类型分派） ----------

build_user_object_from_inbound() {
  local inbound="$1" full_name="$2"
  local inbound_type uuid password
  inbound_type="$(jq -r '.type' <<< "$inbound")" || return 1
  case "$inbound_type" in
    vless|vmess|tuic) uuid="$(sing-box generate uuid)" || return 1 ;;
  esac
  case "$inbound_type" in
    shadowsocks) password="$(openssl rand -base64 16)" || return 1 ;;
    anytls|trojan|hysteria2) password="$(protocol_password_urlsafe)" || return 1 ;;
    tuic|socks) password="$(random_b64_password 12)" || return 1 ;;
  esac
  case "$inbound_type" in
    vless|vmess)
      jq -n --arg name "$full_name" --arg uuid "$uuid" --argjson inbound "$inbound" '
        {name:$name,uuid:$uuid}
        | if $inbound.tls.reality.enabled == true then .flow="xtls-rprx-vision" else . end
      '
      ;;
    shadowsocks|anytls|trojan|hysteria2)
      jq -n --arg name "$full_name" --arg pass "$password" '{name:$name,password:$pass}'
      ;;
    tuic)
      jq -n --arg name "$full_name" --arg uuid "$uuid" --arg pass "$password" '{name:$name,uuid:$uuid,password:$pass}'
      ;;
    socks)
      jq -n --arg username "$full_name" --arg pass "$password" '{username:$username,password:$pass}'
      ;;
    *) return 1 ;;
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

# ====================================================
# Hysteria2 端口跳跃
# sing-box 只监听一个 UDP 端口；跳跃靠防火墙把一段 UDP 端口重定向到监听端口。
# 跳跃范围存在 meta.json（config.json 没有这个字段），按 entry_key 记，如 hy2-443。
# ====================================================

HY2_HOP_DEFAULT_START=42310
HY2_HOP_DEFAULT_END=45545

hy2_hop_range_valid() {
  local start="$1" end="$2" listen_port="$3"
  [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]] && [[ "$listen_port" =~ ^[0-9]+$ ]] || return 1
  [ "$start" -ge 1024 ] && [ "$end" -le 65535 ] && [ "$end" -gt "$start" ] || return 1
  # 范围不能包含监听端口
  { [ "$listen_port" -lt "$start" ] || [ "$listen_port" -gt "$end" ]; } || return 1
  return 0
}

# 解析 "42310-45545" 为 _HOP_START/_HOP_END，格式不对返回 1。
hy2_parse_hop_range() {
  local range="${1:-}"
  [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  _HOP_START="${BASH_REMATCH[1]}"
  _HOP_END="${BASH_REMATCH[2]}"
}

hy2_hop_range_from_meta() {
  local meta_json="${1:-}" tag="$2"
  [ -n "$meta_json" ] || meta_json='{}'
  echo "$meta_json" | jq -r --arg t "$tag" '
    (.[$t].hop_start // null) as $s | (.[$t].hop_end // null) as $e
    | if ($s != null and $e != null) then "\($s)-\($e)" else "" end'
}

hy2_hop_range_set_in_meta() {
  local meta_json="${1:-}" tag="$2" start="$3" end="$4"
  [ -n "$meta_json" ] || meta_json='{}'
  echo "$meta_json" | jq --arg t "$tag" --argjson s "$start" --argjson e "$end" \
    '.[$t] = ((.[$t] // {}) + {hop_start:$s, hop_end:$e})'
}

hy2_hop_range_del_from_meta() {
  local meta_json="${1:-}" tag="$2"
  [ -n "$meta_json" ] || meta_json='{}'
  echo "$meta_json" | jq --arg t "$tag" '
    del(.[$t].hop_start, .[$t].hop_end)
    | if (.[$t] // null) == {} then del(.[$t]) else . end'
}

# 指定的范围是否已被其它 hy2 节点占用（排除自己，用于重装换范围时判断）。
hy2_hop_range_in_use_by_meta() {
  local meta_json="${1:-}" start="$2" end="$3" exclude_tag="${4:-}"
  [ -n "$meta_json" ] || meta_json='{}'
  echo "$meta_json" | jq -e --argjson s "$start" --argjson e "$end" --arg ex "$exclude_tag" '
    [ to_entries[]
      | select((.key | startswith("hy2-")) and .key != $ex)
      | (.value.hop_start // null) as $hs | (.value.hop_end // null) as $he
      | select($hs != null and $he != null)
      | select(($s <= $he) and ($e >= $hs)) ] | length > 0' >/dev/null 2>&1
}

hy2_hop_rule_present() {
  local table_cmd="$1" start="$2" end="$3" port="$4"
  "$table_cmd" -t nat -C PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "$port" 2>/dev/null
}

# 仅在没有 iptables 时的 nft 兜底（有 iptables 的系统走 iptables-nft 即可）。
hy2_hop_apply_nft() {
  local start="$1" end="$2" port="$3"
  if nft list ruleset 2>/dev/null | grep -Fq "udp dport ${start}-${end} redirect to :${port}"; then return 0; fi
  nft add table ip nat 2>/dev/null || true
  nft add chain ip nat prerouting '{ type nat hook prerouting priority 0; }' 2>/dev/null || true
  nft add rule ip nat prerouting udp dport "${start}-${end}" redirect to ":${port}" || return 1
}

# 最近一次 hy2_hop_persist 失败的原因（成功时为空），供调用方在警告里具体说明。
_HY2_PERSIST_FAIL=""

# 持久化重定向规则：只用已装好的工具保存，不自动装包（不装 iptables-persistent）；
# 保存不了返回 1，并把原因记在 _HY2_PERSIST_FAIL 里，由调用方明确提醒用户手动保存，不悄悄跳过。
# 注意：只写 /etc/iptables/rules.v4 并不能保证开机自动恢复（没装 iptables-persistent
# 的系统开机时没人读这个文件）；开机恢复靠下面的 hy2_hop_restore_* 服务/cron。
hy2_hop_persist() {
  _HY2_PERSIST_FAIL=""
  if has_cmd netfilter-persistent; then
    if netfilter-persistent save >/dev/null 2>&1; then return 0; fi
    _HY2_PERSIST_FAIL="netfilter-persistent save 执行失败"
  else
    _HY2_PERSIST_FAIL="未安装 iptables-persistent（没有 netfilter-persistent 命令）"
  fi
  if [ "$PKG_MANAGER" = "apk" ] && has_cmd iptables-save; then
    # Alpine OpenRC 的 iptables 服务从 /etc/iptables/rules-save 恢复
    if mkdir -p /etc/iptables 2>/dev/null && iptables-save > /etc/iptables/rules-save 2>/dev/null; then
      return 0
    fi
    _HY2_PERSIST_FAIL="iptables-save 写入 /etc/iptables/rules-save 失败"
    return 1
  fi
  if has_cmd iptables-save; then
    # 新装系统常没有 /etc/iptables 目录：自己建目录再保存，不装任何包。
    if mkdir -p /etc/iptables 2>/dev/null && iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
      if has_cmd ip6tables-save; then ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true; fi
      return 0
    fi
    _HY2_PERSIST_FAIL="无法创建 /etc/iptables 或 iptables-save 执行失败"
    return 1
  fi
  _HY2_PERSIST_FAIL="本机没有 iptables-save 可用"
  return 1
}

# 只加规则（先查后加，不持久化），供 hy2_hop_apply 与开机恢复共用。
_hy2_hop_add_rule() {
  local start="$1" end="$2" port="$3"
  local applied=0
  if has_cmd iptables; then
    if ! hy2_hop_rule_present iptables "$start" "$end" "$port"; then
      iptables -t nat -A PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "$port" || return 1
    fi
    applied=1
  fi
  if has_cmd ip6tables; then
    if ! hy2_hop_rule_present ip6tables "$start" "$end" "$port"; then
      ip6tables -t nat -A PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "$port" || return 1
    fi
    applied=1
  fi
  if [ "$applied" -eq 0 ]; then
    if has_cmd nft; then
      hy2_hop_apply_nft "$start" "$end" "$port" || return 1
    else
      err "未找到 iptables/ip6tables/nft，无法设置端口跳跃重定向。"
      return 1
    fi
  fi
  return 0
}

# 验证规则确实在防火墙里（安装后立即核对，不只信“执行成功”）。
# 有 iptables 就要求 v4 规则在，有 ip6tables 就要求 v6 规则也在；只有 nft 时查 ruleset。
hy2_hop_rule_verified() {
  local start="$1" end="$2" port="$3"
  if has_cmd iptables || has_cmd ip6tables; then
    if has_cmd iptables && ! hy2_hop_rule_present iptables "$start" "$end" "$port"; then return 1; fi
    if has_cmd ip6tables && ! hy2_hop_rule_present ip6tables "$start" "$end" "$port"; then return 1; fi
    return 0
  fi
  if has_cmd nft; then
    nft list ruleset 2>/dev/null | grep -Fq "udp dport ${start}-${end} redirect to :${port}"
    return $?
  fi
  return 1
}

# 应用端口跳跃重定向（先查后加，重装不重复）。持久化失败只警告，不回滚已生效的规则；
# 持久化失败时尽量装好开机自恢复服务，重启后规则能自动补回。
hy2_hop_apply() {
  local start="$1" end="$2" port="$3"
  _hy2_hop_add_rule "$start" "$end" "$port" || return 1
  if ! hy2_hop_persist; then
    if hy2_hop_restore_sync 2>/dev/null; then
      warn "端口跳跃规则已生效，但持久化保存失败（${_HY2_PERSIST_FAIL}）。已安装开机自恢复服务，重启后会自动补回规则；也可手动保存，例如 Debian/Ubuntu：apt install -y iptables-persistent && netfilter-persistent save。"
    else
      warn "端口跳跃规则已生效，但持久化失败（${_HY2_PERSIST_FAIL}），且开机自恢复服务未能安装：重启后规则会丢失。请手动保存，例如 Debian/Ubuntu：apt install -y iptables-persistent && netfilter-persistent save。"
    fi
  fi
  return 0
}

# 删除端口跳跃重定向（规则不存在也不报错）。调用前请先确认没有其它 hy2 节点还在用这个范围。
hy2_hop_remove() {
  local start="$1" end="$2" port="$3"
  if has_cmd iptables; then
    iptables -t nat -D PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "$port" 2>/dev/null || true
  fi
  if has_cmd ip6tables; then
    ip6tables -t nat -D PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "$port" 2>/dev/null || true
  fi
  if ! has_cmd iptables && ! has_cmd ip6tables && has_cmd nft; then
    local fam handle
    for fam in ip ip6; do
      while IFS= read -r handle; do
        [ -n "$handle" ] && nft delete rule "$fam" nat prerouting handle "$handle" 2>/dev/null || true
      done < <(nft -a list chain "$fam" nat prerouting 2>/dev/null \
        | awk -v pat="udp dport ${start}-${end} redirect to :${port}" 'index($0, pat) && /# handle [0-9]+/ { print $NF }')
    done
  fi
  hy2_hop_persist >/dev/null 2>&1 || true
  return 0
}

# 彻底卸载时调用：按 meta 清理全部端口跳跃防火墙规则与开机自恢复服务。
hy2_hop_remove_all_from_meta() {
  local meta_json _tag _start _end _port
  meta_json="$(meta_load 2>/dev/null)" || meta_json='{}'
  [ -n "$meta_json" ] || meta_json='{}'
  while IFS=' ' read -r _tag _start _end; do
    [ -n "$_tag" ] || continue
    _port="$(entry_key_to_port "$_tag")"
    [ -n "$_port" ] || continue
    hy2_hop_remove "$_start" "$_end" "$_port" 2>/dev/null || true
  done < <(printf '%s\n' "$meta_json" | jq -r '
    to_entries[]
    | select(.key | startswith("hy2-"))
    | select(.value.hop_start != null and .value.hop_end != null)
    | "\(.key) \(.value.hop_start) \(.value.hop_end)"
  ' 2>/dev/null)
  hy2_hop_restore_remove >/dev/null 2>&1 || true
}

# ====================================================
# Hysteria2 端口跳跃：开机自恢复（方案 B，不装 iptables-persistent）
# 原理：规则只在内存里，重启会丢。服务/cron 在开机时读 meta.json，
# 把每个 hy2 节点存的跳跃范围重新加回防火墙。服务由脚本自己建、
# 卸载时自己拆，不动系统包。
# ====================================================

HY2_HOP_RESTORE_SERVICE="/etc/systemd/system/sing-box-hy2-hop-restore.service"
HY2_HOP_RESTORE_CRON_MARK="sing-box-hy2-hop-restore"

# meta 里是否还有任何 hy2 节点的跳跃范围。
hy2_hop_has_any_range() {
  local meta_json="${1:-}"
  [ -n "$meta_json" ] || meta_json='{}'
  echo "$meta_json" | jq -e '
    [ to_entries[]
      | select(.key | startswith("hy2-"))
      | select(.value.hop_start != null and .value.hop_end != null) ] | length > 0' >/dev/null 2>&1
}

# 开机恢复入口（sb.sh --restore-hy2-hops 调用）：按 meta 把所有跳跃规则补回来。
# 不调持久化——恢复本身就是持久化的手段；失败返回 1 供 systemd/cron 日志查看。
hy2_hop_restore_all() {
  local meta_json
  meta_json="$(meta_load 2>/dev/null)" || meta_json='{}'
  [ -n "$meta_json" ] || meta_json='{}'
  local _ok=0 _tag _start _end _port
  while IFS=' ' read -r _tag _start _end; do
    [ -n "$_tag" ] || continue
    _port="$(entry_key_to_port "$_tag")"
    if ! hy2_hop_range_valid "$_start" "$_end" "$_port" 2>/dev/null; then
      warn "开机恢复跳过无效的跳跃范围：${_tag} ${_start}-${_end}。"
      _ok=1
      continue
    fi
    if ! _hy2_hop_add_rule "$_start" "$_end" "$_port"; then
      warn "开机恢复跳跃规则失败：${_tag} UDP ${_start}-${_end} -> ${_port}。"
      _ok=1
    fi
  done <<EOF
$(echo "$meta_json" | jq -r 'to_entries[] | select(.key | startswith("hy2-")) | select(.value.hop_start != null and .value.hop_end != null) | "\(.key) \(.value.hop_start) \(.value.hop_end)"' 2>/dev/null)
EOF
  return $_ok
}

_hy2_hop_restore_service_installed() {
  [ -f "$HY2_HOP_RESTORE_SERVICE" ] && grep -Fq -- "--restore-hy2-hops" "$HY2_HOP_RESTORE_SERVICE" 2>/dev/null
}

_hy2_hop_restore_cron_installed() {
  has_cmd crontab || return 1
  crontab -l 2>/dev/null | grep -Fq "$HY2_HOP_RESTORE_CRON_MARK"
}

# 装开机恢复：优先 systemd oneshot 服务；没有 systemd 时退到 @reboot cron；
# 两者都没有则返回 1，由调用方提醒用户手动处理。
hy2_hop_restore_install() {
  if _hy2_hop_restore_service_installed || _hy2_hop_restore_cron_installed; then return 0; fi
  if has_cmd systemctl && [ -d /run/systemd/system ]; then
    mkdir -p /etc/systemd/system || return 1
    cat > "$HY2_HOP_RESTORE_SERVICE" <<EOF
[Unit]
Description=Restore Hysteria2 port hopping iptables rules
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash ${SB_TARGET_SCRIPT} --restore-hy2-hops
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable sing-box-hy2-hop-restore.service >/dev/null 2>&1 || return 1
    _hy2_hop_restore_service_installed
    return $?
  fi
  if has_cmd crontab; then
    local tmp
    tmp="$(mktemp)" || return 1
    crontab -l 2>/dev/null | grep -v "$HY2_HOP_RESTORE_CRON_MARK" > "$tmp" || true
    echo "@reboot /bin/bash ${SB_TARGET_SCRIPT} --restore-hy2-hops >/dev/null 2>&1 # ${HY2_HOP_RESTORE_CRON_MARK}" >> "$tmp"
    crontab "$tmp" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    _hy2_hop_restore_cron_installed
    return $?
  fi
  return 1
}

# 拆开机恢复（服务和 cron 都清，只在没有跳跃范围剩下时调用）。
hy2_hop_restore_remove() {
  if [ -f "$HY2_HOP_RESTORE_SERVICE" ]; then
    systemctl disable --now sing-box-hy2-hop-restore.service >/dev/null 2>&1 || true
    rm -f "$HY2_HOP_RESTORE_SERVICE" || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if has_cmd crontab; then
    local tmp
    tmp="$(mktemp)" || return 0
    crontab -l 2>/dev/null | grep -v "$HY2_HOP_RESTORE_CRON_MARK" > "$tmp" || true
    if [ -s "$tmp" ]; then
      crontab "$tmp" || true
    else
      crontab -r 2>/dev/null || true
    fi
    rm -f "$tmp"
  fi
  return 0
}

# 按 meta 现状同步开机恢复：还有跳跃范围就确保装好，一个不剩就拆掉。
hy2_hop_restore_sync() {
  local meta_json
  meta_json="$(meta_load 2>/dev/null)" || meta_json='{}'
  [ -n "$meta_json" ] || meta_json='{}'
  if hy2_hop_has_any_range "$meta_json"; then
    hy2_hop_restore_install
  else
    hy2_hop_restore_remove
  fi
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
  if ! echo "$normalized" | jq -e '(.outbounds[]?, .endpoints[]?) | select(.tag == "warp")' >/dev/null 2>&1; then
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
      | select(. != "" and (node_part(.) | contains("-to-") | not))] | unique
  ')" || return 1
  relay_pairs_json="$(relay_list_table "$normalized" | jq -Rsc --argjson config "$normalized" '
    [$config.outbounds[]?.tag] as $tags
    | [split("\n")[] | select(length > 0) | split("\u0001")
       | select(.[1] != "" and .[2] != "") | {u:.[1],o:.[2]}
       | select(.o as $o | ($tags|index($o)) != null)] | sort_by(.o,.u) | unique_by(.u)
  ')" || return 1

  preserved_rules_json="$(
    echo "$normalized" | jq -c '
      [ .route.rules[]? | select(. != {action:"reject"})
        | select(.auth_user? == null or .inbound? != null or
            ((keys - ["auth_user","rule_set","outbound","action"]) | length > 0) or
            ((.action // "route") != "route") or
            ((.outbound // "") | test("^(direct$|warp$|out-|to-|relay-)") | not)) ]
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

SPLIT_RULE_BASE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
SPLIT_RULE_LOOKUP_URL="https://github.com/SagerNet/sing-geosite/tree/rule-set"

split_rule_preset_item() {
  case "${1:-}" in
    1) echo "AI 服务|geosite-category-ai-!cn.srs" ;;
    2) echo "Google|geosite-google.srs" ;;
    3) echo "Netflix|geosite-netflix.srs" ;;
    4) echo "Disney+|geosite-disney.srs" ;;
    5) echo "YouTube|geosite-youtube.srs" ;;
    6) echo "TikTok|geosite-tiktok.srs" ;;
    *) return 1 ;;
  esac
}

split_rule_normalize_file() {
  local raw="${1:-}" name
  name="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$name" ] || return 1
  if [[ "$name" == *"://"* ]]; then
    err "请输入规则文件名（如 openai 或 geosite-openai.srs），不要输入完整链接。"
    return 1
  fi
  name="${name##*/}"
  name="${name%.srs}"
  [[ "$name" == geosite-* ]] || name="geosite-${name}"
  if [[ ! "$name" =~ ^geosite-[A-Za-z0-9._!@+-]+$ ]]; then
    err "规则名称格式不对：${raw}"
    return 1
  fi
  echo "${name}.srs"
}

split_rule_validate_remote_file() {
  local file="$1" url
  url="${SPLIT_RULE_BASE_URL}/${file}"
  run_with_spinner "正在验证规则文件 ${file}..." \
    curl_maybe_warp -fsIL --connect-timeout 8 --max-time 15 "$url"
}

split_rule_confirm_relay_to_warp() {
  local files_json="$1" conflicts count
  conflicts="$(split_rule_relay_conflicts_json "$files_json")" || return 1
  count="$(printf '%s\n' "$conflicts" | jq 'length')" || return 1
  [ "$count" -gt 0 ] || return 0

  warn "以下规则当前正在走部分流量中转："
  printf '%s\n' "$conflicts" | jq -r '
    .[]?
    | "  - \(.name // .file) -> 落地 \(.landing_id // "未设置")（\(.file // "")）"
  '
  ask_confirm_yn "是否切换为 WARP 分流？[y/N]: " || return 1
}

split_rule_confirm_warp_to_relay() {
  local files_json="$1" conflicts count
  conflicts="$(split_rule_warp_conflicts_json "$files_json")" || return 1
  count="$(printf '%s\n' "$conflicts" | jq 'length')" || return 1
  [ "$count" -gt 0 ] || return 0

  warn "以下规则当前正在走 WARP 分流："
  printf '%s\n' "$conflicts" | jq -r '
    .[]?
    | "  - \(.name // .file)（\(.file // "")）"
  '
  ask_confirm_yn "是否切换为部分流量中转？[y/N]: " || return 1
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
  ui_hr
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

  read -r -p "落地地址（域名或 IP，回车返回）: " _ip
  [ -z "${_ip:-}" ] && { warn "已取消，返回上一级。"; return 1; }

  read -r -p "落地 SOCKS 端口（默认: 1080）: " _relay_port
  _relay_port="${_relay_port:-1080}"
  if ! is_valid_port "$_relay_port"; then
    warn "落地 SOCKS 端口无效，已返回上一级。"
    return 1
  fi

  read -r -p "落地 SOCKS Username（无认证可留空）: " _username
  if [ -n "${_username:-}" ]; then
    read -rs -p "落地 SOCKS 密码: " _password || return 1
    printf '\n' >&2
  else
    _password=""
  fi

  printf -v "$ip_var" '%s' "$_ip"
  printf -v "$port_var" '%s' "$_relay_port"
  printf -v "$username_var" '%s' "${_username:-}"
  printf -v "$password_var" '%s' "${_password:-}"
  return 0
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
        password:(.password // ""),
        udp_over_tcp:((.udp_over_tcp // false) | if type == "object" then .enabled == true else . == true end)
      }
  ' | head -n1
}

relay_known_landing_json() {
  local json="$1" land="$2" existing=""
  existing="$(relay_meta_json | jq -c --arg id "$land" '.landings[$id] | select(. != null) | . + {id:$id}' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  existing="$(relay_landing_from_outbound_json "$json" "$land" "$(relay_outbound_tag "" "$land")" 2>/dev/null || true)"
  if [ -z "$existing" ]; then
    local legacy_tag
    legacy_tag="$(relay_list_table "$json" | awk -F '\x01' -v land="$land" '
      {n=$2; sub(/@.*/, "", n); tail="-to-" land
       if (substr(n,length(n)-length(tail)+1)==tail && $3!="") {print $3; exit}}')"
    if [ -n "$legacy_tag" ]; then
      existing="$(relay_landing_from_outbound_json "$json" "$land" "$legacy_tag")"
    fi
  fi
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
  local json="$1" outvar="$2" selected reply candidate old id i
  local -a available=()
  mapfile -t available < <(relay_meta_landings_json | jq -r 'keys[]')
  for i in "${!available[@]}"; do
    printf '  %s. %s\n' "$((i+1))" "${available[i]}"
  done
  if [ "${#available[@]}" -gt 0 ]; then
    read -r -p "选已有落地编号，回车粘贴新链接，q 返回: " reply || return 1
    if [[ "$reply" =~ ^[1-9][0-9]*$ ]] && [ "$reply" -le "${#available[@]}" ]; then
      selected="$(relay_known_landing_json "$json" "${available[reply-1]}")" || return 1
      printf -v "$outvar" '%s' "$selected"
      return 0
    fi
    [ -z "$reply" ] || return 1
  fi

  candidate="$(relay_prompt_connection)" || return 1
  relay_prompt_landing_id id || return 1
  old="$(relay_known_landing_json "$json" "$id")"
  candidate="$(jq --arg id "$id" '.id=$id' <<< "$candidate")" || return 1
  if relay_landing_matches "$old" "$candidate"; then
    printf -v "$outvar" '%s' "$old"
    return 0
  fi
  relay_check_new_endpoint "$candidate" || return 1
  if [ "$old" != null ]; then
    relay_affected_lines "$json" "$id"
    ask_confirm_yes "更新这个标识的落地？输入 yes 确认: " || return 1
  fi
  printf -v "$outvar" '%s' "$candidate"
}

# Adding an existing entry/landing pair leaves all original authentications intact.
relay_add_full_config() {
  local base="$1" entry="$2" landing="$3" id user tag inbound auth outbound
  id="$(jq -r '.id' <<< "$landing")" || return 1
  user="$(relay_user_name "$entry" "$id")"; tag="$(relay_outbound_tag "$entry" "$id")"
  inbound="$(find_inbound_by_entry_key "$base" "$entry")" || return 1
  [ -n "$inbound" ] || return 1
  auth="$(find_user_obj_in_inbound "$inbound" "$user")"
  if [ -n "$auth" ]; then
    printf '%s\n' "$base"
    return
  fi
  auth="$(build_user_object_from_inbound "$inbound" "$user")" || return 1
  outbound="$(relay_probe_config "$landing" false | jq -c --arg tag "$tag" '.outbounds[0] | .tag=$tag')" || return 1
  jq --arg entry "$entry" --arg user "$user" --arg tag "$tag" --argjson auth "$auth" --argjson outbound "$outbound" '
    (.inbounds[] | select(.tag == $entry)).users |= ((. // []) + [$auth])
    | .outbounds = ((.outbounds // []) | map(select(.tag != $tag)) + [$outbound])
    | .route.rules += [{auth_user:[$user],outbound:$tag}]
  ' <<< "$base"
}

relay_commit_projection() {
  local previous_config="$1" previous_meta="$2" next_config="$3" next_meta="$4" projected
  if [ "$(jq -Sc . <<< "$previous_meta")" = "$(jq -Sc . <<< "$next_meta")" ] &&
    [ "$(jq -Sc . <<< "$previous_config")" = "$(jq -Sc . <<< "$next_config")" ]; then return 0; fi
  projected="$(relay_project_partial_state_with_meta "$next_config" "$next_meta")" || return 1
  with_manager_lock protocol_commit_changes "$previous_config" "$previous_meta" "$projected" "$next_meta"
}

relay_add() {
  init_manager_env || { pause; return 0; }
  local json lines=() entry choice i tag proto port landing previous meta next relay_json
  json="$(user_manager_config_for_edit)" || return 1
  previous="$(meta_load)" || return 1
  mapfile -t lines < <(protocol_entry_inventory "$json" | sort_tsv_by_protocol 1 | head -100)
  if [ "${#lines[@]}" -eq 0 ]; then warn "请先安装一个本机入站节点。"; pause; return 0; fi
  if [ "${#lines[@]}" -eq 1 ]; then
    choice=1
  else
    for i in "${!lines[@]}"; do
      IFS=$'\x01' read -r tag proto port <<< "${lines[i]}"
      printf '  %s. %s\n' "$((i+1))" "$tag"
    done
    read -r -p "选择客户端连接的本机节点（回车返回）: " choice || return 0
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#lines[@]}" ] || return 0
  fi
  IFS=$'\x01' read -r entry _ _ <<< "${lines[choice-1]}"
  relay_choose_landing_or_return "$json" landing || return 0
  next="$(relay_add_full_config "$json" "$entry" "$landing")" || return 1
  relay_json="$(relay_meta_json_from_meta "$previous")" || return 1
  relay_json="$(relay_meta_upsert_landing_to_json "$relay_json" "$landing")" || return 1
  meta="$(relay_meta_replace_in_meta_json "$previous" "$relay_json")" || return 1
  relay_commit_projection "$json" "$previous" "$next" "$meta" || return 1
  ok "中转已保存。已有客户端连接凭据已保留。"
  pause
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
  split_rule_normalize_file "$@"
}

relay_validate_rule_file() {
  split_rule_validate_remote_file "$@"
}

relay_preset_rule() {
  split_rule_preset_item "$@"
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
    def socks_out($base; $tag; $landing):
      ($base | del(.username,.password,.udp_over_tcp)) +
      ({type:"socks", version:"5", tag:$tag, server:($landing.server // ""), server_port:(($landing.port // 0) | tonumber)}
      | if (($landing.username // "") != "") then . + {username:$landing.username, password:($landing.password // "")} else . end
      | if $landing.udp_over_tcp == true then . + {udp_over_tcp:true} else . end);
    def full_landing:
      . as $tag |
      if startswith("to-") then sub("^to-"; "")
      elif startswith("out-to-") then sub("^out-to-"; "")
      elif test("^out-.+-to-.+$") then
        ($landings | keys | map(. as $id | select($tag | endswith("-to-" + $id))) | max_by(length)) // ""
      else "" end;
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
              | ($tag | full_landing) as $id
              | if .type == "socks" and $id != "" and $landings[$id] != null then
                  socks_out(.; $tag; $landings[$id])
                else .
                end
            )
          | map(select(((.tag // "") != "relay-partial") and (((.tag // "") | startswith("relay-")) | not)))
        )
        + (if ($used_landings | length) > 0 then
            ($used_landings | map(. as $landing_id | socks_out({}; ("relay-" + $landing_id); $landings[$landing_id])))
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
  json="$(user_manager_config_for_edit)" || return 1
  projected="$(relay_project_partial_state_with_meta "$json" "$meta_json")" || return 1
  if user_db_exists; then
    _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes '' "$projected" "$meta_json"
  else
    _CONFIG_APPLY_QUIET_OK=1 _CONFIG_SKIP_USAGE_SYNC=1 config_and_meta_apply "$projected" "$meta_json"
  fi
}

relay_apply_partial_state() {
  relay_apply_meta_json_state "$(meta_load)"
}

relay_add_preset_rules() {
  local raw="$1" picks=() names=() files=() pick preset item name file landing_json json files_json has_warp_conflict=0
  local meta_json relay_json warp_json
  local previous
  init_manager_env || return 1
  json="$(user_manager_config_for_edit)" || return 1
  previous="$(meta_load)" || return 1
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
  meta_json="$previous"
  warp_json="$(warp_rule_remove_meta_by_files_json_from "$(warp_meta_json)" "$files_json")" || return 1
  relay_json="$(relay_meta_json_from_meta "$previous")"
  for pick in "${!files[@]}"; do
    relay_json="$(relay_rule_add_meta_to_json "$relay_json" "${names[$pick]}" "${files[$pick]}" "$landing_json")" || return 1
  done
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  relay_commit_projection "$json" "$previous" "$json" "$meta_json" || return 1
  ok "部分流量中转规则已应用。"
  pause
}

relay_custom_rule_menu() {
  local raw file name landing_json json files_json has_warp_conflict=0 meta_json relay_json warp_json
  local previous
  init_manager_env || return 1
  json="$(user_manager_config_for_edit)" || return 1
  previous="$(meta_load)" || return 1
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
  meta_json="$previous"
  warp_json="$(warp_rule_remove_meta_by_files_json_from "$(warp_meta_json)" "$files_json")" || return 1
  relay_json="$(relay_rule_add_meta_to_json "$(relay_meta_json_from_meta "$previous")" "$name" "$file" "$landing_json")" || return 1
  meta_json="$(warp_meta_replace_in_meta_json "$meta_json" "$warp_json")" || return 1
  meta_json="$(relay_meta_replace_in_meta_json "$meta_json" "$relay_json")" || return 1
  relay_commit_projection "$json" "$previous" "$json" "$meta_json" || return 1
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

  json="$(user_manager_config_for_edit)" || return 1
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
    db_json="$(user_db_load)" || return 1
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
    json="$(user_manager_config_for_edit)" || return 1
    print_rect_title "中转管理"
    say "客户端连接本机，流量从落地机出去。请先在落地机用本脚本安装 SOCKS5，再复制落地链接。"
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
    printf "  u. 更新落地连接   t. 中转诊断\n"
    echo "2-7支持用+连接，例如：2+4+7"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) relay_add || true ;;
      8) relay_custom_rule_menu || true ;;
      9) relay_delete || true ;;
      u|U) relay_update_landing_menu || true ;;
      t|T) relay_diagnostics_menu || true ;;
      0|q|Q|"") return 0 ;;
      *+*|[2-7]) relay_add_preset_rules "$act" || true ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

# >>>>>>>>> END MODULE: 40_relay.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 42_relay_probe.sh <<<<<<<<<<<
# SOCKS5 link import and authenticated relay probes.

# Decode only URI userinfo. Never interpret pasted text as shell syntax.
relay_decode_userinfo() {
  local LC_ALL=C escaped="$1" decoded='' byte fragment
  [[ "$escaped" =~ ^([A-Za-z0-9._~-]|%[[:xdigit:]]{2})+$ ]] || return 1
  while [ -n "$escaped" ]; do
    if [ "${escaped:0:1}" = % ]; then
      fragment="${escaped:1:2}"
      [[ "${fragment,,}" != 00 ]] || return 1
      printf -v byte '%b' "\\x$fragment"
      escaped="${escaped:3}"
    else
      byte="${escaped:0:1}"
      escaped="${escaped:1}"
    fi
    [[ "$byte" != [[:cntrl:]] ]] || return 1
    decoded+="$byte"
  done
  [ "${#decoded}" -le 255 ] || return 1
  printf '%s' "$decoded"
}

relay_landing_host_valid() {
  local host="$1"
  if [[ "$host" == *:* ]]; then
    [[ "$host" =~ ^[[:xdigit:].:]+$ && "$host" != *:::* ]]
  else
    [[ "${#host}" -le 253 &&
      "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.?$ ]]
  fi
}

relay_select_saved_landing() {
  local json="$1" outvar="$2" selected_id selected_index i result
  local -a ids=()
  mapfile -t ids < <(
    {
      relay_meta_landings_json | jq -r 'keys[]'
      relay_list_table "$json" | awk -F '\x01' '{n=$2; sub(/@.*/, "", n); sub(/^.*-to-/, "", n); if (n!="") print n}'
    } | sort -u
  )
  if [ "${#ids[@]}" -eq 0 ]; then warn "还没有保存的落地机。"; return 1; fi
  for i in "${!ids[@]}"; do printf '  %s. %s\n' "$((i+1))" "${ids[i]}"; done
  read -r -p "选落地机（回车返回）: " selected_index || return 1
  [[ "$selected_index" =~ ^[1-9][0-9]*$ ]] && [ "$selected_index" -le "${#ids[@]}" ] || return 1
  selected_id="${ids[selected_index-1]}"
  result="$(relay_known_landing_json "$json" "$selected_id")" || return 1
  [ "$result" != null ] || return 1
  printf -v "$outvar" '%s' "$result"
}

relay_commit_landing() {
  local config="$1" previous="$2" candidate="$3" normalized next
  normalized="$(relay_meta_json_from_meta "$previous")" || return 1
  normalized="$(relay_meta_upsert_landing_to_json "$normalized" "$candidate")" || return 1
  next="$(relay_meta_replace_in_meta_json "$previous" "$normalized")" || return 1
  relay_commit_projection "$config" "$previous" "$config" "$next"
}

relay_update_landing_menu() {
  local config previous old candidate id
  config="$(user_manager_config_for_edit)" || return 1
  previous="$(meta_load)" || return 1
  relay_select_saved_landing "$config" old || { pause; return 0; }
  candidate="$(relay_prompt_connection)" || { pause; return 0; }
  if relay_landing_matches "$old" "$candidate"; then
    ok "落地连接资料相同。"
    pause
    return 0
  fi
  relay_check_new_endpoint "$candidate" || { pause; return 0; }
  id="$(jq -r '.id' <<< "$old")"
  relay_affected_lines "$config" "$id"
  ask_confirm_yes "确认更换这些线路的落地？输入 yes 确认: " || return 0
  candidate="$(jq --arg id "$id" '.id=$id' <<< "$candidate")" || return 1
  relay_commit_landing "$config" "$previous" "$candidate" || return 1
  ok "落地已更新，客户端继续使用原链接。新落地默认使用原生 UDP。"
  pause
}

relay_diagnose_endpoint() {
  local landing="$1" attempt
  ui_echo "正在检查落地 TCP（最多 4 秒）。"
  if ! relay_probe_dns "$landing" tcp false; then printf '%s\n' tcp_failed; return; fi
  for attempt in 1 2; do
    ui_echo "正在验证原生 UDP 回包（第 ${attempt}/2 次）。"
    if relay_probe_dns "$landing" udp false; then printf '%s\n' native; return; fi
  done
  ui_echo "正在用临时配置验证 UDP over TCP（最多 4 秒）。"
  if relay_probe_dns "$landing" udp true; then printf '%s\n' uot; else printf '%s\n' unavailable; fi
}

relay_diagnostics_menu() {
  local config previous landing id enabled answer state candidate
  config="$(user_manager_config_for_edit)" || return 1
  previous="$(meta_load)" || return 1
  relay_select_saved_landing "$config" landing || { pause; return 0; }
  id="$(jq -r '.id' <<< "$landing")"
  enabled="$(jq -r '.udp_over_tcp == true' <<< "$landing")"
  if [ "$enabled" = true ]; then
    read -r -p "当前使用 UDP over TCP。r 恢复原生，回车诊断，q 返回: " answer || return 0
    case "$answer" in
      r|R)
        relay_affected_lines "$config" "$id"
        ask_confirm_yes "恢复这台落地的原生 UDP？输入 yes 确认: " || return 0
        candidate="$(jq 'del(.udp_over_tcp)' <<< "$landing")" || return 1
        relay_commit_landing "$config" "$previous" "$candidate" || return 1
        ok "已恢复原生 UDP。"; pause; return 0 ;;
      '') ;;
      *) return 0 ;;
    esac
  fi
  state="$(relay_diagnose_endpoint "$landing")" || return 1
  case "$state" in
    tcp_failed) warn "落地 TCP 转发未通过，先核对连接资料。" ;;
    native) ok "原生 UDP 已收到回包。继续使用当前设置。" ;;
    unavailable) warn "TCP 通过，两种 UDP 方式都未收到有效回包。当前设置保持。" ;;
    uot)
      ok "TCP 通过，只有 UDP over TCP 收到有效回包。"
      if [ "$enabled" = false ]; then
        relay_affected_lines "$config" "$id"
        if ask_confirm_yes "仅为这台落地启用 UDP over TCP？输入 yes 确认: "; then
          candidate="$(jq '.udp_over_tcp=true' <<< "$landing")" || return 1
          relay_commit_landing "$config" "$previous" "$candidate" || return 1
          ok "已为所选落地启用 UDP over TCP。"
        fi
      fi
      ;;
  esac
  pause
}

relay_parse_landing_link() {
  local link="$1" rest host port encoded_user encoded_pass username password
  [[ "$link" == socks5://* ]] || return 1
  rest="${link#socks5://}"
  if ! [[ "$rest" =~ ^([^:@]+):([^@]+)@(\[([[:xdigit:].:]+)\]|([a-zA-Z0-9.-]+)):([0-9]+)$ ]]; then
    return 1
  fi
  encoded_user="${BASH_REMATCH[1]}" encoded_pass="${BASH_REMATCH[2]}"
  host="${BASH_REMATCH[4]:-${BASH_REMATCH[5]}}" port="${BASH_REMATCH[6]}"
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && is_valid_port "$port" && relay_landing_host_valid "$host" || return 1
  username="$(relay_decode_userinfo "$encoded_user")" || return 1
  password="$(relay_decode_userinfo "$encoded_pass")" || return 1
  relay_landing_to_meta_json '' "$host" "$port" "$username" "$password"
}

relay_prompt_connection() {
  local connection_answer endpoint
  read -rs -p "粘贴 SOCKS5 落地链接（m 手动填写，回车返回）: " connection_answer || return 1
  printf '\n' >&2
  case "$connection_answer" in
    '') return 1 ;;
    m|M)
      local endpoint_host endpoint_port endpoint_user endpoint_password
      relay_prompt_landing_details '' endpoint_host endpoint_port endpoint_user endpoint_password || return 1
      endpoint_host="${endpoint_host#[}"; endpoint_host="${endpoint_host%]}"
      relay_landing_host_valid "$endpoint_host" || { warn "落地地址无效。"; return 1; }
      endpoint="$(relay_landing_to_meta_json '' "$endpoint_host" "$endpoint_port" "$endpoint_user" "$endpoint_password")" || return 1
      ;;
    *)
      endpoint="$(relay_parse_landing_link "$connection_answer")" || { warn "落地链接格式无效。请复制完整的 socks5:// 链接。"; return 1; }
      ;;
  esac
  printf '%s\n' "$endpoint"
}

relay_landing_matches() {
  jq -en --argjson old "$1" --argjson next "$2" '
    def endpoint: [.server, (.port | tonumber), (.username // ""), (.password // "")];
    $old != null and ($old | endpoint) == ($next | endpoint)
  ' >/dev/null
}

relay_affected_lines() {
  local json="$1" land="$2"
  printf '%s\n' '受影响的线路：'
  relay_list_table "$json" | awk -F '\x01' -v land="$land" '
    {name=$2; sub(/@.*/, "",name); end="-to-" land
     if (length(name)>length(end) && substr(name,length(name)-length(end)+1)==end && !seen[name]++) print "  全量 · " name}'
  relay_meta_json | jq -r --arg land "$land" '.rules[]? | select(.landing_id == $land) | "  网站 · " + .name'
}

relay_probe_target() { printf '%s\n' '1.1.1.1:53'; }

relay_probe_config() {
  local landing="$1" use_uot="$2"
  jq -c --argjson uot "$use_uot" '
    {log:{disabled:true},outbounds:[({type:"socks",tag:"probe",version:"5",
       server:.server,server_port:(.port | tonumber)}
       + (if (.username // "") != "" then {username:.username,password:(.password // "")} else {} end)
       + (if $uot then {udp_over_tcp:true} else {} end))]}
  ' <<< "$landing"
}

relay_probe_dns() (
  local landing="$1" network="$2" use_uot="$3" temp offset=0 wire_id prefix='' header
  umask 077
  temp="$(mktemp -d)" || return 1
  trap 'rm -rf "$temp"' EXIT
  relay_probe_config "$landing" "$use_uot" > "$temp/probe.json" || return 1
  wire_id="$(openssl rand -hex 2)" || return 1
  if [ "$network" = tcp ]; then prefix='\000\035'; fi
  {
    printf '%b' "$prefix\\x${wire_id:0:2}\\x${wire_id:2:2}\001\000\000\001\000\000\000\000\000\000\007example\003com\000\000\001\000\001"
    sleep 1
  } | run_with_timeout 4 sing-box -c "$temp/probe.json" tools connect -o probe -n "$network" \
    "$(relay_probe_target)" > "$temp/reply" 2>/dev/null || true
  [ "$network" != tcp ] || offset=2
  [ "$(wc -c < "$temp/reply")" -ge "$((offset + 29))" ] || return 1
  header="$(od -An -v -tx1 -j "$offset" -N 29 "$temp/reply" | tr -d '[:space:]')"
  [[ "$header" == "$wire_id"[89abcdef]* &&
     "${header:8:4}" = 0001 &&
     "${header:24}" = 076578616d706c6503636f6d0000010001 ]]
)

relay_check_new_endpoint() {
  local landing="$1"
  ui_echo "正在验证落地 SOCKS5 的 TCP 转发和认证。"
  if ! run_with_spinner "正在验证落地连接" relay_probe_dns "$landing" tcp false; then
    warn "落地 TCP 验证失败。请检查地址、端口、认证和落地机的外网访问。"
    return 1
  fi
}

# >>>>>>>>> END MODULE: 42_relay_probe.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 50_v2ray_api.sh <<<<<<<<<<<
# ============================================================
# 模块: 50_v2ray_api.sh
# 职责: gRPC 流量统计查询、meta 存储、grpcurl 安装
# 依赖: 00_base.sh, 01_utils.sh
# ============================================================

# ---------- Proto 文件管理 ----------

ensure_v2ray_api_proto_files() {
  mkdir -p "$(dirname "$V2RAY_PROTO_V2RAY")" || return 1
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
  if ! download_file "$download_url" "$tmp_dir/grpcurl.tar.gz" 20 3 "下载流量统计组件"; then
    rm -rf "$tmp_dir"
    warn "下载流量统计组件失败。"
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
  users_json="$(jq -c '[.inbounds[]?.users[]? | (.name // .username // empty) | select(length > 0)] | unique' <<< "$json")" || return 1
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
        | (if $new_epoch then {} else ($prev.counters[$item.key] // {}) end) as $old
        | ($item.value.uplink // $old.uplink // 0) as $up
        | ($item.value.downlink // $old.downlink // 0) as $down
        | .[$u].up = ((.[$u].up // 0) + delta($up; ($old.uplink // 0)))
        | .[$u].down = ((.[$u].down // 0) + delta($down; ($old.downlink // 0)))
        | .[$u].live_up = ((.[$u].live_up // 0) + $up)
        | .[$u].live_down = ((.[$u].live_down // 0) + $down)
        | .[$u].seen_up = ((.[$u].seen_up // false) or ($item.value | has("uplink")))
        | .[$u].seen_down = ((.[$u].seen_down // false) or ($item.value | has("downlink"))))) as $usage
    | (if $prev.process == null then
         .users | with_entries(.value |= {up:(.last_live_up_bytes // 0), down:(.last_live_down_bytes // 0)})
       elif $new_epoch then {} else ($prev.legacy_pending // {}) end) as $legacy
    | .users |= with_entries(
        .key as $u | .value as $v | ($usage[$u] // {}) as $n
        | ($legacy[$u] // {}) as $baseline
        | .value.used_up_bytes = (($v.used_up_bytes // 0) +
            (if $baseline.up != null and $n.seen_up then delta($n.live_up; $baseline.up) else ($n.up // 0) end))
        | .value.used_down_bytes = (($v.used_down_bytes // 0) +
            (if $baseline.down != null and $n.seen_down then delta($n.live_down; $baseline.down) else ($n.down // 0) end))
        | .value.last_live_up_bytes = ($n.live_up // (if $new_epoch then 0 else ($v.last_live_up_bytes // 0) end))
        | .value.last_live_down_bytes = ($n.live_down // (if $new_epoch then 0 else ($v.last_live_down_bytes // 0) end)))
    | .meta.usage = {
        process:$snap.process,
        start:(if $new_epoch then $snap.start else $prev.start end),
        counters:((if $new_epoch then {} else ($prev.counters // {}) end) * $live),
        legacy_pending:($legacy | with_entries(
          .key as $u | $usage[$u] as $n
          | if $n.seen_up then del(.value.up) else . end
          | if $n.seen_down then del(.value.down) else . end
          | select(.value | length > 0)))
      }
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
  snapshot="$(query_usage_snapshot)" || { warn "流量采样失败，本次保持原统计数据不变。"; return 1; }
  db_json="$(user_db_load)" || return 1
  db_json="$(account_usage_snapshot "$db_json" "$snapshot")" || return 1
  db_json="$(jq --arg sampled "$(TZ="$BUSINESS_TZ" date '+%F %T')" '
    .meta.data_updated_at_text = $sampled
  ' <<< "$db_json")" || return 1
  user_db_save "$db_json" || { warn "流量数据保存失败：$USER_DB_FILE"; return 1; }
}

# ---------- Meta 存储（Reality 公钥、分流与跳跃元数据） ----------

meta_load() {
  if [ -s "$META_FILE" ]; then
    if jq -e 'type == "object"' "$META_FILE" >/dev/null 2>&1; then
      cat "$META_FILE"
      return 0
    fi
    backup_corrupt_json_file "$META_FILE"
  fi
  echo '{}'
}

meta_save() {
  with_manager_lock _meta_save_body "$@"
}

_meta_save_body() {
  local meta_json="$1"
  atomic_write_json_file "$META_FILE" "$meta_json" "节点元数据"
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

# >>>>>>>>> END MODULE: 60_user_db.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 61_user_manager.sh <<<<<<<<<<<
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
  local numbered="${2:-0}" row_number=0
  local sep=$'\t'
  local header widths_line row_line
  local -a rows=()
  local -a cols=()

  header="用户名${sep}状态${sep}已用 / 套餐${sep}进度${sep}重置日${sep}到期"
  rows+=("$header")

  while IFS= read -r row_line; do
    [ -n "$row_line" ] && rows+=("$row_line")
  done < <(
    printf '%s\n' "$db_json" | jq -r '
      .users
      | to_entries
      | .[]
      | (.value.enabled == true) as $en
      | (.value.disabled_reason // "") as $reason
      | (if $en then "正常"
         elif $reason == "quota" or $reason == "quota_exceeded" then "已达上限"
         elif $reason == "needs_review" then "停用待核对"
         elif $reason == "expired" then "已过期"
         else "已停用" end) as $st
      | ((.value.used_up_bytes // 0) + (.value.used_down_bytes // 0) + (.value.manual_added_bytes // 0)) as $used
      | (.value.quota_gb // 0) as $qgb
      | [
          .key,
          $st,
          ($used | tostring),
          ($qgb | tostring),
          (if (.value.reset_day // 0) == 0 then "不重置" elif (.value.reset_day // 0) == 32 then "月底" else ((.value.reset_day|tostring) + "号") end),
          (if (.value.expire_at // "0") == "0" then "永久" else (.value.expire_at // "0") end)
        ] | join("\u0001")
    ' | while IFS=$'\x01' read -r c_name c_status c_used c_qgb c_reset c_expire; do
          local used_txt usage_col bar_col pct
          used_txt="$(format_bytes_human "$c_used")"
          if [ "${c_qgb:-0}" -gt 0 ] 2>/dev/null; then
            usage_col="${used_txt} / ${c_qgb} GiB"
            pct="$(awk -v u="$c_used" -v q="$c_qgb" 'BEGIN {
              p = (u * 100.0) / (q * 1073741824.0);
              if (p < 0) p = 0;
              if (p > 100) p = 100;
              printf "%d", p + 0.5;
            }')"
            bar_col="$(ui_mini_bar "$pct" 8) ${pct}%"
          else
            usage_col="${used_txt} / 不限"
            bar_col="—"
          fi
          if [ "$numbered" = 1 ]; then
            row_number=$((row_number + 1))
            c_name="$row_number. $c_name"
          fi
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$c_name" "$c_status" "$usage_col" "$bar_col" "$c_reset" "$c_expire"
      done
  )

  widths_line="$(table_compute_widths "$sep" "${rows[@]}")"

  IFS="$sep" read -r -a cols <<< "$header"
  local header_line divider_line divider_width
  header_line="$(table_print_row "$widths_line" "${cols[@]}")"
  divider_width="$(text_display_width "$header_line")"
  divider_line=""
  local i
  for ((i=0; i<divider_width; i++)); do divider_line+="─"; done

  ui_echo "${W}${header_line}${NC}"
  ui_echo "${D}${divider_line}${NC}"

  for row_line in "${rows[@]:1}"; do
    IFS="$sep" read -r -a cols <<< "$row_line"
    table_print_row "$widths_line" "${cols[@]}"
  done

  ui_echo "${D}${divider_line}${NC}"
}

show_user_detail_card() {
  local db_json="$1" username="$2"
  local up down manual total
  IFS=$'\x01' read -r up down manual total < <(
    printf '%s\n' "$db_json" | jq -r --arg u "$username" '
      .users[$u] as $v
      | [
          (($v.used_up_bytes // 0) | tostring),
          (($v.used_down_bytes // 0) | tostring),
          (($v.manual_added_bytes // 0) | tostring),
          ((($v.used_up_bytes // 0) + ($v.used_down_bytes // 0) + ($v.manual_added_bytes // 0)) | tostring)
        ] | join("\u0001")
    '
  )
  printf '  %b流量明细：%b上传 %b%s%b · 下载 %b%s%b · 补正 %b%s%b · 合计 %b%s%b\n' \
    "$D" "$NC" "$C" "$(format_bytes_human "$up")" "$NC" \
    "$C" "$(format_bytes_human "$down")" "$NC" \
    "$C" "$(format_bytes_human "$manual")" "$NC" \
    "$W" "$(format_bytes_human "$total")" "$NC"
  printf '  上次成功采样 %s\n' "$(jq -r '.meta.data_updated_at_text | if . == null or . == "" then "尚无记录" else . end' <<< "$db_json")"
  jq -r '.meta.last_usage_gap_at_text // empty | "  上次可能缺计的时间 " + .' <<< "$db_json"
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
  db_json="$(user_db_load)" || return 1
  before_db="$db_json"
  json="$(user_manager_config_for_edit)" || return 1
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
  read -r -p "请输入流量限制（GiB，输入 0 表示不限，回车返回）: " quota
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
  echo ""
  if ask_confirm_default_yes "是否立即导出用户 ${username} 的节点配置？[Y/n]: "; then
    export_configs "$username" || true
  fi
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

  ui_echo "当前流量限制：${current_quota} GiB"
  ui_echo "${Y}折算成单向流量填入。示例：双向800G流量就填写400，单向500G流量就填写500${NC}"
  ui_echo "单位为 GiB ，输入 0 表示不限"
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
  ui_echo "已达额度的账号在清零后会按原授权恢复。手动停用和到期仍然有效。"
  local ans
  ask_confirm_yes "输入 yes 确认清零该用户流量（回车取消）: " || return 1
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
    user_manager_reconcile_user_state || return 1
    db_json="$(user_db_load)" || return 1
    json="$(user_manager_config_for_edit)" || return 1
    clear
    print_rect_title "管理用户 · ${username}"
    show_user_status_table "$db_json"
    show_user_detail_card "$db_json" "$username"
    [ $is_admin -eq 1 ] && echo -e "  ${D}admin 为系统默认管理员，不可删除，拥有全部节点权限。${NC}"
    show_user_allowed_nodes "$db_json" "$username"
    ui_hr
    local toggle_txt
    if jq -e --arg u "$username" '.users[$u].admin_allowed == true' <<< "$db_json" >/dev/null; then
      toggle_txt="禁止接入"
    else
      toggle_txt="允许接入（仍检查到期和额度）"
    fi
    echo -e "  ${C}1.${NC} ${toggle_txt}"
    [ $is_admin -eq 0 ] && echo -e "  ${C}2.${NC} 节点权限"
    echo -e "  ${C}3.${NC} 套餐与到期设置"
    echo -e "  ${C}4.${NC} 清零已用流量"
    echo -e "  ${C}5.${NC} 补正 / 调整流量"
    echo -e "  ${C}6.${NC} 一键续期"
    echo -e "  ${C}7.${NC} 导出该用户配置"
    echo -e "  ${D}0. 返回上一级${NC}"
    ui_hr
    read -r -p "请选择操作（回车返回）: " act
    case "${act:-}" in
      1)
        if jq -e --arg u "$username" '.users[$u].admin_allowed == true' <<< "$db_json" >/dev/null; then
          new_db="$(user_db_set_admin_allowed "$db_json" "$username" false)"
        else
          new_db="$(user_db_set_admin_allowed "$db_json" "$username" true)"
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
        if user_expire_is_past "$(user_today_date)" "$(printf '%s\n' "$db_json" | jq -r --arg u "$username" '.users[$u].expire_at // "0"')"; then mode=reset; fi
        new_db="$(user_renew_menu "$db_json" "$username")" || new_db=""
        if json_is_object "$new_db"; then
          user_manager_commit_edit "$db_json" "$new_db" "$mode" "$username" || true
        fi
        ;;
      7)
        export_configs "$username" || true
        ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

user_delete_menu() {
  local db_json json usernames=() ans new_db picks=() part idx username
  db_json="$(user_db_load)" || return 1
  json="$(user_manager_config_for_edit)" || return 1
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
  ask_confirm_yes "输入 yes 确认彻底删除（回车取消）: " || return 0

  new_db="$db_json"
  for username in "${names_to_delete[@]}"; do
    new_db="$(echo "$new_db" | jq --arg u "$username" 'del(.users[$u])')" || return 1
  done
  user_manager_commit_edit "$db_json" "$new_db" || true
  pause
}

user_manager_menu() {
  ensure_user_manager_ready || { pause; return 0; }
  local db_json choice
  local accounts=()
  while true; do
    user_manager_reconcile_user_state >/dev/null || return 1
    db_json="$(user_db_load)" || return 1
    clear
    print_rect_title "用户管理"
    show_user_status_table "$db_json" 1
    mapfile -t accounts < <(user_db_all_users "$db_json")
    printf '  a. 新增用户   d. 删除用户   0. 返回\n'
    read -r -p "选用户查看详情（回车返回）: " choice || return 0
    case "${choice:-}" in
      a) user_add_menu || true ;;
      d) user_delete_menu || true ;;
      0|q|Q|"") return 0 ;;
      *)
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#accounts[@]}" ]; then
          user_manage_single "${accounts[$((choice - 1))]}" || true
        else
          warn "请选择列表中的用户。"
          pause
        fi
        ;;
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
  with_manager_lock _tg_task_receipt_reserve_body "$@"
}

_tg_task_receipt_reserve_body() {
  local task_id="$1" now receipts
  [ -n "$task_id" ] || return 1
  now="$(date +%s)"
  receipts="$(tg_task_receipts_load | jq --arg id "$task_id" --argjson now "$now" '
    .tasks = (.tasks // {})
    | if .tasks[$id] != null then error("任务已领取") else
        .tasks[$id] = {status:"running", started_at:$now} end
    | .tasks |= with_entries(select(($now - (.value.completed_at // .value.started_at // $now)) <= 604800))
  ')" || return 1
  tg_task_receipts_save "$receipts"
}

# 任务执行结束后落盘最终结果；保存失败必须返回非零，由调用方决定是否上报主控
tg_task_receipt_finalize() {
  with_manager_lock _tg_task_receipt_finalize_body "$@"
}

_tg_task_receipt_finalize_body() {
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
#!/usr/bin/env python3
import contextlib
import datetime
import fcntl
import hmac
import http.server
import json
import logging
import os
import re
import secrets
import shutil
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

CONFIG_PATH = sys.argv[1] if len(sys.argv) > 1 else "/etc/sing-box-manager/telegram.json"
LOCK_PATH = os.environ.get("SB_LOCK_FILE") or "/var/lock/singbox-manager.lock"
REPORT_ONLINE_SECONDS = 900
MAX_REQUEST_BYTES = 1024 * 1024  # 1 MiB ceiling against malformed/oversized POST payloads

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("sb-tg-center")


def load_config():
    if not os.path.exists(CONFIG_PATH):
        return {}
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception as exc:
        logger.warning("Failed to parse %s: %s", CONFIG_PATH, exc)
        try:
            backup = f"{CONFIG_PATH}.corrupt.{int(time.time())}"
            if not os.path.exists(backup):
                shutil.copy2(CONFIG_PATH, backup)
        except OSError:
            pass
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
    os.makedirs(os.path.dirname(LOCK_PATH) or ".", exist_ok=True)
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
    cfg_dir = os.path.dirname(CONFIG_PATH) or "."
    os.makedirs(cfg_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".telegram.tmp.", dir=cfg_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, CONFIG_PATH)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


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
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=8)).date()


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
        if not item or int(item.get("expires_at") or 0) <= now:
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
    if not secret or not got:
        return False
    return hmac.compare_digest(str(got), str(secret))


class PayloadTooLargeError(ValueError):
    pass


def read_json(handler):
    raw_len = handler.headers.get("Content-Length") or "0"
    length = int(raw_len)
    if length < 0:
        raise ValueError("negative content-length")
    if length > MAX_REQUEST_BYTES:
        raise PayloadTooLargeError("payload too large")
    body = handler.rfile.read(length) if length > 0 else b"{}"
    data = json.loads(body.decode("utf-8") or "{}")
    if not isinstance(data, dict):
        raise ValueError("json payload must be an object")
    return data


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
        except PayloadTooLargeError:
            write_json(self, 413, {"ok": False, "error": "payload_too_large"})
            return
        except Exception:
            write_json(self, 400, {"ok": False, "error": "bad_json"})
            return

        if self.path == "/api/report":
            with cfg_lock():
                cfg = load_config()
                reports = cfg.setdefault("reports", {})
                now_utc8 = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=8)
                payload["received_at"] = int(time.time())
                payload["received_at_text"] = now_utc8.strftime("%Y-%m-%d %H:%M:%S")
                payload["updated_at_text"] = payload.get("data_updated_at_text") or ""
                reports[payload.get("vps_id") or "unknown"] = payload
                evaluate_reminders(cfg, payload)
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
  db_json="$(user_db_load)" || return 1
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
  new_db="$(user_db_set_admin_allowed "$db_json" "$username" "$enabled")" || return 1
  tg_task_apply_db "$new_db" || return 1
  if [ "$enabled" = "true" ]; then
    echo "已允许接入，仍按到期和额度判断。"
  else
    echo "用户已停用。"
  fi
}

tg_task_exec_set_quota() {
  local db_json="$1" username="$2" quota="$3" new_db text
  [[ "$quota" =~ ^[0-9]+$ ]] || return 1
  new_db="$(echo "$db_json" | jq --arg u "$username" --argjson quota "$quota" '.users[$u].quota_gb = $quota')" || return 1
  if [ "$quota" = "0" ]; then text="不限"; else text="${quota} GiB"; fi
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
  local task="$1" action username db_json exists params result _USER_SAMPLE_FAILED
  action="$(echo "$task" | jq -r '.action // empty')"
  username="$(echo "$task" | jq -r '.username // empty')"
  [ -n "$action" ] && [ -n "$username" ] || { echo "任务参数不完整。"; return 1; }
  user_db_exists || { user_db_restore_hint; return 1; }
  user_manager_sample_before_change
  db_json="$(user_db_load)" || return 1
  exists="$(echo "$db_json" | jq -r --arg u "$username" 'if .users[$u] then "1" else "0" end')"
  [ "$exists" = "1" ] || { echo "用户不存在：$username"; return 1; }
  params="$(echo "$task" | jq -c '.params // {}')"
  case "$action" in
    set_enabled)
      tg_task_exec_set_enabled "$db_json" "$username" "$(echo "$params" | jq -r '.enabled == true')" ;;
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
      warn "TG Bot 服务刷新失败，请到「Telegram Bot」检查。"
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

  echo "先在 Telegram 找 @BotFather 创建机器人，复制 Bot Token，并准备你的 Telegram 数字 ID。"
  # Bot Token（敏感字段不显示当前值）
  if [ -n "$cur_token" ]; then
    read -rs -p "Bot Token（回车保持当前值）: " token || return 0
    printf '\n' >&2
    [ -n "$token" ] || token="$cur_token"
  else
    read -rs -p "Bot Token（回车返回）: " token || return 0
    printf '\n' >&2
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
  ok "本机机器人已配置。"
  param_echo "主控地址" "$public_url"
  param_echo "接入密钥" "$secret"
  echo "在 Telegram 打开 @${username}，点「开始」，再回「Telegram Bot」选 3 发送测试。"
  echo "接入第二台服务器时，复制上方的主控地址和接入密钥。"
  pause
}

tg_setup_agent() {
  local cfg center_url secret vps_id vps_name
  local cur_url cur_secret cur_vps_name
  cfg="$(tg_config_load)"
  cur_url="$(echo "$cfg" | jq -r '.center_url // empty')"
  cur_secret="$(echo "$cfg" | jq -r '.access_secret // empty')"
  cur_vps_name="$(echo "$cfg" | jq -r '.vps_name // empty')"

  echo "到运行机器人的服务器，打开「Telegram Bot」，复制主控地址和接入密钥。"
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
    read -rs -p "接入密钥（回车保持当前值）: " secret || return 0
    printf '\n' >&2
    [ -n "$secret" ] || secret="$cur_secret"
  else
    read -rs -p "接入密钥（回车返回）: " secret || return 0
    printf '\n' >&2
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
  ok "已保存本机接入设置。"
  pause
}

tg_setup_menu() {
  local cfg enabled role ans
  clear
  print_rect_title "设置机器人"
  cfg="$(tg_config_load)"
  enabled="$(tg_config_enabled_value "$cfg")"
  role="$(echo "$cfg" | jq -r '.role // empty')"
  if [ "$enabled" != "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; }; then
    read -r -p "检测到已保留配置，是否恢复运行？[Y/n]: " ans || return 0
    case "${ans:-Y}" in
      [Nn]*) ;;
      *)
        tg_start_existing_config
        pause
        return
        ;;
    esac
  fi
  echo "  1. 在本机运行机器人（只有一台服务器就选这个）"
  echo "  2. 把本机接入已有机器人"
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
  [ "$enabled" = "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; } || { warn "请先在「Telegram Bot」选 1 设置或恢复机器人。"; pause; return 0; }
  user_db_exists || { warn "用户数据库不存在，请先安装并创建用户。"; pause; return 0; }
  db_json="$(user_db_load)" || return 1
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
  if ! [[ "$ans" =~ ^[1-9][0-9]*$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt "${#usernames[@]}" ]; then
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
    echo "把链接发给 ${username}，请对方在 10 分钟内打开并点「开始」。"
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
  [ "$enabled" = "true" ] && { [ "$role" = "center" ] || [ "$role" = "agent" ]; } || { warn "请先在「Telegram Bot」选 1 设置或恢复机器人。"; pause; return 0; }
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
  print_rect_title "停止机器人"
  echo "停止本机的机器人服务或数据上报。"
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
  local cfg enabled role role_label vps_name center_url access_secret act setup_label active
  while true; do
    clear
    print_rect_title "Telegram Bot"
    echo "管理员可以在 Telegram 管理用户，用户绑定后可以查自己的流量，也能收到到期提醒。"
    cfg="$(tg_config_load)"
    enabled="$(tg_config_enabled_value "$cfg")"
    role="$(jq -r '.role // ""' <<< "$cfg")"
    vps_name="$(jq -r '.vps_name // ""' <<< "$cfg")"
    center_url="$(jq -r '.center_url // ""' <<< "$cfg")"
    access_secret="$(jq -r '.access_secret // ""' <<< "$cfg")"
    setup_label="设置机器人"
    active=0
    case "$role" in
      center) role_label="本机运行机器人" ;;
      agent) role_label="已接入其他服务器的机器人" ;;
      *) role_label="未设置" ;;
    esac
    if [ "$role" = center ] || [ "$role" = agent ]; then
      if [ "$enabled" = true ]; then
        active=1
        install_tg_agent_cron >/dev/null 2>&1 || true
      else
        setup_label="恢复机器人"
        role_label="${role_label}（已停止）"
      fi
    fi
    printf '  当前状态：%s\n' "$role_label"
    if [ -n "$vps_name" ]; then printf '  本机名称：%s\n' "$vps_name"; fi
    if [ "$role" = center ] && [ -n "$center_url" ]; then
      printf '  主控地址：%s\n  接入密钥：%s\n' "$center_url" "$access_secret"
    fi
    case "$role" in
      '') echo "首次使用，选 1 设置机器人。" ;;
      center|agent)
        if [ "$active" -eq 0 ]; then echo "设置已保留，选 1 恢复。"; fi ;;
    esac
    ui_hr
    echo -e "  ${C}1.${NC} $setup_label"
    if [ "$active" -eq 1 ]; then
      echo -e "  ${C}2.${NC} 生成用户绑定链接"
      echo -e "  ${C}3.${NC} 发送通知测试"
      if [ "$role" = center ]; then echo -e "  ${C}4.${NC} 重启机器人"; fi
      echo -e "  ${R}5.${NC} 停止机器人"
    fi
    echo -e "  ${D}0. 返回主菜单${NC}"
    ui_hr
    read -r -p "请选择操作（回车返回）: " act || return 0
    case "${act:-}" in
      1) tg_setup_menu || true ;;
      2) if [ "$active" -eq 1 ]; then tg_generate_bind_link_menu || true; else warn "请先选 1。"; pause; fi ;;
      3) if [ "$active" -eq 1 ]; then tg_notify_test || true; else warn "请先选 1。"; pause; fi ;;
      4) if [ "$active" -eq 1 ] && [ "$role" = center ]; then tg_reload_center_service_menu || true; else warn "只有运行机器人的服务器可以重启它。"; pause; fi ;;
      5) if [ "$active" -eq 1 ]; then tg_disable_menu || true; else warn "机器人当前未运行。"; pause; fi ;;
      0|q|Q|"") return 0 ;;
      *) warn "无效输入：$act"; pause ;;
    esac
  done
}

# >>>>>>>>> END MODULE: 63_telegram_bot.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 64_warp.sh <<<<<<<<<<<
# ============================================================
# 模块: 64_warp.sh
# 职责: 管理 WARP 网站分流和生效状态
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 30_route.sh, 50_v2ray_api.sh
# ============================================================

WARP_PROXY_FILE="/etc/wireguard/proxy.conf"
WARP_RULE_BASE_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
WARP_RULE_LOOKUP_URL="https://github.com/SagerNet/sing-geosite/tree/rule-set"

warp_hr() {
  ui_hr
}

warp_meta_json() {
  warp_meta_json_from_meta "$(meta_load)"
}

warp_meta_json_from_meta() {
  jq -c '
    (.warp // {mode:"off", rules:[]})
    | .mode = (if (.mode // "off") == "rules" then "rules" else "off" end)
    | .rules = [
        (.rules // [])[]?
        | select((.file // "") != "")
        | .tag = ("relay-" + ((.file // "" | sub("\\.srs$"; "")) | gsub("[^A-Za-z0-9_-]"; "-")))
      ]
  ' <<< "$1"
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
  split_rule_normalize_file "$@"
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
    err "尚未安装 sing-box，无法写入 WARP 分流规则。"
    warn "请先在主菜单进入「安装与卸载」安装 sing-box。"
    pause
    return 1
  }
  config_ensure_exists
  ensure_manager_file_permissions
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
  local json="$1" rules="$2" backend="$3"
  jq --argjson rules "$rules" --argjson backend "$backend" '
    ($rules | map(.tag)) as $wanted
    | ([.route.rules[]? | select(.outbound == "warp") | .rule_set // [] |
        if type == "array" then .[] else . end] + $wanted | unique) as $managed
    | .route = (.route // {rules:[]})
    | .route.rules = [.route.rules[]? | select(.outbound != "warp")]
    | .route.rule_set = (
        [.route.rule_set[]? | .tag as $tag
          | select(($tag|startswith("warp-geosite-")|not) and ($managed|index($tag))==null)]
        + ($rules | map({type:"remote",tag:.tag,format:"binary",url:.url,http_client:{version:2,detour:"direct"}}))
      )
    | .outbounds = ([.outbounds[]? | select(.tag != "warp")]
        + (if $backend.type == "socks" then [$backend] else [] end))
    | .endpoints = ([.endpoints[]? | select(.tag != "warp")]
        + (if $backend.type == "wireguard" then [$backend] else [] end))
    | if .endpoints == [] then del(.endpoints) else . end
    | if $backend.type == "wireguard" then
        .dns.servers = ([.dns.servers[]? | select(.tag != "sb-warp-resolver")]
          + [{type:"local",tag:"sb-warp-resolver"}])
      elif any(.dns.servers[]?; .tag=="sb-warp-resolver") then
        .dns.servers |= map(select(.tag != "sb-warp-resolver"))
        | if .dns == {servers:[]} then del(.dns) else . end
      else . end
  ' <<< "$json"
}

warp_apply_meta_json_state() {
  local previous="$1" meta_json="$2" backend="$3" json rules projected rebuilt
  json="$(user_manager_config_for_edit)" || return 1
  rules="$(jq -c '.warp.rules // [] | unique_by(.tag)' <<< "$meta_json")" || return 1
  if [ "$rules" = '[]' ]; then
    backend=null
  elif [ "$backend" = null ]; then
    backend="$(jq -c 'first((.outbounds[]?, .endpoints[]?)|select(.tag=="warp")) // null' <<< "$json")" || return 1
    [ "$backend" != null ] || { err "当前分流缺少出口，请重新选择要启用的网站。"; return 1; }
  fi
  projected="$(warp_config_project_json "$json" "$rules" "$backend")" || return 1
  rebuilt="$(relay_project_partial_state_with_meta "$projected" "$meta_json")" || return 1
  if [ "$(jq -Sc . <<< "$json")" = "$(jq -Sc . <<< "$rebuilt")" ] &&
     [ "$(jq -Sc . <<< "$previous")" = "$(jq -Sc . <<< "$meta_json")" ]; then
    return 0
  fi
  if ! run_with_spinner "应用 WARP 分流" with_manager_lock protocol_commit_changes "$json" "$previous" "$rebuilt" "$meta_json"; then
    err "分流应用失败。请查看上方配置检查或回滚结果。"
    return 1
  fi
}

warp_validate_download() (
  local file="$1" dir url
  umask 077
  dir="$(mktemp -d)" || return 1
  trap 'rm -rf "$dir"' EXIT
  url="$(warp_rule_url_for_file "$file")" || return 1
  curl -q -fsSL --proto '=https' --connect-timeout 8 --max-time 20 "$url" -o "$dir/rule.srs" &&
    sing-box rule-set decompile -o "$dir/rule.json" "$dir/rule.srs" >/dev/null
)

warp_enable_rules() {
  local files_json previous relay_json warp_json next backend file item
  local -a items=("$@") files=()
  for item in "${items[@]}"; do files+=("${item#*|}"); done
  files_json="$(split_rule_files_json_from_args "${files[@]}")" || return 1
  previous="$(meta_load)" || return 1
  split_rule_confirm_relay_to_warp "$files_json" || return 1
  warp_json="$(warp_meta_json_from_meta "$previous")" || return 1
  for item in "${items[@]}"; do
    file="${item#*|}"
    if ! jq -e --arg file "$file" 'any(.rules[]?; .file==$file)' <<< "$warp_json" >/dev/null; then
      if ! run_with_spinner "下载并检查 $file" warp_validate_download "$file"; then
        err "规则下载或格式检查失败：$file"
        return 1
      fi
    fi
    warp_json="$(warp_rule_add_meta_to_json "$warp_json" "${item%%|*}" "$file")" || return 1
  done
  warp_prepare_backend backend || return 1
  relay_json="$(relay_meta_json_from_meta "$previous")" || return 1
  relay_json="$(relay_rule_remove_meta_by_files_json_from "$relay_json" "$files_json")" || return 1
  next="$(relay_meta_replace_in_meta_json "$previous" "$relay_json")" || return 1
  next="$(warp_meta_replace_in_meta_json "$next" "$warp_json")" || return 1
  warp_apply_meta_json_state "$previous" "$next" "$backend" || return 1
  ok "所选网站已走 WARP。"
}

warp_add_preset_rules() {
  local raw="$1" pick
  local -a picks=() items=()
  mapfile -t picks < <(parse_plus_selections "$raw")
  [ "${#picks[@]}" -gt 0 ] || return 1
  for pick in "${picks[@]}"; do
    if ! [[ "$pick" =~ ^[1-6]$ ]]; then
      err "请输入 1–6，多个编号用 + 连接。"
      return 1
    fi
    items+=("$(warp_preset_rule "$pick")")
  done
  warp_require_singbox && warp_enable_rules "${items[@]}"
}

warp_custom_rule_menu() {
  local raw file
  clear
  print_rect_title "自定义网站规则"
  echo "输入规则名，例如 openai。规则列表：$WARP_RULE_LOOKUP_URL"
  read -r -p "规则名（回车返回）: " raw || return 0
  [ -n "$raw" ] || return 0
  file="$(warp_normalize_rule_file "$raw")" || return 1
  warp_require_singbox && warp_enable_rules "${file%.srs}|$file"
}

warp_rules_delete_menu() {
  local rules_json count raw n tag tags_json has_delete_all=0 meta_json warp_json previous
  local -a idx=()
  local -a selected_tags=()
  previous="$(meta_load)" || return 1
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
    ask_confirm_yn "确认取消全部 WARP 分流？(y/N): " || return 0
    meta_json="$(warp_meta_replace_in_meta_json "$previous" '{"mode":"off","rules":[]}')" || return 1
    warp_apply_meta_json_state "$previous" "$meta_json" null || return 1
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
  meta_json="$(warp_meta_replace_in_meta_json "$previous" "$warp_json")" || return 1
  warp_apply_meta_json_state "$previous" "$meta_json" null || return 1
  ok "已删除指定 WARP 分流。"
  pause
}

warp_manager_menu() {
  local act
  warp_init_env || { pause; return 0; }
  while true; do
    clear
    print_rect_title "WARP 分流"
    echo "让选中的网站走 WARP。首次使用会自动配置。"
    split_rule_overview_lines
    warp_hr
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
    read -r -p "选择网站或操作: " act || return 0
    case "${act:-}" in
      0|q|Q|"") return 0 ;;
      7) warp_custom_rule_menu || true; pause ;;
      8) warp_rules_delete_menu || true ;;
      *+*|[1-6]) warp_add_preset_rules "$act" || true; pause ;;
      *) warn "无效输入：$act"; sleep 1 ;;
    esac
  done
}

# >>>>>>>>> END MODULE: 64_warp.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 65_warp_backend.sh <<<<<<<<<<<
# WARP backend discovery, device registration and isolated verification.

warp_wireproxy_configs() {
  local pid arg take cwd path
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    take=0
    while IFS= read -r -d '' arg; do
      if [ "$take" -eq 1 ]; then
        path="$arg"
      else
        case "$arg" in
          -c|--config) take=1; continue ;;
          --config=*|-c=*) path="${arg#*=}" ;;
          *) continue ;;
        esac
      fi
      take=0
      if [[ "$path" != /* ]]; then
        cwd="$(readlink "/proc/$pid/cwd")" || continue
        path="$cwd/$path"
      fi
      [ ! -r "$path" ] || printf '%s\n' "$path"
    done < "/proc/$pid/cmdline"
  done < <(pgrep -x wireproxy 2>/dev/null || true)
  for path in "$WARP_PROXY_FILE" /etc/wireproxy/config /etc/wireproxy/config.conf /etc/wireproxy/wireproxy.conf; do
    [ ! -r "$path" ] || printf '%s\n' "$path"
  done
}

warp_wireproxy_candidates() {
  local file addr user pass host port listeners
  listeners=""
  if has_cmd ss; then listeners="$(ss -nltpH 2>/dev/null)" || listeners=""; fi
  while IFS= read -r file; do
    while IFS=$'\x1f' read -r addr user pass; do
      if [[ "$addr" =~ ^(127\.[0-9]+\.[0-9]+\.[0-9]+|localhost|0\.0\.0\.0|\*|\[::1\]|\[::\]):([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}" port="${BASH_REMATCH[2]}"
      else
        continue
      fi
      case "$host" in
        '[::]'|'[::1]') host=::1 ;;
        localhost|0.0.0.0|'*') host=127.0.0.1 ;;
      esac
      [[ "$port" =~ ^[1-9][0-9]*$ ]] && is_valid_port "$port" || continue
      if [ -n "$listeners" ] && ! awk -v addr="$addr" -v port="$port" '
        /"wireproxy"/ && ($4==addr || $4=="*:"port || $4=="0.0.0.0:"port || $4=="[::]:"port ||
          (addr=="localhost:"port && $4=="127.0.0.1:"port)) {found=1}
        END {exit !found}
      ' <<< "$listeners"; then
        continue
      fi
      jq -nc --arg host "$host" --argjson port "$port" --arg user "$user" --arg pass "$pass" '
        {type:"socks",tag:"warp",version:"5",server:$host,server_port:$port,network:"tcp"}
        | if $user != "" or $pass != "" then .+{username:$user,password:$pass} else . end'
    done < <(awk '
      function flush() {
        if (socks && !filtered && addr != "") printf "%s\037%s\037%s\n",addr,user,pass
        addr=user=pass=""; filtered=0
      }
      /^[[:space:]]*\[/ {
        flush()
        socks=(tolower($0) ~ /^[[:space:]]*\[socks5\][[:space:]\r]*$/)
        next
      }
      socks && /^[[:space:]]*[A-Za-z]+[[:space:]]*=/ {
        key=$0; sub(/=.*/, "", key); gsub(/[[:space:]]/, "", key)
        value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value)
        key=tolower(key)
        if (key=="bindaddress") addr=value
        if (key=="username") user=value
        if (key=="password") pass=value
        if (key=="tunneldomains" && value!="") filtered=1
      }
      END {flush()}
    ' "$file")
  done < <(warp_wireproxy_configs | awk '!seen[$0]++')
}

warp_wireproxy_service() {
  local unit
  case "$INIT_SYSTEM" in
    systemd)
      for unit in wireproxy warp-wireproxy; do
        if [ "$(systemctl show -p LoadState --value "$unit.service" 2>/dev/null)" = loaded ]; then
          printf '%s\n' "$unit.service"; return
        fi
      done ;;
    openrc)
      for unit in wireproxy warp-wireproxy; do
        if [ -x "/etc/init.d/$unit" ]; then printf '%s\n' "$unit"; return; fi
      done ;;
  esac
  return 1
}

warp_start_wireproxy() {
  case "$INIT_SYSTEM" in
    systemd) timeout 30 systemctl start "$1" ;;
    openrc) timeout 30 rc-service "$1" start ;;
    *) return 1 ;;
  esac
}

warp_probe_config() {
  local backend="$1" port="$2" token="$3"
  jq -nc --argjson w "$backend" --argjson port "$port" --arg token "$token" '
    {log:{disabled:true},inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$port,
      users:[{username:"warp-probe",password:$token}]}],route:{final:"warp"}}
    | if $w.type=="wireguard" then
        .endpoints=[$w] | .dns={servers:[{type:"local",tag:"sb-warp-resolver"}]}
      else .outbounds=[$w] end'
}

warp_probe_backend() (
  local backend="$1" dir pid='' port token attempt result
  umask 077
  dir="$(mktemp -d)" || return 1
  trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$dir"' EXIT
  token="$RANDOM$RANDOM$RANDOM$RANDOM"
  for attempt in 1 2 3; do
    port=$((20000+RANDOM))
    warp_probe_config "$backend" "$port" "$token" > "$dir/config.json" || return 1
    sing-box run -c "$dir/config.json" > "$dir/core.log" 2>&1 &
    pid=$!
    sleep 0.25
    if kill -0 "$pid" 2>/dev/null; then break; fi
    wait "$pid" 2>/dev/null || true
    pid=''
  done
  [ -n "$pid" ] || return 1
  result="$(curl -q -fsS --connect-timeout 4 --max-time 18 --noproxy '' --proxy-user "warp-probe:$token" \
    --socks5-hostname "127.0.0.1:$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  tr -d '\r' <<< "$result" | grep -Ex 'warp=(on|plus)' >/dev/null
)

warp_profile_endpoint() {
  awk -F= '
    /^[[:space:]]*\[/ { section=$0; gsub(/[[:space:]\[\]]/,"",section); next }
    NF>1 {
      k=$1; gsub(/[[:space:]]/,"",k)
      v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]]*$/,"",v)
      if (section=="Interface" && k=="Address") address=address (address==""?"":",") v
      if (section=="Interface" && k=="PrivateKey") private=v
      if (section=="Interface" && k=="MTU") mtu=v
      if (section=="Peer" && k=="Endpoint") endpoint=v
      if (section=="Peer" && k=="PublicKey") public=v
      if (section=="Peer" && k=="AllowedIPs") allowed=allowed (allowed==""?"":",") v
    }
    END {
      print address; print private; print mtu; print endpoint; print public; print allowed
    }
  ' "$1" | jq -Rsec '
    split("\n") as $v | ($v[3]|capture("^(?<host>.+):(?<port>[0-9]+)$")) as $peer
    | def csv: split(",") | map(gsub("[[:space:]]";"") | select(length>0));
      {type:"wireguard",tag:"warp",system:false,domain_resolver:{server:"sb-warp-resolver",strategy:"prefer_ipv4"},
       address:($v[0]|csv),private_key:$v[1],mtu:($v[2]|if .=="" then 1280 else tonumber end),
       peers:[{address:($peer.host|ltrimstr("[")|rtrimstr("]")),port:($peer.port|tonumber),
           public_key:$v[4],allowed_ips:($v[5]|csv)}]}
    | select((.address|length)>0 and (.private_key|length)>0 and
      (.peers[0] | (.public_key|length)>0 and (.allowed_ips|length)>0))'
}

warp_check_core() (
  local dir key sample
  umask 077
  dir="$(mktemp -d)" || return 1
  trap 'rm -rf "$dir"' EXIT
  key='EAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEA='
  sample="$(jq -nc --arg k "$key" '{type:"wireguard",tag:"warp",system:false,address:["192.0.2.2/32"],
    private_key:$k,peers:[{address:"192.0.2.1",port:51820,public_key:$k,allowed_ips:["0.0.0.0/0"]}]}')" || return 1
  warp_probe_config "$sample" 23456 check-only > "$dir/check.json" || return 1
  sing-box check -c "$dir/check.json" >/dev/null 2>&1
)

warp_download_wgcf() (
  local dir="$1" version=2.2.30 arch asset digest temp
  case "$(uname -m)" in
    x86_64) arch=amd64; digest=fc443008fe29a6f0b05b45d27436b7ce89e87a6836718597ccb39e41da418304 ;;
    aarch64|arm64) arch=arm64; digest=761f1d35157feb7c527cd8b13fbe428b47a9786af207a73e380630609c3d1f40 ;;
    i386|i486|i586|i686) arch=386; digest=0019c8c83efb4a1cde5aa70b830febb45edd5b9541ec232310e936938f18fad6 ;;
    armv7*) arch=armv7; digest=e7b2db8265295866d4e4f49163c23771e7b4e289d5e74d04cdacea291fd9c500 ;;
    armv6*) arch=armv6; digest=6fbe74e05c4117f1f089f94c0be166f82725e4a887d6f0d00c69502f0f53bb91 ;;
    s390x) arch=s390x; digest=1b43b91625f8cb98057ae36c2777f31e9203e69e0c26628620ba4da2a50f07fa ;;
    *) err "wgcf 暂不支持此 CPU 架构。"; return 1 ;;
  esac
  if [ -x "$dir/wgcf" ] && printf '%s  %s\n' "$digest" "$dir/wgcf" | sha256sum -c - >/dev/null 2>&1; then return 0; fi
  asset="wgcf_${version}_linux_${arch}"
  temp="$(mktemp "$dir/.wgcf.XXXXXX")" || return 1
  trap 'rm -f "$temp"' EXIT
  curl -q -fsSL --proto '=https' --connect-timeout 8 --max-time 45 \
    "https://github.com/ViRb3/wgcf/releases/download/v$version/$asset" -o "$temp" || return 1
  printf '%s  %s\n' "$digest" "$temp" | sha256sum -c - >/dev/null || return 1
  chmod 700 "$temp" && mv -f "$temp" "$dir/wgcf"
)

warp_wgcf_profile() (
  local dir="$1" account="$1/wgcf-account.toml" profile="$1/wgcf-profile.conf" tmp
  umask 077
  if [ -s "$profile" ]; then return 0; fi
  warp_download_wgcf "$dir" || { err "wgcf 下载或校验失败。"; return 1; }
  if [ ! -s "$account" ]; then
    if ! timeout 40 "$dir/wgcf" --config "$account" register --accept-tos >/dev/null 2>&1; then
      [ -s "$account" ] || { err "WARP 注册失败，请检查网络后重试。"; return 1; }
    fi
  fi
  tmp="$(mktemp "$dir/.profile.XXXXXX")" || return 1
  trap 'rm -f "$tmp"' EXIT
  if ! timeout 40 "$dir/wgcf" --config "$account" generate --profile "$tmp" >/dev/null 2>&1; then
    err "获取 WARP 连接资料失败，下次会复用已注册设备。"
    return 1
  fi
  warp_profile_endpoint "$tmp" >/dev/null || { err "WARP 连接资料无法读取。"; return 1; }
  mv -f "$tmp" "$profile"
)

warp_find_verified_wireproxy() {
  local outvar="$1" item
  while IFS= read -r item; do
    if run_with_spinner "验证 WireProxy 的 WARP 出口" warp_probe_backend "$item"; then
      printf -v "$outvar" '%s' "$item"
      return 0
    fi
  done < <(warp_wireproxy_candidates)
  return 1
}

warp_prepare_backend() {
  local outvar="$1" candidate unit dir
  if warp_find_verified_wireproxy candidate; then
    printf -v "$outvar" '%s' "$candidate"
    return 0
  fi
  unit="$(warp_wireproxy_service)" || unit=''
  if [ -n "$unit" ]; then
    local running=0
    case "$INIT_SYSTEM" in
      systemd) systemctl is-active --quiet "$unit" && running=1 ;;
      openrc) rc-service "$unit" status >/dev/null 2>&1 && running=1 ;;
    esac
    if [ "$running" -eq 0 ]; then
      ask_confirm_yes "WireProxy 已停止。启动它？输入 yes 确认: " || return 1
      run_with_spinner "启动 WireProxy" warp_start_wireproxy "$unit" || return 1
      if warp_find_verified_wireproxy candidate; then
        printf -v "$outvar" '%s' "$candidate"
        return 0
      fi
    fi
  fi
  if [ -n "$unit" ] || pgrep -x wireproxy >/dev/null 2>&1 || [ -n "$(warp_wireproxy_configs)" ]; then
    err "WireProxy 未通过 WARP 验证。请检查 SOCKS5 地址、认证和隧道后重试。"
    return 1
  fi
  if ! warp_check_core; then
    err "当前 sing-box 不支持用户态 WireGuard，请先更新内核。"
    return 1
  fi
  dir="$(dirname "$META_FILE")/warp"
  if [ ! -s "$dir/wgcf-account.toml" ] && [ ! -s "$dir/wgcf-profile.conf" ]; then
    ui_echo "首次会用 wgcf 注册。Cloudflare 条款 https://www.cloudflare.com/application/terms/"
    ask_confirm_yes "同意条款并继续？输入 yes 确认: " || return 1
  fi
  (umask 077; mkdir -p "$dir" && chmod 700 "$dir") || return 1
  run_with_spinner "准备 WARP 连接资料" with_manager_lock warp_wgcf_profile "$dir" || return 1
  candidate="$(warp_profile_endpoint "$dir/wgcf-profile.conf")" || return 1
  if ! run_with_spinner "验证 WARP 隧道" warp_probe_backend "$candidate"; then
    err "未能通过 WARP 访问 Cloudflare，已保留注册资料，可稍后重试。"
    return 1
  fi
  printf -v "$outvar" '%s' "$candidate"
}

# >>>>>>>>> END MODULE: 65_warp_backend.sh <<<<<<<<<<<

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

uri_host() {
  local host="$1"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then printf '[%s]' "$host"; else printf '%s' "$host"; fi
}

tls_export_self_signed() {
  local tls="$1" cert inline subject issuer
  cert="$(jq -r '.certificate_path // empty' <<< "$tls")" || return 1
  inline="$(jq -r '.certificate // empty | if type == "array" then join("\n") else . end' <<< "$tls")"
  if [ -n "$cert" ] && [ -r "$cert" ]; then inline="$(cat "$cert")" || return 1; fi
  if [ -z "$inline" ]; then
    [[ "$cert" =~ ^/etc/sing-box/(hy2|anytls|trojan|tuic)-[0-9]+\.crt$ ]]
    return
  fi
  subject="$(openssl x509 -noout -subject -nameopt RFC2253 <<< "$inline" 2>/dev/null)" || return 1
  issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 <<< "$inline" 2>/dev/null)" || return 1
  [ "${subject#subject=}" = "${issuer#issuer=}" ]
}

build_v2rayn_ss_link() {
  local server="$1" port="$2" method="$3" password="$4" name="$5" enc
  if [[ "$method" == 2022-* ]]; then
    enc="$(url_encode "$method"):$(url_encode "$password")"
  else
    enc="$(b64_std_no_wrap "$method:$password" | tr '/+' '_-' | tr -d '=')"
  fi
  printf 'ss://%s@%s:%s#%s' "$enc" "$(uri_host "$server")" "$port" "$(url_encode "$name")"
}

build_v2rayn_vmess_ws_link() {
  local server="$1" uuid="$2" host="$3" path="$4" name="$5" port="${6:-443}"
  local payload
  payload="$(jq -nc --arg ps "$name" --arg add "$server" --arg port "$port" --arg id "$uuid" \
    --arg host "$host" --arg path "$path" \
    '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:$path,tls:"tls",sni:$host}')"
  printf 'vmess://%s' "$(b64_std_no_wrap "$payload")"
}

build_v2rayn_vless_reality_link() {
  local server="$1" port="$2" uuid="$3" sni="$4" pbk="$5" sid="$6" flow="$7" name="$8"
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$uuid" "$(uri_host "$server")" "$port" "$(url_encode "$flow")" "$(url_encode "$sni")" \
    "$(url_encode "$pbk")" "$(url_encode "$sid")" "$(url_encode "$name")"
}

build_v2rayn_vless_ws_link() {
  local server="$1" uuid="$2" host="$3" path="$4" name="$5" port="${6:-443}"
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
    "$uuid" "$(uri_host "$server")" "$port" "$(url_encode "$host")" "$(url_encode "$host")" \
    "$(url_encode "$path")" "$(url_encode "$name")"
}

build_v2rayn_anytls_link() {
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  local insecure="${6:-true}" alpn="${7-h2,http/1.1}" query
  query="sni=$(url_encode "$sni")&fp=chrome"
  [ -z "$alpn" ] || query+="&alpn=$(url_encode "$alpn")"
  [ "$insecure" = false ] || query+="&insecure=1"
  printf 'anytls://%s@%s:%s?%s#%s' \
    "$(url_encode "$password")" "$(uri_host "$server")" "$port" "$query" "$(url_encode "$name")"
}

build_v2rayn_trojan_link() {
  local server="$1" port="$2" password="$3" sni="$4" name="$5"
  local insecure="${6:-true}" alpn="${7:-}" query
  query="security=tls&sni=$(url_encode "$sni")"
  [ -z "$alpn" ] || query+="&alpn=$(url_encode "$alpn")"
  [ "$insecure" = false ] || query+="&allowInsecure=1"
  printf 'trojan://%s@%s:%s?%s#%s' \
    "$(url_encode "$password")" "$(uri_host "$server")" "$port" "$query" "$(url_encode "$name")"
}

build_v2rayn_tuic_link() {
  local server="$1" port="$2" uuid="$3" password="$4" sni="$5" name="$6"
  local insecure="${7:-true}" alpn="${8:-h3}" cc="${9:-bbr}" query
  query="sni=$(url_encode "$sni")&alpn=$(url_encode "$alpn")&congestion_control=$(url_encode "$cc")"
  [ "$insecure" = false ] || query+="&allow_insecure=1"
  printf 'tuic://%s:%s@%s:%s?%s#%s' \
    "$uuid" "$(url_encode "$password")" "$(uri_host "$server")" "$port" "$query" "$(url_encode "$name")"
}

build_v2rayn_hysteria2_link() {
  local server="$1" port="$2" password="$3" sni="$4" obfs_type="$5" obfs_pass="$6" name="$7"
  local insecure="${8:-true}" query
  query="sni=$(url_encode "$sni")"
  [ "$insecure" = false ] || query+="&insecure=1"
  if [ -n "$obfs_type" ]; then
    query+="&obfs=$(url_encode "$obfs_type")&obfs-password=$(url_encode "$obfs_pass")"
  fi
  printf 'hysteria2://%s@%s:%s/?%s#%s' \
    "$(url_encode "$password")" "$(uri_host "$server")" "$port" "$query" "$(url_encode "$name")"
}

build_socks_link() {
  printf 'socks5://%s:%s@%s:%s' "$(url_encode "$3")" "$(url_encode "$4")" "$(uri_host "$1")" "$2"
}

# 从 meta 取某 hy2 节点的跳跃范围 "42310-45545"，没有返回空。
hy2_export_hop_range() {
  local tag="$1" meta_json="${2:-}"
  [ -n "$meta_json" ] || meta_json="$(meta_load 2>/dev/null || echo '{}')"
  hy2_hop_range_from_meta "$meta_json" "$tag"
}

# ---------- 导出上下文收集 ----------

export_collect_context() {
  local json="$1" meta="${2:-}"
  [ -n "$meta" ] || meta='{}'
  local ip=""
  if jq -e --argjson meta "$meta" "${JQ_DETECT_PROTOCOL}"'
    all(.inbounds[]?; (detect_protocol) as $p | $p == "" or ($p|endswith("-ws")) or ($meta[.tag].public_endpoint.host // "") != "")
  ' <<< "$json" >/dev/null; then
    ip=""
  elif [ -z "${_CACHED_PUBLIC_IP:-}" ] && [ -t 1 ] && [ -t 2 ]; then
    local ip_tmp
    ip_tmp="$(mktemp /tmp/sb-ip.XXXXXX)"
    if run_with_spinner "正在获取服务器公网 IP..." bash -c '
      ip=$(curl -s4 --max-time 3 --connect-timeout 2 ifconfig.me 2>/dev/null || true)
      [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 api.ipify.org 2>/dev/null || true)
      [ -z "$ip" ] && ip=$(curl -s4 --max-time 3 --connect-timeout 2 icanhazip.com 2>/dev/null | tr -d "\n" || true)
      printf "%s" "${ip:-IP}" > "'"$ip_tmp"'"
    '; then
      ip="$(cat "$ip_tmp" 2>/dev/null || echo IP)"
      _CACHED_PUBLIC_IP="$ip"
    else
      ip="$(get_public_ip)"
    fi
    rm -f "$ip_tmp" >/dev/null 2>&1 || true
  else
    ip="$(get_public_ip)"
  fi
  jq -n --arg ip "$ip" '{ip:$ip}'
}

# ---------- 主导出函数 ----------

export_collect_records() {
  local filter_user="${1:-__admin__}" allowed_tags="${2:-}"
  [ "$filter_user" != admin ] || filter_user=__admin__
  local json meta_json ctx ip db
  local tag proto port sni path sid method server_p obfs_type obfs_pass
  local name uuid pass flow out_name pw_out business_user reality_public_key v2rayn_link
  local hop_range qx_line clash_line tls cc endpoint node_host node_port cdn_label early ws_options
  local public_address insecure qx_verify alpn_csv yn yh yp ys ypath yobf
  local -A tls_policy=() reality_keys=()
  json="$(config_load)" || return 1
  if [ -n "$allowed_tags" ]; then
    json="$(jq --argjson tags "$allowed_tags" '
      .inbounds |= map(.tag as $tag | select(($tags | index($tag)) != null))
    ' <<< "$json")" || return 1
  fi
  meta_json="$(meta_load 2>/dev/null || echo '{}')"
  [ -n "$meta_json" ] || meta_json='{}'

  db='null'
  if declare -F user_db_exists >/dev/null && user_db_exists; then
    db="$(user_db_load)" || return 1
    db="$(user_manager_evaluate_state "$db")" || return 1
  elif declare -F user_db_is_first_use >/dev/null && ! user_db_is_first_use; then
    user_db_restore_hint
    return 1
  fi
  ctx="$(export_collect_context "$json" "$meta_json")" || return 1
  ip="$(jq -r '.ip // ""' <<< "$ctx")" || return 1

  # 单次 jq 展开全部 inbound × user，减少高频子进程 fork
  while IFS=$'\x01' read -r tag proto port sni path sid method server_p obfs_type obfs_pass name uuid pass flow tls cc endpoint; do
    [ -z "$name" ] && continue
    out_name="$name"

    business_user=admin
    if [[ "$name" == *"@"* ]]; then business_user="$(user_business_name "$name")"; fi
    [ "$filter_user" = __all__ ] || [ "$filter_user" = "$business_user" ] ||
      { [ "$filter_user" = __admin__ ] && [ "$business_user" = admin ]; } || continue
    IFS=$'\x01' read -r node_host node_port cdn_label early < <(
      jq -r '[.host // "", (.port // "" | tostring), (.operator_evidence.operator // ""),
              (.early_data // 0 | tostring)] | join("\u0001")' <<< "$endpoint"
    )
    case "$proto" in
      vmess-ws|vless-ws)
        node_port="${node_port:-443}"
        if [ -z "$node_host" ]; then
          export_record "$out_name" "$proto" "" "" "" "请在「接入已有 CDN」中验证并保存公网入口。"
          continue
        fi
        if jq -e '.verified == true' <<< "$endpoint" >/dev/null; then
          if [ -n "$cdn_label" ]; then cdn_label="${cdn_label}入口"; else cdn_label="CDN 自动"; fi
          case "$proto" in
            vmess-ws) out_name="$out_name · VMess-WS · $cdn_label" ;;
            vless-ws) out_name="$out_name · VLESS-WS · $cdn_label" ;;
          esac
        fi
        ;;
      *)
        node_host="${node_host:-$ip}"
        node_port="${node_port:-$port}"
        ;;
    esac
    public_address="$(uri_host "$node_host"):$node_port"
    if [ -z "${tls_policy[$tag]+set}" ]; then
      tls_policy[$tag]=false
      if tls_export_self_signed "$tls"; then tls_policy[$tag]=true; fi
    fi
    insecure="${tls_policy[$tag]}"
    qx_verify=true
    [ "$insecure" = false ] || qx_verify=false
    alpn_csv="$(jq -r '(.alpn // []) | join(",")' <<< "$tls")"
    IFS=$'\x01' read -r yn yh yp ys ypath yobf < <(
      jq -nr --args '$ARGS.positional | map(@json) | join("\u0001")' -- \
        "$out_name" "$node_host" "$pass" "$sni" "$path" "$obfs_pass"
    )
    v2rayn_link='' clash_line='' qx_line=''
    case "$proto" in
      vless-reality)
        [ -n "$uuid" ] || continue
        if [ -z "${reality_keys[$tag]+set}" ]; then
          reality_public_key="$(jq -r --arg tag "$tag" '.[$tag].public_key // empty' <<< "$meta_json")"
          if [ -z "$reality_public_key" ]; then
            reality_public_key="$(reality_public_key_from_private "$(jq -r '.reality.private_key // empty' <<< "$tls")")" || reality_public_key=''
          fi
          reality_keys[$tag]="$reality_public_key"
        fi
        reality_public_key="${reality_keys[$tag]}"
        if [ -z "$reality_public_key" ]; then
          export_record "$out_name" "$proto" "" "" "" "Reality 公钥无法恢复，请检查密钥资料。"
          continue
        fi
        v2rayn_link="$(build_v2rayn_vless_reality_link "$node_host" "$node_port" "$uuid" "$sni" "$reality_public_key" "$sid" "$flow" "$out_name")"
        clash_line="{name: $yn, type: vless, server: $yh, port: $node_port, uuid: $uuid, network: tcp, udp: true, tls: true, flow: $flow, servername: $ys, reality-opts: {public-key: $reality_public_key, short-id: '$sid'}, client-fingerprint: chrome}"
        qx_line="vless=$public_address, method=none, password=$uuid, obfs=over-tls, obfs-host=$sni, reality-base64-pubkey=$reality_public_key, reality-hex-shortid=$sid, vless-flow=$flow, udp-relay=true, tag=$out_name"
        ;;
      anytls)
        [ -n "$pass" ] || continue
        v2rayn_link="$(build_v2rayn_anytls_link "$node_host" "$node_port" "$pass" "$sni" "$out_name" "$insecure" "$alpn_csv")"
        clash_line="{name: $yn, type: anytls, server: $yh, port: $node_port, password: $yp, client-fingerprint: chrome, udp: true, sni: $ys, skip-cert-verify: $insecure"
        if [ -n "$alpn_csv" ]; then clash_line+=", alpn: $(jq -c '.alpn' <<< "$tls")"; fi
        clash_line+='}'
        qx_line="anytls=$public_address, password=$pass, over-tls=true, tls-host=$sni, tls-verification=$qx_verify, udp-relay=true, tag=$out_name"
        ;;
      shadowsocks)
        [ -n "$pass" ] || continue
        pw_out="$pass"
        [ -z "$server_p" ] || pw_out="$server_p:$pass"
        v2rayn_link="$(build_v2rayn_ss_link "$node_host" "$node_port" "$method" "$pw_out" "$out_name")"
        clash_line="{name: $yn, type: ss, server: $yh, port: $node_port, cipher: $method, password: $(jq -Rn --arg value "$pw_out" '$value'), udp: true}"
        qx_line="shadowsocks=$public_address, method=$method, password=$pw_out, udp-relay=true, tag=$out_name"
        ;;
      trojan)
        [ -n "$pass" ] || continue
        v2rayn_link="$(build_v2rayn_trojan_link "$node_host" "$node_port" "$pass" "$sni" "$out_name" "$insecure" "$alpn_csv")"
        clash_line="{name: $yn, type: trojan, server: $yh, port: $node_port, password: $yp, client-fingerprint: chrome, udp: true, sni: $ys, skip-cert-verify: $insecure"
        if [ -n "$alpn_csv" ]; then clash_line+=", alpn: $(jq -c '.alpn' <<< "$tls")"; fi
        clash_line+='}'
        qx_line="trojan=$public_address, password=$pass, over-tls=true, tls-host=$sni, tls-verification=$qx_verify, fast-open=false, udp-relay=true, tag=$out_name"
        ;;
      vmess-ws|vless-ws)
        [ -n "$uuid" ] || continue
        if [ "$proto" = vmess-ws ]; then
          v2rayn_link="$(build_v2rayn_vmess_ws_link "$node_host" "$uuid" "$node_host" "$path" "$out_name" "$node_port")"
          clash_line="type: vmess, alterId: 0, cipher: auto"
          qx_line="vmess=$public_address, method=chacha20-poly1305"
        else
          v2rayn_link="$(build_v2rayn_vless_ws_link "$node_host" "$uuid" "$node_host" "$path" "$out_name" "$node_port")"
          clash_line="type: vless"
          qx_line="vless=$public_address, method=none"
        fi
        ws_options="path: $ypath, headers: {Host: $yh}"
        if [ "$early" = 2048 ]; then
          ws_options+=", max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol"
        fi
        clash_line="{name: $yn, $clash_line, server: $yh, port: $node_port, uuid: $uuid, udp: true, tls: true, network: ws, servername: $yh, ws-opts: {$ws_options}}"
        qx_line+=", password=$uuid, obfs=wss, obfs-host=$node_host, obfs-uri=$path, tls-verification=true, udp-relay=true, tag=$out_name"
        ;;
      hysteria2)
        [ -n "$pass" ] || continue
        hop_range="$(hy2_export_hop_range "$tag" "$meta_json")"
        v2rayn_link="$(build_v2rayn_hysteria2_link "$node_host" "${hop_range:-$node_port}" "$pass" "$sni" "$obfs_type" "$obfs_pass" "$out_name" "$insecure")"
        clash_line="{name: $yn, type: hysteria2, server: $yh, port: $node_port, password: $yp, sni: $ys, skip-cert-verify: $insecure"
        [ -z "$obfs_type" ] || clash_line+=", obfs: $obfs_type, obfs-password: $yobf"
        [ -z "$hop_range" ] || clash_line+=", ports: \"$hop_range\", hop-interval: 30"
        clash_line+='}'
        if [ "$obfs_type" != gecko ] && [ -z "$hop_range" ]; then
          qx_line="hysteria2=$public_address, password=$pass, tls-host=$sni, tls-verification=$qx_verify, udp-relay=true"
          [ "$obfs_type" != salamander ] || qx_line+=", salamander-password=$obfs_pass"
          qx_line+=", tag=$out_name"
        fi
        ;;
      tuic)
        [ -n "$uuid" ] && [ -n "$pass" ] || continue
        v2rayn_link="$(build_v2rayn_tuic_link "$node_host" "$node_port" "$uuid" "$pass" "$sni" "$out_name" "$insecure" "${alpn_csv:-h3}" "$cc")"
        clash_line="{name: $yn, type: tuic, server: $yh, port: $node_port, uuid: $uuid, password: $yp, alpn: $(jq -c '.alpn // ["h3"]' <<< "$tls"), disable-sni: false, reduce-rtt: false, udp-relay-mode: native, congestion-controller: $cc, skip-cert-verify: $insecure, sni: $ys}"
        ;;
      socks)
        [ -n "$pass" ] || continue
        v2rayn_link="$(build_socks_link "$node_host" "$node_port" "$name" "$pass")"
        clash_line="{name: $yn, type: socks5, server: $yh, port: $node_port, username: $yn, password: $yp, udp: true}"
        qx_line="socks5=$public_address, username=$name, password=$pass, tag=$out_name"
        ;;
      *) continue ;;
    esac
    local notice=''
    if [ "$proto" = tuic ]; then
      notice="TUIC 本期提供通用链接和 Clash / Mihomo。"
    elif [ "$proto" = hysteria2 ] && [ -z "$qx_line" ]; then
      notice="Quantumult X: 此混淆或跳跃组合待真机验证。"
    fi
    export_record "$out_name" "$proto" "$v2rayn_link" "$clash_line" "$qx_line" "$notice"
  done < <(
    printf '%s\n' "$json" | jq -r --argjson meta "$meta_json" --argjson db "$db" "${JQ_SHARED}"'
      [.inbounds[]?]
      | sort_by(protocol_sort_index(.tag // ""))
      | .[]
      | . as $in
      | ($in | detect_protocol) as $proto
      | ($in.users // [])[]? as $user
      | ($user.name // $user.username // "") as $auth
      | (if ($auth|contains("@")) then ($auth|split("@")[1]) else "admin" end) as $account
      | ($auth|node_part(.)|if contains("-to-") then . else $in.tag end) as $node
      | select(if $db == null then $account == "admin" else
          $db.users[$account] as $u | $u.enabled == true and
          ($account == "admin" or $u.allow_all_nodes == true or (($u.nodes // [])|index($node)) != null) end)

      | ($meta[$in.tag] // {}) as $saved
      | (if ($proto|endswith("-ws")) then
           [$saved.cdn_entries[]? | select(.verified == true and .path == $in.transport.path)] as $raw
           | (if ($raw | length) == 1 then $raw | map(del(.operator_evidence)) else $raw end) as $verified
           | ($saved.public_endpoint // {}) as $old
           | ($verified + [($old | select(.host != null
               and all($verified[]; .host != $old.host or .port != ($old.port // 443))))])
         else [$saved.public_endpoint // {}] end) as $entries
      | (if ($entries | length) == 0 then [{}] else $entries end)[] as $endpoint
      | [
          ($in.tag // ""),
          $proto,
          (($in.listen_port // 0) | tostring),
          ($in.tls.server_name // ""),
          ($in.transport.path // "/"),
          ($in.tls.reality.short_id[0] // ""),
          ($in.method // "2022-blake3-aes-128-gcm"),
          ($in.password // ""),
          ($in.obfs.type // ""),
          ($in.obfs.password // ""),
          ($user.name // $user.username // ""),
          ($user.uuid // ""),
          ($user.password // ""),
          ($user.flow // ""),
          (($in.tls // {}) | tojson),
          ($in.congestion_control // "bbr"),
          ($endpoint | tojson)
        ] | join("\u0001")
    '
  )
}

# Internal export records carry strings without terminal formatting.
export_record() {
  jq -nc --arg name "$1" --arg proto "$2" --arg link "$3" \
    --arg clash "$4" --arg qx "$5" --arg notice "$6" '
      {name:$name,proto:$proto,link:$link,clash:(if $clash=="" then "" else "- "+$clash end),qx:$qx,notice:$notice}'
}

export_plain_preview() {
  jq -r '.[] | "\n[\(.name)]",
    (if .link != "" then (if .proto=="socks" then " 落地链接: " else " 通用链接: " end)+.link else empty end),
    (if .clash != "" then " Clash: "+.clash else empty end),
    (if .qx != "" then " Quantumult X: "+.qx else empty end),
    (if .notice != "" then " "+.notice else empty end)' <<< "$1"
}

export_qr() {
  printf '%s' "$1" | qrencode -t ANSIUTF8 -l M -m 4 2>/dev/null
}

export_format_menu() {
  local record="$1"
  if [ -n "$record" ] && jq -e '.proto == "socks"' <<< "$record" >/dev/null; then
    printf '%s\n' '1. 落地链接'
  else
    printf '%s\n' '1. 通用链接'
  fi
  printf '%s\n' '2. Clash / Mihomo' '3. Quantumult X'
  if [ -n "$record" ]; then
    jq -r '.notice | select(length>0)' <<< "$record"
  fi
}

export_detail_card() {
  local record="$1" cols="$2" lines="${3:-100}" uri qr='' first clean width i
  local -a image=() options=()
  jq -r '.name' <<< "$record" | tr -d '[:cntrl:]'
  printf '\n'
  uri="$(jq -r '.link' <<< "$record")"
  if [ -n "$uri" ] && has_cmd qrencode; then
    qr="$(export_qr "$uri")" || qr=''
  fi
  if [ -n "$qr" ]; then
    mapfile -t image <<< "$qr"
    first="${image[0]}"
    clean="$(sed $'s/\033\\[[0-9;]*m//g' <<< "$first")"
    width="$(printf '%s' "$clean" | wc -m | tr -d ' ')"
    if (( width + 24 <= cols && ${#image[@]} + 5 <= lines )); then
      mapfile -t options < <(export_format_menu "$record" | head -n 3)
      for i in "${!image[@]}"; do
        printf '%s' "${image[i]}"
        if [ "$i" -lt "${#options[@]}" ]; then
          printf '\033[%dG%s' "$((width+3))" "${options[i]}"
        fi
        printf '\n'
      done
      jq -r '.notice | select(length>0)' <<< "$record"
      return
    elif (( width <= cols && ${#image[@]} + 7 <= lines )); then
      printf '%s\n' "$qr"
    else
      printf '%s\n' "$uri"
    fi
  elif [ -n "$uri" ]; then
    printf '%s\n' "$uri"
  fi
  export_format_menu "$record"
}

export_print_format() {
  local rows="$1" choice="$2" key
  case "$choice" in 1) key=link ;; 2) key=clash ;; 3) key=qx ;; *) return 1 ;; esac
  if ! jq -e --arg key "$key" 'any(.[]; .[$key] != "")' <<< "$rows" >/dev/null; then
    warn "所选节点缺少该格式或必要资料。"
    return 1
  fi
  jq -r --arg key "$key" '.[] | .[$key] | select(length>0)' <<< "$rows"
}

export_configs() {
  local account="${1:-__admin__}" tags="${2:-}" rows selected choice count record detail cols lines allow_all=0
  init_manager_env || return 1
  [ "$#" -ne 0 ] || allow_all=1
  rows="$(export_collect_records "$account" "$tags" | jq -cs '.')" || return 1
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    export_plain_preview "$rows"
    return
  fi
  cols="$(tput cols 2>/dev/null || printf '%s\n' "${COLUMNS:-80}")"
  lines="$(tput lines 2>/dev/null || printf '%s\n' "${LINES:-40}")"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=40
  while true; do
    count="$(jq 'length' <<< "$rows")"
    if [ "$count" -eq 0 ] && [ "$allow_all" -eq 0 ]; then
      warn "没有可导出的节点。"
      return 0
    fi
    detail=0
    if [ "$count" -eq 1 ]; then
      selected=1
      detail=1
    else
      print_rect_title "导出配置"
      jq -r 'to_entries[] | "  \(.key+1). \(.value.name|gsub("[[:cntrl:]]"; ""))"' <<< "$rows"
      if [ "$count" -gt 1 ]; then printf '  b. 按一种格式批量导出\n'; fi
      if [ "$allow_all" -eq 1 ]; then printf '  a. 导出全部用户\n'; fi
      read -r -p "选择节点（回车返回）: " selected || return 0
      case "$selected" in
        ''|0|q) return 0 ;;
        a)
          [ "$allow_all" -eq 1 ] || continue
          rows="$(export_collect_records __all__ "$tags" | jq -cs '.')" || return 1
          allow_all=0
          continue ;;
        b)
          [ "$count" -gt 1 ] || continue
          export_format_menu ''
          read -r -p "选择批量导出格式（回车返回）: " choice || return 0
          export_print_format "$rows" "$choice" || true
          pause
          continue ;;
      esac
      if ! [[ "$selected" =~ ^[1-9][0-9]*$ ]] || [ "$selected" -gt "$count" ] 2>/dev/null; then
        warn "请选择列表中的节点。"
        continue
      fi
    fi
    record="$(jq -c --argjson index "$((selected-1))" '.[$index]' <<< "$rows")" || continue
    export_detail_card "$record" "$cols" "$lines"
    if [ "$allow_all" -eq 1 ]; then printf 'a. 导出全部用户\n'; fi
    if ! has_cmd qrencode && jq -e '.link != ""' <<< "$record" >/dev/null; then
      printf '%s\n' 'r. 安装本地二维码工具'
    fi
    while read -r -p "选择格式（回车返回）: " choice; do
      case "$choice" in
        ''|0|q) break ;;
        a)
          [ "$allow_all" -eq 1 ] || continue
          rows="$(export_collect_records __all__ "$tags" | jq -cs '.')" || return 1
          allow_all=0
          detail=0
          break ;;
        r)
          if ! has_cmd qrencode; then
            if run_with_spinner "安装本地二维码工具" install_pkg qrencode; then
              export_detail_card "$record" "$cols" "$lines"
            else
              warn "二维码工具安装失败，可以继续复制链接。"
            fi
          fi ;;
        1|2|3) export_print_format "[$record]" "$choice" || true ;;
        *) warn "请选择 1、2 或 3。" ;;
      esac
    done
    if [ "$detail" -eq 1 ]; then return 0; fi
  done
}

# >>>>>>>>> END MODULE: 70_export.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 75_ws_cdn.sh <<<<<<<<<<<
# Existing-CDN routing and validation. Cloud account changes are outside this module.

WS_CDN_NGINX_DIR="/etc/sing-box-manager/ws-cdn.d"

ws_cdn_hostname() {
  local host="$1"
  [[ "${#host}" -le 253 &&
     "$host" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ &&
     "$host" =~ \.[a-z][a-z0-9-]*$ ]]
}

ws_cdn_port_valid() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]
}

ws_cdn_path_valid() {
  [[ "$1" =~ ^/[A-Za-z0-9._~/-]*$ && "$1" != *//* && "$1/" != */../* && "$1/" != */./* ]]
}

ws_cdn_ws_inbound() {
  local json="$1" tag="$2"
  jq -ec "${JQ_DETECT_PROTOCOL}"'first(.inbounds[]?
    | select(.tag == $tag and ((detect_protocol) == "vmess-ws" or (detect_protocol) == "vless-ws")))' \
    --arg tag "$tag" <<< "$json"
}

ws_cdn_list() {
  protocol_entry_table "$1" | awk -F '\x01' '$2 == "vmess-ws" || $2 == "vless-ws"'
}

ws_cdn_public_peer() {
  local ip="${1,,}"
  if [[ "$ip" =~ ^[23][a-fA-F0-9]{3}: && "$ip" != 2001:db8:* ]]; then return 0; fi
  awk -v ip="$ip" 'BEGIN {
    n=split(ip,a,"."); if (n!=4) exit 1
    for (i=1;i<=4;i++) if (a[i] !~ /^[0-9]+$/ || a[i]>255) exit 1
    exit !(a[1]>0 && a[1]<224 && a[1]!=10 && a[1]!=127 &&
      !(a[1]==169 && a[2]==254) && !(a[1]==172 && a[2]>=16 && a[2]<=31) &&
      !(a[1]==192 && (a[2]==168 || (a[2]==0 && a[3]==2) || (a[2]==0 && a[3]==0))) &&
      !(a[1]==100 && a[2]>=64 && a[2]<=127) && !(a[1]==198 && (a[2]==18 || a[2]==19 || (a[2]==51 && a[3]==100))) &&
      !(a[1]==203 && a[2]==0 && a[3]==113))
  }'
}

# The test harness can provide a local trust root without allowing insecure TLS.
ws_cdn_public_ca() { :; }

ws_cdn_http_upgrade() {
  local leg="$1" host="$2" port="$3" path="$4" origin_addr="${5:-}" origin_port="${6:-}" ca="${7:-}" request_host="${8:-$2}"
  local headers result status peer rc=0
  local -a extra=()
  headers="$(mktemp)" || return 1
  [ -z "$origin_addr" ] || extra+=(--connect-to "$host:$port:$(uri_host "$origin_addr"):$origin_port")
  [ -z "$ca" ] || extra+=(--cacert "$ca")
  result="$(curl --silent --noproxy '*' --http1.1 --connect-timeout 4 --max-time 5 \
    --dump-header "$headers" --output /dev/null --write-out '%{http_code} %{remote_ip}' \
    -H "Host: $request_host" -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "${extra[@]}" "https://$host:$port$path")" || rc=$?
  read -r status peer <<< "$result"
  if { [ "$rc" = 0 ] || [ "$rc" = 28 ]; } && [ "$status" = 101 ] &&
    grep -Eiq '^Sec-WebSocket-Accept:[[:space:]]*s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=' "$headers"; then
    rm -f "$headers"
    printf '%s\n' "$peer"
    return 0
  fi
  rm -f "$headers"
  case "$rc:$status" in
    6:*) warn "$leg DNS 解析失败，请检查域名记录。" ;;
    35:*|51:*|60:*|77:*|*:525|*:526) warn "$leg TLS 握手或证书校验失败，请检查证书名称、HTTPS 回源及 CA。" ;;
    *:404) warn "$leg 返回 404，请核对 WebSocket 路径和站点匹配。" ;;
    *:502|*:503|*:504|*:521|*:522|*:523|*:524) warn "$leg 返回 ${status}，请检查源站地址、HTTPS 回源端口和入站监听。" ;;
    7:*|28:000) warn "$leg 无法连接，请检查端口和防火墙。" ;;
    *) warn "$leg 未完成 WebSocket 升级（HTTP ${status:-未知}）。" ;;
  esac
  return 1
}

ws_cdn_probe_target() { printf '%s\n' 'https://www.cloudflare.com/cdn-cgi/trace'; }

ws_cdn_proxy_client() {
  local inbound="$1" host="$2" port="$3" path="$4" local_port="$5" early="$6" ca="$7"
  jq -ce --arg host "$host" --argjson port "$port" --arg path "$path" --argjson local_port "$local_port" \
    --argjson early "$early" --arg ca "$ca" '
      . as $in | first(.users[]? | select((.uuid // "") != "")) as $user
      | {log:{disabled:true},
         inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$local_port}],
         outbounds:[{type:$in.type,tag:"probe",server:$host,server_port:$port,uuid:$user.uuid,
           tls:({enabled:true,server_name:$host} | if $ca != "" then .certificate_path=$ca else . end),
           transport:({type:"ws",path:$path,headers:{Host:$host}} | if $early > 0 then
              .+{max_early_data:$early,early_data_header_name:"Sec-WebSocket-Protocol"} else . end)}
           | if $in.type == "vmess" then .+{security:"auto",alter_id:($user.alterId // 0)} else
                if ($user.flow // "") != "" then .flow=$user.flow else . end end]}
  ' <<< "$inbound"
}

ws_cdn_proxy_probe() (
  local inbound="$1" host="$2" port="$3" path="$4" early="$5" ca="$6" temp pid='' proxy_port attempt result target
  umask 077
  temp="$(mktemp -d)" || return 1
  trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$temp"' EXIT
  target="$(ws_cdn_probe_target)" || return 1
  for attempt in 1 2 3; do
    proxy_port=$(( 20000 + RANDOM ))
    ws_cdn_proxy_client "$inbound" "$host" "$port" "$path" "$proxy_port" "$early" "$ca" > "$temp/client.json" || return 1
    sing-box run -c "$temp/client.json" >/dev/null 2>&1 &
    pid=$!
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then break; fi
    wait "$pid" 2>/dev/null || true
    pid=''
  done
  [ -n "$pid" ] || return 1
  # Clear the environment's bypass list; the request must use this exact client.
  local -a tls_target=()
  [ -z "$ca" ] || tls_target+=(--cacert "$ca")
  result="$(curl -fsS --noproxy '' --connect-timeout 4 --max-time 8 \
    --socks5-hostname "127.0.0.1:$proxy_port" "${tls_target[@]}" "$target" 2>/dev/null)" || return 1
  kill -0 "$pid" 2>/dev/null && grep -Eq '^ip=[0-9A-Fa-f:.]+$' <<< "$result"
)

ws_cdn_entry_conflict() {
  local meta="$1" config="$2" tag="$3" host="$4" path="$5"
  jq -e --argjson config "$config" --arg tag "$tag" --arg host "$host" --arg path "$path" '
    . as $meta
    | any($config.inbounds[]?; .tag != $tag and .transport.type == "ws" and
         ($meta[.tag] // {}) as $other |
         (($other.public_endpoint.host == $host and .transport.path == $path)
          or any($other.cdn_entries[]?; .host == $host and .path == $path)))
  ' <<< "$meta" >/dev/null
}

ws_cdn_store_entry() {
  local meta="$1" tag="$2" entry="$3"
  jq --arg tag "$tag" --argjson entry "$entry" '
    .[$tag].cdn_entries |= ((. // []) | if any(.[]; .host==$entry.host and .port==$entry.port and .path==$entry.path)
      then map(if .host==$entry.host and .port==$entry.port and .path==$entry.path then $entry else . end)
      else . + [$entry] end)
  ' <<< "$meta"
}

ws_cdn_confirm_operator() {
  local entry="$1" evidence="$2" other="$3"
  [ -f "$evidence" ] && [ -r "$evidence" ] && [ "$other" = true ] || return 1
  jq -ec --argjson entry "$entry" '
    select(type == "object" and (.operator == "电信" or .operator == "移动" or .operator == "联通"))
    | select(.host == $entry.host and .port == $entry.port and
       ((.source // "") | type=="string" and test("^https://[^[:space:]]+$")) and
       ((.provider // "") | type=="string" and length>0) and
       (.edge_ips | type == "array" and index($entry.edge_ip) != null))
    | {operator,provider,source}
  ' "$evidence"
}

ws_cdn_nginx() { nginx "$@"; }

ws_cdn_snippet_path() {
  ws_cdn_hostname "$1" || return 1
  printf '%s/%s.managed.conf\n' "$WS_CDN_NGINX_DIR" "$1"
}

ws_cdn_render_nginx() {
  local meta="$1" config="$2" host="$3" rows path addr port
  rows="$(jq -r --argjson config "$config" --arg host "$host" '
    [to_entries[] | select(.value|type=="object") | .key as $tag | .value.cdn_entries[]?
      | select(.host == $host and .mode == "nginx")
      | . as $entry | first($config.inbounds[]? | select(.tag == $tag)) as $in
      | [$entry.path, ($in.listen // "::"), ($in.listen_port | tostring)]]
      | unique | .[] | join("\u0001")
  ' <<< "$meta")" || return 1
  printf '%s\n' '# Managed by sing-box WS CDN'
  while IFS=$'\x01' read -r path addr port; do
    [ -n "$path" ] || continue
    ws_cdn_path_valid "$path" && ws_cdn_port_valid "$port" || return 1
    case "$addr" in ''|0.0.0.0) addr=127.0.0.1 ;; '::') addr=::1 ;; esac
    [[ "$addr" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    printf 'location = %s {\n' "$path"
    printf '    proxy_pass http://%s:%s;\n' "$(uri_host "$addr")" "$port"
    cat <<'NGINX'
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Sec-WebSocket-Protocol $http_sec_websocket_protocol;
    proxy_buffering off;
    proxy_read_timeout 300s;
}
NGINX
  done <<< "$rows"
}

ws_cdn_replace_snippet() {
  local file="$1" tmp
  tmp="$(mktemp "$file.new.XXXXXX")" || return 1
  if ! cat > "$tmp" || ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
}

ws_cdn_update_nginx() {
  local host="$1" contents="$2" file dump pending="$USER_DB_FILE.pending"
  file="$(ws_cdn_snippet_path "$host")" || return 1
  if [ -L "$file" ] || { [ -s "$file" ] && [ "$(head -n1 "$file")" != '# Managed by sing-box WS CDN' ]; }; then
    warn "反代片段已有其他内容，请在现有反代中手动维护该路径。"
    return 1
  fi
  mkdir -p "$WS_CDN_NGINX_DIR" || return 1
  if [ -f "$file" ]; then cp -p "$file" "$pending/ws-origin-before" || return 1; fi
  printf '%s\n' "$host" > "$pending/ws-origin-host" || return 1
  ws_cdn_replace_snippet "$file" <<< "$contents" || return 1
  if ! dump="$(ws_cdn_nginx -T 2>/dev/null)"; then
    ws_cdn_nginx -t || true
    warn "Nginx 配置检查失败，请检查重复路径或站点 include。"
    return 1
  fi
  if ! grep -Fxq "# configuration file $file:" <<< "$dump"; then
    warn "Nginx 未加载该片段。请先把此站点的 include 加到 HTTPS server 中。"
    return 1
  fi
  touch "$pending/ws-origin-reload" || return 1
  ws_cdn_nginx -s reload || return 1
  sleep 0.3
}

# Called from the existing manager journal while its lock is held.
ws_cdn_restore_pending() {
  local pending="$1" host file tmp
  [ -f "$pending/ws-origin-host" ] || return 0
  host="$(cat "$pending/ws-origin-host")" || return 1
  file="$(ws_cdn_snippet_path "$host")" || return 1
  if [ -f "$pending/ws-origin-before" ]; then
    tmp="$(mktemp "$file.restore.XXXXXX")" || return 1
    if ! cp -p "$pending/ws-origin-before" "$tmp" || ! mv -f "$tmp" "$file"; then
      rm -f "$tmp"
      return 1
    fi
  else
    rm -f "$file" || return 1
  fi
  if [ -f "$pending/ws-origin-reload" ]; then
    ws_cdn_nginx -t -q && ws_cdn_nginx -s reload || return 1
  fi
}

ws_cdn_verify() {
  local inbound="$1" entry="$2" host port path origin addr origin_port origin_sni origin_ca
  local public_ca peer early=0
  IFS=$'\x01' read -r host port path addr origin_port origin_sni origin_ca < <(
    jq -r '[.host, (.port|tostring), .path, .origin.address, (.origin.port|tostring),
            .origin.sni, (.origin.ca // "")] | join("\u0001")' <<< "$entry"
  )
  ui_echo "正在验证源站 HTTPS 和路径 ${path}（最多 5 秒）。"
  origin="$(ws_cdn_http_upgrade '源站' "$origin_sni" "$origin_port" "$path" \
    "$addr" "$origin_port" "$origin_ca" "$host")" || return 1
  public_ca="$(ws_cdn_public_ca)"
  ui_echo "正在验证公网入口 $host:${port}（最多 5 秒）。"
  peer="$(ws_cdn_http_upgrade '公网入口' "$host" "$port" "$path" '' '' "$public_ca")" || return 1
  if ! ws_cdn_public_peer "$peer" || [ "$peer" = "$origin" ]; then
    warn "公网域名未通过独立地址访问，请检查 DNS 是否已启用 CDN 代理。"
    return 1
  fi
  ui_echo "正在用节点凭据发起代理请求（最多 9 秒）。"
  if ! ws_cdn_proxy_probe "$inbound" "$host" "$port" "$path" 0 "$public_ca"; then
    warn "公网 WebSocket 已升级，但代理请求失败。请核对 CDN 路径到入站的对应关系、UUID 和源站出口。"
    return 1
  fi
  if jq -e '.transport.max_early_data >= 2048 and
    .transport.early_data_header_name == "Sec-WebSocket-Protocol"' <<< "$inbound" >/dev/null; then
    ui_echo "正在验证 Early Data 透传（最多 9 秒）。"
    if ws_cdn_proxy_probe "$inbound" "$host" "$port" "$path" 2048 "$public_ca"; then early=2048; fi
  fi
  jq --arg peer "$peer" --argjson early "$early" --arg checked "$(date -u '+%FT%TZ')" '
    . + {verified:true, edge_ip:$peer, checked_at:$checked, early_data:$early}
  ' <<< "$entry"
}

ws_cdn_validate_entry() {
  local entry="$1" host port path addr origin_port sni ca mode
  IFS=$'\x01' read -r host port path addr origin_port sni mode ca < <(
    jq -r '[.host, (.port|tostring), .path, .origin.address, (.origin.port|tostring),
            .origin.sni, .mode, (.origin.ca // "")] | join("\u0001")' <<< "$entry"
  )
  ws_cdn_hostname "$host" && ws_cdn_port_valid "$port" && ws_cdn_path_valid "$path" &&
    ws_cdn_port_valid "$origin_port" && ws_cdn_hostname "$sni" &&
    [[ "$addr" =~ ^[A-Za-z0-9.:-]+$ && ( "$mode" = nginx || "$mode" = existing ) ]] &&
    { [ -z "$ca" ] || [ -r "$ca" ]; }
}

ws_cdn_finish_attach() {
  local tag="$1" proposed="$2" evidence="$3" inbound="$4" previous_meta="$5" verified other detail
  verified="$(ws_cdn_verify "$inbound" "$proposed")" || return 1
  if [ -n "$evidence" ]; then
    other="$(jq -r --arg tag "$tag" --argjson tested "$verified" '
      any(.[$tag].cdn_entries[]?; .verified == true and .edge_ip != $tested.edge_ip
          and (.host != $tested.host or .port != $tested.port))
    ' <<< "$previous_meta")"
    if detail="$(ws_cdn_confirm_operator "$verified" "$evidence" "$other")"; then
      verified="$(jq --argjson record "$detail" '.operator_evidence=$record' <<< "$verified")" || return 1
    else
      warn "线路记录与实际入口未匹配，按 CDN 自动导出。"
    fi
  else
    # A changed public peer requires fresh evidence for an operator label.
    detail="$(jq -c --arg tag "$tag" --argjson tested "$verified" '
      first(.[$tag].cdn_entries[]? | select(.host==$tested.host and .port==$tested.port
        and .path==$tested.path and .edge_ip==$tested.edge_ip) | .operator_evidence // empty) // null
    ' <<< "$previous_meta")" || return 1
    if [ "$detail" != null ]; then
      verified="$(jq --argjson record "$detail" '.operator_evidence=$record' <<< "$verified")" || return 1
    fi
  fi
  ws_cdn_store_entry "$previous_meta" "$tag" "$verified"
}

ws_cdn_prepare_entry() {
  local tag="$1" requested="$2" inbound="$3" inventory="$4" previous="$5" path host
  path="$(jq -r '.transport.path // empty' <<< "$inbound")"
  requested="$(jq --arg path "$path" '.path=$path | del(.operator_evidence,.verified,.early_data,.edge_ip)' <<< "$requested")" || return 1
  ws_cdn_validate_entry "$requested" || { warn "公网域名、回源设置或现有路径不符合接入要求。"; return 1; }
  host="$(jq -r '.host' <<< "$requested")"
  if ws_cdn_entry_conflict "$previous" "$inventory" "$tag" "$host" "$path"; then
    warn "同一 CDN 域名下，这条 WebSocket 路径已属于另一个节点。"
    return 1
  fi
  # Keep ownership of existing managed paths across retries.
  if jq -e --arg tag "$tag" --arg host "$host" --arg path "$path" '
    any(.[$tag].cdn_entries[]?; .host == $host and .path == $path and .mode == "nginx")
  ' <<< "$previous" >/dev/null; then
    jq '.mode="nginx"' <<< "$requested"
  else
    printf '%s\n' "$requested"
  fi
}

ws_cdn_attach() {
  local tag="$1" requested="$2" evidence="${3:-}" runtime inventory inbound previous proposed final
  if [ "$(jq -r '.mode' <<< "$requested")" = nginx ]; then
    with_manager_lock _ws_cdn_attach_nginx "$tag" "$requested" "$evidence"
    return
  fi
  user_db_exists || { user_db_restore_hint; return 1; }
  runtime="$(config_load)" || return 1
  inventory="$(user_manager_config_for_edit)" || return 1
  inbound="$(ws_cdn_ws_inbound "$runtime" "$tag")" || { warn "该节点未在运行，请先恢复至少一个用户。"; return 1; }
  previous="$(meta_load)" || return 1
  proposed="$(ws_cdn_prepare_entry "$tag" "$requested" "$inbound" "$inventory" "$previous")" || return 1
  if [ "$(jq -r '.mode' <<< "$proposed")" = nginx ]; then
    with_manager_lock _ws_cdn_attach_nginx "$tag" "$proposed" "$evidence"
    return
  fi
  final="$(ws_cdn_finish_attach "$tag" "$proposed" "$evidence" "$inbound" "$previous")" || return 1
  with_manager_lock _ws_cdn_commit_existing "$tag" "$inbound" "$previous" "$final"
}

_ws_cdn_commit_existing() {
  local tag="$1" expected="$2" previous="$3" final="$4" latest latest_inbound runtime
  user_db_exists || { user_db_restore_hint; return 1; }
  latest="$(meta_load)" || return 1
  runtime="$(config_load)" || return 1
  latest_inbound="$(ws_cdn_ws_inbound "$runtime" "$tag")" || return 1
  if [ "$(jq -Sc . <<< "$previous")" != "$(jq -Sc . <<< "$latest")" ] ||
    [ "$(jq -Sc . <<< "$expected")" != "$(jq -Sc . <<< "$latest_inbound")" ]; then
    warn "验证期间节点或入口资料有变化，请重新验证。"
    return 1
  fi
  meta_save "$final" || return 1
  ok "公网代理请求通过，入口已保存。"
}

_ws_cdn_attach_nginx() {
  local tag="$1" requested="$2" evidence="$3"
  local runtime inventory inbound host previous proposed staged snippet final
  user_db_exists || { user_db_restore_hint; return 1; }
  runtime="$(config_load)" || return 1
  inventory="$(user_manager_config_for_edit)" || return 1
  inbound="$(ws_cdn_ws_inbound "$runtime" "$tag")" || { warn "该节点未在运行，请先恢复至少一个用户。"; return 1; }
  previous="$(meta_load)" || return 1
  proposed="$(ws_cdn_prepare_entry "$tag" "$requested" "$inbound" "$inventory" "$previous")" || return 1
  host="$(jq -r '.host' <<< "$proposed")"
  staged="$(ws_cdn_store_entry "$previous" "$tag" "$proposed")" || return 1
  snippet="$(ws_cdn_render_nginx "$staged" "$inventory" "$host")" || return 1
  manager_transaction_begin || return 1
  if ! ws_cdn_update_nginx "$host" "$snippet" ||
     ! final="$(ws_cdn_finish_attach "$tag" "$proposed" "$evidence" "$inbound" "$previous")" ||
     ! meta_save "$final"; then
    manager_recover_pending || return 1
    return 1
  fi
  manager_transaction_end || return 1
  ok "公网代理请求通过，入口已保存。"
}

ws_cdn_detach() {
  with_manager_lock _ws_cdn_detach_body "$@"
}

_ws_cdn_detach_body() {
  local tag="$1" host="$2" port="$3" previous entry next mode inventory snippet
  previous="$(meta_load)" || return 1
  entry="$(jq -ec --arg tag "$tag" --arg host "$host" --argjson port "$port" '
    first(.[$tag].cdn_entries[]? | select(.host==$host and .port==$port))
  ' <<< "$previous")" || return 1
  next="$(jq --arg tag "$tag" --argjson entry "$entry" '
    .[$tag].cdn_entries |= map(select(.host!=$entry.host or .port!=$entry.port))
    | if .[$tag].public_endpoint.host == $entry.host and
        (.[$tag].public_endpoint.port // 443) == $entry.port
      then del(.[$tag].public_endpoint) else . end
  ' <<< "$previous")" || return 1
  mode="$(jq -r '.mode' <<< "$entry")"
  if [ "$mode" = nginx ]; then
    inventory="$(user_manager_config_for_edit)" || return 1
    snippet="$(ws_cdn_render_nginx "$next" "$inventory" "$host")" || return 1
    manager_transaction_begin || return 1
    if ! ws_cdn_update_nginx "$host" "$snippet" || ! meta_save "$next"; then
      manager_recover_pending || return 1
      return 1
    fi
    manager_transaction_end || return 1
  else
    meta_save "$next" || return 1
  fi
  ok "已移除该导出入口。"
}

ws_cdn_detach_menu() {
  local tag="$1" meta host port answer i
  local -a entries=()
  meta="$(meta_load)" || return 1
  mapfile -t entries < <(jq -cr --arg tag "$tag" '.[$tag].cdn_entries[]?' <<< "$meta")
  [ "${#entries[@]}" -gt 0 ] || { warn "此节点还没有已验证的 CDN 入口。"; return 1; }
  for i in "${!entries[@]}"; do
    printf '  %s. %s\n' "$((i+1))" "$(jq -r '"\(.host):\(.port)\(.path)"' <<< "${entries[i]}")"
  done
  read -r -p "选择移除哪条入口（回车返回）: " answer || return 1
  [[ "$answer" =~ ^[1-9][0-9]*$ ]] && [ "$answer" -le "${#entries[@]}" ] || return 1
  read -r host port < <(jq -r '[.host, (.port|tostring)] | join(" ")' <<< "${entries[answer-1]}")
  ask_confirm_yes "确认移除此公网入口？输入 yes 确认: " || return 1
  ws_cdn_detach "$tag" "$host" "$port"
}

ws_cdn_has_managed_entry() {
  jq -e --arg tag "$2" 'any(.[$tag].cdn_entries[]?; .mode == "nginx")' <<< "$1" >/dev/null
}

ws_cdn_menu() {
  local json="$1" meta selected tag proto local_port i host port path mode origin entry answer evidence=''
  local origin_addr=127.0.0.1 origin_port=443 origin_sni origin_ca=''
  local -a rows=()
  mapfile -t rows < <(ws_cdn_list "$json")
  [ "${#rows[@]}" -gt 0 ] || { warn "请先安装 VMess-WS 或 VLESS-WS。"; pause; return 0; }
  print_rect_title "接入已有 CDN"
  say "选择节点。域名须已启用 CDN 代理、WebSocket 和 HTTPS 回源。"
  for i in "${!rows[@]}"; do
    IFS=$'\x01' read -r tag proto local_port <<< "${rows[i]}"
    printf '  %s. %s\n' "$((i+1))" "$tag"
  done
  read -r -p "选择要接入的节点（回车返回）: " selected || return 0
  [[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "$selected" -le "${#rows[@]}" ] || return 0
  IFS=$'\x01' read -r tag proto local_port <<< "${rows[selected-1]}"
  path="$(ws_cdn_ws_inbound "$json" "$tag" | jq -r '.transport.path // empty')" || return 1
  meta="$(meta_load)" || return 1
  host="$(jq -r --arg tag "$tag" '
    .[$tag].cdn_entries[0].host // .[$tag].public_endpoint.host //
    first(to_entries[] | select(.value|type=="object") | .value.cdn_entries[]? | .host) // ""
  ' <<< "$meta")"
  say "保留当前 WebSocket 路径 $path 和 UUID。新增入口不会覆盖其他已保存的入口。"
  read -r -p "公网域名 [${host:-待填写}]（d 管理已接入入口）: " answer || return 0
  if [ "$answer" = d ]; then ws_cdn_detach_menu "$tag" || true; pause; return 0; fi
  host="$(tr '[:upper:]' '[:lower:]' <<< "${answer:-$host}")"
  [ -n "$host" ] || return 0
  ws_cdn_hostname "$host" || { warn "请输入 CDN 的公网域名，不带协议、端口或路径。"; pause; return 0; }
  entry="$(jq -c --arg host "$host" '
    first(to_entries[] | select(.value|type=="object") | .value.cdn_entries[]? | select(.host == $host)) // {}
  ' <<< "$meta")"
  origin_sni="$host"
  port=443
  mode=existing
  if [ "$entry" != '{}' ]; then
    IFS=$'\x01' read -r port mode origin_addr origin_port origin_sni origin_ca < <(
      jq -r '[.port|tostring] + [.mode,.origin.address,(.origin.port|tostring),.origin.sni,.origin.ca // ""]
             | join("\u0001")' <<< "$entry"
    )
    say "将复用此域名的公网端口和回源设置。"
  fi
  read -r -p "回车验证；n 写入已有 Nginx；c 自定义端口、证书或线路记录: " answer || return 0
  case "$answer" in
    '') ;;
    n|N) mode=nginx ;;
    c|C)
      read -r -p "公网 HTTPS 端口 [$port]: " answer || return 0
      port="${answer:-$port}"
      read -r -p "源站地址 [$origin_addr]: " answer || return 0
      origin_addr="${answer:-$origin_addr}"
      origin_addr="${origin_addr#[}"
      origin_addr="${origin_addr%]}"
      read -r -p "HTTPS 回源端口 [$origin_port]: " answer || return 0
      origin_port="${answer:-$origin_port}"
      read -r -p "源站证书域名 [$origin_sni]: " answer || return 0
      origin_sni="$(tr '[:upper:]' '[:lower:]' <<< "${answer:-$origin_sni}")"
      read -r -p "源站私有 CA 文件（回车沿用现有设置，- 使用系统 CA）: " answer || return 0
      if [ "$answer" = - ]; then origin_ca=''; else origin_ca="${answer:-$origin_ca}"; fi
      read -r -p "供应商独立线路记录 JSON 文件（没有就回车）: " evidence || return 0
      read -r -p "写入已有 Nginx？输入 n，回车沿用当前方式: " answer || return 0
      [ "$answer" != n ] || mode=nginx
      ;;
    *) return 0 ;;
  esac
  if [ "$mode" = nginx ]; then
    has_cmd nginx || { warn "本机未找到 Nginx，可先在现有反代中接好路径，再验证。"; pause; return 0; }
    say "已有 HTTPS server 应先包含以下指令。"
    printf '  include %s/%s.*.conf;\n' "$WS_CDN_NGINX_DIR" "$host"
    read -r -p "已配置 include？按回车继续，q 返回: " answer || return 0
    [ -z "$answer" ] || return 0
  else
    say "确认现有 HTTPS 反代已将 $path 转发到该 WS 入站的端口 ${local_port}。"
  fi
  ws_cdn_port_valid "$port" && ws_cdn_port_valid "$origin_port" || { warn "端口无效。"; return 1; }
  origin="$(jq -nc --arg address "$origin_addr" --argjson port "$origin_port" \
    --arg sni "$origin_sni" --arg ca "$origin_ca" '{address:$address,port:$port,sni:$sni,ca:$ca}')"
  entry="$(jq -nc --arg host "$host" --argjson port "$port" --arg mode "$mode" \
    --argjson origin "$origin" '{host:$host,port:$port,mode:$mode,origin:$origin}')"
  if ws_cdn_attach "$tag" "$entry" "$evidence"; then
    export_configs "__admin__" "$(jq -nc --arg tag "$tag" '[$tag]')" || true
  else
    warn "这次未保存入口。原有节点资料保持可用。"
    pause
  fi
}

# >>>>>>>>> END MODULE: 75_ws_cdn.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 80_installer.sh <<<<<<<<<<<
# ============================================================
# 模块: 80_installer.sh
# 职责: sing-box 安装/更新/卸载、systemd 服务、cron、系统工具
# 依赖: 00_base.sh, 01_utils.sh, 10_config.sh, 50_v2ray_api.sh
# ============================================================

# ---------- 依赖安装 ----------

_install_core_deps_quiet() {
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

ensure_deps_for_installer() {
  require_root
  [ "$PKG_MANAGER" = "unknown" ] && { err "不支持的系统（仅支持 Debian/Ubuntu 和 Alpine）。"; exit 1; }
  run_with_spinner "正在检查并安装系统依赖..." _install_core_deps_quiet
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

remove_log_maintain_cron()      { _remove_cron_job "$LOG_MAINTAIN_CRON_MARK"; }
remove_user_watch_cron()        { _remove_cron_job "$USER_WATCH_CRON_MARK"; }
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
  print_rect_title "安装 / 更新 sing-box"

  ui_step 1 5 "准备环境与检查版本"
  ensure_deps_for_installer || { pause; return 1; }

  local arch file tag latest_ver inst tmp_dir base_url download_url sha_url managed_env
  arch="$(uname -m)"
  case "$arch" in
    x86_64) file="sing-box-linux-amd64.tar.gz" ;;
    aarch64|arm64) file="sing-box-linux-arm64.tar.gz" ;;
    *)
      err "不支持的 CPU 架构：$arch（仅支持 amd64 / arm64）"
      pause
      return 1
      ;;
  esac

  local tag_tmp
  tag_tmp="$(mktemp /tmp/sb-tag.XXXXXX)" || { err "创建临时文件失败。"; pause; return 1; }
  if ! run_with_spinner "正在查询最新可用版本..." bash -c '
    curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/'"${SINGBOX_RELEASE_REPO:-Tangfffyx/sing-box}"'/releases/latest" 2>/dev/null | jq -r ".tag_name // empty" > "'"$tag_tmp"'"
  '; then
    rm -f "$tag_tmp"
    err "获取最新版本失败，请检查服务器网络后再试。"
    pause
    return 1
  fi
  tag="$(cat "$tag_tmp" 2>/dev/null || true)"
  rm -f "$tag_tmp"
  latest_ver="$(normalize_release_tag "$tag")"

  refresh_command_cache
  managed_env="0"
  inst=""
  if is_script_managed_environment; then
    managed_env="1"
    inst="$(get_installed_version)"
  fi

  if [ -z "${latest_ver:-}" ]; then
    err "未能获取到最新版本号，请稍后重试。"
    pause
    return 1
  fi

  if [ "${managed_env}" != "1" ] && singbox_command_exists; then
    warn "检测到已有其他方式安装的 sing-box，请先卸载后再使用本脚本安装。"
    pause >&2
    return 0
  fi

  echo ""
  if [ "${managed_env}" = "1" ]; then
    param_echo "当前版本" "${inst:-未知}"
    param_echo "最新版本" "${latest_ver}"
    echo ""
    if [ -n "${inst:-}" ] && version_ge "$inst" "$latest_ver"; then
      if is_install_complete; then
        config_apply "$(config_load)" || { pause; return 1; }
        ok "当前已是最新版本，无需更新。"
        pause
        return 0
      fi
      warn "版本已是最新，但检测到部分运行组件缺失。"
      ask_confirm_default_yes "是否立即修复补齐？[Y/n]: " || return 0
    elif [ -n "${inst:-}" ]; then
      ask_confirm_default_yes "发现新版本 ${latest_ver}，是否现在升级？[Y/n]: " || return 0
    fi
  else
    param_echo "准备安装" "sing-box ${latest_ver}（内置流量统计支持）"
    echo ""
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

  ui_step 2 5 "下载 sing-box 内核"
  if ! download_file "$download_url" "$tmp_dir/$file" 20 3 "下载 sing-box"; then
    rm -rf "$tmp_dir"
    err "内核下载失败，请检查网络连接后重试。"
    pause
    return 1
  fi

  ui_step 3 5 "校验与解压安装包"
  if curl -fsSL --connect-timeout 20 --retry 3 "$sha_url" -o "$tmp_dir/sha256sum.txt" >/dev/null 2>&1; then
    local expected_sha actual_sha
    expected_sha="$(awk -v f="$file" '{n=$2; sub(/^.*\//,"",n); if (n==f) {print $1; exit}}' "$tmp_dir/sha256sum.txt")"
    actual_sha="$(sha256sum "$tmp_dir/$file" | awk '{print $1}')"
    if [ -z "$expected_sha" ] || [ "$expected_sha" != "$actual_sha" ]; then
      rm -rf "$tmp_dir"
      err "安装包校验不通过，文件可能损坏，已取消安装。"
      pause
      return 1
    fi
    ok "安装包校验通过"
  else
    warn "未获取到校验文件。"
    if ! ask_confirm_yn "是否跳过校验继续安装？[y/N]: "; then
      rm -rf "$tmp_dir"
      return 0
    fi
  fi

  tar -xzf "$tmp_dir/$file" -C "$tmp_dir" || {
    rm -rf "$tmp_dir"
    err "安装包解压失败。"
    pause
    return 1
  }

  [ -f "$tmp_dir/sing-box" ] || {
    rm -rf "$tmp_dir"
    err "安装包中未找到 sing-box 主程序。"
    pause
    return 1
  }

  chmod +x "$tmp_dir/sing-box" 2>/dev/null || true
  if ! "$tmp_dir/sing-box" version 2>/dev/null | grep -q 'with_v2ray_api'; then
    rm -rf "$tmp_dir"
    err "下载的内核不支持流量统计，已取消替换。"
    if [ "$PKG_MANAGER" = "apk" ]; then
      warn "Alpine 系统如果提示无法运行，请先执行：apk add gcompat"
    fi
    pause
    return 1
  fi

  ui_step 4 5 "准备流量统计组件"
  if ! ensure_grpcurl_logged || ! ensure_v2ray_api_proto_files; then
    rm -rf "$tmp_dir"
    err "流量统计组件准备失败，已取消安装。"
    pause
    return 1
  fi

  if ! user_db_initialize; then
    rm -rf "$tmp_dir"
    pause
    return 1
  fi

  ui_step 5 5 "写入内核并启动服务"
  if ! run_with_spinner "正在部署内核并验证服务运行..." with_manager_lock install_candidate_singbox "$tmp_dir/sing-box" "$tag"; then
    rm -rf "$tmp_dir"
    pause
    return 1
  fi
  rm -rf "$tmp_dir"

  ensure_sb_shortcut || true
  install_periodic_sync_cron || warn "实时同步定时任务未能自动写入，稍后可在「安装与卸载」中修复。"
  install_daily_maintenance_cron || warn "日常维护定时任务未能自动写入，稍后可在「安装与卸载」中修复。"
  remove_user_watch_cron || true
  remove_log_maintain_cron || true
  remove_tg_agent_cron || true
  remove_upstream_refresh_cron || true
  refresh_upstream_tag_cache "$tag" >/dev/null 2>&1 || true
  user_manager_background_sync >/dev/null 2>&1 || true
  tg_refresh_after_singbox_install || true

  echo ""
  ok "sing-box ${latest_ver} 安装完成！随时输入 s 可重新打开面板。"
  local inbound_cnt
  inbound_cnt="$(config_load 2>/dev/null | jq '.inbounds | length' 2>/dev/null || echo 0)"
  if [ "${inbound_cnt:-0}" -eq 0 ]; then
    echo ""
    if ask_confirm_default_yes "当前还没有任何节点，是否现在添加第一个节点？[Y/n]: "; then
      protocol_manager || true
      return 0
    fi
  else
    pause
  fi
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

# Clock checks are only called by new SS2022/VMess installation batches.
install_clock_service_active() {
  case "$INIT_SYSTEM" in
    systemd) systemctl is-active --quiet "$1" ;;
    openrc)  openrc_service_running "$1" ;;
    *) return 1 ;;
  esac
}

install_clock_service() {
  local service
  for service in chrony chronyd systemd-timesyncd ntpd ntpsec ntp openntpd; do
    if install_clock_service_active "$service" 2>/dev/null; then printf '%s\n' "$service"; return; fi
  done
  # An unmanaged daemon is still an existing clock service.
  if has_cmd pgrep; then
    for service in chronyd ntpd; do
      if pgrep -x "$service" >/dev/null 2>&1; then printf '%s\n' "$service"; return; fi
    done
  fi
  return 1
}

install_clock_reports_synchronized() {
  local report
  if [ "$INIT_SYSTEM" = systemd ] && has_cmd timedatectl &&
    [ "$(run_with_timeout 3 timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then
    return 0
  fi
  if has_cmd chronyc; then
    report="$(LC_ALL=C run_with_timeout 3 chronyc tracking 2>/dev/null)" &&
      awk -F: '
        /Leap status/ && $2 ~ /^[[:space:]]*Normal/ {normal=1}
        /System time/ {
          split($2, parts, " "); offset=parts[1]+0
          if (offset < 0) offset=-offset
          if (parts[1] ~ /^[-+]?[0-9]/ && offset <= 5) close_enough=1
        }
        END { exit !(normal && close_enough) }
      ' <<< "$report" && return 0
  fi
  if has_cmd ntpq; then
    report="$(LC_ALL=C run_with_timeout 3 ntpq -pn 2>/dev/null)" &&
      awk '/^[*]/ && $9 ~ /^[-+]?[0-9]/ && $9 >= -5000 && $9 <= 5000 {ok=1} END {exit !ok}' <<< "$report" &&
      return 0
  fi
  if has_cmd ntpctl; then
    report="$(run_with_timeout 3 ntpctl -s status 2>/dev/null)" && grep -q 'clock synced' <<< "$report" && return 0
  fi
  return 1
}

install_clock_epoch_utc() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null
}

# 0: close enough. 1: confirmed offset. 2: could not measure reliably.
install_clock_probe() {
  local server before after measured remote offset first=''
  for server in time.cloudflare.com time.apple.com; do
    before="$(date +%s)"
    measured="$(TZ=UTC run_with_timeout 4 sing-box tools synctime --server "$server" --format '2006-01-02 15:04:05' 2>/dev/null)" || continue
    after="$(date +%s)"
    [[ "$measured" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || continue
    (( after >= before && after - before <= 2 )) || continue
    remote="$(install_clock_epoch_utc "$measured")" || continue
    offset=$((remote - (before + after) / 2))
    if (( offset >= -5 && offset <= 5 )); then return 0; fi
    if [ -n "$first" ] && (( offset - first >= -2 && offset - first <= 2 )); then return 1; fi
    first="$offset"
  done
  return 2
}

install_clock_can_adjust() {
  local capabilities
  capabilities="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null)" || return 1
  [[ "$capabilities" =~ ^[[:xdigit:]]+$ ]] && (( (16#$capabilities & (1 << 25)) != 0 ))
}

install_clock_wait() {
  local started=$SECONDS
  while (( SECONDS - started < 30 )); do
    install_clock_reports_synchronized && return 0
    ui_echo "等待时间服务同步，已等待 $((SECONDS - started)) 秒。"
    sleep 3
  done
  install_clock_reports_synchronized || install_clock_probe
}

install_clock_correct() {
  local service="$1" verification=0
  case "$service" in
    chrony|chronyd)
      has_cmd chronyc && run_with_timeout 5 chronyc -a makestep >/dev/null 2>&1 || true
      ;;
    systemd-timesyncd)
      # Restart the already-running client only after two sources confirm a skew.
      run_with_timeout 5 systemctl restart systemd-timesyncd || return 1
      ;;
    ntpd|ntpsec|ntp|openntpd)
      # Let the running daemon converge. Do not replace another time service.
      ;;
    '')
      service="$(chrony_service_name)"
      if ! has_cmd chronyc; then
        ui_echo "未找到时间服务，正在安装 chrony。"
        run_with_spinner "正在安装 chrony" install_pkg chrony || return 1
      fi
      service="$(chrony_service_name)"
      if [ "$INIT_SYSTEM" = openrc ] && [ -z "$service" ]; then
        run_with_spinner "正在安装 OpenRC 时间服务" install_pkg chrony-openrc || return 1
        service="$(chrony_service_name)"
      fi
      [ -n "$service" ] || return 1
      chrony_service_start "$service" || return 1
      chrony_service_enable "$service"
      ;;
  esac
  install_clock_wait || return 1
  install_clock_probe || verification=$?
  case "$verification" in
    0) return 0 ;;
    2) install_clock_reports_synchronized ;;
    *) return 1 ;;
  esac
}

protocol_install_time_guard() {
  local probe service response
  install_clock_reports_synchronized && return 0
  while true; do
    ui_echo "正在检查系统时间。"
    probe=0
    run_with_spinner "正在核对时间源" install_clock_probe || probe=$?
    if [ "$probe" = 0 ]; then return 0; fi
    service="$(install_clock_service)" || service=''
    if [ "$probe" = 2 ] && [ -n "$service" ]; then
      probe=0
      install_clock_wait || probe=$?
      if [ "$probe" = 0 ]; then return 0; fi
    fi
    if [ "$probe" = 1 ]; then
      if ! install_clock_can_adjust; then
        warn "本机时间有偏差，当前环境不能改时间。请先在宿主机校时。"
        return 1
      fi
      if install_clock_correct "$service"; then return 0; fi
      warn "校时未通过，暂缓本批 SS2022 和 VMess。"
      return 1
    fi
    read -r -p "暂时无法核对时间。r 重试，c 继续安装，回车跳过 SS2022 和 VMess: " response || return 1
    case "$response" in
      r|R) ;;
      c|C) return 0 ;;
      *) return 1 ;;
    esac
  done
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

print_wireproxy_cleanup_hint_if_present() {
  wireproxy_warp_environment_present || return 0
  echo ""
  warn "检测到外部安装的 WARP（WireProxy）仍在运行，如需一并卸载可执行："
  echo "  wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh u"
}

_uninstall_core_runtime() {
  local keep_data="${1:-1}"
  if [ "$keep_data" = "1" ]; then
    sync_user_usage_counters || true
  fi
  remove_periodic_sync_cron || true
  remove_daily_maintenance_cron || true
  remove_user_watch_cron || true
  remove_log_maintain_cron || true
  remove_tg_agent_cron || true
  remove_upstream_refresh_cron || true
  rm -f "$UPSTREAM_TAG_CACHE_FILE" >/dev/null 2>&1 || true
  tg_stop_center_service || true
  if [ "$keep_data" = "1" ]; then
    tg_mark_disabled_keep_config || true
  fi
  remove_all_singbox_service_units
  # 清理 Hysteria2 端口跳跃防火墙规则与开机自恢复服务
  if [ "$keep_data" != "1" ]; then
    hy2_hop_remove_all_from_meta 2>/dev/null || true
  fi
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
  rm -f "$SINGBOX_BIN" "${SINGBOX_BIN}.bak" /usr/bin/sing-box "$SINGBOX_VERSION_STAMP" "$GRPCURL_BIN" >/dev/null 2>&1 || true
  rm -rf /var/tmp/sb-install.* /tmp/.sb_pkg_updated >/dev/null 2>&1 || true
  refresh_command_cache
  if pkg_installed sing-box || pkg_installed sing-box-beta; then
    case "$PKG_MANAGER" in
      apt)
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
}

uninstall_singbox_keep_config() {
  require_root
  clear
  print_rect_title "卸载 sing-box"
  echo ""
  echo -e "  ${C}1.${NC} 仅卸载程序（保留节点配置与用户数据，方便重装）"
  echo -e "  ${R}2.${NC} 彻底卸载并清空全部数据（删除配置、用户、日志、防火墙规则与脚本）"
  echo -e "  ${D}0. 返回上一级${NC}"
  ui_hr
  local mode
  read -r -p "请选择卸载方式（回车返回）: " mode
  case "${mode:-}" in
    1)
      echo ""
      ask_confirm_yn "确认仅卸载 sing-box 程序并保留配置数据吗？[y/N]: " || return 0
      run_with_spinner "正在停止服务并卸载程序..." _uninstall_core_runtime 1
      ok "卸载完成，节点配置与用户数据已保留。"
      print_wireproxy_cleanup_hint_if_present
      pause
      ;;
    2)
      echo ""
      warn "彻底卸载将永久删除所有节点配置、用户与流量记录、TG 配置、日志、端口跳跃规则及本脚本。"
      ask_confirm_yes "输入 yes 确认彻底卸载（回车取消）: " || return 0
      run_with_spinner "正在清理服务、防火墙规则与全部数据..." _uninstall_core_runtime 0
      rm -rf /etc/sing-box /etc/sing-box-manager /var/lib/sing-box /var/log/sing-box \
             /var/lock/singbox-manager.lock /var/lock/singbox-tg-agent.lock /var/lock/singbox-tg-agent.lock.d \
             "$SB_SHORTCUT" "$SB_TARGET_SCRIPT" /root/sing-box.sh >/dev/null 2>&1 || true
      echo ""
      ok "已彻底卸载并清空所有文件，无需手动清理。"
      print_wireproxy_cleanup_hint_if_present
      exit 0
      ;;
    ""|0|q|Q) return 0 ;;
    *) warn "无效选择。"; sleep 1 ;;
  esac
}

install_and_uninstall_menu() {
  while true; do
    clear
    print_rect_title "安装与卸载"
    singbox_status_summary
    ui_hr
    echo -e "  ${C}1.${NC} 安装或更新 sing-box"
    echo -e "  ${R}2.${NC} 卸载 sing-box"
    echo -e "  ${D}0. 返回主菜单${NC}"
    ui_hr
    local opt
    read -r -p "请选择操作（回车返回）: " opt
    case "${opt:-}" in
      1) install_or_update_singbox || true ;;
      2) uninstall_singbox_keep_config || true ;;
      ""|0|q|Q) return 0 ;;
      *) warn "无效输入：$opt"; sleep 1 ;;
    esac
  done
}

# >>>>>>>>> END MODULE: 80_installer.sh <<<<<<<<<<<

# >>>>>>>>> BEGIN MODULE: 90_protocol_menu.sh <<<<<<<<<<<
# ============================================================
# 模块: 90_protocol_menu.sh
# 职责: 协议管理菜单、安装/卸载协议、系统工具与状态概览
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

# ---------- Protocol installation ----------
install_port_available() {
  local json="$1" meta="$2" proto="$3" port="$4" layer listeners
  ! port_conflict_for_protocol "$json" "$proto" "$port" || return 1
  for layer in $(protocol_transport_layer "$proto"); do
    if [ "$layer" = udp ] &&
      hy2_hop_range_in_use_by_meta "$meta" "$port" "$port"; then return 1; fi
    if has_cmd ss; then
      listeners="$(ss "-Hln${layer:0:1}" 2>/dev/null)" || continue
      if awk -v port="$port" '$4 ~ (":" port "$") { found=1 } END { exit !found }' <<< "$listeners"; then
        return 1
      fi
    fi
  done
}

install_recommended_port() {
  local json="$1" meta="$2" proto="$3" first fallback port
  case "$proto" in
    shadowsocks) first=8080; fallback=8081 ;;
    socks) first=1080; fallback=1081 ;;
    vmess-ws) first=8001; fallback=8003 ;;
    vless-ws) first=8002; fallback=8003 ;;
    *) first=443; fallback=8443 ;;
  esac
  if install_port_available "$json" "$meta" "$proto" "$first"; then
    printf '%s\n' "$first"
    return
  fi
  for ((port=fallback; port<fallback+100; port++)); do
    if install_port_available "$json" "$meta" "$proto" "$port"; then
      printf '%s\n' "$port"
      return
    fi
  done
  return 1
}

install_hy2_range_available() {
  local json="$1" meta="$2" port="$3" start="$4" end="$5" listeners
  hy2_hop_range_valid "$start" "$end" "$port" || return 1
  ! hy2_hop_range_in_use_by_meta "$meta" "$start" "$end" || return 1
  if jq -e --argjson start "$start" --argjson end "$end" '
    any(.inbounds[]?; .listen_port >= $start and .listen_port <= $end and
       (.type == "hysteria2" or .type == "hysteria" or .type == "tuic" or
        (.type == "shadowsocks" and (.network // "") != "tcp")))
  ' <<< "$json" >/dev/null; then return 1; fi
  if has_cmd ss && listeners="$(ss -Hlnu 2>/dev/null)"; then
    if awk -v start="$start" -v end="$end" '
      {n=split($4,a,":"); if (a[n]+0 >= start && a[n]+0 <= end) used=1}
      END {exit !used}
    ' <<< "$listeners"; then return 1; fi
  fi
}

install_hy2_recommended_range() {
  local json="$1" meta="$2" port="$3" start end
  for ((start=HY2_HOP_DEFAULT_START, end=HY2_HOP_DEFAULT_END; end<=65535; start+=3500, end+=3500)); do
    if install_hy2_range_available "$json" "$meta" "$port" "$start" "$end"; then
      printf '%s-%s\n' "$start" "$end"
      return
    fi
  done
  return 1
}

protocol_preserved_edit() {
  local json="$1" meta="$2" tag="$3" host="$4" port="$5" mapping="$6"
  [ -n "$(find_inbound_by_entry_key "$json" "$tag")" ] || return 1
  jq --arg tag "$tag" --arg host "$host" --arg port "$port" --arg mapping "$mapping" '
    if $mapping == "reset" then del(.[$tag].public_endpoint)
    else .[$tag].public_endpoint = {host:$host, port:($port | tonumber)} end
  ' <<< "$meta"
}

protocol_save_public_endpoint() {
  local json meta candidate
  json="$(user_manager_config_for_edit)" || return 1
  meta="$(meta_load)" || return 1
  candidate="$(protocol_preserved_edit "$json" "$meta" "$@")" || return 1
  meta_save "$candidate"
}

protocol_edit_menu() {
  local json="$1" lines=() selected tag proto port meta current host public_port answer
  mapfile -t lines < <(protocol_entry_table "$json")
  [ "${#lines[@]}" -gt 0 ] || { warn "当前没有可编辑节点。"; pause; return 0; }
  local i
  for i in "${!lines[@]}"; do
    IFS=$'\x01' read -r tag proto port <<< "${lines[i]}"
    printf '  %s. %s (%s)\n' "$((i+1))" "$tag" "$port"
  done
  read -r -p "选择要编辑导出地址的节点（回车返回）: " selected || return 0
  [[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "$selected" -le "${#lines[@]}" ] || return 0
  IFS=$'\x01' read -r tag proto port <<< "${lines[selected-1]}"
  case "$proto" in
    *-ws) say "WebSocket 公网地址请在「接入已有 CDN」中验证并保存。"; pause; return 0 ;;
  esac
  meta="$(meta_load)" || return 1
  current="$(jq -r --arg tag "$tag" '.[$tag].public_endpoint.host // empty' <<< "$meta")"
  public_port="$(jq -r --arg tag "$tag" --arg port "$port" '.[$tag].public_endpoint.port // $port' <<< "$meta")"
  say "监听端口 ${port}。保留原凭据、证书、路径和监听设置。"
  read -r -p "导出地址 [${current:-自动}]（域名、IPv4 或 IPv6，回车返回，输入 - 恢复自动）: " host || return 0
  [ -n "$host" ] || return 0
  if [ "$host" = - ]; then
    with_manager_lock protocol_save_public_endpoint "$tag" '' 0 reset || return 1
  else
    host="${host#[}"; host="${host%]}"
    [[ "$host" =~ ^[A-Za-z0-9:.%-]+$ ]] || { warn "请输入域名或 IP，不带 URL 路径。"; return 1; }
    read -r -p "公网端口 [$public_port]: " answer || return 0
    public_port="${answer:-$public_port}"
    [[ "$public_port" =~ ^[1-9][0-9]{0,4}$ ]] && ((public_port <= 65535)) || { warn "公网端口无效。"; return 1; }
    with_manager_lock protocol_save_public_endpoint "$tag" "$host" "$public_port" save || return 1
  fi
  # Export-only edits leave the runtime and existing remote client links intact.
  ok "导出地址已更新。"
  pause
}

# 按 meta 快照清理一批已删除的 hy2 节点的跳跃规则与记录（卸载/清空配置共用）。
# 参数：meta JSON，之后是 entry_key 列表。只删没有其它节点在用的范围。
# 回显更新后的 meta JSON；调用方在有变化时 meta_save。
hy2_hop_cleanup_removed() {
  local meta_json="${1:-}"; shift
  [ -n "$meta_json" ] || meta_json='{}'
  local _meta_out="$meta_json" _tag _range _port _after
  for _tag in "$@"; do
    _range="$(hy2_hop_range_from_meta "$_meta_out" "$_tag")"
    [ -n "$_range" ] || continue
    hy2_parse_hop_range "$_range" || continue
    _port="$(entry_key_to_port "$_tag")"
    _after="$(hy2_hop_range_del_from_meta "$_meta_out" "$_tag")"
    if hy2_hop_range_in_use_by_meta "$_after" "$_HOP_START" "$_HOP_END" "$_tag"; then
      _meta_out="$_after"
      continue
    fi
    hy2_hop_remove "$_HOP_START" "$_HOP_END" "$_port"
    _meta_out="$_after"
  done
  echo "$_meta_out"
}

protocol_commit_changes() {
  local previous="$1" previous_meta="$2" proposed="$3" meta="$4" latest latest_meta
  latest="$(user_manager_config_for_edit)" || return 1
  latest_meta="$(meta_load)" || return 1
  if [ "$(jq -Sc . <<< "$previous")" != "$(jq -Sc . <<< "$latest")" ] ||
    [ "$(jq -Sc . <<< "$previous_meta")" != "$(jq -Sc . <<< "$latest_meta")" ]; then
    warn "节点资料已变化，请重新打开菜单确认。"
    return 1
  fi
  if user_db_exists; then
    _USER_KEEP_LATEST_DB=1 _USER_MANAGER_APPLY_QUIET_OK=1 user_manager_apply_changes '' "$proposed" "$meta"
  elif user_db_is_first_use; then
    proposed="$(route_rebuild "$proposed" "$meta")" || return 1
    config_and_meta_apply "$proposed" "$meta"
  else
    user_db_restore_hint
    return 1
  fi
}

protocol_install_menu() {
  local previous="$1" proposed="$1" previous_meta meta tag proto port choice answer custom
  local host sni pair sid inbound obfs range start end cert_name path listen pass
  local opt ws_kind clock_needed=0 installed='[]'
  local -a picks=() chosen=() pending_clock=() hop_tags=() hop_ranges=()
  meta="$(meta_load)" || return 1
  previous_meta="$meta"
  print_rect_title "安装节点"
  for ((opt=0; opt<7; opt++)); do
    proto="${SUPPORTED_PROTOCOLS[opt]}"
    printf '  %s. %s\n' "$((opt+1))" "$proto"
  done
  printf '  8. WebSocket 节点（默认 VLESS-WS）\n'
  read -r -p "选择协议（用 + 多选，回车返回）: " choice || return 0
  [ -n "$choice" ] || return 0
  mapfile -t picks < <(parse_plus_selections "$choice")
  for opt in "${picks[@]}"; do
    if ! [[ "$opt" =~ ^[1-8]$ ]]; then warn "请选择列表里的协议。"; return 1; fi
    if [ "$opt" -eq 8 ]; then
      read -r -p "WebSocket 协议（回车 VLESS，m 选 VMess，b 两种都装）: " ws_kind || return 0
      case "$ws_kind" in
        '') chosen+=(vless-ws) ;;
        m|M) chosen+=(vmess-ws) ;;
        b|B) chosen+=(vmess-ws vless-ws) ;;
        *) warn "请选择回车、m 或 b。"; return 1 ;;
      esac
    else
      chosen+=("${SUPPORTED_PROTOCOLS[opt-1]}")
    fi
  done

  for proto in "${chosen[@]}"; do
    range='' obfs='' pass='' listen=127.0.0.1 cert_name="$SELF_SIGNED_SNI"
    port="$(install_recommended_port "$proposed" "$meta" "$proto")" || {
      warn "$proto 暂无推荐端口。"; continue;
    }
    if [ "$proto" = hysteria2 ]; then
      obfs=gecko
      range="$(install_hy2_recommended_range "$proposed" "$meta" "$port")" || range=''
    fi
    printf '\n  %s · %s %s\n' "$proto" "$(protocol_transport_layer "$proto")" "$port"
    case "$proto" in
      hysteria2) printf '  Gecko，端口跳跃 %s\n' "${range:-待选择}" ;;
      vless-reality) printf '  握手目标 %s，自动生成密钥、Short ID 和 UUID\n' "$REALITY_DEFAULT_HANDSHAKE" ;;
      socks) printf '  推荐在落地机安装。装好后复制落地链接，到中转机粘贴。\n' ;;
      *-ws) printf '  本机监听 %s，自动生成 UUID 和路径。\n' "$listen" ;;
      *) printf '  自动生成连接凭据。\n' ;;
    esac
    read -r -p "回车使用推荐值，c 自定义，q 跳过: " answer || return 0
    custom=0
    case "$answer" in
      '') ;;
      c|C) custom=1 ;;
      q|Q) continue ;;
      *) warn "请选择回车、c 或 q。"; continue ;;
    esac
    if [ "$custom" = 1 ]; then
      read -r -p "监听端口 [$port]: " answer || return 0
      port="${answer:-$port}"
      if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || ((port>65535)); then
        warn "监听端口无效。"; continue
      fi
      tag="$(entry_key_from_parts "$proto" "$port")" || return 1
      if [ -n "$(find_inbound_by_entry_key "$proposed" "$tag")" ]; then
        warn "$tag 已安装。可在「编辑节点」中更新导出地址，原连接资料会保留。"; continue
      fi
      if ! install_port_available "$proposed" "$meta" "$proto" "$port"; then
        warn "端口 $port 已被占用或处于现有跳跃范围内。"; continue
      fi
      case "$proto" in
        anytls|hysteria2|trojan|tuic|socks|shadowsocks)
          read -r -p "凭据（回车自动生成）: " pass || return 0 ;;
        *-ws)
          read -r -p "本机监听地址 [$listen]: " answer || return 0
          listen="${answer:-$listen}" ;;
      esac
      if [ "$proto" = hysteria2 ]; then
        range="$(install_hy2_recommended_range "$proposed" "$meta" "$port")" || range=''
        read -r -p "混淆（回车 Gecko，s Salamander，n 关闭）: " answer || return 0
        case "$answer" in '') ;; s|S) obfs=salamander ;; n|N) obfs='' ;; *) warn "混淆选项无效。"; continue ;; esac
        read -r -p "端口跳跃范围 [${range:-需填写}]，n 关闭: " answer || return 0
        case "$answer" in n|N) range='' ;; *) range="${answer:-$range}" ;; esac
      fi
    fi
    if [ "$proto" = hysteria2 ]; then
      if [ -n "$range" ]; then
        if ! hy2_parse_hop_range "$range" ||
          ! install_hy2_range_available "$proposed" "$meta" "$port" "$_HOP_START" "$_HOP_END"; then
          warn "UDP 跳跃范围无效或已占用。"; continue
        fi
        start="$_HOP_START"; end="$_HOP_END"
      elif [ "$custom" = 0 ]; then
        warn "没有可用的跳跃范围，请在自定义中指定范围。"; continue
      fi
    fi
    tag="$(entry_key_from_parts "$proto" "$port")" || return 1
    case "$proto" in
      hysteria2) inbound="$(build_hysteria2_inbound "$port" "$cert_name" "$pass" "$obfs")" || return 1 ;;
      vless-reality)
        host="$REALITY_DEFAULT_HANDSHAKE"
        if [ "$custom" = 1 ]; then
          read -r -p "Reality 握手域名 [$host]: " answer || return 0
          host="${answer:-$host}"
        fi
        if ! run_with_spinner "验证 Reality 握手目标" reality_handshake_check "$host"; then
          warn "无法验证 $host 的域名证书、TLS 1.3 或 HTTP/2。请选择自定义，换一个握手域名。"
          continue
        fi
        pair="$(generate_reality_keypair_auto)" || return 1
        sid="$(openssl rand -hex 4)" || return 1
        inbound="$(build_vless_reality_inbound "$port" "$host" "${pair%%$'\t'*}" "$sid")" || return 1
        meta="$(jq --arg tag "$tag" --arg public "${pair#*$'\t'}" '
          .[$tag] = ((.[$tag] // {}) + {public_key:$public, private_key_auto_generated:true})
        ' <<< "$meta")" || return 1 ;;
      anytls) inbound="$(build_anytls_inbound "$port" "$cert_name" "$pass")" || return 1 ;;
      shadowsocks)
        if ! inbound="$(build_ss_inbound "$port" "$pass")"; then
          warn "SS2022 密钥须是解码后 16 字节的 Base64，可分别指定两段。"; continue
        fi ;;
      socks) inbound="$(build_socks_inbound "$port" "$pass")" || return 1 ;;
      tuic) inbound="$(build_tuic_inbound "$port" "$cert_name" "$pass")" || return 1 ;;
      trojan) inbound="$(build_trojan_inbound "$port" "$cert_name" "$pass")" || return 1 ;;
      vmess-ws|vless-ws)
        answer=''
        if [ "$custom" = 1 ]; then read -r -p 'WS 路径（回车自动生成）: ' answer || return 0; fi
        path="$(normalize_ws_path "$answer")" || return 1
        if [ "$proto" = vmess-ws ]; then
          inbound="$(build_vmess_ws_inbound "$port" "$listen" "$path")" || return 1
        else
          inbound="$(build_vless_ws_inbound "$port" "$listen" "$path")" || return 1
        fi ;;
    esac
    case "$proto" in shadowsocks|vmess-ws) clock_needed=1; pending_clock+=("$tag") ;; esac
    if [ "$proto" = hysteria2 ] && [ -n "$range" ]; then
      hop_tags+=("$tag"); hop_ranges+=("$range")
      meta="$(hy2_hop_range_set_in_meta "$meta" "$tag" "$start" "$end")" || return 1
    fi
    proposed="$(jq --argjson inbound "$inbound" '.inbounds += [$inbound]' <<< "$proposed")" || return 1
    installed="$(jq --arg tag "$tag" '. + [$tag]' <<< "$installed")" || return 1
  done

  if [ "$clock_needed" = 1 ] && ! protocol_install_time_guard; then
    warn "已暂缓本批 SS2022 和 VMess，其余节点继续。"
    for tag in "${pending_clock[@]}"; do
      proposed="$(remove_inbound_by_entry_key "$proposed" "$tag")" || return 1
      installed="$(jq --arg tag "$tag" 'map(select(. != $tag))' <<< "$installed")" || return 1
    done
  fi
  [ "$installed" != '[]' ] || return 0
  with_manager_lock protocol_commit_changes "$previous" "$previous_meta" "$proposed" "$meta" || return 1

  for opt in "${!hop_tags[@]}"; do
    tag="${hop_tags[opt]}"
    port="$(entry_key_to_port "$tag")"
    hy2_parse_hop_range "${hop_ranges[opt]}" || return 1
    if hy2_hop_apply "$_HOP_START" "$_HOP_END" "$port" &&
      hy2_hop_rule_verified "$_HOP_START" "$_HOP_END" "$port"; then
      ok "端口跳跃已启用。请在云安全组放行 UDP ${_HOP_START}-${_HOP_END} 和 UDP ${port}。"
    else
      warn "$tag 的跳跃规则未通过验证，导出将使用主端口。"
      hy2_hop_remove "$_HOP_START" "$_HOP_END" "$port" || true
      meta="$(meta_load)" &&
        meta="$(hy2_hop_range_del_from_meta "$meta" "$tag")" &&
        meta_save "$meta" || warn "跳跃记录未能清理，请检查管理资料。"
    fi
  done
  if [ "${#hop_tags[@]}" -gt 0 ]; then
    hy2_hop_restore_sync || warn "开机恢复未验证，请检查端口跳跃服务。"
  fi
  ok "节点已安装。"
  if jq -e 'any(.[]; startswith("vmess-ws-") or startswith("vless-ws-"))' <<< "$installed" >/dev/null; then
    say "在「接入已有 CDN」中验证 WebSocket 公网入口后即可导出。"
  fi
  export_configs "__admin__" "$installed" || true
}

# ---------- 协议卸载菜单 ----------

protocol_remove_menu() {
  local json="$1"
  local lines=() choice_arr updated_json="$json" c entry_key related sel _rtype
  # 卸载前快照 Hysteria2 跳跃范围（meta 中），成功后按此清理防火墙规则
  local _remove_meta new_meta
  _remove_meta="$(meta_load 2>/dev/null)" || _remove_meta='{}'
  [ -n "$_remove_meta" ] || _remove_meta='{}'
  new_meta="$_remove_meta"
  local -a _removed_hy2_keys=()
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
    IFS=$'\x01' read -r entry_key _rtype _ <<< "${lines[$((c-1))]}"
    if ws_cdn_has_managed_entry "$_remove_meta" "$entry_key"; then
      warn "$entry_key 仍有脚本托管的 CDN 路径。请先在「接入已有 CDN」中移除该入口。"
      pause
      return 1
    fi
    if [ "$_rtype" = "hysteria2" ]; then _removed_hy2_keys+=("$entry_key"); fi
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
    new_meta="$(jq --arg entry "$entry_key" 'del(.[$entry])' <<< "$new_meta")" || return 1
  done

  local _apply_ok=0
  if with_manager_lock protocol_commit_changes "$json" "$_remove_meta" "$updated_json" "$new_meta"; then
    _apply_ok=1
  else
    warn "协议卸载失败，已返回上一级。"
  fi
  if [ "$_apply_ok" -eq 1 ] && [ ${#_cert_files_to_clean[@]} -gt 0 ]; then
    for _f in "${_cert_files_to_clean[@]}"; do
      rm -f "$_f" >/dev/null 2>&1 || true
    done
  fi
  # 卸载成功的 hy2 节点：没有其它节点在用的跳跃范围就删规则、清记录
  if [ "$_apply_ok" -eq 1 ] && [ ${#_removed_hy2_keys[@]} -gt 0 ]; then
    hy2_hop_cleanup_removed "$_remove_meta" "${_removed_hy2_keys[@]}" >/dev/null
    # 没有跳跃范围剩下时，顺带拆掉开机自恢复服务。
    hy2_hop_restore_sync || warn "开机自恢复服务同步失败，请手动检查。"
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
    json="$(user_manager_config_for_edit)" || return 1
    print_rect_title "节点管理"
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
    echo -e "  ${C}3.${NC} 编辑节点导出地址"
    echo -e "  ${C}4.${NC} 接入已有 CDN"
    echo -e "  ${R}0.${NC} 返回主菜单"
    read -r -p "请选择操作: " act
    case "${act:-}" in
      1) protocol_install_menu "$json" || true ;;
      2) protocol_remove_menu "$json" || true ;;
      3) protocol_edit_menu "$json" || true ;;
      4) ws_cdn_menu "$json" || true ;;
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
  local empty_config empty_meta current_config _clear_meta
  current_config="$(user_manager_config_for_edit)" || return 1
  _clear_meta="$(meta_load)" || return 1
  if jq -e 'any(to_entries[] | select(.value|type=="object") | .value.cdn_entries[]?; .mode == "nginx")' <<< "$_clear_meta" >/dev/null; then
    warn "还有脚本托管的 CDN 路径。请先在「接入已有 CDN」中移除这些入口。"
    pause
    return 1
  fi
  empty_config="$(config_min_template)"
  empty_meta="$(jq --argjson config "$current_config" '
    reduce ($config.inbounds[]?.tag // empty) as $tag (del(.warp,.relay); del(.[$tag]))
  ' <<< "$_clear_meta")" || return 1
  if with_manager_lock protocol_commit_changes "$current_config" "$_clear_meta" "$empty_config" "$empty_meta"; then
    ok "配置已清空，分流状态已重置。"
    # 清空配置会删掉所有 hy2 入站，顺带清理其跳跃规则，避免残留重定向
    local -a _clear_keys=()
    mapfile -t _clear_keys < <(echo "$_clear_meta" | jq -r 'to_entries[] | select(.key | startswith("hy2-")) | select(.value.hop_start != null) | .key')
    if [ ${#_clear_keys[@]} -gt 0 ]; then
      hy2_hop_cleanup_removed "$_clear_meta" "${_clear_keys[@]}" >/dev/null
      # 所有 hy2 节点都清掉了，顺带拆掉开机自恢复服务。
      hy2_hop_restore_sync || warn "开机自恢复服务同步失败，请手动检查。"
    fi
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
        active) _status="${G}● 运行中${NC}" ;;
        failed) _status="${Y}● 异常${NC}" ;;
        activating) _status="${Y}● 启动中${NC}" ;;
        *) _status="${R}○ 已停止${NC}" ;;
      esac
      ;;
    openrc)
      _state="$(rc-service sing-box status 2>&1 || true)"
      case "$_state" in
        *crashed*) _status="${Y}● 异常${NC}" ;;
        *started*|*running*) _status="${G}● 运行中${NC}" ;;
        *stopped*) _status="${R}○ 已停止${NC}" ;;
        *)
          if singbox_service_active; then
            _status="${G}● 运行中${NC}"
          else
            _status="${R}○ 已停止${NC}"
          fi
          ;;
      esac
      ;;
    *)
      if singbox_service_active; then
        _status="${G}● 运行中${NC}"
      else
        _status="${R}○ 已停止${NC}"
      fi
      ;;
  esac
  _version=""
  if [ -x "$SINGBOX_BIN" ]; then
    _version="$("$SINGBOX_BIN" version 2>/dev/null | awk '/^sing-box version / {print $3; exit}')"
  fi
  [ -n "$_version" ] || _version="未安装"

  _suffix=""
  _upstream="$(get_cached_upstream_version 2>/dev/null || true)"
  if [ "$_version" != "未安装" ] && [ -n "$_upstream" ]; then
    if [ "$_version" != "$_upstream" ] && version_ge "$_upstream" "$_version"; then
      _suffix="  ${Y}↑ 有新版 v${_upstream}${NC}"
    fi
  fi

  if [ "$_version" = "未安装" ]; then
    printf '  %b运行状态：%b%b  %b(未安装内核)%b\n' "$D" "$NC" "$_status" "$Y" "$NC"
  else
    printf '  %b运行状态：%b%b  %bv%s%b%b\n' "$D" "$NC" "$_status" "$C" "$_version" "$NC" "$_suffix"
  fi
}

# 主界面轻量概览：零网络请求，纯本地快速统计节点/中转/用户/扩展状态
singbox_dashboard_summary() {
  singbox_status_summary
  local node_cnt=0 relay_cnt=0 user_cnt=0 disabled_cnt=0
  if [ -s "$CONFIG_FILE" ] && has_cmd jq; then
    read -r node_cnt relay_cnt < <(
      jq -r '
        [
          ((.inbounds // []) | length),
          ([.outbounds[]? | select((.tag // "") | startswith("to-"))] | length)
        ] | @tsv
      ' "$CONFIG_FILE" 2>/dev/null || printf '0\t0\n'
    )
  fi
  if [ -s "$USER_DB_FILE" ] && has_cmd jq; then
    read -r user_cnt disabled_cnt < <(
      jq -r '
        [
          ((.users // {}) | length),
          ([(.users // {})[] | select(.enabled != true)] | length)
        ] | @tsv
      ' "$USER_DB_FILE" 2>/dev/null || printf '0\t0\n'
    )
  fi
  local user_txt="${user_cnt} 位用户"
  [ "${disabled_cnt:-0}" -gt 0 ] && user_txt="${user_cnt} 位用户 (${disabled_cnt} 停用)"
  printf '  %b节点概览：%b%b%s%b 个节点 · %b%s%b 条中转 · %b%s%b\n' \
    "$D" "$NC" "$W" "${node_cnt:-0}" "$NC" "$W" "${relay_cnt:-0}" "$NC" "$W" "$user_txt" "$NC"

  local warp_txt="${D}未开启${NC}" tg_txt="${D}未启用${NC}"
  if [ -s "$META_FILE" ] && has_cmd jq; then
    local w_cnt
    w_cnt="$(jq -r 'if (.warp.mode // "off") == "rules" then ((.warp.rules // []) | length) else 0 end' "$META_FILE" 2>/dev/null || echo 0)"
    [ "${w_cnt:-0}" -gt 0 ] && warp_txt="${G}已开启(${w_cnt}条)${NC}"
  fi
  if [ -s "$TG_CONFIG_FILE" ] && has_cmd jq; then
    local tg_en tg_role
    read -r tg_en tg_role < <(jq -r '[(.enabled // false | tostring), (.role // "")] | @tsv' "$TG_CONFIG_FILE" 2>/dev/null || printf 'false\t\n')
    if [ "$tg_en" = "true" ]; then
      case "$tg_role" in
        center) tg_txt="${G}中心端${NC}" ;;
        agent)  tg_txt="${G}节点端${NC}" ;;
        *)      tg_txt="${G}已启用${NC}" ;;
      esac
    fi
  fi
  printf '  %b扩展功能：%bWARP 分流 %b  ·  Telegram %b\n' "$D" "$NC" "$warp_txt" "$tg_txt"
}

singbox_restart() {
  clear
  print_rect_title "重启 sing-box"
  if run_with_spinner "正在重启 sing-box 并检查状态..." reload_or_restart_singbox_safe; then
    ok "sing-box 已重启并运行正常。"
  else
    err "重启失败，请查看实时日志排查原因。"
  fi
  echo ""
  pause
}

singbox_start() {
  clear
  print_rect_title "启动 sing-box"
  local rc=0
  case "$INIT_SYSTEM" in
    systemd) run_with_spinner "正在启动 sing-box..." systemctl start sing-box || rc=1 ;;
    openrc)  run_with_spinner "正在启动 sing-box..." openrc_start_service sing-box || rc=1 ;;
    *) err "未识别的系统服务管理器，无法启动。"; pause; return 1 ;;
  esac
  sleep 1
  if [ "$rc" -eq 0 ] && singbox_service_active; then
    ok "sing-box 已启动并运行正常。"
  else
    err "启动失败，请检查配置或查看日志。"
  fi
  echo ""
  pause
}

singbox_stop() {
  clear
  print_rect_title "停止 sing-box"
  case "$INIT_SYSTEM" in
    systemd) run_with_spinner "正在停止 sing-box..." systemctl stop sing-box && ok "sing-box 已停止。" || err "停止失败。" ;;
    openrc)  run_with_spinner "正在停止 sing-box..." openrc_stop_service sing-box && ok "sing-box 已停止。" || err "停止失败。" ;;
    *) err "未识别的系统服务管理器，无法停止。" ;;
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
    ui_hr
    local toggle_label
    if singbox_service_active; then
      toggle_label="停止 sing-box 服务"
    else
      toggle_label="启动 sing-box 服务"
    fi
    echo -e "  ${C}1.${NC} 重启 sing-box 服务"
    echo -e "  ${C}2.${NC} ${toggle_label}"
    echo -e "  ${C}3.${NC} 查看实时运行日志"
    echo -e "  ${C}4.${NC} 查看当前配置文件"
    echo -e "  ${Y}5.${NC} 重置全部节点配置 ${D}(清空 config.json)${NC}"
    echo -e "  ${D}0. 返回主菜单${NC}"
    ui_hr
    local act
    read -r -p "请选择操作（回车返回）: " act
    case "${act:-}" in
      1) singbox_restart ;;
      2)
        if singbox_service_active; then
          singbox_stop
        else
          singbox_start
        fi
        ;;
      3) view_realtime_log ;;
      4) view_config_formatted ;;
      5) clear_config_json ;;
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
    print_rect_title "Sing-box 管理面板  v${SCRIPT_VERSION}"
    singbox_dashboard_summary
    if ! has_cmd sing-box; then
      echo "  首次使用请选择「安装与卸载」安装 sing-box。"
    fi
    ui_hr
    ui_section "核心功能"
    echo -e "    ${C}1.${NC} 节点管理       ${D}安装 / 查看 / 删除协议节点${NC}"
    echo -e "    ${C}2.${NC} 中转管理       ${D}全流量转发 / 按网站分流中转${NC}"
    echo -e "    ${C}3.${NC} 用户管理       ${D}多用户管理 / 套餐限额 / 流量统计${NC}"
    echo -e "    ${C}4.${NC} 导出配置       ${D}通用链接 / Clash / QX${NC}"

    ui_section "系统维护"
    echo -e "    ${C}5.${NC} 安装与卸载     ${D}安装内核 / 检查更新 / 一键卸载${NC}"
    echo -e "    ${C}6.${NC} 系统工具       ${D}重启服务 / 实时日志${NC}"

    ui_section "扩展功能（可选）"
    echo -e "    ${C}7.${NC} WARP 分流      ${D}让选中的网站走 WARP${NC}"
    echo -e "    ${C}8.${NC} Telegram Bot   ${D}查流量 / 到期提醒 / 远程管理${NC}"
    echo ""
    echo -e "    ${D}0. 退出${NC}"
    ui_hr
    read -r -p "请选择操作: " opt || return 0
    case "${opt:-}" in
      1) protocol_manager || true ;;
      2) manage_relay_nodes || true ;;
      3) user_manager_menu || true ;;
      4) export_configs || true ;;
      5) install_and_uninstall_menu || true ;;
      6) system_tools_menu || true ;;
      7) warp_manager_menu || true ;;
      8) telegram_bot_manager_menu || true ;;
      0|q|Q) exit 0 ;;
      "") continue ;;
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
# is_install_complete 探针会在用户进入「安装与卸载」 时引导清理这些老 cron。
if [[ "${1:-}" == "--user-watch" ]] || [[ "${1:-}" == "--maintain-logs" ]] || \
   [[ "${1:-}" == "--tg-agent-sync" ]] || [[ "${1:-}" == "--refresh-upstream" ]]; then
  exit 0
fi

# 开机恢复 Hysteria2 端口跳跃规则（systemd 服务 / @reboot cron 调用，无交互）。
if [[ "${1:-}" == "--restore-hy2-hops" ]]; then
  hy2_hop_restore_all
  exit $?
fi

main_menu

# >>>>>>>>> END MODULE: 99_main.sh <<<<<<<<<<<
