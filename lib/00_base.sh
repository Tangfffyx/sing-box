#!/usr/bin/env bash
# ============================================================
# 模块: 00_base.sh
# 职责: 全局常量、颜色码、UI 基础函数、协议注册表、共享 jq 模板
# ============================================================

set -Eeuo pipefail

# -------------------- 版本 --------------------
SCRIPT_VERSION="6.1.8"

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
V2RAY_PROTO_EXP="/etc/sing-box/v2rayapi-experimental.proto"
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

declare -A PREFIX_TO_PROTO=(
  [reality]=vless-reality
  [anytls]=anytls
  [ss]=shadowsocks
  [trojan]=trojan
  [vmess-ws]=vmess-ws
  [vless-ws]=vless-ws
  [tuic]=tuic
  [socks]=socks
)

declare -A PROTO_TRANSPORT=(
  [vless-reality]=tcp
  [anytls]=tcp
  [shadowsocks]=tcp
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
