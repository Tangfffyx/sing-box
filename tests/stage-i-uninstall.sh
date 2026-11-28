#!/usr/bin/env bash
# Use the generated menus and cleanup functions with all OS operations redirected.
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed '/^main_menu$/d' sb.sh)
tmp="$(mktemp -d)"
trap 'command rm -rf "$tmp"' EXIT
require_root() { :; }
clear() { :; }
pause() { :; }
pkg_installed() { return 1; }
wireproxy_warp_environment_present() { return 1; }
deluser() { :; }
delgroup() { :; }
rmdir() { :; }
sync_user_usage_counters() { touch "$tmp/sampled"; }
remove_periodic_sync_cron() { command rm -f "$tmp/sync"; }
remove_daily_maintenance_cron() { command rm -f "$tmp/maintain"; }
remove_user_watch_cron() { :; }
remove_log_maintain_cron() { :; }
remove_tg_agent_cron() { command rm -f "$tmp/agent"; }
remove_upstream_refresh_cron() { :; }
remove_all_singbox_service_units() { command rm -f "$tmp/core-service"; }
tg_stop_center_service() { command rm -f "$tmp/bot-service"; }
hy2_hop_remove_all_from_meta() { command rm -f "$tmp/hop"; }
rm() {
  local raw
  local -a args=()
  for raw; do
    case "$raw" in
      -*) args+=("$raw") ;;
      "$tmp"/*) args+=("$raw") ;;
      /etc/sing-box|/etc/sing-box-manager|/var/lib/sing-box|/var/log/sing-box|/var/lock/*|/root/sing-box.sh)
        args+=("$tmp${raw}") ;;
      /usr/bin/sing-box|/var/tmp/sb-install.*|/tmp/.sb_pkg_updated) ;;
      *) printf 'Unexpected test removal: %s\n' "$raw" >&2; return 2 ;;
    esac
  done
  command rm "${args[@]}"
}
for mode in keep destroy; do
  mkdir -p "$tmp/etc/sing-box" "$tmp/etc/sing-box-manager" "$tmp/var/log/sing-box" "$tmp/var/lib/sing-box"
  TG_CONFIG_FILE="$tmp/etc/sing-box-manager/telegram.json"
  SB_LOCK_FILE="$tmp/lock"
  CONFIG_FILE="$tmp/etc/sing-box/config.json"
  USER_DB_FILE="$tmp/etc/sing-box-manager/users.json"
  META_FILE="$tmp/etc/sing-box-manager/meta.json"
  TG_AGENT_LOCK_FILE="$tmp/agent-lock"
  UPSTREAM_TAG_CACHE_FILE="$tmp/upstream"
  SINGBOX_BIN="$tmp/bin"
  SINGBOX_VERSION_STAMP="$tmp/version"
  GRPCURL_BIN="$tmp/grpcurl"
  SB_SHORTCUT="$tmp/s"
  SB_TARGET_SCRIPT="$tmp/sb.sh"
  touch "$CONFIG_FILE" "$USER_DB_FILE" "$META_FILE" "$SINGBOX_BIN" "$SINGBOX_VERSION_STAMP" "$GRPCURL_BIN" \
    "$SB_SHORTCUT" "$SB_TARGET_SCRIPT" "$tmp/bot-service" "$tmp/core-service" "$tmp/sync" "$tmp/maintain" "$tmp/agent" \
    "$tmp/hop" "$tmp/etc/sing-box/key" "$tmp/var/log/sing-box/access.log" "$tmp/external-wireproxy"
  printf '%s\n' '{"enabled":true,"role":"center","bindings":[{"username":"alice"}]}' > "$TG_CONFIG_FILE"
  if [ "$mode" = keep ]; then
    uninstall_singbox_keep_config <<< $'1\ny'
    [ -e "$tmp/sampled" ] && [ -e "$tmp/hop" ]
    for preserved in "$CONFIG_FILE" "$USER_DB_FILE" "$META_FILE" "$SB_SHORTCUT" "$SB_TARGET_SCRIPT" \
      "$tmp/etc/sing-box/key" "$tmp/var/log/sing-box/access.log"; do [ -e "$preserved" ]; done
    jq -e '(.enabled==false) and .bindings[0].username=="alice"' "$TG_CONFIG_FILE" >/dev/null
  else
    (uninstall_singbox_keep_config <<< $'2\nyes')
    for removed in "$tmp/etc/sing-box" "$tmp/etc/sing-box-manager" "$tmp/var/log/sing-box" "$tmp/var/lib/sing-box" \
      "$SB_SHORTCUT" "$SB_TARGET_SCRIPT" "$tmp/hop"; do [ ! -e "$removed" ]; done
  fi
  for removed in "$SINGBOX_BIN" "$GRPCURL_BIN" "$SINGBOX_VERSION_STAMP" "$tmp/bot-service" "$tmp/core-service" \
    "$tmp/sync" "$tmp/maintain" "$tmp/agent"; do [ ! -e "$removed" ]; done
  [ -e "$tmp/external-wireproxy" ]
done
printf '%s\n' 'PASS stage I generated uninstall menus: retained and full removal footprints'
