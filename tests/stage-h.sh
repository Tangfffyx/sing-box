#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 60_user_db 63_telegram_bot; do source "lib/$module.sh"; done
source <(sed '/^# CLI 入口路由/,$d' lib/99_main.sh)
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
clear() { :; }
pause() { :; }
ensure_local_script_entrypoint_once() { :; }
singbox_dashboard_summary() { :; }
has_cmd() {
  if [ "$1" = sing-box ]; then [ "$installed" = yes ]; else command -v "$1" >/dev/null; fi
}
for menu in protocol_manager manage_relay_nodes user_manager_menu export_configs install_and_uninstall_menu system_tools_menu warp_manager_menu telegram_bot_manager_menu; do
  eval "$menu() { printf '%s\\n' 'OPEN $menu'; }"
done
for installed in no yes; do
  home="$(main_menu <<< $'1\n2\n3\n4\n5\n6\n7\n8\n0')"
  expected=$'OPEN protocol_manager\nOPEN manage_relay_nodes\nOPEN user_manager_menu\nOPEN export_configs\nOPEN install_and_uninstall_menu\nOPEN system_tools_menu\nOPEN warp_manager_menu\nOPEN telegram_bot_manager_menu'
  [ "$(printf '%s\n' "$home" | awk '/^OPEN /')" = "$expected" ]
  [[ "$home" == *核心功能*系统维护*扩展功能* ]]
  [[ "$home" != *时间校准* ]]
  if [ "$installed" = yes ]; then [[ "$home" != *首次使用请选择* ]]; else [[ "$home" == *首次使用请选择*安装与卸载* ]]; fi
done
printf '%s\n' 'PASS stage H home numbering, dispatch, returns, exit and conditional install hint'

source lib/63_telegram_bot.sh
TG_CONFIG_FILE="$tmp/center.json"
TG_CENTER_APP="$tmp/center.py"
TG_AGENT_LOCK_FILE="$tmp/agent-lock"
CONFIG_FILE="$tmp/core.json"
USER_DB_FILE=tests/fixtures/migration-7.0.0/user-manager.json
SB_LOCK_FILE="$tmp/manager.lock"
get_public_ip() { printf '%s\n' '192.0.2.4'; }
tg_bot_username_from_token() { [ "$1" = 'fixture-token' ] && printf '%s\n' fixture_bot; }
tg_generate_secret() { printf '%s\n' fixture-secret; }
tg_install_center_service() { touch "$tmp/center-running"; }
tg_stop_center_service() { rm -f "$tmp/center-running"; }
install_tg_agent_cron() { touch "$tmp/cron"; }
remove_tg_agent_cron() { rm -f "$tmp/cron"; }
tg_agent_sync_now() {
  jq -c '{role,vps_name,center_url,vps_id}' "$TG_CONFIG_FILE" >> "$tmp/reports"
}
tg_center_api_post() {
  [ "$1" = 'http://127.0.0.1:25888' ] && [ "$2" = fixture-secret ] || return 1
  case "$3" in
    /api/test) jq -e '.vps_name=="首台"' <<< "$4" >/dev/null && printf '%s\n' '{"ok":true}' ;;
    /api/bind-token)
      jq -e '.username=="alice" and .vps_name=="首台"' <<< "$4" >/dev/null &&
        printf '%s\n' '{"link":"https://t.me/fixture_bot?start=bind_fixture"}' ;;
  esac
}
output="$tmp/bot-view"
telegram_bot_manager_menu <<< $'1\n1\nfixture-token\n12345\n\n首台\n3\n2\n1\n5\ny\n1\ny\n0' > "$output" 2>&1
for phrase in '首次使用，选 1 设置机器人。' '在本机运行机器人（只有一台服务器就选这个）'   '在 Telegram 打开 @fixture_bot' '选 3 发送测试' '通知测试已发送到管理员'   '把链接发给 alice，请对方在 10 分钟内打开并点「开始」' '设置已保留，选 1 恢复'; do
  grep -Fq "$phrase" "$output"
done
jq -e '.enabled and .role=="center" and .access_secret=="fixture-secret" and .bot_username=="fixture_bot"' "$TG_CONFIG_FILE" >/dev/null
[ -f "$tmp/center-running" ] && [ -f "$tmp/cron" ]
center_url="$(jq -r .center_url "$TG_CONFIG_FILE")"
TG_CONFIG_FILE="$tmp/second.json"
telegram_bot_manager_menu <<< $'1\n2\n'"$center_url"$'\nfixture-secret\n第二台\n0' > "$output" 2>&1
grep -Fq '复制主控地址和接入密钥' "$output"
grep -Fq '已接入其他服务器的机器人' "$output"
jq -e '.enabled and .role=="agent" and .center_url=="http://192.0.2.4:25888" and .access_secret=="fixture-secret"' "$TG_CONFIG_FILE" >/dev/null
jq -se 'map(.role) == ["center","center","agent"] and .[0].vps_id==.[1].vps_id and .[0].vps_id!=.[2].vps_id' "$tmp/reports" >/dev/null
printf '%s\n' 'PASS stage H Bot first setup, test, user binding guide, retained config recovery and second server setup'

for module in 30_route 35_split_rule_conflict 40_relay 50_v2ray_api 64_warp; do source "lib/$module.sh"; done
warp_init_env() { :; }
warp_add_preset_rules() { printf 'SELECTED %s\n' "$1"; }
META_FILE="$tmp/meta.json"
printf '%s\n' '{}' > "$META_FILE"
view="$(warp_manager_menu <<< $'2\n0')"
[[ "$view" == *首次使用会自动配置*暂无规则*'SELECTED 2'* ]]
printf '%s\n' '{"warp":{"mode":"rules","rules":[{"name":"Google","file":"geosite-google.srs"}]}}' > "$META_FILE"
view="$(warp_manager_menu <<< 0)"
[[ "$view" == *Google*'→ WARP'* ]]
printf '%s\n' 'PASS stage H WARP first selection and configured website status'
