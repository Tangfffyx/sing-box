#!/usr/bin/env bash
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
