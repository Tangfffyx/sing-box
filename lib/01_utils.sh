#!/usr/bin/env bash
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
