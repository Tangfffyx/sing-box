#!/usr/bin/env bash
# Offline task execution only: no Telegram API, reports, polling or notifications.
set -euo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo 'SKIP Telegram fixtures (Bash 4+ in Linux CI)'; exit 0; }
cd "$(dirname "$0")/.."
for module in 00_base 01_utils 10_config 60_user_db 61_user_manager 63_telegram_bot; do source "lib/$module.sh"; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
USER_DB_FILE="$T/users.json"; SB_LOCK_FILE="$T/lock"
sync_user_usage_counters() { :; }
user_db_save() { printf '%s\n' "$1" > "$USER_DB_FILE"; }
tg_task_apply_db() { user_db_save "$1"; }
echo '{"enabled":true,"users":{"admin":{"enabled":true},"alice":{"enabled":true,"expire_at":"0","used_down_bytes":123}}}' > "$USER_DB_FILE"
run_task() { tg_execute_task "$(jq -nc --arg action "$1" --argjson params "$2" '{username:"alice",action:$action,params:$params}')" >/dev/null; }
run_task set_quota '{"quota_gb":20}'
run_task set_enabled '{"enabled":false}'
jq -e '.users.alice.quota_gb == 20 and .users.alice.enabled == false and .users.alice.used_down_bytes == 123' "$USER_DB_FILE" >/dev/null
run_task add_usage '{"bytes":100}'
run_task add_usage '{"bytes":-30}'
jq -e '.users.alice.manual_added_bytes == 70' "$USER_DB_FILE" >/dev/null
run_task reset_usage '{}'
jq -e '.users.alice.used_down_bytes == 0 and .users.alice.manual_added_bytes == 0' "$USER_DB_FILE" >/dev/null
run_task set_expire '{"expire_at":"2099-01-01"}'
run_task set_reset_day '{"reset_day":32}'
run_task set_enabled '{"enabled":true}'
jq -e '.users.alice.enabled and .users.alice.reset_day == 32 and .users.alice.expire_at == "2099-01-01"' "$USER_DB_FILE" >/dev/null
if run_task set_reset_day '{"reset_day":99}' 2>/dev/null; then exit 1; fi
echo 'PASS offline Telegram quota, enabled state, add/reset usage, expiry and reset-day tasks'
